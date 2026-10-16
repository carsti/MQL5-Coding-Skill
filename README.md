# MQL5 Coding Skill

A Windows skill for Codex and Claude Code for building, reviewing, compiling, testing, explaining, and debugging MetaTrader 5 MQL5 programs. It uses the installed [MQL5 CHM MCP](https://github.com/shamwi2846/MQL5-CHM-MCP) as the first authority for MQL5 API and language facts.

**v1.2.10** makes the health check report a Claude Code server turned off with `/mcp disable` as disabled, and makes the Strategy Tester runner say when several data directories claim one terminal installation; earlier changes are listed under [Release history](#release-history).

To install it for Claude Code, run the trusted updater from a reviewed checkout with `-ClientHost Claude -Action Update` and the offline trust inputs described in [releases](skills/mql5-coding/references/releases.md); register the MCP with the MCP package's `Install-Claude.ps1`.

The skill keeps the model selected for the active request. Isolated CLI evaluations receive that request's model and reasoning settings explicitly; saved global defaults and past benchmark settings do not select the active chat model. The documentation MCP has no AI-model dependency.

The skill covers Expert Advisors, indicators, scripts, services, libraries, `.mq5`, `.mqh`, and `.ex5` files. It intentionally excludes MQL4 and MetaTrader 4.

For shared modules, select [optional build-source snapshots](skills/mql5-coding/references/source-snapshots.md). Testing with a selected snapshot requires its matching receipt and unchanged recorded known files. Existing commands remain available without this option. Development validation includes [complete Codex workflows](tests/WORKFLOW-EVALUATION.md); those measurements are separate from the existing scripted processing evaluator.

## Requirements

- Windows with PowerShell 7 or Windows PowerShell 5.1.
- Codex or Claude Code with skill support.
- The `mql5-chm` MCP server installed and enabled.
- MetaTrader 5 and MetaEditor only when compilation or Strategy Tester execution is requested.
- Direct fixed-local-volume paths registered by the Windows mount manager and without reparse-point components for Strategy Tester staging and evidence; mapped network drives, SUBST aliases, and raw DOS-device aliases are rejected.
- An ordinary `.mq5` source file for compilation; directory-junction aliases are canonicalized, but source-file symlinks/reparse points are rejected.
- The shared MQL5 Python launcher under `CODEX_HOME\tools\mql5-python` only for optional Python analysis.

Ordinary source review and explanation do not start MetaTrader, MetaEditor, or Strategy Tester.

## One environment health command

Run the installed read-only checker for the client you use to report its `mql5-chm` registration, real MCP stdio availability, listed package checksums and versions, source/installed differences, MetaEditor paths/builds, and Python/PyYAML availability:

```powershell
# Codex
$codexDirectory = if ([string]::IsNullOrWhiteSpace($env:CODEX_HOME)) {
    Join-Path $env:USERPROFILE '.codex'
} else { $env:CODEX_HOME }
$healthCommand = Join-Path $codexDirectory 'skills\mql5-coding\scripts\Test-Mql5Environment.ps1'
powershell.exe -NoLogo -NoProfile -ExecutionPolicy Bypass -File $healthCommand -ClientHost Codex -WorkspaceRoot '<absolute-workspace-directory>'

# Claude Code
$claudeDirectory = if ([string]::IsNullOrWhiteSpace($env:CLAUDE_CONFIG_DIR)) {
    Join-Path $env:USERPROFILE '.claude'
} else { $env:CLAUDE_CONFIG_DIR }
$healthCommand = Join-Path $claudeDirectory 'skills\mql5-coding\scripts\Test-Mql5Environment.ps1'
powershell.exe -NoLogo -NoProfile -ExecutionPolicy Bypass -File $healthCommand -ClientHost Claude -WorkspaceRoot '<absolute-workspace-directory>'
```

Use `-Json` for structured output and `-ReportPath '<new-report.json>'` to retain evidence. Missing optional compiler/Python tools and source differences are warnings; `-RequireCompiler` and `-RequirePython` make their absence fail. This command never starts MetaEditor/MT5 or changes configuration. Direct stdio success does not establish tool loading in the current chat. See [all options and limits](skills/mql5-coding/references/environment-health.md).

Compiler discovery requires editor file major version 5 and rejects directories containing a non-MT5 terminal, including mixed MT4/MT5 installations. Standalone editors also need an explicit MetaEditor 5 description.

## Documentation and compilation

For multi-identifier reviews, MCP 1.3.0 adds `mql5_chm_lookup_identifiers`: 1 to 16 names per call, up to three candidates per name, with order, match status and citations preserved. The skill uses it when available and retains single-search fallback for older servers and chats. Always read and verify the cited passage before asserting an API fact. The optional consumer contract is tested against the actual server.

The [reusable toolkit](skills/mql5-coding/references/toolkit.md) adds one standard-library Python analysis CLI (`report read/compare`, `includes inventory/compare`, `profile read/compare`), a PowerShell journal processor, and a sequential scenario controller. It reuses current profiles, compiler receipts, tester execution, process cleanup, and redaction. Native statistics, execution status, evidence linkage, comparison conditions, and explicit expectations remain separate. Conditional helpers are selected only when useful.

Focused review, performance, and refactoring references extend the existing guidance. Scenario/comparison templates live under `assets/`, alongside a small assertion include and nontrading self-test EA. Genuine sanitized MT5 trading/no-trade reports and native MetaEditor profiler exports live under `tests/fixtures/` with provenance. They are validation inputs, not extra MCP tools.

Save each EA's entrypoints, include directory, MetaEditor, and optional terminal/preset/tester settings with `New-Mql5ProjectProfile.ps1`. Use `Invoke-Mql5Project.ps1` to validate resolved paths, compile all or one saved entrypoint, or delegate a selected tester action. Project-relative paths survive moving the EA folder and its profile together. Trusted receipts/hashes and output paths remain separate per-run inputs. Tester execution on a terminal whose saved-account state is `present` or `unknown` is blocked until the user explicitly confirms and `-AcknowledgeSavedAccountRisk` is passed; the profile runner forwards that switch. See [commands and limitations](skills/mql5-coding/references/project-profiles.md).

Profile paths must use their documented relative base or a fully qualified absolute path. Values such as `\EA\Main.mq5` and `C:Main.mq5` are rejected rather than resolved through the process's current drive or directory. Update recovery also resolves repeated interrupted rollbacks and retains their original snapshot links if marker cleanup fails.

For an identifier lookup, check the returned passage for the complete identifier and inspect `focus_match` when present. An `approximate` or `none` result does not establish support for the requested identifier; continue reading or select another documented result.

Use the bundled `Compile-Mql5.ps1` wrapper as described in the skill. Pass source and include paths as ordinary quoted PowerShell arguments, including paths containing spaces. The wrapper keeps MetaEditor switch prefixes outside quoted path values; do not embed quotation marks inside the supplied path strings.

Each compilation with a validated source emits `MQL5_COMPILE_RECEIPT=<absolute-json-path>` and preserves a unique JSON receipt and available MetaEditor log beside the source. The receipt includes compiler build/version and hash, errors/warnings, options, exit code, source/EX5 hashes, byte lengths, and log location. It preserves earlier receipts and existing project logs. Failed and syntax-only receipts cannot authorize tester staging.

Profiles, compilation receipts, and release metadata require a JSON object at the root. A single-element array around a valid record is rejected before PowerShell can unwrap it.

Packaging, updates, and health inspection enforce the same exact version-record fields and JSON types. Rollback validates backup identities and all pending recovery records before changing installed files or removing markers, so malformed recovery metadata preserves the installation and retained evidence.

Release helpers preserve absolute drive roots such as `X:\` and inventory the complete selected tree even when the current folder is below that root. Packaging output must remain outside the skill tree, including when the skill occupies a drive root.

Pass that receipt to `Invoke-Mt5TesterSmoke.ps1 -CompilationReceiptPath "<absolute-json-path>"` with the exact EX5 and explicit tester settings. Preflight and execution verify the receipt and unchanged source, EX5, and log automatically, record the evidence in the tester result, and lock those files through cleanup. An explicit `-ExpectedExpertSha256` must agree if also supplied; the existing trusted-EX5 workflow remains supported. Receipts cover the root source, not included `.mqh` files or runtime dependencies, and are unsigned local evidence.

## Install with Codex

Ask Codex:

```text
Use $skill-installer to install the mql5-coding skill from
https://github.com/shamwi2846/MQL5-Coding-Skill/tree/main/skills/mql5-coding
```

The installer places the skill at `CODEX_HOME\skills\mql5-coding` and refuses to overwrite an existing installation. Fully restart Codex after installation.

## Install from a downloaded ZIP

[Download the main branch ZIP](https://github.com/shamwi2846/MQL5-Coding-Skill/archive/refs/heads/main.zip), extract it, then run the following from its root only when the destination does not already exist. Private-repository downloads require an authenticated GitHub account with access.

```powershell
$codexHome = if ([string]::IsNullOrWhiteSpace($env:CODEX_HOME)) {
    Join-Path $env:USERPROFILE ".codex"
} else {
    $env:CODEX_HOME
}
$destination = Join-Path $codexHome "skills\mql5-coding"
if (Test-Path -LiteralPath $destination) {
    throw "Skill already exists: $destination"
}
[IO.Directory]::CreateDirectory((Split-Path -Parent $destination)) | Out-Null
Copy-Item -LiteralPath ".\skills\mql5-coding" -Destination $destination -Recurse
```

Fully restart Codex after installation.

## Safety boundaries

- The skill completes the requested task and necessary supporting actions without additional permission prompts. Codex, tool, operating-system, and account requirements still apply.
- MQL5 API and language claims use the installed MQL5 CHM first, with cited primary-source fallback when the CHM cannot verify a necessary fact or the MCP is unavailable.
- Review and diagnosis preserve source files unless the task also includes changes.
- Compilation does not prove Strategy Tester, broker, demo, or live behavior.
- Strategy Tester execution and EA default inputs need no additional acceptance, with one gate: on a terminal whose saved-account state is `present` or `unknown`, `-Execute` is blocked (exit `4`) until the user explicitly confirms that its saved, possibly live, account may log in and resume Signals copying, and `-AcknowledgeSavedAccountRisk` is passed. Execution evidence still requires verified artifacts, settings, and process cleanup.
- The bundled runner is not a sandbox. Never execute an untrusted `.ex5`.
- Trade operations stay within the actions and account scope established by the user's task. Review, compilation, and tester smoke validation do not initiate trades.

## Repository layout

```text
skills/mql5-coding/
  SKILL.md
  version.json
  agents/openai.yaml
  references/mcp-contract.json
  references/environment-health.md
  references/project-profiles.md
  references/releases.md
  references/strategy-tester.md
  scripts/Compile-Mql5.ps1
  scripts/SkillRelease.ps1
  scripts/Update-Mql5Skill.ps1
  scripts/Test-Mql5Environment.ps1
  scripts/Mql5ProjectProfile.ps1
  scripts/New-Mql5ProjectProfile.ps1
  scripts/Invoke-Mql5Project.ps1
  scripts/WindowsExecutableMetadata.ps1
  scripts/CompilationReceipt.ps1
  scripts/CompilerProcessJob.cs
  scripts/Invoke-Mt5TesterSmoke.ps1
  scripts/TesterProcessJob.cs
  scripts/TesterPathIntegrity.ps1
  scripts/TesterEvidence.ps1
```

Repository-level tests use synthetic MetaEditor and terminal executables. They do not require or launch real MetaTrader 5.

## Validation

GitHub Actions and the local test commands validate:

- skill metadata, dependency declaration, links, portable paths, and the packaged MCP consumer contract;
- the actual MCP server against this skill on each trusted push and pull request, with exact repository revisions retained in a compatibility artifact;
- PowerShell syntax under PowerShell 7 and Windows PowerShell 5.1;
- reproducible release ZIPs and sidecars, full file verification, authenticated metadata policy, legacy and versioned updates, additional verified resources, backup/rollback, interruption recovery, concurrent updater exclusion, archive tampering and path rejection under both shells;
- project profiles under both shells: creation/overwrite refusal, moved paths, rejected execution fields and malformed selections, multiple entrypoints, compiler exit-code propagation, receipt freshness, and synthetic tester delegation without an acknowledgement switch;
- environment-health success and failure cases against a real MCP bundle under both shells, including disabled registrations, checksum failures, source differences, optional dependencies, timeouts, redaction, preserved files, and an editor that must never be launched;
- compiler-wrapper completion, source-path lease, artifact, exit-code contracts, compilation receipts, and automatic tester verification/rejection of changed evidence without starting real MetaEditor;
- Strategy Tester preflight, mount-manager drive validation, path-handle volume correlation, non-reparse path-chain leases, pinned nonempty-directory guards, pinned journal evidence, stable terminal-image identity checks, secret redaction, unambiguous correlated completion, adversarial log rejection, and timeout cleanup without starting real MT5.

For local metadata validation, use the shared MQL5 Python environment when it is installed. Supply the validator's absolute path because the launcher starts in its own `work` directory:

```powershell
$codexHome = if ([string]::IsNullOrWhiteSpace($env:CODEX_HOME)) {
    Join-Path $env:USERPROFILE ".codex"
} else {
    $env:CODEX_HOME
}
$pythonLauncher = Join-Path $codexHome "tools\mql5-python\mql5-python.cmd"
if (-not (Test-Path -LiteralPath $pythonLauncher -PathType Leaf)) {
    throw "Shared MQL5 Python launcher is unavailable: $pythonLauncher"
}
$validator = (Resolve-Path -LiteralPath ".\tests\validate_skill.py").Path
& $pythonLauncher $validator
if ($LASTEXITCODE -ne 0) { throw "Skill metadata validation failed: $LASTEXITCODE" }
```

Run the PowerShell suites sequentially after other validation runs finish:

```powershell
pwsh -NoProfile -ExecutionPolicy Bypass -File .\tests\Test-Skill.ps1
powershell.exe -NoLogo -NoProfile -ExecutionPolicy Bypass -File .\tests\Test-Skill.ps1
pwsh -NoProfile -ExecutionPolicy Bypass -File .\tests\Test-ExecutableMetadata.ps1
powershell.exe -NoLogo -NoProfile -ExecutionPolicy Bypass -File .\tests\Test-ExecutableMetadata.ps1
pwsh -NoProfile -ExecutionPolicy Bypass -File .\tests\Test-HealthProbe.ps1
powershell.exe -NoLogo -NoProfile -ExecutionPolicy Bypass -File .\tests\Test-HealthProbe.ps1
pwsh -NoProfile -ExecutionPolicy Bypass -File .\tests\Test-ProjectProfiles.ps1
powershell.exe -NoLogo -NoProfile -ExecutionPolicy Bypass -File .\tests\Test-ProjectProfiles.ps1
pwsh -NoProfile -ExecutionPolicy Bypass -File .\tests\Test-SkillReleases.ps1
powershell.exe -NoLogo -NoProfile -ExecutionPolicy Bypass -File .\tests\Test-SkillReleases.ps1
```

Run `python -B -m unittest discover -s tests -p 'test_toolkit*.py' -v` and `tests/Test-Toolkit.ps1 -PythonPath <existing-python.exe>` under both supported PowerShell versions. The latter exercises native owned-process orchestration with synthetic executables and reuses the real profile validator. `tests/evaluate_toolkit.py` records fixed-scope comparisons with and without helpers; it reports correctness, commands, retries, elapsed time, output bytes, processing code, and unavailable token measurements without claiming general savings. See [evaluation cases](tests/evaluation-cases.json).

CI uses an isolated Python 3.12 x64 environment and installs `PyYAML==6.0.3` from `.github/requirements-ci.txt`, which locks the expected wheel hash. The local shared environment was also validated with Python 3.13. Do not modify a global Python environment solely to run repository validation. A real MetaEditor or MT5 fixture run is separate from these synthetic suites and follows the skill's compilation and tester workflow.

Compatibility CI checks both counterpart `main` (or explicit `peer_ref`) and the exact approved MCP version and commit in `.github/approved-peer.json`. The record is independent of the containing skill commit, and packaging waits for both checks.

CI preserves running main/tag validations and gives each manually dispatched package check an independent concurrency group. New pull-request validations can supersede older runs for the same pull request. The combined selection/native-harness step checks each command's exit code immediately, so a later successful suite cannot hide an earlier failure. These policies have executable regressions in `tests/test_ci_workflows.py`, including failure propagation under PowerShell 7 and 5.1.

The development workflow evaluator verifies both empty job accounting and released output-file handles before reporting process cleanup. It waits within the existing bounded cleanup deadline; an output file that remains held produces unverified cleanup and prevents continuation. This also keeps retained traces available for immediate inspection or movement after a timed-out child exits.

Workflow evaluation uses stable Codex CLI 0.162.1 with a separate live setup preflight before scored tasks. `--preflight-only` verifies model acceptance, structured output, sandbox file operations and the reviewed MCP identities. Actual CLI discovery must show exactly the selected staged skill enabled before preflight and each task, including exclusion of unrelated user and bundled skills. Shared setup failures stop the batch without fallback. The development native harness also accepts an optional private `--demo-auth-file` for a newly provisioned MetaQuotes-Demo account. It verifies the connected account with a nontrading script outside Strategy Tester, keeps temporary authentication outside retained artifacts and requires verified cleanup. See [evaluation setup](tests/WORKFLOW-EVALUATION.md) and [native integration](tests/NATIVE-INTEGRATION.md).

## Publishing a stable skill release

Update `skills/mql5-coding/version.json`, commit and push the complete reviewed change, then push a matching `v<version>` tag. The tag's CI must succeed: metadata, compiler/tester and profile suites in both shells, the updater suite in both shells, and the actual MCP pair. The release job binds the checkout SHA and tag, builds twice, compares ZIP and sidecar SHA-256, and retains `mql5-coding-release-<commit>`. Download that successful run's artifact, inspect its manifest/commit, and publish those exact two assets with `gh release create <tag> --verify-tag --notes-file <release-notes-file>`. GitHub publication is a separate maintainer action; CI does not write releases. The updater accepts published stable releases with a GitHub asset digest and validates all packaged files. Keep the source tag and source-commit manifest with each package.

## MCP compatibility checks

The packaged `references/mcp-contract.json` describes the documentation interfaces consumed by this skill. Both repositories run `.github/workflows/skill-compatibility.yml` against their current checkout and the counterpart's `main` branch. Manual runs can select a counterpart ref. The tests use the real bundled MCP over stdio with an indexed synthetic corpus, not a mocked server or copied skill. They verify tool names, read-only annotations, inputs, revisions and citation fields, bounded reads and cursors, exact identifier evidence, image bytes, invalid-input rejection, and unchanged corpus files. The artifact records both Git commits and hashes of the server and consumer files. Synthetic fixtures are interface evidence, not MQL5 API documentation or MT5 execution evidence.

For local commands and optional validation of the installed pair, see the counterpart's [compatibility guide](https://github.com/shamwi2846/MQL5-CHM-MCP/blob/main/docs/skill-compatibility.md).

Both repositories are public, so the counterpart is checked out with the job's read-only workflow token and no secret, and pull requests from forks run the pair check too (an owner approves workflow runs from outside contributors first). Checkouts disable persisted credentials. MCP release validation waits for this compatibility job before packaging; skill tag pushes also run the pair check. See [SECURITY.md](SECURITY.md) for vulnerability reporting and the automated checks.

## Release history

v1.2.10 applies a CodeRabbit review of the 1.2.4–1.2.9 changes. The Claude Code health check reads the workspace project's `disabledMcpServers` list, so a server turned off with `/mcp disable` is reported as `disabled` (`mcp_disabled`) instead of enabled. When several data directories name the same terminal installation in `origin.txt`, the tester runner still blocks the run (exit `4`) but now says the startup directory is ambiguous and how to resolve it, instead of asking for a selection that cannot succeed.

v1.2.9 follows a review of 62 real EA-project sessions. `SKILL.md` says batch lookups take identifiers or exact topic titles (MCP 1.3.16+), that the read tool has no offset or limit (continue with `next_cursor`), what to do when the `mql5_chm_*` tools are missing from a chat although the health check passes, that terminal configuration and features newer than the CHM come from official metatrader5.com/mql5.com pages, and to run the health check for setup, updates or suspected faults rather than every task. `Compile-Mql5.ps1` retries publishing a compilation receipt for about two seconds when another process (typically antivirus) briefly holds it; an existing receipt or any other error still fails at once. Path-integrity lease failures now include the Win32 code and reason (for example 32, file in use). The tester reference says how to recover when the bound terminal is already running.

v1.2.8 rejects a GitHub CLI result whose process cleanup cannot be verified instead of accepting it or reporting the process as stopped. The health check records why a failed MCP Node or stdio probe failed (`mcp.probe_failure`: phase, fixed reason category and exit code) and adds matching recovery advice without including probe output; the README lists Claude Code in the requirements and shows the health command for both clients.

v1.2.7 runs the updater's GitHub CLI calls in a kill-on-close process job with deadlines (120 s for release metadata, 600 s for the download), reports a missing `gh.exe` before any GitHub call, and shares that runner with the toolkit. The rollback example now passes `-ClientHost`, and the README describes the saved-account tester gate accurately.

v1.2.6 tells agents to use the MCP tool names their client lists in Codex or Claude Code and aligns with the MCP's own connection instructions (MCP 1.3.12). v1.2.5 read native tester reports with a bounded read (oversized reports are rejected without buffering them) and treats path-resolution runtime errors as tooling failures. v1.2.4 halved the always-loaded `SKILL.md` (compile and receipt detail now lives in the on-demand `references/compile.md`, the shared Python environment in `references/toolkit.md`) and tells agents to batch identifier lookups, read targeted sections without image/related metadata for text work, and reuse verified passages. v1.2.3 added Claude Code support: the updater installs, updates and rolls back a Claude Code copy with `-ClientHost Claude`, the environment health check verifies Claude Code's `mql5-chm` registration, and the instructions resolve scripts from the installed skill root in either client. The Strategy Tester runner now inspects the terminal's default data directory, blocks a mismatched `-TerminalDataPath`, and requires explicit user confirmation (`-AcknowledgeSavedAccountRisk`) before executing on a terminal with saved or uninspectable account state, because startup can log into a live account and resume Signals copying. Direct runs require a compilation receipt or trusted EX5 hash, automatic discovery skips data folders of removed installations, and evidence redaction covers acronym and all-caps secret labels. v1.2.2 kept the model selected for the current request and removed named-model evaluation defaults. It retains the implicit skill-selection evaluations and development-only native integration harness introduced in v1.2.1. It preserves the optional include snapshots bound to compilation receipts, complete Codex workflow evaluations, and approved-commit compatibility introduced in v1.2.0. Snapshot verification protects recorded known files and reports include uncertainty; ordinary commands retain their defaults. It retains v1.1.29 fixes applying one MetaEditor 5 selection policy to compilation, saved profiles, and environment health, with incompatible explicit selections rejected before launch and inspected sibling terminals pinned during compilation. It retains shared Windows executable metadata queries that retain versions and builds at long paths, and preserving fixes for scenario batches that rejected valid large compiler logs while retaining the full log and receipt, and preserving previous fixes including shared JSON validation that rejects invalid Unicode bytes and escapes in saved profiles, scenario selectors, journal evidence, and release metadata before their text can change, the reusable analysis toolkit, comparisons that preserve EA input whitespace, consistent tooling-error exits for failed Python, journal, and batch evidence writes, report count validation that prevents invalid statistics from satisfying expectations, include inventories that preserve Unicode text and filenames without changing physical source lines, complete batch scenario-name validation before any execution, profiler comparisons that retain known build-setting conflicts when other settings are missing, include scanning that preserves dependencies after comments in LF, CRLF, and CR-only sources, batch marker validation that shares the tester's strict format and limits before executing any scenario, saved-profile include inventories that use the compiler root's standard Include directory, include discovery after angle-bracket filenames containing apostrophes, signed tester execution-mode import, entrypoint path normalization for include inventories, terminal-build extraction from report headers, journal overlap detection across physical file aliases, fallback handling that avoids recounting overlapping evidence, exclusive PowerShell output-directory creation, and JSON validation that preserves numeric types and rejects invalid Unicode before writing results. Local delivery uses a reviewed source commit, a reproducible package, and the verified offline updater; this work does not publish a GitHub release. For online installation, select an explicit [published release](https://github.com/shamwi2846/MQL5-Coding-Skill/releases). The trusted `scripts/Update-Mql5Skill.ps1` verifies source identity, the manifest, every file, and the archive digest before replacing skill contents. It retains a complete backup and supports verified rollback. See [commands, recovery and trust limits](skills/mql5-coding/references/releases.md).
