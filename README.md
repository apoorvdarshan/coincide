# Coincide

A native macOS chat app for **Codex and Claude**, built with SwiftUI and AppKit.
Projects, saved conversations and a single model picker keep the focus on chat.
Coincide connects to the providers' CLIs and keeps its own conversation history.

## Current development

The app follows a native Codex/ChatGPT-style chat layout with embedded Settings.
Current work adds provider integrations, configuration editing, local session
inspection and conversation export. Automated validation is enabled again:
[GitHub Actions](https://github.com/apoorvdarshan/coincide/actions/workflows/swift.yml)
runs Swift tests, CLI/CI fixtures, native packaging and desktop UI checks.
See [dated verification details](docs/VALIDATION.md) for actual outcomes and
[provider feature coverage](docs/PROVIDER_FEATURES.md) for supported workflows
and remaining CLI differences.

## Use Coincide

1. Set up and authenticate the Codex or Claude CLI, then select its runtime in
   **Settings → Agents**. An authenticated CLI account does not need an extra
   Coincide API key. Model access follows that account's permissions.
2. Start a new chat, choose a project folder, or import existing conversations.
   Projects expand into their chats; **Recents** provides conversation navigation.
3. Choose a model from the composer's searchable list across Codex and Claude.
   **Settings → Models** controls the default list; **All models** reveals hidden
   rows. Refresh reads the selected runtimes' advertised catalogs.
4. Write a message, attach files or images, and send it. Tool activity, approvals
   and questions stay in the conversation. Native model options appear when the
   selected provider supports them, including reasoning or effort, permissions,
   service tier and interaction mode.

Coincide owns the conversation, its draft and copied history. Changing providers
keeps the same chat and prepares saved context for the next explicit message;
switching alone sends nothing. Finish running and queued work before switching.
Accepted inputs retain the provider and settings captured when they were sent.

Imports are independent Coincide copies, not a request to continue the original
CLI session. New replies use an independent execution binding. Long histories
use a bounded context handoff; private reasoning and attachment bytes are not
replayed as conversation text.

Settings has separate **Skills, Commands, MCP, Plugins and Hooks** pages. Skills
and saved commands can be copied into Coincide's library; MCP, plugin and hook
imports retain links to their original CLI configuration. Importing a reference
does not install or enable it for another provider. **Configuration** edits
supported CLI settings with explicit saves and stale-file protection, while
**Agent sessions** shows provider-owned sessions and their available actions.

Use `/app:` commands for Coincide navigation. The chat menu exports its current
public transcript to Markdown or JSON; private reasoning, runtime configuration
and attachment bytes are excluded.

## Build and run

Requires macOS 14 or later, a Swift 6.2 or later toolchain, and Xcode Command Line
Tools. Provider CLIs and their account setup are separate from building the app.

```sh
./script/build_and_run.sh
```

The script builds and opens the native app. Development signing uses an available
Apple Development identity; `COINCIDE_SIGN_IDENTITY=-` selects ad-hoc signing.
A local build does not publish or notarize the app.

Workspace data is stored under
`~/Library/Application Support/Coincide/`. Provider credentials remain with the
chosen CLI or its configured secure storage; they do not belong in the repository.

## Local command-line control

With Coincide running, the source checkout provides navigation, catalog reads,
model selection, integration/configuration/session controls and screenshots:

```sh
./script/coincide status
./script/coincide projects
./script/coincide models --all --refresh
./script/coincide integrations
./script/coincide configuration codex --scope user
./script/coincide ui --model-picker
./script/coincide screenshot /tmp/coincide-window.png
```

These commands do not send a model prompt. See [local CLI control](docs/LOCAL_CONTROL.md)
for targeting saved chats, Settings navigation and screenshot behavior.

## Documentation

[Product and design direction](docs/DESIGN.md) describes the current native app.

The repository also retains deeper implementation and historical records:
[porting](docs/PORTING.md), [transcript implementation](docs/TRANSCRIPT.md), [app tools](docs/MCP.md),
[remote environments](docs/REMOTE_ENVIRONMENTS.md),
[earlier cloud task briefs](docs/CLOUD_TASKS.md) and
[dated validation evidence](docs/VALIDATION.md).
These describe earlier work and internal infrastructure, not the current set of
user-facing screens or buttons. Legacy backend and persistence code has not all
been removed during the UI simplification.

## License

Coincide is released under the [MIT License](LICENSE); portions derived from
T3 Code keep their original [MIT notice](docs/T3-CODE-LICENSE.txt).

## Attribution and third-party notices

T3 Code is copyright © 2026 T3 Tools Inc.; its
[MIT license](docs/T3-CODE-LICENSE.txt) is preserved here. Coincide is an independent
project. Earlier T3-derived work remains attributed even where its UI is no
longer part of the product direction.

Third-party source and notices retained by the project include:

- [SwiftTerm](https://github.com/migueldeicaza/SwiftTerm) —
  [MIT notice](docs/SwiftTerm-LICENSE.txt).
- [Swift Markdown](https://github.com/swiftlang/swift-markdown) —
  [license](docs/SwiftMarkdown-LICENSE.txt) and [notice](docs/SwiftMarkdown-NOTICE.txt);
  [Swift cmark](https://github.com/swiftlang/swift-cmark) —
  [license](docs/SwiftCMark-LICENSE.txt).
- [SwiftMath](https://github.com/mgriebling/SwiftMath) —
  [MIT license](docs/SwiftMath-LICENSE.txt) and font notices:
  [OFL](docs/SwiftMathFonts-OFL-LICENSE.txt),
  [GUST](docs/SwiftMathFonts-GUST-LICENSE.txt), and
  [MathChat](docs/SwiftMathFonts-MathChat-LICENSE.txt).
- [Yams](https://github.com/jpsim/Yams) — [license](docs/YAMS-LICENSE.txt) and
  [notice](docs/YAMS-NOTICE.txt); libyaml — [license](docs/LIBYAML-LICENSE.txt).
