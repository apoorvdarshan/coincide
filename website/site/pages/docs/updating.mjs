import { cmd, code } from "../../layout.mjs";

export default {
  path: "/docs/updating",
  title: "Update Coincide: in-app, Homebrew and npx · Coincide",
  description: "How Coincide checks for, verifies and installs updates from GitHub, what Install on Quit does, and how updates work with Homebrew and npx.",
  name: "Updating",
  summary: "How the in-app updater checks, verifies and installs new releases, and how Homebrew and npx installs update.",
  type: "TechArticle",
  eyebrow: "Guide",
  h1: "Updating Coincide",
  lede: "Coincide updates itself from its GitHub releases. It checks once a day, downloads only when you say so, verifies every byte and installs only when you quit. It never quits or reopens on its own, and it keeps the previous app as a backup.",
  related: ["/download", "/changelog", "/docs/troubleshooting", "/features/background-agents"],
  body: (s) => `
<h2 id="check">Checking for updates</h2>
<p>Choose <strong>Coincide › Check for Updates…</strong>. Coincide opens Settings › About and asks GitHub’s public Releases API for the latest release. The App Updates section there shows the result, such as “Coincide is up to date.”</p>
<p>Automatic checks are on by default: Coincide looks once a day while it’s open. To turn them off, clear <strong>Check for updates daily</strong> in Settings › About. A check only asks GitHub which version is newest; it doesn’t download anything, stop agents or quit the app. As with any request, GitHub sees your IP address (see the ${s.link("/privacy", "privacy policy")}).</p>
<p>Only regular releases count. Coincide offers a release when its version is newer than the one you run; it never offers a downgrade or the same version again.</p>

<h2 id="install">Downloading and installing</h2>
<ol>
  <li>When a newer version is available, click <strong>Download Update</strong>. Coincide downloads the release’s universal ZIP from GitHub into its own private folder under <code>~/Library/Caches/com.apoorvdarshan.coincide/Updates</code> and checks its size and SHA-256 checksum against what GitHub publishes. It then checks the app inside: the bundle ID and version must match the release, it must be signed with Developer ID by the same team as the copy you run, and it must pass Gatekeeper. The section then says “The update is verified and ready to install.”</li>
  <li>Click <strong>Install on Quit</strong>. Nothing happens yet: Coincide arms a small signed helper and tells you “The update will install after you quit. Wait for confirmation, then reopen Coincide yourself.” Until you quit, <strong>Cancel Installation</strong> takes it back.</li>
  <li>Quit Coincide as usual. After Coincide has saved everything and exited, the helper verifies the update again from the downloaded archive, puts the new app in place and shows a confirmation.</li>
  <li>Open Coincide again yourself.</li>
</ol>
<p><strong>Show Update Folder</strong> reveals the staged download in Finder while it’s ready or armed.</p>
<h3>What the installer won’t do</h3>
<ul>
  <li>It never reads or changes your threads, projects, agent sign-ins or settings, and never asks for an administrator password.</li>
  <li>It installs only after a normal quit. A crash, a Force Quit, another running copy of Coincide, a failed check or a folder it can’t write to leaves the update uninstalled. Reopening Coincide before the confirmation appears makes the helper refuse, so wait for it.</li>
  <li>It keeps the old app next to the new one as <code>.Coincide-backup-&lt;ID&gt;.app</code>, a hidden file in the same folder, and never deletes it. If a final check fails, it swaps the old app back.</li>
</ul>
<p>Old backups stay until you remove them. To find them in <code>/Applications</code>:</p>
${code("ls -a /Applications | grep Coincide-backup")}

<h2 id="agents">Agents during an update</h2>
<p>With <strong>Keep agents running when Coincide quits</strong> on (Settings › General › Agents), agents work in Coincide’s background agent host, so quitting to update doesn’t stop a running turn. The host runs from its own copy of its files, so replacing Coincide.app doesn’t disturb it, and the new version takes its sessions over when you open it. Agents that run inside the app (with that setting off) stop when you quit, and Coincide asks first. See ${s.link("/features/background-agents")}.</p>

<h2 id="homebrew">If you installed with Homebrew</h2>
<p>The Homebrew cask marks Coincide as updating itself (<code>auto_updates true</code>), so use the in-app updater as above. A plain <code>brew upgrade</code> skips casks like this; to have Homebrew reinstall the latest release anyway, run:</p>
${cmd("brew upgrade --cask --greedy coincide", "Copy the Homebrew upgrade command")}

<h2 id="npm">If you installed with npx</h2>
<p>Coincide updates itself in the same way. Running the installer again also installs the latest release over your copy, after checking its checksum, signature and notarization; if Coincide is running, it asks before quitting it (or pass <code>--yes</code>):</p>
${cmd("npx coincide-dev", "Copy the npx command")}
<p>To install a particular version, name it, as in <code>npx coincide-dev install 0.1.0</code>. <code>npx coincide-dev where</code> prints where Coincide is installed and which version it is.</p>

<h2 id="builds">Builds you made yourself</h2>
<p>Only a verified Developer ID build can install updates. A copy you built from source with the default ad-hoc signing can check for updates but shows “Updates can only be installed by a verified Developer ID build.” Download the release instead, or keep building from source (see ${s.link("/docs/build-from-source")}).</p>
<p>When something goes wrong, the ${s.link("/docs/troubleshooting#updates", "troubleshooting guide")} lists each updater message and what to do. What changed in each version is in the ${s.link("/changelog", "changelog")}.</p>
`,
};
