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
ACP v1 agents can use other installed CLIs, such as `opencode acp`.

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

In **Settings → Providers → ACP Agents**, save an agent name, executable, and
arguments (one per line), then choose it in a new conversation's header.
Arguments are passed literally. Model discovery supports the agent's config
options and older model lists; mode and other select options appear after session
setup. Permission buttons preserve the choices the agent supplies. ACP agents
enforce their own sandbox and use their own sign-in. Editing or removing a saved
agent leaves existing conversations' saved invocations intact. ACP v2, managed
registry installs, client-side filesystem/terminal delegation, and native agent
authentication flows are still pending.

Send another message during a turn to queue it. Each queued message keeps its
chosen model and permissions, and can be edited or removed before it starts.
**Stop** interrupts the current turn and holds the queue. Use **Resume Queue** to
continue; restarting the app also holds unfinished work rather than resending it.

Use **+** in the composer to attach files, or paste/drop local files and images.
Attachments stay with drafts, queued turns, and sent messages across restarts.
Image previews include copy, save, and open controls. Codex and Claude receive
supported images directly and other files as paths to private local copies.
The limit is 100 files per message, 10 MiB per normalized image and 80 MiB of
images per message, or 50 MiB per other file. HEIC, TIFF, and oversized images
are converted or resized natively; original files are preserved.

Responses render native Markdown headings, lists, task lists, quotes, tables, and
code blocks with copy controls and basic syntax coloring. Workspace file links
open the native editor at the referenced line. Web links use the default browser;
embedded HTML stays inert. Closed display equations on their own lines (`$$` or
`\[` delimiters) and fenced `math` blocks render through native CoreText, with
LaTeX copying and readable source fallback. Inline equations and media previews
are pending.

Open **Terminal** in the toolbar (⌥⌘T) for a native terminal in the conversation's
workspace. Create multiple tabs, resize the panel, or hide it while commands keep
running. Terminals stay attached to their conversation while the window is open;
closing a tab or quitting the app ends its local processes.

The app uses SwiftUI/AppKit and a Swift core; it does not launch Electron or a T3
Code server. Workspace data stays in `~/Library/Application Support/Coincide/`.
Worktree folders are preserved when conversations are archived.

## Tests

```sh
swift test --no-parallel
```

Tests cover process streaming/failure/cancellation, protocol framing and request
correlation, deterministic Codex and Claude approval conversations, journal replay,
ACP streaming/permissions/images/config options/resume and native agent settings,
atomic commit failures, accepted/rejected command deduplication, queued execution,
approval responsiveness, Stop, stale provider events, lease loss, migration/restart,
attachment import/integrity/conversion, native paste cancellation,
file conflicts/path containment, and Git/worktree operations. See the porting
document for live checks and their limitations.

The terminal uses [SwiftTerm](https://github.com/migueldeicaza/SwiftTerm), with its
[MIT notice](docs/SwiftTerm-LICENSE.txt) bundled in the development app.
Markdown parsing uses [Swift Markdown](https://github.com/swiftlang/swift-markdown)
and [Swift cmark](https://github.com/swiftlang/swift-cmark); their licenses and
notices are also bundled.
Native equations use [SwiftMath](https://github.com/mgriebling/SwiftMath), with its
[MIT license](docs/SwiftMath-LICENSE.txt) and original font notices bundled.

T3 Code is copyright © 2026 T3 Tools Inc.; its [MIT license](docs/T3-CODE-LICENSE.txt)
is preserved here. Coincide is an independent project.
