# Native Pi run evidence

Coincide implements Pi conversations and steering in Swift. New native inputs
capture their selected launcher and storage namespace before admission, then
save an exact live-history baseline before sending. This is the foundation for
native Run History; it does **not** yet enable Pi fork, rollback, session import
or history recovery controls. Full T3 parity remains unfinished.

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
Workspace storage version 38 prevents an older binary from dropping the new
capture and admission fields.

## Independent original-source comparison

[The optional generator](../script/generate_pi_history_oracle.mjs) verifies exact
Pi v0.80.5 hashes and evaluates the original graph/context/reload bodies with
restricted import bindings against private synthetic files. No Node or Pi
dependency ships with the app or runs in Swift tests. This is not a full-package
import, OS sandbox, provider execution or native mutation oracle.

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

Original references are the pinned
[session manager](https://github.com/earendil-works/pi/blob/v0.80.5/packages/coding-agent/src/core/session-manager.ts),
[RPC types](https://github.com/earendil-works/pi/blob/v0.80.5/packages/coding-agent/src/modes/rpc/rpc-types.ts)
and [CLI](https://github.com/earendil-works/pi/blob/v0.80.5/packages/coding-agent/src/main.ts).
Installed Pi authentication/model turns, native mutation/recovery and hosted Pi
history acceptance remain separate unfinished requirements.
