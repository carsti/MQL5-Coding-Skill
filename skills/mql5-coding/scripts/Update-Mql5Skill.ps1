#Requires -Version 5.1
[CmdletBinding()]
param(
    [ValidateSet('Check','Update','Rollback')][string]$Action='Check',
    [string]$Version,
    [string]$CodexDirectory,
    [string]$BackupId,
    [string]$ArchivePath,
    [string]$ExpectedArchiveSha256,
    [string]$ExpectedSourceCommit
)
Set-StrictMode -Version Latest
$ErrorActionPreference='Stop'
. (Join-Path $PSScriptRoot 'SkillRelease.ps1')
try {
    if ([string]::IsNullOrWhiteSpace($CodexDirectory)) {
        $CodexDirectory=if ([string]::IsNullOrWhiteSpace($env:CODEX_HOME)) {Join-Path $env:USERPROFILE '.codex'} else {$env:CODEX_HOME}
    }
    $codex=Assert-Mql5ReleasePath $CodexDirectory
    $target=Assert-Mql5ReleasePath (Join-Path $codex 'skills/mql5-coding')
    $stateRoot=Assert-Mql5ReleasePath (Join-Path $codex 'tools/mql5-skill-updates')
    if ($Action -eq 'Rollback') {
        if ($BackupId -cnotmatch '\A[0-9a-f]{32}\z' -or $Version -or $ArchivePath -or $ExpectedArchiveSha256 -or $ExpectedSourceCommit) {throw 'Rollback requires only a recorded BackupId and optional CodexDirectory.'}
    } elseif ($BackupId) {throw 'BackupId is only valid for Rollback.'}
    if ($Action -ne 'Rollback') {
        if ($ArchivePath) {
            if ($Action -ne 'Update' -or $ExpectedArchiveSha256 -cnotmatch '\A[0-9a-f]{64}\z' -or $ExpectedSourceCommit -cnotmatch '\A[0-9a-f]{40}\z' -or $Version -cnotmatch '\A(?:0|[1-9][0-9]*)\.(?:0|[1-9][0-9]*)\.(?:0|[1-9][0-9]*)\z') {throw 'Offline update requires explicit Version, trusted SHA-256 and SourceCommit.'}
            $release=[pscustomobject]@{version=$Version;source_commit=$ExpectedSourceCommit;sha256=$ExpectedArchiveSha256;bytes=$null;url=$null}
        } else {
            if ($ExpectedArchiveSha256 -or $ExpectedSourceCommit) {throw 'Offline trust inputs require ArchivePath.'}
            $release=Get-Mql5SkillGitHubRelease $Version
        }
    }
    if ($Action -eq 'Check') {
        $installed=$null
        if (Test-Path -LiteralPath (Join-Path $target 'version.json')) {
            $identity=Read-Mql5ReleaseJson (Join-Path $target 'version.json')
            Assert-Mql5SkillVersion $identity;$installed=$identity.version
        }
        [ordered]@{action='check';installed_version=$installed;release=$release;installed_bytes_verified=$false} | ConvertTo-Json -Depth 6
        exit 0
    }
    [IO.Directory]::CreateDirectory($stateRoot) | Out-Null
    $lock=[IO.File]::Open((Join-Path $stateRoot '.lock'),[IO.FileMode]::OpenOrCreate,[IO.FileAccess]::ReadWrite,[IO.FileShare]::None)
    try {
        $pending=@(Get-ChildItem -LiteralPath $stateRoot -Directory | Where-Object {Test-Path -LiteralPath (Join-Path $_.FullName 'pending.json')})
        if ($pending.Count -and ($Action -ne 'Rollback' -or $BackupId -cnotin @($pending.Name))) {throw ('An interrupted transaction requires Rollback with BackupId '+$pending[-1].Name+'.')}
        if ($Action -eq 'Rollback') {
            # Validate the recovery metadata before publishing or clearing any
            # files. A malformed sibling must not fail only after restoration.
            $pendingIntents=@{}
            foreach ($item in $pending) {
                if ($item.Name -cnotmatch '\A[0-9a-f]{32}\z') {throw 'Invalid pending transaction ID.'}
                $path=Assert-Mql5ReleasePath (Join-Path $item.FullName 'pending.json')
                $intent=Read-Mql5ReleaseJson $path;Assert-Mql5ReleaseIntent $intent $target
                $pendingIntents[$item.Name]=[pscustomobject]@{id=$item.Name;path=$path;value=$intent}
            }
            # A crash during rollback must recover the intended original snapshot,
            # rather than restoring the partially published tree saved by that rollback.
            $visited=@{}
            for ($depth=0;$depth -lt 32;$depth++) {
                if ($visited.ContainsKey($BackupId)) {throw 'Cyclic pending rollback recovery.'}
                $visited[$BackupId]=$true
                if (-not $pendingIntents.ContainsKey($BackupId)) {break}
                $intent=$pendingIntents[$BackupId].value
                if ($intent.action -ceq 'update') {break}
                $BackupId=$intent.restore_backup_id
            }
            if ($depth -eq 32) {throw 'Pending rollback recovery is too deep.'}
            $resolvePending={
                # A rollback can itself be interrupted repeatedly. Collect the
                # entire verified recovery family before deleting any intents;
                # deleting only direct children leaves later attempts pending.
                $resolved=@{};$resolved[$BackupId]=0
                $intents=@()
                foreach ($item in $pendingIntents.Values) {
                    $intent=$item.value
                    if ($item.id -ceq $BackupId -or $intent.action -ceq 'rollback') {
                        $intents+=@([pscustomobject]@{id=$item.id;path=$item.path;parent=if ($intent.action -ceq 'rollback') {$intent.restore_backup_id} else {$null}})
                    }
                }
                do {
                    $expanded=$false
                    foreach ($intent in $intents) {
                        if (-not $resolved.ContainsKey($intent.id) -and $null -ne $intent.parent -and $resolved.ContainsKey($intent.parent)) {
                            $resolved[$intent.id]=$resolved[$intent.parent]+1;$expanded=$true
                        }
                    }
                } while ($expanded)
                # Delete descendants first. If cleanup stops, any surviving
                # intent still has the full path to its original backup.
                foreach ($intent in @($intents | Where-Object {$resolved.ContainsKey($_.id)} | Sort-Object {$resolved[$_.id]} -Descending)) {[IO.File]::Delete($intent.path)}
            }
            $txn=Assert-Mql5ReleasePath (Join-Path $stateRoot $BackupId)
            $record=Read-Mql5ReleaseJson (Join-Path $txn 'backup.json')
            Assert-Mql5ReleaseBackup $record $BackupId $target
            $tree=Assert-Mql5ReleasePath (Join-Path $txn 'backup-tree')
            if ($record.had_installation) {
                if (-not (Test-Path -LiteralPath $tree -PathType Container)) {
                    # The process may have stopped after journaling but before the first rename.
                    if (-not (Test-Path -LiteralPath (Join-Path $txn 'pending.json'))) {throw 'Backup tree is missing.'}
                    Assert-Mql5ReleaseInventory $target $record.files
                    & $resolvePending
                    [ordered]@{action='recovered_unchanged';backup_id=$BackupId;target=$target;files_verified=$true} | ConvertTo-Json
                    exit 0
                }
                Assert-Mql5ReleaseInventory $tree $record.files
            }
            $newId=[guid]::NewGuid().ToString('N');$newTxn=Join-Path $stateRoot $newId
            [IO.Directory]::CreateDirectory($newTxn) | Out-Null
            $restore=Join-Path $newTxn 'restore-tree'
            if ($record.had_installation) {
                Copy-Item -LiteralPath $tree -Destination $restore -Recurse
                Assert-Mql5ReleaseInventory $restore $record.files
            } else {[IO.Directory]::CreateDirectory($restore) | Out-Null}
            $hadCurrent=Test-Path -LiteralPath $target -PathType Container
            $currentFiles=@(if ($hadCurrent) {Get-Mql5ReleaseInventory $target})
            if ($hadCurrent) {Copy-Mql5ReleaseSnapshot $target (Join-Path $newTxn 'backup-tree') $currentFiles}
            Write-Mql5ReleaseJson (Join-Path $newTxn 'backup.json') ([ordered]@{schema_version=1;backup_id=$newId;target=$target;had_installation=[bool]$hadCurrent;files=@($currentFiles)})
            Write-Mql5ReleaseJson (Join-Path $newTxn 'pending.json') @{action='rollback';target=$target;restore_backup_id=$BackupId}
            try {
                Set-Mql5ReleaseContents $target $restore (Join-Path $newTxn 'displaced-tree') $record.files -RemoveRoot:(-not $record.had_installation)
                [IO.File]::Delete((Join-Path $newTxn 'pending.json'))
                & $resolvePending
            } catch {
                if ($hadCurrent) {Assert-Mql5ReleaseInventory $target $currentFiles}
                elseif (Test-Path -LiteralPath $target) {throw 'Recovery remains pending: the previously absent target was not restored.'}
                [IO.File]::Delete((Join-Path $newTxn 'pending.json'));throw
            }
            [ordered]@{action='rollback';restored_backup_id=$BackupId;backup_id=$newId;target=$target;files_verified=$true;restart_codex=$true} | ConvertTo-Json
            exit 0
        }
        $id=[guid]::NewGuid().ToString('N');$txn=Join-Path $stateRoot $id
        [IO.Directory]::CreateDirectory($txn) | Out-Null
        $archive=Join-Path $txn 'download.zip'
        if ($ArchivePath) {Copy-Item -LiteralPath (Assert-Mql5ReleasePath $ArchivePath) -Destination $archive}
        else {
            & gh release download ('v'+$Version) --repo 'shamwi2846/MQL5-Coding-Skill' --pattern 'mql5-coding-windows.zip' --dir $txn 2>$null
            if ($LASTEXITCODE -ne 0) {throw 'Authenticated release download failed.'}
            [IO.File]::Move((Join-Path $txn 'mql5-coding-windows.zip'),$archive)
            if ((Get-Item -LiteralPath $archive).Length -ne $release.bytes) {throw 'Downloaded release size differs from GitHub metadata.'}
        }
        $stage=Join-Path $txn 'stage'
        $manifest=Expand-Mql5SkillRelease $archive $release.sha256 $Version $release.source_commit $stage
        $had=Test-Path -LiteralPath $target -PathType Container
        if ((Test-Path -LiteralPath $target) -and -not $had) {throw 'The skill destination is not a directory.'}
        if ($had -and (Test-Path -LiteralPath (Join-Path $target 'version.json'))) {
            $current=Read-Mql5ReleaseJson (Join-Path $target 'version.json')
            Assert-Mql5SkillVersion $current
            if ([version]$current.version -gt [version]$Version) {throw 'Use Rollback for a downgrade; Update cannot install an older release.'}
            if ($current.version -ceq $Version) {
                Assert-Mql5ReleaseInventory $target $manifest.files
                [ordered]@{action='already_current';version=$Version;source_commit=$release.source_commit;files_verified=$true;target=$target} | ConvertTo-Json
                exit 0
            }
        }
        $before=@(if ($had) {Get-Mql5ReleaseInventory $target})
        if ($had) {Copy-Mql5ReleaseSnapshot $target (Join-Path $txn 'backup-tree') $before}
        Write-Mql5ReleaseJson (Join-Path $txn 'backup.json') ([ordered]@{schema_version=1;backup_id=$id;target=$target;had_installation=[bool]$had;files=@($before)})
        Write-Mql5ReleaseJson (Join-Path $txn 'verified-release.json') $manifest
        Write-Mql5ReleaseJson (Join-Path $txn 'pending.json') @{action='update';target=$target}
        [IO.Directory]::CreateDirectory((Split-Path -Parent $target)) | Out-Null
        try {
            Set-Mql5ReleaseContents $target (Join-Path $stage 'mql5-coding') (Join-Path $txn 'displaced-tree') $manifest.files
            [IO.File]::Delete((Join-Path $txn 'pending.json'))
        } catch {
            if ($had) {Assert-Mql5ReleaseInventory $target $before}
            elseif (Test-Path -LiteralPath $target) {throw 'Recovery remains pending: the previously absent target was not restored.'}
            [IO.File]::Delete((Join-Path $txn 'pending.json'));throw
        }
        [ordered]@{action='updated';version=$Version;source_commit=$release.source_commit;archive_sha256=$release.sha256;backup_id=$id;had_previous_installation=[bool]$had;target=$target;files_verified=$true;restart_codex=$true} | ConvertTo-Json
    } finally {$lock.Dispose()}
} catch {Write-Error $_;exit 1}
