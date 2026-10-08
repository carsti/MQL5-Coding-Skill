# Build-source snapshots

Select this optional workflow when shared includes make build provenance useful. It reuses include inventories and compilation receipts. It adds no compiler-consumption guarantee: conditional, unresolved, linked, unsupported, and unselected dependencies remain visible as uncertainty.

```powershell
& '<installed-skill>/scripts/Invoke-Mql5Project.ps1' -ProfilePath '<absolute-profile.json>' -Action Compile -CaptureSourceSnapshot
& '<installed-skill>/scripts/Invoke-Mql5Project.ps1' -ProfilePath '<absolute-profile.json>' -Action TesterPreflight -CompilationReceiptPath '<absolute-receipt.json>' -BuildSnapshotPath '<absolute-receipt.json.sources.json>' -OutputDirectory '<new-absolute-directory>'
```

An explicit absolute `-PythonPath` selects an existing environment; otherwise use the current shared MQL5 Python environment. Missing Python fails with tooling exit 2 and creates no environment. `-CaptureSourceSnapshot` cannot accompany syntax-only compilation. Ordinary compilation needs no Python.

The selected entrypoint and its known literal includes are inventoried before and after compilation. Explicit profile include roots are used; no standard root is guessed. Known files are read-locked during compilation. Conditional includes remain possible dependencies. A changed known conditional dependency therefore also blocks the selected verified workflow, even when its branch might be inactive.

Every capture retains a unique `.mql5-source-snapshot-*` evidence directory beside the source. Successful artifact-producing compilation publishes a new sidecar beside its unique receipt and emits `MQL5_BUILD_SNAPSHOT=<absolute-path>`. Schema 1 contains `kind=mql5_build_source_snapshot`, `status=verified_known_sources`, the entrypoint, path/hash/byte-length commitments for the receipt and before/after/comparison JSON, coverage, and limitations. The inventories retain source hashes, dependencies, unresolved references, and comparison findings. Input evidence is not overwritten.

The sidecar also retains the known files' native volume/file identities. The optional `-BuildSnapshotPath` works in project tester actions and the existing direct tester. It requires the matching successful receipt. Snapshot/inventory commitments and current known-source hashes and identities are verified before terminal launch, and known-file locks remain held through cleanup. A byte-identical replacement with a different native identity is rejected. Changed, missing, replaced, malformed, or mismatched evidence returns tooling exit 2. Existing tester-result and receipt schemas remain unchanged. The selected workflow inherits the tester's direct local-volume, no-reparse path requirements.

The scenario wrapper accepts the same optional capture switch, forwards its selected Python, and passes the freshly emitted snapshot with the receipt to each tester. Default validation never compiles or executes. Existing invocations without snapshot options retain their behavior.

A compiler success followed by failed snapshot publication or verification remains a successful compiler receipt with a failed project verification. Retain both pieces of evidence. These local hashes are not signatures, exact preprocessor traces, runtime-dependency inventories, or strategy-behavior proof.
