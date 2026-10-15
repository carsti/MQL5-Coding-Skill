#Requires -Version 5.1
# Shared primitives; callers own output policy and evidence interpretation.
. (Join-Path $PSScriptRoot 'SkillRelease.ps1')
function Get-ToolkitValue($Object,[string]$Name,$Default=$null) {
    if ($Object -is [Collections.IDictionary]) {
        if ($Object.Contains($Name)) {return $Object[$Name]}
        return $Default
    }
    if ($null -ne $Object) {
        $property=$Object.PSObject.Properties[$Name]
        if ($null -ne $property) {return $property.Value}
    }
    return $Default
}
function Read-ToolkitJsonEvidence([string]$Path) {
    $stream=[IO.File]::Open($Path,[IO.FileMode]::Open,[IO.FileAccess]::Read,[IO.FileShare]::Read)
    try {
        if ($stream.Length -gt 1048576) {throw 'Toolkit JSON evidence exceeds the supported metadata limit.'}
        $buffer=New-Object byte[] ([int]$stream.Length)
        $read=0
        while ($read -lt $buffer.Length) {
            $got=$stream.Read($buffer,$read,$buffer.Length-$read)
            if ($got -eq 0) {throw 'Incomplete toolkit JSON evidence read.'}
            $read+=$got
        }
    } finally {$stream.Dispose()}
    $value=Read-Mql5ReleaseJson -Path $Path -Bytes $buffer
    $sha=[Security.Cryptography.SHA256]::Create()
    try {$hash=([BitConverter]::ToString($sha.ComputeHash($buffer))).Replace('-','').ToLowerInvariant()} finally {$sha.Dispose()}
    return [pscustomobject]@{value=$value;source=@{path=$Path;sha256=$hash;byte_length=$buffer.Length}}
}
function Assert-ToolkitFields($Object,[string[]]$Required,[string[]]$Optional=@()) {
    if ($Object -isnot [pscustomobject]) {throw 'Configuration must be an object.'}
    foreach ($key in $Required) {if ($null -eq $Object.PSObject.Properties[$key]) {throw 'Required configuration field is missing.'}}
    foreach ($key in $Object.PSObject.Properties.Name) {if ($key -cnotin ($Required+$Optional)) {throw 'Unsupported configuration field.'}}
}
function Assert-ToolkitVersion($Object) {
    if (($Object.schema_version -isnot [int] -and $Object.schema_version -isnot [long]) -or $Object.schema_version -ne 1) {throw 'Unsupported schema version.'}
}
function Resolve-ToolkitPath([string]$Path,[string]$Base,[string]$Kind='Leaf') {
    if ([string]::IsNullOrWhiteSpace($Path)) {throw 'Select a nonempty path.'}
    if ([IO.Path]::IsPathRooted($Path) -and $Path -notmatch '^[A-Za-z]:[\\/]' -and $Path -notmatch '^\\\\[^\\/]+[\\/][^\\/]+') {throw 'Unsupported drive-relative or root-relative path.'}
    $full=if ([IO.Path]::IsPathRooted($Path)) {[IO.Path]::GetFullPath($Path)} else {[IO.Path]::GetFullPath((Join-Path $Base $Path))}
    if ($Kind -and -not (Test-Path -LiteralPath $full -PathType $Kind)) {throw 'Selected evidence or configuration path is unavailable.'}
    return $full
}
function New-ToolkitOutput([string]$Path) {
    $full=Assert-Mql5ReleasePath $Path
    if ($Path -notmatch '^[A-Za-z]:[\\/]' -or (Test-Path -LiteralPath $full)) {throw 'Select a new absolute output directory.'}
    if (-not (Test-Path -LiteralPath ([IO.Path]::GetDirectoryName($full)) -PathType Container)) {throw 'Output parent directory is unavailable.'}
    # Reuse the tester's native exclusive create: CreateDirectory returning an
    # existing directory cannot establish ownership after the preceding check.
    if (-not ('Mql5Coding.JobProcessLaunch' -as [type])) {Add-Type -Path (Join-Path $PSScriptRoot 'TesterProcessJob.cs')}
    if (-not [Mql5Coding.JobProcessLaunch]::TryCreateDirectory($full)) {throw 'Select a new absolute output directory.'}
    $owner=[IO.File]::Open((Join-Path $full '.toolkit-owner'),[IO.FileMode]::CreateNew,[IO.FileAccess]::Write,[IO.FileShare]::None)
    try {$bytes=[Text.Encoding]::UTF8.GetBytes([guid]::NewGuid().ToString('N'));$owner.Write($bytes,0,$bytes.Length)} finally {$owner.Dispose()}
    return $full
}
function Save-ToolkitResult([string]$Root,$Result,[string[]]$Summary) {
    Write-Mql5ReleaseJson (Join-Path $Root 'result.json') $Result
    [IO.File]::WriteAllText((Join-Path $Root 'summary.txt'),(($Summary -join "`n")+"`n"),(New-Object Text.UTF8Encoding($false)))
    foreach ($line in $Summary) {Write-Output $line}
    Write-Output ('Evidence: '+(Join-Path $Root 'result.json'))
}
function Set-ToolkitPublicationFailure($Result) {
    $Result.status='failed';$Result.exit_code=2
    if (@($Result.issues | Where-Object {$_.code -eq 'output_publication_failed'}).Count -eq 0) {
        $Result.issues+=@(@{code='output_publication_failed';message='Output could not be saved; retained files may be partial.'})
    }
    # Do not expose exception text, paths or an unbounded PowerShell error record.
    [Console]::Error.WriteLine('Toolkit output could not be saved. Retained files may be partial; check process exit code 2.')
}
function Get-ToolkitPython([string]$Selected) {
    if ($Selected) {
        if ($Selected -notmatch '^[A-Za-z]:[\\/]') {throw 'PythonPath must be absolute.'}
        return Resolve-ToolkitPath $Selected $PSScriptRoot
    }
    $codexDirectory=if ([string]::IsNullOrWhiteSpace($env:CODEX_HOME)) {Join-Path $env:USERPROFILE '.codex'} else {$env:CODEX_HOME}
    $path=Join-Path $codexDirectory 'tools\mql5-python\.venv\Scripts\python.exe'
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) {throw 'Shared MQL5 Python is missing; restore the existing shared environment or select PythonPath. No environment was created.'}
    return [IO.Path]::GetFullPath($path)
}
function Invoke-ToolkitProcess([string]$Executable,[string[]]$Arguments,[string]$Directory,[int]$Seconds) {
    $answer=Invoke-Mql5BoundedProcess $Executable $Arguments $Directory $Seconds @{PYTHONDONTWRITEBYTECODE='1';PYTHONNOUSERSITE='1'}
    # Toolkit tests inject faults into disposable copies at this exact line.
    return [pscustomobject]$answer
}
