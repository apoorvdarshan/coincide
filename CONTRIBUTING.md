# Contributing to Coincide

Thanks for your interest in Coincide, a native Rust desktop app for the coding agents you already use, ported from [T3 Code](https://github.com/pingdotgg/t3code). Bug reports, feature ideas and pull requests are all welcome.

Please read and follow the [Code of Conduct](CODE_OF_CONDUCT.md). Report security issues privately as described in [SECURITY.md](SECURITY.md), never in a public issue.

## Reporting bugs and requesting features

- **Bug:** [open the bug report form](https://github.com/apoorvdarshan/coincide/issues/new?template=bug_report.yml). Include your macOS version, the Coincide version, which agent CLI (and its version) was involved, exact steps, and any error text or logs.
- **Feature:** [open the feature request form](https://github.com/apoorvdarshan/coincide/issues/new?template=feature_request.yml). Describe the problem first, then the change you'd like.

Never paste API keys, tokens, cookies or private code into an issue, a log or a screenshot. Agent CLI output can contain them, so check before you post.

## Getting started

Install a Rust toolchain and the native dependencies for your platform. The desktop is in `crates/coincide-desktop`; the shared application core is in `crates/coincide-core`.

```sh
cargo build -p coincide-desktop --bin coincide-rust --locked
cargo test -p coincide-core --locked
```

The Rust CI workflow lists native dependencies and runs platform-specific checks. See [Rust packaging](docs/rust/packaging.md) for disposable build staging. Do not overwrite an active installation to test a candidate.

Coincide Remote remains a separate iOS app. Generate its committed project with `xcodegen generate --spec project-remote.yml`; generate its test project with `xcodegen generate --spec project-remote-tests.yml`. Its unit and UI tests run in GitHub Actions. For the iOS catalog, use `scripts/sync-strings.sh ios` and `scripts/translations.py`.

## Project layout and style

- `crates/coincide-core/`: Rust state, provider integrations and tests.
- `crates/coincide-desktop/`: GPUI interface and platform integrations.
- `CoincideRemote/`, `CoincideRemoteKit/`, and their test folders: the iOS companion.
- `windows/`: earlier Windows implementation and its checks.
- `website/` and `discord/`: website and support service.

Follow the existing conventions, format Rust with `cargo fmt`, and include focused regression coverage when changing behavior. Discuss new dependencies in an issue first.

## Tests and fuzzing

Rust checks run on macOS, Windows and Linux in `.github/workflows/rust.yml`; iOS unit and UI tests run in `.github/workflows/ios-tests.yml`. The retired Swift desktop's complete unit-test and fuzz suites continue against the pinned final legacy commit to preserve their existing checks. These frozen baseline runs do not test the current Rust implementation; Rust fuzz coverage remains separate work.

## Pull requests

`main` is protected: every change, the maintainer's included, lands through a pull request, and the checks marked **Required** must pass before it merges. Pull requests run the required Rust core and legacy baseline checks, CodeQL for the workflows, and dependency review. The separate Rust workflow covers platform-specific changes. The iOS tests run when a pull request changes what Coincide Remote is built or tested from, and are skipped otherwise (`IOS_PATHS` in `.github/workflows/ios-tests.yml`).

1. Fork the repository and create a branch from `main`.
2. Keep each pull request to one fix or feature.
3. Run the checks that cover what you changed and report any you could not run.
4. Fill in the pull request template: what changed and why, how you tested it, and screenshots for UI changes.
5. Respond to review comments by pushing to the same branch.

There is no CLA, and commits don't need a `Signed-off-by` line (no DCO).

### AI-assisted contributions

Contributions written with AI coding tools are welcome; Coincide is a tool for exactly that. Say in the pull request which tool you used and for what. You are responsible for every line: read and understand it, run the tests, and make sure it follows this guide. Pull requests that look unreviewed may be closed.

## License

By contributing, you agree that your contributions are licensed under the [MIT License](LICENSE).
