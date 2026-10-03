#Requires -Version 5.1
[CmdletBinding()]
param([string]$PythonPath)
Set-StrictMode -Version Latest
$ErrorActionPreference='Stop'
$repo=Split-Path -Parent $PSScriptRoot
$scripts=Join-Path $repo 'skills\mql5-coding\scripts'
. (Join-Path $scripts 'ToolkitSupport.ps1')
$hostExe=if ($PSVersionTable.PSEdition -eq 'Core') {Join-Path $PSHOME 'pwsh.exe'} else {Join-Path $PSHOME 'powershell.exe'}
$testRoot=Join-Path ([IO.Path]::GetTempPath()) ('mql5-toolkit-tests-'+[guid]::NewGuid().ToString('N'))
[IO.Directory]::CreateDirectory($testRoot) | Out-Null
$checks=0
function Check([bool]$Condition,[string]$Label) {if (-not $Condition) {throw $Label};$script:checks++}
function Save([string]$Path,$Value) {[IO.File]::WriteAllText($Path,($Value | ConvertTo-Json -Depth 12),(New-Object Text.UTF8Encoding($false)))}
function Run([string]$Script,[string[]]$Arguments,[string]$Root=$scripts) {
    return Invoke-ToolkitProcess $hostExe (@('-NoLogo','-NoProfile','-NonInteractive','-ExecutionPolicy','Bypass','-File',(Join-Path $Root $Script))+$Arguments) $testRoot 90
}
function ReadResult([string]$Output) {return Read-Mql5ReleaseJson (Join-Path $Output 'result.json')}
$oldTrace=$env:MQL5_SCENARIO_TEST_TRACE;$oldReport=$env:MQL5_SCENARIO_TEST_REPORT
try {
    $python=if ($PythonPath) {Get-ToolkitPython $PythonPath} elseif (Get-Command python -ErrorAction SilentlyContinue) {(Get-Command python).Source} else {Get-ToolkitPython ''}
    $journalPath=Join-Path $testRoot 'journal.log'
    $prefix="prefix`r`n"
    $segment="AA`t0`t10:00:01.000`tFixture`tpassword=hidden repeated`r`nBB`t0`t10:00:02.000`tFixture`tpassword=other repeated`r`nCC`t0`t10:00:03.000`tFixture`tMQL5_CODING_PASS:$('a'*32):test`r`n"
    $encoding=New-Object Text.UnicodeEncoding($false,$true,$true)
    [IO.File]::WriteAllText($journalPath,($prefix+$segment+'unrecorded suffix'),$encoding)
    $buffer=$encoding.GetBytes($segment);$sha=[Security.Cryptography.SHA256]::Create()
    try {$hash=([BitConverter]::ToString($sha.ComputeHash($buffer))).Replace('-','').ToLowerInvariant()} finally {$sha.Dispose()}
    $record=[pscustomobject]@{path='journal.log';source_offset=(2+$encoding.GetByteCount($prefix));byte_length=$buffer.Length;sha256=$hash}
    $journal=[pscustomobject]@{appended_byte_length=$buffer.Length;limit_exceeded=$false;segments=@($record);excerpts=@()}
    $run=[pscustomobject]@{schema_version=2;status='engine_smoke_passed';evidence=[pscustomobject]@{terminal_journal=$journal;tester_journal=[pscustomobject]@{appended_byte_length=0;limit_exceeded=$false;segments=@();excerpts=@()}}}
    $runPath=Join-Path $testRoot 'run.json';Save $runPath $run
    $out=Join-Path $testRoot 'journal-valid'
    $process=Run 'Read-Mql5Journal.ps1' @('-TesterResultPath',$runPath,'-OutputDirectory',$out)
    Check ($process.exit_code -eq 0) ('Verified journal failed: '+$process.stderr)
    $parsed=ReadResult $out
    Check ($parsed.inspected_lines -eq 3 -and $parsed.groups.Count -eq 2) 'Redacted repeated messages group independently of timestamps'
    $serialized=[IO.File]::ReadAllText((Join-Path $out 'result.json'))
    Check ($serialized -notmatch 'hidden|other repeated|MQL5_CODING_PASS' -and $serialized -match 'APPLICATION_MARKER') 'Secrets and marker plaintext are absent'
    Check ($parsed.groups[0].count -eq 2 -and $parsed.groups[0].first_timestamp -eq '10:00:01.000') 'Counts and timestamps retained'
    Check ($parsed.groups[0].locations[0].source_byte_offset -eq $record.source_offset) 'Original byte offset retained'
    $filtered=Join-Path $testRoot 'journal-filtered'
    $process=Run 'Read-Mql5Journal.ps1' @('-TesterResultPath',$runPath,'-OutputDirectory',$filtered,'-LiteralMessage','repeated')
    Check ($process.exit_code -eq 0 -and (ReadResult $filtered).matched_lines -eq 2) 'Literal filter selects matching messages'
    $record.sha256='0'*64;$journal.excerpts=@('AA'+"`t0`t10:00:00.000`tFixture`tpassword=fallback")
    Save $runPath $run
    $bad=Join-Path $testRoot 'journal-mismatch'
    $process=Run 'Read-Mql5Journal.ps1' @('-TesterResultPath',$runPath,'-OutputDirectory',$bad)
    Check ($process.exit_code -eq 4 -and (ReadResult $bad).evidence_status -eq 'bounded_excerpts') 'Mismatch uses disclosed bounded fallback'
    $record.source_offset=1;Save $runPath $run
    $offset=Join-Path $testRoot 'journal-offset'
    $process=Run 'Read-Mql5Journal.ps1' @('-TesterResultPath',$runPath,'-OutputDirectory',$offset)
    Check ($process.exit_code -eq 4 -and (ReadResult $offset).segments[0].status -eq 'unavailable') 'Odd UTF-16 byte offset rejected'
    $record.source_offset=2+$encoding.GetByteCount($prefix);$record.sha256=$hash;$journal.excerpts=@();Save $runPath $run
    $bounded=Join-Path $testRoot 'journal-bounded'
    $process=Run 'Read-Mql5Journal.ps1' @('-TesterResultPath',$runPath,'-OutputDirectory',$bounded,'-MaxLines','1')
    Check ($process.exit_code -eq 4 -and (ReadResult $bounded).truncated) 'Line limit disclosed'
    $journal.segments=@($record,$record);$journal.appended_byte_length=2*$buffer.Length;Save $runPath $run
    $overlap=Join-Path $testRoot 'journal-overlap'
    $process=Run 'Read-Mql5Journal.ps1' @('-TesterResultPath',$runPath,'-OutputDirectory',$overlap)
    Check ($process.exit_code -eq 4 -and (ReadResult $overlap).inspected_lines -eq 3) 'Overlapping segments are not counted twice'
    $journal.segments=@($record);$journal.appended_byte_length=$buffer.Length
    $run.evidence.tester_journal.appended_byte_length=100;Save $runPath $run
    $missing=Join-Path $testRoot 'journal-missing'
    $process=Run 'Read-Mql5Journal.ps1' @('-TesterResultPath',$runPath,'-OutputDirectory',$missing)
    Check ($process.exit_code -eq 4 -and (ReadResult $missing).evidence_status -eq 'partial_segments') 'Missing recorded coverage is incomplete'
    $run.evidence.tester_journal.appended_byte_length=0;Save $runPath $run
    $record.source_offset+=2;$record.byte_length-=2
    $partialBytes=$encoding.GetBytes($segment.Substring(1));$sha=[Security.Cryptography.SHA256]::Create()
    try {$record.sha256=([BitConverter]::ToString($sha.ComputeHash($partialBytes))).Replace('-','').ToLowerInvariant()} finally {$sha.Dispose()}
    $journal.appended_byte_length=$record.byte_length;Save $runPath $run
    $partial=Join-Path $testRoot 'journal-partial-record'
    $process=Run 'Read-Mql5Journal.ps1' @('-TesterResultPath',$runPath,'-OutputDirectory',$partial)
    Check ($process.exit_code -eq 4 -and -not (ReadResult $partial).segments[0].starts_at_line_boundary) 'Hash-verified partial record is disclosed as truncated'
    $record.source_offset-=2;$record.byte_length+=2;$record.sha256=$hash;$journal.appended_byte_length=$buffer.Length;Save $runPath $run
    $process=Run 'Read-Mql5Journal.ps1' @('-TesterResultPath',$runPath,'-OutputDirectory',$out)
    Check ($process.exit_code -eq 2) 'Existing journal output refused'

    $install=Join-Path $testRoot 'install';$project=Join-Path $testRoot ('project '+[char]0xe9);$data=Join-Path $testRoot 'data'
    foreach ($dir in @($install,$project,(Join-Path $data 'MQL5'),(Join-Path $project 'Include'))) {[IO.Directory]::CreateDirectory($dir) | Out-Null}
    $csc=Join-Path $env:WINDIR 'Microsoft.NET\Framework64\v4.0.30319\csc.exe'
    if (-not (Test-Path -LiteralPath $csc)) {$csc=Join-Path $env:WINDIR 'Microsoft.NET\Framework\v4.0.30319\csc.exe'}
    $editor=Join-Path $install 'metaeditor64.exe';$terminal=Join-Path $install 'terminal64.exe';$driver=Join-Path $project 'driver.exe'
    & $csc /nologo /target:exe ('/out:'+$editor) (Join-Path $PSScriptRoot 'FakeMetaEditor.cs');Check ($LASTEXITCODE -eq 0) 'Fake compiler built'
    $resource=Join-Path $testRoot 'resource.cs';[IO.File]::WriteAllText($resource,'using System.Reflection;[assembly:AssemblyFileVersion("5.0.0.1234")]')
    & $csc /nologo /target:exe ('/out:'+$terminal) (Join-Path $PSScriptRoot 'FakeTerminal.cs') $resource;Check ($LASTEXITCODE -eq 0) 'Fake terminal built'
    & $csc /nologo /target:exe ('/out:'+$driver) (Join-Path $PSScriptRoot 'FakeScenarioDriver.cs');Check ($LASTEXITCODE -eq 0) 'Scenario executable built'
    $source=Join-Path $project 'Fixture.mq5';[IO.File]::WriteAllText($source,'void OnTick() {}')
    $origin=Join-Path $data 'origin.txt';[IO.File]::WriteAllText($origin,$install,[Text.Encoding]::Unicode)
    $fixtureScripts=Join-Path $testRoot 'fixture-scripts';Copy-Item -LiteralPath $scripts -Destination $fixtureScripts -Recurse
    # The controller is real; only its existing profile execution boundary is replaced
    # by a synthetic executable. No test-only override is exposed in the public API.
    $stub=@'
param([string]$ProfilePath,[string]$Action,[string]$Entrypoint,[string]$CompilationReceiptPath,[string]$OutputDirectory,[string]$ExpectedLogMarkerFile)
$p=Get-Content -LiteralPath $ProfilePath -Raw -Encoding UTF8 | ConvertFrom-Json
$driver=Join-Path $p.project_root 'driver.exe'
$source=Join-Path $p.project_root 'Fixture.mq5'
if (-not $OutputDirectory) {$OutputDirectory=$p.project_root}
& $driver $Action $p.name $source $OutputDirectory
exit $LASTEXITCODE
'@
    [IO.File]::WriteAllText((Join-Path $fixtureScripts 'Invoke-Mql5Project.ps1'),$stub,(New-Object Text.UTF8Encoding($false)))
    $env:MQL5_SCENARIO_TEST_TRACE=Join-Path $testRoot 'trace.txt'
    $env:MQL5_SCENARIO_TEST_REPORT=Join-Path $PSScriptRoot 'fixtures\reports\no-trades.htm'
    $profiles=@{}
    foreach ($mode in @('success','compiler-failure','tester-failure','timeout','blocked','missing-result','cleanup-failure','bad-report')) {
        $path=Join-Path $testRoot ($mode+'-profile.json')
        $profile=@{schema_version=1;name=$mode;project_root=$project;entrypoints=@('Fixture.mq5');include_path='Include';metaeditor_path=$editor;compiler=@{timeout_seconds=5;warnings_as_errors=$false};tester=@{entrypoint='Fixture.mq5';terminal_path=$terminal;terminal_data_path=$data;set_path=$null;use_expert_defaults=$true;timeout_seconds=10;settings=@{symbol='EURUSD';period='M1';from_date='2025.01.12';to_date='2025.02.28';model=0;deposit='100000';currency='USD';leverage=100;execution_mode=0}}}
        Save $path $profile;$profiles[$mode]=$path
    }
    $manifestPath=Join-Path $testRoot 'scenarios.json'
    Save $manifestPath @{schema_version=1;scenarios=@(@{id='success';profile=$profiles.success})}
    $validated=Join-Path $testRoot 'batch-validate'
    $process=Run 'Invoke-Mql5ScenarioBatch.ps1' @('-ManifestPath',$manifestPath,'-OutputDirectory',$validated,'-PythonPath',$python) $fixtureScripts
    Check ($process.exit_code -eq 0 -and -not (Test-Path -LiteralPath $env:MQL5_SCENARIO_TEST_TRACE)) ('Validation launched code or failed: '+$process.stderr+$process.stdout+((ReadResult $validated).issues | ConvertTo-Json -Compress))
    $full=Join-Path $testRoot 'batch-mixed'
    $scenarios=@('success','compiler-failure','tester-failure','timeout','blocked','missing-result','bad-report') | ForEach-Object {@{id=$_;profile=$profiles[$_]}}
    Save $manifestPath @{schema_version=1;scenarios=@($scenarios)}
    $process=Run 'Invoke-Mql5ScenarioBatch.ps1' @('-ManifestPath',$manifestPath,'-OutputDirectory',$full,'-PythonPath',$python,'-Action','Execute') $fixtureScripts
    Check ($process.exit_code -eq 1) ('Mixed batch should retain failures: '+$process.stderr+$process.stdout+((ReadResult $full).issues | ConvertTo-Json -Compress))
    $batch=ReadResult $full
    $states=@($batch.scenarios | ForEach-Object {$_.status})
    Check (($states -join ',') -eq 'completed,failed,failed,timed_out,blocked,failed,completed') 'Scenario statuses preserved'
    Check ($batch.scenarios[6].analysis[0].exit_code -eq 2) 'Completed tester with failed analysis retained separately'
    Check ($batch.scenarios[3].tester.exit_code -eq 3 -and $batch.scenarios[4].tester.exit_code -eq 4) 'Original exit codes retained'
    Check (@($batch.scenarios | Where-Object {$_.cleanup_verified -eq $false}).Count -eq 0) 'Mixed batch owned cleanup verified'
    $unsafe=Join-Path $testRoot 'batch-unsafe'
    Save $manifestPath @{schema_version=1;scenarios=@(@{id='bad-cleanup';profile=$profiles['cleanup-failure']},@{id='later';profile=$profiles.success})}
    $process=Run 'Invoke-Mql5ScenarioBatch.ps1' @('-ManifestPath',$manifestPath,'-OutputDirectory',$unsafe,'-PythonPath',$python,'-Action','Execute') $fixtureScripts
    $batch=ReadResult $unsafe
    Check ($process.exit_code -eq 2 -and $batch.scenarios[1].status -eq 'skipped' -and $batch.scenarios[0].cleanup_verified -eq $false) 'Cleanup uncertainty aborts remaining scenarios'
    $cancel=Join-Path $testRoot 'cancel.flag';[IO.File]::WriteAllText($cancel,'cancel')
    $cancelled=Join-Path $testRoot 'batch-cancel'
    $process=Run 'Invoke-Mql5ScenarioBatch.ps1' @('-ManifestPath',$manifestPath,'-OutputDirectory',$cancelled,'-PythonPath',$python,'-Action','Execute','-CancellationFile',$cancel) $fixtureScripts
    Check ($process.exit_code -eq 2 -and @((ReadResult $cancelled).scenarios | Where-Object {$_.status -ne 'skipped'}).Count -eq 0) 'Cancellation preserves skipped statuses'
    $before=[IO.File]::ReadAllText($env:MQL5_SCENARIO_TEST_TRACE)
    Save $manifestPath @{schema_version=1;scenarios=@(@{id='first';profile=$profiles.success},@{id='invalid';profile='missing.json'})}
    $invalid=Join-Path $testRoot 'batch-invalid'
    $process=Run 'Invoke-Mql5ScenarioBatch.ps1' @('-ManifestPath',$manifestPath,'-OutputDirectory',$invalid,'-PythonPath',$python,'-Action','Execute') $fixtureScripts
    Check ($process.exit_code -eq 2 -and [IO.File]::ReadAllText($env:MQL5_SCENARIO_TEST_TRACE) -ceq $before) 'Entire manifest validated before execution'
    Save $manifestPath @{schema_version=1;scenarios=@(@{id='COM2';profile=$profiles.success})}
    $reserved=Join-Path $testRoot 'batch-reserved'
    $process=Run 'Invoke-Mql5ScenarioBatch.ps1' @('-ManifestPath',$manifestPath,'-OutputDirectory',$reserved,'-PythonPath',$python) $fixtureScripts
    Check ($process.exit_code -eq 2) 'Reserved Windows scenario name rejected before execution'
    $invalidExpectations=Join-Path $testRoot 'invalid-expectations.json'
    Save $invalidExpectations @{schema_version=1;metrics=@(@{metric='net_profit';target='candidate';minimum='0'});required_conditions=@('invented_condition')}
    Save $manifestPath @{schema_version=1;scenarios=@(@{id='expectations';profile=$profiles.success;baseline_report=$env:MQL5_SCENARIO_TEST_REPORT;expectations=$invalidExpectations})}
    $badExpectations=Join-Path $testRoot 'batch-invalid-expectations'
    $process=Run 'Invoke-Mql5ScenarioBatch.ps1' @('-ManifestPath',$manifestPath,'-OutputDirectory',$badExpectations,'-PythonPath',$python,'-Action','Execute') $fixtureScripts
    Check ($process.exit_code -eq 2 -and [IO.File]::ReadAllText($env:MQL5_SCENARIO_TEST_TRACE) -ceq $before) 'Unsupported comparison requirements rejected before execution'
    $profileInventory=Join-Path $testRoot 'profile-inventory'
    $analyzer=Invoke-ToolkitProcess $python @('-B',(Join-Path $scripts 'mql5_toolkit.py'),'includes','inventory','--project-profile',$profiles.success,'--powershell',$hostExe,'--output',$profileInventory) $testRoot 30
    Check ($analyzer.exit_code -eq 0 -and (ReadResult $profileInventory).profile.path -eq $profiles.success) 'Python inventory reuses existing profile validation'
    'TOOLKIT_POWERSHELL_TESTS='+$checks
} finally {
    $env:MQL5_SCENARIO_TEST_TRACE=$oldTrace;$env:MQL5_SCENARIO_TEST_REPORT=$oldReport
    $full=[IO.Path]::GetFullPath($testRoot)
    $parent=[IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd('\')+'\mql5-toolkit-tests-'
    if (-not $full.StartsWith($parent,[StringComparison]::OrdinalIgnoreCase)) {throw 'Unsafe cleanup target.'}
    Remove-Item -LiteralPath $full -Recurse -Force
}
