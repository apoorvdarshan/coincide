# Coincide native Swift port

The goal is a complete native Swift macOS port of T3 Code, including its core
services. A running T3 Code/Node server or Electron frontend is not the intended
final architecture. This goal is **not complete**.

The product uses the ChatGPT macOS app as its interaction and layout reference.
Liquid Glass is the default design requirement across native chrome and controls
on supported macOS versions, with native system-material fallbacks on older
versions. Shared glass surfaces now cover the composer, search, native status,
approval/recovery cards, attachment shelves and terminal header. Native sidebars,
toolbars, controls and sheets keep their system treatment; text, code and terminal
content keep readable semantic backing. Reduce Transparency uses opaque surfaces
and increased contrast adds outlines. Complete accessibility and oldest-runtime
verification remain pending.
Provider parity includes every T3 built-in driver and ACP Registry integration:
Codex, Claude, Cursor, Grok, OpenCode, Antigravity, Pi, Muse Code, and Copilot
through ACP. A selectable name or preset alone does not establish end-to-end
integration: installation/setup, authentication, controls, streaming, tools,
permissions, recovery and supported history behavior each need verification.
See the detailed [provider parity inventory](PROVIDER_PARITY.md) for exact
transports, evidence boundaries and missing end-to-end behavior.

The reference is [pingdotgg/t3code at 680152e27b2a961686389ca69a1557cbb2c55f08](https://github.com/pingdotgg/t3code/tree/680152e27b2a961686389ca69a1557cbb2c55f08).
`upstream-inventory.json` records 198 registered RPC methods (182 from `WS_METHODS`
and 16 from `ORCHESTRATION_V2_WS_METHODS`), three separate legacy constant-only
names, and 38 user guides. The active method set matches the `Rpc.make`
declarations and `WsRpcGroup` in `packages/contracts/src/rpc.ts`, plus the server
handler table in `apps/server/src/ws.ts` at that revision. The legacy names have
no registered handlers and do not count as pending RPC implementation targets.
These entries are an inventory, not a claim that Coincide implements the server
wire protocol. Applicable desktop behavior, core services, and remote support
must each be mapped and verified before declaring parity.

## Architecture

- `CoincideCore`: Swift value models, SQLite workspace persistence, subprocess
  ownership, JSON-RPC transport, provider adapters, Git, and file services.
- `Coincide`: SwiftUI scenes with native macOS controls; AppKit for application
  lifecycle, file selection, reveal-in-Finder, and clipboard integration.
- `CoincideMarkdown`: Swift Markdown/cmark parsing, bounded off-main rendering
  models, native SwiftUI blocks, lexical code coloring, and contained file links.
  SwiftMath/CoreText renders closed display formulas without a webview. Font
  resources ship inside the app and have a separate runtime-loading CI check.
- Codex and Claude run as CLI processes over stdio. Codex keeps the installed CLI
  default and offers explicit managed or custom executables; Claude uses its
  installed CLI. Existing provider authentication stays in the selected CLI home;
  no API key is embedded or copied into the workspace.
- Claude now retains one root session identity across child events and repeated
  runs, coalesces initialization and joins its owned process, writer and readers
  on close. Prospective original/steering input UUIDs and captured runtime bind
  Run History to actual root transcript records. Native fork journals an exact
  file reservation before publication; deferred rewind selects T3's inclusive
  root-assistant cursor for one explicit successor, preserving raw history,
  queued captures and current drafts. Native review/recovery, inherited/fresh
  reset, separately reviewed Git restoration and once-only prompt recall are
  connected. Legacy evidence remains gated; no `resumeDropsTurn` is enabled.
  The pinned SDK 0.3.276 transform and installed CLI 2.1.304 are distinct.
  Four generated native turns verify fork/deferred-resume context recall and
  restart on 2.1.304; broader compatibility and hosted UI acceptance remain.
  See [Claude history boundaries](CLAUDE_HISTORY.md).
- The dedicated [OpenCode HTTP integration](OPENCODE_HTTP.md) has native
  generation-aware identity/catalog reads, an owned loopback subprocess and
  bounded HTTP/SSE networking. Separate v1/v2 native conversation actors preserve
  captured model/variant/agent/rules, exact message ownership, text/tool/child
  projection, permissions, v1 questions, v2 forms and Stop. V1's server-generated
  session IDs and user-message/assistant-parent/idle admission differ from v2's
  durable inbox/execution contract. Focused checks include a real loopback v1
  HTTP/SSE-to-Engine FIFO test; hosted acceptance is pending. Installed 2.1.2
  metadata is separate evidence, and installed 1.x chat is unverified. V2 active
  steering preserves original-run inbox ownership. Native v2 message-ordered
  history, reviewed fork/rewind and explicit staged-revert recovery are now
  implemented with passing local protocol, Engine and native view checks. V1
  history now copies and adopts an exact prefix with durable candidate publication,
  immutable run-reference mapping and explicit keep-original recovery; its focused
  local protocol/Engine/native-view checks pass. V1 steering, session browsing/import
  and reconnect reconciliation remain unfinished. Existing OpenCode ACP conversations retain their original path and
  do not inherit native v2 history.
- Native Codex Settings reads existing CLI account/plan and subscription allowance
  with identity consistency, sparse update and stale/unsupported handling. Email
  is hidden by default and observations stay outside persistence. Explicit owned
  ChatGPT sign-in and saved-account controls now have a separate Settings path;
  installed owned sign-in/model acceptance and broader usage telemetry remain.
- Codex Runtime Settings saves an explicit installed/managed/custom selection and
  optional absolute home in private bounded preferences. Existing CLI behavior is
  the default; no home contents or authentication are migrated. New conversations
  capture the preference, while active and queued inputs keep their own runtime
  and home. Thread catalogs and metadata ownership include that binding. Applying
  a preference invalidates account/catalog/default reads and drains their owned
  work without retargeting an active conversation.
- Explicit Codex installation pins the complete 0.156.1 package. Bounded download,
  archive identity, extraction and package-layout checks precede activation;
  runtime leases retain in-use versions and protect removal. Explicit runtime
  inspection uses private temporary homes and bounded `--version` and
  `app-server --help` checks, reporting the observed executable/source/version
  separately from account access. The existing 0.163.x history/steering and
  inferred CLI-default guards remain unchanged. A managed binary is not managed
  ChatGPT authentication: owned OAuth/account controls are a separate explicit
  mode; real sign-in/model acceptance, broader usage, skills and MCP/configuration
  parity remain unfinished. Installed managed-package and
  conversation evidence must be recorded separately from offline checks.
- The Codex owned-auth Core layer now implements PKCE, verified RS256/ES256
  identity, a bounded native loopback callback listener, saved registrations and
  separate renewable account credentials in device-only Keychain storage.
  Cross-process rotation ownership and durable uncertainty receipts prevent
  replaying an unconfirmed old refresh token. The explicit flow controller keeps
  an injected workspace lease through publication, cancellation and cleanup.
  Native home overlays share T3's history/configuration entries while preserving
  private auth and model-cache data; fixed token-sharing arguments place the
  access token only in the child environment. These are offline-tested Core
  components now connected to captured account identity, Engine admission/drain,
  lazy process launch and native Settings. Account changes pause retained input
  and join native readers/processes before credential mutation; accepted queues
  keep their original binding. A provisioned development bundle passes the real
  synthetic-item Keychain create/read/update/delete check without accessing saved
  accounts. Profile transfer and installed sign-in/model verification remain
  required before the account feature is complete.
- Custom installed ACP agents use a native JSON-RPC 2.0 adapter. Saved named
  invocations pass literal arguments and are captured in each conversation/queue.
  Config options take precedence over legacy model/mode fields. Permissions keep
  agent-provided option IDs, and resumed history is drained without duplicating
  the journal transcript. Unsupported capabilities are not advertised. ACP agents
  enforce their own permissions and sandbox; a shared permission selection does
  not create a Codex sandbox around an ACP agent.
- Explicit Cursor and Copilot profiles capture their vendor flavor with the
  invocation. Native Settings offers initialize-only connection observations on
  separately owned transports; a successful observation is not an authentication
  or model-access receipt. Cursor extension requests use unique local identities,
  exact option IDs and explicit question/plan responses. Bounded todo merge/replace,
  task and image notifications display activity without filesystem reads or client
  tool execution. Copilot opts into its actual raw event feed and attributes child
  content/lifecycle to the originating run, including background output after the
  parent completes and a new turn starts. Both v1 and experimental v2 preserve
  these vendor profiles. Native auth and complete
  vendor SDK/control/usage parity remain unfinished.
- The explicit Grok ACP profile captures launch permissions through the existing
  `PermissionMode` in each run/queue; it does not keep a second permission source.
  Ask, Auto and Always approve have provider-specific launch arguments;
  Auto-accept edits is rejected. Prompt IDs fence xAI completion and background
  task ownership. Typed plan/questions preserve exact selections and notes through
  the durable response outbox. Offline checks pass; hosted acceptance and
  installed Grok execution are pending. Initialize-only status is not an auth or
  model receipt; normal sessions may use only the CLI's existing noninteractive
  sign-in. Exact owned-parent shutdown makes no descendant-exit guarantee.
- Native Pi uses its own LF-delimited RPC subprocess, captured provider/model/
  thinking selections, and an app-owned tool-approval extension. Native model
  discovery and confirm/select/input/editor dialogs retain exact values. Session
  continuation uses a validated native session file. A command ACK or `agent_end`
  does not release the queue: a native settled event and a fresh idle observation
  must agree. Stop is fenced to the app run; unresolved pre-start work retires
  the connection. Active steering now uses a typed adapter-run target after
  observed native activity, preserving the captured settings and session file.
  Native `prompt` with `streamingBehavior: "steer"` supplies admission ACK evidence;
  Pi has no native expected-turn check or per-prompt turn ID. Pending admission
  invalidates old idle probes and holds settlement; unknown delivery is not
  retried. `/compact` uses the separate native compact command. Existing
  conversation stdio/Engine and native view/store checks have passed. New inputs
  capture the launcher, registered/physical workspace and native storage-selection
  intent. For captured runtimes, an observed 0.80.5+ profile and exact idle
  entries/leaf baseline are committed before prompt admission; steering reserves
  the actor before its durable input marker. Terminal entry evidence precedes
  completion and maps owned inputs only when the unchanged baseline, native
  ancestry, order and payload digests agree. Unknown or rewritten windows remain
  unavailable; process-loss recovery keeps the preparation without replay.
  Storage 39 preserves these captures, proofs and native history operations.
  Reviewed native `--fork`/exclusive-user rewind now journals every candidate
  before adoption, routes lifecycle dialogs to their exact owned worker, and
  supports read-only known-candidate or Keep Original recovery without replay.
  Immutable original run references, separately reviewed workspace restoration,
  once-only prompt recall and explicit deferred empty-context consumers are
  connected. Cold reload-leaf changes and nonempty unpersisted cuts stay refused;
  model/thinking-only first-user resets still need a durable native solution.
  Source-oracle, stdio, journal, Engine, Store and hosted acceptance evidence are
  recorded separately in VALIDATION.md. Session browsing/import, setup/auth,
  usage and actual installed acceptance remain open. No installed Pi calls were
  made. See [native history boundaries](PI_HISTORY.md).
- Native Muse uses a separate MSP JSON-RPC connection with bounded framing,
  exact command admission, initialized-before-use ordering and an owned process.
  Captured model/effort/permission values govern each input; session identity and
  permission-profile read-back must agree before sending. Scoped approval stages
  and questions retain choices, rule previews and notes until native settlement.
  Only the owned root terminal advances FIFO; an idle status or admission ACK
  cannot complete it. Original-run background revisions retain attribution.
  Native steering now sends `turn/steer` with the exact `expectedTurnId` and a
  UUIDv7 command ID. A matched admission or native steered user-message item
  proves acceptance for that original session/turn; neither proves consumption.
  It does not change captured model, effort or permission. Offline stdio/Engine
  and native view/store checks cover the initial integration; the new steering
  fixtures pass the focused serial run. No installed Muse calls were made. Installed execution, broader recovery and usage remain open.
- Native Antigravity uses its paired ACP server and harness over a dedicated
  bounded JSON-RPC connection. Captured account generations, models and native
  modes govern each input; resume reapplies controls without loading old tools.
  Explicit Google/Enterprise/key/Agent Platform setup stages a fresh isolated
  generation under an Engine lease. Runtime initialization is separate from
  verified account/model access; browser URLs stay transient and keys stay in
  Keychain. Exact native options and persistent-grant warnings remain visible.
  Delegated file access is anchored to the captured workspace and drained before
  account or workspace changes. Explicit managed installation pins the archive
  and pair, verifies native initialization before atomic activation, retains
  leased old versions across updates and refuses removal of a leased or custom
  referenced runtime. Legacy captures remain external; storage 31 fences the new
  runtime-selection field. Offline peers exercise conversations, installation
  failures, cancellation and account isolation. Installed account/model execution,
  usage, skills/MCP, portable handoff and broader recovery remain unfinished.
- Transcript entities retain their session, type, opaque ID, structured fields,
  and chunk annotations. The native reducer applies replacements, null clearing,
  metadata patches, independently decoded terminal bytes, and typed user-message
  association. ACP v1 tools already use this durable path, including updates after
  foreground completion. An opt-in ACP v2 adapter negotiates the current draft or
  adopts v1 on the same transport. It separates prompt insertion from foreground
  completion, handles agent-initiated work without fake user input, and lets
  session-level permissions remain pending while the foreground is idle.
- Each local thread has its own provider connection, workspace path, permission
  selection, and persisted conversation. Persistence commits versioned entity and
  message mutations, the cached projection, a command receipt, and an audit marker
  together. Legacy snapshots are imported once and projections can be rebuilt.
  A single native engine serializes typed commands and decisions, then runs provider
  I/O separately through the leased, fenced outbox. The desktop observes committed
  state rather than writing whole snapshots. Rejected commands also retain their
  idempotency receipts. Runtime ownership is exclusive per database, and provider
  events are scoped to a connection and run so stale replies cannot reopen a turn.
- Codex model discovery follows bounded catalog pagination and preserves wire IDs,
  catalog IDs, advertised open-ended reasoning options, descriptions and defaults.
  Native model selection saves per-model reasoning overrides; Model Default clears
  only that model's override and captures a concrete advertised effort. The pinned
  T3 policy prefers Medium for the exact Astra family when advertised. CLI Default
  Model reads cwd-aware CLI configuration and its catalog on an owned metadata
  connection without changing CLI config or sending a turn. It retains only the
  selected model and effort, rechecks relevant configuration after catalog I/O,
  and rejects stale source ownership before committing. Stop, streaming and draft
  edits continue during that read. Header, queue, active-run and audit settings
  remain distinct; omitted legacy effort stays explicitly unspecified. Normal
  turns send the captured `effort` and detailed summaries. Steering has no model
  or reasoning override. Full account/setup and other provider controls remain
  unfinished.
- Queued turns capture their model, reasoning effort, permission, and workspace configuration. Normal
  completion advances the queue; Stop, provider failure, and application restart
  hold it for explicit resumption. Database storage version 35 protects these fields,
  native generation/profile/Pi/Muse/Antigravity captures and typed question-with-notes effects
  and durable history gates from older binaries, including the distinction between
  a native-turn steering target and Pi's adapter-run target, OpenCode v2 ordered
  message proofs and explicit staged-maintenance receipts. No exactly-once
  provider execution is claimed.
- Direct steering durably accepts one authored input into the active local run,
  preserving its captured settings, exact runtime/session and typed target, attachments,
  message identity and leased outbox effect. The dispatch marker commits before
  external handoff. Codex 0.163.x uses `turn/steer` with `expectedTurnId`; a valid
  same-turn receipt acknowledges acceptance without creating a new run or turn.
  Claude sends a `priority: now` envelope on the existing query. Its transport
  write is recorded as submitted, not native acknowledgement; an exact observed
  echo can establish acknowledgement. No receipt proves model consumption.
  Claude has no wire-level expected-turn compare-and-swap, and observed foreground
  Agent/Task ownership keeps steering unavailable until release. Semantic ownership
  events refresh availability without querying on each streamed token.
  Muse uses native expected-turn steering; Pi uses a locally fenced adapter run
  and leaves native turn/history IDs unset. Both pass focused offline steering
  checks and the full local serial suite, with no installed acceptance claim. Neither adapter repeats an input whose delivery is uncertain.
- The composer defaults to Queue while running, with Command/Control-Return using
  the alternate available action. Settings and an explicit delivery menu offer
  Queue or Steer. Direct steering uses the active run's settings even if the
  future-turn header changes. Promotion removes only the selected queued identity
  and preserves the current draft; incompatible captured settings remain queued.
  Pending questions/approvals and unsupported adapters keep steering unavailable.
  Interrupt-and-restart, configuration-changing promotion, OpenCode v1 and the
  remaining providers' active steering are still unfinished.
- Pending steering holds future starts in that conversation while the current
  provider stream, Stop and drafting continue. A valid late receipt remains tied
  to the original run. A proven-unsent input whose exact parent normally completed
  can become one captured follow-up with the same authored row; Stop/removal/restart
  suppress delayed fallback. Unknown delivery keeps its audit and holds the queue
  without replay. Acknowledgement releases that hold without inventing a provider
  receipt or repeating input. Restart distinguishes undispatched from possibly
  dispatched work. History cannot retain unknown/submitted-only steering as a
  verified native prefix; a rewind before its owning run retains hidden audit.
- Each newly started run retains its captured settings, user-message reference
  or explicit agent/legacy origin, observed adapter turn references, stop intent,
  and terminal outcome in the journal. Queue advancement closes one record before
  opening the next; stale scoped events cannot rewrite completed history. Restart
  marks an unfinished run interrupted without replay. Earlier transcript rows are
  not backfilled with guessed turn boundaries. A native Run History sheet exposes
  these records and offers eligible reviewed history actions. Adapter references
  may be locally generated and do not by themselves establish a native boundary.
- Newly produced transcript messages retain their originating app conversation
  and run. Replacements keep that local attribution rather than accepting a
  provider-supplied reference. Journal replay preserves attribution changes;
  earlier messages remain unmodified. A prefix boundary requires a terminal,
  attributed run and rejects interleaved or unattributed later messages. Before-run
  boundaries additionally require the recorded opening user message.
- Native provider history contracts distinguish opaque provider thread/turn IDs
  from app run IDs and Git objects. A bounded Codex 0.163 adapter reads paginated
  turn summaries, forks at an exact inclusive/exclusive boundary into a fresh
  target connection, and reverts conversation history before a reviewed turn.
  Revert requires a loaded idle thread, a null/paused/complete goal and the same
  reviewed head immediately before its RPC. Fork defers goal continuation and
  verifies the new identity, workspace and resulting head. Unknown contracts and
  unverified boundaries fail explicitly; uncertain mutations are not retried and
  prevent further writes on that connection. New threads explicitly select the
  paginated contract on the reviewed profile; existing legacy threads are not
  migrated. The reviewed 0.163.x profile is a temporary compatibility boundary,
  not a claim of support for unknown Codex versions or other providers. The
  provider protocol has no compare-and-swap parameter: another client can still
  change native history between the final read and mutating RPC.
- Native OpenCode v2 history now reads bounded ordered message inventories and
  binds attributed opening/steering inputs to whole-run prefixes. Fork uses an
  exclusive next-opening cut or the native head, proves fresh session ancestry,
  and compares the full canonical prefix despite regenerated native message IDs.
  History-only rewind requires a clean exact source, stages literal `files: false`,
  commits once and verifies the exact retained prefix. A possibly sent mutation
  remains held without replay. Explicit Clear Pending Revert has its own durable
  dispatch and requires a matching empty native execution plus exactly one
  terminal-derived idle append and persisted receipt; ordinary reads never clear
  stages or create sessions. Source/descendant quiet checks are process-local
  observations, not native CAS or external-writer exclusion. Direct, reducer,
  native view and real TCP/SSE-to-Engine history checks pass locally; no
  installed/hosted history acceptance is claimed. ACP history remains a separate
  unfinished path. See [OpenCode HTTP boundaries](OPENCODE_HTTP.md).
- Native OpenCode v1 history uses exclusive native message cuts and complete
  semantic copy proof. It never uses the file-restoring native revert. Rewind
  adopts a verified fresh native session while keeping immutable run references;
  later cuts follow validated positional maps. Candidate acknowledgement is saved
  before further native I/O. Unknown outcomes are not replayed: exact known rewind
  candidates can be re-proved by reads, or an explicit fresh unchanged-source
  confirmation keeps the original with a separate-conversation warning. Quiet
  checks do not exclude independent native writers; installed/hosted acceptance
  remains unverified.
- Native Run History now integrates explicit reviewed Fork After Run and Rewind
  Before Run actions. Eligibility requires verified native IDs or exact OpenCode
  v1/v2 input-message boundaries, local message attribution, a matching current
  checkout, and an idle source without queued work, pending questions or
  unresolved workspace/setup/settlement/checkpoint
  gates. Completed runs can fork; rewind also requires a verified opening user
  message. Legacy or ambiguous boundaries stay unavailable rather than being
  inferred from IDs or timestamps. The exact review and operation are persisted
  before a fenced outbox dispatch; the source is locked against conflicting
  submissions, configuration, archive and removal while the action is pending.
  Drafting, pinning and selection remain available.
- An applied fork creates a separate conversation with the selected run's captured
  provider settings, verified new native identity and reviewed visible transcript
  prefix. It clears runtime, queues, drafts and run/checkpoint/setup/settlement
  state and retains validated lineage. It does not select the new conversation,
  send a prompt, or alter the source. Rewind keeps the source's current provider
  settings, unsent draft and attachments, and marks the removed suffix in the full
  retained message/run audit. Only active messages appear in the transcript and
  count toward last-user activity. Late provider updates cannot rewrite removed
  audit rows. Recall Prompt explicitly appends the original prompt to the latest
  draft, merges attachments within limits, and records one-time application; it
  never submits the prompt.
- History-only actions leave files and staging unchanged. A known
  pre-mutation rejection is a visible failure. An uncertain dispatched rewind,
  including a lost acknowledgment, holds provider work until read-only inspection
  proves the original or expected resulting head or complete message prefix, as
  appropriate to the native contract. OpenCode v2 additionally requires a clean
  stage and exact persisted evidence for any owned maintenance idle append;
  unrelated history or unknown maintenance remains unresolved. Clearing a staged
  revert is a separately reviewed mutation, never part of read-only inspection.
  Restart fails an accepted undispatched intent and marks a dispatched one
  unconfirmed without replaying either RPC or provider work. Resolved audit and
  fork lineage survive source removal. Deterministic adapter, reducer, journal,
  engine and native-store coverage is distinct from real-provider and hosted GUI
  verification. The opt-in installed-Codex engine smoke has verified two generated
  turns, exact native fork/rewind heads, retained audit/draft and unchanged working
  bytes/index/HEAD, with no unexpected tools or approvals. Both generated native
  conversations were archived and local cleanup passed. The hosted native Files
  inspector workflow now passes. The signed immutable helper also passes all
  five formerly blocked provider preflights. Hosted run `39746111640` executed
  all 14 GUI scenarios with eight passes, six failures and zero skips. Container
  accessibility identifiers, native menu title content and transcript lookups
  have subsequent source/harness repairs, but complete hosted history/restoration
  and pull-request workflow verification remains pending.
- A standalone native checkpoint service prepares immutable local plans, captures
  Git working bytes into private refs, inspects owned completion receipts and
  returns bounded snapshot diffs. Captures use a separate index and a frozen
  private Git configuration; HEAD, branches, the real index and checkout files
  remain unchanged. Ordinary and cone sparse/full indexes, staged-but-edited
  files, ignored tracked additions, symlinks and executable modes have regression
  coverage. Configuration and filesystem ownership are rechecked, failed attempts
  are preserved, and missing local objects never trigger a lazy fetch. This
  service is wired to automatic before/after-run capture, with the accepted input's
  captured policy. Baseline failure releases provider work with visible missing
  evidence; post-run capture precedes FIFO advancement, and failure holds the queue
  for a fresh later observation or explicit continuation. Stop, archive, removal
  and shutdown cancel and drain only owned jobs. Restart performs bounded inspection
  without capture/provider replay or automatic queue resumption. Native history
  exposes status, preserved attempts and a bounded read-only workspace diff.
  Successful captures seal scratch ownership into the receipt; cleanup verifies
  file identities/content and retained directory anchors, preserves unknown or
  changed entries, and can resume a durably recorded partial removal. Snapshot
  objects/refs and receipts remain available.
  Unused executable filter settings are permitted. Bounded attribute checks use the
  actual private index/admin, including missing-attribute fallback, before and after
  add; selected executable clean/process drivers remain unsupported and are never
  run. The real and scratch index inventories include ignored tracked additions
  and entries removed from real staging. Non-cone sparse checkouts are currently
  unsupported; modern Git with `--no-lazy-fetch` is required.
- Standalone checkpoint file restoration accepts one exact ready observation,
  independently of the provider and the other checkpoint's success. A native
  review binds the current Git/file manifest, exact checkpoint and idle source
  before one durable dispatch. Restoration requires a separate worktree with no
  other active/archived conversation or retained checkpoint sharing its scope.
  Provider/model-discovery connections, scripts, editors and terminal ownership
  are checked and owned connections drain before the first write; detached
  closing sessions retain their former directory until closure completes.
  Restore/clean/reset runs against an owned shadow checkout with frozen Git
  configuration, followed by verified exclusive publication into the reviewed
  checkout. HEAD and branch identity remain unchanged, nonignored additions are
  removed and staging resets within scope; ignored files and nested repositories
  follow Git's original rules. Original displaced bytes remain in private recovery
  storage. Canceled unused reviews release only verified scratch. Changed/unknown
  entries and started recovery data are preserved. Restart never replays writes;
  read-only inspection can confirm the exact completed result or untouched state,
  otherwise an explicit Keep Current Files releases the hold without another
  restore. Conversation audit, settings and latest draft remain unchanged. Current
  bounds are 100,000 entries, 4 MiB of path names and 512 MiB of copied regular
  bytes, including ignored files. These do not cap transient Git materialization,
  conversion expansion or retained recovery data. Full large-workspace support
  and recovery-storage management remain open.
- Combined Codex rewind offers Keep Changes or a separately reviewed Revert Files
  Too choice. The exact target is the preceding visible local run's latest ready
  after-run observation, or the original first run's ready pre-provider baseline.
  It never substitutes the selected run's later baseline for the previous result.
  Missing, ambiguous, inherited or incompatible boundaries remain unavailable.
  The single durable operation holds the source and overlapping workspace across
  provider and file stages. Provider history is verified first; its success,
  retained removal audit, a new source fingerprint and the distinct file outbox
  intent commit together. Owned connections drain before file dispatch. These
  external operations are not atomic: file failure preserves confirmed provider
  success and holds further work for read-only inspection or explicit Keep
  Current Files. Unknown provider outcomes never start delayed file writes,
  including after inspection. Restart never replays either stage. After complete
  success, a durable recall hold allows the desktop to append the original input
  and attachments to the latest draft exactly once, or explicitly keep the
  current draft. Nothing is submitted automatically. Older saved history actions
  retain manual recall behavior. This remains limited to the verified Codex
  history contract and the standalone restoration compatibility limits above.
- Background clones are project-owned outbox actions. The project and conversation
  appear as soon as their intent is saved; submitted messages retain their captured
  configuration and attachments while waiting for a checkout. A completed clone
  releases eligible queues; Cancel and restart hold them for explicit resumption.
  Git runs in an owned process group and a private staging folder. Publication is
  exclusive, and retry checks local completion evidence before creating another
  attempt. Coincide preserves previous staging folders; Git itself may remove
  files when a clone fails. Partial network transfers are not resumed.
- Worktree preparation persists an intent and final target path before resolving
  local Git references, then journals the immutable plan before mutation. Each
  attempt captures source/common/admin ownership and a pinned commit. Queued input
  retains its provider configuration and waits for readiness. New/existing branch
  setup and explicit registered reuse preserve source edits and untracked files.
  Cancellation, failure, and restart hold queues; conservative completion evidence
  permits recovery without restarting Git over an old folder. New attempts retain
  previous files, branches, and ownership records. No automatic deletion, branch
  reset, pruning, fetch, or remote setup is part of this flow.
- Managed New Project creates a distinct folder under the app's `Projects` data
  directory, initializes Git, and generates a starter README/icon. It respects
  the user's Git branch, identity, hooks, and signing settings. Initial-commit
  failure is a warning with a usable repository. The prepared project and its
  first conversation register atomically; interrupted setup preserves its folder.
- Sidebar organization persists through the same journal. Canonical project order
  is retained for Manual mode, while activity/creation order is derived from
  nonarchived conversations. Accepted queued input counts as user activity;
  assistant output cannot outrank existing user input. Collapsed projects retain
  their selected eligible conversation, and display renames preserve checkout
  paths. New projects have creation/activity dates; legacy unknown dates remain
  unset rather than being assigned synthetic migration timestamps.
- A native, read-only repository identity resolver enriches registered projects
  for logical checkout grouping. It handles nested folders, detached worktrees,
  explicit bare repositories, upstream/origin fork identity, and supported URL
  aliases. Credentials, queries, and fragments are removed before returning
  metadata. Owned refreshes run after load, registration, and clone readiness;
  removal/path/incarnation fences discard late results. Failures preserve the
  previous identity and do not stop agents. Unchanged metadata adds no journal
  event or outbox action.
- Logical groups derive from physical project records. Repository, repository
  and folder, separate-checkout modes, and physical-path overrides persist in
  sidebar preferences. Groups aggregate activity and conversations while retaining
  every project/thread identity. Atomic membership checks protect collapse,
  checkout selection, and manual moves; moves preserve untouched interleaving.
  Future-conversation checkout selection never retargets existing conversations.
  Rename/removal menus support one physical checkout or an atomic whole-group
  action. Whole-group confirmation captures every registration/path and active
  and archived conversation; stale membership is rejected. The last selected
  conversation restores its owner and archived view on restart. Storage version
  10 protects these durable preferences and identity fields from older binaries.
- Project removal commits all active/archived thread removals, project removal,
  collapsed-preference cleanup, and pending-action cancellation together. Running
  actions retain their leases until their owned executors settle; detached
  provider/model/clone cleanup is tracked outside the command inbox. Every native
  window registers its terminal owner for targeted cleanup. Composer/import/model
  state and unreferenced inspectors are reconciled, shared paths remain usable,
  and editor scopes freeze during removal after explicit unsaved-edit confirmation.
  Queued worktree assignments extend those locks before removal commits. Removal
  waits for affected cleanup owners without waiting for unrelated projects.
  New conversations or dirty editors require renewed confirmation. Coincide does
  not delete checkout, worktree, staging, or attachment files; Git may clean up its
  own unfinished files when an active clone is stopped. Append-only recovery
  history remains, so removal is explicitly described as workspace removal rather
  than secure erasure. Removal uses the existing journal event types.
- Attachment bytes live in private, immutable app-owned files. Drafts, queued
  turns, messages, and outbox entries retain typed references. Images are normalized
  with ImageIO as needed and delivered through each provider's native image input;
  other files are included as escaped local-path context. Integrity checks precede
  provider execution. Imported originals are never modified.
- Local file sessions are shared by canonical workspace root. Detached native
  filesystem work lists dotfiles/empty/ignored entries, searches paths with Git
  ignore rules, inventories ignored files, and reads bounded UTF-8 previews.
  Anchored directory descriptors reject escapes, special files, replaced roots,
  and Git-metadata writes. Exclusive creation does not overwrite existing files;
  revision-checked saves preserve deterministic external changes but do not claim
  atomic compare-and-save against concurrent external writers. Native FSEvents
  coalesces advisory invalidations; clean editors refresh and dirty buffers remain
  intact. Cached editors survive inspector/workspace switches; normal Quit asks
  before discarding unsaved edits. Last-owner removal and shutdown drain sessions.
  The composer can insert escaped relative file/folder links into a captured
  conversation without attaching bytes. No upstream filesystem-watch RPC is
  claimed; watching is a native implementation capability.
- Native content search preserves whitespace and UTF-16 source ranges, with
  literal/regex, case, and Unicode whole-word controls. The inspector groups
  highlighted lines by path and opens the selected match in the native editor.
  Matching is cooperative and bounded; partial results and native regex errors
  are explicit. The native ICU regex dialect is not claimed to reproduce fff
  fallback results or ranking. Searches retain dirty buffers and conversation
  state and never replace file contents.
- Explicit external-editor actions use a native catalog, inspected application
  bundles and their contained launchers, a local preferred-editor setting, and
  Launch Services or literal argument vectors. PATH wrappers are not executed.
  Existing regular files and directories are checked through the anchored file
  service, including binary files; ownership is rechecked before handoff. Pending
  validation cancels and drains on shutdown, while accepted external apps own
  their lifetime. Saved bytes open externally without saving or discarding native
  buffers. Native result actions pass a line only; cross-editor Unicode column
  conventions and remote editor targets remain unverified. Xcode is a native
  addition to the pinned T3 editor catalog.
- Default permission mode is supervised. Full access is available as an explicit
  per-thread choice. Unsupported interactive provider requests fail explicitly.
- Native project-script discovery reads the current checkout's anchored `t3.json`
  (up to 256 KiB), including comments/trailing commas and the pinned declaration
  schema. Discovery never executes scripts. A native sheet displays the chosen
  command and checkout; explicit Run rechecks its file revision, conversation,
  window and anchored root before creating a dedicated PTY. The user's login
  shell receives the command as one argument and the T3 project/worktree variables.
  Tabs retain output and exit status, and running scripts use close confirmation
  even when the shell execs its command into its own process group. Imported
  preview fields do not yet trigger their own workflows. Parsed
  icon/environment/submodule fields do not yet override native project settings.
- A separately signed native managed-script helper provides app-owned checkout
  setup execution. It separates actual command exit from background-job
  lifetime, retains ownership independently of windows, and uses bounded private
  control/status/raw-output pipes. A captured plan pins the command, configuration,
  checkout, project root and shell; preparation does not execute the command.
  Worktree requests capture a review gate before Git starts. After checkout
  readiness, anchored discovery selects the first run-on-create script and stores
  its exact plan for explicit native review. Missing roles skip setup; malformed
  or changed configuration holds provider work for a visible decision. Files and
  Terminal use checkout readiness independently. Blocking setup releases providers
  only on actual exit 0; asynchronous setup releases them after a durable startup
  acknowledgment. One Core output consumer feeds bounded complete snapshots to
  every window. Stop, Continue Without Setup and Retry drain the owned group;
  Retry captures a new plan and requires review. Interrupted jobs are never
  replayed after process loss. The existing manual script path stays separate.
- Native GitHub PR reads use the installed `gh` CLI with explicit repository/host
  selection and bounded typed metadata. Creation reviews the exact published head,
  server base commit, title, body and draft state; it never implicitly pushes or
  forks. An exact existing open head is reused even if its base differs. The
  durable engine records intent and dispatch before the external create request,
  holds conflicting checkout work, and retains uncertain outcomes across restart.
  Inspection only reads the captured branch; absence does not authorize a retry.
  Explicit acknowledgment releases an unresolved hold without repeating creation.
  The native browser supports state/search filters, URL/number lookup, descriptions,
  checks and reviewer metadata. AI content generation, compound commit/push/create,
  review/merge actions, stacks and other hosts remain pending.
- Native PR checkout captures exact host/base/head identity, requested commit,
  source/admin/common ownership, index/status/configuration and destination proof
  before durable dispatch. It fetches into an attempt-owned ref, verifies the
  reviewed SHA, switches a clean local checkout or creates/reuses a registered
  worktree, and records the actual branch/HEAD. Fork worktree branches include
  the full base repository identity; fork default branches use an owner prefix
  locally. A missing fork head falls back to the exact base pull ref. Tracking
  setup failures retain a usable checkout with a warning. Clean reused checkouts
  fast-forward; a proven old upstream can advance to its rewritten remote head
  after retaining the old commit. Local commits, dirty checkouts and unrelated
  fork aliases stay unchanged and explicitly off-head. Expected-old ref updates
  preserve a racing external branch advance. Git configuration and pointer changes
  invalidate a review, including destination-only per-worktree settings.
- A distinct checkout ledger reserves the target identity/settings without creating
  a conversation. Confirmed completion or read-only inspection atomically creates
  one blank target with PR lineage, captured agent options and checkpoint policy;
  source history and current draft remain. No prompt or provider session is
  inherited. New/moved managed worktrees may discover setup for explicit review;
  unchanged reuse skips it. Pending/unknown writes hold the affected checkout;
  unrelated source providers, queues, editors, terminals and archived siblings
  continue. Different PR destinations can remain pending together, with each
  native progress/recovery card targeting its own durable identity. Shared Git
  metadata mutations serialize separately from file/provider admission. Source
  commits, branch switches and working/index edits do not invalidate an independent
  worktree review or its completion receipt; repository ownership, chosen remotes
  and execution/transport policy remain sealed. Busy registered worktrees receive
  a distinct read-only review and bounded consistent actual-HEAD observation,
  without fetch, reset, tracking, setup or private metadata writes. Read failures
  and restart leave no unknown write hold. A refreshed target becoming busy after
  review requires a fresh review. Closed terminal tabs/windows retain directory
  ownership until actual process/output drain. Only affected PR reads and clean
  caches are drained/refreshed. Restart never repeats Git or setup; unknown write
  acknowledgment creates no target. Broader real-host/network and interactive
  concurrency verification remain open.
- Explicit Settle/Resume persists a settlement generation independently of provider
  idle. Settle rejects running work, queued messages, unresolved setup and pending
  questions. It drains retained setup jobs before discovering the first settle
  role in a proven separate linked checkout. Main/shared checkouts and unproven
  legacy ownership skip the role. Each generation requires explicit command
  review; script exit does not resume the conversation. Resume or a new user
  submission drains owned cleanup jobs before clearing the generation and
  starting captured queued input. Retry, removal, archive and restart use the
  same script-owner fences. Existing manual terminal tabs remain separate;
  automatic settlement and idle-terminal closure are not implemented.

## Current implementation and evidence requirements

| Area | Implemented now | Remaining work for parity |
| --- | --- | --- |
| Native workspace | Open/clone folders, managed New Project and starter repository, atomic project/first-conversation registration, logical repository/folder/physical grouping and overrides, explicit checkout choice for new conversations, restored conversation selection, physical/group renaming and collapse, persistent manual ordering and aggregated activity/thread-creation sorting, confirmed atomic physical/group removal with archived conversations and targeted runtime cleanup, thread search/rename/pin/archive, explicit settlement generations and Resume, settings | Snooze/automatic settlement, undo, scratch projects, import/migration |
| Codex | Installed CLI default, explicit managed complete 0.156.1 package or custom executable, captured runtime/home and scoped catalogs, private bounded runtime checks and in-use package leases; explicit native owned ChatGPT account Settings, vault and runtime admission; handshake, bounded paginated model discovery, native advertised reasoning controls with per-model preferences and concrete cwd-aware CLI default selection, captured reasoning in turns/queues/history, start/resume, streaming, command/file approvals, user questions, interrupt, reviewed same-workspace native fork and history-only rewind on the 0.163.x profile; bounded workspace-scoped skill discovery and literal composer mentions | Native downloader acceptance and actual owned ChatGPT sign-in/model execution, portable account profiles, full protocol coverage, broader usage telemetry, native commands/MCP/configuration controls, broader history contracts and cross-workspace transfer, all tool events; hosted skill-picker acceptance |
| Claude | Native bidirectional stream-json connection, coalesced startup/root identity/owned drain, model discovery, streaming, session resume, tool approvals, questions, interrupt; prospective UUID/runtime history proof, reserved native fork, inclusive deferred rewind with one consuming explicit run, inherited/fresh reset, read-only recovery and native review/file-restore/recall integration; independent synthetic SDK oracle; installed 2.1.304 four-turn fork/rewind context and restart acceptance | Broader history/resume compatibility and hosted UI acceptance; full control protocol, multi-select question UI, managed installation/auth setup, usage, hooks/configuration and complete tool metadata. Legacy history remains gated; no `resumeDropsTurn` launch. |
| OpenCode HTTP | Separate native v1/v2 actors, captured model/variant/agent/rules, bounded HTTP/SSE, text/tool/child ownership, permissions, questions/forms and Stop; v2 active steering; v2 message-ordered reads, reviewed fork/history-only rewind and explicit staged-maintenance recovery; v1 verified clone/adoption, durable candidate, repeated-run mapping and keep-original recovery with passing focused local checks | V1 steering, session browsing/import, native setup/auth, commands/skills, broader child/reconnect recovery, usage, broader history compatibility and installed/hosted acceptance; existing ACP remains separate |
| Other providers | Custom installed ACP v1 agents, opt-in current ACP v2 draft with same-connection v1 fallback, OpenCode preset, explicit Cursor/Copilot profiles, initialize-only connection checks, Cursor question/plan/todo/task/image extensions, original-run Copilot child attribution, native model/config discovery and select/boolean controls, session load/resume, streaming/thoughts, structured tool/plan output, after-idle tool updates and permissions, agent-initiated foreground work, exact permission choices, interrupt, queued/resumed conversation integration, visible rejected/unconfirmed submissions | Registry/managed installation, native authentication/elicitation, delegated filesystem/terminal methods, richer media and display-terminal UI, live notices, session listing/import/fork, older v2 draft variants, complete OpenCode/Cursor/Copilot/Grok/Antigravity/Pi/Muse behavior and installed end-to-end evidence |
| Durable orchestration | Serial native command engine and effect worker, replayable SQLite journal, atomic projections/receipts/audit/outbox, durable accepted/rejected command deduplication, revision checks, effect leases/fencing, exclusive runtime ownership, scoped provider events, held queues after process loss, durable run settings/references/outcomes, automatic run checkpoints with cancellation/drain/restart inspection, native history and bounded workspace diffs, durable reviewed fork/rewind, standalone restoration and combined provider-then-files intents with retained audit, explicit partial outcomes, inspect-only recovery and one-time latest-draft recall, legacy migration | Complete provider recovery, broader provider history/portable transfer, incremental projection storage/performance, full upstream command coverage |
| Composer/transcript | ChatGPT-style native conversation, persistent per-thread drafts, queued turns with edit/remove/resume, separate Stop, direct Codex/Claude/OpenCode v2/Muse same-turn steering and typed Pi adapter-run steering with passing offline checks, Queue/Steer preference and exact compatible queued promotion, Markdown headings/lists/tasks/quotes/tables/code, lexical syntax coloring and code copy, closed display/math-fence formulas, contained file links with line navigation, native workspace path-reference picker, workspace-scoped Codex skill chooser with `$` and optional `/skill:` triggers, tool/reasoning disclosure, focused Enter/Shift-Enter input | Inline and broader math parsing, transcript media, citations, diagrams/details/alerts, complete language highlighting, native slash commands and broader inline triggers, other-provider skills, plans, restart/configuration-changing steering and remaining-provider delivery; hosted skill-picker acceptance |
| Attachments | Native picker, file/image paste/drop import, persistent drafts/queues/history, thumbnail and image previews, copy/save/open controls, HEIC/TIFF conversion and image resizing, count/size/integrity checks, native Codex/Claude image input and file context | Remote uploads, question attachments, long-paste conversion, prompt stash, failed-import retry UI, reference-aware cleanup, source images over 50 MiB, broader media previews |
| Git/workspaces | Native status including unborn/detached/tracking/conflicts, literal staged/unstaged diffs and paths, stage/unstage/commit, initialize, local branch creation/checkout and remote tracking, fetch, clean fast-forward pull, explicit single-branch push, background clone with progress/stall/cancel/retry, cancellable operations and app-shutdown cleanup, durable local worktree preparation with explicit base/new/existing branch choices, verified registered reuse, queued-message readiness, cancellation/retry and conservative restart recovery, explicit None/top-level/recursive initialization in new worktrees with durable nonfatal warnings, discovered checkout setup with explicit reviewed execution and provider readiness gates, reviewed settle roles with drain-before-resume, automatic workspace observations in private refs with isolated staging and verified scratch cleanup, reviewed standalone and combined rewind checkpoint restoration with owned recovery data, bounded native GitHub PR list/detail/checks and exact reviewed creation, local PR checkout and concurrent managed/reused PR worktrees with captured blank conversations, busy read-only reuse, actual-head warnings and durable inspect-only recovery | AI PR content generation, compound commit/push/create, reviews/merge/stacks/other hosts, large-workspace restoration and recovery-storage management, worktree removal, automatic pull policies, broader credential and network failure coverage |
| Files | Async hidden/empty/ignored directory browsing, bounded path/content/regex search with Unicode ranges and ignored-file inventory, bounded UTF-8 preview with binary rejection, safe exclusive creation and revision-checked saves, advisory native watching, retained dirty editor buffers, normal-Quit discard confirmation, contained composer path references and match/file-link navigation, explicit inspected external-editor and Finder handoffs with preferred-editor settings | Arbitrary-host and remote reads/browsing/metadata, broader binary/media previews, cross-editor Unicode columns and live installed-editor verification, crash recovery of unsaved buffers, cached index/ranking and regex-dialect parity |
| Terminal | Native SwiftTerm emulator and local PTYs, per-window/thread tabs, resize/input, 5,000-line scrollback, hide/show persistence, interrupt and process cleanup, bounded t3.json script discovery with explicit native selection and dedicated command tabs/cwd/environment/exit status, app-owned setup and settle jobs with shared output and separate command/background lifetime | Preview behavior, project-script settings/editing, durable terminal restart restoration, remote attachment/replay, search/settings, activity/idle detection and idle-tab closure, broader terminal compatibility and accessibility |
| Remote environments | Not implemented | Authenticated transport, pairing, capabilities, reconnect, SSH/relay/LAN, multi-environment ownership |
| Desktop integration | App bundle, commands/shortcuts, appearance, default macOS 26+ glass on custom chrome with native system structures/material fallbacks and opaque/increased-contrast accessibility variants | Broader appearance/accessibility/older-runtime QA, notifications, deep links, updates, browser/preview, screenshot/import features, localization resources and locale QA, power/resources |
| Distribution | Local development-identity or ad-hoc signed bundle | Release signing/notarization, installer/update validation, full notices |
| Validation | Deterministic core/protocol/orchestration tests, CI workflow, native Codex/Claude turn and queue smoke checks | Upstream replay corpus, broader live tool/approval coverage, UI automation, full parity and failure audit |

## Validation commands

```sh
swift test --no-parallel
./script/build_and_run.sh --build-only
./script/build_and_run.sh --verify
COINCIDE_LIVE_CODEX=1 swift test --filter installedCodexHandshakeAndModelDiscovery
COINCIDE_LIVE_CODEX_HISTORY=1 swift test --no-parallel --filter installedCodexNativeHistoryForkAndRewindThroughEngine
COINCIDE_LIVE_CODEX_STEERING=1 swift test --no-parallel --filter installedCodexNativePromptSteeringThroughEngineKeepsOneRunAndNativeTurn
COINCIDE_LIVE_CLAUDE=1 swift test --filter installedClaudeHandshakeAndModelDiscovery
COINCIDE_LIVE_CLAUDE_HISTORY=1 swift test --no-parallel --filter installedClaudeNativeHistoryForkAndDeferredRewindThroughEngine
COINCIDE_LIVE_ATTACHMENTS=1 swift test --filter installedProvidersReadAnImageAndFileThroughTheNativeEngine
COINCIDE_LIVE_ACP=1 swift test --filter installedOpenCodeACPHandshakeAndModelDiscovery
COINCIDE_LIVE_ACP_TURN=1 swift test --filter installedOpenCodeCompletesATurnThroughTheNativeEngine
COINCIDE_LIVE_ACP2=1 swift test --filter installedOpenCodeUsesTheVersionNegotiatedOnItsNativeConnection
```

The live discovery test performs a handshake and model listing only. It does not
run a model turn. The separate attachment test incurs real provider usage, sends
only generated image/file markers, and checks both installed providers through
the native engine. It permits only the generated file's Claude Read approval.
The separate Codex history smoke is off by default. Opting in uses existing
installed-CLI authentication, exactly two generated-marker prompts in a temporary
Git project/database, supervised permissions, and refusal of unexpected tool
approvals. It exercises the native engine's automatic checkpoint policy, reviewed
fork/rewind, independent paginated native readback, retained local audit/draft and
unchanged working bytes/index/HEAD. It archives only returned test-native IDs and
never lists or deletes provider conversations. Private evidence records IDs,
booleans and fixed failure categories without response text or credentials. Local
files are removed only after exact-ID archive cleanup and a bounded `lsof` check
finds no other process using the task directory; uncertain cleanup preserves it.
This proves local directory non-use, not that every provider descendant was reaped.
The installed-Codex history smoke has passed with both exact generated markers,
matching native heads, preserved local state, no unexpected tools/approvals, and
completed archive/local cleanup. A separate held-descriptor regression checks
that cleanup excludes the test's own handles but preserves a directory while a
foreign process holds it. These results do not establish hosted GUI verification,
other provider versions, or full provider parity.

The separate installed-Codex steering smoke is also off by default. It submits
one generated counting prompt, then one generated steering marker as soon as the
actual native turn becomes available. It requires a same-turn acknowledgement,
one local run, two correctly attributed user inputs, automatic checkpoints and
unchanged staged/working/untracked bytes and HEAD. An opening turn that ends too
soon fails honestly without retrying or resending. Unexpected tools and approvals
fail the check. Its private evidence and exact-ID native archive/local cleanup
follow the same restrictions as the history smoke.

The deterministic provider fixture contacts no external service
and does not exercise real provider authentication or prove full provider parity.
Tests create temporary isolated Git repositories and remove them after use. Git
synchronization tests use a local bare remote and two working copies; they do not
publish to any external repository or establish live SSH/HTTPS authentication.

The ACP discovery check creates an agent session and reads advertised models; it
does not submit a model turn. The separate ACP turn check sends a generated marker
and declines every tool permission. `COINCIDE_ACP_TEST_MODEL` can select one of
the installed agent's advertised models for that check. A passing agent/model
does not establish availability of the agent's other hosted model endpoints.
The installed OpenCode currently negotiates v1 when v2 is requested. Its passing
live check verifies fallback, not a live v2 server. The current v2 draft is tested
with deterministic peers, including acceptance/completion ordering, startup Stop,
background permissions, agent-initiated activity, and resume snapshots.

## Upstream attribution

T3 Code is copyright © 2026 T3 Tools Inc., MIT licensed. Its license is preserved
in `T3-CODE-LICENSE.txt`. Coincide is independent of T3 Tools Inc.
