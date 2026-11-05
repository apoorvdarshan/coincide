# Coincide for Windows

Native Windows port in development: C++20/C++/WinRT and WinUI 3. This is **not yet a feature-complete Coincide app**.
The Mac application and its data are independent of this target. The feature-by-feature acceptance plan is in
[the parity audit](../docs/windows-port.md).

## Build

Install Visual Studio C++ Build Tools (2022 or 2026) with the C++ desktop workload, CMake tools, and Windows SDK
10.0.26100. The programmatic WinUI shell is an unpackaged desktop application, not a UWP application.
Run in PowerShell:

```powershell
./windows/build.ps1
```

The script executes core regression tests and builds the unpackaged application. Start
`windows/build/x64/Release/Coincide.exe` from the complete output directory; the Windows App SDK is deployed beside it.
Do not copy just the EXE. `-CoreOnly` runs the core checks without building WinUI. ARM64 app builds can be requested
with `-Architecture ARM64`; automated execution of ARM64 artifacts remains a separate validation task.

The pushed foundation candidate passed **3,378 automated checks across 64 suites** on the physical Windows laptop.
Native acceptance also passed **19 panels / 499 checks** and **18 app flows**. Its hosted variant passed the same
18 flows plus orderly Quit, and six actual UI-crash/relaunch checks with unchanged host/provider identities,
no duplicate input commands, exact transcript/index/ACK convergence and final scoped process exit. Exact-revision
CI, real-service acceptance and the remaining parity work are separate gates.

The latest [CI snapshot for app code `a5d2fed`](https://github.com/apoorvdarshan/coincide/actions/runs/41951082618)
passed **3,507 C++ assertions across 66 suites**, **18 app flows**, and **20 native panel suites / 525 assertions**.
Separate PowerShell 5.1 and 7 filesystem/ACL guards pass **63 checks each**. Host entry/bootstrap use restricted-job
guard cases (3/8), so these results do not establish unrestricted hosted readiness. Current-thread find passes
32 scanner and 26 native control checks; physical shortcut/focus and virtualized-row navigation remain pending.

The earlier physical recovery candidate passed **3,457 checks / 65 suites**, explicit native recovery acceptance and the
18 ordinary/hosted app flows. The newer CI app `a5d2fed` now separately passes **18 hosted flows plus orderly Quit** and
**six physical crash/relaunch checkpoints** on the laptop. The interrupted original-binary comparison was retrieved and
also passed. The earlier uncertain-delivery failure and its input remain preserved; these passes do not establish its
root cause. Instruction Git-root handling separately passes **80 checks** with normal and real 8.3 paths. Remaining
recovery and feature acceptance is tracked in the parity checklist.

The portable workspace/framing checks also compile without the Windows runtime. In an **interactive desktop session**,
`./windows/Tests/PreviewSmoke.ps1` exercises native long-thread switching, drafts, Send/Unicode/final-text reconciliation,
command/file approval denial, questions, Stop, schedules, bots, usage and tool panels. It uses isolated conversations and
explicit local protocol fixtures, not real provider accounts. The new `-HostedRuntime` variant targets the candidate
background-host integration and has owned full-app acceptance. `HostedRecoverySmoke.ps1 -RunInteractive` tests
accepted queued work, blocked local saves, UI-only crash/relaunch and exact receipt recovery. The script records evidence, closes its owned
processes and cleans only its synthetic state; uncertain hosted shutdown retains that fixture state for review.

The initial preview keeps its data under `%LOCALAPPDATA%\Coincide Windows Preview`. Override `COINCIDE_DATA_DIR` for
isolated tests. It does not import or rewrite an existing Mac data directory. The small workspace index loads at launch;
each conversation's messages and draft load only when opened. Invalid/future-format files fail closed instead of being
replaced. Files are written through a unique temporary file, flushed, and atomically replaced.

## Current scope

The native development source includes projects/projectless chats, lazy transcripts, per-thread drafts/outbox,
attachments, metadata history/undo/redo, rich Markdown/code/media rendering, approvals/questions and model controls.
It also includes Git/worktrees/checkpoints, a GitHub PR workspace, ConPTY terminal tabs/splits, scheduling, bots, local
usage, native preferences, instructions/imports, browser tools, credentials, offline voice and Computer Use foundations.
Each feature's verified scope and remaining work are listed in [the parity audit](../docs/windows-port.md).

The accepted feature foundations include:

- Browser history/bookmarks and explicit selected metadata import pass **33 store/import + 12 system-SQLite + 35 native
  UI/WebView2 checks**, with the prior 43 browser-agent engine checks still passing. Imports exclude cookies, credentials
  and sign-ins. Capture currently requires an already visible browser pane/target; hidden capture and passkey parity remain pending.
- Instruction Git sync passes **72 backend and 18 native panel checks**. Local/project
  instruction handling is in scope; **iCloud instruction sync is deferred for this phase**.
- Separate authenticated background host/adoption, durable acknowledgment, accepted-work crash replay and orderly
  Quit pass owned full-app acceptance. Explicit recovery of crash-stranded definite non-delivery records is a newer
  candidate; real provider/account lifetime remains unverified.

Codex and Claude default-account paths and verified separate Cursor profiles are wired. Named Codex/Claude profiles,
production Grok/Antigravity account identity, and OpenCode's current CLI/account/host compatibility remain incomplete.
OpenCode's new off-default credential-continuity foundation is not production eligibility. **Real signed-in provider
conversations have not been verified.** Existing native CLIs and the correct verified account are required; opening a
panel does not sign in, start a model turn or invent provider output.

Project chats use their project folder; projectless chats use an isolated workspace under the preview data directory.
Provider runtimes launch explicit executables, keep pipe work off the UI thread and retain separate account/session
bindings. Synthetic fixtures exercise startup, streaming, request routing, failures, cancellation and persistence without
spending account quota. They do not establish live provider compatibility or owner acceptance.

Remaining parity includes composer suggestions and selection context, cross-conversation message/project/terminal search, remote/mobile
pairing and CLI, phone alerts, actual notification/Computer Use/voice acceptance, browser sign-in migration and passkeys,
full localization/accessibility/DPI validation, signed distribution and updates. Offline voice currently uses a local
whisper CLI/model and draft-only insertion; no actual microphone recognition has been validated. No public release or
full-parity claim is made.

Shared labels reuse the existing Mac string catalog in all its languages:

```sh
python3 windows/scripts/sync-resources.py
python3 windows/scripts/sync-resources.py --check
```

New preview notices, runtime errors, and the full Windows UI still need the localization acceptance pass in the audit.
Existing machine translations retain their original quality limitations.
