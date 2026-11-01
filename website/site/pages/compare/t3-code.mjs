import { table } from "../../layout.mjs";

const REPO = "https://github.com/pingdotgg/t3code";
const README = "https://github.com/pingdotgg/t3code#readme";
const FAQ = "https://github.com/pingdotgg/t3code/blob/main/docs/user/faq.md";
const REMOTE = "https://github.com/pingdotgg/t3code/blob/main/docs/user/remote-access.md";
const SITE = "https://t3.codes";

export default {
  path: "/compare/t3-code",
  title: "Coincide vs T3 Code: the native Mac port compared",
  description: "Coincide is a native AppKit port of T3 Code. How the two differ: platforms, Electron versus AppKit, supported agents, remote access and licenses.",
  name: "vs T3 Code",
  summary: "The project Coincide is ported from: cross-platform Electron and web, or native AppKit on the Mac.",
  type: "Article",
  eyebrow: "Compare",
  h1: "Coincide vs T3 Code",
  lede: "Coincide started as a native AppKit port of T3 Code, the open-source agent app from T3 Tools. The two share a design and an idea, bringing the agents you already pay for into one app. They differ in how they’re built and where they run.",
  updated: "2026-11-01",
  published: "2026-11-01",
  related: ["/features/coincide-remote", "/features/switch-agents", "/agents", "/compare/conductor", "/docs/build-from-source"],
  body: (s) => `
<p><a href="${REPO}">T3 Code</a> calls itself an “agent harness control surface”: it controls the agents on your machine from a desktop app, a web app and mobile apps. Coincide ports T3 Code’s design and behavior, under T3 Code’s MIT license, to a native Mac app. Facts about T3 Code below come from its <a href="${README}">README</a>, <a href="${FAQ}">FAQ</a> and <a href="${REMOTE}">remote access guide</a>.</p>

<h2 id="at-a-glance">At a glance</h2>
${table(["", "T3 Code", "Coincide"], [
  ["Made by", "T3 Tools", "Apoorv Darshan, porting T3 Code"],
  ["How it’s built", "An “Electron-based desktop app,” a web app and a <code>t3</code> server", "A native AppKit app, with SwiftUI where it fits, such as Settings"],
  ["Platforms", "macOS, Windows and Linux desktop apps, a web client, and iOS and Android apps", "macOS 26 or later, Apple silicon and Intel; an iPhone and iPad companion, Coincide Remote, is coming soon"],
  ["Agents", "Claude Code, Codex, Cursor, Grok Build, OpenCode, Google Antigravity and fx, per its README", "Claude Code, Codex, Cursor, Grok Build, OpenCode and Antigravity"],
  ["License and price", "“Free and open source (MIT)”", "Free and open source (MIT)"],
  ["Where agents run", "Wherever T3 Code runs: “your desktop, a server, a VPS”", "On the Mac where Coincide is installed"],
])}

<h2 id="native">Electron and a server, or AppKit</h2>
<p>T3 Code’s desktop app is built on Electron, with a Node server behind a web interface; the same server powers its web client and lets other devices connect. Coincide rebuilds the interface with AppKit and drives each agent from native Swift code, with no web server in between, so it uses macOS’s own windows, menus, keyboard shortcuts, accessibility and notifications. Coincide’s ${s.link("/docs/build-from-source", "source")} is Swift, built with Xcode and XcodeGen.</p>
<p>Being native also makes room for Mac-specific features: ${s.link("/features/computer-use", "Computer Use")} for operating other Mac apps, ${s.link("/features/appshots", "Appshots")} to attach another app’s window, ${s.link("/features/keep-awake", "Keep Awake")} for MacBooks, ${s.link("/features/dictation", "dictation")} with Apple’s on-device speech or a local Whisper model, and a ${s.link("/features/browser", "browser")} that signs in with your Keychain, 1Password or Bitwarden, including ${s.link("/features/passkeys", "Bitwarden passkeys")}.</p>

<h2 id="remote">Remote access</h2>
<p>Remote use is central to T3 Code. Its FAQ says: “Run <code>npx t3 up</code> on that machine and you get really good remote support,” through T3 Connect (a Cloudflare tunnel set up by T3’s relay), LAN pairing or Tailscale, with the web client and phone apps as remotes. Coincide runs on your Mac only. Its iPhone and iPad companion, ${s.link("/features/coincide-remote", "Coincide Remote")}, isn’t released yet; it’s designed to connect straight to your Mac over your local network or Tailscale, with no relay server.</p>

<h2 id="agents">Agents</h2>
<p>Both apps drive the agents’ own tools with your existing subscriptions. T3 Code’s README also lists fx, which Coincide doesn’t support. In Coincide, each agent has a page describing exactly what works: ${s.link("/agents/claude-code", "Claude Code")}, ${s.link("/agents/codex", "Codex")}, ${s.link("/agents/cursor", "Cursor")}, ${s.link("/agents/grok-build", "Grok Build")}, ${s.link("/agents/opencode", "OpenCode")} and ${s.link("/agents/antigravity", "Antigravity")}. ${s.link("/features/switch-agents", "Switching agents mid-thread")} gives the next agent a recap of the turns it missed.</p>

<h2 id="data">Data and telemetry</h2>
<p>T3 Code’s FAQ says your code and prompts go from your machine to your provider, not to T3, and that T3 Code sends “basic product usage events” without prompts or file contents, which <code>T3CODE_TELEMETRY_ENABLED=false</code> turns off. Coincide’s own code has no analytics or tracking, and it keeps its data in <code>~/Library/Application Support/Coincide</code>; the ${s.link("/privacy", "privacy policy")} lists every connection the app makes.</p>

<h2 id="t3-better">When T3 Code is the better choice</h2>
<ul>
  <li>You work on Windows or Linux, or want a web client.</li>
  <li>Your agents run on a server or VPS and you drive them from a laptop or phone.</li>
  <li>You want the original project, or agents Coincide doesn’t support, such as fx.</li>
</ul>

<h2 id="coincide-better">When Coincide is the better choice</h2>
<ul>
  <li>You work on a Mac and prefer a native AppKit app.</li>
  <li>You want Mac features such as Computer Use, Appshots, Keep Awake and Keychain sign-ins around your agents.</li>
  <li>You want turns to keep running after you quit the app; Coincide’s ${s.link("/features/background-agents", "background agent host")} does this without extra setup.</li>
</ul>

<p class="note">Checked on November 1, 2026 against T3 Code’s <a href="${README}">README</a>, <a href="${FAQ}">FAQ</a>, <a href="${REMOTE}">remote access guide</a> and <a href="${SITE}">t3.codes</a>; products change, so check their sites. T3 Code is a product of T3 Tools Inc.; Coincide credits it as the original design but isn’t affiliated with or endorsed by T3 Tools. Agent names are trademarks of their owners.</p>
`,
};
