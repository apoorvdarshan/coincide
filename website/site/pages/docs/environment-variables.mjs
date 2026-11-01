import { table } from "../../layout.mjs";

export default {
  path: "/docs/environment-variables",
  title: "Environment variables Coincide reads and sets · Coincide",
  description: "The environment variables Coincide reads, the ones it gives agents and scripts, such as COINCIDE_THREAD_ID, and the agent variables it sets per account.",
  name: "Environment variables",
  summary: "Variables Coincide reads, the ones it gives agents, terminals and scripts, and those it sets for each agent account.",
  type: "TechArticle",
  eyebrow: "Reference",
  h1: "Environment variables",
  lede: "Coincide starts agents with your login shell’s environment, plus a few variables of its own. This page lists the variables that matter to you: those you can set for Coincide, those your agents and scripts receive, and those Coincide sets for agent accounts.",
  related: ["/docs/cli", "/docs/agent-accounts", "/docs/data-storage", "/docs/troubleshooting"],
  body: (s) => `
<h2 id="agents-env">What agents start with</h2>
<p>Coincide reads your login shell’s environment once, as a new Terminal window would, and starts every agent with it. It adds the usual install folders to <code>PATH</code> and removes variables that would make an agent think it’s running inside another Claude Code session, for when you start Coincide from one. On each agent’s page in Settings, <strong>Environment Variables</strong> adds your own on top, for example a custom base URL.</p>

<h2 id="read">Variables Coincide reads</h2>
${table(["Variable", "Effect"], [
  ["<code>COINCIDE_DATA_DIR</code>", "Use this folder instead of <code>~/Library/Application Support/Coincide</code> for Coincide’s data, its worktrees and Antigravity’s profile. Meant for testing; see " + s.link("/docs/data-storage", "data storage") + "."],
  ["<code>COINCIDE_CONTROL_SOCKET</code>", "Read by the <code>coincide</code> command: the socket to talk to. <code>--socket</code> overrides it."],
  ["<code>COINCIDE_THREAD_ID</code>", "Read by the <code>coincide</code> command: the thread <code>this</code> means."],
  ["<code>COINCIDE_AGENT_HOST=1</code>", "In a Debug build from source, use the background agent host instead of running agents in the app."],
  ["<code>CLAUDE_CONFIG_DIR</code>, <code>CODEX_HOME</code>", "Where File › Import CLI Session… looks for Claude Code and Codex histories, when set in Coincide’s own environment."],
])}

<h2 id="given">Variables Coincide gives agents</h2>
${table(["Variable", "When", "Value"], [
  ["<code>PATH</code>", "While Command-line control is on", "Gains the folder with the <code>coincide</code> tool inside Coincide.app"],
  ["<code>COINCIDE_CONTROL_SOCKET</code>", "While Command-line control is on", "The socket of the Coincide that started the agent"],
  ["<code>COINCIDE_THREAD_ID</code>", "While Command-line control is on", "The agent’s own thread, so <code>coincide … this</code> works"],
  ["<code>BW_SESSION</code>", "When you connected Bitwarden and turned on <strong>Let agents use your unlocked password managers</strong> in Settings › Browser", "Bitwarden’s unlocked session, so the agent’s <code>bw</code> can read your vault without unlocking it"],
])}
<p>Agents already running get <code>BW_SESSION</code> when they next start. Leave that setting off unless you want agents to read any item in your Bitwarden vault without asking.</p>

<h2 id="shell">Variables for your shell and scripts</h2>
${table(["Variable", "Where", "Meaning"], [
  ["<code>COINCIDE_RESOLVING_ENVIRONMENT=1</code>", "Your shell’s startup files, while Coincide reads your environment", "Lets a slow <code>.zshrc</code> skip work Coincide doesn’t need. Agents never see it."],
  ["<code>COINCIDE_PROJECT_ROOT</code>", "Project scripts run from the terminal", "The project’s folder"],
  ["<code>COINCIDE_WORKTREE_PATH</code>", "Project scripts, when the thread has its own worktree", "The worktree’s folder, for example to copy <code>.env</code> into it"],
  ["<code>T3CODE_PROJECT_ROOT</code>, <code>T3CODE_WORKTREE_PATH</code>", "Project scripts", "The same values under T3 Code’s names, so scripts from <code>t3.json</code> work unchanged"],
])}

<h2 id="accounts">Variables Coincide sets for agent accounts</h2>
<p>The default account of each agent uses its tool’s own settings. For each account you add, Coincide sets the variable that moves the tool’s sign-in to a folder of that account, or the one that carries its API key. It also clears API-key variables your shell exports for that agent, so the account uses only its own sign-in.</p>
${table(["Agent", "Sign-in folder", "API key"], [
  ["Claude Code", "<code>CLAUDE_CONFIG_DIR</code>", "<code>ANTHROPIC_API_KEY</code>"],
  ["Codex", "<code>CODEX_HOME</code>", "<code>OPENAI_API_KEY</code>, saved in that <code>CODEX_HOME</code> with <code>codex login --with-api-key</code>"],
  ["Cursor", "—", "<code>CURSOR_API_KEY</code>"],
  ["Grok Build", "<code>GROK_HOME</code>", "<code>XAI_API_KEY</code>"],
  ["OpenCode", "<code>XDG_DATA_HOME</code>", "<code>OPENCODE_API_KEY</code> (OpenCode Zen), or <code>ANTHROPIC_API_KEY</code>, <code>OPENAI_API_KEY</code>, <code>OPENROUTER_API_KEY</code>, <code>GOOGLE_GENERATIVE_AI_API_KEY</code>, <code>XAI_API_KEY</code>, <code>GROQ_API_KEY</code>, <code>DEEPSEEK_API_KEY</code> or <code>MISTRAL_API_KEY</code>"],
  ["Antigravity", "—", "<code>GEMINI_API_KEY</code>"],
])}
<p>Keys come from the Keychain and go only into that agent’s process. More in ${s.link("/docs/agent-accounts")}.</p>
`,
};
