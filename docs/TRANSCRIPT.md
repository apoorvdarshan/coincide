# Conversation transcript

The conversation shows each provider's work as compact, expandable rows derived
from the transcript Coincide already stores. No provider adapter output changed,
so the rows only show facts that the stored transcript contains.

## Tool calls and the work log

- Each tool call is one row with an icon, a label and a status. Examples are
  `npm test`, "Read Package.swift", "Edited Sources/App.swift +3 −1", "Searched for
  TODO", "Fetched https://…" and "Called server · tool". Select the row to see
  details:
  - Commands show `$ command`, the working directory when the provider reports
    one, and a bounded output window.
    The window shows the last 200 lines or 64 KB, with Copy Output and Show All.
  - Edits show an inline unified diff with line numbers when the provider sent a
    patch, Copy Patch, and the first 400 lines until you choose Show more.
  - Reads and searches list their files, which you can select to open.
  - Todo lists and plan entries show a native checklist.
  - Unknown tools keep the generic input, output and Details disclosure.
- Two or more consecutive tool or reasoning rows from the same run become one
  work-log row, such as "Ran 2 commands and read 3 files". While the run is
  active, the row names the newest step instead.
- Status appears only when the transcript proves it:
  - Codex command text has no exit status, so a finished Codex command shows no
    badge.
  - A Claude `<tool_use_error>` result shows as failed.
  - An entity that was still pending when its run ended shows no status.

Sources: Codex `$ command` and `File changes` rows, Claude `tool_use` rows paired
with their `result-<id>` rows, and ACP, Cursor, Copilot, Grok, OpenCode, Pi, Muse
and Antigravity `tool_call` entities.

## Reasoning

A reasoning row reads "Thinking" while its run is active, followed by a one-line
preview of the newest heading or line. After the run it reads "Thought for Xs".
Providers do not record reasoning timing, so the duration is only known when
Coincide watched the reasoning stream. Otherwise the row reads "Thought". Expand
the row to read the reasoning as Markdown.

## Finished turns

When a run completes, its tool calls, reasoning and intermediate replies fold
under "Worked for 2m 13s", timed by the recorded run. If you steered the run,
the work after each steer folds under "Continued for …". The final reply stays
visible, along with plans, notices, steering messages and failed trailing tool
calls. Select the fold row to show the work again. Turn off Settings → General →
Collapse finished work to keep every row expanded. Stopped and failed runs never
fold, and neither do rows without recorded run attribution.

Under a finished run, a footer reads "N files changed +a −d":

- With saved run checkpoints, the footer loads the checkpoint diff when it
  appears, and View Changes opens the saved Workspace Changes diff.
- Without checkpoints, the footer totals the run's edit cards instead.

While a run is active, the working row shows the elapsed time.

## Messages

User messages render Markdown, so inserted file references are links you can
select. A message longer than 8 lines or 600 visible characters collapses, with
Show full message and Show less.

Point to a message, or move keyboard focus to it, to show its actions. With
VoiceOver, the actions are always available.

- User messages: a day-aware timestamp (full date in the tooltip), Copy, Steered
  for steering input, and Edit from Here. Edit from Here opens Run History's
  reviewed rewind for the run this message opened. When the rewind succeeds, the
  prompt returns to the composer.
- Assistant replies: Copy (hidden while the reply streams), Fork from Here on the
  run's final reply, which opens the reviewed fork, View Changes when checkpoints
  exist, and the timestamp.
- When an action is unavailable, it is disabled and its help text gives the same
  reason Run History shows.

Settings → General → Timestamp format chooses System, 12-hour or 24-hour.

## Proposed plans

Plans from Claude ExitPlanMode, Grok plan mode and ACP plan content render as
Markdown cards. A plan longer than 20 lines or 900 characters shows a preview
until you choose Expand Plan. The card's menu offers:

- Copy Plan.
- Save to Workspace…, which creates a new file inside the workspace and never
  replaces an existing one.
- Implement Plan, which fills an empty composer draft with "PLEASE IMPLEMENT THIS
  PLAN:" and the plan. It does not send anything.
