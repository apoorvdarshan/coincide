# Saved-login requests

`fill-login` opens the native password-manager workflow for the selected
conversation and active HTTPS tab. An optional `item` is a bounded login ID or
case-insensitive title hint; the user must select that matching entry and approve
its native prompt. A different thread or tab, missing manager, unavailable
private sink, or already-active native workflow is refused. This request does not
run a password-manager command, approve anything, accept a secret from JSON,
or dispatch a page script.

The native workflow keeps the original thread and PageBinding (including its
navigation epoch). Closing or changing the approval context, replacing the
document even at the same origin, declining, cancellation or expiry ends the
request. Existing private permits are revoked before any uncommitted work can
proceed; actual workers remain owned until they return. Already dispatched
renderer work cannot be retracted, so timeout/refusal instructs callers to check
the page before retrying.

The API waits up to 390 seconds plus five seconds for a receipt. It returns only
`filled: true` after the existing private renderer acknowledgement, or a fixed
coarse error. No username, password, code, permit, account metadata, raw CLI
output or provider error is returned. Native approval cannot be supplied by the
agent or page. A queued job is never treated as a successful fill.

The initial implementation uses the existing native manager/account selection;
it does not add automatic vault discovery, login, unlock, account creation or
Windows CLI process ownership. These remain distinct from enabling a validated
browser private sink. Core protocol and inert owner tests exercise request
bounds, absence of a page script, ignored agent approval/secret fields, exact
binding/thread/deadline cancellation and coarse response contents. Compilation
and those tests do not establish native approval pixels, keyboard/accessibility
or real-vault login acceptance. No personal vault or GUI was used.
