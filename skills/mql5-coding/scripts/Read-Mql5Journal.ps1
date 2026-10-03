#Requires -Version 5.1
[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$TesterResultPath,
    [Parameter(Mandatory)][string]$OutputDirectory,
    [string[]]$LiteralMessage=@(),
    [ValidateRange(1024,67108864)][int]$MaxBytes=16777216,
    [ValidateRange(1,1000000)][int]$MaxLines=100000,
    [ValidateRange(1,10000)][int]$MaxGroups=1000
)
Set-StrictMode -Version Latest
$ErrorActionPreference='Stop'
. (Join-Path $PSScriptRoot 'ToolkitSupport.ps1')
. (Join-Path $PSScriptRoot 'TesterEvidence.ps1')
$output=$null
$result=[ordered]@{schema_version=1;operation='journal read';status='failed';source=$null;recorded_run_status=$null;evidence_status='unavailable';segments=@();groups=@();inspected_lines=0;matched_lines=0;grouped_lines=0;budgeted_bytes=0;truncated=$false;filter_sha256=@();issues=@();limitations=@('Counts cover inspected evidence only. Patterns are observations, not proven causes.');exit_code=2}
$groups=[Collections.Hashtable]::new([StringComparer]::Ordinal);$bytesUsed=0;$ranges=@{}
function Protect-JournalObservationText([AllowEmptyString()][string]$Text) {
    if ($Text.Length -eq 0) {return ''}
    # Mask markers before generic redaction can rewrite the nonce, and apply
    # the same protection to both component and message fields.
    $masked=[regex]::Replace($Text,'MQL5_CODING_PASS:[0-9a-fA-F]{32,64}(?::[^\s]*)?','<APPLICATION_MARKER>')
    return Protect-JournalLine -Line $masked
}
function Add-JournalObservation([string]$Line,[string]$Kind,[string]$Path,[long]$Offset,[long]$LineNumber,[bool]$Verified) {
    if ($script:result.inspected_lines -ge $MaxLines) {$script:result.truncated=$true;return}
    $script:result.inspected_lines++
    $columns=$Line -split "`t",5
    $message=if ($columns.Count -eq 5) {$columns[4]} else {$Line}
    $component=if ($columns.Count -eq 5) {$columns[3]} else {'unknown'}
    $time=[regex]::Match($Line,'(?<!\d)(?:\d{4}\.\d{2}\.\d{2}\s+)?\d{2}:\d{2}:\d{2}(?:\.\d+)?')
    $matched=$LiteralMessage.Count -eq 0
    foreach ($literal in $LiteralMessage) {if ($message.IndexOf($literal,[StringComparison]::Ordinal) -ge 0) {$matched=$true}}
    if (-not $matched) {return}
    $script:result.matched_lines++
    $safe=Protect-JournalObservationText $message
    $component=Protect-JournalObservationText $component
    $key=$Kind+"`t"+$component+"`t"+$safe
    if (-not $script:groups.ContainsKey($key)) {
        if ($script:groups.Count -ge $MaxGroups) {$script:result.truncated=$true;return}
        $script:groups[$key]=[ordered]@{journal=$Kind;component=$component;message=$safe;count=0;first_timestamp=$null;last_timestamp=$null;locations=@();representative_excerpt=$safe}
    }
    $group=$script:groups[$key];$group.count++;$script:result.grouped_lines++
    if ($time.Success) {if ($null -eq $group.first_timestamp) {$group.first_timestamp=$time.Value};$group.last_timestamp=$time.Value}
    if ($group.locations.Count -lt 3) {$group.locations+=@([ordered]@{path=$Path;source_byte_offset=if ($Verified) {$Offset} else {$null};segment_line=$LineNumber;hash_verified=$Verified})}
}
try {
    $output=New-ToolkitOutput $OutputDirectory
    if ($TesterResultPath -notmatch '^[A-Za-z]:[\\/]') {throw 'TesterResultPath must be absolute.'}
    $path=Resolve-ToolkitPath $TesterResultPath $PSScriptRoot
    $snapshot=Read-ToolkitJsonEvidence $path
    $run=$snapshot.value
    if (($run.schema_version -isnot [int] -and $run.schema_version -isnot [long]) -or $run.schema_version -ne 2 -or $run.status -isnot [string]) {throw 'Unsupported tester result.'}
    $result.source=$snapshot.source
    $result.recorded_run_status=$run.status
    foreach ($literal in $LiteralMessage) {
        if ([string]::IsNullOrEmpty($literal)) {throw 'Literal filters cannot be empty.'}
        $sha=[Security.Cryptography.SHA256]::Create()
        try {$result.filter_sha256+=@(([BitConverter]::ToString($sha.ComputeHash([Text.Encoding]::UTF8.GetBytes($literal)))).Replace('-','').ToLowerInvariant())} finally {$sha.Dispose()}
    }
    $evidence=Get-ToolkitValue $run 'evidence';$missingJournals=0
    foreach ($kind in @('terminal_journal','tester_journal')) {
        $journal=Get-ToolkitValue $evidence $kind
        $segments=@(Get-ToolkitValue $journal 'segments' @())
        $usable=0;$recordedBytes=0
        if ($null -eq $journal) {$missingJournals++}
        if (Get-ToolkitValue $journal 'limit_exceeded' $false) {$result.truncated=$true}
        foreach ($segment in $segments) {
            $record=[ordered]@{journal=$kind;path=(Get-ToolkitValue $segment 'path');source_offset=(Get-ToolkitValue $segment 'source_offset');byte_length=(Get-ToolkitValue $segment 'byte_length');sha256=(Get-ToolkitValue $segment 'sha256');status='unavailable';hash_verified=$false;starts_at_line_boundary=$null;ends_at_line_boundary=$null;reason=$null}
            try {
                foreach ($field in @('source_offset','byte_length')) {
                    $value=Get-ToolkitValue $segment $field
                    if (($value -isnot [int] -and $value -isnot [long]) -or $value -lt 0 -or $value % 2) {throw 'Invalid UTF-16 byte range.'}
                }
                if ($segment.sha256 -isnot [string] -or $segment.sha256 -cnotmatch '^[0-9a-f]{64}$') {throw 'Missing segment digest.'}
                if ($segment.byte_length -gt ($MaxBytes-$bytesUsed)) {$result.truncated=$true;throw 'Analysis byte limit reached.'}
                $file=Resolve-ToolkitPath $segment.path ([IO.Path]::GetDirectoryName($path))
                $fileKey=$file.ToLowerInvariant()
                if (-not $ranges.ContainsKey($fileKey)) {$ranges[$fileKey]=@()}
                foreach ($range in $ranges[$fileKey]) {
                    if ($segment.source_offset -lt $range.end -and $segment.source_offset+$segment.byte_length -gt $range.start) {throw 'Overlapping recorded segments are uncertain and are not counted twice.'}
                }
                $stream=[IO.File]::Open($file,[IO.FileMode]::Open,[IO.FileAccess]::Read,([IO.FileShare]::ReadWrite -bor [IO.FileShare]::Delete))
                try {
                    if ($segment.source_offset -gt $stream.Length -or $segment.byte_length -gt ($stream.Length-$segment.source_offset)) {throw 'Recorded segment range is unavailable.'}
                    $record.starts_at_line_boundary=$segment.source_offset -eq 0
                    if ($segment.source_offset -ge 2) {
                        $stream.Position=$segment.source_offset-2
                        $previous=$stream.ReadByte();$high=$stream.ReadByte()
                        $record.starts_at_line_boundary=($high -eq 0 -and $previous -in @(10,13)) -or ($segment.source_offset -eq 2 -and $previous -eq 255 -and $high -eq 254)
                    }
                    $stream.Position=$segment.source_offset
                    $buffer=New-Object byte[] ([int]$segment.byte_length)
                    # Charge attempted buffers before hashing/decoding, including
                    # evidence that later fails integrity or observation checks.
                    $bytesUsed+=$buffer.Length;$result.budgeted_bytes=$bytesUsed
                    $read=0
                    while ($read -lt $buffer.Length) {$got=$stream.Read($buffer,$read,$buffer.Length-$read);if ($got -eq 0) {throw 'Incomplete segment read.'};$read+=$got}
                } finally {$stream.Dispose()}
                $sha=[Security.Cryptography.SHA256]::Create()
                try {$actual=([BitConverter]::ToString($sha.ComputeHash($buffer))).Replace('-','').ToLowerInvariant()} finally {$sha.Dispose()}
                if ($actual -cne $segment.sha256) {throw 'Segment integrity mismatch.'}
                $record.hash_verified=$true
                $ranges[$fileKey]+=@(@{start=$segment.source_offset;end=$segment.source_offset+$segment.byte_length})
                $encoding=New-Object Text.UnicodeEncoding($false,$false,$true)
                $text=$encoding.GetString($buffer)
                $recordedBytes+=$buffer.Length;$usable++
                $record.status='hash_verified'
                $record.ends_at_line_boundary=$text.Length -eq 0 -or $text.EndsWith("`n") -or $text.EndsWith("`r")
                if (-not $record.starts_at_line_boundary -or -not $record.ends_at_line_boundary) {$result.truncated=$true}
                $lineNumber=0
                foreach ($line in [regex]::Matches($text,'[^\r\n]+(?:\r\n|\n|\r|$)|(?:\r\n|\n|\r)')) {
                    $lineNumber++
                    $content=$line.Value.TrimEnd([char[]]@("`r","`n")).TrimStart([char]0xfeff)
                    if ($content.Length) {Add-JournalObservation $content $kind $file ($segment.source_offset+2*$line.Index) $lineNumber $true}
                    if ($result.inspected_lines -ge $MaxLines) {if ($line.Index+$line.Length -lt $text.Length) {$result.truncated=$true};break}
                }
            } catch {
                if ($record.hash_verified) {$record.status='processing_failed';$record.reason='Segment hash matched, but observation processing was incomplete.'}
                else {$record.reason='Segment unavailable, invalid, beyond analysis limits, or hash mismatch.'}
            }
            $result.segments+=@($record)
        }
        if ($usable -eq 0) {
            $excerptIndex=0
            foreach ($excerpt in @(Get-ToolkitValue $journal 'excerpts' @())) {
                if ($excerpt -isnot [string]) {throw 'Journal excerpt must be a string.'}
                if ($result.inspected_lines -ge $MaxLines) {$result.truncated=$true;break}
                $excerptBytes=[Text.Encoding]::Unicode.GetByteCount($excerpt)
                if ($excerptBytes -gt ($MaxBytes-$bytesUsed)) {$result.truncated=$true;break}
                $bytesUsed+=$excerptBytes;$result.budgeted_bytes=$bytesUsed
                $excerptIndex++
                if ($excerpt.Length) {Add-JournalObservation $excerpt $kind $path -1 $excerptIndex $false}
            }
        }
        $expectedBytes=Get-ToolkitValue $journal 'appended_byte_length'
        if ($null -ne $journal -and (($expectedBytes -isnot [int] -and $expectedBytes -isnot [long]) -or $expectedBytes -lt 0 -or $expectedBytes -ne $recordedBytes)) {$missingJournals++}
    }
    $result.groups=@($groups.Values | Sort-Object -Property @{Expression={$_.count};Descending=$true},@{Expression={$_.message};Descending=$false})
    $verified=@($result.segments | Where-Object {$_.hash_verified}).Count
    $unavailable=@($result.segments | Where-Object {$_.status -ne 'hash_verified'}).Count
    $result.evidence_status=if ($result.truncated) {'truncated'} elseif ($verified -gt 0 -and $unavailable -eq 0 -and $missingJournals -eq 0) {'complete_segments'} elseif ($verified -gt 0) {'partial_segments'} elseif ($result.inspected_lines -gt 0) {'bounded_excerpts'} else {'unavailable'}
    if ($unavailable) {$result.issues+=@(@{code='unavailable_segments';count=$unavailable})}
    $result.status='completed';$result.exit_code=if ($result.evidence_status -in @('complete_segments')) {0} else {4}
} catch {
    $result.issues+=@(@{code='invalid_input_or_tooling';message='Inspect tester-result schema, evidence paths, byte ranges, and output selection.'})
}
if ($null -ne $output) {Save-ToolkitResult $output $result @('journal read',('Status: '+$result.status),('Evidence: '+$result.evidence_status),('Inspected lines: '+$result.inspected_lines),('Groups: '+$result.groups.Count),('Exit code: '+$result.exit_code))}
else {Write-Error 'Select a new absolute output directory.' -ErrorAction Continue}
exit $result.exit_code
