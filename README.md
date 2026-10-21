# Coincide

A native Swift macOS port of [T3 Code](https://github.com/pingdotgg/t3code).

## Status

In development. Full T3 Code feature parity is **not complete**. See
[porting status](docs/PORTING.md) for implemented behavior, gaps, and verification.

## Build and run

Requires macOS 14+, a Swift 6.2+ toolchain, and Xcode Command Line Tools. Codex
conversations require an installed, authenticated `codex` CLI.

```sh
./script/build_and_run.sh
```

Add a project folder, start a thread, and send a message. Coincide connects directly
to Codex app-server using its existing sign-in. Review requested commands and file
changes in the conversation. Use the inspector to browse/edit files or inspect,
stage, and commit Git changes. A new thread can create a separate Git worktree
before its first message.

The app uses SwiftUI/AppKit and a Swift core; it does not launch Electron or a T3
Code server. Workspace data stays in `~/Library/Application Support/Coincide/`.
Worktree folders are preserved when conversations are archived.

## Tests

```sh
swift test
```

Tests cover process streaming/failure/cancellation, protocol framing and request
correlation, a deterministic Codex approval conversation, persistence/restart,
file conflicts/path containment, and Git/worktree operations. See the porting
document for live checks and their limitations.

T3 Code is copyright © 2026 T3 Tools Inc.; its [MIT license](docs/T3-CODE-LICENSE.txt)
is preserved here. Coincide is an independent project.
