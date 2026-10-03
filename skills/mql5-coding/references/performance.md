# Performance measurements

First name the user-visible cost to improve and preserve a comparable workload. Record compiler/build, profiling options, input selection, data, terminal conditions, and environment. Use the existing tester for repeated scenario execution; its wrapper duration includes startup, data preparation, analysis, and cleanup.

Use native profiler exports to locate measured Self CPU hotspots. Total CPU includes time sampled in callees; sampling counts are not call counts. Inlining, optimization, and missing mappings affect attribution. Consult the MCP for platform-specific conclusions and [the profiler importer](toolkit.md) for supported evidence.

A change in CPU percentage can be caused by a change elsewhere. Compare absolute samples and independently recorded elapsed measurements separately; repeat comparable measurements when variation matters. Do not infer overall speed from a lower percentage. Make one justified change, review the affected consumers, compile, and check relevant behavior before accepting an optimization. Preserve state-update cadence, ownership filtering, data-readiness checks, and strategy outputs.
