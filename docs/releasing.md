# Desktop release status

The Swift macOS desktop implementation has been retired. The existing public release, Homebrew cask and npm installer still distribute that historical build. The `Release` workflow deliberately fails closed for desktop tags and manual runs until a Rust release pipeline is implemented and validated; it publishes nothing.

The Rust staging and validation tools are documented in [rust/packaging.md](rust/packaging.md). They do not by themselves constitute a signed, notarized, tested or published release. Coincide Remote's separate iOS release setup is described in [store/README.md](../store/README.md).
