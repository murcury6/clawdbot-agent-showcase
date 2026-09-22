# ClawdBot — Portable Agent Prototype

An early Windows agent system by **Jordyn Wood**, built around **OpenClaw**: a portable control center, Telegram-driven work queue, local/cloud model routing, and recovery loops that try to keep unfinished work moving.

This repository preserves the recovered custom source **as it was**, including its rough edges. It demonstrates agent integration and operational engineering, not a newly trained model or a replacement for OpenClaw.

## Start reading here

| Component | Source | What it demonstrates |
| --- | --- | --- |
| Work controller | [telegram-work-controller.ps1](clawdbot/scripts/telegram-work-controller.ps1) | Queue selection, assignment repair, pause/resume detection, stalled-work monitoring and cooldowns |
| Model routing | [select-model.ps1](clawdbot/scripts/select-model.ps1) | Memory-aware local tiers, provider probes, routing modes and fallback chains |
| Continuity watchdog | [agent-continuity-watchdog.ps1](clawdbot/scripts/agent-continuity-watchdog.ps1) | Transcript inspection and recovery hooks for apparently unfinished work |
| Service lifecycle | [start-stack.ps1](clawdbot/scripts/start-stack.ps1), [stop-stack.ps1](clawdbot/scripts/stop-stack.ps1) | Process discovery, readiness checks, portable paths and restart handling |
| Credential plumbing | [portable-secrets.ps1](clawdbot/scripts/portable-secrets.ps1), [sync-portable-keys.ps1](clawdbot/scripts/sync-portable-keys.ps1) | Per-user Windows DPAPI storage and process-scoped environment references |
| Windows interface | [clawdbot-control-center.ps1](clawdbot/scripts/clawdbot-control-center.ps1) | A desktop control panel over the portable launchers |

## What is preserved

All 31 scripts, seven recovered root launchers, and the historical [README](clawdbot/README.txt) are preserved byte-for-byte. No embedded credential values were found in those selected files during publication review. The original private recovery archive was not modified.

The new repository wrapper consists of this README, safety/provenance notes, an ignore file, a hash manifest and non-runtime validation. The original implementation has not been refactored or modernized.

## What is deliberately absent

No API keys, OAuth tokens, credential stores, actual model files, tensors, weights, training data, conversation logs, personal memory, private agent instructions, user workspace artifacts, or live configuration are included. References to provider/model names remain in the code; those are identifiers, not model files.

The bundled OpenClaw application, Node runtime, Ollama binaries and downloaded dependencies are also omitted. The recovered OpenClaw package identified itself as `2026.3.13-beta.1` with an MIT license. OpenClaw is an independent upstream project: [openclaw/openclaw](https://github.com/openclaw/openclaw). This repository claims the custom integration layer, not authorship of upstream software or models.

## Status and safety

**Historical source snapshot, not a ready-to-run or production-hardened distribution.** The launchers depend on intentionally omitted runtime/configuration files. Do not point them at an existing personal environment just to try the project.

- Startup can install a scheduled task and Startup entry. Stop/reset scripts terminate processes or delete runtime data. Desktop controls can act on the active Windows desktop.
- The original Telegram unlock flow can skip verification when delivery configuration is absent/disabled and supports an environment-variable bypass. It is not a security boundary.
- DPAPI is tied to the Windows user; this implementation also incorporates the installation path as entropy. Moving the folder or changing users can make stored values unreadable. It does not protect against code running as that user.
- Continuity heuristics can mistake idle or completed work for unfinished work. Multiple nudgers, permissive tool access, API costs, and untrusted messages require stronger isolation and explicit authorization before real deployment.
- Historical README statements are not all synchronized with the implementation: it describes a five-minute watchdog while the installer uses one minute, and mentions a Telegram model different from the selector's current constant. The source is retained unchanged.

See [PUBLICATION.md](PUBLICATION.md) for the exact publication boundary and validation scope.

## Safe validation

With PowerShell 7, from this repository:

```powershell
pwsh -NoProfile -File tools/verify-release.ps1
pwsh -NoProfile -File tools/test-source.ps1
```

These checks verify the release allowlist/hashes, scan common credential patterns, parse the PowerShell source, and exercise selected pure functions using synthetic inputs. They do **not** start the bot, contact providers, load models, decrypt credentials, install tasks, control the desktop, or run the reset scripts. Passing checks are not an end-to-end runtime or security certification.

The custom source is published for inspection with no additional open-source license granted. Upstream dependencies retain their own licenses.
