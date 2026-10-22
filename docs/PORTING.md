# Coincide native Swift port

The goal is a complete native Swift macOS port of T3 Code, including its core
services. A running T3 Code/Node server or Electron frontend is not the intended
final architecture. This goal is **not complete**.

The reference is [pingdotgg/t3code at 680152e27b2a961686389ca69a1557cbb2c55f08](https://github.com/pingdotgg/t3code/tree/680152e27b2a961686389ca69a1557cbb2c55f08).
`upstream-inventory.json` records 198 registered RPC methods (182 from `WS_METHODS`
and 16 from `ORCHESTRATION_V2_WS_METHODS`), three separate legacy constant-only
names, and 38 user guides. The active method set matches the `Rpc.make`
declarations and `WsRpcGroup` in `packages/contracts/src/rpc.ts`, plus the server
handler table in `apps/server/src/ws.ts` at that revision. The legacy names have
no registered handlers and do not count as pending RPC implementation targets.
These entries are an inventory, not a claim that Coincide implements the server
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
- Custom installed ACP agents use a native JSON-RPC 2.0 adapter. Saved named
  invocations pass literal arguments and are captured in each conversation/queue.
  Config options take precedence over legacy model/mode fields. Permissions keep
  agent-provided option IDs, and resumed history is drained without duplicating
  the journal transcript. Unsupported capabilities are not advertised. ACP agents
  enforce their own sandbox; Codex permission settings do not apply to them.
- Transcript entities retain their session, type, opaque ID, structured fields,
  and chunk annotations. The native reducer applies replacements, null clearing,
  metadata patches, independently decoded terminal bytes, and typed user-message
  association. ACP v1 tools already use this durable path, including updates after
  foreground completion. An opt-in ACP v2 adapter negotiates the current draft or
  adopts v1 on the same transport. It separates prompt insertion from foreground
  completion, handles agent-initiated work without fake user input, and lets
  session-level permissions remain pending while the foreground is idle.
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
  hold it for explicit resumption. Database storage version 14 protects these fields
  from older binaries. No exactly-once provider execution is claimed.
- Each newly started run retains its captured settings, user-message reference
  or explicit agent/legacy origin, observed adapter turn references, stop intent,
  and terminal outcome in the journal. Queue advancement closes one record before
  opening the next; stale scoped events cannot rewrite completed history. Restart
  marks an unfinished run interrupted without replay. Earlier transcript rows are
  not backfilled with guessed turn boundaries. A read-only native Run History
  sheet exposes these records. Adapter references may be locally generated and
  do not by themselves establish native provider fork or rollback support.
- A standalone native checkpoint service prepares immutable local plans, captures
  Git working bytes into private refs, inspects owned completion receipts and
  returns bounded snapshot diffs. Captures use a separate index and a frozen
  private Git configuration; HEAD, branches, the real index and checkout files
  remain unchanged. Ordinary and cone sparse/full indexes, staged-but-edited
  files, ignored tracked additions, symlinks and executable modes have regression
  coverage. Configuration and filesystem ownership are rechecked, failed attempts
  are preserved, and missing local objects never trigger a lazy fetch. This
  primitive is not yet wired to automatic run capture or filesystem restore.
  Executable clean/process filters and non-cone sparse checkouts are currently
  unsupported; modern Git with `--no-lazy-fetch` is required.
- Background clones are project-owned outbox actions. The project and conversation
  appear as soon as their intent is saved; submitted messages retain their captured
  configuration and attachments while waiting for a checkout. A completed clone
  releases eligible queues; Cancel and restart hold them for explicit resumption.
  Git runs in an owned process group and a private staging folder. Publication is
  exclusive, and retry checks local completion evidence before creating another
  attempt. Coincide preserves previous staging folders; Git itself may remove
  files when a clone fails. Partial network transfers are not resumed.
- Worktree preparation persists an intent and final target path before resolving
  local Git references, then journals the immutable plan before mutation. Each
  attempt captures source/common/admin ownership and a pinned commit. Queued input
  retains its provider configuration and waits for readiness. New/existing branch
  setup and explicit registered reuse preserve source edits and untracked files.
  Cancellation, failure, and restart hold queues; conservative completion evidence
  permits recovery without restarting Git over an old folder. New attempts retain
  previous files, branches, and ownership records. No automatic deletion, branch
  reset, pruning, fetch, or remote setup is part of this flow.
- Managed New Project creates a distinct folder under the app's `Projects` data
  directory, initializes Git, and generates a starter README/icon. It respects
  the user's Git branch, identity, hooks, and signing settings. Initial-commit
  failure is a warning with a usable repository. The prepared project and its
  first conversation register atomically; interrupted setup preserves its folder.
- Sidebar organization persists through the same journal. Canonical project order
  is retained for Manual mode, while activity/creation order is derived from
  nonarchived conversations. Accepted queued input counts as user activity;
  assistant output cannot outrank existing user input. Collapsed projects retain
  their selected eligible conversation, and display renames preserve checkout
  paths. New projects have creation/activity dates; legacy unknown dates remain
  unset rather than being assigned synthetic migration timestamps.
- A native, read-only repository identity resolver enriches registered projects
  for logical checkout grouping. It handles nested folders, detached worktrees,
  explicit bare repositories, upstream/origin fork identity, and supported URL
  aliases. Credentials, queries, and fragments are removed before returning
  metadata. Owned refreshes run after load, registration, and clone readiness;
  removal/path/incarnation fences discard late results. Failures preserve the
  previous identity and do not stop agents. Unchanged metadata adds no journal
  event or outbox action.
- Logical groups derive from physical project records. Repository, repository
  and folder, separate-checkout modes, and physical-path overrides persist in
  sidebar preferences. Groups aggregate activity and conversations while retaining
  every project/thread identity. Atomic membership checks protect collapse,
  checkout selection, and manual moves; moves preserve untouched interleaving.
  Future-conversation checkout selection never retargets existing conversations.
  Rename/removal menus support one physical checkout or an atomic whole-group
  action. Whole-group confirmation captures every registration/path and active
  and archived conversation; stale membership is rejected. The last selected
  conversation restores its owner and archived view on restart. Storage version
  10 protects these durable preferences and identity fields from older binaries.
- Project removal commits all active/archived thread removals, project removal,
  collapsed-preference cleanup, and pending-action cancellation together. Running
  actions retain their leases until their owned executors settle; detached
  provider/model/clone cleanup is tracked outside the command inbox. Every native
  window registers its terminal owner for targeted cleanup. Composer/import/model
  state and unreferenced inspectors are reconciled, shared paths remain usable,
  and editor scopes freeze during removal after explicit unsaved-edit confirmation.
  Queued worktree assignments extend those locks before removal commits. Removal
  waits for affected cleanup owners without waiting for unrelated projects.
  New conversations or dirty editors require renewed confirmation. Coincide does
  not delete checkout, worktree, staging, or attachment files; Git may clean up its
  own unfinished files when an active clone is stopped. Append-only recovery
  history remains, so removal is explicitly described as workspace removal rather
  than secure erasure. Removal uses the existing journal event types.
- Attachment bytes live in private, immutable app-owned files. Drafts, queued
  turns, messages, and outbox entries retain typed references. Images are normalized
  with ImageIO as needed and delivered through each provider's native image input;
  other files are included as escaped local-path context. Integrity checks precede
  provider execution. Imported originals are never modified.
- Local file sessions are shared by canonical workspace root. Detached native
  filesystem work lists dotfiles/empty/ignored entries, searches paths with Git
  ignore rules, inventories ignored files, and reads bounded UTF-8 previews.
  Anchored directory descriptors reject escapes, special files, replaced roots,
  and Git-metadata writes. Exclusive creation does not overwrite existing files;
  revision-checked saves preserve deterministic external changes but do not claim
  atomic compare-and-save against concurrent external writers. Native FSEvents
  coalesces advisory invalidations; clean editors refresh and dirty buffers remain
  intact. Cached editors survive inspector/workspace switches; normal Quit asks
  before discarding unsaved edits. Last-owner removal and shutdown drain sessions.
  The composer can insert escaped relative file/folder links into a captured
  conversation without attaching bytes. No upstream filesystem-watch RPC is
  claimed; watching is a native implementation capability.
- Native content search preserves whitespace and UTF-16 source ranges, with
  literal/regex, case, and Unicode whole-word controls. The inspector groups
  highlighted lines by path and opens the selected match in the native editor.
  Matching is cooperative and bounded; partial results and native regex errors
  are explicit. The native ICU regex dialect is not claimed to reproduce fff
  fallback results or ranking. Searches retain dirty buffers and conversation
  state and never replace file contents.
- Explicit external-editor actions use a native catalog, inspected application
  bundles and their contained launchers, a local preferred-editor setting, and
  Launch Services or literal argument vectors. PATH wrappers are not executed.
  Existing regular files and directories are checked through the anchored file
  service, including binary files; ownership is rechecked before handoff. Pending
  validation cancels and drains on shutdown, while accepted external apps own
  their lifetime. Saved bytes open externally without saving or discarding native
  buffers. Native result actions pass a line only; cross-editor Unicode column
  conventions and remote editor targets remain unverified. Xcode is a native
  addition to the pinned T3 editor catalog.
- Default permission mode is supervised. Full access is available as an explicit
  per-thread choice. Unsupported interactive provider requests fail explicitly.
- Native project-script discovery reads the current checkout's anchored `t3.json`
  (up to 256 KiB), including comments/trailing commas and the pinned declaration
  schema. Discovery never executes scripts. A native sheet displays the chosen
  command and checkout; explicit Run rechecks its file revision, conversation,
  window and anchored root before creating a dedicated PTY. The user's login
  shell receives the command as one argument and the T3 project/worktree variables.
  Tabs retain output and exit status, and running scripts use close confirmation
  even when the shell execs its command into its own process group. Imported
  preview fields do not yet trigger their own workflows. Parsed
  icon/environment/submodule fields do not yet override native project settings.
- A separately signed native managed-script helper provides app-owned checkout
  setup execution. It separates actual command exit from background-job
  lifetime, retains ownership independently of windows, and uses bounded private
  control/status/raw-output pipes. A captured plan pins the command, configuration,
  checkout, project root and shell; preparation does not execute the command.
  Worktree requests capture a review gate before Git starts. After checkout
  readiness, anchored discovery selects the first run-on-create script and stores
  its exact plan for explicit native review. Missing roles skip setup; malformed
  or changed configuration holds provider work for a visible decision. Files and
  Terminal use checkout readiness independently. Blocking setup releases providers
  only on actual exit 0; asynchronous setup releases them after a durable startup
  acknowledgment. One Core output consumer feeds bounded complete snapshots to
  every window. Stop, Continue Without Setup and Retry drain the owned group;
  Retry captures a new plan and requires review. Interrupted jobs are never
  replayed after process loss. The existing manual script path stays separate.
- Explicit Settle/Resume persists a settlement generation independently of provider
  idle. Settle rejects running work, queued messages, unresolved setup and pending
  questions. It drains retained setup jobs before discovering the first settle
  role in a proven separate linked checkout. Main/shared checkouts and unproven
  legacy ownership skip the role. Each generation requires explicit command
  review; script exit does not resume the conversation. Resume or a new user
  submission drains owned cleanup jobs before clearing the generation and
  starting captured queued input. Retry, removal, archive and restart use the
  same script-owner fences. Existing manual terminal tabs remain separate;
  automatic settlement and idle-terminal closure are not implemented.

## Current implementation and evidence requirements

| Area | Implemented now | Remaining work for parity |
| --- | --- | --- |
| Native workspace | Open/clone folders, managed New Project and starter repository, atomic project/first-conversation registration, logical repository/folder/physical grouping and overrides, explicit checkout choice for new conversations, restored conversation selection, physical/group renaming and collapse, persistent manual ordering and aggregated activity/thread-creation sorting, confirmed atomic physical/group removal with archived conversations and targeted runtime cleanup, thread search/rename/pin/archive, explicit settlement generations and Resume, settings | Snooze/automatic settlement, undo, scratch projects, import/migration |
| Codex | Handshake, model discovery, start/resume, streaming, command/file approvals, user questions, interrupt | Full protocol coverage, auth/setup UI, multi-account/usage, reasoning settings, rollback/fork, all tool events |
| Claude | Native bidirectional stream-json connection, model discovery, streaming, session resume, tool approvals, user questions, interrupt | Full control protocol, multi-select question UI, auth/setup, usage, hooks/configuration, rollback/fork, complete tool metadata |
| Other providers | Custom installed ACP v1 agents, opt-in current ACP v2 draft with same-connection v1 fallback, OpenCode preset, native model/config discovery and select/boolean controls, session load/resume, streaming/thoughts, structured tool/plan output, tool input/output/files/details, after-idle tool updates and permissions, agent-initiated foreground work, exact permission choices, interrupt, queued/resumed conversation integration, visible rejected/unconfirmed submissions | Registry/managed installation, native authentication/elicitation, delegated filesystem/terminal methods, richer media and display-terminal UI, live notices, session listing/import/fork, older v2 draft variants, provider-specific OpenCode/Cursor/Grok/Antigravity/Pi/Muse behavior |
| Durable orchestration | Serial native command engine and effect worker, replayable SQLite journal, atomic projections/receipts/audit/outbox, durable accepted/rejected command deduplication, revision checks, effect leases/fencing, exclusive runtime ownership, scoped provider events, held queues after process loss, durable run settings/references/outcomes with read-only native history, legacy migration | Complete provider recovery, checkpoints/finalization, provider fork/rewind, incremental projection storage/performance, full upstream command coverage |
| Composer/transcript | ChatGPT-style native conversation, persistent per-thread drafts, queued turns with edit/remove/resume, separate Stop, Markdown headings/lists/tasks/quotes/tables/code, lexical syntax coloring and code copy, closed display/math-fence formulas, contained file links with line navigation, native workspace path-reference picker, tool/reasoning disclosure, focused Enter/Shift-Enter input | Inline and broader math parsing, transcript media, citations, diagrams/details/alerts, complete language highlighting, slash/skill and inline-trigger pickers, plans, steering |
| Attachments | Native picker, file/image paste/drop import, persistent drafts/queues/history, thumbnail and image previews, copy/save/open controls, HEIC/TIFF conversion and image resizing, count/size/integrity checks, native Codex/Claude image input and file context | Remote uploads, question attachments, long-paste conversion, prompt stash, failed-import retry UI, reference-aware cleanup, source images over 50 MiB, broader media previews |
| Git/workspaces | Native status including unborn/detached/tracking/conflicts, literal staged/unstaged diffs and paths, stage/unstage/commit, initialize, local branch creation/checkout and remote tracking, fetch, clean fast-forward pull, explicit single-branch push, background clone with progress/stall/cancel/retry, cancellable operations and app-shutdown cleanup, durable local worktree preparation with explicit base/new/existing branch choices, verified registered reuse, queued-message readiness, cancellation/retry and conservative restart recovery, explicit None/top-level/recursive initialization in new worktrees with durable nonfatal warnings, discovered checkout setup with explicit reviewed execution and provider readiness gates, reviewed settle roles with drain-before-resume | PRs/stacks/host integrations, checkpoints/revert, worktree removal, automatic pull policies, broader credential and network failure coverage |
| Files | Async hidden/empty/ignored directory browsing, bounded path/content/regex search with Unicode ranges and ignored-file inventory, bounded UTF-8 preview with binary rejection, safe exclusive creation and revision-checked saves, advisory native watching, retained dirty editor buffers, normal-Quit discard confirmation, contained composer path references and match/file-link navigation, explicit inspected external-editor and Finder handoffs with preferred-editor settings | Arbitrary-host and remote reads/browsing/metadata, broader binary/media previews, cross-editor Unicode columns and live installed-editor verification, crash recovery of unsaved buffers, cached index/ranking and regex-dialect parity |
| Terminal | Native SwiftTerm emulator and local PTYs, per-window/thread tabs, resize/input, 5,000-line scrollback, hide/show persistence, interrupt and process cleanup, bounded t3.json script discovery with explicit native selection and dedicated command tabs/cwd/environment/exit status, app-owned setup and settle jobs with shared output and separate command/background lifetime | Preview behavior, project-script settings/editing, durable terminal restart restoration, remote attachment/replay, search/settings, activity/idle detection and idle-tab closure, broader terminal compatibility and accessibility |
| Remote environments | Not implemented | Authenticated transport, pairing, capabilities, reconnect, SSH/relay/LAN, multi-environment ownership |
| Desktop integration | App bundle, commands/shortcuts, appearance | Notifications, deep links, updates, browser/preview, screenshot/import features, power/resources, accessibility QA |
| Distribution | Local development-identity or ad-hoc signed bundle | Release signing/notarization, installer/update validation, full notices |
| Validation | Deterministic core/protocol/orchestration tests, CI workflow, native Codex/Claude turn and queue smoke checks | Upstream replay corpus, broader live tool/approval coverage, UI automation, full parity and failure audit |

## Validation commands

```sh
swift test --no-parallel
./script/build_and_run.sh --build-only
./script/build_and_run.sh --verify
COINCIDE_LIVE_CODEX=1 swift test --filter installedCodexHandshakeAndModelDiscovery
COINCIDE_LIVE_CLAUDE=1 swift test --filter installedClaudeHandshakeAndModelDiscovery
COINCIDE_LIVE_ATTACHMENTS=1 swift test --filter installedProvidersReadAnImageAndFileThroughTheNativeEngine
COINCIDE_LIVE_ACP=1 swift test --filter installedOpenCodeACPHandshakeAndModelDiscovery
COINCIDE_LIVE_ACP_TURN=1 swift test --filter installedOpenCodeCompletesATurnThroughTheNativeEngine
COINCIDE_LIVE_ACP2=1 swift test --filter installedOpenCodeUsesTheVersionNegotiatedOnItsNativeConnection
```

The live discovery test performs a handshake and model listing only. It does not
run a model turn. The separate attachment test incurs real provider usage, sends
only generated image/file markers, and checks both installed providers through
the native engine. It permits only the generated file's Claude Read approval.
The deterministic provider fixture contacts no external service
and does not exercise real provider authentication or prove full provider parity.
Tests create temporary isolated Git repositories and remove them after use. Git
synchronization tests use a local bare remote and two working copies; they do not
publish to any external repository or establish live SSH/HTTPS authentication.

The ACP discovery check creates an agent session and reads advertised models; it
does not submit a model turn. The separate ACP turn check sends a generated marker
and declines every tool permission. `COINCIDE_ACP_TEST_MODEL` can select one of
the installed agent's advertised models for that check. A passing agent/model
does not establish availability of the agent's other hosted model endpoints.
The installed OpenCode currently negotiates v1 when v2 is requested. Its passing
live check verifies fallback, not a live v2 server. The current v2 draft is tested
with deterministic peers, including acceptance/completion ordering, startup Stop,
background permissions, agent-initiated activity, and resume snapshots.

## Upstream attribution

T3 Code is copyright © 2026 T3 Tools Inc., MIT licensed. Its license is preserved
in `T3-CODE-LICENSE.txt`. Coincide is independent of T3 Tools Inc.
