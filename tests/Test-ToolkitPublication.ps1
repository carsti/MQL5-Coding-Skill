#Requires -Version 5.1
[CmdletBinding()]
param([string]$PythonPath,[string]$ScriptsRoot,[string]$ReportDirectory)
Set-StrictMode -Version Latest
$ErrorActionPreference='Stop'
if (-not $ScriptsRoot) {$ScriptsRoot=Join-Path (Split-Path -Parent $PSScriptRoot) 'skills\mql5-coding\scripts'}
. (Join-Path $ScriptsRoot 'ToolkitSupport.ps1')
$python=Get-ToolkitPython $PythonPath
$hostExe=if ($PSVersionTable.PSEdition -eq 'Core') {Join-Path $PSHOME 'pwsh.exe'} else {Join-Path $PSHOME 'powershell.exe'}
$root=if ($ReportDirectory) {[IO.Path]::GetFullPath($ReportDirectory)} else {Join-Path ([IO.Path]::GetTempPath()) ('mql5-publication-tests-'+[guid]::NewGuid().ToString('N'))}
if (Test-Path -LiteralPath $root) {throw 'Publication test directory must be new.'}
[IO.Directory]::CreateDirectory($root) | Out-Null
$oldBlock=$env:MQL5_PUBLICATION_FIXTURE_BLOCK
$checks=0;$failures=@();$cases=@()
function Check([bool]$Condition,[string]$Label) {$script:checks++;if (-not $Condition) {$script:failures+=@($Label)}}
function Save([string]$Path,$Value) {[IO.File]::WriteAllText($Path,($Value | ConvertTo-Json -Depth 12),(New-Object Text.UTF8Encoding($false)))}
function Run([string]$Script,[string[]]$Arguments,[string]$Block='') {
    $env:MQL5_PUBLICATION_FIXTURE_BLOCK=$Block
    return Invoke-ToolkitProcess $hostExe (@('-NoLogo','-NoProfile','-NonInteractive','-ExecutionPolicy','Bypass','-File',(Join-Path $fixture $Script))+$Arguments) $root 45
}
try {
    $fixture=Join-Path $root 'scripts';Copy-Item -LiteralPath $ScriptsRoot -Destination $fixture -Recurse
    # Only disposable copies inject faults. Native file operations still run;
    # no failure switches or replacement writer are exposed in the helpers.
    $supportPath=Join-Path $fixture 'ToolkitSupport.ps1'
    $support=[IO.File]::ReadAllText($supportPath)
    $needle='finally {$owner.Dispose()}'
    $injection=@'
finally {$owner.Dispose()}
    if ($env:MQL5_PUBLICATION_FIXTURE_BLOCK -in @('result.json','summary.txt','results.tsv','progress.json')) {
        $blocker=Join-Path $full $env:MQL5_PUBLICATION_FIXTURE_BLOCK
        [IO.Directory]::CreateDirectory($blocker) | Out-Null
        [IO.File]::WriteAllText((Join-Path $blocker 'preserve.txt'),'Retained publication fixture')
    }
'@
    if (-not $support.Contains($needle)) {throw 'Output fault injection point is unavailable.'}
    [IO.File]::WriteAllText($supportPath,$support.Replace($needle,$injection),(New-Object Text.UTF8Encoding($false)))
    $batchPath=Join-Path $fixture 'Invoke-Mql5ScenarioBatch.ps1'
    $batch=[IO.File]::ReadAllText($batchPath)
    $checkpoint=@'
$fixtureCheckpointCount=0;$fixtureCheckpointLock=$null
function Save-BatchCheckpoint {
    $script:fixtureCheckpointCount++
    if ($env:MQL5_PUBLICATION_FIXTURE_BLOCK -eq 'final-checkpoint' -and $script:fixtureCheckpointCount -eq 2) {
        $script:fixtureCheckpointLock=[IO.File]::Open((Join-Path $output 'progress.json'),[IO.FileMode]::Open,[IO.FileAccess]::ReadWrite,[IO.FileShare]::None)
    }
'@
    if (-not $batch.Contains('function Save-BatchCheckpoint {')) {throw 'Checkpoint fault injection point is unavailable.'}
    [IO.File]::WriteAllText($batchPath,$batch.Replace('function Save-BatchCheckpoint {',$checkpoint),(New-Object Text.UTF8Encoding($false)))
    # A versioned synthetic executable supplies metadata only. Validate must
    # not execute it, and this test does not launch MetaTrader or MetaEditor.
    $csc=Join-Path $env:WINDIR 'Microsoft.NET\Framework64\v4.0.30319\csc.exe'
    if (-not (Test-Path -LiteralPath $csc)) {$csc=Join-Path $env:WINDIR 'Microsoft.NET\Framework\v4.0.30319\csc.exe'}
    $fixtureSource=Join-Path $root 'fixture.cs';$trace=Join-Path $root 'unexpected-execution.txt'
    [IO.File]::WriteAllText($fixtureSource,('[assembly: System.Reflection.AssemblyFileVersion("5.0.0.1234")]class Fixture {static void Main(){System.IO.File.WriteAllText(@"'+$trace+'","Unexpected execution");}}'))
    $editor=Join-Path $root 'metaeditor64.exe';$terminal=Join-Path $root 'terminal64.exe'
    & $csc /nologo /target:exe ('/out:'+$editor) $fixtureSource
    if ($LASTEXITCODE -ne 0) {throw 'Publication fixture executable could not be built.'}
    Copy-Item -LiteralPath $editor -Destination $terminal
    [IO.File]::WriteAllText((Join-Path $root 'Fixture.mq5'),'void OnTick() {}')
    $profile=Join-Path $root 'profile.json'
    Save $profile @{schema_version=1;name='publication fixture';project_root=$root;entrypoints=@('Fixture.mq5');include_path=$null;metaeditor_path=$editor;compiler=@{timeout_seconds=5;warnings_as_errors=$false};tester=@{entrypoint='Fixture.mq5';terminal_path=$terminal;terminal_data_path=$root;set_path=$null;use_expert_defaults=$true;timeout_seconds=10;settings=@{symbol='EURUSD';period='M1';from_date='2025.01.12';to_date='2025.02.28';model=0;deposit='100000';currency='USD';leverage=100;execution_mode=0}}}
    $manifest=Join-Path $root 'manifest.json';Save $manifest @{schema_version=1;scenarios=@(@{id='fixture';profile='profile.json'})}
    $journal=Join-Path $root 'journal.log';[IO.File]::WriteAllText($journal,"AA`t0`t10:00:01.000`tFixture`tObservation`r`n",[Text.Encoding]::Unicode)
    $run=Join-Path $root 'run.json'
    Save $run @{schema_version=2;status='engine_smoke_passed';evidence=@{terminal_journal=@{appended_byte_length=(Get-Item -LiteralPath $journal).Length;limit_exceeded=$false;segments=@(@{path=$journal;source_offset=0;byte_length=(Get-Item -LiteralPath $journal).Length;sha256=(Get-Mql5ReleaseHash $journal)});excerpts=@()};tester_journal=@{appended_byte_length=0;limit_exceeded=$false;segments=@();excerpts=@()}}}
    $inputs=@($run,$journal,$manifest,$profile);$hashes=@($inputs | ForEach-Object {Get-Mql5ReleaseHash $_})
    foreach ($operation in @('journal','batch')) {
        $scriptName=if ($operation -eq 'journal') {'Read-Mql5Journal.ps1'} else {'Invoke-Mql5ScenarioBatch.ps1'}
        $selected=if ($operation -eq 'journal') {@('-TesterResultPath',$run)} else {@('-ManifestPath',$manifest,'-PythonPath',$python)}
        $control=Join-Path $root ($operation+'-control')
        $process=Run $scriptName ($selected+@('-OutputDirectory',$control))
        $parsed=Read-Mql5ReleaseJson (Join-Path $control 'result.json')
        Check ($process.exit_code -eq 0 -and $process.cleanup_verified -and $parsed.exit_code -eq 0) ($operation+' control succeeds')
        Check ((Test-Path -LiteralPath (Join-Path $control 'summary.txt')) -and -not (Test-Path -LiteralPath $trace)) ($operation+' control saves evidence without executing a terminal')
        $blocks=if ($operation -eq 'journal') {@('result.json','summary.txt')} else {@('progress.json','final-checkpoint','results.tsv','result.json','summary.txt')}
        foreach ($block in $blocks) {
            $output=Join-Path $root ($operation+'-'+$block.Replace('.','-'))
            $process=Run $scriptName ($selected+@('-OutputDirectory',$output)) $block
            $cases+=@([ordered]@{operation=$operation;blocked_artifact=$block;exit_code=$process.exit_code;cleanup_verified=$process.cleanup_verified;stdout=$process.stdout;stderr=$process.stderr;output_directory=$output})
            Check ($process.exit_code -eq 2 -and $process.cleanup_verified) ($operation+' '+$block+' returns tooling exit 2 with verified cleanup')
            Check ($process.stderr.Length -gt 0 -and $process.stderr.Length -le 512 -and $process.stderr -notmatch 'Exception|At .+line|preserve.txt') ($operation+' '+$block+' emits bounded diagnostics without a stack trace')
            if ($block -eq 'final-checkpoint') {
                $retained=Read-Mql5ReleaseJson (Join-Path $output 'progress.json')
                $finalPath=Join-Path $output 'result.json';$final=$null
                if (Test-Path -LiteralPath $finalPath -PathType Leaf) {$final=Read-Mql5ReleaseJson $finalPath}
                Check ($retained.status -eq 'validated' -and $null -ne $final -and $final.status -eq 'failed' -and $final.exit_code -eq 2 -and @($final.issues | Where-Object {$_.code -eq 'output_publication_failed'}).Count -eq 1) 'Failed final checkpoint retains earlier progress and records publication failure'
            } else {
                Check ([IO.File]::ReadAllText((Join-Path $output ($block+'\preserve.txt'))) -ceq 'Retained publication fixture') ($operation+' '+$block+' preserves retained evidence')
            }
            Check (-not (Test-Path -LiteralPath $trace) -and (@(0..($inputs.Count-1) | Where-Object {(Get-Mql5ReleaseHash $inputs[$_]) -cne $hashes[$_]}).Count -eq 0)) ($operation+' '+$block+' leaves source evidence unchanged without executing a terminal')
        }
    }
    Save (Join-Path $root 'publication-test-result.json') @{schema_version=1;checks=$checks;failures=$failures;cases=$cases}
    'TOOLKIT_PUBLICATION_TESTS='+$checks
    foreach ($failure in $failures) {[Console]::Error.WriteLine($failure)}
} finally {
    $env:MQL5_PUBLICATION_FIXTURE_BLOCK=$oldBlock
    if (-not $ReportDirectory) {
        $prefix=[IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd('\')+'\mql5-publication-tests-'
        if (-not $root.StartsWith($prefix,[StringComparison]::OrdinalIgnoreCase)) {throw 'Unsafe publication test cleanup target.'}
        Remove-Item -LiteralPath $root -Recurse -Force
    }
}
if ($failures.Count) {exit 1}
