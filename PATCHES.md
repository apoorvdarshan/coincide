# Pinned dependency patches

## gpui-pre 0.3.11: accessibility rollback on prepaint retry

`vendor/gpui-pre` starts from the exact published crates.io `gpui-pre` 0.3.11
package (164 files, 8,521,599 uncompressed bytes). The runtime patch changes the
two source files listed below; test-only prerequisites are documented separately.
The source archive SHA-256 is
`9303c771abf2acff2a96d706f69d9a82088c4770173a07cce88f0002431d887d`, matching
Coincide's pre-patch Cargo.lock checksum. The cached registry source was also
verified byte-for-byte against that archive before copying.

Upstream package: [gpui-pre 0.3.11](https://crates.io/crates/gpui-pre/0.3.11).
Its published manifest identifies [zed-industries/zed](https://github.com/zed-industries/zed)
and describes the snapshot as `zed@f816e1f`. The GitHub commits API resolves that
abbreviation to `f816e1f9263e3a8ef63c4baaa02e1441ce1c6038`.
The package's Apache-2.0 license, copyright notices, original Cargo.toml.orig,
resources and examples are preserved. The normalized manifest and standalone
lock add only the test prerequisites described below. This does not change
Coincide's license.

### Change

- `src/window.rs`: `Window::transact` takes an accessibility prepaint snapshot
  and restores it when the prepaint closure returns an error, alongside the
  existing hitbox/dispatch/layout rollback.
- `src/window/a11y.rs`: snapshot and restore the complete per-frame node builder
  (including parent child lists, completed nodes, seen IDs, focus, active
  descendant, and debug provenance), focus map, node bounds (including overwritten
  existing/reused bounds), focus diagnostic, and debug view-name cache. Listener
  registration is append-only during prepaint, so restore pre-existing lengths
  and remove new listener entries without cloning callback closures.

A virtual list retries prepaint when a child's native text-range reveal requests
an autoscroll. Previously, accessibility nodes from the abandoned pass remained:
retrying the same visible buttons panicked on duplicate IDs in debug builds and
silently lost nodes in release builds. Accessibility remains enabled, IDs remain
stable, and selection/range-reveal behavior is unchanged. Persistent platform
activation, window title, and the last published debug tree are not rolled back.
Inactive accessibility does not clone the snapshot.

### Regression coverage and validation

Added three tests with the `prepaint_transaction` name prefix:

- Restore existing/cached bounds, tree children, duplicate-ID tracking, focus,
  active descendant, listener additions, and debug metadata after a failed pass.
- Exercise actual `Window::transact` through the headless TestAppContext platform,
  including nested failures and a successful retry of the same accessibility ID.
- Avoid a snapshot while accessibility is inactive.

After root workspace patch/lock registration, run:

```sh
cargo test --manifest-path vendor/gpui-pre/Cargo.toml --features test-support --lib prepaint_transaction --locked -- --nocapture
```

All three focused headless regressions pass, including the actual failed/nested
Window::transact retry. The patched desktop suite passes 242 tests. Workspace
patch/lock registration and CI sparse-checkout coverage are included. No registry
source cache was edited. Native far-row Find acceptance remains pending: the
user has stopped desktop interaction, and no UI launch or input is authorized.
No accessibility-disable or application ID workaround is included.

### Upstream test font fixtures

The published crate omits the repository fonts referenced by its existing
`svg_renderer.rs` unit tests. `vendor/assets/fonts` supplies only the two regular
fonts and their accompanying licenses, copied byte-for-byte from
[the exact upstream snapshot](https://github.com/zed-industries/zed/tree/f816e1f9263e3a8ef63c4baaa02e1441ce1c6038/assets/fonts).
The two test-only `include_bytes!` paths are corrected from `../../../assets`
to `../../assets`, resolving these fixtures within `vendor`. Both fonts retain their upstream SIL Open Font License 1.1
notices; these fixtures do not change Coincide's license. SHA-256 hashes:

- `ibm-plex-sans/IBMPlexSans-Regular.ttf`: `975dcda37d80f038dcd143c22e33ca2d97a0cc5a929aace1c749153b0fe1afa5`
- `ibm-plex-sans/license.txt`: `91c25c350d3cac39da2736d74f7ba37ef648f5237a4e330a240615bc8d8c4360`
- `lilex/Lilex-Regular.ttf`: `8a467ad5a1941dc7c9cebaee34e3ed9364a73b48393034e363e4b528bd711d04`
- `lilex/OFL.txt`: `a356708a399e3f54b937ec7d9b722c26dabba21365b60f95c56eb7ebca0dee40`

### Standalone unit-test prerequisites

The published manifest omits the `util_macros::perf` test dependency. Complete
`crates/util_macros` and `tooling/perf` trees are copied from the same pinned
upstream snapshot, including Apache-2.0 licenses. Upstream license symlink targets are materialized
as the exact root LICENSE-APACHE contents (SHA-256 `752daf2fb234ca4a1fa372c073fe127f44b7b90fd2529ae44273a64f9d53da7a`). Only their Cargo manifests
are normalized: upstream edition 2024, explicit workspace dependency versions
and features, local perf path, and removal of inherited workspace lint references.
The perf collections dependency uses the existing matching `gpui-pre-collections`
0.3.11 package. No macro implementation, test body, or performance behavior is
changed. GPUI adds only a development path dependency on util_macros. Root owns
standalone lock generation and workspace exclusion; no Cargo was run by this worker.

Original upstream file SHA-256 hashes (before manifest normalization):

- `vendor/util_macros/Cargo.toml`: `bece094d5a629c5a9705c9be1cb111ac5eaf24a0795d1723c6ed3c983925967a`
- `vendor/util_macros/LICENSE-APACHE`: `9cff568488e9d56aae60f162404acdb15d8533a0202cf01f6eb0843b264f20ff`
- `vendor/util_macros/src/util_macros.rs`: `05eb38806327fafab5bd5b53f4c82b295d6842b97f1f3011e8317c6ada41b01d`
- `vendor/perf/Cargo.toml`: `0c9bc1e39ad8933ff3fd7b24d15c7f0338ecdb1eb1d75a6b7ef5fd3c14100e3d`
- `vendor/perf/LICENSE-APACHE`: `9cff568488e9d56aae60f162404acdb15d8533a0202cf01f6eb0843b264f20ff`
- `vendor/perf/src/implementation.rs`: `f96fd7b56d90f09bf29094ef0e996ac68bd608f229ad30433f0d099eedd4e9bd`
- `vendor/perf/src/lib.rs`: `99642ba124e5126214ac17f77d99e8897bc1468df4e48e489ea486761c41774b`
- `vendor/perf/src/main.rs`: `191346195037c3939d9e74db75e77da8168806ae0bba944d0d4bfdc09934f515`
