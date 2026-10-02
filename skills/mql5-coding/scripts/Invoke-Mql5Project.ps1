#Requires -Version 5.1
[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$ProfilePath,
    [ValidateSet('Validate','Compile','TesterPreflight','TesterSmoke')][string]$Action='Validate',
    [string]$Entrypoint,
    [switch]$SyntaxOnly,
    [string]$CompilationReceiptPath,
    [string]$ExpectedExpertSha256,
    [string]$OutputDirectory,
    [string]$ExpectedLogMarker,
    [string]$ExpectedLogMarkerFile,
    [switch]$AcknowledgeSavedAccountRisk
)
Set-StrictMode -Version Latest
$ErrorActionPreference='Stop'
function Invoke-Mql5ProfileTool([string]$Tool, [hashtable]$Parameters) {
    $hostExecutable=if ($PSVersionTable.PSEdition -eq 'Core') {Join-Path $PSHOME 'pwsh.exe'} else {Join-Path $PSHOME 'powershell.exe'}
    $arguments=@('-NoLogo','-NoProfile','-NonInteractive','-ExecutionPolicy','Bypass','-File',(Join-Path $PSScriptRoot $Tool))
    foreach ($key in @($Parameters.Keys | Sort-Object)) {
        $value=$Parameters[$key]
        if ($value -is [bool]) {if ($value) {$arguments+=@('-'+$key)}; continue}
        $arguments+=@(('-'+$key),([string]$value))
    }
    # Use Windows argv quoting consistently in PS 5.1 and PS 7, including
    # marker strings containing quotes. No shell evaluates these arguments.
    $quoted=@($arguments | ForEach-Object {
        if ($_ -notmatch '[\s"]') {$_}
        else {'"'+($_ -replace '(\\*)"','$1$1\"' -replace '(\\+)$','$1$1')+'"'}
    })
    $start=New-Object Diagnostics.ProcessStartInfo
    $start.FileName=$hostExecutable
    $start.Arguments=$quoted -join ' '
    $start.UseShellExecute=$false
    $start.CreateNoWindow=$true
    $start.RedirectStandardOutput=$true
    $start.RedirectStandardError=$true
    $process=New-Object Diagnostics.Process
    $process.StartInfo=$start
    try {
        [void]$process.Start()
        $errors=$process.StandardError.ReadToEndAsync()
        while ($null -ne ($line=$process.StandardOutput.ReadLine())) {Write-Output $line}
        $process.WaitForExit()
        [Console]::Error.Write($errors.GetAwaiter().GetResult())
        $script:profileToolExit=$process.ExitCode
    } finally {$process.Dispose()}
}
try {
    . (Join-Path $PSScriptRoot 'Mql5ProjectProfile.ps1')
    $profile=Read-Mql5ProjectProfile $ProfilePath
    if ($Action -eq 'Validate') {
        if (@($PSBoundParameters.Keys | Where-Object {$_ -notin @('ProfilePath','Action')}).Count) {throw 'Validation accepts only a profile path and action.'}
        $profile | ConvertTo-Json -Depth 8
        exit 0
    }
    if ($Action -eq 'Compile') {
        if ($PSBoundParameters.ContainsKey('OutputDirectory') -or $PSBoundParameters.ContainsKey('CompilationReceiptPath') -or $PSBoundParameters.ContainsKey('ExpectedExpertSha256') -or $PSBoundParameters.ContainsKey('ExpectedLogMarker') -or $PSBoundParameters.ContainsKey('ExpectedLogMarkerFile') -or $AcknowledgeSavedAccountRisk) {throw 'Tester parameters cannot be used for compilation.'}
        $selected=@($profile.entrypoints)
        if ($PSBoundParameters.ContainsKey('Entrypoint')) {
            $path=Resolve-Mql5ProfilePath $Entrypoint $profile.project_root 'Leaf'
            if ($path -notin $profile.entrypoints) {throw 'Entrypoint is not selected by this profile.'}
            $selected=@($path)
        }
        foreach ($source in $selected) {
            $parameters=@{SourcePath=$source;MetaEditorPath=$profile.metaeditor_path;TimeoutSeconds=$profile.compiler.timeout_seconds;WarningsAsErrors=$profile.compiler.warnings_as_errors;SyntaxOnly=[bool]$SyntaxOnly}
            if ($null -ne $profile.include_path) {$parameters.IncludePath=$profile.include_path}
            Invoke-Mql5ProfileTool 'Compile-Mql5.ps1' $parameters
            if ($script:profileToolExit -ne 0) {exit $script:profileToolExit}
        }
        exit 0
    }
    if ($SyntaxOnly -or $PSBoundParameters.ContainsKey('Entrypoint')) {throw 'Tester action uses the saved tester entrypoint.'}
    if ($null -eq $profile.tester) {throw 'This profile has no tester configuration.'}
    if ($Action -eq 'TesterSmoke' -and -not $AcknowledgeSavedAccountRisk) {throw 'Execution requires the separate saved-account risk acknowledgement.'}
    if ($Action -eq 'TesterPreflight' -and $AcknowledgeSavedAccountRisk) {throw 'Preflight does not record execution approval.'}
    if ([string]::IsNullOrWhiteSpace($OutputDirectory)) {throw 'Select a new output directory for this tester run.'}
    if ([string]::IsNullOrWhiteSpace($CompilationReceiptPath) -and [string]::IsNullOrWhiteSpace($ExpectedExpertSha256)) {throw 'Select the exact successful receipt or trusted EX5 hash for this run.'}
    $t=$profile.tester
    $parameters=@{ExpertPath=[IO.Path]::ChangeExtension($t.entrypoint,'.ex5');TerminalPath=$t.terminal_path;TerminalDataPath=$t.terminal_data_path;UseExpertDefaults=$t.use_expert_defaults;OutputDirectory=[IO.Path]::GetFullPath($OutputDirectory);TimeoutSeconds=$t.timeout_seconds;Execute=($Action -eq 'TesterSmoke');PreflightOnly=($Action -eq 'TesterPreflight');AcknowledgeSavedAccountRisk=[bool]$AcknowledgeSavedAccountRisk}
    foreach ($mapping in @(@('symbol','Symbol'),@('period','Period'),@('from_date','FromDate'),@('to_date','ToDate'),@('model','Model'),@('deposit','Deposit'),@('currency','Currency'),@('leverage','Leverage'),@('execution_mode','ExecutionMode'))) {$parameters[$mapping[1]]=$t.settings.($mapping[0])}
    if ($null -ne $t.set_path) {$parameters.SetPath=$t.set_path}
    foreach ($key in @('CompilationReceiptPath','ExpectedExpertSha256','ExpectedLogMarker','ExpectedLogMarkerFile')) {if ($PSBoundParameters.ContainsKey($key)) {$parameters[$key]=$PSBoundParameters[$key]}}
    Invoke-Mql5ProfileTool 'Invoke-Mt5TesterSmoke.ps1' $parameters
    if ($script:profileToolExit -eq 0 -and -not (Test-Path -LiteralPath (Join-Path $parameters.OutputDirectory 'smoke-result.json') -PathType Leaf)) {throw 'Tester wrapper returned without its result JSON.'}
    exit $script:profileToolExit
} catch {
    Write-Error -Message 'Project invocation failed: validate the profile, explicit action, per-run evidence/output path, and separate execution acknowledgement.' -ErrorAction Continue
    exit 2
}
