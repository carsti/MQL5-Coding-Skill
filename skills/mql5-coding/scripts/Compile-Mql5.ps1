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
$artifactPrepared = $false
$artifactAccepted = $false
$artifactOutputLease = $null
$artifactBackupLease = $null
$artifactBackupPath = $null
$artifactBackupIdentity = $null
$logPrepared = $false
$logOutputLease = $null
$pathMutex = $null
$pathMutexHeld = $false
$identityMutex = $null
$identityMutexHeld = $false
$sourceParentLease = $null
$sourceReadLease = $null
$compileLaunch = $null
$compileJobEmpty = $true

function Resolve-ExistingFile {
    param(
        [Parameter(Mandatory = $true)]
        [string]$LiteralPath,

        [Parameter(Mandatory = $true)]
        [string]$Description
    )

    if ([string]::IsNullOrWhiteSpace($LiteralPath)) {
        throw "$Description is required."
    }
    return [System.IO.Path]::GetFullPath($LiteralPath)
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
    param(
        [Parameter(Mandatory = $true)][string]$LiteralPath,
        [Parameter(Mandatory = $true)]$Lease
    )

    $expectedIdentity = [string]$Lease.Identity
    if ([string]$Lease.GetCurrentIdentity() -cne $expectedIdentity) {
        throw "Artifact identity lease changed before inspection: $LiteralPath"
    }
    $item = Get-Item -LiteralPath $LiteralPath -ErrorAction Stop
    $state = [pscustomobject]@{
        Existed          = $true
        LastWriteTimeUtc = $item.LastWriteTimeUtc
        Length           = [long]$item.Length
        Sha256           = Get-SharedFileSha256 -LiteralPath $LiteralPath
    }
    if ([string]$Lease.GetCurrentIdentity() -cne $expectedIdentity) {
        throw "Artifact identity lease changed during inspection: $LiteralPath"
    }
    return $state
}

function Move-OriginalArtifactAside {
    param([Parameter(Mandatory = $true)][string]$LiteralPath)

    $directory = [System.IO.Path]::GetDirectoryName($LiteralPath)
    $maximumLeafLength = [System.IO.Path]::GetFileName($LiteralPath).Length
    $backupLeafLength = [Math]::Min(32, $maximumLeafLength)
    $lastError = $null
    for ($attempt = 0; $attempt -lt 100; $attempt++) {
        $candidateLeaf = [guid]::NewGuid().ToString('N').Substring(0, $backupLeafLength)
        $candidate = Join-Path $directory $candidateLeaf
        try {
            [System.IO.File]::Move($LiteralPath, $candidate)
            return $candidate
        }
        catch [System.IO.IOException] {
            $lastError = $_.Exception
        }
    }
    throw "Could not move the original compiler artifact to a unique adjacent backup path: $($lastError.Message)"
}

function Remove-CompilerArtifactSafely {
    param(
        [Parameter(Mandatory = $true)][string]$LiteralPath,
        [AllowNull()][string]$ExpectedIdentity
    )

    $lease = [Mql5Coding.CompilerProcessJob]::TryOpenMovableOutputFileIdentityLease(
        $LiteralPath
    )
    if ($null -eq $lease) {
        return
    }
    try {
        if (-not [string]::IsNullOrWhiteSpace($ExpectedIdentity) -and
            [string]$lease.Identity -cne $ExpectedIdentity) {
            throw "Refusing to remove a compiler artifact whose identity changed: $LiteralPath"
        }
        [System.IO.File]::Delete($LiteralPath)
    }
    finally {
        $lease.Dispose()
    }
}

function Restore-OriginalArtifact {
    param(
        [Parameter(Mandatory = $true)][string]$LiteralPath,
        [Parameter(Mandatory = $true)][string]$BackupPath,
        [Parameter(Mandatory = $true)][string]$BackupIdentity
    )

    $backupLease = [Mql5Coding.CompilerProcessJob]::TryOpenMovableOutputFileIdentityLease(
        $BackupPath
    )
    if ($null -eq $backupLease) {
        throw "The preserved compiler artifact backup is missing: $BackupPath"
    }
    try {
        if ([string]$backupLease.Identity -cne $BackupIdentity) {
            throw "The preserved compiler artifact backup identity changed: $BackupPath"
        }
        [System.IO.File]::Move($BackupPath, $LiteralPath)
    }
    finally {
        $backupLease.Dispose()
    }

    $restoredLease = [Mql5Coding.CompilerProcessJob]::TryOpenPinnedOutputFileIdentityLease(
        $LiteralPath
    )
    if ($null -eq $restoredLease) {
        throw "The original compiler artifact was not restored: $LiteralPath"
    }
    try {
        if ([string]$restoredLease.Identity -cne $BackupIdentity) {
            throw "The restored compiler artifact identity does not match its backup: $LiteralPath"
        }
    }
    finally {
        $restoredLease.Dispose()
    }
}

function ConvertTo-WindowsCommandLineArgument {
    param([Parameter(Mandatory = $true)][AllowEmptyString()][string]$Value)

    if ($Value.Length -eq 0) {
        return '""'
    }
    if ($Value -notmatch '[\s"]') {
        return $Value
    }

    $builder = New-Object Text.StringBuilder
    [void]$builder.Append('"')
    $backslashes = 0
    foreach ($character in $Value.ToCharArray()) {
        if ($character -eq [char]92) {
            $backslashes++
            continue
        }

        if ($character -eq [char]34) {
            if ($backslashes -gt 0) {
                [void]$builder.Append([string]::new([char]92, $backslashes * 2))
            }
            [void]$builder.Append('\"')
        }
        else {
            if ($backslashes -gt 0) {
                [void]$builder.Append([string]::new([char]92, $backslashes))
            }
            [void]$builder.Append($character)
        }
        $backslashes = 0
    }

    if ($backslashes -gt 0) {
        [void]$builder.Append([string]::new([char]92, $backslashes * 2))
    }
    [void]$builder.Append('"')
    return $builder.ToString()
}

function Move-OriginalLogAside {
    param([Parameter(Mandatory = $true)][string]$LiteralPath)

    $directory = [System.IO.Path]::GetDirectoryName($LiteralPath)
    $maximumLeafLength = [System.IO.Path]::GetFileName($LiteralPath).Length
    $backupLeafLength = [Math]::Min(32, $maximumLeafLength)
    $lastError = $null
    for ($attempt = 0; $attempt -lt 100; $attempt++) {
        $candidateLeaf = [guid]::NewGuid().ToString('N').Substring(0, $backupLeafLength)
        $candidate = Join-Path $directory $candidateLeaf
        try {
            [System.IO.File]::Move($LiteralPath, $candidate)
            return $candidate
        }
        catch [System.IO.IOException] {
            $lastError = $_.Exception
        }
    }

    throw "Could not allocate a unique adjacent backup path for '$LiteralPath': $($lastError.Message)"
}

function Restore-OriginalLog {
    param(
        [Parameter(Mandatory = $true)][string]$LiteralPath,
        [Parameter(Mandatory = $true)]$Snapshot
    )

    $lastError = $null
    for ($attempt = 0; $attempt -lt 30; $attempt++) {
        $currentLease = $null
        $backupLease = $null
        try {
            $currentLease = [Mql5Coding.CompilerProcessJob]::TryOpenMovableOutputFileIdentityLease(
                $LiteralPath
            )
            if ($null -ne $currentLease) {
                [System.IO.File]::SetAttributes(
                    $LiteralPath,
                    [System.IO.FileAttributes]::Normal
                )
                [System.IO.File]::Delete($LiteralPath)
                $currentLease.Dispose()
                $currentLease = $null
            }

            if ($Snapshot.Existed) {
                $backupLease = [Mql5Coding.CompilerProcessJob]::TryOpenMovableOutputFileIdentityLease(
                    $Snapshot.BackupPath
                )
                if ($null -eq $backupLease) {
                    throw "The preserved log backup is missing: $($Snapshot.BackupPath)"
                }
                if ($null -ne $Snapshot.PSObject.Properties['Identity'] -and
                    -not [string]::IsNullOrWhiteSpace([string]$Snapshot.Identity) -and
                    [string]$backupLease.Identity -cne [string]$Snapshot.Identity) {
                    throw "The preserved log backup identity changed: $($Snapshot.BackupPath)"
                }
                [System.IO.File]::Move($Snapshot.BackupPath, $LiteralPath)
                $backupLease.Dispose()
                $backupLease = $null
            }
            return
        }
        catch {
            $lastError = $_.Exception
            Start-Sleep -Milliseconds 100
        }
        finally {
            if ($null -ne $currentLease) {
                $currentLease.Dispose()
            }
            if ($null -ne $backupLease) {
                $backupLease.Dispose()
            }
        }
    }

    $recovery = if ($Snapshot.Existed) {
        " The preserved original remains at: $($Snapshot.BackupPath)"
    }
    else {
        ''
    }
    throw "Could not restore the original compilation log: $($lastError.Message)$recovery"
}

function Complete-CompilationLog {
    param(
        [Parameter(Mandatory = $true)][string]$LiteralPath,
        [Parameter(Mandatory = $true)]$Snapshot,
        [Parameter(Mandatory = $true)][bool]$ProcessTreeEmpty
    )

    if (-not $ProcessTreeEmpty) {
        $recovery = if ($Snapshot.Existed) {
            " The preserved original remains at: $($Snapshot.BackupPath)"
        }
        else {
            ''
        }
        throw (
            'MetaEditor process-tree termination was not verified; ' +
            "the compilation log was not restored.$recovery"
        )
    }

    Restore-OriginalLog -LiteralPath $LiteralPath -Snapshot $Snapshot
}

function Test-CompilerLaunchCleanupVerified {
    param([Parameter(Mandatory = $true)][Exception]$Exception)

    $current = $Exception
    while ($null -ne $current) {
        if ($current.Data.Contains('Mql5Coding.CleanupVerified')) {
            return [bool]$current.Data['Mql5Coding.CleanupVerified']
        }
        $current = $current.InnerException
    }
    return $false
}

function Get-CompilerLockHash {
    param([Parameter(Mandatory = $true)][string]$Namespace)

    $algorithm = [System.Security.Cryptography.SHA256]::Create()
    try {
        return [System.BitConverter]::ToString(
            $algorithm.ComputeHash([System.Text.Encoding]::UTF8.GetBytes($Namespace))
        ).Replace('-', '').Substring(0, 24)
    }
    finally {
        $algorithm.Dispose()
    }
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

    # Detect the logical MQL5 root before canonicalizing a source reached
    # through a junction. The include root and source target are independent.
    if (-not [string]::IsNullOrWhiteSpace($IncludePath)) {
        $includeItem = Get-Item -LiteralPath $IncludePath -ErrorAction Stop
        if (-not $includeItem.PSIsContainer) {
            throw "Include path must be an MQL5 root directory: $IncludePath"
        }
        $resolvedInclude = $includeItem.FullName
    }
    else {
        $logicalDirectoryPath = [System.IO.Path]::GetDirectoryName($resolvedSource)
        while (-not [string]::IsNullOrWhiteSpace($logicalDirectoryPath)) {
            $logicalLeaf = [System.IO.Path]::GetFileName(
                $logicalDirectoryPath.TrimEnd('\', '/')
            )
            if ($logicalLeaf -eq 'MQL5') {
                $resolvedInclude = [System.IO.Path]::GetFullPath($logicalDirectoryPath)
                break
            }
            $logicalParent = [System.IO.Path]::GetDirectoryName(
                $logicalDirectoryPath.TrimEnd('\', '/')
            )
            if ([string]::IsNullOrWhiteSpace($logicalParent) -or
                $logicalParent.Equals(
                    $logicalDirectoryPath,
                    [StringComparison]::OrdinalIgnoreCase
                )) {
                break
            }
            $logicalDirectoryPath = $logicalParent
        }
    }

    $sourceLeaf = [System.IO.Path]::GetFileName($resolvedSource)
    $sourceParentPath = [System.IO.Path]::GetDirectoryName($resolvedSource)
    $sourceParentLease = [Mql5Coding.CompilerProcessJob]::OpenDirectoryIdentityLease(
        $sourceParentPath
    )
    $canonicalSource = Join-Path $sourceParentLease.FinalPath $sourceLeaf
    $sourceReadLease = [Mql5Coding.CompilerProcessJob]::OpenSourceFileIdentityLease(
        $canonicalSource
    )
    $initialSourceIdentity = [string]$sourceReadLease.Identity
    $resolvedSource = [System.IO.Path]::GetFullPath($sourceReadLease.FinalPath)
    $sourceParentPath = [System.IO.Path]::GetDirectoryName($resolvedSource)
    if (-not $sourceParentPath.Equals(
            [System.IO.Path]::GetFullPath($sourceParentLease.FinalPath),
            [StringComparison]::OrdinalIgnoreCase
        )) {
        throw 'Source file resolved outside its pinned canonical parent directory.'
    }

    $resolvedMetaEditor = Resolve-MetaEditorExecutable -RequestedPath $MetaEditorPath
    $artifactPath = [System.IO.Path]::ChangeExtension($resolvedSource, '.ex5')
    $logPath = [System.IO.Path]::ChangeExtension($resolvedSource, '.log')

    $outputLeaf = [System.IO.Path]::GetFileName($logPath).ToUpperInvariant()
    $pathNamespace = (
        $sourceParentLease.FinalPath.TrimEnd('\', '/').ToUpperInvariant() +
        '|' + $outputLeaf
    )
    $identityNamespace = $sourceParentLease.Identity + '|' + $outputLeaf
    $pathHash = Get-CompilerLockHash -Namespace $pathNamespace
    $identityHash = Get-CompilerLockHash -Namespace $identityNamespace

    $pathMutex = [System.Threading.Mutex]::new(
        $false,
        "Global\CodexMqlCompilePath_$pathHash"
    )
    $identityMutex = [System.Threading.Mutex]::new(
        $false,
        "Global\CodexMqlCompile_$identityHash"
    )
    $lockBudget = [TimeSpan]::FromSeconds(
        [Math]::Min(30, $TimeoutSeconds)
    )
    $lockTimer = [Diagnostics.Stopwatch]::StartNew()

    $pathWait = $lockBudget - $lockTimer.Elapsed
    if ($pathWait -lt [TimeSpan]::Zero) {
        $pathWait = [TimeSpan]::Zero
    }
    try {
        $pathMutexHeld = $pathMutex.WaitOne($pathWait)
    }
    catch [System.Threading.AbandonedMutexException] {
        $pathMutexHeld = $true
    }
    if (-not $pathMutexHeld) {
        throw "Another compilation is already using this source file (path lock): $resolvedSource"
    }

    $identityWait = $lockBudget - $lockTimer.Elapsed
    if ($identityWait -lt [TimeSpan]::Zero) {
        $identityWait = [TimeSpan]::Zero
    }
    try {
        $identityMutexHeld = $identityMutex.WaitOne($identityWait)
    }
    catch [System.Threading.AbandonedMutexException] {
        $identityMutexHeld = $true
    }
    if (-not $identityMutexHeld) {
        throw "Another compilation is already using this source file (identity lock): $resolvedSource"
    }

    if ($sourceReadLease.Identity -cne $initialSourceIdentity) {
        throw 'Source file identity changed while compilation locks were being acquired.'
    }

    $artifactProbeLease = $null
    try {
            $artifactProbeLease = [Mql5Coding.CompilerProcessJob]::TryOpenMovableOutputFileIdentityLease(
                $artifactPath
            )
            if ($null -eq $artifactProbeLease) {
                $artifactSnapshot = [pscustomobject]@{
                    Existed = $false
                    BackupPath = $null
                    Identity = $null
                }
                $artifactPrepared = $true
            }
            else {
                $artifactBackupIdentity = [string]$artifactProbeLease.Identity
                $artifactBackupPath = Move-OriginalArtifactAside -LiteralPath $artifactPath
                $artifactPrepared = $true
                $artifactBackupLease = [Mql5Coding.CompilerProcessJob]::TryOpenPinnedOutputFileIdentityLease(
                    $artifactBackupPath
                )
                if ($null -eq $artifactBackupLease -or
                    [string]$artifactBackupLease.Identity -cne $artifactBackupIdentity) {
                    throw 'The original compiler artifact changed while it was moved to its backup path.'
                }
                $artifactSnapshot = Get-ArtifactState `
                    -LiteralPath $artifactBackupPath `
                    -Lease $artifactBackupLease
                $artifactSnapshot | Add-Member -NotePropertyName BackupPath -NotePropertyValue $artifactBackupPath
                $artifactSnapshot | Add-Member -NotePropertyName Identity -NotePropertyValue $artifactBackupIdentity
            }
    }
    finally {
        if ($null -ne $artifactProbeLease) {
            $artifactProbeLease.Dispose()
        }
    }

    $logProbeLease = $null
    try {
        $logProbeLease = [Mql5Coding.CompilerProcessJob]::TryOpenMovableOutputFileIdentityLease(
            $logPath
        )
        if ($null -ne $logProbeLease) {
            $logIdentity = [string]$logProbeLease.Identity
            $logSnapshot = [pscustomobject]@{
                Existed    = $true
                BackupPath = Move-OriginalLogAside -LiteralPath $logPath
                Identity   = $logIdentity
            }
            $logBackupProbe = [Mql5Coding.CompilerProcessJob]::TryOpenPinnedOutputFileIdentityLease(
                $logSnapshot.BackupPath
            )
            if ($null -eq $logBackupProbe) {
                throw 'The original compilation log disappeared while it was moved aside.'
            }
            try {
                if ([string]$logBackupProbe.Identity -cne $logIdentity) {
                    throw 'The original compilation log identity changed while it was moved aside.'
                }
            }
            finally {
                $logBackupProbe.Dispose()
            }
        }
        else {
            $logSnapshot = [pscustomobject]@{
                Existed    = $false
                BackupPath = $null
                Identity   = $null
            }
        }
        $logPrepared = $true
    }
    finally {
        if ($null -ne $logProbeLease) {
            $logProbeLease.Dispose()
        }
    }

    $argumentTokens = New-Object 'System.Collections.Generic.List[string]'
    $argumentTokens.Add("/compile:$resolvedSource")
    $argumentTokens.Add('/log')
    if (-not [string]::IsNullOrWhiteSpace($resolvedInclude)) {
        $argumentTokens.Add("/include:$resolvedInclude")
    }
    if ($SyntaxOnly) {
        $argumentTokens.Add('/s')
    }
    $arguments = @(
        $argumentTokens | ForEach-Object {
            ConvertTo-WindowsCommandLineArgument -Value $_
        }
    ) -join ' '

    Write-Output "MQL5_COMPILE_SOURCE=$resolvedSource"
    Write-Output "MQL5_METAEDITOR=$resolvedMetaEditor"
    Write-Output "MQL5_COMPILE_MODE=$(if ($SyntaxOnly) { 'syntax' } else { 'compile' })"
    if (-not [string]::IsNullOrWhiteSpace($resolvedInclude)) {
        Write-Output "MQL5_INCLUDE_ROOT=$resolvedInclude"
    }

    $compileJobEmpty = $false
    try {
        $compileLaunch = [Mql5Coding.CompilerProcessJob]::Start(
            $resolvedMetaEditor,
            $arguments,
            (Split-Path -Parent $resolvedMetaEditor)
        )
    }
    catch {
        if (Test-CompilerLaunchCleanupVerified -Exception $_.Exception) {
            $compileJobEmpty = $true
        }
        throw
    }
    Write-Output "MQL5_METAEDITOR_PROCESS_ID=$($compileLaunch.ProcessId)"

    $stopwatch = [System.Diagnostics.Stopwatch]::StartNew()
    $summaryMatch = $null
    while ($stopwatch.Elapsed.TotalSeconds -lt $TimeoutSeconds) {
        if ($null -eq $logOutputLease) {
            $logOutputLease = [Mql5Coding.CompilerProcessJob]::TryOpenPinnedOutputFileIdentityLease(
                $logPath
            )
        }
        if ($null -ne $logOutputLease) {
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
        if ($compileLaunch.IsEmpty()) {
            $compileJobEmpty = $true
            break
        }
        Start-Sleep -Milliseconds 100
    }
    $stopwatch.Stop()

    if ($null -eq $summaryMatch -and $compileJobEmpty) {
        if ($null -eq $logOutputLease) {
            $logOutputLease = [Mql5Coding.CompilerProcessJob]::TryOpenPinnedOutputFileIdentityLease(
                $logPath
            )
        }
        try {
            if ($null -eq $logOutputLease) {
                throw 'MetaEditor exited without creating its compilation log.'
            }
            $logText = Read-SharedText -LiteralPath $logPath
        }
        catch {
            throw "MetaEditor exited but its compilation log could not be read: $($_.Exception.Message)"
        }
        $finalEarlyMatches = [regex]::Matches(
            $logText,
            '(?im)^\s*Result:\s*(?<errors>\d+)\s+errors?,\s*(?<warnings>\d+)\s+warnings?'
        )
        if ($finalEarlyMatches.Count -gt 0) {
            $summaryMatch = $finalEarlyMatches[$finalEarlyMatches.Count - 1]
        }
    }

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
        if ($compileJobEmpty) {
            $exitCode = $ExitToolError
            $status = 'tool_error'
            $errorMessage = 'MetaEditor exited without producing a complete Result line.'
        }
        else {
            $cleanupFailed = $false
            try {
                $compileLaunch.TerminateAndWaitForEmpty(5000)
                $compileJobEmpty = $true
            }
            catch {
                $cleanupFailed = $true
                $errorMessage = "MetaEditor timed out and its process could not be terminated: $($_.Exception.Message)"
            }
            if ($null -eq $logOutputLease) {
                $logOutputLease = [Mql5Coding.CompilerProcessJob]::TryOpenPinnedOutputFileIdentityLease(
                    $logPath
                )
            }
            if ($null -ne $logOutputLease) {
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
                    if ($null -eq $artifactOutputLease) {
                        $artifactOutputLease = [Mql5Coding.CompilerProcessJob]::TryOpenPinnedOutputFileIdentityLease(
                            $artifactPath
                        )
                    }
                    if ($null -ne $artifactOutputLease) {
                        $artifactState = Get-ArtifactState `
                            -LiteralPath $artifactPath `
                            -Lease $artifactOutputLease
                        $artifactRefreshed = (
                            $artifactState.Existed -and
                            $artifactState.Length -gt 0
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
                $artifactAccepted = -not $SyntaxOnly
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

    if ($null -ne $logOutputLease) {
        try {
            $logOutputLease.Dispose()
        }
        catch {
            $exitCode = $ExitToolError
            $status = 'tool_error'
            if ([string]::IsNullOrWhiteSpace($errorMessage)) {
                $errorMessage = "Could not release the compilation-log identity lease: $($_.Exception.Message)"
            }
        }
        $logOutputLease = $null
    }

    if ($logPrepared -and $null -ne $logPath -and $null -ne $logSnapshot) {
        try {
            Complete-CompilationLog `
                -LiteralPath $logPath `
                -Snapshot $logSnapshot `
                -ProcessTreeEmpty $compileJobEmpty
        }
        catch {
            $exitCode = $ExitToolError
            $status = 'tool_error'
            $logCompletionError = $_.Exception.Message
            if ([string]::IsNullOrWhiteSpace($errorMessage)) {
                $errorMessage = $logCompletionError
            }
            else {
                $errorMessage = "$errorMessage Log handling error: $logCompletionError"
            }
        }
    }

    if ($artifactPrepared) {
        $artifactOutputIdentity = if ($null -eq $artifactOutputLease) {
            $null
        }
        else {
            [string]$artifactOutputLease.Identity
        }
        if ($null -ne $artifactOutputLease) {
            $artifactOutputLease.Dispose()
            $artifactOutputLease = $null
        }
        if ($null -ne $artifactBackupLease) {
            $artifactBackupLease.Dispose()
            $artifactBackupLease = $null
        }

        try {
            if (-not $compileJobEmpty) {
                $recovery = if ([string]::IsNullOrWhiteSpace($artifactBackupPath)) {
                    ''
                }
                else {
                    " The preserved original remains at: $artifactBackupPath"
                }
                throw "MetaEditor process-tree termination was not verified; compiler artifact paths were not finalized.$recovery"
            }

            if ($artifactAccepted) {
                if (-not [string]::IsNullOrWhiteSpace($artifactBackupPath)) {
                    Remove-CompilerArtifactSafely `
                        -LiteralPath $artifactBackupPath `
                        -ExpectedIdentity $artifactBackupIdentity
                }
            }
            else {
                Remove-CompilerArtifactSafely `
                    -LiteralPath $artifactPath `
                    -ExpectedIdentity $artifactOutputIdentity
                if (-not [string]::IsNullOrWhiteSpace($artifactBackupPath)) {
                    Restore-OriginalArtifact `
                        -LiteralPath $artifactPath `
                        -BackupPath $artifactBackupPath `
                        -BackupIdentity $artifactBackupIdentity
                }
            }
        }
        catch {
            $exitCode = $ExitToolError
            $status = 'tool_error'
            $artifactCompletionError = $_.Exception.Message
            if ([string]::IsNullOrWhiteSpace($errorMessage)) {
                $errorMessage = $artifactCompletionError
            }
            else {
                $errorMessage = "$errorMessage Artifact handling error: $artifactCompletionError"
            }
        }
    }
    else {
        if ($null -ne $artifactOutputLease) {
            $artifactOutputLease.Dispose()
            $artifactOutputLease = $null
        }
        if ($null -ne $artifactBackupLease) {
            $artifactBackupLease.Dispose()
            $artifactBackupLease = $null
        }
    }

    if ($null -ne $sourceReadLease) {
        try {
            $sourceReadLease.Dispose()
        }
        catch {
            $exitCode = $ExitToolError
            $status = 'tool_error'
            if ([string]::IsNullOrWhiteSpace($errorMessage)) {
                $errorMessage = "Could not release the source-file read lease: $($_.Exception.Message)"
            }
        }
        $sourceReadLease = $null
    }

    if ($null -ne $sourceParentLease) {
        try {
            $sourceParentLease.Dispose()
        }
        catch {
            $exitCode = $ExitToolError
            $status = 'tool_error'
            if ([string]::IsNullOrWhiteSpace($errorMessage)) {
                $errorMessage = "Could not release the source-directory identity lease: $($_.Exception.Message)"
            }
        }
        $sourceParentLease = $null
    }

    if ($identityMutexHeld -and $null -ne $identityMutex) {
        try {
            $identityMutex.ReleaseMutex()
        }
        catch {
            $exitCode = $ExitToolError
            $status = 'tool_error'
            $releaseMessage = "Could not release the identity compilation lock: $($_.Exception.Message)"
            if ([string]::IsNullOrWhiteSpace($errorMessage)) {
                $errorMessage = $releaseMessage
            }
            else {
                $errorMessage = "$errorMessage $releaseMessage"
            }
        }
    }
    if ($null -ne $identityMutex) {
        $identityMutex.Dispose()
    }
    if ($pathMutexHeld -and $null -ne $pathMutex) {
        try {
            $pathMutex.ReleaseMutex()
        }
        catch {
            $exitCode = $ExitToolError
            $status = 'tool_error'
            $releaseMessage = "Could not release the path compilation lock: $($_.Exception.Message)"
            if ([string]::IsNullOrWhiteSpace($errorMessage)) {
                $errorMessage = $releaseMessage
            }
            else {
                $errorMessage = "$errorMessage $releaseMessage"
            }
        }
    }
    if ($null -ne $pathMutex) {
        $pathMutex.Dispose()
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
