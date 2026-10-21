# Coincide native Swift port

The goal is a complete native Swift macOS port of T3 Code, including its core
services. A running T3 Code/Node server or Electron frontend is not the intended
final architecture. This goal is **not complete**.

The reference is [pingdotgg/t3code at 680152e27b2a961686389ca69a1557cbb2c55f08](https://github.com/pingdotgg/t3code/tree/680152e27b2a961686389ca69a1557cbb2c55f08).
`upstream-inventory.json` records its 185 named RPC methods and 38 user guides.
Those entries are an inventory, not a claim that Coincide implements the server
wire protocol. Applicable desktop behavior, core services, and remote support
must each be mapped and verified before declaring parity.

## Architecture

- `CoincideCore`: Swift value models, SQLite workspace persistence, subprocess
  ownership, JSON-RPC transport, provider adapters, Git, and file services.
- `Coincide`: SwiftUI scenes with native macOS controls; AppKit for application
  lifecycle, file selection, reveal-in-Finder, and clipboard integration.
- Codex and Claude run as installed CLI processes over stdio. Coincide uses existing
  provider authentication; no API key is embedded or copied into the workspace.
- Each local thread has its own provider connection, workspace path, permission
  selection, and persisted conversation. Persistence commits the snapshot and
  audit marker together. This is not yet equivalent to upstream's event-sourced
  orchestration, command receipts, and transactional effect outbox.
- Default permission mode is supervised. Full access is available as an explicit
  per-thread choice. Unsupported interactive provider requests fail explicitly.

## Current implementation and evidence requirements

| Area | Implemented now | Remaining work for parity |
| --- | --- | --- |
| Native workspace | Projects, new threads, search, rename, pin, archive, settings | Groups, sorting/reorder, snooze/settle, undo, scratch projects, import/migration |
| Codex | Handshake, model discovery, start/resume, streaming, command/file approvals, user questions, interrupt | Full protocol coverage, auth/setup UI, multi-account/usage, reasoning settings, rollback/fork, all tool events |
| Claude | Native bidirectional stream-json connection, model discovery, streaming, session resume, tool approvals, user questions, interrupt | Full control protocol, multi-select question UI, auth/setup, usage, hooks/configuration, rollback/fork, complete tool metadata |
| Other providers | Not implemented | Cursor, Grok, OpenCode, Antigravity, Pi, Muse, ACP registry and custom providers |
| Durable orchestration | SQLite snapshots and audit markers; interrupted-run recovery | Durable event decisions/outbox, queued turns, retry/idempotency, checkpoints/finalization, provider recovery |
| Composer/transcript | ChatGPT-style native conversation, persistent per-thread drafts, inline Markdown, tool/reasoning disclosure, copy, Enter/Shift-Enter | Full Markdown/code/math, citations, attachments, slash/skill/file pickers, plans, steering |
| Git/workspaces | Status, staged/unstaged diff, stage/unstage, commit, branches, worktree creation | Checkout/clone, pull/push, PRs/stacks/multiple hosts, checkpoints/revert, worktree lifecycle/setup |
| Files | Browse/read/edit UTF-8 with conflict detection and workspace path checks | Search/ignore support, large/binary files, filesystem watching, editor integration |
| Terminal | Native SwiftTerm emulator and local PTYs, per-window/thread tabs, resize/input, 5,000-line scrollback, hide/show persistence, interrupt and process cleanup | Durable restart restoration, remote attachment/replay, search/settings, activity/idle detection, broader terminal compatibility and accessibility |
| Remote environments | Not implemented | Authenticated transport, pairing, capabilities, reconnect, SSH/relay/LAN, multi-environment ownership |
| Desktop integration | App bundle, commands/shortcuts, appearance | Notifications, deep links, updates, browser/preview, screenshot/import features, power/resources, accessibility QA |
| Distribution | Local ad-hoc signed development bundle | Release signing/notarization, installer/update validation, full notices |
| Validation | Deterministic core/protocol tests and CI workflow | Upstream replay corpus, real provider turn tests, UI automation, full parity and failure audit |

## Validation commands

```sh
swift test
./script/build_and_run.sh --build-only
./script/build_and_run.sh --verify
COINCIDE_LIVE_CODEX=1 swift test --filter installedCodexHandshakeAndModelDiscovery
COINCIDE_LIVE_CLAUDE=1 swift test --filter installedClaudeHandshakeAndModelDiscovery
```

The live discovery test performs a handshake and model listing only. It does not
run a model turn. The deterministic provider fixture contacts no external service
and does not exercise real provider authentication or prove full provider parity.
Tests create temporary isolated Git repositories and remove them after use.

## Upstream attribution

T3 Code is copyright © 2026 T3 Tools Inc., MIT licensed. Its license is preserved
in `T3-CODE-LICENSE.txt`. Coincide is independent of T3 Tools Inc.
