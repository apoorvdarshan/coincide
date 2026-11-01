import { cmd, code, table } from "../../layout.mjs";

export default {
  path: "/docs/uninstall",
  title: "Uninstall Coincide completely · Coincide",
  description: "Remove Coincide from your Mac: turn off Keep Awake first, delete the app, its background helpers, the coincide command, data folders and Keychain items.",
  name: "Uninstall",
  summary: "Turn off Keep Awake first, then remove the app, its helpers, the coincide command, its data and its Keychain items.",
  type: "TechArticle",
  eyebrow: "Guide",
  h1: "Uninstall Coincide",
  lede: "Deleting Coincide.app removes the app. To remove everything it set up, do a few things in Coincide first, then delete its files. Your agents’ own command-line tools, their sign-ins and your projects are never touched.",
  related: ["/docs/data-storage", "/features/keep-awake", "/docs/macos-permissions", "/download"],
  body: (s) => `
<div class="callout warn"><p><strong>Turn off Keep Awake before you delete Coincide.</strong> While it’s on, your Mac’s sleep is disabled with <code>pmset</code>. Turning it off in Coincide puts back the exact sleep settings you had before. If you delete the app first, the Mac stays unable to sleep until you fix it by hand (see <a href="#keep-awake">below</a>).</p></div>

<nav class="toc" aria-label="On this page"><p>On this page</p><ol>
  <li><a href="#before">Before you delete the app</a></li>
  <li><a href="#homebrew">With Homebrew</a></li>
  <li><a href="#manual">By hand</a></li>
  <li><a href="#data">Data and settings</a></li>
  <li><a href="#keychain">Keychain items</a></li>
  <li><a href="#keep-awake">If you already deleted it</a></li>
</ol></nav>

<h2 id="before">Before you delete the app</h2>
<p>Open Coincide and, in Settings › General:</p>
<ol>
  <li>Under <strong>Keep Awake</strong>, turn off <strong>Keep this Mac awake 24/7</strong>. Coincide asks for your password, restores your sleep settings and removes the lid watcher and, if you used <strong>Sleep normally on battery</strong>, the battery helper that runs as root.</li>
  <li>Under <strong>Agents</strong>, turn off <strong>Keep agents running when Coincide quits</strong>. Agents still running in the background agent host finish there; once nothing runs, the host exits and is unregistered.</li>
  <li>Let running turns finish, then quit Coincide.</li>
</ol>
<p>If you paired a device with Coincide Remote, you can also turn off <strong>Allow Coincide Remote</strong> under Remote.</p>

<h2 id="homebrew">With Homebrew</h2>
<p>If you installed with Homebrew, it removes the app, quits Coincide and unloads its three background jobs (the agent host, the lid watcher and the battery helper):</p>
${cmd("brew uninstall --cask coincide", "Copy the uninstall command")}
<p>Add <code>--zap</code> to also delete its data, caches, preferences and browser storage, everything listed in <a href="#data">Data and settings</a> except <code>~/.coincide/worktrees</code>, <code>~/Downloads/Coincide</code> and an iCloud Drive copy. It leaves the <code>coincide</code> command link and the Keychain items, which you remove <a href="#manual">by hand</a>:</p>
${cmd("brew uninstall --zap --cask coincide", "Copy the zap command")}

<h2 id="manual">By hand</h2>
<ol>
  <li>Quit Coincide and drag <strong>Coincide.app</strong> from Applications to the Trash.</li>
  <li>Remove old copies the updater kept: hidden <code>.Coincide-backup-…app</code> folders next to the app (<code>ls -a /Applications | grep Coincide</code> lists them).</li>
  <li>Remove the <code>coincide</code> command. Coincide linked it into one of <code>/opt/homebrew/bin</code>, <code>/usr/local/bin</code> or <code>~/.local/bin</code>. This removes the link only if it points into Coincide.app:</li>
</ol>
${code(`tool=$(command -v coincide) && readlink "$tool" | grep -q 'Coincide.app/Contents/Helpers/coincide' && rm "$tool"`)}
<p>Then check System Settings › General › Login Items &amp; Extensions: nothing from Coincide should be left under Allow in the Background. If a background job is still loaded because the app was deleted while it ran, unload it:</p>
${code(`launchctl bootout gui/$(id -u)/com.apoorvdarshan.coincide.agent-host
launchctl bootout gui/$(id -u)/com.apoorvdarshan.coincide.always-on
sudo launchctl bootout system/com.apoorvdarshan.coincide.power-helper`)}
<p>Each line fails harmlessly when that job isn’t loaded.</p>

<h2 id="data">Data and settings</h2>
<p>Delete these to remove Coincide’s data. Back up anything you want to keep first, such as transcripts in the data folder.</p>
${table(["Location", "What’s there"], [
  ["<code>~/Library/Application Support/Coincide</code>", "Projects, threads and transcripts, attachments, bots, schedules, settings, checkpoints, usage history, the agent host’s logs, sign-in folders of extra agent accounts, imported CLI sessions, browser history and bookmarks, Whisper models and the Antigravity runtime Coincide downloaded"],
  ["<code>~/.coincide/worktrees</code>", "Git worktrees Coincide created for threads. <strong>They can hold work you haven’t committed or pushed</strong>; check them before deleting, and remove them with <code>git worktree remove</code> from the project so git forgets them too"],
  ["<code>~/Library/Caches/com.apoorvdarshan.coincide</code>", "Updates while they download and are checked"],
  ["<code>~/Library/WebKit/com.apoorvdarshan.coincide</code>, <code>~/Library/HTTPStorages/com.apoorvdarshan.coincide</code>", "The browser’s profile: cookies, sign-ins and site data"],
  ["<code>~/Library/Preferences/com.apoorvdarshan.coincide.plist</code>, <code>~/Library/Preferences/com.apoorvdarshan.coincide.agent-host.plist</code>", "Preferences of the app and of the agent host"],
  ["<code>~/Library/Saved Application State/com.apoorvdarshan.coincide.savedState</code>", "Window state macOS keeps"],
  ["<code>~/Downloads/Coincide</code>", "Files downloaded in Coincide’s browser (yours; keep what you need)"],
  ["iCloud Drive › Coincide › Instructions", "Only if you synced an instruction file there; it stays when you turn sync off"],
])}
<p>If you started Coincide with <code>COINCIDE_DATA_DIR</code>, its data and worktrees are in that folder instead. Coincide Debug, built from source, keeps its own data in <code>~/Library/Application Support/Coincide Debug</code>. More detail in ${s.link("/docs/data-storage")}.</p>
<p>Not Coincide’s: your agents’ own files, such as <code>~/.claude</code>, <code>~/.codex</code> or <code>~/.grok</code>, and the agent tools themselves. Uninstall those with each tool’s own instructions if you want them gone too.</p>

<h2 id="keychain">Keychain items</h2>
<p>Coincide keeps secrets in your login Keychain: API keys for extra agent accounts and for dictation, passwords and one-time-code secrets of logins you saved, your Bitwarden session if you connected Bitwarden, and Coincide Remote’s certificate and key. Homebrew’s <code>--zap</code> doesn’t remove them. This removes every password item Coincide created:</p>
${code(`for service in provider-account voice browser browser-logins remote; do
  while security delete-generic-password -s "com.apoorvdarshan.coincide.$service" >/dev/null 2>&1; do :; done
done`)}
<p>To remove Coincide Remote’s certificate and private key, open Keychain Access, search for “Coincide Remote” and delete both.</p>

<h2 id="keep-awake">If you already deleted it</h2>
<p>If Keep Awake was on when you deleted Coincide, your Mac’s sleep is still disabled. Turn it back on with:</p>
${cmd("sudo pmset -a disablesleep 0", "Copy the pmset command")}
<p>Keep Awake also set the Mac never to sleep on the charger. <code>pmset -g</code> shows the current values; set your preferred sleep timing again in System Settings.</p>
`,
};
