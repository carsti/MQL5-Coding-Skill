#Requires -Version 5.1
[CmdletBinding()]
param()
Set-StrictMode -Version Latest
$ErrorActionPreference='Stop'
$repository=Split-Path -Parent $PSScriptRoot
$toggle=Join-Path (Join-Path $repository 'scripts') 'Set-CodexLeanMode.ps1'
$rules=([IO.File]::ReadAllText((Join-Path (Join-Path $repository 'codex') 'lean-mode.md'))).Replace("`r`n","`n").Trim()
$begin='<!-- mql5-coding-skill: codex lean mode begin -->'
$checks=0
function Check([bool]$Condition,[string]$Message) {
    if (-not $Condition) {throw $Message}
    $script:checks++
}
function Invoke-Lean([string]$Mode) {return [string](& $toggle -Mode $Mode -CodexHome $codexHome -WarningAction SilentlyContinue)}
$codexHome=Join-Path ([IO.Path]::GetTempPath()) ('codex-lean-'+[guid]::NewGuid().ToString('N'))
$agents=Join-Path $codexHome 'AGENTS.md'
[IO.Directory]::CreateDirectory($codexHome) | Out-Null
try {
    Check ((Invoke-Lean 'Status') -eq 'Codex lean mode is off.') 'Status without AGENTS.md was not off.'
    Check ((Invoke-Lean 'Off') -eq 'Codex lean mode is already off.') 'Off without AGENTS.md changed state.'
    Check (-not (Test-Path -LiteralPath $agents)) 'Off created AGENTS.md.'

    [void](Invoke-Lean 'On')
    $text=[IO.File]::ReadAllText($agents)
    Check ($text.StartsWith($begin+"`r`n")) 'A new AGENTS.md does not start with the lean mode section.'
    Check ($text.Replace("`r`n","`n").Contains($rules)) 'AGENTS.md does not contain the lean mode rules.'
    Check ((Invoke-Lean 'Status') -eq 'Codex lean mode is on.') 'Status after On was not on.'
    Check ((Invoke-Lean 'On') -eq 'Codex lean mode is already on.') 'A second On was not idempotent.'
    Check ([IO.File]::ReadAllText($agents) -ceq $text) 'A second On changed AGENTS.md.'
    [void](Invoke-Lean 'Off')
    Check (-not (Test-Path -LiteralPath $agents)) 'Off kept an AGENTS.md that held only lean mode.'

    # User instructions outside the section survive On, a rules update, and Off byte for byte.
    $own="# My rules`r`nKeep this line.`r`n"
    [IO.File]::WriteAllText($agents,$own)
    [void](Invoke-Lean 'On')
    $text=[IO.File]::ReadAllText($agents)
    Check ($text.StartsWith($own+"`r`n"+$begin)) 'On did not keep existing instructions before the section.'
    Check (-not $text.Replace("`r`n",'').Contains("`n")) 'On mixed LF into a CRLF AGENTS.md.'
    [IO.File]::WriteAllText($agents,$text.Replace('Never place trades.','Old rule.'))
    Check ((Invoke-Lean 'Status').Contains('differ from')) 'Status did not report outdated rules.'
    [void](Invoke-Lean 'On')
    Check ((Invoke-Lean 'Status') -eq 'Codex lean mode is on.') 'On did not refresh outdated rules.'
    [void](Invoke-Lean 'Off')
    Check ([IO.File]::ReadAllText($agents) -ceq $own) 'Off did not restore the original AGENTS.md.'

    # An override file hides AGENTS.md from Codex, so On must say so.
    [IO.File]::WriteAllText((Join-Path $codexHome 'AGENTS.override.md'),'Override.')
    $warnings=$null
    [void](& $toggle -Mode On -CodexHome $codexHome -WarningVariable warnings -WarningAction SilentlyContinue)
    Check (@($warnings).Count -eq 1 -and ([string]$warnings[0]).Contains('AGENTS.override.md')) 'On did not warn about AGENTS.override.md.'
    [void](Invoke-Lean 'Off')

    # Damaged markers are refused without touching the file.
    $damaged=$own+$begin+"`r`nHalf a section.`r`n"
    [IO.File]::WriteAllText($agents,$damaged)
    $refused=$false
    try {[void](Invoke-Lean 'On')} catch {$refused=$_.Exception.Message.Contains('damaged lean mode markers')}
    Check $refused 'On accepted damaged markers.'
    Check ([IO.File]::ReadAllText($agents) -ceq $damaged) 'Damaged markers were changed.'

    $missing=$false
    try {[void](& $toggle -Mode Status -CodexHome (Join-Path $codexHome 'missing'))} catch {$missing=$_.Exception.Message.Contains('does not exist')}
    Check $missing 'A missing Codex home was accepted.'
} finally {
    Remove-Item -LiteralPath $codexHome -Recurse -Force
}
Write-Output ('CODEX_LEAN_MODE_TESTS='+$checks+' host='+$PSVersionTable.PSVersion)
