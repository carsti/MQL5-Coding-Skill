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
