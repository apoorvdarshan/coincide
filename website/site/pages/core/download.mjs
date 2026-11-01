import { DMG, DOWNLOAD_BUTTONS, VERSION, cmd, code, table } from "../../layout.mjs";

export default {
  path: "/download",
  title: "Download Coincide for Mac: DMG, Homebrew or npm",
  description: "Download Coincide 0.1.0 for macOS 26 or later on Apple silicon and Intel: the notarized DMG, Homebrew or npx. Requirements, updates and uninstalling.",
  name: "Download",
  summary: "The notarized DMG, Homebrew or npm, with system requirements, updates and uninstalling.",
  eyebrow: `Version ${VERSION}`,
  h1: "Download Coincide",
  lede: "Coincide is free and open source. It’s one universal app for Apple silicon and Intel Macs, signed with Developer ID and notarized by Apple. Pick the way you like to install apps.",
  logo: { src: "/img/icon-288.webp", alt: "", size: 64, app: true },
  schema: ["software"],
  related: ["/docs/getting-started", "/docs/updating", "/docs/uninstall", "/changelog", "/docs/build-from-source"],
  body: (s) => `
${DOWNLOAD_BUTTONS.replace('<a class="btn alt" href="/download">All install options</a>', '<a class="btn alt" href="https://github.com/apoorvdarshan/coincide/releases">All releases on GitHub</a>')}

<nav class="toc" aria-label="On this page"><p>On this page</p><ol>
  <li><a href="#requirements">System requirements</a></li>
  <li><a href="#dmg">Install from the DMG</a></li>
  <li><a href="#homebrew">Install with Homebrew</a></li>
  <li><a href="#npm">Install with npm</a></li>
  <li><a href="#verify">Check the download</a></li>
  <li><a href="#updates">Updates</a></li>
  <li><a href="#uninstall">Uninstall</a></li>
  <li><a href="#source">Build from source</a></li>
</ol></nav>

<h2 id="requirements">System requirements</h2>
${table(["", "Requirement"], [
  ["macOS", "macOS 26 or later"],
  ["Mac", "Apple silicon or Intel (one universal app)"],
  ["Agents", `At least one agent’s command-line tool, installed and signed in: ${s.link("/agents/claude-code", "Claude Code")}, ${s.link("/agents/codex", "Codex")}, ${s.link("/agents/cursor", "Cursor")}, ${s.link("/agents/grok-build", "Grok Build")}, ${s.link("/agents/opencode", "OpenCode")} or ${s.link("/agents/antigravity", "Antigravity")}`],
  ["npm install only", "Node.js 18 or later"],
])}
<p>There’s no Coincide account to create and nothing to pay for. Your agents use your own plans or API keys with their providers.</p>

<h2 id="dmg">Install from the DMG</h2>
<ol>
  <li>Download <a href="${DMG}">Coincide.dmg</a>. The link always points to the latest release.</li>
  <li>Open it and drag Coincide to the Applications folder.</li>
  <li>Open Coincide from Applications. Because it came from the internet, macOS asks once whether to open it; it’s notarized, so it opens normally.</li>
</ol>

<h2 id="homebrew">Install with Homebrew</h2>
${cmd("brew install --cask apoorvdarshan/tap/coincide", "Copy the Homebrew command")}
<p>The cask lives in the <a href="https://github.com/apoorvdarshan/homebrew-tap">apoorvdarshan/homebrew-tap</a> repository and is updated by every release. It’s marked as updating itself, so after installing, Coincide’s own updater keeps it current. Removing it with <code>brew uninstall --cask coincide</code> also stops Coincide’s background helpers; add <code>--zap</code> to delete its data too (see ${s.link("/docs/uninstall", "Uninstall")}).</p>

<h2 id="npm">Install with npm</h2>
${cmd("npx coincide-dev", "Copy the npm command")}
<p>The <a href="https://www.npmjs.com/package/coincide-dev"><code>coincide-dev</code></a> package downloads the latest release from GitHub, checks its SHA-256 checksum against the release’s <code>SHA256SUMS.txt</code>, verifies Coincide’s Developer ID signature and notarization, and installs <code>Coincide.app</code> into <code>/Applications</code>. If Coincide is running, it asks before quitting it. It uses only Node’s own modules.</p>
${code(`npx coincide-dev install 0.1.0         # a specific version
npx coincide-dev where                  # where Coincide is installed, and its version
npx coincide-dev --dir ~/Applications   # install somewhere else
npm install -g coincide-dev             # keep the command around as coincide-dev`)}

<h2 id="verify">Check the download</h2>
<p>Each <a href="https://github.com/apoorvdarshan/coincide/releases">GitHub release</a> lists the SHA-256 of its DMG and ZIP files in <code>SHA256SUMS.txt</code>. To compare yours, and to see Apple’s verdict on the installed app:</p>
${code(`shasum -a 256 ~/Downloads/Coincide.dmg
spctl --assess --verbose /Applications/Coincide.app`)}
<p><code>spctl</code> should report <code>accepted</code> with the source <code>Notarized Developer ID</code>. Releases are signed by Apoorv Darshan’s Developer ID (team <code>23RV7FYH36</code>) and built in public by the repository’s release workflow.</p>

<h2 id="updates">Updates</h2>
<p>Coincide checks GitHub for a new release once a day (Settings › About › Check for updates daily, on by default), and you can check any time with Coincide › Check for Updates. Nothing is installed without you: choose Download Update, then Install on Quit, and the update is verified and installed after you quit Coincide; then open it again. The previous version is kept as a backup. ${s.link("/docs/updating", "Updating Coincide")} covers the details, and the ${s.link("/changelog", "changelog")} lists what changed.</p>

<h2 id="uninstall">Uninstall</h2>
<p>Turn off Keep Awake first if you use it (so your Mac’s sleep settings are restored), quit Coincide and move it to the Trash. Coincide’s data, background helpers and the <code>coincide</code> command are covered step by step in ${s.link("/docs/uninstall", "Uninstall Coincide")}.</p>

<h2 id="source">Build from source</h2>
<p>Coincide is MIT-licensed, and you can build it yourself with Xcode 27 and XcodeGen. See ${s.link("/docs/build-from-source", "Build from source")}.</p>
`,
};
