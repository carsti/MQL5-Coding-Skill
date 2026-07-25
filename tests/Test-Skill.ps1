#Requires -Version 5.1

[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$repositoryRoot = Split-Path -Parent $PSScriptRoot
$skillRoot = Join-Path $repositoryRoot 'skills\mql5-coding'
$runner = Join-Path $skillRoot 'scripts\Invoke-Mt5TesterSmoke.ps1'
$compiler = Join-Path $skillRoot 'scripts\Compile-Mql5.ps1'
$compilerProcessJobSource = Join-Path $skillRoot 'scripts\CompilerProcessJob.cs'
$fakeTerminalSource = Join-Path $PSScriptRoot 'FakeTerminal.cs'
$fakeMetaEditorSource = Join-Path $PSScriptRoot 'FakeMetaEditor.cs'
$testRoot = Join-Path ([IO.Path]::GetTempPath()) ('mql5-coding-skill-test-' + [guid]::NewGuid().ToString('N'))
$hostExecutable = if ($PSVersionTable.PSEdition -eq 'Core') {
    Join-Path $PSHOME 'pwsh.exe'
}
else {
    Join-Path $PSHOME 'powershell.exe'
}
$csharpCompiler = $null
foreach ($candidate in @(
        (Join-Path $env:WINDIR 'Microsoft.NET\Framework64\v4.0.30319\csc.exe'),
        (Join-Path $env:WINDIR 'Microsoft.NET\Framework\v4.0.30319\csc.exe')
    )) {
    if (Test-Path -LiteralPath $candidate -PathType Leaf) {
        $csharpCompiler = $candidate
        break
    }
}
if ($null -eq $csharpCompiler) {
    throw 'The .NET Framework C# compiler required by the synthetic test fixture was not found.'
}

function Assert-True {
    param(
        [Parameter(Mandatory = $true)]
        [bool]$Condition,
        [Parameter(Mandatory = $true)]
        [string]$Message
    )

    if (-not $Condition) {
        throw $Message
    }
}

function Quote-NativeArgument {
    param([Parameter(Mandatory = $true)][string]$Value)

    if ($Value -notmatch '[\s"]') {
        return $Value
    }
    return '"' + ($Value -replace '(\\*)"', '$1$1\"' -replace '(\\+)$', '$1$1') + '"'
}

function Assert-PowerShellParses {
    param([Parameter(Mandatory = $true)][string]$Path)

    $tokens = $null
    $parseErrors = $null
    [void][Management.Automation.Language.Parser]::ParseFile(
        $Path,
        [ref]$tokens,
        [ref]$parseErrors
    )
    if ($parseErrors.Count -gt 0) {
        $messages = @($parseErrors | ForEach-Object { $_.Message }) -join '; '
        throw "PowerShell parse failed for '$Path': $messages"
    }
}

function Test-PathInChildPowerShell {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Path,
        [Parameter(Mandatory = $true)]
        [ValidateSet('Leaf', 'Container')]
        [string]$PathType
    )

    $escapedPath = $Path.Replace("'", "''")
    $commandText = (
        "if (Test-Path -LiteralPath '$escapedPath' -PathType $PathType) { exit 0 } " +
        'else { exit 1 }'
    )
    $encodedCommand = [Convert]::ToBase64String(
        [Text.Encoding]::Unicode.GetBytes($commandText)
    )
    $startInfo = New-Object Diagnostics.ProcessStartInfo
    $startInfo.FileName = $hostExecutable
    $startInfo.Arguments = (
        '-NoLogo -NoProfile -NonInteractive -ExecutionPolicy Bypass -EncodedCommand ' +
        $encodedCommand
    )
    $startInfo.UseShellExecute = $false
    $startInfo.CreateNoWindow = $true

    $process = New-Object Diagnostics.Process
    $process.StartInfo = $startInfo
    try {
        $null = $process.Start()
        $process.WaitForExit()
        return $process.ExitCode -eq 0
    }
    finally {
        $process.Dispose()
    }
}

function Invoke-RunnerCase {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Name,
        [Parameter(Mandatory = $true)]
        [ValidateSet('PreflightOnly', 'Execute')]
        [string]$Mode,
        [Parameter(Mandatory = $true)]
        [string]$TerminalPath,
        [Parameter(Mandatory = $true)]
        [string]$TerminalDataPath,
        [Parameter(Mandatory = $true)]
        [string]$ExpertPath,
        [Parameter(Mandatory = $true)]
        [string]$PresetPath,
        [Parameter(Mandatory = $true)]
        [string]$ExpertSha256,
        [string]$FakeMode = 'pass',
        [string]$ExpectedLogMarker,
        [string]$FakeMarker = '',
        [int]$TimeoutSeconds = 15
    )

    $outputDirectory = Join-Path (Join-Path $testRoot 'outputs') $Name
    $arguments = New-Object 'System.Collections.Generic.List[string]'
    foreach ($value in @(
            '-NoLogo',
            '-NoProfile',
            '-ExecutionPolicy',
            'Bypass',
            '-File',
            $runner
        )) {
        $arguments.Add((Quote-NativeArgument -Value ([string]$value)))
    }
    $arguments.Add("-$Mode")
    if ($Mode -eq 'Execute') {
        $arguments.Add('-AcknowledgeSavedAccountRisk')
    }
    foreach ($pair in @(
            @('ExpertPath', $ExpertPath),
            @('ExpectedExpertSha256', $ExpertSha256),
            @('SetPath', $PresetPath),
            @('TerminalPath', $TerminalPath),
            @('TerminalDataPath', $TerminalDataPath),
            @('Symbol', 'SYNTH'),
            @('Period', 'H1'),
            @('FromDate', '2024.01.01'),
            @('ToDate', '2024.01.02'),
            @('Model', '0'),
            @('Deposit', '10000'),
            @('Currency', 'USD'),
            @('Leverage', '100'),
            @('ExecutionMode', '0'),
            @('TimeoutSeconds', [string]$TimeoutSeconds),
            @('OutputDirectory', $outputDirectory)
        )) {
        $arguments.Add('-' + [string]$pair[0])
        $arguments.Add((Quote-NativeArgument -Value ([string]$pair[1])))
    }
    if (-not [string]::IsNullOrWhiteSpace($ExpectedLogMarker)) {
        $arguments.Add('-ExpectedLogMarker')
        $arguments.Add((Quote-NativeArgument -Value $ExpectedLogMarker))
    }

    $startInfo = New-Object Diagnostics.ProcessStartInfo
    $startInfo.FileName = $hostExecutable
    $startInfo.Arguments = $arguments -join ' '
    $startInfo.UseShellExecute = $false
    $startInfo.CreateNoWindow = $true
    $startInfo.RedirectStandardOutput = $true
    $startInfo.RedirectStandardError = $true
    $startInfo.EnvironmentVariables['FAKE_MT5_MODE'] = $FakeMode
    $startInfo.EnvironmentVariables['FAKE_MT5_MARKER'] = $FakeMarker

    $process = New-Object Diagnostics.Process
    $process.StartInfo = $startInfo
    try {
        $null = $process.Start()
        $standardOutput = $process.StandardOutput.ReadToEnd()
        $standardError = $process.StandardError.ReadToEnd()
        $process.WaitForExit()
        $exitCode = $process.ExitCode
    }
    finally {
        $process.Dispose()
    }

    $resultPath = Join-Path $outputDirectory 'smoke-result.json'
    $result = if (Test-Path -LiteralPath $resultPath -PathType Leaf) {
        Get-Content -LiteralPath $resultPath -Raw | ConvertFrom-Json
    }
    else {
        $null
    }

    return [pscustomobject]@{
        Name = $Name
        ExitCode = $exitCode
        OutputDirectory = $outputDirectory
        StandardOutput = $standardOutput
        StandardError = $standardError
        Result = $result
    }
}

function Invoke-CompilerCase {
    param(
        [Parameter(Mandatory = $true)]
        [string]$SourcePath,
        [Parameter(Mandatory = $true)]
        [string]$MetaEditorPath,
        [Parameter(Mandatory = $true)]
        [string]$FakeMode,
        [string]$ChildPidPath,
        [string]$IncludePath,
        [string]$ArgumentsPath,
        [int]$TimeoutSeconds = 5,
        [switch]$SyntaxOnly,
        [switch]$WarningsAsErrors
    )

    $arguments = New-Object 'System.Collections.Generic.List[string]'
    foreach ($value in @(
            '-NoLogo',
            '-NoProfile',
            '-ExecutionPolicy',
            'Bypass',
            '-File',
            $compiler,
            '-SourcePath',
            $SourcePath,
            '-MetaEditorPath',
            $MetaEditorPath,
            '-TimeoutSeconds',
            [string]$TimeoutSeconds
        )) {
        $arguments.Add((Quote-NativeArgument -Value ([string]$value)))
    }
    if (-not [string]::IsNullOrWhiteSpace($IncludePath)) {
        $arguments.Add('-IncludePath')
        $arguments.Add((Quote-NativeArgument -Value $IncludePath))
    }
    if ($SyntaxOnly) {
        $arguments.Add('-SyntaxOnly')
    }
    if ($WarningsAsErrors) {
        $arguments.Add('-WarningsAsErrors')
    }

    $startInfo = New-Object Diagnostics.ProcessStartInfo
    $startInfo.FileName = $hostExecutable
    $startInfo.Arguments = $arguments -join ' '
    $startInfo.UseShellExecute = $false
    $startInfo.CreateNoWindow = $true
    $startInfo.RedirectStandardOutput = $true
    $startInfo.RedirectStandardError = $true
    $startInfo.EnvironmentVariables['FAKE_METAEDITOR_MODE'] = $FakeMode
    if (-not [string]::IsNullOrWhiteSpace($ChildPidPath)) {
        $startInfo.EnvironmentVariables['FAKE_METAEDITOR_CHILD_PID_PATH'] = $ChildPidPath
    }
    if (-not [string]::IsNullOrWhiteSpace($ArgumentsPath)) {
        $startInfo.EnvironmentVariables['FAKE_METAEDITOR_ARGS_PATH'] = $ArgumentsPath
    }

    $process = New-Object Diagnostics.Process
    $process.StartInfo = $startInfo
    try {
        $null = $process.Start()
        $standardOutput = $process.StandardOutput.ReadToEnd()
        $standardError = $process.StandardError.ReadToEnd()
        $process.WaitForExit()
        $exitCode = $process.ExitCode
    }
    finally {
        $process.Dispose()
    }

    return [pscustomobject]@{
        ExitCode = $exitCode
        StandardOutput = $standardOutput
        StandardError = $standardError
    }
}

foreach ($requiredFile in @(
        $runner,
        $compiler,
        $compilerProcessJobSource,
        $fakeTerminalSource,
        $fakeMetaEditorSource
    )) {
    Assert-True -Condition (Test-Path -LiteralPath $requiredFile -PathType Leaf) `
        -Message "Required file is missing: $requiredFile"
}

Assert-PowerShellParses -Path $runner
Assert-PowerShellParses -Path $compiler
if (-not ('Mql5Coding.CompilerProcessJob' -as [type])) {
    Add-Type -Path $compilerProcessJobSource
}
if (-not ('Mql5Coding.JobProcessLaunch' -as [type])) {
    $runnerTextForNativeType = Get-Content -LiteralPath $runner -Raw
    $runnerTypeMatch = [regex]::Match(
        $runnerTextForNativeType,
        "(?s)Add-Type\s+-TypeDefinition\s+@'\r?\n(?<source>.*?)\r?\n'@"
    )
    Assert-True -Condition $runnerTypeMatch.Success `
        -Message 'The tester native helper source could not be extracted for lease tests.'
    Add-Type -TypeDefinition $runnerTypeMatch.Groups['source'].Value
}
if (-not ('Mql5Coding.RawDosDeviceProbe' -as [type])) {
    Add-Type -TypeDefinition @'
using System;
using System.ComponentModel;
using System.Runtime.InteropServices;
using System.Text;

namespace Mql5Coding
{
    public static class RawDosDeviceProbe
    {
        private const uint RawTarget = 0x00000001;
        private const uint RemoveDefinition = 0x00000002;
        private const uint ExactMatchOnRemove = 0x00000004;
        private const uint NoBroadcastSystem = 0x00000008;

        [DllImport(
            "kernel32.dll",
            CharSet = CharSet.Unicode,
            SetLastError = true,
            EntryPoint = "QueryDosDeviceW")]
        private static extern uint QueryDosDevice(
            string deviceName,
            StringBuilder targetPath,
            uint maximumCharacters);

        [DllImport(
            "kernel32.dll",
            CharSet = CharSet.Unicode,
            SetLastError = true,
            EntryPoint = "DefineDosDeviceW")]
        [return: MarshalAs(UnmanagedType.Bool)]
        private static extern bool DefineDosDevice(
            uint flags,
            string deviceName,
            string targetPath);

        public static bool IsDefined(string deviceName)
        {
            StringBuilder target = new StringBuilder(32768);
            uint length = QueryDosDevice(
                deviceName,
                target,
                unchecked((uint)target.Capacity));
            if (length != 0)
                return true;
            int error = Marshal.GetLastWin32Error();
            if (error == 2 || error == 3)
                return false;
            throw new Win32Exception(
                error,
                "QueryDosDevice failed for " + deviceName + ".");
        }

        public static string Query(string deviceName)
        {
            StringBuilder target = new StringBuilder(32768);
            uint length = QueryDosDevice(
                deviceName,
                target,
                unchecked((uint)target.Capacity));
            if (length == 0)
                throw new Win32Exception(
                    Marshal.GetLastWin32Error(),
                    "QueryDosDevice failed for " + deviceName + ".");
            return target.ToString();
        }

        public static void Create(string deviceName, string rawTarget)
        {
            if (!DefineDosDevice(
                    RawTarget | NoBroadcastSystem,
                    deviceName,
                    rawTarget))
                throw new Win32Exception(
                    Marshal.GetLastWin32Error(),
                    "DefineDosDevice create failed for " + deviceName + ".");
        }

        public static void Remove(string deviceName, string rawTarget)
        {
            if (!DefineDosDevice(
                    RawTarget | RemoveDefinition | ExactMatchOnRemove |
                        NoBroadcastSystem,
                    deviceName,
                    rawTarget))
                throw new Win32Exception(
                    Marshal.GetLastWin32Error(),
                    "DefineDosDevice removal failed for " + deviceName + ".");
        }
    }
}
'@
}


$skillText = Get-Content -LiteralPath (Join-Path $skillRoot 'SKILL.md') -Raw
$referenceText = Get-Content -LiteralPath (Join-Path $skillRoot 'references\strategy-tester.md') -Raw
$compilerText = Get-Content -LiteralPath $compiler -Raw
$compilerProcessJobText = Get-Content -LiteralPath $compilerProcessJobSource -Raw
$runnerText = Get-Content -LiteralPath $runner -Raw
$runnerTokens = $null
$runnerParseErrors = $null
$runnerAst = [Management.Automation.Language.Parser]::ParseFile(
    $runner,
    [ref]$runnerTokens,
    [ref]$runnerParseErrors
)
$protectJournalNode = $runnerAst.Find(
    {
        param($node)
        return (
            $node -is [Management.Automation.Language.FunctionDefinitionAst] -and
            $node.Name -eq 'Protect-JournalLine'
        )
    },
    $true
)
$selectEvidenceNode = $runnerAst.Find(
    {
        param($node)
        return (
            $node -is [Management.Automation.Language.FunctionDefinitionAst] -and
            $node.Name -eq 'Select-JournalEvidence'
        )
    },
    $true
)
Assert-True -Condition ($null -ne $protectJournalNode -and $null -ne $selectEvidenceNode) `
    -Message 'Journal redaction functions were not found for regression testing.'
$directoryMutationGuardNode = $runnerAst.Find(
    {
        param($node)
        return (
            $node -is [Management.Automation.Language.FunctionDefinitionAst] -and
            $node.Name -eq 'Open-DirectoryMutationGuard'
        )
    },
    $true
)
Assert-True -Condition ($null -ne $directoryMutationGuardNode) `
    -Message 'The directory mutation-guard function was not found for regression testing.'
$absolutePathNode = $runnerAst.Find(
    {
        param($node)
        return (
            $node -is [Management.Automation.Language.FunctionDefinitionAst] -and
            $node.Name -eq 'Test-IsAbsoluteLocalDrivePath'
        )
    },
    $true
)
Assert-True -Condition ($null -ne $absolutePathNode) `
    -Message 'The absolute local-drive path predicate was not found.'
$absolutePathProbe = & {
    param([Parameter(Mandatory = $true)][string]$DefinitionText)
    . ([scriptblock]::Create($DefinitionText))
    $valid = @('C:\absolute\path', 'z:/absolute/path')
    $invalid = @('C:relative', 'C:', '\root-relative', '\\server\share', 'relative')
    return [pscustomobject]@{
        valid_count = @($valid | Where-Object {
                Test-IsAbsoluteLocalDrivePath -Path $_
            }).Count
        invalid_accepted = @($invalid | Where-Object {
                Test-IsAbsoluteLocalDrivePath -Path $_
            }).Count
    }
} $absolutePathNode.Extent.Text
Assert-True -Condition (
    $absolutePathProbe.valid_count -eq 2 -and
    $absolutePathProbe.invalid_accepted -eq 0 -and
    $runnerText -notmatch '\[IO\.Path\]::IsPathRooted'
) -Message 'Drive-relative, root-relative, or UNC input passed the absolute-path contract.'

$normalizeDirectoryNode = $runnerAst.Find(
    {
        param($node)
        return (
            $node -is [Management.Automation.Language.FunctionDefinitionAst] -and
            $node.Name -eq 'ConvertTo-NormalizedDirectoryPath'
        )
    },
    $true
)
Assert-True -Condition ($null -ne $normalizeDirectoryNode) -Message 'The directory-path normalization function was not found.'
$normalizationProbe = & {
    param([Parameter(Mandatory = $true)][string]$DefinitionText)
    . ([scriptblock]::Create($DefinitionText))
    $probeRoot = [IO.Path]::GetPathRoot(
        [IO.Path]::GetFullPath((Join-Path ([IO.Path]::GetTempPath()) 'mql5-normalization-probe'))
    )
    $probeNested = [IO.Path]::GetFullPath((Join-Path $probeRoot 'alpha\beta'))
    return [pscustomobject]@{
        root = ConvertTo-NormalizedDirectoryPath -Path $probeRoot
        expected_root = $probeRoot
        nested = ConvertTo-NormalizedDirectoryPath -Path ($probeNested + '\')
        expected_nested = $probeNested
    }
} $normalizeDirectoryNode.Extent.Text
Assert-True -Condition (
    $normalizationProbe.root -ceq $normalizationProbe.expected_root -and
    $normalizationProbe.nested -ceq $normalizationProbe.expected_nested
) -Message 'Directory normalization did not preserve a drive root or trim a non-root trailing separator.'

foreach ($functionName in @(
        'Resolve-ExistingFile',
        'Open-NonReparseDirectoryChain',
        'Open-NonReparseFileLeaf'
    )) {
    $pathFunctionNode = $runnerAst.Find(
        {
            param($node)
            return (
                $node -is [Management.Automation.Language.FunctionDefinitionAst] -and
                $node.Name -eq $functionName
            )
        },
        $true
    )
    Assert-True -Condition ($null -ne $pathFunctionNode) `
        -Message "Path-integrity function was not found: $functionName"
    Assert-True -Condition (
        $pathFunctionNode.Extent.Text -notmatch
            '(?i)\b(?:Test-Path|Resolve-Path|Get-Item|Get-ChildItem)\b'
    ) -Message "$functionName performs filesystem probing before its no-follow lease."
}
$newTextArtifactNode = $runnerAst.Find(
    {
        param($node)
        return (
            $node -is [Management.Automation.Language.FunctionDefinitionAst] -and
            $node.Name -eq 'Open-NewTextArtifactReadLock'
        )
    },
    $true
)
Assert-True -Condition ($null -ne $newTextArtifactNode) -Message 'The retained new-text artifact helper was not found.'
$newTextArtifactText = $newTextArtifactNode.Extent.Text
$newTextCreateIndex = $newTextArtifactText.IndexOf(
    'CreatePinnedOutputFileStream(',
    [StringComparison]::Ordinal
)
$newTextLeafLeaseIndex = $newTextArtifactText.IndexOf(
    '$lease = Open-NonReparseFileLeaf',
    [StringComparison]::Ordinal
)
$newTextCreationIdentityIndex = $newTextArtifactText.IndexOf(
    '$creationStream.SafeFileHandle',
    [StringComparison]::Ordinal
)
$newTextExpectedHashIndex = $newTextArtifactText.IndexOf(
    '$expectedHash = Get-StreamSha256 -Stream $creationStream',
    [StringComparison]::Ordinal
)
$newTextRetainedStreamIndex = $newTextArtifactText.IndexOf(
    'stream = $creationStream',
    [StringComparison]::Ordinal
)
$newTextOwnershipTransferIndex = $newTextArtifactText.LastIndexOf(
    '$creationStream = $null',
    [StringComparison]::Ordinal
)
$newTextCreationCloseIndex = $newTextArtifactText.IndexOf(
    '$creationStream.Dispose()',
    [StringComparison]::Ordinal
)
Assert-True -Condition (
    $newTextCreateIndex -ge 0 -and
    $newTextLeafLeaseIndex -gt $newTextCreateIndex -and
    $newTextCreationIdentityIndex -gt $newTextLeafLeaseIndex -and
    $newTextExpectedHashIndex -gt $newTextCreationIdentityIndex -and
    $newTextRetainedStreamIndex -gt $newTextExpectedHashIndex -and
    $newTextOwnershipTransferIndex -gt $newTextRetainedStreamIndex -and
    $newTextCreationCloseIndex -gt $newTextOwnershipTransferIndex -and
    $newTextArtifactText -notmatch '\$readStream\s*='
) -Message 'A generated text artifact is not retained through its exact no-follow creation handle and leaf lease.'

$copyNewNode = $runnerAst.Find(
    {
        param($node)
        return (
            $node -is [Management.Automation.Language.FunctionDefinitionAst] -and
            $node.Name -eq 'Copy-NewHashBoundFile'
        )
    },
    $true
)
Assert-True -Condition ($null -ne $copyNewNode) -Message 'The hash-bound copy helper was not found.'
$copyNewText = $copyNewNode.Extent.Text
Assert-True -Condition (
    $copyNewText -match '\[IO\.FileAccess\]::ReadWrite' -and
    $copyNewText -match 'Get-StreamSha256 -Stream \$input' -and
    $copyNewText -match 'Get-StreamSha256 -Stream \$output' -and
    $copyNewText -notmatch '\b(?:Get-FileSha256|Get-Item)\b'
) -Message 'A new copied artifact is not hashed through its still-open source and creation handles.'

$verifiedOutputCopyNode = $runnerAst.Find(
    {
        param($node)
        return (
            $node -is [Management.Automation.Language.FunctionDefinitionAst] -and
            $node.Name -eq 'Copy-NewVerifiedOutputArtifact'
        )
    },
    $true
)
Assert-True -Condition ($null -ne $verifiedOutputCopyNode) -Message 'The exact-handle report publication helper was not found.'
$verifiedOutputCopyText = $verifiedOutputCopyNode.Extent.Text
Assert-True -Condition (
    $verifiedOutputCopyText -match 'GetFileIdentity\(\$input\.SafeFileHandle\)' -and
    $verifiedOutputCopyText -match '\$SourceLease\.Identity' -and
    $verifiedOutputCopyText -match 'CreatePinnedOutputFileStream' -and
    $verifiedOutputCopyText -match 'Get-StreamSha256 -Stream \$input' -and
    $verifiedOutputCopyText -match 'Get-StreamSha256 -Stream \$output' -and
    $verifiedOutputCopyText -match 'stream = \$output' -and
    $verifiedOutputCopyText -notmatch '\b(?:Get-FileSha256|Get-Item)\b'
) -Message 'Generated reports are not copied and hashed through exact retained source and destination handles.'
Assert-True -Condition (
    ([regex]::Matches($runnerText, 'Open-NewTextArtifactReadLock')).Count -ge 3 -and
    $runnerText -notmatch 'Write-NewTextFile -Text \$configContent' -and
    $runnerText -notmatch '\[IO\.File\]::Copy\(' -and
    $runnerText -match 'Copy-NewVerifiedOutputArtifact'
) -Message 'Owner, canonical-config, or copied-report creation bypasses the retained exact-handle integrity path.'

$processIdentityNode = $runnerAst.Find(
    {
        param($node)
        return (
            $node -is [Management.Automation.Language.FunctionDefinitionAst] -and
            $node.Name -eq 'Get-FileIdentityFromPath'
        )
    },
    $true
)
Assert-True -Condition (
    $null -ne $processIdentityNode -and
    $processIdentityNode.Extent.Text -match 'Open-NonReparseFileLeaf' -and
    $processIdentityNode.Extent.Text -notmatch '\[IO\.File\]::Open'
) -Message 'Process-image identity can still open an unvalidated executable pathname.'
$nativeProcessImageNode = $runnerAst.Find(
    {
        param($node)
        return (
            $node -is [Management.Automation.Language.FunctionDefinitionAst] -and
            $node.Name -eq 'Get-NativeProcessImageObservation'
        )
    },
    $true
)
Assert-True -Condition (
    $null -ne $nativeProcessImageNode -and
    $nativeProcessImageNode.Extent.Text -match
        'TryGetProcessImagePathOnFixedVolume' -and
    $nativeProcessImageNode.Extent.Text -match 'Get-FileIdentityFromPath' -and
    $runnerText -match 'ProcessQueryLimitedInformation' -and
    $runnerText -match 'ProcessNameNative'
) -Message 'Native process-image fallback or its no-follow identity validation is missing.'
$processMatcherNode = $runnerAst.Find(
    {
        param($node)
        return (
            $node -is [Management.Automation.Language.FunctionDefinitionAst] -and
            $node.Name -eq 'Get-MatchingTerminalProcesses'
        )
    },
    $true
)
Assert-True -Condition (
    $null -ne $processMatcherNode -and
    $processMatcherNode.Extent.Text -notmatch '(?i)\$matches\b'
) -Message 'Process matching collides with PowerShell automatic $Matches state.'
Assert-True -Condition (
    $runnerText -notmatch 'function Get-StagingIntegrityFailures' -and
    $runnerText -match 'TryOpenFileLeafLease' -and
    $runnerText -match 'TryCreateDirectory'
) -Message 'Safe optional-file or exclusive-directory primitives are missing.'
Assert-True -Condition (
    $runnerText -match 'CreateMutableOutputFileLease' -and
    $runnerText -match 'CreatePinnedOutputFileStream' -and
    $runnerText -match 'ReplaceReport=1' -and
    $runnerText -notmatch '\[IO\.File\]::Copy'
) -Message 'Generated report reservation or no-follow output publication is missing.'
$mutableOutputMethod = [regex]::Match(
    [string]$runnerTypeMatch.Groups['source'].Value,
    '(?s)public static PathEntryLease CreateMutableOutputFileLease\(string path\).*?(?=public static FileStream CreatePinnedOutputFileStream)'
)
Assert-True -Condition (
    $mutableOutputMethod.Success -and
    $mutableOutputMethod.Value -match '(?s)OpenPathHandle\(.*?GenericRead,.*?ShareReadWrite,.*?CreateNew,' -and
    $mutableOutputMethod.Value -match 'new PathEntryLease\(\s*handle,' -and
    $mutableOutputMethod.Value -notmatch 'OpenExisting' -and
    $mutableOutputMethod.Value -notmatch 'OpenPathHandle\(\s*path,\s*0,'
) -Message 'Mutable report reservation does not retain its exact no-follow creation handle.'
$reportReservationIndex = $runnerText.LastIndexOf(
    '$null = Open-NewMutableOutputFileReservation',
    [StringComparison]::Ordinal
)
$testerLaunchIndex = $runnerText.LastIndexOf(
    '$jobLaunch = [Mql5Coding.JobProcessLaunch]::CreateSuspended(',
    [StringComparison]::Ordinal
)
Assert-True -Condition (
    $reportReservationIndex -ge 0 -and
    $testerLaunchIndex -gt $reportReservationIndex
) -Message 'Generated report identities are not reserved before terminal launch.'
$bindingRootLeaseIndex = $runnerText.IndexOf(
    'Open-NonReparseDirectoryChain -Path $terminalDataRoot',
    [StringComparison]::Ordinal
)
$bindingEnumerationIndex = $runnerText.IndexOf(
    'Get-ChildItem -LiteralPath $terminalDataRoot -Directory',
    [StringComparison]::Ordinal
)
Assert-True -Condition (
    $bindingRootLeaseIndex -ge 0 -and
    $bindingEnumerationIndex -gt $bindingRootLeaseIndex
) -Message 'Terminal discovery enumerates its data root before leasing it.'
$sourceLeaseIndex = $compilerText.IndexOf(
    '$sourceReadLease = [Mql5Coding.CompilerProcessJob]::OpenSourceFileIdentityLease',
    [StringComparison]::Ordinal
)
$sourceIdentityIndex = $compilerText.IndexOf(
    '$initialSourceIdentity = [string]$sourceReadLease.Identity',
    [StringComparison]::Ordinal
)
Assert-True -Condition (
    $sourceLeaseIndex -ge 0 -and
    $sourceIdentityIndex -gt $sourceLeaseIndex -and
    $compilerText -notmatch '(?s)\$canonicalSource = .*?Test-Path.*?\$sourceReadLease'
) -Message 'Compiler source identity is still read before the no-follow leaf lease.'
$metaEditorLeaseIndex = $compilerText.IndexOf(
    '$metaEditorReadLease = [Mql5Coding.CompilerProcessJob]::OpenExecutableFileIdentityLease',
    [StringComparison]::Ordinal
)
$nativeCompilerStartIndex = $compilerText.IndexOf(
    '$compileLaunch = [Mql5Coding.CompilerProcessJob]::Start(',
    [StringComparison]::Ordinal
)
Assert-True -Condition (
    $compilerProcessJobText -match 'OpenExecutableFileIdentityLease' -and
    $metaEditorLeaseIndex -ge 0 -and
    $nativeCompilerStartIndex -gt $metaEditorLeaseIndex
) -Message 'MetaEditor is not pinned by a no-follow executable lease before process creation.'
Assert-True -Condition (
    $compilerProcessJobText -match 'TryOpenObservedOutputFileIdentityLease' -and
    $compilerProcessJobText -match 'TryOpenMovableOutputFileIdentityLease' -and
    $compilerProcessJobText -match 'TryOpenPinnedOutputFileIdentityLease' -and
    $compilerProcessJobText -match 'SetFileInformationByHandle' -and
    $compilerProcessJobText -match 'public void RenameTo' -and
    $compilerProcessJobText -match 'public void Delete' -and
    $compilerText -notmatch 'Test-Path -LiteralPath \$artifactPath' -and
    $compilerText -notmatch '\[System\.IO\.File\]::(?:Move|Delete)'
) -Message 'Compiler outputs are not protected by no-follow, handle-bound lifecycle operations.'
$resultWriteIndex = $runnerText.LastIndexOf(
    'Write-JsonFile -Value $result -Path $resultPath',
    [StringComparison]::Ordinal
)
$outputLeaseReverifyIndex = $runnerText.LastIndexOf(
    '$outputDirectoryLease.VerifyStillNonReparseDirectory()',
    [StringComparison]::Ordinal
)
$mutationGuardReleaseIndex = $runnerText.LastIndexOf(
    '$directoryMutationGuards[$index].stream.Dispose()',
    [StringComparison]::Ordinal
)
$outputClaimReleaseIndex = $runnerText.LastIndexOf(
    '$outputClaim.stream.Dispose()',
    [StringComparison]::Ordinal
)
$stagingPreservationProbeIndex = $runnerText.LastIndexOf(
    'Try-OpenNonReparseFileLeaf `',
    [StringComparison]::Ordinal
)
Assert-True -Condition (
    $resultWriteIndex -ge 0 -and
    $outputLeaseReverifyIndex -ge 0 -and
    $outputLeaseReverifyIndex -lt $resultWriteIndex
) -Message 'The output-directory lease is not reverified immediately before result creation.'
Assert-True -Condition (
    $mutationGuardReleaseIndex -gt $resultWriteIndex -and
    $mutationGuardReleaseIndex -gt $stagingPreservationProbeIndex
) -Message 'Directory mutation guards are released before pathname work is complete.'
Assert-True -Condition ($outputClaimReleaseIndex -gt $resultWriteIndex) `
    -Message 'The output-directory claim is released before the result is created.'
$redactionProbe = & {
    param($ProtectDefinition, $SelectDefinition)
    . ([scriptblock]::Create($ProtectDefinition))
    . ([scriptblock]::Create($SelectDefinition))

    $positive = @(
        'ERROR OPENAI_API_KEY=sk-openai-secret',
        'ERROR AZURE_CLIENT_SECRET:azure-secret',
        'ERROR DB_PASSWORD=db-secret',
        'ERROR HTTP_AUTHORIZATION=Basic authorization-secret',
        'ERROR --refresh-token cli-token',
        'ERROR service.api-key: dotted-secret',
        'ERROR password hunter2',
        'ERROR password is hunter2',
        'ERROR "api key": "sk-secret"',
        'ERROR api  key: sk-double-space',
        "ERROR api`tkey=sk-tab",
        'ERROR DB_PASSWORD=multi word secret',
        'ERROR client secret client-secret-value',
        'ERROR password invalid-secret',
        'ERROR password rejected-P@ssw0rd',
        'ERROR client secret missing-value',
        'ERROR token token-value',
        'ERROR secret secret-value',
        'ERROR auth auth-value',
        'ERROR authorization Basic dXNlcjpwYXNz',
        'ERROR password="quoted\"leaked-tail"',
        'ERROR -password:colon-password',
        'ERROR --token:colon-token',
        'ERROR --authorization:Basic colon-authorization',
        'ERROR {\"password\":\"json-password\"}',
        'ERROR {\"token\":\"json-token\"}',
        'ERROR {\"apiKey\":\"json-api-key\"}',
        'ERROR dbPassword=camel-password',
        'ERROR clientSecret=camel-client-secret',
        'ERROR authToken=camel-auth-token',
        'ERROR oauthToken=camel-oauth-token',
        'ERROR authorizationHeader: Basic header-secret',
        'ERROR AUTHORIZATION_HEADER: Basic snake-header-secret',
        'ERROR AWS_SECRET_ACCESS_KEY=aws-secret-access-key',
        'ERROR SECRET_KEY=framework-secret-key',
        'ERROR secretAccessKey=camel-secret-access-key',
        'ERROR password_confirmation=confirmation-secret',
        'ERROR tokenValue=camel-token-value',
        'ERROR {\"password_confirmation\":\"json-confirmation-secret\"}',
        'ERROR {\"tokenValue\":\"json-token-value\"}'
    )
    $negative = @(
        'ERROR token refresh failed',
        'ERROR authorization denied',
        'ERROR password authentication failed',
        'ERROR client secret missing',
        'ERROR api key not configured',
        'ERROR password is not configured',
        'ERROR api key is not configured',
        'ERROR auth failed',
        'ERROR secret missing',
        'ERROR passwordless mode active',
        'ERROR tokenizer=value',
        'ERROR authentication failed'
    )
    return [pscustomobject]@{
        positive = @($positive | ForEach-Object {
                Protect-JournalLine -Line $_
            })
        negative = @($negative | ForEach-Object {
                Protect-JournalLine -Line $_
            })
        expected_negative = $negative
        selected = @(
            Select-JournalEvidence `
                -Text (
                    "ERROR A OPENAI_API_KEY=selected-secret`r`n" +
                    "ERROR B password selected-password`r`n" +
                    'ERROR C "api key": "selected-api-key"' + "`r`n" +
                    "ERROR D api  key: selected-double-space`r`n" +
                    'ERROR E password selected multi word' + "`r`n" +
                    'OK'
                ) `
                -Patterns @('(?i)error')
        )
    }
} $protectJournalNode.Extent.Text $selectEvidenceNode.Extent.Text
foreach ($redactedLine in @($redactionProbe.positive)) {
    Assert-True -Condition (
        $redactedLine -match '<(?:SECRET|REDACTED)>' -and
        $redactedLine -notmatch (
            '(?i)sk-openai-secret|azure-secret|db-secret|authorization-secret|' +
            'cli-token|dotted-secret|hunter2|sk-secret|sk-double-space|sk-tab|' +
            'multi word secret|client-secret-value|invalid-secret|rejected-P@ssw0rd|' +
            'missing-value|token-value|secret-value|auth-value|dXNlcjpwYXNz|leaked-tail|' +
            'colon-password|colon-token|colon-authorization|json-password|json-token|' +
            'json-api-key|camel-password|camel-client-secret|camel-auth-token|' +
            'camel-oauth-token|header-secret|snake-header-secret|aws-secret-access-key|' +
            'framework-secret-key|camel-secret-access-key|confirmation-secret|' +
            'camel-token-value|json-confirmation-secret|json-token-value'
        )
    ) -Message "A prefixed secret was not redacted: $redactedLine"
}
for ($index = 0; $index -lt $redactionProbe.negative.Count; $index++) {
    Assert-True -Condition (
        [string]$redactionProbe.negative[$index] -ceq
            [string]$redactionProbe.expected_negative[$index]
    ) -Message "Ordinary prose was over-redacted: $($redactionProbe.negative[$index])"
}
$selectedEvidenceText = @($redactionProbe.selected) -join "`n"
Assert-True -Condition (
    $redactionProbe.selected.Count -eq 5 -and
    $selectedEvidenceText -notmatch (
        'selected-secret|selected-password|selected-api-key|' +
        'selected-double-space|selected multi word'
    ) -and
    $selectedEvidenceText -match '<(?:SECRET|REDACTED)>'
) -Message 'Selected journal evidence retained a secret.'

$postExitWaitNode = $runnerAst.Find(
    {
        param($node)
        return (
            $node -is [Management.Automation.Language.FunctionDefinitionAst] -and
            $node.Name -eq 'Wait-ForNoMatchingTerminalProcesses'
        )
    },
    $true
)
Assert-True -Condition ($null -ne $postExitWaitNode) `
    -Message 'Wait-ForNoMatchingTerminalProcesses was not found for CIM-settling regression testing.'
$postExitWaitDefinitionText = $postExitWaitNode.Extent.Text
$postExitMatcherNode = $runnerAst.Find(
    {
        param($node)
        return (
            $node -is [Management.Automation.Language.FunctionDefinitionAst] -and
            $node.Name -eq 'Get-MatchingTerminalProcesses'
        )
    },
    $true
)
Assert-True -Condition ($null -ne $postExitMatcherNode) `
    -Message 'Get-MatchingTerminalProcesses was not found for trusted-identity regression testing.'
$postExitMatcherDefinitionText = $postExitMatcherNode.Extent.Text
$postExitWaitProbe = & {
    param([Parameter(Mandatory = $true)][string]$DefinitionText)

    . ([scriptblock]::Create($DefinitionText))
    $ownedIdentity = [pscustomobject]@{
        process_id = 4242
        creation_utc_ticks = [long]638574336000000000
        session_id = 3
        executable_path = 'C:\synthetic\terminal64.exe'
        executable_file_identity = 'synthetic-identity'
    }
    $state = [pscustomobject]@{
        mode = 'stale_unresolved'
        calls = 0
        sleeps = 0
    }
    function New-UnresolvedOwnedObservation {
        return [pscustomobject]@{
            process_id = 4242
            creation_utc_ticks = $null
            session_id = $null
            executable_file_identity = 'synthetic-identity'
            identity_unresolved = $true
        }
    }
    function Get-MatchingTerminalProcesses {
        param(
            $ExecutablePath,
            $ExpectedFileIdentity,
            $TrustedSuspendedIdentity,
            $SettlingOwnedIdentity
        )
        $state.calls++
        switch ($state.mode) {
            'stale_unresolved' {
                if ($state.calls -lt 3) {
                    return New-UnresolvedOwnedObservation
                }
                return @()
            }
            'persistent_unresolved' {
                return New-UnresolvedOwnedObservation
            }
            'foreign' {
                return [pscustomobject]@{
                    process_id = 5252
                    creation_utc_ticks = [long]638574336000000100
                    session_id = 3
                    executable_file_identity = 'synthetic-identity'
                    identity_unresolved = $false
                }
            }
            'inspection_error' {
                throw 'BLOCKED: synthetic inspection failure'
            }
            default {
                throw "Unexpected process-discovery probe mode: $($state.mode)"
            }
        }
    }
    function Start-Sleep {
        param([int]$Milliseconds)
        $state.sleeps++
    }

    $staleRemaining = @(
        Wait-ForNoMatchingTerminalProcesses `
            -ExecutablePath 'C:\synthetic\terminal64.exe' `
            -ExpectedFileIdentity 'synthetic-identity' `
            -VerifiedOwnedProcessIdentity $ownedIdentity `
            -TimeoutMilliseconds 1000 `
            -PollMilliseconds 1
    )
    $staleCalls = $state.calls
    $staleSleeps = $state.sleeps

    $state.mode = 'persistent_unresolved'
    $state.calls = 0
    $state.sleeps = 0
    $persistentRemaining = @(
        Wait-ForNoMatchingTerminalProcesses `
            -ExecutablePath 'C:\synthetic\terminal64.exe' `
            -ExpectedFileIdentity 'synthetic-identity' `
            -VerifiedOwnedProcessIdentity $ownedIdentity `
            -TimeoutMilliseconds 0 `
            -PollMilliseconds 1
    )
    $persistentCalls = $state.calls
    $persistentSleeps = $state.sleeps

    $state.mode = 'foreign'
    $state.calls = 0
    $state.sleeps = 0
    $foreignRemaining = @(
        Wait-ForNoMatchingTerminalProcesses `
            -ExecutablePath 'C:\synthetic\terminal64.exe' `
            -ExpectedFileIdentity 'synthetic-identity' `
            -VerifiedOwnedProcessIdentity $ownedIdentity `
            -TimeoutMilliseconds 1000 `
            -PollMilliseconds 1
    )
    $foreignCalls = $state.calls
    $foreignSleeps = $state.sleeps

    $state.mode = 'inspection_error'
    $state.calls = 0
    $state.sleeps = 0
    $inspectionError = $null
    try {
        $ignored = @(
            Wait-ForNoMatchingTerminalProcesses `
                -ExecutablePath 'C:\synthetic\terminal64.exe' `
                -ExpectedFileIdentity 'synthetic-identity' `
                -VerifiedOwnedProcessIdentity $ownedIdentity `
                -TimeoutMilliseconds 1000 `
                -PollMilliseconds 1
        )
    }
    catch {
        $inspectionError = $_.Exception.Message
    }

    return [pscustomobject]@{
        stale_calls = $staleCalls
        stale_sleeps = $staleSleeps
        stale_remaining = $staleRemaining.Count
        persistent_calls = $persistentCalls
        persistent_sleeps = $persistentSleeps
        persistent_remaining = $persistentRemaining.Count
        persistent_unresolved = if ($persistentRemaining.Count -gt 0) {
            [bool]$persistentRemaining[0].identity_unresolved
        }
        else {
            $false
        }
        foreign_calls = $foreignCalls
        foreign_sleeps = $foreignSleeps
        foreign_remaining = $foreignRemaining.Count
        foreign_pid = if ($foreignRemaining.Count -gt 0) {
            [int]$foreignRemaining[0].process_id
        }
        else {
            -1
        }
        inspection_calls = $state.calls
        inspection_sleeps = $state.sleeps
        inspection_error = $inspectionError
    }
} $postExitWaitDefinitionText
Assert-True -Condition (
    $postExitWaitProbe.stale_calls -eq 3 -and
    $postExitWaitProbe.stale_sleeps -eq 2 -and
    $postExitWaitProbe.stale_remaining -eq 0
) -Message 'Post-job-empty process discovery did not tolerate a settling owned row.'
Assert-True -Condition (
    $postExitWaitProbe.persistent_calls -eq 1 -and
    $postExitWaitProbe.persistent_sleeps -eq 0 -and
    $postExitWaitProbe.persistent_remaining -eq 1 -and
    $postExitWaitProbe.persistent_unresolved
) -Message 'A persistent unresolved owned row was incorrectly accepted as gone.'
Assert-True -Condition (
    $postExitWaitProbe.foreign_calls -eq 1 -and
    $postExitWaitProbe.foreign_sleeps -eq 0 -and
    $postExitWaitProbe.foreign_remaining -eq 1 -and
    $postExitWaitProbe.foreign_pid -eq 5252
) -Message 'Post-job-empty process discovery retried a foreign terminal process.'
Assert-True -Condition (
    $postExitWaitProbe.inspection_calls -eq 1 -and
    $postExitWaitProbe.inspection_sleeps -eq 0 -and
    $postExitWaitProbe.inspection_error -match 'BLOCKED: synthetic inspection failure'
) -Message 'Post-job-empty process discovery suppressed or retried an inspection failure.'

$trustedMatcherProbe = & {
    param([Parameter(Mandatory = $true)][string]$DefinitionText)

    . ([scriptblock]::Create($DefinitionText))
    $creationDate = [DateTime]::SpecifyKind(
        [DateTime]::ParseExact(
            '2024-01-01T00:00:00',
            'yyyy-MM-ddTHH:mm:ss',
            [Globalization.CultureInfo]::InvariantCulture
        ),
        [DateTimeKind]::Utc
    )
    $ownedIdentity = [pscustomobject]@{
        process_id = 4242
        creation_utc_ticks = [long]$creationDate.Ticks
        session_id = 3
        executable_path = 'C:\synthetic\terminal64.exe'
        executable_file_identity = 'synthetic-identity'
    }
    $processRecord = [pscustomobject]@{
        ProcessId = 4242
        ParentProcessId = 111
        Name = 'terminal64.exe'
        CreationDate = $null
        SessionId = $null
        ExecutablePath = $null
    }
    function Get-CimInstance {
        param($ClassName)
        return $processRecord
    }
    $identityState = [pscustomobject]@{
        throw = $false
        value = 'synthetic-identity'
    }
    function Get-FileIdentityFromPath {
        param($Path)
        if ($identityState.throw) {
            throw 'Synthetic file identity lookup failure.'
        }
        return [string]$identityState.value
    }
    function Get-NativeProcessImageObservation {
        param($ProcessId, $ExpectedVolumePath)
        return [pscustomobject]@{
            query_succeeded = $false
            on_expected_volume = $false
            identity_resolved = $false
            executable_path = $null
            file_identity = $null
            error = 'Synthetic native process-image lookup failure.'
        }
    }

    $suspendedMissingFields = @(
        Get-MatchingTerminalProcesses `
            -ExecutablePath 'C:\synthetic\terminal64.exe' `
            -ExpectedFileIdentity 'synthetic-identity' `
            -TrustedSuspendedIdentity $ownedIdentity
    )

    $noTrustedError = $null
    try {
        $ignored = @(
            Get-MatchingTerminalProcesses `
                -ExecutablePath 'C:\synthetic\terminal64.exe' `
                -ExpectedFileIdentity 'synthetic-identity'
        )
    }
    catch {
        $noTrustedError = $_.Exception.Message
    }

    $processRecord.CreationDate = $creationDate.AddMilliseconds(250)
    $processRecord.SessionId = 4
    $suspendedObservedFields = @(
        Get-MatchingTerminalProcesses `
            -ExecutablePath 'C:\synthetic\terminal64.exe' `
            -ExpectedFileIdentity 'synthetic-identity' `
            -TrustedSuspendedIdentity $ownedIdentity
    )
    $settlingIdentity = $suspendedObservedFields[0]

    $processRecord.CreationDate = $null
    $processRecord.SessionId = $null
    $processRecord.Name = 'other.exe'
    $suspendedNameMismatchError = $null
    try {
        $ignored = @(
            Get-MatchingTerminalProcesses `
                -ExecutablePath 'C:\synthetic\terminal64.exe' `
                -ExpectedFileIdentity 'synthetic-identity' `
                -TrustedSuspendedIdentity $ownedIdentity
        )
    }
    catch {
        $suspendedNameMismatchError = $_.Exception.Message
    }

    $processRecord.Name = 'terminal64.exe'
    $mixedModeError = $null
    try {
        $ignored = @(
            Get-MatchingTerminalProcesses `
                -ExecutablePath 'C:\synthetic\terminal64.exe' `
                -ExpectedFileIdentity 'synthetic-identity' `
                -TrustedSuspendedIdentity $ownedIdentity `
                -SettlingOwnedIdentity $settlingIdentity
        )
    }
    catch {
        $mixedModeError = $_.Exception.Message
    }

    $processRecord.CreationDate = $null
    $processRecord.SessionId = $null
    $settlingMissingFields = @(
        Get-MatchingTerminalProcesses `
            -ExecutablePath 'C:\synthetic\terminal64.exe' `
            -ExpectedFileIdentity 'synthetic-identity' `
            -SettlingOwnedIdentity $settlingIdentity
    )

    $processRecord.Name = $null
    $settlingMissingName = @(
        Get-MatchingTerminalProcesses `
            -ExecutablePath 'C:\synthetic\terminal64.exe' `
            -ExpectedFileIdentity 'synthetic-identity' `
            -SettlingOwnedIdentity $settlingIdentity
    )

    $processRecord.Name = 'terminal64.exe'
    $processRecord.CreationDate = $creationDate.AddSeconds(1)
    $settlingCreationMismatchError = $null
    try {
        $ignored = @(
            Get-MatchingTerminalProcesses `
                -ExecutablePath 'C:\synthetic\terminal64.exe' `
                -ExpectedFileIdentity 'synthetic-identity' `
                -SettlingOwnedIdentity $settlingIdentity
        )
    }
    catch {
        $settlingCreationMismatchError = $_.Exception.Message
    }

    $processRecord.Name = 'terminal64.exe'
    $processRecord.CreationDate = $null
    $processRecord.SessionId = $null
    $processRecord.ExecutablePath = 'C:\other\terminal64.exe'
    $identityState.throw = $true
    $suspendedWrongPathError = $null
    try {
        $ignored = @(
            Get-MatchingTerminalProcesses `
                -ExecutablePath 'C:\synthetic\terminal64.exe' `
                -ExpectedFileIdentity 'synthetic-identity' `
                -TrustedSuspendedIdentity $ownedIdentity
        )
    }
    catch {
        $suspendedWrongPathError = $_.Exception.Message
    }
    $settlingWrongPathError = $null
    try {
        $ignored = @(
            Get-MatchingTerminalProcesses `
                -ExecutablePath 'C:\synthetic\terminal64.exe' `
                -ExpectedFileIdentity 'synthetic-identity' `
                -SettlingOwnedIdentity $settlingIdentity
        )
    }
    catch {
        $settlingWrongPathError = $_.Exception.Message
    }

    $processRecord.ExecutablePath = 'C:\synthetic\terminal64.exe'
    $identityState.throw = $false
    $identityState.value = 'wrong-identity'
    $suspendedWrongIdentityError = $null
    try {
        $ignored = @(
            Get-MatchingTerminalProcesses `
                -ExecutablePath 'C:\synthetic\terminal64.exe' `
                -ExpectedFileIdentity 'synthetic-identity' `
                -TrustedSuspendedIdentity $ownedIdentity
        )
    }
    catch {
        $suspendedWrongIdentityError = $_.Exception.Message
    }
    $settlingWrongIdentityError = $null
    try {
        $ignored = @(
            Get-MatchingTerminalProcesses `
                -ExecutablePath 'C:\synthetic\terminal64.exe' `
                -ExpectedFileIdentity 'synthetic-identity' `
                -SettlingOwnedIdentity $settlingIdentity
        )
    }
    catch {
        $settlingWrongIdentityError = $_.Exception.Message
    }

    $processRecord.ExecutablePath = 'C:\alias\terminal64.exe'
    $identityState.value = 'synthetic-identity'
    $suspendedIdentityAlias = @(
        Get-MatchingTerminalProcesses `
            -ExecutablePath 'C:\synthetic\terminal64.exe' `
            -ExpectedFileIdentity 'synthetic-identity' `
            -TrustedSuspendedIdentity $ownedIdentity
    )
    $settlingIdentityAlias = @(
        Get-MatchingTerminalProcesses `
            -ExecutablePath 'C:\synthetic\terminal64.exe' `
            -ExpectedFileIdentity 'synthetic-identity' `
            -SettlingOwnedIdentity $settlingIdentity
    )

    return [pscustomobject]@{
        suspended_count = $suspendedMissingFields.Count
        suspended_creation_ticks = if ($suspendedMissingFields.Count -gt 0) {
            [long]$suspendedMissingFields[0].creation_utc_ticks
        }
        else {
            0
        }
        suspended_session = if ($suspendedMissingFields.Count -gt 0) {
            [int]$suspendedMissingFields[0].session_id
        }
        else {
            -1
        }
        no_trusted_error = $noTrustedError
        suspended_observed_count = $suspendedObservedFields.Count
        suspended_observed_creation_ticks = if ($suspendedObservedFields.Count -gt 0) {
            [long]$suspendedObservedFields[0].creation_utc_ticks
        }
        else {
            0
        }
        suspended_observed_session = if ($suspendedObservedFields.Count -gt 0) {
            [int]$suspendedObservedFields[0].session_id
        }
        else {
            -1
        }
        suspended_observed_creation_flag = if ($suspendedObservedFields.Count -gt 0) {
            [bool]$suspendedObservedFields[0].creation_cim_observed
        }
        else {
            $false
        }
        suspended_observed_session_flag = if ($suspendedObservedFields.Count -gt 0) {
            [bool]$suspendedObservedFields[0].session_cim_observed
        }
        else {
            $false
        }
        suspended_name_mismatch_error = $suspendedNameMismatchError
        mixed_mode_error = $mixedModeError
        settling_missing_count = $settlingMissingFields.Count
        settling_missing_unresolved = if ($settlingMissingFields.Count -gt 0) {
            [bool]$settlingMissingFields[0].identity_unresolved
        }
        else {
            $false
        }
        settling_missing_name_count = $settlingMissingName.Count
        settling_missing_name_unresolved = if ($settlingMissingName.Count -gt 0) {
            [bool]$settlingMissingName[0].identity_unresolved
        }
        else {
            $false
        }
        settling_creation_mismatch_error = $settlingCreationMismatchError
        suspended_wrong_path_error = $suspendedWrongPathError
        settling_wrong_path_error = $settlingWrongPathError
        suspended_wrong_identity_error = $suspendedWrongIdentityError
        settling_wrong_identity_error = $settlingWrongIdentityError
        suspended_alias_count = $suspendedIdentityAlias.Count
        settling_alias_count = $settlingIdentityAlias.Count
        settling_alias_unresolved = if ($settlingIdentityAlias.Count -gt 0) {
            [bool]$settlingIdentityAlias[0].identity_unresolved
        }
        else {
            $false
        }
    }
} $postExitMatcherDefinitionText
Assert-True -Condition (
    $trustedMatcherProbe.suspended_count -eq 1 -and
    $trustedMatcherProbe.suspended_creation_ticks -eq [long]638396640000000000 -and
    $trustedMatcherProbe.suspended_session -eq 3
) -Message 'The native suspended-process proof did not fill missing CIM fields.'
Assert-True -Condition (
    $trustedMatcherProbe.suspended_observed_count -eq 1 -and
    $trustedMatcherProbe.suspended_observed_creation_ticks -eq
        [long]638396640002500000 -and
    $trustedMatcherProbe.suspended_observed_session -eq 4 -and
    $trustedMatcherProbe.suspended_observed_creation_flag -and
    $trustedMatcherProbe.suspended_observed_session_flag
) -Message 'Observed CIM values were not preserved as the post-exit identity baseline.'
foreach ($blockedSuspendedError in @(
        $trustedMatcherProbe.no_trusted_error,
        $trustedMatcherProbe.suspended_name_mismatch_error
    )) {
    Assert-True -Condition (
        $blockedSuspendedError -match 'identity is unreadable for PID\(s\) 4242'
    ) -Message 'An untrusted or contradictory suspended-process observation did not fail closed.'
}
Assert-True -Condition (
    $trustedMatcherProbe.mixed_mode_error -match
        'cannot use suspended and settling identities together'
) -Message 'Process discovery accepted conflicting identity modes.'
Assert-True -Condition (
    $trustedMatcherProbe.settling_missing_count -eq 1 -and
    $trustedMatcherProbe.settling_missing_unresolved -and
    $trustedMatcherProbe.settling_missing_name_count -eq 1 -and
    $trustedMatcherProbe.settling_missing_name_unresolved
) -Message 'Missing post-exit CIM fields were accepted instead of marked unresolved.'
Assert-True -Condition (
    $trustedMatcherProbe.settling_creation_mismatch_error -match
        'identity is unreadable for PID\(s\) 4242'
) -Message 'A positive post-exit identity mismatch did not fail closed.'
foreach ($readableContradictionError in @(
        $trustedMatcherProbe.suspended_wrong_path_error,
        $trustedMatcherProbe.settling_wrong_path_error,
        $trustedMatcherProbe.suspended_wrong_identity_error,
        $trustedMatcherProbe.settling_wrong_identity_error
    )) {
    Assert-True -Condition (
        $readableContradictionError -match 'identity is unreadable for PID\(s\) 4242'
    ) -Message 'A readable path or file-identity contradiction did not fail closed.'
}
Assert-True -Condition (
    $trustedMatcherProbe.suspended_alias_count -eq 1 -and
    $trustedMatcherProbe.settling_alias_count -eq 1 -and
    $trustedMatcherProbe.settling_alias_unresolved
) -Message 'An identity-equivalent executable alias was incorrectly rejected.'

$processAliasFallbackProbe = & {
    param([Parameter(Mandatory = $true)][string]$DefinitionText)

    . ([scriptblock]::Create($DefinitionText))
    $processRecord = [pscustomobject]@{
        ProcessId = 6262
        ParentProcessId = 111
        Name = 'renamed-host.exe'
        CreationDate = [datetime]'2024-01-01T00:00:00Z'
        SessionId = 3
        ExecutablePath = 'C:\junction\renamed-host.exe'
    }
    $state = [pscustomobject]@{
        reported_error = 'reparse'
        native_mode = 'resolved'
    }
    function Get-CimInstance {
        param($ClassName)
        return $processRecord
    }
    function Get-FileIdentityFromPath {
        param($Path)
        if ($state.reported_error -eq 'reparse') {
            throw (
                'BLOCKED: Unsafe or unleaseable directory path component. ' +
                'Reparse-point path entries are not allowed.'
            )
        }
        throw 'Synthetic access is denied.'
    }
    function Get-NativeProcessImageObservation {
        param($ProcessId, $ExpectedVolumePath)
        switch ($state.native_mode) {
            'resolved' {
                return [pscustomobject]@{
                    query_succeeded = $true
                    on_expected_volume = $true
                    identity_resolved = $true
                    executable_path = 'C:\real\renamed-host.exe'
                    file_identity = 'synthetic-identity'
                    error = $null
                }
            }
            'other_volume' {
                return [pscustomobject]@{
                    query_succeeded = $true
                    on_expected_volume = $false
                    identity_resolved = $false
                    executable_path = $null
                    file_identity = $null
                    error = $null
                }
            }
            'reparse' {
                return [pscustomobject]@{
                    query_succeeded = $true
                    on_expected_volume = $true
                    identity_resolved = $false
                    executable_path = 'C:\junction\renamed-host.exe'
                    file_identity = $null
                    error = 'Reparse-point path entries are not allowed.'
                }
            }
            'failed' {
                return [pscustomobject]@{
                    query_succeeded = $false
                    on_expected_volume = $false
                    identity_resolved = $false
                    executable_path = $null
                    file_identity = $null
                    error = 'Synthetic process query failure.'
                }
            }
            default {
                throw "Unexpected native observation mode: $($state.native_mode)"
            }
        }
    }
    function Invoke-MatcherCase {
        $errorMessage = $null
        try {
            $items = @(
                Get-MatchingTerminalProcesses `
                    -ExecutablePath 'C:\selected\terminal64.exe' `
                    -ExpectedFileIdentity 'synthetic-identity'
            )
        }
        catch {
            $items = @()
            $errorMessage = $_.Exception.Message
        }
        return [pscustomobject]@{
            count = $items.Count
            error = $errorMessage
            first_path = if ($items.Count -gt 0) {
                [string]$items[0].executable_path
            }
            else {
                $null
            }
            first_identity_match = if ($items.Count -gt 0) {
                [bool]$items[0].identity_match
            }
            else {
                $false
            }
            first_path_match = if ($items.Count -gt 0) {
                [bool]$items[0].path_match
            }
            else {
                $false
            }
        }
    }

    $resolvedJunction = Invoke-MatcherCase

    $processRecord.ExecutablePath = $null
    $resolvedMissingCimPath = Invoke-MatcherCase

    $state.native_mode = 'reparse'
    $unresolvedMissingCimPath = Invoke-MatcherCase

    $processRecord.ExecutablePath = 'C:\junction\renamed-host.exe'
    $state.native_mode = 'failed'
    $unresolvedJunction = Invoke-MatcherCase

    $processRecord.ExecutablePath = 'C:\ordinary\unrelated.exe'
    $state.reported_error = 'access_denied'
    $unrelatedAccessDenied = Invoke-MatcherCase

    $processRecord.ExecutablePath = 'C:\junction\renamed-host.exe'
    $state.reported_error = 'reparse'
    $state.native_mode = 'other_volume'
    $otherVolumeJunction = Invoke-MatcherCase
    $processRecord.Name = 'terminal64.exe'
    $otherVolumeSameLeaf = Invoke-MatcherCase

    return [pscustomobject]@{
        resolved_junction = $resolvedJunction
        resolved_missing_cim_path = $resolvedMissingCimPath
        unresolved_missing_cim_path = $unresolvedMissingCimPath
        unresolved_junction = $unresolvedJunction
        unrelated_access_denied = $unrelatedAccessDenied
        other_volume_junction = $otherVolumeJunction
        other_volume_same_leaf = $otherVolumeSameLeaf
    }
} $postExitMatcherDefinitionText
Assert-True -Condition (
    $processAliasFallbackProbe.resolved_junction.count -eq 1 -and
    $null -eq $processAliasFallbackProbe.resolved_junction.error -and
    $processAliasFallbackProbe.resolved_junction.first_identity_match -and
    -not $processAliasFallbackProbe.resolved_junction.first_path_match -and
    [string]$processAliasFallbackProbe.resolved_junction.first_path -ceq
        'C:\real\renamed-host.exe'
) -Message 'A renamed hard-link image behind a junction evaded native identity fallback.'
Assert-True -Condition (
    $processAliasFallbackProbe.resolved_missing_cim_path.count -eq 1 -and
    $null -eq $processAliasFallbackProbe.resolved_missing_cim_path.error -and
    $processAliasFallbackProbe.resolved_missing_cim_path.first_identity_match
) -Message 'Native process-image identity did not recover a missing CIM image path.'
Assert-True -Condition (
    $processAliasFallbackProbe.unresolved_missing_cim_path.count -eq 0 -and
    $processAliasFallbackProbe.unresolved_missing_cim_path.error -match
        'identity is unreadable for PID\(s\) 6262'
) -Message 'A native reparse path with missing CIM fields was silently ignored.'
Assert-True -Condition (
    $processAliasFallbackProbe.unresolved_junction.count -eq 0 -and
    $processAliasFallbackProbe.unresolved_junction.error -match
        'identity is unreadable for PID\(s\) 6262'
) -Message 'An unresolved same-volume reparse alias was silently ignored.'
Assert-True -Condition (
    $processAliasFallbackProbe.unrelated_access_denied.count -eq 0 -and
    $null -eq $processAliasFallbackProbe.unrelated_access_denied.error
) -Message 'An unrelated inaccessible process caused a blanket launch failure.'
Assert-True -Condition (
    $processAliasFallbackProbe.other_volume_junction.count -eq 0 -and
    $null -eq $processAliasFallbackProbe.other_volume_junction.error -and
    $processAliasFallbackProbe.other_volume_same_leaf.count -eq 0 -and
    $null -eq $processAliasFallbackProbe.other_volume_same_leaf.error
) -Message 'A native process image proven to be on another volume was treated as a possible hard link.'

Assert-True -Condition ($skillText -notmatch '(?i)[A-Z]:\\Users\\') `
    -Message 'SKILL.md contains a user-specific path.'
Assert-True -Condition ($referenceText -notmatch '(?i)[A-Z]:\\Users\\') `
    -Message 'Strategy Tester reference contains a user-specific path.'
Assert-True -Condition ($compilerText -notmatch '\$sourceDirectory|nearSource') `
    -Message 'Compiler wrapper must not discover executables from the source tree.'

$compilerTokens = $null
$compilerParseErrors = $null
$compilerAst = [Management.Automation.Language.Parser]::ParseFile(
    $compiler,
    [ref]$compilerTokens,
    [ref]$compilerParseErrors
)
$resolverNode = $compilerAst.Find(
    {
        param($node)
        return (
            $node -is [Management.Automation.Language.FunctionDefinitionAst] -and
            $node.Name -eq 'Resolve-MetaEditorExecutable'
        )
    },
    $true
)
Assert-True -Condition ($null -ne $resolverNode) `
    -Message 'Resolve-MetaEditorExecutable was not found for discovery regression testing.'
$resolverDefinitionText = $resolverNode.Extent.Text
$moveLeasedOutputNode = $compilerAst.Find(
    {
        param($node)
        return (
            $node -is [Management.Automation.Language.FunctionDefinitionAst] -and
            $node.Name -eq 'Move-LeasedCompilerOutputAside'
        )
    },
    $true
)
Assert-True -Condition ($null -ne $moveLeasedOutputNode) `
    -Message 'Move-LeasedCompilerOutputAside was not found for backup-name regression testing.'
$moveLeasedOutputDefinitionText = $moveLeasedOutputNode.Extent.Text
$moveLogNode = $compilerAst.Find(
    {
        param($node)
        return (
            $node -is [Management.Automation.Language.FunctionDefinitionAst] -and
            $node.Name -eq 'Move-OriginalLogAside'
        )
    },
    $true
)
Assert-True -Condition ($null -ne $moveLogNode) `
    -Message 'Move-OriginalLogAside was not found for backup-name regression testing.'
$moveLogDefinitionText = $moveLogNode.Extent.Text
$completeLogNode = $compilerAst.Find(
    {
        param($node)
        return (
            $node -is [Management.Automation.Language.FunctionDefinitionAst] -and
            $node.Name -eq 'Complete-LeasedCompilerOutput'
        )
    },
    $true
)
Assert-True -Condition ($null -ne $completeLogNode) `
    -Message 'Complete-LeasedCompilerOutput was not found for unsafe-cleanup regression testing.'
$completeLogDefinitionText = $completeLogNode.Extent.Text
$launchCleanupNode = $compilerAst.Find(
    {
        param($node)
        return (
            $node -is [Management.Automation.Language.FunctionDefinitionAst] -and
            $node.Name -eq 'Test-CompilerLaunchCleanupVerified'
        )
    },
    $true
)
Assert-True -Condition ($null -ne $launchCleanupNode) `
    -Message 'Test-CompilerLaunchCleanupVerified was not found for launch-state regression testing.'
$launchCleanupDefinitionText = $launchCleanupNode.Extent.Text
$markLaunchUnsafeIndex = $compilerText.IndexOf(
    '$compileJobEmpty = $false',
    [StringComparison]::Ordinal
)
$nativeStartIndex = $compilerText.IndexOf(
    '$compileLaunch = [Mql5Coding.CompilerProcessJob]::Start(',
    [StringComparison]::Ordinal
)
Assert-True -Condition (
    $markLaunchUnsafeIndex -ge 0 -and
    $nativeStartIndex -gt $markLaunchUnsafeIndex
) -Message 'Compiler launch was not marked unsafe before native process creation.'
$discoveryResult = & {
    param([Parameter(Mandatory = $true)][string]$DefinitionText)

    . ([scriptblock]::Create($DefinitionText))

    function Get-MetaEditorFromCandidate {
        param($Candidate)
        if ([string]$Candidate -ceq 'C:\synthetic-valid') {
            return 'C:\synthetic-valid\metaeditor64.exe'
        }
        return $null
    }
    function Get-Process {
        param($Name, $ErrorAction)
        return @()
    }
    function Get-Command {
        param($Name, $ErrorAction)
        return $null
    }
    function Get-ItemProperty {
        param($Path, $ErrorAction)
        return @([pscustomobject]@{ UnrelatedValue = 'incomplete uninstall entry' })
    }
    function Test-Path {
        param($LiteralPath, $PathType)
        return [string]$LiteralPath -ceq 'C:\synthetic-program-files'
    }
    function Get-ChildItem {
        param($LiteralPath, [switch]$Directory, $ErrorAction)
        return @([pscustomobject]@{ FullName = 'C:\synthetic-valid' })
    }

    $savedMetaEditorExe = $env:METAEDITOR_EXE
    $savedMetaEditorPath = $env:METAEDITOR_PATH
    $savedProgramFiles = $env:ProgramFiles
    $savedProgramFilesX86 = ${env:ProgramFiles(x86)}
    try {
        $env:METAEDITOR_EXE = $null
        $env:METAEDITOR_PATH = $null
        $env:ProgramFiles = 'C:\synthetic-program-files'
        ${env:ProgramFiles(x86)} = $null
        return Resolve-MetaEditorExecutable -RequestedPath $null
    }
    finally {
        $env:METAEDITOR_EXE = $savedMetaEditorExe
        $env:METAEDITOR_PATH = $savedMetaEditorPath
        $env:ProgramFiles = $savedProgramFiles
        ${env:ProgramFiles(x86)} = $savedProgramFilesX86
    }
} $resolverDefinitionText
Assert-True -Condition (
    [string]$discoveryResult -ceq 'C:\synthetic-valid\metaeditor64.exe'
) -Message 'MetaEditor auto-discovery stopped at an incomplete uninstall entry.'

try {
    foreach ($directory in @(
            (Join-Path $testRoot 'install'),
            (Join-Path $testRoot 'data\MQL5\Experts'),
            (Join-Path $testRoot 'data\MQL5\Profiles\Tester'),
            (Join-Path $testRoot 'data\Tester\logs'),
            (Join-Path $testRoot 'data\logs'),
            (Join-Path $testRoot 'outputs')
        )) {
        [IO.Directory]::CreateDirectory($directory) | Out-Null
    }

    $terminal = Join-Path $testRoot 'install\terminal64.exe'
    & $csharpCompiler /nologo /target:exe "/out:$terminal" $fakeTerminalSource
    if ($LASTEXITCODE -ne 0) {
        throw "Synthetic terminal compilation failed with exit code $LASTEXITCODE."
    }
    $metaEditor = Join-Path $testRoot 'install\metaeditor64.exe'
    & $csharpCompiler /nologo /target:exe "/out:$metaEditor" $fakeMetaEditorSource
    if ($LASTEXITCODE -ne 0) {
        throw "Synthetic MetaEditor compilation failed with exit code $LASTEXITCODE."
    }

    $dataPath = Join-Path $testRoot 'data'
    [IO.File]::WriteAllText(
        (Join-Path $dataPath 'origin.txt'),
        (Join-Path $testRoot 'install'),
        (New-Object Text.UTF8Encoding($false))
    )
    $expert = Join-Path $testRoot 'fixture.ex5'
    [IO.File]::WriteAllBytes($expert, [Text.Encoding]::ASCII.GetBytes('synthetic fixture'))
    $preset = Join-Path $testRoot 'fixture.set'
    [IO.File]::WriteAllText(
        $preset,
        'FakeInput=1||0||1||N',
        (New-Object Text.UTF8Encoding($false))
    )
    $expertHash = (Get-FileHash -LiteralPath $expert -Algorithm SHA256).Hash.ToLowerInvariant()

    $compileDirectory = Join-Path $testRoot 'compile'
    [IO.Directory]::CreateDirectory($compileDirectory) | Out-Null

    $directVolumeIdentity = [Mql5Coding.JobProcessLaunch]::GetFixedLocalVolumeIdentity(
        $testRoot
    )
    Assert-True -Condition (-not [string]::IsNullOrWhiteSpace(
            [string]$directVolumeIdentity
        )) -Message 'A direct fixed local test volume did not produce an identity.'

    $substExecutable = Join-Path $env:WINDIR 'System32\subst.exe'
    Assert-True -Condition (Test-Path -LiteralPath $substExecutable -PathType Leaf) `
        -Message 'The SUBST regression test could not find subst.exe.'
    $substDrive = $null
    foreach ($letter in [char[]]'ZYXWVUTSRQPONMLKJIHGFED') {
        $candidateDrive = ([string]$letter) + ':'
        & $substExecutable $candidateDrive $testRoot 2>$null | Out-Null
        if ($LASTEXITCODE -eq 0) {
            $substDrive = $candidateDrive
            break
        }
    }
    Assert-True -Condition (-not [string]::IsNullOrWhiteSpace($substDrive)) `
        -Message 'The SUBST regression test could not reserve a drive letter.'
    try {
        $substRejected = $false
        try {
            $null = [Mql5Coding.JobProcessLaunch]::GetFixedLocalVolumeIdentity(
                "$substDrive\"
            )
        }
        catch {
            $substRejected = $true
        }
        Assert-True -Condition $substRejected `
            -Message 'A SUBST drive was accepted as a direct fixed local volume.'
    }
    finally {
        & $substExecutable $substDrive /D 2>$null | Out-Null
        Assert-True -Condition ($LASTEXITCODE -eq 0) `
            -Message "The SUBST regression drive $substDrive could not be removed."
    }

    $testVolumeRoot = [IO.Path]::GetPathRoot($testRoot)
    $testVolumeDevice = $testVolumeRoot.Substring(0, 2)
    $rawDosTarget = [Mql5Coding.RawDosDeviceProbe]::Query($testVolumeDevice)
    $rawAliasDrive = $null
    foreach ($letter in [char[]]'ZYXWVUTSRQPONMLKJIHGFED') {
        $candidateDrive = ([string]$letter) + ':'
        if ([Mql5Coding.RawDosDeviceProbe]::IsDefined($candidateDrive)) {
            continue
        }
        try {
            [Mql5Coding.RawDosDeviceProbe]::Create(
                $candidateDrive,
                $rawDosTarget
            )
            $rawAliasDrive = $candidateDrive
            break
        }
        catch {
            continue
        }
    }
    Assert-True -Condition (-not [string]::IsNullOrWhiteSpace($rawAliasDrive)) `
        -Message 'The raw DOS-device regression test could not reserve a drive letter.'
    try {
        $rawAliasRoot = $rawAliasDrive + '\'
        $rawAliasRejected = $false
        try {
            $null = [Mql5Coding.JobProcessLaunch]::GetFixedLocalVolumeIdentity(
                $rawAliasRoot
            )
        }
        catch {
            $rawAliasRejected = $true
        }
        Assert-True -Condition $rawAliasRejected `
            -Message 'A raw DOS-device alias was accepted as a mount-manager drive.'

        $rawAliasTerminal = $rawAliasRoot + $terminal.Substring($testVolumeRoot.Length)
        $rawAliasDataPath = $rawAliasRoot + $dataPath.Substring($testVolumeRoot.Length)
        $rawAliasExpert = $rawAliasRoot + $expert.Substring($testVolumeRoot.Length)
        $rawAliasPreset = $rawAliasRoot + $preset.Substring($testVolumeRoot.Length)
        foreach ($probe in @(
                [pscustomobject]@{ path = $rawAliasTerminal; type = 'Leaf'; name = 'terminal' },
                [pscustomobject]@{ path = $rawAliasDataPath; type = 'Container'; name = 'data directory' },
                [pscustomobject]@{ path = $rawAliasExpert; type = 'Leaf'; name = 'expert' },
                [pscustomobject]@{ path = $rawAliasPreset; type = 'Leaf'; name = 'preset' }
            )) {
            Assert-True -Condition (
                Test-PathInChildPowerShell -Path $probe.path -PathType $probe.type
            ) -Message (
                "The raw DOS-device $($probe.name) path did not resolve in the child " +
                'PowerShell context, so the mount-manager policy was not exercised.'
            )
        }
        foreach ($runnerProbe in @(
                [pscustomobject]@{
                    name = 'preflight-raw-dos-device-terminal-alias'
                    terminal = $rawAliasTerminal
                    data = $dataPath
                },
                [pscustomobject]@{
                    name = 'preflight-raw-dos-device-data-alias'
                    terminal = $terminal
                    data = $rawAliasDataPath
                }
            )) {
            $rawAliasRunnerBlocked = Invoke-RunnerCase `
                -Name $runnerProbe.name `
                -Mode PreflightOnly `
                -TerminalPath $runnerProbe.terminal `
                -TerminalDataPath $runnerProbe.data `
                -ExpertPath $expert `
                -PresetPath $preset `
                -ExpertSha256 $expertHash
            $rawAliasResultDiagnostic = if ($null -eq $rawAliasRunnerBlocked.Result) {
                '<no result JSON>'
            }
            else {
                $rawAliasRunnerBlocked.Result | ConvertTo-Json -Depth 10 -Compress
            }
            Assert-True -Condition ($rawAliasRunnerBlocked.ExitCode -eq 4) `
                -Message (
                    'A raw DOS-device alias did not produce the required blocked exit. ' +
                    "case=$($runnerProbe.name); " +
                    "exit=$($rawAliasRunnerBlocked.ExitCode); " +
                    "result=$rawAliasResultDiagnostic; " +
                    "stderr=$($rawAliasRunnerBlocked.StandardError)"
                )
            Assert-True -Condition (
                $null -ne $rawAliasRunnerBlocked.Result -and
                [string]$rawAliasRunnerBlocked.Result.status -ceq 'blocked' -and
                -not [bool]$rawAliasRunnerBlocked.Result.process.execution_attempted
            ) -Message (
                "Raw DOS-device rejection for '$($runnerProbe.name)' did not produce " +
                "a pre-execution blocked result. Result: $rawAliasResultDiagnostic; " +
                "stderr=$($rawAliasRunnerBlocked.StandardError)"
            )
            $rawAliasResultErrors = if ($null -eq $rawAliasRunnerBlocked.Result) {
                ''
            }
            else {
                @($rawAliasRunnerBlocked.Result.errors) -join ' '
            }
            $rawAliasDiagnostic = (
                [string]$rawAliasRunnerBlocked.StandardError + ' ' +
                $rawAliasResultErrors
            )
            Assert-True -Condition (
                $rawAliasDiagnostic -match '(?i)mount manager|direct fixed local volume'
            ) -Message (
                "Raw DOS-device rejection for '$($runnerProbe.name)' did not identify " +
                "the unsafe volume mapping. Diagnostic: $rawAliasDiagnostic"
            )
        }
    }
    finally {
        [Mql5Coding.RawDosDeviceProbe]::Remove(
            $rawAliasDrive,
            $rawDosTarget
        )
    }

    $leaseProbeDirectory = Join-Path $testRoot 'compile-lease-probe'
    $leaseProbeRenamed = Join-Path $testRoot 'compile-lease-probe-renamed'
    [IO.Directory]::CreateDirectory($leaseProbeDirectory) | Out-Null
    $directoryLease = [Mql5Coding.CompilerProcessJob]::OpenDirectoryIdentityLease(
        $leaseProbeDirectory
    )
    $leaseBlockedRename = $false
    try {
        try {
            [IO.Directory]::Move($leaseProbeDirectory, $leaseProbeRenamed)
        }
        catch {
            $leaseBlockedRename = $true
        }
        Assert-True -Condition $leaseBlockedRename `
            -Message 'A held compiler directory-identity lease allowed its directory to be renamed.'
    }
    finally {
        $directoryLease.Dispose()
    }
    [IO.Directory]::Move($leaseProbeDirectory, $leaseProbeRenamed)
    [IO.Directory]::Move($leaseProbeRenamed, $leaseProbeDirectory)
    Remove-Item -LiteralPath $leaseProbeDirectory -Force

    $ancestorLeaseRoot = Join-Path $testRoot 'compile-ancestor-probe'
    $ancestorLeaseChild = Join-Path $ancestorLeaseRoot 'child'
    $ancestorLeaseRenamed = Join-Path $testRoot 'compile-ancestor-probe-renamed'
    [IO.Directory]::CreateDirectory($ancestorLeaseChild) | Out-Null
    $ancestorDirectoryLease = [Mql5Coding.CompilerProcessJob]::OpenDirectoryIdentityLease(
        $ancestorLeaseChild
    )
    $ancestorLeaseBlockedRename = $false
    try {
        try {
            [IO.Directory]::Move($ancestorLeaseRoot, $ancestorLeaseRenamed)
        }
        catch {
            $ancestorLeaseBlockedRename = $true
        }
        Assert-True -Condition $ancestorLeaseBlockedRename `
            -Message 'A compiler lease on a descendant allowed an ancestor directory to be renamed.'
    }
    finally {
        $ancestorDirectoryLease.Dispose()
    }
    [IO.Directory]::Move($ancestorLeaseRoot, $ancestorLeaseRenamed)
    [IO.Directory]::Move($ancestorLeaseRenamed, $ancestorLeaseRoot)
    Remove-Item -LiteralPath $ancestorLeaseRoot -Recurse -Force

    $compilerFileProbe = Join-Path $testRoot 'compiler-file-lease-probe.mq5'
    $compilerFileProbeRenamed = Join-Path $testRoot 'compiler-file-lease-probe-renamed.mq5'
    [IO.File]::WriteAllText(
        $compilerFileProbe,
        '// lease probe',
        [Text.Encoding]::ASCII
    )
    $compilerFileLease = [Mql5Coding.CompilerProcessJob]::OpenSourceFileIdentityLease(
        $compilerFileProbe
    )
    $compilerFileLeaseBlockedRename = $false
    $compilerFileLeaseBlockedWrite = $false
    try {
        try {
            [IO.File]::Move($compilerFileProbe, $compilerFileProbeRenamed)
        }
        catch {
            $compilerFileLeaseBlockedRename = $true
        }
        try {
            [IO.File]::WriteAllText(
                $compilerFileProbe,
                '// replacement',
                [Text.Encoding]::ASCII
            )
        }
        catch {
            $compilerFileLeaseBlockedWrite = $true
        }
        Assert-True -Condition $compilerFileLeaseBlockedRename `
            -Message 'A held compiler source-file lease allowed its path to be renamed.'
        Assert-True -Condition $compilerFileLeaseBlockedWrite `
            -Message 'A held compiler source-file lease allowed its bytes to be overwritten.'
    }
    finally {
        $compilerFileLease.Dispose()
    }
    [IO.File]::Move($compilerFileProbe, $compilerFileProbeRenamed)
    [IO.File]::Move($compilerFileProbeRenamed, $compilerFileProbe)
    Remove-Item -LiteralPath $compilerFileProbe -Force

    $testerLeaseProbeDirectory = Join-Path $testRoot 'tester-lease-probe'
    $testerLeaseProbeRenamed = Join-Path $testRoot 'tester-lease-probe-renamed'
    [IO.Directory]::CreateDirectory($testerLeaseProbeDirectory) | Out-Null
    $testerGuardTracker = New-Object 'System.Collections.Generic.List[object]'
    $testerGuardByPath = @{}
    $testerDirectoryLease = $null
    $testerDirectoryGuard = $null
    $testerLeaseCleanupErrors = New-Object 'System.Collections.Generic.List[string]'
    try {
        $testerDirectoryLease = [Mql5Coding.JobProcessLaunch]::OpenDirectoryComponentLease(
            $testerLeaseProbeDirectory
        )
        $testerDirectoryGuard = & {
            param($DefinitionText, $Path, $DirectoryLease, $Tracker, $GuardsByPath)
            . ([scriptblock]::Create($DefinitionText))
            Open-DirectoryMutationGuard `
                -Path $Path `
                -DirectoryLease $DirectoryLease `
                -Tracker $Tracker `
                -GuardsByPath $GuardsByPath `
                -RunId 'lease-probe'
        } `
            $directoryMutationGuardNode.Extent.Text `
            $testerLeaseProbeDirectory `
            $testerDirectoryLease `
            $testerGuardTracker `
            $testerGuardByPath
        $testerLeaseBlockedRename = $false
        $testerLeaseBlockedDataWrite = $false
        $testerGuardBlockedRename = $false
        try {
            [IO.Directory]::Move(
                $testerLeaseProbeDirectory,
                $testerLeaseProbeRenamed
            )
        }
        catch {
            $testerLeaseBlockedRename = $true
        }

        $openPathHandleMethod = [Mql5Coding.JobProcessLaunch].GetMethod(
            'OpenPathHandle',
            [Reflection.BindingFlags]::NonPublic -bor
                [Reflection.BindingFlags]::Static
        )
        Assert-True -Condition ($null -ne $openPathHandleMethod) `
            -Message 'The tester path-handle method was unavailable for the share-mode probe.'
        $directoryDataWriteProbe = $openPathHandleMethod.Invoke(
            $null,
            [object[]]@(
                [string]$testerLeaseProbeDirectory,
                [uint32]0x00000002,
                [uint32]0x00000007,
                [IntPtr]::Zero,
                [uint32]3,
                [uint32]0x02200000,
                [IntPtr]::Zero
            )
        )
        try {
            $testerLeaseBlockedDataWrite = (
                $null -eq $directoryDataWriteProbe -or
                [bool]$directoryDataWriteProbe.IsInvalid
            )
        }
        finally {
            if ($null -ne $directoryDataWriteProbe) {
                $directoryDataWriteProbe.Dispose()
            }
        }

        try {
            [IO.File]::Move(
                [string]$testerDirectoryGuard.path,
                ([string]$testerDirectoryGuard.path + '.renamed')
            )
        }
        catch {
            $testerGuardBlockedRename = $true
        }

        $testerLeaseChildDirectory = Join-Path $testerLeaseProbeDirectory 'child'
        $testerLeaseChildFile = Join-Path $testerLeaseChildDirectory 'probe.txt'
        [IO.Directory]::CreateDirectory($testerLeaseChildDirectory) | Out-Null
        [IO.File]::WriteAllText(
            $testerLeaseChildFile,
            'child write remains available',
            [Text.Encoding]::ASCII
        )

        Assert-True -Condition $testerLeaseBlockedRename `
            -Message 'A held tester path-entry lease allowed its directory to be renamed.'
        Assert-True -Condition $testerLeaseBlockedDataWrite `
            -Message 'A held tester directory lease allowed a second data-write handle.'
        Assert-True -Condition $testerGuardBlockedRename `
            -Message 'A directory mutation guard could be renamed while it was pinned.'
        Assert-True -Condition (
            $testerGuardTracker.Count -eq 1 -and
            (Test-Path -LiteralPath $testerDirectoryGuard.path -PathType Leaf)
        ) -Message 'The directory mutation guard was not pinned in the leased directory.'
        Assert-True -Condition (Test-Path -LiteralPath $testerLeaseChildFile -PathType Leaf) `
            -Message 'A held tester directory lease blocked normal child creation.'
    }
    finally {
        for ($testerGuardIndex = $testerGuardTracker.Count - 1; $testerGuardIndex -ge 0; $testerGuardIndex--) {
            try {
                if ($null -ne $testerGuardTracker[$testerGuardIndex].stream) {
                    $testerGuardTracker[$testerGuardIndex].stream.Dispose()
                }
            }
            catch {
                $testerLeaseCleanupErrors.Add(
                    "Could not release tester mutation guard: $($_.Exception.Message)"
                )
            }
        }
        if ($null -ne $testerDirectoryLease) {
            try {
                $testerDirectoryLease.Dispose()
            }
            catch {
                $testerLeaseCleanupErrors.Add(
                    "Could not release tester directory lease: $($_.Exception.Message)"
                )
            }
        }
    }
    Assert-True -Condition ($testerLeaseCleanupErrors.Count -eq 0) `
        -Message ("Tester lease-probe cleanup failed: " + ($testerLeaseCleanupErrors -join ' '))
    [IO.Directory]::Move(
        $testerLeaseProbeDirectory,
        $testerLeaseProbeRenamed
    )
    [IO.Directory]::Move(
        $testerLeaseProbeRenamed,
        $testerLeaseProbeDirectory
    )
    Remove-Item -LiteralPath $testerLeaseProbeDirectory -Recurse -Force

    $testerFileProbe = Join-Path $testRoot 'tester-file-lease-probe.log'
    $testerFileProbeRenamed = Join-Path $testRoot 'tester-file-lease-probe-renamed.log'
    [IO.File]::WriteAllText(
        $testerFileProbe,
        'probe',
        [Text.Encoding]::ASCII
    )
    $testerFileLease = [Mql5Coding.JobProcessLaunch]::OpenFileLeafLease(
        $testerFileProbe
    )
    $testerFileLeaseBlockedRename = $false
    try {
        try {
            [IO.File]::Move($testerFileProbe, $testerFileProbeRenamed)
        }
        catch {
            $testerFileLeaseBlockedRename = $true
        }
        Assert-True -Condition $testerFileLeaseBlockedRename `
            -Message 'A held tester file-entry lease allowed its file to be renamed.'
    }
    finally {
        $testerFileLease.Dispose()
    }
    [IO.File]::Move($testerFileProbe, $testerFileProbeRenamed)
    [IO.File]::Move($testerFileProbeRenamed, $testerFileProbe)
    Remove-Item -LiteralPath $testerFileProbe -Force

    $retainedArtifactDefinitions = New-Object 'System.Collections.Generic.List[string]'
    foreach ($retainedFunctionName in @(
            'ConvertTo-Hex',
            'Get-StreamSha256',
            'ConvertTo-NormalizedDirectoryPath',
            'Test-IsAbsoluteLocalDrivePath',
            'Assert-StableFixedLocalVolumePath',
            'Open-NonReparseDirectoryChain',
            'Open-NonReparseFileLeaf',
            'Open-NewTextArtifactReadLock'
        )) {
        $retainedFunctionNode = $runnerAst.Find(
            {
                param($node)
                return (
                    $node -is [Management.Automation.Language.FunctionDefinitionAst] -and
                    $node.Name -eq $retainedFunctionName
                )
            },
            $true
        )
        Assert-True -Condition ($null -ne $retainedFunctionNode) -Message "Retained-artifact dependency was not found: $retainedFunctionName"
        $retainedArtifactDefinitions.Add($retainedFunctionNode.Extent.Text)
    }
    $retainedArtifactProbePath = Join-Path $testRoot 'retained-artifact-probe.txt'
    $retainedArtifactProbe = & {
        param($DefinitionTexts, $ProbePath)
        foreach ($definitionText in $DefinitionTexts) {
            . ([scriptblock]::Create($definitionText))
        }
        $script:fixedLocalVolumeIdentities = @{}
        $integrityLocks = New-Object 'System.Collections.Generic.List[object]'
        $pathLeases = New-Object 'System.Collections.Generic.List[object]'
        $leasesByPath = @{}
        try {
            $record = Open-NewTextArtifactReadLock -Text 'retained artifact' -Path $ProbePath -Encoding (New-Object Text.UTF8Encoding($false)) -Kind 'retained artifact probe' -Tracker $integrityLocks -PathEntryLeases $pathLeases -LeasesByPath $leasesByPath
            $overwriteBlocked = $false
            try {
                [IO.File]::WriteAllText(
                    $ProbePath,
                    'replacement',
                    [Text.Encoding]::UTF8
                )
            }
            catch {
                $overwriteBlocked = $true
            }
            return [pscustomobject]@{
                overwrite_blocked = $overwriteBlocked
                integrity_lock_count = $integrityLocks.Count
                path_lease_count = $pathLeases.Count
                byte_length = [long]$record.byte_length
                sha256 = [string]$record.sha256
            }
        }
        finally {
            for ($index = $integrityLocks.Count - 1; $index -ge 0; $index--) {
                $integrityLocks[$index].stream.Dispose()
            }
            for ($index = $pathLeases.Count - 1; $index -ge 0; $index--) {
                $pathLeases[$index].Dispose()
            }
        }
    } ($retainedArtifactDefinitions.ToArray()) $retainedArtifactProbePath
    Assert-True -Condition (
        [bool]$retainedArtifactProbe.overwrite_blocked -and
        [int]$retainedArtifactProbe.integrity_lock_count -eq 1 -and
        [int]$retainedArtifactProbe.path_lease_count -gt 0 -and
        [long]$retainedArtifactProbe.byte_length -gt 0 -and
        [string]$retainedArtifactProbe.sha256 -cmatch '\A[0-9a-f]{64}\z'
    ) -Message 'A newly generated text artifact was not identity-correlated and retained under a write-denying read lock.'
    [IO.File]::WriteAllText(
        $retainedArtifactProbePath,
        'write after release',
        [Text.Encoding]::UTF8
    )
    Remove-Item -LiteralPath $retainedArtifactProbePath -Force
    $mutableReportProbe = Join-Path $testRoot 'mutable-report-reservation.htm'
    $mutableReportLease = [Mql5Coding.JobProcessLaunch]::CreateMutableOutputFileLease(
        $mutableReportProbe
    )
    $mutableReportRename = $mutableReportProbe + '.renamed'
    $mutableReportBlockedRename = $false
    try {
        [IO.File]::WriteAllText(
            $mutableReportProbe,
            'generated report bytes',
            [Text.Encoding]::ASCII
        )
        try {
            [IO.File]::Move($mutableReportProbe, $mutableReportRename)
        }
        catch {
            $mutableReportBlockedRename = $true
        }
        Assert-True -Condition $mutableReportBlockedRename `
            -Message 'A mutable report reservation allowed pathname replacement.'
        Assert-True -Condition (
            [Mql5Coding.JobProcessLaunch]::GetNonReparseGuardFileIdentity($mutableReportProbe) -ceq
                [string]$mutableReportLease.Identity
        ) -Message 'Mutable report writes escaped the reserved file identity.'
    }
    finally {
        $mutableReportLease.Dispose()
    }
    Remove-Item -LiteralPath $mutableReportProbe -Force

    $pinnedOutputProbe = Join-Path $testRoot 'pinned-output-report.htm'
    $pinnedOutputStream = [Mql5Coding.JobProcessLaunch]::CreatePinnedOutputFileStream(
        $pinnedOutputProbe
    )
    $pinnedOutputBlockedWrite = $false
    $pinnedOutputBlockedRename = $false
    try {
        $pinnedBytes = [Text.Encoding]::ASCII.GetBytes('published report bytes')
        $pinnedOutputStream.Write($pinnedBytes, 0, $pinnedBytes.Length)
        $pinnedOutputStream.Flush($true)
        try {
            [IO.File]::WriteAllText(
                $pinnedOutputProbe,
                'replacement',
                [Text.Encoding]::ASCII
            )
        }
        catch {
            $pinnedOutputBlockedWrite = $true
        }
        try {
            [IO.File]::Move($pinnedOutputProbe, ($pinnedOutputProbe + '.renamed'))
        }
        catch {
            $pinnedOutputBlockedRename = $true
        }
        Assert-True -Condition (
            $pinnedOutputBlockedWrite -and $pinnedOutputBlockedRename
        ) -Message 'A pinned output creation stream allowed write or rename races.'
    }
    finally {
        $pinnedOutputStream.Dispose()
    }
    Remove-Item -LiteralPath $pinnedOutputProbe -Force

    $backupNameProbe = Join-Path $compileDirectory 'a.log'
    [IO.File]::WriteAllText($backupNameProbe, 'probe', [Text.Encoding]::ASCII)
    $boundedBackupPath = & {
        param($HelperDefinitionText, $DefinitionText, $ProbePath)
        . ([scriptblock]::Create($HelperDefinitionText))
        . ([scriptblock]::Create($DefinitionText))
        $probeLease = [Mql5Coding.CompilerProcessJob]::TryOpenMovableOutputFileIdentityLease(
            $ProbePath
        )
        try {
            return Move-OriginalLogAside -LiteralPath $ProbePath -Lease $probeLease
        }
        finally {
            if ($null -ne $probeLease) {
                $probeLease.Dispose()
            }
        }
    } $moveLeasedOutputDefinitionText $moveLogDefinitionText $backupNameProbe
    Assert-True -Condition (
        [IO.Path]::GetFileName([string]$boundedBackupPath).Length -le
            [IO.Path]::GetFileName($backupNameProbe).Length
    ) -Message 'The adjacent log backup can lengthen a valid near-limit path.'
    [IO.File]::Move([string]$boundedBackupPath, $backupNameProbe)
    Remove-Item -LiteralPath $backupNameProbe -Force

    $unsafeGeneratedLog = Join-Path $compileDirectory 'unsafe-generated.log'
    $unsafePreservedLog = Join-Path $compileDirectory 'unsafe-preserved.tmp'
    [IO.File]::WriteAllText($unsafeGeneratedLog, 'generated', [Text.Encoding]::ASCII)
    [IO.File]::WriteAllText($unsafePreservedLog, 'preserved', [Text.Encoding]::ASCII)
    $unsafeGeneratedHash = (Get-FileHash -LiteralPath $unsafeGeneratedLog -Algorithm SHA256).Hash
    $unsafePreservedHash = (Get-FileHash -LiteralPath $unsafePreservedLog -Algorithm SHA256).Hash
    $unsafeRestoreError = $null
    try {
        & {
            param($DefinitionText, $LogPath, $BackupPath)
            . ([scriptblock]::Create($DefinitionText))
            Complete-LeasedCompilerOutput `
                -LiteralPath $LogPath `
                -Description 'compilation log' `
                -ProcessTreeEmpty $false `
                -AcceptGenerated $false `
                -OriginalMovableLease $null `
                -OriginalPinnedLease $null `
                -OriginalBackupPath $BackupPath `
                -GeneratedMovableLease $null `
                -GeneratedPinnedLease $null
        } $completeLogDefinitionText $unsafeGeneratedLog $unsafePreservedLog
    }
    catch {
        $unsafeRestoreError = $_.Exception.Message
    }
    Assert-True -Condition (-not [string]::IsNullOrWhiteSpace($unsafeRestoreError)) `
        -Message 'Unverified process-tree cleanup did not block log restoration.'
    Assert-True -Condition ($unsafeRestoreError.Contains($unsafePreservedLog)) `
        -Message 'Unsafe log restoration failure did not report the preserved backup path.'
    Assert-True -Condition (
        (Get-FileHash -LiteralPath $unsafeGeneratedLog -Algorithm SHA256).Hash -eq
            $unsafeGeneratedHash -and
        (Get-FileHash -LiteralPath $unsafePreservedLog -Algorithm SHA256).Hash -eq
            $unsafePreservedHash
    ) -Message 'Unsafe cleanup modified a generated log or its preserved original.'
    Remove-Item -LiteralPath $unsafeGeneratedLog, $unsafePreservedLog -Force

    $untrackedGeneratedLog = Join-Path $compileDirectory 'untracked-generated.log'
    $untrackedPreservedLog = Join-Path $compileDirectory 'untracked-preserved.tmp'
    [IO.File]::WriteAllText($untrackedGeneratedLog, 'untracked', [Text.Encoding]::ASCII)
    [IO.File]::WriteAllText($untrackedPreservedLog, 'preserved', [Text.Encoding]::ASCII)
    $untrackedGeneratedHash = (
        Get-FileHash -LiteralPath $untrackedGeneratedLog -Algorithm SHA256
    ).Hash
    $untrackedPreservedHash = (
        Get-FileHash -LiteralPath $untrackedPreservedLog -Algorithm SHA256
    ).Hash
    $untrackedCleanupError = $null
    try {
        & {
            param($DefinitionText, $LogPath, $BackupPath)
            . ([scriptblock]::Create($DefinitionText))
            Complete-LeasedCompilerOutput `
                -LiteralPath $LogPath `
                -Description 'compilation log' `
                -ProcessTreeEmpty $true `
                -AcceptGenerated $false `
                -OriginalMovableLease $null `
                -OriginalPinnedLease $null `
                -OriginalBackupPath $BackupPath `
                -GeneratedMovableLease $null `
                -GeneratedPinnedLease $null
        } $completeLogDefinitionText $untrackedGeneratedLog $untrackedPreservedLog
    }
    catch {
        $untrackedCleanupError = $_.Exception.Message
    }
    Assert-True -Condition (
        $untrackedCleanupError -match 'Refusing to remove an untracked file'
    ) -Message 'Cleanup deleted or accepted a compiler output without a retained identity lease.'
    Assert-True -Condition (
        (Get-FileHash -LiteralPath $untrackedGeneratedLog -Algorithm SHA256).Hash -eq
            $untrackedGeneratedHash -and
        (Get-FileHash -LiteralPath $untrackedPreservedLog -Algorithm SHA256).Hash -eq
            $untrackedPreservedHash
    ) -Message 'Untracked-output cleanup modified the current file or preserved backup.'
    Remove-Item -LiteralPath $untrackedGeneratedLog, $untrackedPreservedLog -Force

    $unverifiedLaunchError = [InvalidOperationException]::new('unverified launch')
    $unverifiedLaunchError.Data['Mql5Coding.CleanupVerified'] = $false
    $wrappedLaunchError = [Exception]::new('wrapper', $unverifiedLaunchError)
    $unverifiedLaunchAccepted = & {
        param($DefinitionText, $ErrorObject)
        . ([scriptblock]::Create($DefinitionText))
        Test-CompilerLaunchCleanupVerified -Exception $ErrorObject
    } $launchCleanupDefinitionText $wrappedLaunchError
    Assert-True -Condition (-not $unverifiedLaunchAccepted) `
        -Message 'An unverified native launch failure was treated as safe for log restoration.'

    $verifiedLaunchError = [InvalidOperationException]::new('verified launch')
    $verifiedLaunchError.Data['Mql5Coding.CleanupVerified'] = $true
    $verifiedLaunchAccepted = & {
        param($DefinitionText, $ErrorObject)
        . ([scriptblock]::Create($DefinitionText))
        Test-CompilerLaunchCleanupVerified -Exception $ErrorObject
    } $launchCleanupDefinitionText $verifiedLaunchError
    Assert-True -Condition ([bool]$verifiedLaunchAccepted) `
        -Message 'A verified no-process launch failure was not recognized.'

    $compileSource = Join-Path $compileDirectory 'fixture.mq5'
    [IO.File]::WriteAllText(
        $compileSource,
        '// Synthetic source: never passed to real MetaEditor.',
        (New-Object Text.UTF8Encoding($false))
    )
    $compileArtifact = [IO.Path]::ChangeExtension($compileSource, '.ex5')
    $compileLog = [IO.Path]::ChangeExtension($compileSource, '.log')
    $sentinelLogBytes = [Text.Encoding]::UTF8.GetBytes("pre-existing sentinel log`r`n")
    [IO.File]::WriteAllBytes($compileLog, $sentinelLogBytes)
    [IO.File]::SetLastWriteTimeUtc($compileLog, [datetime]::UtcNow.AddDays(-1))
    $sentinelLogHash = (Get-FileHash -LiteralPath $compileLog -Algorithm SHA256).Hash
    $sentinelLogLastWriteUtc = (Get-Item -LiteralPath $compileLog).LastWriteTimeUtc
    $compileLogMirror = Join-Path $compileDirectory 'fixture-log-mirror.log'
    $null = New-Item -ItemType HardLink -Path $compileLogMirror -Target $compileLog
    $sentinelLogIdentity = [Mql5Coding.CompilerProcessJob]::GetFileIdentity($compileLog)

    $artifactHardlinkSentinel = Join-Path $compileDirectory 'artifact-hardlink-sentinel.bin'
    [IO.File]::WriteAllText(
        $artifactHardlinkSentinel,
        'pre-existing artifact sentinel',
        [Text.Encoding]::ASCII
    )
    $null = New-Item -ItemType HardLink -Path $compileArtifact -Target $artifactHardlinkSentinel
    $artifactHardlinkIdentity = [Mql5Coding.CompilerProcessJob]::GetFileIdentity(
        $artifactHardlinkSentinel
    )
    $artifactHardlinkHash = (
        Get-FileHash -LiteralPath $artifactHardlinkSentinel -Algorithm SHA256
    ).Hash

    $compileSuccess = Invoke-CompilerCase `
        -SourcePath $compileSource `
        -MetaEditorPath $metaEditor `
        -FakeMode 'success'
    Assert-True -Condition ($compileSuccess.ExitCode -eq 0) `
        -Message "Synthetic compiler success exit code was $($compileSuccess.ExitCode): $($compileSuccess.StandardError)"
    Assert-True -Condition ($compileSuccess.StandardOutput -match 'status=success errors=0 warnings=0 exit_code=0') `
        -Message 'Synthetic compiler success summary was missing or inaccurate.'
    Assert-True -Condition ($compileSuccess.StandardOutput -match 'MQL5_COMPILE_ARTIFACT=') `
        -Message 'Successful real compilation did not report its artifact.'

    Assert-True -Condition (
        [Mql5Coding.CompilerProcessJob]::GetFileIdentity($artifactHardlinkSentinel) -ceq
            $artifactHardlinkIdentity -and
        (Get-FileHash -LiteralPath $artifactHardlinkSentinel -Algorithm SHA256).Hash -eq
            $artifactHardlinkHash -and
        [Mql5Coding.CompilerProcessJob]::GetFileIdentity($compileArtifact) -cne
            $artifactHardlinkIdentity
    ) -Message 'Successful compilation modified the target of a pre-existing artifact hard link.'

    $sourceLink = Join-Path $compileDirectory 'fixture-source-link.mq5'
    $sourceLinkCreated = $false
    try {
        $null = New-Item `
            -ItemType SymbolicLink `
            -Path $sourceLink `
            -Target $compileSource `
            -ErrorAction Stop
        $sourceLinkCreated = $true
    }
    catch {
        $sourceLinkCreated = $false
    }
    if ($sourceLinkCreated) {
        try {
            $sourceLinkBlocked = Invoke-CompilerCase `
                -SourcePath $sourceLink `
                -MetaEditorPath $metaEditor `
                -FakeMode 'success' `
                -SyntaxOnly
            Assert-True -Condition ($sourceLinkBlocked.ExitCode -eq 2) `
                -Message 'A source-file symbolic link was not rejected.'
            Assert-True -Condition (
                $sourceLinkBlocked.StandardError -match '(?i)reparse'
            ) -Message 'Source-file symbolic-link rejection did not explain the reparse-point block.'
        }
        finally {
            if (Test-Path -LiteralPath $sourceLink) {
                Remove-Item -LiteralPath $sourceLink -Force
            }
        }
    }

    $artifactLinkTarget = Join-Path $compileDirectory 'artifact-link-target.bin'
    [IO.File]::WriteAllText(
        $artifactLinkTarget,
        'artifact target sentinel',
        [Text.Encoding]::ASCII
    )
    $artifactLinkTargetHash = (
        Get-FileHash -LiteralPath $artifactLinkTarget -Algorithm SHA256
    ).Hash
    if (Test-Path -LiteralPath $compileArtifact -PathType Leaf) {
        Remove-Item -LiteralPath $compileArtifact -Force
    }
    $artifactLinkCreated = $false
    try {
        $null = New-Item `
            -ItemType SymbolicLink `
            -Path $compileArtifact `
            -Target $artifactLinkTarget `
            -ErrorAction Stop
        $artifactLinkCreated = $true
    }
    catch {
        $artifactLinkCreated = $false
    }
    if ($artifactLinkCreated) {
        try {
            $artifactLinkBlocked = Invoke-CompilerCase `
                -SourcePath $compileSource `
                -MetaEditorPath $metaEditor `
                -FakeMode 'success'
            Assert-True -Condition ($artifactLinkBlocked.ExitCode -eq 2) `
                -Message 'A planted compiler artifact symlink was not blocked.'
            Assert-True -Condition (
                $artifactLinkBlocked.StandardError -match '(?i)reparse' -and
                (Get-FileHash -LiteralPath $artifactLinkTarget -Algorithm SHA256).Hash -eq
                    $artifactLinkTargetHash
            ) -Message 'Artifact-symlink rejection touched its target or omitted its diagnosis.'
        }
        finally {
            if (Test-Path -LiteralPath $compileArtifact) {
                Remove-Item -LiteralPath $compileArtifact -Force
            }
        }
    }

    $logLinkSource = Join-Path $compileDirectory 'log-link-fixture.mq5'
    $logLinkPath = [IO.Path]::ChangeExtension($logLinkSource, '.log')
    $logLinkTarget = Join-Path $compileDirectory 'log-link-target.txt'
    [IO.File]::WriteAllText($logLinkSource, '// log link probe', [Text.Encoding]::ASCII)
    [IO.File]::WriteAllText($logLinkTarget, 'log target sentinel', [Text.Encoding]::ASCII)
    $logLinkTargetHash = (Get-FileHash -LiteralPath $logLinkTarget -Algorithm SHA256).Hash
    $logLinkCreated = $false
    try {
        $null = New-Item `
            -ItemType SymbolicLink `
            -Path $logLinkPath `
            -Target $logLinkTarget `
            -ErrorAction Stop
        $logLinkCreated = $true
    }
    catch {
        $logLinkCreated = $false
    }
    if ($logLinkCreated) {
        try {
            $logLinkBlocked = Invoke-CompilerCase `
                -SourcePath $logLinkSource `
                -MetaEditorPath $metaEditor `
                -FakeMode 'success' `
                -SyntaxOnly
            Assert-True -Condition ($logLinkBlocked.ExitCode -eq 2) `
                -Message 'A planted compiler log symlink was not blocked.'
            Assert-True -Condition (
                $logLinkBlocked.StandardError -match '(?i)reparse' -and
                (Get-FileHash -LiteralPath $logLinkTarget -Algorithm SHA256).Hash -eq
                    $logLinkTargetHash
            ) -Message 'Log-symlink rejection touched its target or omitted its diagnosis.'
        }
        finally {
            if (Test-Path -LiteralPath $logLinkPath) {
                Remove-Item -LiteralPath $logLinkPath -Force
            }
        }
    }

    Assert-True -Condition (
        [Mql5Coding.CompilerProcessJob]::GetFileIdentity($compileLog) -ceq $sentinelLogIdentity -and
        [Mql5Coding.CompilerProcessJob]::GetFileIdentity($compileLogMirror) -ceq $sentinelLogIdentity
    ) -Message 'Compiler wrapper replaced the pre-existing log file object instead of restoring it.'

    $invalidMetaEditorDirectory = Join-Path $testRoot 'invalid-editor'
    [IO.Directory]::CreateDirectory($invalidMetaEditorDirectory) | Out-Null
    $invalidMetaEditor = Join-Path $invalidMetaEditorDirectory 'metaeditor64.exe'
    [IO.File]::WriteAllText(
        $invalidMetaEditor,
        'not a Windows executable',
        [Text.Encoding]::ASCII
    )
    $launchFailure = Invoke-CompilerCase `
        -SourcePath $compileSource `
        -MetaEditorPath $invalidMetaEditor `
        -FakeMode 'success'
    Assert-True -Condition ($launchFailure.ExitCode -eq 2) `
        -Message 'Invalid compiler launch did not produce a tooling failure.'
    Assert-True -Condition (
        [Mql5Coding.CompilerProcessJob]::GetFileIdentity($compileLog) -ceq
            $sentinelLogIdentity
    ) -Message 'Verified pre-process launch failure did not restore the original log.'

    $delayedCompletion = Invoke-CompilerCase `
        -SourcePath $compileSource `
        -MetaEditorPath $metaEditor `
        -FakeMode 'delayed_completion'
    Assert-True -Condition ($delayedCompletion.ExitCode -eq 0) `
        -Message "Delayed compiler completion exit code was $($delayedCompletion.ExitCode): $($delayedCompletion.StandardError)"
    Assert-True -Condition (
        [IO.File]::ReadAllText($compileArtifact, [Text.Encoding]::ASCII) -ceq 'synthetic ex5 complete'
    ) -Message 'Compiler wrapper accepted or terminated a partially written artifact.'
    Assert-True -Condition (
        (Get-FileHash -LiteralPath $compileLog -Algorithm SHA256).Hash -eq $sentinelLogHash
    ) -Message 'Compiler wrapper did not restore the original log after delayed completion.'

    $artifactBeforeErrorIdentity = [Mql5Coding.CompilerProcessJob]::GetFileIdentity(
        $compileArtifact
    )
    $artifactBeforeErrorHash = (
        Get-FileHash -LiteralPath $compileArtifact -Algorithm SHA256
    ).Hash
    $compileError = Invoke-CompilerCase `
        -SourcePath $compileSource `
        -MetaEditorPath $metaEditor `
        -FakeMode 'errors'
    Assert-True -Condition ($compileError.ExitCode -eq 1) `
        -Message "Synthetic compiler error exit code was $($compileError.ExitCode)."
    Assert-True -Condition ($compileError.StandardOutput -notmatch 'MQL5_COMPILE_ARTIFACT=') `
        -Message 'Compilation error incorrectly reported a stale artifact.'

    Assert-True -Condition (
        [Mql5Coding.CompilerProcessJob]::GetFileIdentity($compileArtifact) -ceq
            $artifactBeforeErrorIdentity -and
        (Get-FileHash -LiteralPath $compileArtifact -Algorithm SHA256).Hash -eq
            $artifactBeforeErrorHash
    ) -Message 'Failed compilation did not restore the exact pre-existing artifact object.'

    $warningsAsErrors = Invoke-CompilerCase `
        -SourcePath $compileSource `
        -MetaEditorPath $metaEditor `
        -FakeMode 'warnings' `
        -WarningsAsErrors
    Assert-True -Condition ($warningsAsErrors.ExitCode -eq 4) `
        -Message "Synthetic warnings-as-errors exit code was $($warningsAsErrors.ExitCode)."
    Assert-True -Condition ($warningsAsErrors.StandardOutput -notmatch 'MQL5_COMPILE_ARTIFACT=') `
        -Message 'Warnings-as-errors incorrectly reported an artifact.'

    Remove-Item -LiteralPath $compileArtifact -Force
    $missingArtifact = Invoke-CompilerCase `
        -SourcePath $compileSource `
        -MetaEditorPath $metaEditor `
        -FakeMode 'no_artifact'
    Assert-True -Condition ($missingArtifact.ExitCode -eq 2) `
        -Message "Synthetic missing-artifact exit code was $($missingArtifact.ExitCode)."
    Assert-True -Condition ($missingArtifact.StandardOutput -notmatch 'MQL5_COMPILE_ARTIFACT=') `
        -Message 'Missing-artifact failure incorrectly reported an artifact.'

    [IO.File]::WriteAllBytes(
        $compileArtifact,
        [Text.Encoding]::ASCII.GetBytes('future-dated ex5')
    )
    [IO.File]::SetLastWriteTimeUtc(
        $compileArtifact,
        [datetime]::UtcNow.AddHours(1)
    )
    $futureDatedArtifact = Invoke-CompilerCase `
        -SourcePath $compileSource `
        -MetaEditorPath $metaEditor `
        -FakeMode 'success'
    Assert-True -Condition ($futureDatedArtifact.ExitCode -eq 0) `
        -Message "Freshly replaced future-dated artifact was rejected with exit code $($futureDatedArtifact.ExitCode)."
    Assert-True -Condition ($futureDatedArtifact.StandardOutput -match 'MQL5_COMPILE_ARTIFACT=') `
        -Message 'Freshly replaced future-dated artifact was not reported.'

    [IO.File]::WriteAllBytes($compileArtifact, [Text.Encoding]::ASCII.GetBytes('stale ex5'))
    [IO.File]::SetLastWriteTimeUtc($compileArtifact, [datetime]::UtcNow.AddMinutes(-10))
    $staleArtifact = Invoke-CompilerCase `
        -SourcePath $compileSource `
        -MetaEditorPath $metaEditor `
        -FakeMode 'stale_artifact'
    Assert-True -Condition ($staleArtifact.ExitCode -eq 2) `
        -Message "Synthetic stale-artifact exit code was $($staleArtifact.ExitCode)."
    Assert-True -Condition ($staleArtifact.StandardOutput -notmatch 'MQL5_COMPILE_ARTIFACT=') `
        -Message 'Stale-artifact failure incorrectly reported an artifact.'

    $syntaxOnly = Invoke-CompilerCase `
        -SourcePath $compileSource `
        -MetaEditorPath $metaEditor `
        -FakeMode 'success' `
        -SyntaxOnly
    Assert-True -Condition ($syntaxOnly.ExitCode -eq 0) `
        -Message "Synthetic syntax-only exit code was $($syntaxOnly.ExitCode)."

    $argumentsPath = Join-Path $testRoot 'fake-metaeditor-arguments.txt'
    $rootInclude = [IO.Path]::GetPathRoot($testRoot)
    $rootIncludeCase = Invoke-CompilerCase `
        -SourcePath $compileSource `
        -MetaEditorPath $metaEditor `
        -FakeMode 'success' `
        -IncludePath $rootInclude `
        -ArgumentsPath $argumentsPath `
        -SyntaxOnly
    Assert-True -Condition ($rootIncludeCase.ExitCode -eq 0) `
        -Message "Root include-path compile exit code was $($rootIncludeCase.ExitCode)."
    $receivedCompilerArguments = @([IO.File]::ReadAllLines($argumentsPath))
    Assert-True -Condition ($receivedCompilerArguments -ccontains "/include:$rootInclude") `
        -Message 'A root include path ending in a backslash was not delivered as one exact argument.'
    Assert-True -Condition ($receivedCompilerArguments -ccontains '/s') `
        -Message 'The syntax-only switch was swallowed by include-path command-line quoting.'

    $earlyExit = Invoke-CompilerCase `
        -SourcePath $compileSource `
        -MetaEditorPath $metaEditor `
        -FakeMode 'exit_without_result'
    Assert-True -Condition ($earlyExit.ExitCode -eq 2) `
        -Message "A compiler that exited without Result was classified as exit code $($earlyExit.ExitCode)."
    Assert-True -Condition ($earlyExit.StandardError -match 'exited without producing a complete Result line') `
        -Message 'Early compiler exit did not report the missing Result line.'
    Assert-True -Condition ($earlyExit.StandardOutput -notmatch 'MQL5_COMPILE_ARTIFACT=') `
        -Message 'Early compiler exit incorrectly reported an artifact.'

    $logicalMql5Root = Join-Path $testRoot 'logical-terminal\MQL5'
    [IO.Directory]::CreateDirectory(
        (Join-Path $logicalMql5Root 'Experts')
    ) | Out-Null
    $compileAliasDirectory = Join-Path $logicalMql5Root 'Experts\compile-junction'
    $null = New-Item -ItemType Junction -Path $compileAliasDirectory -Target $compileDirectory
    try {
        $compileAliasLease = [Mql5Coding.CompilerProcessJob]::OpenDirectoryIdentityLease(
            $compileAliasDirectory
        )
        try {
            Assert-True -Condition (
                [IO.Path]::GetFullPath($compileAliasLease.FinalPath).Equals(
                    [IO.Path]::GetFullPath($compileDirectory),
                    [StringComparison]::OrdinalIgnoreCase
                )
            ) -Message 'Compiler directory lease did not expose the junction target path.'

            $compileRetargetDirectory = Join-Path $testRoot 'compile-retarget'
            [IO.Directory]::CreateDirectory($compileRetargetDirectory) | Out-Null
            [IO.Directory]::Delete($compileAliasDirectory)
            $null = New-Item -ItemType Junction -Path $compileAliasDirectory -Target $compileRetargetDirectory
            $leasedTargetIdentity = $compileAliasLease.GetCurrentIdentity()
            Assert-True -Condition (
                $leasedTargetIdentity -ceq
                    [Mql5Coding.CompilerProcessJob]::GetDirectoryIdentity(
                        $compileDirectory
                    ) -and
                $leasedTargetIdentity -cne
                    [Mql5Coding.CompilerProcessJob]::GetDirectoryIdentity(
                        $compileRetargetDirectory
                    )
            ) -Message 'Retargeting a junction changed the directory object held by the compiler lease.'
            [IO.Directory]::Delete($compileAliasDirectory)
            $null = New-Item -ItemType Junction -Path $compileAliasDirectory -Target $compileDirectory
            Remove-Item -LiteralPath $compileRetargetDirectory -Force
        }
        finally {
            $compileAliasLease.Dispose()
        }

        $compileAliasSource = Join-Path $compileAliasDirectory 'fixture.mq5'
        $aliasIdentity = [Mql5Coding.CompilerProcessJob]::GetFileIdentity($compileAliasSource)
        $sourceIdentityBeforeReplace = [Mql5Coding.CompilerProcessJob]::GetFileIdentity(
            $compileSource
        )
        Assert-True -Condition ($aliasIdentity -ceq $sourceIdentityBeforeReplace) `
            -Message 'Junction alias did not resolve to the source file identity.'

        $directoryIdentity = [Mql5Coding.CompilerProcessJob]::GetDirectoryIdentity(
            $compileDirectory
        )
        $outputNamespace = (
            $directoryIdentity + '|' +
            [IO.Path]::GetFileName($compileLog).ToUpperInvariant()
        )
        $identityBytes = [Text.Encoding]::UTF8.GetBytes($outputNamespace)
        $identityAlgorithm = [Security.Cryptography.SHA256]::Create()
        try {
            $outputHash = [BitConverter]::ToString(
                $identityAlgorithm.ComputeHash($identityBytes)
            ).Replace('-', '').Substring(0, 24)
        }
        finally {
            $identityAlgorithm.Dispose()
        }

        $heldCompilerMutex = [Threading.Mutex]::new(
            $false,
            "Global\CodexMqlCompile_$outputHash"
        )
        $heldCompilerMutexAcquired = $false
        $replacedSourceBackup = Join-Path $compileDirectory 'fixture-before-replace.mq5'
        try {
            $heldCompilerMutexAcquired = $heldCompilerMutex.WaitOne(0)
            Assert-True -Condition $heldCompilerMutexAcquired `
                -Message 'Could not acquire the compiler-output regression mutex.'

            $replacementSource = Join-Path $compileDirectory 'fixture-replacement.tmp'
            [IO.File]::WriteAllText(
                $replacementSource,
                '// Atomically replaced synthetic source.',
                (New-Object Text.UTF8Encoding($false))
            )
            [IO.File]::Replace(
                $replacementSource,
                $compileSource,
                $replacedSourceBackup
            )
            Assert-True -Condition (
                [Mql5Coding.CompilerProcessJob]::GetFileIdentity($compileSource) -cne
                    $sourceIdentityBeforeReplace
            ) -Message 'Atomic source replacement did not change the source file identity.'

            $aliasBlocked = Invoke-CompilerCase `
                -SourcePath $compileAliasSource `
                -MetaEditorPath $metaEditor `
                -FakeMode 'success' `
                -TimeoutSeconds 5 `
                -SyntaxOnly
            Assert-True -Condition ($aliasBlocked.ExitCode -eq 2) `
                -Message 'A source replacement or junction alias bypassed the output compilation mutex.'
            Assert-True -Condition ($aliasBlocked.StandardError -match 'Another compilation is already using') `
                -Message 'Output mutex contention did not report the competing compilation.'
        }
        finally {
            if ($heldCompilerMutexAcquired) {
                $heldCompilerMutex.ReleaseMutex()
            }
            $heldCompilerMutex.Dispose()
            if (Test-Path -LiteralPath $replacedSourceBackup -PathType Leaf) {
                Remove-Item -LiteralPath $replacedSourceBackup -Force
            }
        }

        $aliasArgumentsPath = Join-Path $testRoot 'fake-metaeditor-alias-arguments.txt'
        $aliasCanonical = Invoke-CompilerCase `
            -SourcePath $compileAliasSource `
            -MetaEditorPath $metaEditor `
            -FakeMode 'success' `
            -ArgumentsPath $aliasArgumentsPath `
            -SyntaxOnly
        Assert-True -Condition ($aliasCanonical.ExitCode -eq 0) `
            -Message "Canonical junction compile failed with exit code $($aliasCanonical.ExitCode)."
        $aliasCompilerArguments = @([IO.File]::ReadAllLines($aliasArgumentsPath))
        Assert-True -Condition (
            $aliasCompilerArguments -contains "/compile:$compileSource" -and
            $aliasCompilerArguments -notcontains "/compile:$compileAliasSource"
        ) -Message 'Compiler did not pass its pinned canonical source path to MetaEditor.'
        Assert-True -Condition (
            $aliasCompilerArguments -contains "/include:$logicalMql5Root"
        ) -Message 'Canonical source pinning lost the logical MQL5 include root.'
    }
    finally {
        if (Test-Path -LiteralPath $compileAliasDirectory) {
            [IO.Directory]::Delete($compileAliasDirectory)
        }
    }

    $compilerChildPidPath = Join-Path $testRoot 'fake-metaeditor-child.pid'
    $compileTimeout = Invoke-CompilerCase `
        -SourcePath $compileSource `
        -MetaEditorPath $metaEditor `
        -FakeMode 'timeout_detached' `
        -ChildPidPath $compilerChildPidPath
    Assert-True -Condition ($compileTimeout.ExitCode -eq 3) `
        -Message "Synthetic compiler timeout exit code was $($compileTimeout.ExitCode)."
    Assert-True -Condition ($compileTimeout.StandardOutput -notmatch 'MQL5_COMPILE_ARTIFACT=') `
        -Message 'Compilation timeout incorrectly reported an artifact.'
    Assert-True -Condition (Test-Path -LiteralPath $compilerChildPidPath -PathType Leaf) `
        -Message 'Synthetic MetaEditor timeout fixture did not record its child PID.'
    $compilerChildPid = [int][IO.File]::ReadAllText($compilerChildPidPath)
    $compilerChildAlive = $false
    try {
        $compilerChildAlive = -not (Get-Process -Id $compilerChildPid -ErrorAction Stop).HasExited
    }
    catch {
        $compilerChildAlive = $false
    }
    Assert-True -Condition (-not $compilerChildAlive) `
        -Message "Synthetic MetaEditor timeout left child process $compilerChildPid running."
    $matchingMetaEditors = @(Get-CimInstance Win32_Process | Where-Object {
            try {
                $_.ExecutablePath -and
                    ([IO.Path]::GetFullPath($_.ExecutablePath) -ieq [IO.Path]::GetFullPath($metaEditor))
            }
            catch {
                $false
            }
        })
    Assert-True -Condition ($matchingMetaEditors.Count -eq 0) `
        -Message 'Synthetic MetaEditor process remained after compilation timeout.'
    Assert-True -Condition (
        (Get-FileHash -LiteralPath $compileLog -Algorithm SHA256).Hash -eq $sentinelLogHash
    ) -Message 'Compiler wrapper did not restore the pre-existing log bytes.'
    Assert-True -Condition (
        (Get-Item -LiteralPath $compileLog).LastWriteTimeUtc -eq $sentinelLogLastWriteUtc
    ) -Message 'Compiler wrapper did not restore the pre-existing log timestamp.'

    $dataJunction = Join-Path $testRoot 'data-junction'
    $null = New-Item -ItemType Junction -Path $dataJunction -Target $dataPath
    try {
        $dataJunctionBlocked = Invoke-RunnerCase `
            -Name 'preflight-reparse-data-root' `
            -Mode 'PreflightOnly' `
            -TerminalPath $terminal `
            -TerminalDataPath $dataJunction `
            -ExpertPath $expert `
            -PresetPath $preset `
            -ExpertSha256 $expertHash
    }
    finally {
        if (Test-Path -LiteralPath $dataJunction) {
            [IO.Directory]::Delete($dataJunction)
        }
    }
    Assert-True -Condition ($dataJunctionBlocked.ExitCode -eq 4) `
        -Message 'A reparse-point terminal data root was not blocked.'
    Assert-True -Condition (
        $null -ne $dataJunctionBlocked.Result -and
        $dataJunctionBlocked.Result.status -eq 'blocked' -and
        -not [bool]$dataJunctionBlocked.Result.process.execution_attempted
    ) -Message 'Terminal data reparse rejection did not fail closed before launch.'

    $sourceJunction = Join-Path $testRoot 'source-junction'
    $null = New-Item -ItemType Junction -Path $sourceJunction -Target $testRoot
    try {
        $sourceJunctionBlocked = Invoke-RunnerCase `
            -Name 'preflight-reparse-source' `
            -Mode 'PreflightOnly' `
            -TerminalPath $terminal `
            -TerminalDataPath $dataPath `
            -ExpertPath (Join-Path $sourceJunction 'fixture.ex5') `
            -PresetPath (Join-Path $sourceJunction 'fixture.set') `
            -ExpertSha256 $expertHash
    }
    finally {
        if (Test-Path -LiteralPath $sourceJunction) {
            [IO.Directory]::Delete($sourceJunction)
        }
    }
    Assert-True -Condition ($sourceJunctionBlocked.ExitCode -eq 4) `
        -Message 'A reparse-point source path was not blocked.'
    Assert-True -Condition (
        $sourceJunctionBlocked.StandardError -match '(?i)reparse|unsafe or unleaseable'
    ) -Message 'Source reparse rejection did not explain the unsafe path.'

    $terminalLogsPath = Join-Path $dataPath 'logs'
    $terminalLogsReal = Join-Path $dataPath 'logs-real'
    [IO.Directory]::Move($terminalLogsPath, $terminalLogsReal)
    $null = New-Item -ItemType Junction -Path $terminalLogsPath -Target $terminalLogsReal
    try {
        $logJunctionBlocked = Invoke-RunnerCase `
            -Name 'preflight-reparse-log-root' `
            -Mode 'PreflightOnly' `
            -TerminalPath $terminal `
            -TerminalDataPath $dataPath `
            -ExpertPath $expert `
            -PresetPath $preset `
            -ExpertSha256 $expertHash
    }
    finally {
        if (Test-Path -LiteralPath $terminalLogsPath) {
            [IO.Directory]::Delete($terminalLogsPath)
        }
        [IO.Directory]::Move($terminalLogsReal, $terminalLogsPath)
    }
    Assert-True -Condition ($logJunctionBlocked.ExitCode -eq 4) `
        -Message 'A reparse-point terminal journal directory was not blocked.'
    Assert-True -Condition (
        $null -ne $logJunctionBlocked.Result -and
        $logJunctionBlocked.Result.status -eq 'blocked' -and
        -not [bool]$logJunctionBlocked.Result.process.execution_attempted
    ) -Message 'Journal-directory reparse rejection did not fail closed before launch.'

    $preflight = Invoke-RunnerCase `
        -Name 'preflight' `
        -Mode PreflightOnly `
        -TerminalPath $terminal `
        -TerminalDataPath $dataPath `
        -ExpertPath $expert `
        -PresetPath $preset `
        -ExpertSha256 $expertHash
    Assert-True -Condition ($preflight.ExitCode -eq 0) `
        -Message "Preflight exit code was $($preflight.ExitCode): $($preflight.StandardError)"
    Assert-True -Condition ($null -ne $preflight.Result) `
        -Message 'Preflight did not produce result JSON.'
    Assert-True -Condition ($preflight.Result.status -eq 'preflight_passed') `
        -Message "Unexpected preflight status: $($preflight.Result.status)"
    Assert-True -Condition (-not [bool]$preflight.Result.process.process_created) `
        -Message 'Preflight unexpectedly created a terminal process.'
    Assert-True -Condition (
        [bool]$preflight.Result.safety.direct_fixed_volume_mapping_required
    ) -Message 'Preflight did not report its direct fixed-volume requirement.'
    Assert-True -Condition (
        [bool]$preflight.Result.safety.mount_manager_drive_registration_required
    ) -Message 'Preflight did not report its mount-manager drive requirement.'
    Assert-True -Condition (
        [bool]$preflight.Result.safety.path_handle_volume_correlation
    ) -Message 'Preflight did not report its path-handle volume correlation.'
    Assert-True -Condition (
        [bool]$preflight.Result.safety.directory_data_write_sharing_denied
    ) -Message 'Preflight did not report its directory data-write share protection.'
    Assert-True -Condition (
        [bool]$preflight.Result.safety.directory_mutation_guards
    ) -Message 'Preflight did not report its pinned directory mutation guards.'
    Assert-True -Condition (-not [string]::IsNullOrWhiteSpace(
            [string]$preflight.Result.binding.terminal_image.file_identity
        )) -Message 'Preflight did not record the pinned terminal executable identity.'

    $aliasDirectory = Join-Path $testRoot 'install-alias'
    [IO.Directory]::CreateDirectory($aliasDirectory) | Out-Null
    $aliasTerminal = Join-Path $aliasDirectory 'terminal64.exe'
    $null = New-Item -ItemType HardLink -Path $aliasTerminal -Target $terminal
    $aliasConfig = Join-Path $dataPath 'alias-hold.ini'
    [IO.File]::WriteAllText(
        $aliasConfig,
        '',
        (New-Object Text.UnicodeEncoding($false, $true))
    )
    $aliasReady = Join-Path $dataPath 'alias-hold-ready'
    $aliasStartInfo = New-Object Diagnostics.ProcessStartInfo
    $aliasStartInfo.FileName = $aliasTerminal
    $aliasStartInfo.Arguments = Quote-NativeArgument -Value ("/config:$aliasConfig")
    $aliasStartInfo.UseShellExecute = $false
    $aliasStartInfo.CreateNoWindow = $true
    $aliasStartInfo.EnvironmentVariables['FAKE_MT5_MODE'] = 'hold'
    $aliasStartInfo.EnvironmentVariables['FAKE_MT5_READY_PATH'] = $aliasReady
    $aliasProcess = New-Object Diagnostics.Process
    $aliasProcess.StartInfo = $aliasStartInfo
    $aliasStarted = $false
    try {
        $null = $aliasProcess.Start()
        $aliasStarted = $true
        $aliasDeadline = [datetime]::UtcNow.AddSeconds(10)
        while (-not (Test-Path -LiteralPath $aliasReady -PathType Leaf) -and
            [datetime]::UtcNow -lt $aliasDeadline) {
            Start-Sleep -Milliseconds 25
        }
        Assert-True -Condition (Test-Path -LiteralPath $aliasReady -PathType Leaf) `
            -Message 'Hard-link terminal fixture did not become ready.'

        $aliasBlocked = Invoke-RunnerCase `
            -Name 'preflight-hardlink-alias-running' `
            -Mode PreflightOnly `
            -TerminalPath $terminal `
            -TerminalDataPath $dataPath `
            -ExpertPath $expert `
            -PresetPath $preset `
            -ExpertSha256 $expertHash
        Assert-True -Condition ($aliasBlocked.ExitCode -eq 4) `
            -Message 'A running hard-link alias of the bound terminal was not blocked.'
        Assert-True -Condition ($aliasBlocked.Result.status -eq 'blocked') `
            -Message 'Hard-link alias conflict produced the wrong runner status.'
    }
    finally {
        if ($aliasStarted -and -not $aliasProcess.HasExited) {
            $aliasProcess.Kill()
            $null = $aliasProcess.WaitForExit(5000)
        }
        $aliasProcess.Dispose()
    }

    $renamedAliasRealDirectory = Join-Path $testRoot 'install-renamed-real'
    [IO.Directory]::CreateDirectory($renamedAliasRealDirectory) | Out-Null
    $renamedAliasLeaf = 'renamed-terminal-host.exe'
    $renamedAliasTerminalReal = Join-Path $renamedAliasRealDirectory $renamedAliasLeaf
    $null = New-Item `
        -ItemType HardLink `
        -Path $renamedAliasTerminalReal `
        -Target $terminal
    $renamedAliasJunction = Join-Path $testRoot 'install-renamed-junction'
    $null = New-Item `
        -ItemType Junction `
        -Path $renamedAliasJunction `
        -Target $renamedAliasRealDirectory
    $renamedAliasTerminal = Join-Path $renamedAliasJunction $renamedAliasLeaf
    $renamedAliasConfig = Join-Path $dataPath 'renamed-alias-hold.ini'
    [IO.File]::WriteAllText(
        $renamedAliasConfig,
        '',
        (New-Object Text.UnicodeEncoding($false, $true))
    )
    $renamedAliasReady = Join-Path $dataPath 'renamed-alias-hold-ready'
    $renamedAliasStartInfo = New-Object Diagnostics.ProcessStartInfo
    $renamedAliasStartInfo.FileName = $renamedAliasTerminal
    $renamedAliasStartInfo.Arguments = Quote-NativeArgument -Value ("/config:$renamedAliasConfig")
    $renamedAliasStartInfo.UseShellExecute = $false
    $renamedAliasStartInfo.CreateNoWindow = $true
    $renamedAliasStartInfo.EnvironmentVariables['FAKE_MT5_MODE'] = 'hold'
    $renamedAliasStartInfo.EnvironmentVariables['FAKE_MT5_READY_PATH'] = $renamedAliasReady
    $renamedAliasProcess = New-Object Diagnostics.Process
    $renamedAliasProcess.StartInfo = $renamedAliasStartInfo
    $renamedAliasStarted = $false
    try {
        $null = $renamedAliasProcess.Start()
        $renamedAliasStarted = $true
        $renamedAliasDeadline = [datetime]::UtcNow.AddSeconds(10)
        while (
            -not (Test-Path -LiteralPath $renamedAliasReady -PathType Leaf) -and
            [datetime]::UtcNow -lt $renamedAliasDeadline
        ) {
            Start-Sleep -Milliseconds 25
        }
        Assert-True -Condition (
            Test-Path -LiteralPath $renamedAliasReady -PathType Leaf
        ) -Message 'Renamed junction/hard-link terminal fixture did not become ready.'

        $renamedAliasBlocked = Invoke-RunnerCase `
            -Name 'preflight-renamed-junction-hardlink-running' `
            -Mode PreflightOnly `
            -TerminalPath $terminal `
            -TerminalDataPath $dataPath `
            -ExpertPath $expert `
            -PresetPath $preset `
            -ExpertSha256 $expertHash
        Assert-True -Condition ($renamedAliasBlocked.ExitCode -eq 4) `
            -Message 'A renamed hard-link terminal launched through a junction was not blocked.'
        Assert-True -Condition (
            $null -ne $renamedAliasBlocked.Result -and
            $renamedAliasBlocked.Result.status -eq 'blocked'
        ) -Message 'Renamed junction/hard-link conflict produced the wrong runner status.'
    }
    finally {
        if ($renamedAliasStarted -and -not $renamedAliasProcess.HasExited) {
            $renamedAliasProcess.Kill()
            $null = $renamedAliasProcess.WaitForExit(5000)
        }
        $renamedAliasProcess.Dispose()
        if (Test-Path -LiteralPath $renamedAliasJunction) {
            [IO.Directory]::Delete($renamedAliasJunction)
        }
    }

    $pass = Invoke-RunnerCase `
        -Name 'execute-pass' `
        -Mode Execute `
        -TerminalPath $terminal `
        -TerminalDataPath $dataPath `
        -ExpertPath $expert `
        -PresetPath $preset `
        -ExpertSha256 $expertHash `
        -FakeMode 'pass'
    $passResultDiagnostic = if ($null -eq $pass.Result) {
        '<no result JSON>'
    }
    else {
        $pass.Result | ConvertTo-Json -Depth 10 -Compress
    }
    Assert-True -Condition ($pass.ExitCode -eq 0) `
        -Message (
            "Synthetic execution exit code was $($pass.ExitCode). " +
            "stderr=$($pass.StandardError) stdout=$($pass.StandardOutput) " +
            "result=$passResultDiagnostic"
        )
    Assert-True -Condition ($pass.Result.status -eq 'engine_smoke_passed') `
        -Message "Unexpected synthetic execution status: $($pass.Result.status)"
    Assert-True -Condition ([bool]$pass.Result.process.process_created) `
        -Message 'Synthetic execution did not record a created process.'
    Assert-True -Condition ([bool]$pass.Result.process.job_empty_verified) `
        -Message 'Synthetic execution did not verify an empty Job Object.'

    $markerBase = 'MQL5_CODING_PASS:' + (('a' * 32) -join '')
    $markerLabeled = $markerBase + ':detail'

    $prefixedPass = Invoke-RunnerCase `
        -Name 'execute-prefixed-pass' `
        -Mode Execute `
        -TerminalPath $terminal `
        -TerminalDataPath $dataPath `
        -ExpertPath $expert `
        -PresetPath $preset `
        -ExpertSha256 $expertHash `
        -FakeMode 'prefixed_pass' `
        -ExpectedLogMarker $markerBase `
        -FakeMarker $markerBase
    Assert-True -Condition ($prefixedPass.ExitCode -eq 0) `
        -Message "Tab-prefixed tester evidence was rejected: $($prefixedPass.StandardError)"
    Assert-True -Condition ($prefixedPass.Result.status -eq 'application_marker_passed') `
        -Message 'Tab-prefixed application marker produced the wrong status.'

    $systemInitializedWithBuild = Invoke-RunnerCase `
        -Name 'execute-system-initialized-with-build' `
        -Mode Execute `
        -TerminalPath $terminal `
        -TerminalDataPath $dataPath `
        -ExpertPath $expert `
        -PresetPath $preset `
        -ExpertSha256 $expertHash `
        -FakeMode 'system_initialized_with_build'
    Assert-True -Condition ($systemInitializedWithBuild.ExitCode -eq 0) `
        -Message 'A genuine initialization with trailing key/value detail was rejected.'
    Assert-True -Condition (
        [bool]$systemInitializedWithBuild.Result.evidence.checks.tester_initialized
    ) -Message 'A genuine initialization with trailing detail was not recorded.'

    $systemOnInitWithCode = Invoke-RunnerCase `
        -Name 'execute-system-oninit-failure-with-code' `
        -Mode Execute `
        -TerminalPath $terminal `
        -TerminalDataPath $dataPath `
        -ExpertPath $expert `
        -PresetPath $preset `
        -ExpertSha256 $expertHash `
        -FakeMode 'system_oninit_failure_with_code'
    Assert-True -Condition ($systemOnInitWithCode.ExitCode -eq 1) `
        -Message 'A genuine OnInit failure with trailing code=1 was ignored.'
    Assert-True -Condition (
        -not [bool]$systemOnInitWithCode.Result.evidence.checks.on_init_failure_absent
    ) -Message 'A genuine OnInit failure with trailing detail was not recorded.'

    $systemInitializedOnly = Invoke-RunnerCase `
        -Name 'execute-system-input-initialized-only' `
        -Mode Execute `
        -TerminalPath $terminal `
        -TerminalDataPath $dataPath `
        -ExpertPath $expert `
        -PresetPath $preset `
        -ExpertSha256 $expertHash `
        -FakeMode 'system_input_initialized_only'
    Assert-True -Condition ($systemInitializedOnly.ExitCode -eq 1) `
        -Message 'A system input echo was accepted as tester initialization evidence.'
    Assert-True -Condition (
        -not [bool]$systemInitializedOnly.Result.evidence.checks.tester_initialized
    ) -Message 'A system input echo was marked as a tester initialization.'

    $systemBoundary = Invoke-RunnerCase `
        -Name 'execute-system-input-generic-boundary' `
        -Mode Execute `
        -TerminalPath $terminal `
        -TerminalDataPath $dataPath `
        -ExpertPath $expert `
        -PresetPath $preset `
        -ExpertSha256 $expertHash `
        -FakeMode 'system_input_generic_boundary'
    Assert-True -Condition ($systemBoundary.ExitCode -eq 0) `
        -Message 'A system input echo incorrectly closed the tester evidence window.'
    Assert-True -Condition ($systemBoundary.Result.status -eq 'engine_smoke_passed') `
        -Message 'A system input echo changed a valid engine result.'

    $systemOnInit = Invoke-RunnerCase `
        -Name 'execute-system-input-oninit-failure' `
        -Mode Execute `
        -TerminalPath $terminal `
        -TerminalDataPath $dataPath `
        -ExpertPath $expert `
        -PresetPath $preset `
        -ExpertSha256 $expertHash `
        -FakeMode 'system_input_oninit_failure'
    Assert-True -Condition ($systemOnInit.ExitCode -eq 0) `
        -Message 'A system input echo was accepted as an OnInit failure.'
    Assert-True -Condition (
        [bool]$systemOnInit.Result.evidence.checks.on_init_failure_absent
    ) -Message 'A system input echo was marked as an OnInit failure.'

    $applicationInitializedOnly = Invoke-RunnerCase `
        -Name 'execute-application-initialized-only' `
        -Mode Execute `
        -TerminalPath $terminal `
        -TerminalDataPath $dataPath `
        -ExpertPath $expert `
        -PresetPath $preset `
        -ExpertSha256 $expertHash `
        -FakeMode 'application_initialized_only'
    Assert-True -Condition ($applicationInitializedOnly.ExitCode -eq 1) `
        -Message 'Application-authored initialization text was accepted as tester-system evidence.'
    Assert-True -Condition (
        -not [bool]$applicationInitializedOnly.Result.evidence.checks.tester_initialized
    ) -Message 'Application-authored initialization was marked as a tester initialization.'

    $applicationBoundary = Invoke-RunnerCase `
        -Name 'execute-application-generic-boundary' `
        -Mode Execute `
        -TerminalPath $terminal `
        -TerminalDataPath $dataPath `
        -ExpertPath $expert `
        -PresetPath $preset `
        -ExpertSha256 $expertHash `
        -FakeMode 'application_generic_boundary'
    Assert-True -Condition ($applicationBoundary.ExitCode -eq 0) `
        -Message 'Application-authored generic test text incorrectly closed the system evidence window.'
    Assert-True -Condition ($applicationBoundary.Result.status -eq 'engine_smoke_passed') `
        -Message 'Application-authored generic test text changed a valid engine result.'

    $applicationOnInit = Invoke-RunnerCase `
        -Name 'execute-application-oninit-failure' `
        -Mode Execute `
        -TerminalPath $terminal `
        -TerminalDataPath $dataPath `
        -ExpertPath $expert `
        -PresetPath $preset `
        -ExpertSha256 $expertHash `
        -FakeMode 'application_oninit_failure'
    Assert-True -Condition ($applicationOnInit.ExitCode -eq 0) `
        -Message 'Application-authored OnInit text was accepted as tester-system failure evidence.'
    Assert-True -Condition (
        [bool]$applicationOnInit.Result.evidence.checks.on_init_failure_absent
    ) -Message 'Application-authored OnInit text was marked as a tester-system failure.'

    $forgedPass = Invoke-RunnerCase `
        -Name 'execute-forged-engine-pass' `
        -Mode Execute `
        -TerminalPath $terminal `
        -TerminalDataPath $dataPath `
        -ExpertPath $expert `
        -PresetPath $preset `
        -ExpertSha256 $expertHash `
        -FakeMode 'forged_engine_pass'
    Assert-True -Condition ($forgedPass.ExitCode -eq 1) `
        -Message 'EA-authored text was accepted as a tester-engine pass.'
    Assert-True -Condition (-not [bool]$forgedPass.Result.evidence.checks.tester_engine_passed) `
        -Message 'Forged tester-engine evidence was marked as passed.'

    $duplicateFailure = Invoke-RunnerCase `
        -Name 'execute-duplicate-second-fails' `
        -Mode Execute `
        -TerminalPath $terminal `
        -TerminalDataPath $dataPath `
        -ExpertPath $expert `
        -PresetPath $preset `
        -ExpertSha256 $expertHash `
        -FakeMode 'two_candidates_second_fails'
    Assert-True -Condition ($duplicateFailure.ExitCode -eq 1) `
        -Message 'A later failed duplicate test candidate was ignored.'
    Assert-True -Condition (
        [int]$duplicateFailure.Result.evidence.checks.exact_test_candidate_count -eq 2
    ) -Message 'Duplicate exact test candidates were not recorded.'
    Assert-True -Condition (
        -not [bool]$duplicateFailure.Result.evidence.checks.exact_test_window_selected
    ) -Message 'Ambiguous duplicate test evidence selected a passing window.'

    $exactMarkerPass = Invoke-RunnerCase `
        -Name 'execute-exact-marker-pass' `
        -Mode Execute `
        -TerminalPath $terminal `
        -TerminalDataPath $dataPath `
        -ExpertPath $expert `
        -PresetPath $preset `
        -ExpertSha256 $expertHash `
        -FakeMode 'pass' `
        -ExpectedLogMarker $markerBase `
        -FakeMarker $markerBase
    Assert-True -Condition ($exactMarkerPass.ExitCode -eq 0) `
        -Message 'An exact canonical application marker did not pass.'
    Assert-True -Condition ($exactMarkerPass.Result.status -eq 'application_marker_passed') `
        -Message 'Exact marker pass produced the wrong status.'

    $markerPrefixMismatch = Invoke-RunnerCase `
        -Name 'execute-marker-prefix-mismatch' `
        -Mode Execute `
        -TerminalPath $terminal `
        -TerminalDataPath $dataPath `
        -ExpertPath $expert `
        -PresetPath $preset `
        -ExpertSha256 $expertHash `
        -FakeMode 'pass' `
        -ExpectedLogMarker $markerBase `
        -FakeMarker $markerLabeled
    Assert-True -Condition ($markerPrefixMismatch.ExitCode -eq 1) `
        -Message 'A longer marker incorrectly satisfied its literal prefix.'

    $inputEchoMarker = Invoke-RunnerCase `
        -Name 'execute-input-echo-marker' `
        -Mode Execute `
        -TerminalPath $terminal `
        -TerminalDataPath $dataPath `
        -ExpertPath $expert `
        -PresetPath $preset `
        -ExpertSha256 $expertHash `
        -FakeMode 'input_echo_marker' `
        -ExpectedLogMarker $markerBase `
        -FakeMarker $markerBase
    Assert-True -Condition ($inputEchoMarker.ExitCode -eq 1) `
        -Message 'An automatically echoed input was accepted as an application marker.'
    Assert-True -Condition (
        -not [bool]$inputEchoMarker.Result.evidence.checks.expected_markers_matched
    ) -Message 'Input-echo marker evidence was marked as matched.'

    foreach ($markerFailureMode in @('missing_marker', 'marker_after_pass')) {
        $markerFailure = Invoke-RunnerCase `
            -Name "execute-$markerFailureMode" `
            -Mode Execute `
            -TerminalPath $terminal `
            -TerminalDataPath $dataPath `
            -ExpertPath $expert `
            -PresetPath $preset `
            -ExpertSha256 $expertHash `
            -FakeMode $markerFailureMode `
            -ExpectedLogMarker $markerBase `
            -FakeMarker $markerBase
        Assert-True -Condition ($markerFailure.ExitCode -eq 1) `
            -Message "Marker mode '$markerFailureMode' incorrectly passed."
    }

    $timeout = Invoke-RunnerCase `
        -Name 'execute-timeout' `
        -Mode Execute `
        -TerminalPath $terminal `
        -TerminalDataPath $dataPath `
        -ExpertPath $expert `
        -PresetPath $preset `
        -ExpertSha256 $expertHash `
        -FakeMode 'timeout_child' `
        -TimeoutSeconds 10
    $timeoutResultDiagnostic = if ($null -eq $timeout.Result) {
        '<no result JSON>'
    }
    else {
        $timeout.Result | ConvertTo-Json -Depth 10 -Compress
    }
    Assert-True -Condition ($timeout.ExitCode -eq 3) `
        -Message (
            "Synthetic timeout exit code was $($timeout.ExitCode). " +
            "stderr=$($timeout.StandardError) stdout=$($timeout.StandardOutput) " +
            "result=$timeoutResultDiagnostic"
        )
    Assert-True -Condition ($timeout.Result.status -eq 'timed_out') `
        -Message "Unexpected synthetic timeout status: $($timeout.Result.status)"
    Assert-True -Condition ([bool]$timeout.Result.process.timed_out) `
        -Message 'Synthetic timeout was not recorded.'
    Assert-True -Condition ([bool]$timeout.Result.process.job_empty_verified) `
        -Message 'Synthetic timeout did not verify an empty Job Object.'

    $childPidPath = Join-Path $dataPath 'fake-child.pid'
    Assert-True -Condition (Test-Path -LiteralPath $childPidPath -PathType Leaf) `
        -Message 'Synthetic timeout fixture did not record its child PID.'
    $childPid = [int][IO.File]::ReadAllText($childPidPath)
    $childAlive = $false
    try {
        $childAlive = -not (Get-Process -Id $childPid -ErrorAction Stop).HasExited
    }
    catch {
        $childAlive = $false
    }
    Assert-True -Condition (-not $childAlive) `
        -Message "Synthetic timeout left child process $childPid running."

    $matchingTerminals = @(Get-CimInstance Win32_Process | Where-Object {
            try {
                $_.ExecutablePath -and
                    ([IO.Path]::GetFullPath($_.ExecutablePath) -ieq [IO.Path]::GetFullPath($terminal))
            }
            catch {
                $false
            }
        })
    Assert-True -Condition ($matchingTerminals.Count -eq 0) `
        -Message 'Synthetic terminal process remained after validation.'

    Write-Output (
        'SKILL_TEST_PASS host={0} compile=0,1,2,3,4 preflight={1} execute={2} timeout={3}' -f
        $PSVersionTable.PSVersion,
        $preflight.Result.status,
        $pass.Result.status,
        $timeout.Result.status
    )
}
finally {
    Remove-Item Env:FAKE_MT5_MODE -ErrorAction SilentlyContinue
    if (Test-Path -LiteralPath $testRoot) {
        $resolvedTemp = [IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd('\') + '\'
        $resolvedTestRoot = [IO.Path]::GetFullPath($testRoot)
        if (-not $resolvedTestRoot.StartsWith(
                $resolvedTemp,
                [StringComparison]::OrdinalIgnoreCase
            ) -or
            [IO.Path]::GetFileName($resolvedTestRoot) -notlike 'mql5-coding-skill-test-*') {
            throw "Refusing to remove unexpected test path: $resolvedTestRoot"
        }
        Remove-Item -LiteralPath $resolvedTestRoot -Recurse -Force
    }
}
