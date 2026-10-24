import CryptoKit
import Darwin
import Foundation
import Testing
@testable import CoincideCore

/// Explicitly opt in with COINCIDE_LIVE_CODEX_HISTORY=1. This sends exactly two
/// tiny prompts using the installed CLI's existing authentication. No login,
/// credentials, user project, native thread list or provider setting is changed.
@Test(.timeLimit(.minutes(8)))
func installedCodexNativeHistoryForkAndRewindThroughEngine() async throws {
    guard ProcessInfo.processInfo.environment["COINCIDE_LIVE_CODEX_HISTORY"] == "1" else { return }
    guard let executable = ProcessChannel.findExecutable("codex") else { throw LiveHistorySmokeFailure("installed-cli-missing") }
    let manager = FileManager.default, testID = UUID()
    let temporary = manager.temporaryDirectory.appendingPathComponent("coincide-live-history-\(testID)", isDirectory: true)
        .standardizedFileURL.resolvingSymlinksInPath()
    let evidenceRoot = manager.temporaryDirectory.appendingPathComponent("coincide-live-history-evidence-\(testID)", isDirectory: true)
        .standardizedFileURL.resolvingSymlinksInPath()
    try manager.createDirectory(at: temporary, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
    try manager.createDirectory(at: evidenceRoot, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
    let evidence = try LiveHistorySmokeAudit(id: testID, url: evidenceRoot.appendingPathComponent("evidence.json"))
    let repository = temporary.appendingPathComponent("repository", isDirectory: true)
    let hooks = temporary.appendingPathComponent("empty-hooks", isDirectory: true)
    try manager.createDirectory(at: repository, withIntermediateDirectories: true)
    try manager.createDirectory(at: hooks, withIntermediateDirectories: true)
    let fixture = LiveHistoryGitFixture(repository: repository, hooks: hooks)
    var engine: WorkspaceEngine?
    var failure: (any Error)?
    do {
        try await evidence.stage("git-fixture")
        _ = try await fixture.git(["init", "-b", "main"])
        try Data("Coincide isolated tracked sentinel\n".utf8).write(to: repository.appendingPathComponent("harmless.txt"))
        _ = try await fixture.git(["add", "--", "harmless.txt"])
        _ = try await fixture.git(["commit", "-m", "Coincide isolated history smoke"])
        try Data("Coincide isolated untracked sentinel\n".utf8).write(to: repository.appendingPathComponent("untracked.txt"))
        let initialGitState = try await fixture.state()
        let project = WorkspaceProject(path: repository.path)
        var source = CodingThread(project: project)
        source.title = "Coincide history smoke \(testID)"; source.permission = .supervised
        // Empty model uses the CLI's configured default; automatic checkpoints
        // and the production checkpoint factory intentionally remain unchanged.
        let current = try WorkspaceEngine(url: temporary.appendingPathComponent("workspace.sqlite"), providerFactory: { thread in
            try LiveHistoryObservedSession(executable: executable, cwd: URL(fileURLWithPath: thread.workspacePath), audit: evidence)
        })
        engine = current
        _ = try await current.dispatch(.addProjectWithThread(project: project, thread: source))
        var runIDs: [UUID] = []
        for number in 1...2 {
            try await evidence.stage("turn-\(number)")
            let marker = "COINCIDE_HISTORY_\(testID.uuidString)_\(number)"
            let runID = UUID(); runIDs.append(runID)
            _ = try await current.dispatch(.submit(threadID: source.id,
                text: "Reply with exactly \(marker). Do not use tools, run commands, inspect files, browse, or change any state."), id: runID)
            try await liveHistoryWait(audit: evidence, seconds: 150) {
                let update = await current.current()
                guard update.error == nil else { throw LiveHistorySmokeFailure("engine-failure") }
                guard let thread = update.snapshot.threads.first(where: { $0.id == source.id }),
                      let run = thread.runHistory?.first(where: { $0.id == runID }) else { return false }
                if run.status.isTerminal && run.status != .completed { throw LiveHistorySmokeFailure("turn-not-completed") }
                return run.status == .completed && thread.activeRun == nil && thread.queuedTurns.isEmpty && thread.heldPostRunCheckpoint == nil
            }
            let completed = try liveHistoryThread(await current.current(), source.id)
            let matched = completed.visibleMessages.contains { $0.role == .assistant && $0.text.trimmingCharacters(in: .whitespacesAndNewlines) == marker && $0.runReference?.runID == runID }
            try liveHistoryRequire(matched, "synthetic-marker-mismatch")
            try await evidence.marker(number, matched: matched)
        }
        try await evidence.stage("review-and-fork")
        _ = try await current.dispatch(.editThread(source.id, .draft("Unsent synthetic draft \(testID)")))
        let beforeFork = try liveHistoryThread(await current.current(), source.id)
        let sourceNativeID = try liveHistoryValue(beforeFork.providerThreadID, "source-native-id-missing")
        let first = try liveHistoryValue(beforeFork.runHistory?.first(where: { $0.id == runIDs[0] }), "first-run-missing")
        let second = try liveHistoryValue(beforeFork.runHistory?.first(where: { $0.id == runIDs[1] }), "second-run-missing")
        let firstTurn = try liveHistoryValue(first.turnIDs.last, "first-native-turn-missing")
        let secondTurn = try liveHistoryValue(second.turnIDs.first, "second-native-turn-missing")
        try liveHistoryRequire(first.configuration.permission == .supervised && second.configuration.permission == .supervised,
                               "supervised-policy-not-captured")
        try liveHistoryRequire(first.checkpoints != nil && second.checkpoints != nil, "automatic-checkpoint-policy-not-captured")
        let fork = try await current.reviewConversationHistory(threadID: source.id, runID: first.id, kind: .forkAfterRun)
        try liveHistoryRequire(fork.reviewedHeadTurnID == second.turnIDs.last && fork.boundary == .throughTurn(firstTurn), "fork-reviewed-boundary-mismatch")
        _ = try await current.beginConversationHistory(fork, title: "Coincide synthetic fork \(testID)")
        try await liveHistoryWait(audit: evidence, seconds: 60) { try await liveHistoryApplied(current, operationID: fork.id) }
        let forkUpdate = await current.current(), forkOperation = try liveHistoryOperation(forkUpdate, fork.id)
        let targetID = try liveHistoryValue(fork.targetThreadID, "fork-target-missing")
        let target = try liveHistoryThread(forkUpdate, targetID)
        try liveHistoryRequire(try liveHistoryThread(forkUpdate, source.id) == beforeFork, "fork-changed-source")
        try liveHistoryRequire(target.messages == fork.prefix && target.draft.isEmpty && target.runHistory == nil && target.runtimeID == nil,
                               "fork-local-prefix-mismatch")
        let forkResult = try liveHistoryValue(forkOperation.result, "fork-result-missing")
        try liveHistoryRequire(forkResult.reference.nativeThreadID != sourceNativeID && forkResult.headTurnID == firstTurn && target.providerThreadID == forkResult.reference.nativeThreadID,
                               "fork-native-result-mismatch")
        try await evidence.nativeResult("fork", snapshot: forkResult)

        try await evidence.stage("review-and-rewind")
        let rewind = try await current.reviewConversationHistory(threadID: source.id, runID: second.id, kind: .rewindBeforeRun)
        try liveHistoryRequire(rewind.boundary == .beforeTurn(secondTurn) && rewind.expectedResultHeadTurnID == firstTurn,
                               "rewind-reviewed-boundary-mismatch")
        _ = try await current.beginConversationHistory(rewind)
        try await liveHistoryWait(audit: evidence, seconds: 60) { try await liveHistoryApplied(current, operationID: rewind.id) }
        let final = await current.current(), rewound = try liveHistoryThread(final, source.id)
        let rewindOperation = try liveHistoryOperation(final, rewind.id)
        let rewindResult = try liveHistoryValue(rewindOperation.result, "rewind-result-missing")
        try liveHistoryRequire(rewindResult.reference.nativeThreadID == sourceNativeID && rewindResult.headTurnID == firstTurn,
                               "rewind-native-result-mismatch")
        try liveHistoryRequire(rewound.visibleMessages == rewind.prefix && rewound.messages.count == beforeFork.messages.count && rewound.runHistory?.count == beforeFork.runHistory?.count,
                               "rewind-audit-or-prefix-mismatch")
        try liveHistoryRequire(rewound.draft == beforeFork.draft && ProviderConfiguration(thread: rewound) == ProviderConfiguration(thread: beforeFork), "rewind-changed-draft-or-settings")
        for original in beforeFork.messages {
            var retained = try liveHistoryValue(rewound.messages.first(where: { $0.id == original.id }), "rewind-lost-message")
            retained.removedByHistoryOperationID = nil
            try liveHistoryRequire(retained == original, "rewind-changed-retained-message")
        }
        try WorkspaceJournal.validate(final.snapshot)
        try await evidence.nativeResult("rewind", snapshot: rewindResult)
        try await evidence.stage("native-readback")
        // A separate read-only actor verifies durable provider metadata/heads;
        // it never resumes, starts a turn, or mutates either conversation.
        let inspection = try CodexSession(executable: executable, cwd: repository)
        do {
            let actualSource = try await inspection.conversationSnapshot(threadID: sourceNativeID)
            let actualFork = try await inspection.conversationSnapshot(threadID: forkResult.reference.nativeThreadID)
            try liveHistoryRequire(actualSource == rewindResult && actualFork == forkResult, "native-readback-mismatch")
            let sourcePage = try await inspection.historyPage(threadID: sourceNativeID, cursor: nil, limit: 100)
            let forkPage = try await inspection.historyPage(threadID: forkResult.reference.nativeThreadID, cursor: nil, limit: 100)
            try liveHistoryRequire(sourcePage.turns.first?.id == firstTurn && forkPage.turns.first?.id == firstTurn && !sourcePage.turns.contains(where: { $0.id == secondTurn }), "native-paged-readback-mismatch")
            await inspection.close()
        } catch { await inspection.close(); throw error }
        let bytesPreserved = try await fixture.state() == initialGitState
        try liveHistoryRequire(bytesPreserved, "git-or-working-bytes-changed")
        try await evidence.preserved(bytesPreserved)
        try await evidence.assertNoUnexpectedActions()
        try await evidence.stage("passed")
    } catch { failure = error; try? await evidence.failed(error) }
    // Shutdown owns all engine sessions; archive only the exact generated IDs.
    // Cleanup failures are evidence, never a replacement for the original error.
    await engine?.shutdown()
    let archiveSucceeded = await liveHistoryArchive(executable: executable, cwd: repository, audit: evidence)
    // Existing protocol close APIs signal process exit. Prove only that no
    // foreign process still has this task-owned directory open before deletion;
    // this is not a claim that every provider descendant has been reaped.
    let processProbe = await liveHistoryLocalProcessesClear(temporary)
    let localProcessesClear = processProbe.clear
    var cleanupComplete = false
    if archiveSucceeded && localProcessesClear {
        do { try manager.removeItem(at: temporary); cleanupComplete = true } catch { }
    }
    try? await evidence.cleanup(cleanupComplete, localProcessesClear: localProcessesClear, probeReason: processProbe.reason)
    if failure == nil && !cleanupComplete { try? await evidence.failed(LiveHistorySmokeFailure("test-cleanup-incomplete")) }
    if let failure {
        if let known = failure as? LiveHistorySmokeFailure { throw known }
        if let known = failure as? ProviderHistoryError { throw known }
        throw LiveHistorySmokeFailure("failed-at-recorded-stage; private-evidence=\(evidenceRoot.path)")
    }
    try liveHistoryRequire(cleanupComplete, "test-cleanup-incomplete; private-evidence=\(evidenceRoot.path)")
}

private struct LiveHistorySmokeFailure: Error, CustomStringConvertible {
    let description: String
    init(_ description: String) { self.description = description }
}
private func liveHistoryRequire(_ value: Bool, _ reason: String) throws { if !value { throw LiveHistorySmokeFailure(reason) } }
private func liveHistoryValue<T>(_ value: T?, _ reason: String) throws -> T { guard let value else { throw LiveHistorySmokeFailure(reason) }; return value }
private func liveHistoryThread(_ update: WorkspaceUpdate, _ id: UUID) throws -> CodingThread {
    try liveHistoryValue(update.snapshot.threads.first { $0.id == id }, "test-thread-missing")
}
private func liveHistoryOperation(_ update: WorkspaceUpdate, _ id: UUID) throws -> ConversationHistoryOperation {
    try liveHistoryValue(update.snapshot.conversationHistoryOperation(id), "test-operation-missing")
}
private func liveHistoryApplied(_ engine: WorkspaceEngine, operationID: UUID) async throws -> Bool {
    let update = await engine.current()
    guard update.error == nil else { throw LiveHistorySmokeFailure("engine-failure") }
    guard let operation = update.snapshot.conversationHistoryOperation(operationID) else { return false }
    if [.failed, .unconfirmed].contains(operation.phase) { throw LiveHistorySmokeFailure("history-operation-\(operation.phase.rawValue)") }
    return operation.phase == .applied
}
private func liveHistoryWait(audit: LiveHistorySmokeAudit, seconds: Int, _ condition: () async throws -> Bool) async throws {
    let deadline = ContinuousClock.now + .seconds(seconds)
    while true {
        try Task.checkCancellation(); try await audit.assertNoUnexpectedActions()
        if try await condition() { return }
        guard ContinuousClock.now < deadline else { throw LiveHistorySmokeFailure("bounded-wait-expired") }
        try await Task.sleep(for: .milliseconds(50))
    }
}

private actor LiveHistorySmokeAudit {
    private struct Evidence: Codable {
        let testID: UUID
        var stage = "created"
        var nativeThreadIDs: [String] = []
        var archivedNativeThreadIDs: [String] = []
        var markersMatched: [Int: Bool] = [:]
        var heads: [String: String] = [:]
        var unexpectedTools = 0
        var unexpectedApprovals = 0
        var failureCategory: String?
        var workingBytesPreserved: Bool?
        var cleanupComplete: Bool?
        var localProcessesClear: Bool?
        var localProcessProbeReason: String?
    }
    private var value: Evidence
    private let url: URL
    init(id: UUID, url: URL) throws {
        value = Evidence(testID: id); self.url = url
        guard FileManager.default.createFile(atPath: url.path, contents: nil, attributes: [.posixPermissions: 0o600]) else { throw LiveHistorySmokeFailure("private-evidence-create-failed") }
    }
    private func write() throws {
        let handle = try FileHandle(forWritingTo: url); defer { try? handle.close() }
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        try handle.truncate(atOffset: 0); try handle.write(contentsOf: encoder.encode(value)); try handle.synchronize()
    }
    func stage(_ stage: String) throws { value.stage = stage; try write() }
    func marker(_ index: Int, matched: Bool) throws { value.markersMatched[index] = matched; try write() }
    func native(_ id: String) throws {
        try ProviderHistoryValidation.id(id)
        if !value.nativeThreadIDs.contains(id) { value.nativeThreadIDs.append(id); try write() }
    }
    func nativeResult(_ name: String, snapshot: ProviderConversationSnapshot) throws {
        try native(snapshot.reference.nativeThreadID); value.heads[name] = snapshot.headTurnID ?? "<empty>"; try write()
    }
    func unexpected(tool: Bool) throws {
        if tool { value.unexpectedTools += 1 } else { value.unexpectedApprovals += 1 }; try write()
    }
    func assertNoUnexpectedActions() throws {
        guard value.unexpectedTools == 0, value.unexpectedApprovals == 0 else { throw LiveHistorySmokeFailure("unexpected-tool-or-approval") }
    }
    func preserved(_ preserved: Bool) throws { value.workingBytesPreserved = preserved; try write() }
    func failed(_ error: any Error) throws {
        if let error = error as? ProviderHistoryError { value.failureCategory = "provider-history-\(error.kind.rawValue)" }
        else if let error = error as? LiveHistorySmokeFailure { value.failureCategory = error.description }
        else if error is CancellationError { value.failureCategory = "cancelled" }
        else if error is JSONRPCRemoteError { value.failureCategory = "provider-rpc-error" }
        else { value.failureCategory = "local-or-transport-error" }
        try write()
    }
    func nativeIDs() -> [String] { value.nativeThreadIDs }
    func archived(_ id: String) throws { value.archivedNativeThreadIDs.append(id); try write() }
    func cleanup(_ complete: Bool, localProcessesClear: Bool, probeReason: String) throws {
        value.cleanupComplete = complete; value.localProcessesClear = localProcessesClear; value.localProcessProbeReason = probeReason; try write()
    }
}

private actor LiveHistoryObservedSession: ProviderSession {
    nonisolated let events: AsyncStream<ProviderEvent>
    private let sink: AsyncStream<ProviderEvent>.Continuation
    private let inner: CodexSession
    private let audit: LiveHistorySmokeAudit
    private var reader: Task<Void, Never>?
    init(executable: URL, cwd: URL, audit: LiveHistorySmokeAudit) throws {
        inner = try CodexSession(executable: executable, cwd: cwd); self.audit = audit
        let pair = AsyncStream<ProviderEvent>.makeStream(); events = pair.stream; sink = pair.continuation
    }
    private func observe() {
        guard reader == nil else { return }
        reader = Task { [inner, audit, sink] in
            for await event in inner.events {
                var item = event
                while case .context(_, let nested) = item { item = nested }
                switch item {
                case .thread(let id): try? await audit.native(id)
                case .approval(let request):
                    try? await audit.unexpected(tool: false)
                    if request.isQuestion { try? await inner.answer(request, answers: [:]) }
                    else { try? await inner.respond(request, allow: false) }
                    continue // The test denies directly; the engine must not ask twice.
                case .delta(_, let role, _): if role == .tool { try? await audit.unexpected(tool: true) }
                case .message(let message): if message.role == .tool { try? await audit.unexpected(tool: true) }
                case .entity(let update): if !["agent_message", "agent_thought", "user_message"].contains(update.key.type) { try? await audit.unexpected(tool: true) }
                default: break
                }
                sink.yield(event)
            }
            sink.finish()
        }
    }
    func models() async throws -> [ProviderModel] { observe(); return try await inner.models() }
    func send(text: String, thread: CodingThread) async throws { observe(); try await inner.send(text: text, thread: thread) }
    func send(input: ProviderInput, thread: CodingThread) async throws { observe(); try await inner.send(input: input, thread: thread) }
    func interrupt() async throws { try await inner.interrupt() }
    func respond(_ request: ApprovalRequest, allow: Bool) async throws { try await audit.unexpected(tool: false); try await inner.respond(request, allow: false) }
    func answer(_ request: ApprovalRequest, answers: [String: String]) async throws { try await audit.unexpected(tool: false); try await inner.answer(request, answers: [:]) }
    func historyCapabilities(threadID: String) async throws -> ProviderHistoryCapabilities { observe(); return try await inner.historyCapabilities(threadID: threadID) }
    func conversationSnapshot(threadID: String) async throws -> ProviderConversationSnapshot { observe(); return try await inner.conversationSnapshot(threadID: threadID) }
    func historyPage(threadID: String, cursor: String?, limit: Int) async throws -> ProviderHistoryPage { observe(); return try await inner.historyPage(threadID: threadID, cursor: cursor, limit: limit) }
    func forkConversation(source: ProviderConversationReference, boundary: ProviderHistoryBoundary, configuration: ProviderConfiguration) async throws -> ProviderConversationSnapshot {
        observe(); let result = try await inner.forkConversation(source: source, boundary: boundary, configuration: configuration)
        try await audit.native(result.reference.nativeThreadID); return result
    }
    func revertConversation(thread: ProviderConversationReference, beforeTurnID: String, expectedHeadTurnID: String) async throws -> ProviderConversationSnapshot {
        observe(); return try await inner.revertConversation(thread: thread, beforeTurnID: beforeTurnID, expectedHeadTurnID: expectedHeadTurnID)
    }
    func close() async { await inner.close(); reader?.cancel(); await reader?.value; sink.finish() }
}

private struct LiveHistoryGitFixture {
    let repository: URL
    let hooks: URL
    func git(_ arguments: [String]) async throws -> CommandResult {
        // Per-process settings only. Do not write the user's Git configuration.
        let options = ["--no-optional-locks", "-c", "core.fsmonitor=false", "-c", "core.hooksPath=\(hooks.path)", "-c", "commit.gpgSign=false", "-c", "user.name=Coincide History Test", "-c", "user.email=history@example.invalid"]
        var environment = ProcessChannel.environment()
        for key in Array(environment.keys) where key.hasPrefix("GIT_") { environment.removeValue(forKey: key) }
        let result = try await CommandRunner.run("git", options + arguments, cwd: repository, limit: 65_536, timeout: .seconds(20), environment: environment)
        guard result.status == 0 else { throw LiveHistorySmokeFailure("isolated-git-command-failed") }; return result
    }
    func state() async throws -> String {
        let tracked = try Data(contentsOf: repository.appendingPathComponent("harmless.txt"))
        let untracked = try Data(contentsOf: repository.appendingPathComponent("untracked.txt"))
        let index = try Data(contentsOf: repository.appendingPathComponent(".git/index"))
        let head = try await git(["rev-parse", "HEAD"]), status = try await git(["status", "--porcelain=v1", "-z", "--untracked-files=all"])
        let pieces = [tracked, untracked, index, head.output, status.output]
        return pieces.map { SHA256.hash(data: $0).map { String(format: "%02x", $0) }.joined() }.joined(separator: ":")
    }
}

private func liveHistoryArchive(executable: URL, cwd: URL, audit: LiveHistorySmokeAudit) async -> Bool {
    let ids = await audit.nativeIDs()
    guard !ids.isEmpty else { return true }
    do {
        let rpc = try JSONRPCConnection(executable: executable, arguments: ["app-server", "--stdio"], cwd: cwd)
        let consumer = Task {
            for await event in rpc.events {
                switch event {
                case .request(let id, _, _): try? await rpc.reject(id: id, message: "No tools are permitted during isolated test cleanup.")
                case .callback(let callback): await callback()
                case .barrier(let complete): complete()
                default: break
                }
            }
        }
        do {
            _ = try await rpc.request("initialize", params: .object(["clientInfo": .object(["name": .string("coincide"), "version": .string("0.1.0")]), "capabilities": .object(["experimentalApi": .bool(true)])]), timeout: .seconds(15))
            try await rpc.notify("initialized")
            for id in ids {
                _ = try await rpc.request("thread/archive", params: .object(["threadId": .string(id)]), timeout: .seconds(15))
                try await audit.archived(id)
            }
            await rpc.close(); consumer.cancel(); await consumer.value; return true
        } catch { await rpc.close(); consumer.cancel(); await consumer.value; return false }
    } catch { return false }
}

/// No signals are sent. An unavailable/inconclusive probe preserves all bytes.
private func liveHistoryLocalProcessesClear(_ root: URL) async -> (clear: Bool, reason: String) {
    guard ProcessChannel.findExecutable("/usr/sbin/lsof") != nil else { return (false, "unavailable") }
    let deadline = ContinuousClock.now + .seconds(5)
    let currentPID = Int32(ProcessInfo.processInfo.processIdentifier)
    while ContinuousClock.now < deadline {
        do {
            let result = try await CommandRunner.run("/usr/sbin/lsof", ["-t", "-a", "-p", "^" + String(currentPID), "+D", root.path],
                cwd: FileManager.default.temporaryDirectory, limit: 65_536,
                timeout: min(.seconds(2), ContinuousClock.now.duration(to: deadline)))
            guard (result.status == 0 || result.status == 1), result.error.isEmpty else { return (false, "stderr-or-status") }
            guard let output = String(data: result.output, encoding: .utf8) else { return (false, "invalid-output") }
            let lines = output.split(whereSeparator: \.isNewline)
            var foreign = false
            for line in lines {
                guard !line.isEmpty, line.utf8.allSatisfy({ (48...57).contains($0) }),
                      let pid = Int32(line), pid > 0 else { return (false, "invalid-output") }
                if pid != currentPID { foreign = true }
            }
            if !foreign { return (true, "clear") }
            try await Task.sleep(for: .milliseconds(100))
        } catch { return (false, "timeout-or-command-error") }
    }
    return (false, "foreign-process-timeout")
}


/// Exercise the deletion proof without providers or the opt-in environment.
@Test(.timeLimit(.minutes(1)))
func liveHistoryCleanupProbeExcludesOwnOpenHandleAndPreservesForeignHolder() async throws {
    let manager = FileManager.default
    let root = manager.temporaryDirectory.appendingPathComponent("coincide-history-cleanup-proof-" + UUID().uuidString, isDirectory: true)
    try manager.createDirectory(at: root, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
    defer { try? manager.removeItem(at: root) }
    let file = root.appendingPathComponent("owned.txt")
    try Data("Owned cleanup probe\n".utf8).write(to: file)
    let descriptor = Darwin.open(file.path, O_RDONLY | O_CLOEXEC)
    guard descriptor >= 0 else { throw LiveHistorySmokeFailure("cleanup-proof-open-failed") }
    defer { Darwin.close(descriptor) }
    // The current process deliberately retains this handle, like WorkspaceDatabase.
    let ownHandle = await liveHistoryLocalProcessesClear(root)
    #expect(ownHandle.clear)
    let child = try ProcessChannel(executable: URL(fileURLWithPath: "/usr/bin/python3"), arguments: ["-c",
        "import sys; held=open(sys.argv[1], 'rb'); print('ready', flush=True); sys.stdin.buffer.read(1)", file.path],
        cwd: manager.temporaryDirectory)
    let ready = AsyncStream<Void>.makeStream(bufferingPolicy: .bufferingNewest(1))
    let reader = Task {
        var bytes = Data()
        defer { ready.continuation.finish() }
        for await event in child.events {
            switch event {
            case .stdout(let chunk):
                bytes.append(chunk)
                if bytes.count <= 4096 && String(decoding: bytes, as: UTF8.self).contains("ready") { ready.continuation.yield(()) }
            case .exited: return
            default: break
            }
        }
    }
    do {
        try await withThrowingTaskGroup(of: Bool.self) { group in
            group.addTask { for await _ in ready.stream { return true }; return false }
            group.addTask { try await Task.sleep(for: .seconds(3)); throw LiveHistorySmokeFailure("cleanup-proof-ready-timeout") }
            let reached = try await group.next() == true; group.cancelAll()
            try liveHistoryRequire(reached, "cleanup-proof-child-ended-before-ready")
        }
        // A numeric foreign PID remains a strict preservation result, even when
        // Darwin lsof returns status 1 with no stderr for that matching handle.
        let foreignHandle = await liveHistoryLocalProcessesClear(root)
        #expect(!foreignHandle.clear)
        child.finishInput(); await reader.value
        let closed = await liveHistoryLocalProcessesClear(root)
        #expect(closed.clear)
    } catch { child.finishInput(); await reader.value; throw error }
}
