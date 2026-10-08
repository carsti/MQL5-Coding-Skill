#Requires -Version 5.1
# Internal evaluator validation only; this helper launches no editor or terminal.
[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$TrustedSkillRoot,
    [Parameter(Mandatory)][string]$WorkspaceRoot,
    [Parameter(Mandatory)][string]$ReceiptPathsFile
)
Set-StrictMode -Version Latest
$ErrorActionPreference='Stop'
[Console]::OutputEncoding=New-Object Text.UTF8Encoding($false)
$scripts=Join-Path $TrustedSkillRoot 'scripts'
$project=[IO.Path]::GetFullPath((Join-Path $WorkspaceRoot 'inputs\project'))
$reads=New-Object 'System.Collections.Generic.List[object]'
$paths=New-Object 'System.Collections.Generic.List[object]'
$leases=[Collections.Hashtable]::new([StringComparer]::Ordinal)
$fixedLocalVolumeIdentities=@{}
try {
    if (-not ('Mql5Coding.JobProcessLaunch' -as [type])) {Add-Type -Path (Join-Path $scripts 'TesterProcessJob.cs')}
    . (Join-Path $scripts 'TesterPathIntegrity.ps1')
    . (Join-Path $scripts 'CompilationReceipt.ps1')
    $selection=[IO.File]::ReadAllText($ReceiptPathsFile,[Text.UTF8Encoding]::new($false,$true))
    if (-not $selection.TrimStart().StartsWith('{')) {throw 'Receipt selection must be a JSON object.'}
    $selection=$selection|ConvertFrom-Json
    if ($selection.paths -isnot [Array] -or $selection.paths.Count -lt 2 -or $selection.paths.Count -gt 64) {throw 'Expected bounded receipt-path evidence.'}
    $verified=New-Object 'System.Collections.Generic.List[object]'
    foreach ($path in $selection.paths) {
        if ($path -isnot [string] -or -not (Test-IsAbsoluteLocalDrivePath $path)) {throw 'Expected an absolute receipt path.'}
        $full=[IO.Path]::GetFullPath($path)
        if (-not [IO.Path]::GetDirectoryName($full).Equals($project,[StringComparison]::OrdinalIgnoreCase)) {throw 'Receipt must belong to the prepared project.'}
        # Let the existing bounded, locked reader parse untrusted receipt bytes.
        # Each receipt must validate against one of the two known entrypoints.
        $proof=$null;$source=$null
        foreach ($name in @('A.mq5','B.mq5')) {
            $candidateSource=Join-Path $project $name
            try {
                $candidate=Test-Mql5CompilationReceipt -Path $full -ExpertPath ([IO.Path]::ChangeExtension($candidateSource,'.ex5')) -ExpectedExpertHash $null -Tracker $reads -PathEntryLeases $paths -LeasesByPath $leases
                $proof=$candidate;$source=$candidateSource;break
            } catch { }
        }
        if ($null -eq $proof) {throw 'Receipt failed validation for both selected entrypoints.'}
        $verified.Add([pscustomobject]@{source_path=$source;receipt_path=$full;proof=$proof})
    }
    $sources=@($verified|ForEach-Object {$_.source_path}|Sort-Object -Unique)
    if ($sources.Count -ne 2) {throw 'Both selected entrypoints require verified receipts.'}
    [pscustomobject]@{status='verified';records=@($verified.ToArray())}|ConvertTo-Json -Depth 12 -Compress
}
catch {
    [Console]::Error.WriteLine('Workflow receipt verification failed: '+$_.Exception.Message)
    exit 2
}
finally {
    for ($i=$reads.Count-1;$i -ge 0;$i--) {$reads[$i].stream.Dispose()}
    for ($i=$paths.Count-1;$i -ge 0;$i--) {$paths[$i].Dispose()}
}
