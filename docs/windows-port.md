# Windows port: parity and acceptance

Target: standalone, native C++/WinRT + WinUI 3 Windows desktop application. A Mac connection must not be needed to
run agents. This is a full feature-port request, not permission to replace features with a remote-only client or a web shell.
Baseline: the Mac application at `b54ad87`, including the thread-switch and image-click fixes in #229 and #230.

The owner deferred iCloud instruction sync on Windows for this phase. Local/project instructions and Git sync remain
in scope. The owner approved a Windows-compatible offline dictation replacement and an alternative phone-alert
delivery route. Phone alerts remain pending; the offline dictation foundation is implemented and tested synthetically,
with real recognition and remaining voice parity still unverified. These decisions affect the Windows port.

## Current completion checklist — 2026-11-05

- [x] Pushed native hosted-conversation/tool foundation: `2fdefa6`.
- [x] Earlier physical 11e candidate: **3,457 checks / 65 suites**, native owner-recovery acceptance, **18 ordinary flows** and **18 hosted flows plus Quit** pass. These are separate from the latest CI snapshot below.
- [x] Native panel foundation: **19 panels / 499 checks**; browser path portability separately checked with real long/8.3 paths.
- [x] Current queue/crash acceptance: CI app `a5d2fed` passed **six physical full-app crash/relaunch checkpoints** on the ASUS laptop, including accepted queued work with blocked saves, unchanged host/provider identities, exactly-once replay and explicit Quit. The earlier uncertain-delivery failure and its original input remain preserved; this pass does not establish its root cause.
- [x] Instruction Git-root correction: **80 native checks** pass with both normal and real 8.3 TEMP paths; nested/junction/forged-root refusal remains covered.
- [x] Prepared-host helper portability: **63 actual filesystem/ACL checks pass in each** of Windows PowerShell 5.1 and PowerShell 7 in CI.
- [x] Native runtime shutdown acceptance: **45 RPC, 102 Codex, 50 Claude and 28 ConPTY checks passed and the processes exited** after the synchronized predicate fixes; success reports now follow owned-session teardown.
- [x] C++ build/core/runtime CI at `a5d2fed`: **3,507 assertions across 66 suites** passed. Host entry/bootstrap use the restrictive-job guard cases (3 and 8); this does not establish unrestricted hosted readiness. PowerShell guard counts remain separate.
- [x] [Windows CI for app code `a5d2fed`](https://github.com/apoorvdarshan/coincide/actions/runs/41951082618) passed: **18 app flows and 20 native panel suites / 525 assertions**, including **26 find-control checks**. The clipped toolbar command is revealed through one supported scroll before one visible command invocation; existing waits and coverage remain intact.
- [x] Completed-connect deadline correction: **67 IPC checks** passed, retaining all 45 original checks plus 22 actual-pipe boundary cases. This does not establish the original physical queued-message failure fixed.
- [x] Find in the current conversation: native message search, visible excerpts and next/previous navigation pass **32 scanner checks on both portable Clang and Windows** and **26 native control checks**. Physical Ctrl+F/F3 focus routing and virtualized row-scroll acceptance remain pending.
- [x] Physical follow-up: the interrupted original-binary comparison was retrieved and passed. CI app `a5d2fed` separately passed **18 hosted app flows plus orderly Quit** on the laptop, with no scoped host left running. Its executable SHA-256 is `83c3bfb37b4774ad2c52604d96251e5f6e6043a453f08da986d850cc30456396`.
- [ ] Initial-marker/missing-host-generation owner recovery and the remaining feature/platform acceptance listed below.
- [ ] Signed packaging, updates and distribution acceptance. No public release is authorized.

The app code and UI driver passed the linked exact-revision CI snapshot and the physical hosted/crash scenarios above. Initial-marker/missing-host-generation owner recovery, real-service acceptance and the remaining parity work remain open. Further features will use focused follow-up PRs rather than extending this foundation PR.

The full Windows port is **in progress**, not complete or released. The pushed frozen Windows candidate passed
**3,378 automated checks across 64 suites** on the physical laptop. Native acceptance also passed **19 panels / 499
checks** and **18 full-app flows**. The updated screenshot fixture separately passes all 43 browser checks with both
physical and real 8.3 TEMP spellings; these repeated checks are not added to the totals.

The same frozen hosted candidate passed **18 full-app flows plus orderly Quit**, and **six crash/relaunch checks**:
accepted queued work completes while the owned transcript/index cannot be replaced; killing only the UI leaves the
same host/provider alive; reopening replays exactly four rows without new input/control commands; transcript/index
cursors converge to the original host ACK; explicit Quit saves and exits the exact scoped processes.

These results use owned synthetic providers, temporary repositories and offline pages. They do not establish real
signed-in provider/model compatibility, owner browser/vault imports, live GitHub writes, microphone recognition,
notification delivery or public distribution. Exact-revision CI remains a separate gate. Explicit owner recovery for
crash-stranded definite non-delivery records is a newer candidate and is not part of this frozen acceptance result.

Browser library acceptance includes **33 store/import, 12 actual system-SQLite and 35 native UI checks**. Instruction
Git sync passes **72 backend and 18 native panel checks**; iCloud instruction sync remains deferred for this phase.

| Feature | Current source and evidence | Remaining acceptance or parity |
|---|---|---|
| Native app, conversations and storage | Native window, projects/projectless chats, lazy transcripts, drafts/outbox, attachments, rename/pin/settle/snooze/trash, batch undo/redo and atomic persistence have full-checkpoint fixture coverage | Broader migration, crash recovery, sustained use, mixed-DPI and ARM64 execution |
| Transcript and model controls | Native Markdown/code/tables, local image/audio/video controls, tool/approval/question rows, model favorites/visibility/custom models, effort/speed/plan/access and project defaults are implemented | Complete media, selection, performance and accessibility acceptance |
| Codex and Claude | Default-account runtimes include streaming, resume, approvals/questions, queues and verified-account delivery/resume guards; hosted integration is candidate source | Real signed-in conversations and account-switch recovery are unverified; named Codex/Claude profiles are not connected |
| Cursor, Grok and Antigravity | Verified separate Cursor profiles have scoped ACP/factory/host paths; generic ACP foundations are fixture-tested | Cursor live acceptance pending; production Grok/Antigravity identity flows remain unavailable rather than falling back to unverified accounts |
| OpenCode | Legacy native HTTP/SSE adapter exists; the new off-default credential-continuity foundation is synthetically validated | Actual installed CLI/protocol compatibility, collector integration, account-aware resume and hosted eligibility are unverified; continuity is not verified account identity |
| Composer and search | Send/Ctrl+Enter, Stop, per-thread drafts, attachments, queued input, Codex steering and Git diff-to-composer exist; sidebar search matches titles/providers/projects. A focused follow-up adds native search across saved message bodies with bounded worker reads and exact-message navigation; Windows acceptance is pending | Find-in-thread has 32 scanner and 26 native control checks at the foundation revision; physical shortcut/focus and virtualized-row navigation acceptance remain pending. Cross-conversation search acceptance, project search/command palette, `@` files, `/` commands, `$` skills, `#` PR suggestions and reply/terminal selection-to-composer |
| Git and code hosting | Status/diffs, literal-path stage/unstage, commit/push, branches, worktrees, manual checkpoints and physical shared-repository leases are implemented. Native GitHub PR previews/reviews, exact-head merges and detached review worktrees have injected/native fixture coverage | Per-turn diff/checkpoint integration, other forge parity and full tool acceptance; no real GitHub write has been validated |
| Terminal | ConPTY per-thread tabs/splits, VT screen, resize, Unicode, selection/copy, interruption and repository command guards have native fixture coverage | Terminal search, selection context into the composer and broader interactive shell acceptance |
| Browser and inline preview | WebView2 shared/private profiles, per-thread tabs, navigation/downloads, scoped agent actions and network-disabled inline preview are implemented; owned offline WebView2 acceptance passes | Screenshot capture requires an already visible root/pane/target; hidden capture remains unavailable. Passkey detection/vault/handoff parity and native passkey behavior remain unverified |
| Browser library and import | History/bookmarks, search/delete/clear, explicit private bookmarks, automatic private/credential-private exclusion and selected metadata-file import are implemented with backend and native panel acceptance | Cookie/sign-in migration and broader browser-profile import are not implemented. Metadata imports exclude credentials/cookies/sign-ins |
| Credentials | Saved-login protection, Bitwarden/1Password CLI adapters, CSV/TOTP review, one-use exact-origin approval and browser-fill/controller paths have synthetic/native fixture coverage | Real owner-vault/login acceptance and passkey parity |
| Scheduling, bots and usage | Recurrence/time zones, proposal approval, persisted scheduled delivery, bot histories/defaults/artwork and reported-usage accounting have full-checkpoint app/native coverage | Hosted scheduled delivery passes the owned full-app flow; unreported balances, costs and rate limits remain unavailable |
| Instructions and native-session imports | Read-only global/project/local discovery and Codex/Claude JSONL preview/duplicate detection/atomic publication exist; originals are preserved and unavailable CWD imports are history-only | Broader real archive/provider-resume acceptance; no implicit execution of discovered instructions |
| Instruction Git sync | Reviewed links/copies, isolated commits, explicit fetch/pull/push, conflict handling and opt-in automatic copy sync are implemented; backend and native panel acceptance pass | incoming master changes require explicit review. **iCloud instruction sync is deferred for this phase** |
| Background lifetime | Full checkpoint verifies window hiding/reactivation, independent data scopes, Stop/draft preservation and owned-child/tray cleanup. Separate authenticated host/adoption/persistence/Quit integration passes owned full-app and crash/relaunch acceptance | Real provider/account lifetime and broader storage-failure acceptance remain unverified; crash-stranded definite-input owner recovery is a newer candidate |
| Computer Use | Default-off permissions, fresh element/window tokens, owned native helper, bounded IPC and cross-process desktop arbitration are implemented and synthetically tested | Actual owned UIA/capture/input and app-tool acceptance; browser/password/shell/elevated/secure-desktop targets remain outside its permitted surface |
| Notifications and remote/mobile | Native Windows notification storage/transport/activation foundations have injected coverage | Actual OS registration/delivery/cold-start activation, alternative phone alerts, Windows remote pairing/TLS server/mobile controls/presence and local CLI are not accepted; remote/mobile/CLI counterparts are not implemented |
| Voice | Disabled-default WinMM capture, local whisper CLI/model selection and original-draft insertion are implemented with synthetic/native panel coverage | Real microphone/engine/model recognition; Mac cloud transcription, model-download management, hold/tap/global shortcut and partial-transcript parity |
| Keep Awake | App-owned system/display requests, AC/battery policy and request release exist | Lid/OEM/Windows hibernation can override the request; Mac mute/lid-helper parity and real power-transition acceptance remain pending |
| Preferences, localization and accessibility | Native settings/About/shortcut controls, shared Mac resources, language selection, native automation peers and PerMonitorV2 are present | Full Windows-string translation, long text/RTL, Narrator, keyboard/high-contrast and mixed-DPI acceptance; untranslated text falls back to English |
| Distribution | Unpackaged development build/CI output and required notices exist | Signed installer, install/update/rollback verification, ARM64 runtime acceptance and release decisions; no public release is authorized |

The earlier `4008aa4` milestone passed 202 automated and eleven native UI checks. It is historical evidence, not the
current feature inventory. Later CI exposed fixture portability/timing defects; each changed revision still requires
its own CI and relevant physical acceptance. No real signed-in conversation is claimed from CLI startup/help or a
synthetic fixture. The current account's interactive sign-in state has not been rechecked for this documentation update.

## Platform decisions

No decision below is treated as approval merely because development continues elsewhere.

| Existing implementation | Proposed Windows implementation | Decision |
|---|---|---|
| WebKit browser and preview controls | WebView2, retaining per-thread tabs, profile choices, imports, agent controls and login gates | Asked; pending |
| Keychain and browser encryption keys | Windows Credential Manager/DPAPI; preserve Bitwarden and 1Password CLI integration | Asked; pending |
| SwiftTerm/POSIX terminals | ConPTY-backed native terminal with tabs, splits, and selection context | Asked; pending |
| macOS Accessibility/Screen Recording and bundled Cua Driver | Windows UI Automation and capture with the same permission and per-thread access boundaries | Asked; pending |
| iCloud Drive instruction copies | Defer iCloud sync on Windows for this phase; retain local/project instruction handling and Git sync | Owner deferred; excluded from current Windows acceptance |
| WhisperKit/Core ML and Apple Speech | Windows-compatible offline dictation; retain existing cloud providers | Replacement approved; local CLI foundation implemented, real recognition and remaining voice parity pending |
| CloudKit iPhone lock-screen alerts | Use an alternative phone-alert delivery route; present concrete hosting, account and cost requirements before external setup | Alternative route approved; design and implementation pending |
| launchd background agent host | Windows-owned background process and authenticated local IPC, preserving running sessions across window closure | Must present implementation before replacing behavior |
| pmset/lid/battery helper | Windows power APIs with exact restoration of prior settings | Must present implementation and limitations before changes |
| Developer ID, notarization and app updater | Windows packaging/signing/update path, preserving verified download/install behavior | Signing, distribution and update decisions pending |

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
