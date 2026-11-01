import { cmd, table } from "../../layout.mjs";

export default {
  path: "/agents/cursor",
  title: "Cursor CLI agent in a native Mac app · Coincide",
  description: "Use Cursor’s agent (cursor-agent) in Coincide over the Agent Client Protocol, with your Cursor login or API key: plan mode, models and usage limits.",
  name: "Cursor",
  summary: "Cursor’s command-line agent over the Agent Client Protocol, with your Cursor login or API key, and plan mode.",
  icon: "/img/logo-cursor.png",
  logo: { src: "/img/logo-cursor.png", alt: "Cursor logo" },
  eyebrow: "Agent · Anysphere",
  h1: "Cursor in Coincide",
  lede: "Coincide works with Cursor’s command-line agent, <code>cursor-agent</code>, rather than the Cursor editor. You sign in once with Cursor’s CLI, and your Cursor models, plan mode and usage limits show up next to your other agents in one Mac window.",
  related: ["/features/plan-mode", "/features/model-picker", "/docs/agent-accounts", "/compare/cursor", "/features/usage-dashboard"],
  body: (s) => `
<h2 id="how">How Coincide runs Cursor</h2>
<p>Coincide starts <code>cursor-agent acp</code>, which speaks the Agent Client Protocol (ACP), an open protocol for connecting agents to apps. The Cursor CLI does the work and talks to Cursor’s service under your account; Coincide only shows the conversation, the tool calls and the changes, and answers Cursor’s requests for permission.</p>
<p>The Cursor editor isn’t needed and isn’t involved. If you use both, they share your Cursor account, and Coincide is careful not to change your CLI’s default model: when you pick a model in Coincide, it puts back the model settings in Cursor’s <code>cli-config.json</code>.</p>

<h2 id="setup">Set it up</h2>
<ol>
  <li><strong>Install the Cursor CLI</strong> (see the <a href="https://cursor.com/cli">official Cursor CLI page</a>):
${cmd("curl https://cursor.com/install -fsS | bash", "Copy the Cursor CLI install command")}</li>
  <li><strong>Sign in:</strong>
${cmd("cursor-agent login", "Copy the sign-in command")}</li>
  <li><strong>Open Settings › Cursor</strong> and choose Check Again. Coincide checks <code>cursor-agent status</code> and shows your account. If <code>cursor-agent</code> lives outside your <code>PATH</code>, set a custom path there.</li>
  <li>Pick a Cursor model in the composer, or type <code>/cursor</code> to hand the current thread to Cursor.</li>
</ol>
<p>Instead of signing in, you can set <code>CURSOR_API_KEY</code>. Cursor keeps its login in the macOS Keychain and allows only one, so additional Cursor accounts in Coincide use API keys, which Coincide stores in your Keychain. ${s.link("/docs/agent-accounts", "Agent accounts")} has the details.</p>

<h2 id="models">Models</h2>
<p>Coincide asks the Cursor CLI which models you can use (through Cursor’s ACP extension, or <code>cursor-agent models</code>). A <em>Default</em> entry uses whatever model your Cursor CLI is set to. Where Cursor offers them for a model, Coincide shows its thinking levels as reasoning effort and its context sizes as options. Cursor models don’t have a separate fast mode in Coincide.</p>

<h2 id="features">What works with Cursor</h2>
${table(["In Coincide", "With Cursor"], [
  ["Plan mode", "Cursor’s own plan mode, switched over ACP, with Cursor’s plan captured in the thread."],
  ["Approvals and full access", "Ask for approval shows Cursor’s own choices for each request, plus Cancel. Full access runs <code>cursor-agent --force</code>; switching between the two restarts Cursor’s process and reloads the chat."],
  ["Questions", "Cursor’s questions are answered inline."],
  ["Follow-ups", "Messages sent while Cursor works are queued for the next turn; Cursor can’t take a message in the middle of a turn, so there’s no steering."],
  ["Attachments", "Images are sent to Cursor when it accepts them, and otherwise mentioned by path."],
  ["Resuming", "Each thread reloads its Cursor chat. If Cursor can’t load it, Coincide starts a new chat with a recap and says so."],
  ["Stopping", "Stop cancels the turn and gives Cursor five seconds to finish."],
  ["Usage limits", "Your monthly usage (overall, Cursor models and other models) and included and on-demand spend, read from Cursor. Off until you turn on Show account usage in Settings › Cursor, because it reads Cursor’s sign-in from your Keychain."],
])}

<h2 id="switching">Cursor and your other agents</h2>
<p>Because every agent in Coincide shares the thread, you can start a task with Cursor and continue it with Claude Code or Codex, or the other way round. The next agent gets a recap of the turns it missed. ${s.link("/features/switch-agents", "How switching works")}.</p>

<h2 id="limits">Limitations</h2>
<ul>
  <li>Coincide works with the Cursor CLI agent only, not with the Cursor editor or its features.</li>
  <li>No steering: follow-ups wait for the current turn.</li>
  <li>Changing between approvals and full access restarts the Cursor process for that thread.</li>
  <li>Usage limits aren’t available for API-key accounts.</li>
</ul>
`,
};
