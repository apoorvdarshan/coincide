# Terminal selection in messages

Select text in a terminal pane, then choose **Use selection in message**. The selected text is appended to that
conversation's current draft under a native resource-backed **Terminal selection** heading. The composer receives
focus with its caret after the inserted context. Sending remains a separate explicit action.

Selecting output in a split makes that pane active. The action uses only the active pane's last explicit text selection. An empty selection, hidden/closed panel, missing
pane, changed conversation or unavailable composer is rejected. It preserves the existing draft, attachments and
queued input, and does not write to or interrupt the terminal process.

Selection text must be valid UTF-8, contain no NUL and fit within 32 KiB. The final draft is bounded to 4 MiB. Quoting
chooses a fence longer than every backtick run in the selection, so terminal text remains inside its code block.
The action is placed on its own toolbar row so it remains visible beside the existing terminal controls.

Coverage includes portable quoting and size cases, a real native RichTextBlock selection in the owned ConPTY fixture,
hidden-panel refusal and a full-app selection-to-composer flow. Exact-revision Windows execution is a separate gate;
adding these cases does not assert they have already passed. New labels use existing resources and English fallback
where reviewed translations are absent.
