# Native background host entrypoint

`Runtime/NativeBackgroundHost.h` is deliberately a shallow declaration. Route exactly
`Coincide.exe --background-agent-host <physical-data-directory>` before normal XAML/STA
initialization to `run_native_background_host(path) noexcept`. Add
`App/NativeBackgroundHost.cpp` as a dedicated compilation unit. It includes Windows and
undefines `GetObject` before any WinRT projections, avoiding macro-dependent JSON ABI
spellings in the much larger UI translation unit. Exit codes are 0 for orderly exit,
2 for invalid path/apartment/image setup, and 3 for other setup/runtime failures. The
helper never presents a dialog or returns exception text containing native CLI output.

The entrypoint initializes MTA, binds the existing physical local data folder, pins its
literal ancestors and exact current PE, then composes the existing `Scope`, `Core`,
`NativeHostFactory`, and authenticated `Server`. It creates no service, registry key,
startup task, owner account, or UI window. Closing/crashing the UI does not terminate
active hosted work. The existing server retains active work and prompts, retires after
an idle grace, and obeys the existing durable owner Quit flow. The host writes only its
private runtime ledger and Cursor compilation cache; the UI remains the sole writer
of workspace index/transcripts and settings/profile metadata.

`NativeHostResolver(scope, services={})` is implementation-only. Construction and host
readiness/list do not read settings or profiles, discover/inspect a program, check auth,
or start a provider. Each explicit authenticated Start reads fresh scoped preferences.
Disabled providers fail closed. An explicit settings executable overrides file-only
native discovery; the IPC request's executable must subsequently match it physically
inside the frozen factory. Arbitrary argv, shell wrappers, fixture flags and client-
supplied environment are not supported; the only launch argument is the factory's
`app-server` sentinel, interpreted by the provider implementation.

Only default-profile Codex/Claude and a separately verified exact named Cursor profile
are eligible. OpenCode/Grok/Antigravity remain unavailable. Cursor resolution requires
existing metadata with the official identity source, prior scope, verification time,
and existing profile folder. A changed Settings default does not move a conversation
to another account. The factory still performs a fresh official Cursor metadata check
and retains native per-delivery identity/credential-revision guards. Cached metadata
alone does not authorize sending. No record, folder or account is created as fallback.
Compilation cache may be prepared after validated Cursor Start in the private host
runtime tree, with user-only ACLs. Its contents are not credentials.

The Windows implementation follows the Mac host's separation of runtime ownership,
durable event delivery and UI application (`CoincideKit/AgentHost/AgentHostCore.swift`,
`AgentEventLog.swift`, `AgentSessionLocks.swift`). Windows uses the already validated
user/data-folder scoped named pipe and physical-folder lease rather than macOS XPC or
ServiceManagement. It does not install or enable an OS background service.

`native_background_host_tests(report)` uses owned temporary metadata, copied synthetic
PEs and injected discovery/package seams. It validates inert construction, fresh
settings, provider/profile boundaries, changed defaults, missing/unverified profiles,
case-variant duplicates, malformed/hardlinked metadata, unavailable/wrapper/stream
programs and invalid entrypoint scopes. It never starts the production host/provider,
queries an owner account, reads a real vault/auth file, or sends a model request. Actual
native provider/auth acceptance remains separate and requires an available owner.

Native validation: 63 checks passed with MSVC C++20 `/W4 /WX /utf-8`, compiling the real
dedicated entrypoint translation unit and test harness. The composed Core/Server test
uses an injected fake `AgentSession` and scoped synthetic JSON only. Empty, relative,
missing-root and already-STA entrypoint calls all refuse before host construction.
