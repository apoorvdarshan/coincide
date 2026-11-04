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

On Windows the build runs 71 workspace/process, 17 storage, 39 RPC/Codex protocol, 42 subprocess connection, and
32 Codex session lifecycle checks.
The portable workspace/framing checks also compile without the Windows runtime. In an **interactive desktop session**, run
`./windows/Tests/PreviewSmoke.ps1` for native long-thread switching, drafts, and Codex composer checks. It seeds two
isolated 1,500-message conversations and uses an explicitly labeled subprocess fixture to exercise Send, Unicode
streaming, command/file approval denial, questions, and Stop. It records UI evidence, closes its own process, and
removes its temporary conversation data. It does not use real conversations or a provider account.

On the physical Windows laptop, all 201 automated checks and eleven native UI checks pass. The UI suite covers
long histories, saved drafts, streaming/final-text reconciliation, repeated identical replies, duplicate chat titles,
command/file approval denial, typed question answers, and Stop. Distinct view-model identities keep equal visible text
from confusing WinUI's item lookup and accessibility traversal. Check exact-head CI separately from these local results.

The initial preview keeps its data under `%LOCALAPPDATA%\Coincide Windows Preview`. Override `COINCIDE_DATA_DIR` for
isolated tests. It does not import or rewrite an existing Mac data directory. The small workspace index loads at launch;
each conversation's messages and draft load only when opened. Invalid/future-format files fail closed instead of being
replaced. Files are written through a unique temporary file, flushed, and atomically replaced.

## Current scope

Implemented in the development source: native window, folder picking, local projects and projectless chats,
per-thread saved drafts, archive/undo/redo, provider selection, provider-scoped session bookkeeping, and a virtualized
plain-text transcript. Codex sessions now connect to the native Windows CLI, persist and resume their thread identity,
stream replies, show explicit command/file approvals and questions, and support Stop. Send uses the button or Ctrl+Enter.
Other providers and the rest of the parity checklist remain pending. No public release or full-parity claim is made.

Install the native Windows Codex CLI and sign in with `codex login` before using a real conversation. The app searches
for `codex.exe` on PATH and the per-user Codex/WinGet locations; `COINCIDE_CODEX_EXE` can select an explicit executable.
Project chats use their project folder; projectless chats use an isolated workspace under the preview data directory.
Switching threads preserves active work and unanswered requests. Closing the window stops its owned agent processes;
a persistent background host is not implemented. Live sign-in and a real account conversation have not been verified.

The runtime foundation starts an explicit executable without a shell, confines its descendants to an owned job,
frames UTF-8 JSONL, and keeps pipe reads/writes off the UI thread. Protocol fixtures verify initialization, streamed
notifications, explicit approval decisions, deadlines, and shutdown even when stdin is blocked. These checks do not
sign in, run a model turn, or spend account quota. Session fixtures additionally exercise failed authentication/resume,
turn identity, stream reconciliation, request routing, early completion, startup cancellation, and ignored interrupts.
Fixture output is available only under the explicitly labeled test flag; ordinary launches require the real CLI.

Shared labels reuse the existing Mac string catalog in all its languages:

```sh
python3 windows/scripts/sync-resources.py
python3 windows/scripts/sync-resources.py --check
```

New preview notices, runtime errors, and the full Windows UI still need the localization acceptance pass in the audit.
Existing machine translations retain their original quality limitations.
