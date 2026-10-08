#Requires -Version 5.1
[CmdletBinding()]
param([string]$PythonPath)
Set-StrictMode -Version Latest
$ErrorActionPreference='Stop'
$scripts=Join-Path (Split-Path -Parent $PSScriptRoot) 'skills\mql5-coding\scripts'
. (Join-Path $scripts 'BuildSourceSnapshot.ps1')
. (Join-Path $scripts 'CompilationReceipt.ps1')
. (Join-Path $scripts 'Mql5ProjectProfile.ps1')
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
    # Snapshot inventories have a distinct bounded evidence allowance. Keep
    # the default shared metadata limit unchanged for all other consumers.
    $largeJson='{"padding":"'+('x'*1048576)+'"}'
    $largeBytes=[Text.UTF8Encoding]::new($false).GetBytes($largeJson)
    $largePath=Join-Path $root 'large-snapshot.json';[IO.File]::WriteAllBytes($largePath,$largeBytes)
    $failed=$false;try{Read-Mql5ReleaseJson -Path $largePath|Out-Null}catch{$failed=$true};Check $failed 'Default release metadata limit changed'
    $failed=$false;$stream=[IO.MemoryStream]::new($largeBytes,$false)
    try{Read-Mql5JsonText $stream|Out-Null}catch{$failed=$true}finally{$stream.Dispose()};Check $failed 'Default JSON text limit changed'
    $context=New-Mql5SnapshotLocks
    try{$largeEvidence=Open-Mql5SnapshotJson $largePath $context;Check ($largeEvidence.value.padding.Length -eq 1048576 -and $largeEvidence.source.byte_length -eq $largeBytes.Length -and $largeEvidence.source.sha256 -ceq (Get-Mql5ReleaseHash $largePath)) 'Supported snapshot evidence above 1 MiB rejected or changed'}finally{Close-Mql5SnapshotLocks $context}
    $oversizedPath=Join-Path $root 'oversized-snapshot.json';$stream=[IO.File]::Open($oversizedPath,[IO.FileMode]::CreateNew,[IO.FileAccess]::Write,[IO.FileShare]::None)
    try{$stream.SetLength(16777217)}finally{$stream.Dispose()}
    $context=New-Mql5SnapshotLocks;$failed=$false
    try{Open-Mql5SnapshotJson $oversizedPath $context|Out-Null}catch{$failed=$true}finally{Close-Mql5SnapshotLocks $context};Check $failed 'Snapshot evidence hard limit changed'
    $stream=[IO.File]::OpenRead($oversizedPath);$failed=$false
    try{Read-Mql5JsonText $stream -MaximumBytes 16777216|Out-Null}catch{$failed=$true}finally{$stream.Dispose()};Check $failed 'Explicit JSON text hard limit changed'
    $failed=$false;try{Read-Mql5ReleaseJson -Path $largePath -MaximumBytes 16777217|Out-Null}catch{$failed=$true};Check $failed 'Internal JSON allowance exceeds 16 MiB'
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
    # Compiler versions are native resource text. Retain a valid value exactly,
    # but reject all non-string and blank shapes before metadata reaches a result.
    foreach($versionShape in @('valid','empty_array','singleton_array','multiple_array','null','object','numeric','boolean','empty_string','whitespace_string')){
        $changedReceipt=Read-Mql5ReleaseJson $receipt;$originalVersion=$changedReceipt.compiler.file_version
        switch($versionShape){empty_array{$changedReceipt.compiler.file_version=@()}singleton_array{$changedReceipt.compiler.file_version=@($originalVersion)}multiple_array{$changedReceipt.compiler.file_version=@($originalVersion,$originalVersion)}null{$changedReceipt.compiler.file_version=$null}object{$changedReceipt.compiler.file_version=[pscustomobject]@{version=$originalVersion}}numeric{$changedReceipt.compiler.file_version=5}boolean{$changedReceipt.compiler.file_version=$true}empty_string{$changedReceipt.compiler.file_version=''}whitespace_string{$changedReceipt.compiler.file_version=" `t "}}
        $versionReceipt=Join-Path $root ('version-'+$versionShape+'.receipt.json');[IO.File]::WriteAllText($versionReceipt,($changedReceipt|ConvertTo-Json -Depth 10))
        $validVersion=$versionShape -ceq 'valid';$context=New-Mql5SnapshotLocks;$failed=$false;$verifiedReceipt=$null
        try{$verifiedReceipt=Test-Mql5CompilationReceipt -Path $versionReceipt -ExpertPath ([IO.Path]::ChangeExtension($source,'.ex5')) -ExpectedExpertHash $null -Tracker $context.locks -PathEntryLeases $context.leases -LeasesByPath $context.by_path}catch{$failed=$true}finally{Close-Mql5SnapshotLocks $context}
        Check (($validVersion -and -not $failed -and $verifiedReceipt.compiler_file_version -is [string] -and $verifiedReceipt.compiler_file_version -ceq $originalVersion) -or (-not $validVersion -and $failed)) ('Receipt helper compiler-version shape accepted or changed: '+$versionShape)
        $changedSnapshot=Read-Mql5ReleaseJson $snapshot;$changedSnapshot.compilation_receipt=[pscustomobject]@{path=$versionReceipt;sha256=(Get-Mql5ReleaseHash $versionReceipt);byte_length=(Get-Item -LiteralPath $versionReceipt).Length}
        $versionSnapshot=Join-Path $root ('version-'+$versionShape+'.snapshot.json');[IO.File]::WriteAllText($versionSnapshot,($changedSnapshot|ConvertTo-Json -Depth 10))
        $context=New-Mql5SnapshotLocks;$failed=$false
        try{Test-Mql5BuildSnapshot $versionSnapshot $versionReceipt $source $context|Out-Null}catch{$failed=$true}finally{Close-Mql5SnapshotLocks $context}
        Check ($failed -eq (-not $validVersion)) ('Snapshot verification compiler-version shape accepted: '+$versionShape)
        $versionCapture=Start-Mql5BuildSnapshot (Read-Mql5ProjectProfile $profile) $source $python;$failed=$false;$captureResult=$null
        try{$captureResult=Complete-Mql5BuildSnapshot $versionCapture $versionReceipt}catch{$failed=$true}finally{Close-Mql5SnapshotLocks $versionCapture.locks}
        Check (($failed -eq (-not $validVersion)) -and (-not $validVersion -or (Test-Path -LiteralPath $captureResult -PathType Leaf))) ('Snapshot capture compiler-version shape accepted: '+$versionShape)
        $versionOutput=Join-Path $root ('version-'+$versionShape+'-preflight')
        $versionPreflight=Run 'Invoke-Mt5TesterSmoke.ps1' @{ExpertPath=[IO.Path]::ChangeExtension($source,'.ex5');CompilationReceiptPath=$versionReceipt;TerminalPath=$terminal;TerminalDataPath=$data;OutputDirectory=$versionOutput;PreflightOnly=$true;UseExpertDefaults=$true;Symbol='SYNTH';Period='M1';FromDate='2026.07.01';ToDate='2026.07.02';Model=0;Deposit='10000';Currency='USD';Leverage=100;ExecutionMode=0;TimeoutSeconds=10}
        $versionResultPath=Join-Path $versionOutput 'smoke-result.json'
        $versionResult=if(Test-Path -LiteralPath $versionResultPath -PathType Leaf){Read-Mql5ReleaseJson $versionResultPath}else{$null}
        # Receipt rejection precedes the output claim, so early failures may
        # deliberately have no result file. A valid control must retain one.
        Check ($versionPreflight.exit_code -eq $(if($validVersion){0}else{2}) -and $versionPreflight.cleanup_verified -and
            (($validVersion -and $null -ne $versionResult -and $versionResult.status -ceq 'preflight_passed' -and -not $versionResult.process.execution_attempted) -or
             (-not $validVersion -and ($null -eq $versionResult -or -not $versionResult.process.execution_attempted)))) ('Actual preflight compiler-version shape accepted: '+$versionShape)
    }
    $receiptEncodings=@{
        utf8=[Text.UTF8Encoding]::new($false,$true);utf8_bom=[Text.UTF8Encoding]::new($true,$true)
        utf16_le=[Text.UnicodeEncoding]::new($false,$true,$true);utf16_be=[Text.UnicodeEncoding]::new($true,$true,$true)
        utf32_le=[Text.UTF32Encoding]::new($false,$true,$true);utf32_be=[Text.UTF32Encoding]::new($true,$true,$true)
    }
    $byteCases=@('utf8','utf8_bom','utf16_le','utf16_be','utf32_le','utf32_be','literal_replacement','invalid_utf8','invalid_utf16_le','invalid_utf16_be','invalid_utf32_le','invalid_utf32_be')
    foreach($byteCase in $byteCases){
        $validBytes=-not $byteCase.StartsWith('invalid_',[StringComparison]::Ordinal)
        $encodingName=if($byteCase -ceq 'literal_replacement'){'utf8'}elseif($validBytes){$byteCase}else{$byteCase.Substring(8)}
        $encoding=$receiptEncodings[$encodingName]
        $encodedReceipt=Read-Mql5ReleaseJson $receipt;$expectedVersion='BYTE_ENCODING_SENTINEL'
        if($byteCase -ceq 'literal_replacement'){$expectedVersion=[string][char]0xfffd+$expectedVersion}
        $encodedReceipt.compiler.file_version=$expectedVersion;$text=$encodedReceipt|ConvertTo-Json -Depth 10
        [byte[]]$bytes=$encoding.GetPreamble()+$encoding.GetBytes($text)
        if(-not $validBytes){
            $position=$encoding.GetPreamble().Length+$encoding.GetByteCount($text.Substring(0,$text.IndexOf($expectedVersion,[StringComparison]::Ordinal)))
            # Independent physical encodings: forbidden UTF-8 byte, unpaired
            # UTF-16 high surrogate, or out-of-range UTF-32 code point.
            switch($encodingName){utf8{$bytes[$position]=255}utf16_le{$bytes[$position]=0;$bytes[$position+1]=216}utf16_be{$bytes[$position]=216;$bytes[$position+1]=0}utf32_le{$bytes[$position]=0;$bytes[$position+1]=0;$bytes[$position+2]=17;$bytes[$position+3]=0}utf32_be{$bytes[$position]=0;$bytes[$position+1]=17;$bytes[$position+2]=0;$bytes[$position+3]=0}}
        }
        $decoderRejected=$false;try{[void]$encoding.GetCharCount($bytes)}catch [Text.DecoderFallbackException]{$decoderRejected=$true}
        Check ($decoderRejected -eq (-not $validBytes)) ('Independent encoding fixture classification changed: '+$byteCase)
        $byteReceipt=Join-Path $root ('bytes-'+$byteCase+'.receipt.json');[IO.File]::WriteAllBytes($byteReceipt,$bytes)
        $context=New-Mql5SnapshotLocks;$failed=$false;$byteVerified=$null
        try{$byteVerified=Test-Mql5CompilationReceipt -Path $byteReceipt -ExpertPath ([IO.Path]::ChangeExtension($source,'.ex5')) -ExpectedExpertHash $null -Tracker $context.locks -PathEntryLeases $context.leases -LeasesByPath $context.by_path}catch{$failed=$true}finally{Close-Mql5SnapshotLocks $context}
        Check (($validBytes -and -not $failed -and $byteVerified.compiler_file_version -ceq $expectedVersion) -or (-not $validBytes -and $failed)) ('Physical receipt encoding accepted or changed: '+$byteCase)
        $byteOutput=Join-Path $root ('bytes-'+$byteCase+'-preflight')
        $bytePreflight=Run 'Invoke-Mt5TesterSmoke.ps1' @{ExpertPath=[IO.Path]::ChangeExtension($source,'.ex5');CompilationReceiptPath=$byteReceipt;TerminalPath=$terminal;TerminalDataPath=$data;OutputDirectory=$byteOutput;PreflightOnly=$true;UseExpertDefaults=$true;Symbol='SYNTH';Period='M1';FromDate='2026.07.01';ToDate='2026.07.02';Model=0;Deposit='10000';Currency='USD';Leverage=100;ExecutionMode=0;TimeoutSeconds=10}
        $byteResultPath=Join-Path $byteOutput 'smoke-result.json';$byteResult=if(Test-Path -LiteralPath $byteResultPath -PathType Leaf){Read-Mql5ReleaseJson $byteResultPath}else{$null}
        Check ($bytePreflight.exit_code -eq $(if($validBytes){0}else{2}) -and $bytePreflight.cleanup_verified -and
            (($validBytes -and $null -ne $byteResult -and $byteResult.status -ceq 'preflight_passed' -and -not $byteResult.process.execution_attempted -and $byteResult.inputs.compilation_receipt.compiler_file_version -ceq $expectedVersion) -or
             (-not $validBytes -and ($null -eq $byteResult -or -not $byteResult.process.execution_attempted)))) ('Actual preflight physical receipt encoding accepted or changed: '+$byteCase)
    }
    # Serialized arrays must not satisfy scalar identities through PowerShell's
    # element-wise comparison operators. Refresh outer commitments so failures
    # prove schema rejection, rather than merely detecting an outdated hash.
    function ShapeCommitment([string]$Path){return [pscustomobject]@{path=$Path;sha256=(Get-Mql5ReleaseHash $Path);byte_length=(Get-Item -LiteralPath $Path).Length}}
    $shapeFields=@(
        [pscustomobject]@{section='snapshot';field='kind'},[pscustomobject]@{section='snapshot';field='status'},
        [pscustomobject]@{section='coverage';field='before'},[pscustomobject]@{section='coverage';field='after'}
    )
    foreach($section in @('comparison','before','after','compilation_receipt')){
        $fields=switch($section){comparison{@('schema_version','operation','status')}compilation_receipt{@('schema_version','kind','status','exit_code','syntax_only')}default{@('schema_version','operation','status','coverage')}}
        foreach($field in $fields){$shapeFields+=@([pscustomobject]@{section=$section;field=$field})}
    }
    $malformedKind=$null
    foreach($selection in $shapeFields){
        foreach($shape in @('empty','singleton','multiple')){
            $changed=Read-Mql5ReleaseJson $snapshot
            $target=if($selection.section -ceq 'snapshot'){$changed}elseif($selection.section -ceq 'coverage'){$changed.coverage}else{Read-Mql5ReleaseJson $changed.($selection.section).path}
            $original=$target.($selection.field)
            $target.($selection.field)=switch($shape){empty{,@()}singleton{,@($original)}multiple{,@($original,$original)}}
            if($target.($selection.field) -isnot [array]){throw 'Malformed scalar fixture did not retain its intended array shape.'}
            $leaf='shape-'+$selection.section+'-'+$selection.field+'-'+$shape
            if($selection.section -notin @('snapshot','coverage')){
                $evidencePath=Join-Path $root ($leaf+'.evidence.json');[IO.File]::WriteAllText($evidencePath,($target|ConvertTo-Json -Depth 10))
                $changed.($selection.section)=ShapeCommitment $evidencePath
                if($selection.section -in @('before','after')){
                    $comparison=Read-Mql5ReleaseJson $changed.comparison.path
                    $comparison.sources[$(if($selection.section -ceq 'before'){0}else{1})]=ShapeCommitment $evidencePath
                    $comparisonPath=Join-Path $root ($leaf+'.comparison.json');[IO.File]::WriteAllText($comparisonPath,($comparison|ConvertTo-Json -Depth 10));$changed.comparison=ShapeCommitment $comparisonPath
                }
            }
            $bad=Join-Path $root ($leaf+'.snapshot.json');[IO.File]::WriteAllText($bad,($changed|ConvertTo-Json -Depth 10))
            $selectedReceipt=$changed.compilation_receipt.path
            $context=New-Mql5SnapshotLocks;$failed=$false
            try{Test-Mql5BuildSnapshot $bad $selectedReceipt $source $context|Out-Null}catch{$failed=$true}finally{Close-Mql5SnapshotLocks $context}
            Check $failed ('Array-valued scalar accepted: '+$leaf)
            if($selection.section -ceq 'snapshot' -and $selection.field -ceq 'kind' -and $shape -ceq 'singleton'){$malformedKind=$bad}
        }
    }
    # The actual project/tester chain must reject malformed evidence before its
    # selected synthetic terminal can start, as well as through the helper API.
    $env:FAKE_MT5_MODE='hold';$env:FAKE_MT5_READY_PATH=Join-Path $root 'shape-rejected-launch-marker'
    $shapePreflight=Run 'Invoke-Mql5Project.ps1' @{ProfilePath=$profile;Action='TesterPreflight';CompilationReceiptPath=$receipt;BuildSnapshotPath=$malformedKind;OutputDirectory=(Join-Path $root 'shape-rejected-preflight')}
    Check ($shapePreflight.exit_code -eq 2 -and -not(Test-Path $env:FAKE_MT5_READY_PATH)) 'Malformed snapshot passed actual tester preflight'
    $shapeExecution=Run 'Invoke-Mql5Project.ps1' @{ProfilePath=$profile;Action='TesterSmoke';CompilationReceiptPath=$receipt;BuildSnapshotPath=$malformedKind;OutputDirectory=(Join-Path $root 'shape-rejected-execution')}
    Check ($shapeExecution.exit_code -eq 2 -and -not(Test-Path $env:FAKE_MT5_READY_PATH)) 'Malformed snapshot launched its selected terminal'
    $env:FAKE_MT5_MODE='pass'
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
