---
name: mql5-coding
description: Use for coding, editing, reviewing, compiling, testing, explaining, and debugging MetaTrader 5 (MT5) MQL5 Expert Advisors, indicators, scripts, services, libraries, .mq5 source files, .mqh includes, and compiled .ex5 artifacts, including MetaEditor and Strategy Tester execution or smoke testing. Requires the installed MQL5 CHM MCP as the first authority for MQL5 API, language, event, runtime error, trade-retcode, symbol, and Strategy Tester facts. Excludes MQL4, MetaTrader 4, MT4, .mq4, and .ex4 files.
---

# MQL5 Coding

Work only on MetaTrader 5 and MQL5: Expert Advisors, indicators, scripts, services, libraries, `.mq5`, `.mqh`, and `.ex5`. MQL4, MetaTrader 4, `.mq4`, and `.ex4` are out of scope.

The skill runs in Codex and Claude Code. The installed skill root is the directory containing this `SKILL.md` (normally `%USERPROFILE%\.claude\skills\mql5-coding` in Claude Code, `CODEX_HOME\skills\mql5-coding` in Codex); run bundled scripts from its `scripts` directory. Clients may expose the MCP tools under a server prefix (in Claude Code, for example, `mcp__mql5-chm__mql5_chm_search`); use the names your client actually lists. The MCP's own connection instructions describe the same workflow as the section below.

Use the model selected for the current request; do not switch or escalate models unless the user asks, and let delegated work inherit the request's model and reasoning settings.

## Permissions and intent

Carry out the requested task and its necessary supporting actions (compilation, tester runs, EA default inputs, documentation fallback, skill installation/update/rollback) without extra approval prompts, reusing permissions already established. One gate applies: before Strategy Tester `-Execute` on a terminal whose saved account state is `present` or `unknown`, get explicit user confirmation in chat that its saved (possibly live) account may log in and resume Signals copying, then pass `-AcknowledgeSavedAccountRisk`. Never infer that confirmation from a general request to test. Client, tool, operating-system, user-instruction, and account requirements still apply. Ask for missing information only when it cannot be determined from the request, project, profile, or existing configuration.

- Review or explanation: inspect and report without editing.
- Diagnosis: establish and explain the evidenced root cause; fix only when asked.
- Building or changing code: make the smallest safe change; preserve behavior, public inputs, naming, layout, and user changes unless alteration is required.
- Never silently add strategies, entries, exits, stops, targets, risk rules, retries, trade directions, or position management. Explicit user and project requirements are authoritative; do not carry remembered strategy defaults into unrelated projects.
- Use a separate disposable fixture when a test would otherwise modify an existing EA.
- Do not initiate trades during review, compilation, or tester smoke validation.

## Use the MQL5 CHM first

Before asserting or implementing an MQL5 API, language, event, error, trade-retcode, symbol-property, or Strategy Tester fact:

1. Call `mql5_chm_status` once per task to confirm the active corpus and index.
2. Look up identifiers: for two or more names use one `mql5_chm_lookup_identifiers` call (up to 16 identifiers or exact topic titles such as `Order Properties`, `source: "mql5"`, `limit: 1` unless alternatives are needed; MCP before 1.3.16 rejects titles, so search those); for a single name, or when that tool is not exposed, use `mql5_chm_search` with `source: "mql5"` and `expand: false`. Search concept phrases instead of batching them.
3. Accept identifier support only for an exact match whose standalone title/signature matches, or whose aggregate topic's matched term, selected section, or passage contains the identifier as a complete token. Fuzzy, typo-fallback, prefix, and `non_exact` results are not support. Without an exact result, search a narrowly phrased concept and confirm relevance before reading.
4. Read with `mql5_chm_read`, selecting `section_id` or `focus` rather than a large `max_chars` (500–8000). For text-only work pass `include_related: false` and `include_images: false`; request images or related topics only when they help. There is no offset or limit: continue with the returned `next_cursor` as `cursor`, same `topic_id` and `section_id`, without `focus`. Verify the identifier appears as a complete token in the returned passage; `focus_match` `approximate` or `none` is not proof. Continue reading or search again when the passage is insufficient.
5. Reuse a verified passage for further claims in the same task while the revision is unchanged instead of re-reading it.
6. Cite the exact title, topic ID, section ID when present, and the corpus or index revision once per answer.

Never hard-code a previously observed topic ID or revision. The [MCP consumer contract](references/mcp-contract.json) lists the tool interfaces this skill relies on.

If no `mql5_chm_*` tools are listed in this chat, the client has not loaded them even when the health command passes: start a new chat or restart the client before using the fallback below. The CHM covers the MQL5 reference and books, not MetaTrader 5 terminal configuration (startup/`.ini` parameters, terminal settings) or features newer than its snapshot; take those from official metatrader5.com or mql5.com pages and cite them.

If the installed CHM does not support a required claim, state exactly:

`Not verified in the installed MQL5 CHM`

Then use official MetaQuotes documentation or another primary source without asking, cite what was actually read, and keep the CHM limitation visible; apply the same fallback when the MCP is unavailable. Never substitute remembered facts. Source code, compiler output, logs, and tester reports are evidence about the local program or run, not API documentation.

## Inspect and classify

Read the relevant source, local includes, build output, tester journal, Expert log, and supplied evidence before diagnosing; do not infer a runtime cause from source alone when logs exist. Classify before changing code:

- **Compilation:** syntax, types, overloads, includes, declarations, warnings, toolchain.
- **Initialization/runtime:** event-handler contract, init return, `_LastError`, invalid handles, array bounds, object state, resource lifetime.
- **Indicators/timeseries:** handle creation, `BarsCalculated`, `CopyBuffer` counts, buffer ordering, current versus completed bars, history synchronization.
- **Trade execution:** request construction, retcode, deal result, symbol permissions, volume limits, price/tick alignment, stops, account mode, ownership filtering.
- **Strategy Tester/environment:** symbol, timeframe, dates, tick model, inputs, history, terminal/agent state, permissions, differing configuration.
- **Strategy logic:** signal state, bar timing, position state, branch conditions, after the platform facts are verified.

State symptom, root cause, impact, and evidence separately. Distinguish declarations from runtime assignments and warnings from confirmed defects.

## Review and edit safely

- Trace lifecycle and event handlers for the program type.
- Check every handle for creation failure, readiness, returned counts, and release.
- Verify buffer direction and bar index; index `0` is not a completed bar by default.
- Check `SYMBOL_VOLUME_MIN`, `SYMBOL_VOLUME_MAX`, and `SYMBOL_VOLUME_STEP` without silently changing a requested volume.
- Verify digits, tick size, stops/freeze levels, trade permissions, and trade-server results when relevant.
- Account for netting versus hedging; distinguish positions, orders, and deals.
- Scope management to the intended symbol, magic number, direction, and owner so unrelated/manual trades are preserved.
- Keep diagnostics and tester-only code unable to place unintended trades.
- Avoid unrelated renaming, reformatting, restructuring, or optimization in a bug fix.

## Workflows and references

Read only the references a task needs:

- **Compile** (`scripts\Compile-Mql5.ps1`, e.g. `%USERPROFILE%\.claude\skills\mql5-coding\scripts\Compile-Mql5.ps1`): read [compile.md](references/compile.md) completely before compiling or interpreting compiler output and receipts. Exit `0` is the only success; keep the emitted `MQL5_COMPILE_RECEIPT` path for tester runs.
- **Strategy Tester:** read [the Strategy Tester workflow](references/strategy-tester.md) completely before invoking or interpreting `Invoke-Mt5TesterSmoke.ps1`. Run `-PreflightOnly` first; it reports `saved_account_inspection`, and `-Execute` is blocked (exit `4`) on `present`/`unknown` state until the confirmation gate above is satisfied. Prefer a dedicated terminal without saved accounts. Never execute an untrusted `.ex5`; the runner is not a security sandbox. Source-only review and compilation need no terminal launch.
- **Project profiles** (saved entrypoints, include root, compiler, tester settings): [project-profiles.md](references/project-profiles.md).
- **Toolkit** (report extraction/comparison, include inventories, journal grouping, scenario batches, profiler exports, the shared Python environment): [toolkit.md](references/toolkit.md). Analysis does not prove tester completion or strategy correctness.
- **Environment health** (setup checks, missing tools): run `scripts/Test-Mql5Environment.ps1 -ClientHost Claude|Codex -WorkspaceRoot <absolute>` for setup, after install/update/rollback, or when the environment is suspected, not routinely per task; see [environment-health.md](references/environment-health.md). Distinguish direct MCP availability from whether this chat loaded the tools.
- **Install, update, rollback:** [releases.md](references/releases.md); use the trusted updater with an explicit version and `-ClientHost` for the current client, and keep its backup ID.
- **Review aids:** [focused review](references/focused-review.md), [performance measurement](references/performance.md), [cleanup/refactoring](references/refactoring.md).

## Validate and report

Run checks proportional to the change, then compile every affected `.mq5` entrypoint, including unchanged consumers of a changed `.mqh`; if consumers cannot be identified, report that gap. Run tester or demo validation when requested or needed and available.

Lead with the outcome and report:

- files inspected or changed and the behavioral effect;
- the evidenced root cause for debugging work;
- MQL5 CHM titles, topic or section IDs, and revision used;
- compile result, exit code, errors, warnings, and artifact path;
- tester, broker, demo, installation, or live checks not run;
- remaining uncertainty, without overstating safety, compatibility, or profitability.
