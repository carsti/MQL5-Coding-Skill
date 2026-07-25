# MQL5 Coding Skill

A Windows Codex skill for building, reviewing, compiling, testing, explaining, and debugging MetaTrader 5 MQL5 programs. It uses the installed [MQL5 CHM MCP](https://github.com/shamwi2846/MQL5-CHM-MCP) as the first authority for MQL5 API and language facts.

The skill covers Expert Advisors, indicators, scripts, services, libraries, `.mq5`, `.mqh`, and `.ex5` files. It intentionally excludes MQL4 and MetaTrader 4.

## Requirements

- Windows with PowerShell 7 or Windows PowerShell 5.1.
- Codex with skill support.
- The `mql5-chm` MCP server installed and enabled.
- MetaTrader 5 and MetaEditor only when compilation or Strategy Tester execution is requested.
- Ordinary local-drive paths without reparse-point components for Strategy Tester staging and evidence.
- The shared MQL5 Python launcher under `CODEX_HOME\tools\mql5-python` only for optional Python analysis.

Ordinary source review and explanation do not start MetaTrader, MetaEditor, or Strategy Tester.

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
  references/strategy-tester.md
  scripts/Compile-Mql5.ps1
  scripts/CompilerProcessJob.cs
  scripts/Invoke-Mt5TesterSmoke.ps1
```

Repository-level tests use synthetic MetaEditor and terminal executables. They do not require or launch real MetaTrader 5.

## Validation

GitHub Actions and the local test commands validate:

- skill metadata, dependency declaration, links, and portable paths;
- PowerShell syntax under PowerShell 7 and Windows PowerShell 5.1;
- compiler-wrapper completion, artifact, and exit-code contracts without starting MetaEditor;
- Strategy Tester preflight, non-reparse path-chain leases, pinned journal evidence, stable terminal-image identity checks, unambiguous correlated completion, adversarial log rejection, and timeout cleanup without starting real MT5.

Run locally inside an isolated Python 3.12 x64 environment with `PyYAML==6.0.3` available:

```powershell
python .\tests\validate_skill.py
pwsh -NoProfile -ExecutionPolicy Bypass -File .\tests\Test-Skill.ps1
powershell.exe -NoLogo -NoProfile -ExecutionPolicy Bypass -File .\tests\Test-Skill.ps1
```

CI installs the validator dependency from `.github/requirements-ci.txt`, which locks the expected Windows x64 Python 3.12 wheel hash. Do not modify a global Python environment solely to run repository validation.
