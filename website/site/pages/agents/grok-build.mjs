import { cmd, table } from "../../layout.mjs";

export default {
  path: "/agents/grok-build",
  title: "Grok Build in a native Mac app · Coincide",
  description: "Run xAI’s Grok Build agent in Coincide over ACP with your Grok login or xAI API key: models, reasoning effort, approvals, plans and usage limits.",
  name: "Grok Build",
  summary: "xAI’s agent through the grok CLI over ACP, with your Grok login or an xAI API key, and its usage limits.",
  icon: "/img/logo-grok.png",
  logo: { src: "/img/logo-grok.png", alt: "Grok logo" },
  eyebrow: "Agent · xAI",
  h1: "Grok Build in Coincide",
  lede: "Coincide runs xAI’s <code>grok</code> command-line agent over the Agent Client Protocol, signed in with your Grok account or an xAI API key, and keeps its threads, plans and changes next to your other agents.",
  related: ["/features/approvals", "/features/plan-mode", "/docs/agent-accounts", "/features/usage-dashboard", "/agents/opencode"],
  body: (s) => `
<h2 id="how">How Coincide runs Grok Build</h2>
<p>Coincide starts <code>grok agent stdio</code> and talks to it over the Agent Client Protocol (ACP). In approval mode it adds <code>--permission-mode default</code>; with full access it adds <code>--always-approve</code>. Grok Build does the work and talks to xAI under your account. Coincide finds <code>grok</code> on your shell’s <code>PATH</code>, in <code>~/.grok/bin</code> and in the usual install folders, or at a custom path you set in Settings › Grok Build.</p>

<h2 id="setup">Set it up</h2>
<ol>
  <li><strong>Install Grok Build</strong> by following xAI’s instructions on the <a href="https://x.ai/cli">Grok CLI page</a>.</li>
  <li><strong>Sign in:</strong>
${cmd("grok login", "Copy the sign-in command")}</li>
  <li><strong>Open Settings › Grok Build</strong> and choose Check Again. Coincide runs <code>grok --version</code> and <code>grok models</code> to see whether you’re signed in, and shows your account’s email from <code>~/.grok/auth.json</code>.</li>
  <li>Pick a Grok model in the composer, or type <code>/grok</code> to continue the current thread with Grok Build.</li>
</ol>
<p>You can also use an xAI API key (<code>XAI_API_KEY</code>), and add more Grok login accounts: each gets its own <code>GROK_HOME</code> folder and its own <code>grok login</code>. See ${s.link("/docs/agent-accounts", "Agent accounts")}.</p>

<h2 id="models">Models and reasoning effort</h2>
<p>Coincide reads your models from <code>grok models</code>, with names, reasoning efforts and context windows from Grok’s own model cache, and puts a <em>Grok Build</em> default entry first. Once a session is running, Grok reports the efforts each model supports, and Coincide applies your choice of model and effort over ACP. There’s no separate fast mode for Grok models.</p>

<h2 id="features">What works with Grok Build</h2>
${table(["In Coincide", "With Grok Build"], [
  ["Plan mode", "Grok has no plan mode over ACP, so Coincide asks for a plan in the prompt instead. When Grok finishes planning, its plan is captured in the thread."],
  ["Approvals", "For each request you can Approve, Allow all edits this session, Decline or Cancel. Reading and searching files is always allowed."],
  ["Full access", "Runs Grok with <code>--always-approve</code>. Switching between approvals and full access restarts Grok’s process."],
  ["Questions", "Grok’s questions are answered inline."],
  ["Follow-ups", "Queued until the current turn ends; Grok can’t be steered in the middle of a turn."],
  ["Attachments", "PNG, JPEG, GIF and WebP images up to 10 MB are sent to Grok."],
  ["Stopping", "Stop ends Grok’s process; the next turn reopens the same session."],
  ["Resuming", "Each thread reloads its own Grok session."],
  ["Usage limits", "Your Grok subscription’s weekly or monthly credit window, read from xAI with your Grok sign-in. Not shown for API keys."],
])}

<h2 id="switching">Grok Build and your other agents</h2>
<p>Hand a thread to Grok Build with <code>/grok</code> and it gets a recap of what the other agents did, in the same folder. Hand it back and the earlier agent resumes its own session. This works the same way for every agent; see ${s.link("/features/switch-agents", "switching agents mid-thread")}.</p>

<h2 id="limits">Limitations</h2>
<ul>
  <li>No native plan mode or mid-turn steering over ACP.</li>
  <li>When Grok reports that you’ve reached its usage limit, Coincide shows “Grok usage limit reached. Try again later.”</li>
  <li>Bot personalities and other standing instructions are sent with the first message, because Grok Build doesn’t take a separate system prompt from Coincide.</li>
  <li>Usage limits aren’t read for API keys or custom auth settings.</li>
</ul>
`,
};
