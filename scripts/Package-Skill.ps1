#Requires -Version 5.1
[CmdletBinding()]
param([string]$SkillRoot,
    [Parameter(Mandatory)][string]$OutputDirectory,[Parameter(Mandatory)][string]$SourceCommit,[string]$Tag)
Set-StrictMode -Version Latest
$ErrorActionPreference='Stop'
if (-not $SkillRoot) {$SkillRoot=Join-Path (Split-Path -Parent $PSScriptRoot) 'skills/mql5-coding'}
. (Join-Path $SkillRoot 'scripts/SkillRelease.ps1')
$root=Assert-Mql5ReleasePath $SkillRoot
$output=Assert-Mql5ReleasePath $OutputDirectory
if ($output -ieq $root -or $output.StartsWith($root+'\',[StringComparison]::OrdinalIgnoreCase)) {throw 'Release output must be outside the skill tree.'}
$identity=Read-Mql5ReleaseJson (Join-Path $root 'version.json')
Assert-Mql5ReleaseObject $identity @('schema_version','version')
$version=[string]$identity.version
if (-not $Tag) {$Tag='v'+$version}
if ($Tag -cne ('v'+$version) -or $identity.schema_version -ne 1) {throw 'Release tag must match version.json.'}
$files=@(Get-Mql5ReleaseInventory $root)
$manifest=[ordered]@{schema_version=1;repository='shamwi2846/MQL5-Coding-Skill';tag=$Tag;version=$version;source_commit=$SourceCommit;files=@($files)}
Assert-Mql5SkillManifest ([pscustomobject]$manifest) $version $SourceCommit
[IO.Directory]::CreateDirectory($output) | Out-Null
$archive=Join-Path $output 'mql5-coding-windows.zip'
$sidecar=$archive+'.manifest.json'
if ((Test-Path -LiteralPath $archive) -or (Test-Path -LiteralPath $sidecar)) {throw 'Release output already exists.'}
Add-Type -AssemblyName System.IO.Compression
Add-Type -AssemblyName System.IO.Compression.FileSystem
$stream=[IO.File]::Open($archive,[IO.FileMode]::CreateNew,[IO.FileAccess]::ReadWrite,[IO.FileShare]::None)
$zip=New-Object IO.Compression.ZipArchive($stream,[IO.Compression.ZipArchiveMode]::Create,$true)
try {
    $entries=@('release-manifest.json')+@($files | ForEach-Object {'mql5-coding/'+$_.path})
    foreach ($name in $entries) {
        $entry=$zip.CreateEntry($name,[IO.Compression.CompressionLevel]::Optimal)
        $entry.LastWriteTime=[DateTimeOffset]::Parse('2000-01-01T00:00:00Z',[Globalization.CultureInfo]::InvariantCulture)
        $entry.ExternalAttributes=0
        $destination=$entry.Open()
        try {
            if ($name -eq 'release-manifest.json') {
                $bytes=(New-Object Text.UTF8Encoding($false)).GetBytes(($manifest | ConvertTo-Json -Depth 12 -Compress)+"`n")
                $destination.Write($bytes,0,$bytes.Length)
            } else {
                $source=[IO.File]::OpenRead((Join-Path $root $name.Substring('mql5-coding/'.Length)))
                try {$source.CopyTo($destination)} finally {$source.Dispose()}
            }
        } finally {$destination.Dispose()}
    }
} finally {$zip.Dispose();$stream.Dispose()}
$digest=Get-Mql5ReleaseHash $archive
Write-Mql5ReleaseJson $sidecar ([ordered]@{schema_version=1;file='mql5-coding-windows.zip';version=$version;source_commit=$SourceCommit;bytes=(Get-Item -LiteralPath $archive).Length;sha256=$digest})
$verify=Join-Path $output ('verified-'+[guid]::NewGuid().ToString('N'))
$null=Expand-Mql5SkillRelease $archive $digest $version $SourceCommit $verify
[ordered]@{version=$version;source_commit=$SourceCommit;archive=$archive;sha256=$digest;files=$files.Count} | ConvertTo-Json
