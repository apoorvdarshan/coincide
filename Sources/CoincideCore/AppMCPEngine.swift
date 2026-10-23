import Foundation

extension WorkspaceEngine {
    /// Invoked under the Engine's scoped TaskLocal authority. Every mutation
    /// still passes through the real command queue; this facade never writes a
    /// projection or journal directly and never sends through a provider actor.
    func performAppMCP(_ action: AppMCPAction, context: AppMCPContext) async throws -> JSONValue {
        let view = try await appMCPView(context)
        try Task.checkCancellation()
        switch action {
        case .capabilities(let search): return try await appMCPCapabilities(search: search, context: context, view: view)
        case .wait(let threadID, let runID, let timeout): return try await appMCPWait(threadID: threadID, runID: runID, timeout: timeout, context: context)
        case .createThreads(let requests, let key): return try await appMCPCreateThreads(requests, key: key, context: context, view: view)
        case .launchThread(let request): return try await appMCPLaunch(request, context: context, view: view)
        case .createProject(let request):
            // No unmanaged directory creation or Git subprocess may precede a
            // durable allocator. This batch registers existing directories only.
            guard let path = request.workspaceRoot, !request.createWorkspaceRootIfMissing else { throw AppMCPError(.unsupported) }
            var directory: ObjCBool = false
            guard FileManager.default.fileExists(atPath: path, isDirectory: &directory), directory.boolValue else { throw AppMCPError(.notFound) }
            var project = WorkspaceProject(path: path); project.name = request.title
            let receipt = try await appMCPDispatch([.addProject(project)], context: context)
            return .object(["id": appMCPID(project.id), "title": .string(project.name), "workspaceRoot": .string(project.path), "sequence": .number(Double(receipt.sequence))])
        case .updateProject(let projectID, let title):
            let receipt = try await appMCPDispatch([.renameProject(projectID: projectID, title: title)], context: context)
            return appMCPReceipt(receipt)
        case .deleteProject(let projectID, let force):
            guard view.snapshot.projects.contains(where: { $0.id == projectID }) else { throw AppMCPError(.notFound) }
            let threads = view.snapshot.threads.filter { $0.projectID == projectID }.map(\.id)
            guard force || threads.isEmpty else { throw AppMCPError(.invalidRequest) }
            let receipt = try await appMCPDispatch([.removeProject(projectID: projectID, expectedThreadIDs: threads)], context: context)
            return appMCPReceipt(receipt)
        case .renameThread(let threadID, let title, let key):
            let id = try appMCPRequestID(key, action: "rename-thread:\(threadID)", context: context)
            let receipt = try await appMCPDispatch([.editThread(threadID, .title(title))], context: context, id: id)
            return .object(["threadId": appMCPID(threadID), "title": .string(title), "sequence": .number(Double(receipt.sequence))])
        case .organizeThread(let threadID, let operation):
            let thread = try appMCPThread(threadID, in: view)
            let receipt: WorkspaceCommandReceipt
            switch operation {
            case .pin, .unpin: receipt = try await appMCPDispatch([.editThread(threadID, .pinned(operation == .pin))], context: context)
            case .archive, .unarchive: receipt = try await appMCPDispatch([.editThread(threadID, .archived(operation == .archive))], context: context)
            case .settle:
                // Immediate settlement cannot impersonate T3's deferred own-run
                // successful-completion intent. Refuse that variant honestly.
                guard threadID != context.scope.threadID, !thread.isBusy else { throw AppMCPError(.unsupported) }
                receipt = try await settleThread(threadID: threadID, expectedWorkspacePath: thread.workspacePath)
            case .unsettle:
                guard let settlement = thread.settlement else { throw AppMCPError(.invalidRequest) }
                receipt = try await resumeThread(threadID: threadID, generationID: settlement.id)
            }
            return appMCPReceipt(receipt)
        case .configureThread(let threadID, let selection):
            let thread = try appMCPThread(threadID, in: view)
            let commands = try await appMCPSelection(selection, thread: thread, context: context)
            let receipt = try await appMCPDispatch(commands, context: context, expectedTargets: [threadID: ProviderConfiguration(thread: thread)])
            return appMCPReceipt(receipt)
        case .send(let threadID, let message, let mode, let key):
            let thread = try appMCPThread(threadID, in: view)
            guard mode != .restart else { throw AppMCPError(.unsupported) }
            let receipt: WorkspaceCommandReceipt
            if mode == .steer {
                // No repeatable steering operation is synthesized from a retry
                // key until its native operation/input IDs are durably reserved.
                guard key == nil, let run = thread.activeRun else { throw AppMCPError(.unsupported) }
                let accepted = try await steerAppMCPPrompt(threadID: threadID, text: message, expectedRunID: run.id)
                receipt = accepted.receipt
                let snapshot = current().snapshot
                guard let operation = snapshot.promptSteerings?.first(where: { $0.id == accepted.operationID && $0.threadID == threadID && $0.runID == run.id && $0.preservesComposer == true }) else { throw AppMCPError(.unavailable) }
                return .object(["threadId": appMCPID(threadID), "runId": appMCPID(operation.runID), "messageId": .string(operation.messageID),
                    "operationId": appMCPID(operation.id), "delivery": .string("steered"), "sequence": .number(Double(receipt.sequence)), "status": .string(operation.phase.rawValue)])
            }
            let id = try appMCPRequestID(key, action: "send:\(threadID):\(mode.rawValue)", context: context)
            receipt = try await appMCPDispatch([.submitFromAppMCP(threadID: threadID, text: message, queueEvenWhenIdle: mode == .queue)], context: context, id: id)
            let current = try appMCPThread(threadID, in: .init(snapshot: self.current().snapshot, sequence: receipt.sequence))
            let inputID = receipt.commandID
            let queued = current.queuedTurns.first { $0.id == inputID }
            let record = current.runHistory?.first { $0.id == inputID }
            guard queued != nil || record != nil else { throw AppMCPError(.unavailable) }
            return .object(["threadId": appMCPID(threadID), "runId": appMCPID(inputID), "messageId": .string(record?.userMessageID ?? "user-\(inputID.uuidString)"),
                "delivery": .string(queued == nil ? "started" : "queued"), "status": .string(record?.status.rawValue ?? "queued"), "sequence": .number(Double(receipt.sequence))])
        case .interrupt(let threadID, let runID, _):
            let thread = try appMCPThread(threadID, in: view)
            guard let active = thread.activeRun, runID == nil || runID == active.id else { throw AppMCPError(.notFound) }
            let receipt = try await appMCPDispatch([.interruptFromAppMCP(threadID: threadID, expectedRunID: active.id, expectedRuntimeID: thread.runtimeID)], context: context)
            return .object(["threadId": appMCPID(threadID), "runId": appMCPID(active.id), "sequence": .number(Double(receipt.sequence)), "status": .string("stop_requested")])
        case .editQueued(let threadID, let queuedID, let text):
            guard let queued = try appMCPThread(threadID, in: view).queuedTurns.first(where: { $0.id == queuedID }) else { throw AppMCPError(.notFound) }
            guard queued.existingMessageID == nil else { throw AppMCPError(.unsupported) }
            let receipt = try await appMCPDispatch([.replaceQueuedText(threadID: threadID, queuedID: queuedID, expectedText: queued.text, text: text)], context: context)
            return appMCPReceipt(receipt)
        case .cancelQueued(let threadID, let queuedID):
            guard try appMCPThread(threadID, in: view).queuedTurns.contains(where: { $0.id == queuedID }) else { throw AppMCPError(.notFound) }
            return appMCPReceipt(try await appMCPDispatch([.removeQueued(threadID: threadID, queuedID: queuedID)], context: context))
        case .reorderQueued(let threadID, let queuedID, let beforeID):
            let thread = try appMCPThread(threadID, in: view)
            guard queuedID != beforeID, thread.queuedTurns.contains(where: { $0.id == queuedID }),
                  beforeID == nil || thread.queuedTurns.contains(where: { $0.id == beforeID }) else { throw AppMCPError(.notFound) }
            return appMCPReceipt(try await appMCPDispatch([.moveQueued(threadID: threadID, queuedID: queuedID, beforeID: beforeID, expectedOrder: thread.queuedTurns.map(\.id))], context: context))
        case .promoteQueued(let threadID, let queuedID, let targetRunID):
            let thread = try appMCPThread(threadID, in: view)
            guard thread.activeRun?.id == targetRunID, thread.queuedTurns.contains(where: { $0.id == queuedID }) else { throw AppMCPError(.notFound) }
            return appMCPReceipt(try await steerPrompt(threadID: threadID, text: "", expectedRunID: targetRunID, queuedID: queuedID))
        case .answerQuestion(let threadID, let requestID, let answers):
            let thread = try appMCPThread(threadID, in: view)
            guard let pending = thread.runtimeRequests.first(where: { $0.id == requestID && $0.request.isQuestion && !$0.responding }) else { throw AppMCPError(.notFound) }
            return appMCPReceipt(try await appMCPAnswerQuestion(threadID: threadID, request: pending.request,
                expectedRuntimeID: thread.runtimeID, expectedRunID: thread.activeRun?.id, answers: answers, context: context))
        case .forkThread(let threadID, let runID, let title):
            _ = try appMCPThread(threadID, in: view)
            let review = try await reviewConversationHistory(threadID: threadID, runID: runID, kind: .forkAfterRun)
            do {
                _ = try await appMCPView(context)
                let receipt = try await beginConversationHistory(review, title: title)
                return .object(["sequence": .number(Double(receipt.sequence)), "operationId": appMCPID(review.id),
                    "targetThreadId": review.targetThreadID.map(appMCPID) ?? .null, "status": .string("accepted")])
            } catch { await discardConversationHistoryReview(reviewID: review.id); throw error }
        }
    }

    private func appMCPWait(threadID: UUID, runID requestedRun: UUID?, timeout: Int, context: AppMCPContext) async throws -> JSONValue {
        guard (0...600_000).contains(timeout) else { throw AppMCPError(.invalidRequest) }
        let first = try appMCPThread(threadID, in: await appMCPView(context))
        let target = requestedRun ?? first.activeRun?.id ?? first.runHistory?.last?.id
        let deadline = ContinuousClock.now + .milliseconds(timeout)
        while true {
            let thread = try appMCPThread(threadID, in: await appMCPView(context))
            let record = target.flatMap { id in thread.runHistory?.first { $0.id == id } }
            if requestedRun != nil, record == nil, thread.activeRun?.id != requestedRun { throw AppMCPError(.notFound) }
            let finished = target == nil || record?.status.isTerminal == true || !thread.runtimeRequests.isEmpty
            let expired = ContinuousClock.now >= deadline
            if finished || expired {
                return .object(["threadId": appMCPID(threadID), "runId": target.map(appMCPID) ?? .null,
                    "status": .string(record?.status.rawValue ?? thread.state.rawValue), "timedOut": .bool(!finished && expired)])
            }
            try await Task.sleep(for: .milliseconds(50))
        }
    }

    private func appMCPCapabilities(search: String?, context: AppMCPContext, view: AppMCPView) async throws -> JSONValue {
        var seen = Set<UUID>(), providers: [JSONValue] = []
        let caller = try appMCPThread(context.scope.threadID, in: view)
        let candidates = [caller] + view.snapshot.threads.filter { $0.id != caller.id && !$0.isArchived }
        for thread in candidates {
            guard providers.count < 32, let instance = try? AppMCPAdmission.instanceID(configuration: .init(thread: thread)), seen.insert(instance).inserted else { continue }
            var constraints = ["Creation and configuration support the caller's captured provider instance only. Other catalogs are read-only discovery."]
            let models: [ProviderModel]
            do { models = try await self.models(thread: thread) }
            catch { try Task.checkCancellation(); models = []; constraints.append("The model catalog is currently unavailable.") }
            _ = try await appMCPView(context)
            let matching = models.filter { row in search.map { row.id.localizedCaseInsensitiveContains($0) || row.name.localizedCaseInsensitiveContains($0) } ?? true }
            let bounded = matching.prefix(search == nil ? 12 : 50)
            let rows = bounded.map { row -> JSONValue in
                var value: [String: JSONValue] = ["id": .string(row.catalogID ?? row.id)]
                if row.name != row.id { value["label"] = .string(row.name) }
                let options = appMCPModelOptions(row, provider: thread.provider)
                if !options.isEmpty { value["options"] = .array(options) }
                return .object(value)
            }
            providers.append(.object(["providerInstanceId": appMCPID(instance), "driverKind": .string(thread.provider.rawValue), "displayName": .string(thread.providerName),
                "models": .array(rows), "omittedModels": .number(Double(max(0, matching.count - rows.count))), "canRunChildTask": .bool(false),
                "canRunCrossProviderChildTask": .bool(false), "constraints": .array(constraints.map(JSONValue.string))]))
        }
        return .object(["parentThreadId": appMCPID(caller.id), "inheritedProviderInstanceId": appMCPID(context.scope.providerInstanceID), "inheritedModel": .string(context.configuration.model),
            "permission": .string(context.configuration.permission.rawValue), "providers": .array(providers), "unsupportedCapabilities": .array(AppMCPTools.unsupportedCapabilities.map(JSONValue.string)),
            "features": .object(["appOwnedSubagents": .bool(false), "asyncPolling": .bool(true), "cancellation": .bool(true), "batchThreadCreation": .bool(true),
                "threadManagement": .bool(true), "incrementalThreadRead": .bool(true), "scheduledTasks": .bool(false), "maxBatchThreads": .number(20)])])
    }

    private func appMCPCreateThreads(_ requests: [AppMCPThreadCreation], key: String?, context: AppMCPContext, view: AppMCPView) async throws -> JSONValue {
        guard (1...20).contains(requests.count), let runID = context.runID else { throw AppMCPError(.invalidRequest) }
        let parent = try appMCPThread(context.scope.threadID, in: view)
        let date = parent.runHistory?.first(where: { $0.id == runID })?.startedAt ?? parent.activeRun?.startedAt
        guard let date, let project = view.snapshot.projects.first(where: { $0.id == parent.projectID }) else { throw AppMCPError(.notFound) }
        let requestKey = key ?? UUID().uuidString
        let commandID = try AppMCPAdmission.commandID(sessionID: context.scope.sessionID, clientRequestID: requestKey, action: "create-threads")
        var commands: [WorkspaceCommand] = [], ids: [UUID] = []
        for (index, request) in requests.enumerated() {
            let threadID = try AppMCPAdmission.commandID(sessionID: context.scope.sessionID, clientRequestID: requestKey, action: "created-thread-\(index)")
            var thread = try appMCPNewThread(project: project, workspacePath: parent.workspacePath, configuration: context.configuration, date: date)
            thread.id = threadID; thread.title = request.title ?? "New thread"; thread.permission = request.permission ?? context.configuration.permission
            thread.checkpointPolicy = parent.checkpointPolicy
            thread.createdByAppMCP = .init(sessionID: context.scope.sessionID, threadID: parent.id, runID: runID)
            commands.append(.createThread(thread)); ids.append(threadID)
            if let selection = request.target { commands += try await appMCPSelection(selection, thread: thread, context: context, inherited: parent) }
            if let prompt = request.prompt { commands.append(.submitFromAppMCP(threadID: threadID, text: prompt, queueEvenWhenIdle: false)) }
        }
        let receipt = try await appMCPDispatch(commands, context: context, id: commandID)
        let snapshot = current().snapshot
        return .object(["threads": .array(ids.compactMap { id in snapshot.threads.first(where: { $0.id == id }).map(appMCPCreatedThread) }), "sequence": .number(Double(receipt.sequence))])
    }

    private func appMCPLaunch(_ request: AppMCPThreadLaunch, context: AppMCPContext, view: AppMCPView) async throws -> JSONValue {
        guard let project = view.snapshot.projects.first(where: { $0.id == request.projectID }) else { throw AppMCPError(.notFound) }
        let parent = try appMCPThread(context.scope.threadID, in: view)
        var thread = try appMCPNewThread(project: project, workspacePath: project.path, configuration: context.configuration, date: Date())
        thread.title = request.creation.title ?? "New thread"; thread.permission = request.creation.permission ?? context.configuration.permission
        thread.checkpointPolicy = parent.checkpointPolicy
        var commands: [WorkspaceCommand] = [.createThread(thread)]
        if let selection = request.creation.target { commands += try await appMCPSelection(selection, thread: thread, context: context, inherited: parent) }
        if case .root = request.workspace {
            if let message = request.creation.prompt { commands.append(.submitFromAppMCP(threadID: thread.id, text: message, queueEvenWhenIdle: false)) }
            let receipt = try await appMCPDispatch(commands, context: context)
            let snapshot = current().snapshot
            guard let created = snapshot.threads.first(where: { $0.id == thread.id }) else { throw AppMCPError(.unavailable) }
            return .object(["threadId": appMCPID(created.id), "projectId": appMCPID(project.id), "runId": created.activeRun.map { appMCPID($0.id) } ?? .null,
                "status": .string(created.state.rawValue), "sequence": .number(Double(receipt.sequence))])
        }
        let selection: GitWorktreeSelection
        switch request.workspace {
        case .root: throw AppMCPError(.invalidRequest)
        case .worktree(let base, let branch, let remote):
            guard !remote else { throw AppMCPError(.unsupported) }
            selection = .createBranch(name: branch, baseRef: base)
        case .existingWorktree(let path, _): selection = .reuse(path: path)
        }
        // Registration is a distinct observed fact if later preparation fails.
        // No first prompt is admitted until the native worktree gate exists.
        _ = try await appMCPDispatch(commands, context: context)
        let preparation = try await beginWorktreePreparation(threadID: thread.id, selection: selection)
        if let message = request.creation.prompt { _ = try await appMCPDispatch([.submitFromAppMCP(threadID: thread.id, text: message, queueEvenWhenIdle: false)], context: context) }
        return .object(["threadId": appMCPID(thread.id), "projectId": appMCPID(project.id), "runId": .null, "status": .string("preparing"), "sequence": .number(Double(preparation.sequence))])
    }

    private func appMCPSelection(_ selection: AppMCPModelSelection, thread: CodingThread, context: AppMCPContext, inherited: CodingThread? = nil) async throws -> [WorkspaceCommand] {
        let source = inherited ?? thread
        let instance = try AppMCPAdmission.instanceID(configuration: .init(thread: source))
        guard selection.instanceID == nil || selection.instanceID == instance,
              selection.provider == nil || selection.provider == source.provider,
              source.provider == thread.provider else { throw AppMCPError(.unsupported) }
        guard selection.model != nil || selection.options != nil else { return [] }
        let requested = selection.model ?? thread.model
        guard !requested.isEmpty else { throw AppMCPError(.unsupported) }
        let catalog = try await models(thread: source)
        _ = try await appMCPView(context)
        let matches = catalog.filter { $0.id == requested || $0.catalogID == requested }
        guard matches.count == 1, let model = matches.first else { throw AppMCPError(.invalidRequest) }
        var result: [WorkspaceCommand] = []
        func edit(_ value: ThreadEdit) { result.append(.editThread(thread.id, value)) }
        let options = selection.options
        switch thread.provider {
        case .codex:
            guard options?.keys.allSatisfy({ $0 == "reasoningEffort" }) ?? true else { throw AppMCPError(.unsupported) }
            edit(.codexModel(model))
            if let options {
                let effort = options["reasoningEffort"]?.string
                guard options.isEmpty || effort != nil, effort == nil || model.reasoningEfforts.contains(where: { $0.id == effort }) else { throw AppMCPError(.invalidRequest) }
                edit(.codexReasoning(model: model, effort: effort))
            }
        case .pi:
            guard options?.keys.allSatisfy({ $0 == "thinkingLevel" }) ?? true else { throw AppMCPError(.unsupported) }
            edit(.piModel(model))
            if let options {
                let level = options["thinkingLevel"]?.string
                guard options.isEmpty || level != nil, level == nil || model.piThinkingLevels?.contains(level!) == true else { throw AppMCPError(.invalidRequest) }
                edit(.piThinking(model: model, level: level))
            }
        case .opencode:
            guard options?.keys.allSatisfy({ $0 == "variant" }) ?? true else { throw AppMCPError(.unsupported) }
            edit(.openCodeModel(model))
            if let options {
                let variant = options["variant"]?.string
                guard options.isEmpty || variant != nil, variant == nil || model.openCodeVariants?.contains(variant!) == true else { throw AppMCPError(.invalidRequest) }
                edit(.openCodeVariant(model: model, variant: variant))
            }
        case .muse:
            guard options?.keys.allSatisfy({ $0 == "reasoningEffort" }) ?? true else { throw AppMCPError(.unsupported) }
            edit(.museModel(model))
            if let options {
                let effort = options["reasoningEffort"]?.string
                guard options.isEmpty || effort != nil, effort == nil || model.museReasoningEfforts?.contains(where: { $0.id == effort }) == true else { throw AppMCPError(.invalidRequest) }
                edit(.museReasoning(model: model, effort: effort))
            }
        default:
            guard options?.isEmpty != false else { throw AppMCPError(.unsupported) }
            edit(.model(model.id))
            if options != nil, thread.provider == .acp { edit(.resetAgentOptions) }
        }
        return result
    }

    private func appMCPNewThread(project: WorkspaceProject, workspacePath: String, configuration: ProviderConfiguration, date: Date) throws -> CodingThread {
        var thread = CodingThread(project: project, model: configuration.model)
        thread.workspacePath = workspacePath; thread.provider = configuration.provider; thread.permission = configuration.permission
        thread.reasoningEffort = configuration.reasoningEffort; thread.codexRuntimeConfiguration = configuration.codexRuntimeConfiguration
        thread.claudeRuntimeConfiguration = try configuration.claudeRuntimeConfiguration?.replacingWorkspace(workspacePath)
        thread.acpAgent = configuration.acpAgent; thread.openCodeConfiguration = configuration.openCodeConfiguration
        if let pi = configuration.piConfiguration {
            thread.piConfiguration = .init(instanceID: pi.instanceID, executable: pi.executable, model: pi.model, thinkingLevel: pi.thinkingLevel, runtime: try pi.runtime?.replacingWorkspace(workspacePath))
        }
        thread.museConfiguration = configuration.museConfiguration; thread.antigravityConfiguration = configuration.antigravityConfiguration
        thread.agentModeID = configuration.agentModeID; thread.agentConfigValues = configuration.agentConfigValues; thread.agentConfiguration = configuration.agentConfiguration
        thread.createdAt = date; thread.updatedAt = date
        return thread
    }
    private func appMCPThread(_ id: UUID, in view: AppMCPView) throws -> CodingThread {
        guard let thread = view.snapshot.threads.first(where: { $0.id == id }) else { throw AppMCPError(.notFound) }; return thread
    }
    private func appMCPRequestID(_ key: String?, action: String, context: AppMCPContext) throws -> UUID? {
        try key.map { try AppMCPAdmission.commandID(sessionID: context.scope.sessionID, clientRequestID: $0, action: action) }
    }
    private func appMCPID(_ id: UUID) -> JSONValue { .string(id.uuidString.lowercased()) }
    private func appMCPReceipt(_ receipt: WorkspaceCommandReceipt) -> JSONValue {
        .object(["commandId": appMCPID(receipt.commandID), "sequence": .number(Double(receipt.sequence)), "accepted": .bool(receipt.rejection == nil)])
    }
    private func appMCPCreatedThread(_ thread: CodingThread) -> JSONValue {
        .object(["threadId": appMCPID(thread.id), "title": .string(thread.title), "provider": .string(thread.provider.rawValue), "model": .string(thread.model),
            "runId": thread.activeRun.map { appMCPID($0.id) } ?? thread.queuedTurns.first.map { appMCPID($0.id) } ?? .null,
            "status": .string(thread.activeRun == nil && !thread.queuedTurns.isEmpty ? "queued" : thread.state.rawValue)])
    }
    private func appMCPModelOptions(_ model: ProviderModel, provider: ProviderKind) -> [JSONValue] {
        let values: [String], key: String, fallback: String?
        switch provider {
        case .codex: key = "reasoningEffort"; values = model.reasoningEfforts.map(\.id); fallback = model.defaultReasoningEffort
        case .pi: key = "thinkingLevel"; values = model.piThinkingLevels ?? []; fallback = nil
        case .opencode: key = "variant"; values = model.openCodeVariants ?? []; fallback = nil
        case .muse: key = "reasoningEffort"; values = (model.museReasoningEfforts ?? []).map(\.id); fallback = model.museDefaultReasoningEffort
        default: return []
        }
        guard !values.isEmpty else { return [] }
        var value: [String: JSONValue] = ["id": .string(key), "values": .array(values.map(JSONValue.string))]
        if let fallback { value["default"] = .string(fallback) }
        return [.object(value)]
    }
}
