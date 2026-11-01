import { table } from "../../layout.mjs";

const HOME = "https://cursor.com";
const DOWNLOAD = "https://cursor.com/download";
const DOCS = "https://cursor.com/docs";
const VSCODE = "https://cursor.com/docs/configuration/migrations/vscode";
const CLI = "https://cursor.com/cli";
const ACP = "https://cursor.com/docs/cli/acp";

export default {
  path: "/compare/cursor",
  title: "Coincide vs Cursor: agent workspace or AI code editor",
  description: "Cursor is an AI code editor; Coincide is a Mac app that runs Cursor’s CLI agent next to Claude Code, Codex and others. How they differ and work together.",
  name: "vs Cursor",
  summary: "An AI code editor, or a Mac window for agents that can include Cursor’s own CLI agent.",
  type: "Article",
  eyebrow: "Compare",
  h1: "Coincide vs Cursor",
  lede: "Cursor is a code editor built around its coding agent. Coincide isn’t an editor: it’s a Mac app for running and reviewing agents, and Cursor’s command-line agent is one of the six it can run. So the question is less “which one” than “how do they fit together.”",
  updated: "2026-11-01",
  published: "2026-11-01",
  related: ["/agents/cursor", "/features/switch-agents", "/features/git", "/compare/terminal", "/agents"],
  body: (s) => `
<p>Facts about Cursor below come from Cursor’s <a href="${HOME}">site</a>, <a href="${DOCS}">documentation</a> and <a href="${CLI}">CLI page</a>. Cursor describes itself as “your coding agent for building ambitious software,” available as a desktop app, in the terminal, in Slack and in GitHub.</p>

<h2 id="at-a-glance">At a glance</h2>
${table(["", "Cursor (the editor)", "Coincide"], [
  ["What it is", "A code editor; “Cursor is based upon the VS Code codebase” (<a href=\"" + VSCODE + "\">docs</a>)", "A native Mac app for agent conversations, diffs and review; it opens your project in your editor when you want one"],
  ["Platforms", "macOS, Windows and Linux (<a href=\"" + DOWNLOAD + "\">download page</a>)", "macOS 26 or later, Apple silicon and Intel"],
  ["Agents", "Cursor’s agent, in the editor, the CLI and as cloud agents", "Claude Code, Codex, Cursor, Grok Build, OpenCode and Antigravity"],
  ["Models", "Models from Anthropic, OpenAI, Google, Cursor and others, through Cursor (<a href=\"" + DOCS + "\">model list</a>)", "Each agent’s own models, with that agent’s sign-in; for Cursor, the models your Cursor CLI offers"],
  ["Where agents run", "In the editor, in the terminal, and as cloud agents that “use their own computers”", "On your Mac"],
])}

<h2 id="editor">An editor versus a place for agents</h2>
<p>Cursor puts the agent inside a full editor: you browse and edit files, and Cursor’s docs describe a one-click import of your VS Code extensions, themes, settings and keybindings. Coincide doesn’t edit code itself. Its window is organized around conversations: ${s.link("/features/projects-and-threads", "projects and threads")} in a sidebar, a transcript of what the agent did, ${s.link("/features/git", "diffs and per-turn checkpoints")}, a ${s.link("/features/terminal", "terminal")} and a ${s.link("/features/browser", "browser")} per thread. The toolbar’s Open in button opens the project in the editor you choose, which can be Cursor.</p>

<h2 id="cursor-in-coincide">Running Cursor’s agent inside Coincide</h2>
<p>Cursor also ships its agent as a command-line tool, installed with <code>curl https://cursor.com/install -fsS | bash</code>, and documents an <a href="${ACP}">Agent Client Protocol mode</a> so other editors can drive it. Coincide uses that: it starts <code>cursor-agent acp</code> with your Cursor CLI sign-in. In a Coincide thread, Cursor gets:</p>
<ul>
  <li>Its model list from the CLI, with a Default entry that follows your CLI’s own model, and effort levels where Cursor offers them. Picking a model in Coincide doesn’t change your CLI default.</li>
  <li>Cursor’s own plan mode, its questions answered inline, and approvals, or full access through the CLI’s <code>--force</code> option.</li>
  <li>A switch to another agent mid-thread, with a recap, and back again.</li>
  <li>Your Cursor plan’s monthly usage in the ${s.link("/features/usage-dashboard", "usage dashboard")}.</li>
</ul>
<p>Some things differ from the editor: a message you send while Cursor is working is queued rather than steering the running turn, and additional Cursor accounts in Coincide use Cursor API keys. ${s.link("/agents/cursor", "Cursor in Coincide")} has the full setup and limits.</p>

<h2 id="many-agents">One vendor or several</h2>
<p>Cursor’s docs list models from many providers, used through your Cursor account. Coincide runs each vendor’s own agent with your existing subscription to it, so a Claude Code thread uses your Claude plan, a Codex thread your ChatGPT sign-in, and a Cursor thread your Cursor account. Coincide never proxies or meters tokens. If you pay for several agents already, Coincide puts them in one window and lets a thread ${s.link("/features/switch-agents", "move between them")}.</p>

<h2 id="cursor-better">When Cursor is the better choice</h2>
<ul>
  <li>You want the agent inside a full code editor, with your VS Code setup.</li>
  <li>You want models from several providers inside one tool, through one Cursor account.</li>
  <li>You want cloud agents, or you work on Windows or Linux.</li>
</ul>

<h2 id="coincide-better">When Coincide is the better choice</h2>
<ul>
  <li>You already use agents from several vendors and want them side by side, in one picker.</li>
  <li>You prefer to review agents’ work as conversations and diffs, and edit in an editor of your choice.</li>
  <li>You want open-source software, or Mac features around your agents, such as ${s.link("/features/background-agents", "turns that keep running after you quit")}, ${s.link("/features/scheduled-tasks", "scheduled tasks")} and ${s.link("/features/computer-use", "Computer Use")}.</li>
</ul>
<p>Many people will use both: Cursor as the editor, and Coincide to run Cursor’s CLI agent next to the others.</p>

<p class="note">Checked on November 1, 2026 against <a href="${HOME}">cursor.com</a>, the <a href="${DOWNLOAD}">download page</a>, <a href="${DOCS}">Cursor’s docs</a>, its <a href="${VSCODE}">VS Code migration guide</a>, the <a href="${CLI}">CLI page</a> and the <a href="${ACP}">ACP docs</a>; products change, so check their sites. Cursor is a trademark of Anysphere; Coincide isn’t affiliated with or endorsed by Anysphere.</p>
`,
};
