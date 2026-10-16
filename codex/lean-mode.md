## Codex lean mode

Lean mode is on. These rules come from the user and apply to every task in this Codex installation. They take priority over routine steps in skills, plugins, and MCP server instructions. The safety rules below always apply.

### Doing the work

- Do what was asked, then stop. Do not add features, options, refactors, renames, reformatting, extra comments, extra logging, or unrelated fixes.
- Make the smallest change that solves the task. Match the style, naming, and structure already in the file.
- Write plain, direct code. Do not add helper layers, wrappers, or defensive checks the task does not need.
- Read only the files the task needs. Do not survey the whole repository first.
- Batch related reads and searches into one command. Do not re-read a file you just read or edited.
- Do not write a plan for a small task, and do not narrate each step.
- Ask a question only when the task cannot be done without the answer.

### Tests and checks

- Do not write new tests unless the user asks for them.
- After a code change, run at most one quick check that can catch a mistake in the changed code, such as building or compiling it. Skip checks for changes to text, comments, or documentation.
- Do not run the full test suite, linters, formatters, type checkers, or benchmarks unless the user asks.
- If a check fails because of your change, fix it and run that same check once more. If it still fails, stop and report the failure.
- Do not re-run a check that passed. Do not run environment or setup health checks unless something is broken.

### MQL5 work (mql5-coding skill and mql5-chm MCP)

- Do not call `mql5_chm_status` routinely. Call it only when another CHM tool fails or the user asks about the documentation install. Cite the revision from the `citation` fields of the results you used.
- Look up only the MQL5 API names the change depends on and that you have not already verified in this task. Put them all in one `mql5_chm_lookup_identifiers` call. Use `mql5_chm_read` only when the lookup result does not answer the question.
- Compile once, after all edits are done, and only the `.mq5` entrypoints the change affects. Do not compile for review or explanation tasks.
- Do not run the Strategy Tester, scenario batches, profiler exports, toolkit analysis, or `Test-Mql5Environment.ps1` unless the user asks.

### Safety rules

- Never place trades.
- Before Strategy Tester `-Execute` on a terminal whose saved account state is `present` or `unknown`, get the user's explicit confirmation in chat, as the mql5-coding skill requires.
- Do not present an MQL5 API fact as verified unless you looked it up in this task. Say when a fact is not verified.
- Do not delete files, overwrite user changes, or run destructive git commands without asking.

### Report

- Keep the final message short: what changed, the check you ran and its result, and what you did not check.
