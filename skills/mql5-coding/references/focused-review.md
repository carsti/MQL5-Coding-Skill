# Focused MQL5 review

Extend the skill's existing review workflow when these concerns occur; verify relevant APIs through the documentation MCP before drawing API-specific conclusions.

- Follow event flow from initialization to tick/timer/book callbacks, shutdown, and reinitialization. Check early returns and the state they preserve. Identify which event actually updates each shared value.
- Check data readiness and return counts before using requested buffers or rates. Review indexing direction, completed-bar selection, and assumptions about history availability as separate questions.
- Trace resource ownership and lifetime through failed initialization and normal shutdown. Check releases and replacement handles against the verified API contract.
- Separate requested trade operations, accepted requests, fills, positions, and later account observations. Review ownership filtering and account mode before reasoning about management behavior.
- Test numeric boundaries against a written specification, including empty ranges, sign changes, rounding, minimum/maximum volume, and nonfinite values where relevant. Expected examples must be independently checked.
- Find repeated operations in frequently called events before calling them performance problems. Preserve intended cadence and data freshness when proposing caching.

Every finding needs a concrete trigger, source location, resulting behavior, and evidence. Label uncertain dependencies or runtime hypotheses. Compilation proves build validity; a behavior test covers only its exercised cases. A backtest report describes its recorded conditions and statistics. Use [the toolkit](toolkit.md) for repeatable evidence processing, not as an automatic code-review verdict.
