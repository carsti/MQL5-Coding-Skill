#Requires -Version 5.1
param(
    [Parameter(Mandatory)][string]$SkillRoot,
    [Parameter(Mandatory)][string]$TerminalDataRoot,
    [Parameter(Mandatory)][string]$DemoAuthFile,
    [Parameter(Mandatory)][string]$ExpectedMarkerFile,
    [Parameter(Mandatory)][string]$OutputFile,
    [string]$PrivateOutputRoot
)
$ErrorActionPreference='Stop'
$result=[ordered]@{schema_version=1;operation='native_demo_bootstrap';status='failed';matching_markers=0;failure_markers=0;sources=@();excerpts=@();issues=@()}
try {
    . (Join-Path $SkillRoot 'scripts/ToolkitSupport.ps1')
    . (Join-Path $SkillRoot 'scripts/TesterEvidence.ps1')
    $auth=(Read-ToolkitJsonEvidence $DemoAuthFile).value
    Assert-ToolkitFields $auth @('login','server','password')
    if ($auth.login -isnot [string] -or $auth.login -notmatch '^[1-9][0-9]{0,18}$' -or
        $auth.server -isnot [string] -or $auth.server -cne 'MetaQuotes-Demo' -or $auth.password -isnot [string] -or
        [string]::IsNullOrEmpty($auth.password) -or $auth.password -match '[\r\n\x00]') {throw 'Invalid private authentication input.'}
    $expected=[IO.File]::ReadAllText($ExpectedMarkerFile).TrimEnd("`r","`n")
    if ($expected -cnotmatch '^MQL5_CODING_PASS:[0-9a-f]{32}:dedicated-demo-account$') {throw 'Invalid probe commitment.'}
    $sensitive=@($auth.login,$auth.password,$expected)
    $total=0L
    $files=@()
    foreach ($directory in @('logs','MQL5/Logs')) {
        $path=Join-Path $TerminalDataRoot $directory
        if (Test-Path -LiteralPath $path -PathType Container) {
            $files+=@(Get-ChildItem -LiteralPath $path -Filter '*.log' -File | ForEach-Object {@{path=$_.FullName;journal=$true}})
        }
    }
    if ($PrivateOutputRoot) {
        foreach ($name in @('bootstrap.stdout.txt','bootstrap.stderr.txt')) {
            $path=Join-Path $PrivateOutputRoot $name
            if (Test-Path -LiteralPath $path -PathType Leaf) {$files+=@(@{path=$path;journal=$false})}
        }
    }
    foreach ($file in $files) {
        $stream=[IO.File]::Open($file.path,[IO.FileMode]::Open,[IO.FileAccess]::Read,[IO.FileShare]::Read)
        try {
            if ($stream.Length -gt 16777216-$total) {throw 'Bootstrap evidence exceeds the supported limit.'}
            $bytes=New-Object byte[] ([int]$stream.Length)
            $offset=0
            while ($offset -lt $bytes.Length) {
                $got=$stream.Read($bytes,$offset,$bytes.Length-$offset)
                if ($got -eq 0) {throw 'Incomplete bootstrap evidence.'}
                $offset+=$got
            }
        } finally {$stream.Dispose()}
        $total+=$bytes.Length
        $encoding=New-Object Text.UTF8Encoding($false,$true);$start=0
        if ($bytes.Length -ge 2 -and $bytes[0] -eq 255 -and $bytes[1] -eq 254) {$encoding=New-Object Text.UnicodeEncoding($false,$true,$true);$start=2}
        elseif ($bytes.Length -ge 3 -and $bytes[0] -eq 239 -and $bytes[1] -eq 187 -and $bytes[2] -eq 191) {$start=3}
        $text=$encoding.GetString($bytes,$start,$bytes.Length-$start)
        $digest=[Security.Cryptography.SHA256]::Create()
        try {$hash=([BitConverter]::ToString($digest.ComputeHash($bytes))).Replace('-','').ToLowerInvariant()} finally {$digest.Dispose()}
        $source=Protect-JournalLine $file.path -SensitiveValues $sensitive
        $result.sources+=@(@{path=$source;sha256=$hash;byte_length=$bytes.Length;journal=$file.journal})
        $lineNumber=0
        foreach ($line in ($text -split "`r?`n")) {
            $lineNumber++
            # Only complete application messages in native journals establish
            # identity. Console output cannot supply an account pass marker.
            if ($file.journal -and ($line -split "`t")[-1] -ceq $expected) {$result.matching_markers++}
            if ($file.journal -and $line.Contains('MQL5_DEMO_PROBE:')) {$result.failure_markers++}
            if (($line.Contains('MQL5_DEMO_PROBE:') -or $line.Contains('dedicated-demo-account') -or -not $file.journal) -and $line -ne '' -and $result.excerpts.Count -lt 24) {
                $redacted=Protect-JournalLine $line -SensitiveValues $sensitive
                if ($redacted.Length -gt 1024) {$redacted=$redacted.Substring(0,1024)}
                $result.excerpts+=@(@{source=$source;line=$lineNumber;message=$redacted})
            }
        }
    }
    if ($result.matching_markers -ne 1 -or $result.failure_markers -ne 0) {throw 'Connected dedicated-demo probe did not establish account identity.'}
    $result.status='verified'
} catch {
    # Never retain deserialization/decoder exception text from private inputs.
    $result.issues+=@('Dedicated-demo bootstrap evidence is invalid or incomplete.')
}
[IO.File]::WriteAllText($OutputFile,(ConvertTo-Json -InputObject $result -Depth 10),(New-Object Text.UTF8Encoding($false)))
if ($result.status -eq 'verified') {exit 0}
exit 2
