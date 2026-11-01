export default {
  path: "/features/passkeys",
  title: "Passkeys in Coincide’s browser with Bitwarden · Coincide",
  description: "Sign in with passkeys saved in Bitwarden inside Coincide’s browser, or sign in with any passkey in your own browser and import that sign-in into Coincide.",
  name: "Passkeys",
  summary: "Sign in with Bitwarden passkeys in Coincide’s browser, or import a passkey sign-in from your own browser.",
  type: "WebPage",
  eyebrow: "Feature",
  h1: "Passkeys in Coincide’s browser",
  lede: "Coincide 0.1.0 gives its browser two ways to get past a passkey prompt: sign in with a passkey saved in Bitwarden, confirming each sign-in, or sign in with your passkey in your default browser and import that sign-in into Coincide.",
  related: ["/features/browser-passwords", "/features/browser", "/changelog"],
  body: (s) => `
<h2 id="why">Why passkeys need special handling</h2>
<p>On macOS, a browser can use the system’s passkeys (iCloud Keychain and other passkey providers) on any website only if Apple has given it a special browser entitlement. Coincide’s release builds don’t have it, so when a site asks for a passkey, the system can’t answer. Coincide works around that in the two ways below, and tells you when a page asked for a passkey it can’t provide.</p>

<h2 id="bitwarden">Sign in with a Bitwarden passkey</h2>
<p>If you keep passkeys in Bitwarden, Coincide can answer the site’s passkey request itself, using Bitwarden’s command-line tool on your Mac.</p>
<ol>
  <li>In Settings › Browser › Passwords, turn on Bitwarden and unlock it (see ${s.link("/features/browser-passwords", "passwords and saved logins")} for installing <code>bw</code>).</li>
  <li>Leave “Use passkeys from Bitwarden” on. It’s on by default once Bitwarden is on.</li>
  <li>When a site asks for a passkey you saved in Bitwarden, Coincide asks “Sign in to <em>site</em> with your Bitwarden passkey?”, showing which site the request comes from. If you have more than one passkey for the site, choose the account.</li>
  <li>Click Sign In. Coincide reads that passkey with <code>bw</code>, signs the site’s challenge on your Mac and returns the answer to the page.</li>
</ol>
<h3 id="touch-id">Touch ID</h3>
<p>Your click on Sign In is the confirmation, as with Bitwarden’s browser extension. Coincide also asks for Touch ID or your Mac password when the site requires user verification, or when the Bitwarden item has master password re-prompt turned on. To be asked every time, turn on “Confirm passkey sign-ins with Touch ID” (off by default).</p>
<h3 id="bitwarden-privacy">What happens to the passkey</h3>
<p>Coincide reads the passkey through your own Bitwarden tool only after you confirm, uses it only on your Mac to answer that site’s request, and never sends it to us or anywhere else. The site receives only the signed answer, as it would from any passkey. Coincide answers only the page’s own main frame, for the site the passkey belongs to.</p>

<h2 id="import">Use any passkey through your own browser</h2>
<p>For passkeys stored anywhere else, such as iCloud Keychain or a security key, let your everyday browser do the passkey part and bring the result back:</p>
<ol>
  <li>When the page asks for a passkey, Coincide’s browser shows “Passkeys aren’t available in Coincide’s browser yet” with an <strong>Open in <em>your browser</em></strong> button. Click it to open the same page in your default browser.</li>
  <li>Sign in there with your passkey as usual.</li>
  <li>Back in Coincide, click <strong>Import Sign-In</strong>. Coincide copies that site’s sign-in from your browser into its own browser profile and reloads the page, now signed in.</li>
</ol>
<p>The import reads your browser’s data on your Mac, the same way ${s.link("/features/browser", "importing from another browser")} does: macOS may ask whether Coincide may use the browser’s Keychain key (choose Allow), and Safari needs Full Disk Access. Some browsers take a moment to save a new sign-in; if the page still asks you to sign in, wait and import again.</p>
<p>You can also skip the passkey: many sites offer another way to sign in (such as “Try another way” on Google), after which the key button can fill your password from a password manager.</p>

<h2 id="agents">Passkeys and agents</h2>
<p>Agents can’t sign in with a passkey on their own. When a page an agent is working on asks for one, the agent is told to choose another way to sign in, or to hand the step to you in the browser panel; you then use one of the ways above.</p>

<h2 id="limits">Limitations</h2>
<ul>
  <li>Bitwarden passkeys are for signing in. Creating a new passkey on a site isn’t supported in Coincide’s browser.</li>
  <li>Only an item’s first passkey is used, and only passkeys of the kind Bitwarden creates.</li>
  <li>Bitwarden must be on and unlocked in Coincide for its passkeys to be offered.</li>
  <li>Private browser sessions don’t use imported sign-ins.</li>
</ul>
`,
};
