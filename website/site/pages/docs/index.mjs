const GROUPS = [
  ["Start here", ["/docs/getting-started", "/download", "/docs/updating", "/docs/uninstall"]],
  ["Reference", ["/docs/keyboard-shortcuts", "/docs/cli", "/docs/settings", "/docs/environment-variables"]],
  ["Guides", ["/docs/agent-accounts", "/docs/import-cli-sessions", "/docs/rich-output", "/docs/data-storage", "/docs/macos-permissions", "/docs/troubleshooting"]],
  ["Contributing", ["/docs/build-from-source", "/docs/translations"]],
];

export default {
  path: "/docs",
  title: "Coincide documentation: guides and reference",
  description: "Guides and reference for Coincide: getting started, updates, shortcuts, the coincide command, settings, agent accounts, data locations and troubleshooting.",
  name: "Docs",
  summary: "Guides and reference for using Coincide.",
  type: "CollectionPage",
  eyebrow: "Docs",
  h1: "Coincide documentation",
  lede: "How to install Coincide, connect your agents and get the most out of it, with reference pages for every shortcut, command and setting.",
  wide: true,
  related: ["/faq", "/features", "/agents", "/changelog"],
  body: (s) => `${GROUPS.map(([title, paths]) => `
<h2 class="group-title">${title}</h2>
${s.cards(paths)}`).join("\n")}

<h2 class="group-title">More help</h2>
<p>Answers to common questions are in the ${s.link("/faq", "FAQ")}, and what changed in each release is in the ${s.link("/changelog", "changelog")}. For anything else, ask in the <a href="https://discord.gg/DETrbhDVqw">Coincide Discord</a> or open an issue on <a href="https://github.com/apoorvdarshan/coincide/issues">GitHub</a>. The source code is the final reference: <a href="https://github.com/apoorvdarshan/coincide">github.com/apoorvdarshan/coincide</a>.</p>`,
};
