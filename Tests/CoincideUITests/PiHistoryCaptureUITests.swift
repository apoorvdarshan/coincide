import Darwin
import Foundation
import Testing
@testable import Coincide
@testable import CoincideCore

private struct NativePiCaptureRequest: Sendable, Equatable {
    let workspace: String
    let executable: String
    let instanceID: UUID
}
private final class NativePiCaptureSource: @unchecked Sendable {
    private let lock = NSLock()
    private let root: String
    private var namespace = "A"
    private var shouldFail = false
    private var reads: [NativePiCaptureRequest] = []
    init(root: String) { self.root = root }
    func setNamespace(_ value: String) { lock.withLock { namespace = value } }
    func fail() { lock.withLock { shouldFail = true } }
    var requests: [NativePiCaptureRequest] { lock.withLock { reads } }
    func capture(_ workspace: String, executable: String, instanceID: UUID) throws -> PiRuntimeConfiguration {
        let (namespace, failure) = lock.withLock {
            reads.append(.init(workspace: workspace, executable: executable, instanceID: instanceID))
            return (self.namespace, shouldFail)
        }
        guard !failure else { throw CoincideError("The synthetic Pi capture was rejected.") }
        let agent = root + "/Agent " + namespace
        return try .init(instanceID: instanceID, executable: "/usr/bin/true", requestedExecutable: executable,
            workspacePath: workspace, homeDirectory: root + "/Private Home", agentDirectory: agent,
            agentDirectorySelection: .explicitDirectory(environmentPath: agent))
    }
}
private actor NativePiCapturePeer: ProviderSession {
    nonisolated let events: AsyncStream<ProviderEvent>
    private let continuation: AsyncStream<ProviderEvent>.Continuation
    let captured: CodingThread
    init(_ captured: CodingThread) {
        self.captured = captured
        let pair = AsyncStream<ProviderEvent>.makeStream(); events = pair.stream; continuation = pair.continuation
    }
    func models() throws -> [ProviderModel] {
        guard let runtime = captured.piConfiguration?.runtime else { throw CoincideError("Pi discovery must receive its committed capture.") }
        let selection = PiModelSelection(provider: "native-provider", modelID: "native-model")
        let name = runtime.agentDirectory.hasSuffix("Agent B") ? "Native namespace B" : "Native namespace A"
        return [.init(id: selection.catalogID, name: name, piSelection: selection, piThinkingLevels: ["off", "high"])]
    }
    func send(text: String, thread: CodingThread) throws { throw CoincideError("The capture fixture must not send a provider input.") }
    func interrupt() {}
    func respond(_ request: ApprovalRequest, allow: Bool) {}
    func answer(_ request: ApprovalRequest, answers: [String: String]) {}
    func close() { continuation.finish() }
}
private final class NativePiCaptureFactory: @unchecked Sendable {
    private let lock = NSLock()
    private var captures: [CodingThread] = []
    var launches: [CodingThread] { lock.withLock { captures } }
    func make(_ thread: CodingThread) -> any ProviderSession {
        lock.withLock { captures.append(thread) }
        return NativePiCapturePeer(thread)
    }
}
@MainActor private struct NativePiCaptureFixture {
    let root: URL
    let database: URL
    let original: CodingThread
    let engine: WorkspaceEngine
    let store: WorkspaceStore
    let capture: NativePiCaptureSource
    let factory: NativePiCaptureFactory
    static func make(legacyPi: Bool = false, heldQueue: Bool = false, capturedPi: Bool = false) async throws -> Self {
        let requested = FileManager.default.temporaryDirectory.appendingPathComponent("coincide-native-pi-capture-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: requested, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        guard let pointer = requested.path.withCString({ realpath($0, nil) }) else { throw CoincideError("The private Pi capture fixture is unavailable.") }
        let root = URL(fileURLWithPath: String(cString: pointer)); free(pointer)
        let workspace = root.appendingPathComponent("Workspace 工作")
        try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let project = WorkspaceProject(path: workspace.path), database = root.appendingPathComponent("workspace.sqlite")
        let capture = NativePiCaptureSource(root: root.path), factory = NativePiCaptureFactory()
        var thread = CodingThread(project: project); thread.checkpointPolicy = .disabled
        if legacyPi || capturedPi {
            let selected = PiModelSelection(provider: "saved-provider", modelID: "saved-model")
            thread.provider = .pi; thread.piConfiguration = .init(instanceID: UUID(), executable: "/usr/bin/true", model: selected, thinkingLevel: "high")
            thread.model = selected.catalogID; thread.permission = .autoAcceptEdits
        }
        if heldQueue {
            // Preserve the registered spelling from WorkspaceProject: Foundation
            // and POSIX realpath can spell this same /var directory differently.
            let request = GitWorktreeRequest(sourcePath: thread.workspacePath, destinationRoot: root.appendingPathComponent("Worktrees").path, selection: .reuse(path: thread.workspacePath))
            var preparation = ThreadWorkspacePreparation(request: request); preparation.phase = .interrupted
            thread.workspacePreparation = preparation; thread.queuePaused = true
            thread.queuedTurns = [.init(id: UUID(), text: "Saved legacy FIFO input", configuration: .init(thread: thread), createdAt: Date(), checkpointPolicy: .disabled)]
        }
        if capturedPi, let selected = thread.piConfiguration {
            // Historical snapshots may contain a current runtime capture while
            // older queued inputs still retain their uncaptured configuration.
            try thread.capturePiRuntime(capture.capture(thread.workspacePath, executable: selected.executable, instanceID: selected.instanceID))
        }
        var snapshot = WorkspaceSnapshot(); snapshot.projects = [project]; snapshot.threads = [thread]
        try WorkspaceJournal.validate(snapshot)
        try await WorkspaceDatabase(url: database).save(snapshot, event: "native.pi.capture.fixture")
        let engine = try WorkspaceEngine(url: database, providerFactory: { factory.make($0) }, identityResolver: { _ in nil })
        let store = WorkspaceStore(engine: engine, codexHostID: UUID(), piRuntimeCapture: {
            try capture.capture($0, executable: $1, instanceID: $2)
        })
        await store.load()
        return .init(root: root, database: database, original: thread, engine: engine, store: store, capture: capture, factory: factory)
    }
    func cleanup() async { await store.shutdown(); try? FileManager.default.removeItem(at: root) }
}
@MainActor private func waitNativePiCapture(file: StaticString = #fileID, line: UInt = #line, _ predicate: () -> Bool) async throws {
    let deadline = ContinuousClock.now + .seconds(5)
    while !predicate() {
        guard ContinuousClock.now < deadline else { throw CoincideError("Native Pi capture fixture timed out at \(file):\(line).") }
        try await Task.sleep(for: .milliseconds(5))
    }
}

@Test(.timeLimit(.minutes(1))) @MainActor
func nativePiProviderSelectionIsUnavailableBeforeAnyCaptureModelDiscoveryOrInput() async throws {
    let fixture = try await NativePiCaptureFixture.make()
    do {
        fixture.store.setDraft("Keep the latest draft 😀", id: fixture.original.id)
        fixture.store.setProvider(.pi, id: fixture.original.id)
        let selected = try #require(fixture.store.thread(fixture.original.id))
        #expect(selected.provider == fixture.original.provider && selected.piConfiguration == nil)
        #expect(fixture.store.errorMessage?.contains("Codex and Claude only") == true)
        #expect(selected.draft == "Keep the latest draft 😀" && selected.messages.isEmpty && selected.activeRun == nil)
        #expect(fixture.factory.launches.isEmpty)
        await fixture.store.refreshModels(provider: .pi)
        #expect(fixture.factory.launches.isEmpty && fixture.capture.requests.isEmpty)
        #expect(fixture.store.modelCatalogErrors[.pi]?.contains("Codex and Claude only") == true)
        let effects = try await WorkspaceDatabase(url: fixture.database).effects()
        #expect(effects.isEmpty)
    } catch { await fixture.cleanup(); throw error }
    await fixture.cleanup()
}

@Test(.timeLimit(.minutes(1)), arguments: [false, true]) @MainActor
func nativePiUnavailableAdmissionPreservesProviderDraftAndAllPreviouslyCapturedQueue(legacyPi: Bool) async throws {
    let fixture = try await NativePiCaptureFixture.make(legacyPi: legacyPi, heldQueue: legacyPi)
    do {
        let draft = "Unsent draft 工作 😀"; fixture.store.setDraft(draft, id: fixture.original.id)
        fixture.capture.fail()
        if legacyPi {
            #expect(!(await fixture.store.submit(draft, threadID: fixture.original.id).value))
            await fixture.store.refreshModels(provider: .pi)
        }
        else { fixture.store.setProvider(.pi, id: fixture.original.id) }
        let current = try #require(fixture.store.thread(fixture.original.id))
        #expect(current.provider == fixture.original.provider && current.piConfiguration == fixture.original.piConfiguration)
        #expect(current.queuedTurns == fixture.original.queuedTurns && current.draft == draft)
        #expect(current.messages.isEmpty && current.activeRun == nil && fixture.factory.launches.isEmpty)
        #expect(fixture.store.errorMessage?.contains("Codex and Claude only") == true && fixture.capture.requests.isEmpty)
        let effects = try await WorkspaceDatabase(url: fixture.database).effects()
        #expect(effects.isEmpty)
    } catch { await fixture.cleanup(); throw error }
    await fixture.cleanup()
}

@Test(.timeLimit(.minutes(1))) @MainActor
func nativePiUnavailableQueuedInputPreservesHistoricalCaptureAndExistingFIFOWithoutRecapturing() async throws {
    let fixture = try await NativePiCaptureFixture.make(legacyPi: true, heldQueue: true, capturedPi: true)
    do {
        let old = try #require(fixture.original.queuedTurns.first), original = try #require(fixture.original.piConfiguration)
        #expect(original.runtime != nil && old.configuration.piConfiguration?.runtime == nil)
        #expect(!(await fixture.store.submit("Newly authored input", threadID: fixture.original.id).value))
        let updated = try #require(fixture.store.thread(fixture.original.id)), native = try #require(updated.piConfiguration)
        let runtime = try #require(native.runtime), request = try #require(fixture.capture.requests.only)
        #expect(updated.queuedTurns == [old])
        #expect(native.instanceID == original.instanceID && native.executable == original.executable)
        #expect(native.model == original.model && native.thinkingLevel == original.thinkingLevel)
        #expect(request.instanceID == original.instanceID && request.executable == original.executable)
        #expect(updated.model == fixture.original.model && updated.permission == fixture.original.permission)
        fixture.capture.setNamespace("B")
        #expect(!(await fixture.store.submit("Another explicit input", threadID: fixture.original.id).value))
        let latest = try #require(fixture.store.thread(fixture.original.id))
        #expect(latest.queuedTurns == [old] && latest.piConfiguration?.runtime == runtime)
        #expect(fixture.capture.requests.count == 1 && latest.activeRun == nil && fixture.factory.launches.isEmpty)
        let effects = try await WorkspaceDatabase(url: fixture.database).effects()
        #expect(effects.isEmpty)
        let persisted = try #require(try await WorkspaceDatabase(url: fixture.database).load().threads.first)
        #expect(persisted.queuedTurns == [old] && persisted.piConfiguration == original)
    } catch { await fixture.cleanup(); throw error }
    await fixture.cleanup()
}

@Test(.timeLimit(.minutes(1))) @MainActor
func nativePiLegacyDiscoveryAndReselectionAreUnavailableWithoutStartingOrRecapturing() async throws {
    let fixture = try await NativePiCaptureFixture.make(legacyPi: true, capturedPi: true)
    do {
        await fixture.store.refreshModels(provider: .pi)
        let first = try #require(fixture.store.thread(fixture.original.id)), original = try #require(fixture.original.piConfiguration)
        let firstRuntime = try #require(first.piConfiguration?.runtime)
        #expect(first.piConfiguration?.instanceID == original.instanceID && first.piConfiguration?.executable == original.executable)
        #expect(first.piConfiguration?.model == original.model && first.piConfiguration?.thinkingLevel == original.thinkingLevel)
        #expect(firstRuntime == original.runtime && fixture.factory.launches.isEmpty)
        #expect(fixture.store.models(for: first).isEmpty)
        #expect(fixture.store.modelCatalogErrors[.pi]?.contains("Codex and Claude only") == true)
        fixture.store.setProvider(.codex, id: first.id)
        try await waitNativePiCapture { fixture.store.thread(first.id)?.provider == .codex }
        fixture.capture.setNamespace("B")
        fixture.store.setProvider(.pi, id: first.id)
        let second = try #require(fixture.store.thread(first.id))
        #expect(second.provider == .codex && second.piConfiguration == nil)
        #expect(fixture.store.errorMessage?.contains("Codex and Claude only") == true)
        await fixture.store.refreshModels(provider: .pi)
        #expect(fixture.factory.launches.isEmpty && fixture.capture.requests.count == 1)
        #expect(second.messages.isEmpty && second.queuedTurns.isEmpty && second.activeRun == nil)
    } catch { await fixture.cleanup(); throw error }
    await fixture.cleanup()
}

private extension Array {
    var only: Element? { count == 1 ? first : nil }
}
