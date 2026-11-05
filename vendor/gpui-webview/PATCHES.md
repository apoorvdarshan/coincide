# Coincide pinned release-observer patch

Base: exact published gpui-webview 0.9.0, crates.io checksum
`10995df6a65620593b2f8281bb8b691893343611faa11d4b6d302d6b9b2503f8`,
VCS `7591a35eced761e3613c01e71ff04c10129dae1a`, upstream
https://github.com/longbridge/gpui-kit/tree/7591a35eced761e3613c01e71ff04c10129dae1a/crates/webview .
Original file SHA256s and license source URLs/hashes are in SOURCE-PROVENANCE.json.
Published package lacks license texts; LICENSE-APACHE and LICENSE-DOCS.md were
retrieved unchanged from that exact official upstream commit. The generated
registry Cargo.toml, Cargo.toml.orig, Cargo.lock, README and macos.rs stay exact.
Only the local .cargo-ok cache marker was excluded.

Changed runtime files: src/lib.rs, src/composition.rs, src/linux.rs.
New implementation/tests: src/release.rs. No lb-wry/Objective-C allocator edits,
new dependencies, native subclass/swizzle, private WebKit calls or browser mount.

## Additive opt-in API

- ReleaseRegistry::new(), close(), snapshots(), poll(&mut App).
- WebView::build_with_release_registry(builder, window, cx, &registry).
- WebView::release_receipt() -> Option<ReleaseReceipt>.
- WebView::element_payload(cx) returns the concrete native element used by
  normal Render. This supports explicit Rust ownership without holding an
  arena-backed AnyElement outside its frame. Calling Render outside drawing
  can allocate nested elements in GPUI's fallback arena; such a test holder
  does not release its payload merely by dropping AnyElement.
- Receipt::snapshot() publishes opaque stable ID, SurfacePhase,
  RustOwnerPhase, ReleaseTaskPhase, NativeReleasePhase::Unknown.

Caller retains registry and parent window/event loop while explicit release is
pending. Closing registry blocks new tracked construction, not cleanup. Receipt
is minted before construction; initialization/cleanup failures stay Unknown.
There is no ready(), updater consent, native teardown assertion or automatic
BrowserController close driver.

All existing new/build/raw/handle/Deref/public WebViewElement::new signatures
remain. The private Wry value now shares an Option-backed owner across normal
Entity/frame/handle clones; its final Drop explicitly drops actual Wry before
publishing DropReturned. Legacy public Rc<wry> element construction remains a
separate Legacy path with no fabricated tracked receipt. Existing untracked
surface release still uses original detached behavior. Tracked release instead
retains and polls the actual foreground Task; result/future destruction precede
published Returned/Removed. Failed removal keeps exact surface/native-resource
custody and error, with no automatic retry. Registry-to-task-to-receipt paths use
Weak registry refs to avoid a strong ownership cycle. Lost registry/task panic
is Abandoned/Unknown, not successful removal. macOS keeps the original-parent
reattach before removing the composition surface. Tracked Linux waits for all
escaped tracked Rc handles to drop before destroying Wry's X11 child and then
removing the parent surface; UI polling stays asynchronous.

These are Rust/UI-task ownership facts. They do NOT establish WKWebView or
WKUserContentController superclass-dealloc return, callback-block release,
remote WebKit process termination, profile durability or full application
readiness. NativeReleasePhase always remains Unknown. Default/legacy behavior
and ordinary Coincide Quit policy are not deliberately changed.

## Headless tests (not executed by worker)

Filter `release::tests`: held frame/handle clones postpone actual Rust drop;
early semantic flag does not finish a gated future or drop captures;
actual ready GPUI Task result consumption; failed Task preserves custody;
panicked future remains Unknown and is not repolled; registry/task/receipt has no
strong owner cycle; opaque identities cannot settle a different view; closed admission and unknown construction cleanup fail
closed. No WebView/window/native runtime is created by these tests.

Root owns path patch/lock/workspace exclusion/CI filters/scratch manifests and
Cargo allocation. Standalone vendor tests need a selected gpui-kit backend and
matching gpui-fast feature if applicable; no worker Cargo was run. Preserve all
existing upstream tests and platform modules. Native validation remains pending.
