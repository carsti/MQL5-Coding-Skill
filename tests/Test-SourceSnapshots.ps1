#Requires -Version 5.1
[CmdletBinding()]
param([string]$PythonPath)
Set-StrictMode -Version Latest
$ErrorActionPreference='Stop'
$scripts=Join-Path (Split-Path -Parent $PSScriptRoot) 'skills\mql5-coding\scripts'
. (Join-Path $scripts 'BuildSourceSnapshot.ps1')
$python=Get-ToolkitPython $PythonPath
$hostExe=if ($PSVersionTable.PSEdition -eq 'Core') {Join-Path $PSHOME 'pwsh.exe'} else {Join-Path $PSHOME 'powershell.exe'}
$root=Join-Path ([IO.Path]::GetTempPath()) ('mql5-snapshot-tests-'+[guid]::NewGuid().ToString('N'))
[void][IO.Directory]::CreateDirectory($root)
$checks=0
function Check([bool]$Value,[string]$Message) {if (-not $Value) {throw $Message};$script:checks++}
function Run([string]$Name,[hashtable]$Parameters) {
    $command='& '+"'"+(Join-Path $scripts $Name).Replace("'","''")+"'"
    foreach ($key in $Parameters.Keys) {if ($Parameters[$key] -is [bool]) {if($Parameters[$key]){$command+=' -'+$key}} else {$command+=' -'+$key+" '"+([string]$Parameters[$key]).Replace("'","''")+"'"}}
    $command+='; exit $LASTEXITCODE'
    return Invoke-ToolkitProcess $hostExe @('-NoLogo','-NoProfile','-NonInteractive','-ExecutionPolicy','Bypass','-EncodedCommand',([Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($command)))) $root 90
}
try {
    $install=Join-Path $root 'install';$project=Join-Path $root 'project';$include=Join-Path $project 'Include';$data=Join-Path $root 'data'
    foreach ($dir in @($install,$project,$include,(Join-Path $data 'MQL5\Experts'),(Join-Path $data 'MQL5\Profiles\Tester'),(Join-Path $data 'Tester\logs'),(Join-Path $data 'logs'))) {[void][IO.Directory]::CreateDirectory($dir)}
    $csc=Join-Path $env:WINDIR 'Microsoft.NET\Framework64\v4.0.30319\csc.exe'
    if (-not (Test-Path $csc)) {$csc=Join-Path $env:WINDIR 'Microsoft.NET\Framework\v4.0.30319\csc.exe'}
    $editor=Join-Path $install 'metaeditor64.exe';$terminal=Join-Path $install 'terminal64.exe'
    & $csc /nologo /target:exe ('/out:'+$editor) (Join-Path $PSScriptRoot 'FakeMetaEditor.cs');Check ($LASTEXITCODE -eq 0) 'Synthetic editor build failed'
    $metadata=Join-Path $root 'metadata.cs';[IO.File]::WriteAllText($metadata,'using System.Reflection;[assembly:AssemblyFileVersion("5.0.0.1234")]')
    & $csc /nologo /target:exe ('/out:'+$terminal) (Join-Path $PSScriptRoot 'FakeTerminal.cs') $metadata;Check ($LASTEXITCODE -eq 0) 'Synthetic terminal build failed'
    [IO.File]::WriteAllText((Join-Path $data 'origin.txt'),$install,[Text.Encoding]::Unicode)
    $source=Join-Path $project 'Fixture.mq5';$header=Join-Path $include 'Shared.mqh'
    [IO.File]::WriteAllText($source,"#include <Shared.mqh>`n#ifdef MAYBE`n#include <Shared.mqh>`n#endif`nvoid OnTick() {}")
    [IO.File]::WriteAllText($header,'// independent shared fixture')
    $profile=Join-Path $project 'profile.json'
    $creation=Run 'New-Mql5ProjectProfile.ps1' @{ProfilePath=$profile;Name='Snapshot';ProjectRoot=$project;Entrypoints='Fixture.mq5';MetaEditorPath=$editor;IncludePath=$project;CompileTimeoutSeconds=5;TesterEntrypoint='Fixture.mq5';TerminalPath=$terminal;TerminalDataPath=$data;UseExpertDefaults=$true;Symbol='SYNTH';Period='M1';FromDate='2026.07.01';ToDate='2026.07.02';Model=0;Deposit='10000';Currency='USD';Leverage=100;ExecutionMode=0}
    Check ($creation.exit_code -eq 0) ('Profile creation failed: '+$creation.stderr)
    $env:FAKE_METAEDITOR_MODE='success';$env:FAKE_METAEDITOR_SNAPSHOT_HEADER=$header;$env:FAKE_METAEDITOR_SNAPSHOT_TRACE=Join-Path $root 'header-lock.txt'
    $compiled=Run 'Invoke-Mql5Project.ps1' @{ProfilePath=$profile;Action='Compile';CaptureSourceSnapshot=$true;PythonPath=$python;SuppressLogOutput=$true}
    Check ($compiled.exit_code -eq 0 -and $compiled.cleanup_verified) ('Snapshot compilation failed: '+$compiled.stdout+' '+$compiled.stderr)
    Check ([IO.File]::ReadAllText($env:FAKE_METAEDITOR_SNAPSHOT_TRACE) -ceq 'blocked') 'Known header was not locked during compiler execution'
    $receipt=[regex]::Match($compiled.stdout,'(?m)^MQL5_COMPILE_RECEIPT=(.+)\r?$').Groups[1].Value.TrimEnd("`r")
    $snapshot=[regex]::Match($compiled.stdout,'(?m)^MQL5_BUILD_SNAPSHOT=(.+)\r?$').Groups[1].Value.TrimEnd("`r")
    Check ((Test-Path $receipt) -and (Test-Path $snapshot)) 'Receipt/snapshot evidence missing'
    $value=Read-Mql5ReleaseJson $snapshot
    Check ($value.schema_version -eq 1 -and $value.compilation_receipt.sha256 -ceq (Get-Mql5ReleaseHash $receipt)) 'Receipt commitment mismatch'
    $inventory=Read-Mql5ReleaseJson $value.before.path
    Check ($inventory.files.Count -eq 2 -and $inventory.dependencies.Count -eq 2) 'Shared conditional inventory was not retained'
    $context=New-Mql5SnapshotLocks
    try {$verified=Test-Mql5BuildSnapshot $snapshot $receipt $source $context;Check ($verified.status -ceq 'verified_known_sources') 'Independent snapshot verification failed'} finally {Close-Mql5SnapshotLocks $context}
    [IO.File]::AppendAllText($header,'// after build')
    $rejected=Run 'Invoke-Mql5Project.ps1' @{ProfilePath=$profile;Action='TesterPreflight';CompilationReceiptPath=$receipt;BuildSnapshotPath=$snapshot;OutputDirectory=(Join-Path $root 'changed-preflight')}
    Check ($rejected.exit_code -eq 2) 'Changed known header was accepted by tester'
    $env:FAKE_MT5_MODE='hold';$env:FAKE_MT5_READY_PATH=Join-Path $root 'rejected-launch-marker'
    $rejectedExecution=Run 'Invoke-Mql5Project.ps1' @{ProfilePath=$profile;Action='TesterSmoke';CompilationReceiptPath=$receipt;BuildSnapshotPath=$snapshot;OutputDirectory=(Join-Path $root 'rejected-smoke')}
    Check ($rejectedExecution.exit_code -eq 2 -and -not (Test-Path $env:FAKE_MT5_READY_PATH)) 'Rejected snapshot launched its selected terminal'
    $env:FAKE_MT5_MODE='pass'
    [IO.File]::WriteAllText($header,'// independent shared fixture')
    $originalHeader=Join-Path $root 'original-header.mqh';[IO.File]::Move($header,$originalHeader);[IO.File]::Copy($originalHeader,$header)
    $context=New-Mql5SnapshotLocks;$failed=$false
    try {Test-Mql5BuildSnapshot $snapshot $receipt $source $context | Out-Null} catch {$failed=$true} finally {Close-Mql5SnapshotLocks $context}
    Check $failed 'A byte-identical replacement header was accepted'
    [IO.File]::Delete($header);[IO.File]::Move($originalHeader,$header)
    $preflight=Run 'Invoke-Mql5Project.ps1' @{ProfilePath=$profile;Action='TesterPreflight';CompilationReceiptPath=$receipt;BuildSnapshotPath=$snapshot;OutputDirectory=(Join-Path $root 'valid-preflight')}
    $preflightResult=Read-Mql5ReleaseJson (Join-Path $root 'valid-preflight\smoke-result.json')
    Check ($preflight.exit_code -eq 0) ('Valid preflight failed: '+($preflightResult | ConvertTo-Json -Depth 4 -Compress)+' '+$preflight.stdout+' '+$preflight.stderr)
    $env:FAKE_MT5_RECEIPT_LOCK_PATHS=$source+'|'+$header
    $smoke=Run 'Invoke-Mql5Project.ps1' @{ProfilePath=$profile;Action='TesterSmoke';CompilationReceiptPath=$receipt;BuildSnapshotPath=$snapshot;OutputDirectory=(Join-Path $root 'locked-smoke')}
    Check ($smoke.exit_code -eq 0 -and $smoke.cleanup_verified) ('Snapshot tester failed or known files were writable: '+$smoke.stdout+' '+$smoke.stderr)
    $manifest=Join-Path $root 'scenarios.json';[IO.File]::WriteAllText($manifest,(@{schema_version=1;scenarios=@(@{id='snapshot';profile='project/profile.json'})}|ConvertTo-Json -Depth 5))
    $batch=Run 'Invoke-Mql5ScenarioBatch.ps1' @{ManifestPath=$manifest;Action='Execute';CaptureSourceSnapshot=$true;PythonPath=$python;OutputDirectory=(Join-Path $root 'batch')}
    $batchResult=Read-Mql5ReleaseJson (Join-Path $root 'batch\result.json')
    Check ($batchResult.scenarios[0].compile.exit_code -eq 0 -and $batchResult.scenarios[0].tester.exit_code -eq 0 -and $batchResult.scenarios[0].cleanup_verified) ('Snapshot batch did not hand off evidence: '+$batch.stdout+' '+$batch.stderr)
    foreach ($text in @('[]','[{}]','null','true','{}')) {
        $bad=Join-Path $root ('bad-'+[guid]::NewGuid().ToString('N')+'.json');[IO.File]::WriteAllText($bad,$text)
        $context=New-Mql5SnapshotLocks;$failed=$false
        try {Test-Mql5BuildSnapshot $bad $receipt $source $context | Out-Null} catch {$failed=$true} finally {Close-Mql5SnapshotLocks $context}
        Check $failed 'Malformed snapshot root was accepted'
    }
    foreach($field in @('compilation_receipt','before','after','comparison')) {
        $modified=Read-Mql5ReleaseJson $snapshot;$modified.$field.sha256='0'*64
        $bad=Join-Path $root ('mismatch-'+$field+'.json');[IO.File]::WriteAllText($bad,($modified|ConvertTo-Json -Depth 10))
        $context=New-Mql5SnapshotLocks;$failed=$false
        try {Test-Mql5BuildSnapshot $bad $receipt $source $context | Out-Null}catch{$failed=$true}finally{Close-Mql5SnapshotLocks $context}
        Check $failed ('Mismatched snapshot '+$field+' commitment was accepted')
    }
    $comparisonBytes=[IO.File]::ReadAllBytes($value.comparison.path)
    try {
        $comparison=Read-Mql5ReleaseJson $value.comparison.path;$comparison.sources[0].sha256='0'*64
        [IO.File]::WriteAllText($value.comparison.path,($comparison|ConvertTo-Json -Depth 10))
        $modified=Read-Mql5ReleaseJson $snapshot;$modified.comparison.sha256=Get-Mql5ReleaseHash $value.comparison.path;$modified.comparison.byte_length=(Get-Item $value.comparison.path).Length
        $bad=Join-Path $root 'forged-comparison.json';[IO.File]::WriteAllText($bad,($modified|ConvertTo-Json -Depth 10))
        $context=New-Mql5SnapshotLocks;$failed=$false
        try {Test-Mql5BuildSnapshot $bad $receipt $source $context|Out-Null}catch{$failed=$true}finally{Close-Mql5SnapshotLocks $context}
        Check $failed 'Comparison with a recomputed outer hash and wrong inventory commitments was accepted'
    } finally {[IO.File]::WriteAllBytes($value.comparison.path,$comparisonBytes)}
    $context=New-Mql5SnapshotLocks;$failed=$false
    try {Test-Mql5BuildSnapshot $snapshot '' $source $context | Out-Null} catch {$failed=$true} finally {Close-Mql5SnapshotLocks $context}
    Check $failed 'Snapshot without receipt was accepted'
    [IO.File]::Delete($header)
    $context=New-Mql5SnapshotLocks;$failed=$false
    try {Test-Mql5BuildSnapshot $snapshot $receipt $source $context | Out-Null} catch {$failed=$true} finally {Close-Mql5SnapshotLocks $context}
    Check $failed 'Deleted header was accepted'
    [IO.File]::WriteAllText($header,'// independent shared fixture')
    $env:FAKE_METAEDITOR_SNAPSHOT_FAIL_PUBLICATION='1'
    $verificationFailure=Run 'Invoke-Mql5Project.ps1' @{ProfilePath=$profile;Action='Compile';CaptureSourceSnapshot=$true;PythonPath=$python;SuppressLogOutput=$true}
    $successfulReceipt=[regex]::Match($verificationFailure.stdout,'(?m)^MQL5_COMPILE_RECEIPT=(.+)\r?$').Groups[1].Value.TrimEnd("`r")
    Check ($verificationFailure.exit_code -eq 2 -and $verificationFailure.stdout -match 'MQL5_BUILD_VERIFICATION=failed' -and (Read-Mql5ReleaseJson $successfulReceipt).exit_code -eq 0) 'Successful compiler result was lost after snapshot publication failure'
    $batchFailure=Run 'Invoke-Mql5ScenarioBatch.ps1' @{ManifestPath=$manifest;Action='Execute';CaptureSourceSnapshot=$true;PythonPath=$python;OutputDirectory=(Join-Path $root 'batch-verification-failure')}
    $batchFailureResult=Read-Mql5ReleaseJson (Join-Path $root 'batch-verification-failure\result.json')
    Check ($batchFailureResult.scenarios[0].reason -ceq 'build_verification_failed' -and (Read-Mql5ReleaseJson $batchFailureResult.scenarios[0].compile.receipt_path).exit_code -eq 0 -and $null -eq (Get-ToolkitValue $batchFailureResult.scenarios[0].tester 'exit_code')) 'Batch lost successful compilation evidence or launched after failed build verification'
    $env:FAKE_METAEDITOR_SNAPSHOT_FAIL_PUBLICATION=$null
    $env:FAKE_METAEDITOR_SNAPSHOT_HEADER=$null
    [IO.File]::Delete($header)
    [IO.File]::WriteAllText($source,'void OnTick() {}')
    $singleton=Run 'Invoke-Mql5Project.ps1' @{ProfilePath=$profile;Action='Compile';CaptureSourceSnapshot=$true;PythonPath=$python;SuppressLogOutput=$true}
    $singlePath=[regex]::Match($singleton.stdout,'(?m)^MQL5_BUILD_SNAPSHOT=(.+)\r?$').Groups[1].Value.TrimEnd("`r")
    $singleValue=Read-Mql5ReleaseJson $singlePath
    Check ($singleton.exit_code -eq 0 -and $singleValue.known_source_identities -is [array] -and $singleValue.known_source_identities.Count -eq 1) ('Single-source capture failed: '+$singleton.stdout+' '+$singleton.stderr+' '+($singleValue|ConvertTo-Json -Depth 8 -Compress))
    $context=New-Mql5SnapshotLocks
    try {Check ((Test-Mql5BuildSnapshot $singlePath $singleValue.compilation_receipt.path $source $context).status -ceq 'verified_known_sources') 'Singleton snapshot verification failed'} finally {Close-Mql5SnapshotLocks $context}
    $external=Join-Path $root 'external';[void][IO.Directory]::CreateDirectory((Join-Path $external 'Include'));[IO.File]::WriteAllText((Join-Path $external 'Include\External.mqh'),'// external')
    $externalProfile=Read-Mql5ReleaseJson $profile;$externalProfile.include_path=$external;$externalPath=Join-Path $project 'external-profile.json';[IO.File]::WriteAllText($externalPath,($externalProfile|ConvertTo-Json -Depth 8))
    [IO.File]::WriteAllText($source,"#include <External.mqh>`nvoid OnTick() {}")
    $externalRun=Run 'Invoke-Mql5Project.ps1' @{ProfilePath=$externalPath;Action='Compile';CaptureSourceSnapshot=$true;PythonPath=$python;SuppressLogOutput=$true}
    $externalSnapshot=Read-Mql5ReleaseJson ([regex]::Match($externalRun.stdout,'(?m)^MQL5_BUILD_SNAPSHOT=(.+)\r?$').Groups[1].Value.TrimEnd("`r"))
    Check ($externalRun.exit_code -eq 0 -and (Read-Mql5ReleaseJson $externalSnapshot.before.path).files.Count -eq 2) 'Explicit external standard root was not fingerprinted'
    $missingRoot=Join-Path $root 'missing-standard-root';[void][IO.Directory]::CreateDirectory($missingRoot);$externalProfile.include_path=$missingRoot;[IO.File]::WriteAllText($externalPath,($externalProfile|ConvertTo-Json -Depth 8))
    $uncertain=Run 'Invoke-Mql5Project.ps1' @{ProfilePath=$externalPath;Action='Compile';CaptureSourceSnapshot=$true;PythonPath=$python;SuppressLogOutput=$true}
    $uncertainSnapshot=Read-Mql5ReleaseJson ([regex]::Match($uncertain.stdout,'(?m)^MQL5_BUILD_SNAPSHOT=(.+)\r?$').Groups[1].Value.TrimEnd("`r"))
    Check ($uncertain.exit_code -eq 0 -and $uncertainSnapshot.coverage.before -ceq 'uncertain' -and ($uncertainSnapshot.limitations -join ' ') -match 'standard include directory was unavailable') 'Unavailable include-root coverage was not disclosed'
    $missing=Run 'Invoke-Mql5Project.ps1' @{ProfilePath=$profile;Action='Compile';CaptureSourceSnapshot=$true;PythonPath=(Join-Path $root 'missing-python.exe')}
    Check ($missing.exit_code -eq 2) 'Missing selected Python was accepted'
    $env:FAKE_METAEDITOR_MODE='errors'
    $failure=Run 'Invoke-Mql5Project.ps1' @{ProfilePath=$profile;Action='Compile';CaptureSourceSnapshot=$true;PythonPath=$python;SuppressLogOutput=$true}
    Check ($failure.exit_code -eq 1 -and $failure.stdout -notmatch 'MQL5_BUILD_SNAPSHOT=') 'Compiler failure lost its original exit code or emitted a valid snapshot'
    [IO.File]::AppendAllText($header,'// unlocked after failed compiler')
    $env:FAKE_METAEDITOR_MODE='timeout'
    $timeout=Run 'Invoke-Mql5Project.ps1' @{ProfilePath=$profile;Action='Compile';CaptureSourceSnapshot=$true;PythonPath=$python;SuppressLogOutput=$true}
    Check ($timeout.exit_code -eq 3 -and $timeout.cleanup_verified) 'Compiler timeout/cleanup changed'
    [IO.File]::AppendAllText($header,'// unlocked after timeout')
    Write-Output ('PASS: '+$checks+' build snapshot checks under '+$PSVersionTable.PSVersion)
} finally {
    foreach ($name in @('FAKE_METAEDITOR_MODE','FAKE_METAEDITOR_SNAPSHOT_HEADER','FAKE_METAEDITOR_SNAPSHOT_TRACE','FAKE_MT5_RECEIPT_LOCK_PATHS','FAKE_MT5_MODE','FAKE_MT5_READY_PATH','FAKE_METAEDITOR_SNAPSHOT_FAIL_PUBLICATION')) {[Environment]::SetEnvironmentVariable($name,$null,'Process')}
    $full=[IO.Path]::GetFullPath($root);$parent=[IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd('\')+'\'
    if ($full.StartsWith($parent,[StringComparison]::OrdinalIgnoreCase)) {Remove-Item -LiteralPath $full -Recurse -Force}
}
