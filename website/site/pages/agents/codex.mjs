import { cmd, table } from "../../layout.mjs";

export default {
  path: "/agents/codex",
  title: "Codex CLI in a native Mac app · Coincide",
  description: "Run OpenAI’s Codex in Coincide through codex app-server, with your ChatGPT plan or API key: plan mode, steering, service tiers and rate limits.",
  name: "Codex",
  summary: "OpenAI’s agent through codex app-server, with your ChatGPT sign-in or API key. Plan mode, steering and speed tiers.",
  icon: "/img/logo-codex.png",
  logo: { src: "/img/logo-codex.png", alt: "Codex logo" },
  eyebrow: "Agent · OpenAI",
  h1: "Codex in Coincide",
  lede: "Coincide drives the Codex command-line tool you installed, through its app server, with your ChatGPT sign-in or OpenAI API key. You get Codex’s own sessions, plan mode and models, in a native Mac window next to your other agents.",
  related: ["/features/plan-mode", "/features/composer", "/docs/import-cli-sessions", "/docs/troubleshooting", "/compare/codex-app"],
  body: (s) => `
<h2 id="how">How Coincide runs Codex</h2>
<p>Coincide starts <code>codex app-server</code> and talks to it in JSON-RPC, the interface Codex provides for apps that embed it. Codex then talks to OpenAI (or to the provider it’s configured for) as it would in Terminal. Your <code>~/.codex</code> configuration and <code>AGENTS.md</code> files keep working, because it’s the same tool. Coincide doesn’t proxy or meter anything.</p>
<p>Codex needs to be version 0.149 or later; Coincide asks you to update to 0.156 or later for full support. If <code>codex</code> isn’t on your shell’s <code>PATH</code>, set its location in Settings › Codex.</p>

<h2 id="setup">Set it up</h2>
<ol>
  <li><strong>Install the Codex CLI</strong> (the <a href="https://developers.openai.com/codex/cli">official Codex CLI docs</a> list other ways to install it):
${cmd("curl -fsSL https://chatgpt.com/codex/install.sh | sh", "Copy the Codex install command")}</li>
  <li><strong>Sign in</strong> with ChatGPT, or with an API key:
${cmd("codex login", "Copy the sign-in command")}</li>
  <li><strong>Check Settings › Codex</strong> in Coincide: it shows the version and account Codex reports, and can run the commands above in Terminal. Choose Check Again once you’re signed in.</li>
  <li><strong>Choose a Codex model</strong> in the composer, or type <code>/codex</code> in a thread that another agent started.</li>
</ol>
<p>Codex can sign in with ChatGPT, an OpenAI API key, Amazon Bedrock or a custom provider; Coincide shows which one is in use. To keep a second account, add it in Settings › Codex: a login account gets its own <code>CODEX_HOME</code>, and an API key is saved in your Keychain and given to that account’s Codex. See ${s.link("/docs/agent-accounts", "Agent accounts")}.</p>

<h2 id="models">Models, effort and speed</h2>
<p>Coincide reads the model list from Codex itself, so it shows exactly the models your account offers. For each one it offers the reasoning efforts that model supports, and the service tiers Codex reports for it (such as a faster tier) as speed options in the ${s.link("/features/model-picker", "model picker")}. Image attachments are offered only for models that accept images.</p>

<h2 id="features">What works with Codex</h2>
${table(["In Coincide", "With Codex"], [
  ["Plan mode", "Codex’s own plan collaboration mode, with its plan updates shown in the thread."],
  ["Approvals and full access", "Ask for approval runs Codex in a read-only sandbox and asks before anything that isn’t a known-safe read. Full access never asks and lifts the sandbox."],
  ["Questions", "Codex’s requests for input and MCP forms are answered inline. Link-style MCP requests are declined."],
  ["Steering", "Messages you send while Codex works steer the running turn."],
  ["Attachments", "Images go to Codex as images; other files are mentioned by path."],
  ["Subagents", "Collaborating agents show up in the turn, and their approval requests are labelled as a subagent’s."],
  ["Resuming", "Each thread resumes its own Codex thread, and unarchives it in Codex if needed. If Codex no longer has it, Coincide starts a new one and tells you."],
  ["Stopping", "Stop interrupts the turn; if Codex doesn’t stop within five seconds, Coincide ends its process."],
  ["Usage limits", "For ChatGPT sign-ins, your plan’s rate limits and credits, updated live while Codex works. Optionally, credit details from chatgpt.com (off by default)."],
  ["Importing", "Earlier Codex sessions can be ${s.link("/docs/import-cli-sessions", "imported")} and continued."],
])}

<h2 id="switching">Using Codex with other agents</h2>
<p>A common pattern is to plan or review with one agent and implement with another. When you hand a thread to Codex, it gets a recap of the turns it missed and works in the same folder, and when you switch back the earlier agent resumes its own session. ${s.link("/features/switch-agents", "Switching agents")} explains what the recap contains.</p>

<h2 id="limits">Limitations</h2>
<ul>
  <li>Codex versions before 0.149 aren’t supported, and 0.149 to 0.155 work with reduced support.</li>
  <li>Plan usage limits are read only for ChatGPT sign-ins, not for API keys or custom providers.</li>
  <li>Coincide doesn’t provide Codex with extra “dynamic” tools of its own; Codex keeps the tools and MCP servers you configured.</li>
  <li>OpenAI’s terms and your plan’s limits apply as usual.</li>
</ul>
`,
};
