# Windows port: parity and acceptance

Target: standalone, native C++/WinRT + WinUI 3 Windows desktop application. A Mac connection must not be needed to
run agents. This is a full feature-port request, not permission to replace features with a remote-only client or a web shell.
Baseline: the Mac application at `b54ad87`, including the thread-switch and image-click fixes in #229 and #230.

## Verified development milestone

- SSH access and the native C++ toolchain are working on the owner's Windows laptop.
- The WinUI executable builds on that laptop; GitHub Windows runners also compile the application.
- 71 workspace/process checks and 17 Windows storage checks pass on Windows.
- 39 RPC/Codex protocol checks and 42 real-subprocess RPC connection checks pass on the laptop. These exercise
  initialization ordering, Unicode streaming, opaque approval IDs, explicit declines, deadlines, failed startup,
  child exits, and cancellation while the child stops reading stdin. They do not use a provider account.
- Four native UI checks pass on the laptop: opening the latest row of a 1,500-message thread, switching to another
  1,500-message thread without scrolling, keeping that thread's draft, and returning to the first thread without a blank view.
- A screenshot and the native accessibility tree were inspected. The initial window and plain-text rows render.
- Full parity is not complete. The subprocess/RPC foundation is implemented; agent session orchestration and its
  connection to the composer are not. The preview still cannot run an agent and says so.
- Source is pushed in draft PR #235. Check its current Windows CI result separately from the local results above.

## Platform decisions awaiting the owner's answer

No decision below is treated as approval merely because development continues elsewhere.

| Existing implementation | Proposed Windows implementation | Decision |
|---|---|---|
| WebKit browser and preview controls | WebView2, retaining per-thread tabs, profile choices, imports, agent controls and login gates | Asked; pending |
| Keychain and browser encryption keys | Windows Credential Manager/DPAPI; preserve Bitwarden and 1Password CLI integration | Asked; pending |
| SwiftTerm/POSIX terminals | ConPTY-backed native terminal with tabs, splits, and selection context | Asked; pending |
| macOS Accessibility/Screen Recording and bundled Cua Driver | Windows UI Automation and capture with the same permission and per-thread access boundaries | Asked; pending |
| iCloud Drive instruction copies | iCloud for Windows folder where installed, keeping local and repository copies; no automatic OneDrive substitution | Asked; pending |
| WhisperKit/Core ML and Apple Speech | Windows-compatible offline dictation; retain existing cloud providers | Design requested; approval pending |
| CloudKit iPhone lock-screen alerts | Design a cross-platform alert path; present hosting, account and cost requirements before setup | Design requested; approval pending |
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
| Agents | Claude Code, Codex, Cursor, Grok Build, OpenCode, Antigravity; detect, sign in, catalogs and account selection | Codex protocol and Windows process/RPC transport pass fixture tests; live sessions and other providers pending |
| Model controls | Favorites, hidden models, effort, speed, permissions, plan/build mode, project defaults | Not implemented |
| Streaming runtime | Tools, approvals, questions, cancellation, steering, queueing and background work | Bounded asynchronous RPC queues and process cancellation tested; turn orchestration, UI and background persistence pending |
| Provider handoff | Per-provider/per-thread session IDs, missed turns, reset/resume behavior and context limits | Initial bookkeeping tests; provider integration and bounded recap pending |
| Transcript | Markdown, code, work logs, links, images, audio/video, media opening, previews and copy/selection | Virtualized plain text and four long-thread UI checks pass on Windows; rich content and full performance validation pending |
| Composer | Attachments, mentions, slash commands, quotes, terminal/diff context and per-thread drafts | Drafts only; remaining composer behavior pending |
| Git | Status/diffs, stage/commit/push, checkpoints/revert, worktrees and turn diffs | Not implemented |
| Code hosting | GitHub native PR workspace; other supported forge CLIs/pages, checks, reviews and exact-head merges | Not implemented |
| Terminal | Per-thread terminals, tabs/splits, resize, Unicode, output and process cleanup | Awaiting platform decision |
| Browser | Persistent/private profiles, tabs, navigation, downloads, history/bookmarks/import, agent API and user handoff | Awaiting platform decision |
| Passwords/passkeys | Approved fill, CSV import, TOTP, Bitwarden/1Password and passkey boundaries | Awaiting platform decision |
| Computer Use | Discover windows, inspect, click/type/scroll, screenshot, permissions and single-thread arbitration | Awaiting platform decision |
| Scheduling | All existing recurrence kinds/time zones, approval cards, missed-run and busy-thread handling | Not implemented |
| Bots | Starter lineup, artwork/personality, project folders and separate histories | Not implemented |
| Instructions | Discovery, global/project masters, links/copies, git sync, conflict handling and iCloud choice | Awaiting sync decision; protected instruction files untouched |
| Usage | Provider account limits, balances, activity, usage/cost scopes and local history | Not implemented |
| Remote/CLI | iPhone/iPad pairing, TLS protocol, controls, alerts/presence and local CLI | Not implemented; preserve protocol compatibility |
| Notifications | Completion/input, activation, dismissal synchronization and phone routing | Not implemented; Apple alerts need decision |
| Voice | Dictation, trigger/insertion, offline models and existing transcription providers | Awaiting platform decision |
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
