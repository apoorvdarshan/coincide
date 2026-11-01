import { table } from "../../layout.mjs";

export default {
  path: "/features/appshots",
  title: "Appshots: ask an agent about any Mac window · Coincide",
  description: "Press both ⌘ keys in any Mac app and Coincide attaches that window, optionally with its text, to a chat with your coding agent. Off by default.",
  name: "Appshots",
  summary: "Press both ⌘ keys in any app to bring that window into a chat, ready for your question.",
  type: "WebPage",
  eyebrow: "Feature",
  h1: "Appshots",
  lede: "An appshot is a picture of the window you’re working in, attached to a chat in Coincide in one keystroke. Press both ⌘ keys in any app, and Coincide comes forward with that window in the composer, ready for your question: “Why is this build failing?”, “What does this dialog mean?”, “Turn this design into SwiftUI.”",
  related: ["/features/composer", "/features/computer-use", "/features/dictation", "/docs/macos-permissions"],
  body: (s) => `
<h2 id="turn-on">Turn it on</h2>
<ol>
  <li>Open Settings › Appshots and turn on “Turn on Appshots”. While it’s off, Coincide watches no keys at all.</li>
  <li>Grant Screen Recording, which lets Coincide capture the frontmost window, and Accessibility if the pane asks for it (see below).</li>
  <li>Switch to any app and press the left and right <kbd>⌘</kbd> keys together, without other keys.</li>
</ol>
<p>Coincide plays the screenshot sound (you can turn that off), comes to the front and puts the window’s picture in the composer. If you used a thread in the last minute, the appshot goes to that thread; otherwise it starts a new chat. Nothing is sent until you write your message and send it.</p>

<h2 id="options">Options</h2>
${table(["Setting", "What it does"], [
    ["Take an appshot with", "<strong>Both ⌘ keys</strong> (the default), or a <strong>Custom shortcut</strong> such as <kbd>⌃</kbd><kbd>⌥</kbd><kbd>⌘</kbd><kbd>S</kbd>. A custom shortcut must use ⌘ or ⌃ with a key."],
    ["Include the window’s text", "Adds the text the app makes available in that window, read through Accessibility, as a card beside the picture. Off by default."],
    ["Play a sound", "Plays the screenshot sound at your alert volume when an appshot is taken."],
  ])}

<h3 id="permissions">Which permissions it needs</h3>
<ul>
  <li><strong>Screen Recording</strong>, always: it’s how Coincide captures the window. Appshots never capture the whole screen.</li>
  <li><strong>Accessibility</strong>, only for some setups: to notice both ⌘ keys while you use other apps, and to read the window’s text when that option is on. With a custom shortcut and without the window’s text, Accessibility isn’t needed.</li>
</ul>
<p>${s.link("/docs/macos-permissions", "macOS permissions")} explains every permission Coincide can ask for and where to change it.</p>

<h2 id="privacy">What gets captured</h2>
<ul>
  <li>Only the frontmost window of the app you’re using: never the whole screen and never other windows.</li>
  <li>Coincide skips its own windows, windows that ask not to be captured, and apps where you’re typing a password.</li>
  <li>Captures are kept on your Mac with Coincide’s other attachments. Like any attachment, an appshot reaches the agent, and through it the agent’s provider, only when you send the message.</li>
</ul>

<h2 id="tips">Good uses</h2>
<ul>
  <li>An error dialog or a failing test run in another app: send it with “What went wrong and how do I fix it?”</li>
  <li>A design or a web page in another browser: ask the agent to build the same layout in your project.</li>
  <li>A long document or spreadsheet with “Include the window’s text” on, so the agent gets the text as well as the picture.</li>
  <li>Combine it with ${s.link("/features/dictation", "dictation")}: take the appshot, then speak the question.</li>
</ul>

<h2 id="vs-computer-use">Appshots and Computer Use</h2>
<p>An appshot is a one-off picture you choose to share. ${s.link("/features/computer-use", "Computer Use")} is different: it lets an agent look at and operate apps on its own while it works. You can use either without the other.</p>
`,
};
