import Foundation
import Testing
@testable import CoincideCore

private actor CompactionObservations {
    private(set) var completions = 0
    private(set) var texts: [String] = []
    func append(_ event: ProviderEvent) {
        if case .context(_, let child) = event { append(child); return }
        switch event {
        case .completed: completions += 1
        case .message(let message): texts.append(message.text)
        case .delta(_, _, let text): texts.append(text)
        default: break
        }
    }
}

private struct CompactionPeer {
    let root: URL
    let kind: ProviderKind
    let session: any ProviderSession
    let observed = CompactionObservations()
    init(kind: ProviderKind, scenario: String) throws {
        self.kind = kind
        root = FileManager.default.temporaryDirectory.appendingPathComponent("coincide-compaction-\(UUID())")
            .standardizedFileURL.resolvingSymlinksInPath()
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let fixture = try #require(Bundle.module.url(forResource: "native_compaction", withExtension: "py", subdirectory: "Fixtures"))
        let executable = URL(fileURLWithPath: "/usr/bin/python3")
        let arguments = [fixture.path, kind.rawValue, scenario, root.path]
        if kind == .codex { session = try CodexSession(executable: executable, cwd: root, arguments: arguments) }
        else { session = try ClaudeSession(executable: executable, cwd: root, arguments: arguments) }
    }
    func connect() async throws {
        if let codex = session as? CodexSession { try await codex.connect() }
        else {
            let claude = try #require(session as? ClaudeSession)
            try await claude.connect()
        }
    }
    func frames() throws -> [JSONValue] {
        let url = root.appendingPathComponent("wire.jsonl")
        guard FileManager.default.fileExists(atPath: url.path) else { return [] }
        return try Data(contentsOf: url).split(separator: 10).map { try JSONDecoder().decode(JSONValue.self, from: Data($0)) }
    }
    func compactFrames() throws -> [JSONValue] {
        try frames().filter { kind == .codex ? $0["method"] == .string("thread/compact/start") :
            $0["type"] == .string("user") && $0["message"]["content"] == .string("/compact") }
    }
    func thread() -> CodingThread {
        var value = CodingThread(project: WorkspaceProject(path: root.path), model: "fixture-model")
        value.provider = kind; value.permission = .supervised
        return value
    }
    func start() async throws -> CodingThread {
        var value = thread()
        try await session.send(text: "Public opening", thread: value)
        try await compactionEventually { await observed.completions == 1 }
        value.providerThreadID = "fixture-native-session"
        return value
    }
}

private func withCompactionPeer(kind: ProviderKind, scenario: String = "success", _ body: (CompactionPeer) async throws -> Void) async throws {
    let peer = try CompactionPeer(kind: kind, scenario: scenario)
    let observer = Task { for await event in peer.session.events { await peer.observed.append(event) } }
    do {
        try await body(peer)
        await peer.session.close(); observer.cancel(); await observer.value
        try FileManager.default.removeItem(at: peer.root)
    } catch {
        await peer.session.close(); observer.cancel(); await observer.value
        try? FileManager.default.removeItem(at: peer.root)
        throw error
    }
}
private func compactionEventually(_ predicate: () async throws -> Bool) async throws {
    let deadline = ContinuousClock.now + .seconds(8)
    while try await !predicate() {
        guard ContinuousClock.now < deadline else { throw CoincideError("The offline compaction peer did not reach its expected boundary.") }
        try await Task.sleep(for: .milliseconds(5))
    }
}
private func expectCompactionError(_ kind: ProviderContextCompactionError.Kind, _ action: () async throws -> Void) async {
    do { try await action(); Issue.record("Expected compaction rejection: \(kind)") }
    catch { #expect((error as? ProviderContextCompactionError)?.kind == kind) }
}

@Test(.timeLimit(.minutes(1)), arguments: [ProviderKind.codex, .claude])
func nativeCompactionRequiresExactIdleOwnedConnectionAndKeepsSummaryPrivate(kind: ProviderKind) async throws {
    try await withCompactionPeer(kind: kind) { peer in
        await expectCompactionError(.unsupported) { _ = try await peer.session.compactContext(thread: peer.thread(), operationID: UUID()) }
        #expect(try peer.frames().isEmpty)
        try await peer.connect()
        await expectCompactionError(.notIdle) { _ = try await peer.session.compactContext(thread: peer.thread(), operationID: UUID()) }
        var thread = try await peer.start()
        var alias = peer.thread(); alias.providerThreadID = thread.providerThreadID
        await expectCompactionError(.notIdle) { _ = try await peer.session.compactContext(thread: alias, operationID: UUID()) }
        var foreign = thread; foreign.providerThreadID = "foreign-native-session"
        await expectCompactionError(.notIdle) { _ = try await peer.session.compactContext(thread: foreign, operationID: UUID()) }
        let operationID = UUID(); thread.contextCompactionID = operationID
        await expectCompactionError(.notIdle) { _ = try await peer.session.compactContext(thread: thread, operationID: UUID()) }
        #expect(try peer.compactFrames().isEmpty)
        let receipt = try await peer.session.compactContext(thread: thread, operationID: operationID)
        #expect(receipt == .init(provider: kind, nativeThreadID: "fixture-native-session"))
        #expect(await peer.observed.completions == 1)
        #expect(await peer.observed.texts == ["Public reply 1"])
        let compactFrames = try peer.compactFrames()
        #expect(compactFrames.count == 1)
        if kind == .claude {
            #expect(compactFrames.first?["uuid"] == .string(operationID.uuidString))
            #expect(compactFrames.first?["message"] == .object(["role": .string("user"), "content": .string("/compact")]))
        }
        thread.contextCompactionID = nil
        try await peer.session.send(text: "Explicit next public input", thread: thread)
        try await compactionEventually { await peer.observed.completions == 2 }
        #expect(await peer.observed.texts == ["Public reply 1", "Public reply 2"])
        #expect(try peer.compactFrames().count == 1)
    }
}

@Test(.timeLimit(.minutes(1)), arguments: [ProviderKind.codex, .claude])
func nativeCompactionRejectsUnadvertisedSupportWithoutSendingAnything(kind: ProviderKind) async throws {
    try await withCompactionPeer(kind: kind, scenario: "unsupported") { peer in
        let thread = try await peer.start()
        await expectCompactionError(.unsupported) { _ = try await peer.session.compactContext(thread: thread, operationID: UUID()) }
        #expect(try peer.compactFrames().isEmpty)
        #expect(await peer.observed.completions == 1)
    }
}

@Test(.timeLimit(.minutes(1)), arguments: [ProviderKind.codex, .claude], ["missing-boundary", "failed", "disconnect", "interactive"])
func nativeCompactionNeverTreatsAcceptanceOrAnUnrelatedTerminalAsSuccess(kind: ProviderKind, scenario: String) async throws {
    try await withCompactionPeer(kind: kind, scenario: scenario) { peer in
        let thread = try await peer.start()
        await expectCompactionError(scenario == "failed" ? .failed : .unconfirmed) {
            _ = try await peer.session.compactContext(thread: thread, operationID: UUID())
        }
        #expect(try peer.compactFrames().count == 1)
        #expect(await peer.observed.completions == 1)
        #expect(await peer.observed.texts == ["Public reply 1"])
        await expectCompactionError(.unsupported) { _ = try await peer.session.compactContext(thread: thread, operationID: UUID()) }
        #expect(try peer.compactFrames().count == 1)
    }
}

@Test(.timeLimit(.minutes(1)), arguments: [ProviderKind.codex, .claude], [false, true])
func nativeCompactionCancellationOrCloseSettlesWithoutRetry(kind: ProviderKind, closeConnection: Bool) async throws {
    try await withCompactionPeer(kind: kind, scenario: "hold") { peer in
        let thread = try await peer.start()
        let pending = Task { try await peer.session.compactContext(thread: thread, operationID: UUID()) }
        try await compactionEventually { FileManager.default.fileExists(atPath: peer.root.appendingPathComponent("dispatched").path) }
        if let codex = peer.session as? CodexSession {
            // This offline read includes an ordered event barrier, proving the
            // compaction turn notification was consumed before cancellation.
            _ = try await codex.codexAccountSnapshot()
        }
        await expectCompactionError(.notIdle) { _ = try await peer.session.compactContext(thread: thread, operationID: UUID()) }
        await #expect(throws: CoincideError.self) { try await peer.session.send(text: "Must not send during maintenance", thread: thread) }
        if closeConnection { await peer.session.close() } else { pending.cancel() }
        await expectCompactionError(.unconfirmed) { _ = try await pending.value }
        #expect(try peer.compactFrames().count == 1)
        #expect(await peer.observed.completions == 1)
        if kind == .codex {
            let interrupts = try peer.frames().filter { $0["method"] == .string("turn/interrupt") }
            #expect(interrupts.count == 1)
            #expect(interrupts.first?["params"] == .object(["threadId": .string("fixture-native-session"), "turnId": .string("compact-turn")]))
        }
    }
}

@Test(arguments: [false, true])
func compactionLatchRequiresAckAndBothCodexBoundaries(acknowledged: Bool) async throws {
    let latch = NativeContextCompactionLatch(provider: .codex, nativeThreadID: "native", operationID: UUID())
    await latch.consume(method: "turn/started", params: .object(["threadId": .string("native"), "turn": .object(["id": .string("compact")])]))
    await latch.consume(method: "item/completed", params: .object(["threadId": .string("native"), "turnId": .string("compact"),
        "item": .object(["id": .string("boundary"), "type": .string("contextCompaction")])]))
    await latch.consume(method: "turn/completed", params: .object(["threadId": .string("native"),
        "turn": .object(["id": .string("compact"), "status": .string("completed")])]))
    if acknowledged {
        await latch.acknowledge()
        #expect(try await latch.wait(timeout: .milliseconds(10)).nativeThreadID == "native")
    } else { await expectCompactionError(.unconfirmed) { _ = try await latch.wait(timeout: .milliseconds(10)) } }
}

@Test(arguments: [false, true])
func compactionLatchRequiresManualClaudeBoundary(manual: Bool) async throws {
    let latch = NativeContextCompactionLatch(provider: .claude, nativeThreadID: "native", operationID: UUID())
    await latch.acknowledge()
    await latch.consume(method: "system", params: .object(["session_id": .string("native"), "subtype": .string("compact_boundary"),
        "compact_metadata": .object(["trigger": .string(manual ? "manual" : "auto")])]))
    await latch.consume(method: "result", params: .object(["session_id": .string("native"), "is_error": .bool(false)]))
    if manual { #expect(try await latch.wait(timeout: .milliseconds(10)).provider == .claude) }
    else { await expectCompactionError(.unconfirmed) { _ = try await latch.wait(timeout: .milliseconds(10)) } }
}

@Test
func compactionInterruptAuthorityRequiresOneObservedUnfinishedCodexTurn() async {
    let latch = NativeContextCompactionLatch(provider: .codex, nativeThreadID: "native", operationID: UUID())
    await latch.acknowledge()
    #expect(await latch.claimInterruptTarget() == nil)
    await latch.consume(method: "turn/started", params: .object(["threadId": .string("foreign"), "turn": .object(["id": .string("foreign-turn")])]))
    #expect(await latch.claimInterruptTarget() == nil)
    await latch.consume(method: "turn/started", params: .object(["threadId": .string("native"), "turn": .object(["id": .string("owned-turn")])]))
    #expect(await latch.claimInterruptTarget() == "owned-turn")
    #expect(await latch.claimInterruptTarget() == nil)
    let finished = NativeContextCompactionLatch(provider: .codex, nativeThreadID: "native", operationID: UUID())
    await finished.consume(method: "turn/completed", params: .object(["threadId": .string("native"),
        "turn": .object(["id": .string("finished-turn"), "status": .string("failed")])]))
    #expect(await finished.claimInterruptTarget() == nil)
}
