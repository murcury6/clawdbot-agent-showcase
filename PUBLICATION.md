# Publication boundary

Prepared on 2026-09-22 from the recovered March 2026 portable ClawdBot project.

## Original files

- `clawdbot/scripts/`: all 31 recovered custom scripts.
- Root: seven launchers restored under their original names.
- `clawdbot/README.txt`: historical documentation, not current setup instructions.

These 39 files retain the original bytes. The original README's statement that everything needed to run is bundled applies to the private historical installation, **not** this public source snapshot.

## Excluded from the initial commit and every upload

`clawdkeys`, `state`, `workspace`, `EDIT_AI_HERE`, `logs`, `run`, `offline`, bundled `node` and `openclaw`, debug output, databases, sessions, models and archives. Nothing from those directories is needed to understand the published control scripts. No encrypted credential store is considered safe for public release merely because it is encrypted.

Only explicit reviewed files are copied into a fresh repository; the private project's Git history is not imported. A deny-by-default `.gitignore` supplements, but does not replace, the SHA-256 release allowlist. The manifest itself is excluded from its own hash list.

## Validation scope

The release guard rejects unexpected files, hash mismatches, binary/model payloads, and common token/private-key patterns. Automated scanning cannot prove the absence of every possible secret format; this release also limits content to source and newly authored documentation, excluding all runtime state and key files.

The source tests parse every PowerShell file without running its top-level statements. Only explicitly named, side-effect-free function definitions are extracted for synthetic unit checks. The batch launchers are inspected as source, not executed. Runtime integration, provider compatibility, model quality, desktop behavior and real credential storage are not exercised.

This release preserves prototype behavior. Potential improvements such as fail-closed unlocks, isolated execution, stricter task-completion state, redacted logs, synchronized watchdog ownership, and reproducible dependency setup are observations, not features added to the historical code.
