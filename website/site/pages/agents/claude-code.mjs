import { cmd, table } from "../../layout.mjs";

export default {
  path: "/agents/claude-code",
  title: "Claude Code in a native Mac app · Coincide",
  description: "Use Claude Code in Coincide with your Claude subscription or API key: plan mode, steering, subagents, fast mode, usage limits and switching agents mid-thread.",
  name: "Claude Code",
  summary: "Anthropic’s agent through its own CLI, with your Claude plan or API key. Plan mode, steering, subagents and fast mode.",
  icon: "/img/logo-claude.png",
  logo: { src: "/img/logo-claude.png", alt: "Claude logo" },
  eyebrow: "Agent · Anthropic",
  h1: "Claude Code in Coincide",
  lede: "Coincide runs the <code>claude</code> command-line tool you already have installed, signed in with your own Claude plan or Anthropic API key, and gives it a native Mac window, threads, git tools and a browser. You can hand any thread to another agent and back.",
  related: ["/features/plan-mode", "/features/switch-agents", "/docs/import-cli-sessions", "/docs/agent-accounts", "/compare/claude-desktop"],
  body: (s) => `
<h2 id="how">How Coincide runs Claude Code</h2>
<p>Coincide starts <code>claude</code> and talks to it over Claude Code’s stream-json control protocol, the same one Anthropic’s Agent SDK uses. Nothing goes through a Coincide server: Claude Code talks to Anthropic (or to the Bedrock, Vertex AI or gateway endpoint it’s configured for) exactly as it does in Terminal. Coincide never resells, proxies or meters your tokens.</p>
<p>Coincide looks for <code>claude</code> on your login shell’s <code>PATH</code> and in the usual install folders, such as Homebrew’s and <code>~/.local/bin</code>. If yours lives elsewhere, set a custom path in Settings › Claude Code. Your own Claude Code configuration, <code>CLAUDE.md</code> files and settings keep applying, because it’s the same tool.</p>
<p>Turns run in Coincide’s ${s.link("/features/background-agents", "background agent host")}, so a long Claude Code turn keeps going when you quit or update Coincide.</p>

<h2 id="setup">Set it up</h2>
<ol>
  <li><strong>Install Claude Code</strong> with Anthropic’s installer (see the <a href="https://claude.com/product/claude-code">official Claude Code page</a> for other ways):
${cmd("curl -fsSL https://claude.ai/install.sh | bash", "Copy the Claude Code install command")}</li>
  <li><strong>Sign in</strong> with your Claude account, or set up an API key:
${cmd("claude auth login", "Copy the sign-in command")}</li>
  <li><strong>Open Settings › Claude Code</strong> in Coincide. It shows whether Claude Code is installed and signed in, its version and account, and can run both commands in Terminal for you. Choose Check Again after signing in.</li>
  <li><strong>Pick a Claude model</strong> in the composer’s ${s.link("/features/model-picker", "model picker")} and send your first message.</li>
</ol>
<p>To use more than one Claude account, or an Anthropic API key next to your subscription, add accounts in the same pane. Each login account gets its own Claude Code configuration folder, and API keys are kept in your Keychain. ${s.link("/docs/agent-accounts", "Agent accounts")} explains how.</p>

<h2 id="models">Models, effort and fast mode</h2>
<p>The model list comes from Claude Code itself, so it matches what your account can use, filled in with details Coincide knows about each model. If a model needs a newer Claude Code than you have, Coincide says which version to upgrade to.</p>
<ul>
  <li><strong>Reasoning effort:</strong> the levels Claude Code accepts for the model (from low up to max), plus <em>ultrathink</em> on models that support it, which Coincide asks for in the prompt.</li>
  <li><strong>Fast mode:</strong> offered on models that report it. If Claude Code ran a turn at standard speed anyway, Coincide shows Claude Code’s reason, such as needing a paid plan or usage credits.</li>
  <li><strong>Custom models:</strong> add model IDs Claude Code accepts but doesn’t list in Settings › Claude Code.</li>
</ul>

<h2 id="features">What works with Claude Code</h2>
${table(["In Coincide", "With Claude Code"], [
  ["Plan mode", "Claude Code’s own plan mode. When Claude finishes a plan, Coincide shows it and Claude waits; if Claude enters plan mode by itself, you choose Implement or Keep planning."],
  ["Approvals and full access", "Ask for approval uses Claude Code’s default permission mode. Full access uses <code>bypassPermissions</code>; if your Claude Code settings forbid that, Coincide falls back to auto mode, then to asking. “Always allow” lasts for the session."],
  ["Questions", "Claude’s questions and MCP servers’ forms are answered inline in the thread."],
  ["Steering", "A message sent while Claude works can steer the running turn instead of waiting for it."],
  ["Attachments", "Images (PNG, JPEG, GIF, WebP) and PDFs are sent to Claude; other files are mentioned by path."],
  ["Subagents", "Subagents’ tool calls show as progress in the turn, and background work is tracked."],
  ["Resuming", "Each thread keeps its own Claude Code session. Coincide also names it after the thread, so <code>claude --resume</code> in Terminal shows the same titles."],
  ["Usage limits", "Your plan’s session and weekly limits, read from Claude Code, in the composer and the ${s.link("/features/usage-dashboard", "usage dashboard")}."],
  ["Importing", "Earlier Claude Code conversations can be ${s.link("/docs/import-cli-sessions", "imported")} from <code>~/.claude</code> and continued."],
])}

<h2 id="switching">Switching to and from Claude Code</h2>
<p>Type <code>/claude</code> in the composer, or pick a Claude model, to hand a thread that another agent started to Claude Code. Claude gets a recap of the turns it missed and works in the same folder. Switch away and back again, and Claude Code resumes its own session with only the newer turns recapped. ${s.link("/features/switch-agents", "How switching works")}.</p>

<h2 id="limits">Limitations</h2>
<ul>
  <li>Coincide uses the Claude Code you have installed, so new Claude Code features appear only once Coincide supports them, and some models need a recent Claude Code.</li>
  <li>Changing some settings in the middle of a thread restarts Claude Code’s process, which stops its background work; Coincide tells you when that happens.</li>
  <li>With a custom API endpoint (a non-Anthropic <code>ANTHROPIC_BASE_URL</code>), plan usage limits aren’t shown.</li>
  <li>Claude Code’s own usage policies and plan limits apply as usual.</li>
</ul>
`,
};
