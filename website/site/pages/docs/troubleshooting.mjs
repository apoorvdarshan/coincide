import { code, table } from "../../layout.mjs";

export default {
  path: "/docs/troubleshooting",
  title: "Troubleshooting agents, updates and installs · Coincide",
  description: "Fixes for agents Coincide can’t find or that aren’t signed in, outdated CLIs, Antigravity sign-in, Gatekeeper, updates, the agent host and the CLI.",
  name: "Troubleshooting",
  summary: "What Coincide’s error messages mean and how to fix them: missing or signed-out agents, updates, Gatekeeper and more.",
  type: "TechArticle",
  eyebrow: "Guide",
  h1: "Troubleshooting",
  lede: "Most problems come from an agent’s own command-line tool: it isn’t on the path Coincide sees, it isn’t signed in, or it’s too old. The messages below are the ones Coincide shows, with what to do about each.",
  related: ["/agents", "/docs/updating", "/docs/macos-permissions", "/faq"],
  body: (s) => `
<nav class="toc" aria-label="On this page"><p>On this page</p><ol>
  <li><a href="#not-found">An agent isn’t found</a></li>
  <li><a href="#sign-in">An agent isn’t signed in</a></li>
  <li><a href="#versions">An agent is too old</a></li>
  <li><a href="#antigravity">Antigravity</a></li>
  <li><a href="#gatekeeper">Opening Coincide the first time</a></li>
  <li><a href="#updates">Updates</a></li>
  <li><a href="#host">Agents stop when Coincide quits</a></li>
  <li><a href="#cli">The coincide command</a></li>
  <li><a href="#report">Reporting a problem</a></li>
</ol></nav>

<h2 id="not-found">An agent isn’t found</h2>
<p>Message: “<em>Agent</em> is not installed or could not be found on PATH.”</p>
<p>Coincide doesn’t start agents through Terminal, so it reads your login shell’s environment once (as if you opened a new Terminal window) and adds the usual install folders: Homebrew’s, <code>/usr/local/bin</code>, <code>~/.local/bin</code>, <code>~/.bun/bin</code>, <code>~/.npm-global/bin</code>, <code>~/.cargo/bin</code>, <code>~/.grok/bin</code>, <code>~/.opencode/bin</code> and <code>~/.cursor/bin</code>.</p>
<ol>
  <li>Check the tool runs in a new Terminal window, for example <code>claude --version</code> or <code>cursor-agent --version</code>.</li>
  <li>In Settings, open the agent under Providers and click <strong>Check Again</strong>. Coincide reads your shell’s environment again, so a <code>PATH</code> you just changed counts.</li>
  <li>If it’s installed somewhere else, set <strong>Custom path</strong> under Executable to the program itself. “There’s no executable file at this path.” means the path is wrong or not executable. Leave the field empty to search the <code>PATH</code> again.</li>
</ol>
<p>Coincide gives your shell’s startup files 8 seconds, and falls back to zsh if your shell can’t be read. While it reads them, <code>COINCIDE_RESOLVING_ENVIRONMENT=1</code> is set, so a slow startup file can skip expensive work:</p>
${code(`# in ~/.zshrc
[ -n "$COINCIDE_RESOLVING_ENVIRONMENT" ] && return`)}
<p>Put that line after the lines that set <code>PATH</code>, so Coincide still sees it.</p>

<h2 id="sign-in">An agent isn’t signed in</h2>
<p>Coincide uses each tool’s own sign-in. Run the command in the message in Terminal, then click Check Again (or try the message again):</p>
${table(["Message", "Run"], [
  ["Claude Code is not signed in. Run <code>claude auth login</code> in Terminal, then try again.", "<code>claude auth login</code>"],
  ["Codex CLI is not signed in. Run <code>codex login</code> and try again.", "<code>codex login</code>"],
  ["Cursor isn’t signed in. Run <code>cursor-agent login</code> in Terminal, then try again.", "<code>cursor-agent login</code>"],
  ["Grok CLI is installed but not logged in. Run <code>grok login</code>.", "<code>grok login</code>"],
  ["OpenCode lists no models. Run <code>opencode auth login</code> to connect a provider.", "<code>opencode auth login</code>"],
])}
<p>Each agent’s page in Settings has a <strong>Setup</strong> section with these commands and a <strong>Run in Terminal</strong> button. For extra accounts, see ${s.link("/docs/agent-accounts")}.</p>

<h2 id="versions">An agent is too old</h2>
<ul>
  <li><strong>Codex</strong>: “Codex <em>version</em> is too old. Update the Codex CLI to 0.156 or later.” appears below 0.149. From 0.149 to 0.155 Coincide works but says “Update the Codex CLI to 0.156 or later for full support.”</li>
  <li><strong>OpenCode</strong>: “Coincide needs OpenCode 2 or newer. Run <code>opencode upgrade</code>.”</li>
  <li><strong>Claude Code</strong>: “The installed Claude Code is too old for <em>model</em>. Upgrade to v<em>version</em> or newer to use it.” Only that model is affected; update Claude Code to use it.</li>
</ul>

<h2 id="antigravity">Antigravity</h2>
<p>Antigravity is set up entirely in Settings › Antigravity: <strong>Install Antigravity</strong> downloads Google’s runtime, checked against pinned checksums and Google’s signature, and <strong>Sign in with Google</strong> opens the sign-in in your browser. If you sign in on another device, copy the sign-in link and paste back the address the browser ends on.</p>
<ul>
  <li>“Sign in to Antigravity in Settings before you continue.” A turn needed a sign-in; do it in Settings, then send again.</li>
  <li>“Install Antigravity first, then sign in with Google.” The runtime isn’t installed yet.</li>
  <li>“Google doesn’t publish an Antigravity runtime for this Mac.” Google’s runtime isn’t available for this Mac.</li>
  <li>“This Antigravity version can’t sign out. Update Antigravity.” Use <strong>Update Antigravity</strong> in the same pane.</li>
</ul>
<p>Before you use it, read the account-risk notice on the ${s.link("/agents/antigravity", "Antigravity page")}.</p>

<h2 id="gatekeeper">Opening Coincide the first time</h2>
<p>Releases are signed with Developer ID and notarized by Apple, so macOS opens them after the usual “downloaded from the Internet” question. If macOS refuses to open your copy, check it in Terminal:</p>
${code(`spctl --assess --type execute -vv /Applications/Coincide.app
codesign --verify --deep --strict -v /Applications/Coincide.app`)}
<p>A release reports <code>accepted</code> and <code>source=Notarized Developer ID</code>. If it doesn’t, delete that copy and download Coincide again from the ${s.link("/download", "download page")}. <code>npx coincide-dev</code> runs these checks for you and installs nothing when one fails.</p>

<h2 id="updates">Updates</h2>
${table(["Message", "What it means"], [
  ["Updates can only be installed by a verified Developer ID build.", "Your copy was built from source or isn’t the signed release. Download the release."],
  ["The update failed integrity or signature verification.", "The download didn’t match its checksum or wasn’t signed by Coincide’s team. Nothing was installed; check again later."],
  ["The update is incompatible with this app or Mac.", "The release needs a newer macOS or is for another app."],
  ["Coincide is running. The update has not been installed.", "Coincide was still running when the installer looked; quit it normally (not Force Quit)."],
  ["The update could not be installed. The previous app has been kept.", "The final step failed; your copy is unchanged. Try again, or download the release."],
  ["The update request failed. Try again later.", "GitHub couldn’t be reached."],
])}
<p>Install on Quit installs only after a normal quit, and only when no other copy of Coincide runs. If you reopen Coincide before the confirmation appears, the installer stops; wait for it. Full details in ${s.link("/docs/updating")}.</p>

<h2 id="host">Agents stop when Coincide quits</h2>
<p>Settings › General › Agents says where agents run. If it shows “Agents run in Coincide”, the reason is under it:</p>
<ul>
  <li>“Coincide is turned off under Allow in the Background in Login Items. …” Click <strong>Open Login Items…</strong> and turn Coincide on.</li>
  <li>“The agent host didn’t answer. Coincide keeps trying; …” New agents run in the app until the host answers. Quitting and reopening Coincide usually clears it.</li>
  <li>“This build isn’t signed with a Developer ID, which the agent host needs.” Builds from source run agents in the app.</li>
  <li>“The agent host is missing from this copy of Coincide. Reinstall Coincide …”</li>
</ul>
<p>How the host works across quits and updates is in ${s.link("/features/background-agents")}.</p>

<h2 id="cli">The coincide command</h2>
<ul>
  <li>“Couldn’t reach Coincide at … Is Coincide running, with Settings › General › Command-line control on?” Open Coincide and check the setting.</li>
  <li><code>command not found: coincide</code> in Terminal: Settings › General › Command Line shows where the command is installed, or which folder to add to your <code>PATH</code>.</li>
  <li>“… already exists and isn’t Coincide’s tool, so it was left alone.” Another program is called <code>coincide</code> in that folder; Coincide won’t replace it.</li>
</ul>
<p>Every command is in the ${s.link("/docs/cli", "command-line reference")}.</p>

<h2 id="report">Reporting a problem</h2>
<p>Use <strong>Help › Report an Issue…</strong>. It opens GitHub’s bug report form with your Coincide and macOS versions filled in, and nothing is sent until you submit it. If you don’t have a GitHub account, use <code>/bug</code> in the <a href="https://discord.gg/DETrbhDVqw">Coincide Discord</a> (<strong>Help › Get Help on Discord</strong>); reports there also become public GitHub issues. Include the agent and its version, the exact steps and the error text. Never paste API keys, tokens or private code: agent output can contain them. Report security problems privately through <a href="https://github.com/apoorvdarshan/coincide/security/advisories/new">GitHub’s private vulnerability reporting</a>.</p>
`,
};
