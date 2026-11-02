import { cmd } from "../../layout.mjs";
import { shared, video, videoSchema } from "./_blog.mjs";

const launch = {
  id: "7_vTcjdud8M",
  title: "Coincide: every coding agent in one Mac app",
  description: "Coincide runs Claude Code, Codex, Cursor, Grok Build, OpenCode and Antigravity side by side in one native Mac window, and hands a thread from one agent to another.",
  image: "/img/blog/introducing-coincide.jpg",
  width: 1280,
  height: 720,
  uploaded: "2026-11-01",
  duration: "PT1M16S",
};

export default {
  path: "/blog/introducing-coincide",
  title: "Introducing Coincide: every coding agent in one Mac app",
  description: "Coincide launched November 1, 2026: a free, open-source Mac app that runs Claude Code, Codex, Cursor, Grok Build, OpenCode and Antigravity in one window.",
  name: "Introducing Coincide",
  summary: "The launch: one native Mac window for Claude Code, Codex, Cursor, Grok Build, OpenCode and Antigravity.",
  media: "Launch video",
  type: "Article",
  eyebrow: "Launch",
  h1: "Introducing Coincide",
  lede: "A free, open-source Mac app for the coding agents you already use: Claude Code, Codex, Cursor, Grok Build, OpenCode and Antigravity, side by side in one window.",
  published: "2026-11-01T21:22:00+05:30",
  updated: "2026-11-02",
  image: { url: "https://coincide.dev/img/blog/introducing-coincide.jpg", width: 1280, height: 720, alt: "Coincide: Every agent. One moment. The Janus logo with the Coincide bots." },
  schema: [videoSchema(launch)],
  related: ["/blog/one-conversation-six-agents", "/features", "/download"],
  body: (s) => `
${video(launch)}

<p>Coincide runs each agent through its own command-line tool, with the sign-in or API key you already have. Nothing goes through a Coincide server, and nothing is resold. It’s MIT-licensed, and the source is on <a href="https://github.com/apoorvdarshan/coincide">GitHub</a>.</p>

<h2 id="what">What it does</h2>
<ul>
  <li><strong>Switch agents mid-thread.</strong> Hand a thread from Claude Code to Codex, or any other agent, and the next one gets a recap of what it missed and keeps going in the same folder. ${s.link("/features/switch-agents", "How switching works")}.</li>
  <li><strong>Run them at the same time.</strong> ${s.link("/features/projects-and-threads", "Projects and threads")} with search, pinning and archiving, and a ${s.link("/features/command-palette", "⌘K command palette")}.</li>
  <li><strong>Agents keep working after you quit.</strong> Turns run in a ${s.link("/features/background-agents", "background agent host")}.</li>
  <li><strong>Approve right in the thread.</strong> ${s.link("/features/plan-mode", "Plan mode")}, ${s.link("/features/approvals", "approvals")} or full access, and questions answered inline.</li>
  <li><strong>Git built in.</strong> ${s.link("/features/git", "Diffs, per-turn checkpoints")}, ${s.link("/features/worktrees", "worktrees")}, commits, pushes and ${s.link("/features/pull-requests", "pull requests")}.</li>
  <li><strong>A ${s.link("/features/terminal", "terminal")} and a ${s.link("/features/browser", "browser")} in every thread</strong>, which agents can drive when you allow it, with password filling and Bitwarden passkeys.</li>
  <li><strong>${s.link("/features/bots", "Bots")}</strong> with a personality and a routine, ${s.link("/features/scheduled-tasks", "scheduled tasks")}, ${s.link("/features/computer-use", "Computer Use")} (off by default), ${s.link("/features/dictation", "dictation")} and a ${s.link("/features/usage-dashboard", "usage dashboard")}.</li>
</ul>

<h2 id="install">Install</h2>
<p>${s.link("/download", "Download the notarized DMG")}, or install it from the command line:</p>
${cmd("brew install --cask apoorvdarshan/tap/coincide")}
${cmd("npx coincide-dev")}
<p>It’s a universal app for Apple silicon and Intel Macs running macOS 26 or later.</p>

<h2 id="shared">Launch day, everywhere</h2>
${shared([
    ["YouTube", "https://youtu.be/7_vTcjdud8M", "the launch video"],
    ["DEV", "https://dev.to/apoorvdarshan/coincide-claude-code-codex-cursor-and-more-side-by-side-on-your-mac-14a2", "the launch article"],
    ["Bluesky", "https://bsky.app/profile/apoorvdarshan.com/post/3mzb6bfase422", "launch post with the video"],
    ["Mastodon", "https://mastodon.social/@apoorvcodes/117541998847102223", "launch post with the video"],
    ["daily.dev", "https://app.daily.dev/posts/i-built-a-native-swift-harness-that-runs-claude-code-codex-cursor-grok-opencode-and-antigravity--qbv8iokhi", "“I built a native Swift harness…”, November 2"],
    ["Product Hunt", "https://www.producthunt.com/products/coincide", "launched November 2"],
  ])}
<p>Feedback, bug reports and stars are all welcome, on <a href="https://github.com/apoorvdarshan/coincide/issues">GitHub</a> or in the <a href="https://discord.gg/DETrbhDVqw">Discord</a>.</p>
`,
};
