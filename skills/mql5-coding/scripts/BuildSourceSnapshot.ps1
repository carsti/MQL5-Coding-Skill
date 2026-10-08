#Requires -Version 5.1
# Optional build evidence. Inventories describe possible dependencies, not compiler consumption.
. (Join-Path $PSScriptRoot 'ToolkitSupport.ps1')
if (-not ('Mql5Coding.JobProcessLaunch' -as [type])) {Add-Type -Path (Join-Path $PSScriptRoot 'TesterProcessJob.cs')}
. (Join-Path $PSScriptRoot 'TesterPathIntegrity.ps1')

function New-Mql5SnapshotLocks([bool]$AllowDirectoryWrites=$false) {
    return [pscustomobject]@{locks=(New-Object 'System.Collections.Generic.List[object]');leases=(New-Object 'System.Collections.Generic.List[object]');by_path=([Collections.Hashtable]::new([StringComparer]::Ordinal));allow_directory_writes=$AllowDirectoryWrites}
}
function Close-Mql5SnapshotLocks($Context) {
    $failures=@()
    foreach ($list in @($Context.locks,$Context.leases)) {
        for ($i=$list.Count-1;$i -ge 0;$i--) {
            try {if ($null -ne $list[$i].PSObject.Properties['stream']) {$list[$i].stream.Dispose()} else {$list[$i].Dispose()}} catch {$failures+=@('Snapshot lock cleanup failed.')}
        }
        $list.Clear()
    }
    if ($failures.Count) {throw ($failures -join ' ')}
}
function Open-Mql5SnapshotJson([string]$Path,$Context) {
    if (-not (Test-IsAbsoluteLocalDrivePath $Path)) {throw 'Snapshot evidence paths must be absolute local-drive paths.'}
    $record=Open-VerifiedArtifactReadLock -Path $Path -Kind 'build snapshot evidence' -Tracker $Context.locks -PathEntryLeases $Context.leases -LeasesByPath $Context.by_path -AllowDirectoryWrites:([bool](Get-ToolkitValue $Context 'allow_directory_writes' $false))
    $stream=$Context.locks[$Context.locks.Count-1].stream
    if ($stream.Length -le 0 -or $stream.Length -gt 16777216) {throw 'Snapshot JSON must contain between 1 byte and 16 MiB.'}
    $bytes=New-Object byte[] ([int]$stream.Length);$stream.Position=0;$offset=0
    while ($offset -lt $bytes.Length) {$got=$stream.Read($bytes,$offset,$bytes.Length-$offset);if ($got -eq 0){throw 'Incomplete snapshot evidence.'};$offset+=$got}
    $stream.Position=0
    $value=Read-Mql5ReleaseJson -Path $Path -Bytes $bytes -MaximumBytes 16777216
    if ($value -isnot [pscustomobject]) {throw 'Snapshot JSON requires an object root.'}
    return [pscustomobject]@{value=$value;source=@{path=$record.destination_path;sha256=$record.sha256;byte_length=$record.byte_length}}
}
function Assert-Mql5SnapshotCommitment($Commitment,$Actual) {
    Assert-ToolkitFields $Commitment @('path','sha256','byte_length')
    if ($Commitment.path -isnot [string] -or -not (Test-IsAbsoluteLocalDrivePath $Commitment.path) -or
        $Commitment.sha256 -isnot [string] -or $Commitment.sha256 -cnotmatch '^[0-9a-f]{64}$' -or
        ($Commitment.byte_length -isnot [int] -and $Commitment.byte_length -isnot [long]) -or $Commitment.byte_length -lt 0 -or
        -not ([IO.Path]::GetFullPath($Commitment.path).Equals([IO.Path]::GetFullPath($Actual.path),[StringComparison]::OrdinalIgnoreCase)) -or
        $Commitment.sha256 -cne $Actual.sha256 -or $Commitment.byte_length -ne $Actual.byte_length) {throw 'Build snapshot hash, length, or path does not match the selected evidence.'}
}
function Assert-Mql5SourceInventory($Inventory,[string]$Entrypoint,$Context) {
    if (($Inventory.schema_version -isnot [int] -and $Inventory.schema_version -isnot [long]) -or $Inventory.schema_version -ne 1 -or
        $Inventory.operation -isnot [string] -or $Inventory.operation -cne 'includes inventory' -or
        $Inventory.status -isnot [string] -or $Inventory.status -cne 'completed' -or
        $Inventory.files -isnot [array] -or $Inventory.files.Count -lt 1 -or $Inventory.files.Count -gt 10000 -or
        $Inventory.entrypoints -isnot [array] -or $Inventory.entrypoints.Count -ne 1 -or
        $Inventory.entrypoints[0] -isnot [string] -or -not $Inventory.entrypoints[0].Equals($Entrypoint,[StringComparison]::OrdinalIgnoreCase) -or
        $Inventory.coverage -isnot [string] -or $Inventory.coverage -cnotin @('selected_entrypoints_scanned','uncertain')) {throw 'Expected a completed bounded include inventory for this entrypoint.'}
    $seen=@{};$sourceSeen=$false;$identities=@()
    foreach ($file in $Inventory.files) {
        if ($file.path -isnot [string] -or $seen.ContainsKey($file.path)) {throw 'Invalid or duplicate inventory source.'}
        $seen[$file.path]=$true
        $record=Open-VerifiedArtifactReadLock -Path $file.path -Kind 'known build source' -Tracker $Context.locks -PathEntryLeases $Context.leases -LeasesByPath $Context.by_path -AllowDirectoryWrites:([bool](Get-ToolkitValue $Context 'allow_directory_writes' $false))
        Assert-Mql5SnapshotCommitment $file ([pscustomobject]@{path=$record.destination_path;sha256=$record.sha256;byte_length=$record.byte_length})
        $identities+=@([pscustomobject]@{path=$record.destination_path;file_identity=[Mql5Coding.JobProcessLaunch]::GetFileIdentity($Context.locks[$Context.locks.Count-1].stream.SafeFileHandle)})
        if ($file.path.Equals($Entrypoint,[StringComparison]::OrdinalIgnoreCase)) {$sourceSeen=$true}
    }
    if (-not $sourceSeen) {throw 'Inventory does not fingerprint the selected root source.'}
    return ,$identities
}
function Invoke-Mql5SnapshotInventory($Profile,[string]$Entrypoint,[string]$Python,[string]$Output) {
    $arguments=@('-B',(Join-Path $PSScriptRoot 'mql5_toolkit.py'),'includes','inventory','--root',$Profile.project_root,'--entrypoint',$Entrypoint,'--output',$Output)
    if ($null -ne $Profile.include_path) {
        $root=Join-Path $Profile.include_path 'Include'
        if (Test-Path -LiteralPath $root -PathType Container) {$arguments+=@('--include-root',$root)}
    }
    $run=Invoke-ToolkitProcess $Python $arguments $Profile.project_root 120
    if ($run.status -cne 'completed' -or $run.exit_code -ne 0 -or -not $run.cleanup_verified) {throw 'Include inventory failed; retained evidence may be incomplete.'}
    return Join-Path $Output 'result.json'
}
function Start-Mql5BuildSnapshot($Profile,[string]$Entrypoint,[string]$PythonPath) {
    $context=New-Mql5SnapshotLocks $true
    try {
        $python=Get-ToolkitPython $PythonPath
        $root=New-ToolkitOutput (Join-Path (Split-Path -Parent $Entrypoint) ('.mql5-source-snapshot-'+[guid]::NewGuid().ToString('N')))
        $beforePath=Invoke-Mql5SnapshotInventory $Profile $Entrypoint $python (Join-Path $root 'before')
        $before=Open-Mql5SnapshotJson $beforePath $context
        $identities=Assert-Mql5SourceInventory $before.value $Entrypoint $context
        $rootLimit=if ($null -eq $Profile.include_path) {'No standard include root was selected; angle-include coverage is unavailable.'} elseif (-not (Test-Path -LiteralPath (Join-Path $Profile.include_path 'Include') -PathType Container)) {'Configured standard include directory was unavailable: '+(Join-Path $Profile.include_path 'Include')} else {'Standard includes were inventoried only from the explicitly selected root: '+(Join-Path $Profile.include_path 'Include')}
        return [pscustomobject]@{locks=$context;root=$root;python=$python;profile=$Profile;entrypoint=$Entrypoint;before=$before;identities=$identities;root_limitation=$rootLimit}
    } catch {Close-Mql5SnapshotLocks $context;throw}
}
function Complete-Mql5BuildSnapshot($Capture,[string]$ReceiptPath) {
    if ([string]::IsNullOrWhiteSpace($ReceiptPath)) {throw 'Compilation returned without its receipt.'}
    $receipt=Open-Mql5SnapshotJson $ReceiptPath $Capture.locks
    if (($receipt.value.schema_version -isnot [int] -and $receipt.value.schema_version -isnot [long]) -or $receipt.value.schema_version -ne 1 -or
        $receipt.value.kind -isnot [string] -or $receipt.value.kind -cne 'mql5_compilation_receipt' -or
        $receipt.value.status -isnot [string] -or $receipt.value.status -cne 'success' -or
        ($receipt.value.exit_code -isnot [int] -and $receipt.value.exit_code -isnot [long]) -or $receipt.value.exit_code -ne 0 -or
        $receipt.value.syntax_only -isnot [bool] -or $receipt.value.syntax_only -or
        $receipt.value.compiler -isnot [pscustomobject] -or $receipt.value.compiler.file_version -isnot [string] -or
        [string]::IsNullOrWhiteSpace($receipt.value.compiler.file_version) -or
        $receipt.value.source -isnot [pscustomobject] -or $receipt.value.source.path -isnot [string] -or
        $receipt.value.source.path -ine $Capture.entrypoint) {throw 'Snapshot requires an artifact-producing successful compilation.'}
    $source=@($Capture.before.value.files | Where-Object {$_.path -ieq $Capture.entrypoint})[0]
    Assert-Mql5SnapshotCommitment $receipt.value.source $source
    $afterPath=Invoke-Mql5SnapshotInventory $Capture.profile $Capture.entrypoint $Capture.python (Join-Path $Capture.root 'after')
    $after=Open-Mql5SnapshotJson $afterPath $Capture.locks
    $afterIdentities=Assert-Mql5SourceInventory $after.value $Capture.entrypoint $Capture.locks
    Assert-Mql5SnapshotIdentities $Capture.identities $afterIdentities
    $comparisonRoot=Join-Path $Capture.root 'comparison'
    $run=Invoke-ToolkitProcess $Capture.python @('-B',(Join-Path $PSScriptRoot 'mql5_toolkit.py'),'includes','compare','--baseline',$Capture.before.source.path,'--candidate',$after.source.path,'--output',$comparisonRoot) $Capture.profile.project_root 120
    if ($run.status -cne 'completed' -or $run.exit_code -ne 0 -or -not $run.cleanup_verified) {throw 'Build snapshot comparison failed.'}
    $comparison=Open-Mql5SnapshotJson (Join-Path $comparisonRoot 'result.json') $Capture.locks
    Assert-Mql5SnapshotComparison $comparison.value $Capture.before.source $after.source
    $sidecar=[ordered]@{schema_version=1;kind='mql5_build_source_snapshot';status='verified_known_sources';entrypoint=$Capture.entrypoint;compilation_receipt=$receipt.source;before=$Capture.before.source;after=$after.source;comparison=$comparison.source;known_source_identities=$Capture.identities;coverage=@{before=$Capture.before.value.coverage;after=$after.value.coverage};limitations=@('Possible dependencies only; not proof of exact compiler consumption or runtime dependencies.','Unresolved and conditional include coverage remains visible in the retained inventories.',$Capture.root_limitation)}
    $path=$ReceiptPath+'.sources.json'
    $bytes=(New-Object Text.UTF8Encoding($false)).GetBytes(($sidecar | ConvertTo-Json -Depth 10)+[Environment]::NewLine)
    $stream=[IO.File]::Open($path,[IO.FileMode]::CreateNew,[IO.FileAccess]::Write,[IO.FileShare]::None)
    try {$stream.Write($bytes,0,$bytes.Length);$stream.Flush($true)} finally {$stream.Dispose()}
    return $path
}
function Assert-Mql5SnapshotIdentities($Recorded,$Current) {
    if ($Recorded -isnot [array] -or $Recorded.Count -ne $Current.Count) {throw 'Snapshot known-file identities are incomplete.'}
    $seen=@{}
    foreach ($file in $Recorded) {
        Assert-ToolkitFields $file @('path','file_identity')
        if ($file.path -isnot [string] -or $file.file_identity -isnot [string] -or $file.file_identity -cnotmatch '^[0-9A-F]{8}:[0-9A-F]{16}$' -or $seen.ContainsKey($file.path)) {throw 'Invalid known-file identity.'}
        $seen[$file.path]=$file.file_identity
    }
    foreach ($file in $Current) {if (-not $seen.ContainsKey($file.path) -or $seen[$file.path] -cne $file.file_identity) {throw 'A known source was replaced after snapshot capture.'}}
}
function Assert-Mql5SnapshotComparison($Comparison,$Before,$After) {
    if (($Comparison.schema_version -isnot [int] -and $Comparison.schema_version -isnot [long]) -or $Comparison.schema_version -ne 1 -or
        $Comparison.operation -isnot [string] -or $Comparison.operation -cne 'includes compare' -or
        $Comparison.status -isnot [string] -or $Comparison.status -cne 'completed' -or
        $Comparison.differences -isnot [array] -or $Comparison.differences.Count -ne 0 -or $Comparison.sources -isnot [array] -or $Comparison.sources.Count -ne 2) {throw 'Build sources were not stable across compilation.'}
    Assert-Mql5SnapshotCommitment $Comparison.sources[0] $Before
    Assert-Mql5SnapshotCommitment $Comparison.sources[1] $After
}
function Test-Mql5BuildSnapshot([string]$Path,[string]$ReceiptPath,[string]$Entrypoint,$Context) {
    if ([string]::IsNullOrWhiteSpace($ReceiptPath)) {throw 'BuildSnapshotPath requires CompilationReceiptPath.'}
    $snapshot=Open-Mql5SnapshotJson $Path $Context;$value=$snapshot.value
    Assert-ToolkitFields $value @('schema_version','kind','status','entrypoint','compilation_receipt','before','after','comparison','known_source_identities','coverage','limitations')
    if (($value.schema_version -isnot [int] -and $value.schema_version -isnot [long]) -or $value.schema_version -ne 1 -or
        $value.kind -isnot [string] -or $value.kind -cne 'mql5_build_source_snapshot' -or
        $value.status -isnot [string] -or $value.status -cne 'verified_known_sources' -or
        $value.entrypoint -isnot [string] -or -not $value.entrypoint.Equals($Entrypoint,[StringComparison]::OrdinalIgnoreCase)) {throw 'Invalid build snapshot identity or status.'}
    $receipt=Open-Mql5SnapshotJson $ReceiptPath $Context
    Assert-Mql5SnapshotCommitment $value.compilation_receipt ([pscustomobject]$receipt.source)
    if (($receipt.value.schema_version -isnot [int] -and $receipt.value.schema_version -isnot [long]) -or $receipt.value.schema_version -ne 1 -or
        $receipt.value.kind -isnot [string] -or $receipt.value.kind -cne 'mql5_compilation_receipt' -or
        $receipt.value.status -isnot [string] -or $receipt.value.status -cne 'success' -or
        ($receipt.value.exit_code -isnot [int] -and $receipt.value.exit_code -isnot [long]) -or $receipt.value.exit_code -ne 0 -or
        $receipt.value.syntax_only -isnot [bool] -or $receipt.value.syntax_only -or
        $receipt.value.compiler -isnot [pscustomobject] -or $receipt.value.compiler.file_version -isnot [string] -or
        [string]::IsNullOrWhiteSpace($receipt.value.compiler.file_version) -or
        $receipt.value.source -isnot [pscustomobject] -or $receipt.value.source.path -isnot [string] -or
        $receipt.value.source.path -ine $Entrypoint) {throw 'Snapshot requires the matching successful artifact-producing receipt.'}
    $inventories=@()
    foreach ($name in @('before','after')) {
        $evidence=Open-Mql5SnapshotJson $value.$name.path $Context
        Assert-Mql5SnapshotCommitment $value.$name ([pscustomobject]$evidence.source)
        $identities=Assert-Mql5SourceInventory $evidence.value $Entrypoint $Context
        Assert-Mql5SnapshotIdentities $value.known_source_identities $identities
        $inventories+=@($evidence.value)
    }
    Assert-ToolkitFields $value.coverage @('before','after')
    if ($value.coverage.before -isnot [string] -or $value.coverage.after -isnot [string] -or
        $value.coverage.before -cne $inventories[0].coverage -or $value.coverage.after -cne $inventories[1].coverage -or $value.limitations -isnot [array] -or $value.limitations.Count -lt 1) {throw 'Snapshot coverage or limitations differ from recorded inventories.'}
    $rootSource=@($inventories[0].files | Where-Object {$_.path -ieq $Entrypoint})[0]
    Assert-Mql5SnapshotCommitment $receipt.value.source $rootSource
    $comparison=Open-Mql5SnapshotJson $value.comparison.path $Context
    Assert-Mql5SnapshotCommitment $value.comparison ([pscustomobject]$comparison.source)
    Assert-Mql5SnapshotComparison $comparison.value $value.before $value.after
    $before=@{};foreach ($file in $inventories[0].files){$before[$file.path]=$file.sha256}
    if ($before.Count -ne $inventories[1].files.Count) {throw 'Build inventories have different known files.'}
    foreach ($file in $inventories[1].files){if (-not $before.ContainsKey($file.path) -or $before[$file.path] -cne $file.sha256){throw 'Build inventories have different known sources.'}}
    return [pscustomobject]@{status='verified_known_sources';coverage=$value.coverage;source=$snapshot.source}
}
