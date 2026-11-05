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
