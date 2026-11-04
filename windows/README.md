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

The build runs 27 portable core checks and 17 Windows storage checks. In an **interactive desktop session**, run
`./windows/Tests/PreviewSmoke.ps1` for the native long-thread switching and draft checks. It seeds two isolated
1,500-message conversations, checks the latest rows without scrolling, records UI evidence, closes its own process,
and removes its temporary conversation data. It does not use the owner's real conversations or an agent account.

The initial preview keeps its data under `%LOCALAPPDATA%\Coincide Windows Preview`. Override `COINCIDE_DATA_DIR` for
isolated tests. It does not import or rewrite an existing Mac data directory. The small workspace index loads at launch;
each conversation's messages and draft load only when opened. Invalid/future-format files fail closed instead of being
replaced. Files are written through a unique temporary file, flushed, and atomically replaced.

## Current scope

Implemented in the development source: native window, folder picking, local projects and projectless chats,
per-thread saved drafts, archive/undo/redo, provider selection, provider-scoped session bookkeeping, and a virtualized
plain-text transcript. Provider execution and the full application feature set are still pending. The preview explicitly
reports that agent connections are unavailable; it never fabricates agent output. No release or full-parity claim is made.

Shared labels reuse the existing Mac string catalog in all its languages:

```sh
python3 windows/scripts/sync-resources.py
python3 windows/scripts/sync-resources.py --check
```

New preview notices, runtime errors, and the full Windows UI still need the localization acceptance pass in the audit.
Existing machine translations retain their original quality limitations.
