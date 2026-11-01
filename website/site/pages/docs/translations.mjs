import { code, table } from "../../layout.mjs";

export default {
  path: "/docs/translations",
  title: "Help translate Coincide · Coincide",
  description: "Coincide speaks 19 languages, machine-translated and marked for review. How to pick a language, report a bad translation or fix one with translations.py.",
  name: "Translations",
  summary: "The 19 languages, how to switch Coincide’s language, and how to report or fix a translation with the catalog tools.",
  type: "TechArticle",
  eyebrow: "Guide",
  h1: "Languages and translations",
  lede: "Coincide ships in English and 18 other languages, and Coincide Remote, its iPhone and iPad companion (coming soon), uses the same ones. The translations are machine-made and marked for review in the string catalogs, so corrections from people who speak them are welcome.",
  related: ["/features/languages", "/docs/build-from-source", "/docs/settings"],
  body: (s) => `
<h2 id="languages">The languages</h2>
${table(["Language", "Code"], [
  ["English (the source)", "<code>en</code>"],
  ["Chinese, Simplified", "<code>zh-Hans</code>"],
  ["Chinese, Traditional", "<code>zh-Hant</code>"],
  ["Dutch", "<code>nl</code>"],
  ["French", "<code>fr</code>"],
  ["German", "<code>de</code>"],
  ["Hindi", "<code>hi</code>"],
  ["Indonesian", "<code>id</code>"],
  ["Italian", "<code>it</code>"],
  ["Japanese", "<code>ja</code>"],
  ["Korean", "<code>ko</code>"],
  ["Polish", "<code>pl</code>"],
  ["Portuguese (Brazil)", "<code>pt-BR</code>"],
  ["Russian", "<code>ru</code>"],
  ["Spanish (Spain)", "<code>es</code>"],
  ["Spanish (Latin America)", "<code>es-419</code>"],
  ["Turkish", "<code>tr</code>"],
  ["Ukrainian", "<code>uk</code>"],
  ["Vietnamese", "<code>vi</code>"],
])}

<h2 id="choose">Choosing Coincide’s language</h2>
<p>Coincide follows the language you picked for your Mac, or the one you picked for Coincide alone. To use a different language for Coincide only, open System Settings › General › Language &amp; Region, add Coincide under Applications and choose its language, then reopen Coincide. Text that isn’t translated yet appears in English.</p>

<h2 id="report">Reporting a bad translation</h2>
<p>If a translation is wrong, unclear or doesn’t fit, tell us: open a bug report from <strong>Help › Report an Issue…</strong>, or use <code>/bug</code> in the <a href="https://discord.gg/DETrbhDVqw">Discord</a>. Say which language, where in the app the text appears, what it says now and what it should say.</p>

<h2 id="fix">Fixing translations yourself</h2>
<p>The strings live in Xcode string catalogs:</p>
${table(["Catalog", "What it holds"], [
  ["<code>Coincide/Resources/Localizable.xcstrings</code>", "The Mac app, including the text of its shared frameworks"],
  ["<code>CoincideRemote/Localizable.xcstrings</code>", "Coincide Remote on iPhone and iPad. A few strings of its shared package are kept here by hand, marked “manual”."],
  ["<code>Coincide/Resources/InfoPlist.xcstrings</code>, <code>CoincideRemote/InfoPlist.xcstrings</code>", "The permission texts macOS and iOS show, keyed by their Info.plist key"],
])}
<p><code>scripts/translations.py</code> lists what a language is missing, checks your translations and imports them. For German, for example:</p>
${code(`scripts/translations.py missing de > de.json      # the strings German lacks, with their English text
# translate de.json into {"key": "translation"}
scripts/translations.py check de de-translated.json
scripts/translations.py import de de-translated.json`)}
<p>Start the command with <code>--catalog &lt;path&gt;</code> to work on another catalog, such as <code>--catalog CoincideRemote/Localizable.xcstrings</code>.</p>
<h3>What <code>check</code> enforces</h3>
<ul>
  <li><strong>Placeholders</strong> must match the English: the same kinds, in any order only when numbered (<code>%2$@ … %1$@</code>).</li>
  <li><strong>Plurals</strong>: a string with one number placeholder becomes <code>{"plural": {"one": "…", "other": "…"}}</code>, using exactly the plural forms of the language, such as one, few, many and other for Polish, Russian and Ukrainian, or only other for Japanese, Korean, Chinese, Indonesian and Vietnamese.</li>
</ul>
<p>Imported strings are marked “needs review” in the catalog. Write whole sentences with placeholders rather than pieces joined in code, so each language can order the words its own way.</p>
<h3>When you change English text</h3>
<p>New or changed strings fall back to English until they’re translated, so a pull request that changes text should translate it for every language. First update the catalogs with every string the code uses (this builds both apps, so it needs Xcode):</p>
${code(`scripts/sync-strings.sh        # or: scripts/sync-strings.sh mac | ios`)}
<p>Then run <code>missing</code>, translate and import for each language, and commit the catalogs. The rest of the contributing workflow is in ${s.link("/docs/build-from-source")} and <a href="https://github.com/apoorvdarshan/coincide/blob/main/CONTRIBUTING.md">CONTRIBUTING.md</a>.</p>
`,
};
