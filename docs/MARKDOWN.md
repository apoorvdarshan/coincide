# Message Markdown

Coincide renders assistant replies, plans and pull request bodies with
`CoincideMarkdown`: swift-markdown/cmark parsing off the main actor, a bounded
document cache, and native SwiftUI blocks. Nothing in a message is executed or
loaded. There is no web view for Markdown, HTML or diagrams.

## What renders

- **GFM text.** Tables, task lists, strikethrough and literal punctuation:
  `--force`, straight quotes and `...` stay exactly as written. Bare
  `https://`, `http://`, `www.` and email addresses become links. Trailing
  punctuation and an unbalanced `)` stay outside the link.
- **Footnotes.** `[^label]` references render as superscript numbers that open
  the note in a popover. Definitions, including indented continuation
  paragraphs, are listed after the message in first-reference order. Unknown
  labels stay literal.
- **GitHub alerts.** A quote whose first line is only `[!NOTE]`, `[!TIP]`,
  `[!IMPORTANT]`, `[!WARNING]` or `[!CAUTION]` (any case) becomes a titled,
  colored alert. If the marker shares its line with other text, the quote stays
  ordinary. With Increase Contrast, alerts are also outlined.
- **Safe HTML.** `<details>`/`<summary>` (closed unless `open`), `<br>`, `<kbd>`,
  `<sub>`, `<sup>`, `<b>`/`<strong>`, `<i>`/`<em>`, `<s>`/`<del>`, `<code>`,
  `<a href>`, `<img alt>`, headings, `<pre>`, `<hr>` and transparent containers
  such as `<p>`, `<div>` and `<center>`. Comments are hidden. A block with any
  other element, such as `<script>`, `<style>`, `<iframe>` or a form, is shown as
  its source text. Attributes other than `href`, `src`, `alt` and `open` are
  ignored. Links still pass through the workspace-contained link rules. User text
  keeps all HTML literal (`MarkdownView(…, rawHTML: false)`).
- **Math.** `$…$`, `$$…$$`, `\(…\)` and `\[…\]` outside code, closed `math`
  fences and whole-line `$$`/`\[` blocks typeset natively with SwiftMath. This
  works in tables (including `|x|`), lists and quotes. `$5 and $10` stays text,
  `\$` is a literal dollar, and a dollar touching a letter or digit outside the
  formula (`$PATH:$HOME`, `US$5`) is not math. Unsupported TeX falls back to
  source.
- **Code blocks.** Fences show a title from `title=`, `file=`, `filename=` or a
  bare `name.ext` token, plus a language badge. Each block has a wrap toggle and
  Copy. About 45 languages and their common aliases are colored with
  appearance-aware token colors: C-family, Swift, Python, JavaScript/TypeScript
  and JSX/TSX, shell and PowerShell, SQL, Go, Rust, Ruby, PHP, Kotlin, Java,
  Scala, C#, Dart, Elixir, Haskell, Lua, R, Zig, GraphQL, HTML/XML/Vue/Svelte,
  CSS/SCSS, JSON, YAML, TOML/INI/gitignore, Dockerfile, Makefile, Markdown and
  diff. Inputs over 64 KB or 4,000 lines stay uncolored.
- **Run in terminal.** When the host passes `runShell`, a closed `sh`, `bash`,
  `zsh`, `fish`, `shell`, `powershell` or `pwsh` fence holding one command line
  shows **Run in terminal**. The command must not end with a backslash or contain
  control or invisible formatting characters, and the message must not still be
  streaming. Rendering never runs anything; only a click sends the exact trimmed
  command to the host.
- **Tables.** Long cells wrap at 384 points or truncate when collapsed; tables
  with long cells show an expand/collapse toggle. **Copy table** offers
  Markdown (pipes escaped, alignment row kept) and CSV (RFC 4180 quoting).
  Formulas and footnote references keep their source.
- **Codex directives.** `:codex-file-citation{path line_range_start}` becomes a
  file link to that line. `:codex-followup[Label]{prompt}` shows its label, and
  `::artifact-template{…}` shows a template card. Malformed directives, and
  directives in code or inside a link label, stay literal.
  `CodexDirectives.renderForCopy` gives T3's copy text.
- **Mermaid.** A closed `mermaid` fence draws natively for simple `graph` and
  `flowchart` diagrams (all directions, common node shapes, labeled, dotted
  and thick links, `&` groups, chains) and for `sequenceDiagram` (participants,
  actors, message arrows, notes, `autonumber`, and `loop`/`alt`/`opt`/`par`
  frames). The block can switch to the source and copy it. `click`, styles and
  `classDef` are ignored; subgraphs are drawn without their frame. Other diagram
  types, unsupported syntax and fences that are still streaming show the source.

## Settings

**Settings → General** has two per-device preferences, stored in user defaults:

- **Word wrap** (`wordWrap`, on by default): wraps code blocks and table cells.
  Each block's own toggle overrides it.
- **Render math** (`renderMath`, on by default): off shows formulas as written.
  T3 Code defaults this off. Coincide keeps it on because closed display
  formulas already rendered before inline math was added.

## Limitations

- Mermaid uses a native layered layout, not mermaid.js. Class, state, ER, Gantt,
  pie and other diagram types show as source. Large diagrams (over 20,000
  characters, 150 nodes, 300 links or 300 sequence events) also stay source.
- Highlighting is lexical (no grammar or semantic analysis). Embedded languages
  are recognized only for `<script>` and `<style>` in HTML-like fences.
- Footnote definitions must start a block at the top level; definitions inside
  lists or quotes are not collected.
- A table row is recognized for `\|` unescaping inside formulas only when the
  row starts with `|`.
- Artifact template cards do not offer **Use template** yet, and follow-up
  suggestions are shown as text, not as buttons.
