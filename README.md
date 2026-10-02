# MQL5 Coding Skill

A Windows Codex skill for building, reviewing, compiling, testing, explaining, and debugging MetaTrader 5 MQL5 programs. It uses the installed [MQL5 CHM MCP](https://github.com/shamwi2846/MQL5-CHM-MCP) as the first authority for MQL5 API and language facts.

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

## Documentation and compilation

For an identifier lookup, check the returned passage for the complete identifier and inspect `focus_match` when present. An `approximate` or `none` result does not establish support for the requested identifier; continue reading or select another documented result.

Use the bundled `Compile-Mql5.ps1` wrapper as described in the skill. Pass source and include paths as ordinary quoted PowerShell arguments, including paths containing spaces. The wrapper keeps MetaEditor switch prefixes outside quoted path values; do not embed quotation marks inside the supplied path strings.

Each compilation with a validated source emits `MQL5_COMPILE_RECEIPT=<absolute-json-path>` and preserves a unique JSON receipt and available MetaEditor log beside the source. The receipt includes compiler build/version and hash, errors/warnings, options, exit code, source/EX5 hashes, byte lengths, and log location. It preserves earlier receipts and existing project logs. Failed and syntax-only receipts cannot authorize tester staging.

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

- MQL5 API and language claims must use the installed MQL5 CHM first.
- Review and diagnosis do not authorize edits.
- Compilation does not prove Strategy Tester, broker, demo, or live behavior.
- Strategy Tester execution is opt-in and requires informed acknowledgement that the selected terminal may initialize saved account state.
- The bundled runner is not a sandbox. Never execute an untrusted `.ex5`.
- The skill never authorizes placing, modifying, or cancelling live trades without explicit account-scoped user authorization.

## Repository layout

```text
skills/mql5-coding/
  SKILL.md
  agents/openai.yaml
  references/mcp-contract.json
  references/strategy-tester.md
  scripts/Compile-Mql5.ps1
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
```

CI uses an isolated Python 3.12 x64 environment and installs `PyYAML==6.0.3` from `.github/requirements-ci.txt`, which locks the expected wheel hash. The local shared environment was also validated with Python 3.13. Do not modify a global Python environment solely to run repository validation. A real MetaEditor or MT5 fixture run is separate from these synthetic suites and follows the skill's compilation and tester workflow.

## MCP compatibility checks

The packaged `references/mcp-contract.json` describes the documentation interfaces consumed by this skill. Both repositories run `.github/workflows/skill-compatibility.yml` against their current checkout and the counterpart's `main` branch. Manual runs can select a counterpart ref. The tests use the real bundled MCP over stdio with an indexed synthetic corpus, not a mocked server or copied skill. They verify tool names, read-only annotations, inputs, revisions and citation fields, bounded reads and cursors, exact identifier evidence, image bytes, invalid-input rejection, and unchanged corpus files. The artifact records both Git commits and hashes of the server and consumer files. Synthetic fixtures are interface evidence, not MQL5 API documentation or MT5 execution evidence.

For local commands and optional validation of the installed pair, see the counterpart's [compatibility guide](https://github.com/shamwi2846/MQL5-CHM-MCP/blob/main/docs/skill-compatibility.md).

Both repositories are private. Each requires the Actions secret `MQL5_PEER_READ_KEY` containing a dedicated read-only SSH deploy key registered on the counterpart repository. Never reuse an account token or a write-enabled deploy key. Checkouts disable persisted credentials; fork pull requests skip the job that needs this secret. A trusted run with missing credentials fails. Rotate each key on its target repository and replace the consumer secret together. MCP release validation waits for this compatibility job before packaging; skill tag pushes also run the pair check.
