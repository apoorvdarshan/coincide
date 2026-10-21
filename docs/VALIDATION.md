# Validation record

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
