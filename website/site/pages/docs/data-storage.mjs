import { code, table } from "../../layout.mjs";

export default {
  path: "/docs/data-storage",
  title: "Where Coincide stores your data · Coincide",
  description: "Every folder and Keychain item Coincide uses on your Mac: threads, attachments, checkpoints, worktrees, browser data and keys, and how to move or reset it.",
  name: "Where data is stored",
  summary: "Every folder and Keychain item Coincide uses on your Mac, what’s in each, and how to move, back up or reset them.",
  type: "TechArticle",
  eyebrow: "Reference",
  h1: "Where Coincide keeps your data",
  lede: "Coincide has no account and no server. Everything it keeps stays on your Mac, in the places below. Your agents’ command-line tools keep their own files, which Coincide doesn’t manage.",
  related: ["/privacy", "/docs/uninstall", "/docs/environment-variables", "/docs/agent-accounts"],
  body: (s) => `
<nav class="toc" aria-label="On this page"><p>On this page</p><ol>
  <li><a href="#folder">The data folder</a></li>
  <li><a href="#elsewhere">Other folders</a></li>
  <li><a href="#keychain">The Keychain</a></li>
  <li><a href="#agents">Your agents’ own files</a></li>
  <li><a href="#move">Moving, backing up and resetting</a></li>
</ol></nav>

<h2 id="folder">The data folder</h2>
<p>Coincide’s main folder is <code>~/Library/Application Support/Coincide</code>, unless you set <code>COINCIDE_DATA_DIR</code> (see <a href="#move">below</a>). It holds:</p>
${table(["Inside", "What it is"], [
  ["<code>projects.json</code>, <code>threads/</code>, <code>thread-index.json</code>", "Your projects, and each thread’s transcript. The sidebar loads from the small index; a transcript is read only when you open the thread."],
  ["<code>attachments/</code>", "Images and files you attach, and images agents generate, copied here so they outlive the agent’s scratch folders"],
  ["<code>checkpoints/</code>", "Snapshots of a project’s working tree taken before each turn (Settings › General › Git › Create checkpoints), used to review or revert what a turn changed"],
  ["<code>Chats/</code>", "The working folder of chats that have no project"],
  ["<code>bots.json</code>, <code>scheduled-tasks.json</code>", "Your bots and your scheduled tasks"],
  ["<code>settings.json</code>, <code>ui-state.json</code>", "Settings and what the window last showed"],
  ["<code>usage-history.json</code>", "Usage history of the latest 10,000 finished turns, for Settings › Usage"],
  ["<code>agent-host/</code>", "The background agent host’s event logs, session locks and the copy of its own files it runs from"],
  ["<code>providers/</code>", "Sign-in folders of agent accounts you add besides the default one, and Antigravity’s profile"],
  ["<code>tools/</code>", "The Antigravity runtime Coincide downloads from Google"],
  ["<code>ImportedSessions/</code>", "Exact copies of CLI sessions you imported"],
  ["<code>browser-library.json</code>, <code>browser-logins.json</code>", "Browser history and bookmarks, and the list of logins you saved, without their passwords"],
  ["<code>Voice/</code>", "Whisper models you downloaded for dictation"],
  ["<code>remote.json</code>", "Coincide Remote settings"],
  ["<code>control.sock</code>", "The socket the <code>coincide</code> command talks to, while Command-line control is on"],
])}
<p>Coincide writes threads as they change and loads a transcript only when you open its thread, so long histories stay quick.</p>

<h2 id="elsewhere">Other folders</h2>
${table(["Location", "What it is"], [
  ["<code>~/.coincide/worktrees</code>", "Git worktrees Coincide creates when a thread runs in a worktree of its own. They’re real checkouts and can hold uncommitted work."],
  ["<code>~/Library/WebKit/com.apoorvdarshan.coincide</code>, <code>~/Library/HTTPStorages/com.apoorvdarshan.coincide</code>", "The browser’s shared profile: cookies, sign-ins and site data. Settings › Browser › Browsing data clears it."],
  ["<code>~/Library/Caches/com.apoorvdarshan.coincide</code>", "App updates while they’re downloaded and checked"],
  ["<code>~/Downloads/Coincide</code>", "Files downloaded in Coincide’s browser, each in a folder of its own"],
  ["<code>~/Library/Preferences/com.apoorvdarshan.coincide.plist</code>", "A few app preferences, such as whether the agent host is on"],
  ["iCloud Drive › Coincide › Instructions", "A copy of your instruction file, only if you turn on iCloud sync in Settings › Instructions"],
])}

<h2 id="keychain">The Keychain</h2>
<p>Secrets never go in the data folder. They’re in your login Keychain:</p>
<ul>
  <li>API keys of agent accounts you add, one item each, labelled “Coincide: <em>account name</em>” (service <code>com.apoorvdarshan.coincide.provider-account</code>), and an optional Anthropic Admin API key beside it;</li>
  <li>OpenAI and Groq API keys for dictation (<code>…coincide.voice</code>);</li>
  <li>passwords and one-time-code secrets of logins you save (<code>…coincide.browser-logins</code>) and your Bitwarden session if you connect Bitwarden (<code>…coincide.browser</code>);</li>
  <li>a hash of each device paired with Coincide Remote (<code>…coincide.remote</code>), and Remote’s certificate and private key, both labelled “Coincide Remote”.</li>
</ul>
<p>Coincide passes a key only to the program or service it belongs to, in an environment variable or a request header. See ${s.link("/docs/agent-accounts")}.</p>

<h2 id="agents">Your agents’ own files</h2>
<p>Each agent tool keeps its own sign-in, settings and history where it always does, for example <code>~/.claude</code> for Claude Code, <code>~/.codex</code> for Codex and <code>~/.grok</code> for Grok Build. Coincide reads some of them (to show your account, import sessions or read usage) but doesn’t move or delete them. Extra accounts you add in Coincide get their own copies of these folders under <code>providers/</code> instead.</p>

<h2 id="move">Moving, backing up and resetting</h2>
<h3>A different data folder</h3>
<p>Start Coincide with <code>COINCIDE_DATA_DIR</code> set to use another folder for its data, its worktrees and Antigravity’s profile. It’s meant for testing; your Keychain items and browser profile stay the same. From Terminal:</p>
${code(`COINCIDE_DATA_DIR=~/coincide-scratch /Applications/Coincide.app/Contents/MacOS/Coincide`)}
<p>Builds of Coincide Debug, made from source, use <code>~/Library/Application Support/Coincide Debug</code> and their own Keychain items, background jobs and permissions, so they never touch your installed copy’s data.</p>
<h3>Backups</h3>
<p>Time Machine and other backups of your home folder include these folders and may include your Keychain. Quit Coincide before copying the data folder by hand, so nothing is mid-write.</p>
<h3>Starting fresh</h3>
<p>Quit Coincide, then move <code>~/Library/Application Support/Coincide</code> to the Trash. Coincide starts empty the next time, while your agents stay signed in through their own tools. To clear only the browser, use Settings › Browser › Browsing data. To remove everything, follow ${s.link("/docs/uninstall")}.</p>
<p>What leaves your Mac, and when, is described in the ${s.link("/privacy", "privacy policy")}.</p>
`,
};
