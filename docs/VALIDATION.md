# Validation record

## 2026-10-22 — opt-in ACP v2 connections and foreground lifecycle

- Added an opt-in native adapter for the current ACP v2 draft, using the same
  [official schema baseline](https://github.com/agentclientprotocol/agent-client-protocol/blob/main/schema/v2/schema.json)
  (`e47fe81d2db877fe182bdca2ce4ac52ffd62ec61`) inspected for transcript entities.
  Initialization supplies v2 `info`/`capabilities` plus legacy fields for agents
  choosing v1. A v1 result adopts the existing connection without another process
  or handshake. The per-agent **Use ACP v2 (experimental)** switch defaults off.
- Prompt responses associate the inserted native user ID with its client command;
  they never imply completion. Foreground state updates control busy/action/idle
  state independently of pending session-level permission requests. Native
  agent-initiated work creates no synthetic user message. Early setup/resume
  notifications are drained in order, and repeated idle snapshots do not complete
  a new submission. Unknown idle outcomes end busy state but hold the queue.
- Native select/boolean options use v2 `configId` and the schema's `id`/`boolean`
  request value types. Each queued turn captures its own typed configuration.
  Reset Agent Options clears overrides without changing saved invocations.
  Native settings/store tests verify experimental-mode and boolean persistence.
- Permission responses use a runtime-pinned outbox action, so a background request
  can remain pending through another foreground turn. Resolving one of several
  requests never infers that the agent has resumed; its state update is authoritative.
  Rejected and unconfirmed user submissions retain visible error information and
  are never automatically retried. Request cancellation before insertion uses
  `$/cancel_request`; active work uses `session/cancel`. Unresponsive cancellation
  stops only the owned process after the configured timeout.
- The transport now retains JSON-RPC error code/data and can deliver a request's
  outcome in order with notifications and disconnection. A regression confirms
  acceptance is associated even when the peer immediately exits. Other tests cover
  echo-before/after acceptance, idle-before-ack, repeated idle, pre-insertion hook
  failure, lost acceptance response, concurrent/background permissions, autonomous
  activity, resume while waiting for permission, cancellation before/after insertion,
  unknown outcomes, queue configuration, and journal rebuild after restart.
- Review found a startup Stop race: an early native running snapshot could make
  Stop available while configuration was still waiting. The adapter now cancels
  that unsent input and checks cancellation after setup/configuration. A gated
  regression verifies the start effect becomes cancelled and the peer never receives
  `session/prompt`, even after releasing its delayed configuration response.
- The complete suite passed 107 tests (86 core, 4 terminal, 13 Markdown, 4 native
  UI/store) with Codex/Claude discovery and image/file turns, OpenCode discovery
  and a real marker turn, and the v2-negotiation marker turn enabled. Installed
  OpenCode selected **v1**, and fallback completed a real turn. This is not live
  v2-server validation; the v2 lifecycle cases use deterministic stdio peers.
- Native packaging, launch, strict signature verification, and bundled-font runtime
  verification passed. A private backup preceded storage migration 5 → 6; canonical
  comparison excluding only new optional fields preserved all 3 existing
  conversations and 25 messages. Physical interaction with the new settings and
  state/error UI remains part of unlocked-desktop QA.

The v2 protocol is still a draft. Older draft variants, live v2-provider checks,
native authentication/elicitation, managed agents, session browsing/import/fork,
live notices, richer media, and display-terminal UI remain open parity work.

## 2026-10-22 — durable provider transcript entities

- Added native transcript entities keyed by session, type, and opaque ID. The
  reducer preserves structured content and unknown fields, applies omitted/null/
  replacement semantics, patches `_meta` by top-level key, and keeps chunk metadata
  separate. Binary terminal chunks decode independently before appending; complete
  terminal snapshots replace prior bytes. Plans, compaction summaries, and unknown
  future updates retain their payloads.
- The entity reducer follows the current official
  [ACP v2 entity rules](https://agentclientprotocol.com/protocol/v2/prompt-lifecycle)
  and [tool/terminal updates](https://agentclientprotocol.com/protocol/v2/tool-calls).
  The inspected official schema's Git blob was
  `e47fe81d2db877fe182bdca2ce4ac52ffd62ec61`. The v2 wire adapter is not implemented
  yet; these tests do not establish v2 connection or foreground-lifecycle support.
- ACP v1 tool updates now use these entities, preserving their input/output,
  locations, status, and other metadata. The native disclosure shows the tool
  title/status, input, output, files, and raw details. Its v1 adapter filters null
  updates according to v1 semantics before applying the native patch.
- A gated protocol test waits for the engine to become idle before allowing the
  fixture to send background tool output. The update is saved without starting a
  new turn and survives journal rebuild. Restart/resume tests now verify three
  distinct tool identities and their input/output across three turns.
- Tests also cover entity-ID collisions between types/sessions, streamed-content
  replacement and clearing, unknown variants/content, plan envelope fields,
  metadata-only journal changes, stale runtime events, and native user-message
  association with echo arriving before or after acceptance. Original local text
  and timestamps are preserved; equal content never establishes identity.
- Malformed entity updates fail their owning runtime while the workspace command
  engine remains usable. A regression sends another turn and completes it with a
  new provider connection after that failure.
- `COINCIDE_LIVE_ACP=1 COINCIDE_LIVE_ACP_TURN=1 COINCIDE_ACP_TEST_MODEL=opencode/glm-5.3-flash-free swift test --no-parallel`
  passed all 93 tests: 72 core, 4 terminal, 13 Markdown, and 4 native UI/store.
  Installed OpenCode discovery and a generated-marker turn passed again.
- Packaging, launch, strict signature verification, and bundled-font verification
  passed. A private SQLite backup preceded storage migration 4 → 5; canonical
  comparison excluding only the new optional entity field confirmed all 3 prior
  conversations and 25 messages were unchanged. Physical interaction with the new
  tool disclosures remains part of unlocked-desktop QA.

## 2026-10-22 — native ACP v1 agents

- Added a native JSON-RPC 2.0 stdio adapter following the official
  [initialization](https://agentclientprotocol.com/protocol/v1/initialization),
  [prompt lifecycle](https://agentclientprotocol.com/protocol/v1/prompt-turn), and
  [configuration](https://agentclientprotocol.com/protocol/v1/session-config-options)
  contracts. No T3 server or JavaScript adapter is launched by Coincide.
- Deterministic tests cover streaming, images, reasoning, tool updates, plans,
  opaque permission options, model/mode changes through both legacy fields and
  grouped config options, unsupported versions/images/resume, authentication
  errors, concurrent discovery, and cancellation (including an agent that ignores
  Stop). Client filesystem, terminal, authentication, and elicitation capabilities
  are not advertised yet. Unknown configuration categories keep their select UI.
- The native engine test confirms a start effect settles while a permission is
  still waiting; two queued turns complete through exact permission responses.
  After shutdown/reopen, the same native session loads and completes another turn
  without duplicating its replayed history. Event barriers drain already-decoded
  notifications and release their waiters on cancellation or connection close.
- Native store tests cover saving, selecting, editing, removing, and reopening
  agent configurations. Existing conversations retain their captured invocation.
  Light/dark offscreen AppKit settings captures were inspected. Physical settings,
  permission-button, and keyboard interaction still need unlocked-desktop QA.
- Real installed OpenCode initialized, advertised models through config options,
  and completed a generated-marker turn through the native engine using the
  advertised `opencode/glm-5.3-flash-free` model. The agent's default
  `opencode/flint-40b-free` failed after roughly 91 seconds with
  `Endpoint is unavailable`; this service failure remains recorded. No sign-in,
  provider installation, credential changes, or user files were needed.
- A combined live-provider check also exercised Codex and Claude attachment turns.
  One Codex OCR response substituted an en dash for the image marker's hyphen.
  The fixture now uses letters and digits to avoid that visual ambiguity; its
  exact independent image/file-marker assertion remains unchanged.
- The complete offline suite passed 84 tests: 63 core, 4 terminal, 13 Markdown,
  and 4 native UI/store tests. A combined run enabling live Codex/Claude discovery,
  both image/file cases, OpenCode discovery, and its native-engine turn also passed
  all 84 tests. CI keeps live-provider checks opt-in. The preceding
  transport fix passed [GitHub CI](https://github.com/apoorvdarshan/coincide/actions/runs/39667658837)
  with every test retained and the original one-second deadline assertions.
- Packaging, launch, strict signature verification, and bundled-font runtime
  verification passed. A private SQLite backup preceded storage migration 3 → 4.
  Canonical comparison excluding only new ACP fields confirmed all 3 existing
  conversations and 25 prior messages were unchanged.

ACP v2, registry/managed installs, native authentication and elicitation, delegated
filesystem/terminal operations, richer content/config types, session browsing and
import, and provider-specific features remain pending. These checks establish a
working ACP v1 integration, not full ACP or T3 Code parity.

## 2026-10-22 — durable native attachments

- `COINCIDE_LIVE_CLAUDE=1 COINCIDE_LIVE_CODEX=1 COINCIDE_LIVE_ATTACHMENTS=1 swift test`
  passed all 74 tests: 54 core, 4 terminal, 13 Markdown, and 3 native UI/store tests.
  The installed-provider attachment test ran two real-provider cases. CI leaves
  the provider-dependent discovery/model-turn checks disabled.
- Real Codex and Claude each read a random marker rendered into a synthetic image
  and a different random marker stored in an attached text file. Both returned the
  exact combined markers through the native command engine. The final two-provider
  smoke check passed in about 11 seconds after the transport correction below.
  No user file was attached, no network tool was permitted, and only the generated
  text file's Claude Read approval could be accepted by the test.
- Tests verify immutable private copies after source deletion, mode 700 directories
  and mode 600 files, image type detection, TIFF conversion, resizing, SVG-as-file
  handling, long names, size/count limits, checksum changes, symlink rejection,
  attachment-only queued turns, draft/queue/history restoration, queue editing,
  native image payloads, and attachment-only journal mutations. Storage version 3
  prevents older builds from silently discarding these references.
- Native NSItemProvider tests cover file-URL paste, image-data paste, concurrent
  imports, partial failure, removal, and persistent drafts. Cancellation also
  completes when a provider never calls back, so shutdown cannot wait indefinitely
  for clipboard data. Light/dark offscreen AppKit captures of the attachment shelf
  and image preview were inspected. Actual keyboard-paste/drop and copy/save-panel
  interaction still require an unlocked-desktop smoke check.
- Provider transports now allow bounded 128 MiB incoming frames for image-bearing
  messages; the default transport limit remains 16 MiB. The incremental decoder
  scans only newly appended bytes. A 17 MiB fragmented-frame regression verifies
  decoding and the smaller default's rejection.
- A blocked-stdin regression crashed the previous implementation with SIGPIPE.
  Provider input now uses per-descriptor signal suppression and a serial queue of
  nonblocking writes. RPC actors remain responsive during backpressure; timeout,
  cancellation, and close stop a partial frame without replay. Tests also verify
  whole-frame concurrent writes and cancellation before a write starts. The
  previously crashing regression passed, as did the complete suite and real
  Codex/Claude image/file turns after the fix.
- GitHub's slower runner then exposed an additional responsiveness failure while
  a large JSON payload was being serialized. Encoding now runs on the serial input
  queue, outside the protocol actor and Swift's cooperative executor. Cancellation
  before pipe writing begins leaves the connection intact. The deadline assertions
  remain unchanged; the full 74-test suite and both live attachment cases passed
  again locally after this correction.
- A subsequent hosted run still missed the deadline while many process, PTY,
  image-rendering, and database tests launched concurrently. The measured interval
  also included constructing the 8 MiB test string before the RPC timer existed.
  The fixture payload is now prepared before timing, and CI runs every test with
  `swift test --no-parallel` to keep process-startup contention out of timer checks.
  The same timeout, close paths, payload size, and one-second assertions remain.
- Native packaging, launch, strict signature verification, and bundled-font
  runtime verification passed. A private backup preceded migration of the real
  workspace from storage version 2 to 3. Canonical comparison, excluding only new
  empty attachment defaults, confirmed all 3 conversations and 25 prior messages
  were unchanged.

Removed or failed-import attachment copies are retained for now; reference-aware
cleanup is pending. Files remain local, and remote upload, question attachments,
long-paste conversion, prompt stash, and larger source-image handling are not yet
implemented. This does not establish full T3 attachment or overall feature parity.

## 2026-10-22 — native display equations and packaged fonts

- Added SwiftMath 1.7.3 at the locked revision, with its MIT notice and original
  font bundle/licenses. SwiftMath uses native CoreText rendering. Display formulas
  accept closed, standalone `$$` or `\[` / `\]` blocks and closed `math` code
  fences, including fences nested in quotes. Incomplete fences stay as code.
- The complete local suite passed 60 tests: 43 core, 4 terminal, and 13 Markdown.
  Math tests check Markdown characters retained inside formulas, protected code
  and HTML, prices, incomplete delimiters, nested fences, bounded parsing of many
  unfinished formulas, font loading, fractions/integrals/matrices, invalid-command
  fallback, and expression-size/nesting limits. A final focused math run passed
  after excluding protected code/HTML from closing delimiters.
- Native light/dark offscreen captures include the typeset quadratic formula and
  its Copy LaTeX control. Original message text remains available through response
  copy. Oversized or unsupported expressions display source rather than disappearing.
- Packaging copies the SwiftPM font resource bundle. `--verify-resources` renders
  a formula before starting the app, without opening a workspace, provider process,
  or window. CI now runs this check after bundle/signature verification.
- Native packaging and strict signature verification passed. The resource check
  also passed from a temporary relocated copy of the complete app; that copy was
  removed afterward. Both earlier Markdown commits passed GitHub Swift CI.

Inline formulas, same-line display delimiters, display delimiters nested in quotes,
and full upstream math syntax remain pending. This does not claim KaTeX-level
coverage, interactive copy verification, or complete T3 transcript parity.

## 2026-10-22 — native Markdown transcript

- Added Swift Markdown 0.9.0 and Swift cmark 0.9.0 at the revisions locked in
  `Package.resolved`. Their original licenses/notices are bundled in the app.
  Rendering uses SwiftUI/AppKit; there is no webview or JavaScript renderer.
- `COINCIDE_LIVE_CLAUDE=1 COINCIDE_LIVE_CODEX=1 swift test` passed 56 tests:
  43 core, 4 terminal, and 9 Markdown. New coverage includes nested inline styles,
  streamed unfinished code fences, GFM tables/tasks/lists, inert HTML, rejected URL
  schemes, workspace containment and symlink escape, line-number links, Unicode
  syntax coloring, large-input fallback, cache isolation, and UTF-16 line selection.
- Native offscreen AppKit hosting-window captures were inspected in light and dark
  appearance. They contain the rendered code, tables, list numbering, task states,
  nested lists, and inline styles. Inspection exposed table sizing/alignment issues,
  which were corrected. SwiftUI ImageRenderer alone omitted scroll-view content,
  so those initial images were not used as evidence of code/table rendering.
- File links open the inspector's native text editor with the requested line
  selected. The editor preserves unsaved-change confirmation, conflict-checked
  writes, standard undo, and workspace path checks. The line calculation is tested;
  a full interactive file-link/copy-control smoke check is still pending because
  the desktop was locked during this milestone.
- Development app packaging and strict signature verification passed.
- Repeating packaging exposed read-only dependency notice files copied from the
  package checkout. The script now installs notices with mode 644. Two consecutive
  packaging runs and signature verification passed after that correction.

Code highlighting is lexical and limited to common language families. Unknown or
large code blocks retain plain source. Images currently retain their alternative
text and safe link; media previews, mathematics, and full upstream Markdown
extensions remain pending. This is not a full transcript-parity claim.

## 2026-10-22 — native command engine and queued turns

- `COINCIDE_LIVE_CLAUDE=1 COINCIDE_LIVE_CODEX=1 swift test` passed 47 tests:
  43 core and 4 terminal. Installed-provider tests perform only handshake/model
  discovery; deterministic fixtures verify execution and failure behavior.
- Runtime tests cover ordered queues and captured configuration, durable command
  retries/rejections, responsive approvals while start acknowledgement is pending,
  reserved control capacity with eight blocked starts, stale run/connection events,
  questions, native interruption, Stop during startup, process loss, concurrent
  draft/pin edits, queue editing, restart, exclusive ownership, and lost effect leases.
- A controlled Codex fixture completes two turns before acknowledging their start,
  starts a third, and then delivers the older acknowledgements. The previous guard
  failed by targeting a completed turn on interrupt; the corrected implementation
  passed and targets the third turn. The source was restored after that comparison.
- Native Claude QA sent two prompts in rapid succession. The second appeared in the
  queue, both expected markers arrived in order, and the thread returned to idle.
  A later long response was stopped with a queued message waiting. The app held the
  queue, preserved the same queued ID across a graceful rebuild/restart, and returned
  the expected marker after **Resume Queue**. No queued turn replayed on restart.
- Native Codex QA created a conversation, typed directly into the automatically
  focused composer, and submitted with Return. The real provider returned
  `COINCIDE_NATIVE_ENGINE_CODEX_OK`; state returned to idle and the outbox recorded
  success. These model prompts requested no tool or filesystem actions.
- The database was backed up before migration. Stripping only the newly added
  queue/runtime fields produced an identical canonical snapshot: the existing
  project, both conversations, and all 14 prior messages were preserved. Storage
  version 2 prevents older binaries from silently discarding the new fields.
- Final native development packaging, launch, and strict code-signature
  verification passed after the lease-ownership failure handling change.

This establishes the native orchestration milestone, not full T3 parity. Provider
effects cannot guarantee exactly-once external execution. The current projection
cache still writes a full snapshot; broader live approvals, all providers, remote
environments, checkpoints, and complete transcript rendering remain pending.

## 2026-10-22 — transactional provider outbox foundation

- `COINCIDE_LIVE_CLAUDE=1 COINCIDE_LIVE_CODEX=1 swift test`: all 33 tests passed
  across core (29) and terminal (4). New tests verify atomic effect/intent rollback,
  logical command retries after newer state commits, concurrent claims, owner and
  expiry fencing, lease renewal, failure handling, and cancellation after process
  loss. Expired process-bound effects are not automatically reclaimed or replayed.
- Turn-start, interrupt, and approval/answer intents have typed Swift payloads.
  Turn configuration excludes transcript history and credentials. Pending effects
  commit with the journal, projection, command receipt, and audit marker.
- Native development packaging/launch and strict signature verification passed.
  Canonical JSON comparison confirmed that adding the outbox tables left both
  existing conversations and all 14 messages unchanged.

This is the durable outbox API and its failure/ownership contract. The desktop
still dispatches provider actions directly after persistence; the execution
worker, normalized decisions, and queued-message UI are not yet wired in.

## 2026-10-21 — replayable workspace journal

- `COINCIDE_LIVE_CLAUDE=1 COINCIDE_LIVE_CODEX=1 swift test`: all 29 tests passed
  across core (25) and terminal (4). New coverage includes replay of streaming
  Unicode combining marks, reorder/truncate/removal, concurrent command-ID
  deduplication, stale revision rejection, legacy import, projection rebuild,
  SQLite transaction failure/rollback, empty history, and future/incomplete data.
- Events, projection, receipt, and audit marker commit together. A trigger that
  failed the last transaction write left no partial journal events, receipt, or
  projection change; retrying that command after removing the fault succeeded.
- The app's existing database was backed up before migration. Canonical JSON
  comparison confirmed that its project, both conversations, and all 12 existing
  messages were unchanged after the native app imported the legacy snapshot.
- A real Claude turn through the migrated native app returned
  `COINCIDE_JOURNAL_SMOKE_OK` and finished `idle`. The journal recorded metadata,
  message-upsert, and streamed text-append events for that turn. Development
  packaging and strict code-signature verification passed.
- The database and its WAL/SHM files use private permissions. Replay reads one
  record at a time rather than materializing the whole journal in memory.

The desktop currently derives journal mutations from serialized snapshot writes.
The explicit commit API deduplicates stable command IDs; the convenience `save`
API creates a fresh ID for each call. Normalized domain commands, a transactional
effect outbox/worker, queued turns, and incremental projection storage still need
to be implemented. No exactly-once provider execution is claimed.

## 2026-10-21 — native terminal

- Added SwiftTerm 1.99.1 at locked revision
  `2f573f73af5e768d90847dce20c97fa9535d7164`, with the native macOS frontend and
  PTY backend. No browser terminal or Node terminal service is involved.
- `COINCIDE_LIVE_CLAUDE=1 COINCIDE_LIVE_CODEX=1 swift test` passed all 23 tests
  across the core (19) and terminal (4) test targets. Focused terminal tests were
  repeated after the final accessibility/focus change. Tests verify an actual
  PTY in a workspace containing spaces, Unicode/ANSI rendering, final output and
  exit status, PTY resize, interrupt while keeping the shell alive, closure of
  the foreground job, idempotent close, and rejection of an unavailable folder.
- Native UI QA typed and observed `COINCIDE_TERMINAL_UI_OK`, the workspace path,
  and markers in two separate terminal tabs. Hiding and showing the panel kept
  a shell variable set to `kept`. Creating or closing a tab correctly focused
  the resulting terminal. The terminal exposes its visible text and a focus
  action through accessibility; full screen-reader text navigation needs work.
- Rebuilds now ask only this repository's development bundle to quit through
  AppKit, wait for it to finish, and stop the build if it refuses. They do not
  force-quit another installation. Rebuild QA recorded both owned shell PIDs and
  verified that neither survived shutdown. Workspace close/open events were
  also persisted. The bundled SwiftTerm and T3 license notices were verified,
  and strict code-signature validation passed.
- After further binary rebuilds, Claude model discovery from the native header
  completed in about 0.7 seconds with the stable development signature. It no
  longer stalled on the Documents permission request seen with ad-hoc rebuilds.

Terminal history and processes currently survive panel hiding and thread changes
within a window, not application restarts. Remote terminals, durable attachment,
search/settings, and broad terminal compatibility remain pending.

## 2026-10-21 — Claude and native chat interface

- `COINCIDE_LIVE_CLAUDE=1 COINCIDE_LIVE_CODEX=1 swift test`: 19 tests passed.
  The live tests list models without running model turns. Offline Claude fixtures
  verify streaming/snapshot reconciliation, repeated turns, approval/decline,
  user questions, cancellation, interruption, provider failure, and old workspace
  decoding with the new provider/draft fields.
- Native UI QA verified the ChatGPT-style layout, new-conversation provider menu,
  rounded composer, hidden-by-default inspector, and live Claude text responses.
  Two consecutive real turns returned `COINCIDE_CLAUDE_SMOKE_OK`; a later turn
  after an app restart resumed the same Claude session and returned the marker
  from its conversation history. The resulting thread returned to `idle`.
- Startup initially timed out while macOS awaited Documents-folder consent for
  this machine's shared CLI instructions. Unified logging confirmed the TCC
  request and that ad-hoc rebuilds invalidated the previous code requirement.
  Consent was granted through the native macOS dialog. Local build scripting now
  uses an existing Apple Development identity when available; hosted CI retains
  ad-hoc signing. Strict signature verification passed. Release notarization and
  the oldest supported macOS version remain unverified.
- Provider logs record connection/request stages without prompts, file contents,
  raw provider frames, stderr, or credentials. Noisy temporary byte logs were
  removed after diagnosis. Initialization timeout messaging now identifies a
  possible macOS permission dialog and states that no model turn was submitted.
- Drafts persist per conversation and are cleared with the durable send intent,
  before provider startup, so startup latency does not leave a sent prompt in the
  composer. Failed sends remain visible in the saved conversation.
- The initial Swift CI and both refreshed dependency-update branches passed
  tests, native packaging, and signature verification on GitHub's macOS runner.
  Checkout v7 and cache v6 updates were merged only after those checks passed.

These checks establish basic Codex/Claude conversations, not complete provider
or T3 Code parity. Real tool approvals, all control methods, remote environments,
and long-running behavior still need broader end-to-end verification.

## 2026-10-21 — initial Swift runtime and native workspace

Implementation commit: `c5290b7b6cc2cfa0e8d9f4537bf8e2d6a2fa3ad8`.
Local toolchain: Apple Swift 6.4, Xcode 27.1, Apple Silicon macOS 27.

- `COINCIDE_LIVE_CODEX=1 swift test`: 14 Swift Testing tests passed, including
  the optional installed-Codex handshake/model-discovery check. The preliminary
  XCTest runner reports zero tests because the actual suite uses Swift Testing;
  the Swift Testing summary is the authoritative test count.
- `./script/build_and_run.sh --verify`: built, packaged, and launched Coincide.
- `codesign --verify --strict dist/Coincide.app`: passed for the ad-hoc signed
  development bundle. This does not establish Developer ID signing/notarization.
- Native UI inspection confirmed the empty state, Add Project panel, project
  folder open events, new thread, supervised permission selection, composer,
  source-control inspector, and displayed repository changes.
- A real Codex turn was sent through the native composer with the prompt
  `Respond with exactly COINCIDE_NATIVE_SMOKE_OK. Do not use tools or change files.`
  The native transcript displayed `COINCIDE_NATIVE_SMOKE_OK`. The database
  persisted both user and assistant messages and returned the thread to `idle`.
- The Add Project panel was changed from a synchronous modal loop to an
  asynchronous AppKit panel after accessibility input exposed a responsiveness
  issue. Project folder opening was also verified through Launch Services.
- Process/protocol tests exposed and fixed pipe buffering and thread-pool
  starvation issues. File containment tests exposed and fixed symlink-parent
  resolution when the final path does not yet exist.

This is evidence for the initial implementation only. It does not establish
complete T3 Code parity, all-provider reliability, live tool/approval behavior,
remote support, long-running stability, accessibility completeness, or support
on the oldest declared macOS version. CI results remain separate live evidence.
