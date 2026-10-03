# Cleanup and refactoring

Write the behavior to preserve before editing: public inputs/presets, event sequencing, calculation boundaries, ownership filters, and expected side effects. Keep unrelated strategy changes separate. Identify entrypoints and shared consumers using source reading and, when useful, [include snapshots](toolkit.md). Uncertain include coverage requires review before narrowing validation.

Use small changes with inspectable diffs. Remove unused code only with evidence about references and conditional use; a scanner's absence of a match is not proof. For moved or shared functions, verify include rules through the MCP and compile all possible affected entrypoints. Cycles and conditional declarations need compiler evidence rather than automatic error labels.

Copy [the assertion include](../assets/Mql5Assertions.mqh) and [nontrading example EA](../assets/Mql5ToolkitSelfTest.mq5) together into a scratch project when isolated calculations or state transitions need tests. Replace the example implementation and independently specified cases with the project's contract. The sample clamps to [-2,3] and exercises an absorbing fault state; it contains no trading calls and refuses non-tester execution. Supply a fresh hex nonce using a selected preset, and require its full labeled marker through the existing tester workflow.

Compile success, passing example cases, and matching headline report statistics establish different evidence. Inspect behavior appropriate to the actual change; do not call any of them complete runtime equivalence.
