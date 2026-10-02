# Reusable project profiles

Use a profile when the user asks to save or reuse an EA project's setup. A profile is a versioned JSON data file, not an execution instruction. Creating it and the default `Validate` action do not start MetaEditor or MT5. Compilation and tester actions delegate to the existing wrappers and retain their exit codes, receipts, path checks, and evidence rules.

Read the [Strategy Tester workflow](strategy-tester.md) completely before a tester action. A saved profile does not supply user authorization, saved-account risk acknowledgement, executable trust, or proof of a fresh build. Enter the tester workflow only for an explicitly requested execution or readiness check.

## Save an explicit selection

Resolve the installed scripts directory under `CODEX_HOME\skills\mql5-coding\scripts` (or `%USERPROFILE%\.codex` when `CODEX_HOME` is unset). In PowerShell, substitute real paths and an unused profile filename whose parent already exists:

```powershell
$codexDirectory = if ([string]::IsNullOrWhiteSpace($env:CODEX_HOME)) {
    Join-Path $env:USERPROFILE '.codex'
} else { $env:CODEX_HOME }
$scripts = Join-Path $codexDirectory 'skills\mql5-coding\scripts'
$selection = @{
    ProfilePath = 'D:\EA projects\Breakout\mql5-project.json'
    Name = 'Breakout'
    ProjectRoot = 'D:\EA projects\Breakout'
    Entrypoints = @('Breakout.mq5', 'Diagnostics.mq5')
    MetaEditorPath = 'C:\Program Files\MetaTrader 5\metaeditor64.exe'
    IncludePath = 'D:\EA projects\Breakout'
}
& (Join-Path $scripts 'New-Mql5ProjectProfile.ps1') @selection
```

Do not guess paths, select an editor from PATH, or infer tester inputs. The creation command validates files and MT5 executable metadata and refuses to overwrite an existing profile. Compilation-only profiles set `tester` to `null`. `-WarningsAsErrors` and `-CompileTimeoutSeconds` save compiler policy (defaults: false and 120 seconds).

To save tester settings, add **all** of the following explicitly selected fields to `$selection` before creation:

```powershell
$selection.TesterEntrypoint = 'Breakout.mq5'
$selection.TerminalPath = 'C:\Program Files\MetaTrader 5\terminal64.exe'
$selection.TerminalDataPath = '<selected-terminal-data-directory>'
$selection.SetPath = 'D:\EA projects\Breakout\approved-inputs.set'
$selection.Symbol = 'EURUSD'
$selection.Period = 'M1'
$selection.FromDate = '2025.01.12'
$selection.ToDate = '2025.02.28'
$selection.Model = 0
$selection.Deposit = '100000'
$selection.Currency = 'USD'
$selection.Leverage = 100
$selection.ExecutionMode = 0
```

These values illustrate the fields, not recommended settings. Select exactly one `SetPath` or `UseExpertDefaults = $true`, with defaults explicitly accepted by the user. `-TesterTimeoutSeconds` defaults to 300. The tester entrypoint must belong to the saved entrypoints. Profiles cannot contain account/login credentials, execution flags, acknowledgements, receipt paths, EX5 hashes, output paths, custom commands, or expected log markers; these fields are rejected.

## Validate and compile

```powershell
$profileCommand = Join-Path $scripts 'Invoke-Mql5Project.ps1'
$profile = 'D:\EA projects\Breakout\mql5-project.json'
& $profileCommand -ProfilePath $profile
& $profileCommand -ProfilePath $profile -Action Compile
& $profileCommand -ProfilePath $profile -Action Compile -Entrypoint 'Breakout.mq5'
```

Validation prints normalized JSON with absolute paths. It does not verify source correctness, compiler success, terminal/data-root binding, preset contents, or executable trust. Compilation checks all saved entrypoints in order, stopping at the first nonzero wrapper exit code. Keep each emitted `MQL5_COMPILE_RECEIPT` path. Use `-SyntaxOnly` only for an explicitly requested syntax check; its receipt cannot authorize tester staging. Normal compile exit codes remain 0 success, 1 compiler errors, 2 tooling failure, 3 timeout, and 4 warnings promoted to errors.

## Use fresh evidence for each tester run

For an explicitly requested readiness check, use the exact successful receipt and an unused output directory. No MT5 process is started:

```powershell
& $profileCommand -ProfilePath $profile -Action TesterPreflight `
    -CompilationReceiptPath '<exact-successful-receipt.json>' `
    -OutputDirectory '<new-absolute-output-directory>'
```

After the user explicitly acknowledges the selected terminal's saved-account risk, execution uses `-Action TesterSmoke -AcknowledgeSavedAccountRisk` and the same per-run evidence/output parameters. Supply an expected marker or marker-file only when the selected EA emits it. An explicitly trusted `-ExpectedExpertSha256` remains an alternative to a receipt; if both are supplied they must agree. Interpret `smoke-result.json` and the existing runner exit codes exactly as the tester reference requires. Presets and settings saved in a profile must still reflect the user's current intended run.

## Portability and limits

The generated project root is relative to the profile directory on the same drive. Entrypoints, includes, and presets inside the project are relative to its root. Moving the project and profile together preserves these selections, even when invoked from another working directory. Selections outside the project remain absolute, including on the same drive, so a move cannot silently redirect them to another existing resource. Editor, terminal, and terminal-data selections are also absolute. Review external/tool paths after moving to another computer. Moving the profile alone can change relative selections; validate the resolved paths before an action.

Schema version 1 requires exactly the fields emitted by the creation command. Missing, unknown, duplicate (including differently cased/escaped), incorrectly typed, invalid date/range, or ambiguous input fields fail with exit code 2. Files must still exist. Validation checks both compiler and tester selections, so a stale tester path can block a compile until the profile is corrected. Edit the JSON only when requested, then validate; use a new filename to preserve earlier selections. Profile paths are data, so saving one does not sandbox an executable or authenticate the profile's contents. Receipts retain the original limitation: included headers and runtime dependencies are not fingerprinted.
