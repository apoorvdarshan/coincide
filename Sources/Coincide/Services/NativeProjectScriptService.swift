import CoincideCore
import CoincideTerminal
import Foundation

struct ProjectScriptWorkspace {
    let projectRoot: String
    let files: WorkspaceFileService
}

/// A sheet keeps the exact file revision and conversation incarnation that it displayed.
struct ProjectScriptContext {
    let thread: CodingThread
    let workspace: ProjectScriptWorkspace
    let document: ProjectConfigurationDocument
    fileprivate let incarnation: UUID
}

/// Discovery only reads a repository file. A dedicated PTY is created solely by an
/// explicit Run action, after re-reading the displayed configuration and ownership.
@MainActor final class NativeProjectScriptService {
    typealias Reader = @Sendable (WorkspaceFileService) async throws -> ProjectConfigurationDocument
    private let resolve: (CodingThread) throws -> ProjectScriptWorkspace
    private let authorize: (CodingThread, ProjectScriptWorkspace) -> Bool
    private let authorizeWindow: (TerminalWorkspaceStore) -> Bool
    private let read: Reader
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
         read: Reader? = nil) {
        self.resolve = resolve; self.authorize = authorize; self.authorizeWindow = authorizeWindow
        self.read = read ?? { try await ProjectConfigurationService.load(using: $0) }
    }
    func load(for thread: CodingThread) async throws -> ProjectScriptContext {
        guard !stopping else { throw CancellationError() }
        let workspace = try resolve(thread)
        let incarnation = incarnations[thread.id] ?? UUID()
        incarnations[thread.id] = incarnation
        let document = try await loadDocument(threadID: thread.id, files: workspace.files)
        guard isCurrent(thread: thread, workspace: workspace, incarnation: incarnation) else { throw CancellationError() }
        return .init(thread: thread, workspace: workspace, document: document, incarnation: incarnation)
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
        let root = URL(fileURLWithPath: context.workspace.projectRoot)
        let checkout = URL(fileURLWithPath: context.thread.workspacePath)
        let worktree = root.standardizedFileURL.resolvingSymlinksInPath() == checkout.standardizedFileURL.resolvingSymlinksInPath() ? nil : checkout
        let invocation = try ProjectScriptInvocation(script: current[scriptIndex], projectRoot: root, worktreePath: worktree)
        // No suspension from the final ownership check through PTY creation and
        // registration; removal cannot interleave and leave an unowned process.
        return try terminals.run(invocation, for: context.thread)
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
