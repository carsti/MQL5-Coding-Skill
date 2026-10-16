#Requires -Version 5.1

param(
    $ExpertPath,
    $ExpectedExpertSha256,
    $CompilationReceiptPath,
    $BuildSnapshotPath,
    $Symbol,
    $Period,
    $FromDate,
    $ToDate,
    $Model,
    $SetPath,
    [switch]$UseExpertDefaults,
    $TerminalPath,
    $TerminalDataPath,
    $OutputDirectory,
    $TimeoutSeconds = '300',
    $MaxJournalAppendBytes = '16777216',
    $Deposit,
    $Currency,
    $Leverage,
    $ExecutionMode,

    [string[]]$ExpectedLogMarker = @(),
    $ExpectedLogMarkerFile,

    # Required for -Execute when the terminal has saved account credentials,
    # or when that state cannot be inspected. Pass it only after the user
    # confirms that the saved (possibly live) account may initialize.
    [switch]$AcknowledgeSavedAccountRisk,

    [switch]$Execute,

    [switch]$PreflightOnly
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$fixedLocalVolumeIdentities = @{}

$nativeTypeLoadError = $null
try {
    if (-not ('Mql5Coding.JobProcessLaunch' -as [type])) {
        Add-Type -Path (Join-Path $PSScriptRoot 'TesterProcessJob.cs')
    }
}
catch {
    $nativeTypeLoadError = $_.Exception.Message
}

try {
    . (Join-Path $PSScriptRoot 'TesterPathIntegrity.ps1')
    . (Join-Path $PSScriptRoot 'TesterEvidence.ps1')
    . (Join-Path $PSScriptRoot 'CompilationReceipt.ps1')
    if (-not [string]::IsNullOrWhiteSpace($BuildSnapshotPath)) {. (Join-Path $PSScriptRoot 'BuildSourceSnapshot.ps1')}
}
catch {
    $helperLoadMessage = 'Tester helper scripts could not be loaded.'
    if ($null -ne (Get-Command -Name Protect-JournalLine -ErrorAction SilentlyContinue)) {
        try {
            $helperLoadMessage = Protect-JournalLine -Line (
                "Tester helper scripts could not be loaded: $($_.Exception.Message)"
            )
        }
        catch {
            # Keep the path-safe generic message if redaction itself is unavailable.
            $helperLoadMessage = 'Tester helper scripts could not be loaded.'
        }
    }
    [Console]::Error.WriteLine($helperLoadMessage)
    exit 2
}

$runId = '{0}-{1}' -f ([datetime]::UtcNow.ToString('yyyyMMddTHHmmssZ')), ([guid]::NewGuid().ToString('N').Substring(0, 12))
$startedUtc = [datetimeoffset]::UtcNow
$errors = New-Object 'System.Collections.Generic.List[string]'
$warnings = New-Object 'System.Collections.Generic.List[string]'
$cleanupRemoved = New-Object 'System.Collections.Generic.List[string]'
$cleanupPreserved = New-Object 'System.Collections.Generic.List[string]'
$cleanupErrors = New-Object 'System.Collections.Generic.List[string]'
$hashBoundStaging = New-Object 'System.Collections.Generic.List[object]'
$outputArtifactPublicationLocks = New-Object 'System.Collections.Generic.List[object]'
$stagingReadLocks = New-Object 'System.Collections.Generic.List[object]'
$pathEntryLeases = New-Object 'System.Collections.Generic.List[object]'
$leasedPathEntries = [System.Collections.Hashtable]::new(
    [System.StringComparer]::Ordinal
)
$directoryMutationGuards = New-Object 'System.Collections.Generic.List[object]'
$guardedDirectories = [System.Collections.Hashtable]::new(
    [System.StringComparer]::Ordinal
)
$journalReadStreams = New-Object 'System.Collections.Generic.List[object]'
$generatedOwnedPaths = New-Object 'System.Collections.Generic.List[string]'
$createdDirectories = New-Object 'System.Collections.Generic.List[string]'
$lock = $null
$outputClaim = $null
$process = $null
$jobLaunch = $null
$ownedProcessTreeTerminationVerified = $true
$stagingReadLocksReleased = $true
$stagingReadLockAcquisitionCompleted = $false
$unsafePostLaunchIsolation = $false
$outputCreated = $false
$resultPath = $null
$resultWritten = $false
$exitCode = 2

$result = [ordered]@{
    schema_version = 2
    run_id = $runId
    status = 'preparing'
    primary_status_before_cleanup = $null
    started_utc = $startedUtc.ToString("yyyy-MM-ddTHH:mm:ss.fffffff'Z'")
    ended_utc = $null
    duration_milliseconds = 0
    preflight_only = [bool]$PreflightOnly
    execute_requested = [bool]$Execute
    inputs = [ordered]@{
        expert_path = $ExpertPath
        expected_expert_sha256 = if ([string]::IsNullOrWhiteSpace($ExpectedExpertSha256)) { $null } else { $ExpectedExpertSha256 }
        compilation_receipt_path = if ([string]::IsNullOrWhiteSpace($CompilationReceiptPath)) { $null } else { $CompilationReceiptPath }
        compilation_receipt = $null
        set_path = if ([string]::IsNullOrWhiteSpace($SetPath)) { $null } else { $SetPath }
        use_expert_defaults = [bool]$UseExpertDefaults
        symbol = $Symbol
        period = $Period
        from_date = $FromDate
        to_date = $ToDate
        model = $Model
        deposit = $Deposit
        currency = $Currency
        leverage = $Leverage
        execution_mode = $ExecutionMode
        timeout_seconds = $TimeoutSeconds
        max_journal_append_bytes = $MaxJournalAppendBytes
        expected_log_marker_count = @($ExpectedLogMarker).Count
        expected_log_marker_file = if ([string]::IsNullOrWhiteSpace($ExpectedLogMarkerFile)) { $null } else { $ExpectedLogMarkerFile }
        expected_log_marker_file_sha256 = $null
        expected_log_marker_sha256 = @()
        expected_log_marker_aggregate_sha256 = $null
    }
    binding = $null
    safety = [ordered]@{
        strategy_tester_requested = [bool]$Execute
        saved_account_risk_acknowledgement_required = $false
        saved_account_risk_acknowledged = [bool]$AcknowledgeSavedAccountRisk
        saved_account_inspection = 'not_checked'
        saved_accounts_detected = $null
        default_data_directories = @()
        selected_data_directory_is_default_for_terminal = $false
        saved_terminal_state_isolation_verified = $false
        optimization = $false
        visual_mode = $false
        use_local_agents = $true
        use_remote_agents = $false
        use_cloud_agents = $false
        live_trading_disabled_in_startup_config = $true
        startup_config_effects_chm_verified = $false
        strict_offline_terminal = $false
        process_job_containment = $true
        staging_read_locks = $true
        output_artifact_read_locks = $true
        non_reparse_path_chain_leases = $true
        local_drive_paths_required = $true
        direct_fixed_volume_mapping_required = $true
        mount_manager_drive_registration_required = $true
        path_handle_volume_correlation = $true
        directory_data_write_sharing_denied = $true
        directory_mutation_guards = $true
        terminal_process_checks_point_in_time = $true
        execution_staging_auto_cleanup = $false
        preflight_staging_auto_cleanup = $false
        untrusted_code_sandbox = $false
        notice = 'The generated startup file requests local-only testing, disabled live trading, and terminal shutdown, but the effects of those startup keys are not verified in the installed MQL5 CHM. MT5 may initialize its saved broker account before the Strategy Tester starts, which can include resuming Signals copying; execution therefore requires -AcknowledgeSavedAccountRisk whenever saved account credentials are present or cannot be ruled out. This runner does not attach the EA to a chart or call a live-order API, but it is not a security sandbox for untrusted EX5 code. The terminal is created suspended, assigned to a kill-on-close Windows Job Object, and resumed only after identity checks. Terminal-process discovery is point-in-time and cannot prevent a separately launched terminal from starting and exiting between checks.'
    }
    artifacts = [ordered]@{}
    process = [ordered]@{
        execution_attempted = $false
        process_created = $false
        process_id = $null
        resumed = $false
        suspended_launch_cleanup = $null
        exit_code = $null
        timed_out = $false
        job_containment_established = $false
        job_empty_verified = $false
        post_start_identity_verified = $false
        identity_source = $null
        post_exit_no_matching_terminal = $false
        post_exit_no_potential_descendants = $false
        potential_descendant_process_ids = @()
    }
    evidence = [ordered]@{}
    errors = $errors
    warnings = $warnings
    cleanup = [ordered]@{
        execution_staging_preserved = $false
        preflight_staging_preserved = $false
        removed = $cleanupRemoved
        preserved = $cleanupPreserved
        errors = $cleanupErrors
    }
}

try {
    if ($null -ne $nativeTypeLoadError) {
        throw "Native process helper could not be loaded: $nativeTypeLoadError"
    }
    if ($args.Count -gt 0) {
        throw "Unrecognized command-line argument count: $($args.Count)."
    }
    if ([bool]$Execute -eq [bool]$PreflightOnly) {
        throw 'Select exactly one mode: -Execute for a real tester run, or -PreflightOnly for validation without launching MT5.'
    }
    $hasSetPath = -not [string]::IsNullOrWhiteSpace([string]$SetPath)
    if ($hasSetPath -eq [bool]$UseExpertDefaults) {
        throw 'Select exactly one EA input source: -SetPath for a selected .set preset, or -UseExpertDefaults for the compiled EA defaults.'
    }

    foreach ($required in @(
            [pscustomobject]@{ name = 'ExpertPath'; value = $ExpertPath },
            [pscustomobject]@{ name = 'Symbol'; value = $Symbol },
            [pscustomobject]@{ name = 'Period'; value = $Period },
            [pscustomobject]@{ name = 'FromDate'; value = $FromDate },
            [pscustomobject]@{ name = 'ToDate'; value = $ToDate },
            [pscustomobject]@{ name = 'Model'; value = $Model },
            [pscustomobject]@{ name = 'Deposit'; value = $Deposit },
            [pscustomobject]@{ name = 'Currency'; value = $Currency },
            [pscustomobject]@{ name = 'Leverage'; value = $Leverage },
            [pscustomobject]@{ name = 'ExecutionMode'; value = $ExecutionMode },
            [pscustomobject]@{ name = 'OutputDirectory'; value = $OutputDirectory }
        )) {
        if ($null -eq $required.value -or [string]::IsNullOrWhiteSpace([string]$required.value)) {
            throw "$($required.name) is required."
        }
    }

    $modelValue = 0
    if (-not [int]::TryParse([string]$Model, [Globalization.NumberStyles]::Integer, [Globalization.CultureInfo]::InvariantCulture, [ref]$modelValue) -or
        $modelValue -lt 0 -or $modelValue -gt 4) {
        throw 'Model must be an integer from 0 through 4.'
    }
    $timeoutValue = 0
    if (-not [int]::TryParse([string]$TimeoutSeconds, [Globalization.NumberStyles]::Integer, [Globalization.CultureInfo]::InvariantCulture, [ref]$timeoutValue) -or
        $timeoutValue -lt 10 -or $timeoutValue -gt 86400) {
        throw 'TimeoutSeconds must be an integer from 10 through 86400.'
    }
    $journalLimitValue = 0
    if (-not [int]::TryParse([string]$MaxJournalAppendBytes, [Globalization.NumberStyles]::Integer, [Globalization.CultureInfo]::InvariantCulture, [ref]$journalLimitValue) -or
        $journalLimitValue -lt 1048576 -or $journalLimitValue -gt 268435456) {
        throw 'MaxJournalAppendBytes must be an integer from 1048576 through 268435456.'
    }
    $depositText = [string]$Deposit
    $depositValue = [decimal]::Zero
    if ($depositText -cnotmatch '\A[0-9]+(?:\.[0-9]+)?\z' -or
        -not [decimal]::TryParse($depositText, [Globalization.NumberStyles]::AllowDecimalPoint, [Globalization.CultureInfo]::InvariantCulture, [ref]$depositValue) -or
        $depositValue -lt 1 -or $depositValue -gt 1000000000) {
        throw "Deposit must use invariant digits with an optional '.' fractional part and be from 1 through 1000000000."
    }
    $leverageValue = 0
    if (-not [int]::TryParse([string]$Leverage, [Globalization.NumberStyles]::Integer, [Globalization.CultureInfo]::InvariantCulture, [ref]$leverageValue) -or
        $leverageValue -lt 1 -or $leverageValue -gt 5000) {
        throw 'Leverage must be an integer from 1 through 5000.'
    }
    $executionModeValue = 0
    if (-not [int]::TryParse([string]$ExecutionMode, [Globalization.NumberStyles]::Integer, [Globalization.CultureInfo]::InvariantCulture, [ref]$executionModeValue) -or
        $executionModeValue -lt -1 -or $executionModeValue -gt 10000) {
        throw 'ExecutionMode must be an integer from -1 through 10000.'
    }
    Assert-SafeIniValue -Value ([string]$Currency) -Name 'Currency' -MaximumLength 8
    if ([string]$Currency -cnotmatch '\A[A-Z]{3,8}\z') {
        throw 'Currency must contain 3-8 uppercase letters.'
    }

    $Model = $modelValue
    $TimeoutSeconds = $timeoutValue
    $MaxJournalAppendBytes = $journalLimitValue
    $Deposit = $depositValue
    $Leverage = $leverageValue
    $ExecutionMode = $executionModeValue
    $Currency = [string]$Currency
    $result.inputs.model = $Model
    $result.inputs.deposit = $Deposit
    $result.inputs.currency = $Currency
    $result.inputs.leverage = $Leverage
    $result.inputs.execution_mode = $ExecutionMode
    $result.inputs.timeout_seconds = $TimeoutSeconds
    $result.inputs.max_journal_append_bytes = $MaxJournalAppendBytes

    $expectedExpertHash = $null
    if (-not [string]::IsNullOrWhiteSpace($ExpectedExpertSha256)) {
        if ([string]$ExpectedExpertSha256 -cnotmatch '\A[0-9A-Fa-f]{64}\z') {
            throw 'ExpectedExpertSha256 must contain exactly 64 hexadecimal characters.'
        }
        $expectedExpertHash = ([string]$ExpectedExpertSha256).ToLowerInvariant()
        $result.inputs.expected_expert_sha256 = $expectedExpertHash
    }
    # Never stage an uncommitted EX5: a failed compilation can leave an older
    # artifact at the same path. The profile wrapper enforces the same rule.
    if ($null -eq $expectedExpertHash -and [string]::IsNullOrWhiteSpace([string]$CompilationReceiptPath)) {
        throw 'Select the exact successful -CompilationReceiptPath or a trusted -ExpectedExpertSha256 for this run.'
    }

    Assert-SafeIniValue -Value $Symbol -Name 'Symbol' -MaximumLength 64
    if ($Symbol -match '[\\/]') {
        throw 'Symbol cannot contain a path separator.'
    }
    Assert-SafeIniValue -Value $Period -Name 'Period' -MaximumLength 16
    if ($Period -cnotmatch '\A[A-Za-z0-9_]+\z') {
        throw 'Period must contain only letters, numbers, or underscores.'
    }

    $from = [datetime]::MinValue
    $to = [datetime]::MinValue
    $culture = [Globalization.CultureInfo]::InvariantCulture
    if (-not [datetime]::TryParseExact($FromDate, 'yyyy.MM.dd', $culture, [Globalization.DateTimeStyles]::None, [ref]$from)) {
        throw "FromDate is not a valid date: $FromDate"
    }
    if (-not [datetime]::TryParseExact($ToDate, 'yyyy.MM.dd', $culture, [Globalization.DateTimeStyles]::None, [ref]$to)) {
        throw "ToDate is not a valid date: $ToDate"
    }
    if ($to -le $from) {
        throw 'ToDate must be later than FromDate.'
    }

    $markers = New-Object 'System.Collections.Generic.List[string]'
    foreach ($marker in @($ExpectedLogMarker)) {
        Assert-ExpectedApplicationMarker -Marker $marker -SourceName 'Each ExpectedLogMarker'
        if (-not $markers.Contains($marker)) {
            $markers.Add($marker)
        }
    }
    if (-not [string]::IsNullOrWhiteSpace($ExpectedLogMarkerFile)) {
        $markerFile = Resolve-ExistingFile -Path $ExpectedLogMarkerFile -Name 'ExpectedLogMarkerFile' -Tracker $pathEntryLeases -LeasesByPath $leasedPathEntries
        $markerFileEvidence = Read-ExpectedApplicationMarkerFile -Path $markerFile
        foreach ($marker in $markerFileEvidence.markers) {
            if (-not $markers.Contains($marker)) {
                $markers.Add($marker)
            }
        }
        $result.inputs.expected_log_marker_file = $markerFile
        $result.inputs.expected_log_marker_file_sha256 = Get-BytesSha256 -Bytes $markerFileEvidence.bytes
    }
    Assert-ExpectedApplicationMarkerSet -Markers $markers.ToArray()
    $markerHashes = New-Object 'System.Collections.Generic.List[string]'
    foreach ($marker in $markers) {
        $markerHashes.Add((Get-TextSha256 -Text $marker))
    }
    $result.inputs.expected_log_marker_count = $markers.Count
    $result.inputs.expected_log_marker_sha256 = $markerHashes.ToArray()
    if ($markerHashes.Count -gt 0) {
        $aggregateMaterial = "mql5-coding-markers-v1`n" + (@($markerHashes | Sort-Object) -join "`n")
        $result.inputs.expected_log_marker_aggregate_sha256 = Get-TextSha256 -Text $aggregateMaterial
    }

    $expert = Resolve-ExistingFile -Path $ExpertPath -Name 'ExpertPath' -Tracker $pathEntryLeases -LeasesByPath $leasedPathEntries
    if ([IO.Path]::GetExtension($expert) -ine '.ex5') {
        throw "ExpertPath must identify a compiled .ex5 file: $expert"
    }
    if ((Get-Item -LiteralPath $expert).Length -le 0) {
        throw "ExpertPath is empty: $expert"
    }

    if (-not [string]::IsNullOrWhiteSpace($CompilationReceiptPath)) {
        $stagingReadLocksReleased = $false
        $result.inputs.compilation_receipt = Test-Mql5CompilationReceipt -Path $CompilationReceiptPath -ExpertPath $expert -ExpectedExpertHash $expectedExpertHash -Tracker $stagingReadLocks -PathEntryLeases $pathEntryLeases -LeasesByPath $leasedPathEntries
        $expectedExpertHash = [string]$result.inputs.compilation_receipt.expert_sha256
        $result.inputs.expected_expert_sha256 = $expectedExpertHash
    }

    if (-not [string]::IsNullOrWhiteSpace($BuildSnapshotPath)) {
        $snapshotContext=[pscustomobject]@{locks=$stagingReadLocks;leases=$pathEntryLeases;by_path=$leasedPathEntries}
        $snapshotVerification=Test-Mql5BuildSnapshot $BuildSnapshotPath $CompilationReceiptPath ([IO.Path]::ChangeExtension($expert,'.mq5')) $snapshotContext
        Write-Output ('MQL5_BUILD_SNAPSHOT='+[IO.Path]::GetFullPath($BuildSnapshotPath))
        if ($snapshotVerification.coverage.before -ceq 'uncertain' -or $snapshotVerification.coverage.after -ceq 'uncertain') {Write-Output 'Source snapshot verifies known files; include coverage remains uncertain.'}
    }

    $preset = $null
    $presetInfo = $null
    $presetHash = $null
    if (-not [string]::IsNullOrWhiteSpace($SetPath)) {
        $preset = Resolve-ExistingFile -Path $SetPath -Name 'SetPath' -Tracker $pathEntryLeases -LeasesByPath $leasedPathEntries
        if ([IO.Path]::GetExtension($preset) -ine '.set') {
            throw "SetPath must identify a .set file: $preset"
        }
        $presetInfo = Get-Item -LiteralPath $preset
        $presetHash = Get-FileSha256 -Path $preset
    }

    if (-not (Test-IsAbsoluteLocalDrivePath -Path $OutputDirectory)) {
        throw 'OutputDirectory must be an absolute path.'
    }
    $output = ConvertTo-NormalizedDirectoryPath -Path $OutputDirectory
    $outputParent = Split-Path -Parent $output
    $outputParentLease = Open-NonReparseDirectoryChain `
        -Path $outputParent `
        -Tracker $pathEntryLeases `
        -LeasesByPath $leasedPathEntries
    $null = Open-DirectoryMutationGuard `
        -Path $outputParent `
        -DirectoryLease $outputParentLease `
        -Tracker $directoryMutationGuards `
        -GuardsByPath $guardedDirectories `
        -RunId $runId
    $outputCreation = Open-OrCreateNonReparseDirectory `
        -Path $output `
        -Tracker $pathEntryLeases `
        -LeasesByPath $leasedPathEntries
    if (-not [bool]$outputCreation.created) {
        throw "OutputDirectory must not already exist: $output"
    }
    $outputCreated = $true
    $outputDirectoryLease = $outputCreation.lease
    $outputClaim = Open-NewOutputDirectoryClaim -Path $output -RunId $runId -DirectoryLease $outputDirectoryLease -IntegrityTracker $stagingReadLocks -PathEntryLeases $pathEntryLeases -LeasesByPath $leasedPathEntries
    $resultPath = Join-Path $output 'smoke-result.json'

    $binding = Resolve-TerminalBinding -RequestedTerminalPath $TerminalPath -RequestedDataPath $TerminalDataPath -Tracker $pathEntryLeases -LeasesByPath $leasedPathEntries
    $terminal = [string]$binding.terminal_path
    $data = [string]$binding.terminal_data_path
    $mql5 = Join-Path $data 'MQL5'
    $expertsRoot = Join-Path $mql5 'Experts'
    $profilesRoot = Join-Path $mql5 'Profiles\Tester'
    $terminalLogRoot = Join-Path $data 'logs'
    $testerLogRoot = Join-Path $data 'Tester\logs'
    $terminalPathLease = Open-NonReparseFileLeaf -Path $terminal -Tracker $pathEntryLeases -LeasesByPath $leasedPathEntries
    $mutationGuardDirectories = @(
        $expertsRoot,
        $profilesRoot,
        $terminalLogRoot,
        $testerLogRoot
    )
    foreach ($requiredDirectory in @($data, $mql5) + $mutationGuardDirectories) {
        $requiredDirectoryLease = Open-NonReparseDirectoryChain `
            -Path $requiredDirectory `
            -Tracker $pathEntryLeases `
            -LeasesByPath $leasedPathEntries
        if ($mutationGuardDirectories -icontains $requiredDirectory) {
            $null = Open-DirectoryMutationGuard `
                -Path $requiredDirectory `
                -DirectoryLease $requiredDirectoryLease `
                -Tracker $directoryMutationGuards `
                -GuardsByPath $guardedDirectories `
                -RunId $runId
        }
    }
    $originPathLease = Open-NonReparseFileLeaf -Path (Join-Path $data 'origin.txt') -Tracker $pathEntryLeases -LeasesByPath $leasedPathEntries

    $result.binding = [ordered]@{
        terminal_path = $terminal
        terminal_data_path = $data
        output_directory = $output
        terminal_image = $null
        terminal_origin = $null
    }

    # MT5 is launched with only /config, so it opens the default data
    # directory bound to its installation, not necessarily the selected one.
    # Inspect that directory and refuse a mismatch before any staging write.
    $accountState = Get-TerminalSavedAccountState -TerminalPath $terminal -SelectedDataPath $data -Tracker $pathEntryLeases -LeasesByPath $leasedPathEntries
    $result.safety.default_data_directories = @($accountState.default_data_directories)
    $result.safety.selected_data_directory_is_default_for_terminal = [bool]$accountState.selected_is_default
    $result.safety.saved_account_inspection = [string]$accountState.state
    $result.safety.saved_accounts_detected = if ($accountState.state -ceq 'unknown') { $null } else { $accountState.state -ceq 'present' }
    $result.safety.saved_account_risk_acknowledgement_required = $accountState.state -cne 'none'
    Assert-TerminalStartupDataDirectory -AccountState $accountState
    if ($accountState.state -cne 'none') {
        $accountMessage = if ($accountState.state -ceq 'present') {
            'The terminal has saved account credentials. Starting it may log into that (possibly live) account and resume Signals copying.'
        } else {
            "Saved account state could not be inspected: $($accountState.reason)"
        }
        if ($Execute -and -not $AcknowledgeSavedAccountRisk) {
            throw "BLOCKED: $accountMessage Get explicit user confirmation, then rerun with -AcknowledgeSavedAccountRisk, or use a dedicated terminal without saved accounts."
        }
        $warnings.Add($accountMessage)
    }

    $lock = Open-DataDirectoryLock -TerminalDataPath $data -RunId $runId
    $stagingReadLocksReleased = $false
    $terminalImageRecord = Open-TerminalImageReadLock -Path $terminal -Tracker $stagingReadLocks
    if ($terminalImageRecord.file_identity -cne [string]$terminalPathLease.Identity) {
        throw 'Terminal executable identity changed while its path-chain lease was established.'
    }
    $result.binding.terminal_image = [ordered]@{
        path = $terminalImageRecord.destination_path
        byte_length = [long]$terminalImageRecord.byte_length
        sha256 = $terminalImageRecord.sha256
        file_identity = $terminalImageRecord.file_identity
        read_lock_acquired = $true
    }
    $originRecord = Open-TerminalOriginReadLock `
        -TerminalDataPath $data `
        -TerminalPath $terminal `
        -ExpectedInstallPath $binding.terminal_install_path `
        -Tracker $stagingReadLocks
    if ($originRecord.file_identity -cne [string]$originPathLease.Identity) {
        throw 'Terminal origin identity changed while its path-chain lease was established.'
    }
    $result.binding.terminal_origin = [ordered]@{
        path = $originRecord.destination_path
        install_path = $originRecord.install_path
        byte_length = [long]$originRecord.byte_length
        sha256 = $originRecord.sha256
        read_lock_acquired = $true
    }
    $conflicts = @(Get-MatchingTerminalProcesses -ExecutablePath $terminal -ExpectedFileIdentity $terminalImageRecord.file_identity)
    if ($conflicts.Count -gt 0) {
        $pids = @($conflicts | ForEach-Object { $_.process_id })
        throw "BLOCKED: The bound MT5 terminal is already running (PID(s) $($pids -join ', ')). Close it before an isolated smoke run; the runner will not stop it."
    }

    $expertHash = Get-FileSha256 -Path $expert
    if ($null -ne $expectedExpertHash -and $expertHash -cne $expectedExpertHash) {
        throw "ExpertPath SHA-256 does not match ExpectedExpertSha256: $expert"
    }
    $expertInfo = Get-Item -LiteralPath $expert
    $expertLeaf = [IO.Path]::GetFileName($expert)
    Assert-SafeIniValue -Value $expertLeaf -Name 'Expert file name' -MaximumLength 128
    $expertStageRoot = Join-Path $expertsRoot 'CodexSmoke'
    $expertStageDirectory = Join-Path $expertStageRoot $runId
    $expertStage = Join-Path $expertStageDirectory $expertLeaf
    $expertRelative = "CodexSmoke\$runId\$expertLeaf"
    Assert-SafeIniValue -Value $expertRelative -Name 'Expert relative path' -MaximumLength 220

    $presetLeaf = $null
    $presetStage = $null
    if ($null -ne $preset) {
        $presetLeaf = "CodexSmoke-$runId.set"
        $presetStage = Join-Path $profilesRoot $presetLeaf
    }

    $configStage = Join-Path $data "CodexSmoke-$runId.ini"
    $reportLeaf = "CodexSmokeReport-$runId.htm"
    $reportStage = Join-Path $data $reportLeaf
    $reportCompanionStages = @(
        foreach ($suffix in @('.png', '-hst.png', '-mfemae.png', '-holding.png')) {
            Join-Path $data ("CodexSmokeReport-$runId$suffix")
        }
    )
    $allMt5StagePaths = @($expertStage, $configStage, $reportStage) + @($reportCompanionStages)
    if ($null -ne $presetStage) {
        $allMt5StagePaths += $presetStage
    }
    foreach ($path in $allMt5StagePaths) {
        if ($path.Length -gt 259) {
            throw "Owned MT5 staging path exceeds 259 characters: $path"
        }
    }

    $configLines = New-Object 'System.Collections.Generic.List[string]'
    foreach ($line in @(
            '[Common]',
            'NewsEnable=0',
            'CertInstall=0',
            '',
            '[Experts]',
            'AllowLiveTrading=0',
            'AllowDllImport=0',
            'Enabled=0',
            'Account=0',
            'Profile=0',
            '',
            '[Tester]',
            "Expert=$($expertRelative.Replace('/', '\'))"
        )) {
        $configLines.Add($line)
    }
    if ($null -ne $presetLeaf) {
        $configLines.Add("ExpertParameters=$presetLeaf")
    }
    foreach ($line in @(
            "Symbol=$Symbol",
            "Period=$Period",
            "Model=$Model",
            "ExecutionMode=$ExecutionMode",
            'Optimization=0',
            'OptimizationCriterion=0',
            "FromDate=$FromDate",
            "ToDate=$ToDate",
            'ForwardMode=0',
            "Report=$reportLeaf",
            'ReplaceReport=1',
            'ShutdownTerminal=1',
            ('Deposit=' + $Deposit.ToString([Globalization.CultureInfo]::InvariantCulture)),
            "Currency=$Currency",
            "Leverage=$Leverage",
            'ProfitInPips=0',
            'UseLocal=1',
            'UseRemote=0',
            'UseCloud=0',
            'Visual=0',
            ''
        )) {
        $configLines.Add($line)
    }
    if ($null -eq $presetLeaf) {
        $configLines.Add('[TesterInputs]')
        $configLines.Add('')
    }
    $configContent = ($configLines -join "`r`n")
    $canonicalConfig = Join-Path $output 'tester-start.ini'
    $utf16 = New-Object Text.UnicodeEncoding($false, $true)
    $canonicalConfigRecord = Open-NewTextArtifactReadLock -Text $configContent -Path $canonicalConfig -Encoding $utf16 -Kind 'canonical startup config' -Tracker $stagingReadLocks -PathEntryLeases $pathEntryLeases -LeasesByPath $leasedPathEntries
    if ($stagingReadLocks.Count -eq 0) {
        throw 'Canonical startup config creation did not retain its exact output stream.'
    }
    $canonicalConfigLock = $stagingReadLocks[$stagingReadLocks.Count - 1]
    if (-not [object]::ReferenceEquals(
            $canonicalConfigLock.record,
            $canonicalConfigRecord
        )) {
        throw 'Canonical startup config creation returned a mismatched retained stream.'
    }
    $canonicalConfigHash = $canonicalConfigRecord.sha256

    $result.artifacts = [ordered]@{
        output_owner = [ordered]@{
            path = $outputClaim.owner_path
            byte_length = [long]$outputClaim.owner_record.byte_length
            sha256 = $outputClaim.owner_sha256
        }
        expert = [ordered]@{
            source_path = $expert
            relative_tester_path = $expertRelative.Replace('/', '\')
            byte_length = [long]$expertInfo.Length
            sha256 = $expertHash
            staged_copy_required = $true
            staged_copy = $null
            executed_copy = $null
        }
        preset = if ($null -eq $preset) {
            $null
        }
        else {
            [ordered]@{
                source_path = $preset
                byte_length = [long]$presetInfo.Length
                sha256 = $presetHash
                staged_copy = $null
                executed_copy = $null
            }
        }
        canonical_config = [ordered]@{
            path = $canonicalConfig
            byte_length = [long]$canonicalConfigRecord.byte_length
            sha256 = $canonicalConfigHash
            encoding = 'utf-16le-bom'
            newline = 'crlf'
            staged_copy = $null
            executed_copy = $null
        }
        report = $null
        staging_integrity = [ordered]@{
            read_locks_acquired = $false
            prelaunch_verified = $false
            postrun_verified = $null
        }
    }
    $expertStageRootCreation = Open-OrCreateNonReparseDirectory `
        -Path $expertStageRoot `
        -Tracker $pathEntryLeases `
        -LeasesByPath $leasedPathEntries
    if ([bool]$expertStageRootCreation.created) {
        $createdDirectories.Add($expertStageRoot)
    }
    $expertStageRootLease = $expertStageRootCreation.lease
    $null = Open-DirectoryMutationGuard `
        -Path $expertStageRoot `
        -DirectoryLease $expertStageRootLease `
        -Tracker $directoryMutationGuards `
        -GuardsByPath $guardedDirectories `
        -RunId $runId
    $expertStageDirectory = Split-Path -Parent $expertStage
    $expertStageDirectoryCreation = Open-OrCreateNonReparseDirectory `
        -Path $expertStageDirectory `
        -Tracker $pathEntryLeases `
        -LeasesByPath $leasedPathEntries
    if (-not [bool]$expertStageDirectoryCreation.created) {
        throw "Refusing to reuse an existing run staging directory: $expertStageDirectory"
    }
    $createdDirectories.Add($expertStageDirectory)
    $expertStageDirectoryLease = $expertStageDirectoryCreation.lease
    $null = Open-DirectoryMutationGuard `
        -Path $expertStageDirectory `
        -DirectoryLease $expertStageDirectoryLease `
        -Tracker $directoryMutationGuards `
        -GuardsByPath $guardedDirectories `
        -RunId $runId
    $stageRecord = Copy-NewHashBoundFile -Source $expert -Destination $expertStage -Kind 'expert' -Tracker $hashBoundStaging -PathEntryLeases $pathEntryLeases -LeasesByPath $leasedPathEntries
    if ($stageRecord.sha256 -cne $expertHash -or [long]$stageRecord.byte_length -ne [long]$expertInfo.Length) {
        throw 'Expert source bytes changed while the hash-bound staging copy was prepared.'
    }
    $result.artifacts.expert.staged_copy = [ordered]@{
        path = $stageRecord.destination_path
        byte_length = [long]$stageRecord.byte_length
        sha256 = $stageRecord.sha256
    }
    if ($Execute) {
        $result.artifacts.expert.executed_copy = $result.artifacts.expert.staged_copy
    }
    if ($null -ne $presetStage) {
        $presetRecord = Copy-NewHashBoundFile -Source $preset -Destination $presetStage -Kind 'preset' -Tracker $hashBoundStaging -PathEntryLeases $pathEntryLeases -LeasesByPath $leasedPathEntries
        if ($presetRecord.sha256 -cne $presetHash -or [long]$presetRecord.byte_length -ne [long]$presetInfo.Length) {
            throw 'Preset source bytes changed while the hash-bound staging copy was prepared.'
        }
        $result.artifacts.preset.staged_copy = [ordered]@{
            path = $presetRecord.destination_path
            byte_length = [long]$presetRecord.byte_length
            sha256 = $presetRecord.sha256
        }
        if ($Execute) {
            $result.artifacts.preset.executed_copy = $result.artifacts.preset.staged_copy
        }
    }
    $configRecord = Copy-NewHashBoundFile `
        -Source $canonicalConfig `
        -Destination $configStage `
        -Kind 'startup config' `
        -Tracker $hashBoundStaging `
        -PathEntryLeases $pathEntryLeases `
        -LeasesByPath $leasedPathEntries `
        -RetainedSourceStream $canonicalConfigLock.stream
    if ($configRecord.sha256 -cne $canonicalConfigHash -or [long]$configRecord.byte_length -ne [long]$canonicalConfigRecord.byte_length) {
        throw 'Canonical startup config bytes changed while the staging copy was prepared.'
    }
    $result.artifacts.canonical_config.staged_copy = [ordered]@{
        path = $configRecord.destination_path
        byte_length = [long]$configRecord.byte_length
        sha256 = $configRecord.sha256
    }
    if ($Execute) {
        $result.artifacts.canonical_config.executed_copy = $result.artifacts.canonical_config.staged_copy
    }

    foreach ($generatedPath in @($reportStage) + @($reportCompanionStages)) {
        if ([bool]$Execute) {
            $null = Open-NewMutableOutputFileReservation `
                -Path $generatedPath `
                -Tracker $pathEntryLeases `
                -LeasesByPath $leasedPathEntries
            $generatedOwnedPaths.Add($generatedPath)
        }
        else {
            $existingGeneratedLease = Try-OpenNonReparseFileLeaf `
                -Path $generatedPath `
                -Tracker $pathEntryLeases `
                -LeasesByPath $leasedPathEntries
            if ($null -ne $existingGeneratedLease) {
                throw "Refusing to reuse an existing generated report path: $generatedPath"
            }
        }
    }

    $stagingReadLocksReleased = $false
    $integrityRecordsToLock = @($hashBoundStaging.ToArray())
    Open-StagingReadLocks -Records $integrityRecordsToLock -Tracker $stagingReadLocks -PathEntryLeases $pathEntryLeases -LeasesByPath $leasedPathEntries
    $stagingReadLockAcquisitionCompleted = $true
    $result.artifacts.staging_integrity.read_locks_acquired = $true
    $prelaunchIntegrityFailures = @(Get-PinnedStagingIntegrityFailures -Locks $stagingReadLocks)
    if ($prelaunchIntegrityFailures.Count -gt 0) {
        throw "Staged input integrity failed before launch: $($prelaunchIntegrityFailures -join ' ')"
    }
    $result.artifacts.staging_integrity.prelaunch_verified = $true

    $beforeTerminal = Get-JournalSnapshot -RootPath $terminalLogRoot -PathEntryLeases $pathEntryLeases -LeasesByPath $leasedPathEntries -StreamTracker $journalReadStreams
    $beforeTester = Get-JournalSnapshot -RootPath $testerLogRoot -PathEntryLeases $pathEntryLeases -LeasesByPath $leasedPathEntries -StreamTracker $journalReadStreams

    if ($PreflightOnly) {
        $preflightFinalConflicts = @(Get-MatchingTerminalProcesses -ExecutablePath $terminal -ExpectedFileIdentity $terminalImageRecord.file_identity)
        if ($preflightFinalConflicts.Count -gt 0) {
            $pids = @($preflightFinalConflicts | ForEach-Object { $_.process_id })
            throw "BLOCKED: The bound MT5 terminal started during preflight (PID(s) $($pids -join ', ')); preflight readiness is no longer valid."
        }
        $result.status = 'preflight_passed'
        $warnings.Add('PreflightOnly was used: staging paths, bytes, journal readability, and process-isolation preconditions were verified at the final check, but no MT5 process was started by the runner and no Strategy Tester behavior was validated.')
        $exitCode = 0
    }
    else {
        $conflicts = @(Get-MatchingTerminalProcesses -ExecutablePath $terminal -ExpectedFileIdentity $terminalImageRecord.file_identity)
        if ($conflicts.Count -gt 0) {
            $pids = @($conflicts | ForEach-Object { $_.process_id })
            throw "BLOCKED: The bound MT5 terminal started during preflight (PID(s) $($pids -join ', ')); refusing to continue."
        }

        Assert-Mql5Terminal $terminal | Out-Null
        $result.process.execution_attempted = $true
        $jobLaunch = [Mql5Coding.JobProcessLaunch]::CreateSuspended(
            $terminal,
            $configStage,
            (Split-Path -Parent $terminal)
        )
        $ownedProcessTreeTerminationVerified = $false
        $result.process.process_created = $true
        $result.process.process_id = [int]$jobLaunch.ProcessId
        $result.process.job_containment_established = $true
        $process = [Diagnostics.Process]::GetProcessById([int]$jobLaunch.ProcessId)
        $spawnedImagePath = [IO.Path]::GetFullPath($jobLaunch.GetImagePath())
        $spawnedImageFileIdentity = Get-FileIdentityFromPath -Path $spawnedImagePath
        if ($spawnedImageFileIdentity -cne [string]$terminalImageRecord.file_identity) {
            throw (
                "BLOCKED: Suspended PID $($process.Id) did not map to the pinned " +
                'terminal executable file identity.'
            )
        }
        $spawnedProcessIdentity = Get-SpawnedProcessIdentity `
            -Process $process `
            -ExecutablePath $spawnedImagePath `
            -ExecutableFileIdentity $spawnedImageFileIdentity

        $postStartMatches = @(
            Get-MatchingTerminalProcesses `
                -ExecutablePath $terminal `
                -ExpectedFileIdentity $terminalImageRecord.file_identity `
                -TrustedSuspendedIdentity $spawnedProcessIdentity
        )
        $ownedMatches = @($postStartMatches | Where-Object { [int]$_.process_id -eq [int]$process.Id })
        if ($postStartMatches.Count -ne 1 -or $ownedMatches.Count -ne 1) {
            $observed = @($postStartMatches | ForEach-Object { $_.process_id })
            throw "BLOCKED: Suspended terminal identity was not exactly the owned PID $($process.Id); observed PID(s): $($observed -join ', ')."
        }
        if (
            $null -eq $ownedMatches[0].creation_utc_ticks -or
            $null -eq $ownedMatches[0].session_id
        ) {
            throw "BLOCKED: Creation time or session was unavailable for the owned suspended terminal PID $($process.Id)."
        }
        $result.process.post_start_identity_verified = $true
        $result.process.identity_source = 'pinned_file_identity_and_suspended_cim_cross_check'

        $jobLaunch.Resume()
        $result.process.resumed = $true

        $completed = $process.WaitForExit($TimeoutSeconds * 1000)
        if (-not $completed) {
            $result.process.timed_out = $true
            $ownedProcessTreeTerminationVerified = $false
            $jobLaunch.TerminateAndWaitForEmpty(5000)
            $ownedProcessTreeTerminationVerified = $true
        }
        else {
            $result.process.exit_code = [int]$process.ExitCode
            $ownedProcessTreeTerminationVerified = $false
            $jobLaunch.TerminateAndWaitForEmpty(5000)
            $ownedProcessTreeTerminationVerified = $true
        }
        $result.process.job_empty_verified = $true
        $result.process.post_exit_no_potential_descendants = $true
        if ($process.HasExited) {
            $result.process.exit_code = [int]$process.ExitCode
        }

        # Win32_Process can briefly retain a terminated row after the owned Job Object is empty.
        # Retry only at this post-containment boundary; prelaunch isolation checks remain immediate.
        $postExitMatches = @(
            Wait-ForNoMatchingTerminalProcesses `
                -ExecutablePath $terminal `
                -ExpectedFileIdentity $terminalImageRecord.file_identity `
                -VerifiedOwnedProcessIdentity $ownedMatches[0] `
                -TimeoutMilliseconds 5000 `
                -PollMilliseconds 100
        )
        if ($postExitMatches.Count -gt 0) {
            $remaining = @($postExitMatches | ForEach-Object { $_.process_id })
            throw "BLOCKED: Bound terminal PID(s) $($remaining -join ', ') remained after the owned process ended. The runner will not stop them."
        }
        $result.process.post_exit_no_matching_terminal = $true

        $postrunIntegrityFailures = @(Get-PinnedStagingIntegrityFailures -Locks $stagingReadLocks)
        $postrunIntegrityValid = $postrunIntegrityFailures.Count -eq 0
        $result.artifacts.staging_integrity.postrun_verified = $postrunIntegrityValid
        foreach ($failure in $postrunIntegrityFailures) {
            $errors.Add($failure)
        }

        $terminalDelta = Read-JournalDelta -Before $beforeTerminal -RootPath $terminalLogRoot -LogicalName 'terminal' -MaximumBytes $MaxJournalAppendBytes -PathEntryLeases $pathEntryLeases -LeasesByPath $leasedPathEntries -StreamTracker $journalReadStreams
        $testerDelta = Read-JournalDelta -Before $beforeTester -RootPath $testerLogRoot -LogicalName 'tester' -MaximumBytes $MaxJournalAppendBytes -PathEntryLeases $pathEntryLeases -LeasesByPath $leasedPathEntries -StreamTracker $journalReadStreams

        $terminalText = [string]$terminalDelta.text
        $testerText = [string]$testerDelta.text
        $configLaunchNeedle = "successfully initialized from start config `"$configStage`""
        $configIndex = Get-TextIndex -Text $terminalText -Needle $configLaunchNeedle
        $genericConfigLaunchNeedle = 'successfully initialized from start config'
        $nextConfigIndex = if ($configIndex -ge 0) {
            Get-TextIndex `
                -Text $terminalText `
                -Needle $genericConfigLaunchNeedle `
                -StartIndex ($configIndex + $configLaunchNeedle.Length)
        }
        else {
            -1
        }
        $terminalWindowEnd = if ($nextConfigIndex -ge 0) {
            $nextConfigIndex
        }
        else {
            $terminalText.Length
        }
        $automaticStartedIndex = if ($configIndex -ge 0) {
            $foundAutomaticStart = Get-TextIndex `
                -Text $terminalText `
                -Needle 'automatic testing started' `
                -StartIndex ($configIndex + $configLaunchNeedle.Length)
            if ($foundAutomaticStart -ge 0 -and $foundAutomaticStart -lt $terminalWindowEnd) {
                $foundAutomaticStart
            }
            else {
                -1
            }
        }
        else {
            -1
        }
        $terminalSuccessNeedle = 'last test passed with result "successfully finished"'
        $terminalSucceededIndex = if ($automaticStartedIndex -ge 0) {
            $foundTerminalSuccess = Get-TextIndex `
                -Text $terminalText `
                -Needle $terminalSuccessNeedle `
                -StartIndex ($automaticStartedIndex + 'automatic testing started'.Length)
            if ($foundTerminalSuccess -ge 0 -and $foundTerminalSuccess -lt $terminalWindowEnd) {
                $foundTerminalSuccess
            }
            else {
                -1
            }
        }
        else {
            -1
        }
        $configCorrelated = $configIndex -ge 0
        $automaticStarted = $automaticStartedIndex -ge 0
        $terminalSucceeded = $terminalSucceededIndex -ge 0
        $terminalSequenceOrdered = (
            $configIndex -ge 0 -and
            $automaticStartedIndex -gt $configIndex -and
            $terminalSucceededIndex -gt $automaticStartedIndex
        )
        # The installed CHM does not define journal syntax. Accept only the
        # sample-backed system layouts below and fail closed on unknown layouts.
        $testerSystemHeaderPattern = (
            '(?:' +
                '(?:\d{2}:\d{2}:\d{2}(?:\.\d{1,3})?\tTester\t)' +
                '|(?:[A-Z]{2}\t\d+\t\d{2}:\d{2}:\d{2}(?:\.\d{1,3})?\tCore \d+\t)' +
                '|(?:\d{4}\.\d{2}\.\d{2} \d{2}:\d{2}:\d{2}(?:\.\d{1,3})?\tCore \d+\t)' +
            ')'
        )
        $testerApplicationHeaderPattern = (
            '(?:' +
                '(?:\d{2}:\d{2}:\d{2}(?:\.\d{1,3})?\t' +
                    '(?![Tt][Ee][Ss][Tt][Ee][Rr]\t)[^\r\n\t]+\t)' +
                '|(?:[A-Z]{2}\t\d+\t\d{2}:\d{2}:\d{2}(?:\.\d{1,3})?\tCore \d+\t)' +
                '|(?:\d{4}\.\d{2}\.\d{2} \d{2}:\d{2}:\d{2}(?:\.\d{1,3})?\tCore \d+\t)' +
            ')'
        )
        $simulatedTimePattern = (
            '\d{4}\.\d{2}\.\d{2} ' +
            '\d{2}:\d{2}:\d{2}(?:\.\d{1,3})?[ ]+'
        )
        $testerApplicationLinePrefix = (
            '(?m)^' +
            $testerApplicationHeaderPattern +
            '[ ]*' +
            $simulatedTimePattern
        )
        $testerSystemMessagePrefix = (
            '(?m)^' +
            $testerSystemHeaderPattern +
            '(?![ ]*' + $simulatedTimePattern + ')' +
            '[ ]*'
        )

        $testStartNeedle = (
            $Symbol + ',' + $Period + ': testing of Experts\' +
            $expertRelative.Replace('/', '\') +
            ' from ' + $FromDate + ' 00:00 to ' + $ToDate + ' 00:00'
        )
        $testStartRecord = $testStartNeedle + ' started with inputs:'
        $testStartPattern = (
            $testerSystemMessagePrefix +
            [regex]::Escape($testStartRecord) +
            '[ ]*\r?$'
        )
        $testStartRegex = New-Object Text.RegularExpressions.Regex(
            $testStartPattern,
            [Text.RegularExpressions.RegexOptions]::IgnoreCase
        )
        $testPassedPattern = (
            $testerSystemMessagePrefix +
            [regex]::Escape("$Symbol,$Period") +
            ':[^\r\n]*Test passed in \d+:\d{2}:\d{2}(?:\.\d+)?[^\r\n]*\r?$'
        )
        $testPassedRegex = New-Object Text.RegularExpressions.Regex(
            $testPassedPattern,
            [Text.RegularExpressions.RegexOptions]::IgnoreCase
        )
        $testerInitializedNeedle = 'successfully initialized'
        $testerInitializedPattern = (
            $testerSystemMessagePrefix +
            '(?![^=\r\n]+=[^\r\n]*' +
                [regex]::Escape($testerInitializedNeedle) + ')' +
            '[^\r\n]*' + [regex]::Escape($testerInitializedNeedle) +
            '[^\r\n]*\r?$'
        )
        $testerInitializedRegex = New-Object Text.RegularExpressions.Regex(
            $testerInitializedPattern,
            [Text.RegularExpressions.RegexOptions]::IgnoreCase
        )
        $genericTestStartSignal = 'testing of Experts\'
        $genericTestStartPattern = (
            $testerSystemMessagePrefix +
            '(?![^=\r\n]+=[^\r\n]*' +
                [regex]::Escape($genericTestStartSignal) + ')' +
            '[^,\r\n]+,[^:\r\n]+:[ ]*testing of Experts\\[^\r\n]+ ' +
            'from \d{4}\.\d{2}\.\d{2} \d{2}:\d{2} ' +
            'to \d{4}\.\d{2}\.\d{2} \d{2}:\d{2} ' +
            'started with inputs:[ ]*\r?$'
        )
        $genericTestStartRegex = New-Object Text.RegularExpressions.Regex(
            $genericTestStartPattern,
            [Text.RegularExpressions.RegexOptions]::IgnoreCase
        )
        $onInitFailureNeedle = 'tester stopped because OnInit returns non-zero'
        $onInitFailurePattern = (
            $testerSystemMessagePrefix +
            '(?![^=\r\n]+=[^\r\n]*' +
                [regex]::Escape($onInitFailureNeedle) + ')' +
            '[^\r\n]*' + [regex]::Escape($onInitFailureNeedle) +
            '[^\r\n]*\r?$'
        )
        $onInitFailureRegex = New-Object Text.RegularExpressions.Regex(
            $onInitFailurePattern,
            [Text.RegularExpressions.RegexOptions]::IgnoreCase
        )
        $testerInitializedMatches = $testerInitializedRegex.Matches($testerText)
        $genericTestStartMatches = $genericTestStartRegex.Matches($testerText)
        $testCandidates = New-Object 'System.Collections.Generic.List[object]'
        $candidateSearchIndex = 0
        while ($candidateSearchIndex -lt $testerText.Length) {
            $candidateStartMatch = $testStartRegex.Match($testerText, $candidateSearchIndex)
            if (-not $candidateStartMatch.Success) {
                break
            }
            $candidateStart = [int]$candidateStartMatch.Index
            $candidateEnd = $candidateStart + [int]$candidateStartMatch.Length
            $previousGenericStart = -1
            foreach ($genericStartMatch in $genericTestStartMatches) {
                if ([int]$genericStartMatch.Index -ge $candidateStart) {
                    break
                }
                $previousGenericStart = [int]$genericStartMatch.Index
            }
            $candidateInitialized = -1
            foreach ($initializedMatch in $testerInitializedMatches) {
                if ([int]$initializedMatch.Index -ge $candidateStart) {
                    break
                }
                $candidateInitialized = [int]$initializedMatch.Index
            }
            $initializationInWindow = (
                $candidateInitialized -ge 0 -and
                ($previousGenericStart -lt 0 -or $candidateInitialized -gt $previousGenericStart)
            )
            $nextGenericStart = -1
            foreach ($genericStartMatch in $genericTestStartMatches) {
                if ([int]$genericStartMatch.Index -ge $candidateEnd) {
                    $nextGenericStart = [int]$genericStartMatch.Index
                    break
                }
            }
            $candidateWindowEnd = if ($nextGenericStart -ge 0) {
                $nextGenericStart
            }
            else {
                $testerText.Length
            }
            $candidatePassMatch = $testPassedRegex.Match($testerText, $candidateEnd)
            $candidatePassIndex = if (
                $candidatePassMatch.Success -and
                [int]$candidatePassMatch.Index -lt $candidateWindowEnd
            ) {
                [int]$candidatePassMatch.Index
            }
            else {
                -1
            }
            $candidateOnInitMatch = $onInitFailureRegex.Match($testerText, $candidateEnd)
            $candidateOnInitFailure = if ($candidateOnInitMatch.Success) {
                [int]$candidateOnInitMatch.Index
            }
            else {
                -1
            }
            $onInitFailureInWindow = (
                $candidateOnInitFailure -ge 0 -and
                $candidateOnInitFailure -lt $candidateWindowEnd
            )
            $candidateMarkerIndices = New-Object 'System.Collections.Generic.List[int]'
            $allCandidateMarkersMatched = $true
            foreach ($candidateMarker in $markers) {
                $candidateMarkerPattern = (
                    $testerApplicationLinePrefix +
                    [regex]::Escape($candidateMarker) +
                    '[ ]*\r?$'
                )
                $candidateMarkerRegex = New-Object Text.RegularExpressions.Regex(
                    $candidateMarkerPattern,
                    [Text.RegularExpressions.RegexOptions]::CultureInvariant
                )
                $candidateMarkerMatch = $candidateMarkerRegex.Match(
                    $testerText,
                    $candidateEnd
                )
                $candidateMarkerIndex = if ($candidateMarkerMatch.Success) {
                    [int]$candidateMarkerMatch.Index
                }
                else {
                    -1
                }
                $candidateMarkerEnd = if ($candidateMarkerMatch.Success) {
                    [int]$candidateMarkerMatch.Index + [int]$candidateMarkerMatch.Length
                }
                else {
                    -1
                }
                $candidateMarkerMatched = (
                    $candidateMarkerIndex -ge 0 -and
                    $candidateMarkerEnd -le $candidatePassIndex -and
                    $candidateMarkerEnd -le $candidateWindowEnd
                )
                if (-not $candidateMarkerMatched) {
                    $allCandidateMarkersMatched = $false
                    $candidateMarkerIndices.Add(-1)
                }
                else {
                    $candidateMarkerIndices.Add([int]$candidateMarkerIndex)
                }
            }
            $sequenceValid = (
                $initializationInWindow -and
                $candidatePassIndex -gt $candidateStart
            )
            $testCandidates.Add([pscustomobject][ordered]@{
                start_index = [int]$candidateStart
                end_index = [int]$candidateEnd
                window_end_index = [int]$candidateWindowEnd
                initialized_index = [int]$candidateInitialized
                pass_index = [int]$candidatePassIndex
                on_init_failed = [bool]$onInitFailureInWindow
                sequence_valid = [bool]$sequenceValid
                core_valid = [bool]($sequenceValid -and -not $onInitFailureInWindow)
                all_markers_matched = [bool]$allCandidateMarkersMatched
                marker_indices = $candidateMarkerIndices.ToArray()
            })
            $candidateSearchIndex = $candidateStart + 1
        }

        $selectedCandidate = if ($testCandidates.Count -eq 1) {
            $testCandidates[0]
        }
        else {
            $null
        }

        $expertCorrelated = $testCandidates.Count -eq 1
        $initializedIndex = if ($null -ne $selectedCandidate) {
            [int]$selectedCandidate.initialized_index
        }
        else {
            -1
        }
        $testStartIndex = if ($null -ne $selectedCandidate) {
            [int]$selectedCandidate.start_index
        }
        else {
            -1
        }
        $testPassedIndex = if ($null -ne $selectedCandidate) {
            [int]$selectedCandidate.pass_index
        }
        else {
            -1
        }
        $initialized = $initializedIndex -ge 0
        $testPassed = $testPassedIndex -ge 0
        $testerSequenceOrdered = (
            $null -ne $selectedCandidate -and
            [bool]$selectedCandidate.sequence_valid
        )
        $onInitFailed = if ($null -ne $selectedCandidate) {
            [bool]$selectedCandidate.on_init_failed
        }
        else {
            $onInitFailureRegex.IsMatch($testerText)
        }

        $markerEvidence = New-Object 'System.Collections.Generic.List[object]'
        $missingMarkerHashes = New-Object 'System.Collections.Generic.List[string]'
        for ($markerIndex = 0; $markerIndex -lt $markers.Count; $markerIndex++) {
            $markerHash = $markerHashes[$markerIndex]
            $markerMatched = (
                $null -ne $selectedCandidate -and
                $markerIndex -lt @($selectedCandidate.marker_indices).Count -and
                [int]$selectedCandidate.marker_indices[$markerIndex] -ge 0
            )
            $markerEvidence.Add([pscustomobject][ordered]@{
                sha256 = $markerHash
                matched = $markerMatched
            })
            if (-not $markerMatched) {
                $missingMarkerHashes.Add($markerHash)
            }
        }

        $terminalEvidence = Select-JournalEvidence -Text $terminalText -Patterns @(
            'successfully initialized from start config',
            'Terminal\s+launched with',
            'automatic testing started',
            'last test passed with result',
            'Terminal\s+exit with code'
        ) -SensitiveValues $markers.ToArray()
        $testerEvidence = Select-JournalEvidence -Text $testerText -Patterns @(
            'testing of Experts\\',
            'successfully initialized',
            'Test passed in ',
            'OnInit returns non-zero',
            '(?i)\b(error|failed|cannot load|stopped because)\b'
        ) -SensitiveValues $markers.ToArray()

        $result.evidence = [ordered]@{
            terminal_journal = [ordered]@{
                appended_byte_length = [long]$terminalDelta.appended_byte_length
                limit_exceeded = [bool]$terminalDelta.limit_exceeded
                segments = @($terminalDelta.records)
                excerpts = $terminalEvidence
            }
            tester_journal = [ordered]@{
                appended_byte_length = [long]$testerDelta.appended_byte_length
                limit_exceeded = [bool]$testerDelta.limit_exceeded
                segments = @($testerDelta.records)
                excerpts = $testerEvidence
            }
            expected_markers = [ordered]@{
                aggregate_sha256 = $result.inputs.expected_log_marker_aggregate_sha256
                entries = $markerEvidence.ToArray()
                missing_sha256 = $missingMarkerHashes.ToArray()
            }
            checks = [ordered]@{
                exact_config_launch = $configCorrelated
                automatic_testing_started = $automaticStarted
                terminal_evidence_ordered = $terminalSequenceOrdered
                exact_expert_symbol_period_dates = $expertCorrelated
                exact_test_candidate_count = $testCandidates.Count
                exact_test_window_selected = ($null -ne $selectedCandidate)
                tester_initialized = $initialized
                tester_engine_passed = $testPassed
                tester_evidence_ordered = $testerSequenceOrdered
                terminal_result_successfully_finished = $terminalSucceeded
                on_init_failure_absent = (-not $onInitFailed)
                expected_markers_supplied = ($markers.Count -gt 0)
                expected_markers_matched = ($markers.Count -gt 0 -and $missingMarkerHashes.Count -eq 0)
                missing_marker_count = $missingMarkerHashes.Count
                staged_inputs_unchanged = $postrunIntegrityValid
            }
        }

        $reportStageLease = Try-OpenNonReparseFileLeaf -Path $reportStage -Tracker $pathEntryLeases -LeasesByPath $leasedPathEntries
        if ($null -ne $reportStageLease) {
            $reportSourceRecord = Open-VerifiedArtifactReadLock -Path $reportStage -Kind 'generated report source' -Tracker $stagingReadLocks -PathEntryLeases $pathEntryLeases -LeasesByPath $leasedPathEntries
            if ([long]$reportSourceRecord.byte_length -gt 0) {
                $finalReport = Join-Path $output $reportLeaf
                $finalReportRecord = Copy-NewVerifiedOutputArtifact `
                    -Source $reportStage `
                    -Destination $finalReport `
                    -Kind 'output report' `
                    -SourceLease $reportStageLease `
                    -Tracker $outputArtifactPublicationLocks
                $reportCompanions = New-Object 'System.Collections.Generic.List[object]'
                foreach ($companionStage in $reportCompanionStages) {
                    $companionStageLease = Try-OpenNonReparseFileLeaf -Path $companionStage -Tracker $pathEntryLeases -LeasesByPath $leasedPathEntries
                    if ($null -eq $companionStageLease) {
                        continue
                    }
                    $companionSourceRecord = Open-VerifiedArtifactReadLock -Path $companionStage -Kind 'generated report companion source' -Tracker $stagingReadLocks -PathEntryLeases $pathEntryLeases -LeasesByPath $leasedPathEntries
                    if ([long]$companionSourceRecord.byte_length -le 0) {
                        continue
                    }
                    $companionFinal = Join-Path $output ([IO.Path]::GetFileName($companionStage))
                    $companionRecord = Copy-NewVerifiedOutputArtifact `
                        -Source $companionStage `
                        -Destination $companionFinal `
                        -Kind 'output report companion' `
                        -SourceLease $companionStageLease `
                        -Tracker $outputArtifactPublicationLocks
                    $reportCompanions.Add([pscustomobject][ordered]@{
                        path = $companionFinal
                        byte_length = [long]$companionRecord.byte_length
                        sha256 = $companionRecord.sha256
                    })
                }
                $result.artifacts.report = [ordered]@{
                    path = $finalReport
                    byte_length = [long]$finalReportRecord.byte_length
                    sha256 = $finalReportRecord.sha256
                    companions = $reportCompanions.ToArray()
                    required_for_pass = $false
                }
            }
            else {
                $warnings.Add('MT5 created an empty report; journal evidence remains authoritative for this smoke result.')
            }
        }
        else {
            $warnings.Add('MT5 did not create a report; report existence is optional and was not used as a pass condition.')
        }

        $journalLimitExceeded = [bool]$terminalDelta.limit_exceeded -or [bool]$testerDelta.limit_exceeded
        if ([bool]$terminalDelta.limit_exceeded) {
            $errors.Add("Terminal journal append exceeded the $MaxJournalAppendBytes-byte inspection limit.")
        }
        if ([bool]$testerDelta.limit_exceeded) {
            $errors.Add("Tester journal append exceeded the $MaxJournalAppendBytes-byte inspection limit.")
        }
        if ([bool]$result.process.timed_out) {
            $errors.Add("Strategy Tester exceeded the $TimeoutSeconds-second timeout.")
        }

        if (-not $postrunIntegrityValid -or $journalLimitExceeded) {
            $result.status = 'tooling_error'
            $exitCode = 2
        }
        elseif ([bool]$result.process.timed_out) {
            $result.status = 'timed_out'
            $exitCode = 3
        }
        else {
            if ($null -eq $result.process.exit_code -or [int]$result.process.exit_code -ne 0) {
                $errors.Add("Spawned MT5 process did not exit cleanly (exit code $($result.process.exit_code)).")
            }
            if (-not $configCorrelated) {
                $errors.Add('Terminal journal did not correlate the exact staged startup config.')
            }
            if (-not $automaticStarted) {
                $errors.Add('Terminal journal did not show automatic testing started.')
            }
            if (-not $terminalSequenceOrdered) {
                $errors.Add('Terminal journal did not show staged-config initialization, automatic test start, and successful finish in that order.')
            }
            if ($testCandidates.Count -gt 1) {
                $errors.Add(
                    "Tester journal contained $($testCandidates.Count) exact test candidates; evidence is ambiguous."
                )
            }
            elseif (-not $expertCorrelated) {
                $errors.Add('Tester journal did not correlate the exact expert, symbol, period, and dates.')
            }
            if (-not $initialized) {
                $errors.Add('Tester journal did not show successful agent initialization.')
            }
            if (-not $testPassed) {
                $errors.Add('Tester journal did not show a correlated engine Test passed result.')
            }
            if (-not $testerSequenceOrdered) {
                $errors.Add('Tester journal did not show initialization, the exact test start, and the correlated engine pass in that order.')
            }
            if (-not $terminalSucceeded) {
                $errors.Add('Terminal journal result was not exactly "successfully finished".')
            }
            if ($onInitFailed) {
                $errors.Add('Tester stopped because OnInit returned a non-zero code.')
            }
            if ($missingMarkerHashes.Count -gt 0) {
                $errors.Add("$($missingMarkerHashes.Count) caller-supplied expected log marker(s) were not found.")
            }

            if ($errors.Count -eq 0) {
                if ($markers.Count -gt 0) {
                    $result.status = 'application_marker_passed'
                }
                else {
                    $result.status = 'engine_smoke_passed'
                    $warnings.Add('No expected application marker was supplied. This proves only correlated Strategy Tester engine completion, not strategy correctness or full-date execution.')
                }
                $exitCode = 0
            }
            else {
                $result.status = 'tester_failed'
                $exitCode = 1
            }
        }
    }
}
catch {
    $launchFailure = $_.Exception
    while ($null -ne $launchFailure) {
        if ($launchFailure.Data.Contains('Mql5Coding.ProcessCreated')) {
            $result.process.process_created = [bool]$launchFailure.Data['Mql5Coding.ProcessCreated']
            $result.process.process_id = [int]$launchFailure.Data['Mql5Coding.ProcessId']
            $suspendedTerminationConfirmed = [bool]$launchFailure.Data['Mql5Coding.SuspendedTerminationConfirmed']
            $result.process.suspended_launch_cleanup = [ordered]@{
                termination_confirmed = $suspendedTerminationConfirmed
                terminate_process_succeeded = [bool]$launchFailure.Data['Mql5Coding.TerminateProcessSucceeded']
                terminate_process_error = [int]$launchFailure.Data['Mql5Coding.TerminateProcessError']
                wait_result = [long]$launchFailure.Data['Mql5Coding.WaitResult']
                wait_error = [int]$launchFailure.Data['Mql5Coding.WaitError']
            }
            $ownedProcessTreeTerminationVerified = $suspendedTerminationConfirmed
            if (-not $suspendedTerminationConfirmed) {
                $unsafePostLaunchIsolation = $true
            }
            break
        }
        $launchFailure = $launchFailure.InnerException
    }

    $message = $_.Exception.Message
    $isBlockedMessage = $message.StartsWith('BLOCKED:', [StringComparison]::Ordinal)
    if ($isBlockedMessage -and -not [bool]$result.process.execution_attempted) {
        $result.status = 'blocked'
        $errors.Add($message.Substring('BLOCKED:'.Length).Trim())
        $exitCode = 4
    }
    else {
        $result.status = 'tooling_error'
        if ($isBlockedMessage) {
            $unsafePostLaunchIsolation = $true
            $errors.Add(
                'Post-launch isolation failure: ' +
                $message.Substring('BLOCKED:'.Length).Trim()
            )
        }
        else {
            $errors.Add($message)
        }
        $exitCode = 2
    }
}
finally {
    if ($null -ne $jobLaunch) {
        try {
            if (-not $ownedProcessTreeTerminationVerified) {
                $jobLaunch.TerminateAndWaitForEmpty(5000)
                $ownedProcessTreeTerminationVerified = $true
                $result.process.job_empty_verified = $true
                $result.process.post_exit_no_potential_descendants = $true
            }
        }
        catch {
            $ownedProcessTreeTerminationVerified = $false
            $cleanupErrors.Add("Could not empty the owned Windows Job Object: $($_.Exception.Message)")
        }
    }

    if ($null -ne $process) {
        try {
            $process.Dispose()
        }
        catch {
            $cleanupErrors.Add("Could not dispose the terminal process handle: $($_.Exception.Message)")
        }
    }
    if ($null -ne $jobLaunch) {
        try {
            $jobLaunch.Dispose()
        }
        catch {
            $cleanupErrors.Add("Could not dispose the Windows Job Object handles: $($_.Exception.Message)")
        }
    }

    if ($stagingReadLocks.Count -gt 0) {
        if ([bool]$Execute) {
            $finalIntegrityFailures = @(Get-PinnedStagingIntegrityFailures -Locks $stagingReadLocks)
            if ($finalIntegrityFailures.Count -gt 0) {
                if ($result.artifacts -is [System.Collections.IDictionary] -and
                    $result.artifacts.Contains('staging_integrity')) {
                    $result.artifacts.staging_integrity.postrun_verified = $false
                }
                foreach ($failure in $finalIntegrityFailures) {
                    $cleanupErrors.Add("Final artifact integrity verification failed: $failure")
                }
            }
        }
        $lockReleaseFailed = $false
        for ($index = $stagingReadLocks.Count - 1; $index -ge 0; $index--) {
            try {
                $stagingReadLocks[$index].stream.Dispose()
            }
            catch {
                $lockReleaseFailed = $true
                $cleanupErrors.Add(
                    "Could not release the $($stagingReadLocks[$index].record.kind) integrity read lock: $($_.Exception.Message)"
                )
            }
        }
        $stagingReadLocksReleased = $stagingReadLockAcquisitionCompleted -and -not $lockReleaseFailed
    }

    for ($index = $journalReadStreams.Count - 1; $index -ge 0; $index--) {
        try {
            $journalReadStreams[$index].Dispose()
        }
        catch {
            $cleanupErrors.Add(
                "Could not release a pinned journal read stream: $($_.Exception.Message)"
            )
        }
    }


    $stagingArtifactsExist = (
        $hashBoundStaging.Count -gt 0 -or
        $generatedOwnedPaths.Count -gt 0 -or
        $createdDirectories.Count -gt 0
    )
    $executionStagingPreservationRequired = [bool]$Execute -and $stagingArtifactsExist
    $preflightStagingPreservationRequired = [bool]$PreflightOnly -and $stagingArtifactsExist
    $result.cleanup.execution_staging_preserved = $executionStagingPreservationRequired
    $result.cleanup.preflight_staging_preserved = $preflightStagingPreservationRequired
    $conservativeExecutionPreservation = (
        $executionStagingPreservationRequired -and
        $ownedProcessTreeTerminationVerified -and
        $stagingReadLocksReleased -and
        -not $unsafePostLaunchIsolation
    )
    $conservativePreflightPreservation = (
        $preflightStagingPreservationRequired -and
        $stagingReadLocksReleased -and
        -not [bool]$result.process.execution_attempted
    )
    $preservationReason = if ($conservativeExecutionPreservation) {
        'execution staging is retained because automatic pathname deletion is disabled'
    }
    elseif ($conservativePreflightPreservation) {
        'preflight staging is retained because automatic pathname deletion is disabled'
    }
    else {
        'process isolation or staging-lock release was not verified'
    }
    foreach ($record in $hashBoundStaging) {
        $path = [string]$record.destination_path
        $cleanupPreserved.Add("$($record.kind): $preservationReason; preserved: $path")
    }
    foreach ($path in $generatedOwnedPaths) {
        try {
            $generatedLease = Try-OpenNonReparseFileLeaf `
                -Path $path `
                -Tracker $pathEntryLeases `
                -LeasesByPath $leasedPathEntries
            if ($null -ne $generatedLease) {
                $cleanupPreserved.Add("generated report artifact: $preservationReason; preserved: $path")
            }
        }
        catch {
            $cleanupErrors.Add("Could not safely inspect generated report artifact '$path': $($_.Exception.Message)")
        }
    }
    foreach ($directory in $createdDirectories) {
        $cleanupPreserved.Add("staging directory: $preservationReason; preserved: $directory")
    }
    if ($stagingArtifactsExist -and ($conservativeExecutionPreservation -or $conservativePreflightPreservation)) {
        $warnings.Add(
            'Staging was preserved because automatic deletion by pathname is disabled to avoid deleting a replaced file. Remove the recorded unique paths only after independently verifying their identities and that no related process remains.'
        )
    }
    elseif ($stagingArtifactsExist) {
        $cleanupErrors.Add('Staging was preserved because process isolation or staging-lock release could not be verified.')
    }

    if ($null -ne $lock) {
        try {
            $lock.stream.Dispose()
        }
        catch {
            $cleanupErrors.Add("Could not release the terminal data lock: $($_.Exception.Message)")
        }
    }


    if ($cleanupErrors.Count -gt 0) {
        if ($result.status -ne 'tooling_error') {
            $result.primary_status_before_cleanup = $result.status
        }
        $result.status = 'tooling_error'
        $errors.Add('Owned staging cleanup failed; inspect cleanup.errors. Any primary outcome is recorded in primary_status_before_cleanup.')
        $exitCode = 2
    }

    $endedUtc = [datetimeoffset]::UtcNow
    $result.ended_utc = $endedUtc.ToString("yyyy-MM-ddTHH:mm:ss.fffffff'Z'")
    $result.duration_milliseconds = [long]($endedUtc - $startedUtc).TotalMilliseconds

    if ($outputCreated -and $null -ne $resultPath) {
        try {
            Assert-StableFixedLocalVolumePath -Path $output
            [Mql5Coding.JobProcessLaunch]::VerifyPathEntryLeaseVolume(
                $output,
                $outputDirectoryLease
            )
            $outputDirectoryLease.VerifyStillNonReparseDirectory()
            Write-JsonFile -Value $result -Path $resultPath
            $resultWritten = $true
        }
        catch {
            [Console]::Error.WriteLine(
                (Protect-JournalLine -Line "Could not write smoke result '$resultPath': $($_.Exception.Message)")
            )
            $exitCode = 2
        }
    }
    elseif ($errors.Count -gt 0) {
        [Console]::Error.WriteLine(
            (Protect-JournalLine -Line "MQL5 tester smoke $($result.status): $($errors[$errors.Count - 1])")
        )
    }

    $postResultReleaseErrors = New-Object 'System.Collections.Generic.List[string]'
    for ($index = $outputArtifactPublicationLocks.Count - 1; $index -ge 0; $index--) {
        try {
            $outputArtifactPublicationLocks[$index].stream.Dispose()
        }
        catch {
            $postResultReleaseErrors.Add(
                "Could not release the $($outputArtifactPublicationLocks[$index].record.kind) publication stream: $($_.Exception.Message)"
            )
        }
    }
    for ($index = $directoryMutationGuards.Count - 1; $index -ge 0; $index--) {
        try {
            $directoryMutationGuards[$index].stream.Dispose()
        }
        catch {
            $postResultReleaseErrors.Add(
                "Could not release the directory mutation guard '$($directoryMutationGuards[$index].path)': $($_.Exception.Message)"
            )
        }
    }
    if ($null -ne $outputClaim) {
        try {
            $outputClaim.stream.Dispose()
        }
        catch {
            $postResultReleaseErrors.Add(
                "Could not release the output-directory claim '$($outputClaim.path)': $($_.Exception.Message)"
            )
        }
    }
    if ($postResultReleaseErrors.Count -gt 0) {
        if (-not $resultWritten) {
            $exitCode = 2
        }
        foreach ($releaseError in $postResultReleaseErrors) {
            [Console]::Error.WriteLine(
                (Protect-JournalLine -Line "MQL5 tester smoke warning: $releaseError")
            )
        }
    }

    $pathLeaseReleaseError = $null
    for ($index = $pathEntryLeases.Count - 1; $index -ge 0; $index--) {
        try {
            $pathEntryLeases[$index].Dispose()
        }
        catch {
            if ($null -eq $pathLeaseReleaseError) {
                $pathLeaseReleaseError = $_.Exception.Message
            }
        }
    }
    if ($null -ne $pathLeaseReleaseError) {
        [Console]::Error.WriteLine(
            (Protect-JournalLine -Line (
                    'MQL5 tester smoke warning: could not release a ' +
                    "path-integrity lease: $pathLeaseReleaseError"
                ))
        )
    }

}

if ($resultWritten) {
    Write-Output $resultPath
}
exit $exitCode
