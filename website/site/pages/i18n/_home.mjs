// The localized home pages (/de, /fr, …): one translated introduction to Coincide per language the app ships in,
// linked to the English home page and each other with hreflang. Each language's file passes its strings to
// localizedHome(); EN below is the English source every translation follows. The docs and feature pages they link to
// are in English.
import { DMG, LINKS, REPO, cmd, escape } from "../../layout.mjs";

export const EN = {
  title: "Coincide: every coding agent in one native Mac app",
  description: "Run Claude Code, Codex, Cursor, Grok Build, OpenCode and Antigravity side by side in one native Mac app, and switch agents mid-thread.",
  ui: {
    skip: "Skip to content",
    navLabel: "Main",
    nav: ["Features", "Agents", "Docs", "Download", "FAQ", "GitHub"],
    get: "Get Coincide",
    about: "A native Mac app for the coding agents you already use. Free and open source under the MIT license.",
  },
  t: {
    eyebrow: "Free and open source · macOS",
    h1: "Every coding agent. One native Mac app.",
    lede: "Coincide runs Claude Code, Codex, Cursor, Grok Build, OpenCode and Antigravity in one window. Each agent uses its own command-line tool with the sign-in or API key you already have, and you can switch agents in the middle of a thread.",
    download: "Download for Mac",
    allOptions: "All install options",
    requirements: "Requires macOS 26 or later on an Apple silicon or Intel Mac. Every release is signed with Developer ID and notarized by Apple, and Coincide updates itself.",
    installTitle: "Install from the command line",
    homebrew: "With Homebrew:",
    npm: "With npm (Node.js 18 or later), which checks the download’s checksum, signature and notarization:",
    agentsTitle: "Bring your own agents",
    agentsText: "Install and sign in to at least one agent. Coincide starts that agent’s own tool on your Mac, so your existing subscriptions keep working. It never resells, proxies or meters your tokens.",
    featuresTitle: "What Coincide adds",
    features: [
      ["Switch agents mid-thread", "The next agent gets a recap of the turns it missed and carries on in the same folder. Switch back, and the first agent resumes its own session."],
      ["One model picker", "Models from every installed and signed-in agent in one menu, with reasoning effort and fast mode where the agent supports them."],
      ["Projects and threads", "A sidebar with search, pinning, archiving and snoozing, and a ⌘K command palette."],
      ["Plan mode and approvals", "Let an agent plan first, approve each command and file change, or give it full access."],
      ["Git built in", "Diffs, checkpoints for every turn, worktrees, commits, pushes and pull requests."],
      ["A browser in every thread", "Next to the terminal in each thread. Agents can open pages, read them and click through them when you allow it."],
      ["Agents keep running", "A background host keeps turns going when you quit or update Coincide."],
      ["Scheduled tasks and bots", "Send a prompt every weekday at nine, or give a bot a personality and a job."],
      ["Computer Use", "Off by default. When you turn it on, agents can operate other Mac apps with their own cursor."],
      ["Dictation", "Apple’s on-device speech recognition, a local Whisper model, or your own OpenAI or Groq key."],
      ["Usage dashboard", "Your plans’ usage limits for each agent, with local history of recent turns."],
      ["The coincide command", "Agents and scripts can create threads, send messages and wait for replies from Terminal."],
    ],
    languageTitle: "Coincide in English",
    languageText: "Coincide is available in 19 languages. It follows the language you chose for your Mac, or the one you pick for Coincide in System Settings › General › Language &amp; Region. The translations are machine-made and marked for review, so corrections are welcome.",
    helpTranslate: "How to help with translations",
    remoteTitle: "Coming soon: Coincide Remote",
    remoteText: "A companion app for iPhone and iPad that connects directly to Coincide on your Mac over your own network or Tailscale. It hasn’t been released yet.",
    openTitle: "Open source",
    openText: "Coincide is free and released under the MIT license. Its source code, issues and releases are on GitHub, and the community is on Discord. It’s made by Apoorv Darshan.",
    github: "Coincide on GitHub",
    discord: "Join the Discord",
    englishNote: "The documentation and feature pages on this site are in English.",
  },
};

const FEATURE_PATHS = [
  "/features/switch-agents", "/features/model-picker", "/features/projects-and-threads", "/features/plan-mode",
  "/features/git", "/features/browser", "/features/background-agents", "/features/scheduled-tasks",
  "/features/computer-use", "/features/dictation", "/features/usage-dashboard", "/features/command-line",
];
const AGENTS = [
  ["Claude Code", "claude-code", "claude"], ["Codex", "codex", "codex"], ["Cursor", "cursor", "cursor"],
  ["Grok Build", "grok-build", "grok"], ["OpenCode", "opencode", "opencode"], ["Antigravity", "antigravity", "antigravity"],
];
const APPLE = '<svg viewBox="0 0 24 24" fill="currentColor" aria-hidden="true"><path d="M16.4 12.6c0-2.4 2-3.6 2.1-3.7-1.1-1.7-2.9-1.9-3.5-1.9-1.5-.2-2.9.9-3.7.9-.8 0-1.9-.9-3.2-.8-1.6 0-3.1 1-4 2.4-1.7 3-.4 7.4 1.2 9.8.8 1.2 1.8 2.5 3 2.4 1.2 0 1.7-.8 3.1-.8 1.5 0 1.9.8 3.2.8 1.3 0 2.1-1.2 2.9-2.4.9-1.3 1.3-2.6 1.3-2.7 0 0-2.4-1-2.4-4zM14 5.4c.7-.8 1.1-1.9 1-3-1 0-2.1.7-2.8 1.5-.6.7-1.2 1.8-1 2.9 1 .1 2.1-.6 2.8-1.4z"/></svg>';

/** A localized home page. `lang` is its BCP 47 tag (also used for hreflang), `path` its URL. */
export function localizedHome({ lang, path, nativeName, ogLocale, title, description, ui, t }) {
  if (t.features.length !== FEATURE_PATHS.length) throw new Error(`${lang}: expected ${FEATURE_PATHS.length} features`);
  return {
    path,
    lang,
    nativeName,
    ogLocale,
    group: "home",
    title,
    description,
    name: nativeName,
    summary: "",
    type: "WebPage",
    wide: false,
    ui: { ...ui, home: path },
    eyebrow: t.eyebrow,
    h1: escape(t.h1),
    lede: t.lede,
    logo: { src: "/img/icon-288.webp", alt: "", size: 64, app: true },
    body: () => `
<div class="actions"><a class="btn main" href="${DMG}">${APPLE}${t.download}</a><a class="btn alt" href="/download" hreflang="en">${t.allOptions}</a></div>
<p class="note">${t.requirements}</p>

<h2>${t.installTitle}</h2>
<p>${t.homebrew}</p>
${cmd("brew install --cask apoorvdarshan/tap/coincide")}
<p>${t.npm}</p>
${cmd("npx coincide-dev")}

<h2>${t.agentsTitle}</h2>
<p>${t.agentsText}</p>
<ul class="cards">${AGENTS.map(([name, slug, logo]) => `<li><a class="card" href="/agents/${slug}" hreflang="en"><b><i><img src="/img/logo-${logo}.png" alt="" width="21" height="21" loading="lazy"></i>${name}</b></a></li>`).join("")}</ul>

<h2>${t.featuresTitle}</h2>
<ul class="cards">${t.features.map(([heading, text], i) => `<li><a class="card" href="${FEATURE_PATHS[i]}" hreflang="en"><b>${heading}</b><span>${text}</span></a></li>`).join("")}</ul>

<h2>${t.languageTitle}</h2>
<p>${t.languageText} <a href="/docs/translations" hreflang="en">${t.helpTranslate}</a></p>

<h2>${t.remoteTitle}</h2>
<p>${t.remoteText}</p>

<h2>${t.openTitle}</h2>
<p>${t.openText}</p>
<div class="actions"><a class="btn alt" href="${REPO}">${t.github}</a><a class="btn alt" href="${LINKS.discord}">${t.discord}</a></div>
<p class="note">${t.englishNote}</p>`,
  };
}
