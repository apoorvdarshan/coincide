# Passkeys in the Rust browser

The Swift app serves passkeys from the user's Bitwarden vault, because Apple's managed browser passkey entitlement
(`com.apple.developer.web-browser.public-key-credential`, see `Coincide/Passkeys.entitlements`) is available only to
organization developer accounts, and Coincide's account is an individual one. The Rust desktop app follows the same
approach. Its portable logic is `crates/coincide-core/src/passkeys.rs`; the browser side is
`crates/coincide-desktop/src/browser_passkeys.rs` and its platform files.

## What each platform does

| Platform | WebView | Passkey sign-in | Registration | "Passkeys aren't available" notice and `read` note |
| --- | --- | --- | --- | --- |
| macOS | WKWebView | Bitwarden passkeys, after the user clicks Sign In; Touch ID or the Mac's password when the setting, the site or the item asks | Left to WebKit, which refuses it without the entitlement | Yes, when a page's request reaches WebKit |
| Windows | WebView2 | Left to WebView2's own WebAuthn (Windows Hello, security keys, phones) | WebView2's own | No: the platform answers |
| Linux | WebKitGTK | None: WebKitGTK doesn't give pages the WebAuthn API, so sites see no passkey support and offer other sign-in methods | None | No: pages never ask |

`tabs` reports this as `"passkeys": "bitwarden-sign-in" | "webview2-native" | "unavailable"`, with
`passkey-registration` (macOS) or `passkeys` (Linux) in `unsupported`.

Windows doesn't get the Bitwarden bridge yet: `CliCommand` can't run `bw` on Windows until it has Job Object ownership
and cancellable pipe I/O (`credentials.rs`), so a Windows bridge would have no vault to ask. The fixture checks that
WebView2 gives pages the API; it doesn't run a Windows Hello ceremony. Linux would need the WebAuthn API itself;
polyfilling `PublicKeyCredential` would change how every site's feature detection behaves, so Coincide doesn't, and
the fixture checks that WebKitGTK still lacks it.

## macOS, as in the Swift app

- Each tab gets a `WKWebViewConfiguration` of Coincide's own before WebKit creates the view, so the first document has
  the scripts. Its store is chosen as Wry would choose it (the profile's identified store on macOS 14 and later, the
  default store before, the thread's ephemeral store for private browsing), and checked after the view exists.
- The two page scripts are the Swift app's, unchanged (`passkeys_detection.js` in every frame, then
  `passkeys_sign_in.js` in main frames), at document start in the page's world, with WebKit page-world message
  handlers: `coincidePasskey` (reports) and `coincideBitwardenPasskey` (replies).
- The origin is the message's `WKFrameInfo`: main frames only, and only when the frame's document address agrees with
  its security origin. Relying party IDs are checked against the bundled Public Suffix List
  (`crates/coincide-core/resources/public_suffix_list.dat`, a copy of the Swift app's; `scripts/update-public-suffix-list.sh`
  refreshes both).
- Requests Coincide can't serve (Bitwarden passkeys off, no Bitwarden CLI, no unlocked `BW_SESSION`, the browser not on
  screen, conditional or silent mediation, no matching passkey) go back to WebKit, which fails them and shows the
  notice. Requests it refuses fail as a browser's do (`SecurityError`, `NotAllowedError`).
- `bw list items`, `bw sync`, `bw get item` and `bw edit item` run on workers the browser joins at shutdown. The
  private key is decoded only to sign and erased after; a counter above 0 is synced, incremented and saved through
  `bw`'s standard input (never its arguments) before the page gets the assertion.
- Settings › Browser › Passwords › Passkeys has "Use passkeys from Bitwarden" (on by default) and "Confirm passkey
  sign-ins with Touch ID" (off by default), saved as `usesBitwardenPasskeys` and `confirmsPasskeysWithTouchID` in
  `settings.json`. The notice's × saves `passkeysUnavailableDismissed`.
- The Swift app's "Open in" handoff imports the site's cookies back from the user's browser. The Rust browser can't
  import Chromium or Safari cookies yet, so its notice opens the page in the default browser and says the sign-in
  can't be brought back yet.

## Verification

- `cargo test -p coincide-core passkeys` (and `credentials::tests` for `bw` standard input): the Swift app's
  WebAuthn, Public Suffix List, Bitwarden and sign-in tests, with keys generated per test.
- `cargo test -p coincide-desktop --bin coincide-rust browser::passkeys` on the macOS job: the controller with a fake
  vault and fake verification.
- `examples/native_passkey_sdk.rs` on fresh GitHub-hosted runners only (`COINCIDE_SYNTHETIC_PASSKEY_SDK=1`):
  - macOS: a real WKWebView with the production scripts, handlers and controller signs a simulated
    `https://passkey-fixture.example` page in with a synthetic key; the fixture checks the signature as a relying
    party would, and that cancelling, another site's RP ID, an unmatched request (handed back and noticed) and a child
    frame posting to the handler behave as in the Swift app's page tests. A stub stands in for WebKit's own API.
  - Windows and Linux: the WebView is probed on an owned https page for the API the reported support depends on.
- Not verified anywhere automated: a real Bitwarden vault, the Touch ID dialog (it would block an unattended runner),
  and the prompt's pixels.
