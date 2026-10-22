import Foundation
import Testing
@testable import CoincideCore

private actor AccountCloseGate {
    private var waiting: CheckedContinuation<Void, Never>?
    private var released = false
    private(set) var entered = false
    func wait() async {
        entered = true
        if !released { await withCheckedContinuation { waiting = $0 } }
    }
    func release() { released = true; let saved = waiting; waiting = nil; saved?.resume() }
}

private actor AccountMetadataPeer: ProviderSession {
    nonisolated let events: AsyncStream<ProviderEvent>
    private let continuation: AsyncStream<ProviderEvent>.Continuation
    private let result: CodexAccountSnapshot
    private let hold: Bool
    private let closeGate: AccountCloseGate?
    private let failRead: Bool
    private var waiter: CheckedContinuation<CodexAccountSnapshot, any Error>?
    private(set) var reads = 0
    private(set) var closes = 0
    private(set) var sentInputs = 0
    init(hold: Bool = false, closeGate: AccountCloseGate? = nil, failRead: Bool = false) {
        let pair = AsyncStream<ProviderEvent>.makeStream(); events = pair.stream; continuation = pair.continuation
        self.hold = hold
        self.closeGate = closeGate
        self.failRead = failRead
        result = .init(identity: .init(kind: .chatgpt, requiresOpenAIAuth: true, email: "memory-only-account@example.invalid", planType: "pro"),
                       usage: .available(.init(buckets: [.init(id: "codex", primary: .init(usedPercent: 37))], ordinaryUsageAllowed: true)))
    }
    func models() -> [ProviderModel] { [] }
    func codexAccountSnapshot() async throws -> CodexAccountSnapshot {
        reads += 1
        if failRead { throw CoincideError("A synthetic account read failed.") }
        if hold { return try await withCheckedThrowingContinuation { waiter = $0 } }
        return result
    }
    func send(text: String, thread: CodingThread) { sentInputs += 1 }
    func interrupt() { }
    func respond(_ request: ApprovalRequest, allow: Bool) { }
    func answer(_ request: ApprovalRequest, answers: [String: String]) { }
    func close() async {
        closes += 1
        await closeGate?.wait()
        let pending = waiter; waiter = nil; pending?.resume(throwing: CancellationError())
        continuation.finish()
    }
}

@Test(.timeLimit(.minutes(1)), arguments: [false, true])
func codexAccountEngineCancellationWhileClosingCannotPublishALateObservation(failing: Bool) async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("coincide-account-late-\(UUID())")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let gate = AccountCloseGate(), peer = AccountMetadataPeer(closeGate: gate, failRead: failing)
    let engine = try WorkspaceEngine(url: root.appendingPathComponent("workspace.sqlite"), providerFactory: { _ in peer }, identityResolver: { _ in nil })
    let read = Task { try await engine.codexAccountSnapshot() }
    do {
        try await accountEngineEventually { await gate.entered }
        read.cancel(); await gate.release()
        do { _ = try await read.value; Issue.record("A read canceled while closing its session returned an account snapshot.") }
        catch { #expect(error is CancellationError) }
        #expect(await peer.closes == 1)
        await engine.shutdown()
    } catch { read.cancel(); await gate.release(); await engine.shutdown(); _ = try? await read.value; throw error }
}

private func accountEngineEventually(_ predicate: () async -> Bool) async throws {
    let deadline = ContinuousClock.now + .seconds(3)
    while await !predicate() {
        guard ContinuousClock.now < deadline else { throw CoincideError("The account metadata reader did not reach its expected boundary.") }
        try await Task.sleep(for: .milliseconds(5))
    }
}

@Test(.timeLimit(.minutes(1)))
func codexAccountEngineMetadataIsEphemeralAndRetiresItsOwnSession() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("coincide-account-engine-\(UUID())")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let peer = AccountMetadataPeer(), database = root.appendingPathComponent("workspace.sqlite")
    let engine = try WorkspaceEngine(url: database, providerFactory: { thread in
        #expect(thread.provider == .codex && thread.activeRun == nil && thread.providerThreadID == nil)
        #expect(thread.workspacePath == FileManager.default.homeDirectoryForCurrentUser.path)
        return peer
    }, identityResolver: { _ in nil })
    do {
        _ = try await engine.load()
        let before = await engine.current()
        let snapshot = try await engine.codexAccountSnapshot()
        #expect(snapshot.identity.email == "memory-only-account@example.invalid")
        let after = await engine.current()
        #expect(after.sequence == before.sequence && after.snapshot == before.snapshot)
        #expect(await peer.closes == 1)
        #expect(await peer.sentInputs == 0)
        await engine.shutdown()
        #expect(await peer.closes == 1)
        for file in try FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil) {
            if file.lastPathComponent.hasPrefix("workspace.sqlite") {
                #expect(try !Data(contentsOf: file).contains(Data("memory-only-account@example.invalid".utf8)))
            }
        }
    } catch { await engine.shutdown(); throw error }
}

@Test(.timeLimit(.minutes(1)), arguments: ["callerCancellation", "shutdown"])
func codexAccountEngineCancellationDrainsOwnedReaderExactlyOnce(kind: String) async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("coincide-account-drain-\(UUID())")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let peer = AccountMetadataPeer(hold: true)
    let engine = try WorkspaceEngine(url: root.appendingPathComponent("workspace.sqlite"), providerFactory: { _ in peer }, identityResolver: { _ in nil })
    let read = Task { try await engine.codexAccountSnapshot() }
    do {
        try await accountEngineEventually { await peer.reads == 1 }
        if kind == "shutdown" { await engine.shutdown() } else { read.cancel() }
        do { _ = try await read.value; Issue.record("A retired account reader returned a snapshot.") }
        catch { #expect(error is CancellationError) }
        #expect(await peer.closes == 1)
        await engine.shutdown()
        #expect(await peer.closes == 1)
        #expect(await peer.sentInputs == 0)
    } catch { read.cancel(); await engine.shutdown(); _ = try? await read.value; throw error }
}
