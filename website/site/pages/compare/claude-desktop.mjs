import { table } from "../../layout.mjs";

const DOCS = "https://code.claude.com/docs/en/desktop";
const QUICKSTART = "https://code.claude.com/docs/en/desktop-quickstart";

export default {
  path: "/compare/claude-desktop",
  title: "Coincide vs the Claude desktop app for Claude Code",
  description: "How Coincide and Anthropic’s Claude desktop app differ for Claude Code: platforms, agents, sessions, worktrees and plans, checked against Anthropic’s docs.",
  name: "vs Claude desktop app",
  summary: "Anthropic’s app for Claude Code, or one Mac window for Claude Code and five other agents.",
  type: "Article",
  eyebrow: "Compare",
  h1: "Coincide vs the Claude desktop app",
  lede: "Anthropic’s Claude desktop app has a Code tab that runs Claude Code with a graphical interface. Coincide also runs Claude Code in a Mac window, next to Codex, Cursor, Grok Build, OpenCode and Antigravity. Here’s how they differ.",
  updated: "2026-11-01",
  published: "2026-11-01",
  related: ["/agents/claude-code", "/features/switch-agents", "/features/approvals", "/compare/codex-app", "/compare/terminal"],
  body: (s) => `
<p>Both apps give Claude Code a window with sessions, diffs and a terminal. The main difference is scope: the Claude desktop app is Anthropic’s own app, built around Claude, with cloud and remote environments; Coincide is an open-source Mac app that drives the agent CLIs you already have, Claude Code among them, and lets one thread move between them. Facts about the Claude desktop app below come from Anthropic’s <a href="${QUICKSTART}">desktop quickstart</a> and <a href="${DOCS}">Code tab reference</a>.</p>

<h2 id="at-a-glance">At a glance</h2>
${table(["", "Claude desktop app (Code tab)", "Coincide"], [
  ["Made by", "Anthropic", "Apoorv Darshan; open source under the MIT license"],
  ["Platforms", "macOS (universal), Windows (x64 and ARM64) and Linux in beta (Ubuntu and Debian), per the <a href=\"" + QUICKSTART + "\">quickstart</a>", "macOS 26 or later, Apple silicon and Intel"],
  ["Agents", "Claude Code", "Claude Code, Codex, Cursor, Grok Build, OpenCode and Antigravity"],
  ["Claude Code itself", "Included: “you don’t need to install Node.js or the CLI”", "The <code>claude</code> CLI you install and sign in to"],
  ["Plan for Claude Code", "“Claude Code requires a Pro, Max, Ultra, Team, or Enterprise subscription”", "Whatever your Claude Code sign-in allows: a Claude plan or an Anthropic API key. Coincide itself is free"],
  ["Where sessions run", "Local, Cloud (on Anthropic’s infrastructure), SSH, and WSL on Windows", "On your Mac"],
  ["Parallel work", "Parallel sessions, each optionally in a Git worktree under <code>.claude/worktrees/</code>", "Threads in a sidebar, each optionally in a worktree under <code>~/.coincide/worktrees</code>"],
])}

<h2 id="agents">One agent or several</h2>
<p>The Code tab is Claude Code: its model picker offers Claude models. Coincide shows the models of every agent you’ve installed and signed in to in ${s.link("/features/model-picker", "one picker")}, and you can ${s.link("/features/switch-agents", "switch agents in the middle of a thread")}. Each agent keeps its own native session, and the one you switch to gets a recap of the turns it missed, so a Claude Code thread can continue in Codex and come back.</p>
<p>When Coincide runs Claude Code, it talks to the CLI the way the Agent SDK does, with your existing sign-in. ${s.link("/agents/claude-code", "Claude Code in Coincide")} covers the details: models and effort levels, fast mode, steering a running turn, and usage limits.</p>

<h2 id="environments">Where the agent runs</h2>
<p>The Claude desktop app can run a session locally, in the cloud on Anthropic-managed infrastructure (Anthropic says cloud sessions “continue even if you close the app”), on a remote machine over SSH, or inside WSL on Windows. Coincide runs every agent on the Mac it’s installed on. To keep work going without the window, it starts agents in a ${s.link("/features/background-agents", "background agent host")} that keeps turns running when you quit or update Coincide, and ${s.link("/features/keep-awake", "Keep Awake")} can keep a MacBook from sleeping while they work.</p>

<h2 id="permissions">Permissions and planning</h2>
<p>Anthropic’s docs list five permission modes for the Code tab: Manual, Accept edits, Plan, Auto (a background classifier checks actions) and Bypass permissions. Coincide offers two access levels in its composer for every agent, ${s.link("/features/approvals", "Ask for approval or Full access")}, plus ${s.link("/features/plan-mode", "plan mode")}. For Claude Code, Ask for approval uses Claude Code’s default mode and Full access its bypass mode; if Claude Code’s own settings don’t allow bypassing, Coincide falls back to auto mode and then to asking.</p>

<h2 id="review">Reviewing and shipping changes</h2>
<p>The Code tab has a diff view where you comment on lines and submit the comments together, a <code>/code-review</code> command, and pull request monitoring through the GitHub CLI that can fix failing checks and merge when ready. Coincide shows ${s.link("/features/git", "unified or side-by-side diffs")} for uncommitted changes, the branch and each turn, keeps checkpoints to revert a turn, and ${s.link("/features/pull-requests", "opens pull requests")} on GitHub, GitLab, Bitbucket, Azure DevOps and Forgejo/Codeberg, with a GitHub PR workspace for checks and reviews.</p>

<h2 id="tools">Browser, computer use and extras</h2>
<ul>
  <li><strong>Browser.</strong> Anthropic’s Browser pane previews your app and “uses a clean browser profile, separate from your personal browser.” Coincide’s ${s.link("/features/browser", "browser")} lives in each thread, keeps one persistent profile so sign-ins last, can import cookies from your browsers, and lets agents drive it when you allow it.</li>
  <li><strong>Computer use.</strong> Anthropic describes computer use in the desktop app as “a research preview on macOS and Windows,” off by default and available on Pro, Max and Ultra plans. Coincide’s ${s.link("/features/computer-use", "Computer Use")} is also off by default; it runs a bundled copy of Cua Driver and works with any of its agents.</li>
  <li><strong>Beyond code.</strong> The Claude desktop app also has Chat and Cowork, connectors (MCP servers with a graphical setup), plugins, skills and scheduled tasks. Coincide has ${s.link("/features/bots", "bots")}, ${s.link("/features/scheduled-tasks", "scheduled tasks")} and ${s.link("/features/dictation", "dictation")}, and no chat product of its own: every conversation goes to one of your agents.</li>
</ul>

<h2 id="claude-better">When the Claude desktop app is the better choice</h2>
<ul>
  <li>Claude Code is the only agent you use, and you want Anthropic’s own app and support.</li>
  <li>You want sessions that run in Anthropic’s cloud, on a machine over SSH, or in WSL.</li>
  <li>You work on Windows or Linux, or on a Mac older than macOS 26.</li>
  <li>You want Chat, Cowork, connectors and plugins in the same app, or the Auto and Accept edits permission modes.</li>
</ul>

<h2 id="coincide-better">When Coincide is the better choice</h2>
<ul>
  <li>You use Claude Code alongside other agents, or want to switch agents within one conversation.</li>
  <li>You want open-source software you can read and build yourself.</li>
  <li>You want Mac features such as ${s.link("/features/appshots", "Appshots")}, Keep Awake and on-device dictation around your agents.</li>
</ul>
<p>The two can share one setup: Anthropic says the desktop app “reads the same settings files as the CLI,” and Coincide runs the CLI itself.</p>

<p class="note">Checked on November 1, 2026 against Anthropic’s <a href="${QUICKSTART}">desktop quickstart</a> and <a href="${DOCS}">Code tab documentation</a>; products change, so check their sites. Claude and Claude Code are trademarks of Anthropic; Coincide isn’t affiliated with or endorsed by Anthropic.</p>
`,
};
