#Requires -Version 5.1

[CmdletBinding()]
param(
    [Parameter(Mandatory = $true, Position = 0)]
    [Alias('Path')]
    [string]$SourcePath,

    [string]$IncludePath,

    [string]$MetaEditorPath,

    [ValidateRange(5, 1800)]
    [int]$TimeoutSeconds = 120,

    [switch]$SyntaxOnly,

    [switch]$WarningsAsErrors
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$nativeTypeLoadError = $null
try {
    if (-not ('Mql5Coding.CompilerProcessJob' -as [type])) {
        Add-Type -Path (Join-Path $PSScriptRoot 'CompilerProcessJob.cs')
    }
}
catch {
    $nativeTypeLoadError = $_.Exception.Message
}

$ExitSuccess = 0
$ExitCompileError = 1
$ExitToolError = 2
$ExitTimeout = 3
$ExitWarningsAsErrors = 4

$exitCode = $ExitToolError
$status = 'tool_error'
$errorMessage = $null
$logText = $null
$errorCount = $null
$warningCount = $null
$artifactPath = $null
$resolvedSource = $null
$resolvedInclude = $null
$resolvedMetaEditor = $null
$logPath = $null
$logSnapshot = $null
$artifactSnapshot = $null
$logPrepared = $false
$mutex = $null
$mutexHeld = $false
$compileLaunch = $null
$compileJobEmpty = $false

function Resolve-ExistingFile {
    param(
        [Parameter(Mandatory = $true)]
        [string]$LiteralPath,

        [Parameter(Mandatory = $true)]
        [string]$Description
    )

    $item = Get-Item -LiteralPath $LiteralPath -ErrorAction Stop
    if ($item.PSIsContainer) {
        throw "$Description must be a file: $LiteralPath"
    }

    return $item.FullName
}

function Get-MetaEditorFromCandidate {
    param([AllowNull()][string]$Candidate)

    if ([string]::IsNullOrWhiteSpace($Candidate)) {
        return $null
    }

    $expanded = [Environment]::ExpandEnvironmentVariables($Candidate.Trim().Trim('"'))
    if (Test-Path -LiteralPath $expanded -PathType Container) {
        foreach ($name in @('metaeditor64.exe', 'metaeditor.exe')) {
            $child = Join-Path $expanded $name
            if (Test-Path -LiteralPath $child -PathType Leaf) {
                return (Get-Item -LiteralPath $child).FullName
            }
        }
        return $null
    }

    if (Test-Path -LiteralPath $expanded -PathType Leaf) {
        $item = Get-Item -LiteralPath $expanded
        if ($item.Name -in @('metaeditor64.exe', 'metaeditor.exe')) {
            return $item.FullName
        }
    }

    return $null
}

function Resolve-MetaEditorExecutable {
    param([AllowNull()][string]$RequestedPath)

    if (-not [string]::IsNullOrWhiteSpace($RequestedPath)) {
        $requested = Get-MetaEditorFromCandidate -Candidate $RequestedPath
        if ($null -eq $requested) {
            throw "MetaEditor was not found at the supplied path: $RequestedPath"
        }
        return $requested
    }

    foreach ($variableName in @('METAEDITOR_EXE', 'METAEDITOR_PATH')) {
        foreach ($scope in @('Process', 'User', 'Machine')) {
            $value = [Environment]::GetEnvironmentVariable($variableName, $scope)
            $fromEnvironment = Get-MetaEditorFromCandidate -Candidate $value
            if ($null -ne $fromEnvironment) {
                return $fromEnvironment
            }
        }
    }

    foreach ($knownPath in @(
        'C:\Program Files\MetaTrader 5\metaeditor64.exe',
        'C:\Program Files (x86)\MetaTrader 5\metaeditor.exe'
    )) {
        $known = Get-MetaEditorFromCandidate -Candidate $knownPath
        if ($null -ne $known) {
            return $known
        }
    }

    foreach ($processName in @('metaeditor64', 'metaeditor')) {
        foreach ($process in @(Get-Process -Name $processName -ErrorAction SilentlyContinue)) {
            try {
                $processPath = [string]$process.Path
            }
            catch {
                continue
            }
            $fromProcess = Get-MetaEditorFromCandidate -Candidate $processPath
            if ($null -ne $fromProcess) {
                return $fromProcess
            }
        }
    }

    foreach ($commandName in @('metaeditor64.exe', 'metaeditor.exe')) {
        $command = Get-Command $commandName -ErrorAction SilentlyContinue
        if ($null -ne $command) {
            $fromCommand = Get-MetaEditorFromCandidate -Candidate $command.Source
            if ($null -ne $fromCommand) {
                return $fromCommand
            }
        }
    }

    $uninstallRoots = @(
        'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*',
        'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\*',
        'HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*'
    )
    foreach ($entry in @(Get-ItemProperty -Path $uninstallRoots -ErrorAction SilentlyContinue)) {
        $displayNameProperty = $entry.PSObject.Properties['DisplayName']
        $installLocationProperty = $entry.PSObject.Properties['InstallLocation']
        if ($null -eq $displayNameProperty -or $null -eq $installLocationProperty) {
            continue
        }

        try {
            $displayName = [string]$displayNameProperty.Value
            $installLocation = [string]$installLocationProperty.Value
        }
        catch {
            continue
        }
        if ($displayName -notmatch 'MetaTrader 5|MetaEditor' -or
            [string]::IsNullOrWhiteSpace($installLocation)) {
            continue
        }

        try {
            $fromRegistry = Get-MetaEditorFromCandidate -Candidate $installLocation
        }
        catch {
            continue
        }
        if ($null -ne $fromRegistry) {
            return $fromRegistry
        }
    }

    foreach ($programFilesRoot in @($env:ProgramFiles, ${env:ProgramFiles(x86)})) {
        if ([string]::IsNullOrWhiteSpace($programFilesRoot) -or
            -not (Test-Path -LiteralPath $programFilesRoot -PathType Container)) {
            continue
        }
        foreach ($directory in @(Get-ChildItem -LiteralPath $programFilesRoot -Directory -ErrorAction SilentlyContinue)) {
            $fromProgramFiles = Get-MetaEditorFromCandidate -Candidate $directory.FullName
            if ($null -ne $fromProgramFiles) {
                return $fromProgramFiles
            }
        }
    }

    throw 'MetaEditor was not found. Supply -MetaEditorPath or set METAEDITOR_EXE.'
}

function Read-SharedText {
    param([Parameter(Mandatory = $true)][string]$LiteralPath)

    $stream = [System.IO.FileStream]::new(
        $LiteralPath,
        [System.IO.FileMode]::Open,
        [System.IO.FileAccess]::Read,
        [System.IO.FileShare]::ReadWrite
    )
    try {
        $reader = [System.IO.StreamReader]::new($stream, $true)
        try {
            return $reader.ReadToEnd()
        }
        finally {
            $reader.Dispose()
        }
    }
    finally {
        $stream.Dispose()
    }
}

function Get-SharedFileSha256 {
    param([Parameter(Mandatory = $true)][string]$LiteralPath)

    $stream = [System.IO.FileStream]::new(
        $LiteralPath,
        [System.IO.FileMode]::Open,
        [System.IO.FileAccess]::Read,
        [System.IO.FileShare]::ReadWrite
    )
    $algorithm = [System.Security.Cryptography.SHA256]::Create()
    try {
        return [System.BitConverter]::ToString(
            $algorithm.ComputeHash($stream)
        ).Replace('-', '')
    }
    finally {
        $algorithm.Dispose()
        $stream.Dispose()
    }
}

function Get-ArtifactState {
    param([Parameter(Mandatory = $true)][string]$LiteralPath)

    if (-not (Test-Path -LiteralPath $LiteralPath -PathType Leaf)) {
        return [pscustomobject]@{
            Existed          = $false
            LastWriteTimeUtc = [datetime]::MinValue
            Length           = [long]0
            Sha256           = $null
        }
    }

    $item = Get-Item -LiteralPath $LiteralPath
    return [pscustomobject]@{
        Existed          = $true
        LastWriteTimeUtc = $item.LastWriteTimeUtc
        Length           = [long]$item.Length
        Sha256           = Get-SharedFileSha256 -LiteralPath $LiteralPath
    }
}

function Restore-OriginalLog {
    param(
        [Parameter(Mandatory = $true)][string]$LiteralPath,
        [Parameter(Mandatory = $true)]$Snapshot
    )

    $lastError = $null
    for ($attempt = 0; $attempt -lt 30; $attempt++) {
        try {
            if (Test-Path -LiteralPath $LiteralPath -PathType Leaf) {
                [System.IO.File]::SetAttributes($LiteralPath, [System.IO.FileAttributes]::Normal)
                Remove-Item -LiteralPath $LiteralPath -Force
            }

            if ($Snapshot.Existed) {
                [System.IO.File]::WriteAllBytes($LiteralPath, $Snapshot.Bytes)
                [System.IO.File]::SetCreationTimeUtc($LiteralPath, $Snapshot.CreationTimeUtc)
                [System.IO.File]::SetLastWriteTimeUtc($LiteralPath, $Snapshot.LastWriteTimeUtc)
                [System.IO.File]::SetLastAccessTimeUtc($LiteralPath, $Snapshot.LastAccessTimeUtc)
                [System.IO.File]::SetAttributes($LiteralPath, $Snapshot.Attributes)
            }
            return
        }
        catch {
            $lastError = $_.Exception
            Start-Sleep -Milliseconds 100
        }
    }

    throw "Could not restore the original compilation log: $($lastError.Message)"
}

try {
    if (-not [string]::IsNullOrWhiteSpace($nativeTypeLoadError)) {
        throw "The compiler process-isolation helper could not be loaded: $nativeTypeLoadError"
    }

    $resolvedSource = Resolve-ExistingFile -LiteralPath $SourcePath -Description 'Source path'
    $extension = [System.IO.Path]::GetExtension($resolvedSource).ToLowerInvariant()
    if ($extension -ne '.mq5') {
        throw "Source must be an .mq5 file: $resolvedSource"
    }

    if (-not [string]::IsNullOrWhiteSpace($IncludePath)) {
        $includeItem = Get-Item -LiteralPath $IncludePath -ErrorAction Stop
        if (-not $includeItem.PSIsContainer) {
            throw "Include path must be an MQL5 root directory: $IncludePath"
        }
        $resolvedInclude = $includeItem.FullName
    }
    else {
        $directory = (Get-Item -LiteralPath $resolvedSource).Directory
        while ($null -ne $directory) {
            if ($directory.Name -eq 'MQL5') {
                $resolvedInclude = $directory.FullName
                break
            }
            $directory = $directory.Parent
        }
    }

    $resolvedMetaEditor = Resolve-MetaEditorExecutable -RequestedPath $MetaEditorPath
    $artifactPath = [System.IO.Path]::ChangeExtension($resolvedSource, '.ex5')
    $logPath = [System.IO.Path]::ChangeExtension($resolvedSource, '.log')

    $sha256 = [System.Security.Cryptography.SHA256]::Create()
    try {
        $sourceHash = [System.BitConverter]::ToString(
            $sha256.ComputeHash([System.Text.Encoding]::UTF8.GetBytes($resolvedSource.ToLowerInvariant()))
        ).Replace('-', '').Substring(0, 24)
    }
    finally {
        $sha256.Dispose()
    }

    $mutex = [System.Threading.Mutex]::new($false, "Local\CodexMqlCompile_$sourceHash")
    try {
        $mutexHeld = $mutex.WaitOne([TimeSpan]::FromSeconds([Math]::Min(30, $TimeoutSeconds)))
    }
    catch [System.Threading.AbandonedMutexException] {
        $mutexHeld = $true
    }
    if (-not $mutexHeld) {
        throw "Another compilation is already using this source file: $resolvedSource"
    }

    $artifactSnapshot = Get-ArtifactState -LiteralPath $artifactPath

    if (Test-Path -LiteralPath $logPath -PathType Leaf) {
        $existingLog = Get-Item -LiteralPath $logPath
        $logSnapshot = [pscustomobject]@{
            Existed           = $true
            Bytes             = [System.IO.File]::ReadAllBytes($logPath)
            Attributes        = $existingLog.Attributes
            CreationTimeUtc   = $existingLog.CreationTimeUtc
            LastWriteTimeUtc  = $existingLog.LastWriteTimeUtc
            LastAccessTimeUtc = $existingLog.LastAccessTimeUtc
        }
    }
    else {
        $logSnapshot = [pscustomobject]@{
            Existed           = $false
            Bytes             = $null
            Attributes        = [System.IO.FileAttributes]::Normal
            CreationTimeUtc   = [datetime]::MinValue
            LastWriteTimeUtc  = [datetime]::MinValue
            LastAccessTimeUtc = [datetime]::MinValue
        }
    }

    $logPrepared = $true
    if (Test-Path -LiteralPath $logPath -PathType Leaf) {
        [System.IO.File]::SetAttributes($logPath, [System.IO.FileAttributes]::Normal)
        Remove-Item -LiteralPath $logPath -Force
    }

    $arguments = '/compile:"{0}" /log' -f $resolvedSource
    if (-not [string]::IsNullOrWhiteSpace($resolvedInclude)) {
        $arguments += ' /include:"{0}"' -f $resolvedInclude
    }
    if ($SyntaxOnly) {
        $arguments += ' /s'
    }

    Write-Output "MQL5_COMPILE_SOURCE=$resolvedSource"
    Write-Output "MQL5_METAEDITOR=$resolvedMetaEditor"
    Write-Output "MQL5_COMPILE_MODE=$(if ($SyntaxOnly) { 'syntax' } else { 'compile' })"
    if (-not [string]::IsNullOrWhiteSpace($resolvedInclude)) {
        Write-Output "MQL5_INCLUDE_ROOT=$resolvedInclude"
    }

    $compileLaunch = [Mql5Coding.CompilerProcessJob]::Start(
        $resolvedMetaEditor,
        $arguments,
        (Split-Path -Parent $resolvedMetaEditor)
    )
    Write-Output "MQL5_METAEDITOR_PROCESS_ID=$($compileLaunch.ProcessId)"

    $stopwatch = [System.Diagnostics.Stopwatch]::StartNew()
    $summaryMatch = $null
    while ($stopwatch.Elapsed.TotalSeconds -lt $TimeoutSeconds) {
        if (Test-Path -LiteralPath $logPath -PathType Leaf) {
            try {
                $candidateText = Read-SharedText -LiteralPath $logPath
                $matches = [regex]::Matches(
                    $candidateText,
                    '(?im)^\s*Result:\s*(?<errors>\d+)\s+errors?,\s*(?<warnings>\d+)\s+warnings?'
                )
                if ($matches.Count -gt 0) {
                    $logText = $candidateText
                    $summaryMatch = $matches[$matches.Count - 1]
                    break
                }
            }
            catch {
                # MetaEditor may still have the log open; retry until the deadline.
            }
        }
        Start-Sleep -Milliseconds 100
    }
    $stopwatch.Stop()

    if ($null -ne $summaryMatch) {
        try {
            $compileLaunch.WaitForEmpty(5000)
            $compileJobEmpty = $true
        }
        catch {
            $shutdownError = $_.Exception.Message
            try {
                $compileLaunch.TerminateAndWaitForEmpty(5000)
                $compileJobEmpty = $true
            }
            catch {
                throw (
                    "MetaEditor produced a Result line but did not exit cleanly, and its process " +
                    "could not be terminated: $shutdownError Cleanup error: $($_.Exception.Message)"
                )
            }
            throw (
                "MetaEditor produced a Result line but did not exit cleanly within 5 seconds; " +
                "its process was terminated and the artifact was not accepted. $shutdownError"
            )
        }

        $logText = Read-SharedText -LiteralPath $logPath
        $finalMatches = [regex]::Matches(
            $logText,
            '(?im)^\s*Result:\s*(?<errors>\d+)\s+errors?,\s*(?<warnings>\d+)\s+warnings?'
        )
        if ($finalMatches.Count -eq 0) {
            throw 'MetaEditor log lost its complete Result line before the compiler process exited.'
        }
        $summaryMatch = $finalMatches[$finalMatches.Count - 1]
    }

    if ($null -eq $summaryMatch) {
        $cleanupFailed = $false
        try {
            $compileLaunch.TerminateAndWaitForEmpty(5000)
            $compileJobEmpty = $true
        }
        catch {
            $cleanupFailed = $true
            $errorMessage = "MetaEditor timed out and its process could not be terminated: $($_.Exception.Message)"
        }
        if (Test-Path -LiteralPath $logPath -PathType Leaf) {
            try { $logText = Read-SharedText -LiteralPath $logPath } catch { }
        }
        if ($cleanupFailed) {
            $exitCode = $ExitToolError
            $status = 'tool_error'
        }
        else {
            $exitCode = $ExitTimeout
            $status = 'timeout'
            $errorMessage = "MetaEditor did not produce a complete Result line within $TimeoutSeconds seconds."
        }
    }
    else {
        $errorCount = [int]$summaryMatch.Groups['errors'].Value
        $warningCount = [int]$summaryMatch.Groups['warnings'].Value

        if ($errorCount -gt 0) {
            $exitCode = $ExitCompileError
            $status = 'compile_error'
        }
        elseif ($WarningsAsErrors -and $warningCount -gt 0) {
            $exitCode = $ExitWarningsAsErrors
            $status = 'warnings_as_errors'
        }
        else {
            $artifactRefreshed = $SyntaxOnly
            if (-not $SyntaxOnly) {
                $artifactDeadline = [datetime]::UtcNow.AddSeconds(2)
                do {
                    if (Test-Path -LiteralPath $artifactPath -PathType Leaf) {
                        $artifactState = Get-ArtifactState -LiteralPath $artifactPath
                        $artifactRefreshed = (
                            $artifactState.Existed -and
                            $artifactState.Length -gt 0 -and
                            (
                                -not $artifactSnapshot.Existed -or
                                $artifactState.LastWriteTimeUtc -ne $artifactSnapshot.LastWriteTimeUtc -or
                                $artifactState.Length -ne $artifactSnapshot.Length -or
                                $artifactState.Sha256 -cne $artifactSnapshot.Sha256
                            )
                        )
                        if ($artifactRefreshed) {
                            break
                        }
                    }
                    Start-Sleep -Milliseconds 50
                } while ([datetime]::UtcNow -lt $artifactDeadline)
            }

            if (-not $artifactRefreshed) {
                $exitCode = $ExitToolError
                $status = 'tool_error'
                $errorMessage = "MetaEditor reported zero errors but did not create or refresh the expected artifact: $artifactPath"
            }
            else {
                $exitCode = $ExitSuccess
                $status = 'success'
            }
        }
    }
}
catch {
    $exitCode = $ExitToolError
    $status = 'tool_error'
    $errorMessage = $_.Exception.Message
}
finally {
    if ($null -ne $compileLaunch) {
        if (-not $compileJobEmpty) {
            try {
                $compileLaunch.TerminateAndWaitForEmpty(5000)
                $compileJobEmpty = $true
            }
            catch {
                $exitCode = $ExitToolError
                $status = 'tool_error'
                $errorMessage = "MetaEditor process cleanup failed before log restoration: $($_.Exception.Message)"
            }
        }
        $compileLaunch.Dispose()
        $compileLaunch = $null
    }

    if ($logPrepared -and $null -ne $logPath -and $null -ne $logSnapshot) {
        try {
            Restore-OriginalLog -LiteralPath $logPath -Snapshot $logSnapshot
        }
        catch {
            $exitCode = $ExitToolError
            $status = 'tool_error'
            $errorMessage = $_.Exception.Message
        }
    }

    if ($mutexHeld -and $null -ne $mutex) {
        try { $mutex.ReleaseMutex() } catch { }
    }
    if ($null -ne $mutex) {
        $mutex.Dispose()
    }
}

if (-not [string]::IsNullOrWhiteSpace($logText)) {
    Write-Output 'MQL5_METAEDITOR_LOG_BEGIN'
    Write-Output $logText.TrimEnd()
    Write-Output 'MQL5_METAEDITOR_LOG_END'
}

if (-not [string]::IsNullOrWhiteSpace($errorMessage)) {
    [Console]::Error.WriteLine("MQL5_COMPILE_TOOL_MESSAGE=$errorMessage")
}

$errorValue = if ($null -eq $errorCount) { 'unknown' } else { [string]$errorCount }
$warningValue = if ($null -eq $warningCount) { 'unknown' } else { [string]$warningCount }
Write-Output "MQL5_COMPILE_SUMMARY status=$status errors=$errorValue warnings=$warningValue exit_code=$exitCode"
if ($exitCode -eq $ExitSuccess -and -not $SyntaxOnly -and $null -ne $artifactPath) {
    Write-Output "MQL5_COMPILE_ARTIFACT=$artifactPath"
}

exit $exitCode
