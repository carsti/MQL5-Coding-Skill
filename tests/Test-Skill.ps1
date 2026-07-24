#Requires -Version 5.1

[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$repositoryRoot = Split-Path -Parent $PSScriptRoot
$skillRoot = Join-Path $repositoryRoot 'skills\mql5-coding'
$runner = Join-Path $skillRoot 'scripts\Invoke-Mt5TesterSmoke.ps1'
$compiler = Join-Path $skillRoot 'scripts\Compile-Mql5.ps1'
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

foreach ($requiredFile in @($runner, $compiler, $fakeTerminalSource, $fakeMetaEditorSource)) {
    Assert-True -Condition (Test-Path -LiteralPath $requiredFile -PathType Leaf) `
        -Message "Required file is missing: $requiredFile"
}

Assert-PowerShellParses -Path $runner
Assert-PowerShellParses -Path $compiler

$skillText = Get-Content -LiteralPath (Join-Path $skillRoot 'SKILL.md') -Raw
$referenceText = Get-Content -LiteralPath (Join-Path $skillRoot 'references\strategy-tester.md') -Raw
$compilerText = Get-Content -LiteralPath $compiler -Raw
Assert-True -Condition ($skillText -notmatch '(?i)[A-Z]:\\Users\\') `
    -Message 'SKILL.md contains a user-specific path.'
Assert-True -Condition ($referenceText -notmatch '(?i)[A-Z]:\\Users\\') `
    -Message 'Strategy Tester reference contains a user-specific path.'
Assert-True -Condition ($compilerText -notmatch '\$sourceDirectory|nearSource') `
    -Message 'Compiler wrapper must not discover executables from the source tree.'

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

    $compileError = Invoke-CompilerCase `
        -SourcePath $compileSource `
        -MetaEditorPath $metaEditor `
        -FakeMode 'errors'
    Assert-True -Condition ($compileError.ExitCode -eq 1) `
        -Message "Synthetic compiler error exit code was $($compileError.ExitCode)."
    Assert-True -Condition ($compileError.StandardOutput -notmatch 'MQL5_COMPILE_ARTIFACT=') `
        -Message 'Compilation error incorrectly reported a stale artifact.'

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

    $pass = Invoke-RunnerCase `
        -Name 'execute-pass' `
        -Mode Execute `
        -TerminalPath $terminal `
        -TerminalDataPath $dataPath `
        -ExpertPath $expert `
        -PresetPath $preset `
        -ExpertSha256 $expertHash `
        -FakeMode 'pass'
    Assert-True -Condition ($pass.ExitCode -eq 0) `
        -Message "Synthetic execution exit code was $($pass.ExitCode): $($pass.StandardError)"
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
    Assert-True -Condition ($timeout.ExitCode -eq 3) `
        -Message "Synthetic timeout exit code was $($timeout.ExitCode): $($timeout.StandardError)"
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
