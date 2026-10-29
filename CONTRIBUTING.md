# Contributing to Coincide

Thanks for your interest in Coincide, a native macOS (AppKit) app for the coding agents you already use, ported from [T3 Code](https://github.com/pingdotgg/t3code). Bug reports, feature ideas and pull requests are all welcome.

Please read and follow the [Code of Conduct](CODE_OF_CONDUCT.md). Report security issues privately as described in [SECURITY.md](SECURITY.md), never in a public issue.

## Reporting bugs and requesting features

- **Bug:** [open the bug report form](https://github.com/apoorvdarshan/coincide/issues/new?template=bug_report.yml). Include your macOS version, the Coincide version, which agent CLI (and its version) was involved, exact steps, and any error text or logs.
- **Feature:** [open the feature request form](https://github.com/apoorvdarshan/coincide/issues/new?template=feature_request.yml). Describe the problem first, then the change you'd like.

Never paste API keys, tokens, cookies or private code into an issue, a log or a screenshot. Agent CLI output can contain them, so check before you post.

## Getting started

You need macOS 26 or later, Xcode 27 or later, and [XcodeGen](https://github.com/yonaskolb/XcodeGen).

```sh
brew install xcodegen
git clone https://github.com/<you>/coincide.git
cd coincide
xcodegen generate
open Coincide.xcodeproj
```

`Coincide.xcodeproj` is generated from `project.yml` and is not checked in, so don't edit it in Xcode's project settings. To change targets, build settings or packages, edit `project.yml`. Run `xcodegen generate` again after that and after adding or removing source files.

To try your build, install and sign in to at least one agent CLI (see [Agents](README.md#agents)). Set `COINCIDE_DATA_DIR` to a scratch folder to keep test threads away from your real ones in `~/Library/Application Support/Coincide`.

Builds are signed ad hoc by default. If your agent configuration lives in a protected folder (for example `~/.claude/CLAUDE.md` linked into `~/Documents`), macOS asks Coincide for access the first time an agent reads it, and an ad-hoc build gets a new identity on every build, so it asks again each time. To keep the answer, sign your builds with your own identity: create a gitignored `Local.xcconfig` in the repository root, as described in `Signing.xcconfig`, then run `xcodegen generate`.

## Project layout

| Path | What's there |
|---|---|
| `CoincideKit/` | Everything that isn't UI: models, storage, the provider interface and each provider, the turn runner, mid-thread handoff, git, worktrees and checkpoints |
| `Coincide/` | The AppKit app: window, sidebar, command palette, transcript, composer, diff inspector, terminal, settings |
| `CoincideKitTests/` | Unit tests (Swift Testing) and opt-in live provider tests |
| `Fuzz/` | libFuzzer targets for the parsers in CoincideKit (see [Fuzzing](#fuzzing)) |
| `scripts/` | Maintenance scripts, such as `sync-strings.sh` |

## Code style

- Swift 6 with strict concurrency. The app target defaults to `@MainActor` isolation; CoincideKit defaults to `nonisolated` and states isolation explicitly (`@MainActor` on stores, the registry, the runner and sessions). Keep it that way.
- Put logic in CoincideKit, where it can be unit tested, and keep `Coincide/` to UI.
- Follow the patterns already used next to the code you change. A new provider follows the shape of the existing ones in `CoincideKit/Providers/`.
- Discuss new dependencies in an issue first. Coincide has one package dependency (SwiftTerm) and aims to keep it that way.

## Tests

Run the unit tests the way CI does:

```sh
xcodebuild -project Coincide.xcodeproj -scheme Coincide -destination 'platform=macOS' test
```

New behavior needs tests, and bug fixes should come with a regression test when practical. Tests use [Swift Testing](https://developer.apple.com/documentation/testing).

Live provider tests drive the real agent CLIs with your own signed-in accounts and spend a little of your quota, so they only run when you ask, and CI never runs them:

```sh
xcodebuild -project Coincide.xcodeproj -scheme Coincide -destination 'platform=macOS' test TEST_RUNNER_COINCIDE_LIVE_TESTS=1
```

Some suites have their own switches or scratch-folder settings (`COINCIDE_LIVE_DIR`, `TEST_RUNNER_COINCIDE_LIVE_CURSOR_ACP=1`, …), described at the top of each `*LiveTests.swift` file. Run the live tests for any agent whose provider code you change.

## User-facing text

Write user-facing text with `String(localized:)` (or a localized SwiftUI/AppKit API), in CoincideKit too: Kit strings resolve through the app's string catalog. After adding or changing text, update the catalog and commit the result:

```sh
scripts/sync-strings.sh
```

It builds the app and syncs `Coincide/Resources/Localizable.xcstrings` with every string in use.

Coincide ships in 18 languages besides English. New or changed strings fall back to English until they are translated, so translate them for every language in the same pull request:

```sh
scripts/translations.py missing de > de.json   # the strings German lacks, with their English text
# translate de.json into {"key": "translation"}; give counted strings plural forms (see the script's help)
scripts/translations.py check de de-translated.json
scripts/translations.py import de de-translated.json
```

`check` refuses a translation whose placeholders don't match the English, or whose plural forms aren't the language's own. Imported strings are marked "needs review" in the catalog. Write whole sentences with placeholders rather than joining pieces in code, so each language can order the words its own way.

## Fuzzing

`Fuzz/` is a separate Swift package with one libFuzzer target per area. Each target compiles the real CoincideKit files through symlinks, so it always tests the current code, and checks invariants as well as memory safety:

| Fuzzer | What it checks |
|---|---|
| `JSONValueFuzzer` | `JSONValue` (every agent wire protocol): parsed JSON encodes and reads back unchanged, accessors agree, `displayText` reads back as the same number |
| `GitOutputFuzzer` | `git status --porcelain=2`, `git diff --numstat`, `git worktree list` and path unquoting read back exactly what git would write; branch names stay valid |
| `DiffParserFuzzer` | `DiffParser` reads back patches written the way `git diff` writes them (renames, modes, binaries, quoted names), and keeps counts and line numbers consistent for any text |
| `DiffGeneratorFuzzer` | The diffs written for ACP agents and Cursor parse cleanly and, applied to the old text, give the new text |
| `TerminalTextFuzzer` | Escape-sequence stripping removes exactly the escape sequences, output tails stay within their limits, clipping keeps whole characters |
| `HandoffFuzzer` | Saved threads load leniently and save back unchanged; CLI imports preserve source bytes and session identity; handoff recaps cover what each agent missed and stay within budget |

The Fuzz workflow runs them on Linux (in the official `swift` Docker image, with AddressSanitizer) for pull requests that change a fuzzed file, weekly and on demand. A failure uploads the input that caused it as the `fuzz-failure-<fuzzer>` artifact.

- **Reproduce a failure on any Mac:** `Fuzz/fuzz.sh replay <fuzzer> <downloaded file>`. This uses Xcode's toolchain, so you can debug it in the usual way.
- **Replay all seed inputs:** `Fuzz/fuzz.sh replay`.
- **Fuzz locally:** libFuzzer is not part of Xcode. Install a [swift.org toolchain](https://www.swift.org/install/) (or use the `swift` Docker image), then run `Fuzz/fuzz.sh build <fuzzer>` and `Fuzz/fuzz.sh run <fuzzer> 120`.
- **After fixing a bug a fuzzer found,** add the (minimized) input to `Fuzz/Corpus/<fuzzer>/` so it stays covered.
- **To fuzz another file,** symlink it into the fuzzer's folder in `Fuzz/Sources/`, add its path to `paths` in `.github/workflows/fuzz.yml`, and run `Fuzz/fuzz.sh check`. Fuzzed files must build on Linux, so they cannot use AppKit or other Apple-only APIs.

## Pull requests

`main` is protected: every change, the maintainer's included, lands through a pull request, and the checks marked **Required** must pass before it merges. Pull requests run CI (build and unit tests), CodeQL for the workflows, dependency review and, when a fuzzed parser changes, the fuzzers.

1. Fork the repository and create a branch from `main`.
2. Keep each pull request to one fix or feature.
3. Run the unit tests, and the live tests and fuzzers that cover what you changed.
4. Fill in the pull request template: what changed and why, how you tested it, and screenshots for UI changes.
5. Respond to review comments by pushing to the same branch.

There is no CLA, and commits don't need a `Signed-off-by` line (no DCO).

### AI-assisted contributions

Contributions written with AI coding tools are welcome; Coincide is a tool for exactly that. Say in the pull request which tool you used and for what. You are responsible for every line: read and understand it, run the tests, and make sure it follows this guide. Pull requests that look unreviewed may be closed.

## License

By contributing, you agree that your contributions are licensed under the [Functional Source License, Version 1.1, MIT Future License](LICENSE.md) (FSL-1.1-MIT).
