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
    private var checkpointService: RemoteCheckpointService?
    private var historyService: RemoteHistoryService?
    private var contextService: RemoteContextService?
    private var projectionService: RemoteProjectionService?
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
        .init(environmentID: environmentID, label: label, capabilities: .init(supportsRemoteTerminal: driverFactory != nil, supportsBoundedProjections: true, supportsRemoteHistory: true, supportsContextTransfers: true))
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
            let value = try WorkspaceEngine(url: url, appMCPEnabled: false, contextMCPEnabled: true, providerFactory: factory,
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
            if receipt?.rejection == nil, receipt != nil { await engine.awaitRemotePullRequestCancellation(request); await engine.awaitRemoteHistoryCompletion(request); await engine.awaitRemoteContextCompletion(request) }
            return .init(environmentID: environmentID, receipt: receipt)
        } catch WorkspaceCommitError.commandIDCollision { throw RemoteEnvironmentError(.commandCollision) }
    }
    public func command(_ request: RemoteEnvironmentCommandRequest) async throws -> RemoteEnvironmentCommandResult {
        try require(request.environmentID)
        _ = try RemoteEnvironmentProtocol.payload(request)
        let engine = try await workspace()
        var inspected: RemoteEnvironmentPreparation?
        if request.command.inspectsWorktreeCompletion || request.command.preparesAttachments || request.command.isPullRequestCommand || request.command.isCheckpointCommand || request.command.isHistoryCommand || request.command.isContextTransferCommand {
            do {
                if let receipt = try await engine.remoteEnvironmentReceipt(request) {
                    if receipt.rejection == nil { await engine.awaitRemotePullRequestCancellation(request); await engine.awaitRemoteHistoryCompletion(request); await engine.awaitRemoteContextCompletion(request) }
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
        if result.receipt.rejection == nil { await engine.awaitRemotePullRequestCancellation(request); await engine.awaitRemoteHistoryCompletion(request); await engine.awaitRemoteContextCompletion(request) }
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
                if case .contextTransfer(let prepared) = preparation { try await (try await contexts()).validatePreparation(prepared) }
                if case .history(let prepared) = preparation {
                    let workspace = try await workspaceOperations()
                    try await workspace.validateHistoryTarget(prepared.target, allowLocked: prepared.allowsLockedTarget, requireRoot: prepared.requiresBoundRoot)
                    try await workspace.admitHistoryScope(prepared.scope)
                }
                if case .checkpoint(let prepared) = preparation {
                    let workspace = try await workspaceOperations()
                    try await workspace.validateCheckpointTarget(prepared.target, allowLocked: prepared.allowsLockedTarget, requireRoot: prepared.requiresBoundRoot)
                    try await workspace.admitCheckpointScope(prepared.scope)
                }
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
    private func projections() async throws -> RemoteProjectionService {
        let engine = try await workspace()
        guard !closing else { throw RemoteProjectionFailure(.unavailable) }
        if let projectionService { return projectionService }
        let service = RemoteProjectionService(environmentID: environmentID, engine: engine)
        projectionService = service; return service
    }
    public func openProjection(_ request: RemoteProjectionOpenRequest) async throws -> RemoteProjectionOpenResult {
        try require(request.environmentID)
        return try await (try await projections()).open(request)
    }
    public func projectionCatalog(_ request: RemoteProjectionCatalogRequest) async throws -> RemoteProjectionCatalogResult {
        try require(request.binding.environmentID)
        return try await (try await projections()).catalog(request)
    }
    public func projectionThread(_ request: RemoteProjectionThreadRequest) async throws -> RemoteProjectionThreadResult {
        try require(request.binding.environmentID)
        return try await (try await projections()).thread(request)
    }
    public func projectionMessages(_ request: RemoteProjectionMessagesRequest) async throws -> RemoteProjectionMessagesResult {
        try require(request.binding.environmentID)
        return try await (try await projections()).messages(request)
    }
    public func projectionRuns(_ request: RemoteProjectionRunsRequest) async throws -> RemoteProjectionRunsResult {
        try require(request.binding.environmentID)
        return try await (try await projections()).runs(request)
    }
    public func projectionOperations(_ request: RemoteProjectionOperationsRequest) async throws -> RemoteProjectionOperationsResult {
        try require(request.binding.environmentID)
        return try await (try await projections()).operations(request)
    }
    public func projectionContent(_ request: RemoteProjectionContentRequest) async throws -> RemoteProjectionContentResult {
        try require(request.binding.environmentID)
        return try await (try await projections()).content(request)
    }
    public func projectionRelease(_ request: RemoteProjectionReleaseRequest) async throws -> RemoteProjectionReleaseResult {
        try require(request.binding.environmentID)
        return try await (try await projections()).release(request)
    }
    public func projectionUpdates(hostID: UUID) async throws -> AsyncStream<RemoteProjectionInvalidation> {
        let engine = try await workspace(), id = UUID()
        let pair = AsyncStream<RemoteProjectionInvalidation>.makeStream(bufferingPolicy: .bufferingNewest(1))
        let stream = await engine.updates()
        let environmentID = environmentID
        let task = Task { [weak self] in
            for await update in stream {
                guard !Task.isCancelled, let self, await self.projectionConnectionOpen(), update.error == nil else { break }
                pair.continuation.yield(.init(environmentID: environmentID, hostID: hostID, sequence: update.sequence))
            }
            pair.continuation.finish()
            await self?.removeSubscription(id)
        }
        subscriptions[id] = task
        pair.continuation.onTermination = { _ in task.cancel() }
        return pair.stream
    }
    private func projectionConnectionOpen() -> Bool { !closing }
    private func contexts() async throws -> RemoteContextService {
        let engine = try await workspace(), operations = try await workspaceOperations()
        guard !closing else { throw RemoteContextFailure(.unavailable) }
        if let contextService { return contextService }
        let service = RemoteContextService(environmentID: environmentID, engine: engine, workspace: operations, resolve: { [weak self] destination, source in
            guard let self else { throw RemoteContextFailure(.unavailable) }
            return try await self.captureContextDestination(destination, source: source)
        })
        contextService = service; return service
    }
    public func bindContextWorkspace(_ target: RemoteWorkspaceTarget) async throws -> RemoteWorkspaceTarget {
        try require(target.environmentID)
        return try await (try await workspaceOperations()).bindHistoryTarget(target)
    }
    public func reviewContext(_ request: RemoteContextReviewRequest) async throws -> RemoteContextReview {
        try require(request.target.environmentID)
        return try await (try await contexts()).review(request)
    }
    public func readContext(_ request: RemoteContextReadRequest) async throws -> RemoteContextReadResult {
        try require(request.target.environmentID)
        return try await (try await contexts()).read(request)
    }
    public func discardContextReview(_ request: RemoteContextDiscardRequest) async throws -> RemoteContextDiscardResult {
        try require(request.target.environmentID)
        return try await (try await contexts()).discard(request)
    }
    private func captureContextDestination(_ destination: RemoteContextDestination, source: RemoteWorkspaceTarget) async throws -> ProviderConfiguration {
        try require(source.environmentID)
        let snapshot = await (try await workspace()).current().snapshot
        let path = destination.workspacePath ?? source.workspacePath
        let eligible = snapshot.projects.filter { $0.id == source.projectID }.map(\.path) +
            snapshot.threads.filter { $0.projectID == source.projectID && !$0.isArchived && snapshot.workspaceReady(for: $0) }.map(\.workspacePath)
        guard eligible.contains(where: { $0.utf8.elementsEqual(path.utf8) }),
              path == URL(fileURLWithPath: path).standardizedFileURL.resolvingSymlinksInPath().path,
              destination.model.map({ $0.utf16.count <= 512 && !$0.contains("\0") }) ?? true else { throw RemoteContextFailure(.invalidTarget) }
        let anchor = try WorkspaceFileRoot(root: URL(fileURLWithPath: path)); defer { anchor.close() }
        try anchor.validate()
        let provider = destination.provider ?? source.configuration.provider
        var configuration: ProviderConfiguration
        if provider == source.configuration.provider {
            configuration = source.configuration; configuration.nativeThreadID = nil
            configuration.claudeLaunchSelection = nil; configuration.piFreshSessionIntent = nil
            if let claude = configuration.claudeRuntimeConfiguration {
                configuration.claudeRuntimeConfiguration = try claude.replacingWorkspace(path, physicalPath: ClaudeRuntimeValidation.physical(path, allowMissing: false))
            }
            if let pi = configuration.piConfiguration, let runtime = pi.runtime {
                configuration.piConfiguration = .init(instanceID: pi.instanceID, executable: pi.executable, model: pi.model,
                    thinkingLevel: pi.thinkingLevel, runtime: try runtime.replacingWorkspace(path))
            }
        } else {
            guard [.codex, .claude].contains(provider), let project = snapshot.projects.first(where: { $0.id == source.projectID }) else { throw RemoteContextFailure(.unavailable) }
            var thread = CodingThread(project: project, model: destination.model ?? "")
            thread.provider = provider; thread.workspacePath = path; thread.permission = destination.permission ?? source.configuration.permission
            if provider == .claude {
                thread.claudeRuntimeConfiguration = try ClaudeRuntimeConfiguration.capture(workspacePath: path,
                    executable: options.claudeExecutable, configurationDirectory: options.claudeConfigurationDirectory)
            } else {
                guard let executable = ProcessChannel.findExecutable(options.codexExecutable) else { throw RemoteContextFailure(.unavailable) }
                let home = options.codexHome ?? ProcessChannel.environment()["CODEX_HOME"] ?? NSHomeDirectory() + "/.codex"
                let runtime = CodexRuntimeConfiguration(selection: .custom, executable: executable.path, homeDirectory: home)
                try runtime.validate(); thread.codexRuntimeConfiguration = runtime
            }
            configuration = .init(thread: thread)
        }
        if let model = destination.model, model != configuration.model {
            // Imported provider profiles carry opaque native model selections.
            // A display string cannot manufacture a different native selection.
            if [.opencode, .pi, .muse].contains(provider), !model.isEmpty { throw RemoteContextFailure(.invalidRequest) }
            if model.isEmpty {
                configuration.openCodeConfiguration = configuration.openCodeConfiguration?.selecting(model: nil)
                configuration.piConfiguration = configuration.piConfiguration?.selecting(model: nil)
                configuration.museConfiguration = configuration.museConfiguration?.selecting(model: nil)
            }
            configuration.antigravityConfiguration = configuration.antigravityConfiguration?.selecting(model: model.isEmpty ? nil : model)
            configuration.reasoningEffort = nil
        }
        configuration.workspacePath = path; configuration.model = destination.model ?? configuration.model
        configuration.permission = destination.permission ?? configuration.permission
        try anchor.validate(); return configuration
    }
    private func history() async throws -> RemoteHistoryService {
        let engine = try await workspace(), workspace = try await workspaceOperations()
        guard !closing else { throw RemoteHistoryFailure(.unavailable) }
        if let historyService { return historyService }
        let service = RemoteHistoryService(environmentID: environmentID, engine: engine, workspace: workspace)
        historyService = service; return service
    }
    public func bindHistoryWorkspace(_ target: RemoteWorkspaceTarget) async throws -> RemoteWorkspaceTarget {
        try require(target.environmentID)
        return try await (try await workspaceOperations()).bindHistoryTarget(target)
    }
    public func reviewHistory(_ request: RemoteHistoryReviewRequest) async throws -> RemoteHistoryReview {
        try require(request.target.environmentID)
        return try await (try await history()).review(request)
    }
    public func readHistory(_ request: RemoteHistoryReadRequest) async throws -> RemoteHistoryReadResult {
        try require(request.target.environmentID)
        return try await (try await history()).read(request)
    }
    public func discardHistoryReview(_ request: RemoteHistoryDiscardRequest) async throws -> RemoteHistoryDiscardResult {
        try require(request.target.environmentID)
        return try await (try await history()).discard(request)
    }
    private func checkpoints() async throws -> RemoteCheckpointService {
        let engine = try await workspace()
        guard !closing else { throw RemoteCheckpointFailure(.unavailable) }
        if let checkpointService { return checkpointService }
        let service = RemoteCheckpointService(environmentID: environmentID, engine: engine, workspace: try await workspaceOperations())
        checkpointService = service; return service
    }
    public func bindCheckpointWorkspace(_ target: RemoteWorkspaceTarget) async throws -> RemoteWorkspaceTarget {
        try require(target.environmentID)
        return try await (try await workspaceOperations()).bindCheckpointTarget(target)
    }
    public func readCheckpoints(_ request: RemoteCheckpointReadRequest) async throws -> RemoteCheckpointReadResult {
        try require(request.target.environmentID)
        return try await (try await checkpoints()).read(request)
    }
    public func reviewCheckpointRestore(_ request: RemoteCheckpointReviewRequest) async throws -> RemoteCheckpointReview {
        try require(request.target.environmentID)
        return try await (try await checkpoints()).review(request)
    }
    public func discardCheckpointRestoreReview(_ request: RemoteCheckpointDiscardRequest) async throws -> RemoteCheckpointDiscardResult {
        try require(request.target.environmentID)
        return try await (try await checkpoints()).discard(request)
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
        case .createThread(let id, let projectID, let provider, let title, let model, let permission, let policy):
            guard let project = await engine.current().snapshot.projects.first(where: { $0.id == projectID }),
                  [.codex, .claude].contains(provider) else { throw RemoteEnvironmentError(.invalidRequest) }
            var thread = CodingThread(project: project, model: model)
            thread.id = id; thread.title = title; thread.provider = provider; thread.permission = permission
            thread.checkpointPolicy = policy ?? .disabled
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
        case .checkpoint:
            return try await (try await checkpoints()).prepare(command)
        case .history:
            return try await (try await history()).prepare(command)
        case .contextTransfer:
            return try await (try await contexts()).prepare(command)
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
        case .createThread(_, _, let provider, let title, let model, _, _):
            guard [.codex, .claude].contains(provider) else { throw RemoteEnvironmentError(.unsupported) }
            try text(title, maximum: 512); try text(model, maximum: 512, allowEmpty: true)
        case .editThread(_, let edit, _):
            switch edit { case .draft(let value): try text(value, maximum: 120_000, allowEmpty: true)
            case .title(let value): try text(value, maximum: 512)
            case .model(let value): try text(value, maximum: 512, allowEmpty: true)
            case .permission, .checkpointPolicy: break }
        case .submit(_, let value, _): try text(value, maximum: 120_000)
        case .submitWithAttachments(let target, let value, _, let draft, let uploaded):
            guard target.environmentID == environmentID else { throw RemoteEnvironmentError(.wrongEnvironment) }
            try text(value, maximum: 120_000, allowEmpty: !draft.isEmpty || !uploaded.isEmpty)
            try AttachmentLimits.validate(draft)
            guard draft.count + uploaded.count <= AttachmentLimits.count,
                  Set(uploaded).count == uploaded.count else { throw RemoteEnvironmentError(.invalidRequest) }
        case .contextTransfer(let target, let action):
            guard target.environmentID == environmentID, target.rootID != nil || !action.requiresBoundRoot else { throw RemoteEnvironmentError(.invalidRequest) }
            try ProviderHistoryValidation.path(target.workspacePath)
            switch action {
            case .begin(_, let digest, let title):
                guard CheckpointValidation.digest(digest) else { throw RemoteEnvironmentError(.invalidRequest) }
                if let title { try text(title, maximum: 4_096) }
            case .useFreshContext(_, let ids):
                guard !ids.isEmpty, ids.count <= 32, Set(ids).count == ids.count else { throw RemoteEnvironmentError(.invalidRequest) }
            }
        case .history(let target, let action):
            guard target.environmentID == environmentID, target.rootID != nil || !action.requiresBoundRoot else { throw RemoteEnvironmentError(.invalidRequest) }
            try ProviderHistoryValidation.path(target.workspacePath)
            if case .begin(_, let digest, _) = action, !CheckpointValidation.digest(digest) { throw RemoteEnvironmentError(.invalidRequest) }
            if case .clearMaintenance(_, _, let digest) = action, !CheckpointValidation.digest(digest) { throw RemoteEnvironmentError(.invalidRequest) }
        case .checkpoint(let target, let action):
            guard target.environmentID == environmentID, target.rootID != nil || !action.requiresBoundRoot else { throw RemoteEnvironmentError(.invalidRequest) }
            try ProviderHistoryValidation.path(target.workspacePath)
            if case .beginRestore(_, let digest) = action, !CheckpointValidation.digest(digest) { throw RemoteEnvironmentError(.invalidRequest) }
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
        let subscriptions = Array(subscriptions.values), engine = engine, initializing = initializing, workspaceService = workspaceService, terminalService = terminalService, attachmentService = attachmentService, pullRequestService = pullRequestService, checkpointService = checkpointService, historyService = historyService, contextService = contextService, projectionService = projectionService
        for task in subscriptions { task.cancel() }
        let task = Task {
            await terminalService?.close()
            await projectionService?.close()
            await contextService?.close()
            await historyService?.close()
            await checkpointService?.close()
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
    var isContextTransferCommand: Bool { if case .contextTransfer = self { true } else { false } }
    var isHistoryCommand: Bool { if case .history = self { return true }; return false }
    var isCheckpointCommand: Bool {
        if case .checkpoint = self { return true }; return false
    }
    var isPullRequestCommand: Bool {
        if case .pullRequest = self { return true }
        return false
    }
    var preparesAttachments: Bool {
        if case .submitWithAttachments = self { return true }
        return false
    }
}
