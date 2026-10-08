#Requires -Version 5.1

# Internal path, process, staging, and artifact-integrity helpers for Invoke-Mt5TesterSmoke.ps1.
. (Join-Path $PSScriptRoot 'WindowsExecutableMetadata.ps1')

function ConvertTo-Hex {
    param([Parameter(Mandatory)][byte[]]$Bytes)
    return ([BitConverter]::ToString($Bytes) -replace '-', '').ToLowerInvariant()
}

function Get-BytesSha256 {
    param([Parameter(Mandatory)][byte[]]$Bytes)
    $algorithm = [Security.Cryptography.SHA256]::Create()
    try {
        return ConvertTo-Hex -Bytes $algorithm.ComputeHash($Bytes)
    }
    finally {
        $algorithm.Dispose()
    }
}

function Get-TextSha256 {
    param([Parameter(Mandatory)][string]$Text)
    return Get-BytesSha256 -Bytes ([Text.Encoding]::UTF8.GetBytes($Text))
}

function Get-FileSha256 {
    param([Parameter(Mandatory)][string]$Path)
    return (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash.ToLowerInvariant()
}

function Assert-SafeIniValue {
    param(
        [Parameter(Mandatory)][string]$Value,
        [Parameter(Mandatory)][string]$Name,
        [int]$MaximumLength = 260
    )
    if ([string]::IsNullOrWhiteSpace($Value) -or $Value.Length -gt $MaximumLength -or
        $Value -match '[\x00-\x1f\x7f=]') {
        throw "$Name contains unsupported characters or exceeds $MaximumLength characters."
    }
}

function ConvertTo-NormalizedDirectoryPath {
    param([Parameter(Mandatory)][string]$Path)

    $full = [IO.Path]::GetFullPath($Path)
    $root = [IO.Path]::GetPathRoot($full)
    if (-not [string]::IsNullOrWhiteSpace($root) -and
        $full.Length -gt $root.Length) {
        $full = $full.TrimEnd([char[]]@('\', '/'))
    }
    return $full
}

function Test-IsAbsoluteLocalDrivePath {
    param([Parameter(Mandatory)][string]$Path)

    return (
        -not [string]::IsNullOrWhiteSpace($Path) -and
        $Path -cmatch '\A[A-Za-z]:[\\/]'
    )
}

function Resolve-ExistingFile {
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][string]$Name,
        [Parameter(Mandatory)]$Tracker,
        [Parameter(Mandatory)][hashtable]$LeasesByPath
    )
    if (-not (Test-IsAbsoluteLocalDrivePath -Path $Path)) {
        throw "$Name must be an absolute path."
    }
    $full = [IO.Path]::GetFullPath($Path)
    Assert-StableFixedLocalVolumePath -Path $full
    $null = Open-NonReparseFileLeaf `
        -Path $full `
        -Tracker $Tracker `
        -LeasesByPath $LeasesByPath
    return $full
}

function Assert-StableFixedLocalVolumePath {
    param([Parameter(Mandatory)][string]$Path)

    $volumeIdentityCacheVariable = Get-Variable `
        -Name 'fixedLocalVolumeIdentities' `
        -Scope Script `
        -ErrorAction SilentlyContinue
    if (
        $null -eq $volumeIdentityCacheVariable -or
        $null -eq $volumeIdentityCacheVariable.Value
    ) {
        $script:fixedLocalVolumeIdentities = @{}
    }

    $full = [IO.Path]::GetFullPath($Path)
    try {
        $identity = [Mql5Coding.JobProcessLaunch]::GetFixedLocalVolumeIdentity(
            $full
        )
    }
    catch {
        throw "BLOCKED: Security-sensitive paths must use a direct fixed local volume: $full. $($_.Exception.Message)"
    }

    $rootKey = ([IO.Path]::GetPathRoot($full)).ToUpperInvariant()
    if ($script:fixedLocalVolumeIdentities.ContainsKey($rootKey)) {
        if ([string]$script:fixedLocalVolumeIdentities[$rootKey] -cne
            [string]$identity) {
            throw "BLOCKED: The local-volume mapping changed during tester validation: $rootKey"
        }
    }
    else {
        $script:fixedLocalVolumeIdentities[$rootKey] = $identity
    }
}

function Open-NonReparseDirectoryChain {
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)]$Tracker,
        [Parameter(Mandatory)][hashtable]$LeasesByPath,
        [switch]$AllowChildWrites
    )

    if (-not (Test-IsAbsoluteLocalDrivePath -Path $Path)) {
        throw "BLOCKED: Security-sensitive directories must use absolute local-drive paths: $Path"
    }
    $full = ConvertTo-NormalizedDirectoryPath -Path $Path
    if ($full -cnotmatch '\A[A-Za-z]:\\') {
        throw "BLOCKED: UNC, device, and drive-relative paths are not supported for security-sensitive tester paths: $full"
    }
    Assert-StableFixedLocalVolumePath -Path $full

    $root = [IO.Path]::GetPathRoot($full)
    $candidates = New-Object 'System.Collections.Generic.List[string]'
    $candidates.Add($root)
    $current = $root
    $relative = $full.Substring($root.Length)
    foreach ($component in @($relative -split '[\\/]' | Where-Object {
                -not [string]::IsNullOrWhiteSpace($_)
            })) {
        $current = Join-Path $current $component
        $candidates.Add((ConvertTo-NormalizedDirectoryPath -Path $current))
    }

    foreach ($candidate in $candidates) {
        Assert-StableFixedLocalVolumePath -Path $candidate
        $key = ConvertTo-NormalizedDirectoryPath -Path $candidate
        if ($LeasesByPath.ContainsKey($key)) {
            $existingLease = $LeasesByPath[$key]
            if (-not (ConvertTo-NormalizedDirectoryPath -Path (
                        [string]$existingLease.Path
                    )).Equals($candidate, [StringComparison]::Ordinal)) {
                throw "BLOCKED: A cached directory lease does not exactly match '$candidate'."
            }
            try {
                [Mql5Coding.JobProcessLaunch]::VerifyPathEntryLeaseVolume(
                    $candidate,
                    $existingLease
                )
            }
            catch {
                throw "BLOCKED: Directory volume binding changed for '$candidate': $($_.Exception.Message)"
            }
            continue
        }
        $lease = $null
        try {
            $lease = [Mql5Coding.JobProcessLaunch]::OpenDirectoryComponentLease(
                $candidate, [bool]$AllowChildWrites
            )
            Assert-StableFixedLocalVolumePath -Path $candidate
            [Mql5Coding.JobProcessLaunch]::VerifyPathEntryLeaseVolume(
                $candidate,
                $lease
            )
        }
        catch {
            if ($null -ne $lease) {
                $lease.Dispose()
            }
            throw "BLOCKED: Unsafe or unleaseable directory path component '$candidate': $($_.Exception.Message)"
        }
        $LeasesByPath[$key] = $lease
        $Tracker.Add($lease)
    }
    Assert-StableFixedLocalVolumePath -Path $full
    return $LeasesByPath[$full]
}

function Open-NonReparseFileLeaf {
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)]$Tracker,
        [Parameter(Mandatory)][hashtable]$LeasesByPath,
        [switch]$AllowDirectoryWrites
    )

    if (-not (Test-IsAbsoluteLocalDrivePath -Path $Path)) {
        throw "BLOCKED: Security-sensitive files must use absolute local-drive paths: $Path"
    }
    $full = [IO.Path]::GetFullPath($Path)
    Assert-StableFixedLocalVolumePath -Path $full
    $parent = [IO.Path]::GetDirectoryName($full)
    $null = Open-NonReparseDirectoryChain -Path $parent -Tracker $Tracker -LeasesByPath $LeasesByPath -AllowChildWrites:$AllowDirectoryWrites

    $key = $full
    if ($LeasesByPath.ContainsKey($key)) {
        $existingLease = $LeasesByPath[$key]
        if (-not ([IO.Path]::GetFullPath(
                    [string]$existingLease.Path
                )).Equals($full, [StringComparison]::Ordinal)) {
            throw "BLOCKED: A cached file lease does not exactly match '$full'."
        }
        Assert-StableFixedLocalVolumePath -Path $full
        try {
            [Mql5Coding.JobProcessLaunch]::VerifyPathEntryLeaseVolume(
                $full,
                $existingLease
            )
        }
        catch {
            throw "BLOCKED: File volume binding changed for '$full': $($_.Exception.Message)"
        }
        return $existingLease
    }
    $lease = $null
    try {
        $lease = [Mql5Coding.JobProcessLaunch]::OpenFileLeafLease($full)
        Assert-StableFixedLocalVolumePath -Path $full
        [Mql5Coding.JobProcessLaunch]::VerifyPathEntryLeaseVolume(
            $full,
            $lease
        )
    }
    catch {
        if ($null -ne $lease) {
            $lease.Dispose()
        }
        throw "BLOCKED: Unsafe or unleaseable file path '$full': $($_.Exception.Message)"
    }
    $LeasesByPath[$key] = $lease
    $Tracker.Add($lease)
    return $lease
}

function Try-OpenNonReparseFileLeaf {
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)]$Tracker,
        [Parameter(Mandatory)][hashtable]$LeasesByPath
    )

    if (-not (Test-IsAbsoluteLocalDrivePath -Path $Path)) {
        throw "BLOCKED: Security-sensitive files must use absolute local-drive paths: $Path"
    }
    $full = [IO.Path]::GetFullPath($Path)
    Assert-StableFixedLocalVolumePath -Path $full
    $parent = [IO.Path]::GetDirectoryName($full)
    $null = Open-NonReparseDirectoryChain -Path $parent -Tracker $Tracker -LeasesByPath $LeasesByPath

    $key = $full
    if ($LeasesByPath.ContainsKey($key)) {
        $existingLease = $LeasesByPath[$key]
        if (-not ([IO.Path]::GetFullPath(
                    [string]$existingLease.Path
                )).Equals($full, [StringComparison]::Ordinal)) {
            throw "BLOCKED: A cached optional-file lease does not exactly match '$full'."
        }
        Assert-StableFixedLocalVolumePath -Path $full
        try {
            [Mql5Coding.JobProcessLaunch]::VerifyPathEntryLeaseVolume(
                $full,
                $existingLease
            )
        }
        catch {
            throw "BLOCKED: File volume binding changed for '$full': $($_.Exception.Message)"
        }
        return $existingLease
    }

    $lease = $null
    try {
        $lease = [Mql5Coding.JobProcessLaunch]::TryOpenFileLeafLease($full)
        if ($null -eq $lease) {
            return $null
        }
        Assert-StableFixedLocalVolumePath -Path $full
        [Mql5Coding.JobProcessLaunch]::VerifyPathEntryLeaseVolume(
            $full,
            $lease
        )
    }
    catch {
        if ($null -ne $lease) {
            $lease.Dispose()
        }
        throw "BLOCKED: Unsafe or unleaseable file path '$full': $($_.Exception.Message)"
    }
    $LeasesByPath[$key] = $lease
    $Tracker.Add($lease)
    return $lease
}

function Open-OrCreateNonReparseDirectory {
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)]$Tracker,
        [Parameter(Mandatory)][hashtable]$LeasesByPath
    )

    if (-not (Test-IsAbsoluteLocalDrivePath -Path $Path)) {
        throw "BLOCKED: Security-sensitive directories must use absolute local-drive paths: $Path"
    }
    $full = ConvertTo-NormalizedDirectoryPath -Path $Path
    Assert-StableFixedLocalVolumePath -Path $full
    $parent = [IO.Path]::GetDirectoryName($full)
    if ([string]::IsNullOrWhiteSpace($parent)) {
        throw "BLOCKED: A non-root directory path is required: $full"
    }
    $null = Open-NonReparseDirectoryChain -Path $parent -Tracker $Tracker -LeasesByPath $LeasesByPath
    $created = [Mql5Coding.JobProcessLaunch]::TryCreateDirectory($full)
    $lease = Open-NonReparseDirectoryChain -Path $full -Tracker $Tracker -LeasesByPath $LeasesByPath
    return [pscustomobject]@{
        created = [bool]$created
        lease = $lease
        path = $full
    }
}

function Open-NewMutableOutputFileReservation {
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)]$Tracker,
        [Parameter(Mandatory)][hashtable]$LeasesByPath
    )

    if (-not (Test-IsAbsoluteLocalDrivePath -Path $Path)) {
        throw "BLOCKED: Mutable output reservations must use absolute local-drive paths: $Path"
    }
    $full = [IO.Path]::GetFullPath($Path)
    Assert-StableFixedLocalVolumePath -Path $full
    $parent = [IO.Path]::GetDirectoryName($full)
    $null = Open-NonReparseDirectoryChain -Path $parent -Tracker $Tracker -LeasesByPath $LeasesByPath

    $key = $full
    if ($LeasesByPath.ContainsKey($key)) {
        throw "A mutable output reservation already exists: $full"
    }

    $lease = $null
    try {
        $lease = [Mql5Coding.JobProcessLaunch]::CreateMutableOutputFileLease($full)
        Assert-StableFixedLocalVolumePath -Path $full
        [Mql5Coding.JobProcessLaunch]::VerifyPathEntryLeaseVolume($full, $lease)
    }
    catch {
        if ($null -ne $lease) {
            $lease.Dispose()
        }
        throw "BLOCKED: Could not reserve a stable mutable output file '$full': $($_.Exception.Message)"
    }

    $LeasesByPath[$key] = $lease
    $Tracker.Add($lease)
    return $lease
}

function Open-DirectoryMutationGuard {
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)]$DirectoryLease,
        [Parameter(Mandatory)]$Tracker,
        [Parameter(Mandatory)][hashtable]$GuardsByPath,
        [Parameter(Mandatory)][string]$RunId
    )

    $full = ConvertTo-NormalizedDirectoryPath -Path $Path
    $key = $full
    if ($GuardsByPath.ContainsKey($key)) {
        $existingGuard = $GuardsByPath[$key]
        if (-not (ConvertTo-NormalizedDirectoryPath -Path (
                    [string]$existingGuard.directory_path
                )).Equals($full, [StringComparison]::Ordinal)) {
            throw "BLOCKED: A cached directory mutation guard does not exactly match '$full'."
        }
        return $existingGuard
    }
    if (-not [bool]$DirectoryLease.IsDirectory -or
        -not ([IO.Path]::GetFullPath([string]$DirectoryLease.Path)).Equals(
            $full,
            [StringComparison]::Ordinal
        )) {
        throw "BLOCKED: A matching directory lease is required before creating a mutation guard: $full"
    }

    $guardLeaf = '.mcg-' + [guid]::NewGuid().ToString('N').Substring(0, 8) + '.tmp'
    $guardPath = Join-Path $full $guardLeaf
    if ($guardPath.Length -gt 259) {
        throw "BLOCKED: The directory mutation-guard path exceeds 259 characters: $guardPath"
    }

    $stream = $null
    try {
        $stream = New-Object IO.FileStream(
            $guardPath,
            [IO.FileMode]::CreateNew,
            [IO.FileAccess]::ReadWrite,
            [IO.FileShare]::Read,
            4096,
            [IO.FileOptions]::DeleteOnClose
        )
        $bytes = [Text.Encoding]::UTF8.GetBytes($RunId)
        $stream.Write($bytes, 0, $bytes.Length)
        $stream.Flush($true)

        $DirectoryLease.VerifyStillNonReparseDirectory()
        $handleIdentity = [Mql5Coding.JobProcessLaunch]::GetFileIdentity(
            $stream.SafeFileHandle
        )
        $pathIdentity = [Mql5Coding.JobProcessLaunch]::GetNonReparseGuardFileIdentity(
            $guardPath
        )
        if ([string]$handleIdentity -cne [string]$pathIdentity) {
            throw 'The directory mutation guard did not remain bound to its leased directory.'
        }
        $DirectoryLease.VerifyStillNonReparseDirectory()

        $record = [pscustomobject][ordered]@{
            directory_path = $full
            path = $guardPath
            file_identity = $handleIdentity
            stream = $stream
        }
        $GuardsByPath[$key] = $record
        $Tracker.Add($record)
        return $record
    }
    catch {
        if ($null -ne $stream) {
            $stream.Dispose()
        }
        throw "BLOCKED: Could not pin a nonempty leased directory '$full': $($_.Exception.Message)"
    }
}

function Assert-ExpectedApplicationMarker {
    param(
        [Parameter(Mandatory)][string]$Marker,
        [Parameter(Mandatory)][string]$SourceName
    )

    if ($Marker -cnotmatch '\AMQL5_CODING_PASS:[0-9A-Fa-f]{32,64}(?::[A-Za-z0-9_.-]{1,64})?\z') {
        throw (
            "$SourceName must use the case-sensitive pass protocol " +
            "'MQL5_CODING_PASS:<32-64 hex nonce>[:optional-label]'."
        )
    }
}

function Read-ExpectedApplicationMarkerFile {
    param([Parameter(Mandatory)][string]$Path)

    $stream = [IO.File]::Open($Path, [IO.FileMode]::Open, [IO.FileAccess]::Read, [IO.FileShare]::Read)
    try {
        if ($stream.Length -gt 65536) {
            throw 'ExpectedLogMarkerFile cannot exceed 65536 bytes.'
        }
        $bytes = New-Object byte[] ([int]$stream.Length)
        $read = 0
        while ($read -lt $bytes.Length) {
            $got = $stream.Read($bytes, $read, $bytes.Length - $read)
            if ($got -le 0) {
                throw 'ExpectedLogMarkerFile ended before its declared byte length was read.'
            }
            $read += $got
        }
    }
    finally {
        $stream.Dispose()
    }
    $strictUtf8 = New-Object Text.UTF8Encoding($false, $true)
    $offset = 0
    if ($bytes.Length -ge 3 -and $bytes[0] -eq 0xef -and $bytes[1] -eq 0xbb -and $bytes[2] -eq 0xbf) {
        $offset = 3
    }
    $text = $strictUtf8.GetString($bytes, $offset, $bytes.Length - $offset)
    $markers = New-Object 'System.Collections.Generic.List[string]'
    foreach ($marker in ($text -split '\r\n|\n|\r')) {
        if ([string]::IsNullOrWhiteSpace($marker)) {
            continue
        }
        Assert-ExpectedApplicationMarker -Marker $marker -SourceName 'Each non-empty ExpectedLogMarkerFile line'
        $markers.Add($marker)
    }
    if ($markers.Count -eq 0) {
        throw 'ExpectedLogMarkerFile contains no non-empty markers.'
    }
    return [pscustomobject]@{bytes = $bytes; markers = $markers.ToArray()}
}

function Assert-ExpectedApplicationMarkerSet {
    param([Parameter(Mandatory)][AllowEmptyCollection()][string[]]$Markers)

    if ($Markers.Count -gt 64) {
        throw 'No more than 64 unique expected log markers are allowed.'
    }
    $characterCount = 0
    foreach ($marker in $Markers) {
        $characterCount += $marker.Length
    }
    if ($characterCount -gt 8192) {
        throw 'Expected log markers cannot exceed 8192 aggregate characters.'
    }
}

function ConvertFrom-TerminalOriginText {
    param(
        [Parameter(Mandatory)][string]$Text,
        [Parameter(Mandatory)][string]$SourcePath
    )

    $origin = $Text.Trim()
    if ([string]::IsNullOrWhiteSpace($origin) -or
        $origin -match '[\r\n]' -or
        -not (Test-IsAbsoluteLocalDrivePath -Path $origin)) {
        throw "Terminal origin file must contain exactly one absolute install-directory path: $SourcePath"
    }
    return [IO.Path]::GetFullPath($origin)
}

function Read-TerminalOrigin {
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)]$Lease
    )

    $full = [IO.Path]::GetFullPath($Path)
    if ($null -eq $Lease -or [bool]$Lease.IsDirectory -or
        -not ([IO.Path]::GetFullPath([string]$Lease.Path)).Equals(
            $full,
            [StringComparison]::Ordinal
        )) {
        throw "A matching no-follow file lease is required before reading terminal origin: $full"
    }

    $stream = [IO.File]::Open(
        $full,
        [IO.FileMode]::Open,
        [IO.FileAccess]::Read,
        [IO.FileShare]::Read
    )
    try {
        $streamIdentity = [Mql5Coding.JobProcessLaunch]::GetFileIdentity(
            $stream.SafeFileHandle
        )
        if ([string]$streamIdentity -cne [string]$Lease.Identity) {
            throw "Terminal origin path changed while its file lease was held: $full"
        }
        if ([long]$stream.Length -le 0 -or [long]$stream.Length -gt 32768) {
            throw "Terminal origin file must contain 1-32768 bytes: $full"
        }
        $strictUtf8 = New-Object Text.UTF8Encoding($false, $true)
        $reader = New-Object IO.StreamReader(
            $stream,
            $strictUtf8,
            $true,
            1024,
            $true
        )
        try {
            $text = $reader.ReadToEnd()
        }
        finally {
            $reader.Dispose()
        }
        return ConvertFrom-TerminalOriginText -Text $text -SourcePath $full
    }
    finally {
        $stream.Dispose()
    }
}

function Resolve-TerminalBinding {
    param(
        [string]$RequestedTerminalPath,
        [string]$RequestedDataPath,
        [Parameter(Mandatory)]$Tracker,
        [Parameter(Mandatory)][hashtable]$LeasesByPath
    )

    $terminal = $null
    $data = $null

    if (-not [string]::IsNullOrWhiteSpace($RequestedTerminalPath)) {
        $terminal = Resolve-ExistingFile -Path $RequestedTerminalPath -Name 'TerminalPath' -Tracker $Tracker -LeasesByPath $LeasesByPath
        if ([IO.Path]::GetFileName($terminal) -ine 'terminal64.exe') {
            throw "TerminalPath must identify terminal64.exe: $terminal"
        }
        Assert-Mql5Terminal $terminal | Out-Null
    }

    if (-not [string]::IsNullOrWhiteSpace($RequestedDataPath)) {
        if (-not (Test-IsAbsoluteLocalDrivePath -Path $RequestedDataPath)) {
            throw 'TerminalDataPath must be an absolute path.'
        }
        $data = ConvertTo-NormalizedDirectoryPath -Path $RequestedDataPath
        $null = Open-NonReparseDirectoryChain -Path $data -Tracker $Tracker -LeasesByPath $LeasesByPath
    }

    $terminalDataRoot = Join-Path ([Environment]::GetFolderPath('ApplicationData')) 'MetaQuotes\Terminal'
    if ($null -eq $data) {
        $null = Open-NonReparseDirectoryChain -Path $terminalDataRoot -Tracker $Tracker -LeasesByPath $LeasesByPath
        $matchingTerminals = New-Object 'System.Collections.Generic.List[object]'
        foreach ($directory in Get-ChildItem -LiteralPath $terminalDataRoot -Directory) {
            $candidateData = [IO.Path]::GetFullPath($directory.FullName)
            $null = Open-NonReparseDirectoryChain -Path $candidateData -Tracker $Tracker -LeasesByPath $LeasesByPath
            $originPath = Join-Path $candidateData 'origin.txt'
            $originLease = Try-OpenNonReparseFileLeaf -Path $originPath -Tracker $Tracker -LeasesByPath $LeasesByPath
            if ($null -eq $originLease) {
                continue
            }
            try {
                $origin = Read-TerminalOrigin -Path $originPath -Lease $originLease
            }
            catch {
                continue
            }

            if ($null -eq $terminal) {
                $candidateTerminal = [IO.Path]::GetFullPath(
                    (Join-Path $origin 'terminal64.exe')
                )
                $candidateTerminalLease = Try-OpenNonReparseFileLeaf -Path $candidateTerminal -Tracker $Tracker -LeasesByPath $LeasesByPath
                if ($null -eq $candidateTerminalLease) {
                    continue
                }
                # Automatic discovery excludes non-MT5 images before deciding
                # whether the remaining installation/data bindings are unique.
                try {Assert-Mql5Terminal $candidateTerminal | Out-Null}
                catch {continue}
                $matchingTerminals.Add([pscustomobject]@{
                    data = $candidateData
                    terminal = $candidateTerminal
                })
            }
            else {
                $terminalInstall = [IO.Path]::GetFullPath(
                    (Split-Path -Parent $terminal)
                ).TrimEnd('\', '/')
                try {
                    $originInstallLease = Open-NonReparseDirectoryChain `
                        -Path $origin `
                        -Tracker $Tracker `
                        -LeasesByPath $LeasesByPath
                    $terminalInstallLease = Open-NonReparseDirectoryChain `
                        -Path $terminalInstall `
                        -Tracker $Tracker `
                        -LeasesByPath $LeasesByPath
                }
                catch {
                    continue
                }
                if ([string]$originInstallLease.Identity -ceq
                    [string]$terminalInstallLease.Identity) {
                    $matchingTerminals.Add([pscustomobject]@{
                        data = $candidateData
                        terminal = $terminal
                    })
                }
            }
        }

        if ($matchingTerminals.Count -eq 0) {
            throw 'No terminal data directory with a matching origin.txt was found.'
        }
        if ($matchingTerminals.Count -gt 1) {
            $candidatePaths = @($matchingTerminals | ForEach-Object { $_.data })
            throw "Terminal data discovery is ambiguous: $($candidatePaths -join '; ')"
        }
        $data = [IO.Path]::GetFullPath([string]$matchingTerminals[0].data)
        if ($null -eq $terminal) {
            $terminal = [IO.Path]::GetFullPath([string]$matchingTerminals[0].terminal)
        }
    }

    $null = Open-NonReparseDirectoryChain -Path $data -Tracker $Tracker -LeasesByPath $LeasesByPath
    $originPath = Join-Path $data 'origin.txt'
    $originFileLease = Open-NonReparseFileLeaf -Path $originPath -Tracker $Tracker -LeasesByPath $LeasesByPath
    $origin = Read-TerminalOrigin -Path $originPath -Lease $originFileLease
    if ($null -eq $terminal) {
        $terminal = Resolve-ExistingFile -Path (Join-Path $origin 'terminal64.exe') -Name 'terminal64.exe from origin.txt' -Tracker $Tracker -LeasesByPath $LeasesByPath
    }
    else {
        $null = Open-NonReparseFileLeaf -Path $terminal -Tracker $Tracker -LeasesByPath $LeasesByPath
    }

    $terminalInstall = [IO.Path]::GetFullPath(
        (Split-Path -Parent $terminal)
    ).TrimEnd('\', '/')
    $originInstallLease = Open-NonReparseDirectoryChain `
        -Path $origin `
        -Tracker $Tracker `
        -LeasesByPath $LeasesByPath
    $terminalInstallLease = Open-NonReparseDirectoryChain `
        -Path $terminalInstall `
        -Tracker $Tracker `
        -LeasesByPath $LeasesByPath
    if ([string]$originInstallLease.Identity -cne
        [string]$terminalInstallLease.Identity) {
        throw "TerminalDataPath belongs to '$origin', not to '$terminal'."
    }

    foreach ($requiredDirectory in @(
            (Join-Path $data 'MQL5'),
            (Join-Path $data 'Tester'),
            (Join-Path $data 'logs')
        )) {
        $null = Open-NonReparseDirectoryChain -Path $requiredDirectory -Tracker $Tracker -LeasesByPath $LeasesByPath
    }

    Assert-Mql5Terminal $terminal | Out-Null

    return [pscustomobject][ordered]@{
        terminal_path = [IO.Path]::GetFullPath($terminal)
        terminal_data_path = [IO.Path]::GetFullPath($data)
        terminal_install_path = [IO.Path]::GetFullPath($origin)
        terminal_install_identity = [string]$originInstallLease.Identity
    }
}

function Get-FileIdentityFromPath {
    param([Parameter(Mandatory)][string]$Path)

    $temporaryLeases = New-Object 'System.Collections.Generic.List[object]'
    $temporaryLeasesByPath = [System.Collections.Hashtable]::new(
        [System.StringComparer]::Ordinal
    )
    try {
        $lease = Open-NonReparseFileLeaf -Path $Path -Tracker $temporaryLeases -LeasesByPath $temporaryLeasesByPath
        return [string]$lease.Identity
    }
    finally {
        for ($index = $temporaryLeases.Count - 1; $index -ge 0; $index--) {
            $temporaryLeases[$index].Dispose()
        }
    }
}

function Get-NativeProcessImageObservation {
    param(
        [Parameter(Mandatory)][int]$ProcessId,
        [Parameter(Mandatory)][string]$ExpectedVolumePath
    )

    [string]$translatedPath = ''
    try {
        $onExpectedVolume = [Mql5Coding.JobProcessLaunch]::TryGetProcessImagePathOnFixedVolume(
                $ProcessId,
                $ExpectedVolumePath,
                [ref]$translatedPath
            )
    }
    catch {
        return [pscustomobject][ordered]@{
            query_succeeded = $false
            on_expected_volume = $false
            identity_resolved = $false
            executable_path = $null
            file_identity = $null
            error = $_.Exception.Message
        }
    }

    if (-not $onExpectedVolume) {
        return [pscustomobject][ordered]@{
            query_succeeded = $true
            on_expected_volume = $false
            identity_resolved = $false
            executable_path = $null
            file_identity = $null
            error = $null
        }
    }

    try {
        $identity = Get-FileIdentityFromPath -Path $translatedPath
        return [pscustomobject][ordered]@{
            query_succeeded = $true
            on_expected_volume = $true
            identity_resolved = $true
            executable_path = [IO.Path]::GetFullPath($translatedPath)
            file_identity = [string]$identity
            error = $null
        }
    }
    catch {
        return [pscustomobject][ordered]@{
            query_succeeded = $true
            on_expected_volume = $true
            identity_resolved = $false
            executable_path = [IO.Path]::GetFullPath($translatedPath)
            file_identity = $null
            error = $_.Exception.Message
        }
    }
}

function Open-TerminalImageReadLock {
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)]$Tracker
    )

    $stream = $null
    try {
        $stream = [IO.File]::Open(
            $Path,
            [IO.FileMode]::Open,
            [IO.FileAccess]::Read,
            [IO.FileShare]::Read
        )
        if ([long]$stream.Length -le 0) {
            throw "Terminal executable is empty: $Path"
        }
        # Read sharing only pins the exact image against writes and replacement.
        # Recheck metadata now; discovery's earlier read was point-in-time.
        Assert-Mql5Terminal $Path | Out-Null

        $record = [pscustomobject][ordered]@{
            kind = 'terminal executable'
            destination_path = [IO.Path]::GetFullPath($Path)
            byte_length = [long]$stream.Length
            sha256 = Get-StreamSha256 -Stream $stream
            file_identity = [Mql5Coding.JobProcessLaunch]::GetFileIdentity(
                $stream.SafeFileHandle
            )
            verified = $true
        }
        $Tracker.Add([pscustomobject][ordered]@{
            record = $record
            stream = $stream
        })
        $stream = $null
        return $record
    }
    finally {
        if ($null -ne $stream) {
            $stream.Dispose()
        }
    }
}

function Wait-ForNoMatchingTerminalProcesses {
    param(
        [Parameter(Mandatory)][string]$ExecutablePath,
        [Parameter(Mandatory)][string]$ExpectedFileIdentity,
        [Parameter(Mandatory)]$VerifiedOwnedProcessIdentity,
        [ValidateRange(0, 60000)][int]$TimeoutMilliseconds = 5000,
        [ValidateRange(0, 1000)][int]$PollMilliseconds = 100
    )

    if (
        $null -eq $VerifiedOwnedProcessIdentity.creation_utc_ticks -or
        $null -eq $VerifiedOwnedProcessIdentity.session_id -or
        [string]$VerifiedOwnedProcessIdentity.executable_file_identity -cne
            $ExpectedFileIdentity
    ) {
        throw 'Cannot retry post-exit process discovery without the verified owned process identity.'
    }

    $deadline = [DateTime]::UtcNow.AddMilliseconds($TimeoutMilliseconds)
    while ($true) {
        # Inspection failures remain immediate blockers. Only an exact row for
        # the already verified owned process is eligible for bounded settling.
        $matchedProcesses = @(
            Get-MatchingTerminalProcesses `
                -ExecutablePath $ExecutablePath `
                -ExpectedFileIdentity $ExpectedFileIdentity `
                -SettlingOwnedIdentity $VerifiedOwnedProcessIdentity
        )
        if ($matchedProcesses.Count -eq 0) {
            return @()
        }

        $foreignMatch = @(
            $matchedProcesses | Where-Object {
                if ([bool]$_.identity_unresolved) {
                    return (
                        [int]$_.process_id -ne
                            [int]$VerifiedOwnedProcessIdentity.process_id
                    )
                }
                return (
                    [int]$_.process_id -ne
                        [int]$VerifiedOwnedProcessIdentity.process_id -or
                    $null -eq $_.creation_utc_ticks -or
                    [long]$_.creation_utc_ticks -ne
                        [long]$VerifiedOwnedProcessIdentity.creation_utc_ticks -or
                    $null -eq $_.session_id -or
                    [int]$_.session_id -ne
                        [int]$VerifiedOwnedProcessIdentity.session_id -or
                    [string]$_.executable_file_identity -cne
                        [string]$VerifiedOwnedProcessIdentity.executable_file_identity
                )
            }
        )
        if ($foreignMatch.Count -gt 0) {
            return $matchedProcesses
        }

        if ([DateTime]::UtcNow -ge $deadline) {
            return $matchedProcesses
        }
        if ($PollMilliseconds -gt 0) {
            Start-Sleep -Milliseconds $PollMilliseconds
        }
    }
}

function Get-MatchingTerminalProcesses {
    param(
        [Parameter(Mandatory)][string]$ExecutablePath,
        [Parameter(Mandatory)][string]$ExpectedFileIdentity,
        $TrustedSuspendedIdentity,
        $SettlingOwnedIdentity
    )
    if (
        $null -ne $TrustedSuspendedIdentity -and
        $null -ne $SettlingOwnedIdentity
    ) {
        throw 'Process discovery cannot use suspended and settling identities together.'
    }

    $wanted = [IO.Path]::GetFullPath($ExecutablePath)
    $wantedLeaf = [IO.Path]::GetFileName($wanted)
    $suspendedVerifiedPath = $null
    if ($null -ne $TrustedSuspendedIdentity) {
        $suspendedVerifiedPath = [IO.Path]::GetFullPath(
            [string]$TrustedSuspendedIdentity.executable_path
        )
        if (
            [IO.Path]::GetFileName($suspendedVerifiedPath) -ine $wantedLeaf -or
            [string]$TrustedSuspendedIdentity.executable_file_identity -cne
                $ExpectedFileIdentity
        ) {
            throw 'The trusted suspended process identity does not match the selected terminal image.'
        }
    }
    $settlingVerifiedPath = $null
    if ($null -ne $SettlingOwnedIdentity) {
        $settlingVerifiedPath = [IO.Path]::GetFullPath(
            [string]$SettlingOwnedIdentity.executable_path
        )
        if (
            [IO.Path]::GetFileName($settlingVerifiedPath) -ine $wantedLeaf -or
            [string]$SettlingOwnedIdentity.executable_file_identity -cne
                $ExpectedFileIdentity
        ) {
            throw 'The settling process identity does not match the selected terminal image.'
        }
    }

    $matchingProcesses = New-Object 'System.Collections.Generic.List[object]'
    $unknown = New-Object 'System.Collections.Generic.List[int]'

    try {
        # Enumerate all process images so a hard-link, junction, symlink, or
        # short-path alias cannot evade the selected executable's file identity.
        $processes = @(Get-CimInstance -ClassName Win32_Process)
    }
    catch {
        throw "BLOCKED: Cannot safely inspect running process images: $($_.Exception.Message)"
    }

    foreach ($process in $processes) {
        $processId = [int]$process.ProcessId
        $processName = [string]$process.Name
        $processNameAvailable = -not [string]::IsNullOrWhiteSpace($processName)
        $sameLeafName = (
            $processNameAvailable -and
            $processName.Equals(
                $wantedLeaf,
                [StringComparison]::OrdinalIgnoreCase
            )
        )

        $creationTicks = $null
        try {
            if ($process.CreationDate -is [datetime]) {
                $creationTicks = [long]$process.CreationDate.ToUniversalTime().Ticks
            }
        }
        catch {
            $creationTicks = $null
        }
        $sessionId = $null
        try {
            $observedSessionId = $process.SessionId
            if ($null -ne $observedSessionId) {
                $sessionId = [int]$observedSessionId
            }
        }
        catch {
            $sessionId = $null
        }

        # The live suspended PID and image were already verified through owned
        # native handles. CIM may hide fields until that process is resumed.
        $suspendedProcessIdMatch = (
            $null -ne $TrustedSuspendedIdentity -and
            $processId -eq [int]$TrustedSuspendedIdentity.process_id
        )
        $suspendedIdentityCompatible = (
            $suspendedProcessIdMatch -and
            (
                -not $processNameAvailable -or
                $sameLeafName
            )
        )
        $suspendedMatchRecord = if ($suspendedIdentityCompatible) {
            [pscustomobject][ordered]@{
                process_id = $processId
                parent_process_id = [int]$process.ParentProcessId
                creation_utc_ticks = if ($null -ne $creationTicks) {
                    $creationTicks
                }
                else {
                    [long]$TrustedSuspendedIdentity.creation_utc_ticks
                }
                session_id = if ($null -ne $sessionId) {
                    $sessionId
                }
                else {
                    [int]$TrustedSuspendedIdentity.session_id
                }
                creation_cim_observed = [bool]($null -ne $creationTicks)
                session_cim_observed = [bool]($null -ne $sessionId)
                executable_path = $suspendedVerifiedPath
                executable_file_identity = $ExpectedFileIdentity
                identity_match = $true
                path_match = $true
                identity_unresolved = $false
            }
        }
        else {
            $null
        }

        # After verified Job Object emptiness, an owned row can briefly outlive
        # readable CIM fields. Missing fields may settle; positive mismatches may not.
        $settlingProcessIdMatch = (
            $null -ne $SettlingOwnedIdentity -and
            $processId -eq [int]$SettlingOwnedIdentity.process_id
        )
        $settlingIdentityCompatible = (
            $settlingProcessIdMatch -and
            (
                -not $processNameAvailable -or
                $sameLeafName
            ) -and
            (
                $null -eq $creationTicks -or
                -not [bool]$SettlingOwnedIdentity.creation_cim_observed -or
                $creationTicks -eq [long]$SettlingOwnedIdentity.creation_utc_ticks
            ) -and
            (
                $null -eq $sessionId -or
                -not [bool]$SettlingOwnedIdentity.session_cim_observed -or
                $sessionId -eq [int]$SettlingOwnedIdentity.session_id
            )
        )
        $settlingIdentityComplete = (
            $settlingIdentityCompatible -and
            [bool]$SettlingOwnedIdentity.creation_cim_observed -and
            [bool]$SettlingOwnedIdentity.session_cim_observed -and
            $null -ne $creationTicks -and
            $null -ne $sessionId
        )
        $settlingMatchRecord = if ($settlingIdentityCompatible) {
            [pscustomobject][ordered]@{
                process_id = $processId
                parent_process_id = [int]$process.ParentProcessId
                creation_utc_ticks = $creationTicks
                session_id = $sessionId
                creation_cim_observed = [bool]$SettlingOwnedIdentity.creation_cim_observed
                session_cim_observed = [bool]$SettlingOwnedIdentity.session_cim_observed
                executable_path = $settlingVerifiedPath
                executable_file_identity = $ExpectedFileIdentity
                identity_match = $false
                path_match = $false
                identity_unresolved = $true
            }
        }
        else {
            $null
        }

        try {
            $path = [string]$process.ExecutablePath
        }
        catch {
            $path = ''
        }

        $reportedCandidate = $null
        $reportedIdentityError = $null
        $candidate = $null
        $candidateIdentity = $null
        $identityResolved = $false
        if (-not [string]::IsNullOrWhiteSpace($path)) {
            try {
                $reportedCandidate = [IO.Path]::GetFullPath($path)
                $candidate = $reportedCandidate
                $candidateIdentity = Get-FileIdentityFromPath -Path $reportedCandidate
                $identityResolved = $true
            }
            catch {
                $reportedIdentityError = $_.Exception.Message
            }
        }

        $nativeObservation = $null
        if (-not $identityResolved) {
            $nativeObservation = Get-NativeProcessImageObservation `
                -ProcessId $processId `
                -ExpectedVolumePath $wanted
            if ([bool]$nativeObservation.identity_resolved) {
                $candidate = [IO.Path]::GetFullPath(
                    [string]$nativeObservation.executable_path
                )
                $candidateIdentity = [string]$nativeObservation.file_identity
                $identityResolved = $true
            }
        }

        if (-not $identityResolved) {
            $nativeVolumeContradiction = (
                $null -ne $nativeObservation -and
                [bool]$nativeObservation.query_succeeded -and
                -not [bool]$nativeObservation.on_expected_volume
            )
            $nativeReparseRejected = (
                $null -ne $nativeObservation -and
                [bool]$nativeObservation.query_succeeded -and
                [bool]$nativeObservation.on_expected_volume -and
                -not [bool]$nativeObservation.identity_resolved -and
                -not [string]::IsNullOrWhiteSpace(
                    [string]$nativeObservation.error
                ) -and
                [string]$nativeObservation.error -match
                    '(?i)\breparse(?:-point)?\b'
            )
            if ([string]::IsNullOrWhiteSpace($path)) {
                if (
                    $null -ne $suspendedMatchRecord -and
                    -not $nativeVolumeContradiction
                ) {
                    $matchingProcesses.Add($suspendedMatchRecord)
                }
                elseif (
                    $null -ne $settlingMatchRecord -and
                    -not $nativeVolumeContradiction
                ) {
                    $matchingProcesses.Add($settlingMatchRecord)
                }
                elseif (
                    -not $nativeVolumeContradiction -and
                    (
                        $sameLeafName -or
                        $suspendedProcessIdMatch -or
                        $settlingProcessIdMatch -or
                        $nativeReparseRejected
                    )
                ) {
                    $unknown.Add($processId)
                }
                continue
            }

            $pathMatches = (
                $null -ne $reportedCandidate -and
                $reportedCandidate.Equals(
                    $wanted,
                    [StringComparison]::OrdinalIgnoreCase
                )
            )
            $suspendedKnownPath = (
                $null -eq $reportedCandidate -or
                $pathMatches -or
                (
                    $null -ne $suspendedVerifiedPath -and
                    $reportedCandidate.Equals(
                        $suspendedVerifiedPath,
                        [StringComparison]::OrdinalIgnoreCase
                    )
                )
            )
            $settlingKnownPath = (
                $null -eq $reportedCandidate -or
                $pathMatches -or
                (
                    $null -ne $settlingVerifiedPath -and
                    $reportedCandidate.Equals(
                        $settlingVerifiedPath,
                        [StringComparison]::OrdinalIgnoreCase
                    )
                )
            )
            $reportedReparseRejected = (
                -not [string]::IsNullOrWhiteSpace($reportedIdentityError) -and
                $reportedIdentityError -match '(?i)\breparse(?:-point)?\b'
            )
            $sameVolumeReparseUnresolved = (
                $nativeReparseRejected -or
                (
                    $reportedReparseRejected -and
                    (
                        $null -eq $nativeObservation -or
                        -not [bool]$nativeObservation.query_succeeded -or
                        [bool]$nativeObservation.on_expected_volume
                    )
                )
            )
            if (
                $null -ne $suspendedMatchRecord -and
                $suspendedKnownPath -and
                -not $nativeVolumeContradiction
            ) {
                $matchingProcesses.Add($suspendedMatchRecord)
            }
            elseif (
                $null -ne $settlingMatchRecord -and
                $settlingKnownPath -and
                -not $nativeVolumeContradiction
            ) {
                $matchingProcesses.Add($settlingMatchRecord)
            }
            elseif (
                -not $nativeVolumeContradiction -and
                (
                    $sameLeafName -or
                    $pathMatches -or
                    $suspendedProcessIdMatch -or
                    $settlingProcessIdMatch -or
                    $sameVolumeReparseUnresolved
                )
            ) {
                $unknown.Add($processId)
            }
            continue
        }

        $pathMatch = (
            $candidate.Equals(
                $wanted,
                [StringComparison]::OrdinalIgnoreCase
            ) -or
            (
                $null -ne $reportedCandidate -and
                $reportedCandidate.Equals(
                    $wanted,
                    [StringComparison]::OrdinalIgnoreCase
                )
            )
        )
        $identityMatch = $candidateIdentity.Equals(
            $ExpectedFileIdentity,
            [StringComparison]::Ordinal
        )
        if ($suspendedProcessIdMatch) {
            if (
                $identityMatch -and
                $null -ne $suspendedMatchRecord
            ) {
                $matchingProcesses.Add($suspendedMatchRecord)
            }
            else {
                $unknown.Add($processId)
            }
        }
        elseif ($settlingProcessIdMatch) {
            if (
                -not $identityMatch -or
                $null -eq $settlingMatchRecord
            ) {
                $unknown.Add($processId)
            }
            elseif (-not $settlingIdentityComplete) {
                $matchingProcesses.Add($settlingMatchRecord)
            }
            else {
                $matchingProcesses.Add([pscustomobject][ordered]@{
                    process_id = $processId
                    parent_process_id = [int]$process.ParentProcessId
                    creation_utc_ticks = $creationTicks
                    session_id = $sessionId
                    creation_cim_observed = $true
                    session_cim_observed = $true
                    executable_path = $candidate
                    executable_file_identity = $candidateIdentity
                    identity_match = $true
                    path_match = [bool]$pathMatch
                    identity_unresolved = $false
                })
            }
        }
        elseif ($pathMatch -or $identityMatch) {
            $matchingProcesses.Add([pscustomobject][ordered]@{
                process_id = $processId
                parent_process_id = [int]$process.ParentProcessId
                creation_utc_ticks = $creationTicks
                session_id = $sessionId
                creation_cim_observed = [bool]($null -ne $creationTicks)
                session_cim_observed = [bool]($null -ne $sessionId)
                executable_path = $candidate
                executable_file_identity = $candidateIdentity
                identity_match = [bool]$identityMatch
                path_match = [bool]$pathMatch
                identity_unresolved = $false
            })
        }
    }

    if ($unknown.Count -gt 0) {
        throw "BLOCKED: Running terminal64.exe process identity is unreadable for PID(s) $($unknown -join ', '); refusing an unsafe launch."
    }
    return $matchingProcesses.ToArray()
}

function Open-DataDirectoryLock {
    param(
        [Parameter(Mandatory)][string]$TerminalDataPath,
        [Parameter(Mandatory)][string]$RunId
    )
    # Keep the lock inside the bound data directory. Textual path hashes can be
    # bypassed by reaching the same directory through a junction or symlink.
    $lockPath = Join-Path $TerminalDataPath '.mql5-coding-smoke.data-lock'
    try {
        $stream = New-Object IO.FileStream(
            $lockPath,
            [IO.FileMode]::CreateNew,
            [IO.FileAccess]::ReadWrite,
            [IO.FileShare]::None,
            4096,
            [IO.FileOptions]::DeleteOnClose
        )
    }
    catch [IO.IOException] {
        throw (
            'BLOCKED: Another MQL5 Coding smoke run owns the terminal data lock, ' +
            "or a stale lock remains after an abnormal shutdown. Do not remove it unless no matching run is active: $lockPath"
        )
    }

    try {
        $bytes = [Text.Encoding]::UTF8.GetBytes($RunId)
        $stream.SetLength(0)
        $stream.Write($bytes, 0, $bytes.Length)
        $stream.Flush()
        return [pscustomobject]@{ path = $lockPath; stream = $stream }
    }
    catch {
        $stream.Dispose()
        throw
    }
}

function Open-NewOutputDirectoryClaim {
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][string]$RunId,
        [Parameter(Mandatory)]$DirectoryLease,
        [Parameter(Mandatory)]$IntegrityTracker,
        [Parameter(Mandatory)]$PathEntryLeases,
        [Parameter(Mandatory)][hashtable]$LeasesByPath
    )

    $full = ConvertTo-NormalizedDirectoryPath -Path $Path
    if ($null -eq $DirectoryLease -or
        -not [bool]$DirectoryLease.IsDirectory -or
        -not (ConvertTo-NormalizedDirectoryPath -Path ([string]$DirectoryLease.Path)).Equals(
            $full,
            [StringComparison]::Ordinal
        )) {
        throw "OutputDirectory must have a matching live directory lease before it is claimed: $full"
    }
    $DirectoryLease.VerifyStillNonReparseDirectory()
    if (-not (Test-Path -LiteralPath $full -PathType Container)) {
        throw "OutputDirectory must be created and path-lease validated before it is claimed: $full"
    }
    if (@(Get-ChildItem -LiteralPath $full -Force).Count -ne 0) {
        throw "OutputDirectory was populated before exclusive ownership was established: $full"
    }

    $claimPath = Join-Path $full '.mql5-coding-smoke.claim'
    $ownerPath = Join-Path $full '.mql5-coding-smoke.owner'
    $stream = $null
    try {
        $stream = New-Object IO.FileStream(
            $claimPath,
            [IO.FileMode]::CreateNew,
            [IO.FileAccess]::ReadWrite,
            [IO.FileShare]::Read,
            4096,
            [IO.FileOptions]::DeleteOnClose
        )
        $entries = @(Get-ChildItem -LiteralPath $full -Force)
        if ($entries.Count -ne 1 -or
            -not ([IO.Path]::GetFullPath($entries[0].FullName)).Equals(
                [IO.Path]::GetFullPath($claimPath),
                [StringComparison]::OrdinalIgnoreCase
            )) {
            throw "OutputDirectory was populated before exclusive ownership was established: $full"
        }

        $bytes = [Text.Encoding]::UTF8.GetBytes($RunId)
        $stream.Write($bytes, 0, $bytes.Length)
        $stream.Flush($true)
        $DirectoryLease.VerifyStillNonReparseDirectory()
        $claimHandleIdentity = [Mql5Coding.JobProcessLaunch]::GetFileIdentity(
            $stream.SafeFileHandle
        )
        $claimPathIdentity = [Mql5Coding.JobProcessLaunch]::GetNonReparseGuardFileIdentity(
            $claimPath
        )
        if ([string]$claimHandleIdentity -cne [string]$claimPathIdentity) {
            throw 'The output-directory claim did not remain bound to its leased directory.'
        }
        $DirectoryLease.VerifyStillNonReparseDirectory()

        $ownerText = $RunId + "`n"
        $ownerRecord = Open-NewTextArtifactReadLock -Text $ownerText -Path $ownerPath -Encoding (New-Object Text.UTF8Encoding($false)) -Kind 'output owner' -Tracker $IntegrityTracker -PathEntryLeases $PathEntryLeases -LeasesByPath $LeasesByPath
        return [pscustomobject]@{
            path = $claimPath
            stream = $stream
            owner_path = $ownerPath
            owner_sha256 = $ownerRecord.sha256
            owner_record = $ownerRecord
            file_identity = $claimHandleIdentity
        }
    }
    catch {
        if ($null -ne $stream) {
            $stream.Dispose()
        }
        throw "OutputDirectory could not be claimed exclusively: $full. $($_.Exception.Message)"
    }
}

function Copy-NewHashBoundFile {
    param(
        [Parameter(Mandatory)][string]$Source,
        [Parameter(Mandatory)][string]$Destination,
        [Parameter(Mandatory)][string]$Kind,
        [Parameter(Mandatory)]$Tracker,
        [Parameter(Mandatory)]$PathEntryLeases,
        [Parameter(Mandatory)][hashtable]$LeasesByPath,
        [AllowNull()][IO.FileStream]$RetainedSourceStream
    )

    $sourceLease = Open-NonReparseFileLeaf -Path $Source -Tracker $PathEntryLeases -LeasesByPath $LeasesByPath
    $parent = Split-Path -Parent $Destination
    $null = Open-NonReparseDirectoryChain -Path $parent -Tracker $PathEntryLeases -LeasesByPath $LeasesByPath
    $input = $null
    $disposeInput = $false
    $output = $null
    $record = $null
    try {
        if ($null -eq $RetainedSourceStream) {
            $input = [IO.File]::Open(
                $Source,
                [IO.FileMode]::Open,
                [IO.FileAccess]::Read,
                [IO.FileShare]::Read
            )
            $disposeInput = $true
        }
        else {
            if (-not $RetainedSourceStream.CanRead -or
                -not $RetainedSourceStream.CanSeek) {
                throw "$Kind retained source stream is not readable and seekable: $Source"
            }
            $input = $RetainedSourceStream
            $input.Position = 0
        }
        if ([Mql5Coding.JobProcessLaunch]::GetFileIdentity($input.SafeFileHandle) -cne
            [string]$sourceLease.Identity) {
            throw "$Kind source path changed before staging: $Source"
        }
        $output = [IO.File]::Open($Destination, [IO.FileMode]::CreateNew, [IO.FileAccess]::ReadWrite, [IO.FileShare]::Read)
        $record = [pscustomobject][ordered]@{
            kind = $Kind
            source_path = $Source
            destination_path = $Destination
            byte_length = [long]0
            sha256 = $null
            verified = $false
        }
        $Tracker.Add($record)
        $input.CopyTo($output)
        $output.Flush($true)

        $destinationLease = Open-NonReparseFileLeaf -Path $Destination -Tracker $PathEntryLeases -LeasesByPath $LeasesByPath
        if ([Mql5Coding.JobProcessLaunch]::GetFileIdentity($output.SafeFileHandle) -cne
            [string]$destinationLease.Identity) {
            throw "$Kind staging path changed while its lease was established: $Destination"
        }

        $sourceLength = [long]$input.Length
        $destinationLength = [long]$output.Length
        $sourceHash = Get-StreamSha256 -Stream $input
        $destinationHash = Get-StreamSha256 -Stream $output
        if ($sourceLength -ne $destinationLength -or
            $sourceHash -cne $destinationHash) {
            throw "$Kind staging hash mismatch: $Destination"
        }

        $record.byte_length = $destinationLength
        $record.sha256 = $destinationHash
        $record.verified = $true
        return $record
    }
    finally {
        if ($null -ne $output) {
            $output.Dispose()
        }
        if ($disposeInput -and $null -ne $input) {
            $input.Dispose()
        }
        elseif ($null -ne $input -and $input.CanSeek) {
            $input.Position = 0
        }
    }
}

function Copy-NewVerifiedOutputArtifact {
    param(
        [Parameter(Mandatory)][string]$Source,
        [Parameter(Mandatory)][string]$Destination,
        [Parameter(Mandatory)][string]$Kind,
        [Parameter(Mandatory)]$SourceLease,
        [Parameter(Mandatory)]$Tracker
    )

    $sourcePath = [IO.Path]::GetFullPath($Source)
    $destinationPath = [IO.Path]::GetFullPath($Destination)
    $input = $null
    $output = $null
    try {
        $input = [IO.File]::Open($sourcePath, [IO.FileMode]::Open, [IO.FileAccess]::Read, [IO.FileShare]::Read)
        if ([Mql5Coding.JobProcessLaunch]::GetFileIdentity($input.SafeFileHandle) -cne [string]$SourceLease.Identity) {
            throw "$Kind source identity changed before output publication: $sourcePath"
        }

        $output = [Mql5Coding.JobProcessLaunch]::CreatePinnedOutputFileStream($destinationPath)
        $input.CopyTo($output)
        $output.Flush($true)
        $sourceHash = Get-StreamSha256 -Stream $input
        $destinationHash = Get-StreamSha256 -Stream $output
        if ([long]$input.Length -ne [long]$output.Length -or $sourceHash -cne $destinationHash) {
            throw "$Kind output copy failed exact byte verification: $destinationPath"
        }

        $record = [pscustomobject][ordered]@{
            kind = $Kind
            source_path = $sourcePath
            destination_path = $destinationPath
            byte_length = [long]$output.Length
            sha256 = $destinationHash
            verified = $true
        }
        $Tracker.Add([pscustomobject][ordered]@{
            record = $record
            stream = $output
        })
        $output = $null
        return $record
    }
    finally {
        if ($null -ne $output) {
            $output.Dispose()
        }
        if ($null -ne $input) {
            $input.Dispose()
        }
    }
}

function Get-StreamSha256 {
    param([Parameter(Mandatory)][IO.Stream]$Stream)

    $Stream.Position = 0
    $algorithm = [Security.Cryptography.SHA256]::Create()
    try {
        return ConvertTo-Hex -Bytes $algorithm.ComputeHash($Stream)
    }
    finally {
        $algorithm.Dispose()
        $Stream.Position = 0
    }
}

function Open-NewTextArtifactReadLock {
    param(
        [Parameter(Mandatory)][string]$Text,
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][Text.Encoding]$Encoding,
        [Parameter(Mandatory)][string]$Kind,
        [Parameter(Mandatory)]$Tracker,
        [Parameter(Mandatory)]$PathEntryLeases,
        [Parameter(Mandatory)][hashtable]$LeasesByPath
    )

    $full = [IO.Path]::GetFullPath($Path)
    $parent = [IO.Path]::GetDirectoryName($full)
    $null = Open-NonReparseDirectoryChain -Path $parent -Tracker $PathEntryLeases -LeasesByPath $LeasesByPath
    $creationStream = $null
    try {
        $creationStream = [Mql5Coding.JobProcessLaunch]::CreatePinnedOutputFileStream(
            $full
        )
        $preamble = $Encoding.GetPreamble()
        if ($preamble.Length -gt 0) {
            $creationStream.Write($preamble, 0, $preamble.Length)
        }
        $bytes = $Encoding.GetBytes($Text)
        if ($bytes.Length -gt 0) {
            $creationStream.Write($bytes, 0, $bytes.Length)
        }
        $creationStream.Flush($true)

        # Correlate the exact no-follow creation handle with a retained no-follow
        # leaf lease while the creation handle is still open. Keeping that same
        # stream removes the close-to-reopen replacement window.
        $lease = Open-NonReparseFileLeaf -Path $full -Tracker $PathEntryLeases -LeasesByPath $LeasesByPath
        $creationIdentity = [Mql5Coding.JobProcessLaunch]::GetFileIdentity(
            $creationStream.SafeFileHandle
        )
        if ([string]$creationIdentity -cne [string]$lease.Identity) {
            throw "$Kind creation handle did not remain bound to its no-follow leaf lease: $full"
        }
        $expectedLength = [long]$creationStream.Length
        $expectedHash = Get-StreamSha256 -Stream $creationStream

        $record = [pscustomobject][ordered]@{
            kind = $Kind
            destination_path = $full
            byte_length = $expectedLength
            sha256 = $expectedHash
            file_identity = $creationIdentity
            verified = $true
        }
        $Tracker.Add([pscustomobject][ordered]@{
            record = $record
            stream = $creationStream
        })
        $creationStream = $null
        return $record
    }
    finally {
        if ($null -ne $creationStream) {
            $creationStream.Dispose()
        }
    }
}

function Open-TerminalOriginReadLock {
    param(
        [Parameter(Mandatory)][string]$TerminalDataPath,
        [Parameter(Mandatory)][string]$TerminalPath,
        [Parameter(Mandatory)][string]$ExpectedInstallPath,
        [Parameter(Mandatory)]$Tracker
    )

    $originPath = Join-Path $TerminalDataPath 'origin.txt'
    $stream = $null
    try {
        $stream = [IO.File]::Open(
            $originPath,
            [IO.FileMode]::Open,
            [IO.FileAccess]::Read,
            [IO.FileShare]::Read
        )
        if ([long]$stream.Length -le 0 -or [long]$stream.Length -gt 32768) {
            throw "Terminal origin file must contain 1-32768 bytes: $originPath"
        }

        $strictUtf8 = New-Object Text.UTF8Encoding($false, $true)
        $reader = New-Object IO.StreamReader($stream, $strictUtf8, $true, 1024, $true)
        try {
            $originText = $reader.ReadToEnd()
        }
        finally {
            $reader.Dispose()
        }
        $origin = ConvertFrom-TerminalOriginText -Text $originText -SourcePath $originPath
        $expectedInstall = [IO.Path]::GetFullPath(
            $ExpectedInstallPath
        ).TrimEnd('\', '/')
        if (-not $origin.TrimEnd('\', '/').Equals(
                $expectedInstall,
                [StringComparison]::Ordinal
            )) {
            throw "Terminal data origin changed after binding to '$TerminalPath': $originPath"
        }

        $stream.Position = 0
        $record = [pscustomobject][ordered]@{
            kind = 'terminal origin binding'
            destination_path = $originPath
            install_path = $origin
            byte_length = [long]$stream.Length
            sha256 = Get-StreamSha256 -Stream $stream
            file_identity = [Mql5Coding.JobProcessLaunch]::GetFileIdentity(
                $stream.SafeFileHandle
            )
            verified = $true
        }
        $Tracker.Add([pscustomobject][ordered]@{
            record = $record
            stream = $stream
        })
        $stream = $null
        return $record
    }
    finally {
        if ($null -ne $stream) {
            $stream.Dispose()
        }
    }
}

function Open-StagingReadLocks {
    param(
        [Parameter(Mandatory)]$Records,
        [Parameter(Mandatory)]$Tracker,
        [Parameter(Mandatory)]$PathEntryLeases,
        [Parameter(Mandatory)][hashtable]$LeasesByPath
    )

    foreach ($record in $Records) {
        if ($null -eq $record.PSObject.Properties['verified'] -or -not [bool]$record.verified) {
            throw "Cannot lock an unverified $($record.kind) staging copy: $($record.destination_path)"
        }
        $path = [IO.Path]::GetFullPath([string]$record.destination_path)
        $lease = Open-NonReparseFileLeaf -Path $path -Tracker $PathEntryLeases -LeasesByPath $LeasesByPath
        $stream = [IO.File]::Open(
            $path,
            [IO.FileMode]::Open,
            [IO.FileAccess]::Read,
            [IO.FileShare]::Read
        )
        try {
            if ([Mql5Coding.JobProcessLaunch]::GetFileIdentity($stream.SafeFileHandle) -cne
                [string]$lease.Identity) {
                throw "$($record.kind) path changed while its read lock was established: $path"
            }
            $entry = [pscustomobject][ordered]@{
                record = $record
                stream = $stream
            }
            $Tracker.Add($entry)
            $stream = $null
            $hash = Get-StreamSha256 -Stream $entry.stream
            if ([long]$entry.stream.Length -ne [long]$record.byte_length -or
                $hash -cne [string]$record.sha256) {
                throw "$($record.kind) staging bytes changed before the read lock was established: $path"
            }
        }
        finally {
            if ($null -ne $stream) {
                $stream.Dispose()
            }
        }
    }
}

function Open-VerifiedArtifactReadLock {
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][string]$Kind,
        [Parameter(Mandatory)]$Tracker,
        [Parameter(Mandatory)]$PathEntryLeases,
        [Parameter(Mandatory)][hashtable]$LeasesByPath,
        [switch]$AllowDirectoryWrites
    )

    $full = [IO.Path]::GetFullPath($Path)
    $lease = Open-NonReparseFileLeaf -Path $full -Tracker $PathEntryLeases -LeasesByPath $LeasesByPath -AllowDirectoryWrites:$AllowDirectoryWrites
    $stream = [IO.File]::Open(
        $full,
        [IO.FileMode]::Open,
        [IO.FileAccess]::Read,
        [IO.FileShare]::Read
    )
    try {
        if ([Mql5Coding.JobProcessLaunch]::GetFileIdentity($stream.SafeFileHandle) -cne
            [string]$lease.Identity) {
            throw "$Kind path changed while its read lock was established: $full"
        }
        $record = [pscustomobject][ordered]@{
            kind = $Kind
            destination_path = $full
            byte_length = [long]$stream.Length
            sha256 = Get-StreamSha256 -Stream $stream
            verified = $true
        }
        $Tracker.Add([pscustomobject][ordered]@{
            record = $record
            stream = $stream
        })
        $stream = $null
        return $record
    }
    finally {
        if ($null -ne $stream) {
            $stream.Dispose()
        }
    }
}

function Get-PinnedStagingIntegrityFailures {
    param([Parameter(Mandatory)]$Locks)

    $failures = New-Object 'System.Collections.Generic.List[string]'
    foreach ($entry in $Locks) {
        $record = $entry.record
        $stream = $entry.stream
        try {
            $hash = Get-StreamSha256 -Stream $stream
            if ([long]$stream.Length -ne [long]$record.byte_length -or $hash -cne [string]$record.sha256) {
                $failures.Add("$($record.kind) staging bytes changed while its read lock was held: $($record.destination_path)")
            }
        }
        catch {
            $failures.Add("Could not verify locked $($record.kind) staging bytes '$($record.destination_path)': $($_.Exception.Message)")
        }
    }
    return $failures.ToArray()
}
