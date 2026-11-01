#!/usr/bin/env node
// Builds coincide.dev's content pages into website/public/ from the page modules in website/site/pages/, along with
// sitemap.xml, robots.txt and the shared header and footer of the hand-written pages (home, privacy, terms).
//
//   node website/site/build.mjs           write the files
//   node website/site/build.mjs --check   fail if any file is out of date (CI runs this through site.test.mjs)
//   node website/site/build.mjs --dry     build in memory only and report problems, writing nothing
//
// No dependencies: plain Node 20 or later.
import { readFile, readdir, writeFile, mkdir } from "node:fs/promises";
import { dirname, join, relative } from "node:path";
import { fileURLToPath, pathToFileURL } from "node:url";
import {
  ORIGIN, ORGANIZATION, PERSON, SOFTWARE, WEBSITE, breadcrumbSchema, escape, footer, header, jsonLD, render, url,
} from "./layout.mjs";

const here = dirname(fileURLToPath(import.meta.url));
export const PUBLIC = join(here, "..", "public");
const PAGES = join(here, "pages");

// Pages written by hand, with the date their content last changed (for the sitemap). The build only refreshes their
// shared header, footer and language links.
export const HANDWRITTEN = [
  { file: "index.html", path: "/", updated: "2026-11-01", lang: "en", group: "home", name: "Home",
    title: "Coincide: every coding agent in one native Mac app" },
  { file: "privacy/index.html", path: "/privacy", updated: "2026-11-01", lang: "en", name: "Privacy Policy",
    title: "Privacy Policy · Coincide", summary: "What stays on your Mac, what your agents send to their providers, and every other connection." },
  { file: "terms/index.html", path: "/terms", updated: "2026-11-01", lang: "en", name: "Terms of Service",
    title: "Terms of Service · Coincide", summary: "The MIT-licensed software, your agent accounts, community rules and the limits of responsibility." },
];

/** Structured data for a hand-written page. */
function handwrittenSchema(hand) {
  const pageURL = url(hand.path);
  const webPage = {
    "@type": "WebPage", "@id": `${pageURL}#page`, url: pageURL, name: hand.title, inLanguage: hand.lang,
    isPartOf: { "@id": WEBSITE["@id"] }, about: { "@id": SOFTWARE["@id"] }, dateModified: hand.updated,
  };
  if (hand.path === "/") return [webPage, WEBSITE, ORGANIZATION, PERSON, SOFTWARE];
  const trail = [["Home", "/"], [hand.name, hand.path]];
  webPage.breadcrumb = { "@id": `${pageURL}#breadcrumb` };
  return [webPage, WEBSITE, ORGANIZATION, { ...breadcrumbSchema(trail), "@id": `${pageURL}#breadcrumb` }];
}

export const LIMITS = { title: 60, description: 155 };

async function moduleFiles(dir) {
  const out = [];
  for (const entry of await readdir(dir, { withFileTypes: true })) {
    const full = join(dir, entry.name);
    if (entry.isDirectory()) out.push(...await moduleFiles(full));
    else if (entry.name.endsWith(".mjs") && !entry.name.startsWith("_")) out.push(full);
  }
  return out.sort();
}

const stripTags = (html) => html.replace(/<[^>]+>/g, "").replace(/&amp;/g, "&").replace(/&nbsp;/g, " ").replace(/\s+/g, " ").trim();

function normalize(raw, source) {
  const fail = (message) => { throw new Error(`${relative(here, source)} (${raw.path}): ${message}`); };
  for (const key of ["path", "title", "description", "name"]) if (!raw[key]) fail(`missing ${key}`);
  if (!/^\/[a-z0-9/-]*$/.test(raw.path) || (raw.path !== "/" && raw.path.endsWith("/"))) fail("path must be lowercase, start with / and not end with /");
  const page = {
    lang: "en",
    type: "WebPage",
    updated: "2026-11-01",
    published: "2026-11-01",
    related: [],
    h1: escape(raw.name),
    summary: "",
    ...raw,
    source,
  };
  page.showUpdated ??= ["TechArticle", "Article"].includes(page.type);
  page.ogType = ["TechArticle", "Article"].includes(page.type) ? "article" : "website";
  page.renderBody = (site) => typeof page.body === "function" ? page.body(site) : (page.body ?? "");
  page.schemaNodes = (site, trail) => schemaFor(page, site, trail);
  return page;
}

function schemaFor(page, site, trail) {
  const pageURL = url(page.path);
  const nodes = [];
  const base = {
    "@id": `${pageURL}#page`,
    url: pageURL,
    name: page.title,
    description: page.description,
    inLanguage: page.lang,
    isPartOf: { "@id": WEBSITE["@id"] },
  };
  if (trail.length > 1) base.breadcrumb = { "@id": `${pageURL}#breadcrumb` };
  if (page.type === "TechArticle" || page.type === "Article") {
    nodes.push({
      "@type": page.type,
      ...base,
      headline: stripTags(page.h1).slice(0, 110),
      datePublished: page.published,
      dateModified: page.updated,
      author: { "@id": PERSON["@id"] },
      publisher: { "@id": ORGANIZATION["@id"] },
      image: `${ORIGIN}/img/og.jpg`,
      mainEntityOfPage: pageURL,
      about: { "@id": SOFTWARE["@id"] },
    });
    nodes.push(PERSON, ORGANIZATION, WEBSITE);
  } else if (page.type === "FAQPage") {
    nodes.push({
      "@type": "FAQPage",
      ...base,
      mainEntity: page.faq.map(({ q, a }) => ({
        "@type": "Question",
        name: stripTags(q),
        acceptedAnswer: { "@type": "Answer", text: a },
      })),
    });
    nodes.push(WEBSITE, ORGANIZATION);
  } else {
    nodes.push({ "@type": page.type, ...base, about: { "@id": SOFTWARE["@id"] } });
    nodes.push(WEBSITE, ORGANIZATION);
  }
  if (trail.length > 1) nodes.push({ ...breadcrumbSchema(trail), "@id": `${pageURL}#breadcrumb` });
  for (const extra of page.schema ?? []) nodes.push(extra === "software" ? { ...SOFTWARE } : extra);
  if ((page.schema ?? []).includes("software") && !nodes.includes(PERSON)) nodes.push(PERSON);
  return nodes;
}

export async function loadPages() {
  const pages = [];
  for (const file of await moduleFiles(PAGES)) {
    const exported = (await import(pathToFileURL(file).href)).default;
    for (const raw of [exported].flat()) pages.push(normalize(raw, file));
  }
  return pages;
}

function makeSite(pages) {
  const byPath = new Map();
  for (const page of pages) {
    if (byPath.has(page.path)) throw new Error(`two pages for ${page.path}`);
    byPath.set(page.path, page);
  }
  const named = new Map([
    ...HANDWRITTEN.map((h) => [h.path, { name: h.name, path: h.path, summary: h.summary ?? "" }]),
    ...[...byPath].map(([p, page]) => [p, page]),
  ]);
  // Links to pages that don't exist are collected and fail the build (warnings with --dry).
  const missing = new Set();
  const get = (path) => {
    const page = named.get(path);
    if (!page) { missing.add(path); return { name: path, path, summary: "" }; }
    return page;
  };
  const languages = pages.filter((p) => p.group === "home").map((p) => ({ path: p.path, native: p.nativeName, lang: p.lang }));
  if (languages.length) languages.unshift({ path: "/", native: "English", lang: "en" });
  const site = {
    pages,
    missing,
    languages,
    page: get,
    link: (path, text) => {
      const [p, hash] = path.split("#");
      return `<a href="${path}">${text ?? escape(get(p).name)}</a>`;
    },
    cards: (paths) => `<ul class="cards">${paths.map((path) => {
      const page = get(path);
      const icon = page.icon ? `<i><img src="${page.icon}" alt="" width="21" height="21" loading="lazy"></i>` : "";
      return `<li><a class="card" href="${path}"><b>${icon}${escape(page.name)}</b>${page.summary ? `<span>${page.summary}</span>` : ""}</a></li>`;
    }).join("")}</ul>`,
    trail: (page) => {
      if (page.path === "/" || page.group === "home" || page.path === "/404") return [];
      const parts = page.path.split("/").slice(1);
      const trail = [["Home", "/"]];
      for (let i = 1; i < parts.length; i++) {
        const parent = "/" + parts.slice(0, i).join("/");
        trail.push([get(parent).name, parent]);
      }
      trail.push([page.name, page.path]);
      return trail;
    },
  };
  return site;
}

function alternatesFor(pages, page) {
  if (!page.group) return [];
  const members = [...HANDWRITTEN.filter((h) => h.group === page.group), ...pages.filter((p) => p.group === page.group)];
  const out = members.map((m) => ({ lang: m.lang, path: m.path }));
  const english = members.find((m) => m.lang === "en");
  if (english) out.push({ lang: "x-default", path: english.path });
  return out;
}

function sitemap(pages) {
  const entries = [
    ...HANDWRITTEN.map((h) => ({ path: h.path, updated: h.updated, group: h.group, lang: h.lang })),
    ...pages.filter((p) => !p.noindex),
  ].sort((a, b) => (a.path === "/" ? -1 : b.path === "/" ? 1 : a.path.localeCompare(b.path)));
  const rows = entries.map((entry) => {
    const links = alternatesFor(pages, entry).map((a) => `\n    <xhtml:link rel="alternate" hreflang="${a.lang}" href="${url(a.path)}"/>`).join("");
    return `  <url>\n    <loc>${url(entry.path)}</loc>\n    <lastmod>${entry.updated}</lastmod>${links}\n  </url>`;
  });
  return `<?xml version="1.0" encoding="UTF-8"?>
<urlset xmlns="http://www.sitemaps.org/schemas/sitemap/0.9" xmlns:xhtml="http://www.w3.org/1999/xhtml">
${rows.join("\n")}
</urlset>
`;
}

const ROBOTS = `# coincide.dev: everything is open to crawlers except the Worker's small JSON API.
User-agent: *
Allow: /
Disallow: /api/

Sitemap: ${ORIGIN}/sitemap.xml
`;

function replaceBetween(text, name, content, file) {
  const start = `<!-- site-${name} -->`, end = `<!-- /site-${name} -->`;
  const a = text.indexOf(start), b = text.indexOf(end);
  if (a < 0 || b < a) {
    if (name === "alternates") return text;
    throw new Error(`${file}: missing ${start} … ${end}`);
  }
  return text.slice(0, a + start.length) + "\n" + content + "\n" + text.slice(b);
}

/** Every file the build writes, as a Map of path relative to public/ → contents. */
export async function buildSite() {
  const pages = await loadPages();
  const site = makeSite(pages);
  const out = new Map();
  for (const page of pages) {
    page.alternates = alternatesFor(pages, page);
    const file = page.path === "/404" ? "404.html" : `${page.path.slice(1)}/index.html`;
    out.set(file, render(page, site));
  }
  for (const hand of HANDWRITTEN) {
    let text = await readFile(join(PUBLIC, hand.file), "utf8");
    const section = hand.path.split("/")[1];
    if (hand.file !== "index.html") text = replaceBetween(text, "header", header(section), hand.file);
    text = replaceBetween(text, "footer", footer(site.languages), hand.file);
    const alternates = alternatesFor(pages, hand).map((a) => `<link rel="alternate" hreflang="${a.lang}" href="${url(a.path)}">`).join("\n");
    text = replaceBetween(text, "alternates", alternates, hand.file);
    text = replaceBetween(text, "schema", jsonLD(handwrittenSchema(hand)), hand.file);
    out.set(hand.file, text);
  }
  out.set("sitemap.xml", sitemap(pages));
  out.set("robots.txt", ROBOTS);
  const problems = validate(pages);
  for (const path of site.missing) problems.push(`link to a page that doesn't exist: ${path}`);
  return { files: out, pages, site, problems };
}

/** Problems with the pages' metadata: limits, duplicates, required fields. */
export function validate(pages) {
  const problems = [];
  const seen = { title: new Map(), description: new Map() };
  for (const page of pages) {
    const where = `${relative(here, page.source)} ${page.path}`;
    for (const key of ["title", "description"]) {
      if (page[key].length > LIMITS[key]) problems.push(`${where}: ${key} is ${page[key].length} characters (at most ${LIMITS[key]})`);
      const other = seen[key].get(page[key]);
      if (other) problems.push(`${where}: same ${key} as ${other}`);
      seen[key].set(page[key], page.path);
    }
    if (page.description.length < 70) problems.push(`${where}: description is only ${page.description.length} characters`);
    if (page.type === "FAQPage" && !page.faq?.length) problems.push(`${where}: FAQPage without faq entries`);
    for (const path of page.related) if (path === page.path) problems.push(`${where}: related links to itself`);
  }
  return problems;
}

async function main() {
  const check = process.argv.includes("--check");
  const dry = process.argv.includes("--dry");
  const { files, problems } = await buildSite();
  if (problems.length) {
    console.error(problems.map((p) => `${dry ? "warning" : "error"}: ${p}`).join("\n"));
    if (!dry) process.exit(1);
  }
  if (dry) { console.log(`${files.size} files built in memory; nothing written`); return; }
  const stale = [];
  for (const [file, content] of files) {
    const target = join(PUBLIC, file);
    const current = await readFile(target, "utf8").catch(() => null);
    if (current === content) continue;
    if (check) { stale.push(file); continue; }
    await mkdir(dirname(target), { recursive: true });
    await writeFile(target, content);
    console.log(`wrote ${file}`);
  }
  if (check && stale.length) {
    console.error(`Out of date (run node website/site/build.mjs):\n  ${stale.join("\n  ")}`);
    process.exit(1);
  }
  if (!check) console.log(`${files.size} files up to date`);
}

if (process.argv[1] && fileURLToPath(import.meta.url) === process.argv[1]) await main();
