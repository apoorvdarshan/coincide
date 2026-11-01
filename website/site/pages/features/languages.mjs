import { table } from "../../layout.mjs";

const languages = [
  ["English", "English", "en"],
  ["Chinese (Simplified)", "简体中文", "zh-Hans"],
  ["Chinese (Traditional)", "繁體中文", "zh-Hant"],
  ["Dutch", "Nederlands", "nl"],
  ["French", "Français", "fr"],
  ["German", "Deutsch", "de"],
  ["Hindi", "हिन्दी", "hi"],
  ["Indonesian", "Bahasa Indonesia", "id"],
  ["Italian", "Italiano", "it"],
  ["Japanese", "日本語", "ja"],
  ["Korean", "한국어", "ko"],
  ["Polish", "Polski", "pl"],
  ["Portuguese (Brazil)", "Português (Brasil)", "pt-BR"],
  ["Russian", "Русский", "ru"],
  ["Spanish (Spain)", "Español (España)", "es"],
  ["Spanish (Latin America)", "Español (Latinoamérica)", "es-419"],
  ["Turkish", "Türkçe", "tr"],
  ["Ukrainian", "Українська", "uk"],
  ["Vietnamese", "Tiếng Việt", "vi"],
];

export default {
  path: "/features/languages",
  title: "Coincide in 19 languages: Chinese, Hindi, Spanish and more",
  description: "Coincide for Mac comes in 19 languages, from Chinese and Hindi to Spanish and Ukrainian, and follows the language you pick for your Mac or for the app.",
  name: "19 languages",
  summary: "The interface in 19 languages, following your Mac’s language or one you pick just for Coincide.",
  type: "WebPage",
  eyebrow: "Feature",
  h1: "Coincide in 19 languages",
  lede: "Coincide’s menus, settings, notices and permission prompts are translated into 18 languages besides English. The app follows the language you use on your Mac, or one you choose just for Coincide.",
  related: ["/docs/translations", "/features/dictation", "/features/coincide-remote", "/download"],
  body: (s) => `
<h2 id="list">Supported languages</h2>
${table(["Language", "Native name", "Code"], languages.map(([en, native, lang]) => [en, `<span lang="${lang}">${native}</span>`, `<code>${lang}</code>`]))}

<h2 id="choose">Choose Coincide’s language</h2>
<p>Coincide has no language switch of its own: it uses the standard macOS setting, so it matches your other apps.</p>
<ul>
  <li><strong>For the whole Mac:</strong> put your language at the top of Preferred Languages in System Settings › General › Language &amp; Region.</li>
  <li><strong>Just for Coincide:</strong> in the same pane, add Coincide under Applications and pick a language for it.</li>
</ul>
<p>Quit and reopen Coincide after changing it. Dates, times and numbers follow your region’s formats as well.</p>

<h2 id="what">What’s translated, and what isn’t</h2>
<ul>
  <li><strong>Translated:</strong> the app’s interface, from menus and the composer to every Settings pane, notifications, the text of macOS permission prompts, and error messages Coincide writes itself.</li>
  <li><strong>Not translated by Coincide:</strong> what your agents write, which comes from the agent and its model; you can ask an agent to answer in your language. Messages that come straight from an agent’s CLI or provider arrive as they sent them.</li>
  <li><strong>Dictation</strong> has its own language setting in Settings › Voice, automatic by default; see ${s.link("/features/dictation", "dictation")}.</li>
</ul>

<h2 id="quality">About the translations</h2>
<p>The translations are machine-made and marked for review in the app’s string catalog. They aim to be clear and correct, but a native speaker will spot phrasing to improve. Text that’s new or changed in a release falls back to English until it’s translated.</p>
<p>The iPhone and iPad companion, ${s.link("/features/coincide-remote", "Coincide Remote")}, is being built with the same 18 languages.</p>

<h2 id="help">Help improve them</h2>
<p>Corrections are welcome. Open an issue or a pull request on <a href="https://github.com/apoorvdarshan/coincide">GitHub</a> with the text and your suggested wording, or follow ${s.link("/docs/translations", "the translation guide")} to fix strings in the catalog directly.</p>
`,
};
