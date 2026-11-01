import { table } from "../../layout.mjs";

export default {
  path: "/features/instructions",
  title: "One AGENTS.md for every coding agent · Coincide",
  description: "Edit AGENTS.md, CLAUDE.md and GEMINI.md in one place, link every agent to one master file, and sync it to iCloud Drive or a Git repository.",
  name: "Instruction files",
  summary: "Edit every agent’s instruction files in one place, use one master file for all agents, and sync it.",
  type: "WebPage",
  eyebrow: "Feature",
  h1: "Instruction files for every agent",
  lede: "Each agent reads its standing instructions from its own file: Claude Code from <code>CLAUDE.md</code>, Codex, OpenCode and others from <code>AGENTS.md</code>, Antigravity from <code>GEMINI.md</code>. Coincide shows which agent reads which file, lets you edit them, can link them all to one master file, and can keep that file in step across your Macs.",
  related: ["/features/bots", "/features/projects-and-threads", "/agents", "/docs/data-storage"],
  body: (s) => `
<h2 id="where">Open the instructions</h2>
<ul>
  <li><strong>Global instructions</strong>, which every agent reads in every project: Settings › Instructions.</li>
  <li><strong>A project’s instructions</strong>: select the project and choose File › Edit Instructions…</li>
</ul>
<p>Each file is listed with the agents that read it (“Used by: Codex, Cursor, Grok Build…”), whether it’s a link and where to, and whether it can be read. Edit it right there, or use Open in Editor and Reveal in Finder. If a file changes on disk while you have unsaved edits, Coincide tells you rather than overwriting it.</p>

<h2 id="files">Which agent reads which file</h2>
${table(["Agent", "Global file", "In a project"], [
    ["Claude Code", "<code>~/.claude/CLAUDE.md</code> (or in <code>$CLAUDE_CONFIG_DIR</code>)", "<code>CLAUDE.md</code>, <code>CLAUDE.local.md</code>, <code>.claude/CLAUDE.md</code>"],
    ["Codex", "<code>~/.codex/AGENTS.md</code> (or in <code>$CODEX_HOME</code>)", "<code>AGENTS.md</code>, or <code>AGENTS.override.md</code> first"],
    ["Cursor", "None: Cursor keeps user rules in its own settings", "<code>AGENTS.md</code>, <code>.cursorrules</code>, <code>.cursor/rules/*.mdc</code>"],
    ["Grok Build", "<code>~/.grok/AGENTS.md</code> (or in <code>$GROK_HOME</code>), and Claude Code’s file with its Claude compatibility on", "<code>AGENTS.md</code>, <code>CLAUDE.md</code>"],
    ["OpenCode", "<code>~/.config/opencode/AGENTS.md</code>", "<code>AGENTS.md</code>"],
    ["Antigravity", "<code>GEMINI.md</code> in Coincide’s private Antigravity profile", "<code>AGENTS.md</code>, <code>GEMINI.md</code>"],
  ])}
<p>Accounts you add with their own configuration folder (see ${s.link("/docs/agent-accounts", "agent accounts")}) have their own global files, and Coincide lists those too. If a project has no <code>AGENTS.md</code> yet, Create AGENTS.md makes one; Link CLAUDE.md to AGENTS.md then makes Claude Code read the same text.</p>

<h2 id="one-file">Use one file for all agents</h2>
<p>Turn on “Use one file for all agents” and Coincide links each agent’s file to one master file with a symbolic link, so <code>CLAUDE.md → AGENTS.md</code> and every agent reads the same instructions. It’s off by default.</p>
<ul>
  <li>For a project, the master is its <code>AGENTS.md</code>, which most agents read already.</li>
  <li>For global instructions, the default master is <code>~/.config/coincide/AGENTS.md</code>, a folder no agent owns, so removing an agent never removes your instructions. You can choose another file.</li>
  <li>Files whose text differs are backed up first, as <code>CLAUDE.md.coincide-backup-&lt;date&gt;</code> beside the original. Coincide never deletes text. If two files differ, Compare… shows the lines only in each, and you choose what to keep.</li>
  <li>Saving through a link writes the file it points to and never replaces the link itself. Fix Links… repairs broken links, and turning the option off can replace links with copies of the master.</li>
</ul>

<h2 id="sync">Sync the master file</h2>
<p>Once there’s a master, Sync… keeps a copy of it in step, in one or both places. The master stays where it is; changes made in Coincide go to the copy, and changes made to the copy, for example on your other Mac, come back.</p>
<ul>
  <li><strong>iCloud Drive:</strong> a copy at iCloud Drive › Coincide › Instructions, so Coincide on your other Macs uses the same instructions.</li>
  <li><strong>GitHub or a Git repository:</strong> a copy in a repository you choose, committed whenever the instructions change and, with “Push changes right away”, pushed. Coincide can create a private GitHub repository for it with <code>gh repo create --private</code>. It never force-pushes and never pushes other files.</li>
</ul>
<p>If the master and a copy both changed, Coincide asks which to keep and backs up the other. Synced instructions leave your Mac, so keep keys, tokens and passwords out of them.</p>

<h2 id="bots">Instructions and bots</h2>
<p>These files are what every agent reads in a folder. A ${s.link("/features/bots", "bot’s")} own instructions are separate: they go to its agent at the start of each session, on top of whatever files the folder has.</p>
`,
};
