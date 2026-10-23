# Remote environments: contract and implementation plan

Remote environments are **not implemented** in Coincide. There is no remote
workspace host/client, pairing flow, saved environment registry, SSH provisioning,
LAN listener, relay connection or multi-environment UI. Existing Git remotes,
provider HTTP connections and the local app-MCP server do not establish remote
workspace support. This document records a plan against the pinned T3 reference;
it is not an implementation or acceptance claim.

## Pinned behavior to preserve

The reference is T3 Code
[`680152e27b2a961686389ca69a1557cbb2c55f08`](https://github.com/pingdotgg/t3code/tree/680152e27b2a961686389ca69a1557cbb2c55f08).

- **Environment identity and capabilities.** A public descriptor identifies the
  environment, platform, server version, orchestration protocol and supported
  capabilities. Pinned T3 negotiates orchestration protocol 2. Optional capability
  fields gate behavior; a selectable route is not proof that its operations work.
  See [environment contracts](https://github.com/pingdotgg/t3code/blob/680152e27b2a961686389ca69a1557cbb2c55f08/packages/contracts/src/environment.ts).
- **Pairing and authorization.** The client checks the expected environment ID
  before redeeming a one-time credential. Ordinary pairing grants expire after
  five minutes; token exchange produces scoped sessions. Access-management APIs
  list and revoke pairing links and clients. Native credentials must stay in
  headers/bodies and secret storage, outside workspace journals and URLs. See
  [onboarding](https://github.com/pingdotgg/t3code/blob/680152e27b2a961686389ca69a1557cbb2c55f08/packages/client-runtime/src/connection/onboarding.ts),
  [grants](https://github.com/pingdotgg/t3code/blob/680152e27b2a961686389ca69a1557cbb2c55f08/apps/server/src/auth/PairingGrantStore.ts)
  and [auth contracts](https://github.com/pingdotgg/t3code/blob/680152e27b2a961686389ca69a1557cbb2c55f08/packages/contracts/src/auth.ts).
- **Projection and reconnect.** Shell/thread subscriptions resume after a known
  sequence. Bounded thread snapshots expose an opaque history cursor and an
  explicit incomplete-history flag; clients must not treat a window as the whole
  transcript. See [orchestration contracts](https://github.com/pingdotgg/t3code/blob/680152e27b2a961686389ca69a1557cbb2c55f08/packages/contracts/src/orchestrationV2.ts).
- **SSH lifecycle.** T3 resolves native SSH targets, owns a loopback forwarding
  process, bounds startup/readiness and reuses saved accepted sessions before
  pairing again. Its lifecycle distinguishes managed from external servers.
  Existing host-key and authentication decisions remain with SSH. See
  [SSH transport](https://github.com/pingdotgg/t3code/blob/680152e27b2a961686389ca69a1557cbb2c55f08/packages/ssh/src/tunnel.ts)
  and [platform gateway](https://github.com/pingdotgg/t3code/blob/680152e27b2a961686389ca69a1557cbb2c55f08/packages/client-runtime/src/platform/capabilities.ts).
- **LAN and private routes.** Advertisement follows actual bound private IPv4
  interfaces, excludes loopback/link-local and unsuitable virtual interfaces, and
  publishes Tailscale HTTPS only after a probe. Reachability, source, status and
  client compatibility are distinct endpoint properties. See
  [direct endpoints](https://github.com/pingdotgg/t3code/blob/680152e27b2a961686389ca69a1557cbb2c55f08/apps/server/src/environment/DirectEndpoints.ts)
  and [route contracts](https://github.com/pingdotgg/t3code/blob/680152e27b2a961686389ca69a1557cbb2c55f08/packages/contracts/src/remoteAccess.ts).

## Native implementation sequence

1. Add an environment service boundary above `WorkspaceEngine`, with a local
   implementation and explicit environment-scoped project/thread references.
   Proposed files: `ExecutionEnvironment.swift`, `EnvironmentCapabilities.swift`,
   `WorkspaceEnvironmentClient.swift` and `LocalWorkspaceEnvironmentClient.swift`.
   Route `WorkspaceStore` through it. Remote paths must never reach local file,
   Git or terminal services. Remote provider sessions alone cannot cover this
   boundary because the environment also owns those services and authentication.
2. Add a native `CoincideEnvironment` executable, owning its Engine, SQLite
   database, runtime lock and persistent environment ID. Start with a macOS host:
   current Core services depend on Darwin and Security. Linux/Windows support
   requires deliberate process, file, credential and platform portability work.
   The Swift host is the intended architecture; the T3 Node server is the
   behavioral reference. Coincide's wire DTOs need their own explicit version
   negotiation; this plan does not claim T3 RPC wire compatibility.
3. Build the first complete slice over SSH stdio to an explicitly selected,
   preinstalled native helper. Proposed files: `SSHEnvironmentSession.swift`,
   `RemoteWorkspaceEnvironmentClient.swift` and `EnvironmentRPCServer.swift`.
   Reuse `ProcessChannel` and the `JSONRPCConnection` codec/lifecycle, with
   explicit remote frame, backlog, request-count and deadline bounds. Expose a
   method allow-list mapped to typed Engine admission; internal `EngineCommand`
   values must not become an unrestricted remote API.
   Implement descriptor/capabilities, project/thread listing, submit, streamed
   output, question answer and exact-run Stop, followed by disconnect/reconnect.
   The initial stdio route is an implementation choice; pinned T3 instead uses
   SSH forwarding to its HTTP/WebSocket server. Automatic native helper
   provisioning/update and additional routes follow the working control path.
4. Preserve durable command UUID/payload binding using Engine admission and
   `WorkspaceDatabase.receipt(_:matching:)`. After a lost reply, inspect the
   receipt rather than repeating provider work. Use `journal(after:limit:)` for
   ordered catch-up. Engine `updates()` coalesces full snapshots with
   `bufferingNewest(1)`, so it can wake journal readers but cannot itself carry a
   lossless delta stream. Initial snapshot and subsequent replay need a gap-free
   handoff; missing sequences require explicit resynchronization. Delayed Stop
   and approval commands require atomic expected-run/runtime ownership checks.
5. Add native HTTPS/LAN transport, pairing, scoped authorization, revocation,
   Keychain-backed client credentials and saved route/environment controls on the
   same service boundary. Proposed files: `EnvironmentHTTPServer.swift`,
   `EnvironmentAuthorization.swift`, `EnvironmentCredentialStore.swift` and
   `EnvironmentRegistry.swift`, plus native connection/settings views. The
   existing private MCP listener is loopback-only and closes each response; it
   is not a remote listener. General bounded HTTP client machinery may be shared
   without weakening provider-specific origin or credential rules.
6. Complete remote attachments, file browsing/edit/search, Git/worktrees,
   checkpoints/history/PR operations, provider setup/authentication and PTY
   create/input/resize/replay. `LocalTerminalSession` couples AppKit with process
   creation; remote terminal support needs a headless host PTY service and a
   separate SwiftTerm display adapter. Add signed helper distribution/update,
   private-route discovery, relay behavior and cross-platform acceptance before
   calling remote parity complete.

## First-slice verification gate

Use two isolated native processes, the real wire codec and temporary SQLite to
verify submit/output, question ownership, exact-run Stop, a dropped response with
one provider execution, reconnect replay, persisted environment identity and
identity/protocol refusal. Test client disconnect independently from stopping an
owned host; preserve external processes and unresolved work. Subsequent pairing
checks must cover atomic single use, expiry, scope refusal, revocation and a wrong
machine refusing before credential consumption. No such remote acceptance has
been run yet, and no remote infrastructure or authentication was changed for
this plan.
