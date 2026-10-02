#Requires -Version 5.1
[CmdletBinding()]
param()
Set-StrictMode -Version Latest
$ErrorActionPreference='Stop'
$repo=Split-Path -Parent $PSScriptRoot
$scripts=Join-Path $repo 'skills\mql5-coding\scripts'
. (Join-Path $scripts 'Mql5ProjectProfile.ps1')
$hostExe=if ($PSVersionTable.PSEdition -eq 'Core') {Join-Path $PSHOME 'pwsh.exe'} else {Join-Path $PSHOME 'powershell.exe'}
$temporaryParent=[IO.Path]::GetFullPath([IO.Path]::GetTempPath())
$testRoot=Join-Path $temporaryParent ('mql5-project-profiles-'+[guid]::NewGuid().ToString('N'))
$checks=0
function Check([bool]$Condition,[string]$Message) {
    if (-not $Condition) {throw $Message}
    $script:checks++
}
function Save-Json($Data,[string]$Path) {
    [IO.File]::WriteAllText($Path,(($Data | ConvertTo-Json -Depth 8)+[Environment]::NewLine),(New-Object Text.UTF8Encoding($false)))
}
function Copy-Data($Data) {return ($Data | ConvertTo-Json -Depth 8 | ConvertFrom-Json)}
function Run([string]$Script,[hashtable]$Parameters) {
    $argv=@('-NoLogo','-NoProfile','-NonInteractive','-ExecutionPolicy','Bypass','-File',(Join-Path $scripts $Script))
    foreach ($key in @($Parameters.Keys | Sort-Object)) {
        if ($Parameters[$key] -is [bool]) {if ($Parameters[$key]) {$argv+=@('-'+$key)};continue}
        $argv+=@(('-'+$key),([string]$Parameters[$key]))
    }
    $quoted=@($argv | ForEach-Object {
        if ($_ -notmatch '[\s"]') {$_} else {'"'+($_ -replace '(\\*)"','$1$1\"' -replace '(\\+)$','$1$1')+'"'}
    })
    $start=New-Object Diagnostics.ProcessStartInfo
    $start.FileName=$hostExe
    $start.Arguments=$quoted -join ' '
    $start.UseShellExecute=$false
    $start.CreateNoWindow=$true
    $start.RedirectStandardOutput=$true
    $start.RedirectStandardError=$true
    $start.WorkingDirectory=$testRoot
    $process=New-Object Diagnostics.Process
    $process.StartInfo=$start
    try {
        [void]$process.Start()
        $stdout=$process.StandardOutput.ReadToEndAsync()
        $stderr=$process.StandardError.ReadToEndAsync()
        if (-not $process.WaitForExit(90000)) {$process.Kill();throw 'Profile command timed out.'}
        $process.WaitForExit()
        return [pscustomobject]@{code=$process.ExitCode;stdout=$stdout.GetAwaiter().GetResult();stderr=$stderr.GetAwaiter().GetResult()}
    } finally {$process.Dispose()}
}
function Invoke-Profile([hashtable]$Parameters) {
    $Parameters.ProfilePath=$script:profilePath
    return Run 'Invoke-Mql5Project.ps1' $Parameters
}
function Receipt-Path($Result) {
    $matches=[regex]::Matches($Result.stdout,'(?m)^MQL5_COMPILE_RECEIPT=(.+)\r?$')
    Check ($matches.Count -gt 0) ('No compile receipt: '+$Result.stderr+$Result.stdout)
    return $matches[$matches.Count-1].Groups[1].Value.Trim()
}
function Reject($Data,[string]$Label) {
    $bad=Join-Path $testRoot 'bad-profile.json'
    Save-Json $Data $bad
    $rejected=$false
    try {[void](Read-Mql5ProjectProfile $bad)} catch {$rejected=$true}
    Check $rejected ('Invalid profile accepted: '+$Label)
}
$environmentNames=@('FAKE_METAEDITOR_MODE','FAKE_METAEDITOR_ARGS_PATH','FAKE_MT5_MODE','FAKE_MT5_MARKER')
$originalEnvironment=@{}
foreach ($name in $environmentNames) {$originalEnvironment[$name]=[Environment]::GetEnvironmentVariable($name)}
try {
    $project=Join-Path $testRoot 'EA project with spaces'
    $install=Join-Path $testRoot 'install'
    $data=Join-Path $testRoot 'data'
    foreach ($dir in @($project,$install,(Join-Path $project 'include root'),(Join-Path $data 'MQL5\Experts'),(Join-Path $data 'MQL5\Profiles\Tester'),(Join-Path $data 'Tester\logs'),(Join-Path $data 'logs'))) {[IO.Directory]::CreateDirectory($dir) | Out-Null}
    $csc=Join-Path $env:WINDIR 'Microsoft.NET\Framework64\v4.0.30319\csc.exe'
    if (-not (Test-Path -LiteralPath $csc -PathType Leaf)) {$csc=Join-Path $env:WINDIR 'Microsoft.NET\Framework\v4.0.30319\csc.exe'}
    $editor=Join-Path $install 'metaeditor64.exe'
    & $csc /nologo /target:exe "/out:$editor" (Join-Path $PSScriptRoot 'FakeMetaEditor.cs')
    Check ($LASTEXITCODE -eq 0) 'Synthetic MetaEditor compilation failed.'
    $terminal=Join-Path $install 'terminal64.exe'
    $terminalSource=Join-Path $testRoot 'ProfileFakeTerminal.cs'
    $terminalText=[IO.File]::ReadAllText((Join-Path $PSScriptRoot 'FakeTerminal.cs')).Replace('internal static class FakeTerminal',('[assembly: System.Reflection.AssemblyFileVersion("5.0.0.1234")]'+[Environment]::NewLine+'internal static class FakeTerminal'))
    [IO.File]::WriteAllText($terminalSource,$terminalText)
    & $csc /nologo /target:exe "/out:$terminal" $terminalSource
    Check ($LASTEXITCODE -eq 0) 'Synthetic terminal compilation failed.'
    [IO.File]::WriteAllText((Join-Path $data 'origin.txt'),$install)
    foreach ($file in @('First.mq5','Second.mq5')) {[IO.File]::WriteAllText((Join-Path $project $file),'// synthetic source')}
    [IO.File]::WriteAllText((Join-Path $project 'approved.set'),'FakeInput=1||0||1||N')
    $profilePath=Join-Path $project 'mql5-project.json'
    $creation=@{ProfilePath=$profilePath;Name='Fixture';ProjectRoot=$project;Entrypoints='First.mq5';MetaEditorPath=$editor;IncludePath='include root';TesterEntrypoint='First.mq5';TerminalPath=$terminal;TerminalDataPath=$data;SetPath='approved.set';Symbol='SYNTH';Period='H1';FromDate='2026.07.01';ToDate='2026.07.02';Model=0;Deposit='10000.50';Currency='USD';Leverage=100;ExecutionMode=0}
    $saved=Run 'New-Mql5ProjectProfile.ps1' $creation
    Check ($saved.code -eq 0) ('Profile creation failed: '+$saved.stderr)
    $base=Get-Content -LiteralPath $profilePath -Raw -Encoding UTF8 | ConvertFrom-Json
    Check ($base.project_root -ceq '.') 'Project root stored incorrectly when profile is in the project root.'
    Check ($base.entrypoints[0] -ceq 'First.mq5' -and $base.include_path -ceq 'include root' -and $base.tester.set_path -ceq 'approved.set') 'Project-relative paths were not retained.'
    Check (-not (Test-Path -LiteralPath (Join-Path $project 'First.ex5'))) 'Creation unexpectedly compiled the EA.'
    $originalBytes=[IO.File]::ReadAllBytes($profilePath)
    $again=Run 'New-Mql5ProjectProfile.ps1' $creation
    Check ($again.code -eq 2 -and [Convert]::ToBase64String($originalBytes) -ceq [Convert]::ToBase64String([IO.File]::ReadAllBytes($profilePath))) 'Existing profile was overwritten.'
    $validated=Invoke-Profile @{}
    Check ($validated.code -eq 0) ('Default validation failed: '+$validated.stderr)
    $resolved=$validated.stdout | ConvertFrom-Json
    Check ($resolved.entrypoints[0] -ieq (Join-Path $project 'First.mq5')) 'Validation depends on the invoking working directory.'
    Check (-not (Test-Path -LiteralPath (Join-Path $project 'First.ex5'))) 'Validation unexpectedly compiled the EA.'
    $moved=Join-Path $testRoot 'moved project'
    Copy-Item -LiteralPath $project -Destination $moved -Recurse
    $movedData=Read-Mql5ProjectProfile (Join-Path $moved 'mql5-project.json')
    Check ($movedData.entrypoints[0] -ieq (Join-Path $moved 'First.mq5')) 'Moved profile resolved to the old project.'
    $externalRoot=Join-Path $testRoot 'shared resources'
    [IO.Directory]::CreateDirectory($externalRoot) | Out-Null
    $externalPreset=Join-Path $externalRoot 'shared.set'
    [IO.File]::WriteAllText($externalPreset,'FakeInput=2||0||1||N')
    $externalCreation=$creation.Clone()
    $externalCreation.ProfilePath=Join-Path $project 'external-profile.json'
    $externalCreation.IncludePath=$externalRoot
    $externalCreation.SetPath=$externalPreset
    $externalSaved=Run 'New-Mql5ProjectProfile.ps1' $externalCreation
    Check ($externalSaved.code -eq 0) 'External-resource profile creation failed.'
    $externalData=Get-Content -LiteralPath $externalCreation.ProfilePath -Raw -Encoding UTF8 | ConvertFrom-Json
    Check ($externalData.include_path -ieq $externalRoot) 'A same-drive external include was made project-relative.'
    Check ($externalData.tester.set_path -ieq $externalPreset) 'A same-drive external preset was made project-relative.'
    Copy-Item -LiteralPath $externalCreation.ProfilePath -Destination (Join-Path $moved 'external-profile.json')
    $movedExternal=Read-Mql5ProjectProfile (Join-Path $moved 'external-profile.json')
    Check ($movedExternal.include_path -ieq $externalRoot -and $movedExternal.tester.set_path -ieq $externalPreset) 'Moving the project redirected external resources.'
    Check ((Get-Mql5ProfileStoredPath (Join-Path $externalRoot 'Shared.mq5') $project) -ieq (Join-Path $externalRoot 'Shared.mq5')) 'External source selections were made project-relative.'
    $compileOnly=Copy-Data $base
    $compileOnly.tester=$null
    Check ($null -eq (ConvertTo-Mql5ValidatedProfile $compileOnly $profilePath).tester) 'Compile-only profiles were rejected.'
    foreach ($field in @('Execute','AcknowledgeSavedAccountRisk','Login','CompilationReceiptPath','ExpectedExpertSha256','OutputDirectory','ExpectedLogMarker','command')) {
        $bad=Copy-Data $base
        $bad | Add-Member NoteProperty $field 'forbidden'
        Reject $bad $field
    }
    foreach ($case in @('schema','missing','entrytype','duplicateentry','foreignexpert','date','deposit','bool','timeout','bothinputs','noinputs','newline','missingfile')) {
        $bad=Copy-Data $base
        switch ($case) {
            schema {$bad.schema_version=2}
            missing {$bad.PSObject.Properties.Remove('name')}
            entrytype {$bad.entrypoints='First.mq5'}
            duplicateentry {$bad.entrypoints=@('First.mq5','FIRST.mq5')}
            foreignexpert {$bad.tester.entrypoint='Second.mq5'}
            date {$bad.tester.settings.to_date=$bad.tester.settings.from_date}
            deposit {$bad.tester.settings.deposit='10,000'}
            bool {$bad.compiler.warnings_as_errors='false'}
            timeout {$bad.compiler.timeout_seconds=0}
            bothinputs {$bad.tester.use_expert_defaults=$true}
            noinputs {$bad.tester.set_path=$null}
            newline {$bad.tester.settings.symbol="SYNTH`nLogin=1"}
            missingfile {$bad.entrypoints=@('Missing.mq5')}
        }
        Reject $bad $case
    }
    $acceptedDefaults=Copy-Data $base
    $acceptedDefaults.tester.set_path=$null
    $acceptedDefaults.tester.use_expert_defaults=$true
    Check (ConvertTo-Mql5ValidatedProfile $acceptedDefaults $profilePath).tester.use_expert_defaults 'Explicitly accepted defaults were rejected.'
    foreach ($key in @('name','Name','\u006eame')) {
        $duplicate=[regex]::Replace(($base | ConvertTo-Json -Depth 8),'"schema_version"\s*:\s*1',('"'+$key+'": "duplicate", "schema_version": 1'))
        $rejected=$false
        try {Assert-Mql5ProfileJsonKeys $duplicate} catch {$rejected=$true}
        Check $rejected ('Duplicate JSON key accepted: '+$key)
    }
    $misuse=Invoke-Profile @{Action='Validate';AcknowledgeSavedAccountRisk=$true}
    Check ($misuse.code -eq 2) 'Validate accepted an execution acknowledgement.'
    # The creation API must not silently fill omitted tester settings.
    $partialCreate=@{}
    foreach ($key in $creation.Keys) {$partialCreate[$key]=$creation[$key]}
    $partialCreate.Remove('Model');$partialCreate.ProfilePath=Join-Path $project 'partial.json'
    $partialResult=Run 'New-Mql5ProjectProfile.ps1' $partialCreate
    Check ($partialResult.code -eq 2 -and -not (Test-Path -LiteralPath $partialCreate.ProfilePath)) 'An incomplete tester selection was saved.'
    $env:FAKE_METAEDITOR_MODE='success'
    $env:FAKE_METAEDITOR_ARGS_PATH=Join-Path $testRoot 'editor-argv.txt'
    $compiled=Invoke-Profile @{Action='Compile'}
    Check ($compiled.code -eq 0) ('Profile compile failed: '+$compiled.stderr+$compiled.stdout)
    $receiptPath=Receipt-Path $compiled
    $receipt=Get-Content -LiteralPath $receiptPath -Raw -Encoding UTF8 | ConvertFrom-Json
    Check ($receipt.exit_code -eq 0) 'Compilation did not retain a successful receipt.'
    $arguments=Get-Content -LiteralPath $env:FAKE_METAEDITOR_ARGS_PATH
    Check (@($arguments | Where-Object {$_ -like '/include:*include root*'}).Count -eq 1) 'Include root with spaces was lost.'
    $beforeSources=[IO.File]::ReadAllText((Join-Path $project 'First.mq5'))
    $multi=Copy-Data $base;$multi.entrypoints=@('First.mq5','Second.mq5')
    Save-Json $multi $profilePath
    $all=Invoke-Profile @{Action='Compile'}
    Check ($all.code -eq 0 -and [regex]::Matches($all.stdout,'MQL5_COMPILE_RECEIPT=').Count -eq 2) 'Saved entrypoints were not compiled in order.'
    $selected=Invoke-Profile @{Action='Compile';Entrypoint='Second.mq5'}
    Check ($selected.code -eq 0 -and [regex]::Matches($selected.stdout,'MQL5_COMPILE_RECEIPT=').Count -eq 1) 'An explicit selected entrypoint did not compile once.'
    $multi.compiler.warnings_as_errors=$true;Save-Json $multi $profilePath
    $env:FAKE_METAEDITOR_MODE='warnings'
    $warning=Invoke-Profile @{Action='Compile'}
    Check ($warning.code -eq 4 -and [regex]::Matches($warning.stdout,'MQL5_COMPILE_RECEIPT=').Count -eq 1) 'Warnings policy/stop/exit-code propagation failed.'
    $env:FAKE_METAEDITOR_MODE='errors'
    $errorResult=Invoke-Profile @{Action='Compile'}
    Check ($errorResult.code -eq 1 -and [regex]::Matches($errorResult.stdout,'MQL5_COMPILE_RECEIPT=').Count -eq 1) 'Compiler error/stop/exit-code propagation failed.'
    $env:FAKE_METAEDITOR_MODE='success';Save-Json $base $profilePath
    $fresh=Invoke-Profile @{Action='Compile'};$receiptPath=Receipt-Path $fresh
    Check ($fresh.code -eq 0) 'Fresh receipt compile failed.'
    $preflightOutput=Join-Path $testRoot 'preflight'
    $preflight=Invoke-Profile @{Action='TesterPreflight';CompilationReceiptPath=$receiptPath;OutputDirectory=$preflightOutput}
    Check ($preflight.code -eq 0) ('Profile preflight failed: '+$preflight.stderr+$preflight.stdout)
    $report=Get-Content -LiteralPath (Join-Path $preflightOutput 'smoke-result.json') -Raw -Encoding UTF8 | ConvertFrom-Json
    Check ($report.status -ceq 'preflight_passed') 'Preflight did not report readiness.'
    Check ($report.inputs.deposit -eq 10000.50 -and $report.inputs.model -eq 0 -and $report.inputs.execution_mode -eq 0) 'Explicit decimal/zero settings changed.'
    $blockedOutput=Join-Path $testRoot 'unapproved'
    $blocked=Invoke-Profile @{Action='TesterSmoke';CompilationReceiptPath=$receiptPath;OutputDirectory=$blockedOutput}
    Check ($blocked.code -eq 2 -and -not (Test-Path -LiteralPath $blockedOutput)) 'Tester started without a separate acknowledgement.'
    $noEvidence=Invoke-Profile @{Action='TesterPreflight';OutputDirectory=(Join-Path $testRoot 'no-evidence')}
    Check ($noEvidence.code -eq 2) 'A saved profile supplied executable trust.'
    [IO.File]::AppendAllText((Join-Path $project 'First.mq5'),' changed')
    $stale=Invoke-Profile @{Action='TesterPreflight';CompilationReceiptPath=$receiptPath;OutputDirectory=(Join-Path $testRoot 'stale-evidence')}
    Check ($stale.code -ne 0) 'Changed root source was accepted through a saved profile.'
    [IO.File]::WriteAllText((Join-Path $project 'First.mq5'),$beforeSources)
    $env:FAKE_MT5_MODE='pass';$env:FAKE_MT5_MARKER='MQL5_CODING_PASS:0123456789abcdef0123456789abcdef:profile_test'
    $smokeOutput=Join-Path $testRoot 'synthetic-smoke'
    $smoke=Invoke-Profile @{Action='TesterSmoke';CompilationReceiptPath=$receiptPath;OutputDirectory=$smokeOutput;AcknowledgeSavedAccountRisk=$true;ExpectedLogMarker=$env:FAKE_MT5_MARKER}
    Check ($smoke.code -eq 0) ('Synthetic tester delegation failed: '+$smoke.stderr+$smoke.stdout)
    $smokeReport=Get-Content -LiteralPath (Join-Path $smokeOutput 'smoke-result.json') -Raw -Encoding UTF8 | ConvertFrom-Json
    Check ($smokeReport.status -ceq 'application_marker_passed') 'Synthetic tester result was not retained.'
    Check ([Convert]::ToBase64String($originalBytes) -ceq [Convert]::ToBase64String([IO.File]::ReadAllBytes($profilePath))) 'Project invocation changed the saved profile.'
    Check ([IO.File]::ReadAllText((Join-Path $project 'approved.set')) -ceq 'FakeInput=1||0||1||N') 'Preset was modified.'
    Write-Output ('PROJECT_PROFILE_TESTS='+$checks)
} finally {
    foreach ($name in $environmentNames) {[Environment]::SetEnvironmentVariable($name,$originalEnvironment[$name])}
    $resolvedRoot=[IO.Path]::GetFullPath($testRoot)
    if (-not $resolvedRoot.StartsWith($temporaryParent.TrimEnd('\')+'\mql5-project-profiles-',[StringComparison]::OrdinalIgnoreCase)) {throw 'Unsafe test cleanup target.'}
    if (Test-Path -LiteralPath $resolvedRoot -PathType Container) {Remove-Item -LiteralPath $resolvedRoot -Recurse -Force}
}
