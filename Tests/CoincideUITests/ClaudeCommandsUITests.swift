import Foundation
import Testing
@testable import Coincide
@testable import CoincideCore

private actor ClaudeCommandMetadataPeer: ProviderSession {
    nonisolated let events: AsyncStream<ProviderEvent>
    private let continuation: AsyncStream<ProviderEvent>.Continuation
    private let cwd: String
    init(cwd: String) { (events, continuation) = AsyncStream.makeStream(); self.cwd = cwd }
    func models() -> [ProviderModel] { [] }
    func providerCommands(forceReload: Bool) -> ProviderCommandInventory {
        .init(cwd: cwd, commands: [.init(name: "plugin:review", description: "Native Claude metadata", source: "native", hints: ["<focus>"])], skills: [])
    }
    func send(text: String, thread: CodingThread) throws { throw CoincideError("Command discovery must not submit a turn.") }
    func interrupt() {}
    func respond(_ request: ApprovalRequest, allow: Bool) {}
    func answer(_ request: ApprovalRequest, answers: [String: String]) {}
    func close() { continuation.finish() }
}

private final class ClaudeCommandMetadataFactory: @unchecked Sendable {
    private let lock = NSLock()
    private var captures: [CodingThread] = []
    func make(_ thread: CodingThread) -> any ProviderSession {
        lock.withLock { captures.append(thread) }
        return ClaudeCommandMetadataPeer(cwd: thread.workspacePath)
    }
    var launches: [CodingThread] { lock.withLock { captures } }
}

@Test(.timeLimit(.minutes(1))) @MainActor
func nativeClaudeCommandPickerReadsExactRuntimeWithoutResumingOrChangingDraftAndInvalidatesNamespace() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("coincide-claude-command-ui-\(UUID())")
    let workspace = root.appendingPathComponent("Workspace"), configuration = root.appendingPathComponent("Private Configuration")
    try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: configuration, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let project = WorkspaceProject(path: workspace.path), database = root.appendingPathComponent("workspace.sqlite")
    var thread = CodingThread(project: project); thread.provider = .claude; thread.checkpointPolicy = .disabled
    thread.draft = "Unsent draft 工作"; thread.providerThreadID = UUID().uuidString.lowercased()
    let runtime = ClaudeRuntimeConfiguration(executable: "/offline/claude", configurationDirectory: configuration.path,
        projectDirectoryName: "custom-native-project", workspacePath: workspace.path)
    thread.claudeRuntimeConfiguration = runtime
    var snapshot = WorkspaceSnapshot(); snapshot.projects = [project]; snapshot.threads = [thread]
    try await WorkspaceDatabase(url: database).save(snapshot, event: "claude.commands.fixture")
    let factory = ClaudeCommandMetadataFactory()
    let engine = try WorkspaceEngine(url: database, appMCPEnabled: false,
        providerFactory: { factory.make($0) }, identityResolver: { _ in nil })
    let store = WorkspaceStore(engine: engine, codexHostID: UUID())
    do {
        await store.load()
        let before = await engine.current()
        let model = try #require(store.skillsStore(threadID: thread.id))
        #expect(model.supportsCommands && !model.supportsSkills)
        await model.refresh(forceReload: true)
        #expect(model.errorMessage == nil && model.skills.isEmpty)
        let suggestions = ProviderCommandPicker.matching(commands: model.commands, skills: model.skills, query: "plugin:", showSkills: true)
        #expect(suggestions.map(\.token) == ["/plugin:review"])
        let draft = "/pl arguments 工作\n/other stays arguments", caret = NSRange(location: 3, length: 0)
        let anchor = try #require(ComposerCommandMention.trigger(in: draft, selection: caret))
        #expect(anchor.inserting(command: "plugin:review", into: draft, selection: caret)?.text == "/plugin:review arguments 工作\n/other stays arguments")
        let after = await engine.current()
        #expect(before.sequence == after.sequence && before.snapshot == after.snapshot)
        let launch = try #require(factory.launches.first)
        #expect(factory.launches.count == 1 && launch.claudeRuntimeConfiguration == runtime)
        #expect(launch.providerThreadID == nil && launch.claudeResumeSelection == nil && launch.claudeResumeConsumerRunID == nil)
        #expect(launch.activeRun == nil && launch.runtimeID == nil && launch.runtimeRequests.isEmpty && launch.queuedTurns.isEmpty)
        #expect(store.thread(thread.id)?.draft == thread.draft && store.thread(thread.id)?.claudeResumeSelection == thread.claudeResumeSelection)
        let changed = ClaudeRuntimeConfiguration(executable: runtime.executable, configurationDirectory: runtime.configurationDirectory,
            projectDirectoryName: runtime.projectDirectoryName, workspacePath: runtime.workspacePath,
            configurationDirectorySelection: .explicitDirectory(environmentPath: configuration.path + "/."))
        var changedThread = thread; changedThread.claudeRuntimeConfiguration = changed
        #expect(ProviderSkillsStore.Scope(changedThread) != model.scope)
        let journal = try await WorkspaceDatabase(url: database).journal()
        #expect(!String(reflecting: journal).contains("Native Claude metadata"))
        await store.shutdown()
    } catch { await store.shutdown(); throw error }
}
