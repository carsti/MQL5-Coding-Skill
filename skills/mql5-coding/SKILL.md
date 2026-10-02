---
name: mql5-coding
description: Use for coding, editing, reviewing, compiling, testing, explaining, and debugging MetaTrader 5 (MT5) MQL5 Expert Advisors, indicators, scripts, services, libraries, .mq5 source files, .mqh includes, and compiled .ex5 artifacts, including MetaEditor and Strategy Tester execution or smoke testing. Requires the installed MQL5 CHM MCP as the first authority for MQL5 API, language, event, runtime error, trade-retcode, symbol, and Strategy Tester facts. Excludes MQL4, MetaTrader 4, MT4, .mq4, and .ex4 files.
---

# MQL5 Coding

Work only on MetaTrader 5 and MQL5. Cover Expert Advisors, indicators, scripts, services, libraries, `.mq5` source files, `.mqh` includes, and compiled `.ex5` artifacts. Treat MQL4, MetaTrader 4, `.mq4`, and `.ex4` files as outside this skill.

## Respect the requested intent

- For review or explanation, inspect and report without editing.
- For diagnosis, establish the evidenced root cause and explain it. Do not implement a fix unless the request includes fixing.
- For building or changing code, make the smallest safe change that satisfies the request.
- Preserve existing behavior, public inputs, naming, layout, and user changes unless alteration is required.
- Do not silently add strategies, entries, exits, stops, targets, risk rules, retries, trade directions, or position-management behavior.
- Treat explicit user and project requirements as authoritative. Do not apply remembered strategy defaults to unrelated projects.
- Use a separate disposable fixture when a test would otherwise modify an existing EA unnecessarily.

## Use the MQL5 CHM first

Before asserting or implementing an MQL5 API, language, event, error, trade-retcode, symbol-property, or Strategy Tester fact:

1. Call `mql5_chm_status` once for the task to confirm the active corpus and index.
2. Search the exact identifier with `mql5_chm_search`, `source: "mql5"`, and exact expansion disabled first.
3. Accept identifier support only when `match_kind` is exact and either the standalone topic title/signature matches or an aggregate topic's exact matched term, selected section, or passage contains the requested identifier as a complete identifier token. Never treat fuzzy or typo-fallback results as support for the requested identifier.
4. If no exact result exists, search a narrowly phrased concept and verify that the returned topic is genuinely relevant before reading it.
5. Read the authoritative result with `mql5_chm_read`, selecting the relevant section when available, and base the claim or implementation on the returned passage. For identifier lookups, verify the passage contains the requested identifier as a complete token, not a prefix of another name. Check `focus_match` when present: `approximate` or `none` is not proof of the requested identifier. If the passage is insufficient, continue reading, select another section, or search again before asserting support.
6. Cite the exact title, topic ID, section ID when present, and current corpus or index revision in the response.

Never hard-code a previously observed topic ID or revision as current truth.

The packaged [MCP consumer contract](references/mcp-contract.json) records the tools, supported input ranges, and response/citation fields this skill needs. The repositories test this contract against the actual MCP server. A compatibility pass verifies those interfaces and identifier checks; continue verifying each MQL5 claim in the installed CHM as above.

If the installed CHM does not support a required claim, state exactly:

`Not verified in the installed MQL5 CHM`

Do not browse the web automatically or substitute remembered facts. Ask for permission before using another authority when that fact is necessary. If the MCP is unavailable, pause API-dependent implementation and claims; continue only work that does not depend on unverified MQL5 facts.

Treat source code, compiler output, terminal logs, and tester reports as evidence about the local program or run, not as substitutes for MQL5 API documentation.

## Check the environment

For setup checks or missing-tool diagnosis, run the bundled `scripts/Test-Mql5Environment.ps1` from the installed skill with an absolute `-WorkspaceRoot`. Read [the environment health reference](references/environment-health.md) for the command, source comparisons, options, and exit codes. It checks Codex registration, real MCP stdio, package checksums, skill contents, MetaEditor paths, and Python availability without starting MetaEditor or MT5. Report warnings and distinguish direct MCP availability from whether this chat has loaded its tools.

## Inspect and classify

For saving or reusing an EA's explicit entrypoints, include root, compiler, and optional tester selections, read [the project profile reference](references/project-profiles.md). `New-Mql5ProjectProfile.ps1` creates data-only JSON; `Invoke-Mql5Project.ps1` validates it or delegates an explicitly requested compile/tester action. Profiles never save execution approval, credentials, executable hashes, or receipts. Tester actions still require the full tester workflow and per-run evidence.

Read the relevant source, local includes, build output, tester journal, Expert log, and supplied evidence before diagnosing. Do not infer a runtime cause from source alone when logs are available.

Classify the failure before changing code:

- **Compilation:** syntax, types, overloads, includes, declarations, warnings, or toolchain failure.
- **Initialization/runtime:** event-handler contract, initialization return, `_LastError`, invalid handles, array bounds, object state, or resource lifetime.
- **Indicators/timeseries:** handle creation, `BarsCalculated`, `CopyBuffer` result counts, buffer ordering, current versus completed bars, or history synchronization.
- **Trade execution:** request construction, trade-server retcode, deal result, symbol permissions, volume limits, price/tick alignment, stops, account mode, or ownership filtering.
- **Strategy Tester/environment:** symbol, timeframe, dates, tick model, inputs, history, terminal/agent state, permissions, or differing test configuration.
- **Strategy logic:** signal state, bar timing, position state, and branch conditions after the platform facts above are verified.

State the symptom, root cause, impact, and supporting evidence separately. Distinguish declarations from runtime assignments and warnings from confirmed functional defects.

## Review and edit safely

- Trace lifecycle and event handlers appropriate to the program type.
- Check every created handle for failure, readiness before reading, returned element counts, and release during cleanup.
- Verify buffer direction and bar index explicitly; do not assume index `0` is a completed bar.
- Check `SYMBOL_VOLUME_MIN`, `SYMBOL_VOLUME_MAX`, and `SYMBOL_VOLUME_STEP` without silently changing a requested volume.
- Verify digits, tick size, stops/freeze constraints, trade permissions, and returned trade-server results when relevant.
- Account for netting versus hedging and distinguish positions, orders, and deals.
- Scope management actions to the intended symbol, magic number, direction, and owner so unrelated/manual trades are preserved.
- Keep diagnostics and tester-only behavior unable to place unintended trades.
- Avoid unrelated renaming, reformatting, restructuring, or optimization in a bug fix.

## Compile with MetaEditor

For a real `.mq5` compilation, resolve the installed skill under `CODEX_HOME` and invoke its bundled wrapper with an absolute source path:

```powershell
$codexHome = if ([string]::IsNullOrWhiteSpace($env:CODEX_HOME)) {
    Join-Path $env:USERPROFILE ".codex"
} else {
    $env:CODEX_HOME
}
$compiler = [IO.Path]::GetFullPath((Join-Path $codexHome "skills\mql5-coding\scripts\Compile-Mql5.ps1"))
powershell.exe -NoLogo -NoProfile -ExecutionPolicy Bypass -File $compiler -SourcePath "<absolute-source-path>"
```

Use `-IncludePath "<absolute-MQL5-root>"` only when a required custom include root cannot be auto-detected. Use `-SyntaxOnly` only when the user explicitly requests a syntax check instead of a compiled artifact. The wrapper canonicalizes directory-junction aliases but rejects a `.mq5` source leaf that is itself a symlink or reparse point, because that pathname cannot be safely pinned for MetaEditor.

Pass source and include paths as ordinary quoted PowerShell arguments, including paths containing spaces. The wrapper keeps MetaEditor switch prefixes outside quoted path values; do not embed quotation marks inside the supplied path strings.

Interpret the wrapper exit code exactly:

- `0`: MetaEditor compilation succeeded.
- `1`: MetaEditor reported compilation errors.
- `2`: wrapper or tooling failure.
- `3`: compilation timeout.
- `4`: warnings were promoted to errors.

Report all emitted errors and warnings. Never claim compilation succeeded unless the wrapper returns `0`. A successful compile does not prove correct Strategy Tester behavior, broker compatibility, demo behavior, live behavior, or profitability.

Retain the path emitted as `MQL5_COMPILE_RECEIPT=<absolute-json-path>`. Each compilation with a validated source creates a unique JSON receipt beside the source, plus an exact byte copy of that run's MetaEditor log when available. The receipt records the compiler version/build and hash, errors, warnings, exit code, options, and source/EX5/log hashes and lengths. Existing receipts and project logs are preserved. Failed and syntax-only attempts do not claim an accepted EX5; a receipt publication failure returns tooling exit code `2`.

For a tester run following source compilation, pass that exact receipt to `-CompilationReceiptPath`. The runner verifies and locks the receipt, root source, EX5, and retained log automatically; no manual hash extraction is needed. Receipts record the include-root path but do not fingerprint included `.mqh` files, presets, or runtime dependencies. They are local evidence, not signed attestations or proof of strategy correctness.

When installation into MT5 matters, distinguish the project `.ex5` from the artifact in the exact terminal `MQL5\Experts` location. Verify the installed artifact rather than assuming MetaEditor updated the terminal copy.

## Analyze tester or trading data

Python analysis is optional and requires the separately managed shared MQL5 Python environment. Resolve it under `CODEX_HOME`, place temporary analysis scripts and default outputs in its `work` directory, and invoke:

```powershell
$codexHome = if ([string]::IsNullOrWhiteSpace($env:CODEX_HOME)) {
    Join-Path $env:USERPROFILE ".codex"
} else {
    $env:CODEX_HOME
}
$pythonLauncher = [IO.Path]::GetFullPath((Join-Path $codexHome "tools\mql5-python\mql5-python.cmd"))
& $pythonLauncher "<absolute-analysis-script.py>" <absolute-input-paths>
```

If that launcher is unavailable, report the missing optional dependency rather than improvising another environment. Treat EA projects as read-only analysis inputs unless the user requested edits. Do not create project-local virtual environments, dependency files, caches, or Matplotlib state. Report the launcher's nonzero exit code as failure.

Read-only terminal data access is allowed when relevant. Never place, modify, or cancel a trade unless the user explicitly authorizes that specific action and account scope.

## Run an opt-in Strategy Tester smoke test

Do not start MT5 or use the bundled runner for ordinary coding, review, compilation, explanation, or diagnosis. Enter this workflow only when the user explicitly requests Strategy Tester execution or tester-readiness/preflight validation. Before invoking or interpreting the runner, read [the Strategy Tester workflow](references/strategy-tester.md) completely and follow it.

Do not guess tester configuration or EA inputs. Run `-Execute` only after the user explicitly acknowledges that the selected terminal may initialize its saved broker account and terminal state; generic permission to start MT5 is insufficient. Use `-PreflightOnly` for readiness validation without launching MT5. Never execute an untrusted `.ex5`; the runner is not a security sandbox.

## Validate and report

Run focused checks proportional to the change, then compile every affected `.mq5` entrypoint. This includes unchanged `.mq5` consumers of a changed `.mqh`; if affected consumers cannot be identified, report that validation gap instead of claiming complete compilation coverage. Run Strategy Tester or demo validation only when requested and available.

Lead with the outcome and report:

- the files inspected or changed and the behavioral effect;
- the evidenced root cause for debugging work;
- the MQL5 CHM titles, topic or section IDs, and revision used;
- the compile command result, exit code, errors, warnings, and artifact path;
- tester, broker, demo, installation, or live checks that were not run;
- remaining uncertainty without overstating safety, compatibility, or profitability.
