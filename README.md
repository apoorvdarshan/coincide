# Coincide

A native Swift macOS coding app, with [T3 Code](https://github.com/pingdotgg/t3code)
as the functionality reference and the ChatGPT macOS app as the interface reference.

## Status

In development. Full T3 Code feature parity is **not complete**. See
[porting status](docs/PORTING.md) for implemented behavior, gaps, and verification.

## Build and run

Requires macOS 14+, a Swift 6.2+ toolchain, and Xcode Command Line Tools. Codex
conversations require an installed, authenticated `codex` CLI; Claude conversations
use the installed, authenticated `claude` CLI.

```sh
./script/build_and_run.sh
```

The script uses an existing Apple Development signing identity when available,
so macOS can retain file-access consent across local rebuilds. Set
`COINCIDE_SIGN_IDENTITY=-` to use ad-hoc signing, or set it to a specific identity.
CI uses ad-hoc signing. Local signing does not notarize or publish the app.

Add a project folder, start a thread, and send a message. Coincide connects directly
to Codex app-server or Claude's stream-json protocol using their existing sign-in.
Choose the provider in a new conversation's header. Review requested commands and file
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
correlation, deterministic Codex and Claude approval conversations, persistence/restart,
file conflicts/path containment, and Git/worktree operations. See the porting
document for live checks and their limitations.

T3 Code is copyright © 2026 T3 Tools Inc.; its [MIT license](docs/T3-CODE-LICENSE.txt)
is preserved here. Coincide is an independent project.
