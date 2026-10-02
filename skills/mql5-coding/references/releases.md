# Verified releases, updates and rollback

Stable releases use explicit tags, starting at `v1.0.0`. The ZIP contains exactly the skill files and a release manifest with the tag, version, source commit, lengths and SHA-256 of every file. The repository-level packager verifies its own output. Release CI validates both shells and the MCP pair before retaining packages; publication must use the successful commit's assets.

Run the trusted installed `scripts/Update-Mql5Skill.ps1` from a directory outside the installed skill. For the first upgrade from an older installation, run the script from a reviewed checkout of this repository. Do not run an updater from an unverified download. The updater requires Windows PowerShell 5.1 or PowerShell 7 and authenticated `gh` access to the private repository. It needs neither Python nor MetaTrader.

```powershell
$codexDirectory = if ([string]::IsNullOrWhiteSpace($env:CODEX_HOME)) {
    Join-Path $env:USERPROFILE '.codex'
} else { $env:CODEX_HOME }
$updater = Join-Path $codexDirectory 'skills/mql5-coding/scripts/Update-Mql5Skill.ps1'
& $updater -Action Check -Version 1.0.0
& $updater -Action Update -Version 1.0.0
```

`Check` reads authenticated release metadata and installed version, without downloading or modifying files. Its `installed_bytes_verified=false` explicitly distinguishes version inspection from byte verification. `Update` downloads the named stable release, verifies its length and GitHub asset SHA-256, resolves the tag's source commit, and checks the complete manifest and every skill file before replacing anything. Drafts, prereleases, missing digests, unlisted files, duplicate paths, links, traversal entries, oversized archives, and mismatched identities are rejected. No downloaded code is executed by the verifier. An already installed identical version is verified and returned as `already_current`; changed bytes at that version fail.

Updates preserve the whole previous skill directory, including custom files, under `CODEX_HOME/tools/mql5-skill-updates/<backup_id>/backup-tree`. The result gives that ID. A lock excludes concurrent updater operations. The updater stages on the same volume and publishes with directory renames; caught publication failures restore the previous tree. It retains a pending transaction marker across a process or machine interruption and refuses another update until rollback resolves it. This is recoverable replacement, not a claim that two Windows directory renames are crash-atomic. Close programs that lock the skill directory if a rename fails.

```powershell
& $updater -Action Rollback -BackupId '<32-character-ID-returned-by-update>'
```

Rollback verifies the retained snapshot before restoring it and preserves the displaced installation in a new backup. Rolling back a fresh installation restores the previous absence of the skill. It does not download anything. Backup records and hashes are local integrity evidence, not cryptographic signatures; an actor able to change both can change the evidence. Keep retained backups until they are no longer needed. Project profiles, Python, MCP registration, terminals and broker settings are outside the skill tree and are not changed. Fully restart Codex after a changed installation so new chats load the new instructions.

For an offline update, supply all trust inputs explicitly:

```powershell
& $updater -Action Update -Version 1.0.0 -ArchivePath '<absolute-zip-path>' `
    -ExpectedArchiveSha256 '<trusted-64-hex-digest>' -ExpectedSourceCommit '<trusted-40-hex-commit>'
```

Obtain these values from authenticated release metadata or a separately reviewed successful build. An accompanying ZIP sidecar alone does not establish trust. GitHub's asset digest establishes the downloaded bytes relative to the authenticated repository, not independent publisher signing. Update does not downgrade; use a retained rollback snapshot for that. Existing unversioned installations are backed up before their first versioned update.
