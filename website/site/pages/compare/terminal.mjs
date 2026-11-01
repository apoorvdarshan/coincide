import { table } from "../../layout.mjs";

export default {
  path: "/compare/terminal",
  title: "Coincide vs running coding agents in Terminal",
  description: "What Coincide adds on top of the Claude Code, Codex and other agent CLIs you run in Terminal, what stays the same, and when plain Terminal fits better.",
  name: "vs Terminal",
  summary: "The same agent CLIs, with or without a window around them: what Coincide adds and when Terminal is enough.",
  type: "Article",
  eyebrow: "Compare",
  h1: "Coincide vs running agents in Terminal",
  lede: "Every agent Coincide supports is a command-line tool you can run yourself. Coincide doesn’t replace those tools: it starts the same CLI, with the same sign-in, and builds a Mac window around each conversation.",
  updated: "2026-11-01",
  published: "2026-11-01",
  related: ["/agents", "/features/switch-agents", "/docs/import-cli-sessions", "/features/terminal", "/features/background-agents"],
  body: (s) => `
<p>If you already work with Claude Code, Codex, Cursor, Grok Build, OpenCode or Antigravity in a terminal, this page explains what changes when you run them through Coincide instead, and what doesn’t. Both approaches run the agents on your own Mac; the difference is what surrounds them.</p>

<h2 id="at-a-glance">At a glance</h2>
${table(["", "Agent CLIs in Terminal", "Coincide"], [
  ["What runs the agent", "The CLI’s own interactive interface", "The same CLI, through its machine interface: <code>claude</code> stream-json, <code>codex app-server</code>, <code>cursor-agent acp</code>, <code>grok</code> over ACP, <code>opencode serve</code>, and Antigravity’s ACP runtime"],
  ["Sign-in and billing", "Each CLI’s own login or API key", "The same logins and keys. Coincide never proxies, resells or meters tokens"],
  ["Several agents at once", "One per tab, window or tmux pane", "One window, with projects, threads and chats in a sidebar"],
  ["Changing agent mid-task", "Start a new session and explain the work again", "Switch in the same thread; the next agent gets a recap of the turns it missed"],
  ["Reviewing changes", "<code>git diff</code> and your own tools", "Diffs for uncommitted changes, the branch and each turn, with per-turn checkpoints"],
  ["After you close it", "The agent stops with its terminal session, unless you use something like tmux", "A background agent host keeps turns running after you quit Coincide"],
  ["Where it runs", "Wherever the CLI runs, including servers over SSH", "macOS 26 or later, on Apple silicon or Intel"],
])}

<h2 id="same">What stays the same</h2>
<ul>
  <li><strong>The CLI itself.</strong> Coincide looks for each agent on your login shell’s <code>PATH</code> and in the usual install folders (Homebrew, <code>~/.local/bin</code> and others), or uses a path you set in Settings. You install and update the CLI the way its maker describes; ${s.link("/agents", "each agent’s page")} lists the commands.</li>
  <li><strong>Your sign-in.</strong> If <code>claude auth login</code>, <code>codex login</code>, <code>cursor-agent login</code>, <code>grok login</code> or <code>opencode auth login</code> already worked in Terminal, Coincide uses that sign-in. Your subscription or API key stays with the provider.</li>
  <li><strong>The agents’ own files.</strong> The CLIs keep their configuration and history in their own folders, such as <code>~/.claude</code> and <code>~/.codex</code>, and Coincide doesn’t take them over. Extra sign-in accounts you add in Coincide get configuration folders of their own, so they don’t disturb your default login.</li>
  <li><strong>Where the work happens.</strong> Agents run on your Mac, in your project folder, with your tools on the path.</li>
</ul>

<h2 id="adds">What Coincide adds</h2>
<h3>A place for every conversation</h3>
<p>Each conversation is a thread inside a project, or a chat without one, kept in a searchable sidebar you can pin, archive and snooze. ${s.link("/features/projects-and-threads", "Projects and threads")} replace a row of terminal tabs, and the ${s.link("/features/command-palette", "⌘K command palette")} jumps between them.</p>
<h3>One picker for every agent’s models</h3>
<p>Models from every installed and signed-in agent appear in ${s.link("/features/model-picker", "one menu")}, grouped by agent, with reasoning effort and fast mode where the provider offers them. ${s.link("/features/switch-agents", "Switching agents")} keeps each agent’s native session for the thread and hands the next one a recap, so you don’t paste context between tools.</p>
<h3>Review without leaving the thread</h3>
<p>${s.link("/features/git", "Diffs and checkpoints")} show what each turn changed and let you revert it. ${s.link("/features/worktrees", "Per-thread worktrees")} keep parallel work apart, and ${s.link("/features/pull-requests", "commits, pushes and pull requests")} can use agent-written messages. ${s.link("/features/approvals", "Approvals")} and agents’ questions appear in the thread, where you answer them, instead of as prompts in terminal scrollback.</p>
<h3>Tools around the agent</h3>
<p>Each thread has its own ${s.link("/features/terminal", "terminal")} and ${s.link("/features/browser", "browser")}, which agents can drive when you allow it. ${s.link("/features/scheduled-tasks", "Scheduled tasks")} send a message into a thread on a schedule while Coincide is open, and the ${s.link("/features/usage-dashboard", "usage dashboard")} shows your plans’ limits across agents.</p>

<h2 id="moving">Moving between the two</h2>
<p>You don’t have to choose once. <strong>File › Import CLI Session…</strong> brings an existing Claude Code or Codex conversation into Coincide, keeping its session ID so it continues the same native session; the original file is left untouched. See ${s.link("/docs/import-cli-sessions", "Importing CLI sessions")} for the limits. For Claude Code threads, Coincide also names the native session after the thread, so <code>claude --resume</code> in Terminal shows the same title.</p>
<p>The bundled <code>coincide</code> command works the other way round: from Terminal or a script you can list threads, start one, send a message and wait for the reply. ${s.link("/docs/cli", "The command-line reference")} has the details.</p>

<h2 id="terminal-better">When Terminal is the better choice</h2>
<ul>
  <li>You work on a remote server over SSH, in a container or in CI. Coincide runs agents on the Mac it’s installed on.</li>
  <li>You’re on Linux or Windows, or on a Mac older than macOS 26.</li>
  <li>You rely on CLI options or interactive features that Coincide doesn’t expose in its composer and settings.</li>
  <li>You want a single, short session and nothing else on screen.</li>
</ul>

<h2 id="coincide-better">When Coincide is the better choice</h2>
<ul>
  <li>You use more than one agent, or want to try a different one partway through a task.</li>
  <li>You keep many conversations going and want to find them again later.</li>
  <li>You want to review diffs, approve commands and answer questions without reading terminal scrollback.</li>
  <li>You want turns to keep running after you close the window.</li>
</ul>

<p class="note">Checked on November 1, 2026 against Coincide’s source code and README. The agent CLIs change often, so check their makers’ documentation for current options. Claude Code, Codex, Cursor, Grok Build, OpenCode and Antigravity are trademarks of their owners; Coincide isn’t affiliated with or endorsed by them.</p>
`,
};
