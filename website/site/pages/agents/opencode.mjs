import { cmd, table } from "../../layout.mjs";

export default {
  path: "/agents/opencode",
  title: "OpenCode in a native Mac app · Coincide",
  description: "Use OpenCode in Coincide through its local server with any provider OpenCode supports: plan agent, steering, OpenCode Go limits and Zen balance.",
  name: "OpenCode",
  summary: "The open-source agent through its local server, with any model provider you connect to OpenCode, and steering.",
  icon: "/img/logo-opencode.png",
  logo: { src: "/img/logo-opencode.png", alt: "OpenCode logo" },
  eyebrow: "Agent · open source",
  h1: "OpenCode in Coincide",
  lede: "OpenCode is an open-source coding agent that works with many model providers. Coincide runs its local server on your Mac and shows its sessions as native threads, with your OpenCode providers and keys.",
  related: ["/features/model-picker", "/features/composer", "/docs/agent-accounts", "/features/usage-dashboard", "/agents/claude-code"],
  body: (s) => `
<h2 id="how">How Coincide runs OpenCode</h2>
<p>Coincide starts its own <code>opencode serve</code> on <code>127.0.0.1</code>, on a random port and with a random password, and talks to it over OpenCode’s HTTP API. OpenCode then calls the model providers you connected to it. The server listens only on your Mac and is shared by Coincide’s OpenCode threads.</p>
<p>Coincide needs OpenCode 2 or later; with an older version it asks you to run <code>opencode upgrade</code>. It finds <code>opencode</code> on your shell’s <code>PATH</code>, in <code>~/.opencode/bin</code> and the usual install folders, or at a custom path set in Settings › OpenCode.</p>

<h2 id="setup">Set it up</h2>
<ol>
  <li><strong>Install OpenCode</strong> (see <a href="https://opencode.ai">opencode.ai</a> for other ways):
${cmd("curl -fsSL https://opencode.ai/install | bash", "Copy the OpenCode install command")}</li>
  <li><strong>Connect a provider</strong>, such as OpenCode Zen or your own provider account:
${cmd("opencode auth login", "Copy the provider sign-in command")}</li>
  <li><strong>Open Settings › OpenCode</strong> and choose Check Again. Coincide treats OpenCode as ready once its server lists at least one model.</li>
  <li>Choose an OpenCode model in the composer, or type <code>/opencode</code> to move the current thread to OpenCode.</li>
</ol>
<p>In Settings › OpenCode you can also add accounts. A login account gets its own OpenCode data folder (<code>XDG_DATA_HOME</code>) and its own <code>opencode auth login</code>. An API-key account can use OpenCode Zen, Anthropic, OpenAI, OpenRouter, Gemini, xAI, Groq, DeepSeek or Mistral, with the key kept in your Keychain. ${s.link("/docs/agent-accounts", "Agent accounts")} explains the options.</p>

<h2 id="models">Models</h2>
<p>Models come from OpenCode’s server as <code>provider/model</code> IDs, so every model from every provider you connected shows up in Coincide’s ${s.link("/features/model-picker", "model picker")}. Where a model has reasoning variants, Coincide offers them as reasoning effort. OpenCode models have no fast mode option.</p>

<h2 id="features">What works with OpenCode</h2>
${table(["In Coincide", "With OpenCode"], [
  ["Plan mode", "Uses OpenCode’s own <code>plan</code> agent, with file edits denied while planning."],
  ["Approvals", "Ask for approval asks before shell commands, file edits and access outside the project folder."],
  ["Full access", "Allows everything and answers any remaining permission requests automatically."],
  ["Questions", "OpenCode’s forms are shown inline. Forms with links or hidden or conditional fields are declined, and OpenCode is told why."],
  ["Steering", "Messages sent while OpenCode works steer the running turn."],
  ["Attachments", "Images are sent to OpenCode as files; other files are mentioned by path."],
  ["Subagents", "OpenCode’s subagent tasks and their child sessions are followed in the turn."],
  ["Resuming", "Each thread reloads its own OpenCode session, and Coincide keeps the session’s title in step with the thread’s."],
  ["Usage limits", "OpenCode Go plan windows, read with the key OpenCode stores. Your OpenCode Zen balance is available as an opt-in reading from the OpenCode Console in Settings › Usage."],
])}

<h2 id="why">Why use OpenCode in Coincide</h2>
<p>OpenCode lets one agent reach many providers, including ones the other agents don’t cover, such as OpenRouter, Groq, DeepSeek or Mistral. In Coincide those models sit in the same picker as Claude Code’s and Codex’s, and you can ${s.link("/features/switch-agents", "switch a thread")} between OpenCode and another agent when one of them is a better fit for the next step.</p>

<h2 id="limits">Limitations</h2>
<ul>
  <li>OpenCode 1.x isn’t supported.</li>
  <li>Some OpenCode form types aren’t supported and are declined.</li>
  <li>Earlier OpenCode sessions can’t be imported; ${s.link("/docs/import-cli-sessions", "importing")} works for Claude Code and Codex.</li>
  <li>Bot personalities are sent with the first message rather than as a system prompt.</li>
</ul>
`,
};
