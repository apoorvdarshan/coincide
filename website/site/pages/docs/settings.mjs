import { kbd, table } from "../../layout.mjs";

export default {
  path: "/docs/settings",
  title: "A tour of Coincide’s settings · Coincide",
  description: "What each pane of Coincide’s Settings holds: General, Models, Usage, Instructions, Voice, Browser, Computer Use, Appshots, each agent’s page and About.",
  name: "Settings tour",
  summary: "What each pane of the Settings window holds, from General and Models to each agent’s page and About.",
  type: "TechArticle",
  eyebrow: "Reference",
  h1: "A tour of Settings",
  lede: "Open Settings with " + kbd("⌘", ",") + ". The sidebar lists the panes, then a page for each agent under Providers, then About. The search field at the top of the sidebar finds panes, agents and individual settings by name or keyword, such as “dark mode” or “steer”.",
  related: ["/docs/keyboard-shortcuts", "/docs/agent-accounts", "/docs/macos-permissions", "/features/usage-dashboard"],
  body: (s) => `
<nav class="toc" aria-label="On this page"><p>On this page</p><ol>
  <li><a href="#general">General</a></li>
  <li><a href="#models">Models</a></li>
  <li><a href="#usage">Usage</a></li>
  <li><a href="#instructions">Instructions</a></li>
  <li><a href="#archive">Archive and Keyboard</a></li>
  <li><a href="#voice">Voice</a></li>
  <li><a href="#browser">Browser</a></li>
  <li><a href="#computer-use">Computer Use and Appshots</a></li>
  <li><a href="#providers">Providers</a></li>
  <li><a href="#about">About</a></li>
</ol></nav>

<h2 id="general">General</h2>
<p>The longest pane, in sections. <strong>Restore Defaults…</strong> at the bottom resets them, keeping your providers, custom models and default model.</p>
${table(["Section", "What’s in it"], [
  ["(top)", "Appearance (light, dark or system), number format, font size, reply font, which side your messages sit on, dark and light themes, the pointing hand over clickable items, where the terminal opens (below the chat or on the right), its GPU rendering and translucency, and which app opens project folders"],
  ["Chat", "Send messages with Return or Command-Return; follow-up behavior while an agent works (Steer, Queue or Interrupt); show reasoning; open links in your default browser; confirm before deleting or archiving threads; hold ⌘Q to quit; resume after usage limits"],
  ["New Threads", "The default agent, model and effort, access (Full access or Ask for approval), whether New Thread starts a chat, and whether the agent names threads and keeps their titles up to date"],
  ["Notifications", "Whether Coincide notifies you when a turn finishes or needs you while it’s in the background"],
  ["Git", "Create checkpoints before each turn, and the branch prefix for worktrees (<code>coincide/</code> by default)"],
  ["Agents", "Close idle agents after a while, keep agents running when Coincide quits (the background agent host), and whether schedules agents create need your approval"],
  ["Keep Awake", "Keep this Mac awake 24/7, sleep normally on battery, and the lid options"],
  ["Remote", "Allow Coincide Remote, the iPhone and iPad companion (coming soon to the App Store), with its port, Bonjour name and paired devices"],
  ["Command Line", "Command-line control, and where the <code>coincide</code> command is installed for Terminal"],
])}
<p>More on ${s.link("/features/keep-awake")}, ${s.link("/features/background-agents")} and ${s.link("/features/notifications")}.</p>

<h2 id="models">Models</h2>
<p>Every model your agents offer, in one list you can filter. Star favorites, hide models you never use from the picker, choose <strong>Use for New Threads</strong>, copy a model’s ID, or <strong>Add Custom Model</strong> with an ID the agent’s CLI accepts but doesn’t list. See ${s.link("/features/model-picker")}.</p>

<h2 id="usage">Usage</h2>
<p>Plan limits per account, and the tokens your agents used on this Mac: tokens and estimated cost per day over the last 7, 30 or 90 days, with the top models and projects. Options: show usage in the menu bar, include Claude Code and Codex sessions you ran in a terminal or another app, read figures from provider websites through your sign-in in Coincide’s browser (off by default), and check Anthropic API-key rate limits on request. See ${s.link("/features/usage-dashboard")}.</p>

<h2 id="instructions">Instructions</h2>
<p>The global instruction files every agent reads in every project, such as <code>AGENTS.md</code> and <code>CLAUDE.md</code>, with an editor, <strong>Use one file for all agents</strong> (links the others to one master file) and sync of that master to iCloud Drive or a Git repository. A project’s own instructions open with File › Edit Instructions…. See ${s.link("/features/instructions")}.</p>

<h2 id="archive">Archive and Keyboard</h2>
<p><strong>Archive</strong> lists threads you archived, with a filter, <strong>Unarchive</strong> and <strong>Delete</strong>. <strong>Keyboard</strong> lists every command’s shortcut, lets you record new ones, warns about conflicts, and shows the keys each part of the window uses. See ${s.link("/docs/keyboard-shortcuts")}.</p>

<h2 id="voice">Voice</h2>
<p>Dictation: the engine (Apple’s speech recognition on the Mac, a local Whisper model, or OpenAI or Groq with your own key), the language, the microphone and its level, a keyboard shortcut (off by default), and <strong>Send when I stop</strong>. Whisper models download here, from Hugging Face, only when you click Download. If Codex is signed in with an API key, <strong>Use Codex’s Key…</strong> copies it for OpenAI dictation. See ${s.link("/features/dictation")}.</p>

<h2 id="browser">Browser</h2>
<p>The browser in each thread: the shared profile or private per-thread sessions, the search engine for the address bar, <strong>Agent Control in new threads</strong>, importing cookies, history and bookmarks from other browsers, clearing history or cookies and site data, and bookmarks. Its Passwords section connects 1Password and Bitwarden through their command-line tools, offers to save logins in your Keychain, imports passwords from a CSV export, lists the sites agents may sign in to, and turns on passkeys from Bitwarden. See ${s.link("/features/browser")} and ${s.link("/features/browser-passwords")}.</p>

<h2 id="computer-use">Computer Use and Appshots</h2>
<p><strong>Computer Use</strong> (off by default) lets agents see and operate other Mac apps. The pane shows the permissions it needs, the driver’s status and version, which threads are using the Mac, and whether to show the agent’s cursor. <strong>Appshots</strong> (off by default) captures the window you’re working in into a chat with both ${kbd("⌘")} keys or a shortcut, optionally with the window’s text and a sound. See ${s.link("/features/computer-use")} and ${s.link("/features/appshots")}.</p>

<h2 id="providers">Providers</h2>
<p><strong>Overview</strong> lists each agent with a switch to use it. Each agent then has its own page:</p>
<ul>
  <li><strong>Use <em>agent</em></strong>, which offers its models in the picker and lets threads run it;</li>
  <li><strong>Executable</strong>: a custom path, or empty to search your shell’s <code>PATH</code>, and <strong>Check Again</strong>;</li>
  <li><strong>Details</strong>: version, account and location;</li>
  <li><strong>Accounts</strong>: extra logins or API keys (${s.link("/docs/agent-accounts", "how accounts work")});</li>
  <li><strong>Usage Limits</strong>: for Cursor, whether Coincide may read its sign-in from the Keychain to show your limits;</li>
  <li><strong>Models</strong>: custom model IDs;</li>
  <li><strong>Environment Variables</strong> added on top of your login shell’s;</li>
  <li><strong>Setup</strong>: the install and sign-in commands, with <strong>Run in Terminal</strong>.</li>
</ul>
<p>Antigravity’s page also installs Google’s runtime, signs you in with Google and shows the account-risk notice. Each agent’s page on this site explains the details: ${s.link("/agents")}.</p>

<h2 id="about">About</h2>
<p>Coincide’s version and build, <strong>App Updates</strong> (check for updates daily, which is on by default, Check for Updates…, Download Update and Install on Quit), links to get help, report bugs, request features and follow the project, and the acknowledgements and licenses of T3 Code, SwiftTerm, Cua Driver, WhisperKit and macbook-24x7-agents. See ${s.link("/docs/updating")}.</p>
`,
};
