# Validation record

## 2026-10-21 — Claude and native chat interface

- `COINCIDE_LIVE_CLAUDE=1 COINCIDE_LIVE_CODEX=1 swift test`: 19 tests passed.
  The live tests list models without running model turns. Offline Claude fixtures
  verify streaming/snapshot reconciliation, repeated turns, approval/decline,
  user questions, cancellation, interruption, provider failure, and old workspace
  decoding with the new provider/draft fields.
- Native UI QA verified the ChatGPT-style layout, new-conversation provider menu,
  rounded composer, hidden-by-default inspector, and live Claude text responses.
  Two consecutive real turns returned `COINCIDE_CLAUDE_SMOKE_OK`; a later turn
  after an app restart resumed the same Claude session and returned the marker
  from its conversation history. The resulting thread returned to `idle`.
- Startup initially timed out while macOS awaited Documents-folder consent for
  this machine's shared CLI instructions. Unified logging confirmed the TCC
  request and that ad-hoc rebuilds invalidated the previous code requirement.
  Consent was granted through the native macOS dialog. Local build scripting now
  uses an existing Apple Development identity when available; hosted CI retains
  ad-hoc signing. Strict signature verification passed. Release notarization and
  the oldest supported macOS version remain unverified.
- Provider logs record connection/request stages without prompts, file contents,
  raw provider frames, stderr, or credentials. Noisy temporary byte logs were
  removed after diagnosis. Initialization timeout messaging now identifies a
  possible macOS permission dialog and states that no model turn was submitted.
- Drafts persist per conversation and are cleared with the durable send intent,
  before provider startup, so startup latency does not leave a sent prompt in the
  composer. Failed sends remain visible in the saved conversation.
- The initial Swift CI and both refreshed dependency-update branches passed
  tests, native packaging, and signature verification on GitHub's macOS runner.
  Checkout v7 and cache v6 updates were merged only after those checks passed.

These checks establish basic Codex/Claude conversations, not complete provider
or T3 Code parity. Real tool approvals, all control methods, remote environments,
and long-running behavior still need broader end-to-end verification.

## 2026-10-21 — initial Swift runtime and native workspace

Implementation commit: `c5290b7b6cc2cfa0e8d9f4537bf8e2d6a2fa3ad8`.
Local toolchain: Apple Swift 6.4, Xcode 27.1, Apple Silicon macOS 27.

- `COINCIDE_LIVE_CODEX=1 swift test`: 14 Swift Testing tests passed, including
  the optional installed-Codex handshake/model-discovery check. The preliminary
  XCTest runner reports zero tests because the actual suite uses Swift Testing;
  the Swift Testing summary is the authoritative test count.
- `./script/build_and_run.sh --verify`: built, packaged, and launched Coincide.
- `codesign --verify --strict dist/Coincide.app`: passed for the ad-hoc signed
  development bundle. This does not establish Developer ID signing/notarization.
- Native UI inspection confirmed the empty state, Add Project panel, project
  folder open events, new thread, supervised permission selection, composer,
  source-control inspector, and displayed repository changes.
- A real Codex turn was sent through the native composer with the prompt
  `Respond with exactly COINCIDE_NATIVE_SMOKE_OK. Do not use tools or change files.`
  The native transcript displayed `COINCIDE_NATIVE_SMOKE_OK`. The database
  persisted both user and assistant messages and returned the thread to `idle`.
- The Add Project panel was changed from a synchronous modal loop to an
  asynchronous AppKit panel after accessibility input exposed a responsiveness
  issue. Project folder opening was also verified through Launch Services.
- Process/protocol tests exposed and fixed pipe buffering and thread-pool
  starvation issues. File containment tests exposed and fixed symlink-parent
  resolution when the final path does not yet exist.

This is evidence for the initial implementation only. It does not establish
complete T3 Code parity, all-provider reliability, live tool/approval behavior,
remote support, long-running stability, accessibility completeness, or support
on the oldest declared macOS version. CI results remain separate live evidence.
