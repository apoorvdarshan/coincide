# Rust / GPUI rewrite

This is a replacement implementation in progress, not a replacement release.
The running Swift application and its data remain authoritative until cutover.
The new desktop uses `Coincide Rust`, a separate data directory and control socket.
Do not point both applications at one mutable data store.

## Acceptance checklist

Percentages in progress reports are estimates of verified feature parity, not
percentages of source lines rewritten. An implemented but untested item remains
unchecked. The following inventory is based on the macOS README, app structure,
provider protocols and CLI command parser. Expand it when another behavior is found.

- [x] Rust workspace and independent GPUI macOS build.
- [x] Initial Linux desktop compilation (no GUI acceptance yet).
- [x] Native Windows desktop compilation (no GUI acceptance yet).
- [x] Lossless source-file capture and transactional thread import.
- [x] Preserve unknown fields, attachments, drafts and provider session references.
- [x] Rollback invalid/duplicate imports and refuse symlink traversal.
- [x] Display imported conversations in the macOS preview.
- [ ] Match the existing macOS app's UI and UX in Rust: window/sidebar layout,
  typography, spacing, colors, icons, transcript/composer, panels, menus, dialogs,
  shortcuts, focus, scrolling, loading/error states and accessibility. Verify
  equivalent screens and interaction flows side by side before migration.
- [ ] Complete projects, bots and projectless-chat navigation.
- [ ] Search, pin/archive, multi-select, undo/redo and snooze parity.
- [ ] Fully selectable, virtualized transcript, markdown, media and previews.
- [ ] Composer: attachments, context, file mentions, slash commands and drafts.
- [ ] All six agent providers, account selection and model catalogs.
- [ ] Streaming, approvals, user questions, plan/full-access modes, cancellation.
- [ ] Resume, mid-thread handoff, steer, queue, fork, rewind and edit/resend.
- [ ] CLI/API command parity, thread-scoped access and machine-readable errors.
- [ ] Terminal PTY, tabs, splits, selection and shell integration.
- [ ] Git diff, checkpoints, worktrees and hosted change-request operations.
- [ ] GitHub PR workspace, reviews, exact-head merge and mentions.
- [ ] Browser profiles, tabs, downloads, frames, agent bridge and human handoff.
- [ ] Password managers, imports, autofill and passkeys.
- [ ] Computer-use bridge and permissions.
- [ ] Scheduling, approval cards, busy-thread behavior and persistence.
- [ ] Bots, instructions, task records and CLI-session import.
- [ ] Dictation and transcription settings/providers.
- [ ] Usage/limits dashboard and histories.
- [ ] Settings, shortcuts, themes, localization and accessibility.
- [ ] Background agent host, keep-awake, power helper and appshots.
- [ ] Notifications, remote companion connectivity and iCloud alerts.
- [ ] Signed packaging, updater, rollback and installation/distribution.
- [ ] Real-account acceptance, full test parity and data cutover rehearsal.
- [ ] Remove superseded Swift/C++ desktop implementation and build tooling.

## Current parallel checkpoint (2026-11-05)

Overall verified macOS parity remains approximately 30%. Windows/Linux feature
parity and existing-macOS UI/UX matching remain open acceptance milestones.

All seven first-round worker slices and their delivered follow-ups are integrated.
The broad feature groups above remain open until their complete behavior passes.

| Owner | Verified evidence | Current work / remaining acceptance |
| --- | --- | --- |
| Terminal | Native Mac scroll/selection/alternate-screen checks; Windows ConPTY/control and GPUI compilation pass | Thread-cached tabs/splits, mode-aware input and native IME callbacks mounted; 18 focused tests pass; native IME/shell/Windows GUI acceptance pending |
| Browser | Private WebKit fill passed 11 native fixture groups; upload/private-channel synthetic coverage passes | Windows uploads, broader browser parity and real-account acceptance remain |
| Organization | Native Codex/Claude picker import, stale SHA refusal and read-only protection passed; bot edit/draft persistence passed | Saved-bot new conversation/focus, empty native state, retained editor draft and frozen instructions passed native fixtures; real provider acceptance pending |
| Credentials | Native synthetic WAV insertion preserved Unicode selection and did not send; microphone converter/lifecycle fixtures pass | Gated microphone controls mounted; six fake workflow tests and feature-on converter/lifecycle fixtures pass; real vault/passkey/model/mic acceptance absent |
| Workspace | Native exact whitespace/Unicode transcript copying and composer/terminal isolation passed; fake-gh metadata and URL copy passed | Durable write service and native confirmation transport mounted; 131 combined desktop tests pass; fake-process service validation and native write confirmation acceptance remain separate |
| Host | Serialized notification runtime fake tests pass; native adapters compile | Settings bridge mounted; default-off foreground native-clear issue corrected with regression fixtures; native delivery/remote/iCloud remain |
| Packaging | 22 archive tests per supported host and real Mac ZIP/DMG payload readback passed | Concrete HTTPS/ZIP staging service passes 17 Mac fixtures and strict core Clippy; signatures, install, rollback and release readiness remain open |
| Coordinator | Pushed checkpoint 6830a05 passed all five Rust CI jobs and archive validation; later desktop batch passes 148 tests, updater 17, terminal rendering/PTY 16 and legacy image module 8; Linux final core snapshot passes 369 outer-harness tests | Full UI/UX parity remains open; command palette/terminal mounts and native action acceptance still need a pushed checkpoint; full UI/UX parity remains open |

The latest five native acceptance groups used isolated fixture data and fake
provider/gh/Whisper processes. Import sources stayed unchanged, imported execution
was refused, bot edits survived restart, and WAV insertion left transcript item
counts unchanged. Copy checks preserved selected spaces and Unicode exactly and
preserved real source newlines without adding block separators. The evidence is
in `NATIVE_ACCEPTANCE.md` and `acceptance-report.json` under the retained local
`coincide-native-ui3-1i2rd94e` fixture directory. The synthetic app was stopped;
existing Swift and ordinary Rust preview instances were preserved. These results
do not establish full transcript virtualization, real inference or live GitHub
write acceptance.

Candidate6 (`ccb2fe0`, binary SHA256
`28df2a05ddc8990647c2e3a72a4be04339569417f26d36b501265f6b401ad94d`)
then passed three additional scoped native groups: creating an empty saved-bot
conversation and focusing its composer without sending; preserving unsaved editor
text and the frozen instructions after later edits; passive notification and
gated microphone Settings presentation. Notification Enable/Allow/Refresh were
not invoked. Microphone controls were visually disabled and nonactionable in the
accessibility readback; the driver's enabled-state predicate was unavailable, so
that predicate is not claimed as passing. The source acceptance gate remains false.
No native capture, TCC request, notification delivery or real provider call ran.
The synthetic app stopped and existing Swift/Rust instances stayed alive.
Evidence: retained local `reports/native-candidate-6-acceptance.md`.

The new GitHub service records durable mutation intent before dispatch and retains
non-consuming results/history across restarts and heads. COMMENT binds a commit
but explicitly discloses GitHub's current-head race; approval/request-changes are
unavailable. Merge uses synchronous REST with an exact SHA condition and fresh
preflight, avoiding CLI queue/auto-merge behavior. Unknown/uncertain results lock
the PR and cannot be retried or cleared by this implementation; history lookup is
not a reconciliation/unlock facility. The private ledger path comes from the
trusted Rust data directory, never request JSON. Initialization requires a distinct
native first-setup action; missing/corrupt prior storage never triggers recreation.
All write validation so far uses fake processes, not real GitHub operations.


Windows Core CI at f9e0ca0 passed the real ConPTY and private-pipe integration
targets, then failed a long-path Git worktree test. The fix distinguishes long
destination support from Git for Windows' unsupported long working directory. At 1e5387e, the full Windows core job passed (219 reported
test successes, zero failures) including the four Git integration cases, plus the
real PTY/control targets. Native Windows GPUI compilation also passed in that run.
The diagnostic job preserves the original full-suite failure while exposing PTY/control targets independently.

The private macOS credential bridge uses named isolated-world WebKit argument
objects, document/origin/deadline binding and a final native permit check. Revocation
prevents dispatch; already-dispatched renderer work cannot be retracted. Eleven
native WebKit fixture groups passed; supported Mac builds now advertise the
native approval workflow. Visual approval and integrated console-suppression
acceptance remain pending. These tests used no real vault,
provider account, model inference or microphone. Native transcript copy acceptance now covers whitespace-only and partial Unicode
selection plus complete-message copy and focus isolation. Cross-message and
offscreen selection acceptance remain open.

Checkpoint 1e5387e passed all five Rust CI jobs: core on Mac/Linux/Windows,
macOS GPUI build and native Windows GPUI check (run 42023874869). Windows
reported 219 test successes with no failures/ignored/filtered, including real
ConPTY, control pipe and the four Git integration tests. This is compile/test
coverage; no Windows desktop GUI launch or distribution acceptance is implied.

The next combined Linux source snapshot (base fd65284 plus bot persistence)
passed 312 reported test successes and strict core clippy. Bot-local name/persona
edits preserve the imported envelope and unknown fields, use a full-document
baseline and compare again in one Store transaction. No linked/global instruction
files are writable through these endpoints. That earlier snapshot did not activate bots. The later integrated Engine validates
locally authorized immutable bot snapshots before every fresh/resumed provider turn;
synthetic process fixtures cover activation, with real-provider acceptance pending.

## Verified so far

2026-11-05 checkpoint: approximately 30% of the macOS replacement is verified.
This remains a planning estimate; the broad acceptance groups above stay unchecked
until their complete behavior is accepted. Mac is the first release target; Linux
currently supplies additional build/test capacity and portability feedback.

The first Mac preview compiled and rendered imported data. Its isolated database
captured 71 threads / 569 source files (220,682,918 bytes); no source files were
written. This is a per-file capture while the legacy app remains active, not a
transactionally consistent snapshot of an entire running application. A final
quiesced capture and verification are required at cutover.

The Linux host compiles the GPUI desktop and runs the portable test suite and strict
clippy checks. The suite covers transactional schema migration, literal Unicode
search, retained unknown fields, real PTY I/O, Codex/Claude/ACP fixture subprocesses,
multi-turn engine integration, process-group cancellation, and timezone/DST/cron
calculations. Real provider accounts have not been exercised yet.

The Mac preview's native WebKit browser passed manual API/CLI checks against a local
fixture: navigation, reading, text entry, clicking, password-input refusal, hidden
page access, and cross-thread tab isolation. Visual inspection caught and corrected
a toolbar overlap; the address field follows navigation. API controls also changed
the selected provider and persisted drafts. Subsequent native accessibility actions
verified Allow once, selecting a question option and Submit answers against a local
provider fixture, with the completed result read back through the API. Request action
footers remain visible while long details scroll. Buttons and inputs appear in the
accessibility tree after initialization; full keyboard/accessibility acceptance is
still outstanding.

The previous portable batch passed 97 tests with strict core clippy, including actual
headless CLI/server restart persistence, real PTYs, schedule execution through fake
providers, draft preservation during scheduled sends, safe image normalization and
provider image delivery. Mac GPUI compilation passes. Native image thumbnails and
Send were checked against a synthetic provider. Native schedule approval and Run now
completed while preserving an unsent text/image draft. Visual acceptance exposed a
clipped schedule action row; the schedule view now uses the full panel, preserving
the hidden composer state. No real provider account has been accepted yet.
Checkpoint `a294263` passed all applicable GitHub checks. The following feature
batch passed 116 portable tests, strict core clippy and Linux desktop compilation;
one additional Grok completion regression passed separately on both hosts (117
unique tests validated). Mac focused image/Grok/download tests and GPUI compilation
passed. Native fixture checks verified a hidden WebKit download with exact bytes
and private permissions, styled terminal cells, and terminal creation/selection/close.
Checkpoint `cdbeb48` passed every applicable GitHub check. The next parallel batch
passes 142 portable tests, strict core clippy and both Mac/Linux desktop builds.
Native WebKit checks verified nested frames, editing/select/click, sensitive-field
refusal, scrolling, cross-origin refusal and stale ancestor handles. Native settings
Light/Paper changes persisted and survived restart. Native queue pause/resume and
settled-turn forks passed. macOS CI exposed reverse-DNS blocking in the synthetic
OpenCode HTTP fixture; checkpoint `49d6ba0` removes that lookup and passes the full
Rust GitHub workflow.

The next navigation/browser batch passes 147 portable tests, strict core clippy and
Mac/Linux desktop builds. Native checks verified isolated console capture/clear,
selector/text/frame waits and tab-close cancellation, selected-element reads and
pagination. Native projectless filtering/collapse, rename, snooze/unsnooze,
archive confirmation/restore and edit-message branching passed. Stable thread/item
accessibility IDs replace recycled transcript action IDs. Checkpoint `85cbae1` passed every applicable GitHub check, including Swift CI.

The following Cursor/terminal batch passes 167 portable tests, strict core clippy
and Mac/Linux desktop builds. Mac-focused Cursor and terminal fixtures pass.
Native Cursor selection persisted; terminal Select All/Copy/paste excluded concealed
text and a new tab cleared the selection. Checkpoint `0cae281` passed every applicable
GitHub check after correcting Windows path-prefix validation. No real Cursor account
or provider network call was used.

The current scheduling/composer/Antigravity batch passes 194 portable core tests,
strict Linux core clippy and a macOS desktop build. Antigravity synthetic tests
cover isolated runtime/profile copies, explicit account configuration, approvals,
questions, account-specific sessions and file callbacks. A review fix preserves
existing file permissions during atomic writes and creates new files privately;
focused Mac/Linux regressions cover it. No real account authentication was tested.
Native acceptance verified creating a selected-days schedule in Asia/Kolkata and
saving it as pending approval without execution. All seven recurrence kinds have
editor regression coverage. Image paste/drop and full-message copy are implemented
but native acceptance remains pending. Antigravity desktop setup/sign-in controls,
API-key accounts and Windows runtime support remain pending. This batch still needs
its own GitHub CI; the overall verified parity estimate remains approximately 30%.

CI now uses sparse Rust checkouts and compiler-aware cache fallbacks across lockfile
changes. Rust-only files are excluded from Swift's change classifier; changes to that
classifier itself still run Swift CI. Existing test/lint/platform coverage is retained.
Baseline Rust runs 41991737611 / 41993318402 took 293 / 73 seconds overall.
For checkpoint a294263, successful GPUI jobs took 29 seconds twice, compared with
62 seconds for the earlier warm GPUI job. One intervening attempt failed downloading
a GitHub action because codeload.github.com DNS failed; its failed job was rerun.
Core timings varied and coverage increased, so these observations do not establish
an overall pipeline speedup percentage. Continue independent work while CI runs.

Implemented foundations are deliberately narrower than full feature groups:

- Shared CLI/API supports project CRUD, settings-document patches, thread actions,
  Codex/Claude/Grok/OpenCode/Cursor selection, pending approvals/questions, and explicit responses.
- Browser has a separate persistent profile and thread-scoped tabs. Cross-origin frame actions,
  uploads, passwords, passkeys, dialogs, screenshots and native-key actions
  still need implementation. Existing Swift browser profiles are not migrated. Native downloads have bounded,
  thread-scoped session history and private verified destinations on Mac. Linux
  downloads fail closed because upstream shared-profile callbacks misattribute tabs.
  Progress/cancel/resume, blob downloads and persistent history remain. Same-origin
  nested frames have expiring handles; read/click/input/type/scroll reject stale
  ancestors. Native srcdoc navigation works while public navigation stays HTTP(S).
  Console captures bounded primitive-only diagnostics with per-tab clearing. Native
  nonblocking waits support selectors/text/same-origin frames with bounded timeouts;
  closing a tab cancels its waits. Reads report truncation and invalid pages.
- Terminal has real PTYs, native create/select/close tabs and a styled desktop grid. API clients can request
  paged RGB/style/cursor snapshots (at most ten rows); plain polling stays lightweight.
  The desktop assembles coherent revision-matched pages, capped at 40 visible rows.
  Visible-page selection/copy supports drag, Shift-click, keyboard extension and
  Select All; output/tab/page changes invalidate selection. Copy preserves wide and
  combining characters and soft wraps, masks concealed text, and checks revisions.
  Native Select All/Copy/paste and new-tab clearing passed. Scrollback selection,
  drag autoscroll, splits and shell integration remain.
  Candidate child processes cannot inherit the running Swift conversation's bindings.
- Claude and generic ACP protocol adapters have fixture coverage. ACP is not exposed
  as a named provider until its launch/account/mode integration is implemented.
- Scheduling has validated persisted models, recurrence calculations, CRUD APIs,
  durable claims, native approval cards and restart recovery. Approved schedules
  execute while the Rust engine is running, defer busy threads once, and record
  completion/failure/interruption without resubmitting a durable claim. Scheduled
  sends preserve unsent text and image drafts. Imported Swift approvals cannot
  authorize Rust execution; imported thread execution still requires a fork.
  Native creation currently exposes once/interval; richer recurrence editing and
  complete legacy scheduling UI parity remain.
- Grouped project navigation includes an explicit projectless filter, collapse,
  rename, snooze/unsnooze and archive confirmation/restore. Snooze dates are cached
  transactionally in schema 3; filtering avoids decoding entire transcripts.
  Collapse/filter preferences remain session-local; multi-select and undo remain.
  Project selection and existing-folder registration are in the preview. Bounded
  background Git status/diff, file listing and text-file reads are available through
  API/CLI; Git mutations, worktree/checkpoint UI and provider context injection remain.
- Images import asynchronously through API/CLI or a native file picker. PNG/JPEG/
  GIF/WebP originals are copied privately; a static normalized image is capped at
  2000 pixels per edge and 3,750,000 bytes. Draft removal preserves stored files.
  UUID/path/symlink and content checks precede provider delivery and thumbnails.
  Claude/Codex and generic ACP image transport have fixture coverage; HEIC/TIFF,
  PDFs, image editing, clipboard/paste/drop and broader media parity remain.
- Six legacy providers have a filesystem-only discovery catalog. Discovery does not
  verify authentication, versions, models or runtime support; Codex/Claude/Grok/OpenCode/Cursor are
  connected in the preview. Grok authentication, resume, explicit models, images,
  questions/approvals, plan capture and cancellation have synthetic fixture coverage;
  real accounts, usage/effort and background-task UI remain unverified. OpenCode
  owns an authenticated loopback HTTP/SSE server, verifies its PID, strictly resumes
  sessions, streams, asks approvals/questions, sends images and cleans up on Stop.
  Reconnection/backfill, pooling, dynamic models/accounts and plan controls remain. Successful native sessions record transcript progress;
  subsequent provider handoffs include missed messages/images within bounded limits.
- Cursor uses a private per-thread profile and in-memory environment authentication.
  Model settings and checkpointed native sessions are copied without modifying the
  original profile; live WAL/journal sources are refused. Synthetic fixtures cover
  resume, exact model confirmation, approvals/questions, cancellation, provider
  errors and Engine routing. Keychain/file login reuse, Windows private-session
  resume and richer Cursor extension presentation remain unsupported.
- Text follow-ups persist in a bounded queue and execute in order after successful
  turns. Stop/failure/save failure pause the queue; restarts require explicit Resume.
  Uncertain dispatches become interrupted, never automatically replayed. Provider
  selection changes block queued delivery. Native queue controls preserve drafts
  until enqueue succeeds. Queued images, steering and interrupt-and-send remain.
- Forking can select a settled turn; editing a user message creates a separate
  branch with its draft/images restored. IDs are regenerated, runtime references
  cleared, and original history preserved. This does not rewind files or providers.
- Native settings wire system/light/dark appearance, 19 legacy theme choices,
  conversation font/size/alignment/reasoning and Return behavior. Unknown settings
  remain preserved. Full settings, localization and accessibility parity remain.
- Transcripts use a virtualized list with validated image previews, but selectable
  text and full media behavior remain unfinished.

## Data boundaries

- Original file bytes remain in `original_files`; working threads are separate JSON
  documents in SQLite. Unknown fields are retained when supported fields change.
- Imported provider sessions cannot execute in this preview. Forking creates a
  separate native session, so the preview cannot attach to the live Swift session.
- The import captures root JSON, threads, attachments, imported session sources,
  checkpoints and task records. It does not yet migrate browser cookies/keychain,
  runtime processes/sockets, all provider account files or remote device state.
- A snapshot is not proof of restored functionality: UI features need their own
  parity checks even where their original bytes have been preserved.
- The iOS companion remains SwiftUI; this desktop rewrite does not remove it.

## Development

Use a session-specific `CARGO_TARGET_DIR` outside the repository. Mac builds run on
Mac; portable validation and Linux compilation run over SSH on the ASUS Omarchy
host in `~/coincide-work/rust-gpui-checkout`, reusing the build cache in
`~/coincide-work/rust-gpui-rewrite/target`. No user data is copied to Linux.

```sh
cargo build -p coincide-desktop
cargo test -p coincide-core
cargo run -p coincide-core --bin coincide-store -- import SOURCE NEW_DATABASE
cargo run -p coincide-core --bin coincide-rs -- help
```

For a running preview, `coincide-rs browser THREAD_ID '{"action":"read"}'` runs a
bounded browser command and collects its asynchronous result. `provider THREAD_ID
claude`, `pending THREAD_ID`, and `answer THREAD_ID REQUEST_ID ANSWERS_JSON` use
the same dispatcher as the GUI. Imported threads must be forked before execution;
forks explicitly start in approval/build mode while unsupported modes remain gated.

The CLI talks to the running Rust app's owner-only Unix socket. `coincide-rs api`
accepts one JSON request (`id`, `method`, `params`) on stdin. `capabilities` reports
only implemented commands. `serve` starts the same engine without a GUI. Windows
named-pipe transport, legacy CLI compatibility and broader APIs remain pending.

Headless acceptance uses `coincide-rs serve` with a private
`COINCIDE_RUST_DATA_DIR`; no GUI is required for core tests. Native browser requests
fail explicitly in that mode. `attach THREAD ABSOLUTE_IMAGE_PATH`,
`detach THREAD ATTACHMENT_ID`, and `providers` expose the corresponding API flows.
Use `terminal.read` with `styled:true`, `rowOffset`, and `rowLimit` (1–10) for styled
pages; compare revisions when assembling multiple pages from a changing terminal.

Windows Git path limitation: worktree reservations may create destinations longer
than 260 UTF-16 code units from a shorter source checkout, with `core.longpaths`
enabled for Git. Git for Windows still uses a `MAX_PATH` current-directory buffer;
the Rust launcher therefore explicitly rejects project working directories of
260 or more UTF-16 code units after canonicalization. Such a reserved worktree can
be listed from its source checkout, but opening it as a Git workspace requires a
shorter project path. Device namespaces and path components whose meaning changes
when a verbatim prefix is removed remain rejected. The regression verifies real
long-destination metadata, branch/commit identity and unchanged source files/index;
Windows CI must pass before this fix is considered runtime-verified.

## Latest integration follow-up (2026-11-05)

The snapshot-only command palette is mounted with typed, revision-checked actions
for loaded conversations/projects, Settings, schedules and explicit projectless
creation. Ten model tests pass; native focus/keyboard acceptance is pending.
The terminal workspace now uses cached per-thread entities, tabs/splits, actual
pane focus guards and parser-mode-aware input/IME callbacks. Eighteen focused
fixtures pass; the previous root renderer was removed. Full shell and native IME
acceptance remain separate.

Approved-root historical image inspection/validation/materialization passes eight
synthetic fixture groups and strict core Clippy. It does not yet have the native
root-approval workflow, opaque plan registry, transactional local overlay or
renderer integration. Captured-BLOB restoration and Markdown/audio/video discovery
remain deferred; source files and thread JSON are untouched.

Candidate7 exposed an unreachable GitHub detail action below the viewport. No
fake mutation was sent. Detail actions are now pinned above a bounded scrolling
metadata surface; the correction needs a new immutable native candidate and
confirmation-flow acceptance. Read/ledger initialization passed, but those do
not establish COMMENT or merge UI acceptance.

## Continuing partial-feature closure

The coordinator now keeps explicit active ownership in [PARALLEL.md](PARALLEL.md),
including follow-through through integration, tests, native acceptance and CI.
Workers are reassigned after completing their owned flow; status requests do not
pause implementation.

Strict composer selection/capability validation and searchable Settings are
mounted. Fourteen focused core contract/API tests and 154 combined desktop tests
passed; unsupported stored options are displayed and rejected rather than silently
dropped, and immutable bot choices cannot be edited. Runtime-backed catalog work
is separate and uses explicit refresh only.

The historical-media service's eight initial opener/CAS/receipt groups and strict
core Clippy passed. It uses an existing-only DB connection and a Rust-local overlay;
SQLite may still coordinate WAL sidecars/read marks, so no zero-sidecar-write claim
is made. Native restoration UI and durable recovery ownership remain pending.

Candidate9's synthetic GitHub COMMENT flow passed native cancel, exact summary/body
review, one dispatch per explicit confirmation, success/history persistence,
uncertain outcome locking and restart without resubmission. Palette opening,
Settings routing, Escape restoring composer focus and explicit projectless creation
also passed in a task-only app bundle. Native terminal tests verified independent
pane input, application-cursor framing, keyboard copy/bracketed paste, and a real
macOS dead-key preedit with zero premature PTY bytes followed by one UTF-8 commit.
A split resize feedback loop was found and fixed by retaining the last coherent
frame during resize; a new candidate is required to accept that correction.

## Integrated follow-through batch (2026-11-05)

The prior native acceptance remains valid for its recorded candidates. Full
feature parity is still approximately one-third verified; source delivery alone
never checks a broad row. Current paired source integrates transcript Find and
stable row reveal, browser profiles/password revocation and inspection shielding,
explicit bounded model discovery, inline review threads and historical-media UI.
The combined desktop suite passed 196 tests (171 unit, 10 private-browser integration, nine credential integration and six inline-review integration); native acceptance for these newest flows remains open.

Verified focused Mac checks: historical-media service 10/10, shell parser 8/8,
terminal rendering 20/20, terminal selection 8/8, and GitHub threads Engine routing
4/4. Zsh launch fixture passed; Bash synthetic cwd fixture failed and is assigned
to its owner. Model catalog initially passed 7/8, exposing quadratic partial-frame
scanning; the production fix and an additional work-bound regression are integrated
and passed all nine catalog tests on rerun. Strict core Clippy then found two shell-style issues, assigned to the terminal owner. Newer mounts still require their own combined rerun.

CI at 5a8a806 passed desktop compilation and packaging but stopped all core jobs
at formatting. The two initializer layouts are formatted in the next batch. Last
all-five-Rust-jobs-green remains 4c43fe4. New Linux review-thread validation passed
six fake-process groups plus strict core Clippy on the exact recorded parent453
plus feature overlay, not the newest entire parent.

Candidate10 built from 5a8a806 with the terminal resize fix. Native resize retest
remains unverified: the synthetic app window did not become key, so the existing
visibility guard correctly suppressed the workspace. Foreground retries stopped,
synthetic app quit, and original Swift/Rust apps were preserved. Workflow setup,
transport operations and persisted state checks now prioritize CLI/API/headless
fixtures; physical focus/IME/selection/layout still need brief native checks.

Two additional isolated workers own cross-platform/headless integration and
durable media recovery. Recovery work must preserve every copied identity and
uncertain outcome, verify durable ownership before acknowledging receipts, and
never delete media automatically. Work not yet persisted remains unprotected.

## Follow-through validation update (2026-11-05)

Rust CI run 42045348996 passed all five jobs at exact commit
`276ec83522a0b47dc2e2270ab52abf23338993b3`: core Mac/Linux/Windows, macOS GPUI
build with synthetic feature fixtures, and Windows GPUI check. This checkpoint
precedes the new CLI commits. The subsequent CLI batch passed six focused Mac
fixtures and strict core Clippy at `9a570dd`; its cross-platform rerun is pending.
The exact-ID resolver's full-library response dependency is being replaced with
a bounded scalar lookup; existing green checks do not establish that fix.

Desktop tests at `276ec83` passed 233 tests: 208 unit, 10 private-browser,
nine credential and six inline-review integration tests. Actual historical-media
service completions passed four service-to-durable-recovery tests, preserving
the Store's uppercase thread IDs and requiring exact receipt-token matching.
Computer Use collection-time authority fencing passed nine core tests. These
are synthetic checks, with no live provider, vault or permission effects.

Native candidate13 verified folded-tool and hidden-reasoning Find reveal after
the exact-row anchor fix. Advancing to the far-away match crashed in GPUI with
a duplicate accessibility node ID; that remains a concrete open defect. Native
candidate12 verified the compact composer. Remaining Find, terminal resize and
selection acceptance are not inferred from headless tests. The isolated browser
approval harness compiled; its native control sequence is pending.

Computer Use's bounded mount is delivered for parent registration and testing.
The signed updater helper is under implementation; real shutdown-owner hooks
remain open. Current GPUI offers no supported OS/Dock quit veto. In-flight or
unpersisted media work remains exposed to OS quit/crash; palette/window guards
and the termination observer do not close that gap. Full replacement acceptance,
real-account validation, data cutover and Swift removal remain open.

The subsequent parent batch passes 242 desktop tests (217 unit plus the existing
10/9/6 integrations), including the mounted default-off Computer Use bridge.
Synchronous selection changes revoke prior grants, including A→B→A between UI
polls; two focused tests pass. The stopped-handle error-precedence defect found
by CI at `49dcb71` is corrected with deterministic coverage; eight runtime tests
pass. The bounded scalar resolver passes four core and seven CLI fixtures plus
strict Clippy. ASUS Linux tested exact `bd2296c`: 497 outer tests passed, zero
failed, with nine existing child entry markers ignored; ten visible child
scenario executions are not additional unique tests. Strict Clippy also passed.

The explicitly opt-in updater helper passes 22 Mac and 24 Linux fixtures,
feature-on strict Clippy and explicit helper-bin compilation. No native helper
entry, signing, target replacement or app quit ran. Real launcher/owner wiring
is still pending. Review identified a remaining running-process identity check
to add alongside existing static bundle verification before native acceptance.
All helper checks are now included in core CI without enabling the feature by
default or adding it to packaging inventories.

The dynamic running-code trust adapter now compiles and links on Mac; 26 helper
fixtures, feature-on strict Clippy and the explicit bin check pass. These fixtures
inject independent disk/running identities; no real identity API was invoked.
The pinned GPUI accessibility rollback fix passes three focused headless tests,
including nested transaction rollback and retry, and all 242 desktop tests.
Its standalone test prerequisites and licenses are pinned with the patch.

Current execution constraints: no ASUS/SSH and no Computer Use, foreground
activation, mouse/keyboard input, screenshots or GUI launches. All known task
fixture apps are stopped, Computer Use control is released, and original apps
remain running. Continue source, CLI/API, fake-platform tests and GitHub Actions.
Desktop-only acceptance stays pending until explicitly authorized later.
