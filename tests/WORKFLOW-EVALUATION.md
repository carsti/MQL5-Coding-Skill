# Complete Codex workflow evaluation

`evaluate_workflows.py` executes the seven cases in `evaluation-cases.json` in fresh workspaces. The default is three repetitions for each of baseline skill 1.1.29 and candidate 1.2.0: 42 sequential agent runs. Select the same reviewed MCP package, frozen corpus, explicit CLI, Python, and PowerShell for both arms. It reads the configured model and effort once, or accepts explicit values; it never changes models or automatically retries a failed run.

Use absolute paths and a new output directory:

```powershell
& '<python.exe>' -B '<repository>/tests/evaluate_workflows.py' --skill-root '<candidate-skill>' --baseline-skill-root '<baseline-skill>' --mcp-package-root '<reviewed-portable-mcp>' --codex-path '<supported-codex.exe>' --powershell '<pwsh.exe>' --output '<new-evidence-directory>' --model gpt-6-astra --reasoning-effort xhigh
```

The CLI must support JSONL traces, structured final output, ephemeral sessions, and workspace-write sandboxing. Its version and executable hash are frozen in the result. Each run has a ten-minute maximum deadline and owned-descendant cleanup through a Windows job object. No native MetaEditor/MT5 or trading execution is permitted. Include-impact compilation uses synthetic executables whose metadata identifies them as test doubles. Isolated test preparation is checked against six independently specified boundary cases with a bounded integer-expression interpreter; this does not execute MQL5 behavior.

Only the selected staged skill and reviewed MCP are configured. Desktop IPC and originator environment variables are removed. A temporary credential store outside fixtures and retained evidence supplies normal CLI authentication and is cleaned afterward. Credentials are never copied into workspaces or evaluation artifacts. Windows execution uses the native unelevated workspace sandbox with a run-local TEMP/TMP directory; unavailable sandbox execution is failed evidence, not a reason to remove sandboxing. Synthetic executable bytes are compiled once and reused identically for both arms. Absolute path bindings differ with each fresh workspace and are retained explicitly.

Artifacts and structured conclusions determine correctness. Traces establish resource selection, completed command counts, and forbidden execution/publication attempts. Measurements retain elapsed time, console/artifact bytes, available token usage, repeated identical commands, and runner retry count zero. Semantic agent retries are explicitly unavailable as a stable metric. Retain failed and timed-out runs. Do not label baseline failures as candidate successes, infer native behavior from test doubles, or claim a general percentage improvement from this small sample.

`test_workflow_evaluator.py` validates scoring and process cleanup with synthetic traces/processes without credentials. Automatic CI runs those deterministic tests. `workflow-evaluation.yml` is manually dispatched, with one job per case. It requires a reviewed MCP commit and successful release-validation run retaining its package. Missing `OPENAI_API_KEY` produces an actionable `unavailable` artifact; the mandatory live evaluation gate runs locally. Private counterpart artifacts additionally need `MQL5_PEER_ACTIONS_TOKEN` with read-only Actions access. Job-local credentials are excluded from uploaded evidence.
