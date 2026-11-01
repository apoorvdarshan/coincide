// The features hub. Each group lists its pages by path; a page's card text is its `summary`.
const GROUPS = [
  ["Agents and threads", "Run several agents in one window and move work between them.", [
    "/features/switch-agents", "/features/model-picker", "/features/projects-and-threads", "/features/command-palette",
    "/features/plan-mode", "/features/approvals", "/features/composer", "/features/transcript",
    "/features/background-agents", "/features/notifications",
  ]],
  ["Code and git", "Review what agents changed, undo a turn and ship it.", [
    "/features/git", "/features/worktrees", "/features/pull-requests", "/features/terminal",
  ]],
  ["The browser and your Mac", "Let agents work in a real browser and, if you allow it, in other apps.", [
    "/features/browser", "/features/browser-passwords", "/features/passkeys", "/features/computer-use",
    "/features/appshots", "/features/keep-awake",
  ]],
  ["Automation", "Work that runs on a schedule, from a bot or from a script.", [
    "/features/scheduled-tasks", "/features/bots", "/features/command-line", "/features/instructions",
  ]],
  ["Everything else", "", [
    "/features/dictation", "/features/usage-dashboard", "/features/languages", "/features/coincide-remote",
  ]],
];

export default {
  path: "/features",
  title: "Coincide features: one Mac app for every coding agent",
  description: "Everything Coincide adds to your coding agents: mid-thread switching, plan mode, git and checkpoints, a browser per thread, schedules, bots and more.",
  name: "Features",
  summary: "Everything Coincide does, by topic.",
  type: "CollectionPage",
  eyebrow: "Features",
  h1: "What Coincide adds to your agents",
  lede: "Coincide is a native Mac app built with AppKit. It runs the coding agents you already use and wraps them in the tools around the conversation: threads, git, a terminal and a browser per thread, schedules and bots.",
  wide: true,
  related: ["/agents", "/docs/getting-started", "/download", "/compare"],
  body: (s) => GROUPS.map(([title, text, paths]) => `
<h2 class="group-title">${title}</h2>
${text ? `<p>${text}</p>` : ""}
${s.cards(paths)}`).join("\n"),
};
