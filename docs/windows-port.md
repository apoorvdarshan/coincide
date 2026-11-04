# Windows port: parity and acceptance

Target: standalone, native C++/WinRT + WinUI 3 Windows desktop application. A Mac connection must not be needed to
run agents. This is a full feature-port request, not permission to replace features with a remote-only client or a web shell.
Baseline: the Mac application at `b54ad87`, including the thread-switch and image-click fixes in #229 and #230.

The owner deferred iCloud instruction sync on Windows for this phase. Local/project instructions and Git sync remain
in scope. The owner approved a Windows-compatible offline dictation replacement and an alternative phone-alert
delivery route; neither replacement has been implemented or validated yet. These decisions affect the Windows port.

## Current completion checklist — 2026-11-04

This checkpoint distinguishes combined app validation from isolated module checks. It is an expanded development
build, not a completed or released Windows port. The unchecked parity and acceptance work remains in scope.

| Work | Updated status |
|---|---|
| Last complete integrated Windows test run | **880 automated checks passed**, plus **12 native UI flows, 25 question-form checks and 10 credential checks** on the physical laptop |
| Conversation/project management | Rename, pin, settle, snooze, soft delete/restore, project changes, batch undo/redo, Unicode search, attachments and recoverable outbox implemented; expanded core/store checks pass; new UI-flow verification underway |
| Codex runtime | Model catalogue, explicit model/effort/speed/plan/access controls, FIFO queues, safe steering and Stop/failure recovery implemented; **49 protocol + 63 lifecycle checks pass** |
| Claude runtime | Native stream-json adapter, resume, streaming, approvals/questions and queues implemented; **25 deterministic checks pass**; live account conversation pending |
| OpenCode runtime | Native Windows OpenCode 2.2.5 installed and metadata-only smoke verified; HTTP/SSE adapter has **39 checks passing in the combined app**; app wiring compiles, no live model turn run |
| ACP foundation | Shared Cursor/Grok/Antigravity protocol, scoped filesystem/terminal requests and account-routing guard pass **49 contract checks** in the combined app; providers stay unadvertised until vendor setup/account integration is verified |
| Provider discovery | Native executable validation and bounded metadata probes implemented; **12 checks pass**; unsupported/wrapper-only providers remain explicit |
| Git | Status/diffs, literal-path stage/unstage, commit/push, branches, worktrees and non-destructive checkpoints implemented; **55 Git + 27 subprocess checks pass**; native panel integration underway |
| Rich transcript | Native Markdown/code/link/table renderer is integrated and retains the existing 11 UI regressions; **22 Markdown checks pass**; image/audio/video attachment controls are being validated |
| Provider handoff | Bounded role/provider-preserving reference context implemented; **10 checks pass**; app/provider transition verification underway |
| Terminal | Native ConPTY session and per-thread tab/split UI implemented; **63 VT-screen + 28 native ConPTY checks pass** in the combined build; terminal panel UI acceptance pending |
| Browser | Native WebView2 controller implemented; **23 policy + 7 offline native engine checks pass**; shared-profile default verified; native app panel integration compiles |
| Structured questions | Native single/multiple choice, free text, secret fields and validation implemented; **25 native form checks pass** in initialized WinUI, including radio/custom-text synchronization, immediate Submit, required validation, multiple selection, secret fields and retry |
| Inline HTML/SVG previews | Isolated, network-disabled private preview implemented; **13 policy + 11 native engine checks pass**; app Preview actions compile, combined UI validation pending |
| Scheduling | All recurrence kinds, time zones, approval/recovery/overlap policies and atomic store implemented; **76 core + 70 store + 18 native IANA checks pass**; schedule UI/timer dispatch pending |
| Windows credentials | Windows Credential Manager foundation passes **10 interactive fixture checks in the combined app**; password-manager UI/fill/import integration pending |
| Real signed-in conversations | **Still unverified**. The correct existing Codex account needs interactive password/passkey approval. No approval prompt was sent while the owner is absent. A different saved Google account requested phone verification; that is not the correct-account blocker. |
| Remaining parity | ACP provider setup/account routing, background lifetime, scheduling UI/dispatch, notifications/phone routing, Computer Use, credential UI, instructions/imports/usage, offline voice, complete settings/localization and distribution still need implementation or acceptance |

The 880-check result is one complete combined native build: 153 workspace/process, 22 Markdown, 10 handoff,
63 terminal screen, 76 scheduler, 62 store, 49 protocol, 42 RPC connection, 63 Codex lifecycle, 8 display/media,
55 Git, 12 provider discovery, 25 Claude, 28 ConPTY, 18 IANA calendar, 39 OpenCode, 23 browser policy,
13 preview policy, 70 schedule store/policy, and 49 ACP contract checks. No provider account or model is used.

The earlier media URI and fixture-threading/repaint failures are fixed. Code review also found project-context,
repository-operation exclusion, and drained-event persistence issues; their corrections compile in this build and passed focused review.
Expanded native UI validation passes all 12 flows, including a transient storage-failure recovery regression. The
same interactive run passes 25 question-form and 10 credential checks. No full-parity percentage is claimed.

The previously pushed milestone and CI results are recorded below. The current source checkpoint and checklist are
tracked on `windows-native`; check its new CI result separately from the laptop validation above.

## Previously pushed milestone (4008aa4)

- The native WinUI executable builds on the physical Windows laptop; GitHub Windows runners also compile it.
- All 202 automated checks pass on the laptop: 71 workspace/process, 17 storage, 39 protocol, 42 subprocess connection,
  32 Codex session lifecycle, and one cached-property binding regression check. They do not use a provider account or call a model.
- All eleven native UI checks pass: four long-history/draft checks; Codex Send/Unicode/final-text reconciliation;
  repeated identical replies; command approval denial across thread switching; file approval path/diff display and
  denial; typed question answers; Stop preserving a draft; and duplicate conversation titles.
- A freeze exposed by identical replies is fixed with distinct bindable row identities. Equal display strings no longer
  make WinUI's accessibility sibling traversal revisit the same item. Both transcript and sidebar have regression coverage.
- Cached binding descriptors read the current target instead of retaining an earlier partial reply; the binding regression
  check covers this CI-discovered streaming failure.
- The composer waits for UI completion and transcript persistence before accepting another turn. Native UI checks wait
  for each submitted draft to clear before evaluating its reply, avoiding stale observations from a previous identical reply.
- Screenshots and the native accessibility tree were inspected. Codex turn orchestration and the composer are connected;
  native session IDs persist and resume, and unsupported requests fail closed.
- The native Windows Codex CLI 0.166.0 starts and exposes app-server tooling. A normal app launch reports missing sign-in
  correctly without fabricating output. Correct-account sign-in needs interactive password/passkey approval, so a real account
  conversation remains unverified. See the current completion checklist for newer provider and transcript work.
- The Mac thread-click focus fix passes 16 focused checks. Async-question rendering/answering passes 98 focused checks;
  these fixes are built and pushed but have not been installed into the running Mac app.
- Source is tracked in draft PR #235. Check its current CI result separately from the local results above.

## Platform decisions

No decision below is treated as approval merely because development continues elsewhere.

| Existing implementation | Proposed Windows implementation | Decision |
|---|---|---|
| WebKit browser and preview controls | WebView2, retaining per-thread tabs, profile choices, imports, agent controls and login gates | Asked; pending |
| Keychain and browser encryption keys | Windows Credential Manager/DPAPI; preserve Bitwarden and 1Password CLI integration | Asked; pending |
| SwiftTerm/POSIX terminals | ConPTY-backed native terminal with tabs, splits, and selection context | Asked; pending |
| macOS Accessibility/Screen Recording and bundled Cua Driver | Windows UI Automation and capture with the same permission and per-thread access boundaries | Asked; pending |
| iCloud Drive instruction copies | Defer iCloud sync on Windows for this phase; retain local/project instruction handling and Git sync | Owner deferred; excluded from current Windows acceptance |
| WhisperKit/Core ML and Apple Speech | Windows-compatible offline dictation; retain existing cloud providers | Replacement approved; engine selection, implementation and validation pending |
| CloudKit iPhone lock-screen alerts | Use an alternative phone-alert delivery route; present concrete hosting, account and cost requirements before external setup | Alternative route approved; design and implementation pending |
| launchd background agent host | Windows-owned background process and authenticated local IPC, preserving running sessions across window closure | Must present implementation before replacing behavior |
| pmset/lid/battery helper | Windows power APIs with exact restoration of prior settings | Must present implementation and limitations before changes |
| Developer ID, notarization and app updater | Windows packaging/signing/update path, preserving verified download/install behavior | Signing, distribution and update decisions pending |

## Feature checklist

Source implementation and passing unit tests are distinct from native Windows runtime acceptance. Every row below
needs both the relevant automated coverage and actual Windows verification before claiming parity.

| Feature group | Required behavior | Current state |
|---|---|---|
| Native foundation | Window, resize, DPI, keyboard, focus, accessibility | Initial native window builds and opens on Windows; broader input/DPI checks pending |
| Projects and conversations | Projectless chats, search, rename, pin, archive, settle, snooze, delete, batch operations, undo/redo | Rename, pin, archive, settle, snooze, trash/restore, batch undo/redo, project management and Unicode search implemented; expanded native UI flows pending |
| Persistence | Fast index, lazy transcripts, drafts, crash-safe writes, recovery and forward compatibility | Expanded store passes 62 native checks, including queues, attachments, model preferences and unknown fields; full crash/migration acceptance pending |
| Agents | Claude Code, Codex, Cursor, Grok Build, OpenCode, Antigravity; detect, sign in, catalogs and account selection | Codex, Claude and OpenCode pass combined native fixtures; ACP foundation passes 49 contract checks; vendor/account setup and real sign-in remain pending |
| Model controls | Favorites, hidden models, effort, speed, permissions, plan/build mode, project defaults | Per-provider model preferences and model/effort/speed/plan/access controls implemented; UI integration underway; favorites/hidden models/project defaults pending |
| Streaming runtime | Tools, approvals, questions, cancellation, steering, queueing and background work | Codex/Claude/OpenCode runtimes include queues, approvals/questions and cancellation; Codex steering implemented. Full app UI validation and process-independent background lifetime pending |
| Provider handoff | Per-provider/per-thread session IDs, missed turns, reset/resume behavior and context limits | Provider-isolated native session bookkeeping and bounded role-preserving handoff context implemented; account-switch and app/provider-transition acceptance pending |
| Transcript | Markdown, code, work logs, links, images, audio/video, media opening, previews and copy/selection | Native Markdown/code/link/table and local media controls implemented; existing long-thread regressions passed earlier rich-renderer build; current media URI regressions pass; complete panel/performance acceptance pending |
| Composer | Attachments, mentions, slash commands, quotes, terminal/diff context and per-thread drafts | Send/Ctrl+Enter, Stop, saved drafts, file attachments, queued input, Codex steering and Git diff quotes implemented; mentions/slash commands/terminal selection context pending |
| Git | Status/diffs, stage/commit/push, checkpoints/revert, worktrees and turn diffs | Backend passes 55 Git checks; native panel integration underway; checkpoint restoration/turn-diff acceptance still pending |
| Code hosting | GitHub native PR workspace; other supported forge CLIs/pages, checks, reviews and exact-head merges | Not implemented |
| Terminal | Per-thread terminals, tabs/splits, resize, Unicode, output and process cleanup | ConPTY + native VT-screen/tab/split panel compiles; 63 screen + 28 ConPTY checks pass; panel UI acceptance pending |
| Browser | Persistent/private profiles, tabs, navigation, downloads, history/bookmarks/import, agent API and user handoff | WebView2 shared/private profiles pass 23 policy + 7 native engine checks; native panel compiles; full panel flows, history/bookmarks/import/agent API pending |
| Passwords/passkeys | Approved fill, CSV import, TOTP, Bitwarden/1Password and passkey boundaries | Platform replacement prepared where indicated; complete integration and owner acceptance pending |
| Computer Use | Discover windows, inspect, click/type/scroll, screenshot, permissions and single-thread arbitration | Platform replacement prepared where indicated; complete integration and owner acceptance pending |
| Scheduling | All existing recurrence kinds/time zones, approval cards, missed-run and busy-thread handling | Recurrence/coordinator/store and IANA calendar validated; UI, dispatch and background integration pending |
| Bots | Starter lineup, artwork/personality, project folders and separate histories | Not implemented |
| Instructions | Discovery, global/project masters, local links/copies, Git sync and conflict handling | Implementation pending; iCloud sync explicitly deferred on Windows |
| Usage | Provider account limits, balances, activity, usage/cost scopes and local history | Not implemented |
| Remote/CLI | iPhone/iPad pairing, TLS protocol, controls, alerts/presence and local CLI | Not implemented; preserve protocol compatibility |
| Notifications | Completion/input, activation, dismissal synchronization and phone routing | Alternative phone-alert route approved; implementation pending |
| Voice | Dictation, trigger/insertion, offline models and existing transcription providers | Windows-compatible offline replacement approved; implementation pending |
| Keep Awake | Charger/battery/lid behavior, optional mute/display and restoration | Platform replacement prepared where indicated; complete integration and owner acceptance pending |
| Preferences/help | Appearance, shortcuts/conflicts, languages, About/legal/community links and updates | Not implemented |
| Localization | All 19 existing languages, placeholders/plurals, accessibility and RTL/long-text checks | Shared labels generated; full UI and runtime checks pending |
| Imports | Claude/Codex originals preserved, limits, branch/rollback semantics and duplicate handling | Not implemented |
| Distribution | Reproducible builds, dependency monitoring, security scans, installers and updates | Build/CI foundation in progress; no public release authorized |

## Verification gates

- Core checks: projectless/project threads, drafts, atomic batch archive undo/redo, provider-isolated sessions,
  acknowledged/missed turns, invalid-state rejection and long-history bookkeeping.
- Store checks: round trips, malformed/future files, missing transcripts, Unicode and unknown-field preservation.
- Process/RPC checks: Windows quoting and Unicode paths, separate stdout/stderr, owned-process cleanup, response
  matching, closed/failed channels, explicit approval responses, deadlines and blocked pipe writes. The host owns its
  peer on a dedicated thread; UI callbacks receive UTF-8 values rather than pipe-thread COM/UI objects.
- WinUI checks: switch long mixed threads without scrolling, show the latest rows, resize/reflow, click media,
  copy/select text and keyboard navigation. A successful compile does not satisfy this gate.
- Provider checks: deterministic protocol fixtures and subprocess failure/cancellation tests first. Live provider tests
  use the owner's account and are run only when explicitly authorized, following CONTRIBUTING.md.
- GitHub Windows CI builds/tests every relevant pull request and uploads development artifacts. These artifacts are
  not signed public releases. x64 and ARM64 execution are verified separately.
- The existing Mac/iOS application, protected instruction symlinks, active running app and on-device data remain intact.

SSH access to the owner's Windows laptop has been verified. Remote-desktop access has not been configured.
Do not commit machine addresses, SSH keys, passwords or private connection settings to this document or build scripts.
