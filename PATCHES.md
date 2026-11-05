# Pinned dependency patches

## gpui-pre 0.3.11: accessibility rollback on prepaint retry

`vendor/gpui-pre` contains the exact published crates.io `gpui-pre` 0.3.11
package (164 files, 8,521,599 uncompressed bytes), except the two source files
listed below. The source archive SHA-256 is
`9303c771abf2acff2a96d706f69d9a82088c4770173a07cce88f0002431d887d`, matching
Coincide's pre-patch Cargo.lock checksum. The cached registry source was also
verified byte-for-byte against that archive before copying.

Upstream package: [gpui-pre 0.3.11](https://crates.io/crates/gpui-pre/0.3.11).
Its published manifest identifies [zed-industries/zed](https://github.com/zed-industries/zed)
and describes the snapshot as `zed@f816e1f`. No full upstream commit is inferred.
The package's Apache-2.0 license, copyright notices, original normalized and
original Cargo manifests, resources, examples, tests, and bundled Cargo.lock are
preserved unchanged. This does not change Coincide's license.

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
cargo test -p gpui-pre --lib prepaint_transaction -- --nocapture
```

At this checkpoint only rustfmt parsing/checks, package byte comparisons,
whitespace checks, and source review have run. Tests, compilation, dependency
registration, CI sparse-checkout/native-archive updates, and native far-row Find
acceptance are owned by the coordinating thread and remain pending. No registry
cache was edited. No unrelated upstream formatting, manifest, lockfile, dependency
version, accessibility-disable, or application ID workaround is included.
