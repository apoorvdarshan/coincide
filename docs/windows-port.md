# Windows port: parity and acceptance

Target: standalone, native C++/WinRT + WinUI 3 Windows desktop application. A Mac connection must not be needed to
run agents. This is a full feature-port request, not permission to replace features with a remote-only client or a web shell.
Baseline: the Mac application at `b54ad87`, including the thread-switch and image-click fixes in #229 and #230.

The owner deferred iCloud instruction sync on Windows for this phase. Local/project instructions and Git sync remain
in scope. The owner approved a Windows-compatible offline dictation replacement and an alternative phone-alert
delivery route; phone alerts remain pending, while offline dictation is now being implemented and tested synthetically. These decisions affect the Windows port.

## Current completion checklist — 2026-11-05

The full Windows port is **in progress**. The most recent combined development candidate passes **2,755 automated
checks on the physical Windows laptop**. This is not a completed or released port. The same candidate passes **17 conversation/scheduled/usage/bot/tool-opening flows and 443 native panel checks**. Further
feature integration and final end-to-end acceptance are still in progress; a source implementation alone is not a completed checklist item.
The rough feature estimate is 50–55%, not a measurement derived from the number of tests.

| Work | Updated status |
|---|---|
| Native app and persistence | Builds on the laptop; native workspace/process, lazy transcripts, drafts, outbox, attachments, metadata history and recovery checks pass; store now has **66 checks**, plus **40 atomic import-store checks** |
| Conversations and transcript | Rename, pin, settle, snooze, delete/restore, project changes, search, batch undo/redo and rich native rendering implemented; **12 conversation UI flows passed**; the latest candidate passes **13 conversation/scheduled-delivery UI flows**, including the repaired final-row scrolling and visible approval decisions |
| Codex runtime | Catalogues, model/effort/speed/plan/access controls, queues, steering, Stop and verified-account resume/queue guards implemented; **49 protocol + 78 lifecycle checks pass** |
| Claude runtime | Stream-json, resume, approvals/questions, queues and account preflight guards implemented; **33 deterministic checks pass**; real signed-in conversation not verified |
| OpenCode runtime | Native HTTP/SSE adapter wired; **39 checks pass**; the current Windows PATH and permitted task-tools metadata scan found no OpenCode executable; real CLI compatibility, conversation and account-ownership validation remain pending |
| Cursor / Grok / Antigravity | Shared scoped ACP foundation passes **93 checks in the combined app**; isolated Cursor verified-profile/factory integration is implemented; Grok/Antigravity remain unavailable without verified identity flows |
| Provider accounts | Isolated profile storage and metadata checks pass **42 contracts**; **24 native account-panel checks pass**; explicit profile selection and per-delivery checks are implemented; no sign-in is started merely by opening the panel |
| Questions and approval | Native forms pass **25 interactive checks**; approvals stay with their originating conversation, and explicit decisions reach the fixture |
| Git | Status/diffs, literal-path stage/unstage, commit/push, branches, worktrees and non-destructive checkpoints implemented; **55 Git + 48 management checks pass**; **20 native Git-panel checks pass**; repository/terminal/agent lease guards now compare physical shared Git metadata across sibling worktrees (**41 identity + 13 lease checks**); final end-to-end tool acceptance remains pending |
| Code hosting | Native GitHub pull-request listing, immutable head/diff/check/review previews, exact-head merges and detached review worktrees implemented; **65 injected CLI + 21 native panel checks pass**; no real GitHub write was performed |
| Terminal | ConPTY and per-thread tabs/splits, bounded scoped output, interruption and repository command guards implemented; **63 VT-screen + 28 ConPTY + 15 native panel checks pass** |
| Browser and preview | WebView2, shared-profile policy and network-disabled inline preview implemented; **23 browser + 13 preview policy checks pass**; thread-scoped DOM/frame/tab/console/upload/capture actions and native owner handoff are integrated; **34 agent-policy + 43 owned offline WebView2 checks pass**; history/bookmarks/import remain in development; image capture currently requires an already visible pane |
| Scheduling | All recurrence/time-zone/store policies and native UI/timer dispatch implemented; **76 core + 70 store + 18 IANA + 61 native panel checks pass**; the app fixture verifies persisted scheduled delivery, completion and draft preservation; thread-scoped agent requests pass **33 checks** and always retain proposal approval |
| Preferences | Native General/Providers/Models/Keyboard/About controls and atomic settings implemented; **33 settings checks pass**; **73 native panel checks pass** after the CR/LF model-editor fix; profile/inheritance integration is implemented; the newest combined candidate passes |
| Instructions and imports | Read-only local/project/global discovery, bounded Codex/Claude JSONL previews, duplicate detection and atomic publication implemented; **17 instruction + 29 import + 40 transaction checks pass**; **11 native panel checks pass**; instruction Git sync remains pending |
| Background window lifetime | Physical desktop verifies active work survives window close, same-data relaunch reactivates it, different data stays independent, and Stop preserves the Unicode draft: **all 6 checks pass**, including Composer-focused Ctrl+Q and owned-child/tray cleanup; separate authenticated host/IPC (**91 core + 41 IPC + 78 proxy + 51 tool-context + 152 reducer + 58 factory checks**) is implemented as libraries; production app activation, durable event acknowledgment and final shutdown integration remain pending |
| Notifications | Native Windows notification adapter and thread-scoped activation/storage controls implemented; **68 injected-transport checks pass**; actual OS registration, delivery, cold-start activation and phone alerts remain unverified |
| Credentials | **91 synthetic manager/CSV/TOTP/store checks + 29 native panel checks** pass, alongside **10 owned Credential Manager checks**; browser fill/controller integration passes **62 synthetic checks** and is wired to the app; **12 native controller checks and 3 owner-handoff cancellation/timeout checks pass**; passkeys remain pending |
| Bots | Starter artwork/personality and metadata pass **57 checks**; app workspace integration passes **19**, including separate histories, drafts, immutable per-conversation defaults, working-folder retention and removal recovery; **37 native editor checks and two full-app bot flows pass** |
| Usage | Passive local history, provider normalization and per-delivery ownership pass **50 store/accounting + 181 provider fixture + 12 native panel checks**; app lifecycle acceptance covers interrupted and scheduled deliveries; unreported costs, balances and rate limits remain unavailable |
| Offline voice | Windows capture/CLI foundation passes **29 synthetic + 20 settings checks**; **18 native voice-panel checks pass**; no microphone capture or real recognition has run |
| Computer Use | Permission/token/helper foundations pass **62 policy + 33 settings + 20 owned-pipe checks**; **29 native settings-panel checks pass**; the cross-process desktop lease passes **32 synthetic checks**. Actual native UIA/capture/input and app-tool acceptance remain pending |
| Real signed-in conversations | **Not verified.** The correct existing Codex account needs interactive password/passkey approval. No prompt was sent while the owner was absent. A different account's phone-verification page is not the correct-account blocker. |
| Remaining full parity | Complete provider identity flows, background-host app activation, phone routing, Computer Use acceptance, browser history/bookmarks/import and hidden capture, passkeys, instruction sync, remaining voice features, localization, accessibility/DPI/ARM64, distribution/signing/updating and final native acceptance |

The 2,755-check combined run consists of 153 workspace/process, 22 Markdown, 10 handoff, 63 terminal screen,
76 scheduler, 66 store, 49 protocol, 42 RPC connection, 78 Codex lifecycle, 8 display/media, 55 Git,
12 provider discovery, 33 Claude, 28 ConPTY, 18 IANA, 39 OpenCode, 23 browser policy, 13 preview policy,
70 schedule store, 93 ACP, 33 preferences, 13 desktop/power, 17 instructions, 29 imports, 40 atomic import-store,
42 provider accounts, 68 notification policy, 20 voice settings, 62 Computer Use policy, 33 Computer Use settings,
48 Git management, 86 per-delivery tool context, 102 private app-tool bridge, 33 schedule app-tool,
50 local usage, 181 provider usage, 91 credential foundation, 57 bot catalog/store/artwork, 19 bot workspace,
13 hosted receipt persistence, 91 host core/ledger, 34 browser agent policy, 62 credential controller,
152 hosted reducer, 58 native host factory, 65 code hosting, 41 Git identity, 13 repository lease,
29 synthetic voice, 20 owned-helper IPC, 32 shared desktop lease, 41 authenticated host IPC,
78 background session proxy and 51 live-owner host tool-context checks. These use no real account/model turn,
notification registration, or microphone capture. Interactive UI and Credential Manager checks are counted separately.

The previous pushed checkpoint `1d124b4` passed Windows CI and its other applicable checks. The expanded checkpoint
above has been validated on the physical laptop; check PR #235 for its own exact-revision CI result. Required notices
accompany the Windows build output. The fixture-only schedule clock now starts when its controller opens; a deliberate 12-second startup delay
passes the real app scheduled-delivery flow without changing production missed-run behavior. CI subsequently exposed
a Git mutation-observation fixture race, whose fix passes the expanded native panel run, then a PowerShell cold-start deadline in the advertised curl fixture. The latter now separates bounded shell readiness from its unchanged action deadline and passes all 102 bridge checks. CI then exposed bot fixture comparisons against the runner's DOS 8.3 path spelling. Those checks now compare physical folder identity and the focused 19-check suite passes on the laptop. Exact-revision CI is still required. Background-host app integration and remaining parity work continue.

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
| Persistence | Fast index, lazy transcripts, drafts, crash-safe writes, recovery and forward compatibility | Expanded store passes 66 native checks plus 40 atomic import-store checks; queues, drafts, attachments, native account/session bindings, unknown fields and stale writers are covered; full migration/crash acceptance remains pending |
| Agents | Claude Code, Codex, Cursor, Grok Build, OpenCode, Antigravity; detect, sign in, catalogs and account selection | Codex, Claude and OpenCode pass combined native fixtures; ACP foundation passes 49 contract checks; vendor/account setup and real sign-in remain pending |
| Model controls | Favorites, hidden models, effort, speed, permissions, plan/build mode, project defaults | Per-provider model/effort/speed/plan/access controls, favorites, hidden/custom models and project inheritance are implemented; preferences panel acceptance passes 73 checks |
| Streaming runtime | Tools, approvals, questions, cancellation, steering, queueing and background work | Codex/Claude/OpenCode runtimes include queues, approvals/questions and cancellation; Codex steering implemented. Full app UI validation and process-independent background lifetime pending |
| Provider handoff | Per-provider/per-thread session IDs, missed turns, reset/resume behavior and context limits | Provider-isolated native session bookkeeping and bounded role-preserving handoff context implemented; account-switch and app/provider-transition acceptance pending |
| Transcript | Markdown, code, work logs, links, images, audio/video, media opening, previews and copy/selection | Native Markdown/code/link/table and local media controls implemented; existing long-thread regressions passed earlier rich-renderer build; current media URI regressions pass; complete panel/performance acceptance pending |
| Composer | Attachments, mentions, slash commands, quotes, terminal/diff context and per-thread drafts | Send/Ctrl+Enter, Stop, saved drafts, file attachments, queued input, Codex steering and Git diff quotes implemented; mentions/slash commands/terminal selection context pending |
| Git | Status/diffs, stage/commit/push, checkpoints/revert, worktrees and turn diffs | 55 Git plus 48 management checks and 20 native panel checks pass; worktrees/checkpoints are implemented; final repository lease and per-turn diff acceptance remain pending |
| Code hosting | GitHub native PR workspace; other supported forge CLIs/pages, checks, reviews and exact-head merges | Native GitHub workspace and app toolbar integration implemented; 65 injected backend and 21 native panel checks pass; other forge parity remains pending |
| Terminal | Per-thread terminals, tabs/splits, resize, Unicode, output and process cleanup | ConPTY + native VT-screen/tab/split panel compiles; 63 screen + 28 ConPTY checks pass; panel UI acceptance pending |
| Browser | Persistent/private profiles, tabs, navigation, downloads, history/bookmarks/import, agent API and user handoff | WebView2 shared/private profiles pass 23 policy + 7 native engine checks; native panel compiles; agent DOM/frame/tab/console/upload actions and approved credential flow integrated; 34 agent policy and 43 offline WebView2 checks pass; history/bookmarks/import remain in progress; hidden image capture remains pending |
| Passwords/passkeys | Approved fill, CSV import, TOTP, Bitwarden/1Password and passkey boundaries | Platform replacement prepared where indicated; complete integration and owner acceptance pending |
| Computer Use | Discover windows, inspect, click/type/scroll, screenshot, permissions and single-thread arbitration | Platform replacement prepared where indicated; complete integration and owner acceptance pending |
| Scheduling | All existing recurrence kinds/time zones, approval cards, missed-run and busy-thread handling | 76 recurrence, 70 store, 18 IANA and 61 native panel checks pass; app fixture verifies durable scheduled delivery and draft preservation; thread-scoped agent requests pass **33 checks** and always retain proposal approval |
| Bots | Starter lineup, artwork/personality, project folders and separate histories | Native metadata/editor and root workspace integration implemented; 57 bot + 19 workspace + 37 native editor checks and two full-app flows pass |
| Instructions | Discovery, global/project masters, local links/copies, Git sync and conflict handling | Read-only project/global discovery and native previews are implemented; 17 backend and 11 instruction/import UI checks pass; Git sync remains pending; iCloud sync is explicitly deferred |
| Usage | Provider account limits, balances, activity, usage/cost scopes and local history | Local reported-usage accounting, provider normalization and native panel pass 50 + 181 + 12 checks; balances/rate limits remain unavailable |
| Remote/CLI | iPhone/iPad pairing, TLS protocol, controls, alerts/presence and local CLI | Not implemented; preserve protocol compatibility |
| Notifications | Completion/input, activation, dismissal synchronization and phone routing | 68 injected native notification storage/routing checks pass; actual OS registration/delivery, cold-start activation and alternative phone routing remain unverified |
| Voice | Dictation, trigger/insertion, offline models and existing transcription providers | Native offline capture/CLI settings and draft-only insertion are implemented; 29 synthetic, 20 settings and 18 native panel checks pass; real microphone/recognition remains unverified |
| Keep Awake | Charger/battery/lid behavior, optional mute/display and restoration | Platform replacement prepared where indicated; complete integration and owner acceptance pending |
| Preferences/help | Appearance, shortcuts/conflicts, languages, About/legal/community links and updates | Native settings and About controls pass 33 backend and 73 panel checks; updater and full localization remain pending |
| Localization | All 19 existing languages, placeholders/plurals, accessibility and RTL/long-text checks | Shared labels generated; full UI and runtime checks pending |
| Imports | Claude/Codex originals preserved, limits, branch/rollback semantics and duplicate handling | Bounded preview, unchanged originals, duplicate checks and atomic publication pass 29 import, 40 transaction and 11 shared instruction/import UI checks; broader branch/rollback parity remains pending |
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
