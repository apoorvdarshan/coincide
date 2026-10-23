import Foundation

public struct RemoteEnvironmentOptions: Sendable {
    public let codexExecutable: String
    public let codexHome: String?
    public let claudeExecutable: String
    public let claudeConfigurationDirectory: String?
    public let githubExecutable: String?
    public let githubConfigurationDirectory: String?
    public init(codexExecutable: String = "codex", codexHome: String? = nil,
                claudeExecutable: String = "claude", claudeConfigurationDirectory: String? = nil,
                githubExecutable: String? = nil, githubConfigurationDirectory: String? = nil) {
        self.codexExecutable = codexExecutable; self.codexHome = codexHome
        self.claudeExecutable = claudeExecutable; self.claudeConfigurationDirectory = claudeConfigurationDirectory
        self.githubExecutable = githubExecutable; self.githubConfigurationDirectory = githubConfigurationDirectory
    }
}

/// Owns a headless local Engine. Describing it never opens the workspace or a
/// provider; execution begins only after a caller pins this exact identity.
public actor RemoteEnvironmentService {
    public nonisolated let environmentID: UUID
    private let dataDirectory: URL
    private let label: String
    private let options: RemoteEnvironmentOptions
    private let providerFactory: WorkspaceEngine.ProviderFactory
    private let driverFactory: RemotePTYDriverFactory?
    private var engine: WorkspaceEngine?
    private var workspaceService: RemoteWorkspaceService?
    private var terminalService: RemoteTerminalService?
    private var attachmentService: RemoteAttachmentService?
    private var pullRequestService: RemotePullRequestService?
    private var initializing: Task<WorkspaceEngine, any Error>?
    private var subscriptions: [UUID: Task<Void, Never>] = [:]
    private var closing = false
    private var closeTask: Task<Void, Never>?
    private var workspaceAdmitting = false
    private var workspaceAdmissionWaiters: [(UUID, CheckedContinuation<Void, any Error>)] = []
    private func acquireWorkspaceAdmission() async throws {
        try Task.checkCancellation()
        guard !closing else { throw RemoteWorkspaceFailure(.unavailable) }
        if !workspaceAdmitting { workspaceAdmitting = true; return }
        let id = UUID()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { workspaceAdmissionWaiters.append((id, $0)) }
        } onCancel: { Task { await self.cancelWorkspaceAdmission(id) } }
    }
    private func cancelWorkspaceAdmission(_ id: UUID) {
        guard let index = workspaceAdmissionWaiters.firstIndex(where: { $0.0 == id }) else { return }
        workspaceAdmissionWaiters.remove(at: index).1.resume(throwing: CancellationError())
    }
    private func releaseWorkspaceAdmission() {
        if workspaceAdmissionWaiters.isEmpty { workspaceAdmitting = false }
        else { workspaceAdmissionWaiters.removeFirst().1.resume() }
    }

    public init(dataDirectory: URL, label: String = ProcessInfo.processInfo.hostName,
                expectedEnvironmentID: UUID? = nil, options: RemoteEnvironmentOptions = .init(),
                providerFactory: @escaping WorkspaceEngine.ProviderFactory = { try ProviderSessions.make(for: $0) },
                driverFactory: RemotePTYDriverFactory? = nil) throws {
        guard !label.isEmpty, label.utf8.count <= 256,
              !label.unicodeScalars.contains(where: { $0.value < 32 || $0.value == 127 }) else { throw RemoteEnvironmentError(.invalidRequest) }
        environmentID = try RemoteEnvironmentIdentity.load(dataDirectory: dataDirectory, expected: expectedEnvironmentID)
        self.dataDirectory = dataDirectory; self.label = label; self.options = options; self.providerFactory = providerFactory; self.driverFactory = driverFactory
    }
    public func descriptor() -> RemoteEnvironmentDescriptor {
        .init(environmentID: environmentID, label: label, capabilities: .init(supportsRemoteTerminal: driverFactory != nil))
    }
    private func require(_ id: UUID) throws {
        guard id == environmentID else { throw RemoteEnvironmentError(.wrongEnvironment) }
        guard !closing else { throw RemoteEnvironmentError(.unavailable) }
    }
    private func workspace() async throws -> WorkspaceEngine {
        guard !closing else { throw RemoteEnvironmentError(.unavailable) }
        if let engine { return engine }
        if let initializing { return try await initializing.value }
        let url = dataDirectory.appendingPathComponent("workspace.sqlite"), factory = providerFactory, options = options
        let task = Task {
            var githubEnvironment = ProcessChannel.environment()
            if let directory = options.githubConfigurationDirectory { githubEnvironment["GH_CONFIG_DIR"] = directory }
            let githubExecutable = options.githubExecutable.flatMap(ProcessChannel.findExecutable) ?? (options.githubExecutable == nil ? ProcessChannel.findExecutable("gh") : nil)
            let inherited = githubEnvironment
            let value = try WorkspaceEngine(url: url, appMCPEnabled: false, providerFactory: factory,
                pullRequestFactory: { GitHubPullRequestService(root: $0, environment: inherited, githubExecutable: githubExecutable) },
                pullRequestCheckoutFactory: { GitHubPullRequestCheckoutService(request: $0, environment: inherited, githubExecutable: githubExecutable) })
            do { _ = try await value.load(); return value }
            catch { await value.shutdown(); throw error }
        }
        initializing = task
        do {
            let value = try await task.value
            initializing = nil
            guard !closing else { await value.shutdown(); throw RemoteEnvironmentError(.unavailable) }
            engine = value; return value
        } catch { initializing = nil; throw error }
    }
    public func snapshot(_ request: RemoteEnvironmentSnapshotRequest) async throws -> RemoteEnvironmentSnapshot {
        try require(request.environmentID)
        guard request.afterSequence.map({ $0 >= 0 }) ?? true else { throw RemoteEnvironmentError(.invalidRequest) }
        let update = await (try await workspace()).current()
        guard request.afterSequence.map({ $0 <= update.sequence }) ?? true else { throw RemoteEnvironmentError(.invalidRequest) }
        return try checked(update)
    }
    private func checked(_ update: WorkspaceUpdate) throws -> RemoteEnvironmentSnapshot {
        guard update.error == nil else { throw RemoteEnvironmentError(.unavailable) }
        let value = RemoteEnvironmentSnapshot(environmentID: environmentID, sequence: update.sequence, workspace: update.snapshot)
        _ = try RemoteEnvironmentProtocol.encode(value)
        return value
    }
    public func receipt(_ request: RemoteEnvironmentCommandRequest) async throws -> RemoteEnvironmentReceiptResult {
        try require(request.environmentID)
        do {
            let engine = try await workspace(), receipt = try await engine.remoteEnvironmentReceipt(request)
            if receipt?.rejection == nil, receipt != nil { await engine.awaitRemotePullRequestCancellation(request) }
            return .init(environmentID: environmentID, receipt: receipt)
        } catch WorkspaceCommitError.commandIDCollision { throw RemoteEnvironmentError(.commandCollision) }
    }
    public func command(_ request: RemoteEnvironmentCommandRequest) async throws -> RemoteEnvironmentCommandResult {
        try require(request.environmentID)
        _ = try RemoteEnvironmentProtocol.payload(request)
        let engine = try await workspace()
        var inspected: RemoteEnvironmentPreparation?
        if request.command.inspectsWorktreeCompletion || request.command.preparesAttachments || request.command.isPullRequestCommand {
            do {
                if let receipt = try await engine.remoteEnvironmentReceipt(request) {
                    if receipt.rejection == nil { await engine.awaitRemotePullRequestCancellation(request) }
                    return .init(environmentID: environmentID, receipt: receipt)
                }
            } catch WorkspaceCommitError.commandIDCollision { throw RemoteEnvironmentError(.commandCollision) }
            // Saved-plan inspection can wait for native Git. It owns a bounded
            // task in Engine, outside the short command/mutation admission lane.
            do { try validate(request.command); inspected = try await prepare(request.command, engine: engine) }
            catch is CancellationError { throw CancellationError() }
            catch { inspected = .refused }
        }
        let result = try await commitCommand(request, engine: engine, inspected: inspected)
        if result.receipt.rejection == nil { await engine.awaitRemotePullRequestCancellation(request) }
        return result
    }
    private func commitCommand(_ request: RemoteEnvironmentCommandRequest, engine: WorkspaceEngine,
                               inspected: RemoteEnvironmentPreparation?) async throws -> RemoteEnvironmentCommandResult {
        try await acquireWorkspaceAdmission()
        defer { releaseWorkspaceAdmission() }
        try Task.checkCancellation()
        try require(request.environmentID)
        _ = try RemoteEnvironmentProtocol.payload(request)
        do {
            // A durable original receipt wins before native runtime recapture or
            // filesystem preparation, even when the host has since changed.
            if let receipt = try await engine.remoteEnvironmentReceipt(request) { return .init(environmentID: environmentID, receipt: receipt) }
            var preparation: RemoteEnvironmentPreparation = .none
            do {
                try await workspaceService?.admitConversationCommand(request.command)
                try validate(request.command)
                if let inspected { preparation = inspected }
                else { preparation = try await prepare(request.command, engine: engine) }
                if case .pullRequest(let prepared) = preparation {
                    let workspace = try await workspaceOperations()
                    let requiresRoot: Bool
                    if case .pullRequest(_, let action) = request.command { requiresRoot = action.requiresBoundRoot } else { requiresRoot = true }
                    try await workspace.validatePullRequestTarget(prepared.target, allowLocked: prepared.allowsLockedTarget, requireRoot: requiresRoot)
                    try await workspace.admitPullRequestScope(prepared.scope)
                }
            } catch is CancellationError { throw CancellationError() }
            catch { preparation = .refused }
            try require(request.environmentID)
            let receipt = try await engine.dispatchRemoteEnvironment(request, preparation: preparation)
            return .init(environmentID: environmentID, receipt: receipt)
        } catch WorkspaceCommitError.commandIDCollision { throw RemoteEnvironmentError(.commandCollision) }
    }
    private func workspaceOperations() async throws -> RemoteWorkspaceService {
        let engine = try await workspace()
        guard !closing else { throw RemoteWorkspaceFailure(.unavailable) }
        if let workspaceService { return workspaceService }
        let service = try RemoteWorkspaceService(environmentID: environmentID, engine: engine, dataDirectory: dataDirectory)
        workspaceService = service; return service
    }
    private func attachments() async throws -> RemoteAttachmentService {
        let engine = try await workspace()
        guard !closing else { throw RemoteAttachmentFailure(.unavailable) }
        if let attachmentService { return attachmentService }
        let service = try RemoteAttachmentService(environmentID: environmentID, engine: engine, dataDirectory: dataDirectory)
        attachmentService = service; return service
    }
    private func pullRequests() async throws -> RemotePullRequestService {
        let engine = try await workspace(), workspace = try await workspaceOperations()
        guard !closing else { throw RemotePullRequestFailure(.unavailable) }
        if let pullRequestService { return pullRequestService }
        let service = RemotePullRequestService(environmentID: environmentID, engine: engine, workspace: workspace)
        pullRequestService = service; return service
    }
    public func readPullRequests(_ request: RemotePullRequestReadRequest) async throws -> RemotePullRequestReadResult {
        try require(request.target.environmentID)
        return try await (try await pullRequests()).read(request)
    }
    public func bindPullRequestWorkspace(_ target: RemoteWorkspaceTarget) async throws -> RemoteWorkspaceTarget {
        try require(target.environmentID)
        return try await (try await workspaceOperations()).bindPullRequestTarget(target)
    }
    public func reviewPullRequest(_ request: RemotePullRequestReviewRequest) async throws -> RemotePullRequestReview {
        try require(request.target.environmentID)
        return try await (try await pullRequests()).review(request)
    }
    public func discardPullRequestReview(_ request: RemotePullRequestDiscardRequest) async throws -> RemotePullRequestDiscardResult {
        try require(request.target.environmentID)
        return try await (try await pullRequests()).discard(request)
    }
    public func beginAttachmentUpload(_ request: RemoteAttachmentUploadRequest) async throws -> RemoteAttachmentUpload {
        try require(request.target.environmentID)
        return try await (try await attachments()).begin(request)
    }
    public func attachmentUploadStatus(_ request: RemoteAttachmentUploadRequest) async throws -> RemoteAttachmentUpload? {
        try require(request.target.environmentID)
        return try await (try await attachments()).status(request)
    }
    public func appendAttachmentChunk(_ request: RemoteAttachmentChunkRequest) async throws -> RemoteAttachmentUpload {
        try require(request.upload.target.environmentID)
        return try await (try await attachments()).append(request)
    }
    public func finalizeAttachmentUpload(_ request: RemoteAttachmentUploadRequest) async throws -> RemoteAttachmentUpload {
        try require(request.target.environmentID)
        return try await (try await attachments()).finalize(request)
    }
    public func cancelAttachmentUpload(_ request: RemoteAttachmentUploadRequest) async throws -> RemoteAttachmentUpload? {
        try require(request.target.environmentID)
        return try await (try await attachments()).cancel(request)
    }
    public func downloadAttachment(_ request: RemoteAttachmentDownloadRequest) async throws -> RemoteAttachmentDownloadResult {
        try require(request.target.environmentID)
        return try await (try await attachments()).download(request)
    }
    public func bindWorkspace(_ target: RemoteWorkspaceTarget) async throws -> RemoteWorkspaceTarget {
        try require(target.environmentID)
        return try await (try await workspaceOperations()).bind(target)
    }
    public func readWorkspace(_ request: RemoteWorkspaceReadRequest) async throws -> RemoteWorkspaceReadResult {
        try require(request.target.environmentID)
        return try await (try await workspaceOperations()).read(request)
    }
    public func beginWorkspaceOperation(_ request: RemoteWorkspaceMutationRequest) async throws -> RemoteWorkspaceOperation {
        try await acquireWorkspaceAdmission()
        defer { releaseWorkspaceAdmission() }
        try Task.checkCancellation()
        try require(request.target.environmentID)
        return try await (try await workspaceOperations()).begin(request)
    }
    public func workspaceOperation(_ request: RemoteWorkspaceMutationRequest) async throws -> RemoteWorkspaceOperation? {
        try require(request.target.environmentID)
        return try await (try await workspaceOperations()).operation(request)
    }
    public func cancelWorkspaceOperation(_ request: RemoteWorkspaceMutationRequest) async throws -> RemoteWorkspaceOperation? {
        try require(request.target.environmentID)
        return try await (try await workspaceOperations()).cancel(request)
    }
    private func terminals() async throws -> RemoteTerminalService {
        guard !closing, let driverFactory else { throw RemoteTerminalFailure(.unavailable) }
        let workspace = try await workspaceOperations()
        guard !closing else { throw RemoteTerminalFailure(.unavailable) }
        if let terminalService { return terminalService }
        let service = try RemoteTerminalService(workspace: workspace, factory: driverFactory, dataDirectory: dataDirectory)
        terminalService = service; return service
    }
    public func openTerminal(_ request: RemoteTerminalOpenRequest) async throws -> RemoteTerminalSnapshot {
        try await acquireWorkspaceAdmission()
        defer { releaseWorkspaceAdmission() }
        try Task.checkCancellation(); try require(request.target.environmentID)
        return try await (try await terminals()).open(request)
    }
    public func attachTerminal(_ reference: RemoteTerminalReference) async throws -> RemoteTerminalSnapshot {
        try require(reference.target.environmentID)
        return try await (try await terminals()).attach(reference)
    }
    public func readTerminal(_ request: RemoteTerminalReadRequest) async throws -> RemoteTerminalReadResult {
        try require(request.reference.target.environmentID)
        return try await (try await terminals()).read(request)
    }
    public func writeTerminal(_ request: RemoteTerminalInputRequest) async throws -> RemoteTerminalInputReceipt {
        try require(request.reference.target.environmentID)
        return try await (try await terminals()).write(request)
    }
    public func terminalInputReceipt(_ request: RemoteTerminalInputReceiptRequest) async throws -> RemoteTerminalInputReceipt? {
        try require(request.reference.target.environmentID)
        return try await (try await terminals()).inputReceipt(request)
    }
    public func resizeTerminal(_ request: RemoteTerminalResizeRequest) async throws -> RemoteTerminalSnapshot {
        try require(request.reference.target.environmentID)
        return try await (try await terminals()).resize(request)
    }
    public func closeTerminal(_ reference: RemoteTerminalReference) async throws -> RemoteTerminalSnapshot {
        try require(reference.target.environmentID)
        return try await (try await terminals()).close(reference)
    }
    public func listTerminals(_ target: RemoteWorkspaceTarget) async throws -> [RemoteTerminalSnapshot] {
        try require(target.environmentID)
        return try await (try await terminals()).list(target)
    }
    public func worktreeCatalog(_ request: RemoteWorktreeCatalogRequest) async throws -> RemoteWorktreeCatalog {
        try require(request.target.environmentID)
        let engine = try await workspace(), initial = await engine.current().snapshot
        let thread = try RemoteEnvironmentAdmission.worktreeTarget(request.target, environmentID: environmentID, snapshot: initial)
        guard thread.messages.isEmpty, !thread.isBusy, thread.queuedTurns.isEmpty, thread.settlement == nil,
              thread.workspacePreparation?.isRunning != true else { throw RemoteEnvironmentError(.invalidRequest) }
        let operations = try await workspaceOperations()
        let source = try await operations.bindWorktreeSource(request.target)
        let target = request.target
        let anchor = try WorkspaceFileRoot(root: URL(fileURLWithPath: source.sourcePath))
        defer { anchor.close() }
        async let branches = GitService(root: URL(fileURLWithPath: source.sourcePath)).branchDetails()
        async let inventory = GitWorktreeService(source: URL(fileURLWithPath: source.sourcePath), timeout: .seconds(15)).inventory()
        let (allBranches, registered) = try await (branches, inventory)
        guard allBranches.count <= 10_000, registered.worktrees.count <= 10_000 else { throw RemoteEnvironmentError(.limitExceeded) }
        try Task.checkCancellation(); try anchor.validate()
        let current = try RemoteEnvironmentAdmission.worktreeTarget(target, environmentID: environmentID, snapshot: await engine.current().snapshot)
        guard current.workspacePreparation?.id == thread.workspacePreparation?.id, current.messages.isEmpty,
              !current.isBusy, current.queuedTurns.isEmpty else { throw RemoteEnvironmentError(.invalidRequest) }
        try await operations.validateWorktreeSource(target, sourceRootID: source.sourceRootID, expectedAttemptID: source.attemptID)
        let value = RemoteWorktreeCatalog(target: target, sourcePath: source.sourcePath, sourceRootID: source.sourceRootID, attemptID: source.attemptID, branches: allBranches.filter { !$0.isRemote },
            worktrees: registered.worktrees.filter { !$0.isBare && !$0.isDetached && $0.prunableReason == nil && $0.branch != nil && $0.headCommit != nil })
        _ = try RemoteEnvironmentProtocol.encode(value)
        return value
    }
    private func prepare(_ command: RemoteEnvironmentCommand, engine: WorkspaceEngine) async throws -> RemoteEnvironmentPreparation {
        switch command {
        case .addProject(let id, let path, let title):
            var isDirectory: ObjCBool = false
            guard FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory), isDirectory.boolValue else { throw RemoteEnvironmentError(.invalidRequest) }
            var project = WorkspaceProject(path: path); project.id = id
            if let title { project.name = title }
            return .project(project)
        case .createThread(let id, let projectID, let provider, let title, let model, let permission):
            guard let project = await engine.current().snapshot.projects.first(where: { $0.id == projectID }),
                  [.codex, .claude].contains(provider) else { throw RemoteEnvironmentError(.invalidRequest) }
            var thread = CodingThread(project: project, model: model)
            thread.id = id; thread.title = title; thread.provider = provider; thread.permission = permission
            thread.checkpointPolicy = .disabled
            if provider == .claude {
                thread.claudeRuntimeConfiguration = try ClaudeRuntimeConfiguration.capture(workspacePath: project.path,
                    executable: options.claudeExecutable, configurationDirectory: options.claudeConfigurationDirectory)
            } else {
                guard let executable = ProcessChannel.findExecutable(options.codexExecutable) else { throw RemoteEnvironmentError(.unavailable) }
                let home = options.codexHome ?? ProcessChannel.environment()["CODEX_HOME"] ?? NSHomeDirectory() + "/.codex"
                let captured = CodexRuntimeConfiguration(selection: .custom, executable: executable.path, homeDirectory: home)
                try captured.validate(); thread.codexRuntimeConfiguration = captured
            }
            return .thread(thread)
        case .prepareWorktree(let target, let sourceRootID, let expectedAttemptID, _, _):
            let identity = try await (try await workspaceOperations()).validateWorktreeSource(target, sourceRootID: sourceRootID, expectedAttemptID: expectedAttemptID)
            return try await engine.prepareRemoteWorktree(command, expectedSourceIdentity: identity)
        case .retryWorktree, .inspectWorktree:
            return try await engine.prepareRemoteWorktree(command)
        case .submitWithAttachments:
            return try await engine.prepareRemoteAttachmentSubmission(command)
        case .pullRequest:
            return try await (try await pullRequests()).prepare(command)
        default: return .none
        }
    }
    private func validate(_ command: RemoteEnvironmentCommand) throws {
        func text(_ value: String, maximum: Int, allowEmpty: Bool = false) throws {
            guard value.utf16.count <= maximum, !value.contains("\0"), allowEmpty || !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw RemoteEnvironmentError(.invalidRequest)
            }
        }
        switch command {
        case .addProject(_, let path, let title):
            try ProviderHistoryValidation.path(path); if let title { try text(title, maximum: 512) }
        case .createThread(_, _, let provider, let title, let model, _):
            guard [.codex, .claude].contains(provider) else { throw RemoteEnvironmentError(.unsupported) }
            try text(title, maximum: 512); try text(model, maximum: 512, allowEmpty: true)
        case .editThread(_, let edit, _):
            switch edit { case .draft(let value): try text(value, maximum: 120_000, allowEmpty: true)
            case .title(let value): try text(value, maximum: 512)
            case .model(let value): try text(value, maximum: 512, allowEmpty: true)
            case .permission: break }
        case .submit(_, let value, _): try text(value, maximum: 120_000)
        case .submitWithAttachments(let target, let value, _, let draft, let uploaded):
            guard target.environmentID == environmentID else { throw RemoteEnvironmentError(.wrongEnvironment) }
            try text(value, maximum: 120_000, allowEmpty: !draft.isEmpty || !uploaded.isEmpty)
            try AttachmentLimits.validate(draft)
            guard draft.count + uploaded.count <= AttachmentLimits.count,
                  Set(uploaded).count == uploaded.count else { throw RemoteEnvironmentError(.invalidRequest) }
        case .pullRequest(let target, let action):
            guard target.environmentID == environmentID, target.rootID != nil || !action.requiresBoundRoot else { throw RemoteEnvironmentError(.invalidRequest) }
            try ProviderHistoryValidation.path(target.workspacePath)
            if case .begin(_, let digest) = action, !CheckpointValidation.digest(digest) { throw RemoteEnvironmentError(.invalidRequest) }
        case .prepareWorktree(let target, _, _, let selection, let submodules):
            guard target.environmentID == environmentID else { throw RemoteEnvironmentError(.wrongEnvironment) }
            try GitWorktreeRequest(sourcePath: target.workspacePath, destinationRoot: dataDirectory.appendingPathComponent("Worktrees").path,
                selection: selection, submodules: submodules).validate()
        case .retryWorktree(let target, _), .cancelWorktree(let target, _), .inspectWorktree(let target, _):
            guard target.environmentID == environmentID else { throw RemoteEnvironmentError(.wrongEnvironment) }
            try ProviderHistoryValidation.path(target.workspacePath)
        case .stop, .respond, .resumeQueue: break
        }
    }
    public func updates() async throws -> AsyncStream<RemoteEnvironmentSnapshot> {
        let engine = try await workspace(), id = UUID()
        let pair = AsyncStream<RemoteEnvironmentSnapshot>.makeStream(bufferingPolicy: .bufferingNewest(1))
        let stream = await engine.updates()
        let task = Task { [weak self] in
            for await update in stream {
                guard !Task.isCancelled, let self else { break }
                do { pair.continuation.yield(try await self.checked(update)) }
                catch { break }
            }
            pair.continuation.finish()
            await self?.removeSubscription(id)
        }
        subscriptions[id] = task
        pair.continuation.onTermination = { _ in task.cancel() }
        return pair.stream
    }
    private func removeSubscription(_ id: UUID) { subscriptions.removeValue(forKey: id) }
    public func close() async {
        if let closeTask { await closeTask.value; return }
        closing = true
        let waiting = workspaceAdmissionWaiters; workspaceAdmissionWaiters = []
        for waiter in waiting { waiter.1.resume(throwing: RemoteWorkspaceFailure(.unavailable)) }
        let subscriptions = Array(subscriptions.values), engine = engine, initializing = initializing, workspaceService = workspaceService, terminalService = terminalService, attachmentService = attachmentService, pullRequestService = pullRequestService
        for task in subscriptions { task.cancel() }
        let task = Task {
            await terminalService?.close()
            await pullRequestService?.close()
            await workspaceService?.close()
            await attachmentService?.close()
            if let engine { await engine.shutdown() }
            else if let initializing, let value = try? await initializing.value { await value.shutdown() }
            for task in subscriptions { await task.value }
        }
        closeTask = task; await task.value
        self.engine = nil; self.subscriptions = [:]
    }
}

extension RemoteEnvironmentCommand {
    var isPullRequestCommand: Bool {
        if case .pullRequest = self { return true }
        return false
    }
    var preparesAttachments: Bool {
        if case .submitWithAttachments = self { return true }
        return false
    }
}
