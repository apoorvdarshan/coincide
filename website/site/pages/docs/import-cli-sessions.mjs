import { table } from "../../layout.mjs";

export default {
  path: "/docs/import-cli-sessions",
  title: "Import Claude Code and Codex CLI sessions · Coincide",
  description: "Bring Claude Code or Codex conversations from Terminal into Coincide as threads that resume the same session, without changing the original files.",
  name: "Import CLI sessions",
  summary: "Turn Claude Code and Codex conversations from Terminal into Coincide threads that resume the same native session.",
  type: "TechArticle",
  eyebrow: "Guide",
  h1: "Import sessions from Claude Code and Codex",
  lede: "Conversations you started with <code>claude</code> or <code>codex</code> in Terminal don’t have to stay there. Coincide can import them as threads that keep the agent’s own session, so the next message continues where the CLI left off.",
  related: ["/agents/claude-code", "/agents/codex", "/features/switch-agents", "/features/projects-and-threads"],
  body: (s) => `
<h2 id="how">Importing a session</h2>
<ol>
  <li>Choose <strong>File › Import CLI Session…</strong>. Coincide scans your local histories: <code>~/.claude/projects</code> for Claude Code and <code>~/.codex/sessions</code> and <code>~/.codex/archived_sessions</code> for Codex. It follows <code>CLAUDE_CONFIG_DIR</code> and <code>CODEX_HOME</code> when Coincide itself was started with them, for example from Terminal; otherwise use Choose File… for histories kept elsewhere.</li>
  <li>Search by title or folder and select a session to preview the conversation.</li>
  <li>Click <strong>Import</strong>. If you already imported that session, Coincide offers <strong>Open Existing Thread</strong> instead of making a duplicate.</li>
</ol>
<p>To import a file the list doesn’t show, use <strong>Choose File…</strong> and pick a Claude Code session or Codex rollout <code>.jsonl</code> file.</p>

<h2 id="after">What you get</h2>
<ul>
  <li><strong>A thread that resumes the same session.</strong> The imported thread keeps the provider’s session ID, so your next message resumes the CLI’s own session natively. ${s.link("/features/switch-agents", "Switching to another agent")} works as in any thread: the next agent gets a recap.</li>
  <li><strong>Nothing runs on import.</strong> Importing never starts an agent, and imported threads begin in Ask for approval mode, so the first turn can’t change files without you. Switch the thread to Full access if you want.</li>
  <li><strong>A readable transcript.</strong> For Claude Code it follows the latest main branch of the conversation; for Codex it applies the rollback events, so turns you undid in the CLI stay undone.</li>
</ul>

<h2 id="source">The original file</h2>
<p>Coincide never changes the CLI’s file. It keeps an exact private copy in its own data folder; <strong>File › Reveal Imported Source</strong> shows that copy in Finder. Anything the transcript can’t show stays in that copy: unsupported records, attachments, excluded branches of the conversation and text beyond the limits below. Deleting the imported thread also deletes its copy, and Undo restores both.</p>

<h2 id="limits">Limits</h2>
${table(["Limit", "Value"], [
  ["File size", "32 MB per file"],
  ["Record size", "4 MB per record"],
  ["Records", "100,000 per file"],
  ["Text shown per transcript field", "100,000 characters"],
  ["Preview", "200,000 characters"],
  ["Sessions listed", "2,000, newest first"],
])}
<p>A session over the file limits shows “This session exceeds the import limits (32 MB per file, 4 MB per record, or 100,000 records).” When some histories can’t be listed, the window says so and suggests <strong>Choose File…</strong>.</p>

<h2 id="notes">Good to know</h2>
<ul>
  <li>Only Claude Code and Codex sessions can be imported. The other agents’ histories aren’t read.</li>
  <li>Claude Code’s subagent histories aren’t scanned automatically.</li>
  <li>Each session needs one valid session ID and an absolute working directory; Coincide refuses files without them.</li>
  <li>If the CLI writes to the file after you previewed it, Coincide asks you to select it again: “The session changed after the preview. Select it again to refresh before importing.”</li>
</ul>
`,
};
