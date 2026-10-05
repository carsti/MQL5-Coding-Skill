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

    [switch]$WarningsAsErrors,

    [switch]$SuppressLogOutput
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
$includeRootLease = $null
$resolvedMetaEditor = $null
$metaEditorParentLease = $null
$metaEditorReadLease = $null
$logPath = $null
$logSnapshot = $null
$artifactSnapshot = $null
$artifactPrepared = $false
$artifactAccepted = $false
$artifactOutputLease = $null
$artifactOutputMovableLease = $null
$artifactBackupLease = $null
$artifactBackupMovableLease = $null
$artifactBackupPath = $null
$artifactBackupIdentity = $null
$logPrepared = $false
$logOutputLease = $null
$logOutputMovableLease = $null
$logBackupLease = $null
$logBackupMovableLease = $null
$logBackupPath = $null
$pathMutex = $null
$pathMutexHeld = $false
$identityMutex = $null
$identityMutexHeld = $false
$sourceParentLease = $null
$sourceReadLease = $null
$compileLaunch = $null
$compileJobEmpty = $true
$receiptId = [guid]::NewGuid().ToString('N')
$receiptPath = $null
$receiptLogPath = $null
$receiptParentLease = $null
$receiptLogBytes = $null
$receipt = [ordered]@{
    schema_version = 1
    kind = 'mql5_compilation_receipt'
    run_id = $receiptId
    started_utc = [datetime]::UtcNow.ToString('o')
    ended_utc = $null
    status = 'tool_error'
    exit_code = 2
    errors = $null
    warnings = $null
    syntax_only = [bool]$SyntaxOnly
    warnings_as_errors = [bool]$WarningsAsErrors
    include_root = $null
    compiler = $null
    source = $null
    expert = $null
    log = $null
    message = $null
}

function Get-CompilationFileRecord {
    param([Parameter(Mandatory)][string]$Path, [Parameter(Mandatory)]$Lease)
    return [ordered]@{
        path = $Path
        byte_length = [long]$Lease.GetLength()
        sha256 = $Lease.GetSha256().ToLowerInvariant()
    }
}

function Write-CompilationReceipt {
    # Unique CreateNew files never replace an earlier receipt, source, or log.
    # The canonical parent remains leased until both evidence files are closed.
    $logStream = $null
    $jsonStream = $null
    try {
        if ($null -ne $receiptLogBytes) {
            $logStream = [IO.File]::Open($receiptLogPath, [IO.FileMode]::CreateNew,
                [IO.FileAccess]::ReadWrite, [IO.FileShare]::Read)
            $logStream.Write($receiptLogBytes, 0, $receiptLogBytes.Length)
            $logStream.Flush($true)
            $algorithm = [Security.Cryptography.SHA256]::Create()
            try {
                $logStream.Position = 0
                $logHash = ([BitConverter]::ToString($algorithm.ComputeHash($logStream))).Replace('-', '').ToLowerInvariant()
            }
            finally { $algorithm.Dispose() }
            $receipt.log = [ordered]@{
                path = $receiptLogPath
                byte_length = [long]$logStream.Length
                sha256 = $logHash
            }
        }
        $jsonBytes = (New-Object Text.UTF8Encoding($false)).GetBytes(
            ($receipt | ConvertTo-Json -Depth 8) + [Environment]::NewLine
        )
        $pendingPath = $receiptPath + '.pending'
        $jsonStream = [IO.File]::Open($pendingPath, [IO.FileMode]::CreateNew,
            [IO.FileAccess]::Write, [IO.FileShare]::Read)
        $jsonStream.Write($jsonBytes, 0, $jsonBytes.Length)
        $jsonStream.Flush($true)
        $jsonStream.Dispose()
        $jsonStream = $null
        if ($null -ne $logStream) { $logStream.Dispose(); $logStream = $null }
        # Publish the complete file atomically, after all writes/flushes/closes.
        # File.Move refuses an occupied destination rather than overwriting it.
        [IO.File]::Move($pendingPath, $receiptPath)
    }
    finally {
        if ($null -ne $jsonStream) { $jsonStream.Dispose() }
        if ($null -ne $logStream) { $logStream.Dispose() }
    }
}

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

function ConvertTo-WindowsCommandLineArgument {
    param(
        [Parameter(Mandatory = $true)]
        [AllowEmptyString()]
        [string]$Value
    )

    if ($Value.Length -gt 0 -and $Value -notmatch '[\s"]') {
        return $Value
    }

    $backslash = [char]92
    $quote = [char]34
    $builder = New-Object Text.StringBuilder
    [void]$builder.Append($quote)
    $pendingBackslashes = 0
    foreach ($character in $Value.ToCharArray()) {
        if ($character -eq $backslash) {
            $pendingBackslashes++
            continue
        }

        if ($character -eq $quote) {
            [void]$builder.Append(
                $backslash,
                (($pendingBackslashes * 2) + 1)
            )
            [void]$builder.Append($quote)
        }
        else {
            if ($pendingBackslashes -gt 0) {
                [void]$builder.Append($backslash, $pendingBackslashes)
            }
            [void]$builder.Append($character)
        }
        $pendingBackslashes = 0
    }

    if ($pendingBackslashes -gt 0) {
        [void]$builder.Append($backslash, ($pendingBackslashes * 2))
    }
    [void]$builder.Append($quote)
    return $builder.ToString()
}

function ConvertTo-MetaEditorCommandLineArgument {
    param([Parameter(Mandatory = $true)][string]$Value)

    # MetaEditor requires the switch prefix outside the quoted path value.
    # Quoting the entire /compile:path token is ignored by the real compiler.
    if ($Value -match '^(/(?:compile|include):)(.*)$') {
        return $Matches[1] + (ConvertTo-WindowsCommandLineArgument -Value $Matches[2])
    }
    return ConvertTo-WindowsCommandLineArgument -Value $Value
}

function Read-SharedText {
    param(
        [Parameter(Mandatory = $true)][string]$LiteralPath,
        [Parameter(Mandatory = $true)]$Lease
    )

    $expectedIdentity = [string]$Lease.Identity
    if ([string]$Lease.GetCurrentIdentity() -cne $expectedIdentity) {
        throw "Compiler output identity changed before it was read: $LiteralPath"
    }
    $text = [string]$Lease.ReadAllText()
    if ([string]$Lease.GetCurrentIdentity() -cne $expectedIdentity) {
        throw "Compiler output identity changed while it was read: $LiteralPath"
    }
    return $text
}

function Get-ArtifactState {
    param(
        [Parameter(Mandatory = $true)][string]$LiteralPath,
        [Parameter(Mandatory = $true)]$Lease
    )

    $expectedIdentity = [string]$Lease.Identity
    if ([string]$Lease.GetCurrentIdentity() -cne $expectedIdentity) {
        throw "Compiler artifact identity changed before inspection: $LiteralPath"
    }
    $state = [pscustomobject]@{
        Existed = $true
        Length  = [long]$Lease.GetLength()
        Sha256  = [string]$Lease.GetSha256()
    }
    if ([string]$Lease.GetCurrentIdentity() -cne $expectedIdentity) {
        throw "Compiler artifact identity changed during inspection: $LiteralPath"
    }
    return $state
}

function Move-LeasedCompilerOutputAside {
    param(
        [Parameter(Mandatory = $true)][string]$LiteralPath,
        [Parameter(Mandatory = $true)]$Lease,
        [Parameter(Mandatory = $true)][string]$Description
    )

    $directory = [System.IO.Path]::GetDirectoryName($LiteralPath)
    $maximumLeafLength = [System.IO.Path]::GetFileName($LiteralPath).Length
    $backupLeafLength = [Math]::Min(32, $maximumLeafLength)
    $lastError = $null
    for ($attempt = 0; $attempt -lt 100; $attempt++) {
        $candidateLeaf = [guid]::NewGuid().ToString('N').Substring(
            0,
            $backupLeafLength
        )
        $candidate = Join-Path $directory $candidateLeaf
        try {
            $Lease.RenameTo($candidate)
            return $candidate
        }
        catch {
            $lastError = $_.Exception
            $nativeError = $_.Exception
            while ($null -ne $nativeError -and
                -not ($nativeError -is [System.ComponentModel.Win32Exception])) {
                $nativeError = $nativeError.InnerException
            }
            if ($null -eq $nativeError -or
                $nativeError.NativeErrorCode -notin @(80, 183)) {
                throw
            }
        }
    }
    throw "Could not move the original $Description to a unique adjacent backup path: $($lastError.Message)"
}

function Move-OriginalArtifactAside {
    param(
        [Parameter(Mandatory = $true)][string]$LiteralPath,
        [Parameter(Mandatory = $true)]$Lease
    )

    return Move-LeasedCompilerOutputAside -LiteralPath $LiteralPath -Lease $Lease -Description 'compiler artifact'
}

function Move-OriginalLogAside {
    param(
        [Parameter(Mandatory = $true)][string]$LiteralPath,
        [Parameter(Mandatory = $true)]$Lease
    )

    return Move-LeasedCompilerOutputAside -LiteralPath $LiteralPath -Lease $Lease -Description 'compilation log'
}

function Open-FinalCompilerOutputLeases {
    param(
        [Parameter(Mandatory = $true)][string]$LiteralPath,
        [AllowNull()][string]$ExpectedIdentity,
        [Parameter(Mandatory = $true)][string]$Description
    )

    $movable = $null
    $pinned = $null
    try {
        $movable = [Mql5Coding.CompilerProcessJob]::TryOpenMovableOutputFileIdentityLease(
            $LiteralPath
        )
        if ($null -eq $movable) {
            return $null
        }
        if (-not [string]::IsNullOrWhiteSpace($ExpectedIdentity) -and
            [string]$movable.Identity -cne $ExpectedIdentity) {
            throw "The $Description identity changed before finalization: $LiteralPath"
        }

        $pinned = [Mql5Coding.CompilerProcessJob]::TryOpenPinnedOutputFileIdentityLease(
            $LiteralPath
        )
        if ($null -eq $pinned) {
            throw "The $Description disappeared before it could be pinned: $LiteralPath"
        }
        if ([string]$pinned.Identity -cne [string]$movable.Identity) {
            throw "The $Description path changed while finalization leases were acquired: $LiteralPath"
        }

        $result = [pscustomobject]@{
            Movable = $movable
            Pinned  = $pinned
        }
        $movable = $null
        $pinned = $null
        return $result
    }
    finally {
        if ($null -ne $pinned) {
            $pinned.Dispose()
        }
        if ($null -ne $movable) {
            $movable.Dispose()
        }
    }
}

function Complete-LeasedCompilerOutput {
    param(
        [Parameter(Mandatory = $true)][string]$LiteralPath,
        [Parameter(Mandatory = $true)][string]$Description,
        [Parameter(Mandatory = $true)][bool]$ProcessTreeEmpty,
        [Parameter(Mandatory = $true)][bool]$AcceptGenerated,
        [AllowNull()]$OriginalMovableLease,
        [AllowNull()]$OriginalPinnedLease,
        [AllowNull()][string]$OriginalBackupPath,
        [AllowNull()]$GeneratedMovableLease,
        [AllowNull()]$GeneratedPinnedLease
    )

    $recovery = if ([string]::IsNullOrWhiteSpace($OriginalBackupPath)) {
        ''
    }
    else {
        " The preserved original remains at: $OriginalBackupPath"
    }
    if (-not $ProcessTreeEmpty) {
        throw (
            'MetaEditor process-tree termination was not verified; ' +
            "$Description paths were not finalized.$recovery"
        )
    }

    if (($null -eq $OriginalMovableLease) -xor
        ($null -eq $OriginalPinnedLease)) {
        throw "The preserved $Description does not have a complete identity lease pair.$recovery"
    }
    if ($null -ne $OriginalMovableLease) {
        if ([string]$OriginalMovableLease.GetCurrentIdentity() -cne
            [string]$OriginalMovableLease.Identity) {
            throw "The preserved $Description identity changed.$recovery"
        }
        if ($null -ne $OriginalPinnedLease -and
            (
                [string]$OriginalPinnedLease.Identity -cne
                    [string]$OriginalMovableLease.Identity -or
                [string]$OriginalPinnedLease.GetCurrentIdentity() -cne
                    [string]$OriginalMovableLease.Identity
            )) {
            throw "The preserved $Description leases identify different files.$recovery"
        }
    }

    if (($null -eq $GeneratedMovableLease) -xor
        ($null -eq $GeneratedPinnedLease)) {
        throw "The generated $Description does not have a complete finalization lease pair.$recovery"
    }
    if ($null -ne $GeneratedMovableLease) {
        if ([string]$GeneratedMovableLease.GetCurrentIdentity() -cne
            [string]$GeneratedMovableLease.Identity -or
            [string]$GeneratedPinnedLease.GetCurrentIdentity() -cne
            [string]$GeneratedMovableLease.Identity) {
            throw "The generated $Description identity changed during finalization.$recovery"
        }
    }

    if ($AcceptGenerated) {
        if ($null -eq $GeneratedMovableLease) {
            throw "The generated $Description is missing and cannot be accepted.$recovery"
        }
        if ($null -ne $OriginalMovableLease) {
            $OriginalMovableLease.Delete()
        }
        return
    }

    if ($null -ne $GeneratedMovableLease) {
        $GeneratedMovableLease.Delete()
        $GeneratedPinnedLease.Dispose()
        $GeneratedMovableLease.Dispose()
    }
    else {
        $unexpected = $null
        try {
            $unexpected = [Mql5Coding.CompilerProcessJob]::TryOpenMovableOutputFileIdentityLease(
                $LiteralPath
            )
            if ($null -ne $unexpected) {
                throw (
                    "Refusing to remove an untracked file at the $Description path: " +
                    "$LiteralPath$recovery"
                )
            }
        }
        finally {
            if ($null -ne $unexpected) {
                $unexpected.Dispose()
            }
        }
    }

    if ($null -ne $OriginalMovableLease) {
        $originalIdentity = [string]$OriginalMovableLease.Identity
        $OriginalMovableLease.RenameTo($LiteralPath)
        if ([string]$OriginalMovableLease.GetCurrentIdentity() -cne $originalIdentity -or
            [string]$OriginalPinnedLease.GetCurrentIdentity() -cne $originalIdentity) {
            throw "The original $Description was not restored with its preserved identity."
        }
    }
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

    if (-not [string]::IsNullOrWhiteSpace($resolvedInclude)) {
        $includeRootLease = [Mql5Coding.CompilerProcessJob]::OpenDirectoryIdentityLease(
            $resolvedInclude
        )
        $resolvedInclude = [System.IO.Path]::GetFullPath(
            $includeRootLease.FinalPath
        )
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

    $receiptParentLease = [Mql5Coding.CompilerProcessJob]::OpenDirectoryIdentityLease($sourceParentPath)
    $receiptPath = Join-Path $sourceParentPath "mql5-compile-$receiptId.json"
    $receiptLogPath = Join-Path $sourceParentPath "mql5-compile-$receiptId.log"
    $receipt.source = Get-CompilationFileRecord -Path $resolvedSource -Lease $sourceReadLease
    $receipt.include_root = $resolvedInclude

    $resolvedMetaEditor = Resolve-MetaEditorExecutable -RequestedPath $MetaEditorPath
    $metaEditorLeaf = [System.IO.Path]::GetFileName($resolvedMetaEditor)
    $metaEditorParentPath = [System.IO.Path]::GetDirectoryName($resolvedMetaEditor)
    $metaEditorParentLease = [Mql5Coding.CompilerProcessJob]::OpenDirectoryIdentityLease(
        $metaEditorParentPath
    )
    $canonicalMetaEditor = Join-Path $metaEditorParentLease.FinalPath $metaEditorLeaf
    $metaEditorReadLease = [Mql5Coding.CompilerProcessJob]::OpenExecutableFileIdentityLease(
        $canonicalMetaEditor
    )
    $resolvedMetaEditor = [System.IO.Path]::GetFullPath($metaEditorReadLease.FinalPath)
    if (-not [System.IO.Path]::GetDirectoryName($resolvedMetaEditor).Equals(
            [System.IO.Path]::GetFullPath($metaEditorParentLease.FinalPath),
            [StringComparison]::OrdinalIgnoreCase
        )) {
        throw 'MetaEditor resolved outside its pinned canonical parent directory.'
    }

    $receipt.compiler = Get-CompilationFileRecord -Path $resolvedMetaEditor -Lease $metaEditorReadLease
    . (Join-Path $PSScriptRoot 'WindowsExecutableMetadata.ps1')
    $editorVersion = Get-Mql5ExecutableVersionInfo $resolvedMetaEditor
    $receipt.compiler.file_version = $editorVersion.FileVersion
    # MetaEditor stores its advertised build in 5.0.0.<build>.
    $receipt.compiler.build = $editorVersion.FilePrivatePart

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

    if ([string]$sourceReadLease.GetCurrentIdentity() -cne $initialSourceIdentity) {
        throw 'Source file identity changed while compilation locks were being acquired.'
    }

    $artifactProbeLease = $null
    $artifactProbePinnedLease = $null
    try {
        $artifactProbeLease = [Mql5Coding.CompilerProcessJob]::TryOpenMovableOutputFileIdentityLease(
            $artifactPath
        )
        if ($null -eq $artifactProbeLease) {
            $artifactSnapshot = [pscustomobject]@{
                Existed    = $false
                BackupPath = $null
                Identity   = $null
            }
            $artifactPrepared = $true
        }
        else {
            $artifactBackupIdentity = [string]$artifactProbeLease.Identity
            $artifactProbePinnedLease = [Mql5Coding.CompilerProcessJob]::TryOpenPinnedOutputFileIdentityLease(
                $artifactPath
            )
            if ($null -eq $artifactProbePinnedLease -or
                [string]$artifactProbePinnedLease.Identity -cne $artifactBackupIdentity) {
                throw 'The original compiler artifact changed while its preservation leases were acquired.'
            }
            $artifactSnapshot = Get-ArtifactState -LiteralPath $artifactPath -Lease $artifactProbePinnedLease
            $artifactBackupPath = Move-OriginalArtifactAside -LiteralPath $artifactPath -Lease $artifactProbeLease
            $artifactBackupMovableLease = $artifactProbeLease
            $artifactBackupLease = $artifactProbePinnedLease
            $artifactProbeLease = $null
            $artifactProbePinnedLease = $null
            $artifactPrepared = $true

            $artifactSnapshot | Add-Member -NotePropertyName BackupPath -NotePropertyValue $artifactBackupPath
            $artifactSnapshot | Add-Member -NotePropertyName Identity -NotePropertyValue $artifactBackupIdentity
        }
    }
    finally {
        if ($null -ne $artifactProbePinnedLease) {
            $artifactProbePinnedLease.Dispose()
        }
        if ($null -ne $artifactProbeLease) {
            $artifactProbeLease.Dispose()
        }
    }

    $logProbeLease = $null
    $logProbePinnedLease = $null
    try {
        $logProbeLease = [Mql5Coding.CompilerProcessJob]::TryOpenMovableOutputFileIdentityLease(
            $logPath
        )
        if ($null -eq $logProbeLease) {
            $logSnapshot = [pscustomobject]@{
                Existed    = $false
                BackupPath = $null
                Identity   = $null
            }
            $logPrepared = $true
        }
        else {
            $logIdentity = [string]$logProbeLease.Identity
            $logProbePinnedLease = [Mql5Coding.CompilerProcessJob]::TryOpenPinnedOutputFileIdentityLease(
                $logPath
            )
            if ($null -eq $logProbePinnedLease -or
                [string]$logProbePinnedLease.Identity -cne $logIdentity) {
                throw 'The original compilation log changed while its preservation leases were acquired.'
            }
            $logBackupPath = Move-OriginalLogAside -LiteralPath $logPath -Lease $logProbeLease
            $logBackupMovableLease = $logProbeLease
            $logBackupLease = $logProbePinnedLease
            $logProbeLease = $null
            $logProbePinnedLease = $null
            $logPrepared = $true

            $logSnapshot = [pscustomobject]@{
                Existed    = $true
                BackupPath = $logBackupPath
                Identity   = $logIdentity
            }
        }
    }
    finally {
        if ($null -ne $logProbePinnedLease) {
            $logProbePinnedLease.Dispose()
        }
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
            ConvertTo-MetaEditorCommandLineArgument -Value $_
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
    $pollResultSeen = $false
    $timedOut = $false
    while ($stopwatch.Elapsed.TotalSeconds -lt $TimeoutSeconds) {
        $pollLease = $null
        try {
            $pollLease = [Mql5Coding.CompilerProcessJob]::TryOpenObservedOutputFileIdentityLease(
                $logPath
            )
            if ($null -ne $pollLease) {
                $candidateText = Read-SharedText -LiteralPath $logPath -Lease $pollLease
                $matches = [regex]::Matches(
                    $candidateText,
                    '(?im)^\s*Result:\s*(?<errors>\d+)\s+errors?,\s*(?<warnings>\d+)\s+warnings?'
                )
                if ($matches.Count -gt 0) {
                    $pollResultSeen = $true
                    break
                }
            }
        }
        catch {
            # MetaEditor may still deny read sharing or replace the log while writing.
        }
        finally {
            if ($null -ne $pollLease) {
                $pollLease.Dispose()
            }
        }

        if ($compileLaunch.IsEmpty()) {
            $compileJobEmpty = $true
            break
        }
        Start-Sleep -Milliseconds 100
    }
    $stopwatch.Stop()

    if ($pollResultSeen) {
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
    }
    elseif (-not $compileJobEmpty) {
        $cleanupFailed = $false
        try {
            $compileLaunch.TerminateAndWaitForEmpty(5000)
            $compileJobEmpty = $true
        }
        catch {
            $cleanupFailed = $true
            $errorMessage = "MetaEditor timed out and its process could not be terminated: $($_.Exception.Message)"
        }

        if ($cleanupFailed) {
            $exitCode = $ExitToolError
            $status = 'tool_error'
        }
        else {
            $timedOut = $true
            $exitCode = $ExitTimeout
            $status = 'timeout'
            $errorMessage = "MetaEditor did not produce a complete Result line within $TimeoutSeconds seconds."
        }
    }

    $summaryMatch = $null
    if ($compileJobEmpty) {
        $logPair = Open-FinalCompilerOutputLeases -LiteralPath $logPath -ExpectedIdentity $null -Description 'compilation log'
        if ($null -ne $logPair) {
            $logOutputMovableLease = $logPair.Movable
            $logOutputLease = $logPair.Pinned
            $logText = Read-SharedText -LiteralPath $logPath -Lease $logOutputLease
            $receiptLogBytes = $logOutputLease.ReadAllBytes(16777216)
            $finalMatches = [regex]::Matches(
                $logText,
                '(?im)^\s*Result:\s*(?<errors>\d+)\s+errors?,\s*(?<warnings>\d+)\s+warnings?'
            )
            if ($finalMatches.Count -gt 0) {
                $summaryMatch = $finalMatches[$finalMatches.Count - 1]
            }
        }
        elseif (-not $timedOut) {
            throw 'MetaEditor exited without producing a complete Result line because it did not create its compilation log.'
        }

        $artifactPair = Open-FinalCompilerOutputLeases -LiteralPath $artifactPath -ExpectedIdentity $null -Description 'compiler artifact'
        if ($null -ne $artifactPair) {
            $artifactOutputMovableLease = $artifactPair.Movable
            $artifactOutputLease = $artifactPair.Pinned
        }
    }

    if (-not $timedOut) {
        if ($null -eq $summaryMatch) {
            $exitCode = $ExitToolError
            $status = 'tool_error'
            $errorMessage = 'MetaEditor exited without producing a complete Result line.'
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
                if (-not $SyntaxOnly -and $null -ne $artifactOutputLease) {
                    $artifactState = Get-ArtifactState -LiteralPath $artifactPath -Lease $artifactOutputLease
                    $artifactRefreshed = (
                        $artifactState.Existed -and
                        $artifactState.Length -gt 0
                    )
                }

                if (-not $artifactRefreshed) {
                    $exitCode = $ExitToolError
                    $status = 'tool_error'
                    $errorMessage = "MetaEditor reported zero errors but did not create or refresh the expected artifact: $artifactPath"
                }
                else {
                    $artifactAccepted = -not $SyntaxOnly
                    if ($artifactAccepted) {
                        $receipt.expert = Get-CompilationFileRecord -Path $artifactPath -Lease $artifactOutputLease
                    }
                    $exitCode = $ExitSuccess
                    $status = 'success'
                }
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

    if ($logPrepared -and $null -ne $logPath) {
        try {
            Complete-LeasedCompilerOutput -LiteralPath $logPath -Description 'compilation log' -ProcessTreeEmpty $compileJobEmpty -AcceptGenerated $false -OriginalMovableLease $logBackupMovableLease -OriginalPinnedLease $logBackupLease -OriginalBackupPath $logBackupPath -GeneratedMovableLease $logOutputMovableLease -GeneratedPinnedLease $logOutputLease
        }
        catch {
            $exitCode = $ExitToolError
            $status = 'tool_error'
            $artifactAccepted = $false
            $logCompletionError = $_.Exception.Message
            if ([string]::IsNullOrWhiteSpace($errorMessage)) {
                $errorMessage = $logCompletionError
            }
            else {
                $errorMessage = "$errorMessage Log handling error: $logCompletionError"
            }
        }
    }

    if ($artifactPrepared -and $null -ne $artifactPath) {
        try {
            Complete-LeasedCompilerOutput -LiteralPath $artifactPath -Description 'compiler artifact' -ProcessTreeEmpty $compileJobEmpty -AcceptGenerated $artifactAccepted -OriginalMovableLease $artifactBackupMovableLease -OriginalPinnedLease $artifactBackupLease -OriginalBackupPath $artifactBackupPath -GeneratedMovableLease $artifactOutputMovableLease -GeneratedPinnedLease $artifactOutputLease
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

    foreach ($lease in @(
        $logOutputLease,
        $logOutputMovableLease,
        $logBackupLease,
        $logBackupMovableLease,
        $artifactOutputLease,
        $artifactOutputMovableLease,
        $artifactBackupLease,
        $artifactBackupMovableLease
    )) {
        if ($null -ne $lease) {
            try {
                $lease.Dispose()
            }
            catch {
                $exitCode = $ExitToolError
                $status = 'tool_error'
                if ([string]::IsNullOrWhiteSpace($errorMessage)) {
                    $errorMessage = "Could not release a compiler output identity lease: $($_.Exception.Message)"
                }
            }
        }
    }

    if ($null -ne $includeRootLease) {
        try {
            $includeRootLease.Dispose()
        }
        catch {
            $exitCode = $ExitToolError
            $status = 'tool_error'
            if ([string]::IsNullOrWhiteSpace($errorMessage)) {
                $errorMessage = "Could not release the include-root identity lease: $($_.Exception.Message)"
            }
        }
        $includeRootLease = $null
    }

    if ($null -ne $metaEditorReadLease) {
        try {
            $metaEditorReadLease.Dispose()
        }
        catch {
            $exitCode = $ExitToolError
            $status = 'tool_error'
            if ([string]::IsNullOrWhiteSpace($errorMessage)) {
                $errorMessage = "Could not release the MetaEditor executable lease: $($_.Exception.Message)"
            }
        }
        $metaEditorReadLease = $null
    }

    if ($null -ne $metaEditorParentLease) {
        try {
            $metaEditorParentLease.Dispose()
        }
        catch {
            $exitCode = $ExitToolError
            $status = 'tool_error'
            if ([string]::IsNullOrWhiteSpace($errorMessage)) {
                $errorMessage = "Could not release the MetaEditor directory lease: $($_.Exception.Message)"
            }
        }
        $metaEditorParentLease = $null
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

$receiptPublished = $false
try {
    if ($null -ne $receiptParentLease) {
        # Publish only after process, output restoration, and lock cleanup decide
        # the final exit code. A failed attempt never receives a success receipt.
        $receipt.ended_utc = [datetime]::UtcNow.ToString('o')
        $receipt.status = $status
        $receipt.exit_code = $exitCode
        $receipt.errors = $errorCount
        $receipt.warnings = $warningCount
        $receipt.message = $errorMessage
        if ($exitCode -ne $ExitSuccess) { $receipt.expert = $null }
        Write-CompilationReceipt
        $receiptPublished = $true
    }
}
catch {
    $exitCode = $ExitToolError
    $status = 'tool_error'
    $errorMessage = "Compilation receipt publication failed: $($_.Exception.Message)"
}
finally {
    if ($null -ne $receiptParentLease) { $receiptParentLease.Dispose() }
}

if (-not $SuppressLogOutput -and -not [string]::IsNullOrWhiteSpace($logText)) {
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
if ($receiptPublished) {
    Write-Output "MQL5_COMPILE_RECEIPT=$receiptPath"
}
if ($exitCode -eq $ExitSuccess -and -not $SyntaxOnly -and $null -ne $artifactPath) {
    Write-Output "MQL5_COMPILE_ARTIFACT=$artifactPath"
}

exit $exitCode
