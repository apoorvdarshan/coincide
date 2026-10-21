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
- `CoincideMarkdown`: Swift Markdown/cmark parsing, bounded off-main rendering
  models, native SwiftUI blocks, lexical code coloring, and contained file links.
  SwiftMath/CoreText renders closed display formulas without a webview. Font
  resources ship inside the app and have a separate runtime-loading CI check.
- Codex and Claude run as installed CLI processes over stdio. Coincide uses existing
  provider authentication; no API key is embedded or copied into the workspace.
- Each local thread has its own provider connection, workspace path, permission
  selection, and persisted conversation. Persistence commits versioned entity and
  message mutations, the cached projection, a command receipt, and an audit marker
  together. Legacy snapshots are imported once and projections can be rebuilt.
  A single native engine serializes typed commands and decisions, then runs provider
  I/O separately through the leased, fenced outbox. The desktop observes committed
  state rather than writing whole snapshots. Rejected commands also retain their
  idempotency receipts. Runtime ownership is exclusive per database, and provider
  events are scoped to a connection and run so stale replies cannot reopen a turn.
- Queued turns capture their model, permission, and workspace configuration. Normal
  completion advances the queue; Stop, provider failure, and application restart
  hold it for explicit resumption. Database storage version 3 protects these fields
  from older binaries. No exactly-once provider execution is claimed.
- Attachment bytes live in private, immutable app-owned files. Drafts, queued
  turns, messages, and outbox entries retain typed references. Images are normalized
  with ImageIO as needed and delivered through each provider's native image input;
  other files are included as escaped local-path context. Integrity checks precede
  provider execution. Imported originals are never modified.
- Default permission mode is supervised. Full access is available as an explicit
  per-thread choice. Unsupported interactive provider requests fail explicitly.

## Current implementation and evidence requirements

| Area | Implemented now | Remaining work for parity |
| --- | --- | --- |
| Native workspace | Projects, new threads, search, rename, pin, archive, settings | Groups, sorting/reorder, snooze/settle, undo, scratch projects, import/migration |
| Codex | Handshake, model discovery, start/resume, streaming, command/file approvals, user questions, interrupt | Full protocol coverage, auth/setup UI, multi-account/usage, reasoning settings, rollback/fork, all tool events |
| Claude | Native bidirectional stream-json connection, model discovery, streaming, session resume, tool approvals, user questions, interrupt | Full control protocol, multi-select question UI, auth/setup, usage, hooks/configuration, rollback/fork, complete tool metadata |
| Other providers | Not implemented | Cursor, Grok, OpenCode, Antigravity, Pi, Muse, ACP registry and custom providers |
| Durable orchestration | Serial native command engine and effect worker, replayable SQLite journal, atomic projections/receipts/audit/outbox, durable accepted/rejected command deduplication, revision checks, effect leases/fencing, exclusive runtime ownership, scoped provider events, held queues after process loss, legacy migration | Complete provider recovery, checkpoints/finalization and run history, incremental projection storage/performance, full upstream command coverage |
| Composer/transcript | ChatGPT-style native conversation, persistent per-thread drafts, queued turns with edit/remove/resume, separate Stop, Markdown headings/lists/tasks/quotes/tables/code, lexical syntax coloring and code copy, closed display/math-fence formulas, contained file links with line navigation, tool/reasoning disclosure, focused Enter/Shift-Enter input | Inline and broader math parsing, transcript media, citations, diagrams/details/alerts, complete language highlighting, slash/skill/file pickers, plans, steering |
| Attachments | Native picker, file/image paste/drop import, persistent drafts/queues/history, thumbnail and image previews, copy/save/open controls, HEIC/TIFF conversion and image resizing, count/size/integrity checks, native Codex/Claude image input and file context | Remote uploads, question attachments, long-paste conversion, prompt stash, failed-import retry UI, reference-aware cleanup, source images over 50 MiB, broader media previews |
| Git/workspaces | Status, staged/unstaged diff, stage/unstage, commit, branches, worktree creation | Checkout/clone, pull/push, PRs/stacks/multiple hosts, checkpoints/revert, worktree lifecycle/setup |
| Files | Browse/read/edit UTF-8 with conflict detection and workspace path checks | Search/ignore support, large/binary files, filesystem watching, editor integration |
| Terminal | Native SwiftTerm emulator and local PTYs, per-window/thread tabs, resize/input, 5,000-line scrollback, hide/show persistence, interrupt and process cleanup | Durable restart restoration, remote attachment/replay, search/settings, activity/idle detection, broader terminal compatibility and accessibility |
| Remote environments | Not implemented | Authenticated transport, pairing, capabilities, reconnect, SSH/relay/LAN, multi-environment ownership |
| Desktop integration | App bundle, commands/shortcuts, appearance | Notifications, deep links, updates, browser/preview, screenshot/import features, power/resources, accessibility QA |
| Distribution | Local development-identity or ad-hoc signed bundle | Release signing/notarization, installer/update validation, full notices |
| Validation | Deterministic core/protocol/orchestration tests, CI workflow, native Codex/Claude turn and queue smoke checks | Upstream replay corpus, broader live tool/approval coverage, UI automation, full parity and failure audit |

## Validation commands

```sh
swift test
./script/build_and_run.sh --build-only
./script/build_and_run.sh --verify
COINCIDE_LIVE_CODEX=1 swift test --filter installedCodexHandshakeAndModelDiscovery
COINCIDE_LIVE_CLAUDE=1 swift test --filter installedClaudeHandshakeAndModelDiscovery
COINCIDE_LIVE_ATTACHMENTS=1 swift test --filter installedProvidersReadAnImageAndFileThroughTheNativeEngine
```

The live discovery test performs a handshake and model listing only. It does not
run a model turn. The separate attachment test incurs real provider usage, sends
only generated image/file markers, and checks both installed providers through
the native engine. It permits only the generated file's Claude Read approval.
The deterministic provider fixture contacts no external service
and does not exercise real provider authentication or prove full provider parity.
Tests create temporary isolated Git repositories and remove them after use.

## Upstream attribution

T3 Code is copyright © 2026 T3 Tools Inc., MIT licensed. Its license is preserved
in `T3-CODE-LICENSE.txt`. Coincide is independent of T3 Tools Inc.
