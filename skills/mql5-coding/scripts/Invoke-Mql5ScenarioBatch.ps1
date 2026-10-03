#Requires -Version 5.1
[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$ManifestPath,
    [Parameter(Mandatory)][string]$OutputDirectory,
    [ValidateSet('Validate','Execute')][string]$Action='Validate',
    [string]$PythonPath,
    [string]$CancellationFile
)
Set-StrictMode -Version Latest
$ErrorActionPreference='Stop'
. (Join-Path $PSScriptRoot 'ToolkitSupport.ps1')
. (Join-Path $PSScriptRoot 'Mql5ProjectProfile.ps1')
. (Join-Path $PSScriptRoot 'TesterEvidence.ps1')
$hostExe=if ($PSVersionTable.PSEdition -eq 'Core') {Join-Path $PSHOME 'pwsh.exe'} else {Join-Path $PSHOME 'powershell.exe'}
$output=$null;$current=$null;$abort=$false
$result=[ordered]@{schema_version=1;operation='scenario batch';action=$Action;status='failed';manifest=$null;scenarios=@();issues=@();exit_code=2;duration_milliseconds=$null;duration_is_ea_cost=$false}
$clock=[Diagnostics.Stopwatch]::StartNew()
function Invoke-BatchProfile([string[]]$Arguments,[int]$Seconds) {
    $command='[Console]::OutputEncoding=New-Object Text.UTF8Encoding($false); $OutputEncoding=[Console]::OutputEncoding; & '+"'"+(Join-Path $PSScriptRoot 'Invoke-Mql5Project.ps1').Replace("'","''")+"'"
    if ($Arguments.Count % 2) {throw 'Profile invocation requires named value pairs.'}
    for ($part=0;$part -lt $Arguments.Count;$part+=2) {
        if ($Arguments[$part] -cnotmatch '^-[A-Za-z][A-Za-z0-9]*$') {throw 'Invalid delegated parameter name.'}
        $command+=' '+$Arguments[$part]+" '"+$Arguments[$part+1].Replace("'","''")+"'"
    }
    $command+='; exit $LASTEXITCODE'
    $encoded=[Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($command))
    return Invoke-ToolkitProcess $hostExe @('-NoLogo','-NoProfile','-NonInteractive','-ExecutionPolicy','Bypass','-EncodedCommand',$encoded) $output $Seconds
}
function Save-BatchCheckpoint {
    # Separate progress from the final create-new result; interruption cannot leave a false final completion.
    [IO.File]::WriteAllText((Join-Path $output 'progress.json'),($result | ConvertTo-Json -Depth 12),(New-Object Text.UTF8Encoding($false)))
}
try {
    $output=New-ToolkitOutput $OutputDirectory
    if ($ManifestPath -notmatch '^[A-Za-z]:[\\/]') {throw 'ManifestPath must be absolute.'}
    $manifestPathResolved=Resolve-ToolkitPath $ManifestPath $PSScriptRoot
    $manifest=Read-Mql5ReleaseJson $manifestPathResolved
    Assert-ToolkitFields $manifest @('schema_version','scenarios')
    Assert-ToolkitVersion $manifest
    if ($manifest.scenarios -isnot [array] -or $manifest.scenarios.Count -lt 1 -or $manifest.scenarios.Count -gt 100) {throw 'Select 1 to 100 scenarios.'}
    $python=Get-ToolkitPython $PythonPath
    $base=[IO.Path]::GetDirectoryName($manifestPathResolved);$selected=@();$ids=@{}
    if ($CancellationFile) {
        if ($CancellationFile -notmatch '^[A-Za-z]:[\\/]') {throw 'CancellationFile must be absolute.'}
        $CancellationFile=Resolve-ToolkitPath $CancellationFile $base ''
    }
    foreach ($scenario in $manifest.scenarios) {
        Assert-ToolkitFields $scenario @('id','profile') @('expected_marker_file','baseline_report','baseline_result','expectations')
        if ($scenario.id -isnot [string] -or $scenario.id -cnotmatch '^[a-zA-Z0-9][a-zA-Z0-9_-]{0,63}$' -or $scenario.id -match '^(CON|PRN|AUX|NUL|COM[1-9]|LPT[1-9])$' -or $ids.ContainsKey($scenario.id)) {throw 'Invalid or duplicate scenario identity.'}
        $ids[$scenario.id]=$true
        if ($scenario.profile -isnot [string]) {throw 'Scenario profile must be a path.'}
        $profilePath=Resolve-ToolkitPath $scenario.profile $base
        $profile=Read-Mql5ProjectProfile $profilePath
        if ($null -eq $profile.tester) {throw 'Each scenario requires a profile with saved tester settings.'}
        $item=[ordered]@{id=$scenario.id;profile_path=$profilePath;profile=$profile;evidence_inputs=@();expected_marker_file=$null;baseline_report=$null;baseline_result=$null;expectations=$null}
        foreach ($key in @('expected_marker_file','baseline_report','baseline_result','expectations')) {
            $value=Get-ToolkitValue $scenario $key
            if ($null -ne $value) {
                if ($value -isnot [string]) {throw 'Optional scenario evidence must be a path.'}
                $item[$key]=Resolve-ToolkitPath $value $base
                $item.evidence_inputs+=@(@{kind=$key;path=$item[$key];sha256=(Get-Mql5ReleaseHash $item[$key])})
            }
        }
        if ($item.baseline_result -and -not $item.baseline_report) {throw 'Baseline result requires a baseline report.'}
        if ($item.expectations -and -not $item.baseline_report) {throw 'Comparison expectations require a baseline report.'}
        if ($item.expected_marker_file) {
            $markers=@([IO.File]::ReadAllLines($item.expected_marker_file,(New-Object Text.UTF8Encoding($false,$true))) | Where-Object {-not [string]::IsNullOrWhiteSpace($_)})
            if (-not $markers.Count -or $markers.Count -gt 100 -or @($markers | Select-Object -Unique).Count -ne $markers.Count) {throw 'Invalid expected marker file.'}
            foreach ($marker in $markers) {if ($marker -cnotmatch '^MQL5_CODING_PASS:[0-9a-fA-F]{32,64}(?::[^\s]+)?$') {throw 'Invalid application marker protocol.'}}
        }
        if ($item.expectations) {
            $checkCode='import sys; sys.path.insert(0,sys.argv[1]); from toolkit_common import load_expectations; from toolkit_reports import CORE_CONDITIONS; e=load_expectations(__import__("pathlib").Path(sys.argv[2])); bad=(set(e.get("required_conditions",[]))-set(CORE_CONDITIONS)-{"terminal_image_sha256","terminal_build","history_quality","bars","ticks","symbols"}) | (set(e.get("required_evidence",[]))-{ "linked_run","source_hash","expert_hash","preset_hash"})'+"`n"+'if bad: raise ValueError("Unsupported report evidence requirement")'+"`n"+'print("EXPECTATIONS_VALID")'
            $check=Invoke-ToolkitProcess $python @('-B','-s','-c',$checkCode,$PSScriptRoot,$item.expectations) $output 30
            if (-not $check.cleanup_verified -or $check.exit_code -ne 0 -or $check.stdout.Trim() -cne 'EXPECTATIONS_VALID') {throw 'Invalid comparison expectations or Python tooling.'}
        }
        if ($item.baseline_report) {
            $arguments=@('-B','-s',(Join-Path $PSScriptRoot 'mql5_toolkit.py'),'report','read','--input',$item.baseline_report,'--output',(Join-Path $output ('validate-baseline-'+$item.id)))
            if ($item.baseline_result) {$arguments+=@('--tester-result',$item.baseline_result)}
            $check=Invoke-ToolkitProcess $python $arguments $output 60
            if (-not $check.cleanup_verified -or $check.exit_code -ne 0) {throw 'Baseline report or Python tooling failed validation.'}
            $parsed=Read-Mql5ReleaseJson (Join-Path $output ('validate-baseline-'+$item.id+'\result.json'))
            if ($parsed.evidence_linkage.status -eq 'mismatch') {throw 'Baseline report linkage mismatch.'}
        }
        $selected+=@([pscustomobject]$item)
    }
    $result.manifest=@{path=$manifestPathResolved;sha256=(Get-Mql5ReleaseHash $manifestPathResolved)}
    foreach ($item in $selected) {
        $result.scenarios+=@([ordered]@{id=$item.id;profile=@{path=$item.profile_path;sha256=(Get-Mql5ReleaseHash $item.profile_path)};evidence_inputs=$item.evidence_inputs;status='skipped';reason=if ($Action -eq 'Validate') {'validation_only'} else {'not_started'};compile=$null;tester=$null;analysis=@();cleanup_verified=$null;output_directory=$null})
    }
    $result.status=if ($Action -eq 'Validate') {'validated'} else {'running'}
    Save-BatchCheckpoint
    if ($Action -eq 'Execute') {
        for ($index=0;$index -lt $selected.Count;$index++) {
            $item=$selected[$index];$current=$result.scenarios[$index]
            if ($abort -or ($CancellationFile -and (Test-Path -LiteralPath $CancellationFile))) {
                $abort=$true;$current.reason='aborted_or_cancelled';Save-BatchCheckpoint;continue
            }
            $scenarioRoot=Join-Path $output $item.id
            [IO.Directory]::CreateDirectory($scenarioRoot) | Out-Null
            $current.output_directory=$scenarioRoot;$current.status='running';$current.reason=$null
            Save-BatchCheckpoint
            # Reread the existing profile immediately before compilation; do not silently use changed configuration.
            if ((Get-Mql5ReleaseHash $item.profile_path) -cne $current.profile.sha256) {throw 'Profile changed after manifest validation.'}
            foreach ($inputEvidence in $item.evidence_inputs) {if ((Get-Mql5ReleaseHash $inputEvidence.path) -cne $inputEvidence.sha256) {throw 'Selected evidence changed after manifest validation.'}}
            $start=[DateTime]::UtcNow
            $compiled=Invoke-BatchProfile @('-ProfilePath',$item.profile_path,'-Action','Compile','-Entrypoint',$item.profile.tester.entrypoint) ($item.profile.compiler.timeout_seconds+30)
            $current.compile=@{exit_code=$compiled.exit_code;runner_status=$compiled.status;receipt_path=$null}
            $current.cleanup_verified=$compiled.cleanup_verified
            if ($compiled.exit_code -ne 0 -or $compiled.status -ne 'completed') {
                $current.status=if ($compiled.exit_code -eq 3 -or $compiled.status -eq 'timed_out') {'timed_out'} else {'failed'}
                $current.reason='compilation_failed';$abort=-not $compiled.cleanup_verified;Save-BatchCheckpoint;continue
            }
            $receipts=[regex]::Matches($compiled.stdout,'(?m)^MQL5_COMPILE_RECEIPT=(.+)\r?$')
            if ($receipts.Count -ne 1) {throw 'Selected compilation must emit exactly one fresh receipt.'}
            $receiptPath=Resolve-ToolkitPath $receipts[0].Groups[1].Value.Trim() $base
            $receipt=Read-Mql5ReleaseJson $receiptPath
            if ($receipt.status -cne 'success' -or $receipt.exit_code -ne 0 -or (Get-Item -LiteralPath $receiptPath).LastWriteTimeUtc -lt $start.AddSeconds(-2) -or $receipt.source.path -ine $item.profile.tester.entrypoint) {throw 'Compilation receipt is not fresh for the selected entrypoint.'}
            $current.compile.receipt_path=$receiptPath
            $arguments=@('-ProfilePath',$item.profile_path,'-Action','TesterSmoke','-CompilationReceiptPath',$receiptPath,'-OutputDirectory',(Join-Path $scenarioRoot 'tester'))
            if ($item.expected_marker_file) {$arguments+=@('-ExpectedLogMarkerFile',$item.expected_marker_file)}
            $tested=Invoke-BatchProfile $arguments ($item.profile.tester.timeout_seconds+60)
            $runPath=Join-Path $scenarioRoot 'tester\smoke-result.json';$run=$null
            if (Test-Path -LiteralPath $runPath -PathType Leaf) {try {$run=Read-Mql5ReleaseJson $runPath} catch {$result.issues+=@(@{code='invalid_tester_result';scenario=$item.id})}}
            $nativeStatus=Get-ToolkitValue $run 'status'
            $current.tester=@{exit_code=$tested.exit_code;runner_status=$tested.status;recorded_status=$nativeStatus;result_path=if ($run) {$runPath} else {$null}}
            $current.cleanup_verified=$compiled.cleanup_verified -and $tested.cleanup_verified
            if ($run) {
                $proc=Get-ToolkitValue $run 'process'
                $created=Get-ToolkitValue $proc 'process_created'
                if ($created -eq $true -and (Get-ToolkitValue $proc 'job_empty_verified') -ne $true) {$current.cleanup_verified=$false}
                if ($nativeStatus -eq 'cleanup_failed' -or @(Get-ToolkitValue (Get-ToolkitValue $run 'cleanup') 'errors' @()).Count) {$current.cleanup_verified=$false}
            }
            $current.status=if ($tested.status -eq 'timed_out' -or $tested.exit_code -eq 3) {'timed_out'} elseif ($tested.exit_code -eq 4) {'blocked'} elseif ($tested.exit_code -eq 0 -and $nativeStatus -in @('engine_smoke_passed','application_marker_passed')) {'completed'} else {'failed'}
            if (-not $run) {$current.reason='missing_tester_result'}
            if (-not $current.cleanup_verified) {$abort=$true;$current.reason='cleanup_uncertain'}
            # Parse every retained report, including reports from failed/timed-out tester runs.
            $reportPaths=@(Get-ChildItem -LiteralPath $scenarioRoot -Recurse -File | Where-Object {$_.Extension -in @('.htm','.html')} | ForEach-Object {$_.FullName})
            foreach ($reportPath in $reportPaths) {
                $analysisRoot=Join-Path $scenarioRoot ('analysis-'+[guid]::NewGuid().ToString('N'))
                $analysisArgs=@('-B','-s',(Join-Path $PSScriptRoot 'mql5_toolkit.py'),'report','read','--input',$reportPath,'--output',$analysisRoot)
                if ($run) {$analysisArgs+=@('--tester-result',$runPath)}
                $analyzed=Invoke-ToolkitProcess $python $analysisArgs $scenarioRoot 60
                $current.analysis+=@(@{operation='read';exit_code=$analyzed.exit_code;runner_status=$analyzed.status;output=$analysisRoot})
                if (-not $analyzed.cleanup_verified) {$abort=$true;$current.cleanup_verified=$false;$current.reason='analysis_cleanup_uncertain'}
                if ($item.baseline_report) {
                    $compareRoot=Join-Path $scenarioRoot ('comparison-'+[guid]::NewGuid().ToString('N'))
                    $compareArgs=@('-B','-s',(Join-Path $PSScriptRoot 'mql5_toolkit.py'),'report','compare','--baseline',$item.baseline_report,'--candidate',$reportPath,'--output',$compareRoot)
                    if ($run) {$compareArgs+=@('--candidate-result',$runPath)}
                    if ($item.baseline_result) {$compareArgs+=@('--baseline-result',$item.baseline_result)}
                    if ($item.expectations) {$compareArgs+=@('--expectations',$item.expectations)}
                    $compared=Invoke-ToolkitProcess $python $compareArgs $scenarioRoot 60
                    $current.analysis+=@(@{operation='compare';exit_code=$compared.exit_code;runner_status=$compared.status;output=$compareRoot})
                    if (-not $compared.cleanup_verified) {$abort=$true;$current.cleanup_verified=$false;$current.reason='analysis_cleanup_uncertain'}
                }
            }
            Save-BatchCheckpoint
        }
        $result.status=if ($abort) {'aborted'} elseif (@($result.scenarios | Where-Object {$_.status -ne 'completed'}).Count) {'completed_with_failures'} else {'completed'}
    }
    $result.exit_code=if ($result.status -in @('validated','completed') -and -not @($result.scenarios | Where-Object {@($_.analysis | Where-Object {$_.exit_code -ne 0}).Count}).Count) {0} elseif ($abort) {2} else {1}
} catch {
    if ($null -ne $current -and $current.status -eq 'running') {$current.status='failed';$current.reason='wrapper_failure'}
    $detail=Protect-JournalLine -Line $_.Exception.Message
    $detail=[regex]::Replace($detail,'MQL5_CODING_PASS:[0-9a-fA-F]{32,64}(?::[^\s]*)?','<APPLICATION_MARKER>')
    $result.issues+=@(@{code='invalid_input_or_tooling';message='Inspect manifest, profile, selected evidence, fresh receipts, and child process results.';detail=$detail})
    $result.status='failed';$result.exit_code=2
    foreach ($pending in $result.scenarios) {if ($pending.status -eq 'skipped' -and $pending.reason -eq 'not_started') {$pending.reason='aborted_after_wrapper_failure'}}
} finally {
    $result.duration_milliseconds=$clock.ElapsedMilliseconds
    if ($output) {Save-BatchCheckpoint}
}
if ($output) {
    $table=@("id`tstatus`tcompile_exit`ttester_exit`trecorded_tester_status`tanalysis_exits`tcleanup_verified")
    foreach ($scenario in $result.scenarios) {
        $table+=@((@($scenario.id,$scenario.status,(Get-ToolkitValue $scenario.compile 'exit_code'),(Get-ToolkitValue $scenario.tester 'exit_code'),(Get-ToolkitValue $scenario.tester 'recorded_status'),(@($scenario.analysis | ForEach-Object {$_.exit_code}) -join ','),$scenario.cleanup_verified) -join "`t"))
    }
    [IO.File]::WriteAllLines((Join-Path $output 'results.tsv'),[string[]]$table,(New-Object Text.UTF8Encoding($false)))
    Save-ToolkitResult $output $result @('scenario batch',('Action: '+$Action),('Status: '+$result.status),('Scenarios: '+$result.scenarios.Count),('Exit code: '+$result.exit_code))
} else {Write-Error 'Select a new absolute output directory.' -ErrorAction Continue}
exit $result.exit_code
