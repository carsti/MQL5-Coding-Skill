# MQL5 Coding Skill

For multi-identifier reviews, MCP 1.3.0 adds `mql5_chm_lookup_identifiers`: 1 to 16 names per call, up to three candidates per name, with order, match status and citations preserved. The skill uses it when available and retains single-search fallback for older servers and chats. Always read and verify the cited passage before asserting an API fact. The optional consumer contract is tested against the actual server.

A Windows Codex skill for building, reviewing, compiling, testing, explaining, and debugging MetaTrader 5 MQL5 programs. It uses the installed [MQL5 CHM MCP](https://github.com/shamwi2846/MQL5-CHM-MCP) as the first authority for MQL5 API and language facts.

This checkout prepares **v1.1.26**, including shared JSON validation that rejects invalid Unicode bytes and escapes in saved profiles, scenario selectors, journal evidence, and release metadata before their text can change, the reusable analysis toolkit, comparisons that preserve EA input whitespace, consistent tooling-error exits for failed Python, journal, and batch evidence writes, report count validation that prevents invalid statistics from satisfying expectations, include inventories that preserve Unicode text and filenames without changing physical source lines, complete batch scenario-name validation before any execution, profiler comparisons that retain known build-setting conflicts when other settings are missing, include scanning that preserves dependencies after comments in LF, CRLF, and CR-only sources, batch marker validation that shares the tester's strict format and limits before executing any scenario, saved-profile include inventories that use the compiler root's standard Include directory, include discovery after angle-bracket filenames containing apostrophes, signed tester execution-mode import, entrypoint path normalization for include inventories, terminal-build extraction from report headers, journal overlap detection across physical file aliases, fallback handling that avoids recounting overlapping evidence, exclusive PowerShell output-directory creation, and JSON validation that preserves numeric types and rejects invalid Unicode before writing results. Local delivery uses a reviewed source commit, a reproducible package, and the verified offline updater; this work does not publish a GitHub release. For online installation, select an explicit [published release](https://github.com/shamwi2846/MQL5-Coding-Skill/releases). The trusted `scripts/Update-Mql5Skill.ps1` verifies source identity, the manifest, every file, and the archive digest before replacing skill contents. It retains a complete backup and supports verified rollback. See [commands, recovery and trust limits](skills/mql5-coding/references/releases.md).

The skill covers Expert Advisors, indicators, scripts, services, libraries, `.mq5`, `.mqh`, and `.ex5` files. It intentionally excludes MQL4 and MetaTrader 4.

## Requirements

- Windows with PowerShell 7 or Windows PowerShell 5.1.
- Codex with skill support.
- The `mql5-chm` MCP server installed and enabled.
- MetaTrader 5 and MetaEditor only when compilation or Strategy Tester execution is requested.
- Direct fixed-local-volume paths registered by the Windows mount manager and without reparse-point components for Strategy Tester staging and evidence; mapped network drives, SUBST aliases, and raw DOS-device aliases are rejected.
- An ordinary `.mq5` source file for compilation; directory-junction aliases are canonicalized, but source-file symlinks/reparse points are rejected.
- The shared MQL5 Python launcher under `CODEX_HOME\tools\mql5-python` only for optional Python analysis.

Ordinary source review and explanation do not start MetaTrader, MetaEditor, or Strategy Tester.

## One environment health command

Run the installed read-only checker to report Codex registration, real MCP stdio availability, listed package checksums and versions, source/installed differences, MetaEditor paths/builds, and Python/PyYAML availability:

```powershell
$codexDirectory = if ([string]::IsNullOrWhiteSpace($env:CODEX_HOME)) {
    Join-Path $env:USERPROFILE '.codex'
} else { $env:CODEX_HOME }
$healthCommand = Join-Path $codexDirectory 'skills\mql5-coding\scripts\Test-Mql5Environment.ps1'
powershell.exe -NoLogo -NoProfile -ExecutionPolicy Bypass -File $healthCommand -WorkspaceRoot '<absolute-workspace-directory>'
```

Use `-Json` for structured output and `-ReportPath '<new-report.json>'` to retain evidence. Missing optional compiler/Python tools and source differences are warnings; `-RequireCompiler` and `-RequirePython` make their absence fail. This command never starts MetaEditor/MT5 or changes configuration. Direct stdio success does not establish tool loading in the current chat. See [all options and limits](skills/mql5-coding/references/environment-health.md).

Compiler discovery requires editor file major version 5 and rejects directories containing a non-MT5 terminal, including mixed MT4/MT5 installations. Standalone editors also need an explicit MetaEditor 5 description.

## Documentation and compilation

The [reusable toolkit](skills/mql5-coding/references/toolkit.md) adds one standard-library Python analysis CLI (`report read/compare`, `includes inventory/compare`, `profile read/compare`), a PowerShell journal processor, and a sequential scenario controller. It reuses current profiles, compiler receipts, tester execution, process cleanup, and redaction. Native statistics, execution status, evidence linkage, comparison conditions, and explicit expectations remain separate. Conditional helpers are selected only when useful.

Focused review, performance, and refactoring references extend the existing guidance. Scenario/comparison templates live under `assets/`, alongside a small assertion include and nontrading self-test EA. Genuine sanitized MT5 trading/no-trade reports and native MetaEditor profiler exports live under `tests/fixtures/` with provenance. They are validation inputs, not extra MCP tools.

Save each EA's entrypoints, include directory, MetaEditor, and optional terminal/preset/tester settings with `New-Mql5ProjectProfile.ps1`. Use `Invoke-Mql5Project.ps1` to validate resolved paths, compile all or one saved entrypoint, or delegate a selected tester action. Project-relative paths survive moving the EA folder and its profile together. Trusted receipts/hashes and output paths remain separate per-run inputs. Execution requires no separate acknowledgement; the old switch remains optional for command compatibility. See [commands and limitations](skills/mql5-coding/references/project-profiles.md).

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
- Strategy Tester execution and EA default inputs need no additional acceptance. The selected terminal may initialize saved account state; execution evidence still requires verified artifacts, settings, and process cleanup.
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
pwsh -NoProfile -ExecutionPolicy Bypass -File .\tests\Test-HealthProbe.ps1
powershell.exe -NoLogo -NoProfile -ExecutionPolicy Bypass -File .\tests\Test-HealthProbe.ps1
pwsh -NoProfile -ExecutionPolicy Bypass -File .\tests\Test-ProjectProfiles.ps1
powershell.exe -NoLogo -NoProfile -ExecutionPolicy Bypass -File .\tests\Test-ProjectProfiles.ps1
pwsh -NoProfile -ExecutionPolicy Bypass -File .\tests\Test-SkillReleases.ps1
powershell.exe -NoLogo -NoProfile -ExecutionPolicy Bypass -File .\tests\Test-SkillReleases.ps1
```

Run `python -B -m unittest discover -s tests -p 'test_toolkit*.py' -v` and `tests/Test-Toolkit.ps1 -PythonPath <existing-python.exe>` under both supported PowerShell versions. The latter exercises native owned-process orchestration with synthetic executables and reuses the real profile validator. `tests/evaluate_toolkit.py` records fixed-scope comparisons with and without helpers; it reports correctness, commands, retries, elapsed time, output bytes, processing code, and unavailable token measurements without claiming general savings. See [evaluation cases](tests/evaluation-cases.json).

CI uses an isolated Python 3.12 x64 environment and installs `PyYAML==6.0.3` from `.github/requirements-ci.txt`, which locks the expected wheel hash. The local shared environment was also validated with Python 3.13. Do not modify a global Python environment solely to run repository validation. A real MetaEditor or MT5 fixture run is separate from these synthetic suites and follows the skill's compilation and tester workflow.

## Publishing a stable skill release

Update `skills/mql5-coding/version.json`, commit and push the complete reviewed change, then push a matching `v<version>` tag. The tag's CI must succeed: metadata, compiler/tester and profile suites in both shells, the updater suite in both shells, and the actual MCP pair. The release job binds the checkout SHA and tag, builds twice, compares ZIP and sidecar SHA-256, and retains `mql5-coding-release-<commit>`. Download that successful run's artifact, inspect its manifest/commit, and publish those exact two assets with `gh release create <tag> --verify-tag --notes-file <release-notes-file>`. GitHub publication is a separate maintainer action; CI does not write releases. The updater accepts published stable releases with a GitHub asset digest and validates all packaged files. Keep the source tag and source-commit manifest with each package.

## MCP compatibility checks

The packaged `references/mcp-contract.json` describes the documentation interfaces consumed by this skill. Both repositories run `.github/workflows/skill-compatibility.yml` against their current checkout and the counterpart's `main` branch. Manual runs can select a counterpart ref. The tests use the real bundled MCP over stdio with an indexed synthetic corpus, not a mocked server or copied skill. They verify tool names, read-only annotations, inputs, revisions and citation fields, bounded reads and cursors, exact identifier evidence, image bytes, invalid-input rejection, and unchanged corpus files. The artifact records both Git commits and hashes of the server and consumer files. Synthetic fixtures are interface evidence, not MQL5 API documentation or MT5 execution evidence.

For local commands and optional validation of the installed pair, see the counterpart's [compatibility guide](https://github.com/shamwi2846/MQL5-CHM-MCP/blob/main/docs/skill-compatibility.md).

Both repositories are private. Each requires the Actions secret `MQL5_PEER_READ_KEY` containing a dedicated read-only SSH deploy key registered on the counterpart repository. Never reuse an account token or a write-enabled deploy key. Checkouts disable persisted credentials; fork pull requests skip the job that needs this secret. A trusted run with missing credentials fails. Rotate each key on its target repository and replace the consumer secret together. MCP release validation waits for this compatibility job before packaging; skill tag pushes also run the pair check.
