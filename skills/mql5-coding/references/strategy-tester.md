# Strategy Tester smoke-test workflow

Read this file completely before invoking or interpreting the bundled Strategy Tester runner.

## Authorization and invocation

Use the bundled runner only when the user explicitly requests Strategy Tester execution or tester-readiness/preflight validation. Run `-Execute` only after the user explicitly acknowledges that the selected MT5 terminal may initialize its saved broker account and terminal state; generic permission to start MT5 is insufficient. Record that acknowledgement with `-AcknowledgeSavedAccountRisk`. Use `-PreflightOnly` when the user asks to validate readiness without launching MT5. Use absolute paths:

```powershell
$codexHome = if ([string]::IsNullOrWhiteSpace($env:CODEX_HOME)) {
    Join-Path $env:USERPROFILE ".codex"
} else {
    $env:CODEX_HOME
}
$runner = [IO.Path]::GetFullPath((Join-Path $codexHome "skills\mql5-coding\scripts\Invoke-Mt5TesterSmoke.ps1"))
powershell.exe -NoLogo -NoProfile -ExecutionPolicy Bypass -File $runner -Execute -AcknowledgeSavedAccountRisk -ExpertPath "<absolute-ex5-path>" -SetPath "<absolute-set-path>" -Symbol "<symbol>" -Period "<period>" -FromDate "YYYY.MM.DD" -ToDate "YYYY.MM.DD" -Model <0-4> -Deposit "<deposit>" -Currency "<currency>" -Leverage "<leverage>" -ExecutionMode "<mode>" -OutputDirectory "<new-absolute-output-directory>"
```

When the user supplies `.mq5` source, compile it first with the MetaEditor wrapper and require exit code `0`. Compute SHA-256 for the exact freshly emitted `.ex5`, then pass both that absolute path and `-ExpectedExpertSha256 "<64-hex-sha256>"` to the smoke runner. Never substitute a stale sibling or previously installed artifact. Treat a runner hash mismatch as tooling failure, not as tester evidence.

## Configuration and markers

Do not guess the symbol, period, dates, tester model, deposit, deposit currency, leverage, execution mode, or inputs. Take them from the user or an explicitly selected existing tester configuration; ask when required configuration is missing. A `.set` file controls EA inputs for this runner and does not supply the tester account or execution settings. Require exactly one EA input choice: `-SetPath "<absolute-set-path>"` for an explicit preset, or `-UseExpertDefaults` only after the user explicitly accepts the compiled EA defaults. The runner rejects both omission and conflicting selection. Never silently choose any of these values.

The acknowledgement switch records informed authorization; it does not prove account isolation. The runner only observes logs; it never injects a marker into the EA. For an EA self-test, pass one literal `-ExpectedLogMarker` only when the exact compiled fixture and selected inputs or preset are already arranged to emit that unique nonce and passing result. Every marker must use the case-sensitive form `MQL5_CODING_PASS:<32-64 hex nonce>[:optional-label]`; this prevents ordinary platform text from being promoted to an application pass. Do not add tester-only output to the EA unless the user requested that code change. When multiple independent markers are required, write one non-empty protocol marker per line in a UTF-8 file and pass `-ExpectedLogMarkerFile "<absolute-path>"`; do not repeat the named command-line parameter. The result JSON records SHA-256 commitments and per-marker match results without disclosing marker plaintext. Select exactly one mode: `-Execute` performs the run; `-PreflightOnly` validates discovery, exclusive output ownership, hash-bound staging writes, configuration, journal readability, and process-isolation preconditions without starting MT5.

## Isolation and evidence integrity

The runner refuses to start when the bound MT5 terminal is already running, holds its exclusive runner lock inside the terminal data directory so junction and symlink aliases converge on the same lock, pins and revalidates that directory's `origin.txt` binding, claims a new output directory without overwriting another run, and executes a unique hash-bound staged copy of the `.ex5`. It holds read locks on the exact terminal-origin, staged expert, preset, and startup-config bytes through execution so they cannot be replaced or rewritten while MT5 reads them. It also pins the recorded output-owner, canonical-config, and copied-report bytes through final integrity verification so their recorded hashes are not stale when the result is prepared. Its generated startup file requests local-only agents, disabled optimization and visual mode, disabled live trading, and terminal shutdown. The effects of those startup keys are `Not verified in the installed MQL5 CHM`; treat them as defense-in-depth requests, not proof of isolation. The runner creates the terminal suspended, assigns it to a kill-on-close Windows Job Object, verifies its identity, and only then resumes it. If Job Object assignment fails, it verifies termination of the still-suspended process and records the created PID and cleanup result instead of claiming an unchecked cleanup. On every normal or timed-out exit it terminates the owned job and requires the job to report zero active processes before accepting evidence, so short-lived intermediate parents cannot hide surviving descendants.

Terminal-process discovery is point-in-time and cannot prevent a separately launched terminal from starting and exiting between checks; do not open the bound terminal during a run. The runner never automatically deletes staged files or directories by pathname; both execution and preflight JSON list preserved unique paths for identity-aware manual cleanup. It rejects replaced or modified journal prefixes, bounds terminal success to the selected startup-config window, requires each tester pass and marker inside the selected exact expert's window before any later test starts, reads only bounded bytes appended during the run, and removes caller-supplied marker plaintext plus common password, token, API-key, authorization, and secret values from JSON excerpts. It records only marker hashes and match results. Runtime dependencies outside the `.ex5` are not copied automatically and must already be installed for the selected terminal.

## Result interpretation

Interpret the runner exit code exactly:

- `0`: preflight staging passed, or the result JSON reports `engine_smoke_passed` or `application_marker_passed`.
- `1`: tester execution completed but correlated evidence failed.
- `2`: invalid input, tooling, evidence capture, or cleanup failure.
- `3`: the spawned tester terminal timed out.
- `4`: the run was safely blocked before any MT5 process started, such as by an already-running bound terminal.

These codes apply after PowerShell successfully parses and binds the script invocation. A host-level syntax or duplicate-parameter error, or a pre-output initialization failure such as a blocked native-helper load, can leave no runner JSON. Treat every missing runner result as an invocation/tooling failure; do not infer success from the host exit code alone.

Do not treat MT5 process exit `0`, `automatic testing finished`, or report creation alone as success. Require the JSON evidence for the exact config, expert, symbol, period, dates, agent initialization, engine pass, terminal result, ordered evidence, unchanged locked staging, an emptied owned Job Object, and no residual matching terminal. An expected marker counts only after the exact correlated test-start line and before its correlated engine-pass line, with both inside the same bounded test window. Without caller-supplied application markers, describe a pass only as Strategy Tester engine smoke completion; it does not prove strategy correctness or full-date execution.

## Limitations

The runner requests Strategy Tester operation, but the terminal may still initialize its saved broker account or other saved terminal state before testing. Do not describe it as strictly offline or as proven Strategy-Tester-only. Strict offline validation requires a dedicated credential-free terminal and preloaded history.

Never execute an untrusted `.ex5` with this runner. Its process and staging isolation are not a security sandbox for code executed by MetaTrader.
