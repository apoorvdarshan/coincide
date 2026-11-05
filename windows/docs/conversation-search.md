# Search saved conversations

The sidebar's **Search messages** control opens a native results pane. Enter literal text and choose **Search messages**
to scan saved message bodies across non-deleted conversations, including archived conversations. Matching uses the
same Unicode folding as find-in-conversation. Results show the conversation title and an excerpt, with one result per
message. Select a result and choose **Open message** to open its conversation and reveal that exact message.

Each explicit search takes a metadata snapshot and reads one transcript at a time on a worker. It does not start an
agent, search drafts or queued input, read attachments, or populate the live workspace's lazy transcript cache.
Streaming text that has not been saved yet is absent from this snapshot. Search again to refresh the results.

Changing the query or closing the pane cancels the old operation and revokes its result actions. Opening a result
rechecks the current conversation and message identity; find-in-conversation searches the current text again before
scrolling. A deleted, missing or changed result cannot silently navigate to a different message.

Search pins the physical workspace root and transcript folder, refuses redirected folders and linked transcript
files, validates transcript format/identity and rejects duplicate message IDs. Limits are 10,000 conversations,
16 MiB per saved file, 128 MiB aggregate reads, 100,000 messages per file, 1,024 query bytes and 1,000 results.
Unavailable files and partial results are reported explicitly. Search never rewrites a saved file.

Coverage includes portable search/cancellation cases, actual filesystem and hard-link isolation cases, native
control/worker/stale-result cases, exact-target find navigation and a full-app virtualized-message search flow.
Windows CI and physical acceptance must pass for each changed revision; these descriptions do not assert they ran.
New labels use the existing native resource generation and English fallback where reviewed translations are absent.
