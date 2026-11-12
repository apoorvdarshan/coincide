# Agent sessions across quits, relaunches and updates

> Historical Swift desktop documentation. The active desktop implementation is Rust.

Coincide runs agents (Claude Code, Codex, Cursor, Grok, OpenCode, Antigravity) in its background agent host, `CoincideAgentHost`: a LaunchAgent (`com.apoorvdarshan.coincide.agent-host`) that launchd starts on demand and that the app talks to over XPC. The host owns the agent processes and logs their events, so agents keep working while Coincide is closed. This applies to every provider in the same way: the host and the app only see `AgentSession`s and `AgentEvent`s.

Sources: `CoincideKit/AgentHost/` (engine, protocol, locks, routing, runtime copies), `CoincideAgentHost/` (the host executable), `Coincide/App/AgentHostController.swift` (the app's side).

## Rules

1. **One process per session.** Every running session is locked, across processes, by the process that runs it (`AgentSessionLocks`): `flock(2)` on `agent-host/locks/thread-<thread>.<provider>.lock`, and on `session-<provider>-<hash>.lock` once the provider session ID is known. The kernel releases a lock when its process dies, so a held lock always means a live owner and a free one means nobody runs the session. The host refuses to start a session another process holds, the app refuses to run one in-process that the host holds, and a second start of a session the host already runs attaches to it (`attachedToRunning`).
2. **Attach, don't resume.** On relaunch the app takes up every session the host reports and replays its log (`AgentSessionRoute.attach`). It resumes from history (`--resume` and the like) only once nothing runs the session: the host has no live session for it, and no lock is held.
3. **Never kill a running turn silently.** The host exits only when nothing runs: no turn, no prompt waiting for an answer, no background work (subagents, long commands). If it crashes, the next host ends the logs it left with "The agent host stopped unexpectedly", which shows in the thread.

## Quit

The app detaches from its hosted sessions, tells the host how far it applied their events, and exits. Turns go on, subagents included, and the host keeps logging. Only sessions that run in the app (see below) stop; quitting asks first when any do.

## Relaunch

At launch, before any transcript is read, the app marks the threads whose sessions another process runs (from the locks), so their unfinished items are not settled. Then it says hello to the host (waiting at most 1.5 s) and adopts every session the host reports: live ones are attached to, ended ones have their log applied.

If the host doesn't answer, the app keeps trying, waiting 2 s, then 4 s, up to 30 s between attempts, instead of giving up until the next launch. Meanwhile a new turn waits up to 8 s for a host being connected to, then runs in the app; a thread whose session the host still runs fails the turn with an explanation rather than starting it a second time.

## Host upgrades

A new Coincide replaces Coincide.app while the old host may still run agents.

- **The host runs from its own copy.** Started from the bundle, the host copies its build (the host app and the frameworks it links, laid out as in Coincide.app) into `agent-host/runtime/<build>-<digest>` and `exec`s the copy, keeping the process launchd started. An update never changes a running host's files, so macOS keeps accepting its code signature and the new app can still talk to it. Each copy is checked against the team's signature, kept while a host runs from it, and removed once no host does. A copy that exits before the app ever reached it is not tried again; the host then runs from the bundle.
- **Same protocol:** the new app uses the old host, adopts its sessions, and asks it to exit once idle. Until then the old host also runs the new app's new sessions. Once idle it exits, stopping only idle agent processes (resumed from history on their next turn), and launchd starts the new build's host on the next message.
- **Incompatible protocol:** the old host's agents finish there, with their events logged, and the locks keep the app from starting them again. New sessions run in the app until the old host exits; the app checks every 30 s and then uses the new host, applying what the old one logged. Settings › General › Agents shows this state.
- **A host from before these copies** (builds up to 1 Nov 2026) still runs from inside the replaced bundle, so the new app can't accept its replies. The app asks it, with a message that carries no data, to exit once idle. It treats sessions whose logs haven't ended as running there while such a host process exists, and doesn't resume them. It connects to the new host once the old one is gone.

## When agents run in the app

When the host is turned off in Settings, the build is unsigned or a Debug build without `COINCIDE_AGENT_HOST=1`, Coincide isn't allowed in Login Items, the host is unreachable, or an incompatible host is still busy, sessions run in the app. They take the same locks, and stop when Coincide quits.
