import { code, table } from "../../layout.mjs";

export default {
  path: "/docs/cli",
  title: "coincide command-line reference · Coincide",
  description: "Every command, option and exit status of coincide, the tool that lists, starts, steers and answers Coincide threads from Terminal or an agent.",
  name: "Command-line reference",
  summary: "Every coincide command, option, output format and exit status, with the rules for naming threads and projects.",
  type: "TechArticle",
  eyebrow: "Reference",
  h1: "<code>coincide</code> command reference",
  lede: "The <code>coincide</code> tool talks to the running Coincide app and does what you’d otherwise do in its window: list projects, agents and threads, start a thread, send a message, wait for the reply, approve a request or answer a question. This page lists everything it accepts.",
  related: ["/features/command-line", "/docs/environment-variables", "/features/approvals", "/features/background-agents"],
  body: (s) => `
<nav class="toc" aria-label="On this page"><p>On this page</p><ol>
  <li><a href="#setup">Where it comes from</a></li>
  <li><a href="#names">Naming threads and projects</a></li>
  <li><a href="#commands">Commands</a></li>
  <li><a href="#options">Global options</a></li>
  <li><a href="#sending">Sending, waiting and reading</a></li>
  <li><a href="#answers">Approvals and questions</a></li>
  <li><a href="#exit">Exit status</a></li>
  <li><a href="#json">JSON output</a></li>
  <li><a href="#security">How it connects</a></li>
</ol></nav>

<h2 id="setup">Where it comes from</h2>
<p>The tool ships inside the app, at <code>Coincide.app/Contents/Helpers/coincide</code>. It only works while Coincide is running with <strong>Command-line control</strong> on, in Settings › General › Command Line. That setting is on by default.</p>
<ul>
  <li><strong>In Terminal.</strong> At launch, Coincide links the tool into the first folder it can write to among <code>/opt/homebrew/bin</code>, <code>/usr/local/bin</code> and <code>~/.local/bin</code>, preferring one that’s already on your shell’s <code>PATH</code>. Settings › General › Command Line shows where it went. If that folder isn’t on your <code>PATH</code>, the setting tells you which folder to add. Coincide never replaces another program called <code>coincide</code>: it shows “… already exists and isn’t Coincide’s tool, so it was left alone.”</li>
  <li><strong>For agents.</strong> Every agent Coincide starts gets the tool on its <code>PATH</code>, plus <code>COINCIDE_CONTROL_SOCKET</code> and <code>COINCIDE_THREAD_ID</code>, so it can run <code>coincide</code> without any setup and refer to its own thread as <code>this</code>. When Command-line control is off, agents get none of these.</li>
</ul>
<p>Run <code>coincide help</code> (or <code>-h</code>, <code>--help</code>) for the built-in summary.</p>

<h2 id="names">Naming threads and projects</h2>
<p>Commands that take <code>THREAD</code> accept, in this order:</p>
<ul>
  <li><code>this</code>: the thread whose agent is running the command. It works only inside a thread Coincide started; elsewhere you get “<code>this</code> works only inside a thread Coincide started.”</li>
  <li>a full thread ID, or a unique start of one at least four characters long;</li>
  <li>the thread’s exact title (case doesn’t matter).</li>
</ul>
<p>If a name matches more than one thread, the command lists the matches and stops, so use the ID. Archived threads are found too.</p>
<p><code>--project P</code> accepts a project’s ID (or a unique start of it), its name, or its folder path (<code>~</code> works). <code>chats</code> means the chats that have no project.</p>

<h2 id="commands">Commands</h2>
${table(["Command", "What it does"], [
  ["<code>coincide projects</code>", "Lists projects: ID, name and folder."],
  ["<code>coincide threads [--project P | --chats] [--archived] [--running]</code>", "Lists threads, newest first, with ID, state (idle, starting, running, needs approval, has a question, archived), project and title. <code>--archived</code> includes archived threads; <code>--running</code> shows only those starting or running."],
  ["<code>coincide agents</code>", "Lists each agent with its ID, name and state, and under it the models it offers, with their reasoning-effort levels."],
  ["<code>coincide new [--chat | --project P] [--agent A] [--model M] [--effort E] [--access full|approval] [--plan] [--title T] [--wait] [--timeout S] [--open] [MESSAGE…]</code>", "Starts a chat (the default) or a thread in a project, applies the options, and sends <code>MESSAGE</code> if you give one. With <code>--wait</code> it prints the reply when the turn ends."],
  ["<code>coincide send THREAD [--wait] [--timeout S] [--alternate] MESSAGE…</code>", "Sends a message to a thread. While a turn runs, the message steers or queues as that thread’s follow-up setting says; <code>--alternate</code> does the other."],
  ["<code>coincide wait THREAD [--timeout S]</code>", "Waits until the thread’s turn ends or the agent needs you, then prints the latest replies."],
  ["<code>coincide read THREAD [--count N]</code>", "Prints the latest turn’s replies, or the last <code>N</code> replies."],
  ["<code>coincide status THREAD</code>", "Shows the thread’s state, agent and model, how many messages are queued, and any approval or question waiting, with its ID."],
  ["<code>coincide stop THREAD</code>", "Stops the running turn."],
  ["<code>coincide approve THREAD [--item ID] [--always]</code>", "Approves the waiting approval request. <code>--always</code> picks the request’s “always allow” choice when it has one."],
  ["<code>coincide deny THREAD [--item ID] [--message TEXT]</code>", "Denies it. <code>--message</code> goes to the agent when the request accepts a reason."],
  ["<code>coincide questions THREAD</code>", "Shows the agent’s waiting questions, with each question’s ID and its choices."],
  ["<code>coincide answer THREAD [--item ID] [--answer QUESTION=ANSWER …] [ANSWER…]</code>", "Answers them. With a single question, just give the answer."],
  ["<code>coincide archive THREAD</code>, <code>coincide unarchive THREAD</code>", "Moves the thread to or from the archive."],
  ["<code>coincide open THREAD</code>", "Brings Coincide forward and shows the thread."],
  ["<code>coincide help</code>", "Prints the summary."],
])}
<h3>Options of <code>new</code></h3>
${table(["Option", "Meaning"], [
  ["<code>--chat</code> / <code>--project P</code>", "Where the thread goes. A chat is the default; you can’t give both."],
  ["<code>--agent A</code>", "The agent, by ID (<code>claude</code>, <code>codex</code>, <code>cursor</code>, <code>grok</code>, <code>opencode</code>, <code>antigravity</code>), name or the start of its name. Without it, the thread uses your default for new threads."],
  ["<code>--model M</code>", "A model of that agent, by ID, name or the start of either. Without <code>--agent</code>, it’s looked up in the new thread’s default agent. Run <code>coincide agents</code> for the list."],
  ["<code>--effort E</code>", "The reasoning effort, as <code>coincide agents</code> lists it for the model."],
  ["<code>--access full|approval</code>", "Full access, or ask for approval (<code>fullAccess</code> and <code>ask</code> work too)."],
  ["<code>--plan</code>", "Starts the thread in plan mode."],
  ["<code>--title T</code>", "Names the thread."],
  ["<code>--wait</code>, <code>--timeout S</code>", "Waits for the reply; needs a message."],
  ["<code>--open</code>", "Shows the new thread in Coincide’s window."],
])}

<h2 id="options">Global options</h2>
<ul>
  <li><code>--json</code> prints JSON instead of text (see <a href="#json">below</a>).</li>
  <li><code>--socket PATH</code> talks to another socket than <code>COINCIDE_CONTROL_SOCKET</code> or the default, <code>~/Library/Application Support/Coincide/control.sock</code>.</li>
  <li>A <code>MESSAGE</code> of <code>-</code> is read from standard input, so you can pipe a file or another command’s output into a thread.</li>
  <li>Options can go anywhere. After <code>--</code>, everything is part of the message, even words that start with <code>--</code>.</li>
  <li>Options take their value as the next word or after <code>=</code>, as in <code>--timeout=600</code>.</li>
</ul>

<h2 id="sending">Sending, waiting and reading</h2>
<p><code>send</code> reports how the message was delivered: <code>sent</code> when the thread was idle, <code>queued</code> for after the running turn, <code>steered</code> into the running turn, or <code>interrupting</code> when the thread’s follow-up setting is Interrupt. Steering works with Claude Code, Codex and OpenCode; with the other agents a steered message is queued. See ${s.link("/features/composer", "the composer")} for how follow-ups behave.</p>
<p><code>--wait</code> and <code>wait</code> poll the thread about once a second until its turn ends (including any queued messages) or it waits for an approval or an answer. The default timeout is 1,800 seconds; <code>--timeout 0</code> waits as long as it takes. When the wait times out, the turn keeps running and the command prints “Still working; stopped waiting.”</p>
<p>The replies printed are the agent’s messages and errors after your last message. <code>read --count N</code> prints the last <code>N</code> replies instead, whatever turn they came from.</p>

<h2 id="answers">Approvals and questions</h2>
<p>A thread that runs with ${s.link("/features/approvals", "Ask for approval")} stops at each command or file change the agent wants to make. <code>status</code> and a waiting <code>--wait</code> show each request’s ID. With one request waiting you can leave out <code>--item</code>; with several, Coincide lists their IDs and asks you to pick one.</p>
<p>For questions, <code>questions</code> prints each question’s ID and choices. Answer one question with plain text, or several with <code>--answer QUESTION=ANSWER</code>, repeated as often as needed (repeat the same question to give it several answers).</p>

<h2 id="exit">Exit status</h2>
${table(["Status", "Meaning"], [
  ["<code>0</code>", "Done."],
  ["<code>1</code>", "Failed, for example Coincide isn’t reachable or a thread or model doesn’t exist. The reason goes to standard error."],
  ["<code>2</code>", "Wrong usage: an unknown command or option, or a missing value."],
  ["<code>3</code>", "The thread waits for an approval or an answer."],
  ["<code>4</code>", "Timed out while waiting."],
])}
<p>When Coincide isn’t running, or Command-line control is off, every command fails with “Couldn’t reach Coincide at … Is Coincide running, with Settings › General › Command-line control on?”</p>

<h2 id="json">JSON output</h2>
<p>With <code>--json</code>, each command prints one compact JSON value. Lists (<code>projects</code>, <code>threads</code>, <code>agents</code>, <code>questions</code>) print arrays. Commands that wait print an object with <code>threadID</code>, <code>state</code> (<code>done</code>, <code>needsInput</code> or <code>timedOut</code>), <code>replies</code> (an array of strings) and, when something waits for you, <code>waiting</code>; <code>new</code> and <code>send</code> add <code>delivery</code>. <code>read</code> prints <code>threadID</code>, <code>running</code> and <code>replies</code>.</p>
${code(`# Start a Codex chat, wait for the answer and keep only the text
coincide new --agent codex --wait --json "List the TODOs in this repo" | jq -r '.replies[]'`)}

<h2 id="security">How it connects</h2>
<p>The tool sends requests over a Unix socket in Coincide’s data folder, one line of JSON each way. The socket is created for your user only, and Coincide checks that each connection comes from your user. There’s no network access and no pairing. That also means any process running as your Mac user can control threads while Command-line control is on; turn it off in Settings › General › Command Line if you don’t want that. When the data folder’s path is too long for a socket (with a long <code>COINCIDE_DATA_DIR</code>, say), the socket goes in your temporary folder instead.</p>
<p>A Debug build of Coincide (built from source) has its own data folder and socket, and its tool talks only to it. It leaves Terminal’s <code>coincide</code> to the installed app.</p>
`,
};
