#Requires -Version 5.1
# Trusted release primitives. No code from a downloaded archive is executed.
function Get-Mql5SkillReleaseFiles {
    return @('SKILL.md','agents/openai.yaml','references/strategy-tester.md','references/mcp-contract.json',
        'references/environment-health.md','references/project-profiles.md','references/releases.md',
        'scripts/Mql5ProjectProfile.ps1','scripts/New-Mql5ProjectProfile.ps1','scripts/Invoke-Mql5Project.ps1',
        'scripts/Test-Mql5Environment.ps1','scripts/Compile-Mql5.ps1','scripts/CompilationReceipt.ps1',
        'scripts/WindowsExecutableMetadata.ps1',
        'scripts/CompilerProcessJob.cs','scripts/Invoke-Mt5TesterSmoke.ps1','scripts/TesterEvidence.ps1',
        'scripts/TesterPathIntegrity.ps1','scripts/TesterProcessJob.cs','scripts/SkillRelease.ps1',
        'scripts/Update-Mql5Skill.ps1','version.json',
        'scripts/mql5_toolkit.py','scripts/toolkit_common.py','scripts/toolkit_reports.py',
        'scripts/toolkit_includes.py','scripts/toolkit_profiles.py','scripts/ToolkitSupport.ps1',
        'scripts/Read-Mql5Journal.ps1','scripts/Invoke-Mql5ScenarioBatch.ps1',
        'references/toolkit.md','references/focused-review.md','references/performance.md','references/refactoring.md',
        'assets/scenarios.template.json','assets/comparison-expectations.template.json',
        'assets/Mql5Assertions.mqh','assets/Mql5ToolkitSelfTest.mq5') | Sort-Object
}
function Get-Mql5ReleaseHash([string]$Path) {
    $stream=[IO.File]::Open($Path,[IO.FileMode]::Open,[IO.FileAccess]::Read,[IO.FileShare]::Read)
    $sha=[Security.Cryptography.SHA256]::Create()
    try {return ([BitConverter]::ToString($sha.ComputeHash($stream))).Replace('-','').ToLowerInvariant()}
    finally {$sha.Dispose();$stream.Dispose()}
}
function Assert-Mql5ReleasePath([string]$Path) {
    $full=[IO.Path]::GetFullPath($Path)
    if ($full -notmatch '^[A-Za-z]:\\' -or $full.IndexOf(':',2) -ge 0) {throw 'Release paths must be ordinary absolute local Windows paths.'}
    $part=$full
    while ($part) {
        if ([IO.File]::Exists($part) -or [IO.Directory]::Exists($part)) {
            if (([IO.File]::GetAttributes($part) -band [IO.FileAttributes]::ReparsePoint) -ne 0) {throw 'Reparse points are not permitted in release paths.'}
        }
        $next=[IO.Path]::GetDirectoryName($part)
        if ($next -eq $part) {break}; $part=$next
    }
    # Preserve a drive root's separator so later APIs cannot resolve C: through cwd.
    if ($full -ieq [IO.Path]::GetPathRoot($full)) {return $full}
    return $full.TrimEnd('\')
}
function Assert-Mql5ReleaseObject($Object,[string[]]$Fields) {
    if ($Object -isnot [pscustomobject]) {throw 'Release metadata must be a JSON object.'}
    $names=@($Object.PSObject.Properties.Name)
    if ($names.Count -ne $Fields.Count) {throw 'Unsupported release metadata fields.'}
    foreach ($name in $names) {if ($name -cnotin $Fields) {throw 'Unsupported release metadata fields.'}}
}
function Assert-Mql5SkillVersion($Identity) {
    Assert-Mql5ReleaseObject $Identity @('schema_version','version')
    if (($Identity.schema_version -isnot [int] -and $Identity.schema_version -isnot [long]) -or
        $Identity.schema_version -ne 1 -or $Identity.version -isnot [string] -or
        $Identity.version -cnotmatch '\A(?:0|[1-9][0-9]*)\.(?:0|[1-9][0-9]*)\.(?:0|[1-9][0-9]*)\z') {throw 'Invalid skill version metadata.'}
}
function Assert-Mql5ReleaseBackup($Record,[string]$BackupId,[string]$Target) {
    Assert-Mql5ReleaseObject $Record @('schema_version','backup_id','target','had_installation','files')
    if (($Record.schema_version -isnot [int] -and $Record.schema_version -isnot [long]) -or
        $Record.schema_version -ne 1 -or $Record.backup_id -isnot [string] -or $Record.backup_id -cne $BackupId -or
        $Record.target -isnot [string] -or $Record.target -cne $Target -or $Record.had_installation -isnot [bool]) {throw 'Invalid backup record for this destination.'}
    $null=Get-Mql5ReleaseFileMap $Record.files
    if (-not $Record.had_installation -and $Record.files.Count -ne 0) {throw 'An empty installation backup must have an empty inventory.'}
}
function Assert-Mql5ReleaseIntent($Intent,[string]$Target) {
    if ($Intent -isnot [pscustomobject] -or $Intent.action -isnot [string] -or $Intent.action -cnotin @('update','rollback') -or
        $Intent.target -isnot [string] -or $Intent.target -cne $Target) {throw 'Invalid pending release intent.'}
    if ($Intent.action -ceq 'update') {Assert-Mql5ReleaseObject $Intent @('action','target')}
    else {
        Assert-Mql5ReleaseObject $Intent @('action','target','restore_backup_id')
        if ($Intent.restore_backup_id -isnot [string] -or $Intent.restore_backup_id -cnotmatch '\A[0-9a-f]{32}\z') {throw 'Invalid pending rollback intent.'}
    }
}
function Assert-Mql5JsonString([string]$Token) {
    # Both supported JSON converters replace unpaired escaped UTF-16 units.
    # Inspect serialized escapes first, respecting escaped literal backslashes.
    $escapes=@([regex]::Matches($Token,'\\(?:u[0-9a-fA-F]{4}|.)'))
    for ($index=0; $index -lt $escapes.Count; $index++) {
        $escape=$escapes[$index]
        if ($escape.Value.Length -ne 6 -or $escape.Value[1] -cne 'u') {continue}
        $unit=[Convert]::ToInt32($escape.Value.Substring(2),16)
        if ($unit -ge 0xd800 -and $unit -le 0xdbff) {
            if ($index+1 -ge $escapes.Count) {throw 'JSON contains invalid Unicode text.'}
            $next=$escapes[$index+1]
            if ($next.Index -ne $escape.Index+6 -or $next.Value.Length -ne 6 -or $next.Value[1] -cne 'u') {throw 'JSON contains invalid Unicode text.'}
            $low=[Convert]::ToInt32($next.Value.Substring(2),16)
            if ($low -lt 0xdc00 -or $low -gt 0xdfff) {throw 'JSON contains invalid Unicode text.'}
            $index++
        } elseif ($unit -ge 0xdc00 -and $unit -le 0xdfff) {throw 'JSON contains invalid Unicode text.'}
    }
}
function Read-Mql5JsonText([IO.Stream]$Stream) {
    if ($Stream.Length -gt 1048576) {throw 'JSON metadata is too large.'}
    $buffer=New-Object byte[] ([int]$Stream.Length)
    $read=0
    while ($read -lt $buffer.Length) {
        $got=$Stream.Read($buffer,$read,$buffer.Length-$read)
        if ($got -eq 0) {throw 'Incomplete JSON metadata read.'}
        $read+=$got
    }
    $reader=[IO.StreamReader]::new([IO.MemoryStream]::new($buffer,$false),(New-Object Text.UTF8Encoding($false,$true)),$true)
    try {
        $text=$reader.ReadToEnd()
        # BOM detection can select a forgiving UTF-16/UTF-32 decoder despite
        # the strict initial UTF-8 encoding. Validate these exact captured
        # bytes with a strict clone of the encoding actually selected.
        $strictEncoding=$reader.CurrentEncoding.Clone()
        $strictEncoding.DecoderFallback=[Text.DecoderFallback]::ExceptionFallback
        [void]$strictEncoding.GetCharCount($buffer)
        return $text
    } finally {$reader.Dispose()}
}
function Read-Mql5ReleaseJson([string]$Path,[byte[]]$Bytes) {
    if ($PSBoundParameters.ContainsKey('Bytes')) {
        if ($null -eq $Bytes -or $Bytes.Length -gt 1048576) {throw 'Release metadata buffer is unavailable or too large.'}
        $stream=[IO.MemoryStream]::new($Bytes,$false)
    } else {
        $stream=[IO.File]::Open($Path,[IO.FileMode]::Open,[IO.FileAccess]::Read,[IO.FileShare]::Read)
    }
    try {$text=Read-Mql5JsonText $stream} finally {$stream.Dispose()}
    # Refuse array roots before ConvertFrom-Json can unwrap a single element.
    if (-not $text.TrimStart().StartsWith('{')) {throw 'Release metadata must have a JSON object at its root.'}
    # Refuse duplicate, case-aliased and escaped JSON keys before ConvertFrom-Json.
    $stack=New-Object 'Collections.Generic.Stack[object]'
    foreach ($token in [regex]::Matches($text,'"(?:[^"\\]|\\.)*"|[{}\[\]]')) {
        switch ($token.Value) {
            '{' {$stack.Push(@{});continue} '[' {$stack.Push($null);continue}
            '}' {if ($stack.Count) {[void]$stack.Pop()};continue} ']' {if ($stack.Count) {[void]$stack.Pop()};continue}
        }
        Assert-Mql5JsonString $token.Value
        $next=$token.Index+$token.Length
        while ($next -lt $text.Length -and [char]::IsWhiteSpace($text[$next])) {$next++}
        if ($next -lt $text.Length -and $text[$next] -eq ':' -and $stack.Count -and $null -ne $stack.Peek()) {
            $key=(('{"k":'+$token.Value+'}') | ConvertFrom-Json).k
            if ($stack.Peek().ContainsKey($key)) {throw 'Duplicate release metadata keys.'}
            $stack.Peek()[$key]=$true
        }
    }
    return ($text | ConvertFrom-Json)
}
function Write-Mql5ReleaseJson([string]$Path,$Value) {
    $stream=[IO.File]::Open($Path,[IO.FileMode]::CreateNew,[IO.FileAccess]::Write,[IO.FileShare]::None)
    try {
        $bytes=(New-Object Text.UTF8Encoding($false)).GetBytes(($Value | ConvertTo-Json -Depth 12 -Compress)+"`n")
        $stream.Write($bytes,0,$bytes.Length); $stream.Flush($true)
    } finally {$stream.Dispose()}
}
function Get-Mql5ReleaseInventory([string]$Root) {
    $root=Assert-Mql5ReleasePath $Root
    $rootPrefix=$root.TrimEnd('\')+'\'
    $result=@()
    # Enumerate one level at a time, refusing junctions before recursion.
    $pending=New-Object 'Collections.Generic.Stack[string]'; $pending.Push($root)
    while ($pending.Count) {
        foreach ($item in Get-ChildItem -LiteralPath $pending.Pop() -Force) {
            if ($item.Attributes -band [IO.FileAttributes]::ReparsePoint) {throw 'Skill tree contains a reparse point.'}
            if ($item.PSIsContainer) {$pending.Push($item.FullName)}
            else {$result+=@([pscustomobject][ordered]@{path=$item.FullName.Substring($rootPrefix.Length).Replace('\','/');bytes=$item.Length;sha256=(Get-Mql5ReleaseHash $item.FullName)})}
        }
    }
    return @($result | Sort-Object -Property path)
}
function Get-Mql5ReleaseFileMap($Files) {
    if ($Files -isnot [Array]) {throw 'File records must be an array.'}
    $expected=@{}
    foreach ($file in $Files) {
        Assert-Mql5ReleaseObject $file @('path','bytes','sha256')
        if ($file.path -isnot [string] -or $file.path.Length -gt 240 -or $file.path -match '[\x00-\x1f\x7f\\:*?"<>|]' -or
            @($file.path.Split('/') | Where-Object {$_ -in @('','.','..') -or $_ -match '[. ]$' -or $_ -match '^(con|prn|aux|nul|com[1-9]|lpt[1-9])(?:\.|$)'}).Count -or
            $expected.ContainsKey($file.path) -or $file.sha256 -isnot [string] -or $file.sha256 -cnotmatch '\A[0-9a-f]{64}\z' -or
            ($file.bytes -isnot [int] -and $file.bytes -isnot [long]) -or $file.bytes -lt 0) {throw 'Invalid release file record.'}
        $expected[$file.path]=$file
    }
    return $expected
}
function Assert-Mql5ReleaseInventory([string]$Root,$Files) {
    $actual=@(Get-Mql5ReleaseInventory $Root)
    $expected=Get-Mql5ReleaseFileMap $Files
    if ($actual.Count -ne $Files.Count) {throw 'Skill file inventory differs from the verified inventory.'}
    foreach ($file in $actual) {
        if (-not $expected.ContainsKey($file.path) -or $file.path -cne $expected[$file.path].path -or
            $file.sha256 -cne $expected[$file.path].sha256 -or $file.bytes -ne $expected[$file.path].bytes) {throw 'Skill bytes differ from the verified inventory.'}
    }
}
function Assert-Mql5SkillManifest($Manifest,[string]$Version,[string]$Commit) {
    Assert-Mql5ReleaseObject $Manifest @('schema_version','repository','tag','version','source_commit','files')
    # PowerShell comparisons filter array operands; an array containing only
    # the expected identity can otherwise look equal to a required string.
    foreach ($field in @('repository','tag','version','source_commit')) {
        if ($Manifest.$field -isnot [string]) {throw 'Release identity fields must be strings.'}
    }
    if (($Manifest.schema_version -isnot [int] -and $Manifest.schema_version -isnot [long]) -or $Manifest.schema_version -ne 1 -or
        $Manifest.repository -cne 'shamwi2846/MQL5-Coding-Skill' -or $Manifest.version -cne $Version -or
        $Manifest.tag -cne ('v'+$Version) -or $Manifest.source_commit -cne $Commit -or
        $Commit -cnotmatch '\A[0-9a-f]{40}\z' -or $Version -cnotmatch '\A(?:0|[1-9][0-9]*)\.(?:0|[1-9][0-9]*)\.(?:0|[1-9][0-9]*)\z') {throw 'Release identity differs from the requested tag and commit.'}
    $expected=@(Get-Mql5SkillReleaseFiles)
    if ($Manifest.files -isnot [Array] -or $Manifest.files.Count -lt $expected.Count -or $Manifest.files.Count -gt 128) {throw 'Release file set is incomplete or too large.'}
    $null=Get-Mql5ReleaseFileMap $Manifest.files
    foreach ($file in $Manifest.files) {
        if ($file.path -cnotin @('SKILL.md','version.json') -and $file.path -cnotmatch '\A(?:agents|references|scripts|assets)/') {throw 'Unexpected skill package location.'}
        if ($file.bytes -gt 4194304) {throw 'Released skill file is too large.'}
    }
    foreach ($path in $expected) {if (@($Manifest.files | Where-Object {$_.path -ceq $path}).Count -ne 1) {throw 'Release file set is unexpected.'}}
}
function Expand-Mql5SkillRelease([string]$Archive,[string]$Digest,[string]$Version,[string]$Commit,[string]$Stage) {
    if ($Digest -cnotmatch '\A[0-9a-f]{64}\z' -or (Get-Mql5ReleaseHash $Archive) -cne $Digest) {throw 'Release ZIP SHA-256 differs from the trusted digest.'}
    if ((Get-Item -LiteralPath $Archive).Length -gt 16777216) {throw 'Release ZIP is too large.'}
    Add-Type -AssemblyName System.IO.Compression
    Add-Type -AssemblyName System.IO.Compression.FileSystem
    $zip=[IO.Compression.ZipFile]::OpenRead($Archive)
    try {
        $manifests=@($zip.Entries | Where-Object {$_.FullName -ceq 'release-manifest.json'})
        if ($manifests.Count -ne 1 -or $manifests[0].Length -gt 1048576) {throw 'Release ZIP has no unique bounded manifest.'}
        [IO.Directory]::CreateDirectory($Stage) | Out-Null
        $manifestPath=Join-Path $Stage 'release-manifest.json'
        [IO.Compression.ZipFileExtensions]::ExtractToFile($manifests[0],$manifestPath,$false)
        $manifest=Read-Mql5ReleaseJson $manifestPath
        Assert-Mql5SkillManifest $manifest $Version $Commit
        $expected=@('release-manifest.json')+@($manifest.files | ForEach-Object {'mql5-coding/'+$_.path})
        if ($zip.Entries.Count -ne $expected.Count) {throw 'Unexpected release ZIP entry count.'}
        $seen=@{}; $total=0L
        foreach ($entry in $zip.Entries) {
            $name=$entry.FullName
            $unixType=(([long]$entry.ExternalAttributes -shr 16) -band 61440)
            if ($name -cnotin $expected -or $seen.ContainsKey($name) -or $unixType -eq 40960 -or
                ($entry.ExternalAttributes -band 1024) -or $entry.Length -gt 4194304) {throw 'Unsafe or unexpected release ZIP entry.'}
            $seen[$name]=$true; $total+=$entry.Length
        }
        if ($total -gt 16777216) {throw 'Uncompressed release ZIP is too large.'}
        [IO.Directory]::CreateDirectory($Stage) | Out-Null
        foreach ($entry in $zip.Entries) {
            if ($entry.FullName -ceq 'release-manifest.json') {continue}
            $path=Join-Path $Stage $entry.FullName
            [IO.Directory]::CreateDirectory((Split-Path -Parent $path)) | Out-Null
            [IO.Compression.ZipFileExtensions]::ExtractToFile($entry,$path,$false)
        }
    } finally {$zip.Dispose()}
    $manifest=Read-Mql5ReleaseJson (Join-Path $Stage 'release-manifest.json')
    Assert-Mql5SkillManifest $manifest $Version $Commit
    Assert-Mql5ReleaseInventory (Join-Path $Stage 'mql5-coding') $manifest.files
    $identity=Read-Mql5ReleaseJson (Join-Path $Stage 'mql5-coding/version.json')
    Assert-Mql5SkillVersion $identity
    if ($identity.version -cne $Version) {throw 'Packaged skill version differs from its manifest.'}
    return $manifest
}
function Invoke-Mql5ReleaseGh([string[]]$Arguments) {
    # gh owns authentication. Never read, print or persist its access token.
    $result=& gh @Arguments 2>$null
    if ($LASTEXITCODE -ne 0) {throw 'Authenticated GitHub operation failed. Check gh auth status and repository access.'}
    return (($result -join "`n") | ConvertFrom-Json)
}
function Move-Mql5ReleaseItem([string]$Source,[string]$Destination) {
    $source=Assert-Mql5ReleasePath $Source;$destination=Assert-Mql5ReleasePath $Destination
    if ([IO.Directory]::Exists($source)) {[IO.Directory]::Move($source,$destination)}
    else {[IO.File]::Move($source,$destination)}
}
function Copy-Mql5ReleaseSnapshot([string]$Source,[string]$Destination,$Files) {
    Assert-Mql5ReleaseInventory $Source $Files
    Copy-Item -LiteralPath $Source -Destination $Destination -Recurse
    Assert-Mql5ReleaseInventory $Destination $Files
    Assert-Mql5ReleaseInventory $Source $Files
}
function Set-Mql5ReleaseContents([string]$Target,[string]$Prepared,[string]$Displaced,$Files,[switch]$RemoveRoot) {
    # Codex's directory watcher can pin the skill root without FILE_SHARE_DELETE.
    # Preserve that root and publish its children; keep a complete snapshot before calling.
    $hadRoot=[IO.Directory]::Exists($Target)
    $null=Get-Mql5ReleaseInventory $Prepared
    if ($hadRoot) {$null=Get-Mql5ReleaseInventory $Target}
    [IO.Directory]::CreateDirectory($Target) | Out-Null
    [IO.Directory]::CreateDirectory($Displaced) | Out-Null
    $failed=$Displaced+'-failed';[IO.Directory]::CreateDirectory($failed) | Out-Null
    $old=@();$published=@()
    try {
        foreach ($item in @(Get-ChildItem -LiteralPath $Target -Force | Sort-Object Name)) {
            Move-Mql5ReleaseItem $item.FullName (Join-Path $Displaced $item.Name)
            $old+=@($item.Name)
        }
        foreach ($item in @(Get-ChildItem -LiteralPath $Prepared -Force | Sort-Object Name)) {
            Move-Mql5ReleaseItem $item.FullName (Join-Path $Target $item.Name)
            $published+=@($item.Name)
        }
        Assert-Mql5ReleaseInventory $Target $Files
        if ($RemoveRoot) {
            if ($Files.Count -ne 0) {throw 'Only a verified empty skill root can be removed.'}
            [IO.Directory]::Delete($Target,$false)
        }
    } catch {
        foreach ($name in $published) {Move-Mql5ReleaseItem (Join-Path $Target $name) (Join-Path $failed $name)}
        foreach ($name in $old) {Move-Mql5ReleaseItem (Join-Path $Displaced $name) (Join-Path $Target $name)}
        if (-not $hadRoot) {[IO.Directory]::Delete($Target,$false)}
        throw
    }
}
function Get-Mql5SkillGitHubRelease([string]$Version) {
    if ($Version -cnotmatch '\A(?:0|[1-9][0-9]*)\.(?:0|[1-9][0-9]*)\.(?:0|[1-9][0-9]*)\z') {throw 'Select an explicit stable version, such as 1.0.0.'}
    $repo='shamwi2846/MQL5-Coding-Skill'; $tag='v'+$Version
    $release=Invoke-Mql5ReleaseGh @('api',('repos/'+$repo+'/releases/tags/'+$tag))
    if ($release.draft -ne $false -or $release.prerelease -ne $false -or $release.tag_name -cne $tag) {throw 'Select a published stable skill release.'}
    $commit=Invoke-Mql5ReleaseGh @('api',('repos/'+$repo+'/commits/'+$tag))
    $assets=@($release.assets | Where-Object {$_.name -ceq 'mql5-coding-windows.zip'})
    if ($assets.Count -ne 1 -or $assets[0].state -cne 'uploaded' -or $assets[0].digest -cnotmatch '\Asha256:[0-9a-f]{64}\z' -or $assets[0].size -lt 1 -or $assets[0].size -gt 16777216 -or $commit.sha -cnotmatch '\A[0-9a-f]{40}\z') {throw 'Release asset has no valid GitHub SHA-256 digest, size or source commit.'}
    return [pscustomobject]@{version=$Version;tag=$tag;source_commit=$commit.sha;sha256=$assets[0].digest.Substring(7);bytes=$assets[0].size;url=$release.html_url;repository=$repo}
}
