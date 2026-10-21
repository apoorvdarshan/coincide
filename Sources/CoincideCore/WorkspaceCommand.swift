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
}

enum EngineCommand: Codable, Sendable {
    case client(WorkspaceCommand)
    case runtimeOpened(threadID: UUID, runID: UUID, runtimeID: UUID)
    case provider(threadID: UUID, runtimeID: UUID, event: ProviderEvent)
    case effectResult(WorkspaceEffectRequest, EffectResult)
    case pauseQueues
}
enum EffectResult: Codable, Sendable { case succeeded, failed(String), cancelled, stopped }

struct WorkspaceDecision: Sendable {
    var snapshot: WorkspaceSnapshot
    var effects: [PendingWorkspaceEffect] = []
    var closeRuntime: UUID?

    static func make(_ command: EngineCommand, id: UUID, snapshot: WorkspaceSnapshot, now: Date) throws -> Self {
        var decision = Self(snapshot: snapshot)
        switch command {
        case .client(.saveACPAgent(let agent)):
            do { try agent.validate() } catch { throw WorkspaceCommandError(error.localizedDescription) }
            if let i = decision.snapshot.acpAgents.firstIndex(where: { $0.id == agent.id }) { decision.snapshot.acpAgents[i] = agent }
            else { decision.snapshot.acpAgents.append(agent) }
        case .client(.removeACPAgent(let id)): decision.snapshot.acpAgents.removeAll { $0.id == id }
        case .client(.addProject(let project)):
            if decision.snapshot.projects.contains(where: { $0.path == project.path }) { return decision }
            guard !decision.snapshot.projects.contains(where: { $0.id == project.id }) else { throw WorkspaceCommandError("This project identity is already in use.") }
            decision.snapshot.projects.append(project)
        case .client(.createThread(let thread)):
            guard decision.snapshot.projects.contains(where: { $0.id == thread.projectID }), !decision.snapshot.threads.contains(where: { $0.id == thread.id }),
                  thread.messages.isEmpty, !thread.isBusy, thread.queuedTurns.isEmpty else { throw WorkspaceCommandError("A new conversation needs an existing project and a unique identity.") }
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
                    decision.closeRuntime = thread.id; thread.provider = kind; thread.acpAgent = nil; thread.agentModeID = nil; thread.agentConfigValues = nil; thread.agentConfiguration = nil; thread.providerMetadata = nil; thread.providerActivity = nil; thread.runtimeRequests = []; thread.model = ""; thread.providerThreadID = nil; thread.runtimeID = nil
                case .acpAgent(let agent):
                    guard !thread.isBusy, thread.messages.isEmpty, thread.queuedTurns.isEmpty else { throw WorkspaceCommandError("Start a new conversation to change agents.") }
                    guard decision.snapshot.acpAgents.contains(agent) else { throw WorkspaceCommandError("Save this agent in Settings first.") }
                    decision.closeRuntime = thread.id; thread.provider = .acp; thread.acpAgent = agent; thread.agentModeID = nil; thread.agentConfigValues = nil; thread.providerMetadata = nil
                    thread.model = ""; thread.providerThreadID = nil; thread.runtimeID = nil
                    thread.agentConfiguration = nil; thread.providerActivity = nil; thread.runtimeRequests = []
                case .draft(let value): thread.draft = value
                case .pinned(let value): thread.isPinned = value
                case .archived(let value):
                    guard !thread.isBusy else { throw WorkspaceCommandError("Stop the running turn before archiving this conversation.") }
                    thread.isArchived = value
                    if value { thread.queuePaused = true; decision.closeRuntime = thread.id; thread.runtimeID = nil; thread.runtimeRequests = []; thread.providerActivity = nil }
                case .workspacePath(let path):
                    guard !thread.isBusy, thread.messages.isEmpty, thread.queuedTurns.isEmpty else { throw WorkspaceCommandError("Change the workspace before sending the first message.") }
                    thread.workspacePath = path; decision.closeRuntime = thread.id; thread.runtimeID = nil; thread.runtimeRequests = []; thread.providerActivity = nil; thread.providerMetadata = nil
                }
            case .submit(_, let text):
                let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
                guard (!text.isEmpty || !thread.draftAttachments.isEmpty), !thread.isArchived else { throw WorkspaceCommandError("Enter a message or attach a file in an active conversation.") }
                guard text.utf16.count <= 120_000 else { throw WorkspaceCommandError("Messages can contain up to 120,000 characters. Shorten the draft or attach it as a file.") }
                let queued = QueuedTurn(id: id, text: text, configuration: .init(thread: thread), createdAt: now,
                                        attachments: thread.draftAttachments.isEmpty ? nil : thread.draftAttachments)
                thread.draft = ""; thread.draftAttachments = []
                if thread.isBusy { thread.queuedTurns.append(queued) }
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
            case .addProject, .createThread, .saveACPAgent, .removeACPAgent: break
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
        }
        try WorkspaceJournal.validate(decision.snapshot)
        return decision
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
        guard !thread.isBusy, !thread.queuePaused, !thread.isArchived, !thread.queuedTurns.isEmpty else { return }
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
            closeRuntime = thread.id; thread.runtimeID = nil
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
        guard let index = snapshot.threads.firstIndex(where: { $0.id == request.threadID }) else { return }
        var thread = snapshot.threads[index]
        switch request {
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
                thread.messages.append(.init(role: .system, text: message)); closeRuntime = thread.id; thread.runtimeID = nil
            }
        case .providerInterrupt(_, let runID):
            guard thread.activeRun?.id == runID else { return }
            guard case .stopped = result else { return }
            thread.activeRun = nil; thread.runtimeRequests = []; thread.state = .interrupted; thread.queuePaused = true
            thread.runtimeID = nil; closeRuntime = thread.id
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
        case .addProject, .createThread, .saveACPAgent, .removeACPAgent: nil
        case .editThread(let id, _), .submit(let id, _), .interrupt(let id), .respond(let id, _, _), .removeQueued(let id, _), .editQueued(let id, _), .resumeQueue(let id), .addAttachments(let id, _), .removeAttachment(let id, _): id
        }
    }
}
