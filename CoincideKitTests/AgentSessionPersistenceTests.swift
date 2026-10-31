import Darwin
import Foundation
import Testing

@testable import CoincideKit

private func scratch(_ name: String) -> URL {
    FileManager.default.temporaryDirectory.appendingPathComponent("coincide-\(name)-\(UUID().uuidString)", isDirectory: true)
}

private func info(_ key: AgentSessionKey, live: Bool) -> AgentHostSessionInfo {
    AgentHostSessionInfo(
        key: key, isLive: live, sessionID: "s1", supportsSteering: false, hasBackgroundWork: false, lastSequence: 3,
        acknowledgedSequence: 1, turnWasActiveAtAcknowledged: false, isTurnActive: live, pendingApprovals: [],
        pendingQuestions: [])
}

/// Holds a lock file from another process, as another app or host would: `perl` takes the flock and waits.
private final class LockHolder {
    let process = Process()

    init(_ file: URL) throws {
        process.executableURL = URL(fileURLWithPath: "/usr/bin/perl")
        process.arguments = [
            "-e", #"use Fcntl qw(:flock O_RDWR O_CREAT); sysopen(F, $ARGV[0], O_RDWR|O_CREAT) or die; flock(F, LOCK_EX) or die; print "locked\n"; $|=1; sleep 60;"#,
            file.path,
        ]
        let output = Pipe()
        process.standardOutput = output
        try process.run()
        // Until it says it holds the lock.
        _ = output.fileHandleForReading.availableData
    }

    /// Kills it, as a crash would: nothing lets go of the lock but the kernel.
    func kill() {
        process.terminate()
        process.waitUntilExit()
    }
}

// MARK: - Attach or resume

struct AgentSessionRouteTests {
    private let key = AgentSessionKey(threadID: UUID(), provider: .claude)

    @Test func aSessionTheHostRunsIsAttachedToNeverResumed() {
        #expect(AgentSessionRoute.decide(host: .connected(info(key, live: true)), runningElsewhere: false) == .attach)
        // Whatever the locks say: the connected host's view of its own session is what counts.
        #expect(AgentSessionRoute.decide(host: .connected(info(key, live: true)), runningElsewhere: true) == .attach)
    }

    @Test func anEndedSessionIsReplayedAndResumedOnlyLater() {
        #expect(AgentSessionRoute.decide(host: .connected(info(key, live: false)), runningElsewhere: false) == .replayLog)
    }

    @Test func aConnectedHostWithNothingStartsIt() {
        #expect(AgentSessionRoute.decide(host: .connected(nil), runningElsewhere: false) == .startInHost)
    }

    @Test func aHostBeingConnectedToIsWaitedFor() {
        #expect(AgentSessionRoute.decide(host: .connecting, runningElsewhere: false) == .waitForHost)
        #expect(AgentSessionRoute.decide(host: .connecting, runningElsewhere: true) == .waitForHost)
    }

    /// The bug of 1 Nov 2026: the app could not reach the host that still ran the session, and resumed it in-app.
    @Test func withoutTheHostASessionRunningElsewhereIsNeverStartedAgain() {
        #expect(AgentSessionRoute.decide(host: .unavailable, runningElsewhere: true) == .runningElsewhere)
        #expect(AgentSessionRoute.decide(host: .unavailable, runningElsewhere: false) == .startInApp)
    }
}

// MARK: - Locks

@MainActor
struct AgentSessionLockTests {
    private let directory = scratch("locks")
    private let key = AgentSessionKey(threadID: UUID(), provider: .codex)

    private func owner(_ role: AgentSessionOwner.Role) -> AgentSessionOwner { AgentSessionOwner(role: role, build: "7") }

    @Test func oneOwnerAtATime() throws {
        let host = AgentSessionLocks(directory: directory)
        let app = AgentSessionLocks(directory: directory)
        guard case .acquired(let lease) = host.acquire(key, sessionID: nil, owner: owner(.host)) else {
            Issue.record("The first owner gets the lock")
            return
        }
        guard case .heldElsewhere(let other) = app.acquire(key, sessionID: nil, owner: owner(.app)) else {
            Issue.record("A second owner is refused")
            return
        }
        #expect(other?.role == .host)
        #expect(other?.build == "7")
        #expect(app.owner(of: key)?.role == .host)
        // Its own lock is not "elsewhere" to the one holding it.
        #expect(host.owner(of: key) == nil)
        #expect(app.sessionsRunningElsewhere().keys.map(\.self) == [key])

        lease.release()
        #expect(app.owner(of: key) == nil)
        guard case .acquired = app.acquire(key, sessionID: nil, owner: owner(.app)) else {
            Issue.record("Free again once released")
            return
        }
    }

    /// The same provider session can't run under two threads, or under one thread in two processes.
    @Test func theProviderSessionIsLockedOnceItsIDIsKnown() {
        let host = AgentSessionLocks(directory: directory)
        let app = AgentSessionLocks(directory: directory)
        guard case .acquired(let lease) = host.acquire(key, sessionID: nil, owner: owner(.host)) else { return }
        #expect(lease.claim(sessionID: "native-1"))
        #expect(app.owner(ofSession: "native-1", provider: .codex)?.sessionID == "native-1")
        let otherThread = AgentSessionKey(threadID: UUID(), provider: .codex)
        guard case .heldElsewhere = app.acquire(otherThread, sessionID: "native-1", owner: owner(.app)) else {
            Issue.record("Resuming a provider session that runs elsewhere is refused")
            return
        }
        // Refused, it holds nothing of the other thread.
        #expect(host.owner(of: otherThread) == nil)
        lease.release()
        #expect(app.owner(ofSession: "native-1", provider: .codex) == nil)
    }

    /// A lock is released by the kernel when its process dies, so a crash never leaves a session locked forever.
    @Test func anotherProcessHoldsTheLockUntilItDies() throws {
        let locks = AgentSessionLocks(directory: directory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let holder = try LockHolder(directory.appendingPathComponent(AgentSessionLocks.keyFileName(key)))
        guard case .heldElsewhere = locks.acquire(key, sessionID: nil, owner: owner(.app)) else {
            holder.kill()
            Issue.record("A live process's lock is respected")
            return
        }
        #expect(locks.owner(of: key) != nil)
        holder.kill()
        #expect(locks.owner(of: key) == nil)
        guard case .acquired = locks.acquire(key, sessionID: nil, owner: owner(.app)) else {
            Issue.record("Free once its process is gone")
            return
        }
    }

    @Test func theHostLockSaysAHostRuns() {
        let host = AgentSessionLocks(directory: directory)
        let app = AgentSessionLocks(directory: directory)
        #expect(app.runningHost() == nil)
        let lease = host.acquireHostLock(build: "9")
        #expect(app.runningHost()?.build == "9")
        #expect(host.runningHost() == nil)
        // One host at a time.
        #expect(AgentSessionLocks(directory: directory).acquireHostLock(build: "10") == nil)
        lease?.release()
        #expect(app.runningHost() == nil)
    }

    @Test func anUnusableFolderDoesNotStopAgents() throws {
        let file = directory.appendingPathExtension("file")
        try Data().write(to: file)
        guard case .unavailable = AgentSessionLocks(directory: file).acquire(key, sessionID: nil, owner: owner(.app)) else {
            Issue.record("A folder that can't be made is reported, not taken for a held lock")
            return
        }
    }
}

// MARK: - The host's lock

@MainActor
struct AgentHostLockTests {
    private let directory = scratch("host-lock")
    private let provider = ScriptedProvider(kind: .claude)
    private let key = AgentSessionKey(threadID: UUID(), provider: .claude)

    private var locksDirectory: URL { directory.appendingPathComponent("locks") }

    private func makeCore() -> AgentHostCore {
        AgentHostCore(
            logDirectory: directory, build: "1", version: "1.0", locks: AgentSessionLocks(directory: locksDirectory)
        ) { [provider] launch, _ in provider.makeSession(launch) }
    }

    private func launch(resume: String? = nil) -> AgentLaunch {
        AgentLaunch(
            provider: .claude, executable: URL(fileURLWithPath: "/bin/sh"), environment: [:],
            workingDirectory: URL(fileURLWithPath: "/tmp"), resumeSessionID: resume,
            selection: ModelSelection(provider: .claude, modelID: "m"), accessMode: .approval, interactionMode: .build)
    }

    private func start(_ core: AgentHostCore, _ key: AgentSessionKey, resume: String? = nil, from client: AgentHostCore.Client)
        async -> AgentHostReply
    {
        await core.perform(
            .start(key: key, launch: launch(resume: resume), account: .defaultAccount(for: .claude),
                thread: AgentHostThreadInfo(title: "T", projectName: nil)), from: client)
    }

    /// A second launch request for a running session attaches to it: still one process.
    @Test func aSecondStartAttaches() async throws {
        let core = makeCore()
        let app = InProcessAgentHostTransport(core: core)
        let client = core.connect(app)
        guard case .started(let first) = await start(core, key, from: client) else { Issue.record("started"); return }
        #expect(first.attachedToRunning == nil)
        guard case .started(let second) = await start(core, key, resume: "claude-1", from: client) else {
            Issue.record("attached"); return
        }
        #expect(second.attachedToRunning == true)
        #expect(provider.sessions.count == 1)
        // Others can see the host runs it, by thread and by provider session.
        let app2 = AgentSessionLocks(directory: locksDirectory)
        #expect(app2.owner(of: key)?.role == .host)
        #expect(app2.owner(ofSession: "claude-1", provider: .claude)?.role == .host)
    }

    @Test func aProviderSessionRunningForAnotherThreadIsRefused() async throws {
        let core = makeCore()
        let client = core.connect(InProcessAgentHostTransport(core: core))
        _ = await start(core, key, resume: "shared", from: client)
        let other = AgentSessionKey(threadID: UUID(), provider: .claude)
        guard case .failure(let message) = await start(core, other, resume: "shared", from: client) else {
            Issue.record("refused"); return
        }
        #expect(message == AgentHostError.runningInAnotherThread.localizedDescription)
        #expect(provider.sessions.count == 1)
    }

    /// The app runs the session in-process (the host was unreachable); the host must not start a second one.
    @Test func aSessionTheAppRunsIsRefused() async throws {
        let app = AgentSessionLocks(directory: locksDirectory)
        guard case .acquired(let lease) = app.acquire(key, sessionID: nil, owner: AgentSessionOwner(role: .app, build: "1")) else {
            Issue.record("app lock"); return
        }
        let core = makeCore()
        let client = core.connect(InProcessAgentHostTransport(core: core))
        guard case .failure(let message) = await start(core, key, from: client) else { Issue.record("refused"); return }
        #expect(message == AgentHostError.runningElsewhere(.app).localizedDescription)
        #expect(provider.sessions.isEmpty)
        lease.release()
        guard case .started = await start(core, key, from: client) else { Issue.record("free once the app let go"); return }
    }

    @Test func theLockGoesWithTheSession() async throws {
        let core = makeCore()
        let client = core.connect(InProcessAgentHostTransport(core: core))
        _ = await start(core, key, from: client)
        let others = AgentSessionLocks(directory: locksDirectory)
        #expect(others.owner(of: key) != nil)
        try #require(provider.last).emit(.sessionExited(error: nil))
        #expect(others.owner(of: key) == nil)
        #expect(others.owner(ofSession: "claude-1", provider: .claude) == nil)
    }

    /// A second host process (one macOS started outside launchd) leaves alone the logs of sessions another host runs:
    /// ending them would end turns that go on.
    @Test func anotherHostsRunningSessionsAreNotEnded() async throws {
        let first = makeCore()
        let client = first.connect(InProcessAgentHostTransport(core: first))
        _ = await start(first, key, from: client)
        try #require(provider.last).emit(.assistantTextDelta(itemID: "a", delta: "working"))
        let second = makeCore()
        #expect(second.sessionInfos.isEmpty)
        let events = AgentEventLogStore(directory: directory).open(key).backlog.compactMap(\.event)
        #expect(!events.contains { if case .sessionExited = $0 { true } else { false } })
    }
}

// MARK: - The app's in-process sessions

@MainActor
struct InAppSessionLockTests {
    private let directory = scratch("in-app-locks")
    private let store: AppStore
    private let claude = ScriptedProvider(kind: .claude)
    private let runner: ThreadRunner
    private let threadID: UUID

    init() {
        store = AppStore(directory: directory.appendingPathComponent("data"))
        store.updateSettings { $0.checkpointsEnabled = false }
        runner = ThreadRunner(store: store, registry: ProviderRegistry(store: store, providers: [claude]))
        runner.sessionLocks = AgentSessionLocks(directory: directory.appendingPathComponent("locks"))
        let project = store.addProject(at: URL(fileURLWithPath: "/tmp"))
        threadID = store.createThread(in: project.id, selection: ModelSelection(provider: .claude, modelID: "m")).id
        claude.configure = { $0.onSend = { session, _ in session.emit(.turnCompleted(.completed)) } }
    }

    private var key: AgentSessionKey { AgentSessionKey(threadID: threadID, provider: .claude) }
    private var lastError: String? { store.thread(threadID)?.items.last { $0.kind == .error }?.text }

    @Test func aSessionTheHostRunsIsNotResumedInTheApp() async throws {
        let host = AgentSessionLocks(directory: directory.appendingPathComponent("locks"))
        guard case .acquired(let lease) = host.acquire(key, sessionID: nil, owner: AgentSessionOwner(role: .host, build: "1")) else {
            Issue.record("host lock"); return
        }
        await runner.send(threadID: threadID, text: "hi")
        #expect(claude.sessions.isEmpty)
        #expect(lastError == AgentHostError.runningElsewhere(.host).localizedDescription)
        lease.release()
        await runner.send(threadID: threadID, text: "again")
        #expect(claude.sessions.count == 1)
    }

    @Test func theRouteKeepsASessionRunningElsewhereFromStarting() async throws {
        runner.sessionRoute = { _ in .runningElsewhere }
        await runner.send(threadID: threadID, text: "hi")
        #expect(claude.sessions.isEmpty)
        #expect(lastError == AgentHostError.runningElsewhere(.host).localizedDescription)
    }

    @Test func anInAppSessionHoldsItsLockUntilItEnds() async throws {
        await runner.send(threadID: threadID, text: "hi")
        let others = AgentSessionLocks(directory: directory.appendingPathComponent("locks"))
        #expect(others.owner(of: key)?.role == .app)
        #expect(others.owner(ofSession: "claude-1", provider: .claude)?.role == .app)
        runner.shutdown(threadID: threadID, provider: .claude)
        #expect(others.owner(of: key) == nil)
        await runner.send(threadID: threadID, text: "again")
        #expect(others.owner(of: key) != nil)
        try #require(claude.last).emit(.sessionExited(error: nil))
        #expect(others.owner(of: key) == nil)
    }
}

// MARK: - A legacy host

@MainActor
struct AgentHostLegacyOwnershipTests {
    private let directory = scratch("legacy")

    @Test func unfinishedLogsCountOnlyWhileAHostWithoutLocksRuns() {
        let running = AgentSessionKey(threadID: UUID(), provider: .claude)
        let ended = AgentSessionKey(threadID: UUID(), provider: .codex)
        let logs = AgentEventLogStore(directory: directory)
        logs.open(running).append(.assistantTextDelta(itemID: "a", delta: "x"), turnActive: true)
        let endedLog = logs.open(ended)
        endedLog.append(.notice("n"), turnActive: false)
        endedLog.append(.sessionExited(error: nil), turnActive: false)
        #expect(AgentHostLegacyOwnership.unfinishedKeys(in: directory) == [running])

        let ownership = AgentSessionOwnership(hostDirectory: directory)
        var hosts: [pid_t] = []
        ownership.runningHosts = { hosts }
        // No host runs: its logs are an earlier run's, which the next host ends.
        #expect(ownership.ownerElsewhere(of: running) == nil)
        hosts = [4242]
        #expect(ownership.ownerElsewhere(of: running)?.pid == 4242)
        #expect(ownership.ownerElsewhere(of: ended) == nil)
        #expect(ownership.threadsRunningElsewhere() == [running.threadID])
        // A host that takes the locks is judged by them alone.
        let lease = AgentSessionLocks(directory: directory.appendingPathComponent("locks")).acquireHostLock(build: "2")
        #expect(ownership.ownerElsewhere(of: running) == nil)
        lease?.release()
    }

    @Test func findsHostExecutablesByBundleID() throws {
        let bundle = directory.appendingPathComponent("CoincideAgentHost.app/Contents", isDirectory: true)
        try FileManager.default.createDirectory(at: bundle.appendingPathComponent("MacOS"), withIntermediateDirectories: true)
        try (["CFBundleIdentifier": "com.example.agent-host"] as NSDictionary).write(to: bundle.appendingPathComponent("Info.plist"))
        let executable = bundle.appendingPathComponent("MacOS/CoincideAgentHost").path
        #expect(AgentHostLegacyOwnership.isHostExecutable(executable, bundleID: "com.example.agent-host"))
        #expect(!AgentHostLegacyOwnership.isHostExecutable(executable, bundleID: "com.example.other"))
        #expect(!AgentHostLegacyOwnership.isHostExecutable("/bin/sh", bundleID: "com.example.agent-host"))
        #expect(AgentHostLegacyOwnership.executablePath(of: getpid()) != nil)
    }
}

// MARK: - The host outliving the app, with a real agent process

/// The agent host's engine with a real agent process (a shell ACP agent) and the app quitting and coming back
/// mid-turn. The process must keep running, start once, and the reply must read on without a gap.
@MainActor
struct AgentHostSurvivesTheAppTests {
    private let directory: URL
    private let store: AppStore
    private let registry: ProviderRegistry
    private let core: AgentHostCore
    private let threadID: UUID
    private let starts: URL
    private let release: URL

    init() throws {
        directory = try acpTemporaryDirectory()
        starts = directory.appendingPathComponent("starts")
        release = directory.appendingPathComponent("release")
        let script = directory.appendingPathComponent("fake-agent")
        // Answers a prompt with "one ", then "two " once released, then "three", from a background job so it keeps
        // reading. Each start appends its pid to `starts`.
        try #"""
            #!/bin/sh
            echo $$ >> '\#(starts.path)'
            while IFS= read -r line; do
              id=$(printf '%s' "$line" | sed -n 's/^{"id":\([0-9]*\),.*/\1/p')
              case "$line" in
                *'"method":"initialize"'*) printf '{"jsonrpc":"2.0","id":%s,"result":{"protocolVersion":1,"agentCapabilities":{}}}\n' "$id" ;;
                *'"method":"session/new"'*) printf '{"jsonrpc":"2.0","id":%s,"result":{"sessionId":"shell-1"}}\n' "$id" ;;
                *'"method":"session/prompt"'*)
                  (
                    chunk() { printf '{"jsonrpc":"2.0","method":"session/update","params":{"sessionId":"shell-1","update":{"sessionUpdate":"agent_message_chunk","content":{"type":"text","text":"%s"}}}}\n' "$1"; }
                    chunk "one "
                    while [ ! -f '\#(release.path)' ]; do sleep 0.05; done
                    chunk "two "
                    sleep 0.2
                    chunk "three"
                    printf '{"jsonrpc":"2.0","id":%s,"result":{"stopReason":"end_turn"}}\n' "$id"
                  ) & ;;
              esac
            done
            """#.write(to: script, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script.path)

        store = AppStore(directory: directory.appendingPathComponent("data"))
        store.updateSettings {
            $0.checkpointsEnabled = false
            $0.providers[.grok] = ProviderSettings(executablePath: script.path)
        }
        registry = ProviderRegistry(store: store, providers: [ScriptedProvider(kind: .grok)])
        core = AgentHostCore(
            logDirectory: directory.appendingPathComponent("agent-host"), build: "1", version: "1.0",
            locks: AgentSessionLocks(directory: directory.appendingPathComponent("agent-host/locks"))
        ) { launch, _ in
            var launch = launch
            launch.environment["PATH"] = "/usr/bin:/bin"
            return ACPSession(launch: launch, flavor: ACPPlainFlavor())
        }
        let project = store.addProject(at: directory)
        threadID = store.createThread(in: project.id, selection: ModelSelection(provider: .grok, modelID: "default")).id
    }

    private struct AppRun {
        let runner: ThreadRunner
        let transport: InProcessAgentHostTransport
        let client: AgentHostClient
    }

    private func launchApp() -> AppRun {
        let runner = ThreadRunner(store: store, registry: registry)
        let transport = InProcessAgentHostTransport(core: core)
        let client = AgentHostClient(transport: transport)
        runner.hostedSession = { [weak client] threadID, launch, account in
            client?.makeSession(
                key: AgentSessionKey(threadID: threadID, provider: launch.provider), launch: launch, account: account,
                thread: { AgentHostThreadInfo(title: "Thread", projectName: nil) })
        }
        return AppRun(runner: runner, transport: transport, client: client)
    }

    private var replies: [String] {
        (store.thread(threadID)?.items ?? []).filter { $0.kind == .assistant }.map(\.text)
    }

    private var agentPIDs: [pid_t] {
        ((try? String(contentsOf: starts, encoding: .utf8)) ?? "").split(separator: "\n").compactMap { pid_t($0) }
    }

    @Test func theTurnGoesOnWhileTheAppIsGoneAndReadsOnWithoutAGap() async throws {
        defer {
            for pid in agentPIDs { kill(pid, SIGKILL) }
            try? FileManager.default.removeItem(at: directory)
        }
        let first = launchApp()
        await first.runner.send(threadID: threadID, text: "count")
        await acpWaitUntil("the first chunk", timeout: .seconds(10)) { replies.joined().contains("one") }
        let pid = try #require(agentPIDs.first)

        // The app quits mid-turn: what `applicationWillTerminate` does for hosted sessions. (Not `shutdownAll`: it
        // also stops this process's child processes, which in a test include the in-process host's agent.)
        first.runner.detachHostedSessions()
        first.client.flushAcknowledgements()
        first.transport.invalidate()
        #expect(kill(pid, 0) == 0)
        #expect(core.isBusy)
        // While the app is away nobody else may start it: the host holds it.
        let key = AgentSessionKey(threadID: threadID, provider: .grok)
        #expect(AgentSessionLocks(directory: directory.appendingPathComponent("agent-host/locks")).owner(of: key)?.role == .host)

        // The agent goes on with no app attached; the host logs it.
        FileManager.default.createFile(atPath: release.path, contents: nil)
        await acpWaitUntil("the turn to end in the host", timeout: .seconds(10)) { !core.isBusy }
        #expect(replies.joined() == "one ")

        // Relaunch: the session is attached to and its log replayed, not resumed.
        let second = launchApp()
        let welcome = try await second.transport.hello(AgentHostHello(build: "1", version: "1.0", notifiesWhileAppIsClosed: false))
        let hosted = try #require(welcome.sessions.first)
        #expect(AgentSessionRoute.decide(host: .connected(hosted), runningElsewhere: false) == .attach)
        let session = second.client.adopt(hosted, thread: { AgentHostThreadInfo(title: "Thread", projectName: nil) })
        #expect(second.runner.adopt(session, threadID: threadID, turnWasActive: hosted.turnWasActiveAtAcknowledged))
        await second.client.attach(session)
        await acpWaitUntil("the rest of the reply", timeout: .seconds(10)) { replies.joined() == "one two three" }
        #expect(replies.count == 1)
        #expect(!second.runner.isRunning(threadID))
        // One process, started once, still the one answering.
        #expect(agentPIDs == [pid])
        #expect(kill(pid, 0) == 0)
        second.runner.detachHostedSessions()
        second.transport.invalidate()
    }
}

// MARK: - Host upgrades

/// A new build installed while a host runs: the host runs from its own copy (`AgentHostRuntime`), so the update
/// never changes its files, and copies of builds no host runs any more go.
struct AgentHostRuntimeTests {
    private let root = scratch("runtime")

    /// A fake Coincide.app with a host and a framework, `version` naming their contents.
    private func makeApp(_ version: String) throws -> AgentHostRuntime.Source {
        let app = root.appendingPathComponent("install-\(version)/Coincide.app", isDirectory: true)
        let host = app.appendingPathComponent("Contents/Helpers/CoincideAgentHost.app", isDirectory: true)
        let kit = app.appendingPathComponent("Contents/Frameworks/CoincideKit.framework", isDirectory: true)
        try FileManager.default.createDirectory(at: host.appendingPathComponent("Contents/MacOS"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: kit.appendingPathComponent("Versions/A"), withIntermediateDirectories: true)
        try Data(version.utf8).write(to: host.appendingPathComponent("Contents/MacOS/CoincideAgentHost"))
        try Data(version.utf8).write(to: kit.appendingPathComponent("Versions/A/CoincideKit"))
        try FileManager.default.createSymbolicLink(atPath: kit.appendingPathComponent("Versions/Current").path, withDestinationPath: "A")
        return try #require(AgentHostRuntime.Source.bundled(hostBundle: host, build: version))
    }

    private var runtime: URL { root.appendingPathComponent("runtime", isDirectory: true) }
    private let valid: AgentHostRuntime.Validator = { _ in true }

    /// What a bundle holds stands in for its cdhash.
    private let identity: AgentHostRuntime.Identity = { bundle in
        let files = ["Contents/MacOS/CoincideAgentHost", "Versions/A/CoincideKit"]
        return files.lazy.compactMap { try? String(contentsOf: bundle.appendingPathComponent($0), encoding: .utf8) }.first
    }

    @Test func findsTheHostInsideTheApp() throws {
        let source = try makeApp("5")
        #expect(source.frameworks.map(\.lastPathComponent) == ["CoincideKit.framework"])
        #expect(source.appBundle.lastPathComponent == "Coincide.app")
        // A copy is not inside an app, so it never copies itself again.
        let copy = try #require(AgentHostRuntime.prepare(source, runtimeRoot: runtime, validate: valid, identity: identity))
        let copiedHost = copy.deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        #expect(AgentHostRuntime.Source.bundled(hostBundle: copiedHost, build: "5") == nil)
    }

    @Test func runsFromACopyTheUpdateCannotTouch() throws {
        let old = try makeApp("5")
        let executable = try #require(AgentHostRuntime.prepare(old, runtimeRoot: runtime, validate: valid, identity: identity))
        let folder = AgentHostRuntime.runtimeFolder(ofExecutable: executable)
        #expect(try String(contentsOf: executable, encoding: .utf8) == "5")
        // Laid out as in the app, so the host's rpath finds the framework.
        let rpath = executable.deletingLastPathComponent().appendingPathComponent("../../../../Frameworks/CoincideKit.framework/Versions/Current/CoincideKit")
        #expect(try String(contentsOf: rpath.standardizedFileURL, encoding: .utf8) == "5")
        AgentHostRuntime.markLaunched(runtimeFolder: folder)
        let inUse = try #require(AgentHostRuntime.holdInUse(runtimeFolder: folder))
        defer { close(inUse) }

        // The update replaces Coincide.app; the running host's copy stays as it was.
        try FileManager.default.removeItem(at: old.appBundle)
        let new = try makeApp("6")
        let next = try #require(AgentHostRuntime.prepare(new, runtimeRoot: runtime, validate: valid, identity: identity))
        #expect(next != executable)
        #expect(try String(contentsOf: executable, encoding: .utf8) == "5")
        #expect(try String(contentsOf: next, encoding: .utf8) == "6")

        // Copies a host still runs from stay; the rest go.
        let newFolder = AgentHostRuntime.runtimeFolder(ofExecutable: next)
        AgentHostRuntime.prune(runtimeRoot: runtime, keeping: newFolder.lastPathComponent)
        #expect(FileManager.default.fileExists(atPath: executable.path))
        close(inUse)
        var unregistered: [String] = []
        AgentHostRuntime.prune(runtimeRoot: runtime, keeping: newFolder.lastPathComponent) { unregistered.append($0.lastPathComponent) }
        #expect(!FileManager.default.fileExists(atPath: folder.path))
        #expect(unregistered == ["CoincideAgentHost.app"])
        #expect(FileManager.default.fileExists(atPath: next.path))
    }

    @Test func aGoodCopyIsReusedAndABadOneReplaced() throws {
        let source = try makeApp("5")
        let first = try #require(AgentHostRuntime.prepare(source, runtimeRoot: runtime, validate: valid, identity: identity))
        AgentHostRuntime.markLaunched(runtimeFolder: AgentHostRuntime.runtimeFolder(ofExecutable: first))
        let marker = first.deletingLastPathComponent().appendingPathComponent("kept")
        try Data().write(to: marker)
        #expect(AgentHostRuntime.prepare(source, runtimeRoot: runtime, validate: valid, identity: identity) == first)
        #expect(FileManager.default.fileExists(atPath: marker.path))
        // A copy whose signature no longer checks out is made again.
        var checks = 0
        let failingOnce: AgentHostRuntime.Validator = { _ in
            checks += 1
            return checks > 1
        }
        #expect(AgentHostRuntime.prepare(source, runtimeRoot: runtime, validate: failingOnce, identity: identity) == first)
        #expect(!FileManager.default.fileExists(atPath: marker.path))
    }

    @Test func runsFromTheBundleWhenTheCopyIsNotValid() throws {
        let source = try makeApp("5")
        #expect(AgentHostRuntime.prepare(source, runtimeRoot: runtime, validate: { _ in false }, identity: identity) == nil)
        #expect(AgentHostRuntime.prepare(source, runtimeRoot: runtime, validate: valid, identity: { _ in nil }) == nil)
        let leftovers = (try? FileManager.default.contentsOfDirectory(atPath: runtime.path)) ?? []
        #expect(leftovers.isEmpty)
    }

    /// A copy that was started but died before the app reached it is not tried again, so a host never fails on
    /// every launch.
    @Test func aCopyThatFailedToStartIsNotTriedAgain() throws {
        let source = try makeApp("5")
        let executable = try #require(AgentHostRuntime.prepare(source, runtimeRoot: runtime, validate: valid, identity: identity))
        let folder = AgentHostRuntime.runtimeFolder(ofExecutable: executable)
        // The attempt was made by a process that is gone now.
        let dead = Process()
        dead.executableURL = URL(fileURLWithPath: "/usr/bin/true")
        try dead.run()
        dead.waitUntilExit()
        try "\(dead.processIdentifier)".write(to: folder.appendingPathComponent(".launch-attempt"), atomically: true, encoding: .utf8)
        #expect(AgentHostRuntime.prepare(source, runtimeRoot: runtime, validate: valid, identity: identity) == nil)
        #expect(AgentHostRuntime.prepare(source, runtimeRoot: runtime, validate: valid, identity: identity) == nil)
        // Another build gets its own chance.
        #expect(AgentHostRuntime.prepare(try makeApp("6"), runtimeRoot: runtime, validate: valid, identity: identity) != nil)
    }
}

/// What happens to running agents when the app is another build than the host.
@MainActor
struct AgentHostUpgradeTests {
    private let directory = scratch("upgrade")
    private let claude = ScriptedProvider(kind: .claude)

    /// An older host the new app can talk to keeps its agents, and exits only once nothing runs: a running turn is
    /// never stopped. Its sessions' locks go with it, so the new host can then resume them from history.
    @Test func anOlderHostKeepsItsTurnsAndRetiresOnceIdle() async throws {
        let locks = directory.appendingPathComponent("locks")
        let old = AgentHostCore(logDirectory: directory, build: "1", version: "1.0", locks: AgentSessionLocks(directory: locks)) {
            [claude] launch, _ in claude.makeSession(launch)
        }
        var exited = false
        old.onExit = { exited = true }
        let transport = InProcessAgentHostTransport(core: old)
        let key = AgentSessionKey(threadID: UUID(), provider: .claude)
        _ = try await transport.perform(
            .start(key: key, launch: AgentLaunch(
                provider: .claude, executable: URL(fileURLWithPath: "/bin/sh"), environment: [:],
                workingDirectory: URL(fileURLWithPath: "/tmp"), resumeSessionID: nil,
                selection: ModelSelection(provider: .claude, modelID: "m"), accessMode: .approval, interactionMode: .build),
                account: .defaultAccount(for: .claude), thread: AgentHostThreadInfo(title: "", projectName: nil)))
        _ = try await transport.perform(.send(key: key, input: AgentTurnInput(text: "go", imagePaths: [],
            selection: ModelSelection(provider: .claude, modelID: "m"), accessMode: .approval, interactionMode: .build),
            thread: AgentHostThreadInfo(title: "", projectName: nil)))

        let hello = AgentHostHello(build: "2", version: "2.0", notifiesWhileAppIsClosed: false)
        let welcome = try await transport.hello(hello)
        #expect(AgentHostCompatibility.evaluate(app: hello, host: welcome) == .useAndReplaceWhenIdle)
        transport.retireWhenIdle()
        #expect(!exited)
        let agent = try #require(claude.last)
        #expect(!agent.isShutDown)
        let others = AgentSessionLocks(directory: locks)
        #expect(others.owner(of: key) != nil)

        agent.emit(.turnCompleted(.completed))
        #expect(exited)
        #expect(agent.isShutDown)
        #expect(others.owner(of: key) == nil)
        // The app still attached learned the session ended, so it resumes it in the new host next time.
        let ended = AgentEventLogStore(directory: directory).open(key).backlog.last?.event
        #expect(ended == .sessionExited(error: nil))
    }
}
