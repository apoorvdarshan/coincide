export default {
  path: "/compare",
  title: "How Coincide compares to other coding agent apps",
  description: "Fair, dated comparisons of Coincide with running agent CLIs in Terminal, the Claude and Codex apps, Cursor, Conductor and T3 Code, with sources.",
  name: "Compare",
  summary: "Coincide next to the other ways to run coding agents.",
  type: "CollectionPage",
  eyebrow: "Compare",
  h1: "Coincide compared",
  lede: "Coincide is one of several ways to work with coding agents. These pages set it next to the others using facts from each product’s own site, with the date they were checked and a section on when the other choice fits better.",
  wide: true,
  related: ["/features", "/agents", "/faq"],
  body: (s) => `
${s.cards(["/compare/terminal", "/compare/claude-desktop", "/compare/codex-app", "/compare/cursor", "/compare/conductor", "/compare/t3-code"])}
<h2>How these comparisons are written</h2>
<p>Every statement about another product links to that product’s own website, documentation or repository, and each page says when it was last checked. Products change quickly, so check their sites for the current details. If you find something out of date or wrong, please <a href="https://github.com/apoorvdarshan/coincide/issues/new?template=bug_report.yml">open an issue</a> and it will be corrected.</p>
<p>Product names and logos belong to their owners. Coincide isn’t affiliated with or endorsed by any of them.</p>`,
};
