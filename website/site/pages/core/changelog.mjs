// /changelog, rendered from the repository's CHANGELOG.md (the source of each GitHub release's notes). Rebuild the site
// after adding a release's section there. Only the Markdown CHANGELOG.md uses is supported: paragraphs, "- " lists,
// ## headings, **bold**, `code` and [links](…).
import { readFileSync } from "node:fs";
import { fileURLToPath } from "node:url";
import { escape, REPO } from "../../layout.mjs";

const source = readFileSync(fileURLToPath(new URL("../../../../CHANGELOG.md", import.meta.url)), "utf8");

function inline(text) {
  return escape(text)
    .replace(/`([^`]+)`/g, "<code>$1</code>")
    .replace(/\*\*([^*]+)\*\*/g, "<strong>$1</strong>")
    .replace(/\[([^\]]+)\]\(([^)]+)\)/g, (_, label, href) => {
      const target = /^https?:/.test(href) ? href : `${REPO}/blob/main/${href.replace(/^\.\//, "")}`;
      return `<a href="${target}">${label}</a>`;
    });
}

/** Splits CHANGELOG.md into its intro and one { version, html } per "## version" section. */
export function parseChangelog(markdown) {
  const [intro, ...sections] = markdown.replace(/^# .*\n/, "").split(/^## /m);
  const blocks = (text) => {
    const out = [];
    for (const block of text.trim().split(/\n\s*\n/)) {
      const lines = block.split("\n");
      if (lines.every((l) => /^- /.test(l) || /^ {2,}\S/.test(l))) {
        const items = [];
        for (const l of lines) /^- /.test(l) ? items.push(l.slice(2)) : (items[items.length - 1] += " " + l.trim());
        out.push(`<ul>${items.map((i) => `<li>${inline(i)}</li>`).join("")}</ul>`);
      } else if (block.trim()) {
        out.push(`<p>${inline(lines.join(" "))}</p>`);
      }
    }
    return out.join("\n");
  };
  return {
    intro: blocks(intro),
    releases: sections.map((section) => {
      const [heading, ...rest] = section.split("\n");
      return { version: heading.trim(), html: blocks(rest.join("\n")) };
    }),
  };
}

const { releases } = parseChangelog(source);
const anchor = (version) => "v" + version.replace(/[^0-9a-z]+/gi, "-");

export default {
  path: "/changelog",
  title: "Coincide changelog: what’s new in each release",
  description: `Release notes for Coincide, the native Mac app for coding agents, from the first public release, ${releases.at(-1)?.version ?? "0.1.0"}, to the latest.`,
  name: "Changelog",
  summary: "What changed in each release.",
  eyebrow: "Changelog",
  h1: "What’s new in Coincide",
  lede: `The latest release is <strong>${releases[0]?.version}</strong>. Each release’s notes are also on its <a href="${REPO}/releases">GitHub release</a>, and Coincide › Check for Updates installs newer ones.`,
  related: ["/download", "/docs/updating", "/features"],
  body: () => releases.map(({ version, html }) => `
<h2 id="${anchor(version)}">Coincide ${escape(version)}</h2>
<p class="note"><a href="${REPO}/releases/tag/v${encodeURIComponent(version)}">Release v${escape(version)} on GitHub</a></p>
${html}`).join("\n") + `
<p class="note">These notes come from <a href="${REPO}/blob/main/CHANGELOG.md">CHANGELOG.md</a> in the repository.</p>`,
};
