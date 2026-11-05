# Native credential integration handoff

`crates/coincide-desktop/src/credentials.rs` supplies a GPUI approval view and
an acknowledged private sink. It is compiled by the desktop integration test
harness; it is not registered in main.rs or browser.rs yet. This is not live
browser autofill. Passkeys and dictation capture/transcription remain unavailable.

Owner integration steps:

1. Main owner registers `mod credentials`, creates an `ApprovalPrompt` from
   selected metadata returned by `Vault::logins`, and displays `ApprovalView`
   in native chrome. Keep its decision receiver private. Wait off the UI thread
   for at most 300 seconds, treating timeout/drop/replacement/navigation as denial.
   Never derive an allow decision from agent JSON, website content or stored data.
2. On the same vault instance, run `complete_approval` off the UI thread using
   the original prompt, native decision, current page binding and `QueuedSink`.
   Keep the Vault alive through the approval; tokens are instance-bound.
3. Browser owner drains the bounded `FillJob` receiver on the UI thread via
   `deliver_fill`. Implement `PrivateBrowserHook` against its owned tab/view.
   `PageBinding.tab` must be globally unique across threads; navigation must
   advance on every document replacement, including redirects, reloads,
   same-origin navigation and history restoration. Tab close invalidates it.
4. `fill_bound_document` must check the provided `FillPermit` immediately before
   mutation and atomically enforce the exact original document binding. Retain
   the permit in any async callback. Ordinary delayed wry evaluate_script with
   an earlier URL check does not provide this guarantee. Return an explicit
   failure until the target backend can enforce it. Never fill a cross-origin
   frame or silently substitute a new tab/document.
5. Fill only visible, enabled login fields; avoid arbitrary page-selected
   selectors and form submission. Confirm writes before acknowledging success.
   Return only `Result<(), Failure>`; omit passwords, codes, evaluated source,
   DOM field values, raw provider errors and console logs. The website necessarily
   receives values entered into its login fields; the agent must never receive them.

The worker waits at most ten seconds for native acknowledgement. Jobs expire
before that deadline, and timeout revokes the shared permit. A queue send is not
success. Drop/unsupported backend/script errors fail closed. Native UI remains
responsive while the CLI runs. CLI executable selection is explicit and absolute;
Bitwarden uses the inherited authorized session, 1Password uses its CLI app
integration. No native secret-store migration, account selection or unlock UI is
provided yet. No real account/vault tests are authorized for this checkpoint.

Coordinator validation requested:

- `cargo test -p coincide-core credentials::tests` (updated cleanup-order test)
- `cargo test -p coincide-desktop --test credential_integration`
- strict core clippy on allocated Linux lane

Native approval accessibility/keyboard and actual browser fill acceptance remain
pending after main/browser owners integrate the hooks. Never advertise this module
as a working browser fill capability until that acceptance succeeds.

## Native manager/account panel

`credential_settings.rs` now supplies `CredentialSettings` and filesystem-only
`installed_sources()`. Construct the panel once and retain its returned private
job receiver. CLI account reads begin only after a native manager click. 1Password
accounts are selected from `op account list` metadata and every subsequent command
is explicitly scoped with `--account`; Bitwarden exposes its current CLI account
without switching/logging in/out. Selection remains session-local and is never a
stored approval. BW list output internally includes full vault records; only
metadata is retained/displayed, and individual `get item`/TOTP commands cannot run
while filling is unavailable. This is not a claim that CLI listing is secret-free.

Parent main owner registers both `mod credentials;` and `mod credential_settings;`.
Suggested constructor flow (in existing native UI setup):

```rust
let (panel, credential_jobs) = credential_settings::CredentialSettings::new(
    credential_settings::installed_sources(),
);
let credential_panel = cx.new(|_| panel);
```

On every existing UI tick, before displaying/polling the panel, obtain the selected
thread's native page through `browser.credential_page(thread, cx)` (or None without
a selected thread). Set page and capability on the entity, then poll it:

```rust
credential_panel.update(cx, |panel, cx| {
    panel.set_page(page, browser_fill_available, cx);
    panel.poll(cx);
});
// Browser owner implements this with explicit selected-thread ownership.
browser.drain_credential_fills(thread, &credential_jobs, cx);
```

Read `browser_fill_available` from `browser.credential_fill_available()`; current
Wry backends return false. Under that value login rows remain metadata-only and
approval/individual-secret retrieval are disabled. Do not override the capability
for a demo. Main displays `credential_panel.clone()` in its settings/browser panel.
Set page None before removing/closing the workflow and on loss of selected thread.
Revocable sink scopes invalidate dispatched permits when manager, account, page or
backend capability changes, or the workflow drops. Browser hooks still check the
permit and original document at mutation time.
