#Requires -Version 5.1
# Extended paths are used only for Windows version-resource queries. Callers
# retain their canonical paths for selection, execution, and evidence records.
function ConvertTo-Mql5ExtendedWindowsPath {
    param([Parameter(Mandatory)][string]$Path)
    $fullPath = [IO.Path]::GetFullPath($Path)
    if ($fullPath.StartsWith('\\?\', [StringComparison]::Ordinal)) { return $fullPath }
    if ($fullPath.StartsWith('\\', [StringComparison]::Ordinal)) { return '\\?\UNC\' + $fullPath.Substring(2) }
    return '\\?\' + $fullPath
}

function Get-Mql5ExecutableVersionInfo {
    param([Parameter(Mandatory)][string]$Path)
    try {
        $info = [Diagnostics.FileVersionInfo]::GetVersionInfo((ConvertTo-Mql5ExtendedWindowsPath $Path))
        if ([string]::IsNullOrWhiteSpace($info.FileVersion)) { throw 'No readable Windows version resource.' }
        return $info
    } catch {
        throw "Windows executable metadata is unavailable for '$Path': $($_.Exception.Message)"
    }
}

function Assert-Mql5Terminal {
    param([Parameter(Mandatory)][string]$Path)
    # Selection and evidence retain ordinary canonical paths; only resource
    # queries use the extended spelling in Get-Mql5ExecutableVersionInfo.
    $canonicalPath=[IO.Path]::GetFullPath($Path)
    if ($canonicalPath.StartsWith('\\?\UNC\',[StringComparison]::OrdinalIgnoreCase)) {$canonicalPath='\\'+$canonicalPath.Substring(8)}
    elseif ($canonicalPath.StartsWith('\\?\',[StringComparison]::Ordinal)) {$canonicalPath=$canonicalPath.Substring(4)}
    $terminal=Get-Item -LiteralPath $canonicalPath -ErrorAction Stop
    if ($terminal.PSIsContainer -or $terminal.Name -ine 'terminal64.exe' -or
        ($terminal.Attributes -band [IO.FileAttributes]::ReparsePoint)) {
        throw 'Select an ordinary MT5 terminal64.exe executable.'
    }
    $version=Get-Mql5ExecutableVersionInfo $terminal.FullName
    if ($version.FileMajorPart -ne 5) {throw 'Select a terminal64.exe executable with major version 5.'}
    return [pscustomobject]@{Path=$terminal.FullName;VersionInfo=$version}
}

function Assert-Mql5MetaEditor {
    param(
        [Parameter(Mandatory)][string]$Path,
        # The compiler supplies its existing executable identity leases here.
        # Discovery and profile validation only inspect metadata.
        [scriptblock]$PinSibling
    )
    $canonicalPath=[IO.Path]::GetFullPath($Path)
    if ($canonicalPath.StartsWith('\\?\UNC\',[StringComparison]::OrdinalIgnoreCase)) {$canonicalPath='\\'+$canonicalPath.Substring(8)}
    elseif ($canonicalPath.StartsWith('\\?\',[StringComparison]::Ordinal)) {$canonicalPath=$canonicalPath.Substring(4)}
    $editor=Get-Item -LiteralPath $canonicalPath -ErrorAction Stop
    if ($editor.PSIsContainer -or $editor.Name -notin @('metaeditor64.exe','metaeditor.exe') -or
        ($editor.Attributes -band [IO.FileAttributes]::ReparsePoint)) {
        throw 'Select an ordinary metaeditor64.exe or metaeditor.exe executable.'
    }
    $version=Get-Mql5ExecutableVersionInfo $editor.FullName
    if ($version.FileMajorPart -ne 5) {throw 'Select a MetaEditor executable with major version 5.'}
    $siblings=@()
    foreach ($name in @('terminal64.exe','terminal.exe')) {
        $siblingPath=Join-Path ([IO.Path]::GetDirectoryName($editor.FullName)) $name
        if (-not (Test-Path -LiteralPath $siblingPath)) {continue}
        $sibling=Get-Item -LiteralPath $siblingPath -ErrorAction Stop
        if ($sibling.PSIsContainer -or ($sibling.Attributes -band [IO.FileAttributes]::ReparsePoint)) {
            throw 'The selected editor has an incompatible sibling terminal.'
        }
        $inspectedPath=$sibling.FullName
        if ($null -ne $PinSibling) {
            $inspectedPath=& $PinSibling $inspectedPath
            if (-not [IO.Path]::GetFullPath($inspectedPath).Equals($sibling.FullName,[StringComparison]::OrdinalIgnoreCase)) {
                throw 'Sibling terminal resolved outside its pinned canonical path.'
            }
        }
        $terminalVersion=Get-Mql5ExecutableVersionInfo $inspectedPath
        if ($terminalVersion.FileMajorPart -ne 5) {throw 'The selected editor belongs to an incompatible non-MT5 terminal.'}
        $siblings+=@($sibling.FullName)
    }
    if ($siblings.Count -eq 0 -and $version.FileDescription -notmatch '^MetaEditor\s+5\b') {
        throw 'A standalone editor must identify itself as MetaEditor 5.'
    }
    return [pscustomobject]@{Path=$editor.FullName;VersionInfo=$version;SiblingPaths=$siblings}
}
