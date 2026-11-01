import { table } from "../../layout.mjs";

export default {
  path: "/docs/agent-accounts",
  title: "Multiple agent accounts and API keys · Coincide",
  description: "Use two Claude Code logins, an API key next to a subscription, or several OpenCode providers: how agent accounts work in Coincide and where keys are kept.",
  name: "Accounts and API keys",
  summary: "Add a second subscription login or an API key to any agent, pick it per thread, and see where each key is kept.",
  type: "TechArticle",
  eyebrow: "Guide",
  h1: "Agent accounts and API keys",
  lede: "Each agent in Coincide starts with one account: its command-line tool’s own sign-in, exactly as you set it up in Terminal. You can add more, such as a second subscription login or an API key, and choose which one each thread uses.",
  related: ["/agents", "/features/model-picker", "/features/usage-dashboard", "/docs/data-storage"],
  body: (s) => `
<h2 id="default">The default account</h2>
<p>Coincide runs each agent’s own tool with your login shell’s environment, so the default account is whatever that tool is signed in to: your Claude subscription in <code>~/.claude</code>, your ChatGPT login in <code>~/.codex</code>, and so on. If your shell exports an API key the tool reads, such as <code>ANTHROPIC_API_KEY</code>, the default account uses it the way the tool would in Terminal. Nothing about it changes when you add other accounts. For signing in to each agent the first time, see the ${s.link("/agents", "agent pages")}.</p>

<h2 id="add">Adding an account</h2>
<ol>
  <li>Open Settings and choose the agent under <strong>Providers</strong> in the sidebar.</li>
  <li>In <strong>Accounts</strong>, add an account, name it, and pick how it signs in: a login or an API key.</li>
  <li>For a login, Coincide opens a terminal that runs that agent’s sign-in for this account only, in a folder of its own. For an API key, paste the key; Coincide saves it in the Keychain and can check it (“Key not accepted” means the service refused it).</li>
</ol>
<p>When an agent has more than one account, the ${s.link("/features/model-picker", "model picker")} shows an <strong>Account</strong> row under the agent’s tab, and the thread uses the account you pick. Removing an account deletes its key and sign-in from this Mac; threads that used it continue with the agent’s default account.</p>

<h2 id="per-agent">What each agent supports</h2>
${table(["Agent", "Added logins", "API keys"], [
  ["Claude Code", "Yes: each gets its own <code>CLAUDE_CONFIG_DIR</code> and signs in with <code>claude auth login</code>", "Anthropic API key, passed as <code>ANTHROPIC_API_KEY</code>"],
  ["Codex", "Yes: each gets its own <code>CODEX_HOME</code> and signs in with <code>codex login</code>", "OpenAI API key, stored in that account’s own <code>CODEX_HOME</code> with <code>codex login --with-api-key</code>"],
  ["Cursor", "No: Cursor keeps one login, in the macOS Keychain", "Cursor API key, passed as <code>CURSOR_API_KEY</code>"],
  ["Grok Build", "Yes: each gets its own <code>GROK_HOME</code> and signs in with <code>grok login</code>", "xAI API key, passed as <code>XAI_API_KEY</code>"],
  ["OpenCode", "Yes: each gets its own <code>XDG_DATA_HOME</code> and signs in with <code>opencode auth login --standalone</code>", "A key for OpenCode Zen (<code>OPENCODE_API_KEY</code>), Anthropic, OpenAI, OpenRouter, Google Gemini, xAI, Groq, DeepSeek or Mistral, each in that service’s own variable, in a folder of its own"],
  ["Antigravity", "No: the Google sign-in belongs to Coincide’s one managed Antigravity profile", "Gemini API key (<code>GEMINI_API_KEY</code>), in a profile of its own"],
])}
<p>An added account’s folder is <code>providers/<em>agent</em>/<em>account ID</em>/</code> inside Coincide’s ${s.link("/docs/data-storage", "data folder")}, so two logins of one agent never overwrite each other.</p>
<div class="callout warn"><p><strong>Antigravity and Google accounts.</strong> Google’s Antigravity terms treat using the service through third-party software as a breach, and Google has suspended accounts for it. Coincide shows this notice and asks you to acknowledge it once. Gemini API keys from Google AI Studio or Gemini Enterprise aren’t affected. Details on the ${s.link("/agents/antigravity", "Antigravity page")}.</p></div>

<h2 id="keys">Where keys are kept</h2>
<ul>
  <li>Each account’s API key is one item in your login Keychain, labelled “Coincide: <em>account name</em>”. It never goes in settings, logs or thread files.</li>
  <li>When the agent starts, Coincide hands the key to that agent’s process only, in the variable the tool reads.</li>
  <li>For an added account, Coincide removes API-key variables your shell exports for that agent, so a login account isn’t silently signed in with a shell key, and an API-key account uses only its own key.</li>
</ul>

<h2 id="usage">Usage and Admin keys</h2>
<p>Settings › Usage shows plan limits per account where the provider reports them; most providers report no plan limits for API keys. An Anthropic API-key account can also take an optional <strong>Admin API key</strong>, which gives read-only access to your organization’s usage and cost reports. It’s kept in the Keychain beside the account’s key and sent only to Anthropic. See ${s.link("/features/usage-dashboard")}.</p>

<h2 id="environment">Other settings per agent</h2>
<p>Each agent’s page in Settings also has <strong>Environment Variables</strong>, added to the agent’s environment on top of your login shell’s, for example a custom base URL, and a <strong>Custom path</strong> for its executable. These apply to every account of that agent.</p>
`,
};
