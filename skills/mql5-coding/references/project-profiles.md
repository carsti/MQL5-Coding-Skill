# Reusable project profiles

Use a profile when the user asks to save or reuse an EA project's setup. A profile is a versioned JSON data file with one object at its root, not an execution instruction. Wrapping that object in an array is unsupported and rejected. Creating it and the default `Validate` action do not start MetaEditor or MT5. Compilation and tester actions delegate to the existing wrappers and retain their exit codes, receipts, path checks, and evidence rules.

Read the [Strategy Tester workflow](strategy-tester.md) completely before a tester action. A saved profile supplies settings, not executable trust or proof of a fresh build. Enter the tester workflow for execution or readiness checks requested or needed for the task, without a separate approval or saved-account acknowledgement.

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

The shared `WindowsExecutableMetadata.ps1` reads version resources through extended Windows paths for drive, UNC, and already-prefixed inputs. Its editor validator is also used by direct compilation and environment health. It requires an accepted editor filename, readable major-version-5 metadata, and compatible metadata for every sibling terminal. A standalone editor must identify itself as MetaEditor 5. Explicit incompatible selections fail without fallback. Profile selections and compiler receipts retain canonical paths. Missing or unreadable version resources fail validation; a successful compilation receipt records the actual compiler file version and build. Compilation rechecks the pinned editor before launch and holds inspected sibling-terminal leases through cleanup. Metadata support alone does not establish that an executable can run at that path.

`IncludePath` saves the compiler's MQL5 root, with standard headers under its `Include` subdirectory. In the example, those headers belong under `D:\EA projects\Breakout\Include`. The toolkit's profile inventory derives that same directory automatically. In explicit inventory mode, `--include-root` instead names the header directory itself. Profile schema 1 and compiler delegation retain their existing interfaces.

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

These values illustrate the fields, not recommended settings. Select exactly one `SetPath` or `UseExpertDefaults = $true`; use compiled defaults when no preset is selected, without asking for acceptance. `-TesterTimeoutSeconds` defaults to 300. The tester entrypoint must belong to the saved entrypoints. Profiles cannot contain account/login credentials, execution flags, compatibility switches, receipt paths, EX5 hashes, output paths, custom commands, or expected log markers; these fields are rejected.

Symbol names are preserved exactly, including `#`, which MQL5 permits in custom-symbol names. Profile validation rejects control characters, path separators, `=`, and `;`. Accepting a name does not establish that the selected terminal has that symbol or the required history; tester evidence must establish the run outcome.

## Validate and compile

```powershell
$profileCommand = Join-Path $scripts 'Invoke-Mql5Project.ps1'
$profile = 'D:\EA projects\Breakout\mql5-project.json'
& $profileCommand -ProfilePath $profile
& $profileCommand -ProfilePath $profile -Action Compile
& $profileCommand -ProfilePath $profile -Action Compile -Entrypoint 'Breakout.mq5'
```

Validation prints normalized JSON with absolute paths and accepts PowerShell common parameters such as `-Verbose` and `-ErrorAction Stop`; compile/tester parameters remain invalid for validation. It does not verify source correctness, compiler success, terminal/data-root binding, preset contents, or executable trust. Compilation checks all saved entrypoints in order, stopping at the first nonzero wrapper exit code. Keep each emitted `MQL5_COMPILE_RECEIPT` path. Use `-SyntaxOnly` only for an explicitly requested syntax check; its receipt cannot authorize tester staging. Normal compile exit codes remain 0 success, 1 compiler errors, 2 tooling failure, 3 timeout, and 4 warnings promoted to errors. `-SuppressLogOutput` is available only with `-Action Compile`; it omits the full console log while retaining the exact log bytes and the receipt, summary, artifact references, and exit code. Without the switch, compilation prints its log as before. Inspect the retained log for individual diagnostics.

## Use fresh evidence for each tester run

For a readiness check, use the exact successful receipt and an unused output directory. No MT5 process is started:

```powershell
& $profileCommand -ProfilePath $profile -Action TesterPreflight `
    -CompilationReceiptPath '<exact-successful-receipt.json>' `
    -OutputDirectory '<new-absolute-output-directory>'
```

Execution uses `-Action TesterSmoke` and the same per-run evidence/output parameters, with no separate permission prompt or acknowledgement. `-AcknowledgeSavedAccountRisk` remains optional for compatibility with older commands. Supply an expected marker or marker-file only when the selected EA emits it. A trusted `-ExpectedExpertSha256` remains an alternative to a receipt; if both are supplied they must agree. Interpret `smoke-result.json` and the existing runner exit codes exactly as the tester reference requires. Presets and settings saved in a profile must still reflect the user's current intended run.

## Portability and limits

The generated project root is relative to the profile directory on the same drive. Entrypoints, includes, and presets inside the project are relative to its root. Moving the project and profile together preserves these selections, even when invoked from another working directory. Selections outside the project remain absolute, including on the same drive, so a move cannot silently redirect them to another existing resource. Editor, terminal, and terminal-data selections are also absolute. Review external/tool paths after moving to another computer. Moving the profile alone can change relative selections; validate the resolved paths before an action.

Paths must be relative to their documented base or fully qualified absolute paths. Root-relative values such as `\EA\Main.mq5` and drive-relative values such as `C:Main.mq5` are rejected because their meaning depends on the process's current drive or directory. Use `Main.mq5` for a project-relative source or `C:\EA\Main.mq5` for an absolute selection.

Schema version 1 requires exactly the fields emitted by the creation command. Missing, unknown, duplicate (including differently cased/escaped), incorrectly typed, invalid date/range, or ambiguous input fields fail with exit code 2. Escaped unpaired UTF-16 surrogate units in any JSON key or string value are invalid Unicode and fail before deserialization, compilation, or tester delegation. Valid literal Unicode, escaped surrogate pairs, and literal backslash text retain their exact values; validation leaves input bytes unchanged. BOM-selected encodings are validated strictly against the same captured bytes; isolated UTF-16 units cannot become replacement characters before profile validation. Files must still exist. Validation checks both compiler and tester selections, so a stale tester path can block a compile until the profile is corrected. Edit the JSON only when requested, then validate; use a new filename to preserve earlier selections. Profile paths are data, so saving one does not sandbox an executable or authenticate the profile's contents. Receipts retain the original limitation: included headers and runtime dependencies are not fingerprinted.
