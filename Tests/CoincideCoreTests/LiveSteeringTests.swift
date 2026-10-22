import CryptoKit
import Foundation
import Testing
@testable import CoincideCore

/// Off by default. Exactly one opening prompt and one steering input, using the
/// installed CLI's existing authentication in a private task-owned Git checkout.
@Test(.timeLimit(.minutes(8)))
func installedCodexNativePromptSteeringThroughEngineKeepsOneRunAndNativeTurn() async throws {
    guard ProcessInfo.processInfo.environment["COINCIDE_LIVE_CODEX_STEERING"] == "1" else { return }
    guard let executable = ProcessChannel.findExecutable("codex") else { throw LiveSteeringFailure("installed-cli-missing") }
    let manager = FileManager.default, testID = UUID()
    let temporary = manager.temporaryDirectory.appendingPathComponent("coincide-live-steering-\(testID)", isDirectory: true)
        .standardizedFileURL.resolvingSymlinksInPath()
    let evidenceRoot = manager.temporaryDirectory.appendingPathComponent("coincide-live-steering-evidence-\(testID)", isDirectory: true)
        .standardizedFileURL.resolvingSymlinksInPath()
    try manager.createDirectory(at: temporary, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
    try manager.createDirectory(at: evidenceRoot, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
    let audit = try LiveSteeringAudit(id: testID, url: evidenceRoot.appendingPathComponent("evidence.json"))
    let repository = temporary.appendingPathComponent("repository", isDirectory: true), hooks = temporary.appendingPathComponent("empty-hooks", isDirectory: true)
    try manager.createDirectory(at: repository, withIntermediateDirectories: true)
    try manager.createDirectory(at: hooks, withIntermediateDirectories: true)
    let git = LiveSteeringGit(repository: repository, hooks: hooks)
    var engine: WorkspaceEngine?, failure: (any Error)?
    do {
        try await audit.stage("git-fixture")
        _ = try await git.run(["init", "-b", "main"])
        try Data("Committed isolated sentinel\n".utf8).write(to: repository.appendingPathComponent("harmless.txt"))
        _ = try await git.run(["add", "--", "harmless.txt"])
        _ = try await git.run(["commit", "-m", "Coincide isolated steering smoke"])
        try Data("Staged isolated sentinel\n".utf8).write(to: repository.appendingPathComponent("harmless.txt"))
        _ = try await git.run(["add", "--", "harmless.txt"])
        try Data("Working isolated sentinel\n".utf8).write(to: repository.appendingPathComponent("harmless.txt"))
        try Data("Untracked isolated sentinel\n".utf8).write(to: repository.appendingPathComponent("untracked.txt"))
        let originalState = try await git.state()
        let project = WorkspaceProject(path: repository.path)
        var source = CodingThread(project: project)
        source.title = "Coincide steering smoke \(testID)"; source.permission = .supervised
        let current = try WorkspaceEngine(url: temporary.appendingPathComponent("workspace.sqlite"), providerFactory: { thread in
            try LiveSteeringObservedSession(executable: executable, cwd: URL(fileURLWithPath: thread.workspacePath), audit: audit)
        })
        engine = current
        _ = try await current.dispatch(.addProjectWithThread(project: project, thread: source))
        let openingMarker = "COINCIDE_STEERING_OPEN_\(testID.uuidString)", marker = "COINCIDE_STEERING_ACCEPTED_\(testID.uuidString)"
        let runID = UUID()
        let opening = "This is an isolated streaming protocol test. Do not use tools, agents, commands, files, network, or approvals. Write \(openingMarker) on its own line, then write each integer from 1 through 200 on a separate line. If another user instruction arrives while you are writing, follow that newer instruction immediately."
        try await audit.stage("opening-turn")
        _ = try await current.dispatch(.submit(threadID: source.id, text: opening), id: runID)
        try await liveSteeringWait(audit: audit, seconds: 150, poll: .milliseconds(5)) {
            let update = await current.current()
            guard update.error == nil else { throw LiveSteeringFailure("engine-failure") }
            let thread = try liveSteeringThread(update, source.id)
            if let record = thread.runHistory?.first(where: { $0.id == runID }), record.status.isTerminal {
                throw LiveSteeringFailure("opening-turn-finished-before-steer")
            }
            guard thread.activeRun?.id == runID, thread.activeRun?.nativeTurnID != nil else { return false }
            return await current.promptSteeringAvailability(threadID: source.id).canSteer
        }
        let active = try liveSteeringThread(await current.current(), source.id)
        let nativeThread = try liveSteeringValue(active.providerThreadID, "native-thread-missing")
        let nativeTurn = try liveSteeringValue(active.activeRun?.nativeTurnID, "active-native-turn-missing")
        try liveSteeringRequire(active.runHistory?.count == 1 && active.activeRun?.configuration.permission == .supervised,
                                "opening-run-boundary-mismatch")
        try await audit.target(runID: runID, nativeThreadID: nativeThread, nativeTurnID: nativeTurn)
        let draft = "Unsent unrelated synthetic draft \(testID)"
        _ = try await current.dispatch(.editThread(source.id, .draft(draft)))
        try await audit.stage("steering-input")
        let steeringText = "Stop the counting request now. Reply with exactly \(marker). Do not use tools, agents, commands, files, network, or approvals."
        _ = try await current.steerPrompt(threadID: source.id, text: steeringText, expectedRunID: runID, queuedID: nil)
        try await liveSteeringWait(audit: audit, seconds: 30) {
            let update = await current.current()
            guard update.error == nil else { throw LiveSteeringFailure("engine-failure") }
            let records = (update.snapshot.promptSteerings ?? []).filter { $0.threadID == source.id }
            guard records.count <= 1 else { throw LiveSteeringFailure("duplicate-steering-operations") }
            guard let operation = records.first else { return false }
            if [.failed, .queued, .unconfirmed].contains(operation.phase) { throw LiveSteeringFailure("steering-not-acknowledged") }
            return operation.phase == .delivered
        }
        try await audit.stage("same-turn-completion")
        try await liveSteeringWait(audit: audit, seconds: 180) {
            let update = await current.current()
            guard update.error == nil else { throw LiveSteeringFailure("engine-failure") }
            let thread = try liveSteeringThread(update, source.id)
            guard let record = thread.runHistory?.first(where: { $0.id == runID }) else { return false }
            if record.status.isTerminal && record.status != .completed { throw LiveSteeringFailure("steered-run-not-completed") }
            return record.status == .completed && thread.activeRun == nil && thread.queuedTurns.isEmpty && thread.heldPostRunCheckpoint == nil
        }
        let final = await current.current(), thread = try liveSteeringThread(final, source.id)
        let operation = try liveSteeringValue(final.snapshot.promptSteerings?.first(where: { $0.threadID == source.id }), "steering-operation-missing")
        let receipt = try liveSteeringValue(operation.receipt, "steering-receipt-missing")
        let record = try liveSteeringValue(thread.runHistory?.first, "run-record-missing")
        try liveSteeringRequire(operation.phase == .delivered && operation.runID == runID && operation.nativeThreadID == nativeThread && operation.nativeTurnID == nativeTurn &&
            receipt.turnID == nativeTurn && receipt.delivery == .acknowledged, "same-native-turn-acknowledgement-mismatch")
        try liveSteeringRequire(thread.runHistory?.count == 1 && record.id == runID && record.turnIDs == [nativeTurn] &&
            thread.providerThreadID == nativeThread && thread.draft == draft && thread.queuedTurns.isEmpty,
            "steering-created-run-or-changed-draft")
        try liveSteeringRequire(record.checkpoints?.baseline.phase == .ready && record.checkpoints?.postRun?.phase == .ready &&
            record.checkpoints?.providerReleased == true, "automatic-checkpoint-policy-not-captured")
        let users = thread.visibleMessages.filter { $0.role == .user }
        let steeringRows = users.filter { $0.promptSteeringID == operation.id }
        try liveSteeringRequire(users.count == 2 && steeringRows.count == 1 && steeringRows.first?.text == steeringText &&
            steeringRows.first?.runReference == .init(threadID: source.id, runID: runID), "steering-transcript-attribution-mismatch")
        let openingSeen = thread.visibleMessages.contains { $0.role == .assistant && $0.text.contains(openingMarker) }
        let markerMatched = thread.visibleMessages.contains { message in
            message.role == .assistant && message.runReference?.runID == runID &&
                message.text.split(whereSeparator: \.isNewline).contains { $0.trimmingCharacters(in: .whitespacesAndNewlines) == marker }
        }
        try await audit.result(operationID: operation.id, receipt: receipt, openingMarkerObserved: openingSeen, markerMatched: markerMatched)
        try liveSteeringRequire(markerMatched, "steering-marker-mismatch")
        try WorkspaceJournal.validate(final.snapshot)
        let preserved = try await git.state() == originalState
        try await audit.preserved(preserved)
        try liveSteeringRequire(preserved, "source-bytes-index-or-head-changed")
        try await audit.requireCounts()
        try await audit.stage("passed")
    } catch { failure = error; try? await audit.failed(error) }
    await engine?.shutdown()
    if failure == nil {
        do { try await audit.requireCounts() } catch { failure = error; try? await audit.failed(error) }
    }
    let archived = await liveSteeringArchive(executable: executable, cwd: repository, audit: audit)
    let probe = await liveSteeringProcessesClear(temporary)
    var removed = false
    if archived && probe.clear { do { try manager.removeItem(at: temporary); removed = true } catch {} }
    try? await audit.cleanup(removed: removed, processesClear: probe.clear, reason: probe.reason)
    if failure == nil && !removed {
        let cleanupFailure = LiveSteeringFailure("task-cleanup-incomplete")
        failure = cleanupFailure; try? await audit.failed(cleanupFailure)
    }
    if let failure {
        if let known = failure as? LiveSteeringFailure { throw known }
        if let known = failure as? ProviderSteeringError { throw known }
        throw LiveSteeringFailure("failed-at-recorded-stage; private-evidence=\(evidenceRoot.path)")
    }
}

private struct LiveSteeringFailure: Error, CustomStringConvertible {
    let description: String
    init(_ description: String) { self.description = description }
}
private func liveSteeringRequire(_ condition: Bool, _ category: String) throws { if !condition { throw LiveSteeringFailure(category) } }
private func liveSteeringValue<T>(_ value: T?, _ category: String) throws -> T { guard let value else { throw LiveSteeringFailure(category) }; return value }
private func liveSteeringThread(_ update: WorkspaceUpdate, _ id: UUID) throws -> CodingThread {
    try liveSteeringValue(update.snapshot.threads.first { $0.id == id }, "task-thread-missing")
}
private func liveSteeringWait(audit: LiveSteeringAudit, seconds: Int, poll: Duration = .milliseconds(25), _ condition: () async throws -> Bool) async throws {
    let deadline = ContinuousClock.now + .seconds(seconds)
    while true {
        try Task.checkCancellation(); try await audit.requireNoUnexpectedActions()
        if try await condition() { return }
        guard ContinuousClock.now < deadline else { throw LiveSteeringFailure("bounded-wait-expired") }
        try await Task.sleep(for: poll)
    }
}

private actor LiveSteeringAudit {
    private struct Evidence: Codable {
        let testID: UUID
        var stage = "created"
        var nativeThreadIDs: [String] = []
        var archivedNativeThreadIDs: [String] = []
        var runID: UUID?
        var nativeTurnID: String?
        var steeringOperationID: UUID?
        var receipt: ProviderSteeringReceipt?
        var openingMarkerObserved: Bool?
        var markerMatched: Bool?
        var providerStarts = 0
        var steeringCalls = 0
        var unexpectedTools = 0
        var unexpectedApprovals = 0
        var failureCategory: String?
        var workingBytesPreserved: Bool?
        var cleanupComplete: Bool?
        var localProcessesClear: Bool?
        var localProcessProbeReason: String?
    }
    private var evidence: Evidence
    private let url: URL
    init(id: UUID, url: URL) throws {
        evidence = .init(testID: id); self.url = url
        guard FileManager.default.createFile(atPath: url.path, contents: nil, attributes: [.posixPermissions: 0o600]) else { throw LiveSteeringFailure("private-evidence-create-failed") }
    }
    private func write() throws {
        let handle = try FileHandle(forWritingTo: url); defer { try? handle.close() }
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        try handle.truncate(atOffset: 0); try handle.write(contentsOf: encoder.encode(evidence)); try handle.synchronize()
    }
    func stage(_ stage: String) throws { evidence.stage = stage; try write() }
    func native(_ id: String) throws {
        try ProviderHistoryValidation.id(id)
        if !evidence.nativeThreadIDs.contains(id) { evidence.nativeThreadIDs.append(id); try write() }
    }
    func target(runID: UUID, nativeThreadID: String, nativeTurnID: String) throws {
        try native(nativeThreadID); evidence.runID = runID; evidence.nativeTurnID = nativeTurnID; try write()
    }
    func result(operationID: UUID, receipt: ProviderSteeringReceipt, openingMarkerObserved: Bool, markerMatched: Bool) throws {
        evidence.steeringOperationID = operationID; evidence.receipt = receipt
        evidence.openingMarkerObserved = openingMarkerObserved; evidence.markerMatched = markerMatched; try write()
    }
    func startCall() throws { evidence.providerStarts += 1; try write() }
    func steerCall() throws { evidence.steeringCalls += 1; try write() }
    func unexpected(tool: Bool) throws { if tool { evidence.unexpectedTools += 1 } else { evidence.unexpectedApprovals += 1 }; try write() }
    func requireNoUnexpectedActions() throws {
        guard evidence.unexpectedTools == 0 && evidence.unexpectedApprovals == 0 else { throw LiveSteeringFailure("unexpected-tool-or-approval") }
    }
    func requireCounts() throws {
        try requireNoUnexpectedActions()
        guard evidence.providerStarts == 1 && evidence.steeringCalls == 1 && evidence.nativeThreadIDs.count == 1 else { throw LiveSteeringFailure("provider-replay-or-fallthrough") }
    }
    func preserved(_ value: Bool) throws { evidence.workingBytesPreserved = value; try write() }
    func nativeIDs() -> [String] { evidence.nativeThreadIDs }
    func archived(_ id: String) throws { evidence.archivedNativeThreadIDs.append(id); try write() }
    func failed(_ error: any Error) throws {
        if let known = error as? LiveSteeringFailure { evidence.failureCategory = known.description }
        else if let known = error as? ProviderSteeringError { evidence.failureCategory = "steering-" + known.kind.rawValue }
        else if error is CancellationError { evidence.failureCategory = "cancelled" }
        else { evidence.failureCategory = "engine-or-transport-error" }
        try write()
    }
    func cleanup(removed: Bool, processesClear: Bool, reason: String) throws {
        evidence.cleanupComplete = removed; evidence.localProcessesClear = processesClear; evidence.localProcessProbeReason = reason; try write()
    }
}

private actor LiveSteeringObservedSession: ProviderSession {
    nonisolated let events: AsyncStream<ProviderEvent>
    private let sink: AsyncStream<ProviderEvent>.Continuation
    private let inner: CodexSession
    private let audit: LiveSteeringAudit
    private var reader: Task<Void, Never>?
    init(executable: URL, cwd: URL, audit: LiveSteeringAudit) throws {
        inner = try .init(executable: executable, cwd: cwd); self.audit = audit
        let pair = AsyncStream<ProviderEvent>.makeStream(); events = pair.stream; sink = pair.continuation
    }
    private func observe() {
        guard reader == nil else { return }
        reader = Task { [inner, sink, audit] in
            for await event in inner.events {
                var item = event
                while case .context(_, let child) = item { item = child }
                switch item {
                case .thread(let id): try? await audit.native(id)
                case .approval(let request), .sessionApproval(let request):
                    try? await audit.unexpected(tool: false)
                    if request.isQuestion { try? await inner.answer(request, answers: [:]) }
                    else { try? await inner.respond(request, allow: false) }
                    continue
                case .delta(_, let role, _): if role == .tool { try? await audit.unexpected(tool: true) }
                case .message(let message):
                    if message.role == .tool { try? await audit.unexpected(tool: true) }
                    else if message.role == .system && message.text.hasPrefix("Unsupported provider request:") { try? await audit.unexpected(tool: false) }
                case .entity(let update): if !["agent_message", "agent_thought", "user_message"].contains(update.key.type) { try? await audit.unexpected(tool: true) }
                default: break
                }
                sink.yield(event)
            }
            sink.finish()
        }
    }
    func models() async throws -> [ProviderModel] { observe(); return try await inner.models() }
    func send(text: String, thread: CodingThread) async throws { try await send(input: .init(text: text), thread: thread) }
    func send(input: ProviderInput, thread: CodingThread) async throws { observe(); try await audit.startCall(); try await inner.send(input: input, thread: thread) }
    func steeringCapabilities() async -> ProviderSteeringCapabilities { observe(); return await inner.steeringCapabilities() }
    func steer(input: ProviderInput, thread: CodingThread, expectedTurnID: String, clientMessageID: String) async throws -> ProviderSteeringReceipt {
        observe(); try await audit.steerCall()
        return try await inner.steer(input: input, thread: thread, expectedTurnID: expectedTurnID, clientMessageID: clientMessageID)
    }
    func interrupt() async throws { try await inner.interrupt() }
    func respond(_ request: ApprovalRequest, allow: Bool) async throws { try await audit.unexpected(tool: false); try await inner.respond(request, allow: false) }
    func answer(_ request: ApprovalRequest, answers: [String: String]) async throws { try await audit.unexpected(tool: false); try await inner.answer(request, answers: [:]) }
    func close() async { await inner.close(); reader?.cancel(); await reader?.value; sink.finish() }
}

private struct LiveSteeringGit {
    let repository: URL
    let hooks: URL
    func run(_ arguments: [String]) async throws -> CommandResult {
        var environment = ProcessChannel.environment()
        for key in Array(environment.keys) where key.hasPrefix("GIT_") { environment.removeValue(forKey: key) }
        let options = ["--no-optional-locks", "-c", "core.fsmonitor=false", "-c", "core.hooksPath=\(hooks.path)",
            "-c", "commit.gpgSign=false", "-c", "user.name=Coincide Steering Test", "-c", "user.email=steering@example.invalid"]
        let result = try await CommandRunner.run("git", options + arguments, cwd: repository, limit: 65_536, timeout: .seconds(20), environment: environment)
        guard result.status == 0 else { throw LiveSteeringFailure("isolated-git-command-failed") }; return result
    }
    func state() async throws -> String {
        let tracked = try Data(contentsOf: repository.appendingPathComponent("harmless.txt")), untracked = try Data(contentsOf: repository.appendingPathComponent("untracked.txt"))
        let index = try Data(contentsOf: repository.appendingPathComponent(".git/index")), head = try await run(["rev-parse", "HEAD"])
        let headFile = try Data(contentsOf: repository.appendingPathComponent(".git/HEAD"))
        let status = try await run(["status", "--porcelain=v1", "-z", "--untracked-files=all"])
        return [tracked, untracked, index, headFile, head.output, status.output].map { SHA256.hash(data: $0).map { String(format: "%02x", $0) }.joined() }.joined(separator: ":")
    }
}

private func liveSteeringArchive(executable: URL, cwd: URL, audit: LiveSteeringAudit) async -> Bool {
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
            _ = try await rpc.request("initialize", params: .object(["clientInfo": .object(["name": .string("coincide"), "version": .string("0.1.0")]),
                "capabilities": .object(["experimentalApi": .bool(true)])]), timeout: .seconds(15))
            try await rpc.notify("initialized")
            for id in ids { _ = try await rpc.request("thread/archive", params: .object(["threadId": .string(id)]), timeout: .seconds(15)); try await audit.archived(id) }
            await rpc.close(); consumer.cancel(); await consumer.value; return true
        } catch { await rpc.close(); consumer.cancel(); await consumer.value; return false }
    } catch { return false }
}

/// A numeric foreign PID is a reason to keep waiting, including Darwin's normal
/// status 1 result. Only a later valid empty scan permits task-folder deletion.
private func liveSteeringProcessesClear(_ root: URL) async -> (clear: Bool, reason: String) {
    guard ProcessChannel.findExecutable("/usr/sbin/lsof") != nil else { return (false, "unavailable") }
    let deadline = ContinuousClock.now + .seconds(5), ownPID = ProcessInfo.processInfo.processIdentifier
    while ContinuousClock.now < deadline {
        do {
            let result = try await CommandRunner.run("/usr/sbin/lsof", ["-t", "-a", "-p", "^" + String(ownPID), "+D", root.path],
                cwd: FileManager.default.temporaryDirectory, limit: 65_536, timeout: min(.seconds(2), ContinuousClock.now.duration(to: deadline)))
            guard result.status == 0 || result.status == 1, result.error.isEmpty else { return (false, "stderr-or-status") }
            guard let text = String(data: result.output, encoding: .utf8) else { return (false, "invalid-output") }
            let lines = text.split(whereSeparator: \.isNewline)
            for line in lines {
                guard line.utf8.allSatisfy({ (48...57).contains($0) }), let pid = Int32(line), pid > 0 else { return (false, "invalid-output") }
            }
            if lines.isEmpty { return (true, "clear") }
            try await Task.sleep(for: .milliseconds(100))
        } catch { return (false, "timeout-or-command-error") }
    }
    return (false, "foreign-process-timeout")
}
