#Requires -Version 5.1
[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$ProfilePath,
    [Parameter(Mandatory)][string]$Name,
    [Parameter(Mandatory)][string]$ProjectRoot,
    [Parameter(Mandatory)][string[]]$Entrypoints,
    [Parameter(Mandatory)][string]$MetaEditorPath,
    [string]$IncludePath,
    [ValidateRange(5,1800)][int]$CompileTimeoutSeconds=120,
    [switch]$WarningsAsErrors,
    [string]$TesterEntrypoint,
    [string]$TerminalPath,
    [string]$TerminalDataPath,
    [string]$SetPath,
    [switch]$UseExpertDefaults,
    [string]$Symbol,
    [string]$Period,
    [string]$FromDate,
    [string]$ToDate,
    [int]$Model,
    [string]$Deposit,
    [string]$Currency,
    [int]$Leverage,
    [int]$ExecutionMode,
    [ValidateRange(10,86400)][int]$TesterTimeoutSeconds=300
)
Set-StrictMode -Version Latest
$ErrorActionPreference='Stop'
try {
    . (Join-Path $PSScriptRoot 'Mql5ProjectProfile.ps1')
    $profilePath=[IO.Path]::GetFullPath($ProfilePath)
    $parent=Split-Path -Parent $profilePath
    if (-not (Test-Path -LiteralPath $parent -PathType Container)) {throw 'Profile parent directory must exist.'}
    $root=Resolve-Mql5ProfilePath $ProjectRoot (Get-Location).Path 'Container'
    $entryPaths=@($Entrypoints | ForEach-Object {Get-Mql5ProfileStoredPath (Resolve-Mql5ProfilePath $_ $root 'Leaf') $root})
    $editor=Resolve-Mql5ProfilePath $MetaEditorPath $root 'Leaf'
    $include=$null
    if ($PSBoundParameters.ContainsKey('IncludePath')) {$include=Get-Mql5ProfileStoredPath (Resolve-Mql5ProfilePath $IncludePath $root 'Container') $root}
    $tester=$null
    $testerKeys=@('TesterEntrypoint','TerminalPath','TerminalDataPath','SetPath','UseExpertDefaults','Symbol','Period','FromDate','ToDate','Model','Deposit','Currency','Leverage','ExecutionMode','TesterTimeoutSeconds')
    $testerRequested=@($testerKeys | Where-Object {$PSBoundParameters.ContainsKey($_)}).Count -gt 0
    if ($testerRequested) {
        foreach ($required in @('TesterEntrypoint','TerminalPath','TerminalDataPath','Symbol','Period','FromDate','ToDate','Model','Deposit','Currency','Leverage','ExecutionMode')) {if (-not $PSBoundParameters.ContainsKey($required)) {throw 'All tester selectors and settings must be explicit when saving a tester profile.'}}
        $preset=$null
        if ($PSBoundParameters.ContainsKey('SetPath')) {$preset=Get-Mql5ProfileStoredPath (Resolve-Mql5ProfilePath $SetPath $root 'Leaf') $root}
        $tester=[ordered]@{entrypoint=(Get-Mql5ProfileStoredPath (Resolve-Mql5ProfilePath $TesterEntrypoint $root 'Leaf') $root);terminal_path=(Resolve-Mql5ProfilePath $TerminalPath $root 'Leaf');terminal_data_path=(Resolve-Mql5ProfilePath $TerminalDataPath $root 'Container');set_path=$preset;use_expert_defaults=[bool]$UseExpertDefaults;timeout_seconds=$TesterTimeoutSeconds;settings=[ordered]@{symbol=$Symbol;period=$Period;from_date=$FromDate;to_date=$ToDate;model=$Model;deposit=$Deposit;currency=$Currency;leverage=$Leverage;execution_mode=$ExecutionMode}}
    }
    $data=[ordered]@{schema_version=1;name=$Name;project_root=(Get-Mql5ProfileStoredPath $root $parent);entrypoints=@($entryPaths);include_path=$include;metaeditor_path=$editor;compiler=[ordered]@{timeout_seconds=$CompileTimeoutSeconds;warnings_as_errors=[bool]$WarningsAsErrors};tester=$tester}
    # Validate the exact data before exclusively creating the requested profile.
    $json=$data | ConvertTo-Json -Depth 8
    [void](ConvertTo-Mql5ValidatedProfile ($json | ConvertFrom-Json) $profilePath)
    $bytes=(New-Object Text.UTF8Encoding($false)).GetBytes($json+[Environment]::NewLine)
    $stream=[IO.File]::Open($profilePath,[IO.FileMode]::CreateNew,[IO.FileAccess]::Write,[IO.FileShare]::Read)
    try {$stream.Write($bytes,0,$bytes.Length)} finally {$stream.Dispose()}
    Write-Output ('MQL5_PROJECT_PROFILE='+$profilePath)
    exit 0
} catch {
    Write-Error -Message 'Profile creation failed: check explicit selections, settings, and an unused filename in an existing directory.' -ErrorAction Continue
    exit 2
}
