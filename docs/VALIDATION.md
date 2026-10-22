# Validation record

## 2026-10-22 — reviewed native checkpoint file restoration

- Ready baseline, post-run and retained earlier observations now offer explicit
  native file restoration in an isolated conversation worktree. The selected
  attempt is exact and independent of the other checkpoint or provider's history
  capabilities. Review shows the checkout, observation time, affected paths,
  bounded current-to-target patch and destructive working/staging/new-file
  warning. Cancel is the default action. Conversation history, settings and the
  latest unsent draft are retained.
- Review prepares a frozen private Git administration/index and an owned shadow
  checkout. Git restore/clean/reset runs only there. Publication requires the
  unchanged reviewed working inventory, configuration, index, HEAD identity,
  directory ownership and exact saved target. Exclusive file publication retains
  displaced original bytes in private recovery storage; index publication follows
  working-file verification. HEAD and branches remain unchanged. Ignored files,
  nested repositories, symlinks, executable modes, empty scopes, outside-scope
  staging and unborn/no-index behavior have real-Git coverage. A direct isolated
  upstream Git probe corrected an invalid test expectation: deleting an untracked
  ignore file in a single clean does not also delete the files it had ignored.
- Accepted intent and outbox are journaled together, and dispatching is committed
  before the sole filesystem writer. Conflicting provider/configuration/removal
  work, dirty editors, active terminals and overlapping conversations are blocked.
  Owned provider/model-discovery connections drain before first write; detached
  closing connections retain their former working directory. JSON-RPC closure now
  awaits its exact native parent process's exit, including caller cancellation.
  This does not establish termination of all provider descendants.
- Local acceptance bridges the asynchronous durable lock across windows. Clean
  editor and Git caches remain read-only through authoritative refresh. A gated
  regression releases an older canceled read after a newer read and proves it
  cannot clear or replace the newer clean document. Deleted clean files close;
  existing dirty buffers are preserved and prevent acceptance.
- Restart never repeats a restore. Accepted undispatched work fails;
  dispatched uncertain work remains held. Inspect Restore State reads the pinned
  owned manifest/lock/completion and can confirm the exact result or untouched
  state. Missing, altered or partial evidence stays unresolved. Explicit Keep
  Current Files releases the hold without restoring or repeating anything.
  Canceled unused reviews remove only sealed scratch; unknown additions,
  interrupted cleanup and all started recovery data are preserved.
- Real production Git through the durable engine verifies Cancel, exact restored
  bytes, staging reset, ignored-file retention, nonignored-file removal, unchanged
  main checkout/HEAD/branches, latest draft and complete conversation/audit,
  journal rebuild, normal-close unused-review cleanup and reopen without replay.
  Gated own/other metadata-close tests prove the old directory remains protected
  through closure. Real process/RPC shutdown fixtures prove the close does not
  return before the exact owned native parent exits.
- Prior commit `22b140ac` [run 39715997685](https://github.com/apoorvdarshan/coincide/actions/runs/39715997685)
  executed 530 production tests and failed two assertions in one project-group
  removal fixture; its GUI job was skipped. The fixture now waits for its exact
  surviving completed run's provider release and terminal post-checkpoint before
  comparing/reopening projections. Its checkpoint policy, assertions and timeout
  budget remain enabled. The local worktree FIFO replay fixture likewise waits
  for both exact completed runs' final observations before comparing projections.
  A legacy migration expectation also advances to storage 18 with the new
  restoration journal field.
- The hosted GUI gate requires all ten workflows, zero failures and zero skips.
  The new workflow uses a native managed worktree, production automatic Git
  checkpoints and a private offline peer that edits only its synthetic README.
  It checks Cancel, real restore loss/preservation, original transcript/draft,
  unchanged source/HEAD, applied audit and reopen without provider replay.
  All original nine workflows remain. Seven GUI-free peer/configuration tests
  pass, and the complete runner compiles. No interactive GUI tests ran locally;
  the native inspector replacement and newest workflows still require an actual
  hosted result. Offscreen 320/680-point reviews and unconfirmed controls render
  and fit in light/dark appearances; 240-point action layout is unverified.
- Final `swift test --no-parallel` passes **575 tests**: 479 Core, 77 native
  UI/Store, six terminal and 13 Markdown, with no compiler warnings. Core
  completes in 117.702 seconds and native UI/Store in 31.565 seconds. Additional
  cancellation/archive/model-change review regressions verify exact unused
  scratch disposal and zero writes. Once acceptance starts, a disappearing review
  cannot dispose its pending action's scratch. A completed restore whose evidence
  becomes a FIFO/directory remains uncertain and retains recovery bytes.
- The repository-owned app packages and launches. Deep/strict app/helper
  signature checks and native math-resource rendering pass. Storage upgrades from
  17 to 18 with the complete canonical workspace unchanged against its private
  SQLite backup: three conversations and 25 messages. No system install or public
  app release was performed.
- After the provider shutdown change, the opt-in installed-Codex history smoke
  passes again in **11.549 seconds**, with two generated-marker turns, exact
  native fork/rewind and independent readback, unchanged Git state, retained
  draft/settings/audit, no unexpected tools/approvals and completed test-native
  archive/local cleanup. This verifies the existing live history flow; it does
  not exercise combined provider rewind plus file restoration.

Current restoration limits are 100,000 nodes, 4 MiB of path names and 512 MiB of
regular-file bytes per working inventory, including ignored files. Whole
repository copying/hashing, special/cross-device files, executable checkout
filters, unsupported sparse layouts and recovery-storage management remain
compatibility limits. Preview is bounded to 1 MiB and 128 leaf pairs with explicit
omission warnings. Inventory limits do not cap transient Git materialization,
conversion expansion or retained recovery storage. Combined provider rewind plus
file restoration, broader provider history and the other areas in `PORTING.md`
remain unfinished. This
milestone does not establish full T3 parity.

## 2026-10-22 — durable native conversation forks and rewinds

- Run History now reviews an exact verified Codex boundary before accepting a
  native Fork After Run or history-only Rewind Before Run. The engine binds the
  complete review to its current incarnation and source fingerprint, journals the
  accepted action and outbox together, and saves dispatching before the sole
  mutating RPC. Repeated acceptance observes the original action. Conflicting
  provider/configuration/archive/removal commands wait; drafts and selection stay
  available.
- Fork uses a fresh target actor and creates a separate conversation with the
  selected run's settings and visible prefix, without changing the source or
  sending a prompt. Rewind retains all messages/run audit with removal markers,
  keeps current settings/draft/attachments, and retires the old event stream.
  Explicit one-time Recall Prompt appends to the latest draft. An older Recall
  cannot run during a newer pending history action.
- Restart never repeats history mutations. Accepted undispatched actions fail;
  dispatched actions become unconfirmed. Read-only inspection resolves an
  uncertain rewind only when the unchanged or expected head is observed twice;
  an unrelated head stays unresolved. Drafting remains available while provider
  work is held. Deterministic engine tests cover lost acknowledgments before and
  after native mutation, reopen, no replay, source preservation, journal rebuild,
  stale reviews and external native changes.
- A held old turn-start acknowledgment exposed an adapter generation boundary:
  successful fork/revert now fences that suspended send before it can restore an
  old active turn ID. The protocol regression releases the old acknowledgment
  after rewind, then verifies the next explicit turn completes normally.
- The installed-Codex smoke uses two synthetic replies in its own Git project,
  production automatic checkpoints, exact native fork/rewind and independent
  paginated readback. Its first live review caught native `/private/var` versus
  app `/var` spelling for the same folder. Metadata ingress now applies the
  app's existing path convention; protocol tests cover snapshot/fork/revert on
  that actual directory alias while preserving wrong-workspace rejection.
- The final opt-in installed-Codex engine smoke passes in **12.008 seconds**:
  both expected replies, distinct native fork identity, exact fork/rewind head,
  independent native readback, preserved source/draft/settings/audit and unchanged
  tracked/untracked bytes, index, HEAD and status. No unexpected tools or approvals
  occurred. Only its two generated native conversations were archived and its
  local fixture was removed after a no-foreign-process proof. Earlier failed
  fixtures were preserved until separate archive and non-use checks permitted
  cleanup; their original failure evidence remains private.
- The cleanup proof excludes only the current test process's own open database
  handles and waits within its existing five-second budget for owned providers
  to drain. Darwin `lsof` can return status 1 with numeric matching PIDs, so such
  foreign matches remain a hold, not a successful deletion proof. Errors,
  nonnumeric output or stderr preserve the folder. A separate real-descriptor
  regression passes in **5.181 seconds**, proving own-handle exclusion, foreign
  holder preservation and clearance after that child exits. This proves directory
  non-use, not independent reaping of every provider descendant.
- Exact `fc869947` [run 39712233248](https://github.com/apoorvdarshan/coincide/actions/runs/39712233248)
  executed 491 production tests and failed two timing fixtures; its GUI job was
  skipped. ACP recovery now waits for the exact completed run's provider release
  and final checkpoint before shutdown, and checks the provider-start effect
  rather than the earlier checkpoint effect. Organization replay waits for its
  exact final checkpoint before comparing projections. Automatic checkpoints,
  assertions and timeout budgets remain enabled.
- The hosted gate now requires all nine real GUI workflows with zero failures
  and skips. The new isolated offline Codex peer persists across fresh processes
  and exercises native Fork/Rewind cancel/confirm, draft recall, reopen, exact
  mutation counts and unchanged Git bytes. The original eight workflows remain.
  The runner compiles and passes deep/strict signature verification; five Python
  fixture/configuration checks, shell syntax and project-plist validation pass.
  No actual GUI tests ran locally. The native inspector replacement still needs
  an actual hosted verdict after the earlier seven-of-eight GUI result.
- Final `swift test --no-parallel` passes **530 tests**: 438 Core, 73 native
  UI/Store, six terminal and 13 Markdown, with no compiler warnings. The Core
  summary completes in 83.612 seconds; native UI/Store completes in 30.266 seconds.
  Default execution does not opt into installed-provider prompts. The separate
  live result above and hosted interactive GUI evidence remain distinct.
- The repository-owned app packages and launches; deep/strict app/helper
  signatures and native math-resource rendering pass. Storage upgrades from 16
  to 17 with the complete canonical saved workspace unchanged against its private
  SQLite backup: three conversations and 25 messages. No system install or public
  app release was performed.

Support remains limited to verified new paginated histories on the reviewed
Codex 0.163.x profile. Filesystem restoration, other-provider/legacy history,
portable transfer and full T3 parity remain open. The provider protocol has no
compare-and-swap history RPC, so another client can still race the final read.

## 2026-10-22 — provider history contracts and durable transcript attribution

- Newly accepted and agent-initiated runs attribute their messages to their local
  conversation/run. Provider replacements cannot forge that reference; existing
  rows, user-echo association, late entity updates, terminal notices and recovery
  preserve it. Earlier transcripts are not backfilled. Verified prefix slicing
  rejects active, unknown, interleaved or unattributed later boundaries and does
  not invent an opening user message for agent-initiated work.
- Journal text-append optimization now requires unchanged run attribution. A
  same-text or appended-text attribution change uses a full message mutation;
  rebuilding the journal preserves the exact resulting snapshot.
- Native history contracts use opaque provider IDs. The reviewed Codex 0.163
  adapter reads bounded paginated summaries, forks an exact inclusive/exclusive
  boundary into a distinct target connection with goal continuation deferred,
  and reverts before a selected turn only on a loaded idle thread with a safe
  goal and an unchanged reviewed head. It verifies the resulting provider
  identity, workspace and head. Unsupported contracts do not drop the boundary.
  An uncertain mutation blocks further writes on that connection and is never
  automatically repeated; read-only inspection remains available.
- Initialization has one shared handshake with independently cancellable waiters.
  An isolated installed-CLI initialize-only check confirmed the actual
  `coincide/0.163.0` server user-agent prefix. It made no thread/model requests.
  New threads explicitly request paginated history only on the reviewed profile;
  existing legacy resume remains unchanged. History handshake errors are generic
  and do not expose the provider's private message/data.
- Deterministic protocol peers test exact request parameters, cursor/page bounds,
  cross-page boundaries, missing/unknown turns, unsafe goals, changed heads,
  unrelated identities, uncertain replies and target adoption. These do not
  establish live provider history mutation or complete provider parity.
- `swift test --no-parallel` passes **491 tests**: 405 Core, 67 native UI/Store,
  6 terminal and 13 Markdown, with no compiler warnings. This includes the
  repaired settlement fixture: it waits for the final checkpoint to finish
  before testing archive/unarchive against a retained provider-close owner.
- The repository-owned app packages and launches; deep/strict app/helper
  signature verification and native math-resource rendering pass. Storage
  upgrades from 15 to 16 with the complete canonical saved workspace unchanged
  against its private SQLite backup: three conversations and 25 messages.
- Exact `c5622dd` [run 39710791452](https://github.com/apoorvdarshan/coincide/actions/runs/39710791452)
  previously failed that one timing boundary in its 460-test production job;
  the dependent GUI job did not execute. The new native inspector replacement
  therefore still requires an actual hosted GUI verdict.
- App-level durable fork/rewind intents, recovery, transcript adoption and native
  controls remain to be implemented. Filesystem restoration and full T3 parity
  remain open.

## 2026-10-22 — automatic run checkpoints and native workspace comparisons

- Newly accepted input captures its checkpoint policy, defaulting to automatic.
  Before provider dispatch, the engine saves an immutable plan and attempts its
  baseline. A non-cancellation failure releases the original accepted payload
  with visible missing evidence. Legacy queued messages retain their absent
  policy without being retroactively changed.
- Completed/interrupted provider boundaries save a final workspace observation
  before the next FIFO message. Failure holds the queue for an exact-attempt
  Retry Current Workspace or Continue Without Snapshot. Retries retain earlier
  attempts and label their later observation; they never replay provider work.
  Failed, unknown, app-lost and never-dispatched runs record unavailable final
  evidence instead of inventing a successful capture.
- Incarnation/run/stage/attempt/path/plan fences protect asynchronous results.
  Stop, archive, removal and shutdown drain owned work outside the command inbox.
  A second canceled baseline cannot join its own drain. Restart performs bounded
  inspection only, does not replay provider work/captures or resume the restored
  FIFO, and a late inspection cannot override a newer explicit resume intent.
- Successful receipts bind a bounded scratch manifest by SHA-256. Cleanup checks
  retained directory anchors, exact file identities/content and known entry sets
  before unlinking only the temporary alternate index/private Git admin. Unknown,
  replaced, modified or locked entries are preserved. Matching durable markers
  permit partial cleanup to resume. Saved refs, objects, plans and receipts remain
  usable, including after cleanup and restart; legacy unproven scratch is kept.
- Unused executable filter settings, including global Git LFS configuration, no
  longer reject ordinary repositories. Actual driver use is checked against the
  frozen private admin/index before and after add, using bounded real/scratch
  inventories and literal attributes. Selected executable drivers remain omitted
  and unsupported. Fixtures prove missing-attribute fallback, staged ignored
  additions, removed real-index entries, configuration changes and attribute-only
  races cannot execute a filter or publish an unsupported capture.
- Native controls expose policy, preparation, queue holds, later-observation
  retries, preserved attempt status and bounded read-only Workspace Changes.
  Captured drafts, settings and selection survive reopen. Sixteen offscreen
  banner/history/diff/unavailable renders at 320/680 points in light/dark were
  inspected for readability and overflow. They do not establish interactive GUI
  or keyboard behavior.
- A real-Git engine fixture proves the baseline is ready before provider send,
  final receipt precedes second FIFO dispatch, scratch is removed, diff survives
  reopen, and working bytes/real staging remain unchanged. Focused Core execution
  passes **49 tests**, including cancellation/recovery, cleanup and filter races.
- Final `swift test --no-parallel` passes **460 tests**: 374 Core, 67 native
  UI/Store, 6 terminal and 13 Markdown, with no compiler warnings. Native tests
  include real setup/worktree/settlement FIFO using the production checkpoint
  factory and this Mac's unchanged global LFS configuration. Offscreen native split
  tests verify bounded loaded/dirty Files content, divider width restoration,
  retained host/cache ownership and first-responder preservation. These checks
  remain separate from the hosted interactive crash verdict.
- The repository-owned app packages, signs and launches successfully. Deep/strict
  app/helper signature checks and native math-resource rendering pass. Storage
  upgrades from 14 to 15 with the complete canonical workspace unchanged against
  its private SQLite backup: three conversations and 25 messages. No system install
  or public app release was performed.
- Fork, conversation rewind, filesystem restore and full T3 parity remain open.

## 2026-10-22 — strict-eight GUI result and explicit native inspector hosting

- Exact pushed `16b61a4` [run 39707700757](https://github.com/apoorvdarshan/coincide/actions/runs/39707700757)
  passes production tests/package/signatures/resources and **7 of 8 actual GUI
  workflows**, with zero skips (795.343 seconds). Setup (77.360 seconds) and settle
  (99.074 seconds) now pass their exact output/exit/draft checks and explicit
  Continue/Resume actions using the observed native triangle location.
- Files still aborts when opening the inspector. The retained `7483BE6F…ips`
  has the same constraint exception through `NSWindow._postWindowNeedsUpdateConstraints`,
  `SplitViewChildController.hostingView` and `NSHostingView.SizeConstraints`.
  The geometry-bound SwiftUI inspector candidate did not fix the actual crash.
- The next candidate replaces that inspector host with a narrow native
  `NSSplitView` bridge and retained hosting controllers whose intrinsic sizing and
  inner scene bridging are disabled. Existing sidebar, outer toolbar/commands,
  explicit inspector toggle, Files/Changes views and shared buffers are retained.
  Actual GUI proof of this replacement is still pending; no test assertion or
  workflow was removed to obtain a passing result.

## 2026-10-22 — inspector constraint boundary and script-output GUI targeting

- Manual strict-seven run [39705334238](https://github.com/apoorvdarshan/coincide/actions/runs/39705334238)
  at `d14b85a` passed five actual GUI workflows and failed two, with zero skips
  (665.317 seconds). Dark/light chat, manual scripts, grouping and worktrees pass.
  The toolbar-overflow script helper and folder-import readiness correction work.
- Files now imports its fixture successfully, then the app aborts at inspector
  reveal. The retained crash is a constraint-update exception through
  `NSWindow._postWindowNeedsUpdateConstraints`, `SplitViewChildController` and
  `NSHostingView.SizeConstraints.update`. Moving the inspector to the outer
  navigation host did not resolve it. The next controlled candidate keeps native
  inspector chrome while bounding asynchronous Git/file content to the allocated
  geometry, so its intrinsic minimum cannot grow the split host. A new offscreen
  regression checks unloaded/loaded files and a dirty editor at 280/360 points;
  this does not establish an actual GUI crash fix.
- The setup workflow reaches reviewed execution and the real exit status 7.
  Retained video/AX show the default disclosure click hits label text and leaves
  the native triangle collapsed. Setup and settle now click the observed triangle
  relative to its AX frame, require expanded state 1, and keep the exact output,
  exit, draft, checkout and source-byte assertions. No retry or assertion removal
  substitutes for expansion.
- Hosted proof of these two changes remains pending. The strict gate still
  requires all eight actual workflows with zero skips.
- The updated strict-eight runner compiles and passes deep/strict signature
  verification without executing GUI tests locally. Packaging/launch, app/helper
  signatures and native math-resource loading pass. Storage upgrades from 13 to
  14 with the complete saved workspace unchanged against its private SQLite
  backup: three conversations and 25 messages.

## 2026-10-22 — isolated native Git checkpoint primitive

- A read-only prepare step pins workspace/repository/admin/common/object directory
  identities, HEAD, effective configuration and the real-index revision. Capture
  uses one exclusive private ref and a separately owned alternate index. An owned,
  drained successful command path writes the completion receipt; a ref or orphaned
  process alone never proves completion. Retry cannot overwrite an incomplete
  attempt, and completed capture is idempotent.
- Snapshot staging uses frozen private Git configuration, sparse/ignore/attribute
  sources and the anchored original object store. Global/system/legacy config,
  hooks, fsmonitor, external diff/text conversion, replacement refs and lazy fetch
  cannot supply implicit execution. Preexisting executable clean/process filters
  fail visibly; a gated clean/process configuration change during add cannot run
  its sentinel. New private refs never change the branch, HEAD or real index.
- Real Git fixtures cover dirty/staged/untracked/deleted and ignored files, unborn
  repositories, modes, symlinks, literal/newline names, nested and linked worktree
  scopes, split indexes, ordinary/manual flags and cone sparse/full indexes.
  Sparse rules distinguish missing included manually skipped files from excluded
  entries. Auxiliary global/info ignore and attribute behavior is tested separately.
  Cancellation, changed ownership/configuration/HEAD/index, collisions, forged
  receipts, late ref/mapping changes and redacted bounded diffs also have coverage.
- Compatibility limits remain explicit: non-cone sparse and executable filter
  drivers are unsupported; modern Git with `--no-lazy-fetch` is needed. Auxiliary
  files are capped at 128 KiB each, the real index at 64 MiB and Git configuration
  and ordinary command output at 4 MiB. Operations have a 60-second budget with
  30-second command limits; diff defaults to 1 MiB and permits up to 8 MiB. Failed
  attempts and private indexes are preserved. Capture is not a transactional lock
  against another process changing working files while Git reads them.
- Automatic run integration, checkpoint UI and restore remain pending. No user
  checkout was captured, restored or deleted during this milestone's fixtures.
- Final focused run passes 32 declarations across Core and native UI/Store,
  including all 20 checkpoint declarations and parameterized race/compatibility
  cases. Full `swift test --no-parallel` passes **427 tests**: 345 Core, 63 native
  UI/Store, 6 terminal and 13 Markdown, with no compiler warnings. This includes
  the inspector size-boundary and completion-only Codex regressions.

## 2026-10-22 — durable per-run history and native inspection

- Newly started user turns retain their exact captured configuration and user
  message reference. Agent-initiated foreground work has its own origin and never
  creates a fake user prompt. Observed adapter turn references survive completion;
  they are not treated as proof of native provider fork or rollback support.
- Queue advancement closes the previous record before opening the next. Approval,
  Stop, forced runtime closure, start failure, provider failure, connection loss,
  unknown stop reasons and application restart retain distinct outcomes. Stale
  scoped events and repeated completed activity cannot reopen or rewrite a run.
  Legacy transcripts remain unchanged without guessed historical boundaries.
- Codex completion-only notifications retain the actual completed turn reference
  even when both its start notification and start response arrive later or not at
  all. The late-acknowledgment protocol fixture also covers this ordering.
- Seven focused Core test declarations cover these transitions, legacy recovery,
  journal reconstruction and invalid boundaries, including parameterized failure
  and ACP activity cases. The existing real-engine FIFO test also verifies the
  completed run settings, user references and rebuilt projection.
- The workspace menu opens a read-only native Run History sheet. Three native
  cases check captured settings, mixed/unknown history, agent-managed model
  options and small-sheet geometry. Light/dark offscreen renders at 320 and 560
  points were captured; recorded, mixed and legacy states were visually inspected.
  This is separate from actual hosted GUI execution.
- The serial run-history suite passes **406 tests** (325 Core, 62 native UI/Store,
  6 terminal and 13 Markdown). The separate checkpoint primitive was excluded
  while it was still under development. No compiler warnings were reported.
- Fork, rewind, filesystem restore and automatic per-turn checkpoints remain
  separate work; the history sheet performs none of those actions.

## 2026-10-22 — explicit settlement generations and reviewed cleanup scripts

- Native workspace/context/Thread menus offer Settle Conversation with a
  confirmation and default-on settle-script review. Settle requires an idle
  conversation, empty queue, no pending questions and resolved checkout setup.
  Repeating Settle keeps the same generation. Provider idle does not settle it.
- A generation holds provider readiness independently of script exit. Anchored
  discovery selects the first run-on-settle role in a proven separate linked
  worktree; main/shared checkouts and unproven legacy ownership skip it. Command
  review pins the exact configuration and cwd. Changed configuration fails before
  execution; retry creates another reviewed run. The async flag remains a setup
  setting and does not release a settled conversation.
- Retained setup jobs and prior cleanup for the exact thread drain before settle
  discovery. Scoped cleanup joins cover archive/unarchive followed by Settle,
  including an already-closing idle provider. Unrelated threads stay responsive.
  Resume or new user input drains the generation's owned script jobs before
  clearing its gate and starting captured FIFO messages. A later Stop preserves
  the paused queue when cleanup completes; explicit Resume Queue releases it.
- The shared runtime uses a typed setup/settlement owner, per-run output and
  incarnation fences. Script exit remains separate from job lifetime. Archive,
  removal, shutdown and restart retain those ownership rules. Interrupted cleanup
  never replays after restart, and an unstarted review can resume without running.
  Existing manual terminal tabs stay open.
- Seventeen focused Core settlement cases and four new native Store/view cases
  pass alongside the existing setup coverage. Native cases run actual temporary
  Git worktrees and helper commands, including TERM-ignoring background jobs,
  two output listeners, automatic input-driven Resume, captured models/permissions,
  changed commands, fresh review, restart, main-checkout skipping, unsent drafts
  and preserved source files. The confirmation and exact-command review were
  inspected in light/dark offscreen renders; small-display geometry passes.
- Full `swift test --no-parallel`: **396 passed** (318 Core, 6 terminal,
  13 Markdown, 59 native UI/Store). The eight-workflow actual GUI runner compiles
  and passes deep/strict signature verification without launching local GUI tests.
- Packaging/launch, deep strict app/helper signatures and native math-resource
  loading pass. Storage upgrades from 12 to 13, preserving the complete saved
  workspace against its private SQLite checkpoint: three conversations and
  25 messages.
- An eighth actual GUI workflow covers native confirmation/default review,
  both Cancel paths without execution, exact command/cwd, first-role execution,
  exit/output while still settled and explicit Resume with the same draft,
  thread, checkout and source bytes. Its strict gate requires all eight workflows
  and zero skips; actual hosted execution remains separate from local build proof.
- Automatic inactivity/PR settlement, snooze settings and idle-terminal closure
  remain pending.

## 2026-10-22 — reviewed checkout setup and provider readiness

- Worktree requests persist the setup-review choice before Git starts. Discovery
  reads the ready checkout's anchored configuration and selects the first
  run-on-create role. It captures a complete plan for explicit native review;
  Cancel never starts it. Missing roles skip setup, while malformed or changing
  configuration requires a visible retry/continue decision. Reusing the main
  checkout skips the role, including when the source is a linked checkout.
- Files and Terminal use checkout readiness independently of the provider gate.
  Blocking setup releases captured queued messages only after actual exit 0;
  asynchronous setup requires a durably recorded startup acknowledgment. Later
  asynchronous failure does not cancel provider work already accepted.
- The Core owns one raw-output consumer and the managed job across windows.
  Bounded Unicode text snapshots fan out to independent listeners without storing
  raw output in the workspace journal. Stop, Continue Without Setup, Retry,
  archive, removal and shutdown drain the owned session; a closed output snapshot
  cannot precede that drain. Retry creates a new run and review. Restart marks
  uncertain work interrupted and never replays the command automatically.
- Sixteen focused Core cases pass, including exact approval, first-role selection,
  blocking/async readiness, FIFO provider settings, commit failure before launch,
  claimed-outbox recovery, retained background jobs after exit 0, held cleanup,
  Stop followed by removal/shutdown, archive/unarchive/retry joining an existing
  drain, no-runtime log closure, stale owner IDs and main-checkout reuse. Three new native Store/view cases pass with actual local
  Git worktrees and the native helper executable: two-window output/cleanup, real
  exit 7 and environment/cwd, changed configuration, fresh retry, restart review,
  unsent drafts/source-file preservation and small-display form geometry.
- Full `swift test --no-parallel`: **375 passed** (301 Core, 6 terminal,
  13 Markdown, 55 native UI/Store). Offscreen setup-review and worktree-form
  previews were inspected in light and dark appearances. The first light capture
  mixed SwiftUI's light scheme with the host's dark AppKit semantic background;
  scoping the capture window and drawing appearance fixed the harness. The
  focused render check passes again; no product colors changed.
- The repository-owned app packages and launches with deep strict signature,
  separate helper signature and native math-resource checks passing. Storage
  upgrades from 11 to 12, with the entire saved workspace unchanged against its
  private SQLite checkpoint: three conversations and 25 messages.
- CI run `39701358026` at the preceding helper-only commit failed compilation
  under Apple Swift 6.3.3 before tests could execute. The local Swift 6.4 compiler
  accepted C argument-vector inference that the hosted compiler rejected. The
  helper and launcher now use explicit String and C-pointer array types, with an
  unambiguous filesystem path. All 375 local tests pass again; the seven-workflow
  native runner also compiles and verifies its signature. Exact-head hosted
  compilation then succeeded in run `39703856781`. Its setup Store test failed
  because the default Codex executable was absent on the runner, so the Store
  rejected input before reaching the injected provider. A four-line fixture fix
  at `d14b85a` saves/selects a synthetic ACP executable (`/usr/bin/true`); the
  injected peer still owns protocol behavior and all queue assertions remain.
  Seven focused native setup/settlement cases pass locally with that fixture.
  Hosted push run `39704717961` passes all 375 tests (142.235 seconds), packaging,
  signing and resources. Its fixture-only path filter intentionally skips GUI.
  Manual run `39705334238` records the same immutable `d14b85a` head with the
  unchanged seven-workflow suite enabled; actual GUI results remain pending.
- Actual setup GUI workflow verification remains separate from these focused
  tests. The existing manual script workflow and its terminal ownership remain
  unchanged. Settle/resume generations and settle-script execution remain pending.

## 2026-10-22 — managed native script process primitive

- A separately signed native helper owns a PTY and remains its process-group
  leader after the command shell exits. Actual wait status travels through a
  separate framed status pipe; terminal text cannot impersonate it. Background
  jobs may retain the PTY without delaying command completion. Explicit close or
  authority-pipe EOF stops the owned group and drains transport readers before
  the leader is reaped. Processes that deliberately leave that group are outside
  this ownership guarantee.
- Plans capture the exact script/index, complete configuration revision, anchored
  project/checkout identities and absolute shell. Inherited environment values
  are not serialized in the plan. Preparation validates without running commands;
  a one-shot Start revalidates immediately before descriptor-based cwd handoff.
  Configuration/root replacement rejects execution rather than silently running
  a changed command. Startup handshakes and frames are bounded and versioned.
- Output uses one ordered, lossless consumer with bounded backpressure. Separate
  nonblocking control processing keeps Stop responsive under output pressure;
  closing does not await an arbitrarily stalled presentation callback. Shell
  children do not inherit authority/status pipes or directory anchors. The app
  retains its helper child identity until final group signaling and cleanup.
- The first focused run failed in fixture discovery because Swift's test runner
  executable lived outside the build folder. The fixture now uses the explicit
  checkout/build configuration, and the test target depends on the helper product.
  Removing only the generated helper binary and running ordinary `swift test`
  relinked it. The final fourteen-case focused run passed, covering exit 7,
  background jobs with closed stdio, continuing PTY output after command exit 0,
  owner-loss EOF, root/config replacement, cancellation/input/resize, ordered
  Unicode output, held-consumer pressure, descriptor isolation and strict plans.
  Further cases cover coalesced Stop/Start without execution, unexpected helper
  death without replay, commands that never read pending PTY input, and aggregate
  control-write admission before frame allocation (16 pending writes/1 MiB).
  Write reservations release before completion resumes; close also waits for the
  serial writer barrier. The final focused run passed in 8.317 seconds.
- Full `swift test --no-parallel`: **356 passed** (285 core, 6 terminal,
  13 Markdown, 52 native UI/Store). Packaging/launch, deep strict app signing,
  separate helper signature, bundled-helper executable loading and native math
  resources pass. The complete saved workspace remains unchanged against the
  private checkpoint: three conversations, 25 messages and storage version 11.
- This is a Core process primitive, not yet automatic setup/settle behavior. Native review,
  durable readiness/approval/restart state and app-owned presentation remain
  separate integration work; the existing manual script path is unchanged.

## 2026-10-22 — inspector layout crash investigation

- Hosted run `39697982965` at `8c0df0b` passed four of five actual GUI workflows,
  with no skips. Project scripts completed discovery/Cancel, stale-config rejection,
  Reload, dedicated command cwd/environment/exit status, and running-tab close
  confirmation. Light, dark and grouped-checkout workflows also passed.
- Files/editor testing crashed the app immediately after opening the inspector,
  before its Files control appeared. The crash report and video confirm an app
  failure; changing a test selector would not address it. The main-thread exception
  cycles through AppKit window constraints, SwiftUI toolbar preferences and layout.
  This stack identifies the failing framework path, rather than proving an exact
  source-level cause.
- Commit `076efa3` moves the inspector from a conditional detail split view to the
  stable outer navigation host, preserving its content and existing controls.
  All 342 serial tests pass; packaging/launch, deep strict signing and native math
  resources pass. The entire saved workspace remains unchanged: three conversations,
  25 messages and storage version 11.
- Run `39699162944` at `4e76a90` passed five of six actual GUI workflows, with no
  skips. Files reproduced the same inspector constraint/toolbar crash. The new
  worktree workflow passed its complete local-base/branch/submodule-choice,
  draft/cwd/restart and source-preservation checks (93.905 seconds). Project scripts
  passed again (93.121 seconds). Actual six-test execution took 647.088 seconds.
- The unchanged six-workflow GUI suite in run `39699875038` passed four, failed
  two and skipped none (534.352 seconds). Files stopped before opening the
  inspector: the combined readiness predicate timed out, while the exported
  native location, screenshot and accessibility diagnostic showed the requested
  folder with Add Project enabled and hittable. Scripts stopped because Run Script
  had moved into the native toolbar overflow, visible in both pixels and the
  accessibility tree. No inspector execution occurred, so this run does not
  establish whether the layout change resolves the crash.
- Harness navigation now waits for the observed native folder-location value
  before directly asserting Add Project's enabled/hittable state, and follows
  the actual toolbar overflow when Run Script is hidden there. Existing workflow
  assertions remain. A seventh workflow adds reviewed setup/Cancel, exact command
  and cwd, first-role execution, exit/output, explicit Continue and retained draft
  and source checks; the result gate rejects fewer than seven tests or any skips.
  Its execution allowance is 20 minutes, reflecting the earlier six-workflow
  647-second test-only duration plus the new workflow and complete Files body.

## 2026-10-22 — explicit submodule initialization for new worktrees

- New worktree requests capture an explicit None/top-level/recursive choice. None
  remains the native default; old requests, ownership records and completion
  receipts decode without enabling downloads. Retry preserves the captured mode.
  Registered-worktree reuse rejects initialization and remains read-only. Storage
  version 11 prevents older apps from ignoring a selected preparation stage.
- Initialization follows successful owned checkout creation and precedes the
  final completion receipt and eligible queued provider start. It uses the new
  checkout, pinned regular `.gitmodules` bytes (up to 256 KiB), an unchanged index, captured Git
  administration/common-directory ownership, and `--checkout` without force,
  remote-update, reset or source-submodule mutation. Final synchronous config
  revalidation rejects a replacement during awaited policy/mapping reads; this
  does not claim filesystem locking against arbitrary external writers.
- Only standard transports allowed by effective Git policy and any inherited
  allowlist can run. File transport requires explicit allowance; arbitrary/ext
  helpers and configured custom update commands cannot execute. Planning,
  checkout creation and completion inspection continue to deny transport access.
  Development regressions use private nested local repositories and gated wrapper
  processes, with no real remote requests.
- Normal initialization failures/timeouts/output limits persist one fixed generic
  warning with a usable checkout. The warning remains visible after restart and
  contains no raw Git output, URL or configuration value. Cancellation, changed
  configuration and lost ownership preserve partial files without a completion
  receipt; their queues stay held. Explicit reuse/new selection remains necessary
  for an unproven partial attempt rather than replaying Git over retained files.
- Five new primitive cases cover mode/legacy/policy validation, None/top-level/
  recursive nested checkout contents and source dirty-file/HEAD preservation,
  custom-update/ext-helper rejection, warning recovery, owned cancellation, and
  config replacement during policy discovery. An engine case checks held FIFO
  readiness and persisted warning recovery. The existing native Store workflow
  now carries top-level selection through real Git, queued settings and restart.
- A committed gitlink without `.gitmodules` initially returned success without
  trying the selected initialization. The regression fails before the fix; missing
  pinned configuration now requires proven absence and still invokes Git, whose
  normal failure becomes the generic warning. Ordinary repositories remain no-ops.
- The sixth hosted GUI workflow exercises the native worktree sheet, explicit
  older local base/new branch, safe default and all mode controls, retained draft,
  native readiness, actual new cwd/HEAD/content, restart reuse and unchanged source
  HEAD/dirty/untracked files. It is separate from the immutable five-test run on
  `8c0df0b`; compilation alone does not establish its runtime result.
- Final `swift test --no-parallel`: **342 passed** (271 core, 6 terminal,
  13 Markdown, 52 native UI/Store). All six Xcode GUI methods compile, the runner
  passes deep signature verification, and Python CI configuration checks pass 3/3.
  Packaging/launch, deep strict app signature and bundled math-font rendering pass.
  Migration to storage 11 preserves the entire canonical user workspace against
  its private storage-10 backup, including three conversations and 25 messages.

## 2026-10-22 — explicit native project scripts and process pipe isolation

- Native discovery reads the current checkout's anchored `t3.json`, capped at
  256 KiB, with the pinned declaration schema, comments and trailing commas.
  Eight core cases cover strict known types/null rejection, ordered duplicate
  declarations, literal strings, malformed JSON, size/depth limits, file revisions,
  contained links, special files, cancellation and root replacement. Foundation's
  decoder accepted a malformed repeated-comma fixture; grammar validation now
  rejects it before normalization. Diagnostics do not include configuration values.
- The native sheet displays the chosen command and checkout. Explicit Run checks
  the displayed file revision and script, fresh anchored root metadata, captured
  conversation incarnation and current window ownership before synchronous PTY
  creation/registration. Replacing the root during a gated read preserves both
  folders and launches nothing. Removal/re-add and switching away/back invalidate
  old actions even when a surviving owner keeps the same file session. Removal and
  shutdown cancel and drain late reads. These checks do not claim cross-process
  locking against an external filesystem mutation after the final check.
- Script tabs receive literal shell-command arguments and T3 project/worktree
  environment values, retain output and exit status, and preserve the draft,
  provider/model settings and existing terminal tabs. Setup/settle/async/preview
  fields remain data: discovery does not run commands or open URLs. Eight native
  Store/process workflows and two command-terminal cases use controlled local
  shells and private fixtures; none submit a provider turn.
- Hosted worktree-head run `39696929949` failed the existing terminal-removal
  fixture at its 60-second limit and resumed after its unrelated 120-second child
  exited. Native GUI execution was skipped. Investigation found inheritable
  Foundation pipe descriptors: a new deterministic test failed before the fix
  because a terminal child kept another process's stdin open, and passed after
  setting close-on-exec on all six provider pipe descriptors. Pipe setup and the
  app's native terminal fork now share a short synchronous lock. This proves the
  inheritance defect; its exact interleaving in the hosted failure is inferred.
  The unchanged removal fixture passes locally with CI's serial settings.
- `swift test --no-parallel`: **336 passed** (265 core, 6 terminal, 13 Markdown,
  52 native UI/Store). The five-method Xcode runner builds and passes deep signature
  verification; Python CI configuration checks pass 3/3. A fifth actual GUI workflow
  covers discovery/Cancel, changed-config rejection/Reload, explicit command cwd/env
  and exit status, and running-tab close confirmation with retained drafts. The
  strict hosted gate requires all five actual tests and zero skips; compilation
  does not establish their runtime result. Hosted execution remains pending.
- `./script/build_and_run.sh --verify` packages and launches the repository-owned
  app. Deep strict signature and bundled math-font rendering checks pass. Storage
  remains version 10, with the entire canonical user workspace unchanged against
  its private checkpoint, including all three conversations and 25 messages.

## 2026-10-22 — durable native worktree preparation

- Worktree choices now save an intent and target cwd before asynchronous local Git
  resolution. A second durable stage saves the immutable plan before Git mutation;
  readiness, the prepared target, and the first eligible FIFO provider effect commit
  together. Queued turns preserve provider/model/permission/ACP/attachments. Retry
  changes only their cwd/native-session fields when assigning a fresh destination.
  Old provider session IDs cannot resume in the newly selected checkout.
- Native choices cover a new branch with an explicit local base, an existing local
  branch, and registered local-branch worktree reuse. Git inventory parses NUL
  fields, including newline paths and lock reasons. Actual inventory normalizes
  macOS `/private/var` and `/var` aliases consistently; lexical validation still
  rejects traversal, empty components, remote URLs, and credential-bearing URLs.
  The first real-Git run exposed the alias mismatch; this was corrected without
  relaxing repository or inode containment.
- Plans capture source/admin/common-directory and parent identities and a pinned
  commit. Git commands use captured repository binding and an owned process group
  with bounded output, timeouts, cancellation, and exit/pipe draining. A gated
  linked-source `.git` replacement verifies that neither repository nor destination
  is mutated. Exclusive managed destinations and sibling ownership records prevent
  overwriting retained folders; reuse verifies registration, common directory,
  checkout/admin identities, and backlinks.
- Automatic completion requires a durable receipt written only after owned Git
  exits successfully, plus exact pinned HEAD and matching ownership. A running
  post-checkout hook cannot satisfy completion. If a crash precedes that receipt,
  registration alone remains unproven and preserved; explicit verified reuse can
  accept it later. No branch reset, worktree deletion, pruning, or missing-base fetch
  is performed. Git may clean its own unfinished files when cancelled.
- Cancel and restart hold queues. Startup publishes interrupted state immediately,
  then runs owned read-only completion probes in four lanes. A gated probe proves
  load and unrelated provider commands remain responsive. Attempt/incarnation and
  removal fences reject late results and old begin intents even after same-ID
  re-add. Failed empty setup can choose another worktree; previous attempts remain
  journaled. Manual path edits cannot invalidate a preparation record.
- Checkout changes reject unsaved file edits and conversation terminal tabs across
  all registered windows. Running commands remain open for explicit closure.
  Synchronous preflight locks the old path through intent commit/application, and
  terminal creation rechecks its captured conversation path/attempt. Regressions
  preserve a dirty completed-worktree editor and both window terminal owners,
  retain unrelated terminals, and reject a stale terminal action after transition.
- Eleven primitive cases, thirteen engine cases, and four native Store workflows
  cover real Git bytes/receipts, source edits/untracked sentinels, new/existing/reuse,
  aliases/newline paths, replacement/FIFO/containment, cancellation, queued settings,
  corrected setup, restart windows, background recovery, stale owners, transaction
  rollback, dirty buffers, and terminal ownership. No installed provider model turn
  or local interactive GUI was used for these new cases.
- The full suite passed 318 tests: 257 core, 4 terminal, 13 Markdown, and 44 native
  UI/store. The 31-case focused worktree run also passed. Packaging/launch,
  strict deep app/runner signing, bundled-font rendering, GUI-runner compilation,
  and all three CI-configuration tests pass. A private SQLite backup precedes the
  storage 9-to-10 migration; canonical comparison confirms the entire existing
  workspace, all 3 conversations, 25 messages, and project fields are unchanged.
- Hosted run 39694657397 at `288000b` passed all three actual GUI workflows with
  zero failures or skips: full light/dark and complete grouped/separate checkout,
  three drafts, restart/selection, group rename, Cancel, and confirmed group removal.
  The fourth Files/editor/content-search/reference/unsaved-Quit workflow is now
  compiled with a strict four-test gate; its actual hosted execution remains pending.

Full T3 Code parity remains incomplete; see `PORTING.md` for the remaining areas.

## 2026-10-22 — native external-editor handoffs

- Added the pinned editor catalog and native Xcode support, local preferred-editor
  settings, explicit file/result/checkout actions, and separate Finder reveal.
  Discovery inspects application metadata and contained launchers, including
  stable/Insiders separation, versioned JetBrains bundles, and Antigravity IDE
  versus Hub. It does not execute PATH wrappers. Bundle identifiers and launcher
  layouts were checked against current Homebrew package manifests; this is not
  vendor-signature validation or proof every installed editor works.
- Existing file/directory metadata uses anchored descriptors without reading file
  contents. Binary files and internal links are supported; escaping links, special
  files, replaced roots, and unavailable owners are rejected. The selected bundle
  and captured workspace owner are rechecked after asynchronous preparation and
  immediately before synchronous submission. Native buffers remain unsaved and
  unchanged; external apps receive the saved disk version. Native actions pass a
  line, without asserting cross-editor Unicode column conventions.
- Launch Services completion errors reach the caller. CLI argument vectors remain
  literal; detached children use null standard streams, are reaped on exit, and
  never receive Coincide timeout/shutdown signals. A synchronous request returns
  its completion receipt before any await, preserving the final ownership boundary.
  Accepted external apps and delayed completion remain independent of later
  cancellation, removal, and shutdown. Pending preparation cancels; shutdown drains
  the actual shared discovery scan even after its callers have detached.
- Eight core and ten UI/store regressions cover catalog/position/argument rules,
  fixture-bundle discovery and replacement, metadata containment, preference
  fallback, dirty buffers, same-ID owner replacement, shared-root survival, final
  target revalidation, completion failure, concurrent discovery/cancellation, and
  shutdown before and after handoff. An initial shared-waiter test exposed a wait
  on the uncancelled common task; per-caller continuations now release cancelled
  waiters while retaining the underlying scan's independent ownership and drain.
  No installed editor, Finder window, or local interactive GUI was launched.
- The full suite passed 290 tests: 233 core, 4 terminal, 13 Markdown, and 40 native
  UI/store. Packaging/launch, strict deep app signing, bundled-font rendering, and
  all three CI-configuration tests pass. Canonical comparison confirms the existing
  3 conversations, 25 messages, and non-identity project fields are unchanged;
  storage remains version 9. The GUI runner compiles and passes strict deep
  signature verification without local interactive execution.
- Hosted run 39693126654 passed both complete light/dark workflows. Grouping
  passed checkout creation/preferences and draft capture, then XCTest could not
  click a visible native OutlineRow. Retained screenshot/accessibility evidence
  shows its identified title inside the row. The harness now clicks that visible
  title and requires the actual row to become selected; all three workflows remain
  required, with complete grouping GUI verification pending the next hosted run.

Full T3 Code parity remains incomplete; see `PORTING.md` for the remaining areas.

## 2026-10-22 — native workspace content search

- Added whitespace-preserving literal/regex search with case and Unicode whole-word
  options. Matches use one-based lines and original UTF-16/end-exclusive ranges.
  Whole-word filtering handles letters, marks, numbers, underscore, astral scalars,
  punctuation-edged adjacent matches, and later accepted candidates after rejected
  raw matches. Zero-width regex matches are bounded and excluded in whole-word mode.
- Path and content searches share fresh, anchored, ignore-aware discovery: at most
  25,000 entries and a 15-second discovery budget. Content matching has a cooperative
  250-ms budget, at most 500 matching lines, 100 lines per file, 100 ranges per line,
  1 MiB read per file, 32 MiB aggregate reads, and 16,384 UTF-16 units per line.
  Binary/malformed prefixes consume the read budget before exclusion. Large-file
  prefixes contribute complete lines only. Every omission or exhausted budget is
  reported through `truncated`; queries are never written into diagnostics.
- Native ICU regex compilation failures return a generic visible error with no
  pattern or raw Foundation diagnostic. SDK-supported progress callbacks, per-line
  checks, and owned task cancellation provide cooperative interruption. The
  pathological-pattern regression checks partial-result behavior under the test
  framework timeout; it does not prove a specific callback interleaving or a hard
  real-time deadline. Native regex/fallback semantics are not fff compatibility.
- The inspector adds Paths/Contents, Match Case, Whole Words, and Regex controls.
  A lazy native list groups and highlights matching lines. Opening a result targets
  its captured file, line, and UTF-16 range, with existing dirty-buffer confirmation.
  Same-file navigation retains unsaved edits. Search generations and complete
  request/options fence late results; superseded reads/scans cancel and drain before
  a replacement starts. Same-file navigation cancels and fences an older pending
  other-file open while retaining its shutdown drain. A held real-read completion
  verifies that the latest navigation and subsequent dirty edit cannot be replaced.
  Watch refreshes preserve conversation and dirty editor state.
- The full suite passed 272 tests: 225 core, 4 terminal, 13 Markdown, and 30 native
  UI/store. Thirteen new core cases cover Unicode/CRLF/case folding, literal spaces,
  word filtering, regex/zero-width/privacy, Git ignores, file/line/range/result and
  byte budgets, special files, cancellation, root replacement, and pathological
  regex. The new offscreen UI test checks actual NSTextView selection after an
  emoji and retains dirty text, drafts, provider, selection, and source-file bytes.
  All prior file/walker/read and Git regressions pass. No local interactive GUI test ran.
- Hosted run 39691871298 passed both full light and dark workflows, including
  restart, draft persistence, warning text, Cancel, confirmed removal, and original
  Git files. The grouping workflow reached checkout menus but XCTest rejected a
  207-character path passed to its convenience identifier lookup (128-character
  runtime limit). Exact property predicates replace that lookup; full grouping
  GUI verification remains pending. All three workflows remain required.
  The passing warning checks do not establish that the OCR fallback ran; the
  exported result contains no OCR attachment for those successful checks.
- Packaging/launch, strict deep app/runner signing, bundled-font rendering,
  GUI-runner compilation, and all three CI-configuration tests pass. Canonical
  comparison confirms the existing 3 conversations, 25 messages, and non-identity
  project fields are unchanged; storage remains version 9.

Full T3 Code parity remains incomplete; see `PORTING.md` for the remaining areas.

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
