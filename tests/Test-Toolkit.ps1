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
function New-JournalCase([string]$Name,[string]$Text) {
    $path=Join-Path $testRoot ($Name+'.log');[IO.File]::WriteAllText($path,$Text,[Text.Encoding]::Unicode)
    $length=(Get-Item -LiteralPath $path).Length
    $runPath=Join-Path $testRoot ($Name+'.json')
    Save $runPath @{schema_version=2;status='engine_smoke_passed';evidence=@{terminal_journal=@{appended_byte_length=$length;limit_exceeded=$false;segments=@(@{path=$path;source_offset=0;byte_length=$length;sha256=(Get-Mql5ReleaseHash $path)});excerpts=@()};tester_journal=@{appended_byte_length=0;limit_exceeded=$false;segments=@();excerpts=@()}}}
    return $runPath
}
function New-JournalSegment([string]$Path,[int]$Offset,[int]$Length) {
    $data=[IO.File]::ReadAllBytes($Path);$sha=[Security.Cryptography.SHA256]::Create()
    try {$hash=([BitConverter]::ToString($sha.ComputeHash($data,$Offset,$Length))).Replace('-','').ToLowerInvariant()} finally {$sha.Dispose()}
    return [pscustomobject]@{path=$Path;source_offset=$Offset;byte_length=$Length;sha256=$hash}
}
$oldTrace=$env:MQL5_SCENARIO_TEST_TRACE;$oldReport=$env:MQL5_SCENARIO_TEST_REPORT
try {
    $python=if ($PythonPath) {Get-ToolkitPython $PythonPath} elseif (Get-Command python -ErrorAction SilentlyContinue) {(Get-Command python).Source} else {Get-ToolkitPython ''}
    $publication=Invoke-ToolkitProcess $hostExe @('-NoLogo','-NoProfile','-NonInteractive','-ExecutionPolicy','Bypass','-File',(Join-Path $PSScriptRoot 'Test-ToolkitPublication.ps1'),'-PythonPath',$python) $testRoot 90
    Check ($publication.exit_code -eq 0 -and $publication.cleanup_verified -and $publication.stdout -match 'TOOLKIT_PUBLICATION_TESTS=32') ('Toolkit output failure checks failed: '+$publication.stderr)
    Check ((Get-ToolkitValue @{exit_code=3} 'exit_code') -eq 3 -and (Get-ToolkitValue ([ordered]@{exit_code=4}) 'exit_code') -eq 4) 'Dictionary exit codes are retained'
    $raceEvidence=& {
        $script:toolkitRaceOutput=Join-Path $testRoot 'output-creation-race'
        $script:toolkitRaceParent=$testRoot;$script:toolkitRaceTriggered=$false
        $sentinel='Previously retained evidence'
        function Test-Path {
            param([string]$LiteralPath,[string]$PathType)
            if ($LiteralPath -eq $script:toolkitRaceParent -and $PathType -eq 'Container' -and -not $script:toolkitRaceTriggered) {
                [IO.Directory]::CreateDirectory($script:toolkitRaceOutput) | Out-Null
                [IO.File]::WriteAllText((Join-Path $script:toolkitRaceOutput 'summary.txt'),$sentinel)
                $script:toolkitRaceTriggered=$true
            }
            return Microsoft.PowerShell.Management\Test-Path @PSBoundParameters
        }
        $rejected=$false
        try {
            $claimed=New-ToolkitOutput $script:toolkitRaceOutput
            Save-ToolkitResult $claimed @{schema_version=1;status='completed';operation='race fixture'} @('Replacement evidence') | Out-Null
        } catch {$rejected=$true}
        [pscustomobject]@{rejected=$rejected;triggered=$script:toolkitRaceTriggered;preserved=([IO.File]::ReadAllText((Join-Path $script:toolkitRaceOutput 'summary.txt')) -ceq $sentinel);owner_created=(Microsoft.PowerShell.Management\Test-Path -LiteralPath (Join-Path $script:toolkitRaceOutput '.toolkit-owner'));result_created=(Microsoft.PowerShell.Management\Test-Path -LiteralPath (Join-Path $script:toolkitRaceOutput 'result.json'))}
    }
    Check ($raceEvidence.triggered -and $raceEvidence.rejected -and $raceEvidence.preserved -and -not $raceEvidence.owner_created -and -not $raceEvidence.result_created) 'A directory created between checks cannot be claimed or have its evidence overwritten'
    $newOutput=Join-Path $testRoot ('new output '+[char]0xe9)
    $claimedOutput=New-ToolkitOutput $newOutput
    $reused=$false;try {New-ToolkitOutput $newOutput | Out-Null} catch {$reused=$true}
    Check ($claimedOutput -ceq $newOutput -and $reused -and (Get-Item -LiteralPath (Join-Path $newOutput '.toolkit-owner')).Length -eq 32) 'A new Unicode output directory is claimed once and repeat use is refused'
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
    $run.evidence.tester_journal=$journal;Save $runPath $run
    $crossOverlap=Join-Path $testRoot 'journal-cross-overlap'
    $process=Run 'Read-Mql5Journal.ps1' @('-TesterResultPath',$runPath,'-OutputDirectory',$crossOverlap)
    Check ($process.exit_code -eq 4 -and (ReadResult $crossOverlap).inspected_lines -eq 3) 'Same segment recorded under both journal kinds is counted once'
    $journalAlias=Join-Path $testRoot 'journal-hardlink.log'
    New-Item -ItemType HardLink -Path $journalAlias -Target $journalPath | Out-Null
    $aliasRecord=New-JournalSegment $journalAlias $record.source_offset $record.byte_length
    $run.evidence.tester_journal=[pscustomobject]@{appended_byte_length=$record.byte_length;limit_exceeded=$false;segments=@($aliasRecord);excerpts=@()}
    Save $runPath $run
    $aliasOverlap=Join-Path $testRoot 'journal-alias-overlap'
    $process=Run 'Read-Mql5Journal.ps1' @('-TesterResultPath',$runPath,'-OutputDirectory',$aliasOverlap)
    $aliasRead=ReadResult $aliasOverlap
    Check ($process.exit_code -eq 4 -and $aliasRead.inspected_lines -eq 3 -and $aliasRead.evidence_status -eq 'partial_segments' -and $aliasRead.segments[0].file_identity -ceq $aliasRead.segments[1].file_identity) 'Hard-link aliases cannot make duplicate physical journal ranges complete evidence'
    $run.evidence.tester_journal.segments=@($record)
    $run.evidence.tester_journal.excerpts=@("AA`t0`t10:00:01.000`tFixture`tpassword=duplicate excerpt")
    Save $runPath $run
    $overlapExcerpt=Join-Path $testRoot 'journal-overlap-excerpt'
    $process=Run 'Read-Mql5Journal.ps1' @('-TesterResultPath',$runPath,'-OutputDirectory',$overlapExcerpt)
    $excerptRead=ReadResult $overlapExcerpt
    Check ($process.exit_code -eq 4 -and $excerptRead.inspected_lines -eq 3 -and $excerptRead.budgeted_bytes -eq $buffer.Length -and @($excerptRead.issues | Where-Object {$_.code -eq 'overlap_excerpt_fallback_skipped'}).Count -eq 1) 'Known overlapping segments cannot be counted again through unverified fallback excerpts'
    $run.evidence.tester_journal.segments=@($aliasRecord);Save $runPath $run
    $aliasExcerpt=Join-Path $testRoot 'journal-alias-excerpt'
    $process=Run 'Read-Mql5Journal.ps1' @('-TesterResultPath',$runPath,'-OutputDirectory',$aliasExcerpt)
    Check ($process.exit_code -eq 4 -and (ReadResult $aliasExcerpt).inspected_lines -eq 3) 'Alias overlap also prevents fallback duplicate observations'
    $journalCopy=Join-Path $testRoot 'journal-independent-copy.log'
    Copy-Item -LiteralPath $journalPath -Destination $journalCopy
    $run.evidence.tester_journal.segments=@(New-JournalSegment $journalCopy $record.source_offset $record.byte_length)
    $run.evidence.tester_journal.excerpts=@();Save $runPath $run
    $independentOut=Join-Path $testRoot 'journal-independent-copy'
    $process=Run 'Read-Mql5Journal.ps1' @('-TesterResultPath',$runPath,'-OutputDirectory',$independentOut)
    $independentRead=ReadResult $independentOut
    Check ($process.exit_code -eq 0 -and $independentRead.inspected_lines -eq 6 -and $independentRead.segments[0].file_identity -cne $independentRead.segments[1].file_identity) 'Equal bytes in independent files remain distinct journal evidence'
    $firstLineBytes=$encoding.GetByteCount(($segment -split "`r`n")[0]+"`r`n")
    $run.evidence.terminal_journal=[pscustomobject]@{appended_byte_length=$firstLineBytes;limit_exceeded=$false;segments=@(New-JournalSegment $journalPath $record.source_offset $firstLineBytes);excerpts=@()}
    $run.evidence.tester_journal=[pscustomobject]@{appended_byte_length=($record.byte_length-$firstLineBytes);limit_exceeded=$false;segments=@(New-JournalSegment $journalAlias ($record.source_offset+$firstLineBytes) ($record.byte_length-$firstLineBytes));excerpts=@()}
    Save $runPath $run
    $disjointOut=Join-Path $testRoot 'journal-alias-disjoint'
    $process=Run 'Read-Mql5Journal.ps1' @('-TesterResultPath',$runPath,'-OutputDirectory',$disjointOut)
    Check ($process.exit_code -eq 0 -and (ReadResult $disjointOut).inspected_lines -eq 3) 'Non-overlapping ranges through file aliases remain complete evidence'
    $budgetPath=New-JournalCase 'overlap-budget' ("AA`t0`t10:00:01.000`tFixture`t"+('x'*500)+"`r`nBB`t0`t10:00:02.000`tFixture`t"+('y'*500)+"`r`n")
    $budgetRun=Read-Mql5ReleaseJson $budgetPath;$budgetRecord=$budgetRun.evidence.terminal_journal.segments[0]
    $budgetAlias=Join-Path $testRoot 'overlap-budget-alias.log'
    New-Item -ItemType HardLink -Path $budgetAlias -Target $budgetRecord.path | Out-Null
    foreach ($selectedPath in @($budgetRecord.path,$budgetAlias)) {
        $budgetRun.evidence.tester_journal=[pscustomobject]@{appended_byte_length=$budgetRecord.byte_length;limit_exceeded=$false;segments=@(New-JournalSegment $selectedPath 0 $budgetRecord.byte_length);excerpts=@()}
        Save $budgetPath $budgetRun
        $budgetOutput=Join-Path $testRoot ('journal-overlap-budget-'+[guid]::NewGuid().ToString('N'))
        $process=Run 'Read-Mql5Journal.ps1' @('-TesterResultPath',$budgetPath,'-OutputDirectory',$budgetOutput,'-MaxBytes',([string]$budgetRecord.byte_length))
        $budgetRead=ReadResult $budgetOutput
        Check ($process.exit_code -eq 4 -and $budgetRead.inspected_lines -eq 2 -and $budgetRead.evidence_status -eq 'partial_segments' -and -not $budgetRead.truncated -and $budgetRead.budgeted_bytes -eq $budgetRecord.byte_length) 'Skipped physical overlap cannot consume the byte budget or invent truncation'
    }
    $run.evidence.terminal_journal=$journal
    $run.evidence.tester_journal=[pscustomobject]@{appended_byte_length=0;limit_exceeded=$false;segments=@();excerpts=@()}
    $excerptPath=Join-Path $testRoot 'excerpts-only.json'
    Save $excerptPath @{schema_version=2;status='engine_smoke_passed';evidence=@{terminal_journal=@{appended_byte_length=4096;segments=@();excerpts=@(('x'*2048))};tester_journal=$run.evidence.tester_journal}}
    $largeExcerpt=Join-Path $testRoot 'journal-large-excerpt'
    $process=Run 'Read-Mql5Journal.ps1' @('-TesterResultPath',$excerptPath,'-OutputDirectory',$largeExcerpt,'-MaxBytes','1024')
    Check ($process.exit_code -eq 4 -and (ReadResult $largeExcerpt).truncated -and (ReadResult $largeExcerpt).inspected_lines -eq 0) 'Fallback excerpts obey the byte limit'
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

    $emptyCase=New-JournalCase 'empty-message' "AA`t0`t10:00:01.000`tFixture`t`r`nBB`t0`t10:00:02.000`tFixture`tafter-empty`r`n"
    $emptyOut=Join-Path $testRoot 'journal-empty-message'
    $process=Run 'Read-Mql5Journal.ps1' @('-TesterResultPath',$emptyCase,'-OutputDirectory',$emptyOut)
    $emptyRead=ReadResult $emptyOut
    Check ($process.exit_code -eq 0 -and $emptyRead.inspected_lines -eq 2 -and $emptyRead.grouped_lines -eq 2 -and @($emptyRead.groups | Where-Object {$_.message -eq 'after-empty'}).Count -eq 1) 'Empty journal messages cannot silently stop processing of later observations'
    $markerCase=New-JournalCase 'marker-fields' ("AA`t0`t10:00:01.000`tMQL5_CODING_PASS:"+('a'*32)+":component_id`tMQL5_CODING_PASS:"+('1'*32)+":application-case`r`n")
    $markerOut=Join-Path $testRoot 'journal-marker-fields'
    $process=Run 'Read-Mql5Journal.ps1' @('-TesterResultPath',$markerCase,'-OutputDirectory',$markerOut)
    $markerRead=ReadResult $markerOut;$markerJson=[IO.File]::ReadAllText((Join-Path $markerOut 'result.json'))
    Check ($process.exit_code -eq 0 -and $markerRead.groups[0].component -eq '<APPLICATION_MARKER>' -and $markerRead.groups[0].message -eq '<APPLICATION_MARKER>' -and $markerJson -notmatch 'MQL5_CODING_PASS|component_id|application-case') 'Marker masking covers component fields and precedes generic numeric redaction'
    $processingScripts=Join-Path $testRoot 'processing-failure-scripts';Copy-Item -LiteralPath $scripts -Destination $processingScripts -Recurse
    $journalHelper=Join-Path $processingScripts 'Read-Mql5Journal.ps1'
    $journalCode=[IO.File]::ReadAllText($journalHelper).Replace('Add-JournalObservation $content $kind $file ($segment.source_offset+2*$line.Index) $lineNumber $true','throw "Synthetic observation failure."')
    [IO.File]::WriteAllText($journalHelper,$journalCode,(New-Object Text.UTF8Encoding($false)))
    $failedObservations=Join-Path $testRoot 'journal-processing-failure'
    $process=Run 'Read-Mql5Journal.ps1' @('-TesterResultPath',$emptyCase,'-OutputDirectory',$failedObservations) $processingScripts
    $failedRead=ReadResult $failedObservations
    Check ($process.exit_code -eq 4 -and $failedRead.evidence_status -eq 'partial_segments' -and $failedRead.segments[0].status -eq 'processing_failed' -and $failedRead.segments[0].hash_verified -eq $true) 'Verified bytes with failed observation processing cannot become complete journal evidence'

    $casePath=New-JournalCase 'case-distinct' "AA`t0`t10:00:01.000`tFixture`tSignalA ready`r`nBB`t0`t10:00:02.000`tFixture`tsignala ready`r`nCC`t0`t10:00:03.000`tfixture`tSignalA ready`r`n"
    $caseOut=Join-Path $testRoot 'journal-case-distinct'
    $process=Run 'Read-Mql5Journal.ps1' @('-TesterResultPath',$casePath,'-OutputDirectory',$caseOut)
    $caseRead=ReadResult $caseOut
    Check ($process.exit_code -eq 0 -and $caseRead.groups.Count -eq 3 -and @($caseRead.groups | Where-Object {$_.count -ne 1}).Count -eq 0) 'Case-distinct redacted messages and components remain distinct groups'

    $largePath=New-JournalCase 'budget-corrupt' ('x'*500)
    $largeRun=Read-Mql5ReleaseJson $largePath
    $largeRecord=$largeRun.evidence.terminal_journal.segments[0];$largeRecord.sha256='0'*64
    $laterPath=New-JournalCase 'budget-later' "AA`t0`t10:00:04.000`tFixture`tlater message`r`n"
    $laterRecord=(Read-Mql5ReleaseJson $laterPath).evidence.terminal_journal.segments[0]
    $largeRun.evidence.terminal_journal.segments=@($largeRecord,$laterRecord)
    $largeRun.evidence.terminal_journal.appended_byte_length=$largeRecord.byte_length+$laterRecord.byte_length
    Save $largePath $largeRun
    $budgetOut=Join-Path $testRoot 'journal-invalid-segment-budget'
    $process=Run 'Read-Mql5Journal.ps1' @('-TesterResultPath',$largePath,'-OutputDirectory',$budgetOut,'-MaxBytes','1024')
    $budgetRead=ReadResult $budgetOut
    Check ($process.exit_code -eq 4 -and $budgetRead.truncated -and $budgetRead.inspected_lines -eq 0 -and -not $budgetRead.segments[1].hash_verified -and $budgetRead.budgeted_bytes -eq $largeRecord.byte_length) 'Invalid segment buffers consume the budget before later segment reads'
    $largeRun.evidence.terminal_journal.segments=@($largeRecord)
    $largeRun.evidence.terminal_journal.appended_byte_length=$largeRecord.byte_length
    $largeRun.evidence.terminal_journal.excerpts=@('fallback message should not fit')
    Save $largePath $largeRun
    $fallbackBudgetOut=Join-Path $testRoot 'journal-invalid-segment-fallback-budget'
    $process=Run 'Read-Mql5Journal.ps1' @('-TesterResultPath',$largePath,'-OutputDirectory',$fallbackBudgetOut,'-MaxBytes','1024')
    $fallbackBudgetRead=ReadResult $fallbackBudgetOut
    Check ($process.exit_code -eq 4 -and $fallbackBudgetRead.truncated -and $fallbackBudgetRead.inspected_lines -eq 0 -and $fallbackBudgetRead.budgeted_bytes -eq $largeRecord.byte_length) 'Invalid segment buffers also consume the fallback excerpt budget'

    $jsonDriftScripts=Join-Path $testRoot 'json-drift-scripts';Copy-Item -LiteralPath $scripts -Destination $jsonDriftScripts -Recurse
    $releasePath=Join-Path $jsonDriftScripts 'SkillRelease.ps1'
    $releaseCode=[IO.File]::ReadAllText($releasePath)
    $replacement='$parsed=($text | ConvertFrom-Json); if ($parsed.PSObject.Properties["evidence"]) {$changed=($text | ConvertFrom-Json);$changed.status="blocked";[IO.File]::WriteAllText($Path,($changed | ConvertTo-Json -Depth 12 -Compress),(New-Object Text.UTF8Encoding($false)))}; return $parsed'
    if (-not $releaseCode.Contains('return ($text | ConvertFrom-Json)')) {throw 'JSON drift fixture anchor unavailable.'}
    [IO.File]::WriteAllText($releasePath,$releaseCode.Replace('return ($text | ConvertFrom-Json)',$replacement),(New-Object Text.UTF8Encoding($false)))
    $sourceBeforeHash=Get-Mql5ReleaseHash $casePath;$sourceBeforeLength=(Get-Item -LiteralPath $casePath).Length
    $jsonDriftOut=Join-Path $testRoot 'journal-json-source-drift'
    $process=Run 'Read-Mql5Journal.ps1' @('-TesterResultPath',$casePath,'-OutputDirectory',$jsonDriftOut) $jsonDriftScripts
    $jsonDriftRead=ReadResult $jsonDriftOut
    Check ($process.exit_code -eq 0 -and $jsonDriftRead.recorded_run_status -eq 'engine_smoke_passed' -and $jsonDriftRead.source.sha256 -ceq $sourceBeforeHash -and $jsonDriftRead.source.byte_length -eq $sourceBeforeLength -and (Get-Mql5ReleaseHash $casePath) -cne $sourceBeforeHash) 'Journal JSON provenance fingerprints the consumed bytes despite a subsequent replacement'

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
$code=$LASTEXITCODE
# The synthetic tester records the profile's selected execution setting. This
# validates analysis integration, not real MetaTrader delay behavior.
$runPath=Join-Path $OutputDirectory 'smoke-result.json'
if ($Action -eq 'TesterSmoke' -and (Test-Path -LiteralPath $runPath -PathType Leaf)) {
    $run=Get-Content -LiteralPath $runPath -Raw -Encoding UTF8 | ConvertFrom-Json
    $run.inputs.execution_mode=$p.tester.settings.execution_mode
    [IO.File]::WriteAllText($runPath,($run | ConvertTo-Json -Depth 12),(New-Object Text.UTF8Encoding($false)))
}
$global:LASTEXITCODE=$code
exit $LASTEXITCODE
'@
    [IO.File]::WriteAllText((Join-Path $fixtureScripts 'Invoke-Mql5Project.ps1'),$stub,(New-Object Text.UTF8Encoding($false)))
    $env:MQL5_SCENARIO_TEST_TRACE=Join-Path $testRoot 'trace.txt'
    $env:MQL5_SCENARIO_TEST_REPORT=Join-Path $PSScriptRoot 'fixtures\reports\no-trades.htm'
    $profiles=@{}
    foreach ($mode in @('success','compiler-failure','tester-failure','timeout','blocked','missing-result','cleanup-failure','bad-report','missing-report','wrong-report-hash')) {
        $path=Join-Path $testRoot ($mode+'-profile.json')
        $profile=@{schema_version=1;name=$mode;project_root=$project;entrypoints=@('Fixture.mq5');include_path='Include';metaeditor_path=$editor;compiler=@{timeout_seconds=5;warnings_as_errors=$false};tester=@{entrypoint='Fixture.mq5';terminal_path=$terminal;terminal_data_path=$data;set_path=$null;use_expert_defaults=$true;timeout_seconds=10;settings=@{symbol='EURUSD';period='M1';from_date='2025.01.12';to_date='2025.02.28';model=0;deposit='100000';currency='USD';leverage=100;execution_mode=0}}}
        Save $path $profile;$profiles[$mode]=$path
    }
    $manifestPath=Join-Path $testRoot 'scenarios.json'
    Save $manifestPath @{schema_version=1;scenarios=@(@{id='success';profile=$profiles.success})}
    $validated=Join-Path $testRoot 'batch-validate'
    $process=Run 'Invoke-Mql5ScenarioBatch.ps1' @('-ManifestPath',$manifestPath,'-OutputDirectory',$validated,'-PythonPath',$python) $fixtureScripts
    Check ($process.exit_code -eq 0 -and -not (Test-Path -LiteralPath $env:MQL5_SCENARIO_TEST_TRACE)) ('Validation launched code or failed: '+$process.stderr+$process.stdout+((ReadResult $validated).issues | ConvertTo-Json -Compress))
    foreach ($case in @(
        @{name='trailing-lf';id="later`n"},
        @{name='trailing-crlf';id="later`r`n"},
        @{name='embedded-lf';id="la`nter"},
        @{name='trailing-tab';id="later`t"}
    )) {
        Save $manifestPath @{schema_version=1;scenarios=@(@{id='first';profile=$profiles.success},@{id=$case.id;profile=$profiles.success})}
        $manifestHash=Get-Mql5ReleaseHash $manifestPath
        foreach ($action in @('Validate','Execute')) {
            $rejected=Join-Path $testRoot ('batch-identity-'+$case.name+'-'+$action)
            $process=Run 'Invoke-Mql5ScenarioBatch.ps1' @('-ManifestPath',$manifestPath,'-OutputDirectory',$rejected,'-PythonPath',$python,'-Action',$action) $fixtureScripts
            $rejectedRead=ReadResult $rejected
            Check ($process.exit_code -eq 2 -and $process.cleanup_verified -and $rejectedRead.status -eq 'failed' -and $rejectedRead.scenarios.Count -eq 0 -and -not (Test-Path -LiteralPath $env:MQL5_SCENARIO_TEST_TRACE) -and (Get-Mql5ReleaseHash $manifestPath) -ceq $manifestHash) ($case.name+' scenario identity must fail '+$action+' before any earlier scenario executes')
        }
    }
    foreach ($id in @(('A'*64),'scenario_9-ok')) {
        Save $manifestPath @{schema_version=1;scenarios=@(@{id=$id;profile=$profiles.success})}
        $identityOutput=Join-Path $testRoot ('batch-valid-identity-'+[guid]::NewGuid().ToString('N'))
        $process=Run 'Invoke-Mql5ScenarioBatch.ps1' @('-ManifestPath',$manifestPath,'-OutputDirectory',$identityOutput,'-PythonPath',$python) $fixtureScripts
        $identityRead=ReadResult $identityOutput
        Check ($process.exit_code -eq 0 -and $identityRead.status -eq 'validated' -and $identityRead.scenarios[0].id -ceq $id -and -not (Test-Path -LiteralPath $env:MQL5_SCENARIO_TEST_TRACE)) 'Valid scenario identities retain their full spelling, including the 64-character boundary'
    }
    $nonce='a'*32
    $markerCases=@(
        @{name='punctuation';text=('MQL5_CODING_PASS:'+$nonce+':invalid!')},
        @{name='nested-label';text=('MQL5_CODING_PASS:'+$nonce+':invalid:label')},
        @{name='unicode-label';text=('MQL5_CODING_PASS:'+$nonce+':'+[char]0xe9)},
        @{name='long-label';text=('MQL5_CODING_PASS:'+$nonce+':'+('Z'*65))},
        @{name='utf16';text=('MQL5_CODING_PASS:'+$nonce+':fixture');utf16=$true},
        @{name='65-markers';text=((1..65 | ForEach-Object {'MQL5_CODING_PASS:'+$nonce+':case_'+$_}) -join "`n")},
        @{name='aggregate-limit';text=((1..64 | ForEach-Object {'MQL5_CODING_PASS:'+('F'*64)+':'+('x'*61)+$_.ToString('D3')}) -join "`n")},
        @{name='file-limit';text=('MQL5_CODING_PASS:'+$nonce+":fixture`n"+(' '*65536))}
    )
    foreach ($case in $markerCases) {
        $markerFile=Join-Path $testRoot ('invalid-'+$case.name+'-markers.txt')
        $encoding=if ($case.ContainsKey('utf16')) {[Text.Encoding]::Unicode} else {New-Object Text.UTF8Encoding($false)}
        [IO.File]::WriteAllText($markerFile,$case.text,$encoding)
        $markerHash=Get-Mql5ReleaseHash $markerFile
        Save $manifestPath @{schema_version=1;scenarios=@(@{id='first';profile=$profiles.success},@{id='invalid-marker';profile=$profiles.success;expected_marker_file=$markerFile})}
        foreach ($action in @('Validate','Execute')) {
            $rejected=Join-Path $testRoot ('batch-marker-'+$case.name+'-'+$action)
            $process=Run 'Invoke-Mql5ScenarioBatch.ps1' @('-ManifestPath',$manifestPath,'-OutputDirectory',$rejected,'-PythonPath',$python,'-Action',$action) $fixtureScripts
            $rejectedRead=ReadResult $rejected
            Check ($process.exit_code -eq 2 -and $process.cleanup_verified -and $rejectedRead.status -eq 'failed' -and $rejectedRead.scenarios.Count -eq 0 -and -not (Test-Path -LiteralPath $env:MQL5_SCENARIO_TEST_TRACE) -and (Get-Mql5ReleaseHash $markerFile) -ceq $markerHash) ($case.name+' markers must fail '+$action+' before any earlier scenario executes')
        }
    }
    foreach ($case in @(
        @{name='no-label';text=('MQL5_CODING_PASS:'+$nonce)},
        @{name='label-boundary';text=('MQL5_CODING_PASS:'+('F'*64)+':'+('Z'*64))},
        @{name='utf8-bom';text=("`r`nMQL5_CODING_PASS:"+$nonce+":Case_9.ok-`r`n");bom=$true},
        @{name='collection-boundary';text=((1..64 | ForEach-Object {'MQL5_CODING_PASS:'+('F'*64)+':'+('x'*43)+$_.ToString('D3')}) -join "`n")}
    )) {
        $markerFile=Join-Path $testRoot ('valid-'+$case.name+'-markers.txt')
        [IO.File]::WriteAllText($markerFile,$case.text,(New-Object Text.UTF8Encoding($case.ContainsKey('bom'))))
        $markerHash=Get-Mql5ReleaseHash $markerFile
        Save $manifestPath @{schema_version=1;scenarios=@(@{id='valid-marker';profile=$profiles.success;expected_marker_file=$markerFile})}
        $validOutput=Join-Path $testRoot ('batch-marker-'+$case.name)
        $process=Run 'Invoke-Mql5ScenarioBatch.ps1' @('-ManifestPath',$manifestPath,'-OutputDirectory',$validOutput,'-PythonPath',$python) $fixtureScripts
        Check ($process.exit_code -eq 0 -and (ReadResult $validOutput).status -eq 'validated' -and -not (Test-Path -LiteralPath $env:MQL5_SCENARIO_TEST_TRACE) -and (Get-Mql5ReleaseHash $markerFile) -ceq $markerHash) ($case.name+' markers remain valid without launching execution')
    }
    $randomProfile=Read-Mql5ReleaseJson $profiles.success
    $randomProfile.tester.settings.execution_mode=-1
    $randomProfilePath=Join-Path $testRoot 'random-delay-profile.json';Save $randomProfilePath $randomProfile
    Save $manifestPath @{schema_version=1;scenarios=@(@{id='random-delay';profile=$randomProfilePath})}
    $randomBatch=Join-Path $testRoot 'batch-random-delay'
    $process=Run 'Invoke-Mql5ScenarioBatch.ps1' @('-ManifestPath',$manifestPath,'-OutputDirectory',$randomBatch,'-PythonPath',$python,'-Action','Execute') $fixtureScripts
    $randomResult=ReadResult $randomBatch
    $randomAnalysis=Read-Mql5ReleaseJson $randomResult.scenarios[0].analysis[0].result_path
    Check ($process.exit_code -eq 0 -and $randomResult.scenarios[0].status -eq 'completed' -and $randomResult.scenarios[0].analysis[0].status -eq 'completed' -and $randomAnalysis.conditions.execution_mode -ceq '-1' -and $randomAnalysis.evidence_linkage.status -ceq 'hash_verified') 'A valid random-delay profile completes synthetic tester analysis with its recorded execution setting'
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
    $table=Import-Csv -LiteralPath (Join-Path $full 'results.tsv') -Delimiter "`t"
    Check ($table[1].compile_exit -eq '1' -and $table[3].tester_exit -eq '3' -and $table[4].recorded_tester_status -eq 'blocked') 'Combined table retains compiler and tester evidence'
    Check (@($batch.scenarios | Where-Object {$_.cleanup_verified -eq $false}).Count -eq 0) 'Mixed batch owned cleanup verified'
    foreach ($mode in @('missing-report','wrong-report-hash')) {
        Save $manifestPath @{schema_version=1;scenarios=@(@{id=$mode;profile=$profiles[$mode]})}
        $reportEvidence=Join-Path $testRoot ('batch-'+$mode)
        $process=Run 'Invoke-Mql5ScenarioBatch.ps1' @('-ManifestPath',$manifestPath,'-OutputDirectory',$reportEvidence,'-PythonPath',$python,'-Action','Execute') $fixtureScripts
        $batch=ReadResult $reportEvidence
        Check ($process.exit_code -eq 1 -and $batch.scenarios[0].status -eq 'completed' -and $batch.scenarios[0].tester.exit_code -eq 0 -and $batch.scenarios[0].analysis[0].status -eq 'failed') ('Completed tester cannot hide '+$mode+' evidence: exit='+$process.exit_code)
    }
    $driftScripts=Join-Path $testRoot 'drift-scripts';Copy-Item -LiteralPath $fixtureScripts -Destination $driftScripts -Recurse
    foreach ($stage in @('Compile','TesterSmoke')) {
    foreach ($mode in @('profile','marker','manifest')) {
        $markerFile=Join-Path $testRoot 'drift-markers.txt';[IO.File]::WriteAllText($markerFile,('MQL5_CODING_PASS:'+('a'*32)+':fixture'),(New-Object Text.UTF8Encoding($false)))
        Save $manifestPath @{schema_version=1;scenarios=@(@{id='drift';profile=$profiles.success;expected_marker_file=$markerFile},@{id='later';profile=$profiles.success})}
        $originalProfile=[IO.File]::ReadAllBytes($profiles.success)
        $change=if ($mode -eq 'profile') {
            '$p.name="changed"; [IO.File]::WriteAllText($ProfilePath,($p | ConvertTo-Json -Depth 12),(New-Object Text.UTF8Encoding($false)))'
        } elseif ($mode -eq 'marker') {
            '[IO.File]::WriteAllText('+"'"+$markerFile.Replace("'","''")+"'"+',"MQL5_CODING_PASS:'+('b'*32)+':fixture",(New-Object Text.UTF8Encoding($false)))'
        } else {
            '[IO.File]::AppendAllText('+"'"+$manifestPath.Replace("'","''")+"'"+'," ",(New-Object Text.UTF8Encoding($false)))'
        }
        $driftStub=$stub.Replace('exit $LASTEXITCODE',('if ($Action -eq "'+$stage+'") {'+$change+'}; exit $LASTEXITCODE'))
        [IO.File]::WriteAllText((Join-Path $driftScripts 'Invoke-Mql5Project.ps1'),$driftStub,(New-Object Text.UTF8Encoding($false)))
        $priorTrace=[IO.File]::ReadAllText($env:MQL5_SCENARIO_TEST_TRACE)
        $drift=Join-Path $testRoot ('batch-drift-'+$stage+'-'+$mode)
        $process=Run 'Invoke-Mql5ScenarioBatch.ps1' @('-ManifestPath',$manifestPath,'-OutputDirectory',$drift,'-PythonPath',$python,'-Action','Execute') $driftScripts
        $batch=ReadResult $drift
        $traceDelta=[IO.File]::ReadAllText($env:MQL5_SCENARIO_TEST_TRACE).Substring($priorTrace.Length)
        [IO.File]::WriteAllBytes($profiles.success,$originalProfile)
        $expectedTrace=if ($stage -eq 'Compile') {"Compile:success`n"} else {"Compile:success`nTesterSmoke:success`n"}
        $expectedStatus=if ($stage -eq 'Compile') {'failed'} else {'completed'}
        Check ($process.exit_code -eq 2 -and $batch.scenarios[0].status -eq $expectedStatus -and $batch.scenarios[0].reason -eq 'selection_changed' -and $batch.scenarios[0].analysis.Count -eq 0 -and $batch.scenarios[1].status -eq 'skipped' -and $traceDelta -eq $expectedTrace) ($mode+' drift during '+$stage+' must stop later execution: '+$traceDelta)
    }
    }
    $validationDriftScripts=Join-Path $testRoot 'validation-drift-scripts';Copy-Item -LiteralPath $fixtureScripts -Destination $validationDriftScripts -Recurse
    $supportPath=Join-Path $validationDriftScripts 'ToolkitSupport.ps1'
    $replacement='if ($Arguments -contains "--output") {[IO.File]::AppendAllText('+"'"+$manifestPath.Replace("'","''")+"'"+'," ",(New-Object Text.UTF8Encoding($false)))}; return [pscustomobject]$answer'
    $support=[IO.File]::ReadAllText($supportPath).Replace('return [pscustomobject]$answer',$replacement)
    [IO.File]::WriteAllText($supportPath,$support,(New-Object Text.UTF8Encoding($false)))
    Save $manifestPath @{schema_version=1;scenarios=@(@{id='validate-drift';profile=$profiles.success;baseline_report=$env:MQL5_SCENARIO_TEST_REPORT})}
    $validationDrift=Join-Path $testRoot 'batch-validation-drift';$priorTrace=[IO.File]::ReadAllText($env:MQL5_SCENARIO_TEST_TRACE)
    $process=Run 'Invoke-Mql5ScenarioBatch.ps1' @('-ManifestPath',$manifestPath,'-OutputDirectory',$validationDrift,'-PythonPath',$python,'-Action','Execute') $validationDriftScripts
    Check ($process.exit_code -eq 2 -and [IO.File]::ReadAllText($env:MQL5_SCENARIO_TEST_TRACE) -ceq $priorTrace) 'Manifest fingerprint must precede validation and reject drift before compilation'
    foreach ($boundary in @('tester','analysis','missing-analysis')) {
        $limitedScripts=Join-Path $testRoot ($boundary+'-limited-scripts');Copy-Item -LiteralPath $fixtureScripts -Destination $limitedScripts -Recurse
        $supportPath=Join-Path $limitedScripts 'ToolkitSupport.ps1'
        # Preserve real owned execution/cleanup and simulate the completed-child
        # race where output bounds are exceeded despite a zero process exit.
        $replacement=if ($boundary -eq 'tester') {
            'if ($Arguments -contains "-EncodedCommand" -and [Text.Encoding]::Unicode.GetString([Convert]::FromBase64String($Arguments[-1])).Contains("TesterSmoke")) {$answer.status="output_limit"}; return [pscustomobject]$answer'
        } elseif ($boundary -eq 'analysis') {
            'if ($Executable.EndsWith("python.exe",[StringComparison]::OrdinalIgnoreCase)) {$answer.status="output_limit"}; return [pscustomobject]$answer'
        } else {
            'if ($Executable.EndsWith("python.exe",[StringComparison]::OrdinalIgnoreCase) -and $Arguments -contains "--output") {[IO.File]::Delete((Join-Path $Arguments[[Array]::IndexOf($Arguments,"--output")+1] "result.json"))}; return [pscustomobject]$answer'
        }
        $support=[IO.File]::ReadAllText($supportPath).Replace('return [pscustomobject]$answer',$replacement)
        [IO.File]::WriteAllText($supportPath,$support,(New-Object Text.UTF8Encoding($false)))
        Save $manifestPath @{schema_version=1;scenarios=@(@{id='limited';profile=$profiles.success})}
        $limited=Join-Path $testRoot ('batch-'+$boundary+'-limited')
        $process=Run 'Invoke-Mql5ScenarioBatch.ps1' @('-ManifestPath',$manifestPath,'-OutputDirectory',$limited,'-PythonPath',$python,'-Action','Execute') $limitedScripts
        $batch=ReadResult $limited
        if ($boundary -eq 'tester') {
            Check ($process.exit_code -eq 1 -and $batch.scenarios[0].status -eq 'failed' -and $batch.scenarios[0].tester.exit_code -eq 0 -and $batch.scenarios[0].tester.runner_status -eq 'output_limit') 'Tester process failure cannot become success through its zero exit code'
        } elseif ($boundary -eq 'analysis') {
            Check ($process.exit_code -eq 1 -and $batch.scenarios[0].status -eq 'completed' -and $batch.scenarios[0].analysis[0].status -eq 'failed' -and $batch.scenarios[0].analysis[0].exit_code -eq 0) 'Analysis process failure is retained separately and fails the batch'
        } else {
            Check ($process.exit_code -eq 1 -and $batch.scenarios[0].analysis[0].reason -eq 'analysis_result_missing_or_invalid') 'Zero-exit analysis without its result JSON fails the batch'
        }
    }
    $unsafe=Join-Path $testRoot 'batch-unsafe'
    Save $manifestPath @{schema_version=1;scenarios=@(@{id='bad-cleanup';profile=$profiles['cleanup-failure']},@{id='later';profile=$profiles.success})}
    $process=Run 'Invoke-Mql5ScenarioBatch.ps1' @('-ManifestPath',$manifestPath,'-OutputDirectory',$unsafe,'-PythonPath',$python,'-Action','Execute') $fixtureScripts
    $batch=ReadResult $unsafe
    Check ($process.exit_code -eq 2 -and $batch.scenarios[1].status -eq 'skipped' -and $batch.scenarios[0].cleanup_verified -eq $false) 'Cleanup uncertainty aborts remaining scenarios'
    Check ($batch.scenarios[0].analysis.Count -eq 0 -and $batch.scenarios[0].analysis_skipped_reason -eq 'owned_process_cleanup_uncertain') 'Cleanup uncertainty does not launch subsequent analysis'
    $uncertainScripts=Join-Path $testRoot 'uncertain-scripts';Copy-Item -LiteralPath $fixtureScripts -Destination $uncertainScripts -Recurse
    $supportPath=Join-Path $uncertainScripts 'ToolkitSupport.ps1'
    # Actual cleanup still runs; this private fixture reports uncertainty at the
    # existing process boundary to exercise the controller's mandatory stop.
    $support=[IO.File]::ReadAllText($supportPath).Replace('return [pscustomobject]$answer','$answer.cleanup_verified=$false; return [pscustomobject]$answer')
    [IO.File]::WriteAllText($supportPath,$support,(New-Object Text.UTF8Encoding($false)))
    Save $manifestPath @{schema_version=1;scenarios=@(@{id='uncertain-compile';profile=$profiles.success},@{id='later';profile=$profiles.success})}
    $uncertain=Join-Path $testRoot 'batch-uncertain-compile';$priorTrace=[IO.File]::ReadAllText($env:MQL5_SCENARIO_TEST_TRACE)
    $process=Run 'Invoke-Mql5ScenarioBatch.ps1' @('-ManifestPath',$manifestPath,'-OutputDirectory',$uncertain,'-PythonPath',$python,'-Action','Execute') $uncertainScripts
    $batch=ReadResult $uncertain;$traceDelta=[IO.File]::ReadAllText($env:MQL5_SCENARIO_TEST_TRACE).Substring($priorTrace.Length)
    Check ($process.exit_code -eq 2 -and $batch.scenarios[0].reason -eq 'compilation_cleanup_uncertain' -and $batch.scenarios[1].status -eq 'skipped' -and $traceDelta -eq "Compile:success`n") 'Successful compilation with uncertain cleanup cannot launch tester'
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
    Save $invalidExpectations @{schema_version=1;metrics=@(@{metric='net_profit';target='candidate';minimum=1.5})}
    $numericExpectations=Join-Path $testRoot 'batch-numeric-string-bound'
    $process=Run 'Invoke-Mql5ScenarioBatch.ps1' @('-ManifestPath',$manifestPath,'-OutputDirectory',$numericExpectations,'-PythonPath',$python,'-Action','Execute') $fixtureScripts
    Check ($process.exit_code -eq 2 -and [IO.File]::ReadAllText($env:MQL5_SCENARIO_TEST_TRACE) -ceq $before) 'Decimal JSON bounds cannot satisfy string fields or launch compilation'
    [IO.File]::WriteAllText($invalidExpectations,'{"schema_version":1,"metrics":[{"metric":"\ud800","target":"candidate","minimum":"0"}]}',(New-Object Text.UTF8Encoding($false)))
    $unicodeExpectations=Join-Path $testRoot 'batch-unpaired-unicode'
    $process=Run 'Invoke-Mql5ScenarioBatch.ps1' @('-ManifestPath',$manifestPath,'-OutputDirectory',$unicodeExpectations,'-PythonPath',$python,'-Action','Execute') $fixtureScripts
    Check ($process.exit_code -eq 2 -and [IO.File]::ReadAllText($env:MQL5_SCENARIO_TEST_TRACE) -ceq $before -and (ReadResult $unicodeExpectations).status -eq 'failed') 'Unpaired Unicode in expectations fails validation before compilation'
    $profileInventory=Join-Path $testRoot 'profile-inventory'
    $analyzer=Invoke-ToolkitProcess $python @('-B',(Join-Path $scripts 'mql5_toolkit.py'),'includes','inventory','--project-profile',$profiles.success,'--powershell',$hostExe,'--output',$profileInventory) $testRoot 30
    Check ($analyzer.exit_code -eq 0 -and (ReadResult $profileInventory).profile.path -eq $profiles.success) 'Python inventory reuses existing profile validation'
    $inventoryProject=Join-Path $testRoot ('inventory project '+[char]0xe9)
    $compilerRoot=Join-Path $testRoot 'inventory MQL5 root'
    $standardRoot=Join-Path $compilerRoot 'Include'
    [void][IO.Directory]::CreateDirectory($inventoryProject)
    [void][IO.Directory]::CreateDirectory($standardRoot)
    $inventoryEntry=Join-Path $inventoryProject 'Inventory.mq5'
    $standardHeader=Join-Path $standardRoot 'Shared.mqh'
    [IO.File]::WriteAllText($inventoryEntry,"#include <Shared.mqh>`n",(New-Object Text.UTF8Encoding($false)))
    [IO.File]::WriteAllText($standardHeader,"// independently specified standard header`n",(New-Object Text.UTF8Encoding($false)))
    [IO.File]::WriteAllText((Join-Path $compilerRoot 'Shared.mqh'),"// wrong-root decoy`n",(New-Object Text.UTF8Encoding($false)))
    $standardProfile=Join-Path $testRoot 'standard-inventory-profile.json'
    Save $standardProfile @{schema_version=1;name='standard inventory';project_root=$inventoryProject;entrypoints=@('Inventory.mq5');include_path=$compilerRoot;metaeditor_path=$editor;compiler=@{timeout_seconds=5;warnings_as_errors=$false};tester=$null}
    $standardInventory=Join-Path $testRoot 'standard-profile-inventory'
    $analyzer=Invoke-ToolkitProcess $python @('-B',(Join-Path $scripts 'mql5_toolkit.py'),'includes','inventory','--project-profile',$standardProfile,'--powershell',$hostExe,'--output',$standardInventory) $testRoot 30
    $standardRead=ReadResult $standardInventory
    Check ($analyzer.exit_code -eq 0 -and $standardRead.include_roots[0] -ceq $standardRoot -and $standardRead.dependencies[0].target -ceq $standardHeader -and $standardRead.coverage -eq 'selected_entrypoints_scanned') 'Saved compiler roots select their Include child and exclude wrong-root decoys'
    [IO.File]::WriteAllText($standardHeader,"// independently specified changed standard header`n",(New-Object Text.UTF8Encoding($false)))
    $changedInventory=Join-Path $testRoot 'standard-profile-changed'
    $analyzer=Invoke-ToolkitProcess $python @('-B',(Join-Path $scripts 'mql5_toolkit.py'),'includes','inventory','--project-profile',$standardProfile,'--powershell',$hostExe,'--output',$changedInventory) $testRoot 30
    if ($analyzer.exit_code -ne 0) {throw 'Changed standard inventory failed.'}
    $standardImpact=Join-Path $testRoot 'standard-profile-impact'
    $comparison=Invoke-ToolkitProcess $python @('-B',(Join-Path $scripts 'mql5_toolkit.py'),'includes','compare','--baseline',(Join-Path $standardInventory 'result.json'),'--candidate',(Join-Path $changedInventory 'result.json'),'--output',$standardImpact) $testRoot 30
    $impactRead=ReadResult $standardImpact
    Check ($comparison.exit_code -eq 0 -and $impactRead.differences.Count -eq 1 -and $impactRead.differences[0].path -ceq $standardHeader -and $impactRead.differences[0].kind -eq 'changed' -and $impactRead.possible_affected_entrypoints[0] -ceq $inventoryEntry) 'Native-style saved-profile snapshots retain changed standard-header consumers'
    $crProject=Join-Path $testRoot ('CR inventory '+[char]0xe9)
    [void][IO.Directory]::CreateDirectory($crProject)
    $crEntry=Join-Path $crProject 'Probe.mq5'
    $crShared=Join-Path $crProject 'Shared.mqh'
    [IO.File]::WriteAllText($crEntry,"#include `"First.mqh`"`r// comment`r#include `"Shared.mqh`"`r",(New-Object Text.UTF8Encoding($false)))
    [IO.File]::WriteAllText((Join-Path $crProject 'First.mqh'),"// first header`n",(New-Object Text.UTF8Encoding($false)))
    [IO.File]::WriteAllText($crShared,"// original shared header`n",(New-Object Text.UTF8Encoding($false)))
    $crBaseline=Join-Path $testRoot 'cr-inventory-baseline'
    $analyzer=Invoke-ToolkitProcess $python @('-B',(Join-Path $scripts 'mql5_toolkit.py'),'includes','inventory','--root',$crProject,'--entrypoint',$crEntry,'--output',$crBaseline) $testRoot 30
    $crRead=ReadResult $crBaseline
    Check ($analyzer.exit_code -eq 0 -and $crRead.coverage -eq 'selected_entrypoints_scanned' -and $crRead.dependencies.Count -eq 2 -and $crRead.dependencies[1].line -eq 3 -and $crRead.dependencies[1].target -ceq $crShared -and @(Get-ToolkitValue $crRead.possible_consumers $crShared)[0] -ceq $crEntry) 'CR-only sources retain includes after line comments through the CLI'
    [IO.File]::WriteAllText($crShared,"// changed shared header`n",(New-Object Text.UTF8Encoding($false)))
    $crChanged=Join-Path $testRoot 'cr-inventory-changed'
    $analyzer=Invoke-ToolkitProcess $python @('-B',(Join-Path $scripts 'mql5_toolkit.py'),'includes','inventory','--root',$crProject,'--entrypoint',$crEntry,'--output',$crChanged) $testRoot 30
    if ($analyzer.exit_code -ne 0) {throw 'Changed CR inventory failed.'}
    $crChangeImpact=Join-Path $testRoot 'cr-change-impact'
    $comparison=Invoke-ToolkitProcess $python @('-B',(Join-Path $scripts 'mql5_toolkit.py'),'includes','compare','--baseline',(Join-Path $crBaseline 'result.json'),'--candidate',(Join-Path $crChanged 'result.json'),'--output',$crChangeImpact) $testRoot 30
    $crImpact=ReadResult $crChangeImpact
    Check ($comparison.exit_code -eq 0 -and $crImpact.differences.Count -eq 1 -and $crImpact.differences[0].path -ceq $crShared -and $crImpact.differences[0].kind -eq 'changed' -and $crImpact.possible_affected_entrypoints[0] -ceq $crEntry) 'Changed headers keep their CR-only source consumers through the CLI'
    [IO.File]::Delete($crShared)
    $crDeleted=Join-Path $testRoot 'cr-inventory-deleted'
    $analyzer=Invoke-ToolkitProcess $python @('-B',(Join-Path $scripts 'mql5_toolkit.py'),'includes','inventory','--root',$crProject,'--entrypoint',$crEntry,'--output',$crDeleted) $testRoot 30
    if ($analyzer.exit_code -ne 0) {throw 'Deleted CR inventory failed.'}
    $crDeleteImpact=Join-Path $testRoot 'cr-delete-impact'
    $comparison=Invoke-ToolkitProcess $python @('-B',(Join-Path $scripts 'mql5_toolkit.py'),'includes','compare','--baseline',(Join-Path $crChanged 'result.json'),'--candidate',(Join-Path $crDeleted 'result.json'),'--output',$crDeleteImpact) $testRoot 30
    $crImpact=ReadResult $crDeleteImpact
    Check ($comparison.exit_code -eq 0 -and $crImpact.differences.Count -eq 1 -and $crImpact.differences[0].kind -eq 'removed' -and $crImpact.possible_affected_entrypoints[0] -ceq $crEntry -and $crImpact.differences[0].consumer_coverage_unknown) 'Deleted headers retain prior CR-only source consumers and disclose missing evidence'
    foreach ($variant in @('utf8','utf16')) {
        $unicodeProject=Join-Path $testRoot ('unicode-inventory-'+$variant)
        Copy-Item -LiteralPath (Join-Path $repo ('tests\fixtures\unicode-include-separators\'+$variant)) -Destination $unicodeProject -Recurse
        $unicodeEntry=Join-Path $unicodeProject 'Probe.mq5'
        $unicodeHeader=Join-Path $unicodeProject ('Header'+[char]0x85+[char]0x2028+[char]0x2029+'Name.mqh')
        $entryHash=Get-Mql5ReleaseHash $unicodeEntry
        $unicodeBaseline=Join-Path $testRoot ('unicode-baseline-'+$variant)
        $analyzer=Invoke-ToolkitProcess $python @('-B',(Join-Path $scripts 'mql5_toolkit.py'),'includes','inventory','--root',$unicodeProject,'--output',$unicodeBaseline) $testRoot 30
        $unicodeRead=ReadResult $unicodeBaseline
        Check ($analyzer.exit_code -eq 0 -and $unicodeRead.coverage -eq 'selected_entrypoints_scanned' -and $unicodeRead.unresolved.Count -eq 0 -and $unicodeRead.dependencies.Count -eq 2 -and $unicodeRead.dependencies[0].line -eq 3 -and $unicodeRead.dependencies[1].line -eq 4 -and $unicodeRead.dependencies[0].target -ceq $unicodeHeader -and @(Get-ToolkitValue $unicodeRead.possible_consumers $unicodeHeader)[0] -ceq $unicodeEntry -and (Get-Mql5ReleaseHash $unicodeEntry) -ceq $entryHash) 'Native Unicode text and header names retain complete dependencies, physical source lines, and unchanged source bytes'
        $encoding=if ($variant -eq 'utf16') {[Text.Encoding]::Unicode} else {New-Object Text.UTF8Encoding($true)}
        [IO.File]::WriteAllText($unicodeHeader,"int HeaderValue(void) { return 8; }`r`n",$encoding)
        $unicodeChanged=Join-Path $testRoot ('unicode-changed-'+$variant)
        $analyzer=Invoke-ToolkitProcess $python @('-B',(Join-Path $scripts 'mql5_toolkit.py'),'includes','inventory','--root',$unicodeProject,'--output',$unicodeChanged) $testRoot 30
        if ($analyzer.exit_code -ne 0) {throw 'Changed Unicode inventory failed.'}
        $unicodeImpact=Join-Path $testRoot ('unicode-impact-'+$variant)
        $comparison=Invoke-ToolkitProcess $python @('-B',(Join-Path $scripts 'mql5_toolkit.py'),'includes','compare','--baseline',(Join-Path $unicodeBaseline 'result.json'),'--candidate',(Join-Path $unicodeChanged 'result.json'),'--output',$unicodeImpact) $testRoot 30
        $impactRead=ReadResult $unicodeImpact
        Check ($comparison.exit_code -eq 0 -and $impactRead.differences.Count -eq 1 -and $impactRead.differences[0].kind -eq 'changed' -and $impactRead.differences[0].path -ceq $unicodeHeader -and $impactRead.possible_affected_entrypoints[0] -ceq $unicodeEntry) 'Changed native Unicode-named headers retain possible consumers through the comparison CLI'
    }
    $reportFixtures=Join-Path $repo 'tests\fixtures\reports'
    $countHtml=[IO.File]::ReadAllText((Join-Path $reportFixtures 'mixed-trades.htm'),[Text.Encoding]::Unicode)
    $countCases=@(@{label='Total Trades';metric='trades';raw='1.5';code=4},@{label='Total Deals';metric='deals';raw='-1';code=4},@{label='Ticks';metric='ticks';raw='123.25';code=4},@{label='Total Trades';metric='trades';raw='56.00';code=0})
    foreach ($variant in @('utf8','utf16')) {
        $caseIndex=0
        foreach ($countCase in $countCases) {
            $name='count-'+$variant+'-'+$caseIndex;$caseIndex++
            $pattern='('+[regex]::Escape($countCase.label)+':</td>\s*<td[^>]*><b>)([^<]*)(</b>)'
            if ([regex]::Matches($countHtml,$pattern).Count -ne 1) {throw 'Expected one native count cell.'}
            $candidateHtml=[regex]::Replace($countHtml,$pattern,[Text.RegularExpressions.MatchEvaluator]{param($match);return $match.Groups[1].Value+$countCase.raw+$match.Groups[3].Value})
            $candidateReport=Join-Path $testRoot ($name+'.htm')
            $encoding=if ($variant -eq 'utf16') {[Text.Encoding]::Unicode} else {New-Object Text.UTF8Encoding($false)}
            [IO.File]::WriteAllText($candidateReport,$candidateHtml,$encoding)
            $candidateHash=Get-Mql5ReleaseHash $candidateReport
            $candidateRun=Read-Mql5ReleaseJson (Join-Path $reportFixtures 'mixed-trades-result.json')
            $candidateRun.artifacts.report.sha256=$candidateHash
            $candidateRun.artifacts.report.byte_length=(Get-Item -LiteralPath $candidateReport).Length
            $candidateRun.fixture_derivation='Synthetic invalid/valid count mutation; not a tester execution'
            $candidateRunPath=Join-Path $testRoot ($name+'.json');Save $candidateRunPath $candidateRun
            $expectationPath=Join-Path $testRoot ($name+'-expectations.json')
            Save $expectationPath @{schema_version=1;metrics=@(@{metric=$countCase.metric;target='candidate';minimum='0'})}
            $comparisonRoot=Join-Path $testRoot ($name+'-comparison')
            $comparison=Invoke-ToolkitProcess $python @('-B',(Join-Path $scripts 'mql5_toolkit.py'),'report','compare','--baseline',(Join-Path $reportFixtures 'mixed-trades.htm'),'--baseline-result',(Join-Path $reportFixtures 'mixed-trades-result.json'),'--candidate',$candidateReport,'--candidate-result',$candidateRunPath,'--expectations',$expectationPath,'--output',$comparisonRoot) $testRoot 30
            $countRead=ReadResult $comparisonRoot
            $measurement=(Get-ToolkitValue $countRead.metrics $countCase.metric).candidate
            $valid=if ($countCase.code -eq 0) {$measurement.state -eq 'finite' -and $measurement.value -ceq '56.00' -and $countRead.expectations.status -eq 'pass'} else {$measurement.state -eq 'unparseable' -and $null -eq $measurement.value -and $measurement.reason -eq 'invalid_count' -and $countRead.expectations.status -eq 'not_evaluable'}
            Check ($comparison.exit_code -eq $countCase.code -and $countRead.exit_code -eq $countCase.code -and $countRead.status -eq 'completed' -and $countRead.candidate.evidence_linkage.status -eq 'hash_verified' -and $countRead.compatibility.status -eq 'comparable' -and $measurement.raw -ceq $countCase.raw -and $measurement.unit -eq 'count' -and $countRead.sources[1].sha256 -ceq $candidateHash -and (Get-Mql5ReleaseHash $candidateReport) -ceq $candidateHash -and $valid) 'Invalid native report counts cannot pass or fail expectations; valid whole counts remain evaluable and input bytes are preserved'
        }
    }
    $profileFixtures=Join-Path $repo 'tests\fixtures\profiles'
    $partialBaseline=Read-Mql5ReleaseJson (Join-Path $profileFixtures 'native-functions-conditions.json')
    $partialCandidate=Read-Mql5ReleaseJson (Join-Path $profileFixtures 'native-functions-inlined-conditions.json')
    $partialBaseline.build_conditions.PSObject.Properties.Remove('architecture')
    $partialCandidate.build_conditions.PSObject.Properties.Remove('architecture')
    $partialBaselinePath=Join-Path $testRoot 'partial-profile-baseline.json'
    $partialCandidatePath=Join-Path $testRoot 'partial-profile-candidate.json'
    Save $partialBaselinePath $partialBaseline
    Save $partialCandidatePath $partialCandidate
    $profileExpectations=Join-Path $testRoot 'profile-expectations.json'
    Save $profileExpectations @{schema_version=1;metrics=@(@{metric='OnStart.self_cpu_samples';target='candidate';minimum='0'})}
    $profileConflict=Join-Path $testRoot 'profile-partial-conflict'
    $comparison=Invoke-ToolkitProcess $python @('-B',(Join-Path $scripts 'mql5_toolkit.py'),'profile','compare','--baseline',(Join-Path $profileFixtures 'native-functions.csv'),'--candidate',(Join-Path $profileFixtures 'native-functions-inlined.csv'),'--baseline-conditions',$partialBaselinePath,'--candidate-conditions',$partialCandidatePath,'--expectations',$profileExpectations,'--output',$profileConflict) $testRoot 30
    $profileRead=ReadResult $profileConflict
    $profileMetric=Get-ToolkitValue $profileRead.metrics 'OnStart.self_cpu_samples'
    Check ($comparison.exit_code -eq 3 -and $profileRead.compatibility.status -eq 'incompatible' -and $profileRead.compatibility.missing -contains 'build_conditions.architecture' -and $profileRead.compatibility.differences.Count -eq 1 -and $profileRead.compatibility.differences[0].condition -eq 'build_conditions.profiling_inlining' -and $profileRead.expectations.status -eq 'not_evaluable' -and $profileMetric.difference.state -eq 'finite' -and -not $profileRead.speed_improvement_established) 'Missing profiling metadata cannot hide a known inlining conflict or permit expectations'
    $profileMissing=Join-Path $testRoot 'profile-partial-equal'
    $comparison=Invoke-ToolkitProcess $python @('-B',(Join-Path $scripts 'mql5_toolkit.py'),'profile','compare','--baseline',(Join-Path $profileFixtures 'native-functions.csv'),'--candidate',(Join-Path $profileFixtures 'native-functions.csv'),'--baseline-conditions',$partialBaselinePath,'--candidate-conditions',$partialBaselinePath,'--expectations',$profileExpectations,'--output',$profileMissing) $testRoot 30
    $profileRead=ReadResult $profileMissing
    Check ($comparison.exit_code -eq 4 -and $profileRead.compatibility.status -eq 'insufficient_evidence' -and $profileRead.compatibility.missing -contains 'build_conditions.architecture' -and $profileRead.compatibility.differences.Count -eq 0 -and $profileRead.expectations.status -eq 'not_evaluable') 'Matching partial profiling settings still require missing build evidence'
    'TOOLKIT_POWERSHELL_TESTS='+$checks
} finally {
    $env:MQL5_SCENARIO_TEST_TRACE=$oldTrace;$env:MQL5_SCENARIO_TEST_REPORT=$oldReport
    $full=[IO.Path]::GetFullPath($testRoot)
    $parent=[IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd('\')+'\mql5-toolkit-tests-'
    if (-not $full.StartsWith($parent,[StringComparison]::OrdinalIgnoreCase)) {throw 'Unsafe cleanup target.'}
    Remove-Item -LiteralPath $full -Recurse -Force
}
