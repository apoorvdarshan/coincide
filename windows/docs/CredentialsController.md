# Native credentials controller

`App/CredentialsController.h` composes the existing settings pane, private vault/CLI
adapters, two-phase fill broker, and trusted browser credential bridge. It never
submits a form. Production password/passkey acceptance is separate from synthetic
fixture results; native WebAuthn/Hello remains unconnected as stated in the pane.

## Root integration

Create one controller on the initialized WinUI dispatcher with the app data folder.
Keep that controller and the BrowserPanel alive until shutdown. Opening/constructing
it reads only manager preferences; missing preferences mean every manager is off.
There is no executable discovery, CLI invocation, vault enumeration, import,
browser observation, authentication, or unlock during construction or selection.

- `create(dataDirectory, Services = {}) -> shared_ptr<CredentialsController>`
- `view() -> StackPanel`
- `select_thread(threadID)`, `tick()`, `cancel_navigation(opaqueFrame)`, `close()`
- `refresh(manager)`, `choose_csv()` are explicit native actions.
- `fill_login(browser, threadID, tabID = {}, item = {}, Cancel = {}) ->
  IAsyncOperation<JsonObject>` captures the originating thread. The operation
  marshals itself to its owning dispatcher; other public native UI methods belong
  on that dispatcher. Never block the dispatcher with `.get()`.

`Services.show_panel(threadID)` runs only when an explicit request has one matching
login and needs Allow once. Root can restore/show the appropriate window and select
that originating conversation there. Root owns any subsequent restoration/hiding;
the controller never closes or hides an already visible pane/window. The selected
conversation must match before the approval card is shown. Changing to a different
conversation cancels the old request.

Connect `BrowserPanel::set_navigation_callback` to a weak controller reference and
`cancel_navigation(frame)`. The browser invalidates its opaque frame mapping before
that callback. `tick()` additionally validates a pending explicit approval's live
context and expires requests; idle ticks do not observe the browser. Call `close()`
on owner shutdown to revoke all transient tickets and cancel private handoffs.

`Services.choose_csv` is a callback-based owner-window picker. Reply with a selected
local path or `nullopt`; choosing/previewing never imports. The existing pane keeps
passwords in its transient review, and invokes its import callback only for explicit
checked rows. Default import uses the scoped SavedLoginVault transaction; original
CSV files and existing vault entries remain intact. The existing pane's synchronous
import callback performs bounded local credential writes only after that native
review. Metadata listing and approved password resolution always run on workers.

## Fill policy

The browser supplies the actual frame, document/navigation binding, and exact
HTTP(S) origin. Tool payloads cannot supply an origin. Controller lookup considers
only enabled managers and exact-origin matches. Optional `item` must exactly match
a record ID, title, or username. Zero matches return `no_match`; multiple matches
return `ambiguous`, without resolving a password. Root may ask the owner to specify
one item; the controller never guesses between accounts.

Allow once is explicit, bounded to five minutes, and single-use. The controller
consumes a Permit before secret lookup, checks live context before and after the
worker lookup, and rereads metadata/fingerprints around resolution. Disable,
navigation, thread selection, external cancellation, close, expiry, or supersession
revokes it. The resulting ApprovedFill stays alive across the trusted browser
await, with its cancellation predicate and shared secrets wiped on every return
or exception. Actual SDK fill still checks its own live origin/frame/grant at each
await, marks fields private before insertion, and never submits/clicks a form.

Existing `bw.exe`/`op.exe` are discovered only when an explicit enabled CLI operation
needs them. Discovery searches absolute PATH directories and rejects reparse
paths; it never executes scripts, installers, login, unlock, lock, or logout.
Missing native executables return a safe unavailable status. CLI listing output can
contain private fields internally; adapters retain only public metadata and wipe
their transient output. No raw output or errors enter status or tool results.

The JSON result contains only `status`, plus `username` when `status == filled`.
Statuses are `filled`, `disabled`, `no_match`, `ambiguous`, `denied`, `canceled`,
`not_filled`, or `unavailable`. It contains no password, TOTP, seed, vault response,
path, private error text, or approval token. There is no persisted fill grant.

## Validation routes

`Tests/CredentialsControllerTests.h` provides:

- `credentials_controller_tests(report)`: native MTA console tests using injected
  metadata/CLI/approval/context/fill, an isolated settings folder, and synthetic
  passwords only. No WinUI window, vault, executable discovery, or real account.
- `credentials_controller_panel_tests(report, XamlRoot)`: requires an initialized
  hidden WinUI Panel host. Exercises the real manager toggles and Allow/Deny/import
  controls with injected browser/vault/picker services. Do not activate the host.

Native UI fixture source is compiled independently; its actual execution belongs
to Root's reserved hidden application test route. These fixtures do not authorize
access to an owner's vault, sign-in, actual imports, native prompts, or real fill.
