# OpenCode credential-continuity preparation

This foundation is **off by default and not production eligibility**. It does not
change `OpenCodeSession`, read any auth/database/config file, run a CLI, call an
account/model endpoint, or emit `SessionEvent::account_scope`. Root's native host
factory continues to refuse OpenCode until a compatible collector and distinct
typed persistence/adoption path have been validated.

## Version and primary-source evidence

The reviewed official source is immutable commit
[`d356b9b24928cfebde9179e791501fff583eec7c`](https://github.com/anomalyco/opencode/tree/d356b9b24928cfebde9179e791501fff583eec7c).
It is source evidence, not evidence that the installed Windows CLI implements that
protocol. Metadata-only searches found no `opencode.exe`/`opencode` in the current
SSH PATH or the permitted CoincideDev task-tools directories. No CLI command,
owner auth file, database, config, vault, account, or model was accessed.

| Capability | Current acceptance |
|---|---|
| Actual Windows CLI version/protocol | Unverified; no production version claimed |
| Existing Windows adapter's older provider/auth routes | Unchanged; compatibility with this collector contract unproven |
| Normalized active credential/integration/config schema | Synthetic fixtures only |
| API-key continuity | Synthetic paired snapshots and local HMAC seal only |
| OAuth continuity | Synthetic unexpired records; refresh/change pauses for review |
| Environment/external credentials, custom provider/plugin/config directories | Unsupported in this restricted foundation |
| Production host/adoption | Off; account scope is not reused |

The upstream [credential service](https://github.com/anomalyco/opencode/blob/d356b9b24928cfebde9179e791501fff583eec7c/packages/core/src/credential.ts)
orders stored credentials by selection and permits a secret value to change under
an existing record ID. An ID or label therefore does not prove account identity.
The [integration service](https://github.com/anomalyco/opencode/blob/d356b9b24928cfebde9179e791501fff583eec7c/packages/core/src/integration.ts)
selects stored connections before environment credentials and can refresh OAuth
values within five minutes of expiry. Its connection reference is not a universal
verified provider subject. Current [credential schema](https://github.com/anomalyco/opencode/blob/d356b9b24928cfebde9179e791501fff583eec7c/packages/schema/src/credential.ts)
distinguishes key, OAuth, and externally managed credential sources.

The source [global roots](https://github.com/anomalyco/opencode/blob/d356b9b24928cfebde9179e791501fff583eec7c/packages/util/src/global-roots.ts)
use XDG overrides or the home directory's `.local/share`, `.config`, `.cache`, and
`.local/state`, including on Windows. Paths are rooted under `opencode`.
[Legacy migration](https://github.com/anomalyco/opencode/blob/d356b9b24928cfebde9179e791501fff583eec7c/packages/core/src/database/migration/20260805200742_import_legacy_credentials.ts)
imports `auth.json` from that data root into credential records; the guard performs
no such import. Windows [config discovery](https://github.com/anomalyco/opencode/blob/d356b9b24928cfebde9179e791501fff583eec7c/packages/core/src/config/discovery.ts)
also includes managed `%ProgramData%/opencode` configuration and project sources.
The existing Mac adapter's `auth.json`/database usage reader is contextual evidence,
not a replacement for matching an actual Windows CLI version.

## Typed API

`OpenCodeAccountScope` accepts immutable `Policy` and a move-only local `Sensitive`
HMAC seal. Construction is inert. `enabled`, `reviewed_protocol`, and an exact
`expected_version` are explicit trusted-caller decisions; missing proof or seal
returns unsupported. There is no default-home discovery or credential fallback.

- `probe_permission(stage)` must pass before a future collector reads anything
  private. Passing only authorizes a probe; it never authorizes delivery.
- `verify(before, after, stage)` consumes two move-only snapshots and returns
  `bound`, `unchanged`, `unsupported`, or `review`, with enum reason and `must_pause`.
- `invalidate(credentials/selection/config/integration)` latches review immediately.
- `binding()` exposes only the last good typed, opaque continuity descriptor.

Snapshots contain exact version, binary/profile/project physical identities,
explicit model, and normalized private JSON arrays from owned-server credential
list, integration list, and location config-entry responses. The future collector
must preserve source priority and cannot substitute tool-provided records or an
origin supplied by an agent. The public upstream [config endpoint](https://github.com/anomalyco/opencode/blob/d356b9b24928cfebde9179e791501fff583eec7c/packages/protocol/src/groups/config.ts)
returns an ordered array, while credential/integration endpoints have their own
response envelopes. The current adapter's generic object-only API helper is not
silently treated as a compatible collector.

The restricted parser requires exactly one active stored credential matching the
selected integration connection and an explicit matching provider/model. Missing
or ambiguous active selection never falls through to another row, environment
variable, default model, profile, or legacy auth file. External credentials and
config-level provider/plugin/auth overrides are unsupported. Directory sources
are also unsupported because their auto-discovered files are not proven by an
entry's path alone. Do not remove real config or managed policy to satisfy this
restriction; those cases remain unsupported until their complete sources can be
proved by an audited collector.

The descriptor type is `opencode-credential-continuity-v1`. Its HMAC covers selected
credential material, connection/config context, exact binary/version/model,
physical profile/project identities, and profile ID. It contains no password,
API key, access/refresh token, credential JSON, or verified account subject. Root
must store the random local seal in the scoped secret store, not in JSON/source or
alongside the digest. This module creates, reads, or persists no seal. Losing the
seal requires review, not automatic migration. Existing `account_scope` values
cannot be reinterpreted as this distinct descriptor.

Owned UTF-8 buffers, temporary canonical strings, crypto state, and seal memory are
wiped when released. Immutable WinRT parsing copies remain transient private RAM;
this is not a locked-memory guarantee. Raw snapshots/error text never enter the
result or a log.

## Refresh, delivery and restart behavior

Any material change across paired snapshots or since the last good binding
pauses delivery and remains latched even if old material reappears. Resuming a
saved native session, or restarting in a new process, needs the same saved typed
binding and local seal. Same-process server restart must recheck its existing
binding. A first delivery cannot silently replace a previously saved binding.

OAuth access/refresh/expiry changes, including a legitimate refresh under the same
record ID, require explicit review because generic OpenCode metadata cannot prove
that the account stayed the same. A trusted UTC observation time is required;
credentials within the upstream five-minute refresh window plus a one-second
margin are refused before delivery. The guard never refreshes or authenticates.
Changing an explicit model/config may conservatively require another review too.

Upstream prompt admission exposes no expected-credential compare-and-swap field.
Paired observations plus switch invalidation do **not** prove atomicity against
concurrent external changes. A production integration must preserve this limit,
stop/pause on changes, never replay uncertain input, and validate compatibility
before enabling any host path. This foundation provides no session patch or
production support claim.

## Isolated validation

`opencode_account_scope_tests(report)` uses synthetic JSON records and synthetic
local seals only. It covers inert defaults, version/context mismatch, exact
selection, no environment/external/default fallback, HMAC canonicalization,
changes/invalidation, typed resume/restart, lost seal, and OAuth refresh/expiry.
No CLI, auth database, file import, vault, account, model, or network is involved
in the native suite. The harness writes only its isolated result report.
