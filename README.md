# Coincide

[![CI](https://github.com/apoorvdarshan/coincide/actions/workflows/ci.yml/badge.svg)](https://github.com/apoorvdarshan/coincide/actions/workflows/ci.yml)
[![OpenSSF Best Practices](https://www.bestpractices.dev/projects/15854/badge)](https://www.bestpractices.dev/projects/15854)
[![OpenSSF Scorecard](https://api.scorecard.dev/projects/github.com/apoorvdarshan/coincide/badge)](https://scorecard.dev/viewer/?uri=github.com/apoorvdarshan/coincide)

Coincide is a native desktop interface for coding agents, with a Rust core and GPUI desktop application for macOS, Windows and Linux. It uses the agent CLIs and accounts you already have. Coincide Remote is the separate iPhone and iPad companion.

The Rust desktop is in development. Platform acceptance and feature parity are still being verified; see [Rust status](docs/rust/STATUS.md) and the [UI audit](docs/rust/UI-UX-AUDIT.md) for recorded work and limitations.

## Downloads and releases

The current public `v0.1.0` release, Homebrew cask and npm installer contain the **retired Swift macOS app**, not the Rust app. The Rust release pipeline has not been configured; the release workflow fails closed until it is ready. See [release status](docs/releasing.md).

## Develop the Rust desktop

Install a Rust toolchain and the native dependencies for your platform. On macOS, install the Xcode command-line tools. The platform CI configuration lists Linux and Windows dependencies.

```sh
cargo build -p coincide-desktop --bin coincide-rust --locked
cargo test -p coincide-core --locked
```

Packaging uses explicit built binaries and a scratch directory. See [Rust packaging](docs/rust/packaging.md); packaging checks alone do not establish signing, installation, updater or platform acceptance.

## Coincide Remote

The iOS app and its tests remain in `CoincideRemote/`, `CoincideRemoteKit/`, `CoincideRemoteTests/`, and `CoincideRemoteUITests/`. Generate its Xcode project with `xcodegen generate --spec project-remote.yml`. Its store configuration is documented in [store/README.md](store/README.md). Compatibility between the Rust desktop and the companion is still being mapped and verified; see [Remote port notes](docs/rust/REMOTE.md).

## Repository

| Path | Purpose |
|---|---|
| `crates/coincide-core/` | Rust application core, storage and agent integrations |
| `crates/coincide-desktop/` | GPUI desktop interface and native integrations |
| `crates/coincide-native-host-tests/` | Desktop native-host test fixtures |
| `CoincideRemote/`, `CoincideRemoteKit/` | iOS companion and its protocol package |
| `windows/` | Earlier Windows implementation and its checks |
| `website/`, `discord/` | Website and community support service |
| `docs/rust/` | Rust design, acceptance and packaging records |

The retired Swift desktop source remains accessible in Git history. The CI baseline and fuzz workflows explicitly test its final frozen commit; those results do not validate changes to the Rust app.

## Contributing and security

See [CONTRIBUTING.md](CONTRIBUTING.md) and [SECURITY.md](SECURITY.md). Coincide follows the design of [T3 Code](https://github.com/pingdotgg/t3code). Third-party attributions are in [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md).

Coincide is released under the [MIT License](LICENSE).
