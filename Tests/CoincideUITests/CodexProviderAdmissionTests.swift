import Darwin
import Foundation
import Testing
@testable import Coincide
@testable import CoincideCore

private final class CodexProviderAdmissionStorage: CodexCredentialStorage, @unchecked Sendable {
    private let lock = NSLock()
    private var calls = 0
    var count: Int { lock.withLock { calls } }
    func read(instanceID: UUID) -> Data? { lock.withLock { calls += 1; return nil } }
    func write(_ data: Data, instanceID: UUID) { lock.withLock { calls += 1 } }
    func delete(instanceID: UUID) { lock.withLock { calls += 1 } }
    func createIfAbsent(_ data: Data, instanceID: UUID) -> Bool { lock.withLock { calls += 1; return true } }
}

private actor CodexProviderAdmissionTransport: CodexOAuthTransport {
    func response(for request: URLRequest, maximumBytes: Int) throws -> CodexOAuthHTTPResponse {
        Issue.record("Provider admission must not make an OAuth request.")
        throw CodexOAuthError(.protocolViolation)
    }
}

private final class CodexProviderAdmissionAudit: @unchecked Sendable {
    struct Input: Sendable { let text: String; let configuration: ProviderConfiguration }
    private let lock = NSLock()
    private var constructed: [ProviderConfiguration] = []
    private var delivered: [Input] = []
    var factories: [ProviderConfiguration] { lock.withLock { constructed } }
    var inputs: [Input] { lock.withLock { delivered } }
    func make(_ thread: CodingThread) -> any ProviderSession {
        lock.withLock { constructed.append(.init(thread: thread)) }
        return CodexProviderAdmissionPeer(audit: self)
    }
    func record(_ text: String, thread: CodingThread) {
        lock.withLock { delivered.append(.init(text: text, configuration: .init(thread: thread))) }
    }
}

private actor CodexProviderAdmissionPeer: ProviderSession {
    nonisolated let events: AsyncStream<ProviderEvent>
    private let continuation: AsyncStream<ProviderEvent>.Continuation
    private let audit: CodexProviderAdmissionAudit
    init(audit: CodexProviderAdmissionAudit) {
        self.audit = audit
        let pair = AsyncStream<ProviderEvent>.makeStream(); events = pair.stream; continuation = pair.continuation
    }
    func models() -> [ProviderModel] { [] }
    func send(text: String, thread: CodingThread) throws {
        audit.record(text, thread: thread)
        let run = try #require(thread.activeRun?.id)
        continuation.yield(.context(runID: run, event: .thread("admission-cli-thread")))
        continuation.yield(.context(runID: run, event: .turn("admission-cli-turn")))
        continuation.yield(.context(runID: run, event: .completed(.idle)))
    }
    func interrupt() {}
    func respond(_ request: ApprovalRequest, allow: Bool) {}
    func answer(_ request: ApprovalRequest, answers: [String: String]) {}
    func close() { continuation.finish() }
}

@MainActor private struct CodexProviderAdmissionFixture {
    let root: URL
    let store: WorkspaceStore
    let engine: WorkspaceEngine
    let installation: CodexInstallation
    let storage: CodexProviderAdmissionStorage
    let audit: CodexProviderAdmissionAudit
    let claudeID: UUID
    let unsignedID: UUID
    let cliID: UUID
    let configuration: CodexRuntimeConfiguration

    static func make() async throws -> Self {
        let pointer = try #require(realpath(FileManager.default.temporaryDirectory.path, nil))
        let temporary = URL(fileURLWithPath: String(cString: pointer), isDirectory: true); free(pointer)
        let root = temporary.appendingPathComponent("coincide-codex-provider-admission-" + UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        let executable = root.appendingPathComponent("codex-never-executed")
        try Data("#!/bin/sh\nexit 99\n".utf8).write(to: executable)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: executable.path)
        let project = WorkspaceProject(path: root.path)
        let configuration = CodexRuntimeConfiguration(homeDirectory: root.appendingPathComponent("SharedHome").path,
            authenticationMode: .ownedChatGPT)
        var claude = CodingThread(project: project); claude.provider = .claude; claude.checkpointPolicy = .disabled
        var unsigned = CodingThread(project: project); unsigned.checkpointPolicy = .disabled; unsigned.codexRuntimeConfiguration = configuration
        var cli = CodingThread(project: project); cli.checkpointPolicy = .disabled
        var snapshot = WorkspaceSnapshot(); snapshot.projects = [project]; snapshot.threads = [claude, unsigned, cli]
        let database = root.appendingPathComponent("workspace.sqlite")
        try await WorkspaceDatabase(url: database).save(snapshot, event: "codex.provider.admission.fixture")
        let audit = CodexProviderAdmissionAudit(), storage = CodexProviderAdmissionStorage()
        let engine = try WorkspaceEngine(url: database, providerFactory: { audit.make($0) }, identityResolver: { _ in nil })
        let installation = CodexInstallation(rootURL: root.appendingPathComponent("Tools/Codex"), release: nil,
            downloader: { _, _, _ in Issue.record("Admission tests must not download a provider."); throw CoincideError("Unexpected download") },
            inspector: { _, _ in Issue.record("Admission tests must not execute a provider."); throw CoincideError("Unexpected inspection") },
            localResolver: { _ in executable })
        // WorkspaceStore deliberately constructs an inert controller, which is
        // allowed to construct its client. It must never read credentials or
        // use that client's transport unless the user starts authentication.
        let transport = CodexProviderAdmissionTransport()
        let inertBroker = CodexOwnedRuntimeBroker(storage: storage, lockRoot: root.appendingPathComponent("locks"),
            homesRoot: root.appendingPathComponent("homes"), clientFactory: { CodexOAuthClient(transport: transport) })
        let store = WorkspaceStore(engine: engine, codexInstallation: installation, codexOwnedRuntime: inertBroker,
            codexHostID: UUID(), codexListenerFactory: {
                Issue.record("Provider admission must not open an authentication listener."); throw CancellationError()
            }, codexAuthorization: { _ in
                Issue.record("Provider admission must not open a browser."); throw CancellationError()
            })
        await store.load()
        store.codexRuntime.homeDirectory = configuration.homeDirectory ?? ""
        store.codexRuntime.authenticationMode = .ownedChatGPT
        await store.codexRuntime.applySelection()
        return .init(root: root, store: store, engine: engine, installation: installation, storage: storage, audit: audit,
            claudeID: claude.id, unsignedID: unsigned.id, cliID: cli.id, configuration: configuration)
    }
    func close() async {
        await store.shutdown(); await installation.shutdown()
        try? FileManager.default.removeItem(at: root)
    }
}

@MainActor private func waitCodexProviderAdmission(_ condition: () async -> Bool) async throws {
    let deadline = ContinuousClock.now + .seconds(5)
    while !(await condition()) {
        guard ContinuousClock.now < deadline else { throw CoincideError("The Codex provider admission fixture timed out.") }
        try await Task.sleep(for: .milliseconds(5))
    }
}

@MainActor @Test(.timeLimit(.minutes(1)))
func nativeCodexProviderSwitchDuringAccountChangeCannotCommitAnAmbientCLIIntermediate() async throws {
    let fixture = try await CodexProviderAdmissionFixture.make()
    var lease: UUID?
    do {
        #expect(fixture.store.codexRuntime.configuration == fixture.configuration)
        let before = try #require(fixture.store.thread(fixture.claudeID))
        lease = try await fixture.engine.beginCodexAuthentication(configuration: fixture.configuration)
        fixture.store.setProvider(.codex, id: fixture.claudeID)
        try await waitCodexProviderAdmission { fixture.store.errorMessage != nil }
        let rejected = try #require(fixture.store.thread(fixture.claudeID))
        #expect(rejected.provider == before.provider && rejected.codexRuntimeConfiguration == before.codexRuntimeConfiguration)
        #expect(rejected.messages == before.messages && rejected.queuedTurns == before.queuedTurns && rejected.runtimeID == nil)
        #expect(fixture.audit.factories.isEmpty && fixture.storage.count == 0)
        let heldUpdate = await fixture.engine.current()
        #expect(heldUpdate.error == nil)

        if let lease { await fixture.engine.endCodexAuthentication(leaseID: lease) }; lease = nil
        fixture.store.errorMessage = nil
        fixture.store.setProvider(.codex, id: fixture.claudeID)
        try await waitCodexProviderAdmission {
            fixture.store.thread(fixture.claudeID)?.provider == .codex &&
            fixture.store.thread(fixture.claudeID)?.codexRuntimeConfiguration == fixture.configuration
        }
        let selected = try #require(fixture.store.thread(fixture.claudeID))
        #expect(selected.codexRuntimeConfiguration?.authenticationMode == .ownedChatGPT)
        #expect(selected.codexRuntimeConfiguration?.accountBinding == nil)
        #expect(selected.messages.isEmpty && selected.queuedTurns.isEmpty && selected.activeRun == nil)
        #expect(fixture.store.errorMessage == nil && fixture.audit.factories.isEmpty && fixture.storage.count == 0)
        try WorkspaceJournal.validate(fixture.store.snapshot)
    } catch {
        if let lease { await fixture.engine.endCodexAuthentication(leaseID: lease) }
        await fixture.close(); throw error
    }
    await fixture.close()
}

@MainActor @Test(.timeLimit(.minutes(1)))
func nativeCodexUnsignedOwnedSubmitRejectsWithoutStoppingWorkspaceOrChangingCLIAccount() async throws {
    let fixture = try await CodexProviderAdmissionFixture.make()
    do {
        let input = "Keep this unsigned owned-account draft"
        #expect(await fixture.store.submit(input, threadID: fixture.unsignedID).value == false)
        let rejected = try #require(fixture.store.thread(fixture.unsignedID))
        #expect(rejected.codexRuntimeConfiguration == fixture.configuration && rejected.activeRun == nil)
        #expect(rejected.messages.isEmpty && rejected.queuedTurns.isEmpty && rejected.draft == input)
        #expect(fixture.audit.factories.isEmpty && fixture.storage.count == 0)
        let rejectedUpdate = await fixture.engine.current()
        #expect(rejectedUpdate.error == nil, "An unsigned account is a rejected command, not a fatal workspace error.")

        fixture.store.rename(fixture.cliID, title: "Unrelated CLI conversation remains editable")
        try await waitCodexProviderAdmission { fixture.store.thread(fixture.cliID)?.title == "Unrelated CLI conversation remains editable" }
        #expect(fixture.audit.factories.isEmpty && fixture.store.thread(fixture.cliID)?.codexRuntimeConfiguration == nil)
        #expect(await fixture.store.submit("Explicit unchanged CLI input", threadID: fixture.cliID).value)
        try await waitCodexProviderAdmission {
            fixture.audit.inputs.count == 1 && fixture.store.thread(fixture.cliID)?.runHistory?.last?.status == .completed
        }
        let sent = try #require(fixture.audit.inputs.first)
        #expect(sent.text == "Explicit unchanged CLI input" && sent.configuration.codexRuntimeConfiguration == nil)
        #expect(fixture.audit.factories.count == 1 && fixture.audit.factories.first?.codexRuntimeConfiguration == nil)
        #expect(fixture.storage.count == 0 && fixture.store.thread(fixture.unsignedID)?.codexRuntimeConfiguration == fixture.configuration)
        let finalUpdate = await fixture.engine.current()
        #expect(finalUpdate.error == nil)
        try WorkspaceJournal.validate(fixture.store.snapshot)
    } catch { await fixture.close(); throw error }
    await fixture.close()
}
