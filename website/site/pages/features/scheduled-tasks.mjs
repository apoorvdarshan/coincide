import { kbd, table } from "../../layout.mjs";

export default {
  path: "/features/scheduled-tasks",
  title: "Scheduled tasks for coding agents on your Mac · Coincide",
  description: "Schedule prompts for Claude Code, Codex and other agents in Coincide: once, daily, on weekdays, every few minutes or with cron, in any time zone.",
  name: "Scheduled tasks",
  summary: "Send a prompt to a thread or start a fresh one on a schedule: daily, weekdays, intervals or cron.",
  type: "WebPage",
  eyebrow: "Feature",
  h1: "Scheduled tasks",
  lede: "A scheduled task sends a prompt to an agent at the times you choose: a dependency check every weekday at nine, release notes every Friday, a reminder to follow up next Tuesday. It lands in the same thread each time, or starts a fresh thread in a project, and you can ask the agent to set it up for you.",
  related: ["/features/bots", "/features/keep-awake", "/features/background-agents", "/docs/keyboard-shortcuts"],
  body: (s) => `
<h2 id="create">Create a schedule</h2>
<ul>
  <li><strong>In a thread:</strong> choose Thread › Schedule…, or the thread’s menu in the sidebar. Each run sends the prompt into that thread as your next message.</li>
  <li><strong>For a project:</strong> choose New Thread Each Run… in the Scheduled Tasks panel. Each run starts a new thread in the project with the project’s defaults.</li>
  <li><strong>For a bot:</strong> choose Schedule… from the bot’s menu in the sidebar, so it runs in the bot’s conversation. That’s how a ${s.link("/features/bots", "bot")} gets a morning routine.</li>
  <li><strong>By asking:</strong> tell the agent in any thread to do something later or on a schedule, for example “Check for outdated dependencies every weekday at 9 and summarize what changed.” It creates the schedule in its own thread.</li>
</ul>

<h2 id="when">When it runs</h2>
${table(["Repeat", "Example"], [
    ["Once", "Next Tuesday at 10:00"],
    ["Daily", "Every day at 18:00"],
    ["Weekdays", "Monday to Friday at 9:00"],
    ["On Selected Days", "Monday, Wednesday and Friday at 8:30"],
    ["Weekly", "Every Friday at 17:00"],
    ["Every…", "Every 30 minutes, or every 4 hours, from a first run you pick (at least 5 minutes apart)"],
    ["Custom (cron)", "A five-field cron expression: minute, hour, day of month, month and day of week"],
  ])}
<p>Every schedule has a time zone, so “9:00” stays 9:00 where you mean it. The editor shows the next few run times before you save.</p>

<h2 id="panel">The Scheduled Tasks panel</h2>
<p>Choose View › Show Scheduled Tasks (${kbd("⌥", "⌘", "S")}), or click the clock at the top right of the toolbar, to see every schedule beside the conversation. It starts with the open thread’s schedules when it has some and shows that thread’s next run. From there you can search and filter schedules, Run Now, Pause and Resume, edit or delete them, and open the thread or its last run.</p>
<p>Each schedule shows how its last run went: running, completed, failed, interrupted or missed, and whether it’s waiting for its thread.</p>

<h2 id="rules">How runs behave</h2>
<ul>
  <li>A run uses the thread’s agent, model and access mode at that moment. If you ${s.link("/features/switch-agents", "switch the thread to another agent")}, later runs go to that agent.</li>
  <li>If the thread is busy, the run waits and is sent when the current turn ends; it never interrupts a turn.</li>
  <li>Schedules run only while Coincide is open. Runs missed while Coincide was closed or the Mac was asleep are skipped, not run late in a burst. To keep a Mac running overnight, see ${s.link("/features/keep-awake", "Keep Awake")}.</li>
  <li>Archiving a thread pauses its schedules until you unarchive it. Deleting the thread pauses them too; delete the schedule, or undo deleting the thread.</li>
</ul>

<h2 id="agents">Schedules agents create</h2>
<p>Every agent Coincide runs can create, change and delete schedules in its own thread through a private connection on your Mac, so this works the same with Claude Code, Codex, Cursor, Grok Build, OpenCode and Antigravity. An agent sees only its own thread’s schedules, never other threads’ or project tasks.</p>
<p>By default, what an agent creates or changes waits behind a card in the thread, and nothing runs until you allow it: review the name, prompt and timing, then choose Save and Allow. No request from an agent, or from a page it reads, can approve it. If you trust your agents with this, turn off “Approve schedules agents create” in Settings › General; you still see and change their schedules in the thread and in the panel.</p>
<p>To keep things tidy, a thread can have at most 10 schedules, with at most 3 waiting for your approval at once, and agents can make only a few changes in a short time.</p>

<h2 id="limits">Limitations</h2>
<ul>
  <li>Schedules don’t start Coincide. If it isn’t running at the scheduled time, that run is skipped.</li>
  <li>A prompt is sent as typed; it can’t include attachments.</li>
</ul>
`,
};
