# Browser credential sink integration

The macOS bridge now supports native credential filling after eleven real WebKit
fixture groups passed; see [native acceptance](NATIVE_CREDENTIAL_ACCEPTANCE.md).
Linux and Windows remain unavailable. Approval is native-only: no agent/browser
JSON command can approve a fill or return its password/code.

## Parent hooks

Main registers the shared `credentials` and `credential_settings` modules.
On the UI thread, it obtains `browser.credential_page(thread, cx)`, passes that
page and `browser.credential_fill_available()` to the retained workflow, polls
native approval decisions, then calls `browser.drain_credential_fills` with the
private job receiver. Jobs never pass through Engine, BrowserRequest, persisted
settings or page IPC.

The selected thread's active tab must be loaded. Native URL access and its
navigation epoch bind approval to an HTTPS origin. Navigation, reload, history
restoration and tab close invalidate the epoch; thread/tab changes invalidate
workflow scope. Missing or stale bindings fail without delivery.

## macOS implementation

`browser_credentials_macos.rs` obtains the pinned Wry WKWebView and uses a named
isolated `WKContentWorld`. A secret-free probe binds a random ticket to the exact
Document and eligible field objects. Its callback rechecks native origin,
navigation epoch and the revocable permit before dispatching the fill.

Static JavaScript receives credentials as native NSDictionary arguments; values
are never interpolated into script source, sent through Wry IPC or returned by
its completion. The isolated world avoids page overrides of input prototypes.
The final synchronous script checks ticket, document, origin, field identity,
type, form and deadline, writes visible/enabled login fields, dispatches input
and change events, and confirms assignments again. Ambiguous targets fail. It
never submits a form. Password and OTP fields may support separate login steps.

**Final native dispatch is the commit boundary.** Revocation before dispatch
blocks delivery. Already dispatched WebKit renderer work cannot be retracted;
its document binding and deadline still apply. A ten-second worker timeout is
not a guarantee that already-dispatched DOM work can be undone. The bridge
retains at most two outstanding native operations, including stalled callbacks.

Completions contain only success/coarse `Failure`, never NSError descriptions,
credentials or DOM snapshots. The controller clears and suppresses console
capture for an approved document until navigation completes; console replies
report `credentialCaptureSuppressed`. A site necessarily owns values entered
into its fields. This is not containment of a hostile site's reflection or
exfiltration, and native fill is not exposed as an autonomous agent action.

## Verification scope

`cargo test -p coincide-desktop --locked` passed 47 tests before native acceptance.
The dedicated native harness used only synthetic vault data and local HTML with
an HTTPS base URL, without a certificate exemption. Exact cases and artifact
hashes are recorded in the linked report. Visual manager/account selection,
approval keyboard/accessibility behavior and the integrated console suppression
flow remain separate native acceptance work. No real vault/login was tested.
