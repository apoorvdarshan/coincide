import CoincideCore
import CoincideTerminal
import Foundation

struct ProjectScriptWorkspace {
    let projectRoot: String
    let files: WorkspaceFileService
    var settingsKeys: [String] = []
}

/// A sheet keeps the exact file revision, app-owned actions and conversation incarnation that it displayed.
struct ProjectScriptContext {
    let thread: CodingThread
    let workspace: ProjectScriptWorkspace
    let document: ProjectConfigurationDocument
    var actions: [ProjectAction]? = nil
    var settingsError: String? = nil
    fileprivate let incarnation: UUID
    var catalog: ProjectScriptCatalog { .init(actions: actions, configuration: document.configuration) }
}

/// Discovery only reads a repository file. A dedicated PTY is created solely by an
/// explicit Run action, after re-reading the displayed configuration and ownership.
@MainActor final class NativeProjectScriptService {
    typealias Reader = @Sendable (WorkspaceFileService) async throws -> ProjectConfigurationDocument
    typealias SettingsReader = @Sendable ([String]) throws -> ProjectSettingsDocument?
    private let resolve: (CodingThread) throws -> ProjectScriptWorkspace
    private let authorize: (CodingThread, ProjectScriptWorkspace) -> Bool
    private let authorizeWindow: (TerminalWorkspaceStore) -> Bool
    private let read: Reader
    private let readSettings: SettingsReader
    let preview: ScriptPreviewLauncher
    private struct Read {
        let threadID: UUID
        let task: Task<ProjectConfigurationDocument, any Error>
    }
    private var reads: [UUID: Read] = [:]
    private var incarnations: [UUID: UUID] = [:]
    private var stopping = false

    init(resolve: @escaping (CodingThread) throws -> ProjectScriptWorkspace,
         authorize: @escaping (CodingThread, ProjectScriptWorkspace) -> Bool,
         authorizeWindow: @escaping (TerminalWorkspaceStore) -> Bool,
         read: Reader? = nil, settingsRoot: URL? = nil, preview: ScriptPreviewLauncher? = nil) {
        self.resolve = resolve; self.authorize = authorize; self.authorizeWindow = authorizeWindow
        self.read = read ?? { try await ProjectConfigurationService.load(using: $0) }
        readSettings = { keys in try settingsRoot.flatMap { try ProjectSettingsFiles.load(root: $0, keys: keys)?.document } }
        self.preview = preview ?? ScriptPreviewLauncher()
    }
    func load(for thread: CodingThread) async throws -> ProjectScriptContext {
        guard !stopping else { throw CancellationError() }
        let workspace = try resolve(thread)
        let incarnation = incarnations[thread.id] ?? UUID()
        incarnations[thread.id] = incarnation
        let document = try await loadDocument(threadID: thread.id, files: workspace.files)
        let settings = await loadSettings(workspace.settingsKeys)
        try Task.checkCancellation()
        guard isCurrent(thread: thread, workspace: workspace, incarnation: incarnation) else { throw CancellationError() }
        var context = ProjectScriptContext(thread: thread, workspace: workspace, document: document, incarnation: incarnation)
        switch settings {
        case .success(let value): context.actions = value?.actions
        case .failure(let error): context.settingsError = error.localizedDescription
        }
        return context
    }
    /// Runs an app-owned action exactly as displayed: its stable ID and execution digest must still
    /// match both the loaded context and the current settings file before the PTY is created.
    @discardableResult func run(_ context: ProjectScriptContext, actionID: String, expectedDigest: Data, in terminals: TerminalWorkspaceStore) async throws -> LocalTerminalSession {
        guard isCurrent(context), authorizeWindow(terminals), context.settingsError == nil,
              let displayed = context.actions?.first(where: { $0.id == actionID }) else { throw CancellationError() }
        guard displayed.digest == expectedDigest else { throw CoincideError("The project actions changed. Reload the list before running an action.") }
        let current = try await loadSettings(context.workspace.settingsKeys).get()
        try Task.checkCancellation()
        guard current?.actions?.first(where: { $0.id == actionID })?.digest == expectedDigest else {
            throw CoincideError("The project actions changed. Reload the list before running an action.")
        }
        _ = try await context.workspace.files.metadata()
        try Task.checkCancellation()
        guard isCurrent(context), authorizeWindow(terminals) else { throw CancellationError() }
        let invocation = try invocation(for: try displayed.script(), context: context)
        let session = try terminals.run(invocation, for: context.thread)
        if let script = try? displayed.script() { preview.scheduleAutoOpen(script, session: session) }
        return session
    }
    /// Loads a fresh context and runs the displayed action, so the toolbar keeps the same pinning as the sheet.
    @discardableResult func run(_ action: ProjectAction, thread: CodingThread, in terminals: TerminalWorkspaceStore) async throws -> LocalTerminalSession {
        let context = try await load(for: thread)
        if let error = context.settingsError { throw CoincideError(error) }
        guard context.actions?.contains(where: { $0.id == action.id }) == true else {
            throw CoincideError("The project actions changed. Reload the list before running an action.")
        }
        return try await run(context, actionID: action.id, expectedDigest: action.digest, in: terminals)
    }
    @discardableResult func run(_ context: ProjectScriptContext, scriptIndex: Int, in terminals: TerminalWorkspaceStore) async throws -> LocalTerminalSession {
        guard isCurrent(context), authorizeWindow(terminals),
              let scripts = context.document.configuration?.scripts, scripts.indices.contains(scriptIndex) else { throw CancellationError() }
        let document = try await loadDocument(threadID: context.thread.id, files: context.workspace.files)
        try Task.checkCancellation()
        guard isCurrent(context), authorizeWindow(terminals) else { throw CancellationError() }
        guard document.exists, document.revision == context.document.revision,
              let current = document.configuration?.scripts, current.indices.contains(scriptIndex),
              current[scriptIndex] == scripts[scriptIndex] else {
            throw CoincideError("The project scripts changed. Reload the list before running a script.")
        }
        // A read can complete before this actor resumes. Validate the anchored
        // checkout again so replacement during that gap cannot redirect its PTY.
        _ = try await context.workspace.files.metadata()
        try Task.checkCancellation()
        guard isCurrent(context), authorizeWindow(terminals) else { throw CancellationError() }
        let invocation = try invocation(for: current[scriptIndex], context: context)
        // No suspension from the final ownership check through PTY creation and
        // registration; removal cannot interleave and leave an unowned process.
        let session = try terminals.run(invocation, for: context.thread)
        preview.scheduleAutoOpen(current[scriptIndex], session: session)
        return session
    }
    private func invocation(for script: ProjectScript, context: ProjectScriptContext) throws -> ProjectScriptInvocation {
        let root = URL(fileURLWithPath: context.workspace.projectRoot)
        let checkout = URL(fileURLWithPath: context.thread.workspacePath)
        let worktree = root.standardizedFileURL.resolvingSymlinksInPath() == checkout.standardizedFileURL.resolvingSymlinksInPath() ? nil : checkout
        return try ProjectScriptInvocation(script: script, projectRoot: root, worktreePath: worktree)
    }
    private func loadSettings(_ keys: [String]) async -> Result<ProjectSettingsDocument?, any Error> {
        guard !keys.isEmpty else { return .success(nil) }
        let readSettings = readSettings
        return await Task.detached { Result { try readSettings(keys) } }.value
    }
    @discardableResult func invalidate(threadIDs: Set<UUID>) -> [Task<Void, Never>] {
        for id in threadIDs { incarnations[id] = UUID() }
        return reads.values.filter { threadIDs.contains($0.threadID) }.map { read in
            read.task.cancel()
            return Task { _ = await read.task.result }
        }
    }
    func shutdown() async {
        stopping = true
        preview.shutdown()
        let pending = Array(reads.values)
        for read in pending { read.task.cancel() }
        for read in pending { _ = await read.task.result }
    }
    private func isCurrent(_ context: ProjectScriptContext) -> Bool {
        isCurrent(thread: context.thread, workspace: context.workspace, incarnation: context.incarnation)
    }
    private func isCurrent(thread: CodingThread, workspace: ProjectScriptWorkspace, incarnation: UUID) -> Bool {
        !stopping && incarnations[thread.id] == incarnation && authorize(thread, workspace)
    }
    private func loadDocument(threadID: UUID, files: WorkspaceFileService) async throws -> ProjectConfigurationDocument {
        try Task.checkCancellation()
        let id = UUID(), read = read
        let task = Task { try await read(files) }
        reads[id] = .init(threadID: threadID, task: task)
        defer { reads.removeValue(forKey: id) }
        return try await withTaskCancellationHandler {
            do {
                let document = try await task.value
                try Task.checkCancellation()
                guard !task.isCancelled else { throw CancellationError() }
                return document
            } catch {
                try Task.checkCancellation()
                guard !task.isCancelled else { throw CancellationError() }
                throw error
            }
        } onCancel: { task.cancel() }
    }
}
