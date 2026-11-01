# coincide.dev pages

The site's content pages (features, agents, docs, compare, download, FAQ, changelog, the localized home pages and the
404 page) are generated from the modules in `pages/` by `build.mjs`, which writes them into `../public/` together with
`sitemap.xml` and `robots.txt`. The home page, privacy policy and terms stay hand-written in `../public/`; the build
only refreshes their shared header, footer, language links and structured data between their `<!-- site-… -->`
markers. The generated files are committed, so deploying is still just `wrangler deploy` from `website/`.

```sh
node website/site/build.mjs           # regenerate after changing a page, layout.mjs or CHANGELOG.md
node website/site/build.mjs --dry     # build in memory and list problems, writing nothing
node --test website/site/             # what CI checks: files up to date, links, metadata, structured data
```

`/changelog` and the version shown on the site come from the repository's `CHANGELOG.md`, so rebuild the site after
adding a release's notes.

After deploying, `node website/site/indexnow.mjs` tells IndexNow search engines (Bing, Yandex and others) about every
page in the sitemap, or only the paths you pass. Its key is the public `<key>.txt` file in `public/`.

## A page

Each `.mjs` file in `pages/` (files starting with `_` are helpers) exports one page, or an array of them:

```js
import { cmd, kbd } from "../../layout.mjs";

export default {
  path: "/features/plan-mode",       // the URL, without a trailing slash; the file is written to public/<path>/index.html
  title: "Plan mode for coding agents · Coincide",   // at most 60 characters, unique
  description: "…",                  // 70–155 characters, unique
  name: "Plan mode",                 // short label for breadcrumbs, cards and related links
  summary: "…",                      // one sentence for cards on hub pages and in Related
  type: "WebPage",                   // or "TechArticle" (docs), "Article" (comparisons), "FAQPage", "CollectionPage"
  eyebrow: "Feature",
  h1: "Plan first, then build",      // defaults to name; may contain HTML
  lede: "…",                         // the paragraph under the title
  updated: "2026-11-01",             // sitemap lastmod and, for articles, the date shown on the page
  related: ["/features/approvals", "/agents/claude-code"],
  body: (s) => `<h2>…</h2><p>… ${s.link("/docs/keyboard-shortcuts")} …</p>`,   // HTML, or a function of the site
};
```

`s.link(path, text?)` and `s.cards([paths])` link to other pages by path and fail the build if the page doesn't exist.
`layout.mjs` has helpers for commands with a copy button (`cmd`), code blocks (`code`), tables (`table`) and keys
(`kbd`). Breadcrumbs, the header, footer, canonical URL, Open Graph and Twitter tags and JSON-LD come from the layout.

Only describe what Coincide actually does: check the code, README.md and CHANGELOG.md, and link official sources for
anything about other products.
