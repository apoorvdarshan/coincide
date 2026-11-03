// Checks coincide.dev's built files: they're up to date with the page sources, every internal link and anchor
// resolves, every page has the metadata search engines need, the structured data parses, and the sitemap lists
// exactly the indexable pages. Run with `node --test website/site/`.
import assert from "node:assert/strict";
import { existsSync, readFileSync, readdirSync, statSync } from "node:fs";
import { join, relative } from "node:path";
import { test } from "node:test";
import { HANDWRITTEN, LIMITS, PUBLIC, buildSite } from "./build.mjs";
import { ORIGIN } from "./layout.mjs";

const { files, problems } = await buildSite();

function walk(dir) {
  return readdirSync(dir).flatMap((name) => {
    const full = join(dir, name);
    return statSync(full).isDirectory() ? walk(full) : [relative(PUBLIC, full)];
  });
}
const onDisk = walk(PUBLIC);
const htmlFiles = onDisk.filter((f) => f.endsWith(".html"));
const read = (file) => readFileSync(join(PUBLIC, file), "utf8");
const pathOf = (file) => file === "index.html" ? "/" : "/" + file.replace(/\/?index\.html$/, "").replace(/\.html$/, "");

/** The file Cloudflare's assets (html_handling: drop-trailing-slash) serves for a URL path, or null. */
function resolve(path) {
  const clean = decodeURIComponent(path.split(/[?#]/)[0]);
  if (clean === "/") return "index.html";
  const rel = clean.slice(1);
  for (const candidate of [rel, `${rel}.html`, `${rel}/index.html`]) {
    if (existsSync(join(PUBLIC, candidate)) && statSync(join(PUBLIC, candidate)).isFile()) return candidate;
  }
  return null;
}

const attr = (html, re) => [...html.matchAll(re)].map((m) => m[1]);
const meta = (html, key) => html.match(new RegExp(`<meta (?:name|property)="${key}" content="([^"]*)"`))?.[1];
const ids = (html) => new Set(attr(html, /\sid="([^"]+)"/g));
const unescape = (s) => s.replace(/&quot;/g, '"').replace(/&lt;/g, "<").replace(/&gt;/g, ">").replace(/&amp;/g, "&");

test("pages build without problems", () => {
  assert.deepEqual(problems, []);
});

test("built files are up to date (run node website/site/build.mjs)", () => {
  const stale = [...files].filter(([file, content]) => !existsSync(join(PUBLIC, file)) || read(file) !== content).map(([f]) => f);
  assert.deepEqual(stale, []);
});

test("every HTML file is generated or listed as hand-written", () => {
  const known = new Set([...files.keys(), ...HANDWRITTEN.map((h) => h.file)]);
  assert.deepEqual(htmlFiles.filter((f) => !known.has(f)), []);
});

test("internal links, images and anchors resolve", () => {
  const broken = [];
  for (const file of htmlFiles) {
    const html = read(file);
    for (const ref of attr(html, /\s(?:href|src)="([^"]+)"/g)) {
      if (/^(https?:|mailto:|data:)/.test(ref)) continue;
      if (ref.startsWith("#")) {
        if (ref.length > 1 && !ids(html).has(ref.slice(1))) broken.push(`${file}: ${ref}`);
        continue;
      }
      if (!ref.startsWith("/")) { broken.push(`${file}: relative link ${ref}`); continue; }
      if (ref !== "/" && /\/(#|\?|$)/.test(ref)) { broken.push(`${file}: trailing slash in ${ref}`); continue; }
      const target = resolve(ref);
      if (!target) { broken.push(`${file}: ${ref}`); continue; }
      const hash = ref.split("#")[1];
      if (hash && !ids(read(target)).has(hash)) broken.push(`${file}: missing anchor ${ref}`);
    }
  }
  assert.deepEqual(broken, []);
});

test("every page has a title, description, canonical URL, social tags and one h1", () => {
  const issues = [];
  const titles = new Map(), descriptions = new Map();
  for (const file of htmlFiles) {
    const html = read(file);
    const path = pathOf(file);
    const title = unescape(html.match(/<title>([^<]*)<\/title>/)?.[1] ?? "");
    const description = unescape(meta(html, "description") ?? "");
    const noindex = /<meta name="robots" content="noindex">/.test(html);
    if (!/^<!doctype html>\n<html lang="[a-zA-Z-]+">/.test(html)) issues.push(`${file}: doctype or lang`);
    if (!title || title.length > LIMITS.title) issues.push(`${file}: title “${title}” (${title.length})`);
    if (!description || description.length > LIMITS.description) issues.push(`${file}: description (${description.length})`);
    if (titles.has(title)) issues.push(`${file}: same title as ${titles.get(title)}`);
    if (descriptions.has(description)) issues.push(`${file}: same description as ${descriptions.get(description)}`);
    titles.set(title, file); descriptions.set(description, file);
    const h1s = html.match(/<h1[\s>]/g)?.length ?? 0;
    if (h1s !== 1) issues.push(`${file}: ${h1s} h1 elements`);
    if (!noindex) {
      const canonical = html.match(/<link rel="canonical" href="([^"]+)">/)?.[1];
      const expected = ORIGIN + (path === "/" ? "/" : path);
      if (canonical !== expected) issues.push(`${file}: canonical ${canonical}, expected ${expected}`);
      if (meta(html, "og:url") !== expected) issues.push(`${file}: og:url`);
    }
    for (const key of ["og:title", "og:description", "og:image", "og:image:width", "og:image:height", "og:image:alt", "twitter:card"]) {
      if (!meta(html, key)) issues.push(`${file}: no ${key}`);
    }
    for (const img of html.match(/<img\b[^>]*>/g) ?? []) {
      if (!/\salt="[^"]*"/.test(img)) issues.push(`${file}: image without alt: ${img}`);
      if (!/\swidth="\d+"/.test(img) || !/\sheight="\d+"/.test(img)) issues.push(`${file}: image without width and height: ${img}`);
    }
  }
  assert.deepEqual(issues, []);
});

test("structured data parses and names its types", () => {
  const issues = [];
  for (const file of htmlFiles) {
    const blocks = attr(read(file), /<script type="application\/ld\+json">([\s\S]*?)<\/script>/g);
    if (!blocks.length && !file.startsWith("404")) issues.push(`${file}: no JSON-LD`);
    for (const block of blocks) {
      let data;
      try { data = JSON.parse(block); } catch (error) { issues.push(`${file}: ${error.message}`); continue; }
      if (data["@context"] !== "https://schema.org") issues.push(`${file}: @context`);
      for (const node of data["@graph"] ?? [data]) if (!node["@type"]) issues.push(`${file}: node without @type`);
    }
  }
  assert.deepEqual(issues, []);
  const types = (file) => JSON.parse(read(file).match(/<script type="application\/ld\+json">([\s\S]*?)<\/script>/)[1])["@graph"].map((n) => n["@type"]);
  const videos = htmlFiles.flatMap((file) => attr(read(file), /<script type="application\/ld\+json">([\s\S]*?)<\/script>/g)
    .flatMap((block) => JSON.parse(block)["@graph"] ?? []).filter((n) => n["@type"] === "VideoObject").map((n) => [file, n]));
  for (const [file, video] of videos) {
    assert.match(video.uploadDate, /T\d{2}:\d{2}(:\d{2})?(Z|[+-]\d{2}:\d{2})$/, `${file}: uploadDate needs a time and time zone`);
    for (const key of ["name", "description", "thumbnailUrl", "duration", "embedUrl"]) assert.ok(video[key], `${file}: VideoObject ${key}`);
  }
  for (const t of ["SoftwareApplication", "Organization", "WebSite"]) assert.ok(types("index.html").includes(t), `home has ${t}`);
  assert.ok(types("download/index.html").includes("SoftwareApplication"));
  assert.ok(types("download/index.html").includes("BreadcrumbList"));
  assert.ok(types("faq/index.html").includes("FAQPage"));
  const app = JSON.parse(read("index.html").match(/<script type="application\/ld\+json">([\s\S]*?)<\/script>/)[1])["@graph"].find((n) => n["@type"] === "SoftwareApplication");
  assert.equal(app.offers.price, "0");
  assert.equal(app.applicationCategory, "DeveloperApplication");
});

test("the sitemap lists every indexable page, and only those", () => {
  const sitemap = read("sitemap.xml");
  const locs = attr(sitemap, /<loc>([^<]+)<\/loc>/g);
  assert.equal(new Set(locs).size, locs.length, "no duplicates");
  for (const loc of locs) {
    assert.ok(loc.startsWith(ORIGIN + "/"), loc);
    assert.ok(resolve(loc.slice(ORIGIN.length) || "/"), `${loc} has a file`);
  }
  for (const lastmod of attr(sitemap, /<lastmod>([^<]+)<\/lastmod>/g)) assert.match(lastmod, /^\d{4}-\d{2}-\d{2}$/);
  const indexable = htmlFiles.filter((f) => !/<meta name="robots" content="noindex">/.test(read(f))).map((f) => ORIGIN + (pathOf(f) === "/" ? "/" : pathOf(f)));
  assert.deepEqual([...locs].sort(), indexable.sort());
});

test("localized home pages link to each other with matching hreflang alternates", () => {
  const group = htmlFiles.filter((f) => /hreflang="x-default"/.test(read(f)));
  if (!group.length) return;
  const alternates = (file) => attr(read(file), /<link rel="alternate" hreflang="([^"]+)" href="[^"]+">/g).join(",") + "|" +
    attr(read(file), /<link rel="alternate" hreflang="[^"]+" href="([^"]+)">/g).join(",");
  const first = alternates(group[0]);
  for (const file of group) {
    assert.equal(alternates(file), first, `${file} lists the same alternates`);
    const own = ORIGIN + (pathOf(file) === "/" ? "/" : pathOf(file));
    assert.ok(read(file).includes(`href="${own}">`), `${file} lists itself`);
  }
});

test("the blog's RSS feed lists every post, and blog pages link to it", () => {
  const feed = read("blog/feed.xml");
  assert.match(feed, /^<\?xml version="1.0" encoding="UTF-8"\?>\n<rss version="2.0"/);
  const items = attr(feed, /<item>([\s\S]*?)<\/item>/g);
  const links = items.map((item) => item.match(/<link>([^<]+)<\/link>/)[1]);
  const posts = htmlFiles.filter((f) => /^blog\/[^/]+\/index\.html$/.test(f)).map((f) => ORIGIN + pathOf(f));
  assert.ok(posts.length > 0, "at least one post");
  assert.deepEqual([...links].sort(), posts.sort());
  for (const item of items) assert.ok(!Number.isNaN(Date.parse(item.match(/<pubDate>([^<]+)<\/pubDate>/)[1])), item);
  for (const file of htmlFiles.filter((f) => f.startsWith("blog/"))) {
    assert.match(read(file), /<link rel="alternate" type="application\/rss\+xml" title="Coincide blog" href="\/blog\/feed.xml">/, file);
  }
});

test("robots.txt, the 404 page, the IndexNow key and Workers settings", () => {
  const robots = read("robots.txt");
  assert.match(robots, /^User-agent: \*$/m);
  assert.match(robots, /^Disallow: \/api\/$/m);
  assert.match(robots, new RegExp(`^Sitemap: ${ORIGIN}/sitemap.xml$`, "m"));
  assert.match(read("404.html"), /<meta name="robots" content="noindex">/);
  const wrangler = readFileSync(join(PUBLIC, "..", "wrangler.jsonc"), "utf8");
  assert.match(wrangler, /"not_found_handling":\s*"404-page"/);
  assert.match(wrangler, /"html_handling":\s*"drop-trailing-slash"/);
  const keys = onDisk.filter((f) => /^[0-9a-f]{32}\.txt$/.test(f));
  assert.equal(keys.length, 1, "one IndexNow key file");
  assert.equal(read(keys[0]).trim(), keys[0].replace(".txt", ""));
});
