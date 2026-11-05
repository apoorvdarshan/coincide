# Browser credential sink integration

The native browser bridge supplies a **disabled** credential sink until the
backend can prove atomic original-document and revocable-permit checks at the
actual field mutation. Current Wry asynchronous evaluation cannot supply this.
No credentials are placed in scripts, BrowserReply, console, or DOM by this sink.
This checkpoint does not implement successful native autofill.

## Parent hooks

Register `mod credentials;` alongside `mod browser;` in the parent. The browser
registers its own private `browser_credentials.rs` helper; it uses the same
`crate::credentials` types as the native workflow. Do not create duplicate
credential module instances. The worker deliberately does not edit main.rs.

On the native UI thread, with the selected thread ID:

1. `let page = browser.credential_page(thread, cx);`
2. `let available = browser.credential_fill_available();` (currently false)
3. `workflow.set_page(page, available, cx);`
4. `workflow.poll(cx);` and render the native workflow/ApprovalView.
5. `browser.drain_credential_fills(thread, &fill_jobs, cx);`

The workflow owns the approval decision and shared revocation scope. Pass the
`FillJob` receiver returned at workflow construction directly to the browser;
never route it through the engine, BrowserRequest, persisted settings, or page
IPC. While availability is false, metadata discovery is allowed but approval
and secret fetch must remain disabled. Do not register an agent allow action.

`credential_page` selects only that thread's active tab, refuses loading pages,
reads the URL from native Wry instead of JavaScript, and checks navigation epoch
before/after native URL access. HTTPS origin validation uses PageBinding. Tab
IDs are generated globally as UUIDs. Navigation policy and page-load-start
callbacks advance the epoch; explicit navigation and tab close invalidate it.
This is suitable for fail-closed metadata/approval invalidation, not proof of
atomic mutation in a later document.

Draining verifies the selected thread/tab again. A missing or changed binding
fails StalePage; an invalid permit fails FillFailed; a matching live binding
still fails Unavailable because no backend has been accepted. Errors are sent
only to the private acknowledgement channel; no normal browser reply is emitted.
The sink never formats, copies or logs supplied credential arguments.

## Required before enabling a backend

A future implementation must preserve the original document identity through
redirects, reload/history restoration and close, validate revocable FillPermit
at mutation rather than at dispatch, restrict writes to appropriate visible,
enabled top-level login fields, confirm writes without returning values, and
never submit. Origin checking followed by a delayed evaluate_script is not an
atomic binding. Scripts carrying secrets in the page world are not acceptable.
The normal read/console channels also need a proven design against reflected
credential content before successful autofill can be exposed to agent control.
Do not set availability true based only on OS name or raw WKWebView access.

## Synthetic verification

Run on the coordinator's allocated lane:

```sh
cargo test -p coincide-desktop --test browser_credential_integration
cargo test -p coincide-desktop --test credential_integration
cargo test -p coincide-core credentials::tests
```

The browser credential integration harness uses the real private channel and
synthetic VaultCommand only. It verifies matching-document unsupported failure
and navigation failure are acknowledged to the waiting worker, plus epoch,
origin, tab, closed-page and permit-validation cases. It makes no real vault or
account calls. It does not test successful DOM filling.

For native negative acceptance, serve `crates/coincide-core/tests/fixtures/` on
loopback and open `browser-credentials.html` in an allocated synthetic candidate
thread. HTTP must yield no PageBinding and approval/fetch must remain disabled.
With a coordinator-owned HTTPS fixture, metadata may be available, but approval
must still remain disabled while availability is false. Never weaken certificate
validation or access a real vault to exercise this checkpoint. Use a synthetic
workflow runner when testing metadata selection; after navigation/reload/close
or selected-thread/tab changes, approval must be invalidated. Inspect the fixture
via #inspect: changes/submissions remain zero. Check normal read/console and
agent replies have no synthetic secret sentinel. Existing apps need no restart.
Successful native filling remains untested and unavailable.
