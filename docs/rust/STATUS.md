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
| Terminal | Native Mac scroll/selection/alternate-screen checks; Windows ConPTY and control integration each passed 1/1 at f9e0ca0 | Splits/shell parity; Windows GPUI compile job added, first result pending |
| Browser | Native Mac upload fixture passed seven groups; 47 combined Mac desktop tests pass, including 10 private-channel cases | Private isolated-world WebKit fill implemented but capability remains disabled pending native acceptance; Windows uploads unavailable |
| Organization | CLI import Store/API tests passed on Mac/Linux; native preview/import panel mounted with five passing tests | Native picker/confirmation acceptance; bots persistence and native editor underway |
| Credentials | Six native-workflow fixture tests passed; local Whisper subprocess tests passed 5/5 plus strict clippy on Linux at cf90172 | Local transcription UI; real model/microphone, native fill, vault and passkey acceptance remain |
| Workspace | Async checkpoint/worktree panel mounted; seven worker tests pass; exact-copy helper mounted with five pure tests | Native panel/copy acceptance; bounded live GitHub metadata API and panel underway |
| Host | Runtime synthetic tests and four Engine idle-sleep tests passed on Linux; explicit Rust-owned opt-in wired | Native idle-sleep lifecycle acceptance; notifications delivery adapter; privileged power/remote/iCloud remain |
| Packaging | d4a9de5 passed 22 tests per host on Mac/Linux/Windows (DMG explicitly skipped off Mac), plus real store rehearsal; actual Mac ZIP/DMG payload readback verified | Runtime dependencies, signatures, HFS/Finder behavior, launch/install/updater and release readiness remain unverified |
| Coordinator | Full Mac desktop suite passed 47 tests including current import/transcript hooks; Windows long-destination handling corrected with explicit long-cwd limitation | Integrated Linux checks, native acceptance, CI triage and combined UI/UX parity |

Windows Core CI at f9e0ca0 passed the real ConPTY and private-pipe integration
targets, then failed a long-path Git worktree test. The current fix distinguishes
long destination support from Git for Windows' unsupported long working directory;
its Windows CI result is still pending. The diagnostic job preserves the original
full-suite failure while exposing PTY/control targets independently.

The private macOS credential bridge uses named isolated-world WebKit argument
objects, document/origin/deadline binding and a final native permit check. Revocation
prevents dispatch; already-dispatched renderer work cannot be retracted. Capability
remains disabled until native synthetic acceptance. These tests used no real vault,
provider account, model inference or microphone. Copy helper pure tests establish
byte/range handling, not native cross-message or offscreen selection acceptance.

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
