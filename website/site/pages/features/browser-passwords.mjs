import { cmd, table } from "../../layout.mjs";

export default {
  path: "/features/browser-passwords",
  title: "Saved logins, 1Password and Bitwarden · Coincide",
  description: "Fill sign-ins in Coincide’s browser from logins saved in your Keychain, 1Password or Bitwarden, and let agents sign in without ever seeing a password.",
  name: "Passwords and logins",
  summary: "Fill sign-ins from your Keychain, 1Password or Bitwarden, and let agents sign in without seeing passwords.",
  type: "WebPage",
  eyebrow: "Feature",
  h1: "Passwords and saved logins",
  lede: "Coincide’s browser can fill sign-ins and one-time codes from logins it saves in your Keychain, from 1Password and from Bitwarden, without any browser extension. When an agent needs to sign in, Coincide types the login for it after you allow the site, and the agent never sees the password.",
  related: ["/features/browser", "/features/passkeys", "/docs/data-storage"],
  body: (s) => `
<h2 id="sources">Where logins come from</h2>
<p>Turn password managers on in Settings › Browser › Passwords. None is on until you choose one, and you can use several at once.</p>
${table(["Source", "How Coincide reaches it", "Set up"], [
    ["Coincide Saved Logins", "Your login Keychain on this Mac", "Nothing to install"],
    ["1Password", "1Password’s command-line tool, <code>op</code>", "Install it, then turn on “Integrate with 1Password CLI” in 1Password › Settings › Developer"],
    ["Bitwarden", "Bitwarden’s command-line tool, <code>bw</code>", "Install it, run <code>bw login</code> in Terminal once, then unlock it in Coincide"],
  ])}
<p>Both tools install with Homebrew:</p>
${cmd("brew install --cask 1password-cli", "Copy the 1Password CLI install command")}
${cmd("brew install bitwarden-cli", "Copy the Bitwarden CLI install command")}
<p>Bitwarden’s master password goes only to <code>bw</code>. Coincide keeps the unlocked session that <code>bw</code> returns in your Keychain until you choose Lock.</p>

<h2 id="fill">Fill a sign-in</h2>
<ol>
  <li>Open the sign-in page in a thread’s ${s.link("/features/browser", "browser")}.</li>
  <li>Click the key button in the address bar. It lists the logins that match the site from every source you turned on.</li>
  <li>Pick one. Coincide types the username and password into the page itself. On a two-factor page, the same menu offers the login’s one-time code, for logins that have one.</li>
</ol>
<p>After you sign in on a page by hand, Coincide offers to save the login in your Keychain (turn this off with “Offer to save logins”, or choose Never for This Site).</p>

<h2 id="csv">Import passwords from a CSV export</h2>
<p>“Import CSV…” in Settings › Browser › Passwords reads password exports from Chrome, Safari and Apple Passwords, Firefox, 1Password and Bitwarden, and saves the logins in your Keychain as Coincide saved logins. Rows without a web address or a password are skipped. Delete the CSV file afterwards: it holds your passwords unencrypted.</p>

<h2 id="agents">When an agent needs to sign in</h2>
<p>An agent driving the browser can ask Coincide to sign in on the page it’s on. Coincide shows a sign-in request in the thread naming the site and the login it would use, and you choose Allow Once, Always for This Site or Deny. If you allow it, Coincide fills the form; the agent gets the username at most, never the password or the one-time code, and submits the form itself. Sites you allowed always are listed under “Sites Agents Can Sign In To”, where you can revoke them.</p>
<p>If no saved login matches, the agent hands the step to you instead, with a note in the browser panel saying what to do.</p>

<div class="callout warn">
  <p><strong>Agents and your Bitwarden session.</strong> “Let agents use your unlocked password managers” in Settings › Browser › Passwords is on by default. While it’s on, agents Coincide starts receive Bitwarden’s unlocked session, so they can read any item in your vault with the <code>bw</code> command, such as API keys and tokens, without asking. Turn it off if you don’t want that; agents that are already running pick up the change when they start again.</p>
</div>

<h2 id="security">How the secrets are handled</h2>
<ul>
  <li>Coincide talks to each password manager through its own command-line tool on your Mac. It doesn’t need or use their browser extensions.</li>
  <li>Logins you save in Coincide stay in your login Keychain, together with any one-time-code secrets. Coincide’s data folder keeps only the list of logins, without passwords.</li>
  <li>Agents can’t read password fields, cookies or site storage through the browser connection.</li>
  <li>Passkeys are a separate feature; see ${s.link("/features/passkeys", "passkeys in Coincide’s browser")}.</li>
</ul>
<p>The <a href="/privacy">privacy policy</a> lists what’s kept where, and ${s.link("/docs/data-storage", "where Coincide stores data")} shows how to remove it.</p>

<h2 id="limits">Limitations</h2>
<ul>
  <li>Some password tools can’t search by site; Coincide then matches their logins to the page itself. Settings shows which features each tool supports.</li>
  <li>Filling needs the password manager to be unlocked: Bitwarden in Coincide’s Settings, 1Password through its app.</li>
</ul>
`,
};
