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

## Verified so far

2026-11-05 checkpoint: approximately 24% of the macOS replacement is verified.
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

The current portable batch passes 97 tests with strict core clippy, including actual
headless CLI/server restart persistence, real PTYs, schedule execution through fake
providers, draft preservation during scheduled sends, safe image normalization and
provider image delivery. Mac GPUI compilation passes. Native image thumbnails and
Send were checked against a synthetic provider. Native schedule approval and Run now
completed while preserving an unsent text/image draft. Visual acceptance exposed a
clipped schedule action row; the schedule view now uses the full panel, preserving
the hidden composer state. No real provider account has been accepted yet.
Checkpoint `fd2b758` passed every applicable GitHub check; the next checkpoint's CI
result must be verified after push.

CI now uses sparse Rust checkouts and compiler-aware cache fallbacks across lockfile
changes. Rust-only files are excluded from Swift's change classifier; changes to that
classifier itself still run Swift CI. Existing test/lint/platform coverage is retained.
Baseline Rust runs 41991737611 / 41993318402 took 293 / 73 seconds; two post-change
runs are required before attributing a speedup to these changes.

Implemented foundations are deliberately narrower than full feature groups:

- Shared CLI/API supports project CRUD, settings-document patches, thread actions,
  Codex/Claude selection, pending approvals/questions, and explicit responses.
- Browser has a separate persistent profile and thread-scoped tabs. Frames,
  downloads/uploads, passwords, passkeys, dialogs, screenshots and native-key actions
  still need implementation. Existing Swift browser profiles are not migrated.
- Terminal has a real PTY and monochrome desktop grid. API clients can request
  paged RGB/style/cursor snapshots (at most ten rows); plain polling stays lightweight.
  Styled desktop rendering, selection, splits, tabs and shell integration remain.
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
- Project selection and existing-folder registration are in the preview. Bounded
  background Git status/diff, file listing and text-file reads are available through
  API/CLI; Git mutations, worktree/checkpoint UI and provider context injection remain.
- Images import asynchronously through API/CLI or a native file picker. PNG/JPEG/
  GIF/WebP originals are copied privately; a static normalized image is capped at
  2000 pixels per edge and 3,750,000 bytes. Draft removal preserves stored files.
  UUID/path/symlink and content checks precede provider delivery and thumbnails.
  Claude/Codex and generic ACP image transport have fixture coverage; HEIC/TIFF,
  PDFs, image editing, clipboard/paste/drop and broader media parity remain.
- Six legacy providers have a filesystem-only discovery catalog. Discovery does not
  verify authentication, versions, models or runtime support; only Codex/Claude are
  connected in the preview. Successful native sessions record transcript progress;
  subsequent provider handoffs include missed messages/images within bounded limits.
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
