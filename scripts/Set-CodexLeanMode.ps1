#Requires -Version 5.1
[CmdletBinding()]
param(
    [Parameter(Mandatory)][ValidateSet('On','Off','Status')][string]$Mode,
    [string]$CodexHome
)
Set-StrictMode -Version Latest
$ErrorActionPreference='Stop'

# Lean mode is one marked section of the global Codex AGENTS.md. Claude Code never
# reads CODEX_HOME, so turning it on or off changes Codex only. Text outside the
# markers belongs to the user and is kept as it is.
$begin='<!-- mql5-coding-skill: codex lean mode begin -->'
$end='<!-- mql5-coding-skill: codex lean mode end -->'
$rulesPath=Join-Path (Join-Path (Split-Path -Parent $PSScriptRoot) 'codex') 'lean-mode.md'

if ([string]::IsNullOrWhiteSpace($CodexHome)) {
    if (-not [string]::IsNullOrWhiteSpace($env:CODEX_HOME)) {$CodexHome=$env:CODEX_HOME}
    elseif (-not [string]::IsNullOrWhiteSpace($env:USERPROFILE)) {$CodexHome=Join-Path $env:USERPROFILE '.codex'}
    else {throw 'Set CODEX_HOME or USERPROFILE, or pass -CodexHome.'}
}
if (-not (Test-Path -LiteralPath $CodexHome -PathType Container)) {throw "Codex home '$CodexHome' does not exist. Start Codex once, or pass -CodexHome."}
$target=Join-Path $CodexHome 'AGENTS.md'
$override=Join-Path $CodexHome 'AGENTS.override.md'

function Read-Text([string]$Path) {
    if (Test-Path -LiteralPath $Path -PathType Leaf) {return [IO.File]::ReadAllText($Path)}
    return ''
}
function Write-Text([string]$Path,[string]$Text) {
    # Write beside the target, then swap it in, so a failed write cannot truncate AGENTS.md.
    $temporary=$Path+'.lean-mode.tmp'
    [IO.File]::WriteAllText($temporary,$Text,(New-Object Text.UTF8Encoding($false)))
    if (Test-Path -LiteralPath $Path -PathType Leaf) {[IO.File]::Replace($temporary,$Path,[NullString]::Value)}
    else {[IO.File]::Move($temporary,$Path)}
}
function Get-Normalized([string]$Text) {return $Text.Replace("`r`n","`n").Trim()}
function Find-Section([string]$Text) {
    $starts=[regex]::Matches($Text,[regex]::Escape($begin)).Count
    $ends=[regex]::Matches($Text,[regex]::Escape($end)).Count
    if ($starts -eq 0 -and $ends -eq 0) {return $null}
    $first=$Text.IndexOf($begin,[StringComparison]::Ordinal)
    $last=$Text.IndexOf($end,[StringComparison]::Ordinal)
    if ($starts -ne 1 -or $ends -ne 1 -or $last -lt $first) {
        throw "$target has damaged lean mode markers. Remove the lean mode section by hand, then run this script again."
    }
    $length=$last+$end.Length-$first
    return [pscustomobject]@{
        Start=$first
        Length=$length
        Rules=Get-Normalized $Text.Substring($first+$begin.Length,$last-$first-$begin.Length)
    }
}
function Remove-Section([string]$Text,$Section,[string]$NewLine) {
    $before=$Text.Substring(0,$Section.Start).TrimEnd("`r","`n")
    $after=$Text.Substring($Section.Start+$Section.Length).TrimStart("`r","`n")
    if ($before -and $after) {return $before+$NewLine+$NewLine+$after}
    if ($before) {return $before+$NewLine}
    return $after
}

$text=Read-Text $target
$newLine=if ($text.Contains("`r`n")) {"`r`n"} elseif ($text.Contains("`n")) {"`n"} else {"`r`n"}
$rules=Get-Normalized ([IO.File]::ReadAllText($rulesPath))
$section=Find-Section $text

switch ($Mode) {
    'Status' {
        if (-not $section) {Write-Output 'Codex lean mode is off.'}
        elseif ($section.Rules -cne $rules) {Write-Output 'Codex lean mode is on, but its rules differ from codex\lean-mode.md. Run -Mode On to update them.'}
        else {Write-Output 'Codex lean mode is on.'}
    }
    'On' {
        if ($section -and $section.Rules -ceq $rules) {Write-Output 'Codex lean mode is already on.'; break}
        $rest=if ($section) {Remove-Section $text $section $newLine} else {$text}
        $block=$begin+$newLine+$rules.Replace("`n",$newLine)+$newLine+$end+$newLine
        $rest=$rest.TrimEnd("`r","`n")
        Write-Text $target ($(if ($rest) {$rest+$newLine+$newLine} else {''})+$block)
        Write-Output "Codex lean mode is on ($target). Start a new Codex chat; fully restart Codex if it still uses the old rules."
    }
    'Off' {
        if (-not $section) {Write-Output 'Codex lean mode is already off.'; break}
        $rest=Remove-Section $text $section $newLine
        # Codex skips an empty AGENTS.md, so a file holding only lean mode is removed.
        if ([string]::IsNullOrWhiteSpace($rest)) {Remove-Item -LiteralPath $target}
        else {Write-Text $target $rest}
        Write-Output 'Codex lean mode is off. Start a new Codex chat; fully restart Codex if it still uses lean mode.'
    }
}
if (($Mode -eq 'On' -or ($Mode -eq 'Status' -and $section)) -and -not [string]::IsNullOrWhiteSpace((Read-Text $override))) {
    Write-Warning "Codex reads '$override' instead of '$target', so lean mode has no effect until that file is empty or removed."
}
