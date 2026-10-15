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
$bufferText='{"schema_version":1,"value":42,"label":"'+[char]0xe9+'"}'
$bufferBytes=(New-Object Text.UTF8Encoding($false,$true)).GetBytes($bufferText)
$unavailablePath=Join-Path $work 'buffer-only.json'
$buffered=Read-Mql5ReleaseJson -Path $unavailablePath -Bytes $bufferBytes
Check ($buffered.value -eq 42 -and $buffered.label -ceq ([char]0xe9).ToString()) 'Buffered JSON preserves independently specified values without rereading a path'
$bomBytes=[byte[]]([Text.Encoding]::UTF8.GetPreamble()+$bufferBytes)
Check ((Read-Mql5ReleaseJson -Path $unavailablePath -Bytes $bomBytes).label -ceq ([char]0xe9).ToString()) 'Buffered UTF-8 BOM JSON remains supported'
$unicodeBytes=[byte[]]([Text.Encoding]::Unicode.GetPreamble()+[Text.Encoding]::Unicode.GetBytes($bufferText))
Check ((Read-Mql5ReleaseJson -Path $unavailablePath -Bytes $unicodeBytes).label -ceq ([char]0xe9).ToString()) 'Buffered JSON retains existing UTF-16 BOM decoding'
Reject {Read-Mql5ReleaseJson -Path $unavailablePath -Bytes ([Text.Encoding]::UTF8.GetBytes('[{"value":42}]'))} 'Buffered JSON rejects array roots'
Reject {Read-Mql5ReleaseJson -Path $unavailablePath -Bytes ([Text.Encoding]::UTF8.GetBytes('{"key":1,"\u006bey":2}'))} 'Buffered JSON rejects escaped duplicate keys'
Reject {Read-Mql5ReleaseJson -Path $unavailablePath -Bytes ([byte[]]@(123,34,107,34,58,34,255,34,125))} 'Buffered JSON rejects malformed UTF-8'
Reject {Read-Mql5ReleaseJson -Path $unavailablePath -Bytes (New-Object byte[] 1048577)} 'Buffered JSON enforces the existing metadata byte limit'
Reject {Read-Mql5ReleaseJson -Path $unavailablePath -Bytes ([byte[]]@())} 'Buffered JSON rejects an explicitly empty document'
# The shared reader must reject malformed Unicode before a selected path or
# retained message can be replaced by ConvertFrom-Json. All other JSON is valid.
$unicodeCodecs=@(
    (New-Object Text.UTF8Encoding($false,$true)),
    (New-Object Text.UTF8Encoding($true,$true)),
    (New-Object Text.UnicodeEncoding($false,$true,$true))
)
$malformedText=@(
    '{"label":"\ud800"}', '{"label":"\udfff"}',
    '{"label":"\udfff\ud800"}', '{"label":"\ud800A"}',
    '{"label":"\ud800\u0061"}', '{"label":"\ud800\ud800"}',
    '{"label":"\ud800\\udfff"}', '{"\ud800":1}',
    '{"nested":{"items":["\udfff"]}}'
)
$validText=@(
    @{json='\ud83d\ude00';expected=[char]::ConvertFromUtf32(0x1f600)},
    @{json='\uDbFF\uDfFF';expected=[char]::ConvertFromUtf32(0x10ffff)},
    @{json='\\ud800';expected='\ud800'},
    @{json='\\\ud83d\ude00';expected=('\'+[char]::ConvertFromUtf32(0x1f600))},
    @{json='\u00e9';expected=([char]0xe9).ToString()},
    @{json=[char]::ConvertFromUtf32(0x1f600);expected=[char]::ConvertFromUtf32(0x1f600)},
    @{json=([char]0xfffd).ToString();expected=([char]0xfffd).ToString()}
)
$unicodeJsonPath=Join-Path $work 'unicode-metadata.json'
foreach ($codec in $unicodeCodecs) {
    foreach ($text in $malformedText) {
        $raw=[byte[]]($codec.GetPreamble()+$codec.GetBytes($text))
        [IO.File]::WriteAllBytes($unicodeJsonPath,$raw)
        Reject {Read-Mql5ReleaseJson -Path $unicodeJsonPath -Bytes $raw} 'Buffered JSON rejects unpaired Unicode escapes'
        Reject {Read-Mql5ReleaseJson -Path $unicodeJsonPath} 'File JSON rejects unpaired Unicode escapes'
    }
    foreach ($case in $validText) {
        $text='{"label":"'+$case.json+'"}'
        $raw=[byte[]]($codec.GetPreamble()+$codec.GetBytes($text))
        [IO.File]::WriteAllBytes($unicodeJsonPath,$raw)
        Check ((Read-Mql5ReleaseJson -Path $unicodeJsonPath -Bytes $raw).label -ceq $case.expected) 'Buffered JSON preserves valid Unicode and literal backslash text'
        Check ((Read-Mql5ReleaseJson -Path $unicodeJsonPath).label -ceq $case.expected) 'File JSON preserves valid Unicode and literal backslash text'
    }
}
# A BOM must not change the strict decoding policy. Inject isolated UTF-16
# units as actual bytes; do not pass them through a forgiving text encoder.
foreach ($bigEndian in @($false,$true)) {
    $codec=New-Object Text.UnicodeEncoding($bigEndian,$true,$true)
    foreach ($unit in @(0xd800,0xdfff)) {
        $unitBytes=if ($bigEndian) {[byte[]]@(($unit -shr 8),($unit -band 255))} else {[byte[]]@(($unit -band 255),($unit -shr 8))}
        $raw=[byte[]]($codec.GetPreamble()+$codec.GetBytes('{"label":"')+$unitBytes+$codec.GetBytes('"}'))
        [IO.File]::WriteAllBytes($unicodeJsonPath,$raw)
        Reject {Read-Mql5ReleaseJson -Path $unicodeJsonPath -Bytes $raw} 'Buffered BOM JSON rejects malformed UTF-16 bytes'
        Reject {Read-Mql5ReleaseJson -Path $unicodeJsonPath} 'File BOM JSON rejects malformed UTF-16 bytes'
    }
    $text='{"label":"'+[char]::ConvertFromUtf32(0x1f600)+([char]0xfffd)+'"}'
    $raw=[byte[]]($codec.GetPreamble()+$codec.GetBytes($text))
    [IO.File]::WriteAllBytes($unicodeJsonPath,$raw)
    Check ((Read-Mql5ReleaseJson -Path $unicodeJsonPath -Bytes $raw).label -ceq ([char]::ConvertFromUtf32(0x1f600)+[char]0xfffd)) 'Buffered UTF-16 BOM retains valid pairs and literal replacement text'
    Check ((Read-Mql5ReleaseJson -Path $unicodeJsonPath).label -ceq ([char]::ConvertFromUtf32(0x1f600)+[char]0xfffd)) 'File UTF-16 BOM retains valid pairs and literal replacement text'
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
function ChangeVerifiedVersion([string]$Name,[string]$Content) {
    $path=ChangeZip $Name 'mql5-coding/version.json' $Content
    # Rehash the changed version file and the ZIP. Rejection must be caused by
    # its metadata contract, not an unrelated file or archive hash mismatch.
    $zip=[IO.Compression.ZipFile]::Open($path,[IO.Compression.ZipArchiveMode]::Update)
    try {
        $reader=New-Object IO.StreamReader($zip.GetEntry('release-manifest.json').Open())
        try {$manifest=$reader.ReadToEnd() | ConvertFrom-Json} finally {$reader.Dispose()}
        $bytes=(New-Object Text.UTF8Encoding($false)).GetBytes($Content)
        $sha=[Security.Cryptography.SHA256]::Create()
        try {$hash=([BitConverter]::ToString($sha.ComputeHash($bytes))).Replace('-','').ToLowerInvariant()} finally {$sha.Dispose()}
        $record=@($manifest.files | Where-Object {$_.path -ceq 'version.json'})[0]
        $record.bytes=$bytes.Length;$record.sha256=$hash
        $zip.GetEntry('release-manifest.json').Delete()
        $stream=$zip.CreateEntry('release-manifest.json').Open()
        try {$text=(New-Object Text.UTF8Encoding($false)).GetBytes(($manifest | ConvertTo-Json -Depth 12 -Compress));$stream.Write($text,0,$text.Length)} finally {$stream.Dispose()}
    } finally {$zip.Dispose()}
    return $path
}
foreach ($file in @((Join-Path $repo 'scripts/Package-Skill.ps1'))+@(Get-ChildItem -LiteralPath (Join-Path $skill 'scripts') -Filter '*.ps1' | ForEach-Object {$_.FullName})) {
    $tokens=$null;$parseErrors=$null
    [void][Management.Automation.Language.Parser]::ParseFile($file,[ref]$tokens,[ref]$parseErrors)
    Check ($parseErrors.Count -eq 0) ('syntax '+[IO.Path]::GetFileName($file))
}
# Exercise a real, disposable drive root while the ambient directory is nested.
# No files on an existing drive root are inventoried or changed.
$rootFixture=Join-Path $work 'drive-root'
Copy-Item -LiteralPath $skill -Destination $rootFixture -Recurse
[void][IO.Directory]::CreateDirectory((Join-Path $rootFixture 'scripts/ambient'))
[IO.File]::WriteAllText((Join-Path $rootFixture 'scripts/ambient/marker.txt'),'nested fixture')
$expectedRootFiles=@(Get-Mql5ReleaseInventory $rootFixture)
$usedLetters=@([Environment]::GetLogicalDrives() | ForEach-Object {$_.Substring(0,1)})+@(Get-PSDrive -PSProvider FileSystem | Select-Object -ExpandProperty Name)
$availableLetters=@('Z','Y','X','W','V','U','T','S','R' | Where-Object {$_ -notin $usedLetters})
if ($availableLetters.Count -eq 0) {throw 'No free drive letter for the root-path regression.'}
$rootLetter=$availableLetters[0];$rootDrive=$rootLetter+':'
$absoluteRoot=$rootDrive+'\';$subst=Join-Path $env:SystemRoot 'System32/subst.exe'
$previousLocation=(Get-Location).Path;$previousDirectory=[Environment]::CurrentDirectory
$rootMapped=$false;$rootProvider=$false
try {
    & $subst $rootDrive $rootFixture
    if ($LASTEXITCODE -ne 0) {throw 'Could not map the disposable root-path fixture.'};$rootMapped=$true
    if (-not (Get-PSDrive -Name $rootLetter -ErrorAction SilentlyContinue)) {[void](New-PSDrive -Name $rootLetter -PSProvider FileSystem -Root $absoluteRoot);$rootProvider=$true}
    Set-Location -LiteralPath ($absoluteRoot+'scripts/ambient')
    [Environment]::CurrentDirectory=$absoluteRoot+'scripts/ambient'
    $resolvedRoot=Assert-Mql5ReleasePath $absoluteRoot
    Check ($resolvedRoot -ceq $absoluteRoot) 'release drive roots remain fully qualified'
    Check ([IO.Path]::GetFullPath($resolvedRoot) -ceq $absoluteRoot) 'root normalization is independent of ambient directory'
    $actualRootFiles=@(Get-Mql5ReleaseInventory $absoluteRoot)
    Check (($actualRootFiles | ConvertTo-Json -Depth 4 -Compress) -ceq ($expectedRootFiles | ConvertTo-Json -Depth 4 -Compress)) 'drive-root inventory includes all files with correct relative paths'
    $insideOutput=$absoluteRoot+'package-output'
    Reject {& (Join-Path $repo 'scripts/Package-Skill.ps1') -SkillRoot $absoluteRoot -OutputDirectory $insideOutput -SourceCommit $commit} 'packaging output inside a drive-root skill is rejected'
    Check (-not (Test-Path -LiteralPath $insideOutput)) 'inside-root packaging refusal creates no output'
    $rootOutput=Join-Path $work 'drive-root-package'
    & (Join-Path $repo 'scripts/Package-Skill.ps1') -SkillRoot $absoluteRoot -OutputDirectory $rootOutput -SourceCommit $commit -Tag ('v'+$version) | Out-Null
    Check (Test-Path -LiteralPath (Join-Path $rootOutput 'mql5-coding-windows.zip')) 'valid drive-root skill packages successfully to an outside destination'
} finally {
    [Environment]::CurrentDirectory=$previousDirectory
    Set-Location -LiteralPath $previousLocation
    if ($rootProvider) {Remove-PSDrive -Name $rootLetter -Force}
    if ($rootMapped) {& $subst $rootDrive /D;if ($LASTEXITCODE -ne 0) {throw 'Could not remove the owned root-path fixture drive.'}}
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
Check (@(Get-Mql5ReleaseInventory $target).Count -eq @(Get-Mql5SkillReleaseFiles $version).Count) 'installed release is complete'
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
$validManifest=$manifestText | ConvertFrom-Json
Assert-Mql5SkillManifest $validManifest $version $commit
Check $true 'valid release identity accepted before testing malformed field types'
foreach ($field in @('repository','tag','version','source_commit')) {
    $arrayIdentity=$manifestText | ConvertFrom-Json
    $arrayIdentity.$field=@($arrayIdentity.$field)
    Reject {Assert-Mql5SkillManifest $arrayIdentity $version $commit} ('array-valued release identity rejected: '+$field)
}
$validVersion='{"schema_version":1,"version":"'+$version+'"}'
$versionControl=ChangeVerifiedVersion 'version-control' $validVersion
$null=Expand-Mql5SkillRelease $versionControl (Get-Mql5ReleaseHash $versionControl) $version $commit (Join-Path $work 'verified-version-control')
Check $true 'rehashed version control archive passes before malformed metadata tests'
$versionCases=@(
    @{name='array-version';text=('{"schema_version":1,"version":["'+$version+'"]}')},
    @{name='array-schema';text=('{"schema_version":[1],"version":"'+$version+'"}')},
    @{name='boolean-schema';text=('{"schema_version":true,"version":"'+$version+'"}')},
    @{name='string-schema';text=('{"schema_version":"1","version":"'+$version+'"}')},
    @{name='decimal-schema';text=('{"schema_version":1.0,"version":"'+$version+'"}')},
    @{name='extra-version-field';text=('{"schema_version":1,"version":"'+$version+'","extra":true}')}
)
foreach ($case in $versionCases) {
    $bad=ChangeVerifiedVersion $case.name $case.text
    Reject {Expand-Mql5SkillRelease $bad (Get-Mql5ReleaseHash $bad) $version $commit (Join-Path $work ('verified-'+$case.name))} ($case.name+' version record rejected with matching file hashes')
}
$invalidSkill=Join-Path $work 'invalid-version-skill';Copy-Item -LiteralPath $skill -Destination $invalidSkill -Recurse
foreach ($case in $versionCases) {
    [IO.File]::WriteAllText((Join-Path $invalidSkill 'version.json'),$case.text)
    $output=Join-Path $work ('package-'+$case.name)
    Reject {& (Join-Path $repo 'scripts/Package-Skill.ps1') -SkillRoot $invalidSkill -OutputDirectory $output -SourceCommit $commit} ('packager rejects '+$case.name+' before coercing version fields')
    Check (-not (Test-Path -LiteralPath $output)) 'invalid version does not publish package output'
}
foreach ($case in @(
    @{name='wrong-commit';text=$manifestText.Replace($commit,('b'*40))},
    @{name='wrong-version';text=$manifestText.Replace('"version":"'+$version+'"','"version":"9.0.0"')},
    @{name='unknown-field';text=$manifestText.Replace('"schema_version":1','"schema_version":1,"execute":true')},
    @{name='duplicate-key';text=$manifestText.Replace('"schema_version":1','"schema_version":1,"schema_version":1')},
    @{name='escaped-key';text=$manifestText.Replace('"schema_version":1','"schema_version":1,"\u0073chema_version":1')},
    @{name='wrong-hash';text=$manifestText.Replace('"sha256":"','"sha256":"0')},
    @{name='array-manifest';text=('['+$manifestText+']')}
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
# Invalid recovery metadata must leave both the installation and retained
# evidence unchanged. Each fixture can restore different bytes if accepted.
foreach ($case in @('backup-array-schema','backup-string-schema','backup-boolean-schema','backup-array-id','backup-array-target',
    'intent-wrong-action','intent-wrong-target','intent-array-action','intent-array-target','intent-extra-field','intent-array-parent','intent-missing-parent','malformed-sibling')) {
    $recoveryHome=Join-Path $work $case;$destination=Join-Path $recoveryHome 'skills/mql5-coding'
    [void][IO.Directory]::CreateDirectory($destination);[IO.File]::WriteAllText((Join-Path $destination 'SKILL.md'),'current installation')
    $current=@(Get-Mql5ReleaseInventory $destination)
    $id=[guid]::NewGuid().ToString('N');$txn=Join-Path $recoveryHome ('tools/mql5-skill-updates/'+$id)
    $tree=Join-Path $txn 'backup-tree';[void][IO.Directory]::CreateDirectory($tree)
    [IO.File]::WriteAllText((Join-Path $tree 'SKILL.md'),'original installation')
    $record=[pscustomobject]@{schema_version=1;backup_id=$id;target=$destination;had_installation=$true;files=@(Get-Mql5ReleaseInventory $tree)}
    switch ($case) {
        'backup-array-schema' {$record.schema_version=@(1)}
        'backup-string-schema' {$record.schema_version='1'}
        'backup-boolean-schema' {$record.schema_version=$true}
        'backup-array-id' {$record.backup_id=@($id)}
        'backup-array-target' {$record.target=@($destination)}
    }
    Write-Mql5ReleaseJson (Join-Path $txn 'backup.json') $record
    if ($case -like 'intent-*' -or $case -eq 'malformed-sibling') {
        $intent=[pscustomobject]@{action='update';target=$destination}
        switch ($case) {
            'intent-wrong-action' {$intent.action='unexpected'}
            'intent-wrong-target' {$intent.target=$destination+'-other'}
            'intent-array-action' {$intent.action=@('update')}
            'intent-array-target' {$intent.target=@($destination)}
            'intent-extra-field' {$intent | Add-Member -NotePropertyName extra -NotePropertyValue $true}
            'intent-array-parent' {$intent.action='rollback';$intent | Add-Member -NotePropertyName restore_backup_id -NotePropertyValue @($id)}
            'intent-missing-parent' {$intent.action='rollback'}
        }
        Write-Mql5ReleaseJson (Join-Path $txn 'pending.json') $intent
        if ($case -eq 'malformed-sibling') {
            $sibling=Join-Path $recoveryHome ('tools/mql5-skill-updates/'+[guid]::NewGuid().ToString('N'))
            [void][IO.Directory]::CreateDirectory($sibling);[IO.File]::WriteAllText((Join-Path $sibling 'pending.json'),'{malformed')
        }
    }
    $retained=@(Get-Mql5ReleaseInventory (Join-Path $recoveryHome 'tools/mql5-skill-updates'))
    $invalid=RunUpdater @('-Action','Rollback','-CodexDirectory',$recoveryHome,'-BackupId',$id)
    Check ($invalid.code -ne 0) ($case+' rejected before restoration')
    Assert-Mql5ReleaseInventory $destination $current
    $after=@(Get-Mql5ReleaseInventory (Join-Path $recoveryHome 'tools/mql5-skill-updates') | Where-Object {$_.path -cne '.lock'})
    Check (($after | ConvertTo-Json -Compress -Depth 6) -ceq ($retained | ConvertTo-Json -Compress -Depth 6)) 'invalid recovery metadata preserves the installation and all retained evidence'
}
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
    $nestedIntents=@()
    if ($phase -eq 'partial-new') {
        # Repeated interruptions produce a chain of rollback intents. Recovering
        # its latest member must resolve every intent after restoring the original.
        for ($interruption=0;$interruption -lt 2;$interruption++) {
            $nestedId=[guid]::NewGuid().ToString('N');$nested=Join-Path $fixtureHome ('tools/mql5-skill-updates/'+$nestedId)
            [IO.Directory]::CreateDirectory($nested) | Out-Null
            $partial=@(Get-Mql5ReleaseInventory $target)
            Copy-Mql5ReleaseSnapshot $target (Join-Path $nested 'backup-tree') $partial
            Write-Mql5ReleaseJson (Join-Path $nested 'backup.json') @{schema_version=1;backup_id=$nestedId;target=$target;had_installation=$true;files=@($partial)}
            $intentPath=Join-Path $nested 'pending.json'
            Write-Mql5ReleaseJson $intentPath @{action='rollback';target=$target;restore_backup_id=$recoveryId}
            $nestedIntents+=@($intentPath);$recoveryId=$nestedId
        }
    }
    $recovered=RunUpdater @('-Action','Rollback','-CodexDirectory',$fixtureHome,'-BackupId',$recoveryId)
    if ($recovered.code) {throw $recovered.error_text}
    foreach ($intentPath in $nestedIntents) {Check (-not (Test-Path -LiteralPath $intentPath)) 'repeatedly interrupted rollback resolves every nested intent'}
    Check $true ($phase+' interruption recovered under root watcher')
    Assert-Mql5ReleaseInventory $target (($old | ConvertTo-Json -Depth 4 -Compress) | ConvertFrom-Json)
    Check $true 'partial publication recovery restores original bytes'
}
# A cleanup failure must retain all ancestors of an unresolved rollback intent.
# Otherwise resuming that intent could select a partial snapshot as the original.
$cleanupIds=@(('0'*31+'1'),('0'*31+'2'),('0'*31+'3'))
$cleanupIntents=@()
for ($level=0;$level -lt $cleanupIds.Count;$level++) {
    $cleanupTxn=Join-Path $fixtureHome ('tools/mql5-skill-updates/'+$cleanupIds[$level])
    [IO.Directory]::CreateDirectory($cleanupTxn) | Out-Null
    $savedFiles=@(Get-Mql5ReleaseInventory $target)
    Copy-Mql5ReleaseSnapshot $target (Join-Path $cleanupTxn 'backup-tree') $savedFiles
    Write-Mql5ReleaseJson (Join-Path $cleanupTxn 'backup.json') @{schema_version=1;backup_id=$cleanupIds[$level];target=$target;had_installation=$true;files=@($savedFiles)}
    $cleanupIntent=Join-Path $cleanupTxn 'pending.json';$cleanupIntents+=@($cleanupIntent)
    if ($level -eq 0) {
        Write-Mql5ReleaseJson $cleanupIntent @{action='update';target=$target}
        $empty=Join-Path $cleanupTxn 'empty';[IO.Directory]::CreateDirectory($empty) | Out-Null
        Set-Mql5ReleaseContents $target $empty (Join-Path $cleanupTxn 'displaced-tree') @()
        Copy-Item -LiteralPath (Join-Path $skill 'version.json') -Destination (Join-Path $target 'version.json')
    } else {Write-Mql5ReleaseJson $cleanupIntent @{action='rollback';target=$target;restore_backup_id=$cleanupIds[$level-1]}}
}
$intentPin=[IO.File]::Open($cleanupIntents[-1],[IO.FileMode]::Open,[IO.FileAccess]::Read,[IO.FileShare]::Read)
try {
    $blocked=RunUpdater @('-Action','Rollback','-CodexDirectory',$fixtureHome,'-BackupId',$cleanupIds[-1])
    Check ($blocked.code -ne 0) 'locked pending marker causes a reported cleanup failure'
    foreach ($intentPath in $cleanupIntents) {Check (Test-Path -LiteralPath $intentPath) 'failed cleanup retains the unresolved intent and every recovery ancestor'}
    Assert-Mql5ReleaseInventory $target (($old | ConvertTo-Json -Depth 4 -Compress) | ConvertFrom-Json)
    Check $true 'cleanup failure retains the verified original files'
} finally {$intentPin.Dispose()}
$recovered=RunUpdater @('-Action','Rollback','-CodexDirectory',$fixtureHome,'-BackupId',$cleanupIds[-1])
if ($recovered.code) {throw $recovered.error_text}
Assert-Mql5ReleaseInventory $target (($old | ConvertTo-Json -Depth 4 -Compress) | ConvertFrom-Json)
Check $true 'cleanup retry restores the original snapshot rather than an intermediate snapshot'
foreach ($intentPath in $cleanupIntents) {Check (-not (Test-Path -LiteralPath $intentPath)) 'cleanup retry resolves the entire recovery family'}
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
$claudeHome=Join-Path $work 'claude-home'
$claude=RunUpdater @('-ClientHost','Claude','-Action','Update','-Version',$version,'-ClaudeDirectory',$claudeHome,'-ArchivePath',$archive,'-ExpectedArchiveSha256',$digest,'-ExpectedSourceCommit',$commit)
if ($claude.code) {throw $claude.error_text}
Check ($claude.data.client_host -ceq 'Claude' -and -not $claude.data.restart_codex -and $claude.data.restart_client -and (Test-Path -LiteralPath (Join-Path $claudeHome 'skills/mql5-coding/SKILL.md')) -and (Test-Path -LiteralPath (Join-Path $claudeHome ('mql5-skill-updates/'+$claude.data.backup_id+'/backup.json')))) 'Claude Code install uses the Claude skill and state directories'
Check (-not (Test-Path -LiteralPath (Join-Path $claudeHome 'tools'))) 'Claude Code install leaves Codex state untouched'
$mixed=RunUpdater @('-ClientHost','Claude','-Action','Update','-Version',$version,'-CodexDirectory',$claudeHome,'-ArchivePath',$archive,'-ExpectedArchiveSha256',$digest,'-ExpectedSourceCommit',$commit)
Check ($mixed.code -ne 0) 'Claude Code selection rejects a Codex directory'
$claudeBack=RunUpdater @('-ClientHost','Claude','-Action','Rollback','-ClaudeDirectory',$claudeHome,'-BackupId',$claude.data.backup_id)
if ($claudeBack.code) {throw $claudeBack.error_text}
Check (-not (Test-Path -LiteralPath (Join-Path $claudeHome 'skills/mql5-coding'))) 'Claude Code fresh install rollback restores absence'
# Files introduced in 1.2.4 are required only from that version: a complete
# older package without them still installs, and a newer one without them fails.
$olderSkill=Join-Path $work 'older-skill';Copy-Item -LiteralPath $skill -Destination $olderSkill -Recurse
[IO.File]::Delete((Join-Path $olderSkill 'references/compile.md'))
[IO.File]::WriteAllText((Join-Path $olderSkill 'version.json'),'{"schema_version":1,"version":"1.2.3"}')
& (Join-Path $repo 'scripts/Package-Skill.ps1') -SkillRoot $olderSkill -OutputDirectory (Join-Path $work 'older-package') -SourceCommit $commit | Out-Null
$olderArchive=Join-Path $work 'older-package/mql5-coding-windows.zip'
$olderHome=Join-Path $work 'older-home'
$older=RunUpdater @('-ClientHost','Codex','-Action','Update','-Version','1.2.3','-CodexDirectory',$olderHome,'-ArchivePath',$olderArchive,'-ExpectedArchiveSha256',(Get-Mql5ReleaseHash $olderArchive),'-ExpectedSourceCommit',$commit)
if ($older.code) {throw $older.error_text}
Check ($older.data.version -ceq '1.2.3') 'current verifier installs a complete pre-1.2.4 package without compile.md'
$missingSkill=Join-Path $work 'missing-compile-skill';Copy-Item -LiteralPath $skill -Destination $missingSkill -Recurse
[IO.File]::Delete((Join-Path $missingSkill 'references/compile.md'))
Reject {& (Join-Path $repo 'scripts/Package-Skill.ps1') -SkillRoot $missingSkill -OutputDirectory (Join-Path $work 'missing-compile-package') -SourceCommit $commit} 'a 1.2.4 package without compile.md is rejected'
$base=RunUpdater (Options $freshHome $archive $digest)
if ($base.code) {throw $base.error_text}
$nextSkill=Join-Path $work 'next-skill';Copy-Item -LiteralPath $skill -Destination $nextSkill -Recurse
$nextVersion=([string]([version]$version).Major)+'.'+([string](([version]$version).Minor+1))+'.0'
[IO.File]::WriteAllText((Join-Path $nextSkill 'version.json'),('{"schema_version":1,"version":"'+$nextVersion+'"}'))
[IO.File]::WriteAllText((Join-Path $nextSkill 'references/new-reference.md'),'A future release can add a verified resource.')
& (Join-Path $repo 'scripts/Package-Skill.ps1') -SkillRoot $nextSkill -OutputDirectory (Join-Path $work 'next-package') -SourceCommit $commit -Tag ('v'+$nextVersion) | Out-Null
$nextArchive=Join-Path $work 'next-package/mql5-coding-windows.zip'
$installedVersion=Join-Path $freshHome 'skills/mql5-coding/version.json'
$installedText=[IO.File]::ReadAllText($installedVersion)
foreach ($case in @(
    @{name='array-schema';text=('{"schema_version":[1],"version":"'+$version+'"}')},
    @{name='string-schema';text=('{"schema_version":"1","version":"'+$version+'"}')},
    @{name='boolean-schema';text=('{"schema_version":true,"version":"'+$version+'"}')},
    @{name='extra-field';text=('{"schema_version":1,"version":"'+$version+'","extra":true}')}
)) {
    [IO.File]::WriteAllText($installedVersion,$case.text)
    $preserved=@(Get-Mql5ReleaseInventory (Split-Path -Parent $installedVersion))
    try {
        $invalid=RunUpdater @('-Action','Update','-Version',$nextVersion,'-CodexDirectory',$freshHome,'-ArchivePath',$nextArchive,'-ExpectedArchiveSha256',(Get-Mql5ReleaseHash $nextArchive),'-ExpectedSourceCommit',$commit)
        Check ($invalid.code -ne 0) ('installed '+$case.name+' version record rejected before upgrade')
        Assert-Mql5ReleaseInventory (Split-Path -Parent $installedVersion) $preserved
    } finally {[IO.File]::WriteAllText($installedVersion,$installedText)}
}
$upgrade=RunUpdater @('-Action','Update','-Version',$nextVersion,'-CodexDirectory',$freshHome,'-ArchivePath',$nextArchive,'-ExpectedArchiveSha256',(Get-Mql5ReleaseHash $nextArchive),'-ExpectedSourceCommit',$commit)
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
# GitHub CLI calls run under a deadline in a kill-on-close job so a stalled call cannot hold the update lock.
$cmd=Join-Path $env:WINDIR 'System32\cmd.exe'
$stalled=Invoke-Mql5BoundedProcess $cmd @('/d','/c','ping -n 30 127.0.0.1 >nul') $work 2
Check ($stalled.status -ceq 'timed_out' -and $stalled.cleanup_verified) 'bounded process stops a stalled process tree at its deadline'
$finished=Invoke-Mql5BoundedProcess $cmd @('/d','/c','echo ok') $work 30
Check ($finished.status -ceq 'completed' -and $finished.exit_code -eq 0 -and $finished.stdout.Trim() -ceq 'ok') 'bounded process returns completed output'
$fakeBin=Join-Path $work 'fake-gh';[IO.Directory]::CreateDirectory($fakeBin) | Out-Null
Copy-Item -LiteralPath $cmd -Destination (Join-Path $fakeBin 'gh.exe')
$savedPath=$env:PATH;$realBounded=${function:Invoke-Mql5BoundedProcess}
try {
    $env:PATH=$work
    $message=$null;try {Invoke-Mql5ReleaseGhProcess @('api','x') 5 'failed'} catch {$message=$_.Exception.Message}
    Check ($message -like 'GitHub CLI (gh.exe) was not found*') 'missing gh is reported before any GitHub call'
    $env:PATH=$fakeBin
    function Invoke-Mql5BoundedProcess {return [pscustomobject]@{status='timed_out';exit_code=$null;stdout='';stderr='';cleanup_verified=$true}}
    $message=$null;try {Invoke-Mql5ReleaseGhProcess @('release','download') 600 'Authenticated release download failed.'} catch {$message=$_.Exception.Message}
    Check ($message -like 'GitHub CLI did not finish within 600 seconds*') 'stalled GitHub download fails with a timeout error'
    function Invoke-Mql5BoundedProcess {return [pscustomobject]@{status='completed';exit_code=1;stdout='';stderr='';cleanup_verified=$true}}
    $message=$null;try {Invoke-Mql5ReleaseGhProcess @('release','download') 600 'Authenticated release download failed.'} catch {$message=$_.Exception.Message}
    Check ($message -ceq 'Authenticated release download failed.') 'failed GitHub download keeps its specific error'
} finally {$env:PATH=$savedPath;Set-Item -Path function:Invoke-Mql5BoundedProcess -Value $realBounded}
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
