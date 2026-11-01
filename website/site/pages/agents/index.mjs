import { table } from "../../layout.mjs";

const AGENTS = ["/agents/claude-code", "/agents/codex", "/agents/cursor", "/agents/grok-build", "/agents/opencode", "/agents/antigravity"];

export default {
  path: "/agents",
  title: "Coding agents that work with Coincide",
  description: "Coincide works with Claude Code, Codex, Cursor, Grok Build, OpenCode and Antigravity through their own CLIs. Compare what each agent supports.",
  name: "Agents",
  summary: "The six agents Coincide works with, and what each one supports.",
  type: "CollectionPage",
  eyebrow: "Agents",
  h1: "Bring your own agents",
  lede: "Coincide doesn’t provide AI models. It starts each agent’s own command-line tool on your Mac, with the sign-in or API key you already set up, so your existing subscriptions keep working. Nothing is resold, proxied or metered.",
  wide: true,
  related: ["/features/switch-agents", "/features/model-picker", "/docs/agent-accounts", "/docs/getting-started"],
  body: (s) => `
${s.cards(AGENTS)}

<h2 id="how">How it works</h2>
<p>Install and sign in to at least one agent the way its maker describes, then open Coincide. Coincide finds each agent’s executable on your login shell’s <code>PATH</code> (or at a path you choose in Settings), checks whether you’re signed in, and lists its models in one ${s.link("/features/model-picker", "model picker")}. Each agent keeps its own configuration and instruction files, such as <code>CLAUDE.md</code> or <code>AGENTS.md</code>, because Coincide runs the same tool you’d run in Terminal.</p>
<p>A thread isn’t tied to one agent. Type <code>/claude</code>, <code>/codex</code>, <code>/cursor</code>, <code>/grok</code>, <code>/opencode</code> or <code>/antigravity</code> in the composer, or pick another agent’s model, and the next agent gets a recap of the turns it missed. ${s.link("/features/switch-agents", "Switching agents")} explains the recap.</p>

<h2 id="compare">What each agent supports in Coincide</h2>
<p>Coincide offers the same interface for every agent, but what happens underneath depends on what the agent itself can do.</p>
${table(["", "Claude Code", "Codex", "Cursor", "Grok Build", "OpenCode", "Antigravity"], [
  ["Connection", "stream-json control protocol", "<code>codex app-server</code>", "ACP", "ACP", "local <code>opencode serve</code>", "Google’s ACP runtime"],
  ["Signs in with", "Claude plan or Anthropic API key", "ChatGPT or OpenAI API key", "Cursor login or API key", "Grok login or xAI API key", "Providers you connect to OpenCode", "Google account or Gemini API key"],
  ["Plan mode", "Native", "Native", "Native", "Asked for in the prompt", "OpenCode’s plan agent", "Asked for in the prompt"],
  ["Steer a running turn", "Yes", "Yes", "Queued", "Queued", "Yes", "Queued"],
  ["Speed options", "Fast mode, where offered", "Service tiers, where offered", "No", "No", "No", "No"],
  ["Import earlier sessions", "Yes", "Yes", "No", "No", "No", "No"],
  ["Plan usage limits", "Session and weekly", "Rate limits and credits (ChatGPT)", "Monthly usage (opt-in)", "Subscription credits", "OpenCode Go", "Gemini and shared quotas"],
])}
<p class="note">“ACP” is the Agent Client Protocol, an open protocol for connecting coding agents to apps. Every agent supports approvals or full access, inline questions, image attachments where its model accepts images, resuming its own session in each thread, and running in Coincide’s ${s.link("/features/background-agents", "background agent host")}.</p>

<h2 id="choosing">Choosing an agent</h2>
<p>You don’t have to choose one. Keep several signed in and pick per task, for example one agent to plan or review, another to implement, another for a second opinion. Coincide’s ${s.link("/features/usage-dashboard", "usage dashboard")} shows how much of each plan you’ve used, which helps when one agent is close to its limit.</p>
<p>Antigravity is the exception to “just sign in”: Google’s terms restrict third-party tools, so read the ${s.link("/agents/antigravity", "account risk")} before using a Google subscription with it.</p>
`,
};
