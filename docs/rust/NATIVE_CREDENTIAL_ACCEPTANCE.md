# macOS native credential acceptance — 2026-11-05

Eleven native WebKit groups passed against the production bridge from source
revision `1e5387e`. The final run completed and its isolated harness exited. No
real vault, credential account, website, certificate trust setting or running
Coincide instance was changed. Swift PID 2761 and existing Rust PID 36070 remained
running. This is renderer/private-channel acceptance, not visual approval-panel
or real-account acceptance.

The scratch GPUI harness included the repository's `credentials.rs` and
`browser_credentials.rs` modules. It used `Vault<SyntheticVault>`, an explicitly
approved synthetic login, the real `QueuedSink`/`deliver_fill` path, and the real
`NativeCredentialTarget`. A separate incognito WebKit view loaded local HTML via
`loadHTMLString:baseURL:` with `https://credential-fixture.invalid/login`. Native
URL and HTTPS origin checks remained enabled; there was no HTTP exemption, DNS
request, external resource or certificate bypass.

Credential assertions ran privately and returned booleans only. The fixture
used known synthetic username/password/code values; no secret values appeared
in normal browser IPC, logs or acceptance results. Its page world overrode the
input value setter to throw if intercepted. The production bridge's isolated
world still assigned fields correctly without invoking that override.

## Passed groups

1. Private username/password/OTP argument delivery, exact field assignments,
   six input/change events, zero page-setter interceptions and zero submissions.
   The private isolated-world ticket was not visible in the page world.
2. Revocation before queued delivery refused all writes.
3. Revocation after the secret-free probe dispatch, before final dispatch,
   refused all writes.
4. Native origin mismatch refused all writes, even with a matching synthetic
   metadata lookup.
5. Stale native navigation epoch refused all writes.
6. Disabled login fields refused all writes.
7. Multiple eligible password fields refused ambiguous targeting.
8. A page event handler changing the password field prevented a false success
   acknowledgement after mutation.
9. Same-origin document replacement never received credential values. A fill
   completing in the old document before navigation committed was permitted.
10. Deterministic document identity check: the exact production probe script
    bound a ticket, the native view replaced its document, and the exact fill
    script in the same isolated world rejected the stale ticket without writes.
    This case directly exercised the production script bodies to avoid treating
    an asynchronous navigation race as a deterministic cancellation guarantee.
11. A queued request held beyond the private acknowledgement/permit deadline
    failed without mutating fields.

An enabled OTP field can legitimately support an OTP-only flow when no eligible
password field remains. The disabled-field refusal fixture disabled all login
fields; it did not incorrectly assume that an enabled OTP field must be ignored.

## Artifact identities

All hashes are SHA-256. The bridge hash below is the tested source before changing
only its validated capability constant from false to true.

| Artifact | SHA-256 |
| --- | --- |
| `browser_credentials_macos.rs` tested source | `4e76a9192852173ca27cd2156a29219dee13f46d9ac2acc3d3bdc1610dd76c40` |
| Scratch native harness source | `90c7305fa1429b9041abd36f8dc3bfacf1374a429386e4d9a2180a6e1507b0b5` |
| Immutable native harness binary | `c89925bc963b29c9afda2a4e608bab97a918286248dbc314249d85b1b8125b04` |

Local artifacts: `/tmp/coincide-native-credentials-harness/` contains
`src/main.rs`, `native-fixture-candidate`, `native.log`, `result.json`, and
`build.log`. The fixture used the allocated shared Cargo target, ten build jobs,
`cargo build --offline --manifest-path .../Cargo.toml`, then directly launched its
binary. These scratch paths are evidence locations, not packaged app inputs.

## Enforceable boundary and remaining checks

Final native dispatch is the commit boundary. Revocation before it blocks secret
delivery. Already dispatched renderer work cannot be retracted; it is still
constrained by document identity, origin, selected field identities and deadline.
The bridge confirms assignments after input/change handlers and never submits.
Its completion is only a boolean/coarse failure, never field values or NSError
text. Two outstanding native fills cap callback retention if a renderer stalls.

Only the supported macOS backend is enabled. Linux and Windows remain unavailable
for native credential filling. Filling requires native approval; no agent API can
approve or provide a secret-fill command. The native browser clears and suppresses
console capture for the approved document until navigation completes, reporting
`credentialCaptureSuppressed` to callers. Console suppression wiring, visual
manager/account/approval flow, and keyboard/accessibility approval acceptance
remain separate checks, not covered by this direct bridge harness.

A destination necessarily receives its filled DOM values. The bridge does not
promise containment of a hostile site deliberately reflecting values into visible
content or transmitting its own fields. It does not expose an arbitrary-script
credential API, perform a real login, support passkeys, or fill cross-origin frames.
