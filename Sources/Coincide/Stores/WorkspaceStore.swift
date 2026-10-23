import AppKit
import CoincideCore
import CoincideTerminal
import Observation
import UniformTypeIdentifiers

struct FileNavigation: Equatable {
    let id = UUID()
    let workspacePath: String
    let path: String
    let line: Int?
    let utf16Column: Int?
    let utf16Length: Int?
    init(workspacePath: String, path: String, line: Int?, utf16Column: Int? = nil, utf16Length: Int? = nil) {
        self.workspacePath = workspacePath; self.path = path; self.line = line
        self.utf16Column = utf16Column; self.utf16Length = utf16Length
    }
}

struct ProjectRemovalRequest: Identifiable {
    let id: UUID
    let name: String
    let path: String
    let threadIDs: [UUID]
    let dirtyEditorIDs: Set<UUID>
}

struct ProjectGroupRemovalRequest: Identifiable {
    let id: String
    let name: String
    let projects: [ProjectGroupMemberReference]
    let threadIDs: [UUID]
    let dirtyEditorIDs: Set<UUID>
}

private struct ProjectRemovalCleanup {
    let projectIDs: Set<UUID>
    let task: Task<Void, Never>
}

private struct WorkspaceFileCleanup {
    let projectIDs: Set<UUID>
    let task: Task<Void, Never>
}

private struct WorktreeOptionsRead {
    let threadID: UUID
    let task: Task<WorktreeSetupOptions, any Error>
}

private struct ConversationHistoryRead {
    let threadID: UUID
    let task: Task<ConversationHistoryReview, any Error>
}

private struct CodexModelDefaultsRead {
    let id: UUID
    let task: Task<Bool, Never>
}

private struct CodexWorkspaceAuthenticationLease {
    let instanceID: UUID
    let engineLeaseID: UUID
    let runtimeLease: CodexRuntimeAdmissionLease
}

private struct CheckpointRestoreRead {
    let threadID: UUID
    let task: Task<RunCheckpointRestoreReview, any Error>
}

private struct CheckpointRestoreInspection {
    let threadID: UUID
    let task: Task<WorkspaceCommandReceipt, any Error>
}

private struct ConversationHistoryInspection {
    let threadID: UUID
    let task: Task<WorkspaceCommandReceipt, any Error>
}

private struct PiHistoryResponse {
    let operationID: UUID
    let sessionID: UUID
    let request: ApprovalRequest
    let owner: ConversationHistoryInspection
}

private struct PiFreshHistoryInspection {
    let intent: PiFreshSessionIntent
    let consumerRunID: UUID
    let task: Task<(PiFreshSessionInspection, WorkspaceCommandReceipt?), any Error>
}

private struct PiFreshHistoryObservation {
    let intent: PiFreshSessionIntent
    let consumerRunID: UUID
    let result: PiFreshSessionInspection
}

@MainActor private final class WeakTerminalStore {
    weak var value: TerminalWorkspaceStore?
    init(_ value: TerminalWorkspaceStore) { self.value = value }
}

@MainActor @Observable
final class WorkspaceStore {
    typealias ProjectCreator = @Sendable (String, URL) async throws -> ManagedProjectCreationResult
    typealias ClaudeRuntimeCapture = @Sendable (String) throws -> ClaudeRuntimeConfiguration
    typealias PiRuntimeCapture = @Sendable (String, String, UUID) throws -> PiRuntimeConfiguration
    let managedProjectsRoot: URL
    let worktreesRoot: URL
    let composerDraftTools: ComposerDraftToolsStore
    let agentSessionImports: AgentSessionImportStore
    let projectSettings: ProjectSettingsStore
    @ObservationIgnored private var agentSessionImportScans: [UUID: [AgentSessionProjectCandidate]] = [:]
    @ObservationIgnored private var agentSessionImportProjects: [UUID: [UUID: UUID]] = [:]
    private let projectCreator: ProjectCreator
    private let projectScriptReader: NativeProjectScriptService.Reader
    @ObservationIgnored private let claudeRuntimeCapture: ClaudeRuntimeCapture
    @ObservationIgnored private let piRuntimeCapture: PiRuntimeCapture
    var snapshot = WorkspaceSnapshot()
    @ObservationIgnored private var contextTransferStores: [UUID: ContextTransferStore] = [:]
    @ObservationIgnored lazy var notifications = NativeThreadNotifications { [weak self] id in
        guard let self, !self.terminating, let thread = self.thread(id), !thread.isArchived,
              self.snapshot.projects.contains(where: { $0.id == thread.projectID }) else { return }
        self.selectedProjectID = thread.projectID; self.showArchived = false; self.selectedThreadID = id
        _ = NSApp?.delegate?.applicationShouldHandleReopen?(NSApplication.shared, hasVisibleWindows: false)
        NSApp?.activate(ignoringOtherApps: true)
    }
    var selectedThreadID: UUID? {
        didSet {
            if selectedThreadID != oldValue {
                historyNavigationRequests = historyNavigationRequests.filter { $0.value == selectedThreadID }
                pullRequestCheckoutNavigation = pullRequestCheckoutNavigation.filter { $0.value == selectedThreadID }
            }
            guard !isLoading, !terminating, selectedThreadID != oldValue,
                  selectedThreadID.map({ id in snapshot.threads.contains { $0.id == id } }) ?? true else { return }
            sendCommand(.selectConversation(threadID: selectedThreadID))
        }
    }
    var selectedProjectID: UUID?
    var search = ""
    var showArchived = false
    var errorMessage: String?
    var providerModels: [ProviderKind: [ProviderModel]] = [:]
    var acpModels: [UUID: [ProviderModel]] = [:]
    var openCodeCatalogs: [UUID: OpenCodeMetadataSnapshot] = [:]
    var piModels: [UUID: [ProviderModel]] = [:]
    var museModels: [UUID: [ProviderModel]] = [:]
    var antigravityModels: [UUID: [ProviderModel]] = [:]
    let antigravityAccount: AntigravityAccountStore
    let antigravityInstallation: AntigravityInstallationStore
    @ObservationIgnored private let antigravityRuntimeInstallation: AntigravityInstallation
    var isLoading = true
    var isRefreshingModels = false
    let codexAccount = CodexAccountStore()
    let codexRuntime: CodexRuntimeStore
    let codexAuthentication: CodexAuthenticationStore
    @ObservationIgnored private let codexRuntimeInstallation: CodexInstallation
    @ObservationIgnored private let codexOwnedRuntime: CodexOwnedRuntimeBroker
    @ObservationIgnored private let codexAuthorization: CodexAuthentication.AuthorizationHandler
    @ObservationIgnored private let codexListenerFactory: CodexAuthentication.ListenerFactory
    @ObservationIgnored private let codexHostID: UUID
    @ObservationIgnored private var codexAuthenticationBinding: Task<Void, Never>?
    @ObservationIgnored private var codexAuthenticationChanges: Set<UUID> = []
    @ObservationIgnored private var codexAuthenticationLeases: [UUID: CodexWorkspaceAuthenticationLease] = [:]
    var codexModels: [UUID: [ProviderModel]] = [:]
    private var claudeModels: [UUID: (identity: ClaudeRuntimeIdentity, models: [ProviderModel])] = [:]
    @ObservationIgnored private var codexCatalogReads: [UUID: Task<[ProviderModel], any Error>] = [:]
    @ObservationIgnored private var codexMetadataScope = UUID()
    private var providerSkills: [UUID: ProviderSkillsStore] = [:]
    @ObservationIgnored private var providerSkillsDrains: [UUID: (scope: ProviderSkillsStore.Scope, task: Task<Void, Never>)] = [:]
    let acpConnections = ACPConnectionStore()
    var inspectorVisible = false
    var fileNavigation: FileNavigation?
    private var engine: WorkspaceEngine?
    private var loadingTask: Task<Void, Never>?
    private var updatesTask: Task<Void, Never>?
    private var commandTail: Task<Void, Never>?
    private var codexModelDefaultsReads: [UUID: CodexModelDefaultsRead] = [:]
    private var promptSteeringAvailability: [UUID: (NativePromptSteeringKey, PromptSteeringAvailability)] = [:]
    private var acceptingPromptSteering: Set<UUID> = []
    private var draftSaveTask: Task<Void, Never>?
    private var draftOverrides: [UUID: String] = [:]
    private var pendingDrafts: [UUID: String] = [:]
    private var preparingWorkspaces: Set<UUID> = []
    private var attachmentImportCounts: [UUID: Int] = [:]
    private var attachmentImportTasks: [UUID: Task<Void, Never>] = [:]
    private var attachmentImportOwners: [UUID: UUID] = [:]
    private var worktreeTasks: [UUID: Task<Void, any Error>] = [:]
    private var worktreeOptionsReads: [UUID: WorktreeOptionsRead] = [:]
    private var projectCloneRetryTasks: [UUID: Task<Void, Never>] = [:]
    private var removalCleanupTasks: [UUID: ProjectRemovalCleanup] = [:]
    private var terminalStores: [ObjectIdentifier: WeakTerminalStore] = [:]
    let terminalArchives: TerminalArchiveStore
    private(set) var hasLoadedWorkspace = false
    private var terminalSuspensions: [UUID: Task<Void, Never>] = [:]
    private var closingTerminalSessions: [UUID: LocalTerminalSession] = [:]
    private var closingTerminalTasks: [UUID: Task<Void, Never>] = [:]
    private var dirtyEditors: [UUID: String] = [:]
    private var removalEditorLocks: [UUID: Set<String>] = [:]
    private var workspaceTransitionLocks: [UUID: Set<String>] = [:]
    private var gitInspectors: [String: GitInspectorStore] = [:]
    private var pullRequestStores: [String: PullRequestStore] = [:]
    var pullRequestSessionFactory: @Sendable (URL) -> any GitHubPullRequestSession = { GitHubPullRequestService(root: $0) }
    private var fileServices: [String: WorkspaceFileService] = [:]
    private var fileBrowsers: [String: FileBrowserStore] = [:]
    private var fileServiceCleanupTasks: [String: WorkspaceFileCleanup] = [:]
    private var externalEditorService: NativeExternalEditorService?
    private var projectScriptService: NativeProjectScriptService?
    private(set) var availableExternalEditors: [ExternalEditorDescriptor] = []
    private var retryingProjectClones: Set<UUID> = []
    private var respondingToPostRunCheckpoints: Set<UUID> = []
    private var checkpointRestoreReads: [UUID: CheckpointRestoreRead] = [:]
    private var checkpointRestoreInspections: [UUID: CheckpointRestoreInspection] = [:]
    private var checkpointRestoreLocks: [UUID: String] = [:]
    private var acceptingCheckpointRestores: Set<UUID> = []
    private var checkpointRefreshTasks: [UUID: Task<Void, Never>] = [:]
    private var pullRequestCheckoutLocks: [UUID: Set<String>] = [:]
    private var acceptingPullRequestCheckouts: Set<UUID> = []
    private var pullRequestCheckoutRefreshTasks: [UUID: Task<Void, Never>] = [:]
    private var pullRequestCheckoutNavigation: [UUID: UUID?] = [:]
    private var historyReviewReads: [UUID: ConversationHistoryRead] = [:]
    private var acceptingHistoryThreads: Set<UUID> = []
    private var historyNavigationRequests: [UUID: UUID] = [:]
    private var historyInspections: [UUID: ConversationHistoryInspection] = [:]
    private var piHistoryResponses: [UUID: PiHistoryResponse] = [:]
    private var piHistoryCancellations: [UUID: ConversationHistoryInspection] = [:]
    private var piFreshHistoryReads: [UUID: PiFreshHistoryInspection] = [:]
    private var piFreshHistoryObservations: [UUID: PiFreshHistoryObservation] = [:]
    private var recallingHistoryPrompts: Set<UUID> = []
    private var automaticHistoryRecallTasks: [UUID: Task<Void, Never>] = [:]
    private var automaticHistoryRecallErrors: [UUID: String] = [:]
    private var historyRecallDraftOwners: [UUID: UUID] = [:]
    private var historyRecallDrainWaiters: [CheckedContinuation<Void, Never>] = []
    private var projectCreationTasks: [UUID: Task<ManagedProjectCreationResult, any Error>] = [:]
    private var lastSequence: Int64 = -1
    private var terminating = false

    init(databaseURL: URL? = nil, appMCPEnabled: Bool = true, runtimeInstallation: AntigravityInstallation = .shared, codexInstallation: CodexInstallation = .shared,
         codexOwnedRuntime: CodexOwnedRuntimeBroker = .shared, codexHostID: UUID? = nil,
         codexListenerFactory: CodexAuthentication.ListenerFactory? = nil,
         claudeRuntimeCapture: ClaudeRuntimeCapture? = nil,
         piRuntimeCapture: PiRuntimeCapture? = nil,
         codexAuthorization: @escaping CodexAuthentication.AuthorizationHandler = WorkspaceStore.openCodexAuthorization) {
        composerDraftTools = .init(root: (databaseURL?.deletingLastPathComponent() ?? Self.applicationDataRoot).appendingPathComponent("ComposerDrafts", isDirectory: true))
        agentSessionImports = .init(root: (databaseURL?.deletingLastPathComponent() ?? Self.applicationDataRoot).appendingPathComponent("AgentSessionImports", isDirectory: true))
        terminalArchives = .init(root: (databaseURL?.deletingLastPathComponent() ?? Self.applicationDataRoot).appendingPathComponent("TerminalHistory", isDirectory: true))
        projectSettings = .init(root: ProjectSettingsFiles.root(dataRoot: databaseURL?.deletingLastPathComponent() ?? Self.applicationDataRoot))
        self.claudeRuntimeCapture = claudeRuntimeCapture ?? { try ClaudeRuntimeConfiguration.capture(workspacePath: $0) }
        self.piRuntimeCapture = piRuntimeCapture ?? { try PiRuntimeConfiguration.capture(workspacePath: $0, executable: $1, instanceID: $2) }
        codexRuntimeInstallation = codexInstallation
        codexRuntime = .init(rootURL: databaseURL?.deletingLastPathComponent() ?? Self.applicationDataRoot, installation: codexInstallation)
        codexAuthentication = .init(configuration: codexRuntime.configuration)
        self.codexOwnedRuntime = codexOwnedRuntime; self.codexHostID = codexHostID ?? Self.savedCodexHostID()
        self.codexAuthorization = codexAuthorization
        self.codexListenerFactory = codexListenerFactory ?? { try await CodexOAuthLoopback.start() }
        let runtimeRoot = databaseURL.map { $0.deletingLastPathComponent().appendingPathComponent("Providers/Antigravity", isDirectory: true) } ?? AntigravityRuntime.defaultStateRoot
        antigravityRuntimeInstallation = runtimeInstallation
        antigravityInstallation = .init(installation: runtimeInstallation)
        antigravityAccount = .init(stateRoot: (databaseURL?.deletingLastPathComponent() ?? Self.applicationDataRoot).appendingPathComponent("AntigravitySettings", isDirectory: true),
                                  sessionFactory: AntigravityAuthentication.nativeSessionFactory(stateRoot: runtimeRoot, installation: runtimeInstallation))
        defer {
            if let engine { antigravityAccount.bind(engine: engine) }
            bindAntigravityInstallation(); bindCodexRuntime(); bindComposerDraftTools(); bindAgentSessionImports()
        }
        projectScriptReader = { try await ProjectConfigurationService.load(using: $0) }
        managedProjectsRoot = (databaseURL?.deletingLastPathComponent() ?? Self.applicationDataRoot).appendingPathComponent("Projects", isDirectory: true)
        worktreesRoot = (databaseURL?.deletingLastPathComponent() ?? Self.applicationDataRoot).appendingPathComponent("Worktrees", isDirectory: true)
        projectCreator = { name, root in try await ManagedProjectService(root: root).create(name: name) }
        let accountRoot = (databaseURL?.deletingLastPathComponent() ?? Self.applicationDataRoot).appendingPathComponent("AntigravitySettings", isDirectory: true)
        let providers: WorkspaceEngine.ProviderFactory = {
            try ProviderSessions.make(for: $0, antigravityStateRoot: runtimeRoot,
                antigravityInstallation: runtimeInstallation, antigravityAccountRoot: accountRoot, codexInstallation: codexInstallation,
                codexOwnedRuntime: codexOwnedRuntime)
        }
        do {
            if let databaseURL { engine = try WorkspaceEngine(url: databaseURL, appMCPEnabled: appMCPEnabled, providerFactory: providers, projectScriptFactory: Self.managedScriptFactory); return }
            let root = try FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
                .appendingPathComponent("Coincide", isDirectory: true)
            engine = try WorkspaceEngine(url: root.appendingPathComponent("workspace.sqlite"), appMCPEnabled: appMCPEnabled, providerFactory: providers, projectScriptFactory: Self.managedScriptFactory)
        } catch { errorMessage = error.localizedDescription }
    }
    init(engine: WorkspaceEngine, managedProjectsRoot: URL? = nil, runtimeInstallation: AntigravityInstallation = .shared, codexInstallation: CodexInstallation = .shared,
         codexOwnedRuntime: CodexOwnedRuntimeBroker = .shared, codexHostID: UUID? = nil,
         codexListenerFactory: CodexAuthentication.ListenerFactory? = nil,
         codexAuthorization: @escaping CodexAuthentication.AuthorizationHandler = WorkspaceStore.openCodexAuthorization,
         claudeRuntimeCapture: ClaudeRuntimeCapture? = nil,
         piRuntimeCapture: PiRuntimeCapture? = nil,
         projectScriptReader: NativeProjectScriptService.Reader? = nil,
         projectCreator: ProjectCreator? = nil) {
        composerDraftTools = .init(root: engine.worktreesRoot.deletingLastPathComponent().appendingPathComponent("ComposerDrafts", isDirectory: true))
        agentSessionImports = .init(root: engine.worktreesRoot.deletingLastPathComponent().appendingPathComponent("AgentSessionImports", isDirectory: true))
        terminalArchives = .init(root: engine.worktreesRoot.deletingLastPathComponent().appendingPathComponent("TerminalHistory", isDirectory: true))
        projectSettings = .init(root: ProjectSettingsFiles.root(dataRoot: engine.worktreesRoot.deletingLastPathComponent()))
        self.claudeRuntimeCapture = claudeRuntimeCapture ?? { try ClaudeRuntimeConfiguration.capture(workspacePath: $0) }
        self.piRuntimeCapture = piRuntimeCapture ?? { try PiRuntimeConfiguration.capture(workspacePath: $0, executable: $1, instanceID: $2) }
        codexRuntimeInstallation = codexInstallation
        codexRuntime = .init(rootURL: engine.worktreesRoot.deletingLastPathComponent(), installation: codexInstallation)
        codexAuthentication = .init(configuration: codexRuntime.configuration)
        self.codexOwnedRuntime = codexOwnedRuntime; self.codexHostID = codexHostID ?? Self.savedCodexHostID()
        self.codexAuthorization = codexAuthorization
        self.codexListenerFactory = codexListenerFactory ?? { try await CodexOAuthLoopback.start() }
        antigravityRuntimeInstallation = runtimeInstallation
        antigravityInstallation = .init(installation: runtimeInstallation)
        antigravityAccount = .init(stateRoot: engine.worktreesRoot.deletingLastPathComponent().appendingPathComponent("AntigravitySettings", isDirectory: true),
                                  sessionFactory: AntigravityAuthentication.nativeSessionFactory(installation: runtimeInstallation))
        self.engine = engine
        self.managedProjectsRoot = managedProjectsRoot ?? Self.applicationDataRoot.appendingPathComponent("Projects", isDirectory: true)
        self.worktreesRoot = engine.worktreesRoot
        self.projectCreator = projectCreator ?? { name, root in try await ManagedProjectService(root: root).create(name: name) }
        self.projectScriptReader = projectScriptReader ?? { try await ProjectConfigurationService.load(using: $0) }
        antigravityAccount.bind(engine: engine)
        bindAntigravityInstallation(); bindCodexRuntime(); bindComposerDraftTools(); bindAgentSessionImports()
    }
    private func bindAgentSessionImports() {
        agentSessionImports.bind(.init(scan: { [weak self] in
            guard let self, !self.terminating, let engine = self.engine else { throw CancellationError() }
            let profiles = try await self.captureAgentSessionProfiles()
            try Task.checkCancellation()
            guard !self.terminating else { throw CancellationError() }
            let result = try await engine.scanAgentSessions(profiles: profiles)
            guard !self.terminating, !Task.isCancelled else { await engine.releaseAgentSessionScan(result.id); throw CancellationError() }
            self.agentSessionImportScans[result.id] = result.candidates
            return result
        }, prepare: { [weak self] scanID, candidate, cursor in
            guard let self else { throw CancellationError() }
            return try await self.prepareAgentSessionImport(scanID: scanID, candidate: candidate, cursor: cursor)
        }, accept: { [weak self] reviewID, digest, commandID in
            guard let self, !self.terminating, let engine = self.engine else { throw CancellationError() }
            let receipt = try await engine.acceptAgentSessionImport(reviewID: reviewID, digest: digest, commandID: commandID)
            self.apply(await engine.current()); return receipt
        }, receipt: { [weak self] reviewID, digest, commandID in
            guard let self, !self.terminating, let engine = self.engine else { throw CancellationError() }
            let receipt = try await engine.agentSessionImportReceipt(reviewID: reviewID, digest: digest, commandID: commandID, resolvingAbsent: true)
            self.apply(await engine.current()); return receipt
        }, release: { [weak self] scanID in
            guard let self else { return }
            await self.engine?.releaseAgentSessionScan(scanID)
            self.agentSessionImportScans.removeValue(forKey: scanID); self.agentSessionImportProjects.removeValue(forKey: scanID)
        }))
    }
    private func captureAgentSessionProfiles() async throws -> [AgentSessionProfile] {
        let selected = selectedThread.map { [ProviderConfiguration(thread: $0)] } ?? []
        let captured = selected + snapshot.threads.flatMap { thread in
            [ProviderConfiguration(thread: thread)] + [thread.activeRun?.configuration].compactMap { $0 } + thread.queuedTurns.map(\.configuration)
        }
        let runtime = codexRuntime.configuration, capture = claudeRuntimeCapture
        let path = selectedThread?.workspacePath ?? snapshot.projects.first?.path ?? FileManager.default.homeDirectoryForCurrentUser.path
        let environment = ProcessChannel.environment()
        let task = Task.detached { try AgentSessionProfileCapture.profiles(codex: runtime, captured: captured, workspacePath: path, environment: environment, claude: capture) }
        return try await withTaskCancellationHandler { try await task.value } onCancel: { task.cancel() }
    }
    private func prepareAgentSessionImport(scanID: UUID, candidate: AgentSessionProjectCandidate, cursor: UUID?) async throws -> AgentSessionImportPage {
        guard !terminating, let engine, let captured = agentSessionImportScans[scanID]?.first(where: { $0.id == candidate.id }),
              try AgentSessionImportProtocol.payload(captured) == AgentSessionImportProtocol.payload(candidate) else { throw AgentSessionImportError.staleScan }
        let projectID: UUID
        if let frozen = agentSessionImportProjects[scanID]?[candidate.id] { projectID = frozen }
        else {
            guard cursor == nil else { throw AgentSessionImportError.staleScan }
            let path = candidate.path
            try await Task.detached {
                try Task.checkCancellation()
                let url = URL(fileURLWithPath: path), values = try url.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
                guard values.isDirectory == true, values.isSymbolicLink != true,
                      url.standardizedFileURL.resolvingSymlinksInPath().path.utf8.elementsEqual(path.utf8) else { throw AgentSessionImportError.changed }
            }.value
            if let expected = candidate.projectID {
                guard let project = snapshot.projects.first(where: { $0.id == expected }), project.path.utf8.elementsEqual(candidate.path.utf8) else { throw AgentSessionImportError.changed }
                projectID = expected
            } else if let project = snapshot.projects.first(where: { $0.path.utf8.elementsEqual(candidate.path.utf8) }) { projectID = project.id }
            else {
                var project = WorkspaceProject(path: candidate.path)
                project.id = TaskOrchestration.derivedID(candidate.id, "agent-session-project")
                guard project.path.utf8.elementsEqual(candidate.path.utf8) else { throw AgentSessionImportError.changed }
                let capturedProject = project, previous = commandTail
                let actionID = TaskOrchestration.derivedID(candidate.id, "agent-session-add-project")
                let action = Task {
                    await previous?.value
                    try Task.checkCancellation()
                    guard !self.terminating, self.agentSessionImportScans[scanID] != nil else { throw CancellationError() }
                    let receipt = try await engine.dispatch(.addProject(capturedProject), id: actionID)
                    self.apply(await engine.current()); return receipt
                }
                commandTail = Task { _ = await action.result }
                _ = try await action.value
                projectID = project.id
            }
            agentSessionImportProjects[scanID, default: [:]][candidate.id] = projectID
        }
        try Task.checkCancellation()
        guard !terminating, let project = snapshot.projects.first(where: { $0.id == projectID }),
              project.path.utf8.elementsEqual(candidate.path.utf8), removalEditorLocks[projectID] == nil else { throw AgentSessionImportError.changed }
        return try await engine.prepareAgentSessionImport(scanID: scanID, projectID: projectID, expectedWorkspaceRoot: candidate.path, cursor: cursor)
    }
    private func bindComposerDraftTools() {
        composerDraftTools.bind(.init(snapshot: { [weak self] id in self?.composerDraftSnapshot(id) },
            replace: { [weak self] id, replacement in
                guard let self else { return .unknown }
                return await self.replaceComposerDraft(id: id, replacement: replacement)
            }, receipt: { [weak self] id, replacement in
                guard let self, !self.terminating, let engine = self.engine else { return nil }
                guard let receipt = try await engine.composerDraftReceipt(commandID: id, replacement: replacement, resolvingAbsent: true) else { return nil }
                self.apply(await engine.current())
                return receipt.rejection == nil ? .applied : .rejected
            }, importData: { [weak self] data, name in
                guard let self, !self.terminating, let engine = self.engine else { throw CancellationError() }
                return try await engine.attachments.importData(data, name: name)
            }, verify: { [weak self] attachment in
                guard let self, !self.terminating, let engine = self.engine else { throw CancellationError() }
                _ = try await engine.attachments.data(for: attachment)
            }, canOperate: { [weak self] id in
                guard let self, !self.terminating, let thread = self.thread(id), !thread.isArchived,
                      self.historyRecallDraftOwners[id] == nil, self.removalEditorLocks[thread.projectID] == nil else { return false }
                return self.snapshot.projects.contains { $0.id == thread.projectID }
            }, reportError: { [weak self] id, message in
                guard let self, !self.terminating, let thread = self.thread(id),
                      self.removalEditorLocks[thread.projectID] == nil else { return }
                self.errorMessage = message
            }))
    }
    func composerDraftSnapshot(_ id: UUID) -> ComposerDraftSnapshot? {
        guard let thread = thread(id) else { return nil }
        return .init(threadID: id, projectID: thread.projectID, workspacePath: thread.workspacePath,
            text: thread.draft, attachments: thread.draftAttachments)
    }
    private func replaceComposerDraft(id: UUID, replacement: ComposerDraftReplacement) async -> ComposerDraftToolsOutcome {
        guard !terminating, let engine, historyRecallDraftOwners[replacement.expected.threadID] == nil else { return .rejected }
        flushDrafts()
        let previous = commandTail
        let task = Task<ComposerDraftToolsOutcome, Never> { [weak self] in
            await previous?.value
            guard let self, !self.terminating, self.historyRecallDraftOwners[replacement.expected.threadID] == nil,
                  let current = self.composerDraftSnapshot(replacement.expected.threadID), current.matches(replacement.expected) else { return .rejected }
            do {
                _ = try await engine.dispatch(.replaceComposerDraft(replacement), id: id)
                self.apply(await engine.current())
                let target = replacement.expected.threadID
                if self.draftOverrides[target].map({ $0.utf8.elementsEqual(replacement.expected.text.utf8) }) == true {
                    self.draftOverrides.removeValue(forKey: target)
                }
                if self.pendingDrafts[target].map({ $0.utf8.elementsEqual(replacement.expected.text.utf8) }) == true {
                    self.pendingDrafts.removeValue(forKey: target)
                }
                return .applied
            } catch is WorkspaceCommandError { return .rejected }
            catch { return .unknown }
        }
        commandTail = Task { _ = await task.value }
        return await task.value
    }
    private func bindCodexRuntime() {
        let initial = codexRuntime.configuration
        codexAuthenticationBinding = Task { [weak self] in await self?.bindCodexAuthentication(configuration: initial) }
        codexRuntime.bind(apply: { [weak self] configuration in
            try configuration.validate()
            guard let self, !self.terminating || !self.codexAuthenticationLeases.isEmpty else { throw CancellationError() }
            await self.codexAuthenticationBinding?.value
            let sameScope = CodexAuthenticationStore.sameControllerScope(self.codexAuthentication.configuration, configuration)
            guard sameScope || (!self.codexAuthentication.isWorking && self.codexAuthenticationChanges.isEmpty) else {
                throw CoincideError("Finish the ChatGPT account change before selecting another runtime.")
            }
            self.codexMetadataScope = UUID()
            self.codexModels.removeAll(); self.providerModels.removeValue(forKey: .codex)
            let skills = self.retireSkills { $0.provider == .codex }
            let catalogs = Array(self.codexCatalogReads.values)
            for task in catalogs { task.cancel() }
            let defaults = self.codexModelDefaultsReads.values.map(\.task)
            self.codexModelDefaultsReads.removeAll()
            for task in defaults { task.cancel() }
            await self.codexAccount.invalidate()
            for task in catalogs { _ = try? await task.value }
            for task in defaults { _ = await task.value }
            for task in skills { await task.value }
            guard !self.terminating || !self.codexAuthenticationLeases.isEmpty else { throw CancellationError() }
            if sameScope { self.codexAuthentication.updateConfiguration(configuration) }
            else { await self.bindCodexAuthentication(configuration: configuration) }
        }, protectedCustomPaths: { [weak self] in
            guard let self else { return [] }
            var configurations = [self.codexRuntime.configuration]
            for thread in self.snapshot.threads {
                if let value = thread.codexRuntimeConfiguration { configurations.append(value) }
                if let value = thread.activeRun?.configuration.codexRuntimeConfiguration { configurations.append(value) }
                configurations += thread.queuedTurns.compactMap { $0.configuration.codexRuntimeConfiguration }
            }
            return configurations.filter { $0.selection == .custom }.map(\.executable)
        })
    }
    private static func savedCodexHostID() -> UUID {
        let key = "Coincide.CodexAuthentication.hostID"
        if let value = UserDefaults.standard.string(forKey: key), let id = UUID(uuidString: value) { return id }
        let id = UUID(); UserDefaults.standard.set(id.uuidString.lowercased(), forKey: key); return id
    }
    nonisolated static func openCodexAuthorization(_ authorization: CodexOAuthAuthorization) async throws {
        let opened = await MainActor.run { NSWorkspace.shared.open(authorization.authorizationURL) }
        guard opened else { throw CoincideError("The ChatGPT sign-in page could not be opened. Try the sign-in link again.") }
    }
    private func bindCodexAuthentication(configuration: CodexRuntimeConfiguration) async {
        guard !terminating, !Task.isCancelled else { return }
        let components = await codexOwnedRuntime.components(instanceID: configuration.instanceID)
        guard !terminating, !Task.isCancelled else { return }
        let controller = CodexAuthentication(instanceID: configuration.instanceID, hostID: codexHostID,
            vault: components.vault, client: components.client, listenerFactory: codexListenerFactory,
            authorizationHandler: codexAuthorization,
            beginLease: { [weak self] instance in
                guard let self, instance == configuration.instanceID else { throw CancellationError() }
                return try await self.beginCodexAccountChange(configuration: configuration)
            }, endLease: { [weak self] id in await self?.endCodexAccountChange(id) },
            apply: { [weak self] overview in
                guard let self else { throw CancellationError() }
                try await self.publishCodexAccount(overview.binding, instanceID: configuration.instanceID)
            }, invalidate: { [weak self] in
                try? await self?.publishCodexAccount(nil, instanceID: configuration.instanceID)
            })
        await codexAuthentication.bind(client: .init(instanceID: configuration.instanceID, controller: controller, vault: components.vault),
                                       configuration: configuration)
    }
    private func beginCodexAccountChange(configuration: CodexRuntimeConfiguration) async throws -> UUID {
        guard !terminating, !codexRuntime.isApplying, let engine,
              configuration.authenticationMode == .ownedChatGPT,
              CodexAuthenticationStore.sameControllerScope(configuration, codexRuntime.configuration),
              codexAuthenticationChanges.insert(configuration.instanceID).inserted else { throw CancellationError() }
        let instanceID = configuration.instanceID
        codexMetadataScope = UUID(); codexModels.removeAll(); providerModels.removeValue(forKey: .codex)
        let skills = retireSkills { $0.provider == .codex && $0.configuration.authenticationMode == .ownedChatGPT && $0.configuration.instanceID == instanceID }
        let catalogs = Array(codexCatalogReads.values), defaults = codexModelDefaultsReads.values.map(\.task)
        codexModelDefaultsReads.removeAll()
        catalogs.forEach { $0.cancel() }; defaults.forEach { $0.cancel() }
        var engineLease: UUID?, runtimeLease: CodexRuntimeAdmissionLease?
        do {
            // Engine cancellation owns native metadata close. Join app readers
            // only after that close has unblocked cancellation-resistant work.
            let id = try await engine.beginCodexAuthentication(configuration: configuration); engineLease = id
            try Task.checkCancellation()
            runtimeLease = try await codexOwnedRuntime.beginMutation(instanceID: instanceID)
            for task in catalogs { _ = try? await task.value }
            for task in defaults { _ = await task.value }
            for task in skills { await task.value }
            await codexAccount.invalidate()
            try Task.checkCancellation()
            guard !terminating, CodexAuthenticationStore.sameControllerScope(configuration, codexRuntime.configuration),
                  let runtimeLease else { throw CancellationError() }
            codexAuthenticationLeases[id] = .init(instanceID: instanceID, engineLeaseID: id, runtimeLease: runtimeLease)
            return id
        } catch {
            runtimeLease?.release()
            if let engineLease { await engine.endCodexAuthentication(leaseID: engineLease) }
            codexAuthenticationChanges.remove(instanceID)
            throw error
        }
    }
    private func publishCodexAccount(_ binding: CodexAccountBinding?, instanceID: UUID) async throws {
        guard let engine, let lease = codexAuthenticationLeases.values.first(where: { $0.instanceID == instanceID }),
              codexRuntime.configuration.instanceID == instanceID,
              codexRuntime.configuration.authenticationMode == .ownedChatGPT else { throw CancellationError() }
        try await engine.applyCodexAccountBinding(instanceID: instanceID, binding: binding, leaseID: lease.engineLeaseID)
        apply(await engine.current())
        try await codexRuntime.publishAccountBinding(binding, expectedInstanceID: instanceID)
    }
    private func endCodexAccountChange(_ id: UUID) async {
        guard let lease = codexAuthenticationLeases[id] else { return }
        lease.runtimeLease.release()
        await engine?.endCodexAuthentication(leaseID: lease.engineLeaseID)
        codexAuthenticationLeases.removeValue(forKey: id)
        codexAuthenticationChanges.remove(lease.instanceID)
    }
    func contextTransferStore(threadID: UUID) -> ContextTransferStore {
        if contextTransferStores[threadID] == nil { contextTransferStores[threadID] = ContextTransferStore() }
        updateContextTransferStore(threadID: threadID)
        return contextTransferStores[threadID]!
    }
    private func updateContextTransferStore(threadID: UUID) {
        guard let model = contextTransferStores[threadID] else { return }
        let transport: ContextTransferNativeTransport?
        if let engine {
            transport = .init(review: { try await engine.reviewContextTransfer($0) },
                discard: { await engine.discardContextTransferReview(id: $0, digest: $1) },
                accept: { [weak self] id, digest, title in
                    guard let self else { throw CancellationError() }
                    return try await self.acceptContextTransfer(threadID: threadID, id: id, digest: digest, title: title)
                })
        } else { transport = nil }
        model.update(sourceThreadID: threadID, snapshot: snapshot, transport: transport,
            destination: { [weak self] kind, provider, path, selectedModel, permission, agentID in
                guard let self else { throw CancellationError() }
                return try self.contextTransferDestination(threadID: threadID, kind: kind, provider: provider,
                    path: path, model: selectedModel, permission: permission, agentID: agentID)
            }, canReview: { [weak self] in self?.canReviewContextTransfer(threadID: threadID) == true },
            canAccept: { [weak self] review in
                guard let self, self.canReviewContextTransfer(threadID: threadID),
                      let source = self.thread(threadID), ContextTransferProtocol.same(ProviderConfiguration(thread: source), review.request.expectedConfiguration),
                      self.snapshot.contextTransfers?.contains(where: { $0.id == review.id }) != true else { return false }
                if case .mergeBack(let expected) = review.request.intent {
                    guard let parent = self.thread(review.targetThreadID), !parent.isArchived,
                          ContextTransferProtocol.same(ProviderConfiguration(thread: parent), expected) else { return false }
                }
                return true
            }, open: { [weak self] id in
                guard let self, let target = self.thread(id) else { return }
                self.selectedProjectID = target.projectID; self.showArchived = target.isArchived; self.selectedThreadID = id
            })
    }
    private func canReviewContextTransfer(threadID: UUID) -> Bool {
        guard !terminating, let source = thread(threadID), !source.isArchived, snapshot.workspaceReady(for: source),
              !snapshot.isConversationHistoryLocked(threadID: threadID), !isCheckpointRestoreLocked(threadID: threadID),
              !isPullRequestCreationLocked(threadID: threadID), !isPullRequestCheckoutLocked(threadID: threadID) else { return false }
        return true
    }
    private func acceptContextTransfer(threadID: UUID, id: UUID, digest: String, title: String?) async throws -> WorkspaceCommandReceipt {
        guard canReviewContextTransfer(threadID: threadID), let engine,
              let review = contextTransferStores[threadID]?.review, review.id == id, review.digest == digest else { throw ContextTransferError.staleReview }
        flushDrafts()
        let previous = commandTail
        let task = Task { [weak self] in
            await previous?.value
            guard let self, self.canReviewContextTransfer(threadID: threadID),
                  let current = self.thread(threadID), ContextTransferProtocol.same(ProviderConfiguration(thread: current), review.request.expectedConfiguration) else { throw ContextTransferError.staleReview }
            let receipt = try await engine.acceptContextTransfer(reviewID: id, digest: digest, title: title, commandID: UUID())
            self.apply(await engine.current())
            return receipt
        }
        commandTail = Task { _ = await task.result }
        return try await task.value
    }
    func useFreshContext(threadID: UUID, deliveryID: UUID, transferIDs: [UUID]) async {
        guard !terminating, let engine else { return }
        flushDrafts()
        let previous = commandTail
        let task = Task { [weak self] in
            await previous?.value
            guard let self, !self.terminating else { return }
            do {
                let receipt = try await engine.abandonContextTransfer(threadID: threadID, deliveryID: deliveryID, expectedTransferIDs: transferIDs)
                self.apply(await engine.current()); if let rejection = receipt.rejection { self.errorMessage = rejection }
            } catch { self.errorMessage = "The context outcome changed. Inspect its saved state before choosing fresh context again." }
        }
        commandTail = task; await task.value
    }
    private func contextTransferDestination(threadID: UUID, kind: ContextTransferFormKind, provider: ProviderKind,
                                            path: String, model: String, permission: PermissionMode, agentID: UUID?) throws -> ProviderConfiguration {
        guard let source = thread(threadID), canReviewContextTransfer(threadID: threadID) else { throw ContextTransferError.unavailable }
        let sameProvider = provider == source.provider && (provider != .acp || agentID == source.acpAgent?.id)
        var configuration: ProviderConfiguration
        if sameProvider { configuration = .init(thread: source) }
        else {
            let project = WorkspaceProject(path: path)
            var fresh = newCodingThread(project: project); fresh.provider = provider; fresh.codexRuntimeConfiguration = nil
            fresh.model = ""; fresh.permission = permission
            switch provider {
            case .codex: fresh.codexRuntimeConfiguration = codexRuntime.configuration
            case .claude: fresh.claudeRuntimeConfiguration = try claudeRuntimeCapture(path)
            case .pi:
                let runtime = try piRuntimeCapture(path, ProviderKind.pi.executable, UUID())
                fresh.piConfiguration = .init(instanceID: runtime.instanceID, executable: runtime.requestedExecutable, runtime: runtime)
            case .opencode: fresh.openCodeConfiguration = .init()
            case .muse: fresh.museConfiguration = .init()
            case .antigravity: fresh.antigravityConfiguration = antigravityAccount.configuration
            case .acp:
                guard let agent = snapshot.acpAgents.first(where: { $0.id == agentID }) else { throw ContextTransferError.unavailable }
                fresh.acpAgent = agent
            }
            configuration = .init(thread: fresh)
        }
        if sameProvider, !path.utf8.elementsEqual(source.workspacePath.utf8) {
            if let runtime = configuration.claudeRuntimeConfiguration {
                var environment = ProcessChannel.environment()
                switch runtime.configurationDirectorySelection {
                case .defaultHome(let home): environment["HOME"] = home; environment.removeValue(forKey: "CLAUDE_CONFIG_DIR")
                case .explicitDirectory(let raw): environment["CLAUDE_CONFIG_DIR"] = raw
                }
                configuration.claudeRuntimeConfiguration = try .capture(workspacePath: path, executable: runtime.executable,
                    projectDirectoryName: runtime.projectDirectoryName, environment: environment)
            }
            if let native = configuration.piConfiguration, let runtime = native.runtime {
                let captured = try PiRuntimeConfiguration.capture(workspacePath: path, executable: runtime.requestedExecutable,
                    instanceID: runtime.instanceID, environment: runtime.environment())
                configuration.piConfiguration = .init(instanceID: native.instanceID, executable: native.executable,
                    model: native.model, thinkingLevel: native.thinkingLevel, runtime: captured)
            }
        }
        if model != configuration.model {
            let rows = sameProvider ? models(for: source) : providerModels[provider] ?? []
            let row = rows.first { $0.id == model }
            switch provider {
            case .opencode:
                guard model.isEmpty || row?.openCodeSelection != nil else { throw CoincideError("Use the CLI default or a model already refreshed for OpenCode.") }
                configuration.openCodeConfiguration = configuration.openCodeConfiguration?.selecting(model: row?.openCodeSelection)
            case .pi:
                guard model.isEmpty || row?.piSelection != nil else { throw CoincideError("Use the CLI default or a model already refreshed for Pi.") }
                configuration.piConfiguration = configuration.piConfiguration?.selecting(model: row?.piSelection)
            case .muse:
                guard model.isEmpty || row?.museSelection != nil else { throw CoincideError("Use the CLI default or a model already refreshed for Muse.") }
                configuration.museConfiguration = configuration.museConfiguration?.selecting(model: row?.museSelection)
            case .antigravity: configuration.antigravityConfiguration = configuration.antigravityConfiguration?.selecting(model: model.isEmpty ? nil : model)
            default: break
            }
            configuration.reasoningEffort = nil
        }
        configuration.workspacePath = path; configuration.model = model; configuration.permission = permission
        configuration.nativeThreadID = nil; configuration.claudeLaunchSelection = nil; configuration.piFreshSessionIntent = nil
        return configuration
    }
    private func newCodingThread(project: WorkspaceProject) -> CodingThread {
        var thread = CodingThread(project: project)
        if codexRuntime.configuration != .init() { thread.codexRuntimeConfiguration = codexRuntime.configuration }
        return thread
    }
    private func bindAntigravityInstallation() {
        antigravityInstallation.bind { [weak self] in
            guard let self else { return [] }
            var configurations = [self.antigravityAccount.configuration]
            for thread in self.snapshot.threads {
                if let value = thread.antigravityConfiguration { configurations.append(value) }
                if let value = thread.activeRun?.configuration.antigravityConfiguration { configurations.append(value) }
                configurations += thread.queuedTurns.compactMap { $0.configuration.antigravityConfiguration }
            }
            return configurations.filter { $0.runtimeSelection == .external }.flatMap { [$0.executable] + ($0.harnessPath.map { [$0] } ?? []) }
        }
    }
    private static var applicationDataRoot: URL {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support", isDirectory: true)
        return support.appendingPathComponent("Coincide", isDirectory: true)
    }
    private static var managedScriptFactory: WorkspaceEngine.ProjectScriptFactory {
        let helper = Bundle.main.bundleURL.appendingPathComponent("Contents/Helpers/CoincideScriptHelper")
        return { try NativeProjectScriptExecutionSession(plan: $0, helperURL: helper) }
    }
    func thread(_ id: UUID) -> CodingThread? {
        guard var value = snapshot.threads.first(where: { $0.id == id }) else { return nil }
        if let draft = draftOverrides[id] { value.draft = draft }
        return value
    }
    var selectedThread: CodingThread? { selectedThreadID.flatMap { thread($0) } }
    var selectedProject: WorkspaceProject? {
        let id = selectedThread?.projectID ?? selectedProjectID
        return snapshot.projects.first { $0.id == id }
    }
    var approvals: [UUID: [ApprovalRequest]] {
        Dictionary(uniqueKeysWithValues: snapshot.threads.map { ($0.id, $0.runtimeRequests.map(\.request)) })
    }
    func isResponding(_ request: ApprovalRequest, threadID: UUID) -> Bool {
        thread(threadID)?.runtimeRequests.first(where: { $0.id == request.id })?.responding == true
    }
    func gitInspector(path: String) -> GitInspectorStore {
        let path = URL(fileURLWithPath: path).standardizedFileURL.resolvingSymlinksInPath().path
        if let existing = gitInspectors[path] { return existing }
        let model = GitInspectorStore(path: path, canMutate: { [weak self] in self?.canEditWorkspace(path) == true })
        if terminating { model.prepareForShutdown() }
        gitInspectors[path] = model; return model
    }
    func pullRequestStore(path: String) -> PullRequestStore {
        let path = Self.canonicalPath(path)
        if let existing = pullRequestStores[path] { return existing }
        let model = PullRequestStore(path: path, session: pullRequestSessionFactory(URL(fileURLWithPath: path)), engine: engine,
            owner: { [weak self] in self?.pullRequestProjectID(path: path) },
            canRead: { [weak self] in
                guard let self, !self.terminating, self.pullRequestProjectID(path: path) != nil else { return false }
                return !self.removalEditorLocks.values.contains { $0.contains(where: { Self.pathsOverlap($0, path) }) } &&
                    !self.snapshot.isPullRequestCheckoutLocked(path: path) &&
                    !self.pullRequestCheckoutLocks.values.contains { $0.contains { Self.pathsOverlap($0, path) } }
            }, canMutate: { [weak self] in self?.canCreatePullRequest(path: path) == true },
            updateWorkspace: { [weak self] in self?.apply($0) },
            checkoutSupport: .init(configuration: { [weak self] in self?.pullRequestCheckoutConfiguration(path: path) },
                canPrepare: { [weak self] mode, plan, excluded in self?.canPreparePullRequestCheckout(path: path, mode: mode, plan: plan, excludingOperationID: excluded) == true },
                begin: { [weak self] review in
                    guard let self else { throw CancellationError() }
                    return try await self.beginPullRequestCheckout(review)
                }, open: { [weak self] id in self?.openPullRequestCheckoutConversation(id) },
                unavailableReason: { [weak self] mode, plan, excluded in
                    self?.pullRequestCheckoutUnavailableReason(path: path, mode: mode, plan: plan, excludingOperationID: excluded)
                }, busyWorktreePaths: { [weak self] in self?.busyPullRequestWorktreePaths() ?? [] }))
        model.apply(snapshot)
        if terminating { model.prepareForShutdown() }
        pullRequestStores[path] = model
        return model
    }
    private func pullRequestProjectID(path: String) -> UUID? {
        let owners = Set(snapshot.projects.filter { Self.canonicalPath($0.path) == path }.map(\.id) +
            snapshot.threads.filter { Self.canonicalPath($0.workspacePath) == path }.map(\.projectID))
        return owners.count == 1 ? owners.first : nil
    }
    private func canCreatePullRequest(path: String) -> Bool {
        let context = pullRequestStores[path]?.context
        let paths = [path] + (context.map { [$0.repositoryPath, $0.commonDirectoryPath] } ?? [])
        guard paths.allSatisfy({ canEditWorkspace($0) }), pullRequestProjectID(path: path) != nil,
              !paths.contains(where: { snapshot.isPullRequestCheckoutCoordinating(path: $0) }),
              !gitInspectors.contains(where: { Self.pathsOverlap(path, $0.key) && $0.value.operationName != nil }) else { return false }
        return !snapshot.threads.contains { thread in
            Self.pathsOverlap(path, thread.workspacePath) &&
                (thread.isBusy || !thread.queuedTurns.isEmpty || !thread.runtimeRequests.isEmpty ||
                 snapshot.isConversationHistoryLocked(threadID: thread.id) || !snapshot.workspaceReady(for: thread))
        }
    }
    private func pullRequestCheckoutConfiguration(path: String) -> (ProviderConfiguration, RunCheckpointPolicy?)? {
        guard let projectID = pullRequestProjectID(path: path), let project = snapshot.projects.first(where: { $0.id == projectID }) else { return nil }
        let source = selectedThread.flatMap { $0.projectID == projectID && Self.canonicalPath($0.workspacePath) == path ? $0 : nil }
            ?? snapshot.threads.first { $0.projectID == projectID && Self.canonicalPath($0.workspacePath) == path }
            ?? newCodingThread(project: project)
        var configuration = ProviderConfiguration(thread: source); configuration.nativeThreadID = nil
        if source.provider == .claude, configuration.claudeRuntimeConfiguration == nil {
            guard let captured = try? claudeRuntimeCapture(source.workspacePath) else { return nil }
            configuration.claudeRuntimeConfiguration = captured
        }
        if source.provider == .pi, let native = source.piConfiguration, native.runtime == nil {
            guard let captured = try? piRuntimeCapture(source.workspacePath, native.executable, native.instanceID) else { return nil }
            configuration.piConfiguration = .init(instanceID: native.instanceID, executable: native.executable,
                model: native.model, thinkingLevel: native.thinkingLevel, runtime: captured)
        }
        return (configuration, source.checkpointPolicy)
    }
    private func pullRequestCheckoutScope(paths: [String]) -> Set<String> {
        Set(paths.map(Self.canonicalPath))
    }
    private func busyPullRequestWorktreePaths() -> [String] {
        var paths = Array(dirtyEditors.values)
        paths += fileBrowsers.filter { $0.value.isDirty || $0.value.isSaving }.map(\.key)
        paths += gitInspectors.filter { $0.value.operationName != nil }.map(\.key)
        paths += fileServiceCleanupTasks.keys
        paths += workspaceTerminalSessions.compactMap { session in
            switch session.lifecycle { case .running, .closing: return session.directory; case .exited, .failed: return nil }
        }
        return Array(Set(paths.map(Self.canonicalPath)))
    }
    private func canPreparePullRequestCheckout(path: String, mode: GitHubPullRequestCheckoutMode,
                                               plan: GitHubPullRequestCheckoutPlan?, excludingOperationID: UUID?) -> Bool {
        pullRequestCheckoutUnavailableReason(path: path, mode: mode, plan: plan, excludingOperationID: excludingOperationID) == nil
    }
    private func pullRequestCheckoutUnavailableReason(path: String, mode: GitHubPullRequestCheckoutMode,
                                                       plan: GitHubPullRequestCheckoutPlan?, excludingOperationID: UUID?) -> String? {
        guard !terminating, let projectID = pullRequestProjectID(path: path),
              let project = snapshot.projects.first(where: { $0.id == projectID }), project.clone?.isReady ?? true else {
            return String(localized: "The registered checkout is unavailable. Reopen its project before reviewing the pull request.")
        }
        let context = pullRequestStores[path]?.context
        let paths = pullRequestCheckoutScope(paths: plan?.affectedWorkspacePaths ?? (mode == .local ? [context?.repositoryPath ?? path] : []))
        func overlaps(_ path: String) -> Bool { paths.contains { Self.pathsOverlap(path, $0) } }
        let observations = plan.map { [$0.destinationPath] } ?? (mode == .local ? [context?.repositoryPath ?? path] : [])
        func overlapsObserved(_ path: String) -> Bool { overlaps(path) || observations.contains { Self.pathsOverlap(path, $0) } }
        let coordination = plan?.coordinationPaths ?? context.map { [$0.commonDirectoryPath] } ?? []
        guard removalEditorLocks[projectID] == nil,
              !snapshot.isPullRequestCheckoutLocked(path: path, excludingOperationID: excludingOperationID),
              !removalEditorLocks.values.contains(where: { $0.contains(where: overlapsObserved) }),
              !workspaceTransitionLocks.values.contains(where: { $0.contains(where: overlapsObserved) }),
              !checkpointRestoreLocks.values.contains(where: overlapsObserved),
              !(observations + coordination).contains(where: { snapshot.isCheckpointRestoreLocked(path: $0) || snapshot.isPullRequestCreationLocked(path: $0) }),
              !(snapshot.pullRequestCheckouts ?? []).contains(where: { operation in
                  guard operation.id != excludingOperationID, operation.retainsProject else { return false }
                  if operation.locksSource, operation.scopePaths.contains(where: overlapsObserved) { return true }
                  if operation.review.plan.isReadOnly, overlaps(operation.review.plan.destinationPath) { return true }
                  guard let plan, !plan.isReadOnly, !operation.review.plan.isReadOnly else { return false }
                  return plan.commonDirectoryPath == operation.review.plan.commonDirectoryPath &&
                      plan.proof.commonDirectoryIdentity == operation.review.plan.proof.commonDirectoryIdentity &&
                      plan.requestedBranch == operation.review.plan.requestedBranch
              }),
              !pullRequestCheckoutLocks.contains(where: { $0.key != excludingOperationID && $0.value.contains(where: overlapsObserved) }) else {
            return String(localized: "Finish or inspect the pending workspace action before checking out a pull request.")
        }
        guard !dirtyEditors.values.contains(where: overlaps),
              !fileBrowsers.contains(where: { overlaps($0.key) && $0.value.isDirty }) else {
            return String(localized: "Save or discard unsaved editor changes in every window before checking out a pull request.")
        }
        guard !fileBrowsers.contains(where: { overlaps($0.key) && $0.value.isSaving }),
              !gitInspectors.contains(where: { overlaps($0.key) && $0.value.operationName != nil }),
              !fileServiceCleanupTasks.keys.contains(where: overlaps),
              !pullRequestStores.values.contains(where: { model in
                  let ownsAcceptance = excludingOperationID.map { model.acceptingCheckoutID == $0 } ?? false
                  return model.isMutating && !ownsAcceptance && model.mutationPaths.contains(where: overlaps)
              }) else {
            return String(localized: "Wait for file saves and source control operations to finish before checking out a pull request.")
        }
        if workspaceTerminalSessions.contains(where: { session in
            guard overlaps(session.directory) else { return false }
            switch session.lifecycle { case .running, .closing: return true; case .exited, .failed: return false }
        }) {
            return String(localized: "Close terminals and running project scripts using this repository in every window before checking out a pull request.")
        }
        if snapshot.threads.contains(where: { thread in
            thread.pullRequestCheckoutWorkspacePaths.contains(where: overlaps) &&
                (thread.isBusy || !thread.queuedTurns.isEmpty || !thread.runtimeRequests.isEmpty ||
                 snapshot.isConversationHistoryLocked(threadID: thread.id) || !snapshot.workspaceReady(for: thread))
        }) { return String(localized: "Finish active turns, queues, and pending actions in the affected checkout before changing its files. Review again to open a busy worktree without refreshing it.") }
        return nil
    }
    private func beginPullRequestCheckout(_ review: PullRequestCheckoutReview) async throws -> WorkspaceCommandReceipt {
        guard let engine, canPreparePullRequestCheckout(path: Self.canonicalPath(review.plan.sourcePath),
              mode: review.plan.request.mode, plan: review.plan, excludingOperationID: review.id),
              acceptingPullRequestCheckouts.insert(review.id).inserted else {
            throw WorkspaceCommandError(pullRequestCheckoutUnavailableReason(path: Self.canonicalPath(review.plan.sourcePath),
                mode: review.plan.request.mode, plan: review.plan, excludingOperationID: review.id) ?? String(localized: "This checkout is already being prepared."))
        }
        let paths = pullRequestCheckoutScope(paths: review.plan.affectedWorkspacePaths)
        pullRequestCheckoutLocks[review.id] = paths
        pullRequestCheckoutNavigation.updateValue(selectedThreadID, forKey: review.id)
        suspendPullRequestCheckoutCaches(paths: paths)
        flushDrafts()
        let previous = commandTail
        let task = Task {
            await previous?.value
            guard self.canPreparePullRequestCheckout(path: Self.canonicalPath(review.plan.sourcePath),
                    mode: review.plan.request.mode, plan: review.plan, excludingOperationID: review.id) else {
                throw WorkspaceCommandError(self.pullRequestCheckoutUnavailableReason(path: Self.canonicalPath(review.plan.sourcePath),
                    mode: review.plan.request.mode, plan: review.plan, excludingOperationID: review.id) ?? String(localized: "The checkout changed. Review it again."))
            }
            let readers = self.pullRequestStores.filter { entry in paths.contains { Self.pathsOverlap(entry.key, $0) } }
            for model in readers.values { await model.waitForReads() }
            guard self.canPreparePullRequestCheckout(path: Self.canonicalPath(review.plan.sourcePath),
                    mode: review.plan.request.mode, plan: review.plan, excludingOperationID: review.id) else {
                throw WorkspaceCommandError(self.pullRequestCheckoutUnavailableReason(path: Self.canonicalPath(review.plan.sourcePath),
                    mode: review.plan.request.mode, plan: review.plan, excludingOperationID: review.id) ?? String(localized: "The checkout changed. Review it again."))
            }
            let receipt = try await engine.beginPullRequestCheckout(review: review)
            self.apply(await engine.current())
            if let rejection = receipt.rejection { throw WorkspaceCommandError(rejection) }
            return receipt
        }
        commandTail = Task { _ = await task.result }
        defer { acceptingPullRequestCheckouts.remove(review.id); reconcilePullRequestCheckoutLocks() }
        do { return try await task.value }
        catch { apply(await engine.current()); pullRequestCheckoutNavigation.removeValue(forKey: review.id); throw error }
    }
    private func suspendPullRequestCheckoutCaches(paths: Set<String>) {
        func overlaps(_ path: String) -> Bool { paths.contains { Self.pathsOverlap(path, $0) } }
        for (path, model) in fileBrowsers where overlaps(path) { model.suspendForWorkspaceMutation() }
        for (path, model) in gitInspectors where overlaps(path) { model.suspendForWorkspaceMutation() }
        for (path, model) in pullRequestStores where overlaps(path) { model.suspendForWorkspaceMutation() }
    }
    private func reconcilePullRequestCheckoutLocks() {
        let durable = Dictionary(uniqueKeysWithValues: (snapshot.pullRequestCheckouts ?? []).filter(\.locksSource).map {
            ($0.id, pullRequestCheckoutScope(paths: $0.scopePaths))
        })
        for (id, paths) in durable where pullRequestCheckoutLocks[id] == nil {
            pullRequestCheckoutLocks[id] = paths; suspendPullRequestCheckoutCaches(paths: paths)
        }
        for (id, paths) in Array(pullRequestCheckoutLocks) where !acceptingPullRequestCheckouts.contains(id) && durable[id] == nil {
            pullRequestCheckoutLocks.removeValue(forKey: id)
            guard !terminating else { continue }
            func overlaps(_ path: String) -> Bool { paths.contains { Self.pathsOverlap(path, $0) } }
            let browsers = fileBrowsers.filter { overlaps($0.key) }.map(\.value)
            let inspectors = gitInspectors.filter { overlaps($0.key) }.map(\.value)
            let requests = pullRequestStores.filter { overlaps($0.key) }.map(\.value)
            pullRequestCheckoutRefreshTasks[id] = Task { [weak self] in
                for browser in browsers { await browser.refreshAfterWorkspaceMutation() }
                for inspector in inspectors { await inspector.refreshAfterWorkspaceMutation() }
                for model in requests { await model.refreshAfterWorkspaceMutation() }
                self?.pullRequestCheckoutRefreshTasks.removeValue(forKey: id)
            }
        }
        for (id, selection) in Array(pullRequestCheckoutNavigation) {
            guard let operation = snapshot.pullRequestCheckout(id) else {
                if !acceptingPullRequestCheckouts.contains(id) { pullRequestCheckoutNavigation.removeValue(forKey: id) }
                continue
            }
            if operation.phase == .completed {
                pullRequestCheckoutNavigation.removeValue(forKey: id)
                if selectedThreadID == selection { openPullRequestCheckoutConversation(operation.targetThreadID) }
            } else if operation.phase == .failed || operation.acknowledgedAt != nil { pullRequestCheckoutNavigation.removeValue(forKey: id) }
        }
    }
    private func openPullRequestCheckoutConversation(_ id: UUID) {
        guard !terminating, let target = thread(id) else { return }
        selectedProjectID = target.projectID; showArchived = target.isArchived; selectedThreadID = id
    }
    func canAccessWorkspaceFiles(_ path: String) -> Bool {
        let path = Self.canonicalPath(path)
        guard canEditWorkspace(path), fileServiceCleanupTasks[path] == nil else { return false }
        let projects = snapshot.projects.filter { Self.canonicalPath($0.path) == path }
        let threads = snapshot.threads.filter { Self.canonicalPath($0.workspacePath) == path }
        guard !projects.isEmpty || !threads.isEmpty else { return false }
        return projects.allSatisfy { $0.clone?.isReady ?? true } && threads.allSatisfy { workspaceReady(for: $0) }
    }
    func fileService(path: String) throws -> WorkspaceFileService {
        guard canAccessWorkspaceFiles(path) else { throw CoincideError("This workspace is unavailable. Wait for cloning, worktree preparation, or removal to finish before accessing its files.") }
        let path = Self.canonicalPath(path)
        if let service = fileServices[path] { return service }
        let service = WorkspaceFileService(root: URL(fileURLWithPath: path))
        fileServices[path] = service
        return service
    }
    func fileBrowser(path: String) throws -> FileBrowserStore {
        let service = try fileService(path: path), path = Self.canonicalPath(path)
        if let model = fileBrowsers[path] { return model }
        let model = FileBrowserStore(workspace: self, path: path, service: service)
        fileBrowsers[path] = model
        return model
    }
    func externalEditors() -> NativeExternalEditorService {
        if let service = externalEditorService { return service }
        let service = NativeExternalEditorService(resolveWorkspace: { [weak self] root in
            guard let self else { throw CancellationError() }
            return try self.fileService(path: root.path)
        }, authorize: { [weak self] root, captured in
            guard let self, self.canAccessWorkspaceFiles(root.path), let current = try? self.fileService(path: root.path) else { return false }
            return current === captured
        })
        externalEditorService = service; return service
    }
    func projectScripts() -> NativeProjectScriptService {
        if let projectScriptService { return projectScriptService }
        let service = NativeProjectScriptService(resolve: { [weak self] thread in
            guard let self, self.canOpenTerminal(for: thread),
                  let project = self.snapshot.projects.first(where: { $0.id == thread.projectID }) else { throw CancellationError() }
            return .init(projectRoot: project.path, files: try self.fileService(path: thread.workspacePath), settingsKeys: ProjectSettingsKey.candidates(for: project))
        }, authorize: { [weak self] thread, workspace in
            guard let self, self.canOpenTerminal(for: thread),
                  self.snapshot.projects.contains(where: { $0.id == thread.projectID && $0.path == workspace.projectRoot }),
                  let current = try? self.fileService(path: thread.workspacePath) else { return false }
            return current === workspace.files
        }, authorizeWindow: { [weak self] terminals in
            self?.terminalStores[ObjectIdentifier(terminals)]?.value === terminals
        }, read: projectScriptReader, settingsRoot: projectSettings.root)
        projectScriptService = service; return service
    }
    func refreshExternalEditors(forceRefresh: Bool = false) async {
        guard !terminating else { return }
        let editors = await externalEditors().availableEditors(forceRefresh: forceRefresh)
        if !terminating { availableExternalEditors = editors }
    }
    private func closeUnreferencedFileServices(previous: WorkspaceSnapshot) {
        let referenced = Set((snapshot.projects.map(\.path) + snapshot.threads.map(\.workspacePath)).map(Self.canonicalPath))
        let removed = fileServices.filter { !referenced.contains($0.key) }
        for (path, service) in removed {
            fileServices.removeValue(forKey: path)
            let browser = fileBrowsers.removeValue(forKey: path)
            browser?.prepareForShutdown()
            let owners = Set(previous.projects.filter { Self.canonicalPath($0.path) == path }.map(\.id)
                + previous.threads.filter { Self.canonicalPath($0.workspacePath) == path }.map(\.projectID))
            let task = Task { [weak self] in
                await browser?.shutdown()
                await service.close()
                self?.fileServiceCleanupTasks.removeValue(forKey: path)
            }
            fileServiceCleanupTasks[path] = .init(projectIDs: owners, task: task)
        }
    }
    var visibleThreads: [CodingThread] {
        snapshot.threads.filter {
            $0.isArchived == showArchived && (search.isEmpty || $0.title.localizedCaseInsensitiveContains(search) || $0.visibleMessages.contains { $0.text.localizedCaseInsensitiveContains(search) })
        }.sorted { $0.isPinned != $1.isPinned ? $0.isPinned : $0.updatedAt > $1.updatedAt }
    }
    var orderedProjects: [WorkspaceProject] { snapshot.orderedProjects }
    var orderedProjectGroups: [ProjectGroup] { snapshot.orderedProjectGroups }
    var projectGroupingMode: ProjectGroupingMode { snapshot.effectiveSidebarPreferences.groupingMode }
    var projectSortMode: ProjectSortMode { snapshot.effectiveSidebarPreferences.sortMode }
    func projectGroup(containing projectID: UUID) -> ProjectGroup? {
        snapshot.projectGroups.first { $0.memberProjectIDs.contains(projectID) }
    }
    func isProjectGroupExpanded(_ key: String) -> Bool { snapshot.isProjectGroupExpanded(key) }
    func sidebarThreads(groupKey: String) -> [CodingThread] {
        guard let group = snapshot.projectGroups.first(where: { $0.key == groupKey }) else { return [] }
        let members = Set(group.memberProjectIDs)
        let threads = visibleThreads.filter { members.contains($0.projectID) }
        return isProjectGroupExpanded(groupKey) ? threads : threads.filter { $0.id == selectedThreadID }
    }
    func preferredProject(in group: ProjectGroup) -> WorkspaceProject? {
        let members = Set(group.memberProjectIDs)
        let activeID = snapshot.effectiveSidebarPreferences.activeProjectByGroup[group.key]
        if let project = snapshot.projects.first(where: { $0.id == activeID && members.contains($0.id) && ($0.clone?.isReady ?? true) }) { return project }
        let selectedID = selectedProjectID ?? selectedThread?.projectID
        if let project = snapshot.projects.first(where: { $0.id == selectedID && members.contains($0.id) }) { return project }
        return group.members.first(where: { $0.clone?.isReady ?? true }) ?? group.members.first
    }
    func setProjectGroupingMode(_ mode: ProjectGroupingMode) { sendCommand(.setProjectGroupingMode(mode)) }
    func setProjectGroupingOverride(_ id: UUID, mode: ProjectGroupingMode?) { sendCommand(.setProjectGroupingOverride(projectID: id, mode: mode)) }
    func setProjectGroupExpanded(_ group: ProjectGroup, expanded: Bool) {
        sendCommand(.setProjectGroupExpanded(groupKey: group.key, expectedProjectIDs: group.memberProjectIDs, expanded: expanded))
    }
    func setProjectGroupCheckout(_ group: ProjectGroup, projectID: UUID) {
        sendCommand(.setProjectGroupCheckout(groupKey: group.key, expectedProjectIDs: group.memberProjectIDs, projectID: projectID))
    }
    func refreshRepositoryIdentity(_ id: UUID) {
        guard !terminating, let engine else { return }
        Task {
            do { _ = try await engine.refreshRepositoryIdentity(projectID: id); apply(await engine.current()) }
            catch is CancellationError { }
            catch { if !terminating, snapshot.projects.contains(where: { $0.id == id }) { errorMessage = GitService.redactURLs(error.localizedDescription) } }
        }
    }
    func moveProjectGroup(_ key: String, by offset: Int) {
        let groups = snapshot.projectGroups
        guard projectSortMode == .manual, let index = groups.firstIndex(where: { $0.key == key }),
              [-1, 1].contains(offset), groups.indices.contains(index + offset) else { return }
        moveProjectGroups(fromOffsets: IndexSet(integer: index), toOffset: offset > 0 ? index + 2 : index - 1)
    }
    func moveProjectGroups(fromOffsets offsets: IndexSet, toOffset destination: Int) {
        let groups = snapshot.projectGroups, order = snapshot.projects.map(\.id)
        guard projectSortMode == .manual, !offsets.isEmpty, offsets.allSatisfy({ groups.indices.contains($0) }),
              (0...groups.count).contains(destination) else { return }
        let movingMembers = Set(offsets.flatMap { groups[$0].memberProjectIDs })
        let moving = order.filter { movingMembers.contains($0) }
        var next = order.filter { !movingMembers.contains($0) }
        let remainingGroups = groups.enumerated().filter { !offsets.contains($0.offset) }.map(\.element)
        let groupInsertion = destination - offsets.filter { $0 < destination }.count
        var nextGroups = remainingGroups
        nextGroups.insert(contentsOf: offsets.map { groups[$0] }, at: groupInsertion)
        guard nextGroups.map(\.key) != groups.map(\.key) else { return }
        let insertion: Int
        if remainingGroups.indices.contains(groupInsertion) {
            let target = Set(remainingGroups[groupInsertion].memberProjectIDs)
            insertion = next.firstIndex(where: { target.contains($0) }) ?? next.count
        } else { insertion = next.count }
        next.insert(contentsOf: moving, at: insertion)
        let membership = Dictionary(uniqueKeysWithValues: groups.map { ($0.key, $0.memberProjectIDs) })
        sendCommand(.reorderProjectGroups(projectIDs: next, expectedOrder: order, expectedGroups: membership))
    }
    func isProjectExpanded(_ id: UUID) -> Bool { snapshot.isProjectExpanded(id) }
    func sidebarThreads(projectID: UUID) -> [CodingThread] {
        let threads = visibleThreads.filter { $0.projectID == projectID }
        return isProjectExpanded(projectID) ? threads : threads.filter { $0.id == selectedThreadID }
    }
    func renameProject(_ id: UUID, title: String) { sendCommand(.renameProject(projectID: id, title: title)) }
    func renameProjectGroup(_ group: ProjectGroup, title: String) {
        sendCommand(.renameProjectGroup(groupKey: group.key, expectedProjects: group.memberProjectReferences, title: title))
    }
    private var workspaceTerminalSessions: [LocalTerminalSession] {
        var ids = Set<UUID>()
        return (terminalStores.values.compactMap(\.value).flatMap { $0.sessions.values.flatMap { $0 } } + Array(closingTerminalSessions.values))
            .filter { ids.insert($0.id).inserted }
    }
    func registerTerminals(_ terminals: TerminalWorkspaceStore) {
        terminalStores[ObjectIdentifier(terminals)] = WeakTerminalStore(terminals)
        terminals.sessionWillClose = { [weak self] in self?.retainClosingTerminal($0) }
    }
    func restoreTerminals(_ terminals: TerminalWorkspaceStore) {
        guard hasLoadedWorkspace, engine != nil, !terminating else { return }
        terminals.restore(from: terminalArchives, currentThreads: { [weak self] in self?.snapshot.threads ?? [] })
    }
    func unregisterTerminals(_ terminals: TerminalWorkspaceStore) {
        terminals.suspend()
        terminalStores.removeValue(forKey: ObjectIdentifier(terminals))
        terminals.sessionWillClose = nil
        let id = UUID()
        terminalSuspensions[id] = Task { [weak self] in
            await terminals.waitForRestoration(); await terminals.waitForPersistence()
            self?.terminalSuspensions.removeValue(forKey: id)
        }
    }
    private func retainClosingTerminal(_ session: LocalTerminalSession) {
        guard closingTerminalSessions[session.id] == nil else { return }
        closingTerminalSessions[session.id] = session
        closingTerminalTasks[session.id] = Task { [weak self] in
            await session.waitForClose()
            self?.closingTerminalSessions.removeValue(forKey: session.id)
            self?.closingTerminalTasks.removeValue(forKey: session.id)
        }
    }
    func setEditorDirty(_ id: UUID, workspacePath: String, dirty: Bool) {
        if dirty { dirtyEditors[id] = Self.canonicalPath(workspacePath) } else { dirtyEditors.removeValue(forKey: id) }
    }
    var hasUnsavedFileEdits: Bool { !dirtyEditors.isEmpty }
    private static func pathsOverlap(_ first: String, _ second: String) -> Bool {
        let a = canonicalPath(first), b = canonicalPath(second)
        return a == b || a == "/" || b == "/" || a.hasPrefix(b + "/") || b.hasPrefix(a + "/")
    }
    func canEditWorkspace(_ path: String) -> Bool {
        let path = Self.canonicalPath(path)
        guard !terminating, !removalEditorLocks.values.contains(where: { $0.contains(path) }),
              !workspaceTransitionLocks.values.contains(where: { $0.contains(path) }),
              !snapshot.isCheckpointRestoreLocked(path: path),
              !snapshot.isPullRequestCreationLocked(path: path),
              !snapshot.isPullRequestCheckoutLocked(path: path),
              !pullRequestStores.values.contains(where: { model in model.isAccepting && model.mutationPaths.contains { Self.pathsOverlap(path, $0) } }),
              !pullRequestCheckoutLocks.values.contains(where: { $0.contains { Self.pathsOverlap(path, $0) } }),
              !checkpointRestoreLocks.values.contains(where: { Self.pathsOverlap(path, $0) }) else { return false }
        return !snapshot.threads.contains { removalEditorLocks[$0.projectID] != nil && Self.canonicalPath($0.workspacePath) == path }
    }
    func projectRemovalRequest(_ id: UUID) -> ProjectRemovalRequest? {
        guard let project = snapshot.projects.first(where: { $0.id == id }) else { return nil }
        let threads = snapshot.threads.filter { $0.projectID == id }
        let paths = Set(([project.path] + threads.map(\.workspacePath)).map(Self.canonicalPath))
        return .init(id: id, name: project.name, path: project.path, threadIDs: threads.map(\.id).sorted { $0.uuidString < $1.uuidString },
                     dirtyEditorIDs: Set(dirtyEditors.compactMap { paths.contains($0.value) ? $0.key : nil }))
    }
    func removeProject(_ request: ProjectRemovalRequest) async throws {
        guard !terminating, let engine, removalEditorLocks[request.id] == nil,
              let current = projectRemovalRequest(request.id), let project = snapshot.projects.first(where: { $0.id == request.id }) else { throw CancellationError() }
        guard current.path == request.path else { throw CoincideError("The checkout changed. Review the project removal again.") }
        guard current.dirtyEditorIDs.isSubset(of: request.dirtyEditorIDs) else {
            throw CoincideError("New unsaved file edits appeared. Review the project removal again before discarding them.")
        }
        removalEditorLocks[request.id] = Set(([project.path] + snapshot.threads.filter { $0.projectID == request.id }.map(\.workspacePath)).map(Self.canonicalPath))
        let affected = Set(request.threadIDs)
        var removed = false
        defer { removalEditorLocks.removeValue(forKey: request.id); if !removed { composerDraftTools.resume(threadIDs: affected) } }
        await composerDraftTools.suspend(threadIDs: affected)
        _ = try await enqueue(.removeProject(projectID: request.id, expectedThreadIDs: request.threadIDs), preflight: {
            guard let latest = self.projectRemovalRequest(request.id) else { throw CancellationError() }
            guard latest.path == request.path else { throw CoincideError("The checkout changed. Review the project removal again.") }
            guard latest.dirtyEditorIDs.isSubset(of: request.dirtyEditorIDs) else {
                throw CoincideError("New unsaved file edits appeared. Review the project removal again before discarding them.")
            }
            let paths = [latest.path] + self.snapshot.threads.filter { $0.projectID == request.id }.map(\.workspacePath)
            self.extendRemovalLocks(projectIDs: [request.id], paths: paths)
        }).value
        removed = true
        await engine.awaitProjectRemovalCleanup(projectID: request.id)
        await awaitRemovalCleanup(projectIDs: [request.id])
    }
    func projectGroupRemovalRequest(_ key: String) -> ProjectGroupRemovalRequest? {
        guard let group = snapshot.projectGroups.first(where: { $0.key == key }) else { return nil }
        let members = Set(group.memberProjectIDs), threads = snapshot.threads.filter { members.contains($0.projectID) }
        let paths = Set((group.memberProjectReferences.map(\.path) + threads.map(\.workspacePath)).map(Self.canonicalPath))
        return .init(id: key, name: group.displayName, projects: group.memberProjectReferences,
                     threadIDs: threads.map(\.id).sorted { $0.uuidString < $1.uuidString },
                     dirtyEditorIDs: Set(dirtyEditors.compactMap { paths.contains($0.value) ? $0.key : nil }))
    }
    private func validateGroupRemoval(_ request: ProjectGroupRemovalRequest) throws {
        guard let current = projectGroupRemovalRequest(request.id),
              current.projects.sorted(by: { $0.id.uuidString < $1.id.uuidString }) == request.projects.sorted(by: { $0.id.uuidString < $1.id.uuidString }),
              current.threadIDs == request.threadIDs else {
            throw CoincideError("The group's checkouts or conversations changed. Review the group removal again.")
        }
        guard current.dirtyEditorIDs.isSubset(of: request.dirtyEditorIDs) else {
            throw CoincideError("New unsaved file edits appeared. Review the group removal again before discarding them.")
        }
    }
    func removeProjectGroup(_ request: ProjectGroupRemovalRequest) async throws {
        guard !terminating, let engine else { throw CancellationError() }
        try validateGroupRemoval(request)
        let members = Set(request.projects.map(\.id))
        guard !members.isEmpty, members.allSatisfy({ removalEditorLocks[$0] == nil }) else { throw CancellationError() }
        let threads = snapshot.threads.filter { members.contains($0.projectID) }
        let paths = Set((request.projects.map(\.path) + threads.map(\.workspacePath)).map(Self.canonicalPath))
        for id in members { removalEditorLocks[id] = paths }
        let affected = Set(request.threadIDs)
        var removed = false
        defer { for id in members { removalEditorLocks.removeValue(forKey: id) }; if !removed { composerDraftTools.resume(threadIDs: affected) } }
        await composerDraftTools.suspend(threadIDs: affected)
        _ = try await enqueue(.removeProjectGroup(groupKey: request.id, expectedProjects: request.projects, expectedThreadIDs: request.threadIDs), preflight: {
            try self.validateGroupRemoval(request)
            let paths = request.projects.map(\.path) + self.snapshot.threads.filter { members.contains($0.projectID) }.map(\.workspacePath)
            self.extendRemovalLocks(projectIDs: members, paths: paths)
        }).value
        removed = true
        for id in members { await engine.awaitProjectRemovalCleanup(projectID: id) }
        await awaitRemovalCleanup(projectIDs: members)
    }
    private func awaitRemovalCleanup(projectIDs: Set<UUID>) async {
        while true {
            let tasks = removalCleanupTasks.values.filter { !$0.projectIDs.isDisjoint(with: projectIDs) }.map(\.task)
            guard !tasks.isEmpty else { return }
            for task in tasks { await task.value }
        }
    }
    private func extendRemovalLocks(projectIDs: Set<UUID>, paths: [String]) {
        let added = Set(paths.map(Self.canonicalPath))
        for id in projectIDs { removalEditorLocks[id, default: []].formUnion(added) }
    }
    private static func canonicalPath(_ path: String) -> String {
        URL(fileURLWithPath: path).standardizedFileURL.resolvingSymlinksInPath().path
    }
    func setProjectExpanded(_ id: UUID, expanded: Bool) { sendCommand(.setProjectExpanded(projectID: id, expanded: expanded)) }
    func setProjectSortMode(_ mode: ProjectSortMode) { sendCommand(.setProjectSortMode(mode)) }
    func moveProject(_ id: UUID, by offset: Int) {
        let order = snapshot.projects.map(\.id)
        guard projectSortMode == .manual, let index = order.firstIndex(of: id), [-1, 1].contains(offset), order.indices.contains(index + offset) else { return }
        var next = order; next.remove(at: index); next.insert(id, at: index + offset)
        sendCommand(.reorderProjects(projectIDs: next, expectedOrder: order))
    }
    func moveProjects(fromOffsets offsets: IndexSet, toOffset destination: Int) {
        let order = snapshot.projects.map(\.id)
        guard projectSortMode == .manual, !offsets.isEmpty,
              offsets.allSatisfy({ order.indices.contains($0) }), (0...order.count).contains(destination) else { return }
        let moving = offsets.map { order[$0] }
        var next = order.enumerated().filter { !offsets.contains($0.offset) }.map(\.element)
        let insertion = destination - offsets.filter { $0 < destination }.count
        next.insert(contentsOf: moving, at: insertion)
        sendCommand(.reorderProjects(projectIDs: next, expectedOrder: order))
    }
    func load() async {
        if let loadingTask { await loadingTask.value; return }
        let task = Task<Void, Never> { await self.loadRuntime() }
        loadingTask = task; await task.value
    }
    private func loadRuntime() async {
        defer { isLoading = false }
        guard let engine else { return }
        do {
            let stream = await engine.updates()
            updatesTask = Task { [weak self] in for await value in stream { self?.apply(value) } }
            _ = try await engine.load()
            apply(await engine.current())
            await composerDraftTools.load()
            await agentSessionImports.load()
            selectedThreadID = snapshot.effectiveSidebarPreferences.selectedThreadID
                ?? snapshot.threads.first(where: { !$0.isArchived })?.id
            selectedProjectID = selectedThread?.projectID ?? snapshot.projects.first?.id
            showArchived = selectedThread?.isArchived ?? false
            hasLoadedWorkspace = true
        } catch { errorMessage = error.localizedDescription }
    }
    private func apply(_ update: WorkspaceUpdate) {
        guard update.sequence >= lastSequence else { return }
        _ = retireSkills { scope in
            guard let next = update.snapshot.threads.first(where: { $0.id == scope.threadID }),
                  scope.matches(next), update.snapshot.providerReady(for: next) else { return true }
            return false
        }
        for id in Array(acpModels.keys) {
            let old = snapshot.threads.first { $0.id == id }, next = update.snapshot.threads.first { $0.id == id }
            if old?.providerMetadata != next?.providerMetadata || old?.acpAgent != next?.acpAgent || old?.workspacePath != next?.workspacePath {
                acpModels.removeValue(forKey: id)
            }
        }
        for id in Array(openCodeCatalogs.keys) {
            let old = snapshot.threads.first { $0.id == id }, next = update.snapshot.threads.first { $0.id == id }
            if next?.provider != .opencode || old?.workspacePath != next?.workspacePath ||
                old?.openCodeConfiguration?.runtimeIdentity != next?.openCodeConfiguration?.runtimeIdentity {
                openCodeCatalogs.removeValue(forKey: id)
            }
        }
        for id in Array(piModels.keys) {
            let old = snapshot.threads.first { $0.id == id }, next = update.snapshot.threads.first { $0.id == id }
            if next?.provider != .pi || old?.workspacePath != next?.workspacePath ||
                old?.piConfiguration?.runtimeIdentity != next?.piConfiguration?.runtimeIdentity || old?.permission != next?.permission {
                piModels.removeValue(forKey: id)
            }
        }
        for id in Array(museModels.keys) {
            let old = snapshot.threads.first { $0.id == id }, next = update.snapshot.threads.first { $0.id == id }
            if next?.provider != .muse || old?.workspacePath != next?.workspacePath ||
                old?.museConfiguration?.runtimeIdentity != next?.museConfiguration?.runtimeIdentity || old?.permission != next?.permission {
                museModels.removeValue(forKey: id)
            }
        }
        for id in Array(codexModels.keys) {
            let old = snapshot.threads.first { $0.id == id }, next = update.snapshot.threads.first { $0.id == id }
            if next?.provider != .codex || old?.workspacePath != next?.workspacePath ||
                old.map({ ProviderConfiguration(thread: $0).codexRuntimeBinding }) != next.map({ ProviderConfiguration(thread: $0).codexRuntimeBinding }) {
                codexModels.removeValue(forKey: id)
            }
        }
        for id in Array(antigravityModels.keys) {
            let old = snapshot.threads.first { $0.id == id }, next = update.snapshot.threads.first { $0.id == id }
            if next?.provider != .antigravity || old?.workspacePath != next?.workspacePath ||
                old?.antigravityConfiguration?.runtimeIdentity != next?.antigravityConfiguration?.runtimeIdentity || old?.permission != next?.permission {
                antigravityModels.removeValue(forKey: id)
            }
        }
        let removedThreads = Set(snapshot.threads.map(\.id)).subtracting(update.snapshot.threads.map(\.id))
        let removedProjects = Set(snapshot.projects.map(\.id)).subtracting(update.snapshot.projects.map(\.id))
        let changedScriptThreads = Set(snapshot.threads.compactMap { old -> UUID? in
            guard let next = update.snapshot.threads.first(where: { $0.id == old.id }),
                  old.projectID == next.projectID, old.workspacePath == next.workspacePath,
                  old.workspacePreparation?.id == next.workspacePreparation?.id else { return old.id }
            return nil
        })
        projectScriptService?.invalidate(threadIDs: changedScriptThreads)
        let previous = snapshot
        lastSequence = update.sequence; snapshot = update.snapshot
        if !terminating { notifications.observe(snapshot, baseline: isLoading, appIsActive: NSApp?.isActive ?? false) }
        acpConnections.invalidate(validAgents: snapshot.acpAgents)
        for model in pullRequestStores.values { model.apply(snapshot) }
        for id in Array(contextTransferStores.keys) { updateContextTransferStore(threadID: id) }
        closeUnreferencedFileServices(previous: previous)
        if !removedThreads.isEmpty || !removedProjects.isEmpty { reconcileRemovedResources(threadIDs: removedThreads, projectIDs: removedProjects) }
        if let error = update.error, !terminating { errorMessage = error }
        reconcileCheckpointRestoreLocks()
        reconcilePullRequestCheckoutLocks()
        openAppliedHistoryForks()
        processAutomaticHistoryRecalls()
    }
    private func reconcileRemovedResources(threadIDs: Set<UUID>, projectIDs: Set<UUID>) {
        let modelReads = threadIDs.compactMap { codexModelDefaultsReads[$0]?.task }
        let skills = providerSkillsDrains.values.filter { projectIDs.contains($0.scope.projectID) || threadIDs.contains($0.scope.threadID) }.map(\.task)
        for id in threadIDs {
            pendingDrafts.removeValue(forKey: id); draftOverrides.removeValue(forKey: id); acpModels.removeValue(forKey: id)
            promptSteeringAvailability.removeValue(forKey: id)
            codexModelDefaultsReads.removeValue(forKey: id)?.task.cancel()
        }
        let imports = attachmentImportTasks.compactMap { key, task in attachmentImportOwners[key].map { threadIDs.contains($0) } == true ? task : nil }
        let worktrees = worktreeTasks.filter { threadIDs.contains($0.key) }.map(\.value)
        let worktreeReads = worktreeOptionsReads.values.filter { threadIDs.contains($0.threadID) }.map(\.task)
        let historyReads = historyReviewReads.values.filter { threadIDs.contains($0.threadID) }.map(\.task)
        let historyChecks = historyInspections.values.filter { threadIDs.contains($0.threadID) }.map(\.task)
        let piHistoryActions = piHistoryResponses.values.filter { threadIDs.contains($0.owner.threadID) }.map(\.owner.task)
            + piHistoryCancellations.values.filter { threadIDs.contains($0.threadID) }.map(\.task)
        let piFreshReads = piFreshHistoryReads.filter { threadIDs.contains($0.key) }.map(\.value.task)
        for id in threadIDs { piFreshHistoryObservations.removeValue(forKey: id) }
        let automaticRecalls = automaticHistoryRecallTasks.filter { key, _ in
            conversationHistoryOperation(key).map { threadIDs.contains($0.review.sourceThreadID) } ?? true
        }.map(\.value)
        let restoreReads = checkpointRestoreReads.values.filter { threadIDs.contains($0.threadID) }.map(\.task)
        let restoreChecks = checkpointRestoreInspections.values.filter { threadIDs.contains($0.threadID) }.map(\.task)
        let scriptReads = projectScriptService?.invalidate(threadIDs: threadIDs) ?? []
        let retries = projectCloneRetryTasks.filter { projectIDs.contains($0.key) }.map(\.value)
        for task in imports { task.cancel() }; for task in worktrees { task.cancel() }; for task in retries { task.cancel() }
        for task in worktreeReads { task.cancel() }
        for task in historyReads { task.cancel() }; for task in historyChecks { task.cancel() }
        for task in piHistoryActions { task.cancel() }
        for task in piFreshReads { task.cancel() }
        for task in restoreReads { task.cancel() }; for task in restoreChecks { task.cancel() }
        for task in automaticRecalls { task.cancel() }
        let terminals = terminalStores.values.compactMap(\.value)
        terminalStores = terminalStores.filter { $0.value.value != nil }
        let closingTerminals = terminals.flatMap { $0.remove(threadIDs: threadIDs) }
        let closingFileServices = fileServiceCleanupTasks.values.filter { !$0.projectIDs.isDisjoint(with: projectIDs) }.map(\.task)
        let referencedPaths = Set((snapshot.projects.map(\.path) + snapshot.threads.map(\.workspacePath)).map(Self.canonicalPath))
        dirtyEditors = dirtyEditors.filter { referencedPaths.contains($0.value) }
        let discardedInspectors = gitInspectors.filter { !referencedPaths.contains($0.key) }
        for (path, inspector) in discardedInspectors { inspector.prepareForShutdown(); gitInspectors.removeValue(forKey: path) }
        let discardedPullRequests = pullRequestStores.filter { !referencedPaths.contains($0.key) }
        for (path, model) in discardedPullRequests { model.prepareForShutdown(); pullRequestStores.removeValue(forKey: path) }
        if let navigation = fileNavigation, !referencedPaths.contains(Self.canonicalPath(navigation.workspacePath)) { fileNavigation = nil }
        if selectedThreadID.map({ threadIDs.contains($0) }) == true {
            let fallback = snapshot.threads.first(where: { $0.isArchived == showArchived })
                ?? snapshot.threads.first(where: { !$0.isArchived }) ?? snapshot.threads.first
            selectedThreadID = fallback?.id
            showArchived = fallback?.isArchived ?? false
        }
        if selectedProjectID.map({ projectIDs.contains($0) }) == true {
            selectedProjectID = selectedThread?.projectID ?? snapshot.projects.first?.id
        }
        let cleanupID = UUID()
        let task: Task<Void, Never> = Task { [weak self] in
            await self?.composerDraftTools.forgetRemovedThreads(threadIDs)
            for task in modelReads { _ = await task.value }
            for task in skills { await task.value }
            for task in imports { await task.value }
            for task in worktrees { _ = await task.result }
            for task in worktreeReads { _ = await task.result }
            for task in historyReads { _ = await task.result }; for task in historyChecks { _ = await task.result }
            for task in piHistoryActions { _ = await task.result }
            for task in piFreshReads { _ = await task.result }
            for task in restoreReads { _ = await task.result }; for task in restoreChecks { _ = await task.result }
            for task in automaticRecalls { await task.value }
            for task in scriptReads { await task.value }
            for task in retries { await task.value }
            for terminal in closingTerminals { await terminal.waitForClose() }
            for inspector in discardedInspectors.values { await inspector.shutdown() }
            for model in discardedPullRequests.values { await model.shutdown() }
            for task in closingFileServices { await task.value }
            self?.removalCleanupTasks.removeValue(forKey: cleanupID)
        }
        removalCleanupTasks[cleanupID] = .init(projectIDs: projectIDs, task: task)
    }
    private func enqueue(_ command: WorkspaceCommand, preflight: (@MainActor () throws -> Void)? = nil) -> Task<WorkspaceCommandReceipt, any Error> {
        enqueuePreparing({ command }, preflight: preflight)
    }
    private func enqueuePreparing(_ prepare: @escaping @MainActor () throws -> WorkspaceCommand,
                                  preflight: (@MainActor () throws -> Void)? = nil) -> Task<WorkspaceCommandReceipt, any Error> {
        let previous = commandTail, engine = engine
        let task = Task<WorkspaceCommandReceipt, any Error> {
            await previous?.value
            try preflight?()
            guard let engine else { throw CoincideError("The workspace runtime is unavailable.") }
            let receipt = try await engine.dispatch(try prepare())
            apply(await engine.current())
            return receipt
        }
        commandTail = Task { _ = try? await task.value }
        return task
    }
    private func sendCommand(_ command: WorkspaceCommand) {
        let task = enqueue(command)
        Task { do { _ = try await task.value } catch { if !terminating { errorMessage = error.localizedDescription } } }
    }
    func addProject() {
        let panel = NSOpenPanel(); panel.canChooseDirectories = true; panel.canChooseFiles = false
        panel.allowsMultipleSelection = false; panel.prompt = "Add Project"
        panel.begin { [weak self] response in
            guard response == .OK, let url = panel.url else { return }
            self?.addProject(at: url)
        }
    }
    func addProject(at url: URL) {
        var directory: ObjCBool = false
        guard url.isFileURL, FileManager.default.fileExists(atPath: url.path, isDirectory: &directory), directory.boolValue else {
            errorMessage = "Choose an existing project folder."; return
        }
        let project = WorkspaceProject(path: url.path)
        if let existing = snapshot.projects.first(where: { $0.path == project.path }) { selectedProjectID = existing.id; return }
        let task = enqueue(.addProject(project))
        Task {
            do { _ = try await task.value; if let added = snapshot.projects.first(where: { $0.path == project.path }) { selectedProjectID = added.id } }
            catch { errorMessage = error.localizedDescription }
        }
    }
    func workspaceReady(for thread: CodingThread) -> Bool {
        snapshot.workspaceReady(for: thread) && !isCheckpointRestoreLocked(threadID: thread.id) &&
            !isPullRequestCreationLocked(threadID: thread.id) && !isPullRequestCheckoutLocked(threadID: thread.id) &&
            !workspaceTransitionLocks.values.contains { $0.contains(Self.canonicalPath(thread.workspacePath)) }
    }
    func canPresentWorkspaceInspector(for thread: CodingThread) -> Bool {
        if workspaceReady(for: thread) { return true }
        // Keep read-only PR recovery mounted while its write hold is active.
        // File access and source-control mutations retain their separate gates.
        return !terminating && snapshot.workspaceReady(for: thread) &&
            (isPullRequestCreationLocked(threadID: thread.id) || isPullRequestCheckoutLocked(threadID: thread.id)) &&
            !isCheckpointRestoreLocked(threadID: thread.id) && removalEditorLocks[thread.projectID] == nil &&
            !workspaceTransitionLocks.values.contains { $0.contains(Self.canonicalPath(thread.workspacePath)) }
    }
    func canOpenTerminal(for captured: CodingThread) -> Bool {
        guard let current = thread(captured.id), current.projectID == captured.projectID,
              current.workspacePath == captured.workspacePath,
              current.workspacePreparation?.id == captured.workspacePreparation?.id else { return false }
        return workspaceReady(for: current) && canAccessWorkspaceFiles(current.workspacePath)
    }
    func createManagedProject(name: String) async throws -> ManagedProjectCreationResult {
        guard !terminating, engine != nil else { throw CancellationError() }
        let name = try ManagedProjectService.validatedName(name)
        let root = managedProjectsRoot, creator = projectCreator, id = UUID()
        let task = Task.detached(priority: .userInitiated) { try await creator(name, root) }
        projectCreationTasks[id] = task
        defer { projectCreationTasks.removeValue(forKey: id) }
        let result = try await withTaskCancellationHandler { try await task.value } onCancel: { task.cancel() }
        try Task.checkCancellation()
        guard !terminating else { throw CancellationError() }
        let thread = newCodingThread(project: result.project)
        do { _ = try await enqueue(.addProjectWithThread(project: result.project, thread: thread)).value }
        catch {
            throw CoincideError("The project files are preserved at \(result.project.path), but the project could not be opened. \(GitService.redactURLs(error.localizedDescription))")
        }
        if snapshot.threads.contains(where: { $0.id == thread.id }) { selectedProjectID = result.project.id; selectedThreadID = thread.id; showArchived = false }
        return result
    }
    func cloneRepository(source: String, destination: URL) async throws {
        let plan = try GitClonePlan.prepare(source: source, destination: destination)
        var project = WorkspaceProject(path: plan.destinationPath); project.clone = .init(plan: plan)
        let thread = newCodingThread(project: project)
        _ = try await enqueue(.startProjectClone(project: project, thread: thread)).value
        if snapshot.threads.contains(where: { $0.id == thread.id }) { selectedProjectID = project.id; selectedThreadID = thread.id; showArchived = false }
    }
    func cancelProjectClone(_ projectID: UUID) { sendCommand(.cancelProjectClone(projectID)) }
    func retryProjectClone(_ projectID: UUID) {
        guard !terminating, snapshot.projects.first(where: { $0.id == projectID })?.clone?.canRetry == true,
              retryingProjectClones.insert(projectID).inserted else { return }
        projectCloneRetryTasks[projectID] = Task {
            defer { retryingProjectClones.remove(projectID); projectCloneRetryTasks.removeValue(forKey: projectID) }
            guard let engine else { return }
            do { _ = try await engine.retryProjectClone(projectID); apply(await engine.current()) }
            catch { if !terminating, snapshot.projects.contains(where: { $0.id == projectID }) { errorMessage = GitService.redactURLs(error.localizedDescription) } }
        }
    }
    func isRetryingProjectClone(_ projectID: UUID) -> Bool { retryingProjectClones.contains(projectID) }
    func newThread(projectID: UUID? = nil) {
        let project: WorkspaceProject
        if let projectID {
            // A stale checkout menu must never redirect its action to another workspace.
            guard let selected = snapshot.projects.first(where: { $0.id == projectID }) else { return }
            project = selected
        } else if let currentID = selectedProjectID ?? selectedThread?.projectID,
                  let group = projectGroup(containing: currentID), let selected = preferredProject(in: group) {
            project = selected
        } else if let selected = snapshot.projects.first { project = selected }
        else { addProject(); return }
        let thread = newCodingThread(project: project)
        let task = enqueue(.createThread(thread))
        Task {
            do {
                _ = try await task.value
                guard self.thread(thread.id) != nil else { return }
                selectedThreadID = thread.id
                selectedProjectID = project.id; showArchived = false
            } catch { errorMessage = error.localizedDescription }
        }
    }
    func setClaudeModelOptions(_ options: ClaudeModelOptions, model: ProviderModel, threadID: UUID, expected: ProviderConfiguration? = nil) {
        let captured = expected ?? thread(threadID).map { ProviderConfiguration(thread: $0) }
        let task = enqueuePreparing { [weak self] in
            guard let self, !self.terminating, let current = self.thread(threadID), current.provider == .claude,
                  let captured, ProviderConfiguration(thread: current).matchesModelControlCapture(captured),
                  let actual = self.models(for: current).first(where: { $0.id == model.id }), actual == model else {
                throw CoincideError("Claude's model controls changed. Refresh models and choose the current options.")
            }
            return .editThread(threadID, .claudeModelOptions(model: actual, options: options, expected: captured))
        }
        Task { do { _ = try await task.value } catch { if !terminating { errorMessage = error.localizedDescription } } }
    }
    func setCodexServiceTier(_ tier: String?, model: ProviderModel, threadID: UUID, expected: ProviderConfiguration? = nil) {
        let captured = expected ?? thread(threadID).map { ProviderConfiguration(thread: $0) }
        let task = enqueuePreparing { [weak self] in
            guard let self, !self.terminating, let current = self.thread(threadID), current.provider == .codex,
                  let captured, ProviderConfiguration(thread: current).matchesModelControlCapture(captured),
                  let actual = self.models(for: current).first(where: { $0.id == model.id }), actual == model else {
                throw CoincideError("Codex's speed choices changed. Refresh models and choose the current option.")
            }
            return .editThread(threadID, .codexServiceTier(model: actual, tier: tier, expected: captured))
        }
        Task { do { _ = try await task.value } catch { if !terminating { errorMessage = error.localizedDescription } } }
    }
    func resetCodexServiceTier(threadID: UUID, expected: ProviderConfiguration? = nil) { resetNativeModelOptions(.codex, threadID: threadID, expected: expected) }
    func resetClaudeModelOptions(threadID: UUID, expected: ProviderConfiguration? = nil) { resetNativeModelOptions(.claude, threadID: threadID, expected: expected) }
    private func resetNativeModelOptions(_ provider: ProviderKind, threadID: UUID, expected: ProviderConfiguration?) {
        let captured = expected ?? thread(threadID).map { ProviderConfiguration(thread: $0) }
        let task = enqueuePreparing { [weak self] in
            guard let self, !self.terminating, let current = self.thread(threadID), current.provider == provider,
                  let captured, ProviderConfiguration(thread: current).matchesModelControlCapture(captured) else { throw CancellationError() }
            return .editThread(threadID, .resetProviderModelOptions(expected: captured))
        }
        Task { do { _ = try await task.value } catch { if !terminating { errorMessage = error.localizedDescription } } }
    }
    func setModel(_ model: String, id: UUID) {
        cancelCodexModelDefaultsRead(id)
        if thread(id)?.provider == .claude {
            let task = enqueuePreparing { [weak self] in
                guard let self, !self.terminating, let current = self.thread(id), current.provider == .claude else { throw CancellationError() }
                if model.isEmpty { return .editThread(id, .claudeModel(nil)) }
                guard let row = self.models(for: current).first(where: { $0.id == model }) else { throw CoincideError("Refresh Claude models before choosing a model.") }
                return .editThread(id, .claudeModel(row))
            }
            Task { do { _ = try await task.value } catch { if !terminating { errorMessage = error.localizedDescription } } }
            return
        }
        if thread(id)?.provider == .antigravity {
            _ = enqueuePreparing { [weak self] in
                guard let self, !self.terminating, let current = self.thread(id), current.provider == .antigravity,
                      model.isEmpty || self.models(for: current).contains(where: { $0.id == model }) else {
                    throw WorkspaceCommandError("Refresh Antigravity models before choosing a model.")
                }
                return .editThread(id, .model(model))
            }
            return
        }
        if thread(id)?.provider == .muse {
            _ = enqueueMuseEdit(threadID: id) { [weak self] current in
                if model.isEmpty { return .museModel(nil) }
                guard let row = self?.models(for: current).first(where: { $0.id == model }) else { throw CoincideError("Refresh Muse models before choosing a model.") }
                return .museModel(row)
            }
            return
        }
        if thread(id)?.provider == .pi {
            _ = enqueuePiEdit(threadID: id) { [weak self] current in
                if model.isEmpty { return .piModel(nil) }
                guard let row = self?.models(for: current).first(where: { $0.id == model }) else { throw CoincideError("Refresh Pi models before choosing a model.") }
                return .piModel(row)
            }
            return
        }
        if let current = thread(id), current.provider == .opencode {
            _ = enqueueOpenCodeEdit(threadID: id) { [weak self] current in
                if model.isEmpty { return .openCodeModel(nil) }
                guard let advertised = self?.models(for: current).first(where: { $0.id == model }) else {
                    throw CoincideError("Refresh OpenCode models before choosing a model.")
                }
                return .openCodeModel(advertised)
            }
            return
        }
        if let current = thread(id), current.provider == .codex, let advertised = models(for: current).first(where: { $0.id == model }) {
            sendCommand(.editThread(id, .codexModel(advertised)))
        } else { sendCommand(.editThread(id, .model(model))) }
    }
    func setProvider(_ provider: ProviderKind, id: UUID) {
        let previousProvider = thread(id)?.provider
        guard provider != previousProvider else { return }
        if provider == .pi {
            guard let current = thread(id) else { return }
            do {
                let captured = try piRuntimeCapture(current.workspacePath, ProviderKind.pi.executable, UUID())
                cancelCodexModelDefaultsRead(id)
                sendCommand(.editThread(id, .piProvider(captured)))
            } catch { errorMessage = "Choose an available Pi runtime and storage namespace before sending a message." }
            return
        }
        if provider == .claude {
            guard let current = thread(id) else { return }
            do {
                let captured = try claudeRuntimeCapture(current.workspacePath)
                cancelCodexModelDefaultsRead(id)
                sendCommand(.editThread(id, .claudeProvider(captured)))
            } catch { errorMessage = "Install and sign in to Claude before sending a message." }
            return
        }
        if provider == .codex {
            cancelCodexModelDefaultsRead(id)
            sendCommand(.editThread(id, .codexProvider(codexRuntime.configuration)))
            return
        }
        cancelCodexModelDefaultsRead(id); sendCommand(.editThread(id, .provider(provider)))
        if provider == .antigravity {
            _ = enqueuePreparing { [weak self] in
                guard let self, !self.terminating, self.thread(id)?.provider == .antigravity else { throw CancellationError() }
                return .editThread(id, .antigravityConfiguration(self.antigravityAccount.configuration))
            }
        }
    }
    func setACPAgent(_ agent: ACPAgentConfiguration, id: UUID) {
        cancelCodexModelDefaultsRead(id); sendCommand(.editThread(id, .acpAgent(agent)))
    }
    @discardableResult func setOpenCodeVariant(_ variant: String?, model: ProviderModel, threadID: UUID) -> Task<Bool, Never> {
        enqueueOpenCodeEdit(threadID: threadID) { [weak self] current in
            guard current.model == model.id, let advertised = self?.models(for: current).first(where: { $0.id == model.id }) else {
                throw CoincideError("The selected OpenCode model changed. Refresh models and choose again.")
            }
            return .openCodeVariant(model: advertised, variant: variant)
        }
    }
    @discardableResult func setOpenCodeAgent(_ agent: String, threadID: UUID) -> Task<Bool, Never> {
        enqueueOpenCodeEdit(threadID: threadID) { [weak self] _ in
            guard self?.openCodeCatalogs[threadID]?.agents.contains(where: { $0.id == agent && !$0.hidden && $0.mode != .subagent }) == true else {
                throw CoincideError("This OpenCode agent is no longer available. Refresh agents and choose again.")
            }
            return .openCodeAgent(agent)
        }
    }
    func setOpenCodeGeneration(_ generation: OpenCodeGeneration, threadID: UUID) {
        _ = enqueueOpenCodeEdit(threadID: threadID) { _ in .openCodeGeneration(generation) }
    }
    @discardableResult func setMuseReasoning(_ effort: String?, model: ProviderModel, threadID: UUID) -> Task<Bool, Never> {
        enqueueMuseEdit(threadID: threadID) { [weak self] current in
            guard current.model == model.id, let row = self?.models(for: current).first(where: { $0.id == model.id }) else { throw CoincideError("The selected Muse model changed. Refresh models and choose again.") }
            return .museReasoning(model: row, effort: effort)
        }
    }
    private func enqueueMuseEdit(threadID: UUID, prepare: @escaping @MainActor (CodingThread) throws -> ThreadEdit) -> Task<Bool, Never> {
        guard !terminating, let captured = thread(threadID), captured.provider == .muse else { return Task { false } }
        let task = enqueuePreparing { [weak self] in
            guard let self, !self.terminating, let current = self.thread(threadID), current.provider == .muse,
                  current.projectID == captured.projectID, current.workspacePath == captured.workspacePath,
                  ProviderConfiguration(thread: current).museRuntimeBinding == ProviderConfiguration(thread: captured).museRuntimeBinding else { throw CancellationError() }
            return .editThread(threadID, try prepare(current))
        }
        return Task {
            do { _ = try await task.value; return true }
            catch { if !(error is CancellationError), !terminating { errorMessage = error.localizedDescription }; return false }
        }
    }
    @discardableResult func setPiThinking(_ level: String?, model: ProviderModel, threadID: UUID) -> Task<Bool, Never> {
        enqueuePiEdit(threadID: threadID) { [weak self] current in
            guard current.model == model.id, let row = self?.models(for: current).first(where: { $0.id == model.id }) else { throw CoincideError("The selected Pi model changed. Refresh models and choose again.") }
            return .piThinking(model: row, level: level)
        }
    }
    private func enqueuePiEdit(threadID: UUID, prepare: @escaping @MainActor (CodingThread) throws -> ThreadEdit) -> Task<Bool, Never> {
        guard !terminating, let captured = thread(threadID), captured.provider == .pi else { return Task { false } }
        let task = enqueuePreparing { [weak self] in
            guard let self, !self.terminating, let current = self.thread(threadID), current.provider == .pi,
                  current.projectID == captured.projectID, current.workspacePath == captured.workspacePath,
                  current.piConfiguration?.runtimeIdentity == captured.piConfiguration?.runtimeIdentity else { throw CancellationError() }
            return .editThread(threadID, try prepare(current))
        }
        return Task {
            do { _ = try await task.value; return true }
            catch { if !(error is CancellationError), !terminating { errorMessage = error.localizedDescription }; return false }
        }
    }
    func setGrokRuntimeMode(_ mode: GrokACPRuntimeMode, threadID: UUID) {
        guard let captured = thread(threadID), captured.provider == .acp, captured.acpAgent?.integration == .grok else { return }
        let task = enqueuePreparing { [weak self] in
            guard let self, let current = self.thread(threadID), current.projectID == captured.projectID,
                  current.workspacePath == captured.workspacePath, current.acpAgent == captured.acpAgent else { throw CancellationError() }
            return .editThread(threadID, .grokRuntimeMode(mode))
        }
        Task {
            do { _ = try await task.value }
            catch { if !(error is CancellationError), !terminating { errorMessage = error.localizedDescription } }
        }
    }
    private func enqueueOpenCodeEdit(threadID: UUID, prepare: @escaping @MainActor (CodingThread) throws -> ThreadEdit) -> Task<Bool, Never> {
        guard !terminating, let captured = thread(threadID), captured.provider == .opencode else { return Task { false } }
        let task = enqueuePreparing { [weak self] in
            guard let self, !self.terminating, let current = self.thread(threadID), current.provider == .opencode,
                  current.projectID == captured.projectID, current.workspacePath == captured.workspacePath,
                  current.openCodeConfiguration?.runtimeIdentity == captured.openCodeConfiguration?.runtimeIdentity else { throw CancellationError() }
            return .editThread(threadID, try prepare(current))
        }
        return Task {
            do { _ = try await task.value; return true }
            catch {
                if !(error is CancellationError), !terminating { errorMessage = error.localizedDescription }
                return false
            }
        }
    }
    func codexReasoningModel(threadID: UUID) -> ProviderModel? {
        guard let thread = thread(threadID), thread.provider == .codex else { return nil }
        return models(for: thread).first { $0.id == thread.model }
    }
    func setCodexReasoningEffort(_ effort: String?, model: ProviderModel, threadID: UUID) -> Task<Bool, Never> {
        guard !terminating, let thread = thread(threadID), thread.provider == .codex, thread.model == model.id else { return Task { false } }
        cancelCodexModelDefaultsRead(threadID)
        let task = enqueuePreparing { [weak self] in
            guard let self, !self.terminating, let current = self.thread(threadID), current.provider == .codex,
                  current.projectID == thread.projectID, current.workspacePath == thread.workspacePath,
                  current.model == model.id else { throw CancellationError() }
            guard let advertised = self.codexReasoningModel(threadID: threadID) else {
                throw CoincideError("This model's reasoning options changed. Refresh models and choose again.")
            }
            return .editThread(threadID, .codexReasoning(model: advertised, effort: effort))
        }
        return Task {
            do { _ = try await task.value; return true }
            catch {
                if !(error is CancellationError), !terminating { errorMessage = error.localizedDescription }
                return false
            }
        }
    }
    func isReadingCodexModelDefaults(_ threadID: UUID) -> Bool { codexModelDefaultsReads[threadID] != nil }
    private func cancelCodexModelDefaultsRead(_ threadID: UUID) {
        codexModelDefaultsReads.removeValue(forKey: threadID)?.task.cancel()
    }
    func useCodexDefaultModel(_ threadID: UUID) -> Task<Bool, Never> {
        guard !terminating, !codexRuntime.isApplying, let engine, let captured = thread(threadID), captured.provider == .codex,
              workspaceReady(for: captured), !actionsPreventPromptSteering(threadID: threadID) else { return Task { false } }
        cancelCodexModelDefaultsRead(threadID)
        let id = UUID()
        let task = Task { [weak self] in
            guard let self else { return false }
            defer { if self.codexModelDefaultsReads[threadID]?.id == id { self.codexModelDefaultsReads.removeValue(forKey: threadID) } }
            do {
                // Metadata I/O stays outside commandTail so Stop, approvals and
                // drafting remain responsive while the CLI reads its defaults.
                let selection = try await engine.reviewCodexDefaultModel(threadID: threadID)
                try Task.checkCancellation()
                guard self.codexModelDefaultsReads[threadID]?.id == id, !self.terminating else { return false }
                let commit = self.enqueue(.editThread(threadID, .codexDefaultModel(selection))) { [weak self] in
                    guard let self, !self.terminating, self.codexModelDefaultsReads[threadID]?.id == id,
                          let current = self.thread(threadID), current.projectID == captured.projectID,
                          current.workspacePath == captured.workspacePath, current.provider == .codex,
                          current.model == captured.model, current.reasoningEffort == captured.reasoningEffort,
                          ProviderConfiguration(thread: current).codexRuntimeBinding == ProviderConfiguration(thread: captured).codexRuntimeBinding,
                          current.codexReasoningPreferences == captured.codexReasoningPreferences,
                          current.codexModelSelectionSource == captured.codexModelSelectionSource,
                          !self.actionsPreventPromptSteering(threadID: threadID) else { throw CancellationError() }
                }
                _ = try await commit.value
                if !Task.isCancelled, !self.terminating, !self.codexRuntime.isApplying,
                   self.codexModelDefaultsReads[threadID]?.id == id,
                   let current = self.thread(threadID), current.provider == .codex,
                   current.projectID == captured.projectID, current.workspacePath == captured.workspacePath,
                   ProviderConfiguration(thread: current).codexRuntimeBinding == ProviderConfiguration(thread: captured).codexRuntimeBinding,
                   let advertised = selection.catalogModel {
                    var values = self.models(for: captured)
                    if let index = values.firstIndex(where: { $0.id == advertised.id }) { values[index] = advertised }
                    else { values.append(advertised) }
                    self.codexModels[threadID] = values
                }
                return true
            } catch {
                if !(error is CancellationError), !self.terminating, self.codexModelDefaultsReads[threadID]?.id == id {
                    self.errorMessage = error.localizedDescription
                }
                return false
            }
        }
        codexModelDefaultsReads[threadID] = .init(id: id, task: task)
        return task
    }
    func setAgentMode(_ mode: String?, id: UUID) { sendCommand(.editThread(id, .agentMode(mode))) }
    func setAgentConfig(_ optionID: String, value: String?, id: UUID) { sendCommand(.editThread(id, .agentConfig(id: optionID, value: value))) }
    func setAgentConfiguration(_ optionID: String, value: JSONValue?, id: UUID) { sendCommand(.editThread(id, .agentConfiguration(id: optionID, value: value))) }
    func resetAgentOptions(_ id: UUID) { sendCommand(.editThread(id, .resetAgentOptions)) }
    func setCheckpointPolicy(_ policy: RunCheckpointPolicy, id: UUID) {
        guard !terminating, thread(id) != nil else { return }
        sendCommand(.editThread(id, .checkpointPolicy(policy)))
    }
    func saveACPAgent(_ agent: ACPAgentConfiguration) async throws { _ = try await enqueue(.saveACPAgent(agent)).value }
    func removeACPAgent(_ id: UUID) { sendCommand(.removeACPAgent(id)) }
    func models(for provider: ProviderKind) -> [ProviderModel] {
        if provider == .codex, let selectedThread, selectedThread.provider == .codex { return models(for: selectedThread) }
        if provider == .claude, let selectedThread, selectedThread.provider == .claude,
           selectedThread.claudeRuntimeConfiguration != nil { return models(for: selectedThread) }
        if provider == .opencode || provider == .pi || provider == .muse || provider == .antigravity {
            guard let selectedThread, selectedThread.provider == provider else { return [] }
            return models(for: selectedThread)
        }
        return providerModels[provider] ?? []
    }
    func models(for thread: CodingThread) -> [ProviderModel] {
        if thread.provider == .claude, let runtime = thread.claudeRuntimeConfiguration {
            guard let catalog = claudeModels[thread.id], catalog.identity == runtime.runtimeIdentity else { return [] }
            return catalog.models
        }
        if thread.provider == .codex {
            if let models = codexModels[thread.id] { return models }
            return ProviderConfiguration(thread: thread).codexRuntimeBinding == CodexRuntimeConfiguration() && codexRuntime.configuration == .init() ? providerModels[.codex] ?? [] : []
        }
        if thread.provider == .pi { return piModels[thread.id] ?? [] }
        if thread.provider == .muse { return museModels[thread.id] ?? [] }
        if thread.provider == .antigravity { return antigravityModels[thread.id] ?? [] }
        if thread.provider == .opencode {
            guard let inventory = openCodeCatalogs[thread.id] else { return [] }
            return inventory.models.filter(\.enabled).map { descriptor in
                .init(id: descriptor.selection.catalogID, name: descriptor.name,
                      isDefault: inventory.defaults.contains(descriptor.selection),
                      openCodeSelection: descriptor.selection, openCodeVariants: descriptor.variants)
            }
        }
        guard thread.provider == .acp else { return models(for: thread.provider) }
        if let refreshed = acpModels[thread.id] { return refreshed }
        if let metadata = thread.providerMetadata { return ACPConfigurationOptions.models(metadata) }
        return []
    }
    func setDraft(_ text: String, id: UUID) {
        guard !terminating, thread(id) != nil else { return }
        draftOverrides[id] = text; pendingDrafts[id] = text
        draftSaveTask?.cancel()
        draftSaveTask = Task { [weak self] in
            do { try await Task.sleep(for: .milliseconds(350)) } catch { return }
            self?.flushDrafts()
        }
    }
    func insertWorkspaceReference(path: String, workspacePath: String, threadID: UUID) async {
        guard let thread = thread(threadID), Self.canonicalPath(thread.workspacePath) == Self.canonicalPath(workspacePath), canAccessWorkspaceFiles(workspacePath) else { return }
        do {
            let service = try fileService(path: workspacePath)
            _ = try WorkspaceFiles(root: URL(fileURLWithPath: workspacePath)).resolve(path)
            let directory = (path as NSString).deletingLastPathComponent
            let page = try await service.listEntries(directoryPath: directory)
            guard page.entries.contains(where: { $0.path == path }) else { throw CoincideError("This file or folder is no longer available. Search again before referencing it.") }
            try Task.checkCancellation()
            guard let current = self.thread(threadID), Self.canonicalPath(current.workspacePath) == Self.canonicalPath(workspacePath), canAccessWorkspaceFiles(workspacePath) else { return }
            let separator = current.draft.isEmpty || current.draft.last?.isWhitespace == true ? "" : " "
            setDraft(current.draft + separator + WorkspaceFileReference.markdown(path: path) + " ", id: threadID)
        } catch is CancellationError { }
        catch { if !terminating, self.thread(threadID) != nil { errorMessage = error.localizedDescription } }
    }
    private func flushDrafts() {
        // A later plain-text save must not land behind a successful recall and
        // overwrite its append. Recall releases and flushes that live overlay.
        let values = pendingDrafts.filter { historyRecallDraftOwners[$0.key] == nil }
        for id in values.keys { pendingDrafts.removeValue(forKey: id) }
        for (id, text) in values {
            guard thread(id) != nil else { continue }
            let task = enqueue(.editThread(id, .draft(text)))
            Task {
                do { _ = try await task.value; if draftOverrides[id].map({ $0.utf8.elementsEqual(text.utf8) }) == true { draftOverrides.removeValue(forKey: id) } }
                catch { if !terminating, thread(id) != nil { errorMessage = error.localizedDescription } }
            }
        }
    }
    func setPermission(_ mode: PermissionMode, id: UUID) { sendCommand(.editThread(id, .permission(mode))) }
    func togglePin(_ id: UUID) { if let value = thread(id) { sendCommand(.editThread(id, .pinned(!value.isPinned))) } }
    func toggleArchive(_ id: UUID) { if let value = thread(id) { sendCommand(.editThread(id, .archived(!value.isArchived))) } }
    func rename(_ id: UUID, title: String) { sendCommand(.editThread(id, .title(title))) }
    func isBusy(_ id: UUID) -> Bool { thread(id)?.isBusy == true }
    func isPreparingWorkspace(_ id: UUID) -> Bool { preparingWorkspaces.contains(id) }
    func isImportingAttachments(_ id: UUID) -> Bool { attachmentImportCounts[id, default: 0] > 0 || composerDraftTools.isWorking(id) }
    func chooseAttachments(threadID: UUID) {
        let panel = NSOpenPanel(); panel.canChooseDirectories = false; panel.canChooseFiles = true
        panel.allowsMultipleSelection = true; panel.prompt = "Attach"
        panel.begin { [weak self] response in
            guard response == .OK else { return }; self?.importAttachments(files: panel.urls, threadID: threadID)
        }
    }
    func importAttachments(files: [URL] = [], providers: [NSItemProvider] = [], threadID: UUID) {
        guard !terminating, engine != nil, thread(threadID) != nil else { return }
        guard files.count + providers.count <= AttachmentLimits.count else { errorMessage = "Attach up to 100 files per message."; return }
        composerDraftTools.importFiles(files, threadID: threadID)
        composerDraftTools.importProviders(providers, threadID: threadID)
    }
    private func legacyImportAttachments(files: [URL] = [], providers: [NSItemProvider] = [], threadID: UUID) {
        guard !terminating, let engine, thread(threadID) != nil else { return }
        guard files.count + providers.count <= AttachmentLimits.count else { errorMessage = "Attach up to 100 files per message."; return }
        let taskID = UUID()
        attachmentImportOwners[taskID] = threadID
        attachmentImportCounts[threadID, default: 0] += 1
        attachmentImportTasks[taskID] = Task {
            defer {
                let remaining = attachmentImportCounts[threadID, default: 1] - 1
                attachmentImportCounts[threadID] = remaining > 0 ? remaining : nil
                attachmentImportTasks.removeValue(forKey: taskID)
                attachmentImportOwners.removeValue(forKey: taskID)
            }
            var references: [ChatAttachment] = [], errors: [String] = []
            for file in files {
                do { try Task.checkCancellation(); references.append(try await engine.attachments.importFile(file)) }
                catch is CancellationError { return }
                catch { errors.append("\(file.lastPathComponent): \(error.localizedDescription)") }
            }
            for provider in providers {
                do {
                    try Task.checkCancellation()
                    if provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) {
                        let data = try await NativePasteData.load(provider, type: UTType.fileURL.identifier)
                        guard let url = URL(dataRepresentation: data, relativeTo: nil), url.isFileURL else { throw CoincideError("This is not a local file.") }
                        references.append(try await engine.attachments.importFile(url))
                    } else if let type = provider.registeredTypeIdentifiers.first(where: { UTType($0)?.conforms(to: .image) == true }) {
                        let data = try await NativePasteData.load(provider, type: type)
                        let suffix = UTType(type)?.preferredFilenameExtension ?? "png"
                        references.append(try await engine.attachments.importData(data, name: provider.suggestedName ?? "Pasted image.\(suffix)"))
                    }
                } catch is CancellationError { return }
                catch { errors.append(error.localizedDescription) }
            }
            guard !terminating, !Task.isCancelled, thread(threadID) != nil else { return }
            if !references.isEmpty {
                do { _ = try await enqueue(.addAttachments(threadID: threadID, attachments: references)).value }
                catch { errors.append(error.localizedDescription) }
            }
            if !errors.isEmpty, thread(threadID) != nil { errorMessage = errors.joined(separator: "\n") }
        }
    }
    func removeAttachment(_ attachmentID: UUID, threadID: UUID) { sendCommand(.removeAttachment(threadID: threadID, attachmentID: attachmentID)) }
    func attachmentData(_ attachment: ChatAttachment) async throws -> Data {
        guard let engine else { throw CoincideError("The workspace runtime is unavailable.") }
        return try await engine.attachments.data(for: attachment)
    }
    func openAttachment(_ attachment: ChatAttachment) async {
        guard let engine else { return }
        do {
            _ = try await engine.attachments.data(for: attachment)
            let url = try await engine.attachments.url(for: attachment)
            guard !terminating else { return }
            if !NSWorkspace.shared.open(url) { errorMessage = "No application could open this attachment." }
        } catch { errorMessage = error.localizedDescription }
    }
    func copyAttachmentImage(_ attachment: ChatAttachment) async {
        do {
            let data = try await attachmentData(attachment)
            guard !terminating, attachment.isImage, let image = NSImage(data: data) else { return }
            NSPasteboard.general.clearContents(); NSPasteboard.general.writeObjects([image])
        } catch { if !terminating { errorMessage = error.localizedDescription } }
    }
    func saveAttachment(_ attachment: ChatAttachment) {
        let panel = NSSavePanel()
        let base = (attachment.name as NSString).deletingPathExtension
        panel.nameFieldStringValue = attachment.fileExtension.isEmpty ? attachment.name : base + "." + attachment.fileExtension
        if let type = UTType(mimeType: attachment.mimeType) { panel.allowedContentTypes = [type] }
        panel.begin { [weak self] response in
            guard response == .OK, let url = panel.url, let self else { return }
            Task {
                do {
                    let bytes = try await self.attachmentData(attachment)
                    guard !self.terminating else { return }
                    let scoped = url.startAccessingSecurityScopedResource(); defer { if scoped { url.stopAccessingSecurityScopedResource() } }
                    try bytes.write(to: url, options: .atomic)
                } catch { if !self.terminating { self.errorMessage = error.localizedDescription } }
            }
        }
    }

    func submit(_ text: String, threadID id: UUID) -> Task<Bool, Never> {
        let prompt = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let thread = thread(id), (!prompt.isEmpty || !thread.draftAttachments.isEmpty),
              !preparingWorkspaces.contains(id), !isImportingAttachments(id), !composerDraftTools.blocksSubmission(id), !acceptingHistoryThreads.contains(id),
              !snapshot.isConversationHistoryLocked(threadID: id), !isCheckpointRestoreLocked(threadID: id),
              !claudeResumeSelectionNeedsInspection(threadID: id),
              !isPullRequestCreationLocked(threadID: id), !isPullRequestCheckoutLocked(threadID: id) else { return Task { false } }
        let capturedClaude: ClaudeRuntimeConfiguration?
        if thread.provider == .claude, thread.claudeRuntimeConfiguration == nil {
            do { capturedClaude = try claudeRuntimeCapture(thread.workspacePath) }
            catch { errorMessage = "Install and sign in to Claude before sending a message."; return Task { false } }
        } else { capturedClaude = nil }
        let capturedPi: PiRuntimeConfiguration?
        if thread.provider == .pi, thread.piConfiguration?.runtime == nil {
            guard let native = thread.piConfiguration else { return Task { false } }
            do { capturedPi = try piRuntimeCapture(thread.workspacePath, native.executable, native.instanceID) }
            catch { errorMessage = "Choose an available Pi runtime and storage namespace before sending a message."; return Task { false } }
        } else { capturedPi = nil }
        let executable: String
        if thread.provider == .claude { executable = (thread.claudeRuntimeConfiguration ?? capturedClaude)?.executable ?? thread.provider.executable }
        else if thread.provider == .pi { executable = (thread.piConfiguration?.runtime ?? capturedPi)?.executable ?? thread.piConfiguration?.executable ?? thread.provider.executable }
        else { executable = thread.provider == .acp ? thread.acpAgent?.executable ?? "" : thread.antigravityConfiguration?.executable ?? thread.museConfiguration?.executable ?? thread.openCodeConfiguration?.executable ?? thread.provider.executable }
        if thread.provider == .codex {
            do { _ = try codexRuntimeInstallation.resolve(configuration: thread.codexRuntimeConfiguration ?? .init()) }
            catch { errorMessage = error.localizedDescription; return Task { false } }
        } else if let native = thread.antigravityConfiguration {
            do { _ = try antigravityRuntimeInstallation.resolve(configuration: native) }
            catch { errorMessage = error.localizedDescription; return Task { false } }
        } else if executable.isEmpty || ProcessChannel.findExecutable(executable) == nil {
            errorMessage = "Install and sign in to \(thread.providerName) before sending a message."
            return Task { false }
        }
        pendingDrafts.removeValue(forKey: id)
        draftOverrides[id] = ""
        let command: WorkspaceCommand
        if let capturedClaude { command = .submitCapturedClaude(threadID: id, text: prompt, configuration: capturedClaude) }
        else if let capturedPi { command = .submitCapturedPi(threadID: id, text: prompt, configuration: capturedPi) }
        else { command = .submit(threadID: id, text: prompt) }
        let task = enqueue(command)
        return Task {
            do { _ = try await task.value; if draftOverrides[id] == "" { draftOverrides.removeValue(forKey: id) }; return true }
            catch {
                guard self.thread(id) != nil else { return false }
                if (draftOverrides[id] ?? "").isEmpty { setDraft(text, id: id) }
                errorMessage = error.localizedDescription; return false
            }
        }
    }
    func promptSteeringKey(threadID: UUID) -> NativePromptSteeringKey? {
        guard let thread = thread(threadID) else { return nil }
        return .init(runtimeID: thread.runtimeID, run: thread.activeRun, nativeThreadID: thread.providerThreadID,
            capabilityRevision: thread.steeringCapabilityRevision,
            state: thread.state, requests: thread.runtimeRequests, workspaceReady: workspaceReady(for: thread),
            historyLocked: snapshot.isConversationHistoryLocked(threadID: threadID),
            accepting: acceptingPromptSteering.contains(threadID),
            operations: (snapshot.promptSteerings ?? []).filter { $0.threadID == threadID }.map {
                .init(id: $0.id, phase: $0.phase.rawValue, acknowledgedAt: $0.acknowledgedAt)
            })
    }
    func refreshPromptSteeringAvailability(threadID: UUID) async {
        guard !terminating, let engine, let key = promptSteeringKey(threadID: threadID) else { return }
        let value = await engine.promptSteeringAvailability(threadID: threadID)
        guard !terminating, !Task.isCancelled, promptSteeringKey(threadID: threadID) == key else { return }
        promptSteeringAvailability[threadID] = (key, value)
    }
    func steeringAvailability(threadID: UUID) -> PromptSteeringAvailability? {
        guard let cached = promptSteeringAvailability[threadID], cached.0 == promptSteeringKey(threadID: threadID),
              !acceptingPromptSteering.contains(threadID) else { return nil }
        return cached.1
    }
    func isAcceptingPromptSteering(_ threadID: UUID) -> Bool { acceptingPromptSteering.contains(threadID) }
    func steeringExplanation(threadID: UUID) -> String? {
        guard let thread = thread(threadID), thread.isBusy else { return nil }
        guard let availability = steeringAvailability(threadID: threadID), availability.canSteer,
              let configuration = availability.configuration else {
            return steeringAvailability(threadID: threadID)?.unavailableReason
                ?? String(localized: "Queue this message while the current turn becomes available for steering.")
        }
        let name = configuration.provider == .acp ? configuration.acpAgent?.name ?? configuration.provider.name : configuration.provider.name
        let model = configuration.model.isEmpty ? String(localized: "its current model") : configuration.model
        if availability.interruptsTools {
            return String(localized: "Steer sends to \(name) with \(model) and interrupts its current tools. Future-turn settings stay separate.")
        }
        return String(localized: "Steer sends to \(name) with \(model), using the running turn's settings.")
    }
    func canSteerQueued(_ queued: QueuedTurn, threadID: UUID) -> Bool {
        guard let availability = steeringAvailability(threadID: threadID), availability.canSteer,
              var running = availability.configuration else { return false }
        var captured = queued.configuration
        running.nativeThreadID = nil; captured.nativeThreadID = nil
        return running == captured
    }
    func steer(_ text: String, threadID id: UUID, queuedID: UUID? = nil) -> Task<Bool, Never> {
        let prompt = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !terminating, let engine, let thread = thread(id), !isImportingAttachments(id), queuedID != nil || !composerDraftTools.blocksSubmission(id),
              !isPreparingWorkspace(id), !actionsPreventPromptSteering(threadID: id),
              let availability = steeringAvailability(threadID: id), availability.canSteer,
              let runID = availability.runID, thread.activeRun?.id == runID,
              queuedID != nil || !prompt.isEmpty || !thread.draftAttachments.isEmpty,
              !acceptingPromptSteering.contains(id) else { return Task { false } }
        if let queuedID {
            guard let queued = thread.queuedTurns.first(where: { $0.id == queuedID }), canSteerQueued(queued, threadID: id) else {
                return Task { false }
            }
        } else {
            pendingDrafts.removeValue(forKey: id)
            draftOverrides[id] = ""
        }
        acceptingPromptSteering.insert(id)
        let previous = commandTail
        let task = Task {
            await previous?.value
            guard !self.terminating, !self.actionsPreventPromptSteering(threadID: id),
                  self.thread(id)?.activeRun?.id == runID else { throw CancellationError() }
            if queuedID == nil {
                // The editor can be ahead of its debounced save. Persist this
                // captured input before acceptance so clearing it cannot expose
                // an older saved draft. Later edits keep their live overlay and
                // their saves remain ordered behind this command.
                let draftReceipt = try await engine.dispatch(.editThread(id, .draft(text)))
                if let rejection = draftReceipt.rejection { throw WorkspaceCommandError(rejection) }
            }
            let receipt = try await engine.steerPrompt(threadID: id, text: prompt, expectedRunID: runID, queuedID: queuedID)
            self.apply(await engine.current())
            if let rejection = receipt.rejection { throw WorkspaceCommandError(rejection) }
            return receipt
        }
        commandTail = Task { _ = await task.result }
        return Task {
            defer { acceptingPromptSteering.remove(id) }
            do {
                _ = try await task.value
                if queuedID == nil, draftOverrides[id] == "" { draftOverrides.removeValue(forKey: id) }
                return true
            } catch {
                apply(await engine.current())
                if queuedID == nil, self.thread(id) != nil, (draftOverrides[id] ?? "").isEmpty { setDraft(text, id: id) }
                if !(error is CancellationError), !terminating { errorMessage = error.localizedDescription }
                return false
            }
        }
    }
    private func actionsPreventPromptSteering(threadID: UUID) -> Bool {
        snapshot.isConversationHistoryLocked(threadID: threadID) || isCheckpointRestoreLocked(threadID: threadID) ||
            isPullRequestCreationLocked(threadID: threadID) || isPullRequestCheckoutLocked(threadID: threadID)
    }
    func steerQueued(_ queuedID: UUID, threadID: UUID) -> Task<Bool, Never> {
        steer("", threadID: threadID, queuedID: queuedID)
    }
    func acknowledgePromptSteering(_ operationID: UUID) async {
        let task = enqueue(.acknowledgePromptSteering(operationID: operationID))
        do { _ = try await task.value }
        catch { if !terminating { errorMessage = error.localizedDescription } }
    }
    func interrupt(_ id: UUID) async {
        let task = enqueue(.interrupt(threadID: id))
        do { _ = try await task.value } catch { errorMessage = error.localizedDescription }
    }
    func respond(_ request: ApprovalRequest, threadID id: UUID, allow: Bool) async {
        let task = enqueue(.respond(threadID: id, requestID: request.id, response: .decision(allow)))
        do { _ = try await task.value } catch { errorMessage = error.localizedDescription }
    }
    func answer(_ request: ApprovalRequest, threadID id: UUID, answers: [String: String]) async {
        let task = enqueue(.respond(threadID: id, requestID: request.id, response: .answers(answers)))
        do { _ = try await task.value } catch { errorMessage = error.localizedDescription }
    }
    func selectAnswers(_ request: ApprovalRequest, threadID id: UUID, selections: [String: [String]]) async {
        let task = enqueue(.respond(threadID: id, requestID: request.id, response: .selections(selections)))
        do { _ = try await task.value } catch { errorMessage = error.localizedDescription }
    }
    func selectAnswers(_ request: ApprovalRequest, threadID id: UUID, selections: [String: [String]], notes: [String: String]) async {
        let task = enqueue(.respond(threadID: id, requestID: request.id, response: .selectionsWithNotes(selections: selections, notes: notes)))
        do { _ = try await task.value } catch { errorMessage = error.localizedDescription }
    }
    func choose(_ request: ApprovalRequest, threadID id: UUID, optionID: String) async {
        let task = enqueue(.respond(threadID: id, requestID: request.id, response: .option(optionID)))
        do { _ = try await task.value } catch { errorMessage = error.localizedDescription }
    }
    func removeQueued(_ queuedID: UUID, threadID: UUID) { sendCommand(.removeQueued(threadID: threadID, queuedID: queuedID)) }
    func editQueued(_ queuedID: UUID, threadID: UUID) {
        flushDrafts(); sendCommand(.editQueued(threadID: threadID, queuedID: queuedID))
    }
    func resumeQueue(_ threadID: UUID) { sendCommand(.resumeQueue(threadID: threadID)) }
    func openFile(_ url: URL, line: Int?, workspacePath: String) {
        let normalizedPath = Self.canonicalPath(workspacePath)
        let threads = snapshot.threads.filter { Self.canonicalPath($0.workspacePath) == normalizedPath }
        let projects = snapshot.projects.filter { Self.canonicalPath($0.path) == normalizedPath }
        guard !terminating, canEditWorkspace(workspacePath), !threads.isEmpty || !projects.isEmpty else { return }
        if threads.contains(where: { !workspaceReady(for: $0) }) || projects.contains(where: { $0.clone.map { !$0.isReady } ?? false }) {
            errorMessage = "Wait for the repository to finish cloning before opening its files."; return
        }
        let root = URL(fileURLWithPath: workspacePath).standardizedFileURL.resolvingSymlinksInPath()
        guard url.path.hasPrefix(root.path + "/") else { errorMessage = "This file is outside the workspace."; return }
        let relative = String(url.path.dropFirst(root.path.count + 1))
        do { _ = try WorkspaceFiles(root: root).resolve(relative) }
        catch { errorMessage = error.localizedDescription; return }
        fileNavigation = .init(workspacePath: workspacePath, path: relative, line: line); inspectorVisible = true
    }
    func refreshModels(provider: ProviderKind? = nil) async {
        guard !isRefreshingModels, let engine else { return }; isRefreshingModels = true
        defer { isRefreshingModels = false }
        do {
            let kind = provider ?? selectedThread?.provider ?? .codex
            if kind == .codex {
                guard !codexRuntime.isApplying else { return }
                let captured = selectedThread.flatMap { $0.provider == .codex ? $0 : nil }
                let configuration = captured?.codexRuntimeConfiguration ?? (captured == nil ? codexRuntime.configuration : .init())
                guard configuration.authenticationMode != .ownedChatGPT || !codexAuthenticationChanges.contains(configuration.instanceID) else { return }
                let scope = codexMetadataScope, id = UUID()
                let task = Task {
                    if let captured { return try await engine.models(thread: captured) }
                    return try await engine.models(provider: .codex, codexRuntimeConfiguration: configuration)
                }
                codexCatalogReads[id] = task
                defer { codexCatalogReads.removeValue(forKey: id) }
                let models = try await withTaskCancellationHandler { try await task.value } onCancel: { task.cancel() }
                try Task.checkCancellation()
                guard !terminating, codexMetadataScope == scope else { return }
                if let captured {
                    guard let current = thread(captured.id), current.provider == .codex,
                          current.projectID == captured.projectID, current.workspacePath == captured.workspacePath,
                          ProviderConfiguration(thread: current).codexRuntimeBinding == ProviderConfiguration(thread: captured).codexRuntimeBinding else { return }
                    codexModels[captured.id] = models
                } else if codexRuntime.configuration == configuration { providerModels[.codex] = models }
            } else if kind == .claude, let captured = selectedThread,
                      captured.provider == .claude, let runtime = captured.claudeRuntimeConfiguration {
                let models = try await engine.models(thread: captured)
                guard !terminating, let current = thread(captured.id), current.provider == .claude,
                      current.projectID == captured.projectID, current.workspacePath == captured.workspacePath,
                      current.claudeRuntimeConfiguration?.runtimeIdentity == runtime.runtimeIdentity else { return }
                claudeModels[captured.id] = (runtime.runtimeIdentity, models)
            } else if kind == .opencode {
                guard let thread = selectedThread, thread.provider == .opencode else {
                    throw CoincideError("Choose OpenCode in a conversation before refreshing its workspace models.")
                }
                let catalog = try await engine.openCodeInventory(thread: thread)
                guard let current = self.thread(thread.id), current.provider == .opencode,
                      current.projectID == thread.projectID, current.workspacePath == thread.workspacePath,
                      current.openCodeConfiguration?.runtimeIdentity == thread.openCodeConfiguration?.runtimeIdentity else { return }
                openCodeCatalogs[thread.id] = catalog
            } else if kind == .antigravity {
                guard let thread = selectedThread, thread.provider == .antigravity else { throw CoincideError("Choose Antigravity in a conversation before refreshing its models.") }
                let models = try await engine.models(thread: thread)
                guard let current = self.thread(thread.id), current.projectID == thread.projectID, current.provider == .antigravity,
                      current.workspacePath == thread.workspacePath,
                      ProviderConfiguration(thread: current).antigravityRuntimeBinding == ProviderConfiguration(thread: thread).antigravityRuntimeBinding else { return }
                antigravityModels[thread.id] = models
            } else if kind == .muse {
                guard let thread = selectedThread, thread.provider == .muse else { throw CoincideError("Choose Muse in a conversation before refreshing its models.") }
                let models = try await engine.models(thread: thread)
                guard let current = self.thread(thread.id), current.projectID == thread.projectID, current.provider == .muse,
                      current.workspacePath == thread.workspacePath,
                      ProviderConfiguration(thread: current).museRuntimeBinding == ProviderConfiguration(thread: thread).museRuntimeBinding else { return }
                museModels[thread.id] = models
            } else if kind == .pi {
                guard var thread = selectedThread, thread.provider == .pi, let native = thread.piConfiguration else { throw CoincideError("Choose Pi in a conversation before refreshing its models.") }
                if native.runtime == nil {
                    let captured = try piRuntimeCapture(thread.workspacePath, native.executable, native.instanceID)
                    _ = try await enqueue(.editThread(thread.id, .piRuntimeConfiguration(captured))).value
                    guard let current = self.thread(thread.id), current.provider == .pi,
                          current.projectID == thread.projectID, current.workspacePath == thread.workspacePath,
                          current.piConfiguration?.runtime == captured else { throw CancellationError() }
                    thread = current
                }
                let models = try await engine.models(thread: thread)
                guard let current = self.thread(thread.id), current.projectID == thread.projectID, current.provider == .pi,
                      current.workspacePath == thread.workspacePath,
                      ProviderConfiguration(thread: current).piRuntimeBinding == ProviderConfiguration(thread: thread).piRuntimeBinding else { return }
                piModels[thread.id] = models
            } else if kind == .acp, let thread = selectedThread, thread.acpAgent != nil {
                let models = try await engine.models(thread: thread)
                guard let current = self.thread(thread.id), current.provider == thread.provider,
                      current.acpAgent == thread.acpAgent, current.workspacePath == thread.workspacePath else { return }
                acpModels[thread.id] = models
            } else { providerModels[kind] = try await engine.models(provider: kind) }
        } catch is CancellationError { }
        catch { if !terminating { errorMessage = error.localizedDescription } }
    }
    func skillsScope(threadID: UUID) -> ProviderSkillsStore.Scope? {
        guard !terminating, let thread = thread(threadID), [.codex, .pi, .opencode, .claude].contains(thread.provider),
              workspaceReady(for: thread), snapshot.providerReady(for: thread) else { return nil }
        let scope = ProviderSkillsStore.Scope(thread)
        if thread.provider == .codex {
            guard !codexRuntime.isApplying,
                  scope.configuration.authenticationMode != .ownedChatGPT || !codexAuthenticationChanges.contains(scope.configuration.instanceID) else { return nil }
        } else if thread.provider == .pi {
            guard scope.piConfiguration?.runtime != nil else { return nil }
        } else if thread.provider == .claude {
            guard scope.claudeConfiguration != nil else { return nil }
        } else if scope.openCodeConfiguration == nil { return nil }
        return scope
    }
    func inspectDelegatedTask(parentThreadID: UUID, taskID: UUID) async throws -> DelegatedTaskStatusSnapshot {
        guard !terminating, let engine else { throw CancellationError() }
        return try await engine.delegatedTaskStatus(parentThreadID: parentThreadID, taskID: taskID, acknowledge: false)
    }
    func cancelDelegatedTask(parentThreadID: UUID, taskID: UUID, commandID: UUID) async throws -> WorkspaceCommandReceipt {
        guard !terminating, let engine else { throw CancellationError() }
        return try await engine.cancelDelegatedTask(parentThreadID: parentThreadID, taskID: taskID,
            reason: "Cancelled from the task panel", commandID: commandID)
    }
    func skillsStore(threadID: UUID) -> ProviderSkillsStore? {
        guard let scope = skillsScope(threadID: threadID), let thread = thread(threadID), let engine else { return nil }
        if let cached = providerSkills[threadID], cached.scope == scope, !cached.isClosed { return cached }
        _ = retireSkills { $0.threadID == threadID }
        let id = UUID()
        let isCurrent: @MainActor () -> Bool = { [weak self] in
            guard let self else { return false }
            return self.providerSkills[threadID]?.id == id && self.skillsScope(threadID: threadID) == scope
        }
        let model: ProviderSkillsStore
        if thread.provider == .codex {
            model = .init(id: id, scope: scope, read: { forceReload in
                try await engine.skills(thread: thread, forceReload: forceReload)
            }, isCurrent: isCurrent)
        } else if thread.provider == .claude, let configuration = scope.claudeSkills {
            model = .init(id: id, scope: scope, skillRead: { _ in
                let task = Task.detached { try ClaudeSkillService.discover(configuration: configuration) }
                return try await withTaskCancellationHandler { try await task.value } onCancel: { task.cancel() }
            }, commandRead: { forceReload in try await engine.commands(thread: thread, forceReload: forceReload) }, isCurrent: isCurrent)
        } else {
            model = .init(id: id, scope: scope, commandRead: { forceReload in
                try await engine.commands(thread: thread, forceReload: forceReload)
            }, isCurrent: isCurrent)
        }
        providerSkills[threadID] = model; return model
    }
    /// Cancel synchronously so no old result can publish, then retain every
    /// drain until callers have joined the exact metadata lifecycle.
    private func retireSkills(where predicate: (ProviderSkillsStore.Scope) -> Bool = { _ in true }) -> [Task<Void, Never>] {
        for (threadID, model) in providerSkills.filter({ predicate($0.value.scope) }) {
            model.cancel(); providerSkills.removeValue(forKey: threadID)
            let id = model.id
            let task = Task { [weak self] in
                await model.shutdown(); self?.providerSkillsDrains.removeValue(forKey: id)
            }
            providerSkillsDrains[id] = (model.scope, task)
        }
        // Previously retired readers may still be draining after a scope
        // change. Joining all retained drains also covers that window.
        return providerSkillsDrains.values.filter { predicate($0.scope) }.map(\.task)
    }
    func refreshCodexAccount() async {
        guard !terminating, !codexRuntime.isApplying, codexRuntime.configuration.authenticationMode == .cliDefault, let engine else { return }
        let configuration = codexRuntime.configuration
        await codexAccount.refresh { try await engine.codexAccountSnapshot(configuration: configuration) }
    }
    func refreshACPConnection(agent: ACPAgentConfiguration) async {
        guard !terminating, let engine, snapshot.acpAgents.contains(agent) else { return }
        acpConnections.invalidate(validAgents: snapshot.acpAgents)
        await acpConnections.refresh(agent: agent) { try await engine.acpConnectionInfo(agent: agent) }
    }
    /// Completed worktree assignments share the UI command order with confirmations and drafts.
    func setWorkspacePath(_ path: String, threadID: UUID) -> Task<WorkspaceCommandReceipt, any Error> {
        enqueue(.editThread(threadID, .workspacePath(path)))
    }
    func createWorktree(for id: UUID, branch: String) async {
        await prepareWorktree(for: id, selection: .createBranch(name: branch, baseRef: "HEAD"))
    }
    func prepareWorktree(for id: UUID, selection: GitWorktreeSelection, submodules: ProjectWorktreeSubmoduleMode = .none,
                         reviewSetup: Bool = false) async {
        guard let thread = thread(id) else { return }
        guard !thread.isSettled else { errorMessage = "Resume this conversation before choosing another worktree."; return }
        guard thread.messages.isEmpty, !thread.isBusy, thread.queuedTurns.isEmpty else {
            errorMessage = "Choose the worktree before sending the first message."; return
        }
        guard snapshot.projects.first(where: { $0.id == thread.projectID })?.clone?.isReady ?? true else {
            errorMessage = "Wait for cloning to finish before choosing a worktree."; return
        }
        guard thread.workspacePreparation?.isRunning != true else { return }
        await performWorktreeCommand(for: id, changesWorkspace: true) { engine in
            try await engine.beginWorktreePreparation(threadID: id, selection: selection, submodules: submodules, reviewSetup: reviewSetup)
        }
    }
    func cancelWorktreePreparation(_ id: UUID) {
        Task { await performWorktreeCommand(for: id) { try await $0.cancelWorktreePreparation(id) } }
    }
    func retryWorktreePreparation(_ id: UUID) {
        Task { await performWorktreeCommand(for: id) { try await $0.retryWorktreePreparation(id) } }
    }
    func approveProjectScript(threadID: UUID, runID: UUID, expectedPlan: ProjectScriptExecutionPlan) async throws {
        try await performProjectScriptCommand(.approveProjectScript(threadID: threadID, runID: runID, expectedPlan: expectedPlan),
                                             threadID: threadID, runID: runID)
    }
    func stopProjectScript(threadID: UUID, runID: UUID) async throws {
        try await performProjectScriptCommand(.stopProjectScript(threadID: threadID, runID: runID), threadID: threadID, runID: runID)
    }
    func skipProjectScript(threadID: UUID, runID: UUID) async throws {
        try await performProjectScriptCommand(.skipProjectScript(threadID: threadID, runID: runID), threadID: threadID, runID: runID)
    }
    func retryProjectScript(threadID: UUID, runID: UUID) async throws {
        try await performProjectScriptCommand(.retryProjectScript(threadID: threadID, runID: runID), threadID: threadID, runID: runID)
    }
    func projectScriptOutput(threadID: UUID, runID: UUID) async throws -> AsyncStream<ProjectScriptOutputSnapshot> {
        guard !terminating, let engine, projectScriptRun(threadID: threadID, runID: runID) != nil else { throw CancellationError() }
        return try await engine.projectScriptOutput(threadID: threadID, runID: runID)
    }
    func projectScriptRun(threadID: UUID, runID: UUID) -> ThreadProjectScriptRun? {
        thread(threadID)?.projectScript(runID: runID)
    }
    private func projectScriptOwner(_ thread: CodingThread, runID: UUID) -> ProjectScriptOwner? {
        if let preparation = thread.workspacePreparation, preparation.setup?.id == runID { return .setup(attemptID: preparation.id) }
        if let settlement = thread.settlement, settlement.script?.id == runID { return .settlement(generationID: settlement.id) }
        return nil
    }
    private func performProjectScriptCommand(_ command: WorkspaceCommand, threadID: UUID, runID: UUID) async throws {
        guard !terminating, let captured = thread(threadID), let owner = projectScriptOwner(captured, runID: runID) else { throw CancellationError() }
        flushDrafts()
        let task = enqueue(command) { [weak self] in
            guard let self, !self.terminating, let current = self.thread(threadID),
                  current.projectID == captured.projectID, current.workspacePath == captured.workspacePath,
                  self.projectScriptOwner(current, runID: runID) == owner,
                  self.canEditWorkspace(current.workspacePath) else { throw CancellationError() }
        }
        _ = try await task.value
    }
    func isRespondingToPostRunCheckpoint(_ attemptID: UUID) -> Bool {
        respondingToPostRunCheckpoints.contains(attemptID)
    }
    func retryPostRunCheckpoint(threadID: UUID, runID: UUID, expectedAttemptID: UUID) async throws {
        try await performPostRunCheckpointCommand(.retryPostRunCheckpoint(threadID: threadID, runID: runID,
                                                                        expectedAttemptID: expectedAttemptID),
                                                threadID: threadID, runID: runID, attemptID: expectedAttemptID, retry: true)
    }
    func continueAfterPostRunCheckpoint(threadID: UUID, runID: UUID, expectedAttemptID: UUID) async throws {
        try await performPostRunCheckpointCommand(.continueAfterPostRunCheckpoint(threadID: threadID, runID: runID,
                                                                                 expectedAttemptID: expectedAttemptID),
                                                threadID: threadID, runID: runID, attemptID: expectedAttemptID, retry: false)
    }
    private func performPostRunCheckpointCommand(_ command: WorkspaceCommand, threadID: UUID, runID: UUID,
                                                 attemptID: UUID, retry: Bool) async throws {
        guard !terminating, let captured = thread(threadID), !captured.isArchived,
              let held = captured.heldPostRunCheckpoint, held.runID == runID, held.attempt.id == attemptID,
              retry ? held.attempt.canRetryPostRun : held.attempt.canContinuePostRun,
              canEditWorkspace(captured.workspacePath), respondingToPostRunCheckpoints.insert(attemptID).inserted else {
            throw CancellationError()
        }
        defer { respondingToPostRunCheckpoints.remove(attemptID) }
        flushDrafts()
        let task = enqueue(command) { [weak self] in
            guard let self, !self.terminating, let current = self.thread(threadID), !current.isArchived,
                  current.projectID == captured.projectID, current.workspacePath == captured.workspacePath,
                  let held = current.heldPostRunCheckpoint, held.runID == runID, held.attempt.id == attemptID,
                  retry ? held.attempt.canRetryPostRun : held.attempt.canContinuePostRun,
                  self.canEditWorkspace(current.workspacePath) else { throw CancellationError() }
        }
        let receipt = try await task.value
        if let rejection = receipt.rejection { throw CoincideError(rejection) }
    }
    func runCheckpointDiff(threadID: UUID, runID: UUID, maxBytes: Int = 262_144) async throws -> GitCheckpointDiff {
        guard !terminating, let engine, let captured = thread(threadID), canEditWorkspace(captured.workspacePath),
              let checkpoints = captured.runHistory?.first(where: { $0.id == runID })?.checkpoints,
              checkpoints.baseline.phase == .ready, checkpoints.baseline.receipt != nil,
              checkpoints.postRun?.phase == .ready, checkpoints.postRun?.receipt != nil else { throw CancellationError() }
        let result = try await engine.runCheckpointDiff(threadID: threadID, runID: runID,
                                                       maxBytes: min(max(maxBytes, 1), 262_144))
        try Task.checkCancellation()
        guard !terminating, let current = thread(threadID), current.projectID == captured.projectID,
              current.workspacePath == captured.workspacePath, canEditWorkspace(current.workspacePath),
              let latest = current.runHistory?.first(where: { $0.id == runID })?.checkpoints,
              latest.baseline.receipt == checkpoints.baseline.receipt,
              latest.postRun?.receipt == checkpoints.postRun?.receipt else { throw CancellationError() }
        return result
    }
    func checkpointRestoreOperations(threadID: UUID) -> [RunCheckpointRestoreOperation] {
        Array((snapshot.checkpointRestoreOperations ?? []).filter { $0.review.threadID == threadID }.reversed())
    }
    func isCheckpointRestoreLocked(threadID: UUID) -> Bool {
        snapshot.isCheckpointRestoreLocked(threadID: threadID) || thread(threadID).map { thread in
            checkpointRestoreLocks.values.contains { Self.pathsOverlap(thread.workspacePath, $0) }
        } == true
    }
    func isPullRequestCreationLocked(threadID: UUID) -> Bool {
        if snapshot.isPullRequestCreationLocked(threadID: threadID) { return true }
        guard let thread = thread(threadID) else { return false }
        return pullRequestStores.contains { path, model in
            model.isAccepting && model.acceptingCheckoutID == nil && (pullRequestProjectID(path: path) == thread.projectID ||
                model.mutationPaths.contains { Self.pathsOverlap(thread.workspacePath, $0) })
        }
    }
    func isPullRequestCheckoutLocked(threadID: UUID) -> Bool {
        if snapshot.isPullRequestCheckoutLocked(threadID: threadID) { return true }
        guard let thread = thread(threadID) else { return false }
        let livePaths = thread.pullRequestCheckoutWorkspacePaths
        func overlaps(_ path: String) -> Bool { livePaths.contains { Self.pathsOverlap($0, path) } }
        return pullRequestCheckoutLocks.values.contains { $0.contains(where: overlaps) } ||
            pullRequestStores.values.contains { model in
                model.acceptingCheckoutID != nil && model.mutationPaths.contains(where: overlaps)
            }
    }
    func checkpointRestoreUnavailableReason(threadID: UUID, runID: UUID, stage: RunCheckpointStage, expectedAttemptID: UUID) -> String? {
        if let reason = snapshot.checkpointRestoreUnavailableReason(threadID: threadID, runID: runID, stage: stage, expectedAttemptID: expectedAttemptID) { return reason }
        guard let thread = thread(threadID), let attempt = thread.runCheckpoint(runID: runID, stage: stage, expectedAttemptID: expectedAttemptID),
              let path = attempt.receipt?.plan.repositoryPath, canEditWorkspace(path) else {
            return String(localized: "Finish the current workspace transition before restoring files.")
        }
        return checkpointRestoreActivityReason(path: path)
    }
    private func checkpointRestoreActivityReason(path: String) -> String? {
        if dirtyEditors.values.contains(where: { Self.pathsOverlap(path, $0) }) ||
            fileBrowsers.contains(where: { Self.pathsOverlap(path, $0.key) && $0.value.isDirty }) {
            return String(localized: "Save or discard unsaved editor changes in every window before restoring files.")
        }
        if fileBrowsers.contains(where: { Self.pathsOverlap(path, $0.key) && $0.value.isSaving }) {
            return String(localized: "Wait for file saves to finish before restoring files.")
        }
        if gitInspectors.contains(where: { Self.pathsOverlap(path, $0.key) && $0.value.operationName != nil }) {
            return String(localized: "Wait for source control operations to finish before restoring files.")
        }
        if pullRequestStores.values.contains(where: { $0.isMutating && $0.mutationPaths.contains { Self.pathsOverlap(path, $0) } }) {
            return String(localized: "Wait for the pull request operation to finish before restoring files.")
        }
        if workspaceTerminalSessions.contains(where: { session in
            guard Self.pathsOverlap(path, session.directory) else { return false }
            switch session.lifecycle { case .running, .closing: return true; case .exited, .failed: return false }
        }) {
            return String(localized: "Close terminals and running project scripts using these files in every window before restoring files.")
        }
        return nil
    }
    func reviewCheckpointRestore(threadID: UUID, runID: UUID, stage: RunCheckpointStage, expectedAttemptID: UUID) async throws -> RunCheckpointRestoreReview {
        guard !terminating, let engine,
              checkpointRestoreUnavailableReason(threadID: threadID, runID: runID, stage: stage, expectedAttemptID: expectedAttemptID) == nil else { throw CancellationError() }
        let requestID = UUID()
        let task = Task { try await engine.reviewCheckpointRestore(threadID: threadID, runID: runID, stage: stage, expectedAttemptID: expectedAttemptID) }
        checkpointRestoreReads[requestID] = .init(threadID: threadID, task: task)
        defer { checkpointRestoreReads.removeValue(forKey: requestID) }
        let review = try await withTaskCancellationHandler { try await task.value } onCancel: { task.cancel() }
        guard !Task.isCancelled, !terminating,
              checkpointRestoreUnavailableReason(threadID: threadID, runID: runID, stage: stage, expectedAttemptID: expectedAttemptID) == nil,
              checkpointRestoreActivityReason(path: review.gitReview.currentPlan.repositoryPath) == nil else {
            await engine.discardCheckpointRestoreReview(reviewID: review.id)
            throw CancellationError()
        }
        return review
    }
    func discardCheckpointRestoreReview(_ id: UUID) {
        guard let engine else { return }
        Task { await engine.discardCheckpointRestoreReview(reviewID: id) }
    }
    func beginCheckpointRestore(_ review: RunCheckpointRestoreReview) async throws {
        guard !terminating, let engine,
              checkpointRestoreUnavailableReason(threadID: review.threadID, runID: review.runID, stage: review.stage, expectedAttemptID: review.attemptID) == nil,
              acceptingCheckpointRestores.insert(review.id).inserted else { throw CancellationError() }
        let path = Self.canonicalPath(review.gitReview.currentPlan.repositoryPath)
        checkpointRestoreLocks[review.id] = path
        suspendCheckpointCaches(path: path)
        flushDrafts()
        let previous = commandTail
        let task = Task {
            await previous?.value
            guard !self.terminating, self.snapshot.canReviewCheckpointRestore(threadID: review.threadID),
                  self.checkpointRestoreActivityReason(path: path) == nil,
                  !self.checkpointRestoreLocks.contains(where: { $0.key != review.id && Self.pathsOverlap(path, $0.value) }),
                  !self.removalEditorLocks.values.contains(where: { $0.contains(where: { Self.pathsOverlap(path, $0) }) }),
                  !self.workspaceTransitionLocks.values.contains(where: { $0.contains(where: { Self.pathsOverlap(path, $0) }) }) else { throw CancellationError() }
            let receipt = try await engine.beginCheckpointRestore(review)
            self.apply(await engine.current())
            if let rejection = receipt.rejection { throw CoincideError(rejection) }
        }
        commandTail = Task { _ = await task.result }
        defer { acceptingCheckpointRestores.remove(review.id); reconcileCheckpointRestoreLocks() }
        do { try await task.value }
        catch { apply(await engine.current()); throw error }
    }
    func isInspectingCheckpointRestore(_ id: UUID) -> Bool { checkpointRestoreInspections[id] != nil }
    func inspectCheckpointRestore(_ id: UUID) async throws {
        guard !terminating, let engine, let operation = snapshot.checkpointRestoreOperation(id),
              operation.phase == .unconfirmed, operation.acknowledgedAt == nil, checkpointRestoreInspections[id] == nil else { throw CancellationError() }
        let task = Task { try await engine.inspectCheckpointRestore(operationID: id) }
        checkpointRestoreInspections[id] = .init(threadID: operation.review.threadID, task: task)
        defer { checkpointRestoreInspections.removeValue(forKey: id) }
        let receipt = try await withTaskCancellationHandler { try await task.value } onCancel: { task.cancel() }
        guard !terminating else { throw CancellationError() }
        apply(await engine.current())
        if let rejection = receipt.rejection { throw CoincideError(rejection) }
    }
    func acknowledgeCheckpointRestore(_ id: UUID) async throws {
        guard !terminating, let operation = snapshot.checkpointRestoreOperation(id), operation.phase == .unconfirmed,
              operation.acknowledgedAt == nil, checkpointRestoreInspections[id] == nil else { throw CancellationError() }
        let receipt = try await enqueue(.acknowledgeCheckpointRestore(operationID: id)).value
        if let rejection = receipt.rejection { throw CoincideError(rejection) }
    }
    private func suspendCheckpointCaches(path: String) {
        for (root, browser) in fileBrowsers where Self.pathsOverlap(root, path) { browser.suspendForWorkspaceMutation() }
        for (root, inspector) in gitInspectors where Self.pathsOverlap(root, path) { inspector.suspendForWorkspaceMutation() }
    }
    private func reconcileCheckpointRestoreLocks() {
        var durable: [UUID: String] = [:]
        for operation in snapshot.checkpointRestoreOperations ?? [] where operation.locksSource {
            durable[operation.id] = operation.review.gitReview.currentPlan.repositoryPath
        }
        for operation in snapshot.conversationHistoryOperations ?? [] where operation.locksFiles {
            if let files = operation.files { durable[operation.id] = files.review.gitReview.currentPlan.repositoryPath }
        }
        for (id, root) in durable {
            if checkpointRestoreLocks[id] == nil {
                let path = Self.canonicalPath(root)
                checkpointRestoreLocks[id] = path; suspendCheckpointCaches(path: path)
            }
        }
        for (id, path) in Array(checkpointRestoreLocks) where !acceptingCheckpointRestores.contains(id) && durable[id] == nil {
            checkpointRestoreLocks.removeValue(forKey: id)
            guard !terminating else { continue }
            let browsers = fileBrowsers.filter { Self.pathsOverlap($0.key, path) }.map(\.value)
            let inspectors = gitInspectors.filter { Self.pathsOverlap($0.key, path) }.map(\.value)
            checkpointRefreshTasks[id] = Task { [weak self] in
                for browser in browsers { await browser.refreshAfterWorkspaceMutation() }
                for inspector in inspectors { await inspector.refreshAfterWorkspaceMutation() }
                self?.checkpointRefreshTasks.removeValue(forKey: id)
            }
        }
    }
    func conversationHistoryOperation(_ id: UUID) -> ConversationHistoryOperation? {
        snapshot.conversationHistoryOperations?.first { $0.id == id }
    }
    func conversationHistoryOperations(threadID: UUID) -> [ConversationHistoryOperation] {
        Array((snapshot.conversationHistoryOperations ?? []).filter { $0.review.sourceThreadID == threadID }.reversed())
    }
    func conversationHistoryUnavailableReason(threadID: UUID, runID: UUID, kind: ConversationHistoryKind) -> String? {
        guard let thread = thread(threadID), let run = thread.runHistory?.first(where: { $0.id == runID }) else {
            return String(localized: "This recorded run is no longer available.")
        }
        if run.removedByHistoryOperationID != nil { return String(localized: "This run was removed from the current conversation by a rewind.") }
        if run.messageAttributionVersion != 1 || !run.status.isTerminal {
            return String(localized: "This run does not have a verified completed transcript boundary.")
        }
        if snapshot.isConversationHistoryLocked(threadID: threadID) || acceptingHistoryThreads.contains(threadID) {
            return String(localized: "Finish or inspect the pending conversation history action first.")
        }
        if thread.isArchived { return String(localized: "Unarchive this conversation before changing its history.") }
        if !snapshot.canReviewConversationHistory(threadID: threadID) || !canEditWorkspace(thread.workspacePath) {
            return String(localized: "Finish the current turn, queued messages, questions and workspace setup before changing conversation history.")
        }
        return snapshot.conversationHistoryUnavailableReason(threadID: threadID, runID: runID, kind: kind)
    }
    func reviewConversationHistory(threadID: UUID, runID: UUID, kind: ConversationHistoryKind, recallPromptOnSuccess: Bool = false) async throws -> ConversationHistoryReview {
        guard !terminating, let engine, let captured = thread(threadID),
              conversationHistoryUnavailableReason(threadID: threadID, runID: runID, kind: kind) == nil,
              !recallPromptOnSuccess || !isImportingAttachments(threadID) else { throw CancellationError() }
        let requestID = UUID()
        let task = Task { try await engine.reviewConversationHistory(threadID: threadID, runID: runID, kind: kind, recallPromptOnSuccess: recallPromptOnSuccess) }
        historyReviewReads[requestID] = .init(threadID: threadID, task: task)
        defer { historyReviewReads.removeValue(forKey: requestID) }
        let review = try await withTaskCancellationHandler { try await task.value } onCancel: { task.cancel() }
        guard !Task.isCancelled, !terminating, let current = thread(threadID), current.projectID == captured.projectID,
              current.workspacePath == captured.workspacePath, canEditWorkspace(current.workspacePath),
              !snapshot.isConversationHistoryLocked(threadID: threadID) else {
            await engine.discardConversationHistoryReview(reviewID: review.id)
            throw CancellationError()
        }
        return review
    }
    func reviewConversationHistoryRestoringFiles(_ keepReview: ConversationHistoryReview) async throws -> ConversationHistoryReview {
        let id = keepReview.sourceThreadID
        guard !terminating, let engine, let captured = thread(id), keepReview.kind == .rewindBeforeRun,
              conversationHistoryUnavailableReason(threadID: id, runID: keepReview.runID, kind: .rewindBeforeRun) == nil,
              canEditWorkspace(captured.workspacePath), checkpointRestoreActivityReason(path: captured.workspacePath) == nil else { throw CancellationError() }
        let requestID = UUID()
        let task = Task { try await engine.reviewConversationHistoryRestoringFiles(keepReview) }
        historyReviewReads[requestID] = .init(threadID: id, task: task)
        defer { historyReviewReads.removeValue(forKey: requestID) }
        let review = try await withTaskCancellationHandler { try await task.value } onCancel: { task.cancel() }
        guard !Task.isCancelled, !terminating, let current = thread(id), current.projectID == captured.projectID,
              current.workspacePath == captured.workspacePath, canEditWorkspace(current.workspacePath),
              let files = review.files, checkpointRestoreActivityReason(path: files.gitReview.currentPlan.repositoryPath) == nil else {
            await engine.discardConversationHistoryReview(reviewID: review.id)
            throw CancellationError()
        }
        return review
    }
    func discardConversationHistoryReview(_ id: UUID) {
        guard let engine else { return }
        Task { await engine.discardConversationHistoryReview(reviewID: id) }
    }
    func beginConversationHistory(_ review: ConversationHistoryReview, title: String? = nil) async throws {
        let id = review.sourceThreadID
        guard !terminating, let engine, let captured = thread(id),
              conversationHistoryUnavailableReason(threadID: id, runID: review.runID, kind: review.kind) == nil,
              review.recallPromptOnSuccess != true || !isImportingAttachments(id),
              acceptingHistoryThreads.insert(id).inserted else { throw CancellationError() }
        defer { acceptingHistoryThreads.remove(id) }
        if let files = review.files {
            let path = Self.canonicalPath(files.gitReview.currentPlan.repositoryPath)
            guard canEditWorkspace(path), checkpointRestoreActivityReason(path: path) == nil else { throw CancellationError() }
            acceptingCheckpointRestores.insert(review.id); checkpointRestoreLocks[review.id] = path
            suspendCheckpointCaches(path: path)
        }
        defer { acceptingCheckpointRestores.remove(review.id); reconcileCheckpointRestoreLocks() }
        flushDrafts()
        if review.kind == .forkAfterRun, selectedThreadID == id { historyNavigationRequests[review.id] = id }
        let previous = commandTail
        let task = Task {
            await previous?.value
            guard !self.terminating, let current = self.thread(id), current.projectID == captured.projectID,
                  current.workspacePath == captured.workspacePath,
                  review.recallPromptOnSuccess != true || !self.isImportingAttachments(id),
                  self.canAcceptConversationHistoryWorkspace(review),
                  !self.snapshot.isConversationHistoryLocked(threadID: id) else { throw CancellationError() }
            let receipt = try await engine.beginConversationHistory(review, title: title)
            self.apply(await engine.current())
            if let rejection = receipt.rejection { throw CoincideError(rejection) }
        }
        commandTail = Task { _ = await task.result }
        do { try await task.value }
        catch { historyNavigationRequests.removeValue(forKey: review.id); apply(await engine.current()); throw error }
    }
    private func canAcceptConversationHistoryWorkspace(_ review: ConversationHistoryReview) -> Bool {
        guard let files = review.files else { return canEditWorkspace(review.sourceConfiguration.workspacePath) }
        let path = files.gitReview.currentPlan.repositoryPath
        return !snapshot.isCheckpointRestoreLocked(path: path) && checkpointRestoreActivityReason(path: path) == nil &&
            !checkpointRestoreLocks.contains(where: { $0.key != review.id && Self.pathsOverlap(path, $0.value) }) &&
            !removalEditorLocks.values.contains(where: { $0.contains(where: { Self.pathsOverlap(path, $0) }) }) &&
            !workspaceTransitionLocks.values.contains(where: { $0.contains(where: { Self.pathsOverlap(path, $0) }) })
    }
    private func openAppliedHistoryForks() {
        for (id, source) in Array(historyNavigationRequests) {
            guard let operation = conversationHistoryOperation(id) else { continue }
            if operation.phase == .failed || operation.phase == .unconfirmed { historyNavigationRequests.removeValue(forKey: id); continue }
            guard operation.phase == .applied, let targetID = operation.review.targetThreadID, let target = thread(targetID) else { continue }
            historyNavigationRequests.removeValue(forKey: id)
            guard selectedThreadID == source else { continue }
            selectedProjectID = target.projectID; showArchived = target.isArchived; selectedThreadID = targetID
        }
    }
    func isInspectingConversationHistory(_ id: UUID) -> Bool { historyInspections[id] != nil }
    func canInspectConversationHistory(_ operation: ConversationHistoryOperation) -> Bool {
        !terminating && snapshot.canInspectConversationHistory(operationID: operation.id)
    }
    func isRespondingPiHistory(operationID: UUID, sessionID: UUID, requestID: JSONValue) -> Bool {
        piHistoryResponses.values.contains {
            $0.operationID == operationID && $0.sessionID == sessionID && $0.request.id == requestID
        }
    }
    func canRespondPiHistory(operationID: UUID, sessionID: UUID, requestID: JSONValue) -> Bool {
        guard !terminating, engine != nil, let operation = conversationHistoryOperation(operationID),
              operation.isPending, operation.review.pi != nil, operation.review.sourceConfiguration.provider == .pi,
              thread(operation.review.sourceThreadID) != nil,
              let controls = operation.piControls, controls.sessionID == sessionID,
              controls.requests.contains(where: { $0.id == requestID && !$0.responding }),
              piHistoryCancellations[operationID] == nil else { return false }
        return !isRespondingPiHistory(operationID: operationID, sessionID: sessionID, requestID: requestID)
    }
    func respondPiHistory(operationID: UUID, sessionID: UUID, request: ApprovalRequest,
                          response: ProviderApprovalResponse) async throws {
        guard let engine, canRespondPiHistory(operationID: operationID, sessionID: sessionID, requestID: request.id),
              let operation = conversationHistoryOperation(operationID),
              operation.piControls?.requests.contains(where: { $0.request == request && !$0.responding }) == true else {
            throw CancellationError()
        }
        let id = UUID()
        let task = Task { try await engine.respondPiHistory(operationID: operationID, sessionID: sessionID,
                                                           requestID: request.id, response: response) }
        piHistoryResponses[id] = .init(operationID: operationID, sessionID: sessionID, request: request,
            owner: .init(threadID: operation.review.sourceThreadID, task: task))
        defer { piHistoryResponses.removeValue(forKey: id) }
        let receipt: WorkspaceCommandReceipt
        do { receipt = try await withTaskCancellationHandler { try await task.value } onCancel: { task.cancel() } }
        catch {
            guard !terminating else { throw CancellationError() }
            apply(await engine.current())
            guard let current = conversationHistoryOperation(operationID), current.isPending,
                  current.piControls?.sessionID == sessionID,
                  current.piControls?.requests.contains(where: { $0.request == request }) == true else { throw CancellationError() }
            throw error
        }
        guard !terminating else { throw CancellationError() }
        apply(await engine.current())
        if let rejection = receipt.rejection {
            guard let current = conversationHistoryOperation(operationID), current.isPending,
                  current.piControls?.sessionID == sessionID,
                  current.piControls?.requests.contains(where: { $0.request == request }) == true else { throw CancellationError() }
            throw CoincideError(rejection)
        }
    }
    func isCancellingPiHistory(_ id: UUID) -> Bool { piHistoryCancellations[id] != nil }
    func canCancelPiHistory(_ operation: ConversationHistoryOperation) -> Bool {
        !terminating && engine != nil && operation.isPending && operation.review.pi != nil && operation.review.sourceConfiguration.provider == .pi &&
            piHistoryCancellations[operation.id] == nil && thread(operation.review.sourceThreadID) != nil
    }
    func cancelPiHistory(_ id: UUID) async throws {
        guard let engine, let operation = conversationHistoryOperation(id), canCancelPiHistory(operation) else { throw CancellationError() }
        // The Engine owns the accepted job. Keep cancellation independent of a
        // response awaiting native I/O and of the workspace command queue.
        let task = Task { try await engine.cancelPiHistory(operationID: id) }
        piHistoryCancellations[id] = .init(threadID: operation.review.sourceThreadID, task: task)
        defer { piHistoryCancellations.removeValue(forKey: id) }
        let receipt = try await withTaskCancellationHandler { try await task.value } onCancel: { task.cancel() }
        guard !terminating else { throw CancellationError() }
        apply(await engine.current())
        if let rejection = receipt.rejection { throw CoincideError(rejection) }
    }
    func hasPendingClaudeResumeSelection(_ operation: ConversationHistoryOperation) -> Bool {
        snapshot.isClaudeResumeSelectionPending(operationID: operation.id)
    }
    func isConsumingClaudeResumeSelection(_ operation: ConversationHistoryOperation) -> Bool {
        hasPendingClaudeResumeSelection(operation) && thread(operation.review.sourceThreadID)?.claudeResumeConsumerRunID != nil
    }
    func claudeResumeSelectionNeedsInspection(threadID: UUID) -> Bool {
        snapshot.claudeResumeSelectionNeedsInspection(threadID: threadID)
    }
    func isInspectingClaudeResumeSelection(threadID: UUID) -> Bool { historyInspections[threadID] != nil }
    func inspectClaudeResumeSelection(threadID: UUID) async throws {
        guard !terminating, let engine, snapshot.claudeResumeSelectionNeedsInspection(threadID: threadID),
              historyInspections[threadID] == nil else { throw CancellationError() }
        let task = Task { try await engine.reconcileClaudeResumeSelection(threadID: threadID) }
        historyInspections[threadID] = .init(threadID: threadID, task: task)
        defer { historyInspections.removeValue(forKey: threadID) }
        let receipt = try await withTaskCancellationHandler { try await task.value } onCancel: { task.cancel() }
        guard !terminating else { throw CancellationError() }
        apply(await engine.current())
        if let rejection = receipt.rejection { throw CoincideError(rejection) }
    }
    func canKeepOpenCodeV1Original(_ operation: ConversationHistoryOperation) -> Bool {
        !terminating && operation.phase == .unconfirmed && operation.review.kind == .rewindBeforeRun &&
            operation.review.openCodeV1 != nil && !operation.isWorking &&
            historyInspections[operation.id] == nil && thread(operation.review.sourceThreadID) != nil
    }
    func canKeepPiOriginal(_ operation: ConversationHistoryOperation) -> Bool {
        !terminating && operation.phase == .unconfirmed && operation.review.pi != nil && !operation.isWorking &&
            historyInspections[operation.id] == nil && thread(operation.review.sourceThreadID) != nil
    }
    func keepPiOriginal(_ id: UUID) async throws {
        guard let engine, let operation = conversationHistoryOperation(id), canKeepPiOriginal(operation),
              let source = thread(operation.review.sourceThreadID),
              operation.files != nil || canEditWorkspace(source.workspacePath) else { throw CancellationError() }
        let task = Task {
            let expected = try await engine.inspectPiOriginal(operationID: id)
            return try await engine.keepPiOriginal(operationID: id, expected: expected)
        }
        historyInspections[id] = .init(threadID: source.id, task: task)
        defer { historyInspections.removeValue(forKey: id) }
        let receipt = try await withTaskCancellationHandler { try await task.value } onCancel: { task.cancel() }
        guard !terminating else { throw CancellationError() }
        apply(await engine.current())
        if let rejection = receipt.rejection { throw CoincideError(rejection) }
    }
    func piFreshSessionNeedsInspection(threadID: UUID) -> Bool {
        snapshot.piFreshSessionNeedsInspection(threadID: threadID)
    }
    func isInspectingPiFreshSession(threadID: UUID) -> Bool {
        piFreshHistoryReads[threadID] != nil || historyInspections[threadID] != nil
    }
    func canInspectPiFreshSession(threadID: UUID) -> Bool {
        !terminating && engine != nil && piFreshSessionNeedsInspection(threadID: threadID) && !isInspectingPiFreshSession(threadID: threadID)
    }
    func inspectPiFreshSession(threadID: UUID) async throws {
        guard let engine, canInspectPiFreshSession(threadID: threadID), let source = thread(threadID),
              let intent = source.piFreshSessionIntent, let consumerRunID = source.piFreshConsumerRunID else { throw CancellationError() }
        let task = Task<(PiFreshSessionInspection, WorkspaceCommandReceipt?), any Error> {
            let result = try await engine.inspectPiFreshSession(threadID: threadID)
            try Task.checkCancellation()
            if case .persisted(let revision) = result {
                return (result, try await engine.confirmPersistedPiFreshSession(threadID: threadID, expected: revision))
            }
            return (result, nil)
        }
        piFreshHistoryReads[threadID] = .init(intent: intent, consumerRunID: consumerRunID, task: task)
        piFreshHistoryObservations.removeValue(forKey: threadID)
        defer { piFreshHistoryReads.removeValue(forKey: threadID) }
        let (result, receipt) = try await withTaskCancellationHandler { try await task.value } onCancel: { task.cancel() }
        guard !terminating else { throw CancellationError() }
        apply(await engine.current())
        if let rejection = receipt?.rejection { throw CoincideError(rejection) }
        guard let current = thread(threadID), current.piFreshSessionIntent == intent, current.piFreshConsumerRunID == consumerRunID else { return }
        piFreshHistoryObservations[threadID] = .init(intent: intent, consumerRunID: consumerRunID, result: result)
    }
    func canKeepUnwrittenPiFreshSession(threadID: UUID) -> Bool {
        guard canInspectPiFreshSession(threadID: threadID), let current = thread(threadID),
              let observed = piFreshHistoryObservations[threadID], current.piFreshSessionIntent == observed.intent,
              current.piFreshConsumerRunID == observed.consumerRunID, case .unwritten = observed.result else { return false }
        return true
    }
    func keepUnwrittenPiFreshSession(threadID: UUID) async throws {
        guard let engine, canKeepUnwrittenPiFreshSession(threadID: threadID), let observed = piFreshHistoryObservations[threadID] else {
            throw CancellationError()
        }
        let task = Task { try await engine.acknowledgeUnwrittenPiFreshSession(threadID: threadID,
            expectedIntentID: observed.intent.id, expectedConsumerRunID: observed.consumerRunID) }
        historyInspections[threadID] = .init(threadID: threadID, task: task)
        defer { historyInspections.removeValue(forKey: threadID) }
        let receipt = try await withTaskCancellationHandler { try await task.value } onCancel: { task.cancel() }
        guard !terminating else { throw CancellationError() }
        apply(await engine.current()); piFreshHistoryObservations.removeValue(forKey: threadID)
        if let rejection = receipt.rejection { throw CoincideError(rejection) }
    }
    func keepOpenCodeV1Original(_ id: UUID) async throws {
        guard let engine, let operation = conversationHistoryOperation(id), canKeepOpenCodeV1Original(operation),
              let source = thread(operation.review.sourceThreadID),
              operation.files != nil || canEditWorkspace(source.workspacePath) else { throw CancellationError() }
        let task = Task {
            let expected = try await engine.inspectOpenCodeV1Original(operationID: id)
            return try await engine.keepOpenCodeV1Original(operationID: id, expected: expected)
        }
        historyInspections[id] = .init(threadID: source.id, task: task)
        defer { historyInspections.removeValue(forKey: id) }
        let receipt = try await withTaskCancellationHandler { try await task.value } onCancel: { task.cancel() }
        guard !terminating else { throw CancellationError() }
        apply(await engine.current())
        if let rejection = receipt.rejection { throw CoincideError(rejection) }
    }
    func canClearConversationHistoryMaintenance(_ operation: ConversationHistoryOperation) -> Bool {
        !terminating && operation.phase == .unconfirmed && operation.review.kind == .rewindBeforeRun &&
            operation.review.openCodeV2 != nil && operation.maintenance?.phase.isWorking != true &&
            operation.maintenance?.phase != .applied &&
            historyInspections[operation.id] == nil && thread(operation.review.sourceThreadID) != nil
    }
    func clearConversationHistoryMaintenance(_ id: UUID) async throws {
        guard let engine, let operation = conversationHistoryOperation(id), canClearConversationHistoryMaintenance(operation),
              let source = thread(operation.review.sourceThreadID),
              operation.files != nil || canEditWorkspace(source.workspacePath) else { throw CancellationError() }
        let task = Task { try await engine.clearConversationHistoryMaintenance(operationID: id) }
        historyInspections[id] = .init(threadID: source.id, task: task)
        defer { historyInspections.removeValue(forKey: id) }
        let receipt = try await withTaskCancellationHandler { try await task.value } onCancel: { task.cancel() }
        guard !terminating else { throw CancellationError() }
        apply(await engine.current())
        if let rejection = receipt.rejection { throw CoincideError(rejection) }
    }
    func reconcileConversationHistory(_ id: UUID) async throws {
        guard !terminating, let engine, let operation = conversationHistoryOperation(id), canInspectConversationHistory(operation),
              historyInspections[id] == nil,
              operation.maintenance?.phase.isWorking != true,
              let source = thread(operation.review.sourceThreadID),
              operation.files != nil || canEditWorkspace(source.workspacePath) else { throw CancellationError() }
        let task = Task { try await engine.reconcileConversationHistory(operationID: id) }
        historyInspections[id] = .init(threadID: source.id, task: task)
        defer { historyInspections.removeValue(forKey: id) }
        let receipt = try await withTaskCancellationHandler { try await task.value } onCancel: { task.cancel() }
        guard !terminating else { throw CancellationError() }
        apply(await engine.current())
        if let rejection = receipt.rejection { throw CoincideError(rejection) }
    }
    func canRecallConversationHistoryPrompt(_ operation: ConversationHistoryOperation) -> Bool {
        guard operation.phase == .applied, operation.review.kind == .rewindBeforeRun, operation.recalledAt == nil,
              operation.allExternalWorkSucceeded, operation.recallDismissedAt == nil,
              historyRecallDraftOwners[operation.review.sourceThreadID].map({ $0 == operation.id }) ?? true,
              !snapshot.isCheckpointRestoreLocked(threadID: operation.review.sourceThreadID),
              !snapshot.isConversationHistoryLocked(threadID: operation.review.sourceThreadID, excludingOperationID: operation.needsPromptRecall ? operation.id : nil),
              let thread = thread(operation.review.sourceThreadID),
              let run = thread.runHistory?.first(where: { $0.id == operation.review.runID }), run.origin == .user,
              let message = thread.messages.first(where: {
                  $0.id == run.userMessageID && $0.role == .user &&
                  $0.runReference == .init(threadID: operation.review.sourceThreadID, runID: run.id)
              }) else { return false }
        return operation.needsPromptRecall || !message.text.isEmpty || message.attachments?.isEmpty == false
    }
    func isRecallingConversationHistoryPrompt(_ id: UUID) -> Bool { recallingHistoryPrompts.contains(id) || automaticHistoryRecallTasks[id] != nil }
    func conversationHistoryRecallError(_ id: UUID) -> String? { automaticHistoryRecallErrors[id] }
    private func processAutomaticHistoryRecalls() {
        for operation in snapshot.conversationHistoryOperations ?? [] {
            if !operation.needsPromptRecall { automaticHistoryRecallErrors.removeValue(forKey: operation.id); continue }
            guard !terminating, automaticHistoryRecallTasks[operation.id] == nil,
                  !recallingHistoryPrompts.contains(operation.id), automaticHistoryRecallErrors[operation.id] == nil else { continue }
            automaticHistoryRecallTasks[operation.id] = Task { [weak self] in
                guard let self else { return }
                defer { self.automaticHistoryRecallTasks.removeValue(forKey: operation.id) }
                do { try await self.recallConversationHistoryPrompt(operation.id) }
                catch is CancellationError {
                    if !self.terminating, self.conversationHistoryOperation(operation.id)?.needsPromptRecall == true {
                        self.automaticHistoryRecallErrors[operation.id] = ConversationHistoryPresentation.recallFailure(operation)
                    }
                } catch {
                    if !self.terminating, self.conversationHistoryOperation(operation.id)?.needsPromptRecall == true {
                        self.automaticHistoryRecallErrors[operation.id] = ConversationHistoryPresentation.recallFailure(operation)
                    }
                }
            }
        }
    }
    func recallConversationHistoryPrompt(_ id: UUID) async throws {
        guard !terminating, let operation = conversationHistoryOperation(id), canRecallConversationHistoryPrompt(operation),
              recallingHistoryPrompts.insert(id).inserted else { throw CancellationError() }
        defer { recallingHistoryPrompts.remove(id) }
        automaticHistoryRecallErrors.removeValue(forKey: id)
        let threadID = operation.review.sourceThreadID
        guard let current = thread(threadID), let run = current.runHistory?.first(where: { $0.id == operation.review.runID }),
              let message = current.messages.first(where: { $0.id == run.userMessageID }) else { throw CancellationError() }
        flushDrafts()
        historyRecallDraftOwners[threadID] = id
        defer {
            historyRecallDraftOwners.removeValue(forKey: threadID)
            flushDrafts()
            if historyRecallDraftOwners.isEmpty {
                let waiters = historyRecallDrainWaiters; historyRecallDrainWaiters = []
                for waiter in waiters { waiter.resume() }
            }
        }
        let task = enqueue(.recallConversationHistoryPrompt(operationID: id)) { [weak self] in
            guard let self, !self.terminating, let latest = self.conversationHistoryOperation(id),
                  self.canRecallConversationHistoryPrompt(latest), let thread = self.thread(threadID),
                  self.canEditWorkspace(thread.workspacePath) else { throw CancellationError() }
        }
        do {
            let receipt = try await task.value
            if let rejection = receipt.rejection { throw CoincideError(rejection) }
            // A newer local edit can arrive while the atomic Core command is awaiting
            // acknowledgment. Append to that live edit rather than restoring an old draft.
            if let latest = pendingDrafts[threadID] ?? draftOverrides[threadID], !message.text.isEmpty {
                let merged = latest.isEmpty ? message.text : latest + "\n\n" + message.text
                // Finishing an already accepted recall remains necessary during
                // shutdown; setDraft intentionally rejects new edits then.
                draftOverrides[threadID] = merged; pendingDrafts[threadID] = merged
            }
        } catch {
            if !terminating, conversationHistoryOperation(id)?.needsPromptRecall == true {
                automaticHistoryRecallErrors[id] = ConversationHistoryPresentation.recallFailure(operation)
            }
            throw error
        }
    }
    func dismissConversationHistoryRecall(_ id: UUID) async throws {
        guard !terminating, let operation = conversationHistoryOperation(id), operation.needsPromptRecall,
              !isRecallingConversationHistoryPrompt(id) else { throw CancellationError() }
        flushDrafts()
        let receipt = try await enqueue(.dismissConversationHistoryRecall(operationID: id)).value
        if let rejection = receipt.rejection { throw CoincideError(rejection) }
    }
    func inspectConversationHistoryFiles(_ id: UUID) async throws {
        guard !terminating, let engine, let operation = conversationHistoryOperation(id), operation.phase == .applied,
              operation.files?.phase == .unconfirmed, operation.files?.acknowledgedAt == nil, historyInspections[id] == nil else { throw CancellationError() }
        let task = Task { try await engine.inspectConversationHistoryFiles(operationID: id) }
        historyInspections[id] = .init(threadID: operation.review.sourceThreadID, task: task)
        defer { historyInspections.removeValue(forKey: id) }
        let receipt = try await withTaskCancellationHandler { try await task.value } onCancel: { task.cancel() }
        guard !terminating else { throw CancellationError() }
        apply(await engine.current())
        if let rejection = receipt.rejection { throw CoincideError(rejection) }
    }
    func acknowledgeConversationHistoryFiles(_ id: UUID) async throws {
        guard !terminating, let operation = conversationHistoryOperation(id), operation.phase == .applied,
              let files = operation.files, [.failed, .unconfirmed].contains(files.phase), files.acknowledgedAt == nil,
              historyInspections[id] == nil else { throw CancellationError() }
        let receipt = try await enqueue(.acknowledgeConversationHistoryFiles(operationID: id)).value
        if let rejection = receipt.rejection { throw CoincideError(rejection) }
    }
    func canSettle(_ thread: CodingThread) -> Bool {
        !terminating && snapshot.canSettle(threadID: thread.id) && canEditWorkspace(thread.workspacePath)
    }
    func settleThread(_ id: UUID, reviewScript: Bool = true) async throws {
        try await performSettlementCommand(for: id) { engine, thread in
            try await engine.settleThread(threadID: id, expectedWorkspacePath: thread.workspacePath, reviewScript: reviewScript)
        }
    }
    func resumeThread(_ id: UUID, generationID: UUID) async throws {
        guard thread(id)?.settlement?.id == generationID else { throw CancellationError() }
        try await performSettlementCommand(for: id) { engine, _ in
            try await engine.resumeThread(threadID: id, generationID: generationID)
        }
    }
    func requestResume(_ id: UUID, generationID: UUID) {
        Task {
            do { try await resumeThread(id, generationID: generationID) }
            catch is CancellationError { }
            catch { if !terminating { errorMessage = error.localizedDescription } }
        }
    }
    private func performSettlementCommand(for id: UUID,
        operation: @escaping @MainActor (WorkspaceEngine, CodingThread) async throws -> WorkspaceCommandReceipt) async throws {
        guard !terminating, let engine, let captured = thread(id), canEditWorkspace(captured.workspacePath) else { throw CancellationError() }
        flushDrafts()
        let previous = commandTail
        let task = Task<WorkspaceCommandReceipt, any Error> {
            await previous?.value
            try Task.checkCancellation()
            guard !self.terminating, let current = self.thread(id), current.projectID == captured.projectID,
                  current.workspacePath == captured.workspacePath, current.settlement?.id == captured.settlement?.id,
                  current.workspacePreparation?.id == captured.workspacePreparation?.id,
                  self.canEditWorkspace(current.workspacePath) else { throw CancellationError() }
            let receipt = try await operation(engine, current)
            if let rejection = receipt.rejection { throw CoincideError(rejection) }
            self.apply(await engine.current())
            return receipt
        }
        commandTail = Task { _ = await task.result }
        _ = try await withTaskCancellationHandler { try await task.value } onCancel: { task.cancel() }
    }
    private func performWorktreeCommand(for id: UUID, changesWorkspace: Bool = false,
                                        operation: @escaping @MainActor (WorkspaceEngine) async throws -> WorkspaceCommandReceipt) async {
        guard !terminating, let engine, let captured = thread(id), canEditWorkspace(captured.workspacePath),
              preparingWorkspaces.insert(id).inserted else { return }
        flushDrafts()
        let previous = commandTail
        let task = Task<Void, any Error> {
            await previous?.value
            try Task.checkCancellation()
            guard !self.terminating, let current = self.thread(id), current.projectID == captured.projectID,
                  current.workspacePath == captured.workspacePath,
                  current.workspacePreparation?.request.id == captured.workspacePreparation?.request.id,
                  self.canEditWorkspace(current.workspacePath) else { throw CancellationError() }
            if changesWorkspace {
                let path = Self.canonicalPath(current.workspacePath)
                guard !self.dirtyEditors.values.contains(path) else {
                    throw CoincideError("Save or discard unsaved file edits before changing this conversation's checkout.")
                }
                guard !self.terminalStores.values.compactMap(\.value).contains(where: { !($0.sessions[id] ?? []).isEmpty }),
                      !self.closingTerminalSessions.values.contains(where: { Self.pathsOverlap($0.directory, current.workspacePath) }) else {
                    throw CoincideError("Close this conversation's terminal tabs in every window before changing its checkout. Running commands are kept open until you close them.")
                }
                self.workspaceTransitionLocks[id] = [path]
            }
            defer { self.workspaceTransitionLocks.removeValue(forKey: id) }
            _ = try await operation(engine)
            self.apply(await engine.current())
        }
        worktreeTasks[id] = task; commandTail = Task { _ = await task.result }
        defer { preparingWorkspaces.remove(id); worktreeTasks.removeValue(forKey: id) }
        do { try await withTaskCancellationHandler { try await task.value } onCancel: { task.cancel() } }
        catch is CancellationError { }
        catch { if thread(id) != nil, !terminating { errorMessage = GitService.redactURLs(error.localizedDescription) } }
    }
    func worktreeSetupOptions(for id: UUID) async throws -> WorktreeSetupOptions {
        guard !terminating, let captured = thread(id), canEditWorkspace(captured.workspacePath),
              captured.workspacePreparation?.isRunning != true,
              snapshot.projects.first(where: { $0.id == captured.projectID })?.clone?.isReady ?? true,
              captured.messages.isEmpty, !captured.isBusy, captured.queuedTurns.isEmpty else { throw CancellationError() }
        let path = captured.workspacePreparation.map { $0.isReady ? captured.workspacePath : $0.request.sourcePath } ?? captured.workspacePath
        let anchor = WorkspaceFileService(root: URL(fileURLWithPath: path)), jobID = UUID()
        let task = Task<WorktreeSetupOptions, any Error> {
            do {
                _ = try await anchor.metadata()
                async let inventory = GitWorktreeService(source: URL(fileURLWithPath: path)).inventory()
                async let branches = GitService(root: URL(fileURLWithPath: path)).branches()
                let result = try await WorktreeSetupOptions(branches: branches, worktrees: inventory.worktrees.filter {
                    !$0.isBare && !$0.isDetached && $0.prunableReason == nil && $0.branch != nil && $0.headCommit != nil
                })
                _ = try await anchor.metadata()
                try Task.checkCancellation()
                await anchor.close(); return result
            } catch { await anchor.close(); throw error }
        }
        worktreeOptionsReads[jobID] = .init(threadID: id, task: task)
        defer { worktreeOptionsReads.removeValue(forKey: jobID) }
        func isCurrent() -> Bool {
            guard !task.isCancelled, !terminating, let current = thread(id), current.projectID == captured.projectID,
                  current.workspacePath == captured.workspacePath,
                  current.workspacePreparation?.request.id == captured.workspacePreparation?.request.id,
                  canEditWorkspace(current.workspacePath) else { return false }
            return true
        }
        do {
            let result = try await withTaskCancellationHandler { try await task.value } onCancel: { task.cancel() }
            try Task.checkCancellation()
            guard isCurrent() else { throw CancellationError() }
            return result
        } catch {
            try Task.checkCancellation()
            guard isCurrent() else { throw CancellationError() }
            throw error
        }
    }
    func shutdown() async {
        terminating = true
        await agentSessionImports.shutdown()
        await composerDraftTools.shutdown()
        await notifications.shutdown()
        for model in contextTransferStores.values { await model.shutdown() }
        let skills = retireSkills()
        codexAuthenticationBinding?.cancel()
        await codexAuthenticationBinding?.value
        await codexAuthentication.shutdown()
        await antigravityAccount.shutdown()
        await antigravityInstallation.shutdown()
        await codexAccount.cancel()
        await codexRuntime.shutdown()
        for task in skills { await task.value }
        let codexReads = Array(codexCatalogReads.values)
        for task in codexReads { task.cancel() }
        for task in codexReads { _ = try? await task.value }
        await acpConnections.cancel()
        let modelReads = codexModelDefaultsReads.values.map(\.task); codexModelDefaultsReads.removeAll()
        for task in modelReads { task.cancel() }; for task in modelReads { _ = await task.value }
        let recalls = Array(automaticHistoryRecallTasks.values)
        for task in recalls { task.cancel() }; for task in recalls { await task.value }
        while !historyRecallDraftOwners.isEmpty {
            await withCheckedContinuation { historyRecallDrainWaiters.append($0) }
        }
        let restoreReads = checkpointRestoreReads.values.map(\.task)
        let restoreChecks = checkpointRestoreInspections.values.map(\.task)
        for task in restoreReads { task.cancel() }; for task in restoreChecks { task.cancel() }
        for task in restoreReads { _ = await task.result }; for task in restoreChecks { _ = await task.result }
        let refreshes = Array(checkpointRefreshTasks.values) + Array(pullRequestCheckoutRefreshTasks.values)
        for task in refreshes { task.cancel() }; for task in refreshes { await task.value }
        let historyReads = historyReviewReads.values.map(\.task)
        let historyChecks = historyInspections.values.map(\.task)
        let piHistoryActions = piHistoryResponses.values.map(\.owner.task) + piHistoryCancellations.values.map(\.task)
        let piFreshReads = piFreshHistoryReads.values.map(\.task)
        for task in historyReads { task.cancel() }; for task in historyChecks { task.cancel() }
        for task in piHistoryActions { task.cancel() }
        for task in piFreshReads { task.cancel() }
        for task in historyReads { _ = await task.result }; for task in historyChecks { _ = await task.result }
        for task in piHistoryActions { _ = await task.result }
        for task in piFreshReads { _ = await task.result }
        await projectScriptService?.shutdown(); await projectSettings.shutdown()
        await externalEditorService?.shutdown()
        let creations = Array(projectCreationTasks.values)
        for task in creations { task.cancel() }
        for task in creations { _ = await task.result }
        let worktrees = Array(worktreeTasks.values); for task in worktrees { task.cancel() }; for task in worktrees { _ = await task.result }
        let worktreeReads = worktreeOptionsReads.values.map(\.task)
        for task in worktreeReads { task.cancel() }; for task in worktreeReads { _ = await task.result }
        let retries = Array(projectCloneRetryTasks.values); for task in retries { task.cancel() }; for task in retries { await task.value }
        let inspectors = Array(gitInspectors.values)
        for model in inspectors { model.prepareForShutdown() }
        for model in inspectors { await model.shutdown() }
        let pullRequests = Array(pullRequestStores.values)
        for model in pullRequests { model.prepareForShutdown() }
        for model in pullRequests { await model.shutdown() }
        let browsers = Array(fileBrowsers.values); fileBrowsers.removeAll()
        for model in browsers { model.prepareForShutdown() }
        for model in browsers { await model.shutdown() }
        let services = Array(fileServices.values); fileServices.removeAll()
        for service in services { await service.close() }
        for cleanup in Array(fileServiceCleanupTasks.values) { await cleanup.task.value }
        let imports = Array(attachmentImportTasks.values); for task in imports { task.cancel() }; for task in imports { await task.value }
        draftSaveTask?.cancel(); flushDrafts()
        await commandTail?.value
        for cleanup in Array(removalCleanupTasks.values) { await cleanup.task.value }
        for terminals in terminalStores.values.compactMap(\.value) {
            let closing = terminals.suspend()
            await terminals.waitForRestoration(); await terminals.waitForPersistence()
            for session in closing { await session.waitForClose() }
        }
        for task in Array(closingTerminalTasks.values) { await task.value }
        for task in Array(terminalSuspensions.values) { await task.value }
        await engine?.shutdown()
        updatesTask?.cancel(); updatesTask = nil
    }
}
