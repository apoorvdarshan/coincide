import Foundation

public struct QueuedTurn: Codable, Sendable, Equatable, Identifiable {
    public var id: UUID
    public var text: String
    public var configuration: ProviderConfiguration
    public var createdAt: Date
    public var attachments: [ChatAttachment]? = nil
}
public struct ActiveRun: Codable, Sendable, Equatable, Identifiable {
    public var id: UUID
    public var configuration: ProviderConfiguration
    public var startedAt: Date
    public var stopRequested = false
    public var nativeTurnID: String?
}
public struct RuntimeRequest: Codable, Sendable, Equatable, Identifiable {
    public var request: ApprovalRequest
    public var responding = false
    public var sessionScoped: Bool?
    public var id: JSONValue { request.id }
}

public enum ThreadEdit: Codable, Sendable, Equatable {
    case title(String), model(String), provider(ProviderKind), permission(PermissionMode)
    case draft(String), pinned(Bool), archived(Bool), workspacePath(String)
    case acpAgent(ACPAgentConfiguration), agentMode(String?)
    case agentConfig(id: String, value: String?)
    case agentConfiguration(id: String, value: JSONValue?)
    case resetAgentOptions
}

public enum WorkspaceCommand: Codable, Sendable, Equatable {
    case addProject(WorkspaceProject)
    case addProjectWithThread(project: WorkspaceProject, thread: CodingThread)
    case renameProject(projectID: UUID, title: String)
    case removeProject(projectID: UUID, expectedThreadIDs: [UUID])
    case setProjectExpanded(projectID: UUID, expanded: Bool)
    case setProjectSortMode(ProjectSortMode)
    case moveProject(projectID: UUID, before: UUID?, expectedOrder: [UUID])
    case reorderProjects(projectIDs: [UUID], expectedOrder: [UUID])
    case createThread(CodingThread)
    case editThread(UUID, ThreadEdit)
    case submit(threadID: UUID, text: String)
    case interrupt(threadID: UUID)
    case respond(threadID: UUID, requestID: JSONValue, response: ProviderApprovalResponse)
    case removeQueued(threadID: UUID, queuedID: UUID)
    case editQueued(threadID: UUID, queuedID: UUID)
    case resumeQueue(threadID: UUID)
    case addAttachments(threadID: UUID, attachments: [ChatAttachment])
    case removeAttachment(threadID: UUID, attachmentID: UUID)
    case saveACPAgent(ACPAgentConfiguration)
    case removeACPAgent(UUID)
    case startProjectClone(project: WorkspaceProject, thread: CodingThread)
    case cancelProjectClone(UUID)
    case retryProjectClone(projectID: UUID, plan: GitClonePlan)
}

enum EngineCommand: Codable, Sendable {
    case client(WorkspaceCommand)
    case runtimeOpened(threadID: UUID, runID: UUID, runtimeID: UUID)
    case provider(threadID: UUID, runtimeID: UUID, event: ProviderEvent)
    case effectResult(WorkspaceEffectRequest, EffectResult)
    case pauseQueues
    case cloneStarted(projectID: UUID, attemptID: UUID)
    case cloneProgress(projectID: UUID, attemptID: UUID, progress: GitCloneProgress)
}
enum EffectResult: Codable, Sendable { case succeeded, failed(String), cancelled, stopped }

struct WorkspaceDecision: Sendable {
    var snapshot: WorkspaceSnapshot
    var effects: [PendingWorkspaceEffect] = []
    var closeRuntimes: Set<UUID> = []
    // Kept for existing single-runtime decision inspections.
    var closeRuntime: UUID? { closeRuntimes.first }
    var cancelCloneAttempt: UUID?

    static func make(_ command: EngineCommand, id: UUID, snapshot: WorkspaceSnapshot, now: Date) throws -> Self {
        var decision = Self(snapshot: snapshot)
        switch command {
        case .client(.removeProject(let projectID, let expectedThreadIDs)):
            guard decision.snapshot.projects.contains(where: { $0.id == projectID }) else { throw WorkspaceCommandError("This project is no longer available.") }
            let threadIDs = Set(decision.snapshot.threads.filter { $0.projectID == projectID }.map(\.id))
            guard Set(expectedThreadIDs).count == expectedThreadIDs.count, Set(expectedThreadIDs) == threadIDs else {
                throw WorkspaceCommandError("This project's conversations changed. Review the current active and archived conversations before removing it.")
            }
            decision.snapshot.projects.removeAll { $0.id == projectID }
            decision.snapshot.threads.removeAll { $0.projectID == projectID }
            if var preferences = decision.snapshot.sidebarPreferences {
                preferences.collapsedProjectIDs.removeAll { $0 == projectID }; decision.snapshot.sidebarPreferences = preferences
            }
            decision.closeRuntimes.formUnion(threadIDs)
        case .client(.renameProject(let projectID, let requested)):
            let title: String
            do { title = try ManagedProjectService.validatedName(requested) }
            catch { throw WorkspaceCommandError(error.localizedDescription) }
            guard let index = decision.snapshot.projects.firstIndex(where: { $0.id == projectID }) else { throw WorkspaceCommandError("This project is no longer available.") }
            if decision.snapshot.projects[index].name != title {
                decision.snapshot.projects[index].name = title
                decision.snapshot.projects[index].updatedAt = now
            }
        case .client(.setProjectExpanded(let projectID, let expanded)):
            guard decision.snapshot.projects.contains(where: { $0.id == projectID }) else { throw WorkspaceCommandError("This project is no longer available.") }
            var preferences = decision.snapshot.effectiveSidebarPreferences
            if decision.snapshot.isProjectExpanded(projectID) != expanded {
                preferences.collapsedProjectIDs.removeAll { $0 == projectID }
                if !expanded { preferences.collapsedProjectIDs.append(projectID) }
                preferences.collapsedProjectIDs.sort { $0.uuidString < $1.uuidString }
                decision.snapshot.sidebarPreferences = preferences
            }
        case .client(.setProjectSortMode(let mode)):
            var preferences = decision.snapshot.effectiveSidebarPreferences
            if preferences.sortMode != mode {
                preferences.sortMode = mode; decision.snapshot.sidebarPreferences = preferences
            }
        case .client(.moveProject(let projectID, let before, let expected)):
            try decision.validateProjectOrder(expected)
            guard expected.contains(projectID), before.map({ expected.contains($0) }) ?? true else { throw WorkspaceCommandError("The project being moved is no longer available.") }
            if before != projectID {
                var order = expected.filter { $0 != projectID }
                let index = before.flatMap { order.firstIndex(of: $0) } ?? order.endIndex
                order.insert(projectID, at: index)
                decision.reorderProjects(order)
            }
        case .client(.reorderProjects(let order, let expected)):
            try decision.validateProjectOrder(expected)
            guard order.count == expected.count, Set(order) == Set(expected) else { throw WorkspaceCommandError("Move only the projects currently shown in Manual order.") }
            decision.reorderProjects(order)
        case .client(.addProjectWithThread(let project, let thread)):
            guard project.clone == nil, thread.projectID == project.id, thread.workspacePath == project.path,
                  !decision.snapshot.projects.contains(where: { $0.id == project.id || $0.path == project.path }) else {
                throw WorkspaceCommandError("This project is already open, or its first conversation uses another workspace.")
            }
            decision.snapshot.projects.append(project)
            decision = try Self.make(.client(.createThread(thread)), id: id, snapshot: decision.snapshot, now: now)
        case .client(.startProjectClone(var project, let thread)):
            guard let submitted = project.clone else { throw WorkspaceCommandError("Choose a repository to clone.") }
            do { try submitted.plan.validate() } catch { throw WorkspaceCommandError(error.localizedDescription) }
            guard submitted.plan.destinationPath == project.path, thread.projectID == project.id, thread.workspacePath == project.path,
                  !decision.snapshot.projects.contains(where: { $0.id == project.id || $0.path == project.path }),
                  !decision.snapshot.cloneAttemptIDs.contains(submitted.plan.id) else { throw WorkspaceCommandError("This project or clone destination is already in use.") }
            project.clone = .init(plan: submitted.plan, now: now)
            decision.snapshot.projects.append(project)
            decision = try Self.make(.client(.createThread(thread)), id: id, snapshot: decision.snapshot, now: now)
            decision.effects.append(.init(id: submitted.plan.id, request: .projectClone(projectID: project.id, plan: submitted.plan)))
        case .client(.cancelProjectClone(let projectID)):
            guard let i = decision.snapshot.projects.firstIndex(where: { $0.id == projectID }), var clone = decision.snapshot.projects[i].clone else { throw WorkspaceCommandError("This project has no clone to cancel.") }
            if clone.isRunning, !clone.cancelRequested {
                clone.cancelRequested = true; clone.updatedAt = now; decision.snapshot.projects[i].clone = clone
                decision.cancelCloneAttempt = clone.id
                for j in decision.snapshot.threads.indices where decision.snapshot.threads[j].projectID == projectID { decision.snapshot.threads[j].queuePaused = true }
            }
        case .client(.retryProjectClone(let projectID, let plan)):
            do { try plan.validate() } catch { throw WorkspaceCommandError(error.localizedDescription) }
            guard let i = decision.snapshot.projects.firstIndex(where: { $0.id == projectID }), let old = decision.snapshot.projects[i].clone,
                  old.canRetry, old.plan.source == plan.source, old.plan.destinationPath == plan.destinationPath,
                  !decision.snapshot.cloneAttemptIDs.contains(plan.id) else { throw WorkspaceCommandError("This clone cannot be retried now. Refresh its status first.") }
            decision.snapshot.projects[i].clone = .init(plan: plan, now: now, previousPlans: old.previousPlans + [old.plan])
            decision.effects.append(.init(id: plan.id, request: .projectClone(projectID: projectID, plan: plan)))
        case .client(.saveACPAgent(let agent)):
            do { try agent.validate() } catch { throw WorkspaceCommandError(error.localizedDescription) }
            if let i = decision.snapshot.acpAgents.firstIndex(where: { $0.id == agent.id }) { decision.snapshot.acpAgents[i] = agent }
            else { decision.snapshot.acpAgents.append(agent) }
        case .client(.removeACPAgent(let id)): decision.snapshot.acpAgents.removeAll { $0.id == id }
        case .client(.addProject(let project)):
            guard project.clone == nil else { throw WorkspaceCommandError("Use Clone Repository to create a cloning project.") }
            if decision.snapshot.projects.contains(where: { $0.path == project.path }) { return decision }
            guard !decision.snapshot.projects.contains(where: { $0.id == project.id }) else { throw WorkspaceCommandError("This project identity is already in use.") }
            decision.snapshot.projects.append(project)
        case .client(.createThread(let thread)):
            guard decision.snapshot.projects.contains(where: { $0.id == thread.projectID }), !decision.snapshot.threads.contains(where: { $0.id == thread.id }),
                  thread.messages.isEmpty, !thread.isBusy, thread.queuedTurns.isEmpty else { throw WorkspaceCommandError("A new conversation needs an existing project and a unique identity.") }
            guard decision.snapshot.workspaceReady(for: thread) || decision.snapshot.projects.first(where: { $0.id == thread.projectID })?.path == thread.workspacePath else { throw WorkspaceCommandError("Wait for the clone before choosing another workspace.") }
            if thread.provider == .acp {
                guard let agent = thread.acpAgent, decision.snapshot.acpAgents.contains(agent) else { throw WorkspaceCommandError("Choose a saved ACP agent for this conversation.") }
            }
            var thread = thread; thread.runtimeID = nil; thread.runtimeRequests = []; thread.providerActivity = nil
            decision.snapshot.threads.insert(thread, at: 0)
        case .client(let action):
            guard let threadID = action.threadID, let index = decision.snapshot.threads.firstIndex(where: { $0.id == threadID }) else { throw WorkspaceCommandError("This conversation no longer exists.") }
            var thread = decision.snapshot.threads[index]
            switch action {
            case .editThread(_, let edit):
                switch edit {
                case .title(let title):
                    let title = title.trimmingCharacters(in: .whitespacesAndNewlines)
                    guard !title.isEmpty else { throw WorkspaceCommandError("A conversation title cannot be empty.") }; thread.title = title
                case .model(let model): thread.model = model
                case .permission(let mode): thread.permission = mode
                case .agentMode(let mode): thread.agentModeID = mode
                case .agentConfig(let id, let value):
                    guard thread.provider == .acp else { throw WorkspaceCommandError("Choose an ACP agent first.") }
                    var values = thread.agentConfigValues ?? [:]; values[id] = value; thread.agentConfigValues = values.isEmpty ? nil : values
                case .agentConfiguration(let id, let value):
                    guard thread.provider == .acp else { throw WorkspaceCommandError("Choose an ACP agent first.") }
                    if let value { guard value.string != nil || value == .bool(true) || value == .bool(false) else { throw WorkspaceCommandError("Choose a supported agent configuration value.") } }
                    var values = thread.agentConfiguration ?? [:]; values[id] = value; thread.agentConfiguration = values.isEmpty ? nil : values
                    thread.agentConfigValues?.removeValue(forKey: id)
                case .resetAgentOptions:
                    guard thread.provider == .acp else { throw WorkspaceCommandError("Choose an ACP agent first.") }
                    thread.agentConfigValues = nil; thread.agentConfiguration = nil; thread.agentModeID = nil; thread.model = ""
                case .provider(let kind):
                    guard kind != .acp else { throw WorkspaceCommandError("Choose a configured ACP agent.") }
                    guard !thread.isBusy, thread.messages.isEmpty, thread.queuedTurns.isEmpty else { throw WorkspaceCommandError("Start a new conversation to change providers.") }
                    decision.closeRuntimes.insert(thread.id); thread.provider = kind; thread.acpAgent = nil; thread.agentModeID = nil; thread.agentConfigValues = nil; thread.agentConfiguration = nil; thread.providerMetadata = nil; thread.providerActivity = nil; thread.runtimeRequests = []; thread.model = ""; thread.providerThreadID = nil; thread.runtimeID = nil
                case .acpAgent(let agent):
                    guard !thread.isBusy, thread.messages.isEmpty, thread.queuedTurns.isEmpty else { throw WorkspaceCommandError("Start a new conversation to change agents.") }
                    guard decision.snapshot.acpAgents.contains(agent) else { throw WorkspaceCommandError("Save this agent in Settings first.") }
                    decision.closeRuntimes.insert(thread.id); thread.provider = .acp; thread.acpAgent = agent; thread.agentModeID = nil; thread.agentConfigValues = nil; thread.providerMetadata = nil
                    thread.model = ""; thread.providerThreadID = nil; thread.runtimeID = nil
                    thread.agentConfiguration = nil; thread.providerActivity = nil; thread.runtimeRequests = []
                case .draft(let value): thread.draft = value
                case .pinned(let value): thread.isPinned = value
                case .archived(let value):
                    guard !thread.isBusy else { throw WorkspaceCommandError("Stop the running turn before archiving this conversation.") }
                    thread.isArchived = value
                    if value { thread.queuePaused = true; decision.closeRuntimes.insert(thread.id); thread.runtimeID = nil; thread.runtimeRequests = []; thread.providerActivity = nil }
                case .workspacePath(let path):
                    guard !thread.isBusy, thread.messages.isEmpty, thread.queuedTurns.isEmpty else { throw WorkspaceCommandError("Change the workspace before sending the first message.") }
                    guard decision.snapshot.workspaceReady(for: thread) else { throw WorkspaceCommandError("Wait for the clone before changing workspaces.") }
                    thread.workspacePath = path; decision.closeRuntimes.insert(thread.id); thread.runtimeID = nil; thread.runtimeRequests = []; thread.providerActivity = nil; thread.providerMetadata = nil
                }
            case .submit(_, let text):
                let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
                guard (!text.isEmpty || !thread.draftAttachments.isEmpty), !thread.isArchived else { throw WorkspaceCommandError("Enter a message or attach a file in an active conversation.") }
                guard text.utf16.count <= 120_000 else { throw WorkspaceCommandError("Messages can contain up to 120,000 characters. Shorten the draft or attach it as a file.") }
                let queued = QueuedTurn(id: id, text: text, configuration: .init(thread: thread), createdAt: now,
                                        attachments: thread.draftAttachments.isEmpty ? nil : thread.draftAttachments)
                thread.draft = ""; thread.draftAttachments = []
                if thread.isBusy || !decision.snapshot.workspaceReady(for: thread) {
                    if thread.queuedTurns.isEmpty, !thread.isBusy { thread.queuePaused = false }
                    thread.queuedTurns.append(queued)
                }
                else {
                    if thread.queuedTurns.isEmpty { thread.queuePaused = false }
                    decision.start(queued, in: &thread, now: now)
                }
            case .interrupt:
                thread.queuePaused = true
                if var run = thread.activeRun, !run.stopRequested {
                    run.stopRequested = true; thread.activeRun = run
                    decision.effects.append(.init(id: id, request: .providerInterrupt(threadID: thread.id, runID: run.id)))
                }
            case .respond(_, let requestID, let response):
                guard let i = thread.runtimeRequests.firstIndex(where: { $0.id == requestID }), !thread.runtimeRequests[i].responding else {
                    throw WorkspaceCommandError("This provider request is no longer awaiting a response.")
                }
                let sessionScoped = thread.runtimeRequests[i].sessionScoped == true
                guard sessionScoped ? thread.runtimeID != nil : (thread.activeRun != nil && thread.activeRun?.stopRequested == false) else { throw WorkspaceCommandError("This provider request is no longer awaiting a response.") }
                let request = thread.runtimeRequests[i].request
                switch response {
                case .option(let id):
                    guard request.method == "session/request_permission", (request.params["options"].array ?? []).contains(where: { $0["optionId"].string == id }) else {
                        throw WorkspaceCommandError("This permission option is no longer available.")
                    }
                case .decision: guard !request.isQuestion else { throw WorkspaceCommandError("Answer this question before continuing.") }
                case .answers(let answers):
                    guard request.isQuestion, request.questions.allSatisfy({ !(answers[$0["id"].string ?? ""] ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }) else { throw WorkspaceCommandError("Answer every required question.") }
                }
                thread.runtimeRequests[i].responding = true
                if sessionScoped, let runtimeID = thread.runtimeID {
                    decision.effects.append(.init(id: id, request: .providerSessionRespond(threadID: thread.id, runtimeID: runtimeID, request: request, response: response)))
                } else if let run = thread.activeRun {
                    decision.effects.append(.init(id: id, request: .providerRespond(threadID: thread.id, runID: run.id, request: request, response: response)))
                }
            case .removeQueued(_, let queuedID): thread.queuedTurns.removeAll { $0.id == queuedID }
            case .editQueued(_, let queuedID):
                guard thread.draft.isEmpty, thread.draftAttachments.isEmpty, let item = thread.queuedTurns.first(where: { $0.id == queuedID }) else { throw WorkspaceCommandError("Clear the composer before editing a queued message.") }
                thread.draft = item.text; thread.draftAttachments = item.attachments ?? []; thread.queuedTurns.removeAll { $0.id == queuedID }
            case .resumeQueue:
                guard !thread.isBusy, !thread.isArchived else { throw WorkspaceCommandError("Wait for the current turn before resuming the queue.") }
                thread.queuePaused = false; decision.startNext(in: &thread, now: now)
            case .addAttachments(_, let attachments):
                guard !thread.isArchived else { throw WorkspaceCommandError("Restore this conversation before attaching files.") }
                do { try AttachmentLimits.validate(thread.draftAttachments + attachments) }
                catch { throw WorkspaceCommandError(error.localizedDescription) }
                thread.draftAttachments += attachments
            case .removeAttachment(_, let attachmentID): thread.draftAttachments.removeAll { $0.id == attachmentID }
            case .addProject, .addProjectWithThread, .renameProject, .removeProject, .setProjectExpanded, .setProjectSortMode, .moveProject, .reorderProjects, .createThread, .saveACPAgent, .removeACPAgent, .startProjectClone, .cancelProjectClone, .retryProjectClone: break
            }
            if thread != decision.snapshot.threads[index] {
                if case .editThread(_, .draft) = action {} else { thread.updatedAt = now }
            }
            decision.snapshot.threads[index] = thread
        case .runtimeOpened(let threadID, let runID, let runtimeID):
            if let i = decision.snapshot.threads.firstIndex(where: { $0.id == threadID }), decision.snapshot.threads[i].activeRun?.id == runID {
                decision.snapshot.threads[i].runtimeID = runtimeID
            }
        case .provider(let threadID, let runtimeID, let event):
            do { try decision.receive(event, threadID: threadID, runtimeID: runtimeID, now: now) }
            catch let error as CoincideError {
                try decision.receive(.failure(error.localizedDescription), threadID: threadID, runtimeID: runtimeID, now: now)
            }
        case .effectResult(let request, let result):
            decision.finished(request, result: result, now: now)
        case .pauseQueues:
            for i in decision.snapshot.threads.indices where !decision.snapshot.threads[i].queuedTurns.isEmpty { decision.snapshot.threads[i].queuePaused = true }
        case .cloneStarted(let projectID, let attemptID):
            if let i = decision.snapshot.projects.firstIndex(where: { $0.id == projectID }), var clone = decision.snapshot.projects[i].clone,
               clone.id == attemptID, clone.isRunning, !clone.cancelRequested {
                clone.phase = .running; clone.updatedAt = now; decision.snapshot.projects[i].clone = clone
            }
        case .cloneProgress(let projectID, let attemptID, var progress):
            if let i = decision.snapshot.projects.firstIndex(where: { $0.id == projectID }), var clone = decision.snapshot.projects[i].clone,
               clone.id == attemptID, clone.isRunning, !clone.cancelRequested {
                progress.percent = progress.percent.map { min(100, max(0, $0)) }
                progress.detail = progress.detail.map { String(GitService.redactURLs($0).prefix(500)) }
                clone.progress = progress; clone.updatedAt = now; decision.snapshot.projects[i].clone = clone
            }
        }
        try WorkspaceJournal.validate(decision.snapshot)
        return decision
    }
    private func validateProjectOrder(_ expected: [UUID]) throws {
        guard snapshot.effectiveSidebarPreferences.sortMode == .manual else { throw WorkspaceCommandError("Choose Manual sorting before moving projects.") }
        guard snapshot.projects.map(\.id) == expected else { throw WorkspaceCommandError("The project order changed. Try moving the project again.") }
    }
    private mutating func reorderProjects(_ order: [UUID]) {
        let projects = Dictionary(uniqueKeysWithValues: snapshot.projects.map { ($0.id, $0) })
        snapshot.projects = order.compactMap { projects[$0] }
    }

    private mutating func start(_ queued: QueuedTurn, in thread: inout CodingThread, now: Date) {
        var configuration = queued.configuration; configuration.nativeThreadID = thread.providerThreadID
        thread.activeRun = ActiveRun(id: queued.id, configuration: configuration, startedAt: now)
        if thread.messages.isEmpty { thread.title = queued.text.isEmpty ? (queued.attachments?.first?.name ?? "Attachments") : String(queued.text.prefix(80)) }
        var message = ChatMessage(id: "user-\(queued.id.uuidString)", role: .user, text: queued.text, attachments: queued.attachments); message.createdAt = queued.createdAt
        thread.messages.append(message); thread.state = .running; thread.runtimeRequests.removeAll { $0.sessionScoped != true }
        effects.append(.init(id: queued.id, request: .providerStart(threadID: thread.id, runID: queued.id, configuration: configuration, prompt: queued.text, attachments: queued.attachments)))
    }
    private mutating func startNext(in thread: inout CodingThread, now: Date) {
        guard snapshot.workspaceReady(for: thread), !thread.isBusy, !thread.queuePaused, !thread.isArchived, !thread.queuedTurns.isEmpty else { return }
        let queued = thread.queuedTurns.removeFirst(); start(queued, in: &thread, now: now)
    }
    private mutating func receive(_ event: ProviderEvent, threadID: UUID, runtimeID: UUID, now: Date) throws {
        guard let index = snapshot.threads.firstIndex(where: { $0.id == threadID }), snapshot.threads[index].runtimeID == runtimeID else { return }
        var thread = snapshot.threads[index]
        if case .context(let runID, let inner) = event {
            guard thread.activeRun?.id == runID else { return }
            try receive(inner, threadID: threadID, runtimeID: runtimeID, now: now); return
        }
        switch event {
        case .submissionFailed(let id, let reason):
            if let i = thread.messages.firstIndex(where: { $0.id == id && $0.role == .user }) { thread.messages[i].submissionError = reason; thread.queuePaused = true }
        case .activity(let activity):
            thread.providerActivity = activity
            if activity.state != .idle {
                if thread.activeRun == nil { thread.activeRun = .init(id: activity.id, configuration: .init(thread: thread), startedAt: now) }
                thread.activeRun?.nativeTurnID = activity.id.uuidString
                thread.state = activity.state == .requiresAction ? .awaitingApproval : .running
            } else if activity.finishesRun, let run = thread.activeRun, run.nativeTurnID == activity.id.uuidString {
                let reason = activity.stopReason?.string
                thread.activeRun = nil; thread.runtimeRequests.removeAll { $0.sessionScoped != true }
                if run.stopRequested || reason == "cancelled" { thread.state = .interrupted }
                else if reason == "error" {
                    thread.state = .failed
                    thread.messages.append(.init(role: .system, text: activity.error?["message"].string ?? "The agent stopped because of an error."))
                } else { thread.state = .idle }
                let normalCompletion = ["end_turn", "max_tokens", "max_turn_requests", "refusal"].contains(reason ?? "")
                if thread.state == .idle, normalCompletion, reason != "end_turn" {
                    thread.messages.append(.init(role: .system, text: "The agent stopped: \((reason ?? "").replacingOccurrences(of: "_", with: " "))."))
                }
                if thread.state != .idle || !normalCompletion { thread.queuePaused = true }
                else { startNext(in: &thread, now: now) }
            }
        case .sessionApproval(let request):
            if !thread.runtimeRequests.contains(where: { $0.id == request.id }) { thread.runtimeRequests.append(.init(request: request, sessionScoped: true)) }
        case .sessionApprovalDismissed(let id): thread.runtimeRequests.removeAll { $0.id == id && $0.sessionScoped == true }
        case .entity(let update):
            if let i = thread.messages.firstIndex(where: { $0.providerEntity?.key == update.key }) {
                let entity = try update.apply(to: thread.messages[i].providerEntity)
                thread.messages[i].providerEntity = entity
                if thread.messages[i].role != .user || !thread.messages[i].id.hasPrefix("user-") { thread.messages[i].text = entity.text }
            } else {
                let entity = try update.apply(to: nil)
                var message = ChatMessage(id: entity.key.messageID, role: entity.role, text: entity.text)
                message.createdAt = now; message.providerEntity = entity; thread.messages.append(message)
            }
        case .associateEntity(let key, let clientID):
            guard key.type == "user_message", let target = thread.messages.firstIndex(where: { $0.id == clientID && $0.role == .user }) else { return }
            guard thread.messages[target].providerEntity == nil || thread.messages[target].providerEntity?.key == key else { throw CoincideError("The agent changed an accepted message identity.") }
            let echoed = thread.messages.firstIndex(where: { $0.providerEntity?.key == key })
            let entity = echoed.flatMap { thread.messages[$0].providerEntity } ?? ProviderEntity(key: key)
            thread.messages[target].providerEntity = entity
            if let echoed, echoed != target { thread.messages.remove(at: echoed) }
        case .configuration(let metadata): thread.providerMetadata = metadata
        case .thread(let native): thread.providerThreadID = native
        case .turn(let native): thread.activeRun?.nativeTurnID = native // A late acknowledgement never changes idle to running.
        case .delta(let itemID, let role, let text):
            guard thread.activeRun != nil else { return }
            if let i = thread.messages.firstIndex(where: { $0.id == itemID }) { thread.messages[i].text += text }
            else { thread.messages.append(.init(id: itemID, role: role, text: text)) }
        case .message(let message):
            guard thread.activeRun != nil else { return }
            if let i = thread.messages.firstIndex(where: { $0.id == message.id }) { thread.messages[i] = message }
            else { thread.messages.append(message) }
        case .approval(let request):
            guard thread.activeRun != nil, thread.activeRun?.stopRequested == false else { return }
            if !thread.runtimeRequests.contains(where: { $0.id == request.id }) { thread.runtimeRequests.append(.init(request: request)) }
            thread.state = .awaitingApproval
        case .approvalDismissed(let id):
            thread.runtimeRequests.removeAll { $0.id == id }
            if thread.activeRun != nil { thread.state = thread.runtimeRequests.isEmpty ? .running : .awaitingApproval }
        case .completed(let state):
            guard thread.activeRun != nil else { return }
            let stopped = thread.activeRun?.stopRequested == true
            thread.activeRun = nil; thread.runtimeRequests = []; thread.state = stopped ? .interrupted : state
            if stopped || state != .idle { thread.queuePaused = true }
            else { startNext(in: &thread, now: now) }
        case .failure(let message), .connectionClosed(let message):
            closeRuntimes.insert(thread.id); thread.runtimeID = nil
            thread.providerActivity = nil
            if thread.activeRun != nil {
                thread.state = thread.activeRun?.stopRequested == true ? .interrupted : .failed
                thread.messages.append(.init(role: .system, text: message))
            }
            thread.activeRun = nil; thread.runtimeRequests = []; thread.queuePaused = true
        case .context: break
        }
        if thread != snapshot.threads[index] { thread.updatedAt = now }
        snapshot.threads[index] = thread
    }
    private mutating func finished(_ request: WorkspaceEffectRequest, result: EffectResult, now: Date) {
        if case .projectClone(let projectID, let plan) = request {
            guard let i = snapshot.projects.firstIndex(where: { $0.id == projectID }), var clone = snapshot.projects[i].clone,
                  clone.id == plan.id, !clone.isReady else { return }
            switch result {
            case .succeeded:
                clone.phase = .completed; clone.error = nil; clone.progress = .init(stage: .checkout, percent: 100, detail: nil, stalled: false)
            case .failed(let message): clone.phase = .failed; clone.error = String(GitService.redactURLs(message).prefix(4_000))
            case .cancelled, .stopped:
                clone.phase = clone.cancelRequested ? .cancelled : .interrupted; clone.error = nil
            }
            clone.cancelRequested = false; clone.progress.stalled = false; clone.updatedAt = now; clone.endedAt = now
            snapshot.projects[i].clone = clone
            if clone.isReady {
                for index in snapshot.threads.indices where snapshot.threads[index].projectID == projectID {
                    var thread = snapshot.threads[index]; startNext(in: &thread, now: now); snapshot.threads[index] = thread
                }
            }
            return
        }
        guard let index = snapshot.threads.firstIndex(where: { $0.id == request.threadID }) else { return }
        var thread = snapshot.threads[index]
        switch request {
        case .projectClone: break // Project-owned effects are handled before thread lookup.
        case .providerSessionRespond(_, let runtimeID, let request, _):
            guard thread.runtimeID == runtimeID, let i = thread.runtimeRequests.firstIndex(where: { $0.id == request.id && $0.sessionScoped == true }) else { return }
            if case .succeeded = result { thread.runtimeRequests.remove(at: i) }
            else {
                thread.runtimeRequests[i].responding = false
                if case .failed(let message) = result { thread.messages.append(.init(role: .system, text: message)) }
            }
        case .providerStart(_, let runID, _, _, _):
            guard thread.activeRun?.id == runID else { return }
            if case .failed(let message) = result {
                thread.state = thread.activeRun?.stopRequested == true ? .interrupted : .failed
                thread.activeRun = nil; thread.runtimeRequests = []; thread.providerActivity = nil; thread.queuePaused = true
                thread.messages.append(.init(role: .system, text: message)); closeRuntimes.insert(thread.id); thread.runtimeID = nil
            }
        case .providerInterrupt(_, let runID):
            guard thread.activeRun?.id == runID else { return }
            guard case .stopped = result else { return }
            thread.activeRun = nil; thread.runtimeRequests = []; thread.state = .interrupted; thread.queuePaused = true
            thread.runtimeID = nil; closeRuntimes.insert(thread.id)
            thread.providerActivity = nil
        case .providerRespond(_, let runID, let request, _):
            guard thread.activeRun?.id == runID, let i = thread.runtimeRequests.firstIndex(where: { $0.id == request.id }) else { return }
            if case .succeeded = result { thread.runtimeRequests.remove(at: i) }
            else {
                thread.runtimeRequests[i].responding = false
                if case .failed(let message) = result { thread.messages.append(.init(role: .system, text: message)) }
            }
            thread.state = thread.runtimeRequests.isEmpty ? .running : .awaitingApproval
        }
        if thread != snapshot.threads[index] { thread.updatedAt = now }
        snapshot.threads[index] = thread
    }
}

private extension WorkspaceCommand {
    var threadID: UUID? {
        switch self {
        case .addProject, .addProjectWithThread, .renameProject, .removeProject, .setProjectExpanded, .setProjectSortMode, .moveProject, .reorderProjects, .createThread, .saveACPAgent, .removeACPAgent, .startProjectClone, .cancelProjectClone, .retryProjectClone: nil
        case .editThread(let id, _), .submit(let id, _), .interrupt(let id), .respond(let id, _, _), .removeQueued(let id, _), .editQueued(let id, _), .resumeQueue(let id), .addAttachments(let id, _), .removeAttachment(let id, _): id
        }
    }
}
