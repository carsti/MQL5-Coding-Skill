#Requires -Version 5.1
[CmdletBinding()]
param([Parameter(Mandatory)][string]$PythonPath)
Set-StrictMode -Version Latest
$ErrorActionPreference='Stop'
$scripts=Join-Path (Split-Path -Parent $PSScriptRoot) 'skills\mql5-coding\scripts'
. (Join-Path $scripts 'ToolkitSupport.ps1')
$hostExe=if ($PSVersionTable.PSEdition -eq 'Core') {Join-Path $PSHOME 'pwsh.exe'} else {Join-Path $PSHOME 'powershell.exe'}
$testRoot=Join-Path ([IO.Path]::GetTempPath()) ('mql5-large-compile-'+[guid]::NewGuid().ToString('N'))
$checks=0
function Check([bool]$Condition,[string]$Label) {if (-not $Condition) {throw $Label};$script:checks++}
function Save([string]$Path,$Value) {[IO.File]::WriteAllText($Path,($Value | ConvertTo-Json -Depth 12),(New-Object Text.UTF8Encoding($false)))}
function Run([string]$Script,[string[]]$Arguments) {Invoke-ToolkitProcess $hostExe (@('-NoLogo','-NoProfile','-NonInteractive','-ExecutionPolicy','Bypass','-File',(Join-Path $scripts $Script))+$Arguments) $testRoot 60}
$names=@('FAKE_METAEDITOR_MODE','FAKE_METAEDITOR_LOG_CHARACTERS','FAKE_METAEDITOR_LOG_ENCODING','FAKE_METAEDITOR_CHILD_PID_PATH','FAKE_MT5_MODE','FAKE_MT5_REPORT_FIXTURE')
$before=@{};foreach ($name in $names) {$before[$name]=[Environment]::GetEnvironmentVariable($name);[Environment]::SetEnvironmentVariable($name,$null)}
try {
    $install=Join-Path $testRoot 'install';$project=Join-Path $testRoot ('project '+[char]0xe9);$data=Join-Path $testRoot 'data'
    foreach ($dir in @($install,$project,(Join-Path $data 'MQL5\Experts'),(Join-Path $data 'MQL5\Profiles\Tester'),(Join-Path $data 'Tester\logs'),(Join-Path $data 'logs'))) {[void][IO.Directory]::CreateDirectory($dir)}
    $csc=Join-Path $env:WINDIR 'Microsoft.NET\Framework64\v4.0.30319\csc.exe'
    $editor=Join-Path $install 'metaeditor64.exe';$terminal=Join-Path $install 'terminal64.exe'
    & $csc /nologo /target:exe ('/out:'+$editor) (Join-Path $PSScriptRoot 'FakeMetaEditor.cs');Check ($LASTEXITCODE -eq 0) 'Synthetic compiler builds'
    $resource=Join-Path $testRoot 'resource.cs';[IO.File]::WriteAllText($resource,'using System.Reflection;[assembly:AssemblyFileVersion("5.0.0.1234")]')
    & $csc /nologo /target:exe ('/out:'+$terminal) (Join-Path $PSScriptRoot 'FakeTerminal.cs') $resource;Check ($LASTEXITCODE -eq 0) 'Synthetic terminal builds'
    $source=Join-Path $project 'Fixture.mq5';[IO.File]::WriteAllText($source,'void OnTick() {}')
    [IO.File]::WriteAllText((Join-Path $data 'origin.txt'),$install,[Text.Encoding]::Unicode)
    $profilePath=Join-Path $testRoot 'profile.json'
    $profile=@{schema_version=1;name='Large compile integration';project_root=$project;entrypoints=@('Fixture.mq5');include_path=$null;metaeditor_path=$editor;compiler=@{timeout_seconds=5;warnings_as_errors=$false};tester=@{entrypoint='Fixture.mq5';terminal_path=$terminal;terminal_data_path=$data;set_path=$null;use_expert_defaults=$true;timeout_seconds=10;settings=@{symbol='EURUSD';period='M1';from_date='2025.01.12';to_date='2025.02.28';model=0;deposit='100000';currency='USD';leverage=100;execution_mode=0}}}
    Save $profilePath $profile
    $manifest=Join-Path $testRoot 'manifest.json';Save $manifest @{schema_version=1;scenarios=@(@{id='large';profile=$profilePath})}
    $env:FAKE_MT5_REPORT_FIXTURE=Join-Path $PSScriptRoot 'fixtures\reports\no-trades.htm'
    # All wrappers are real. Only the external editor and terminal are synthetic.
    foreach ($case in @(@{name='utf8';characters=1100000},@{name='utf16';characters=1100000},@{name='near-limit';characters=15000000})) {
        $env:FAKE_METAEDITOR_LOG_CHARACTERS=[string]$case.characters;$env:FAKE_METAEDITOR_LOG_ENCODING=$case.name
        $output=Join-Path $testRoot ('batch-'+$case.name)
        $process=Run 'Invoke-Mql5ScenarioBatch.ps1' @('-ManifestPath',$manifest,'-OutputDirectory',$output,'-PythonPath',$PythonPath,'-Action','Execute')
        $result=Read-Mql5ReleaseJson (Join-Path $output 'result.json');$scenario=$result.scenarios[0]
        $testerDetail=if ($null -ne $scenario.tester -and $scenario.tester.result_path) {[IO.File]::ReadAllText($scenario.tester.result_path)} else {''}
        Check ($process.exit_code -eq 0 -and $process.cleanup_verified -and $scenario.status -eq 'completed' -and $scenario.compile.runner_status -eq 'completed' -and $scenario.compile.exit_code -eq 0 -and $scenario.tester.recorded_status -eq 'engine_smoke_passed') ('Large log must reach the tester: '+$process.stderr+($result | ConvertTo-Json -Depth 6 -Compress)+$testerDetail)
        $receipt=Read-Mql5ReleaseJson $scenario.compile.receipt_path
        $expectedText=('x'*$case.characters)+[Environment]::NewLine+'Result: 0 errors, 0 warnings'+[Environment]::NewLine
        $encoding=if ($case.name -eq 'utf16') {[Text.Encoding]::Unicode} else {New-Object Text.UTF8Encoding($false)}
        $expectedLength=$encoding.GetPreamble().Length+$encoding.GetByteCount($expectedText)
        Check ($receipt.status -eq 'success' -and $receipt.log.byte_length -eq $expectedLength -and (Get-Mql5ReleaseHash $receipt.log.path) -ceq $receipt.log.sha256 -and [IO.File]::ReadAllText($receipt.log.path) -ceq $expectedText) 'The receipt retains exact complete compiler log bytes and hash'
        $run=Read-Mql5ReleaseJson $scenario.tester.result_path
        Check ($run.inputs.compilation_receipt_path -ceq $scenario.compile.receipt_path -and $run.inputs.compilation_receipt.verified) 'Tester uses the freshly emitted compilation receipt'
    }
    $env:FAKE_METAEDITOR_LOG_CHARACTERS=$null;$env:FAKE_METAEDITOR_LOG_ENCODING=$null
    $default=Run 'Compile-Mql5.ps1' @('-SourcePath',$source,'-MetaEditorPath',$editor)
    Check ($default.exit_code -eq 0 -and $default.stdout -match 'MQL5_METAEDITOR_LOG_BEGIN' -and $default.stdout -match 'Result: 0 errors, 0 warnings') 'Direct compilation still prints its log by default'
    $silent=Run 'Invoke-Mql5Project.ps1' @('-ProfilePath',$profilePath,'-Action','Compile','-SuppressLogOutput')
    Check ($silent.exit_code -eq 0 -and $silent.stdout -notmatch 'MQL5_METAEDITOR_LOG_BEGIN|Result:' -and $silent.stdout -match 'MQL5_COMPILE_RECEIPT=' -and $silent.stdout -match 'MQL5_COMPILE_ARTIFACT=' -and $silent.stdout -match 'MQL5_COMPILE_SUMMARY') 'Suppression preserves receipt, artifact and summary output'
    foreach ($action in @('Validate','TesterPreflight','TesterSmoke')) {
        $invalid=Run 'Invoke-Mql5Project.ps1' @('-ProfilePath',$profilePath,'-Action',$action,'-SuppressLogOutput')
        Check ($invalid.exit_code -eq 2) 'Compilation-only suppression is rejected for other actions'
    }
    foreach ($case in @(@{mode='errors';code=1},@{mode='warnings';code=4},@{mode='timeout';code=3})) {
        $env:FAKE_METAEDITOR_MODE=$case.mode;$env:FAKE_METAEDITOR_LOG_CHARACTERS='1100000'
        $profile.compiler.warnings_as_errors=($case.mode -eq 'warnings');Save $profilePath $profile
        $child=Join-Path $testRoot 'compiler-child.pid';$env:FAKE_METAEDITOR_CHILD_PID_PATH=$child
        $output=Join-Path $testRoot ('batch-'+$case.mode)
        $process=Run 'Invoke-Mql5ScenarioBatch.ps1' @('-ManifestPath',$manifest,'-OutputDirectory',$output,'-PythonPath',$PythonPath,'-Action','Execute')
        $result=Read-Mql5ReleaseJson (Join-Path $output 'result.json');$scenario=$result.scenarios[0]
        Check ($process.exit_code -eq 1 -and $process.cleanup_verified -and $scenario.compile.exit_code -eq $case.code -and $scenario.cleanup_verified -and $null -eq $scenario.tester) 'Compiler failure and timeout codes survive suppressed logs and prevent tester execution'
        if ($case.mode -eq 'timeout') {
            $childId=[int][IO.File]::ReadAllText($child)
            Check ($null -eq (Get-Process -Id $childId -ErrorAction SilentlyContinue)) 'Compiler timeout terminates the owned descendant'
        }
    }
    'LARGE_COMPILE_BATCH_TESTS='+$checks
} finally {
    foreach ($name in $names) {[Environment]::SetEnvironmentVariable($name,$before[$name])}
    $full=[IO.Path]::GetFullPath($testRoot);$prefix=[IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd('\')+'\mql5-large-compile-'
    if (-not $full.StartsWith($prefix,[StringComparison]::OrdinalIgnoreCase)) {throw 'Unsafe test cleanup target.'}
    if (Test-Path -LiteralPath $full) {Remove-Item -LiteralPath $full -Recurse -Force}
}
