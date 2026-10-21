# Validation record

## 2026-10-22 — native workspace file sessions and editor integration

- Added local async listing, path search, ignored-file inventory, bounded UTF-8
  reads, exclusive creation, revision-checked saves, and advisory recursive
  FSEvents invalidations. Immediate listing includes hidden/empty/ignored entries;
  path search excludes ignored paths, including tracked files matching ignore
  rules, while tracked files are not labelled ignored in immediate listings.
  Search has a 256-UTF-16 query limit, 200-result ceiling, 25,000-entry scan ceiling,
  and shared 15-second scan budget. Ranking is native, not upstream fff ranking.
- Filesystem workers use owned directory descriptors and nonblocking regular-file
  reads. Tests cover repeated enumeration, internal/dangling/escaping links,
  special nodes, named/resolved Git and bare/linked-worktree metadata, optional
  absence, strict UTF-8 and partial Unicode previews, binary rejection, stale
  revisions, same-byte inode replacement, executable mode, exclusive-create races,
  root replacement, and cancellation. Real Git ignore probes use bounded private
  input/output and sanitized context; a config FIFO verifies cancellation waits
  until the owned Git process has exited. Watch streams are ready before return,
  bounded/coalesced, and finished/drained on close.
- The inspector now uses background services end to end. Cached editors retain
  unsaved buffers through inspector visibility, tab, and conversation changes.
  Clean buffers reload on invalidation; dirty buffers and external bytes survive
  conflicts. Truncated previews are read-only. Normal Quit offers Cancel or an
  explicit discard choice. Native file/folder search inserts an escaped relative
  link into the captured conversation only, retaining selection, provider, queue,
  attachments, and drafts across restart. Last-owner cleanup drains editors and
  services; a shared-path surviving project retains both. Legacy synchronous
  compatibility reads/writes share anchored checks, and untracked Git diff reads
  now use the bounded async service.
- The full suite passed 257 tests: 212 core, 4 terminal, 13 Markdown, and 28 native
  UI/store. All 11 file-service core tests, the untracked Git-preview regression,
  and both new UI/store workflows ran, including real Git cancellation.
  Independent service and UI lifecycle
  reviews found no remaining blocker. No local interactive GUI test ran.
- Packaging/launch, strict deep app signing, and bundled-font rendering pass.
  The Xcode GUI runner compiles and passes strict deep signature verification.
  Canonical comparison confirms all 3 existing conversations, 25 messages, and
  non-identity project fields are unchanged; storage remains version 9.
- Hosted run 39690616352 passed the 243-test production suite and ran all three
  real GUI workflows without skips. Light/dark reached physical removal and
  displayed the complete warning; XCTest truncated its informative value at
  512 UTF-16 units. The grouping workflow reached the correct native folder but
  its global confirm-button query also matched an offscreen Touch Bar button.
  Harness queries now scope native panels/sheets and their observed identifiers.
  For the observed text-truncation boundary only, on-device Vision checks both
  warning concepts in retained native-alert pixels. All functional, copy, and
  geometry assertions remain enabled. Complete hosted GUI verification is pending.
- Revision saves are a guarded check followed by atomic replacement, with a final
  check-to-rename race against arbitrary external writers. They are not atomic
  cross-process compare-and-save. Content/regex search, host/remote file APIs,
  external-editor integration, and crash recovery remain pending.

Full T3 Code parity remains incomplete; see `PORTING.md` for the remaining areas.

## 2026-10-22 — atomic group rename and removal

- Whole-group rename and removal validate every registration ID and literal
  checkout path. Removal additionally validates the full active/archived
  conversation union. Stale, missing, duplicate, moved, or regrouped members reject
  before changing any project. SQLite rollback tests preserve journal, receipts,
  preferences, leases, and effects; successful transactions replay after restart.
- The native removal sheet lists all checkout paths, explains retained files and
  recovery history, and warns about unsaved edits. Cancel preserves the group.
  Removal starts after dismissal so a stale-confirmation error remains visible.
- Every affected path locks before the first suspension. A real queued worktree
  assignment blocked by a separate SQLite writer commits before removal preflight;
  the new path remains locked even after its conversation disappears. Two-window
  PTY coverage checks targeted closure and surviving terminals. A held unrelated
  provider cleanup does not delay group completion. Shared inspectors and files
  remain usable afterward. Archived fallback stays visible and restores on restart.
- The full suite passed 243 tests: 200 core, 4 terminal, 13 Markdown, and 26 native
  UI/store. Independent source review found no remaining blocker. Hosted run
  39689027117 exposed an installed-Codex assumption in the preceding grouping
  fixture; that test now configures its injected ACP agent explicitly and passes
  locally without depending on a developer's installed Codex.
- The third hosted GUI workflow now includes native whole-group rename, physical
  mode headers, removal-sheet paths, Cancel/draft retention, confirmed removal,
  and unchanged Git HEAD/file checks. The gate still requires all three workflows
  without skips. Complete hosted GUI verification remains pending.
- Packaging/launch, strict deep app and runner signing, bundled-font rendering,
  and UI-runner compilation pass. No local GUI test ran. Canonical comparison
  confirms all 3 existing conversations, 25 messages, and non-identity project
  fields are unchanged; storage remains version 9.

Full T3 Code parity remains incomplete; see `PORTING.md` for the remaining areas.

## 2026-10-22 — persisted logical checkout groups and conversation selection

- Registered projects now acquire credential-free repository identity on load,
  registration, and clone readiness through bounded native Git discovery. Request,
  path, and project-incarnation checks fence both successful and failed results,
  including explicit callers resuming after removal. Cleanup drains canceled
  discovery outside the command inbox. Failures preserve known identity without
  stopping agents; unchanged metadata does not add journal events or outbox work.
  The exact SQLite commit/actor-ack interleaving is source-reviewed; held-result
  and held-error tests reproduce removal and same-ID re-add boundaries.
- Repository, repository-and-folder, and separate-checkout modes derive groups
  while preserving physical project/thread records, fork identity, local folders,
  and duplicate-path registration references. Preferences persist grouping mode,
  physical-path overrides, expansion, and the future-conversation checkout.
  Activity includes eligible conversations across all members. Group moves retain
  untouched physical interleaving and reject stale order or membership; self drops
  are no-ops. Collapse retains the selected eligible conversation.
- Native menus expose physical checkout paths for new conversations and individual
  rename/removal. Clone badges and readiness use each thread's actual owner.
  Changing future checkout does not rebind a conversation, draft, queue, or agent.
  Removal confirms the captured path and leaves sibling checkouts open. The last
  selected conversation persists; archived selection restores the archived view.
- Storage 8 to 9 migration retains absent/default legacy fields and protects the
  new state from older writers. Journal replay covers identity, preferences, and
  selection. Tests cover invalid metadata, forks/worktrees, monorepo boundaries,
  duplicate physical paths, activity, stale commands, cleanup, clone readiness,
  nonfatal discovery errors, restart, and unchanged thread/runtime/outbox state.
- The full suite passed 235 tests: 195 core, 4 terminal, 13 Markdown, and 23 native
  UI/store. The final pass includes the error-side and public-continuation owner
  guards. Three CI-configuration tests pass, and the Xcode UI runner compiles
  without local GUI execution. A third hosted GUI workflow uses two private real
  Git repositories to check grouping, physical checkout routing, distinct drafts,
  mode changes, selection restoration, and unchanged HEADs. All three workflows
  must pass without skips; real hosted verification remains pending.
- Native packaging/launch, strict deep app/runner signing, and bundled-font
  runtime verification pass. A private backup preceded the real storage 8 to 9
  migration. Canonical comparisons confirm all 3 existing conversations, their
  25 messages, and every non-identity project field are unchanged. One existing
  project acquired repository metadata; no user checkout was added or removed.

Full T3 Code parity remains incomplete; see `PORTING.md` for the remaining areas.

## 2026-10-22 — small-display window layout and native alert verification

- The third hosted run verified real Git HEAD and draft entry. The rename dialog
  appeared, but macOS omitted its SwiftUI text-field identifier; the test now
  scopes the single field to the observed native sheet and its Save control.
- Actual screenshots and accessibility frames showed a 1280-point default window
  extending beyond a 1024-point display, plus an oversized chat detail. Default
  sizing now fits the current display's visible area, and chat/detail containers
  accept smaller proposed widths. Large displays retain the 1280 by 820 default.
- Both hosted appearance workflows now require the entire window and each sidebar
  control to fit the actual display. All rename, draft, collapse, persistence,
  removal, and preserved-file checks remain enabled. The fourth hosted run
  confirmed unclipped light/dark geometry, rename, collapse, graceful restart, and
  retained draft/selection. It then stopped at the Add Project geometry lookup:
  macOS removes the image-derived identifier after relaunch, while the native
  title remains stable. The helper now queries that observed title and retains
  every existence/bounds assertion. Complete hosted verification remains pending.
- The full 220-test suite passed (183 core, 4 terminal, 13 Markdown, 20 native
  UI/store), including small-display sizing and offscreen narrow-detail checks.
  The Xcode UI runner compiled without launching a local GUI. Configuration tests,
  app packaging/launch, strict deep signing, and bundled-font verification passed.
  Canonical comparison confirmed the real workspace and its 3 conversations and
  25 messages are unchanged.

## 2026-10-22 — repository identity foundation

- Added native local Git identity resolution without remote access. Tests cover
  protocol/port and Azure aliases, nested names, IDNA hosts, SCP/IPv6 round trips,
  upstream/origin fork separation, fetch-only selection, bare repositories,
  nested and symlink roots, detached worktrees, and current configuration reads.
- Returned URLs strip authentication, queries, and fragments; encoded host
  delimiters and inconsistent stored metadata are rejected. Inherited Git context
  and trace variables cannot redirect discovery or write trace files. Metadata is
  bounded, errors omit raw Git diagnostics, and cancellation waits for Git exit.
- All nine focused tests and the full 218-test suite passed (183 core, 4 terminal,
  13 Markdown, 18 native UI/store). Independent source review found no remaining
  blocker. Existing workspace models and storage version 8 are unchanged.

This is a tested core foundation. Persisted identity enrichment, grouping
preferences, and the grouped sidebar remain pending.

## 2026-10-22 — native project removal and hosted GUI test foundation

- Added confirmed project removal covering active and archived conversations in
  one journal/projection/receipt transaction. The confirmation includes the exact
  conversation set; a new conversation requires renewed confirmation. Pending
  actions cancel atomically, running actions retain their executor leases, and
  exact action identities fence late registration and cancellation. Provider,
  clone, and owned model operations wait across the removal commit/acknowledgement
  window. Old model results cannot attach to a re-created owner with the same IDs.
- Runtime handles detach before publication. Tracked cleanup waits outside the
  serial inbox, so unrelated projects remain responsive while processes close.
  All registered native windows close only the removed conversations' terminals.
  Pending imports/worktree setup and clone retries cancel, drafts/model caches and
  stale selection/navigation clear, and inspectors with surviving path references
  remain open. Coincide does not delete checkout, worktree, staging, or attachment
  files. Git can clean up its own unfinished files when an active clone stops;
  the removal confirmation and documentation explicitly qualify that case.
  Append-only recovery history remains; the confirmation does not promise erasure.
- File edits register dirtiness synchronously. Project editor scopes freeze
  before waiting for earlier UI commands, and a queued preflight checks for newly
  dirty buffers. Rejected removal releases the scopes. Shared workspaces stay
  locked through cleanup and become editable again for surviving owners. Stale
  file callbacks cannot reopen an unreferenced workspace.
- The full SwiftPM suite passed 209 tests: 174 core, 4 terminal, 13 Markdown, and
  18 native UI/store tests. New regressions cover stale/duplicate confirmations,
  empty projects, receipt replay/collision, transaction rollback, restart/journal
  rebuild, saturated pending/running effects, slow close responsiveness, same-ID
  metadata reuse, late clone events, preserved file/attachment bytes, terminals in
  two window owners, never-finishing paste cancellation, shared inspector paths,
  dirty-buffer confirmation, edit locks, and stale navigation. The full suite
  passed again after the final catch-side metadata guard found during review.
- Native packaging/launch, strict deep signature checks, and bundled-font runtime
  verification passed. A private backup and canonical JSON comparison confirmed
  storage version 8 and all existing 3 conversations/25 messages are unchanged.
- Added a test-only Xcode UI runner exercising the SwiftPM-built app through real
  macOS windows, menus, keyboard input, and screenshots. The runner compiles and
  passes strict deep signature verification without launching a local GUI. Its
  three configuration tests and workflow lint pass. The CI script refuses local
  GUI execution. A copied app uses a dedicated bundle identifier and DEBUG-only
  private workspace; invalid test configuration cannot fall back to user data.
  Hosted light/dark workflows cover project creation and initial Git commit,
  rename/collapse, retained selection/draft, and graceful quit/reopen. The first
  hosted run passed all 209 SwiftPM tests but both GUI tests failed before app
  launch: Xcode's generated runner is sandboxed and could not create fixtures in
  shell-owned scratch. Fixtures now use the runner's Foundation temporary
  directory; screenshots remain retained XCTest attachments exported after the
  run. A second hosted run reached project creation in both appearances but its
  Git verification child exited unsuccessfully; the harness now resolves the
  actual developer Git executable outside the runner sandbox and retains command
  diagnostics. Recordings confirm readable selected rows and symbols in the live
  light/dark app, unlike the earlier offscreen captures. Later frame diagnostics
  identified window and content overflow; see the small-display entry above.
  The workflows now also
  test Cancel/confirmed removal, draft retention, and preserved README/icon/HEAD
  bytes. Local compile/configuration checks pass; the complete hosted workflows
  and screenshot review remain pending.

Full T3 Code parity remains incomplete; see `PORTING.md` for the remaining areas.

## 2026-10-22 — persistent native project organization

- Added native project collapse/expand, display-name editing, a project-sort menu,
  and Manual drag/context-menu ordering. Collapse retains the selected eligible
  conversation; existing search/archive filters still apply. It does not alter
  drafts, queues, provider connections, or running turns. Rename preserves project
  and thread identities, checkout paths, clone state, and canonical manual order.
- Last user message is the default sort. Ranking includes accepted queued input
  before provider execution, and later assistant/tool activity cannot outrank an
  existing user-input date. Created at ranks by the newest nonarchived conversation
  in each project. Empty projects use their available project timestamps; legacy
  projects without dates retain their relative canonical order. Dated ties use
  localized title and stable identity. Search and archived-view filters do not
  rewrite the activity score.
- Switching sort modes retains the exact saved Manual order. Moves require
  Manual mode and the current expected project order; stale moves are rejected
  without partial reordering. Native multi-row moves commit one complete order.
  Preferences and rename/order mutations use journal events with command receipts
  and transaction rollback. Default-expanded/default-activity preferences and
  absent legacy project dates decode without synthetic migration timestamps.
  Storage version 8 prevents older binaries from dropping the new state.
- `COINCIDE_RENDER_ORGANIZATION=1 swift test --no-parallel` passed all 197 tests:
  166 core, 4 terminal, 13 Markdown, and 14 native UI/store tests. Coverage includes
  user/assistant/queued dates, newly created threads, archived exclusion, invalid
  dates, stable fallbacks/ties, Manual round trips, multiple-index moves, rename
  validation, deduplication, concurrent/stale commands, malformed preferences,
  atomic rollback, restart, projection rebuild, and storage 7 → 8 compatibility.
  A gated provider regression confirms queueing changes activity ranking while
  leaving the active run and transcript intact, then drains that queue normally.
- Native packaging/launch, strict deep signature verification, and bundled-font
  runtime verification passed. A private backup preceded the actual storage
  migration from 7 to 8. Canonical JSON comparison confirmed the existing
  3 conversations and 25 messages were unchanged, with old project dates unset.
- Offscreen AppKit captures at 280 and 340 points were inspected in light/dark
  appearance. Headers, layout, and row presence are visible. The light selected
  row appears black, and some SF Symbols stay dark. These captures do not establish
  whether that is a capture limitation or a live rendering issue. Live contrast,
  pointer drag behavior, menus, and keyboard interaction remain
  unverified while the desktop is locked; no production palette workaround was
  added to conceal that verification limit.

Logical checkout grouping, project removal/cleanup, and the other remaining areas
in `PORTING.md` are still required for full T3 Code parity.

## 2026-10-22 — managed native New Project

- Added a focused-window New Project sheet and File/sidebar actions. Creation
  runs off the main actor, while existing workspace commands remain usable.
  A single journal command saves the prepared project and first conversation
  together; invalid starters, duplicate paths/identities, and command collisions
  leave the existing workspace intact. The first conversation uses the created
  folder, and saved titles/drafts survive restart and projection rebuild.
- Managed folders live under Coincide's application-data `Projects` directory.
  Folder names follow the pinned upstream NFKD/ASCII slug rules, 64-character
  truncation, reserved-name suffixes, and up to 100 atomically claimed collision
  candidates. Display names remain intact, with the upstream 200-UTF-16-unit limit.
  Unicode line separators are rejected; emoji ZWJ sequences remain valid.
  Existing files, directories, and symlinks are preserved.
- Git initialization respects `init.defaultBranch`, falling back to `main`.
  Coincide generates its own README and SVG icon, force-stages those two paths
  despite global ignore rules, then attempts `Initial commit`. Git identity,
  hooks, and signing settings are retained. Missing identity, failed signing or
  hooks, and commit timeout produce a visible Project Created warning with a
  usable repository; they do not offer a second Create action for that result.
- Git mutations explicitly target the new `.git` and worktree, and inherited
  Git directory/index/config overrides cannot redirect staging into another
  repository. Diagnostics are bounded and URL credentials are redacted. Setup
  failures report the preserved folder for recovery. Shutdown cancels owned
  creation tasks before draining accepted workspace commands; a cancelled setup
  never registers an unfinished project. Cancellation after registration has been
  accepted does not undo a saved project or delete its files.
- `swift test --no-parallel` passed all 172 tests: 143 core, 4 terminal,
  13 Markdown, and 12 native UI/store tests. New real-Git fixtures use isolated
  identity/global configuration and cover starter content/commit, configured
  branches, global ignores, missing identity, signing/hook/timeout warnings,
  collision exhaustion, concurrent claims, unsafe inherited Git context,
  cancellation, and recovery paths. The cancellation fixture observes its hook
  process exiting; it does not require a killed hook to write a final marker.
  A store test opens the same folder during creation and confirms registration
  refusal preserves the already-open project and prepared files.
- Light/dark offscreen AppKit captures of the native sheet and commit-warning
  content were inspected. Native packaging/launch, strict deep signature checks,
  and bundled-font runtime verification passed. Storage remains at version 7;
  canonical JSON comparison confirmed the existing 3 conversations and 25
  messages were unchanged. Physical menu, keyboard, and sheet interaction still
  need an unlocked desktop. Live signing-provider interaction and behavior under
  an active same-user process replacing project directories remain unverified.
  Timeout tests do not establish complete arbitrary hook-descendant cleanup.

Project rename/removal, collapse, sorting/reorder, hosting/publishing, and other
remaining work in `PORTING.md` are still required for full parity.

## 2026-10-22 — native background repository cloning

- Added a native Clone Repository sheet, focused-window File command, sidebar
  status, and conversation progress/cancel/retry controls. A project and its first
  conversation appear after one atomic journal/outbox commit, while Git runs
  separately. Drafts remain editable, submitted turns retain their configuration
  and attachments, and no provider or workspace terminal starts before the
  checkout is ready. Other projects remain responsive during a gated clone.
- Clone attempts use distinct private staging folders and never replace an
  existing destination. Git runs with a retained checkout directory as its working
  directory; metadata uses retained directory handles. Identity checks surround
  completion-marker writes and exclusive promotion. Gated tests replace the
  checkout, staging folder, or parent while Git runs, and verify writes stay in the
  original checkout and replacement folders receive no completion marker.
  These checks do not claim atomic source-identity protection against an active
  same-user process swapping paths between the check and rename.
- Cancellation stops the owned Git process group and awaits cleanup. A lost-child
  observation disables all later signals and closes only owned pipe readers;
  a regression reaps the fixture child early while another helper retains its
  pipes, then verifies no process signal was attempted. Bounded backpressure
  preserves raw stderr chunks before CR/LF parsing and URL redaction. Stress
  fixtures exercise 40,000 progress frames, split UTF-8, oversized remote noise,
  cancellation under continuous output, and stalled progress.
- Unexpected FIFO metadata and lock files fail promptly without being removed.
  Directory descriptors are kept above standard input/output descriptors before
  spawn actions; that closed-stdio edge was source-reviewed, not tested by closing
  the shared test runner's descriptors. Existing Git credentials and SSH setup are
  retained; interactive credential prompts are disabled. Password/userinfo HTTP
  URLs and query/fragment sources are rejected before journal or outbox persistence.
- Retry uses a fresh attempt and preserves previous staging folders. Coincide
  does not delete partial files, although Git may roll back its own failed clone;
  partial network transfers are not resumed. Late Cancel and restart first inspect
  local ownership/completion evidence. Restart never reruns a lost clone or sends
  waiting messages automatically. Explicit Cancel holds queues even if the clone
  finished at the same moment. Stale attempt callbacks cannot alter a retry.
- `swift test --no-parallel` passed all 148 tests: 122 core, 4 terminal,
  13 Markdown, and 9 native UI/store tests. Real Git fixtures clone isolated local
  bare repositories and file URLs, including paths with spaces. Engine/store
  tests cover queue order, captured options/attachments, failure/retry, held
  queues, restart, completion recovery, privacy, and atomic effect-ID collisions.
  Light/dark offscreen AppKit captures of the sheet and six progress/error states
  were inspected. Native packaging/launch, strict deep signature verification,
  and bundled-font runtime verification passed. A private backup preceded the
  actual workspace migration from storage 6 to 7; canonical JSON comparison
  confirmed all 3 existing conversations and 25 messages were unchanged.
  Physical menu, sheet, and keyboard QA still needs an unlocked
  desktop; live SSH/HTTPS authentication and network recovery remain unverified.

This establishes native background cloning, not full T3 Code Git parity.
Managed New Project, project organization/removal, PR/stack/host integrations,
checkpoints, and broader worktree lifecycle behavior remain open.

## 2026-10-22 — native Git branches and synchronization

- Replaced the HEAD-dependent status read with a single NUL-delimited
  [porcelain v2](https://git-scm.com/docs/git-status#_porcelain_format_version_2)
  snapshot. Empty repositories, detached HEAD, missing upstream commits,
  ahead/behind counts, rename paths, submodules, and conflicts now have explicit
  native state. Nested project folders resolve repository-relative paths against
  the actual worktree root, including roots and filenames containing newlines.
- Added native initialization, branch creation/switching, remote branch tracking,
  fetch, clean fast-forward pull, and explicit single-branch push controls. Pull
  overrides rebase/squash/autostash configuration; divergence leaves the current
  commit intact. Push overrides mirror configuration and uses an explicit refspec,
  with force updates and automatic tag propagation disabled. Pre-push hooks remain
  active. Existing credential helpers and SSH configuration are reused; secrets
  are not copied into app settings, and URL userinfo/query/fragment are removed
  from error messages.
- Git mutations share a cancellable FIFO keyed by the common Git directory, so
  linked worktrees and multiple windows serialize their operations. Literal NUL
  path input prevents pathspec expansion and command-line-size limits. Unstaging
  an initial file removes only its index entry, preserving newer worktree bytes.
  Repository initialization refuses an existing or containing repository.
- Native inspector state survives switching panels and is owned by the workspace.
  Application shutdown cancels and awaits its mutation, status, and diff tasks.
  A regression cancels a commit while its hook is waiting and verifies that no
  commit was made and staged file bytes remain. Another cancels a waiting push
  hook and verifies that no remote branch or tracking configuration was created.
  Cancellation now consistently surfaces as `CancellationError` in CommandRunner.
- Real Git tests use isolated local bare repositories and two working copies.
  They cover initial commits, modified initial-file unstaging, literal magic-like
  paths, nested roots, renamed/newline paths, detached state, preserving edits on
  checkout failure, remote tracking, fetch/pull/push, divergent history, conflict
  resolution, mirror/force/matching/tag configuration, remote names containing
  equals signs, deleted tracking refs, hooks, cancellation, and queued mutations.
  These tests do not establish live SSH/HTTPS authentication or network recovery.
- `swift test --no-parallel` passed all 120 tests: 97 core, 4 terminal, 13 Markdown,
  and 6 native UI/store tests. The Git inspector/store tests exercise initialization,
  staging, first commit, branch switching, recoverable errors, and app shutdown.
  Light/dark offscreen AppKit captures were inspected at 280- and 420-point widths.
  Native packaging, launch, strict signature checks, and bundled-font runtime
  verification passed. Physical menu, sheet, and keyboard interaction still needs
  unlocked-desktop QA.

Clone/progress/retry, PR/stack/host integrations, checkpoints, worktree cleanup and
setup, automatic-pull policies, and comprehensive network/credential recovery
remain open Git parity work. No external repository was used by these fixtures.

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
