// Shared markup for coincide.dev: the <head>, header, breadcrumbs, footer and structured data every page uses.
// build.mjs renders each page in pages/ through render() and injects header() and footer() into the hand-written
// pages (the home page, privacy and terms) between their <!-- site-header --> / <!-- site-footer --> markers.

import { readFileSync } from "node:fs";

export const ORIGIN = "https://coincide.dev";
// The latest release: the first numbered section of the repository's CHANGELOG.md.
export const VERSION = readFileSync(new URL("../../CHANGELOG.md", import.meta.url), "utf8").match(/^## (\d+\.\d+\.\d+)\s*$/m)[1];
export const DMG = "https://github.com/apoorvdarshan/coincide/releases/latest/download/Coincide.dmg";
export const REPO = "https://github.com/apoorvdarshan/coincide";
export const LINKS = {
  github: REPO,
  discord: "https://discord.gg/DETrbhDVqw",
  productHunt: "https://www.producthunt.com/products/coincide",
  x: "https://x.com/apoorvdarshan",
  instagram: "https://instagram.com/apoorvcodes",
  linkedin: "https://www.linkedin.com/showcase/coincide-dev",
  email: "mailto:apoorv@fud-ai.app",
};
const FONTS = "https://fonts.googleapis.com/css2?family=Bricolage+Grotesque:opsz,wght@12..96,300..800&family=JetBrains+Mono:wght@400;500&display=swap";

export const escape = (text) => String(text).replace(/[&<>"]/g, (c) => ({ "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;" })[c]);
export const url = (path) => ORIGIN + (path === "/" ? "/" : path);

// The people and things every page's structured data refers to by @id.
export const PERSON = {
  "@type": "Person",
  "@id": `${ORIGIN}/#apoorv`,
  name: "Apoorv Darshan",
  url: "https://github.com/apoorvdarshan",
  sameAs: ["https://github.com/apoorvdarshan", LINKS.x, LINKS.instagram],
};
export const ORGANIZATION = {
  "@type": "Organization",
  "@id": `${ORIGIN}/#organization`,
  name: "Coincide",
  url: `${ORIGIN}/`,
  logo: { "@type": "ImageObject", url: `${ORIGIN}/img/icon-512.png`, width: 512, height: 512 },
  email: "apoorv@fud-ai.app",
  founder: { "@id": PERSON["@id"] },
  sameAs: [REPO, LINKS.x, LINKS.linkedin, LINKS.productHunt],
};
export const WEBSITE = {
  "@type": "WebSite",
  "@id": `${ORIGIN}/#website`,
  url: `${ORIGIN}/`,
  name: "Coincide",
  inLanguage: "en",
  publisher: { "@id": ORGANIZATION["@id"] },
};
export const APP_LANGUAGES = ["en", "de", "es", "es-419", "fr", "hi", "id", "it", "ja", "ko", "nl", "pl", "pt-BR", "ru", "tr", "uk", "vi", "zh-Hans", "zh-Hant"];
export const SOFTWARE = {
  "@type": "SoftwareApplication",
  "@id": `${ORIGIN}/#app`,
  name: "Coincide",
  description: "A native macOS app that runs the coding agents you already use (Claude Code, Codex, Cursor, Grok Build, OpenCode and Antigravity) in one window, and lets you switch agents in the middle of a thread.",
  url: `${ORIGIN}/`,
  image: `${ORIGIN}/img/og.jpg`,
  applicationCategory: "DeveloperApplication",
  operatingSystem: "macOS 26 or later",
  processorRequirements: "Apple silicon or Intel (universal app)",
  softwareVersion: VERSION,
  downloadUrl: DMG,
  installUrl: `${ORIGIN}/download`,
  releaseNotes: `${ORIGIN}/changelog`,
  license: "https://opensource.org/license/mit",
  isAccessibleForFree: true,
  inLanguage: APP_LANGUAGES,
  offers: { "@type": "Offer", price: "0", priceCurrency: "USD" },
  author: { "@id": PERSON["@id"] },
  publisher: { "@id": PERSON["@id"] },
  sameAs: [REPO],
};

const NAV = [
  ["Features", "/features"],
  ["Agents", "/agents"],
  ["Docs", "/docs"],
  ["Download", "/download"],
  ["FAQ", "/faq"],
  ["GitHub", REPO],
];

/** The site header. `section` is the first path segment of the current page, to mark its nav item. `ui` holds
 *  translated labels for the localized home pages: { nav: [six labels], get, navLabel, home }. */
export function header(section = "", ui = {}) {
  const items = NAV.map(([label, href], i) => {
    const current = href === `/${section}` ? ' aria-current="true"' : "";
    return `<a href="${href}"${current}>${ui.nav?.[i] ?? label}</a>`;
  }).join("");
  return `<header class="site-bar">
  <div class="site-top">
    <a class="site-brand" href="${ui.home ?? "/"}"><img src="/img/icon-tight-96.png" alt="" width="30" height="30">Coincide</a>
    <nav class="site-nav" aria-label="${ui.navLabel ?? "Main"}">${items}</nav>
    <a class="site-get" href="${ui.getHref ?? "/download"}">${ui.get ?? "Get Coincide"}</a>
  </div>
</header>`;
}

/** The site footer: every hub and the pages people look for most, plus the localized home pages. */
export function footer(languages = [], ui = {}) {
  const list = (title, links) => `<div><p class="h">${title}</p><ul>${links.map(([label, href]) => `<li><a href="${href}">${label}</a></li>`).join("")}</ul></div>`;
  const langs = languages.length
    ? `<span class="langs">${languages.map(({ path, native, lang }) => `<a href="${path}" hreflang="${lang}" lang="${lang}">${native}</a>`).join(" · ")}</span>`
    : "";
  return `<footer class="site-foot">
  <div class="cols">
    <div class="about"><a class="site-brand" href="/"><img src="/img/icon-tight-96.png" alt="" width="30" height="30" loading="lazy">Coincide</a><p>${ui.about ?? "A native Mac app for the coding agents you already use. Free and open source under the MIT license."}</p></div>
    ${list("Product", [["Features", "/features"], ["Download", "/download"], ["Changelog", "/changelog"], ["Blog", "/blog"], ["Compare", "/compare"], ["Coincide Remote", "/features/coincide-remote"], ["FAQ", "/faq"]])}
    ${list("Agents", [["Claude Code", "/agents/claude-code"], ["Codex", "/agents/codex"], ["Cursor", "/agents/cursor"], ["Grok Build", "/agents/grok-build"], ["OpenCode", "/agents/opencode"], ["Antigravity", "/agents/antigravity"]])}
    ${list("Docs", [["All docs", "/docs"], ["Getting started", "/docs/getting-started"], ["Keyboard shortcuts", "/docs/keyboard-shortcuts"], ["Command line", "/docs/cli"], ["Troubleshooting", "/docs/troubleshooting"], ["Uninstall", "/docs/uninstall"]])}
    ${list("Community", [["GitHub", REPO], ["Discord", LINKS.discord], ["Product Hunt", LINKS.productHunt], ["X @apoorvdarshan", LINKS.x], ["Instagram @apoorvcodes", LINKS.instagram], ["LinkedIn", LINKS.linkedin]])}
  </div>
  <div class="base"><span>© 2026 Apoorv Darshan · <a href="/privacy">Privacy</a> · <a href="/terms">Terms</a> · <a href="${LINKS.email}">apoorv@fud-ai.app</a></span>${langs}</div>
</footer>`;
}

export function breadcrumbs(trail) {
  const items = trail.map(([name, path], i) => i === trail.length - 1
    ? `<li><span aria-current="page">${escape(name)}</span></li>`
    : `<li><a href="${path}">${escape(name)}</a></li>`).join("");
  return `<nav aria-label="Breadcrumb"><ol class="crumbs">${items}</ol></nav>`;
}

export function breadcrumbSchema(trail) {
  return {
    "@type": "BreadcrumbList",
    itemListElement: trail.map(([name, path], i) => ({ "@type": "ListItem", position: i + 1, name, item: url(path) })),
  };
}

export const jsonLD = (graph) => `<script type="application/ld+json">${JSON.stringify({ "@context": "https://schema.org", "@graph": graph }).replace(/</g, "\\u003c")}</script>`;

/** <head> contents shared by every page. */
export function head({ title, description, path, lang = "en", ogLocale, ogType = "website", image, imageAlt, alternates = [], noindex = false, feed = false, schema = [] }) {
  const canonical = url(path);
  const img = image ?? { url: `${ORIGIN}/img/og.jpg`, width: 1200, height: 630, alt: "Coincide: Every agent. One moment. The two-faced Janus logo with the Coincide bots climbing it." };
  const hreflang = alternates.map(({ lang: l, path: p }) => `<link rel="alternate" hreflang="${l}" href="${url(p)}">`).join("\n");
  const locale = ogLocale ?? ({ en: "en_US" }[lang] ?? lang.replace("-", "_"));
  return `<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1, viewport-fit=cover">
<title>${escape(title)}</title>
<meta name="description" content="${escape(description)}">
${noindex ? '<meta name="robots" content="noindex">\n' : ""}<meta name="theme-color" content="#0A0D24">
${noindex ? "" : `<link rel="canonical" href="${canonical}">\n`}${hreflang ? hreflang + "\n" : ""}${feed ? '<link rel="alternate" type="application/rss+xml" title="Coincide blog" href="/blog/feed.xml">\n' : ""}<meta property="og:type" content="${ogType}">
<meta property="og:site_name" content="Coincide">
<meta property="og:locale" content="${locale}">
<meta property="og:url" content="${canonical}">
<meta property="og:title" content="${escape(title)}">
<meta property="og:description" content="${escape(description)}">
<meta property="og:image" content="${img.url}">
<meta property="og:image:width" content="${img.width}">
<meta property="og:image:height" content="${img.height}">
<meta property="og:image:alt" content="${escape(imageAlt ?? img.alt)}">
<meta name="twitter:card" content="summary_large_image">
<meta name="twitter:site" content="@apoorvdarshan">
<meta name="twitter:creator" content="@apoorvdarshan">
<meta name="twitter:title" content="${escape(title)}">
<meta name="twitter:description" content="${escape(description)}">
<meta name="twitter:image" content="${img.url}">
<link rel="icon" href="/img/icon-tight-96.png" type="image/png">
<link rel="apple-touch-icon" href="/img/icon-288.png">
<link rel="preconnect" href="https://fonts.googleapis.com">
<link rel="preconnect" href="https://fonts.gstatic.com" crossorigin>
<link href="${FONTS}" rel="stylesheet">
<link rel="stylesheet" href="/css/site.css">
${schema.length ? jsonLD(schema) : ""}`;
}

const COPY_SCRIPT = `<script>
  // Copy buttons for commands: shown only when there's a clipboard to copy to.
  document.querySelectorAll('.cmd .copy').forEach(button => {
    if (!navigator.clipboard) return;
    button.hidden = false;
    button.addEventListener('click', () => navigator.clipboard.writeText(button.dataset.copy).then(() => {
      button.classList.add('done');
      setTimeout(() => button.classList.remove('done'), 1400);
    }).catch(() => {}));
  });
</script>`;

/** A full page. `page` is a normalized page from build.mjs; `site` resolves links between pages. */
export function render(page, site) {
  const section = page.path.split("/")[1] ?? "";
  const trail = site.trail(page);
  const schema = [...page.schemaNodes(site, trail)];
  const titleRow = page.logo
    ? `<div class="title-row"><span class="mark${page.logo.app ? " app" : ""}"><img src="${page.logo.src}" alt="${escape(page.logo.alt ?? "")}" width="${page.logo.size ?? 38}" height="${page.logo.size ?? 38}"></span><h1>${page.h1}</h1></div>`
    : `<h1>${page.h1}</h1>`;
  const updated = page.post
    ? `<p class="updated"><time datetime="${page.published}">${formatDate(page.published)}</time> · Apoorv Darshan${page.updated > page.published.slice(0, 10) ? ` · Updated <time datetime="${page.updated}">${formatDate(page.updated)}</time>` : ""}</p>`
    : page.showUpdated
    ? `<p class="updated">Updated <time datetime="${page.updated}">${formatDate(page.updated)}</time></p>`
    : "";
  const related = page.related.length
    ? `<section class="related" aria-labelledby="related"><h2 id="related">Related</h2>${site.cards(page.related)}</section>`
    : "";
  const body = page.renderBody(site);
  return `<!doctype html>
<html lang="${page.lang}">
<head>
${head({ ...page, ogType: page.ogType, schema })}
</head>
<body>
<a class="skip" href="#content">${page.ui?.skip ?? "Skip to content"}</a>
${header(section, page.ui)}

<main class="page${page.wide ? " wide" : ""}" id="content">
  ${trail.length > 1 ? breadcrumbs(trail) : ""}
  <header class="page-head">
    ${page.eyebrow ? `<p class="eyebrow">${page.eyebrow}</p>` : ""}
    ${titleRow}
    ${page.lede ? `<p class="lede">${page.lede}</p>` : ""}
    ${updated}
  </header>
  <div class="prose${page.bodyClass ? " " + page.bodyClass : ""}">
${body}
  </div>
  ${related}
</main>

${footer(site.languages, page.ui)}
${body.includes('class="copy"') ? COPY_SCRIPT : ""}
</body>
</html>
`;
}

/** "November 2, 2026" from an ISO date, or from the date part of an ISO date and time. */
export function formatDate(iso) {
  return new Date(iso.slice(0, 10) + "T00:00:00Z").toLocaleDateString("en-US", { year: "numeric", month: "long", day: "numeric", timeZone: "UTC" });
}

// ---------- helpers for page bodies ----------

const COPY_ICON = '<svg viewBox="0 0 20 20" aria-hidden="true"><rect x="7" y="7" width="9" height="9" rx="2"/><path d="M4.5 13V6.2c0-1 .8-1.7 1.7-1.7H13"/></svg>';
/** A one-line shell command with a copy button (the button appears only with JavaScript and a clipboard). */
export const cmd = (command, label = "Copy the command") =>
  `<div class="cmd"><code>${escape(command)}</code><button class="copy" type="button" hidden data-copy="${escape(command)}" aria-label="${escape(label)}">${COPY_ICON}</button></div>`;

/** A code block. */
export const code = (text) => `<pre><code>${escape(text.replace(/^\n/, "").replace(/\n\s*$/, ""))}</code></pre>`;

/** A table: `head` is a list of header cells, `rows` a list of rows of HTML cells. */
export const table = (headCells, rows) =>
  `<div class="table-wrap"><table><thead><tr>${headCells.map((h) => `<th scope="col">${h}</th>`).join("")}</tr></thead><tbody>${rows.map((r) => `<tr>${r.map((c) => `<td>${c}</td>`).join("")}</tr>`).join("")}</tbody></table></div>`;

/** Keyboard keys: kbd("⌘", "K") → ⌘K as separate keys. */
export const kbd = (...keys) => keys.map((k) => `<kbd>${escape(k)}</kbd>`).join("");

export const DOWNLOAD_BUTTONS = `<div class="actions"><a class="btn main" href="${DMG}"><svg viewBox="0 0 24 24" fill="currentColor" aria-hidden="true"><path d="M16.4 12.6c0-2.4 2-3.6 2.1-3.7-1.1-1.7-2.9-1.9-3.5-1.9-1.5-.2-2.9.9-3.7.9-.8 0-1.9-.9-3.2-.8-1.6 0-3.1 1-4 2.4-1.7 3-.4 7.4 1.2 9.8.8 1.2 1.8 2.5 3 2.4 1.2 0 1.7-.8 3.1-.8 1.5 0 1.9.8 3.2.8 1.3 0 2.1-1.2 2.9-2.4.9-1.3 1.3-2.6 1.3-2.7 0 0-2.4-1-2.4-4zM14 5.4c.7-.8 1.1-1.9 1-3-1 0-2.1.7-2.8 1.5-.6.7-1.2 1.8-1 2.9 1 .1 2.1-.6 2.8-1.4z"/></svg>Download for Mac</a><a class="btn alt" href="/download">All install options</a></div>`;
