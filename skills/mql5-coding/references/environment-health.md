# MQL5 environment health

Use `scripts/Test-Mql5Environment.ps1` for installation checks and troubleshooting. It reads files and queries processes that it starts for the check. It never compiles code, starts MetaEditor or MT5, changes Codex or Claude Code configuration, downloads packages, or repairs installations.

Run it for initial setup, after installing, updating or rolling back the skill or MCP, and when a tool, compiler or terminal problem suggests an environment fault. It takes several seconds per run, so do not repeat it routinely for every task, and it cannot fix tool argument errors. When the `mql5_chm_*` tools are missing from a chat but the direct MCP check passes, start a new chat or restart the client.

Resolve the command from the installed skill root (the directory containing `SKILL.md`; normally `%USERPROFILE%\.claude\skills\mql5-coding` in Claude Code or `CODEX_HOME\skills\mql5-coding` in Codex) and select the current client with `-ClientHost Claude` or `-ClientHost Codex`. When omitted, a checker running from a Claude Code skill tree checks Claude Code and any other location checks Codex:

```powershell
$skillRoot = '<installed skill root containing SKILL.md>'
$healthCommand = Join-Path $skillRoot 'scripts\Test-Mql5Environment.ps1'
powershell.exe -NoLogo -NoProfile -ExecutionPolicy Bypass -File $healthCommand -WorkspaceRoot '<absolute-workspace-directory>'
```

PowerShell 7 (`pwsh`) and Windows PowerShell 5.1 are supported. Use an existing workspace directory; the command does not change the folder saved for a Codex or Claude Code chat. No Python dependency is needed to run the command.

Editor and associated-terminal metadata use the shared `WindowsExecutableMetadata.ps1` helper, including paths longer than 260 characters. Extended prefixes are used only for version-resource queries; reported paths remain canonical. Unreadable metadata is an explicit `executable_metadata_unavailable` error. This read-only discovery does not establish native execution support at a long path.

Explicit skill, package, and source roots may be absolute drive roots such as `X:\`. The checker preserves that separator and inventories paths relative to the selected root, including when invoked from a subfolder on that drive. Root selection must not become the drive-relative `X:` or make root files disappear from the inventory.

## Checks and their limits

- **Codex registration:** invokes the native Codex CLI's `mcp get mql5-chm --json` in the selected workspace with the selected `CODEX_HOME`. It checks the enabled state, required tool filters, command, server argument, and any explicit working directory against the selected portable package. An absent/null working directory is accepted because the absolute bundled server path selects its package independently of the inherited directory; an explicit directory must be fully qualified and match that package. Root-relative and drive-relative launch paths are rejected. Malformed enabled states, arguments, environment settings, or tool-filter types fail registration validation. An empty tool allowlist disables the required tools. See the official [Codex MCP guide](https://developers.openai.com/codex/mcp) and [configuration reference](https://developers.openai.com/codex/config-reference). CLI version is reported separately from MCP version; this does not identify the desktop app's version.
- **Claude Code registration:** reads `.claude.json` (inside `CLAUDE_CONFIG_DIR` when set, otherwise in the user's home directory) with a case-sensitive JSON reader and the workspace `.mcp.json`. It applies Claude Code's precedence (local entry for this workspace, then project `.mcp.json`, then user scope), reports the selected `registration_scope` and any `shadowed_scopes`, and applies the same command, server-argument, environment, and package checks as for Codex. A server turned off with `/mcp disable` in this workspace (its name in the project's `disabledMcpServers` array) is reported as `disabled` with `mcp_disabled`; turn it back on with `/mcp enable mql5-chm`. The Claude CLI is used only for `--version`. See the official [Claude Code MCP guide](https://code.claude.com/docs/en/mcp).
- **Probe cleanup:** each native probe starts suspended and joins an owned kill-on-close Windows Job Object before resuming, with only its standard-stream handles inherited. Every exit path terminates that job and verifies it is empty, including when the parent exited while a child retained output pipes or detached its output. Failed cleanup cannot produce a successful probe result. Each stdout and stderr stream is limited to 1,048,576 decoded characters while reading; stderr is discarded. Exceeding either limit stops the probe and fails the check without returning its output.
- **MCP integrity and availability:** verifies every entry in the package's `checksums.sha256` before running its pinned Node executable or existing smoke probe. The probe checks real stdio initialization, the four documentation tools, and `mql5_chm_status`, including the package version and active revisions. Integrity means the listed files match the local checksum manifest; it is not a signed authenticity check or an inventory of unlisted mutable files. It is a direct package probe. `native_chat_availability` remains `not_checked`: the command cannot establish whether the current chat has loaded that server. Custom registration environment settings are reported as unverified; their values are never printed. A failed Node-version or stdio probe records `mcp.probe_failure` with its `phase`, a fixed `reason` (`timeout`, `launch_failed`, `oversized_output`, `output_timeout`, `cleanup_failed`, `nonzero_exit` or `unexpected_result`) and `exit_code`, and the issue message adds matching recovery advice; probe output is never included.
- **Skill installation:** requires the packaged instructions, metadata, references, and helpers and checks the consumer contract's server name. `version.json` must be an object with exactly an integer `schema_version` of 1 and a stable version string, using the same rules as packaging and updates. Malformed roots, duplicate/unknown keys, and array/string/boolean schema values fail. It reports the semantic version, file count, and a deterministic SHA-256 fingerprint of the complete skill inventory. This is an installation check, not the full YAML/consumer-contract validator.
- **Source differences:** auto-detects source folders in the workspace, including the two nested GitHub ZIP layouts, or accepts explicit roots. The skill comparison covers every file and identifies changed, missing, or extra installed files. The MCP comparison covers common checksummed distributable files present in the selected source, excluding generated `data`, `revisions`, and `runtime` files and development-only files. It does not prove equivalence between source modules and a generated bundle. An absent source is `not_requested`; an unreadable selected source is a warning. A source difference is evidence to inspect, not an instruction to reinstall.
- **MetaEditor:** requires editor file major version 5 and checks every associated terminal's file major version. A standalone editor also needs an explicit MetaEditor 5 description. Incompatible editors, MT4 installations, and mixed MT4/MT5 terminal directories are excluded, consistent with profile validation. It lists candidate paths and builds without launching the editor; compilation readiness still requires a real compile.
- **Python:** prefers the separately managed shared MQL5 Python executable, then `python.exe` on PATH. An isolated, bytecode-disabled probe reports Python version and PyYAML presence without installing anything. Python is optional for ordinary documentation review and compilation. PyYAML is needed for repository metadata/compatibility validation.

## Options

| Option | Purpose |
| --- | --- |
| `-WorkspaceRoot` | Existing workspace used for registration and source discovery. |
| `-ClientHost` | `Codex` or `Claude`. Defaults to `Claude` when the checker runs from a Claude Code skill tree, when `-ClaudeConfigDirectory` or `-ClaudePath` is supplied; otherwise `Codex`. |
| `-CodexHome` | Override the Codex directory for this check only; defaults to `CODEX_HOME` or the user's `.codex` directory. The shared Python environment is always resolved here. |
| `-CodexPath` | Explicit native `codex.exe`; shell shims are not used. |
| `-ClaudeConfigDirectory` | Override the Claude Code configuration directory; defaults to `CLAUDE_CONFIG_DIR` or the user's `.claude` directory. |
| `-ClaudePath` | Explicit native `claude.exe`, used only for its version. |
| `-McpPackageRoot` | Portable package to inspect; otherwise inferred from registration. A registration/package mismatch fails the check. |
| `-SkillRoot` | Skill to inspect; defaults to `<claude directory>\skills\mql5-coding` for Claude Code or `CODEX_HOME\skills\mql5-coding` for Codex. |
| `-McpSourceRoot`, `-SkillSourceRoot` | Select source roots for comparison. The skill root must contain `SKILL.md`. |
| `-MetaEditorPath`, `-PythonPath` | Select executable paths instead of automatic discovery; the editor option also accepts its directory. |
| `-TimeoutSeconds` | Each ordinary subprocess probe's deadline, 5–60 seconds; default 15. MCP smoke gets five additional seconds for cleanup. Multiple probes run sequentially, so this is not a total command deadline. |
| `-RequireCompiler`, `-RequirePython` | Promote missing optional tools to errors for tasks that need them. Missing PyYAML remains a separate validation warning. |
| `-Json` | Emit only a schema-versioned JSON report to stdout. |
| `-ReportPath` | Also create a JSON report at a new filename in an existing directory. Existing files are never overwritten. |

Exit codes: **0** means required checks passed (warnings may remain); **1** means a diagnosed required check failed; **2** means the command or report creation could not complete. Read `status` and `issues`, not just the exit code. A disabled registration can coexist with `stdio_available: true`, because the direct probe is independent of the client's enabled state.

For automation, use `-Json`, inspect issue codes/severity, and preserve the report with a unique filename when evidence is needed. Treat it as a point-in-time report, not a guarantee of compilation, tester behavior, broker access, or profitability.
