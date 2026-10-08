# Verified releases, updates and rollback

Stable releases use explicit tags, starting at `v1.0.0`; this source prepares package `v1.2.0`. Local preparation and verified offline installation do not publish a GitHub release. The ZIP contains exactly the skill files and a release manifest with the tag, version, reviewed source commit, lengths and SHA-256 of every file. The repository-level packager verifies its own output. Release CI validates both shells and the MCP pair before retaining packages; any later publication must use a successful commit's assets.

Run the trusted installed `scripts/Update-Mql5Skill.ps1` from a directory outside the installed skill. For the first upgrade from an older installation, run the script from a reviewed checkout of this repository. In particular, the 1.0.2 verifier rejects the new `assets/` package location; the reviewed 1.1.0 verifier accepts that bounded location and retains the same manifest, hash, backup, and rollback checks. Do not run an updater from an unverified download. The updater requires Windows PowerShell 5.1 or PowerShell 7; online actions also require authenticated `gh` access to the private repository. Offline updates need neither GitHub access, Python, nor MetaTrader.

```powershell
$codexDirectory = if ([string]::IsNullOrWhiteSpace($env:CODEX_HOME)) {
    Join-Path $env:USERPROFILE '.codex'
} else { $env:CODEX_HOME }
$updater = Join-Path $codexDirectory 'skills/mql5-coding/scripts/Update-Mql5Skill.ps1'
& $updater -Action Check -Version '<published-version>'
& $updater -Action Update -Version '<published-version>'
```

`Check` reads authenticated release metadata and installed version, without downloading or modifying files. Its `installed_bytes_verified=false` explicitly distinguishes version inspection from byte verification. `Update` downloads the named stable release, verifies its length and GitHub asset SHA-256, resolves the tag's source commit, and checks the complete manifest and every skill file before replacing anything. Drafts, prereleases, missing digests, unlisted files, duplicate paths, links, traversal entries, oversized archives, and mismatched identities are rejected. No downloaded code is executed by the verifier. An already installed identical version is verified and returned as `already_current`; changed bytes at that version fail.

Release manifests, version records, backup records, and pending recovery records require a JSON object at their root. An array around an otherwise valid record is rejected before PowerShell can unwrap it. Manifest repository, tag, version, and source-commit fields require strings; arrays containing an expected string are rejected. Version records require exactly an integer `schema_version` of 1 and a stable version string. Packaging, `Check`, `Update`, and environment health use the same version rules. The manifest's `files` field remains an array inside that object. The shared reader rejects escaped unpaired UTF-16 surrogate units in every JSON key or string value before deserialization, in both file and captured-buffer mode. Valid Unicode and literal escaped backslashes retain their values across the existing UTF-8 and BOM-based decoding paths. BOM-selected encodings use strict decoding on the captured input bytes, so malformed UTF-16 units cannot be replaced silently. File input is read through one bounded open stream.

Rollback requires a typed backup record with the selected backup ID, exact destination, boolean installation state, and valid file inventory. Before changing installed files or clearing markers, it validates every pending recovery record's action, destination, allowed fields, and any parent backup ID. Invalid records fail while preserving the installation and retained evidence; they must be inspected before retrying recovery.

Absolute drive roots retain their trailing separator through path validation and file inventory. Selecting `X:\` must not become the drive-relative `X:` or follow a current subfolder. Inventories keep correct paths relative to that root, and packaging still refuses an output directory inside the selected skill tree.

Updates preserve the whole previous skill directory, including custom files, under `CODEX_HOME/tools/mql5-skill-updates/<backup_id>/backup-tree`. The result gives that ID. A lock excludes concurrent updater operations. The updater verifies a complete snapshot before changing anything, keeps the installed root directory in place, and stages on the same volume. It journals replacement of the root's children so an open Codex directory watcher does not block an update. Caught publication failures restore displaced children. It retains a pending transaction marker across a process or machine interruption and refuses another update until rollback resolves it. This is recoverable replacement, not a crash-atomic switch of all files. Close programs that lock individual child directories/files if a rename fails, or the root when rolling back a fresh installation to absence.

```powershell
& $updater -Action Rollback -BackupId '<32-character-ID-returned-by-update>'
```

Rollback verifies the retained snapshot before restoring it and preserves the displaced installation in a new backup. Rolling back a fresh installation restores the previous absence of the skill. It does not download anything. Backup records and hashes are local integrity evidence, not cryptographic signatures; an actor able to change both can change the evidence. Keep retained backups until they are no longer needed. Project profiles, Python, MCP registration, terminals and broker settings are outside the skill tree and are not changed. Fully restart Codex after a changed installation so new chats load the new instructions.

If rollback is interrupted again, recovery follows the pending intents back to the original snapshot. After verifying the restored files, it clears all related pending markers, removing descendants before their ancestors. A cleanup failure retains the unresolved intent's recovery chain so a later rollback still selects the original snapshot.

For an offline update, supply all trust inputs explicitly:

```powershell
& $updater -Action Update -Version 1.2.0 -ArchivePath '<absolute-zip-path>' `
    -ExpectedArchiveSha256 '<trusted-64-hex-digest>' -ExpectedSourceCommit '<trusted-40-hex-commit>'
```

Obtain these values from authenticated release metadata or a separately reviewed successful build. An accompanying ZIP sidecar alone does not establish trust. GitHub's asset digest establishes the downloaded bytes relative to the authenticated repository, not independent publisher signing. Update does not downgrade; use a retained rollback snapshot for that. Existing unversioned installations are backed up before their first versioned update.
