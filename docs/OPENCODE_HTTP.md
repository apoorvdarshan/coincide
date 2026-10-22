# Native OpenCode HTTP integration

The dedicated native HTTP integration remains **in progress**. The transport,
owned-server lifecycle, read-only metadata and volatile event subscription are
implemented in Swift. They do not yet supply an OpenCode `ProviderSession`,
normal chat turns, approvals, steering or native history. Existing OpenCode ACP
conversations retain their original transport and captured configuration.

## Generation and connection boundaries

`OpenCodeMetadataConnection` distinguishes generation 1 JSON `/global/health`
from generation 2 JSON `/api/info`. An HTML 200 is not identity, and an
authentication rejection never falls through to another generation. Supported
metadata floors follow the pinned T3 reference: 1.14.19 and 2.0.18. Unknown
majors are rejected; decoding metadata is not a promise of all controls on an
unreviewed version. A local v2 connection must match the owned process ID. The
v1 health protocol cannot establish that PID.

`OpenCodeOwnedServer` starts only an explicitly supplied executable. It captures
an ephemeral loopback port and a fresh, runtime-only Basic credential. V2 uses
`serve --stdio --hostname 127.0.0.1 --port 0` and an stdin lease; v1 uses its
legacy serve/listening-text contract. Close awaits the exact owned parent and
joins app-owned pipe readers. It does not signal arbitrary descendants, stop an
existing service, or claim a v1 process-death lease. Default runtime environments
still use normal CLI configuration; a GET-only check does not make plugin
startup or database migration inert. Installed HTTP execution has not been
verified against entirely isolated configuration.

`OpenCodeHTTPClient` accepts an explicit HTTPS origin or loopback HTTP origin.
It rejects redirects, URL credentials and credential-bearing query parameters.
Credentials remain in headers and memory. Ephemeral URLSession state uses no
cookie, cache or shared credential store. Request bodies, incremental response
bodies and headers have explicit bounds. Cancellation closes only owned I/O;
it does not retry a mutation or imply that a server-side action was cancelled.

## Metadata and events

V1 catalogs use connected provider/model records and name-based agents. V2 uses
location-wrapped model, agent and default-model responses. The requested
absolute local directory must match the returned directory exactly. Advertised
provider ID, model ID and variant IDs stay separate; upstream `modelID` and
display names never replace wire selections. Empty initial catalogs remain
valid snapshots. Raw provider request headers, bodies, system prompts and
unknown configuration are discarded. A second identity read fences catalog
observation against server replacement. Closing metadata cancels and joins only
its own reads, preserving a shared event subscription and HTTP client.

`OpenCodeSSEConnection` waits for accepted event-stream headers before returning.
V1 is directory-scoped; v2 is a global feed whose future adapter must route exact
native session identities. Framing handles split UTF-8, BOM, CR/LF, comments,
multiline data and committed event IDs. Each line/event is bounded, as are raw
bytes and queued events. Heartbeat bytes refresh a 45-second silence watchdog.
EOF, invalid framing, overflow and silence fail explicitly and require session
reconciliation. They never complete a provider turn or replay a prompt. An
unfinished event does not advance the committed cursor. A cursor alone does not
make OpenCode's global stream durable.

## Remaining integration

Native chat must add captured durable configuration with the storage-version
fence, a shared runtime lease registry, exact inbox/input/run attribution,
generation-specific tool/text/reasoning events, questions and permissions,
explicit Stop and reconnect reconciliation. V2 HTTP prompt success is durable
inbox admission, not execution completion. V1 and v2 history have distinct
semantics; files remain under Coincide's reviewed checkpoint service. Native
setup/authentication, commands, skills, usage and installed-provider verification
also remain required by [the full parity inventory](PROVIDER_PARITY.md).

Sources: [pinned T3 OpenCode implementation](https://github.com/pingdotgg/t3code/tree/680152e27b2a961686389ca69a1557cbb2c55f08/packages/provider-opencode),
[official v2 API](https://dev.opencode.ai/v2/docs/api),
[2.1.2 model routes](https://github.com/anomalyco/opencode/blob/a517687fde98a7329ada3ae644a01a9fc6c4e99e/packages/protocol/src/groups/model.ts),
[2.1.2 event contract](https://github.com/anomalyco/opencode/blob/a517687fde98a7329ada3ae644a01a9fc6c4e99e/packages/protocol/src/groups/event.ts).
