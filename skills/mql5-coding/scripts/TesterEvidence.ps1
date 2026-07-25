#Requires -Version 5.1

# Internal journal, evidence, redaction, and result-writing helpers for Invoke-Mt5TesterSmoke.ps1.

function Get-StreamPrefixSha256 {
    param(
        [Parameter(Mandatory)][IO.Stream]$Stream,
        [Parameter(Mandatory)][long]$Length
    )

    if ($Length -lt 0 -or $Length -gt [long]$Stream.Length) {
        throw "Cannot hash $Length bytes from a stream of length $($Stream.Length)."
    }
    $Stream.Position = 0
    $algorithm = [Security.Cryptography.SHA256]::Create()
    $buffer = New-Object byte[] 1048576
    $remaining = $Length
    try {
        while ($remaining -gt 0) {
            $requested = [int][Math]::Min([long]$buffer.Length, $remaining)
            $read = $Stream.Read($buffer, 0, $requested)
            if ($read -le 0) {
                throw "Stream ended before the requested $Length-byte prefix could be hashed."
            }
            $null = $algorithm.TransformBlock($buffer, 0, $read, $buffer, 0)
            $remaining -= $read
        }
        $empty = New-Object byte[] 0
        $null = $algorithm.TransformFinalBlock($empty, 0, 0)
        return ConvertTo-Hex -Bytes $algorithm.Hash
    }
    finally {
        $algorithm.Dispose()
        $Stream.Position = 0
    }
}

function Get-JournalSnapshot {
    param(
        [Parameter(Mandatory)][string]$RootPath,
        [Parameter(Mandatory)]$PathEntryLeases,
        [Parameter(Mandatory)][hashtable]$LeasesByPath,
        [Parameter(Mandatory)]$StreamTracker,
        [hashtable]$Existing
    )
    if ($null -eq $Existing) {
        $Existing = [System.Collections.Hashtable]::new(
            [System.StringComparer]::Ordinal
        )
    }
    $snapshot = [System.Collections.Hashtable]::new(
        [System.StringComparer]::Ordinal
    )
    $null = Open-NonReparseDirectoryChain -Path $RootPath -Tracker $PathEntryLeases -LeasesByPath $LeasesByPath
    foreach ($file in Get-ChildItem -LiteralPath $RootPath -File -Filter '*.log') {
        $fullPath = [IO.Path]::GetFullPath($file.FullName)
        $key = $fullPath
        $stream = $null
        $lease = $null
        $newStream = $false
        if ($Existing.ContainsKey($key)) {
            $stream = $Existing[$key].stream
            $lease = $Existing[$key].path_entry_lease
        }
        else {
            $lease = Open-NonReparseFileLeaf -Path $fullPath -Tracker $PathEntryLeases -LeasesByPath $LeasesByPath
            $stream = [IO.File]::Open(
                $fullPath,
                [IO.FileMode]::Open,
                [IO.FileAccess]::Read,
                [IO.FileShare]::ReadWrite
            )
            $newStream = $true
        }

        try {
            $streamIdentity = [Mql5Coding.JobProcessLaunch]::GetFileIdentity(
                $stream.SafeFileHandle
            )
            if ($streamIdentity -cne [string]$lease.Identity) {
                throw "Journal path changed while its read lease was acquired: $fullPath"
            }
            $byteLength = [long]$stream.Length
            $prefixHash = Get-StreamPrefixSha256 -Stream $stream -Length $byteLength
            if ($newStream) {
                $StreamTracker.Add($stream)
                $newStream = $false
            }
        }
        finally {
            if ($newStream -and $null -ne $stream) {
                $stream.Dispose()
            }
        }
        $snapshot[$key] = [pscustomobject]@{
            path = $fullPath
            byte_length = $byteLength
            prefix_sha256 = $prefixHash
            file_identity = $streamIdentity
            path_entry_lease = $lease
            stream = $stream
        }
    }
    return $snapshot
}

function Read-ExactBytesFromStream {
    param(
        [Parameter(Mandatory)][IO.Stream]$Stream,
        [Parameter(Mandatory)][long]$Offset,
        [Parameter(Mandatory)][int]$Length,
        [Parameter(Mandatory)][string]$Path
    )

    $bytes = New-Object byte[] $Length
    $null = $Stream.Seek($Offset, [IO.SeekOrigin]::Begin)
    $readTotal = 0
    while ($readTotal -lt $Length) {
        $read = $Stream.Read($bytes, $readTotal, $Length - $readTotal)
        if ($read -le 0) {
            throw "Journal ended while reading appended bytes: $Path"
        }
        $readTotal += $read
    }
    return $bytes
}

function Read-JournalDelta {
    param(
        [Parameter(Mandatory)][hashtable]$Before,
        [Parameter(Mandatory)][string]$RootPath,
        [Parameter(Mandatory)][string]$LogicalName,
        [Parameter(Mandatory)][int]$MaximumBytes,
        [Parameter(Mandatory)]$PathEntryLeases,
        [Parameter(Mandatory)][hashtable]$LeasesByPath,
        [Parameter(Mandatory)]$StreamTracker
    )
    $after = Get-JournalSnapshot -RootPath $RootPath -PathEntryLeases $PathEntryLeases -LeasesByPath $LeasesByPath -StreamTracker $StreamTracker -Existing $Before
    $plans = New-Object 'System.Collections.Generic.List[object]'
    $total = [long]0

    foreach ($beforeKey in $Before.Keys) {
        if (-not $after.ContainsKey($beforeKey)) {
            throw "$LogicalName journal disappeared during the run: $($Before[$beforeKey].path)"
        }
    }

    foreach ($entry in @($after.Values | Sort-Object path)) {
        $key = [string]$entry.path
        $offset = [long]0
        $beforePrefixHash = $null
        if ($Before.ContainsKey($key)) {
            $offset = [long]$Before[$key].byte_length
            $beforePrefixHash = [string]$Before[$key].prefix_sha256
        }
        if ([long]$entry.byte_length -lt $offset) {
            throw "$LogicalName journal was truncated during the run: $($entry.path)"
        }
        $length = [long]$entry.byte_length - $offset
        if ($length -le 0) {
            if ($offset -gt 0 -and [string]$entry.prefix_sha256 -cne $beforePrefixHash) {
                throw "$LogicalName journal bytes were replaced or modified during the run: $($entry.path)"
            }
            continue
        }
        $total += $length
        $plans.Add([pscustomobject]@{
            path = $entry.path
            offset = $offset
            byte_length = $length
            before_prefix_sha256 = $beforePrefixHash
            after_byte_length = [long]$entry.byte_length
            after_sha256 = [string]$entry.prefix_sha256
            file_identity = [string]$entry.file_identity
            stream = $entry.stream
        })
    }

    if ($total -gt $MaximumBytes) {
        return [pscustomobject][ordered]@{
            logical_name = $LogicalName
            root_path = $RootPath
            appended_byte_length = $total
            limit_exceeded = $true
            records = @()
            text = ''
        }
    }

    $records = New-Object 'System.Collections.Generic.List[object]'
    $textParts = New-Object 'System.Collections.Generic.List[string]'
    $unicode = New-Object Text.UnicodeEncoding($false, $true, $true)
    foreach ($plan in $plans) {
        if ([long]$plan.byte_length -gt [int]::MaxValue) {
            throw "$LogicalName appended segment is too large to inspect safely: $($plan.path)"
        }
        $stream = $plan.stream
        if ([Mql5Coding.JobProcessLaunch]::GetFileIdentity(
                $stream.SafeFileHandle
            ) -cne [string]$plan.file_identity) {
            throw "$LogicalName journal file identity changed after its post-run snapshot: $($plan.path)"
        }
        if ([long]$stream.Length -ne [long]$plan.after_byte_length) {
            throw "$LogicalName journal changed after its post-run snapshot: $($plan.path)"
        }
        $afterHash = Get-StreamPrefixSha256 -Stream $stream -Length ([long]$plan.after_byte_length)
        if ($afterHash -cne [string]$plan.after_sha256) {
            throw "$LogicalName journal bytes changed after its post-run snapshot: $($plan.path)"
        }
        if ([long]$plan.offset -gt 0) {
            $prefixHash = Get-StreamPrefixSha256 -Stream $stream -Length ([long]$plan.offset)
            if ($prefixHash -cne [string]$plan.before_prefix_sha256) {
                throw "$LogicalName journal prefix was replaced or modified during the run: $($plan.path)"
            }
        }
        $bytes = Read-ExactBytesFromStream `
            -Stream $stream `
            -Offset ([long]$plan.offset) `
            -Length ([int]$plan.byte_length) `
            -Path ([string]$plan.path)
        $start = 0
        if ([long]$plan.offset -eq 0 -and $bytes.Length -ge 2 -and $bytes[0] -eq 0xff -and $bytes[1] -eq 0xfe) {
            $start = 2
        }
        if ((($bytes.Length - $start) % 2) -ne 0) {
            throw "$LogicalName appended UTF-16LE journal segment has an odd byte length: $($plan.path)"
        }
        $decoded = $unicode.GetString($bytes, $start, $bytes.Length - $start)
        $textParts.Add($decoded)

        $algorithm = [Security.Cryptography.SHA256]::Create()
        try {
            $hash = ConvertTo-Hex -Bytes $algorithm.ComputeHash($bytes)
        }
        finally {
            $algorithm.Dispose()
        }
        $records.Add([pscustomobject][ordered]@{
            path = [string]$plan.path
            source_offset = [long]$plan.offset
            byte_length = [long]$plan.byte_length
            sha256 = $hash
        })
    }

    return [pscustomobject][ordered]@{
        logical_name = $LogicalName
        root_path = $RootPath
        appended_byte_length = $total
        limit_exceeded = $false
        records = $records.ToArray()
        text = ($textParts -join "`r`n")
    }
}

function Test-ContainsText {
    param(
        [AllowEmptyString()][string]$Text,
        [Parameter(Mandatory)][string]$Needle,
        [switch]$CaseSensitive
    )
    $comparison = if ($CaseSensitive) {
        [StringComparison]::Ordinal
    }
    else {
        [StringComparison]::OrdinalIgnoreCase
    }
    return $Text.IndexOf($Needle, $comparison) -ge 0
}

function Get-TextIndex {
    param(
        [AllowEmptyString()][string]$Text,
        [Parameter(Mandatory)][string]$Needle,
        [int]$StartIndex = 0,
        [switch]$CaseSensitive
    )

    if ($StartIndex -lt 0 -or $StartIndex -gt $Text.Length) {
        return -1
    }
    $comparison = if ($CaseSensitive) {
        [StringComparison]::Ordinal
    }
    else {
        [StringComparison]::OrdinalIgnoreCase
    }
    return $Text.IndexOf($Needle, $StartIndex, $comparison)
}

function Protect-JournalLine {
    param(
        [Parameter(Mandatory)][string]$Line,
        [string[]]$SensitiveValues = @()
    )
    $redacted = $Line
    $secretLabelPattern =
        '(?:' +
            '(?:[A-Za-z0-9]+[._-])*' +
                '(?:password|passwd|pwd|token|secret|authorization|auth|' +
                    'access[._-]+token|refresh[._-]+token|api[._-]+key|' +
                    'client[._-]+secret)' +
                '(?:[._-][A-Za-z0-9]+)*' +
            '|' +
            '(?-i:[A-Za-z0-9]*(?:[Pp]assword|[Pp]asswd|[Pp]wd|[Tt]oken|' +
                '[Ss]ecret|[Aa]uthorization|[Aa]uth|[Aa]pi[Kk]ey)' +
                '(?:[A-Z][A-Za-z0-9]*)*)' +
            '|' +
            'access[ \t]+token|refresh[ \t]+token|api[ \t]+key|' +
                'client[ \t]+secret' +
        ')'
    $secretLabelClosingQuotePattern = '(?:\\*["''])?'
    $orderedSensitiveValues = @(
        $SensitiveValues |
            Where-Object { -not [string]::IsNullOrEmpty($_) } |
            Sort-Object { $_.Length } -Descending
    )
    if (-not [string]::IsNullOrWhiteSpace($env:USERPROFILE)) {
        $redacted = [regex]::Replace(
            $redacted,
            [regex]::Escape($env:USERPROFILE),
            '<USERPROFILE>',
            [Text.RegularExpressions.RegexOptions]::IgnoreCase
        )
    }
    $redacted = [regex]::Replace($redacted, '(?<![0-9])(?:[0-9]{1,3}\.){3}[0-9]{1,3}(?![0-9])', '<IP>')
    $redacted = [regex]::Replace(
        $redacted,
        '(?i)\b(account|login)\s*[:=]?\s*[0-9]{5,}\b',
        '$1 <REDACTED>'
    )
    $redacted = [regex]::Replace(
        $redacted,
        '(?i)\b(balance|equity|profit)\s+[-+]?[0-9]+(?:\.[0-9]+)?',
        '$1 <REDACTED>'
    )
    $redacted = [regex]::Replace(
        $redacted,
        '(?i)\b(community|username|user)\s*[:=]\s*\S+',
        '$1=<REDACTED>'
    )
    $redacted = [regex]::Replace(
        $redacted,
        '(?i)(?<![A-Za-z0-9_.-])(?:[A-Za-z0-9]+[._-])*' +
            '(?:authorization|auth)\b\s*[:=].*$',
        '<SECRET>=<REDACTED>'
    )
    $redacted = [regex]::Replace(
        $redacted,
        '(?i)\bBearer\s+[A-Za-z0-9._~+/=-]+',
        'Bearer <REDACTED>'
    )
    $redacted = [regex]::Replace(
        $redacted,
        '(?i)(?<![A-Za-z0-9_.-])(?:' +
            $secretLabelPattern +
            $secretLabelClosingQuotePattern +
            '\s*[:=]\s*[^\r\n]*' +
            '|--?' +
            $secretLabelPattern +
            '(?:\s+|\s*[:=]\s*)[^\r\n]*' +
        ')',
        '<SECRET>=<REDACTED>'
    )
    $bareSecretPattern =
        '(?i)(?<![A-Za-z0-9_.-])' +
            $secretLabelPattern +
            $secretLabelClosingQuotePattern +
            '\s+(?<bareSecretValue>[^\r\n]+)'
    $knownBareSecretDiagnosticPattern =
        '(?i)^(?:is\s+)?(?:authentication\s+failed|refresh\s+failed|not\s+configured|' +
            'missing|required|invalid|expired|rejected|failed|failure|denied|disabled|' +
            'enabled|unavailable|empty|absent)$'
    $redacted = [regex]::Replace(
        $redacted,
        $bareSecretPattern,
        [Text.RegularExpressions.MatchEvaluator]{
            param($match)
            $normalizedValue = [regex]::Replace(
                $match.Groups['bareSecretValue'].Value.Trim(),
                '\s+',
                ' '
            )
            if ($normalizedValue -match $knownBareSecretDiagnosticPattern) {
                return $match.Value
            }
            return '<SECRET>=<REDACTED>'
        }
    )
    $redacted = [regex]::Replace(
        $redacted,
        '(?i)\b[A-Z0-9._%+-]+@[A-Z0-9.-]+\.[A-Z]{2,}\b',
        '<EMAIL>'
    )
    $redacted = [regex]::Replace($redacted, '(?<![A-Za-z0-9])[0-9]{7,}(?![A-Za-z0-9])', '<NUMBER>')
    foreach ($sensitiveValue in $orderedSensitiveValues) {
        $redacted = $redacted.Replace($sensitiveValue, '')
    }
    foreach ($sensitiveValue in $orderedSensitiveValues) {
        if ($redacted.Contains($sensitiveValue)) {
            return ''
        }
    }
    return $redacted
}

function Select-JournalEvidence {
    param(
        [AllowEmptyString()][string]$Text,
        [Parameter(Mandatory)][string[]]$Patterns,
        [string[]]$SensitiveValues = @()
    )
    $selected = New-Object 'System.Collections.Generic.List[string]'
    foreach ($line in ($Text -split '\r?\n')) {
        if ([string]::IsNullOrWhiteSpace($line)) {
            continue
        }
        $matched = $false
        foreach ($pattern in $Patterns) {
            if ($line -match $pattern) {
                $matched = $true
                break
            }
        }
        if ($matched) {
            $safe = Protect-JournalLine -Line $line -SensitiveValues $SensitiveValues
            if (-not [string]::IsNullOrWhiteSpace($safe) -and -not $selected.Contains($safe)) {
                $selected.Add($safe)
            }
        }
        if ($selected.Count -ge 60) {
            break
        }
    }
    return $selected.ToArray()
}

function Get-SpawnedProcessIdentity {
    param(
        [Parameter(Mandatory)][Diagnostics.Process]$Process,
        [Parameter(Mandatory)][string]$ExecutablePath,
        [Parameter(Mandatory)][string]$ExecutableFileIdentity
    )

    try {
        $creationUtcTicks = [long]$Process.StartTime.ToUniversalTime().Ticks
        $sessionId = [int]$Process.SessionId
    }
    catch {
        throw "Cannot capture the spawned process identity for PID $($Process.Id): $($_.Exception.Message)"
    }
    return [pscustomobject][ordered]@{
        process_id = [int]$Process.Id
        parent_process_id = [int]$PID
        creation_utc_ticks = $creationUtcTicks
        session_id = $sessionId
        executable_path = [IO.Path]::GetFullPath($ExecutablePath)
        executable_file_identity = $ExecutableFileIdentity
    }
}

function Write-NewTextFile {
    param(
        [Parameter(Mandatory)][string]$Text,
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][Text.Encoding]$Encoding
    )

    $stream = [IO.File]::Open($Path, [IO.FileMode]::CreateNew, [IO.FileAccess]::Write, [IO.FileShare]::None)
    try {
        $preamble = $Encoding.GetPreamble()
        if ($preamble.Length -gt 0) {
            $stream.Write($preamble, 0, $preamble.Length)
        }
        $bytes = $Encoding.GetBytes($Text)
        if ($bytes.Length -gt 0) {
            $stream.Write($bytes, 0, $bytes.Length)
        }
        $stream.Flush($true)
    }
    finally {
        $stream.Dispose()
    }
}

function Write-JsonFile {
    param(
        [Parameter(Mandatory)]$Value,
        [Parameter(Mandatory)][string]$Path
    )
    $json = $Value | ConvertTo-Json -Depth 12
    $utf8 = New-Object Text.UTF8Encoding($false)
    Write-NewTextFile -Text ($json + "`n") -Path $Path -Encoding $utf8
}
