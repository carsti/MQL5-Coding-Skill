#Requires -Version 5.1
[CmdletBinding()]
param([Parameter(Mandatory)][string]$SkillRoot,[Parameter(Mandatory)][string]$PlatformRoot,[Parameter(Mandatory)][string]$OutputFile)
Set-StrictMode -Version Latest
$ErrorActionPreference='Stop'
. (Join-Path $SkillRoot 'scripts/WindowsExecutableMetadata.ps1')
try {
    $editor=Assert-Mql5MetaEditor (Join-Path $PlatformRoot 'MetaEditor64.exe')
    $terminal=Assert-Mql5Terminal (Join-Path $PlatformRoot 'terminal64.exe')
    $tester=Get-Mql5ExecutableVersionInfo (Join-Path $PlatformRoot 'metatester64.exe')
    if ($tester.FileMajorPart -ne 5) {throw 'Select genuine major-version-5 tester metadata.'}
    $result=[ordered]@{schema_version=1;status='inspected';editor_version=$editor.VersionInfo.FileVersion;terminal_version=$terminal.VersionInfo.FileVersion;tester_version=$tester.FileVersion;native_execution=$false}
    $bytes=[Text.Encoding]::UTF8.GetBytes(($result | ConvertTo-Json -Compress)+[Environment]::NewLine)
    $stream=[IO.File]::Open([IO.Path]::GetFullPath($OutputFile),[IO.FileMode]::CreateNew,[IO.FileAccess]::Write,[IO.FileShare]::Read)
    try {$stream.Write($bytes,0,$bytes.Length)} finally {$stream.Dispose()}
    exit 0
} catch {Write-Error -Message $_.Exception.Message -ErrorAction Continue;exit 2}
