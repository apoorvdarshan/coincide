# Scheduled tasks

Coincide provides native Settings → Scheduled Tasks, durable task definitions and
occurrence audit in the existing workspace journal, and app MCP scheduling tools.
Offline tests exercise actual Engine admission, private local Git preparation,
loopback HTTP/HMAC delivery, shutdown, restart and scoped MCP refusal paths.

## Execution and ownership

Saving an enabled definition explicitly authorizes future input while Coincide
is open. It does not install a daemon or LaunchAgent, keep the Mac awake, deploy
a server, configure DNS, or open an external interface.

The editor captures the selected source conversation's birth, project, exact
workspace path, preparation, directory identities, provider/model/options,
permission and checkpoint policy. A source or profile change refuses admission
until the task is reviewed and saved again. The source is never taken from the
currently selected conversation at timer delivery. Changing a native thread ID
through ordinary provider use does not change the captured profile.

The destination explicitly chooses a new conversation for each occurrence or
queues into the captured existing conversation. Both use the normal Engine
submission path under the original occurrence UUID. Thread allocation, optional
worktree preparation, queued input, ledger record and effects commit atomically.
Existing drafts and attachments are preserved. A fresh worktree resolves the
chosen local base ref at admission, excludes source dirty/untracked files and
uses the normal reviewed setup gate before releasing input. No arbitrary
provider executable, environment, network ref or permission upgrade comes from
a webhook or timer.

A response loss does not resend an admitted input. On restart, an unfinished
occurrence becomes uncertain and its task is paused. Inspect its original
conversation, acknowledge that audit record, then explicitly enable the task if
appropriate. Acknowledgment does not resend, resume a queue or enable a task.
Known provider completion and input admission have separate statuses. Deleting a
definition retains the original run audit and does not silently stop or repeat
an input already admitted.

## Schedule semantics

These follow the pinned T3 schedule source at `680152e…`:

- Writable intervals are at least 60,000 milliseconds. Legacy shorter values
  remain readable and advance with a one-minute minimum. Intervals advance
  elapsed time, not local clock components. An overdue interval admits one
  occurrence and schedules the next from the current observation; there is no
  replay burst.
- Fixed times use host-local `HH:MM` and Sunday=0 through Saturday=6. An empty
  weekday selection means every day. Formatting-only hour changes and weekday
  ordering do not reset an existing due time. A fixed-time occurrence more than
  ten minutes late is recorded as missed rather than dispatched.
- Webhooks have no periodic next-run date. Their HTTP delivery and any configured
  fixed coalescing window are distinct from timer scheduling.

Storage is bounded: 100 definitions, 1,000 occurrence records, 20 pending webhook
windows per task (200 globally), 10,000 unexpired replay claims and 16 MiB total
serialized scheduler state. Overflow fails explicitly. Clear resolved history
or unused definitions before more work is admitted. Original Engine command
receipts remain separate from the compact run-history display.

## Webhooks

The listener starts only through an explicit saved native control. It binds
**127.0.0.1 only**, using the chosen port (0 requests a free port). The saved
choice is restored while the app is open; the actual port is shown in Settings.
External HTTPS, reverse proxies or port forwarding require the user's own setup.
This patch does not configure those services or claim internet reachability.

Requests use `POST /hooks/<task UUID>`, a stable `Idempotency-Key` header, a bounded
`Content-Length` body, and an `Authorization: Bearer …` header generated through
the native editor. Credentials never occur in the URL. The bearer digest and
private Keychain item names are persisted, not the credential values. Signing
secrets are entered in a secure native field and stored in Keychain. Existing
authorization credentials stay unchanged during ordinary edits; rotation is an
explicit editor choice. Fixture tests inject an in-memory secret store.

Optional HMAC-SHA256 verification covers the exact body bytes. Header name,
hex/base64 encoding and prefix are reviewed in the editor. The parser limits
headers to 16 KiB/64 fields, bodies to 1 MiB and owned simultaneous peers to 8. It
rejects duplicate headers, transfer encoding, ambiguous lengths and extra framed
requests. Partial readers time out and are cancelled/joined on shutdown. Accepted
input handlers finish their original admission rather than being replayed when
a settings window closes.

Prompt placeholders support `body.path`, `headers.name`, `query.name`, `body` and
`request`. JSON and form bodies are supported. Inserted values are framed as
untrusted request data and provider mention syntax is neutralized. Credential
headers/query names are excluded, including explicit credential placeholders.
Logs and occurrence metadata do not contain raw request headers, bodies or
signing secrets. Providers still see the user-authorized rendered prompt; this
framing is not a security sandbox.

Up to 16 all-match filters support equals, notEquals, startsWith, in and exists.
Missing paths fail every operation except a matching exists check. Replay-key
templates retain claims for seven days independently of cleared display history.
Missing/empty template values do not create a shared empty replay key. Coalescing
keeps the latest matching payload inside a 10–3,600 second fixed window measured
from its first request. Rate admission is limited to 60 accepted deliveries per
task per minute. Stable delivery IDs also prevent a lost HTTP response from
causing another input; changed bytes under the same ID are refused.

## App MCP

The catalogue exposes `schedule_task`, `list_scheduled_tasks`,
`read_scheduled_task`, `update_scheduled_task`, `delete_scheduled_task`,
`run_scheduled_task_now` and `acknowledge_scheduled_task_run`.

Writes require a live full-access caller and a stable original `commandId` UUID.
Scoped admission checks the calling project, source and permission ceiling.
`bindToCurrentThread` defaults to true, matching pinned T3's thread caller; false
chooses a fresh thread. Native Settings exposes both destinations. Timer inputs
are structured objects. Listing returns bounded metadata/previews; exact prompt
reads use a task revision, UTF-8 byte offsets, byte count and digest. Context-only
MCP scopes expose none of these writes. Webhook secret entry is deliberately a
private native Settings operation, not a model tool argument.

## Explicit remaining boundaries

There is no T3 Connect relay, offline relay-delivery age handling, managed public
webhook URL, external hosting, DNS configuration or unattended app-closed
execution. Native Keychain operation, installed provider turns, live SSH and
hosted native UI interaction remain unverified by the offline fixture tests.
The remote environment wire does not yet expose a separate scheduling editor;
the implemented surfaces are native Settings and the app MCP scope.
