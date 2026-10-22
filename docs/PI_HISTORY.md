# Native Pi run evidence

Coincide implements Pi conversations, steering and native Run History in Swift.
New inputs capture their selected launcher and storage namespace before
admission, then save an exact live-history baseline before sending. Reviewed
fork/rewind, native lifecycle controls and explicit recovery are connected to
the durable workspace ledger. The current mutation profile is exactly Pi
0.80.5. Full T3 parity remains unfinished; this implementation does not establish
installed-package or model acceptance, session browsing/import, or compatibility
with later mutation profiles. See [validation evidence](VALIDATION.md).

## Captured runtime and admission

`PiRuntimeConfiguration` preserves the requested executable separately from its
resolved absolute invocation, registered workspace spelling and physical cwd.
Default HOME-based agent configuration remains distinct from an explicit
`PI_CODING_AGENT_DIR`. An explicit session-directory override is retained;
otherwise native settings choose the session directory. These values contain
paths and configuration intent, never credentials or settings-file contents.
Physical namespace checks run before launch; capture creates no native directory.

The native Store saves this capture before discovery or a newly authored prompt.
Upgrading a legacy conversation leaves its active and queued configurations
unchanged. Worktree and pull-request checkout targets rebind the captured
workspace while retaining the selected launcher and storage namespace.

An owned, bounded `--version` observation requires the minimum settled/entries
profile (0.80.5 or later). The actual observed version is retained separately
from that profile. Pi bootstraps settings before returning its version, so this
is a no-model observation, not a promise of zero filesystem I/O. The profile
establishes neither installed acceptance nor compatibility of future mutation
methods. Legacy nil-capture sessions retain their existing path.

The captured adapter prepares the exact outgoing text/image digest using
state → complete entries → state observations while idle. `get_entries.leafId`
is authoritative for the live branch; `get_state` does not provide that cursor.
The one-use preparation includes its local run/input owner, native session/file,
observed version, inventory descriptors and leaf. Engine commits that exact
preparation to SQLite before calling the prepared send method. Both sides check
the run, runtime, configuration and input again after their awaits. Stop,
removal, changed ownership or a changed baseline prevents prompt admission.

Captured steering also reserves its actor before Engine saves the new input
owner and digest. The reservation fences pending final reads until admission
settles or is canceled; releasing it transmits nothing. A proven-unsent request
may follow the existing explicit-input fallback policy in a separate new run.
Unknown delivery is never replayed.

## Native evidence and its limits

Append inventory and active ancestry are separate. The terminal read requires
the complete prior inventory to remain unchanged and a parent walk from the
new live leaf to reach the exact baseline leaf. Native user entries are mapped
to the durably owned opening and steered inputs only when their order and
payload digests match. Native entry IDs are not provider turn IDs; Pi continues
to use the explicitly local adapter-run target for steering.

Run records retain bounded IDs and digests rather than raw native prompts,
images or another transcript archive. Terminal evidence is emitted before native
completion. A command with no native change is distinct from a proven user
window. Extension rewrites, unknown inputs or an unverifiable graph leave
history evidence unavailable rather than manufacturing a boundary. If Stop
follows a saved steering marker before send, an exact older-prefix terminal
observation preserves all durable owners but clears native mappings. This
canceled-input case still needs richer proven-unsent history semantics.

Stale admission markers are ordinary command rejections. Malformed proof from
the current scoped provider closes that runtime without failing the workspace
database or unrelated conversations. An obsolete outer run context stays ignored.
Process-loss recovery retains the preparation and audit without replaying input.
Workspace storage version 39 prevents an older binary from dropping the new
capture and admission fields.

## Reviewed native history

Review joins prospectively owned opening/steered user-entry IDs to the current
active branch and immutable prior adoption edges. Native input IDs remain
separate from provider turn IDs. Review retains bounded descriptors/digests,
not another raw prompt archive; journal admission validates those retained
facts without reading native files. Anchored native-byte and label-transform
checks occur outside journal reduction before native mutation.

A head fork uses native `--fork` and preserves the entire append inventory,
including abandoned branches. It refuses a live cursor that would change on
native reload. A historical fork then uses Pi's exclusive user-entry fork on
the separate worker; rewind uses the owned live source actor when available.
Each reserved directory, initial clone and final branch is committed before
further native work or adoption. Intermediate files remain in the audit; no
native file is deleted or guessed from a directory scan after a lost reply.
Deferred model/thinking selection is applied on the next explicit ordinary
turn, rather than claimed as already applied by the history operation.

Pi extension questions belong to the exact history worker generation, outside
ordinary chat requests. Answer admission is committed before one wire response;
a restart never replays it. The single existing event reader, ordered barriers,
source observation and owned close/drain prevent an already observed wake,
changed branch, lost reply or shutdown write from becoming successful adoption.
Unconfirmed operations hold their source. Known candidates can be inspected
without reissuing a fork; Keep Original verifies the exact source and warns
that separate or unrecorded native files may remain. Cold inspection refuses a
live cursor that native reload cannot retain. Physical aliases and hard links
do not create independent ownership of a held native file.

Rewinds retain immutable original run/input references, audit removed rows and
preserve the latest draft. Separately reviewed Git restoration uses that exact
run boundary; once-only prompt recall follows successful external work. A
native no-change suffix can be removed locally without inventing a native cut.

## Empty context and the remaining persistence boundary

A genuinely empty native result may have no file yet. Only its durably selected
consumer receives the explicit empty-context intent; an ordinary missing resume
path remains refused. Reopening this exact absent path creates a new native UUID
and loses the native parent header. The app records that actual identity and
proves empty context before applying its own model/thinking controls. It retains
application lineage without claiming native UUID or parent-header continuity.

The intent is released automatically only after a proven completed consumer and
anchored persisted native file. Failed or lost consumers hold subsequent work.
Read-only inspection may confirm the exact persisted owned input, or report an
absent file. Absence does not establish that an input was never processed. An
explicit Keep Empty Context acknowledgement preserves that uncertainty in the
audit, keeps the queue paused and permits a new explicit input; it never replays
the previous prompt.

A nonempty branch containing no assistant may also be unpersisted in native Pi.
That case remains **unconfirmed/unavailable for adoption**; it is never normalized
to empty context. This includes first-user cuts retaining only model/thinking
metadata. A native-compatible durable solution for this boundary, actual
installed-package/model acceptance and session browsing/import remain required
before declaring Pi parity complete.

## Independent original-source comparison

[The optional generator](../script/generate_pi_history_oracle.mjs) verifies exact
Pi v0.80.5 hashes and evaluates the original graph/context/reload bodies with
restricted import bindings against private synthetic files. No Node or Pi
dependency ships with the app or runs in Swift tests. This is not a full-package
import, OS sandbox or installed provider execution. The optional fork output
separately evaluates the original native file-producing fork bodies.

The [golden fixture](../Tests/CoincideCoreTests/Fixtures/pi_history_original_0_80_5.json)
contains eleven histories, 41 branch/reset observations and thirteen exclusive
user cuts. It distinguishes file reload from the runtime leaf, active and
abandoned compactions, label ancestry, extension state versus context messages,
Unicode/images and missing/null content. Swift compares native inventory,
ancestry, context classification, reload and exact retained user prefixes; it
does not claim complete LLM message conversion from those checks.

Generation uses private HOME/TMPDIR, denies subprocess/network/configuration and
identity creation, permits only exact synthetic read descriptors, verifies all
descriptors close and checks original source/file bytes afterward. Guard probes
are counted separately from actual source execution. Root regeneration is
byte-identical; altered/symlinked source and non-private or existing output are
refused. The Swift file reader deliberately rejects malformed, ambiguous and
legacy data which Pi's permissive reader may skip or migrate; those refusal
policies are tested separately from conformance.

The separate [fork fixture](../Tests/CoincideCoreTests/Fixtures/pi_history_fork_original_0_80_5.json)
contains thirteen cases: ten native outputs, two native rejections and one
intentional policy refusal. It preserves full head inventories, branch rechaining,
global effective labels, compaction references and native missing-file behavior.
Its SHA-256 is `4429c00ca0154c9839138649a4f0db54207cfe7281962f131d7a82dde6af9239`.
Default oracle output remains byte-identical. Fork generation permits bounded,
explicitly owned clock/identity/file writes; subprocess, network and configuration
access remain denied. This is separate from a real RPC process or model turn.

Original references are the pinned
[session manager](https://github.com/earendil-works/pi/blob/v0.80.5/packages/coding-agent/src/core/session-manager.ts),
[RPC types](https://github.com/earendil-works/pi/blob/v0.80.5/packages/coding-agent/src/modes/rpc/rpc-types.ts)
and [CLI](https://github.com/earendil-works/pi/blob/v0.80.5/packages/coding-agent/src/main.ts).
Installed Pi authentication/model turns and hosted Pi history acceptance remain
separate unfinished requirements until their actual results are recorded.
