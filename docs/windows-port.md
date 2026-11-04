# Windows port: parity and acceptance

Target: standalone, native C++/WinRT + WinUI 3 Windows desktop application. A Mac connection must not be needed to
run agents. This is a full feature-port request, not permission to replace features with a remote-only client or a web shell.
Baseline: the Mac application at `b54ad87`, including the thread-switch and image-click fixes in #229 and #230.

The owner deferred iCloud instruction sync on Windows for this phase. Local/project instructions and Git sync remain
in scope. The owner approved a Windows-compatible offline dictation replacement and an alternative phone-alert
delivery route; neither replacement has been implemented or validated yet. These decisions affect the Windows port.

## Current completion checklist — 2026-11-04

The completion pass is active. The results below distinguish the latest integrated build from newer modules tested
in isolation. New source in the working tree is being integrated and is not yet a completed or released Windows port.

| Work | Updated status |
|---|---|
| Last complete integrated Windows test run | **430 automated checks passed**, plus **all 11 existing native UI checks** on the physical laptop |
| Conversation/project management | Rename, pin, settle, snooze, soft delete/restore, project changes, batch undo/redo, Unicode search, attachments and recoverable outbox implemented; expanded core/store checks pass; new UI-flow verification underway |
| Codex runtime | Model catalogue, explicit model/effort/speed/plan/access controls, FIFO queues, safe steering and Stop/failure recovery implemented; **49 protocol + 63 lifecycle checks pass** |
| Claude runtime | Native stream-json adapter, resume, streaming, approvals/questions and queues implemented; **25 deterministic checks pass**; live account conversation pending |
| OpenCode runtime | Native Windows OpenCode 2.2.5 installed and metadata-only smoke verified; HTTP/SSE adapter has **36 deterministic checks passing**; full app wiring underway, no live model turn run |
| Provider discovery | Native executable validation and bounded metadata probes implemented; **12 checks pass**; unsupported/wrapper-only providers remain explicit |
| Git | Status/diffs, literal-path stage/unstage, commit/push, branches, worktrees and non-destructive checkpoints implemented; **55 Git + 23 subprocess checks pass**; native panel integration underway |
| Rich transcript | Native Markdown/code/link/table renderer is integrated and retains the existing 11 UI regressions; **22 Markdown checks pass**; image/audio/video attachment controls are being validated |
| Provider handoff | Bounded role/provider-preserving reference context implemented; **10 checks pass**; app/provider transition verification underway |
| Terminal | Native ConPTY session and per-thread tab/split UI implemented; **63 portable VT-screen checks pass**; ConPTY/native UI execution pending integration |
| Browser | Native WebView2 controller implemented; **23 policy + 7 offline native engine checks pass**; shared-profile default adjustment and app integration are being verified |
| Structured questions | Native single/multiple choice, free text, secret fields and validation implemented; **25 native form assertions prepared**, execution pending |
| Inline HTML/SVG previews | Isolated, network-disabled private preview implementation in progress |
| Real signed-in conversations | **Still unverified**. The correct existing Codex account needs interactive password/passkey approval. No approval prompt was sent while the owner is absent. A different saved Google account requested phone verification; that is not the correct-account blocker. |
| Remaining parity | Other provider adapters, background lifetime, scheduling, notifications/phone routing, Computer Use, credential integrations, instructions/imports/usage, offline voice, complete settings/localization and distribution still need implementation or acceptance |

The 430-check result is a complete earlier integration snapshot, **not** a sum of all newer isolated results. The next
integration build reached the expanded core/store/runtime suites but exposed a local-image URI escaping regression;
the correction is implemented and awaiting rerun. No newer total or full-parity percentage is claimed.

The previously pushed milestone and CI results are recorded below. Current implementation changes will be committed
and pushed after their integration checks; the live checklist is updated while work continues.

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
| Projects and conversations | Projectless chats, search, rename, pin, archive, settle, snooze, delete, batch operations, undo/redo | Basic project/chat/archive model and UI; remaining operations pending |
| Persistence | Fast index, lazy transcripts, drafts, crash-safe writes, recovery and forward compatibility | Initial isolated store passes 17 Windows regression checks; full recovery/migration still pending |
| Agents | Claude Code, Codex, Cursor, Grok Build, OpenCode, Antigravity; detect, sign in, catalogs and account selection | Codex, Claude and OpenCode adapters/discovery pass isolated fixtures; full integration and real sign-in remain pending; other adapters unfinished |
| Model controls | Favorites, hidden models, effort, speed, permissions, plan/build mode, project defaults | Per-provider model preferences and model/effort/speed/plan/access controls implemented; UI integration underway; favorites/hidden models/project defaults pending |
| Streaming runtime | Tools, approvals, questions, cancellation, steering, queueing and background work | Codex Send, streaming, command approvals, questions and Stop pass native fixture UI checks; file approval denial also passes; steering, queueing and background persistence pending |
| Provider handoff | Per-provider/per-thread session IDs, missed turns, reset/resume behavior and context limits | Initial bookkeeping tests; provider integration and bounded recap pending |
| Transcript | Markdown, code, work logs, links, images, audio/video, media opening, previews and copy/selection | Virtualized plain text, long-thread switching, repeated replies, Unicode streaming and final-text reconciliation pass native UI checks; rich content and full performance validation pending |
| Composer | Attachments, mentions, slash commands, quotes, terminal/diff context and per-thread drafts | Send/Ctrl+Enter, Stop and per-thread drafts connected; attachments, mentions and other context controls pending |
| Git | Status/diffs, stage/commit/push, checkpoints/revert, worktrees and turn diffs | Backend passes 55 Git checks; native panel integration underway; checkpoint restoration/turn-diff acceptance still pending |
| Code hosting | GitHub native PR workspace; other supported forge CLIs/pages, checks, reviews and exact-head merges | Not implemented |
| Terminal | Per-thread terminals, tabs/splits, resize, Unicode, output and process cleanup | ConPTY + native VT-screen/tab/split candidate implemented; 63 screen checks pass; native process/UI acceptance pending |
| Browser | Persistent/private profiles, tabs, navigation, downloads, history/bookmarks/import, agent API and user handoff | WebView2 candidate passes 23 policy +7 offline engine checks; integration/profile recheck underway; history/bookmarks/import/agent API pending |
| Passwords/passkeys | Approved fill, CSV import, TOTP, Bitwarden/1Password and passkey boundaries | Awaiting platform decision |
| Computer Use | Discover windows, inspect, click/type/scroll, screenshot, permissions and single-thread arbitration | Awaiting platform decision |
| Scheduling | All existing recurrence kinds/time zones, approval cards, missed-run and busy-thread handling | Not implemented |
| Bots | Starter lineup, artwork/personality, project folders and separate histories | Not implemented |
| Instructions | Discovery, global/project masters, local links/copies, Git sync and conflict handling | Implementation pending; iCloud sync explicitly deferred on Windows |
| Usage | Provider account limits, balances, activity, usage/cost scopes and local history | Not implemented |
| Remote/CLI | iPhone/iPad pairing, TLS protocol, controls, alerts/presence and local CLI | Not implemented; preserve protocol compatibility |
| Notifications | Completion/input, activation, dismissal synchronization and phone routing | Alternative phone-alert route approved; implementation pending |
| Voice | Dictation, trigger/insertion, offline models and existing transcription providers | Windows-compatible offline replacement approved; implementation pending |
| Keep Awake | Charger/battery/lid behavior, optional mute/display and restoration | Awaiting platform decision |
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
