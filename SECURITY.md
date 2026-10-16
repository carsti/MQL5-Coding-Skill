# Security policy

## Reporting a vulnerability

Report suspected vulnerabilities privately through GitHub: open the repository's **Security** tab and choose **Report a vulnerability**. Do not open a public issue for a security problem. Include the affected version, the steps to reproduce and the impact you observed.

## Supported versions

Only the latest release on `main` receives fixes. Releases are immutable: a published release and its assets are never edited, so a correction always ships as a new version and tag.

## Scope

In scope are the skill's scripts: compilation through MetaEditor, the Strategy Tester runner and its process and path isolation, the environment health check, the project-profile and toolkit helpers, and the updater, which verifies a release archive's SHA-256, manifest and source commit before installing. The skill never places trades, moves money or enters credentials. The tester runner refuses to start a terminal with saved accounts unless the user explicitly acknowledges that risk for the run.

## Automated checks

- **Secret scanning with push protection** blocks pushes that contain known credential formats and scans the full history.
- **Dependabot** raises alerts, and weekly pull requests that move the pinned GitHub Actions commits and the hash-pinned CI validator dependency.
- **Dependency review** fails a pull request that adds a dependency with a known high or critical vulnerability.
- **CodeQL** scans Python, C# and the workflows; **zizmor** audits the workflows; **PSScriptAnalyzer** checks the PowerShell scripts with a curated security and correctness rule set. Findings appear under **Security > Code scanning**.
- Every workflow pins its actions to full commit SHAs, checks out code without persisted credentials and runs with a read-only token unless a job needs more.

## Pins maintained by hand

Dependabot does not update these; review them at least monthly and after any advisory that affects them:

- The Codex CLI version installed by the manually dispatched `workflow-evaluation.yml` (`@openai/codex@<version>`).
- The Node.js and Python versions selected in the workflows.
- The approved MCP peer in `.github/approved-peer.json`, updated after each MCP release.
- The scanner versions: zizmor (`version:` in `.github/workflows/static-analysis.yml`) and PSScriptAnalyzer (`$AnalyzerVersion` in `.github/scripts/Invoke-PSScriptAnalyzerSarif.ps1`). Dependabot moves the actions that run them, not these versions.
