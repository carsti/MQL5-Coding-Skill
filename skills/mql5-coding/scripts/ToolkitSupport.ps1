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
    # Directory creation itself is not exclusive on Windows; reserve a create-new owner file
    # after creation and refuse a concurrent winner before publishing any evidence.
    [IO.Directory]::CreateDirectory($full) | Out-Null
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
    if (-not ('Mql5Coding.JobProcessLaunch' -as [type])) {Add-Type -Path (Join-Path $PSScriptRoot 'TesterProcessJob.cs')}
    $job=$null
    $answer=[ordered]@{exit_code=$null;status='launch_failed';stdout='';stderr='';cleanup_verified=$true}
    try {
        $job=[Mql5Coding.JobProcessLaunch]::CreateSuspendedProbe($Executable,$Arguments,$Directory,@{PYTHONDONTWRITEBYTECODE='1';PYTHONNOUSERSITE='1'})
        $out=[Mql5Coding.JobProcessLaunch]::ReadProbeOutputAsync($job.StandardOutput,1048576,$true)
        $err=[Mql5Coding.JobProcessLaunch]::ReadProbeOutputAsync($job.StandardError,1048576,$true)
        $job.Resume()
        $clock=[Diagnostics.Stopwatch]::StartNew();$done=$false
        do {
            if (($out.IsCompleted -and $out.Result.LimitExceeded) -or ($err.IsCompleted -and $err.Result.LimitExceeded)) {$answer.status='output_limit';break}
            $left=[int]($Seconds*1000-$clock.ElapsedMilliseconds)
            if ($left -le 0) {$answer.status='timed_out';break}
            $done=$job.WaitForExit([Math]::Min(100,$left))
        } while (-not $done)
        if ($done) {
            $answer.exit_code=$job.ExitCode
            if ($out.Wait(3000) -and $err.Wait(3000) -and -not $out.Result.LimitExceeded -and -not $err.Result.LimitExceeded) {
                $answer.stdout=$out.Result.Text;$answer.stderr=$err.Result.Text;$answer.status='completed'
            } else {$answer.status='output_limit'}
        }
    } finally {
        if ($null -ne $job) {
            try {$job.TerminateAndWaitForEmpty(5000)} catch {$answer.cleanup_verified=$false}
            finally {$job.Dispose()}
        }
    }
    return [pscustomobject]$answer
}
