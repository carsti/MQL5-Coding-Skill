#Requires -Version 5.1
# Shared data-only profile validation. Execution remains in the existing wrappers.
function Assert-Mql5ProfileObject($Object, [string[]]$Fields) {
    if ($Object -isnot [pscustomobject]) {throw 'Profile section must be a JSON object.'}
    $actual=@($Object.PSObject.Properties.Name)
    if ($actual.Count -ne $Fields.Count) {throw 'Profile has missing or unsupported fields.'}
    foreach ($field in $actual) {if ($field -cnotin $Fields) {throw 'Profile has missing or unsupported fields.'}}
}
function Assert-Mql5ProfileText($Value, [int]$Maximum=4096) {
    if ($Value -isnot [string] -or [string]::IsNullOrWhiteSpace($Value) -or $Value.Length -gt $Maximum -or $Value -match '[\x00-\x1f\x7f]') {throw 'Profile has an invalid text value.'}
}
function Assert-Mql5ProfileInteger($Value, [int]$Minimum, [int]$Maximum) {
    if (($Value -isnot [int] -and $Value -isnot [long]) -or $Value -lt $Minimum -or $Value -gt $Maximum) {throw 'Profile has an invalid integer value.'}
}
function Resolve-Mql5ProfilePath($Value, [string]$Base, [string]$Kind) {
    Assert-Mql5ProfileText $Value
    # IsPathRooted also accepts \file and C:file. Those depend on ambient
    # drive/directory state rather than the profile's declared base.
    if ([IO.Path]::IsPathRooted($Value) -and $Value -notmatch '\A[A-Za-z]:[\\/]' -and $Value -notmatch '\A[\\/]{2}[^\\/]+[\\/][^\\/]+') {
        throw 'Profile paths must be relative to their declared base or fully qualified absolute paths.'
    }
    $path=if ([IO.Path]::IsPathRooted($Value)) {[IO.Path]::GetFullPath($Value)} else {[IO.Path]::GetFullPath((Join-Path $Base $Value))}
    if (-not (Test-Path -LiteralPath $path -PathType $Kind)) {throw 'A selected profile file or directory is unavailable.'}
    return $path
}
function Get-Mql5ProfileStoredPath([string]$Path, [string]$Base, [switch]$AllowOutsideBase) {
    $path=[IO.Path]::GetFullPath($Path)
    $base=[IO.Path]::GetFullPath($Base).TrimEnd('\')+'\'
    if ($path.TrimEnd('\') -ieq $base.TrimEnd('\')) {return '.'}
    # External source/include/preset selections must not silently follow a
    # moved project to a different existing file or directory.
    if (-not $AllowOutsideBase -and -not $path.StartsWith($base,[StringComparison]::OrdinalIgnoreCase)) {return $path}
    if ([IO.Path]::GetPathRoot($path) -ine [IO.Path]::GetPathRoot($base)) {return $path}
    $baseUri=New-Object Uri($base)
    $pathUri=New-Object Uri($path)
    $relative=[Uri]::UnescapeDataString($baseUri.MakeRelativeUri($pathUri).ToString())
    if ([string]::IsNullOrEmpty($relative)) {return '.'}
    return $relative.Replace('/','\')
}
function Assert-Mql5ProfileJsonKeys([string]$Text) {
    # ConvertFrom-Json can collapse duplicate keys. Refuse ambiguous selectors,
    # including differently cased and escaped spellings, before deserialization.
    $stack=New-Object 'Collections.Generic.Stack[object]'
    foreach ($token in [regex]::Matches($Text,'"(?:[^"\\]|\\.)*"|[{}\[\]]')) {
        switch ($token.Value) {
            '{' {$stack.Push(@{}); continue}
            '[' {$stack.Push($null); continue}
            '}' {if ($stack.Count) {[void]$stack.Pop()}; continue}
            ']' {if ($stack.Count) {[void]$stack.Pop()}; continue}
        }
        $next=$token.Index+$token.Length
        while ($next -lt $Text.Length -and [char]::IsWhiteSpace($Text[$next])) {$next++}
        if ($next -lt $Text.Length -and $Text[$next] -eq ':' -and $stack.Count -gt 0 -and $null -ne $stack.Peek()) {
            $key=(('{"k":'+$token.Value+'}') | ConvertFrom-Json).k
            $keys=$stack.Peek()
            if ($keys.ContainsKey($key)) {throw 'Duplicate profile fields are not allowed.'}
            $keys[$key]=$true
        }
    }
}
function ConvertTo-Mql5ValidatedProfile($Data, [string]$ProfilePath) {
    Assert-Mql5ProfileObject $Data @('schema_version','name','project_root','entrypoints','include_path','metaeditor_path','compiler','tester')
    Assert-Mql5ProfileInteger $Data.schema_version 1 1
    Assert-Mql5ProfileText $Data.name 80
    $parent=Split-Path -Parent ([IO.Path]::GetFullPath($ProfilePath))
    $root=Resolve-Mql5ProfilePath $Data.project_root $parent 'Container'
    if ($Data.entrypoints -isnot [Array] -or $Data.entrypoints.Count -lt 1 -or $Data.entrypoints.Count -gt 64) {throw 'Profile must select 1-64 MQ5 entrypoints.'}
    $entrypoints=@()
    foreach ($entry in $Data.entrypoints) {
        Assert-Mql5ProfileText $entry
        $path=Resolve-Mql5ProfilePath $entry $root 'Leaf'
        if ([IO.Path]::GetExtension($path) -ine '.mq5' -or ((Get-Item -LiteralPath $path).Attributes -band [IO.FileAttributes]::ReparsePoint)) {throw 'Entrypoints must be ordinary MQ5 files.'}
        if ($path -in $entrypoints) {throw 'Duplicate entrypoints are not allowed.'}
        $entrypoints+=@($path)
    }
    $include=$null
    if ($null -ne $Data.include_path) {$include=Resolve-Mql5ProfilePath $Data.include_path $root 'Container'}
    $editor=Resolve-Mql5ProfilePath $Data.metaeditor_path $root 'Leaf'
    if ([IO.Path]::GetFileName($editor) -inotmatch '^metaeditor(?:64)?\.exe$' -or (Get-Item -LiteralPath $editor).VersionInfo.FileMajorPart -ne 5) {throw 'Select an explicit MetaEditor 5 executable.'}
    foreach ($terminalName in @('terminal64.exe','terminal.exe')) {
        $sibling=Join-Path (Split-Path -Parent $editor) $terminalName
        if ((Test-Path -LiteralPath $sibling -PathType Leaf) -and (Get-Item -LiteralPath $sibling).VersionInfo.FileMajorPart -ne 5) {throw 'The selected editor belongs to a non-MT5 terminal.'}
    }
    Assert-Mql5ProfileObject $Data.compiler @('timeout_seconds','warnings_as_errors')
    Assert-Mql5ProfileInteger $Data.compiler.timeout_seconds 5 1800
    if ($Data.compiler.warnings_as_errors -isnot [bool]) {throw 'Compiler warning policy must be boolean.'}
    $tester=$null
    if ($null -ne $Data.tester) {
        $t=$Data.tester
        Assert-Mql5ProfileObject $t @('entrypoint','terminal_path','terminal_data_path','set_path','use_expert_defaults','timeout_seconds','settings')
        $expertSource=Resolve-Mql5ProfilePath $t.entrypoint $root 'Leaf'
        if ($expertSource -notin $entrypoints) {throw 'Tester entrypoint must be one of the project entrypoints.'}
        $terminal=Resolve-Mql5ProfilePath $t.terminal_path $root 'Leaf'
        if ([IO.Path]::GetFileName($terminal) -ine 'terminal64.exe' -or (Get-Item -LiteralPath $terminal).VersionInfo.FileMajorPart -ne 5) {throw 'Select an explicit MT5 terminal64.exe.'}
        $terminalData=Resolve-Mql5ProfilePath $t.terminal_data_path $root 'Container'
        if ($t.use_expert_defaults -isnot [bool]) {throw 'Tester input choice must be boolean.'}
        $preset=$null
        if ($null -ne $t.set_path) {$preset=Resolve-Mql5ProfilePath $t.set_path $root 'Leaf'; if ([IO.Path]::GetExtension($preset) -ine '.set') {throw 'Tester preset must be a SET file.'}}
        if (($null -ne $preset) -eq $t.use_expert_defaults) {throw 'Select exactly one preset or compiled EA defaults.'}
        Assert-Mql5ProfileInteger $t.timeout_seconds 10 86400
        $settings=$t.settings
        Assert-Mql5ProfileObject $settings @('symbol','period','from_date','to_date','model','deposit','currency','leverage','execution_mode')
        Assert-Mql5ProfileText $settings.symbol 64
        if ($settings.symbol -match '[\\/=;]') {throw 'Invalid tester symbol.'}
        Assert-Mql5ProfileText $settings.period 16
        if ($settings.period -cnotmatch '\A[A-Za-z0-9_]+\z') {throw 'Invalid tester period.'}
        foreach ($date in @($settings.from_date,$settings.to_date)) {
            Assert-Mql5ProfileText $date 10
            $parsed=[datetime]::MinValue
            if (-not [datetime]::TryParseExact($date,'yyyy.MM.dd',[Globalization.CultureInfo]::InvariantCulture,[Globalization.DateTimeStyles]::None,[ref]$parsed)) {throw 'Tester dates must use YYYY.MM.DD.'}
        }
        if ([datetime]::ParseExact($settings.to_date,'yyyy.MM.dd',[Globalization.CultureInfo]::InvariantCulture) -le [datetime]::ParseExact($settings.from_date,'yyyy.MM.dd',[Globalization.CultureInfo]::InvariantCulture)) {throw 'Tester end date must follow its start date.'}
        Assert-Mql5ProfileInteger $settings.model 0 4
        Assert-Mql5ProfileInteger $settings.leverage 1 5000
        Assert-Mql5ProfileInteger $settings.execution_mode -1 10000
        Assert-Mql5ProfileText $settings.deposit 32
        $deposit=[decimal]::Zero
        if ($settings.deposit -cnotmatch '\A[0-9]+(?:\.[0-9]+)?\z' -or -not [decimal]::TryParse($settings.deposit,[Globalization.NumberStyles]::AllowDecimalPoint,[Globalization.CultureInfo]::InvariantCulture,[ref]$deposit) -or $deposit -lt 1 -or $deposit -gt 1000000000) {throw 'Invalid invariant tester deposit.'}
        if ($settings.currency -isnot [string] -or $settings.currency -cnotmatch '\A[A-Z]{3,8}\z') {throw 'Invalid tester currency.'}
        $tester=[pscustomobject]@{entrypoint=$expertSource;terminal_path=$terminal;terminal_data_path=$terminalData;set_path=$preset;use_expert_defaults=$t.use_expert_defaults;timeout_seconds=$t.timeout_seconds;settings=$settings}
    }
    return [pscustomobject]@{schema_version=1;name=$Data.name;project_root=$root;entrypoints=@($entrypoints);include_path=$include;metaeditor_path=$editor;compiler=$Data.compiler;tester=$tester}
}
function Read-Mql5ProjectProfile([string]$Path) {
    $path=[IO.Path]::GetFullPath($Path)
    $stream=[IO.File]::Open($path,[IO.FileMode]::Open,[IO.FileAccess]::Read,[IO.FileShare]::Read)
    try {
        if ($stream.Length -lt 1 -or $stream.Length -gt 262144) {throw 'Profile must contain 1-262144 bytes.'}
        $reader=New-Object IO.StreamReader($stream,(New-Object Text.UTF8Encoding($false,$true)),$true)
        try {$text=$reader.ReadToEnd()} finally {$reader.Dispose()}
    } finally {$stream.Dispose()}
    # ConvertFrom-Json enumerates a one-item root array in both supported
    # shells. Check the serialized root before that array can become an object.
    if (-not $text.TrimStart().StartsWith('{')) {throw 'Profile metadata must have a JSON object at its root.'}
    Assert-Mql5ProfileJsonKeys $text
    $data=$text | ConvertFrom-Json
    return ConvertTo-Mql5ValidatedProfile $data $path
}
