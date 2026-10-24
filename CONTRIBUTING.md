# Contributing to Coincide

Thanks for your interest in Coincide, a native macOS chat app for the Codex and
Claude CLIs. The project has one maintainer,
[@apoorvdarshan](https://github.com/apoorvdarshan), who reviews every change.

By taking part you agree to follow the [Code of Conduct](CODE_OF_CONDUCT.md).

## Reporting bugs and requesting features

- Use [GitHub Issues](https://github.com/apoorvdarshan/coincide/issues/new/choose)
  with the bug report or feature request form. Search existing issues first.
- Report security problems privately as described in [SECURITY.md](SECURITY.md),
  not in a public issue.
- Remove API keys, tokens and personal data from logs and screenshots.

## Development setup

You need macOS 14 or later, a Swift 6.2 or later toolchain, Xcode Command Line
Tools and Python 3. The Codex and Claude CLIs are only needed to try
provider features; building and testing do not need provider accounts.

```sh
swift build                                                  # build every target
swift test --no-parallel                                     # Swift unit and integration tests
python3 -m unittest discover -s UITests/macOS -p 'test_*.py'  # CLI and CI-configuration tests
./script/build_and_run.sh                                    # package and open the app
```

The tests run serially (`--no-parallel`) because process and terminal tests
share timers. The Python tests do not launch the app. The desktop UI suite in
`UITests/` drives real windows and runs in GitHub Actions; you don't need to run
it locally. `Tests/Fuzz/` holds an [Atheris](https://github.com/google/atheris)
fuzz target for `script/coincide`, which CI runs with ClusterFuzzLite.

## Pull requests

Every change, including the maintainer's own, reaches `main` through a pull
request, and merging requires the required checks to pass.

1. Fork the repository and branch from `main`.
2. Keep each pull request to one focused change, and explain what it changes
   and why. Link the issue it fixes, if there is one.
3. Add or update automated tests for new functionality and for bug fixes.
   Shared logic belongs in `CoincideCore`, with tests in `Tests/CoincideCoreTests`.
   If something cannot be tested automatically, explain how you checked it.
4. Update `README.md` or `docs/` when behavior changes.
5. Run the build and tests above, then fill in the pull request template with
   what you ran.

The maintainer reviews pull requests as time allows and may ask for changes. No
second reviewer is required.

## What makes a change acceptable

- It builds without new compiler warnings and keeps all existing tests passing.
- It follows the style of the surrounding code: Swift API Design Guidelines
  naming, 4-space indentation, and SwiftUI/AppKit for app UI.
- Python scripts in `script/` and `UITests/` use only the standard library.
- It contains no credentials, tokens, provider configuration, Coincide workspace
  data, or build output (`.build/`, `dist/`).
- Third-party code keeps its license notice in `docs/` and is listed in
  `docs/third-party-notices.json`.
- Commit messages start with a short imperative summary, such as
  "Fix provider settings navigation".

## License

Coincide is released under the [MIT License](LICENSE). By contributing, you
agree that your contributions are licensed under the same terms.
