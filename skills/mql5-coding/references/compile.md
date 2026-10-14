# Compile with MetaEditor

Read this file completely before compiling, interpreting compiler output, or using a compilation receipt.

## Editor selection

Compilation, profiles, and environment health share one editor-selection validator. Select `metaeditor64.exe` or `metaeditor.exe` with readable major-version-5 metadata. Every sibling terminal must also be major version 5; a standalone editor must explicitly identify itself as MetaEditor 5. An incompatible explicit selection fails with tooling exit code `2` before launch. Automatic discovery skips incompatible candidates in its existing order. Compilation repeats validation against the pinned canonical executable immediately before launch and holds inspected sibling-terminal leases until process cleanup.

## Command

Invoke the bundled wrapper from the installed skill root (the directory containing `SKILL.md`) with an absolute source path:

```powershell
$skillRoot = "<installed skill root containing SKILL.md>"
$compiler = [IO.Path]::GetFullPath((Join-Path $skillRoot "scripts\Compile-Mql5.ps1"))
powershell.exe -NoLogo -NoProfile -ExecutionPolicy Bypass -File $compiler -SourcePath "<absolute-source-path>"
```

Use `-IncludePath "<absolute-MQL5-root>"` only when a required custom include root cannot be auto-detected. Use `-SyntaxOnly` only when the user explicitly requests a syntax check instead of a compiled artifact. The wrapper canonicalizes directory-junction aliases but rejects a `.mq5` source leaf that is itself a symlink or reparse point, because that pathname cannot be safely pinned for MetaEditor.

Pass source and include paths as ordinary quoted PowerShell arguments, including paths containing spaces. The wrapper keeps MetaEditor switch prefixes outside quoted path values; do not embed quotation marks inside the supplied path strings.

## Exit codes

Interpret the wrapper exit code exactly:

- `0`: MetaEditor compilation succeeded.
- `1`: MetaEditor reported compilation errors.
- `2`: wrapper or tooling failure.
- `3`: compilation timeout.
- `4`: warnings were promoted to errors.

Report all emitted errors and warnings. Automated batches use `-SuppressLogOutput` to omit the full console log while preserving its exact retained bytes, receipt, summary, and artifact references. Read the receipt's retained log when reporting individual diagnostics; ordinary compilation still prints the log by default. Never claim compilation succeeded unless the wrapper returns `0`. A successful compile does not prove correct Strategy Tester behavior, broker compatibility, demo behavior, live behavior, or profitability.

## Receipts

Retain the path emitted as `MQL5_COMPILE_RECEIPT=<absolute-json-path>`. Each compilation with a validated source creates a unique JSON receipt beside the source, plus an exact byte copy of that run's MetaEditor log when available. The receipt records the compiler version/build and hash, errors, warnings, exit code, options, and source/EX5/log hashes and lengths. Existing receipts and project logs are preserved. Failed and syntax-only attempts do not claim an accepted EX5; a receipt publication failure returns tooling exit code `2`.

For a tester run following source compilation, pass that exact receipt to `-CompilationReceiptPath`. The runner verifies and locks the receipt, root source, EX5, and retained log automatically; no manual hash extraction is needed. Receipts record the include-root path but do not fingerprint included `.mqh` files, presets, or runtime dependencies. They are local evidence, not signed attestations or proof of strategy correctness.

For shared-include projects where build-source provenance matters, select the optional [source-snapshot workflow](source-snapshots.md). It links known include hashes to the receipt and can block testing when those recorded files changed. Preserve uncertainty about conditional, unresolved, and unsupported dependencies.

## Installed artifacts

When installation into MT5 matters, distinguish the project `.ex5` from the artifact in the exact terminal `MQL5\Experts` location. Verify the installed artifact rather than assuming MetaEditor updated the terminal copy.
