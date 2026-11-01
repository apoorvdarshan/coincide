import { table } from "../../layout.mjs";

export default {
  path: "/features/browser",
  title: "A browser in every thread for your agents · Coincide",
  description: "Each Coincide thread has its own WebKit browser that you and your agent can both use: shared sign-ins, imports from other browsers and Agent Control.",
  name: "Browser in every thread",
  summary: "A WebKit browser beside each conversation that agents can read, click and type in, with your sign-ins.",
  type: "WebPage",
  eyebrow: "Feature",
  h1: "A browser in every thread",
  lede: "Every thread in Coincide has its own browser panel: a WebKit page beside the conversation, with its own tabs and back and forward history. You can browse in it, and the thread’s agent can use it too, in the background, to check the page it just built or look something up while signed in as you.",
  related: ["/features/browser-passwords", "/features/passkeys", "/features/computer-use", "/docs/rich-output"],
  body: (s) => `
<h2 id="open">Open it</h2>
<p>Choose View › Show Browser Preview, or click the globe button at the top right of the window. The address bar takes web addresses, local servers such as <code>localhost:3000</code>, IP addresses and file paths, and searches anything else with the search engine you pick in Settings › Browser: Google (the default), DuckDuckGo, Bing, Brave Search, Ecosia or Kagi.</p>
<p>A thread keeps up to 20 tabs (<kbd>⌘</kbd><kbd>T</kbd> opens one in the panel, <kbd>⌘</kbd><kbd>W</kbd> closes it), and remembers them across relaunches. Bookmark a page with the star in the address bar; bookmarks and history are listed in the panel and in Settings › Browser.</p>
<p>Web links you click in a conversation open in this browser, and <kbd>⌘</kbd>-click opens your default browser. If you’d rather have it the other way round, turn on “Open links in your default browser” in Settings › General.</p>

<h2 id="profile">One profile, or private sessions</h2>
<p>By default all threads share one persistent browser profile, so a site you sign in to in one thread stays signed in in the others, and after you relaunch. Each thread still has its own pages and history.</p>
<p>Turn on “Use private sessions” in Settings › Browser and each thread’s browser gets its own temporary storage instead, cleared when Coincide quits. Private sessions don’t use imported cookies or saved sign-ins. “Clear Browsing Data…” in the same pane removes cookies and site data, history, or both; bookmarks are kept.</p>

<h2 id="import">Bring your sign-ins from another browser</h2>
<p>Settings › Browser › Import… copies cookies and sign-ins, history and bookmarks from a browser on your Mac, and lets you pick which sites’ cookies to bring. Coincide reads a copy of the browser’s data on your Mac; nothing is sent anywhere.</p>
${table(["Browsers", "Notes"], [
    ["Safari, Safari Technology Preview, Orion", "macOS protects Safari’s data, so Coincide asks for Full Disk Access when it needs it and shows where to grant it."],
    ["Chrome, Chromium, Brave, Edge, Arc, Dia, Vivaldi, Opera, Opera GX, Yandex, Perplexity Comet, Sidekick, Thorium, Helium", "macOS asks once whether Coincide may use the browser’s key in your Keychain to read its cookies; choose Allow."],
    ["Firefox, LibreWolf, Zen, Floorp, Waterfox", "Profiles are listed separately."],
    ["DuckDuckGo", "Not supported: it keeps its data in a form only it can read."],
  ])}

<h2 id="agent-control">Agent Control: what agents can do</h2>
<p>With Agent Control on (the default for new threads), the thread’s agent can drive its browser through a private connection on your Mac that only that thread can use. It works for every agent that has a shell tool, since agents reach it with <code>curl</code>; there’s no MCP server to set up. Agents can:</p>
<ul>
  <li>open pages and search, read a page’s text and its buttons and fields, click, type (rich editors included), press keys, scroll and wait for an element;</li>
  <li>take screenshots, including full-page ones, and switch to a mobile, tablet or desktop viewport for layout checks;</li>
  <li>answer page dialogs, attach local files to an upload field, work inside embedded frames, open and switch tabs, and read the page’s recent console messages and JavaScript errors;</li>
  <li>download files, which are saved in their own folder under <code>~/Downloads/Coincide</code> and never opened automatically.</li>
</ul>
<p>The agent works in the background while the panel is closed. When it needs you, for a sign-in, a CAPTCHA, a two-factor code, a payment or a personal choice, it opens the panel with a short note saying what to do, and waits for you to click <strong>Done</strong>.</p>

<h3 id="limits">What agents can’t do</h3>
<ul>
  <li>They can’t read cookies, site storage or what’s typed in password fields, and they can’t run arbitrary JavaScript in the page.</li>
  <li>They don’t see your passwords or one-time codes. When an agent asks Coincide to sign in, you choose whether to allow it, and Coincide types the login itself. ${s.link("/features/browser-passwords", "Saved logins and password managers")} explains how.</li>
  <li>They’re told to treat page content as untrusted data, not instructions, and never to try to solve or bypass CAPTCHAs or bot checks.</li>
  <li>Access is limited to the thread’s own browser and ends when you turn Agent Control off or quit Coincide.</li>
</ul>
<p>To turn Agent Control off for one thread, use the Agent Control button in its browser panel. To change the default for new threads, use “Agent Control in new threads” in Settings › Browser.</p>

<h2 id="privacy">Privacy</h2>
<p>Pages load from their own sites, as in any browser. What an agent reads or captures from a page goes to that agent’s provider as part of the conversation, so keep Agent Control off in threads where that matters. The <a href="/privacy">privacy policy</a> covers the browser in detail.</p>

<h2 id="not-yet">Limitations</h2>
<ul>
  <li>Passkeys from iCloud Keychain and other system passkey providers aren’t available in Coincide’s browser yet. Bitwarden passkeys are, and for other sites you can sign in in your own browser and import that sign-in; see ${s.link("/features/passkeys", "passkeys")}.</li>
  <li>The browser is for web pages. To let agents use native Mac apps, turn on ${s.link("/features/computer-use", "Computer Use")}.</li>
</ul>
`,
};
