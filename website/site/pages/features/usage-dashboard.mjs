import { table } from "../../layout.mjs";

export default {
  path: "/features/usage-dashboard",
  title: "Usage limits for Claude, Codex, Cursor and more · Coincide",
  description: "See plan limits, credits and token activity for every coding agent in one place, from each provider’s own reports, plus a menu bar gauge. All on your Mac.",
  name: "Usage dashboard",
  summary: "Every agent’s plan limits and credits in one place, token activity charts and a menu bar gauge.",
  type: "WebPage",
  eyebrow: "Feature",
  h1: "Usage dashboard",
  lede: "How much of your Claude plan is left this week? Is Codex close to its limit? Settings › Usage answers both for every agent you use, from the figures each provider reports, next to charts of what your agents did in Coincide. A menu bar item keeps the closest limit in view.",
  related: ["/features/model-picker", "/docs/agent-accounts", "/agents"],
  body: (s) => `
<h2 id="limits">Plan limits and credits</h2>
<p>For each signed-in agent account, Coincide shows the limits its provider reports, such as a 5-hour session window, a weekly limit or a monthly allowance, how much of each is used, and when it resets. A mark shows where even spending across the window would be, so you can tell whether you’re ahead of pace. Choose whether figures read as what’s used or what’s left.</p>
<p>Coincide reads these with the sign-in each agent already keeps on your Mac, and the credential goes only in a request header to that provider’s own address:</p>
${table(["Agent", "Where the figures come from"], [
    [s.link("/agents/claude-code", "Claude Code"), "Claude Code itself: session and weekly limits, per-model weekly limits, monthly spend and extra usage, updated live as you work"],
    [s.link("/agents/codex", "Codex"), "Codex itself, for ChatGPT sign-ins: plan limits, per-model limits and credits, updated live"],
    [s.link("/agents/cursor", "Cursor"), "Cursor’s usage service: monthly limits and dollar figures for included and on-demand usage. Off until you turn on “Show account usage” in Settings › Cursor, since it reads Cursor’s sign-in from your Keychain"],
    [s.link("/agents/grok-build", "Grok Build"), "xAI’s billing service for Grok sign-ins: the weekly, monthly or subscription window"],
    [s.link("/agents/opencode", "OpenCode"), "OpenCode Go plan windows, with OpenCode’s own stored key"],
    [s.link("/agents/antigravity", "Antigravity"), "Google’s Cloud Code service: Gemini and shared Claude &amp; GPT windows, 5-hour and weekly"],
  ])}
<p>The same figures appear in the composer while you work, so you see a limit coming before a turn fails. Accounts that use an API key have no plan limits; for those, Coincide counts the tokens of the turns it runs.</p>

<h3 id="extras">Extra figures you can turn on</h3>
<ul>
  <li><strong>Anthropic API keys:</strong> on request, Coincide reads a key’s per-minute rate limits by sending a one-token message, which costs a fraction of a cent. If you add an Anthropic Admin API key, it reads your organization’s usage and cost reports from Anthropic.</li>
  <li><strong>Provider websites</strong> (off by default): “Use my browser sign-in for extra details” reads Codex credit details from chatgpt.com, your prepaid API credit balance from the Claude Console, and your OpenCode Zen balance from the OpenCode Console, with your sign-in in ${s.link("/features/browser", "Coincide’s browser")}. These are the sites’ own internal pages, not public APIs, so they can stop working without notice; Coincide then says why.</li>
</ul>

<h2 id="activity">Activity in Coincide</h2>
<p>Below the limits, Settings › Usage charts the turns your agents ran, for today or the last 7, 30 or 90 days, for all agents or one:</p>
<ul>
  <li>tokens per day, split into input, output and cache reads and writes;</li>
  <li>an estimated cost per day at the providers’ API list prices, labelled as an estimate, since subscription usage isn’t billed per token;</li>
  <li>top models and top projects, turns, threads and active time.</li>
</ul>
<p>“Include usage from outside Coincide” (on by default) also counts Claude Code and Codex sessions you ran in a terminal or another app, read from their own logs on your Mac. Coincide keeps the history of the latest 10,000 finished turns, on your Mac only.</p>
<p>Token counts and reported costs are shown with their scope. Coincide never adds them up into a bill: your provider’s invoice is the only billing total.</p>

<h2 id="menu-bar">The menu bar item</h2>
<p>With “Show usage in the menu bar” on (the default), Coincide’s menu bar item shows one figure: by default the agent you used last, with its most used limit or its credit balance. You can pin a specific account and limit instead, show the limit closest to running out across every account as a gauge, or add a second figure beside the first. Click it for every account’s limits and today’s usage.</p>

<h2 id="refresh">How often it refreshes</h2>
<p>Limits refresh automatically while you work, and on a schedule you can set, from every minute to every hour, or only when you open the dashboard. Claude Code and Codex also push updates during turns.</p>

<h2 id="privacy">Privacy</h2>
<p>None of this goes to us. Usage requests go from your Mac straight to each provider, and the history stays in Coincide’s data folder. The <a href="/privacy">privacy policy</a> lists every usage source.</p>
`,
};
