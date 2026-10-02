#Requires -Version 5.1
Set-StrictMode -Version Latest
$ErrorActionPreference='Stop'
$repo=Split-Path -Parent $PSScriptRoot
$skill=Join-Path $repo 'skills/mql5-coding'
. (Join-Path $skill 'scripts/SkillRelease.ps1')
$work=Join-Path $repo ('build/release-tests-'+[guid]::NewGuid().ToString('N'))
[IO.Directory]::CreateDirectory($work) | Out-Null
$shell=(Get-Process -Id $PID).Path
$commit='aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa'
$version=(Read-Mql5ReleaseJson (Join-Path $skill 'version.json')).version
$script:checks=0
function Check([bool]$Condition,[string]$Name) {
    if (-not $Condition) {throw "FAIL: $Name"}
    $script:checks++;Write-Host "PASS: $Name"
}
function Reject([scriptblock]$Body,[string]$Name) {
    $failed=$false;try {& $Body | Out-Null} catch {$failed=$true}
    Check $failed $Name
}
function Quote([string]$Value) {return '"'+[regex]::Replace([regex]::Replace($Value,'(\\*)"','$1$1\"'),'(\\+)$','$1$1')+'"'}
function RunUpdater([string[]]$Options) {
    $info=New-Object Diagnostics.ProcessStartInfo
    $info.FileName=$shell
    $info.Arguments=(@('-NoLogo','-NoProfile','-ExecutionPolicy','Bypass','-File',(Join-Path $skill 'scripts/Update-Mql5Skill.ps1'))+$Options | ForEach-Object {Quote $_}) -join ' '
    $info.UseShellExecute=$false;$info.CreateNoWindow=$true;$info.RedirectStandardOutput=$true;$info.RedirectStandardError=$true
    $info.WorkingDirectory=$work
    $process=New-Object Diagnostics.Process;$process.StartInfo=$info
    try {
        [void]$process.Start();$stdout=$process.StandardOutput.ReadToEndAsync();$stderr=$process.StandardError.ReadToEndAsync()
        if (-not $process.WaitForExit(30000)) {$process.Kill();throw 'Updater exceeded test timeout.'}
        $output=$stdout.GetAwaiter().GetResult();$errorText=$stderr.GetAwaiter().GetResult()
        if ($process.ExitCode -eq 0) {$data=$output | ConvertFrom-Json} else {$data=$null}
        return [pscustomobject]@{code=$process.ExitCode;data=$data;error_text=$errorText}
    } finally {$process.Dispose()}
}
function Options([string]$FixtureHome,[string]$Zip,[string]$Hash) {
    return @('-Action','Update','-Version',$version,'-CodexDirectory',$FixtureHome,'-ArchivePath',$Zip,'-ExpectedArchiveSha256',$Hash,'-ExpectedSourceCommit',$commit)
}
function ChangeZip([string]$Name,[string]$Entry,[string]$Content,[switch]$Add) {
    $path=Join-Path $work ($Name+'.zip');Copy-Item -LiteralPath $archive -Destination $path
    $zip=[IO.Compression.ZipFile]::Open($path,[IO.Compression.ZipArchiveMode]::Update)
    try {
        if (-not $Add) {$zip.GetEntry($Entry).Delete()}
        $item=$zip.CreateEntry($Entry);$stream=$item.Open()
        try {$bytes=(New-Object Text.UTF8Encoding($false)).GetBytes($Content);$stream.Write($bytes,0,$bytes.Length)} finally {$stream.Dispose()}
    } finally {$zip.Dispose()}
    return $path
}
foreach ($file in @((Join-Path $repo 'scripts/Package-Skill.ps1'))+@(Get-ChildItem -LiteralPath (Join-Path $skill 'scripts') -Filter '*.ps1' | ForEach-Object {$_.FullName})) {
    $tokens=$null;$parseErrors=$null
    [void][Management.Automation.Language.Parser]::ParseFile($file,[ref]$tokens,[ref]$parseErrors)
    Check ($parseErrors.Count -eq 0) ('syntax '+[IO.Path]::GetFileName($file))
}
$first=Join-Path $work 'first';$second=Join-Path $work 'second'
& (Join-Path $repo 'scripts/Package-Skill.ps1') -SkillRoot $skill -OutputDirectory $first -SourceCommit $commit -Tag ('v'+$version) | Out-Null
& (Join-Path $repo 'scripts/Package-Skill.ps1') -SkillRoot $skill -OutputDirectory $second -SourceCommit $commit -Tag ('v'+$version) | Out-Null
$archive=Join-Path $first 'mql5-coding-windows.zip';$digest=Get-Mql5ReleaseHash $archive
Check ($digest -ceq (Get-Mql5ReleaseHash (Join-Path $second 'mql5-coding-windows.zip'))) 'reproducible ZIP'
Check ((Get-Mql5ReleaseHash ($archive+'.manifest.json')) -ceq (Get-Mql5ReleaseHash (Join-Path $second 'mql5-coding-windows.zip.manifest.json'))) 'reproducible sidecar'
Reject {& (Join-Path $repo 'scripts/Package-Skill.ps1') -SkillRoot $skill -OutputDirectory $first -SourceCommit $commit} 'existing package is preserved'
Reject {& (Join-Path $repo 'scripts/Package-Skill.ps1') -SkillRoot $skill -OutputDirectory (Join-Path $work 'bad-tag') -SourceCommit $commit -Tag 'v9.0.0'} 'mismatched tag rejected'
$fixtureHome=Join-Path $work 'legacy-home';$target=Join-Path $fixtureHome 'skills/mql5-coding'
[IO.Directory]::CreateDirectory((Join-Path $target 'custom')) | Out-Null
[IO.File]::WriteAllText((Join-Path $target 'SKILL.md'),'legacy instructions')
[IO.File]::WriteAllBytes((Join-Path $target 'custom/settings.bin'),[byte[]]@(0,1,2,255))
[IO.File]::WriteAllText((Join-Path $target 'custom/my settings (saved).txt'),'custom configuration')
$old=@(Get-Mql5ReleaseInventory $target)
Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
using Microsoft.Win32.SafeHandles;
public static class Mql5ReleaseFolderLock {
    [DllImport("kernel32.dll", CharSet=CharSet.Unicode, SetLastError=true)]
    public static extern SafeFileHandle CreateFile(string name, uint access, uint share, IntPtr security,
        uint creation, uint flags, IntPtr template);
    public static SafeFileHandle Pin(string path) {return CreateFile(path, 0x80000000, 3, IntPtr.Zero, 3, 0x02000000, IntPtr.Zero);}
}
'@
$rootPin=[Mql5ReleaseFolderLock]::Pin($target)
Check (-not $rootPin.IsInvalid) 'watcher-like root handle acquired without delete sharing'
Reject {[IO.Directory]::Move($target,$target+'-blocked')} 'watcher-pinned root cannot be renamed'
$argsForUpdate=Options $fixtureHome $archive $digest
$updated=RunUpdater $argsForUpdate
if ($updated.code) {throw $updated.error_text}
Check ($updated.data.action -ceq 'updated') 'legacy upgrade succeeds'
$backup=$updated.data.backup_id
$backupTree=Join-Path $fixtureHome ('tools/mql5-skill-updates/'+$backup+'/backup-tree')
Assert-Mql5ReleaseInventory $backupTree (($old | ConvertTo-Json -Depth 4 -Compress) | ConvertFrom-Json)
Check $true 'legacy custom files are backed up exactly'
Check (@(Get-Mql5ReleaseInventory $target).Count -eq 21) 'installed release is complete'
$again=RunUpdater $argsForUpdate
Check ($again.code -eq 0 -and $again.data.action -ceq 'already_current') 'identical update is idempotent'
[IO.File]::AppendAllText((Join-Path $target 'SKILL.md'),'changed')
$changed=@(Get-Mql5ReleaseInventory $target)
$invalid=RunUpdater $argsForUpdate
Check ($invalid.code -ne 0) 'changed same-version installation rejected'
Assert-Mql5ReleaseInventory $target (($changed | ConvertTo-Json -Depth 4 -Compress) | ConvertFrom-Json)
Check $true 'rejection preserves installed bytes'
$rollback=RunUpdater @('-Action','Rollback','-CodexDirectory',$fixtureHome,'-BackupId',$backup)
if ($rollback.code) {throw $rollback.error_text}
Check ($rollback.data.action -ceq 'rollback') 'rollback succeeds'
Assert-Mql5ReleaseInventory $target (($old | ConvertTo-Json -Depth 4 -Compress) | ConvertFrom-Json)
Check $true 'rollback restores every legacy file'
Assert-Mql5ReleaseInventory (Join-Path $fixtureHome ('tools/mql5-skill-updates/'+$rollback.data.backup_id+'/backup-tree')) (($changed | ConvertTo-Json -Depth 4 -Compress) | ConvertFrom-Json)
Check $true 'rollback preserves displaced installation'
[IO.File]::AppendAllText((Join-Path $backupTree 'SKILL.md'),'tampered')
$invalid=RunUpdater @('-Action','Rollback','-CodexDirectory',$fixtureHome,'-BackupId',$backup)
Check ($invalid.code -ne 0) 'changed rollback snapshot rejected'
Assert-Mql5ReleaseInventory $target (($old | ConvertTo-Json -Depth 4 -Compress) | ConvertFrom-Json)
Check $true 'failed rollback preserves current installation'
foreach ($case in @(
    @{name='traversal';entry='../escape.ps1';content='escape';add=$true},
    @{name='extra-code';entry='mql5-coding/execute.ps1';content='throw "must never run"';add=$true},
    @{name='duplicate';entry='mql5-coding/SKILL.md';content='duplicate';add=$true},
    @{name='case-alias';entry='mql5-coding/skill.md';content='alias';add=$true},
    @{name='modified-file';entry='mql5-coding/SKILL.md';content='modified';add=$false}
)) {
    $bad=ChangeZip $case.name $case.entry $case.content -Add:$case.add
    $invalid=RunUpdater (Options $fixtureHome $bad (Get-Mql5ReleaseHash $bad))
    Check ($invalid.code -ne 0) ($case.name+' rejected')
    Assert-Mql5ReleaseInventory $target (($old | ConvertTo-Json -Depth 4 -Compress) | ConvertFrom-Json)
}
Check (-not (Test-Path -LiteralPath (Join-Path $work 'escape.ps1'))) 'traversal never extracted'
$zip=[IO.Compression.ZipFile]::OpenRead($archive)
try {$reader=New-Object IO.StreamReader($zip.GetEntry('release-manifest.json').Open());try {$manifestText=$reader.ReadToEnd()} finally {$reader.Dispose()}} finally {$zip.Dispose()}
foreach ($case in @(
    @{name='wrong-commit';text=$manifestText.Replace($commit,('b'*40))},
    @{name='wrong-version';text=$manifestText.Replace('"version":"'+$version+'"','"version":"9.0.0"')},
    @{name='unknown-field';text=$manifestText.Replace('"schema_version":1','"schema_version":1,"execute":true')},
    @{name='duplicate-key';text=$manifestText.Replace('"schema_version":1','"schema_version":1,"schema_version":1')},
    @{name='escaped-key';text=$manifestText.Replace('"schema_version":1','"schema_version":1,"\u0073chema_version":1')},
    @{name='wrong-hash';text=$manifestText.Replace('"sha256":"','"sha256":"0')}
)) {
    $bad=ChangeZip $case.name 'release-manifest.json' $case.text
    $invalid=RunUpdater (Options $fixtureHome $bad (Get-Mql5ReleaseHash $bad))
    Check ($invalid.code -ne 0) ($case.name+' rejected')
}
$invalid=RunUpdater (Options $fixtureHome $archive ('0'*64));Check ($invalid.code -ne 0) 'wrong trusted archive hash rejected'
$invalid=RunUpdater @('-Action','Update','-Version',$version,'-CodexDirectory',$fixtureHome,'-ArchivePath',$archive)
Check ($invalid.code -ne 0) 'offline update requires both trust values'
$invalid=RunUpdater @('-Action','Rollback','-CodexDirectory',$fixtureHome,'-BackupId','../escape')
Check ($invalid.code -ne 0) 'backup path traversal rejected'
$lock=[IO.File]::Open((Join-Path $fixtureHome 'tools/mql5-skill-updates/.lock'),[IO.FileMode]::Open,[IO.FileAccess]::ReadWrite,[IO.FileShare]::None)
try {$invalid=RunUpdater $argsForUpdate;Check ($invalid.code -ne 0) 'concurrent update excluded'} finally {$lock.Dispose()}
# Simulate process interruption before and after the first directory rename.
foreach ($afterMove in @($false,$true)) {
    $id=[guid]::NewGuid().ToString('N');$txn=Join-Path $fixtureHome ('tools/mql5-skill-updates/'+$id)
    [IO.Directory]::CreateDirectory($txn) | Out-Null
    Write-Mql5ReleaseJson (Join-Path $txn 'backup.json') @{schema_version=1;backup_id=$id;target=$target;had_installation=$true;files=@($old)}
    Write-Mql5ReleaseJson (Join-Path $txn 'pending.json') @{action='update';target=$target}
    if ($afterMove) {
        Copy-Mql5ReleaseSnapshot $target (Join-Path $txn 'backup-tree') $old
        $empty=Join-Path $txn 'empty';[IO.Directory]::CreateDirectory($empty) | Out-Null
        Set-Mql5ReleaseContents $target $empty (Join-Path $txn 'displaced-tree') @()
    }
    $invalid=RunUpdater $argsForUpdate;Check ($invalid.code -ne 0) 'pending transaction blocks update'
    $recovered=RunUpdater @('-Action','Rollback','-CodexDirectory',$fixtureHome,'-BackupId',$id)
    if ($recovered.code) {throw $recovered.error_text}
    Check $true ('interrupted transaction recovered afterMove='+$afterMove)
    Assert-Mql5ReleaseInventory $target (($old | ConvertTo-Json -Depth 4 -Compress) | ConvertFrom-Json)
    Check $true 'interruption recovery restores original bytes'
}
$child=Join-Path $target 'zz-lock';[IO.Directory]::CreateDirectory($child) | Out-Null
foreach ($phase in @('partial-old','partial-new')) {
    $id=[guid]::NewGuid().ToString('N');$txn=Join-Path $fixtureHome ('tools/mql5-skill-updates/'+$id)
    [IO.Directory]::CreateDirectory($txn) | Out-Null
    Copy-Mql5ReleaseSnapshot $target (Join-Path $txn 'backup-tree') $old
    Write-Mql5ReleaseJson (Join-Path $txn 'backup.json') @{schema_version=1;backup_id=$id;target=$target;had_installation=$true;files=@($old)}
    Write-Mql5ReleaseJson (Join-Path $txn 'pending.json') @{action='update';target=$target}
    if ($phase -eq 'partial-old') {[IO.File]::Move((Join-Path $target 'SKILL.md'),(Join-Path $txn 'old-skill.md'))}
    else {
        $empty=Join-Path $txn 'empty';[IO.Directory]::CreateDirectory($empty) | Out-Null
        Set-Mql5ReleaseContents $target $empty (Join-Path $txn 'displaced-tree') @()
        Copy-Item -LiteralPath (Join-Path $skill 'version.json') -Destination (Join-Path $target 'version.json')
    }
    $recoveryId=$id
    if ($phase -eq 'partial-new') {
        $nestedId=[guid]::NewGuid().ToString('N');$nested=Join-Path $fixtureHome ('tools/mql5-skill-updates/'+$nestedId)
        [IO.Directory]::CreateDirectory($nested) | Out-Null
        $partial=@(Get-Mql5ReleaseInventory $target)
        Copy-Mql5ReleaseSnapshot $target (Join-Path $nested 'backup-tree') $partial
        Write-Mql5ReleaseJson (Join-Path $nested 'backup.json') @{schema_version=1;backup_id=$nestedId;target=$target;had_installation=$true;files=@($partial)}
        Write-Mql5ReleaseJson (Join-Path $nested 'pending.json') @{action='rollback';target=$target;restore_backup_id=$id}
        $recoveryId=$nestedId
    }
    $recovered=RunUpdater @('-Action','Rollback','-CodexDirectory',$fixtureHome,'-BackupId',$recoveryId)
    if ($recovered.code) {throw $recovered.error_text}
    if ($phase -eq 'partial-new') {Check (-not (Test-Path -LiteralPath (Join-Path $nested 'pending.json'))) 'interrupted rollback follows its original snapshot and resolves the nested intent'}
    Check $true ($phase+' interruption recovered under root watcher')
    Assert-Mql5ReleaseInventory $target (($old | ConvertTo-Json -Depth 4 -Compress) | ConvertFrom-Json)
    Check $true 'partial publication recovery restores original bytes'
}
$childPin=[Mql5ReleaseFolderLock]::Pin($child)
try {
    $invalid=RunUpdater $argsForUpdate
    Check ($invalid.code -ne 0) 'locked child causes a caught publication failure'
    Assert-Mql5ReleaseInventory $target (($old | ConvertTo-Json -Depth 4 -Compress) | ConvertFrom-Json)
    Check $true 'partly displaced children are automatically restored on failure'
} finally {$childPin.Dispose();[IO.Directory]::Delete($child,$false)}
$rootPin.Dispose()
$freshHome=Join-Path $work 'fresh-home'
$fresh=RunUpdater (Options $freshHome $archive $digest)
if ($fresh.code) {throw $fresh.error_text}
Check (-not $fresh.data.had_previous_installation) 'fresh install has explicit empty backup'
$freshTarget=Join-Path $freshHome 'skills/mql5-coding';$freshFiles=@(Get-Mql5ReleaseInventory $freshTarget)
$freshPin=[Mql5ReleaseFolderLock]::Pin($freshTarget)
try {
    $blocked=RunUpdater @('-Action','Rollback','-CodexDirectory',$freshHome,'-BackupId',$fresh.data.backup_id)
    Check ($blocked.code -ne 0) 'fresh uninstall with a pinned root fails safely'
    Assert-Mql5ReleaseInventory $freshTarget (($freshFiles | ConvertTo-Json -Depth 4 -Compress) | ConvertFrom-Json)
    Check $true 'failed fresh uninstall restores the entire current installation'
} finally {$freshPin.Dispose()}
$uninstall=RunUpdater @('-Action','Rollback','-CodexDirectory',$freshHome,'-BackupId',$fresh.data.backup_id)
if ($uninstall.code) {throw $uninstall.error_text}
Check (-not (Test-Path -LiteralPath (Join-Path $freshHome 'skills/mql5-coding'))) 'fresh install rollback restores absence'
$base=RunUpdater (Options $freshHome $archive $digest)
if ($base.code) {throw $base.error_text}
$nextSkill=Join-Path $work 'next-skill';Copy-Item -LiteralPath $skill -Destination $nextSkill -Recurse
[IO.File]::WriteAllText((Join-Path $nextSkill 'version.json'),'{"schema_version":1,"version":"1.1.0"}')
[IO.File]::WriteAllText((Join-Path $nextSkill 'references/new-reference.md'),'A future release can add a verified resource.')
& (Join-Path $repo 'scripts/Package-Skill.ps1') -SkillRoot $nextSkill -OutputDirectory (Join-Path $work 'next-package') -SourceCommit $commit -Tag 'v1.1.0' | Out-Null
$nextArchive=Join-Path $work 'next-package/mql5-coding-windows.zip'
$upgrade=RunUpdater @('-Action','Update','-Version','1.1.0','-CodexDirectory',$freshHome,'-ArchivePath',$nextArchive,'-ExpectedArchiveSha256',(Get-Mql5ReleaseHash $nextArchive),'-ExpectedSourceCommit',$commit)
if ($upgrade.code) {throw $upgrade.error_text}
Check ($upgrade.data.action -ceq 'updated' -and (Test-Path -LiteralPath (Join-Path $freshHome 'skills/mql5-coding/references/new-reference.md'))) 'versioned upgrade accepts verified additional resources'
$invalid=RunUpdater (Options $freshHome $archive $digest)
Check ($invalid.code -ne 0) 'update cannot silently downgrade'
$back=RunUpdater @('-Action','Rollback','-CodexDirectory',$freshHome,'-BackupId',$upgrade.data.backup_id)
if ($back.code) {throw $back.error_text}
Check ((Read-Mql5ReleaseJson (Join-Path $freshHome 'skills/mql5-coding/version.json')).version -ceq $version) 'versioned rollback restores prior release'
$junction=Join-Path $work 'aliased-home'
New-Item -ItemType Junction -Path $junction -Target $freshHome | Out-Null
$invalid=RunUpdater (Options $junction $archive $digest)
Check ($invalid.code -ne 0) 'junction installation path rejected'
# Unit-test authenticated metadata policy independently of the real download exercised at release time.
$script:fakeRelease=[pscustomobject]@{tag_name=('v'+$version);draft=$false;prerelease=$false;html_url='https://github.com/shamwi2846/MQL5-Coding-Skill/releases';assets=@([pscustomobject]@{name='mql5-coding-windows.zip';state='uploaded';digest=('sha256:'+$digest);size=1000})}
function Invoke-Mql5ReleaseGh([string[]]$Arguments) {
    if ($Arguments[1] -like '*/commits/*') {return [pscustomobject]@{sha=$commit}}
    return $script:fakeRelease
}
Check ((Get-Mql5SkillGitHubRelease $version).sha256 -ceq $digest) 'authenticated asset digest is the trust input'
$script:fakeRelease.draft=$true;Reject {Get-Mql5SkillGitHubRelease $version} 'draft release rejected';$script:fakeRelease.draft=$false
$script:fakeRelease.prerelease=$true;Reject {Get-Mql5SkillGitHubRelease $version} 'prerelease rejected';$script:fakeRelease.prerelease=$false
$script:fakeRelease.assets[0].digest=$null;Reject {Get-Mql5SkillGitHubRelease $version} 'missing GitHub asset digest rejected'
Reject {Get-Mql5SkillGitHubRelease '../v1.0.0'} 'invalid remote version rejected before gh'
$record=[ordered]@{status='passed';shell=$PSVersionTable.PSVersion.ToString();checks=$script:checks;fixture=$work;real_github_download=$false;real_mt5_started=$false}
Write-Mql5ReleaseJson (Join-Path $work 'result.json') $record
$record | ConvertTo-Json
