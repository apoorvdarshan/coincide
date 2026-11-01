import { code } from "../../layout.mjs";

export default {
  path: "/features/command-line",
  title: "Drive Coincide from Terminal and agents · Coincide",
  description: "The coincide command lets scripts and agents start threads on any agent, send messages, wait for replies and answer approvals in Coincide.",
  name: "Command line",
  summary: "Start threads, send messages, wait for replies and answer approvals from Terminal, scripts or another agent.",
  type: "WebPage",
  eyebrow: "Feature",
  h1: "Drive Coincide from Terminal, scripts and agents",
  lede: "Coincide comes with a <code>coincide</code> command. Anything that can run a shell command, you in Terminal, a script or one of your agents, can use it to start threads on any agent, talk to them and wait for what they say.",
  related: ["/docs/cli", "/features/switch-agents", "/features/scheduled-tasks", "/features/background-agents"],
  body: (s) => `
<h2>Agents that hand work to other agents</h2>
<p>Every agent Coincide starts can already run <code>coincide</code>, with no setup, and can call its own thread <code>this</code>. So a Claude Code thread can start a Codex chat to review its change, wait for the review and read it back, all in one turn:</p>
${code(`coincide new --agent codex --wait "Review the diff in $(pwd) for bugs. Reply with a list."`)}
<p>The new chat shows up in your sidebar like any other, so you can open it, follow along or take over. This is different from ${s.link("/features/switch-agents", "switching agents")} inside one thread: here each agent keeps its own thread, and they work at the same time.</p>

<h2>Scripts and shell habits</h2>
<p>Because the tool waits for replies and returns meaningful exit codes, it fits into scripts:</p>
<ul>
  <li>pipe text in with <code>-</code> as the message, for example a failing test log;</li>
  <li>use <code>--wait</code> to block until the agent answers, and <code>--json</code> to pick the reply apart with <code>jq</code>;</li>
  <li>check the exit status: <code>3</code> means the thread is waiting for an approval or an answer, <code>4</code> that it timed out.</li>
</ul>
${code(`npm test 2>&1 | coincide send "Fix the failing test" --wait -
case $? in
  3) coincide status "Fix the failing test" ;;   # it needs you
  4) echo "still working" ;;
esac`)}
<p>(<code>send</code> names the thread by its title here; an ID or the start of one works too.)</p>

<h2>Answering from anywhere</h2>
<p>A thread that asks for approval doesn’t have to wait for you to come back to the window. <code>coincide status</code> shows what’s waiting, and <code>approve</code>, <code>deny</code> and <code>answer</code> respond, the same as the cards in the thread. <code>coincide open</code> brings the thread up in Coincide when you’d rather look first.</p>

<h2>What it can and can’t do</h2>
<ul>
  <li>It lists projects, agents with their models, and threads; starts chats or project threads with a chosen agent, model, effort, access and plan mode; sends, steers or queues messages; waits; reads replies; stops turns; answers approvals and questions; archives and opens threads.</li>
  <li>It doesn’t change settings, edit files or reach other Macs. It talks only to the Coincide running on this Mac, through a private socket, and only while Settings › General › Command Line › Command-line control is on.</li>
  <li>Coincide must be running. With the ${s.link("/features/background-agents", "background agent host")}, turns keep going after you quit, but the command needs the app open to answer.</li>
</ul>
<p>Every command, option and exit status is in the ${s.link("/docs/cli", "command-line reference")}.</p>
`,
};
