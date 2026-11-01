import { kbd, table } from "../../layout.mjs";

export default {
  path: "/features/model-picker",
  title: "One model picker for every coding agent · Coincide",
  description: "Pick any model from Claude Code, Codex, Cursor, Grok Build, OpenCode or Antigravity in one searchable menu, with favorites, reasoning effort and speed.",
  name: "Model picker",
  summary: "Every installed agent’s models in one searchable menu, with favorites, hidden models, reasoning effort and speed.",
  type: "WebPage",
  eyebrow: "Feature",
  h1: "One picker for every agent’s models",
  lede: "Coincide asks each installed agent for its models and puts them in one menu, grouped by agent. Choosing a model also chooses the agent, so switching from Claude Code to Codex is the same gesture as switching between two Claude models.",
  related: ["/features/switch-agents", "/features/usage-dashboard", "/docs/agent-accounts", "/agents"],
  body: (s) => `
<h2>Opening it</h2>
<ul>
  <li>Click the model button in the composer, below where you type.</li>
  <li>Thread › Choose Agent and Model… or ${kbd("⇧", "⌘", "M")}.</li>
  <li>Type <code>/model</code> in the composer.</li>
  <li>In the ${s.link("/features/command-palette", "command palette")} (${kbd("⌘", "K")}), Choose Agent and Model… searches every model.</li>
</ul>

<h2>What’s in it</h2>
<p>The picker has a search field, a <strong>Favorites</strong> tab and a tab for each agent with its logo. An agent that isn’t set up yet shows a dimmed logo. The chosen tab lists that agent’s models with their context sizes, the agent’s default model marked <strong>Default</strong>. Searching looks through every ready agent’s models at once. Tab and Shift-Tab step between the tabs, and the arrow keys move through the list.</p>
<ul>
  <li><strong>Favorites.</strong> Hover over a model and click its star, or use Add to Favorites from its context menu. Favorites from every agent are listed together, and the picker opens on them once you have any.</li>
  <li><strong>Hidden models.</strong> Hide Model in a row’s context menu removes it from the picker. Settings › Models shows hidden models again.</li>
  <li><strong>Accounts.</strong> When an agent has more than one account set up, chips under the tabs choose which account the model runs with. See ${s.link("/docs/agent-accounts")}.</li>
  <li><strong>Reasoning and Speed.</strong> Under the list, chips show the current model’s reasoning efforts and, when it offers more than one, its speeds, starting with Standard.</li>
  <li><strong>Refresh</strong> asks the agents for their models again; <strong>Agent Settings…</strong> opens their settings.</li>
</ul>
<p>Thread › Reasoning Effort… (${kbd("⇧", "⌘", "E")}) changes effort without opening the whole picker.</p>

<h2>Where the models come from</h2>
<p>Coincide doesn’t keep its own list of what you’re allowed to use. Each agent reports its models through its own CLI, with your sign-in, so the picker shows what your plan or key can run. A few built-in entries cover the case where an agent can’t be asked yet.</p>
${table(["Agent", "Models listed from", "Reasoning effort", "Speed"], [
  ["Claude Code", "Claude Code’s startup handshake, checked against Coincide’s catalog of Claude models", "Per model, from low to max, plus ultracode and ultrathink where they apply", "Fast mode on models that support it"],
  ["Codex", "<code>codex app-server</code>’s model list", "The efforts each model supports", "The service tiers each model offers"],
  ["Cursor", "Cursor’s model list over ACP, else <code>cursor-agent models</code>", "From the model’s thought-level option", "—"],
  ["Grok Build", "<code>grok models</code> and Grok’s model cache", "The efforts Grok reports", "—"],
  ["OpenCode", "OpenCode’s server, as <code>provider/model</code>", "Each model’s reasoning variants", "—"],
  ["Antigravity", "Antigravity’s runtime, for your account", "Only if the runtime offers it", "—"],
])}
<p>When Claude Code can’t run a turn at fast speed, for example on a free plan or a model that doesn’t allow it, the thread says why and the turn runs at standard speed.</p>

<h2>Managing models in Settings</h2>
<p>Settings › Models lists every model from every agent with a filter and a provider menu. From there you can add or remove favorites, hide models or show them again, and <strong>add a custom model</strong>: enter the ID the agent’s CLI accepts and it appears in the picker even if the CLI doesn’t list it. This helps with a model that’s new or behind a flag.</p>
<p>Settings › General › New Threads sets the model and reasoning effort new threads start with. Choosing a model, effort, speed or access in a thread also makes that the default for the next new thread. A project can override this with its own defaults (see ${s.link("/features/projects-and-threads")}).</p>

<h2>Things to know</h2>
<ul>
  <li>An agent appears in the picker once it’s installed and signed in; until then its tab is dimmed. The ${s.link("/agents", "agent pages")} cover setup.</li>
  <li>Picking a Cursor model in Coincide doesn’t change Cursor CLI’s own default: Coincide puts the CLI’s model setting back.</li>
  <li>Antigravity’s tab carries a warning about Google’s terms; see ${s.link("/agents/antigravity")}.</li>
  <li>The models you can use, and their limits, are set by each provider, not by Coincide.</li>
</ul>
`,
};
