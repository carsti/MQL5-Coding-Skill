#Requires -Version 5.1

# Receipt validation uses the runner's no-follow path leases and integrity locks.
# These local hash commitments are evidence, not signatures or a trust sandbox.
function Test-Mql5CompilationReceipt {
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][string]$ExpertPath,
        [AllowNull()][string]$ExpectedExpertHash,
        [Parameter(Mandatory)]$Tracker,
        [Parameter(Mandatory)]$PathEntryLeases,
        [Parameter(Mandatory)][hashtable]$LeasesByPath
    )

    $receiptRecord = Open-VerifiedArtifactReadLock -Path $Path -Kind 'compilation receipt' -Tracker $Tracker -PathEntryLeases $PathEntryLeases -LeasesByPath $LeasesByPath
    if ($receiptRecord.byte_length -le 0 -or $receiptRecord.byte_length -gt 1048576) {
        throw 'Compilation receipt must contain between 1 byte and 1 MiB.'
    }
    $reader = [IO.StreamReader]::new($Tracker[$Tracker.Count - 1].stream, [Text.Encoding]::UTF8, $true, 4096, $true)
    try {
        $receiptText = $reader.ReadToEnd()
        # The JSON root must remain an object. ConvertFrom-Json would otherwise
        # unwrap a single-element array and hide the unsupported receipt shape.
        if (-not $receiptText.TrimStart().StartsWith('{')) {throw 'Compilation receipt must have a JSON object at its root.'}
        $receipt = $receiptText | ConvertFrom-Json
    }
    finally { $reader.Dispose(); $Tracker[$Tracker.Count - 1].stream.Position = 0 }

    if ($receipt.schema_version -ne 1 -or $receipt.kind -isnot [string] -or $receipt.kind -cne 'mql5_compilation_receipt' -or
        $receipt.run_id -isnot [string] -or $receipt.run_id -cnotmatch '\A[0-9a-f]{32}\z' -or
        $receipt.status -isnot [string] -or $receipt.status -cne 'success' -or $receipt.exit_code -ne 0 -or
        $receipt.errors -ne 0 -or $receipt.warnings -lt 0 -or
        $receipt.syntax_only -isnot [bool] -or $receipt.syntax_only -or
        $receipt.warnings_as_errors -isnot [bool] -or
        ($receipt.warnings_as_errors -and $receipt.warnings -ne 0) -or
        $receipt.compiler -isnot [pscustomobject] -or $null -eq $receipt.expert -or $null -eq $receipt.log) {
        throw 'Compilation receipt must describe a successful artifact-producing compilation.'
    }
    foreach ($number in @($receipt.schema_version, $receipt.exit_code, $receipt.errors, $receipt.warnings, $receipt.compiler.build)) {
        if ($number -isnot [int] -and $number -isnot [long]) {
            throw 'Compilation receipt counts and compiler build must be integers.'
        }
    }
    foreach ($file in @($receipt.source, $receipt.expert, $receipt.log, $receipt.compiler)) {
        if ($file -isnot [pscustomobject] -or $file.path -isnot [string] -or
            $file.sha256 -isnot [string] -or $file.sha256 -cnotmatch '\A[0-9a-f]{64}\z' -or
            ($file.byte_length -isnot [int] -and $file.byte_length -isnot [long]) -or
            $file.byte_length -le 0 -or -not (Test-IsAbsoluteLocalDrivePath -Path $file.path)) {
            throw 'Compilation receipt contains an invalid file commitment.'
        }
    }
    if ([IO.Path]::GetExtension($receipt.source.path) -ine '.mq5' -or
        -not [IO.Path]::GetFullPath($receipt.expert.path).Equals($ExpertPath, [StringComparison]::OrdinalIgnoreCase) -or
        -not [IO.Path]::ChangeExtension([IO.Path]::GetFullPath($receipt.source.path), '.ex5').Equals($ExpertPath, [StringComparison]::OrdinalIgnoreCase)) {
        throw 'Compilation receipt does not bind the selected ExpertPath to its source.'
    }
    if (-not [string]::IsNullOrWhiteSpace($ExpectedExpertHash) -and
        $ExpectedExpertHash -cne $receipt.expert.sha256) {
        throw 'Compilation receipt EX5 hash does not match ExpectedExpertSha256.'
    }

    # Read-lock source, EX5, receipt, and retained log until final runner cleanup.
    # The compiler image is recorded historically; testing does not require that
    # exact compiler to remain installed after it produced the artifact.
    foreach ($name in @('source', 'expert', 'log')) {
        $file = $receipt.$name
        $record = Open-VerifiedArtifactReadLock -Path $file.path -Kind "compilation $name" -Tracker $Tracker -PathEntryLeases $PathEntryLeases -LeasesByPath $LeasesByPath
        if ($record.byte_length -ne $file.byte_length -or $record.sha256 -cne $file.sha256) {
            throw "Compilation receipt $name hash or byte length no longer matches."
        }
        if ($name -eq 'log') {
            if ($record.byte_length -gt 16777216) { throw 'Compilation receipt log exceeds 16 MiB.' }
            $reader = [IO.StreamReader]::new($Tracker[$Tracker.Count - 1].stream, [Text.Encoding]::UTF8, $true, 4096, $true)
            try { $logText = $reader.ReadToEnd() }
            finally { $reader.Dispose(); $Tracker[$Tracker.Count - 1].stream.Position = 0 }
        }
    }
    $matches = [regex]::Matches($logText, '(?im)^\s*Result:\s*(?<errors>\d+)\s+errors?,\s*(?<warnings>\d+)\s+warnings?')
    if ($matches.Count -eq 0 -or
        [int]$matches[$matches.Count - 1].Groups['errors'].Value -ne $receipt.errors -or
        [int]$matches[$matches.Count - 1].Groups['warnings'].Value -ne $receipt.warnings) {
        throw 'Compilation receipt counts do not match the retained MetaEditor log.'
    }
    return [ordered]@{
        path = $receiptRecord.destination_path
        sha256 = $receiptRecord.sha256
        run_id = $receipt.run_id
        verified = $true
        expert_sha256 = $receipt.expert.sha256
        source_sha256 = $receipt.source.sha256
        log_sha256 = $receipt.log.sha256
        compiler_build = $receipt.compiler.build
        compiler_file_version = $receipt.compiler.file_version
        errors = $receipt.errors
        warnings = $receipt.warnings
    }
}
