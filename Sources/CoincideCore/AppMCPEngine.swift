import Foundation

extension WorkspaceEngine {
    /// Invoked under the Engine's scoped TaskLocal authority. Every mutation
    /// still passes through the real command queue; this facade never writes a
    /// projection or journal directly and never sends through a provider actor.
    func performAppMCP(_ action: AppMCPAction, context: AppMCPContext) async throws -> JSONValue {
        let view = try await appMCPView(context)
        try Task.checkCancellation()
        switch action {
        case .scheduledTask(let request): return try await performScheduledTaskMCP(request, context: context)
        case .delegateTask(let request): return try await appMCPDelegate(request, context: context, view: view)
        case .delegatedTaskStatus(let id):
            let status = try await delegatedTaskStatus(parentThreadID: context.scope.threadID, taskID: id, acknowledge: true)
            _ = try await appMCPView(context)
            return try appMCPTaskResult(status)
        case .cancelDelegatedTask(let taskID, let reason, let key):
            guard let runID = context.runID else { throw AppMCPError(.staleCaller) }
            let commandID = TaskOrchestration.derivedID(runID, "cancel-task:" + context.scope.threadID.uuidString + ":" + taskID.uuidString + ":" + (key ?? UUID().uuidString))
            _ = try await cancelDelegatedTask(parentThreadID: context.scope.threadID, taskID: taskID, reason: reason, commandID: commandID)
            _ = try await appMCPView(context)
            let status = try await delegatedTaskStatus(parentThreadID: context.scope.threadID, taskID: taskID, acknowledge: false)
            return .object(["taskId": appMCPID(taskID), "childThreadId": appMCPID(status.task.childThreadID), "status": .string(status.task.status.rawValue)])
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
            return try await appMCPTransfer(sourceID: threadID, point: .run(runID), parentID: nil, title: title, context: context)
        case .forkContext(let threadID, let point, let title):
            return try await appMCPTransfer(sourceID: threadID, point: point, parentID: nil, title: title, context: context)
        case .mergeContext(let sourceID, let targetID, let point):
            return try await appMCPTransfer(sourceID: sourceID, point: point, parentID: targetID, title: nil, context: context)
        }
    }

    private func appMCPDelegate(_ input: AppMCPDelegation, context: AppMCPContext, view: AppMCPView) async throws -> JSONValue {
        guard let runID = context.runID else { throw AppMCPError(.staleCaller) }
        let parent = try appMCPThread(context.scope.threadID, in: view)
        let key = input.clientRequestID ?? UUID().uuidString
        let commandID = TaskOrchestration.derivedID(runID, "delegate-task:" + parent.id.uuidString + ":" + key)
        // The wait budget changes observation, not the accepted child intent.
        let canonical = AppMCPDelegation(task: input.task, title: input.title, target: input.target, permission: input.permission,
            role: input.role, isolation: input.isolation, mode: input.mode, timeoutMilliseconds: 0, clientRequestID: input.clientRequestID)
        let digest = try ContextTransferProtocol.digest(canonical)
        let acceptance: DelegatedTaskAcceptance
        if let old = view.snapshot.delegatedTasks?.first(where: { $0.commandID == commandID }) {
            guard old.parentThreadID == parent.id, old.parentRunID == runID, old.request.appMCPRequestDigest == digest else { throw AppMCPError(.invalidRequest) }
            acceptance = try await createDelegatedTask(old.request, commandID: commandID)
        } else {
            let selected = try await appMCPTaskConfiguration(input.target, permission: input.permission, context: context, view: view)
            _ = try await appMCPView(context)
            let request = DelegatedTaskRequest(parentThreadID: parent.id, parentRunID: runID,
                expectedConfiguration: .init(thread: parent), configuration: selected.configuration,
                task: input.task, title: input.title, role: input.role, isolation: input.isolation, mode: input.mode,
                clientRequestID: input.clientRequestID, configurationSourceThreadID: selected.sourceThreadID,
                expectedConfigurationSource: selected.sourceConfiguration, appMCPRequestDigest: digest)
            acceptance = try await createDelegatedTask(request, commandID: commandID)
        }
        let status: DelegatedTaskStatusSnapshot
        if input.mode == .wait {
            status = try await waitForDelegatedTask(parentThreadID: parent.id, taskID: acceptance.taskID, timeoutMilliseconds: input.timeoutMilliseconds)
        } else {
            status = try await delegatedTaskStatus(parentThreadID: parent.id, taskID: acceptance.taskID, acknowledge: true)
        }
        _ = try await appMCPView(context)
        return try appMCPTaskResult(status)
    }

    private struct AppMCPTaskConfiguration {
        let configuration: ProviderConfiguration
        let sourceThreadID: UUID?
        let sourceConfiguration: ProviderConfiguration?
    }
    private func appMCPTaskConfiguration(_ selection: AppMCPModelSelection?, permission: PermissionMode?,
                                       context: AppMCPContext, view: AppMCPView) async throws -> AppMCPTaskConfiguration {
        let parent = try appMCPThread(context.scope.threadID, in: view)
        let candidates = [parent] + view.snapshot.threads.filter { $0.id != parent.id && !$0.isArchived }
        var instances: [UUID: CodingThread] = [:]
        for candidate in candidates {
            guard let id = try? AppMCPAdmission.instanceID(configuration: .init(thread: candidate)), instances[id] == nil else { continue }
            instances[id] = candidate
        }
        let source: CodingThread
        if let id = selection?.instanceID {
            guard let selected = instances[id], selection?.provider == nil || selected.provider == selection?.provider else { throw AppMCPError(.notFound) }
            source = selected
        } else if let provider = selection?.provider, provider != context.configuration.provider {
            let matches = instances.values.filter { $0.provider == provider }
            guard matches.count == 1, let selected = matches.first else { throw AppMCPError(.invalidRequest) }; source = selected
        } else { source = parent }
        let sameInstance = try AppMCPAdmission.instanceID(configuration: .init(thread: source)) == context.scope.providerInstanceID && source.provider == context.configuration.provider
        let base = sameInstance ? context.configuration : ProviderConfiguration(thread: source)
        var selected = source
        selected.applyContextConfiguration(base)
        let requestedModel = selection?.model ?? base.model
        let inherits = sameInstance && requestedModel == context.configuration.model
        var options = inherits ? try appMCPTaskOptions(context.configuration) : [:]
        if let overrides = selection?.options {
            if overrides.isEmpty { options = [:] }
            else { for (id, value) in overrides { options[id] = value } }
        }
        if selection?.model != nil || selection?.options != nil || !sameInstance {
            let catalog = sameInstance
                ? try await appMCPCapturedTaskModels(thread: selected, context: context)
                : try await models(thread: source)
            _ = try await appMCPView(context)
            let model: ProviderModel
            if let explicit = selection?.model {
                let matches = AppMCPProviderModelOptions.rows(catalog, id: explicit, provider: selected.provider)
                guard matches.count == 1, let row = matches.first else { throw AppMCPError(.invalidRequest) }; model = row
            } else if sameInstance, let current = catalog.first(where: { AppMCPProviderModelOptions.matches($0, id: base.model, provider: selected.provider) }) { model = current }
            else if let current = catalog.first(where: \.isDefault) ?? catalog.first(where: { AppMCPProviderModelOptions.matches($0, id: base.model, provider: selected.provider) }) { model = current }
            else { throw AppMCPError(.unavailable) }
            if !inherits { selected.reasoningEffort = nil; selected.codexReasoningPreferences = nil }
            switch selected.provider {
            case .codex:
                let tier = try AppMCPProviderModelOptions.codexTier(options, model: model, configuration: .init(thread: selected))
                try selected.selectCodexModel(model)
                if let value = options["reasoningEffort"] {
                    guard let effort = value.string, model.reasoningEfforts.contains(where: { $0.id == effort }) else { throw AppMCPError(.invalidRequest) }
                    try selected.selectCodexReasoning(model: model, effort: effort)
                } else { selected.reasoningEffort = nil }
                try selected.selectCodexServiceTier(model: model, tier: tier)
                var speedOptions = options; speedOptions.removeValue(forKey: "reasoningEffort")
                if !speedOptions.isEmpty {
                    if selected.agentConfiguration == nil { selected.agentConfiguration = [:] }
                    selected.agentConfiguration?[CodexServiceTier.configurationKey] = .object(speedOptions)
                }
            case .claude:
                let controls = try AppMCPProviderModelOptions.claude(options, model: model)
                if !AppMCPProviderModelOptions.matches(model, id: selected.model, provider: .claude) { selected.model = model.id }
                try selected.selectClaudeModelOptions(controls, model: model)
            }
        }
        selected.permission = permission ?? context.configuration.permission
        guard AppMCPAdmission.permits(selected.permission, ceiling: context.configuration.permission),
              AppMCPAdmission.permits(selected.permission, ceiling: parent.permission),
              let project = view.snapshot.projects.first(where: { $0.id == parent.projectID }) else { throw AppMCPError(.permissionDenied) }
        let child = try appMCPNewThread(project: project, workspacePath: parent.workspacePath, configuration: .init(thread: selected), date: Date())
        return .init(configuration: .init(thread: child), sourceThreadID: sameInstance ? nil : source.id,
            sourceConfiguration: sameInstance ? nil : .init(thread: source))
    }

    private func appMCPTaskOptions(_ configuration: ProviderConfiguration) throws -> [String: JSONValue] {
        try AppMCPProviderModelOptions.captured(configuration)
    }
    private func appMCPTaskResult(_ value: DelegatedTaskStatusSnapshot) throws -> JSONValue {
        let task = value.task, original = task.result, latest = task.latestTerminalResult
        func preview(_ result: DelegatedTaskResult?) -> JSONValue {
            guard let result else { return .null }; return .string(taskResultPrefix(result.summary, maximumBytes: 32_768))
        }
        let options = try appMCPTaskOptions(task.request.configuration).sorted { $0.key < $1.key }.map { JSONValue.object(["id": .string($0.key), "value": $0.value]) }
        let pending = value.pendingApproval.map { request in JSONValue.object(["requestId": request.id,
            "kind": .string("approval"), "runId": appMCPID(value.pendingApprovalRunID ?? task.childRunID)]) } ?? .null
        return .object(["taskId": appMCPID(task.id), "childThreadId": appMCPID(task.childThreadID), "childRunId": appMCPID(task.childRunID),
            "childNodeId": appMCPID(task.id), "status": .string(task.status.rawValue),
            "workState": .string(task.workState == .working ? "working" : task.workState == .waitingForChildren ? "waiting_for_children" : "result_available"),
            "hasPendingChildRuns": .bool(value.hasPendingChildRuns), "providerInstanceId": appMCPID(try AppMCPAdmission.instanceID(configuration: task.request.configuration)),
            "model": task.request.configuration.model.isEmpty ? .null : .string(task.request.configuration.model), "options": .array(options),
            "summary": preview(original), "summaryTruncated": .bool(original.map { $0.summary.utf8.count > 32_768 || $0.truncated == true } ?? false),
            "summaryTotalBytes": original.map { .number(Double($0.summary.utf8.count)) } ?? .null,
            "resultContextTransferId": original.map { appMCPID($0.contextTransferID) } ?? .null,
            "latestTerminalRunId": latest.map { appMCPID($0.runID) } ?? .null,
            "latestTerminalStatus": latest.map { .string($0.status.rawValue) } ?? .null,
            "latestTerminalSummary": latest?.summary == original?.summary ? .null : preview(latest),
            "latestTerminalResultContextTransferId": latest?.contextTransferID == original?.contextTransferID ? .null : latest.map { appMCPID($0.contextTransferID) } ?? .null,
            "hasPendingQuestion": .bool(!value.pendingQuestions.isEmpty), "pendingApproval": pending, "waitTimedOut": .bool(value.waitTimedOut)])
    }
    private func taskResultPrefix(_ text: String, maximumBytes: Int) -> String {
        let bytes = Data(text.utf8); guard bytes.count > maximumBytes else { return text }
        var end = maximumBytes
        while end > 0, bytes[end] & 0xc0 == 0x80 { end -= 1 }
        return String(decoding: bytes.prefix(end), as: UTF8.self)
    }

    private func appMCPTransfer(sourceID: UUID, point: ContextTransferSourcePoint, parentID: UUID?, title: String?, context: AppMCPContext) async throws -> JSONValue {
        let view = try await appMCPView(context), source = try appMCPThread(sourceID, in: view)
        let caller = try appMCPThread(context.scope.threadID, in: view)
        let sourceConfiguration = ProviderConfiguration(thread: source)
        var destination = sourceConfiguration; destination.nativeThreadID = nil
        destination.claudeLaunchSelection = nil
        let intent: ContextTransferIntent
        if let parentID {
            let parent = try appMCPThread(parentID, in: view)
            guard source.contextTransferLineage?.parentThreadID == parent.id, source.projectID == parent.projectID else { throw AppMCPError(.invalidRequest) }
            destination = .init(thread: parent); intent = .mergeBack(targetConfiguration: destination)
        } else { intent = .fork(destination: destination) }
        guard [sourceConfiguration.permission, destination.permission].allSatisfy({
            AppMCPAdmission.permits($0, ceiling: context.configuration.permission) && AppMCPAdmission.permits($0, ceiling: caller.permission)
        }) else { throw AppMCPError(.permissionDenied) }
        let review = try await reviewContextTransfer(request: .init(sourceThreadID: source.id,
            expectedConfiguration: sourceConfiguration, sourcePoint: point, intent: intent))
        do {
            _ = try await appMCPView(context)
            let receipt = try await acceptContextTransfer(reviewID: review.id, digest: review.digest, title: title, commandID: UUID())
            guard receipt.rejection == nil else { throw AppMCPError(.unavailable) }
            return .object(["sequence": .number(Double(receipt.sequence)), "transferId": appMCPID(review.id),
                "targetThreadId": appMCPID(review.targetThreadID), "status": .string("accepted")])
        } catch { await discardContextTransferReview(id: review.id, digest: review.digest); throw error }
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
            var constraints = ["delegate_task can use this registered launch profile. Thread creation and configuration use the caller's captured instance.",
                "Child permissions cannot exceed the captured or current parent permission. Independent task briefs do not copy parent history.",
                "Worktree isolation requires a verified local project repository and pins the parent's local HEAD; dirty edits are not copied."]
            let models: [ProviderModel]
            do { models = try await self.models(thread: thread) }
            catch { try Task.checkCancellation(); models = []; constraints.append("The model catalog is currently unavailable.") }
            _ = try await appMCPView(context)
            let matching = models.filter { row in search.map { row.id.localizedCaseInsensitiveContains($0) || row.name.localizedCaseInsensitiveContains($0) } ?? true }
            let bounded = matching.prefix(search == nil ? 12 : 50)
            let rows = bounded.map { row -> JSONValue in
                var value: [String: JSONValue] = ["id": .string(row.catalogID ?? row.id)]
                if row.name != row.id { value["label"] = .string(row.name) }
                let options = AppMCPProviderModelOptions.descriptors(row, configuration: .init(thread: thread))
                if !options.isEmpty { value["options"] = .array(options) }
                return .object(value)
            }
            providers.append(.object(["providerInstanceId": appMCPID(instance), "driverKind": .string(thread.provider.rawValue), "displayName": .string(thread.providerName),
                "models": .array(rows), "omittedModels": .number(Double(max(0, matching.count - rows.count))), "canRunChildTask": .bool(true),
                "canRunCrossProviderChildTask": .bool(true), "constraints": .array(constraints.map(JSONValue.string))]))
        }
        return .object(["parentThreadId": appMCPID(caller.id), "inheritedProviderInstanceId": appMCPID(context.scope.providerInstanceID), "inheritedModel": .string(context.configuration.model),
            "permission": .string(context.configuration.permission.rawValue), "providers": .array(providers), "unsupportedCapabilities": .array(AppMCPTools.unsupportedCapabilities.map(JSONValue.string)),
            "features": .object(["appOwnedSubagents": .bool(true), "asyncPolling": .bool(true), "cancellation": .bool(true), "batchThreadCreation": .bool(true),
                "threadManagement": .bool(true), "incrementalThreadRead": .bool(true), "scheduledTasks": .bool(true), "scheduledTaskPolicy": .object(["minimumIntervalMs": .number(60_000), "hostTimeZone": .string(TimeZone.current.identifier),
                    "boundCurrentThread": .bool(true), "freshThreads": .bool(true), "fullAccessWritesRequired": .bool(true),
                    "webhookCredentialSetup": .string("native-settings"), "listenerScope": .string("explicit-loopback-only"), "managedRelay": .bool(false)]), "maxBatchThreads": .number(20)])])
    }

    private func appMCPCreateThreads(_ requests: [AppMCPThreadCreation], key: String?, context: AppMCPContext, view: AppMCPView) async throws -> JSONValue {
        guard (1...20).contains(requests.count), let runID = context.runID else { throw AppMCPError(.invalidRequest) }
        let parent = try appMCPThread(context.scope.threadID, in: view)
        guard parent.scratchWorkspace == nil else { throw AppMCPError(.unsupported) }
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
        if request.scratch { return try await appMCPScratchLaunch(request, context: context, view: view) }
        if view.snapshot.projects.first(where: { $0.id == request.projectID })?.scratch != nil {
            if case .existingWorktree = request.workspace { throw AppMCPError(.unsupported) }
            // The pinned launcher normalizes worktree requests for Scratch:
            // every ordinary launch gets its own actual non-Git folder.
            return try await appMCPScratchLaunch(.init(scratch: true, creation: request.creation), context: context, view: view)
        }
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

    private func appMCPScratchLaunch(_ request: AppMCPThreadLaunch, context: AppMCPContext, view: AppMCPView) async throws -> JSONValue {
        guard request.projectID == nil, request.workspace == .root else { throw AppMCPError(.invalidRequest) }
        let parent = try appMCPThread(context.scope.threadID, in: view), commandID = UUID(), threadID = UUID()
        let allocation = try await prepareScratchWorkspace(commandID: commandID, threadID: threadID,
            namingText: request.creation.prompt ?? request.creation.title ?? "")
        _ = try await appMCPView(context)
        var thread = try appMCPNewThread(project: allocation.project, workspacePath: allocation.workspacePath,
            configuration: context.configuration, date: allocation.receipt.createdAt)
        thread.id = threadID; thread.scratchWorkspace = allocation.receipt; thread.checkpointPolicy = .disabled
        thread.title = request.creation.title ?? "New thread"; thread.permission = request.creation.permission ?? context.configuration.permission
        guard let runID = context.runID else { throw AppMCPError(.staleCaller) }
        thread.createdByAppMCP = .init(sessionID: context.scope.sessionID, threadID: parent.id, runID: runID)
        var edits: [ThreadEdit] = []
        if let selection = request.creation.target {
            for command in try await appMCPSelection(selection, thread: thread, context: context, inherited: parent) {
                guard case .editThread(let id, let edit) = command, id == threadID else { throw AppMCPError(.invalidRequest) }
                edits.append(edit)
            }
        }
        _ = try await appMCPView(context)
        let creation = ScratchThreadCreation(allocation: allocation, thread: thread, prompt: request.creation.prompt,
            selectsConversation: false, modelEdits: edits)
        let receipt = try await createScratchThread(creation, commandID: commandID)
        guard receipt.rejection == nil, let created = current().snapshot.threads.first(where: { $0.id == threadID }) else { throw AppMCPError(.unavailable) }
        return .object(["threadId": appMCPID(created.id), "projectId": appMCPID(created.projectID),
            "runId": created.activeRun.map { appMCPID($0.id) } ?? .null, "status": .string(created.state.rawValue),
            "sequence": .number(Double(receipt.sequence))])
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
        let matches = AppMCPProviderModelOptions.rows(catalog, id: requested, provider: thread.provider)
        guard matches.count == 1, let model = matches.first else { throw AppMCPError(.invalidRequest) }
        var result: [WorkspaceCommand] = []
        func edit(_ value: ThreadEdit) { result.append(.editThread(thread.id, value)) }
        let options = selection.options
        switch thread.provider {
        case .codex:
            edit(.codexModel(model))
            if let options {
                let inherited = AppMCPProviderModelOptions.matches(model, id: thread.model, provider: .codex) ? try appMCPTaskOptions(.init(thread: thread)) : [:]
                let merged = AppMCPProviderModelOptions.merged(inherited, overrides: options)
                let tier = try AppMCPProviderModelOptions.codexTier(merged, model: model, configuration: .init(thread: thread))
                let effort = merged["reasoningEffort"]?.string
                guard merged["reasoningEffort"] == nil || effort != nil,
                      effort == nil || model.reasoningEfforts.contains(where: { $0.id == effort }) else { throw AppMCPError(.invalidRequest) }
                if !model.reasoningEfforts.isEmpty { edit(.codexReasoning(model: model, effort: effort)) }
                edit(.codexServiceTier(model: model, tier: tier))
            } else if !AppMCPProviderModelOptions.matches(model, id: thread.model, provider: .codex) {
                edit(.codexServiceTier(model: model, tier: nil))
            }
        case .claude:
            let sameModel = AppMCPProviderModelOptions.matches(model, id: thread.model, provider: .claude)
            if !sameModel || requested != thread.model { edit(.claudeModel(model)) }
            if options != nil || sameModel {
                let inherited = sameModel ? try appMCPTaskOptions(.init(thread: thread)) : [:]
                let merged = AppMCPProviderModelOptions.merged(inherited, overrides: options)
                edit(.claudeModelOptions(model: model, options: try AppMCPProviderModelOptions.claude(merged, model: model)))
            }
        }
        return result
    }

    private func appMCPNewThread(project: WorkspaceProject, workspacePath: String, configuration: ProviderConfiguration, date: Date) throws -> CodingThread {
        var thread = CodingThread(project: project, model: configuration.model)
        thread.workspacePath = workspacePath; thread.provider = configuration.provider; thread.permission = configuration.permission
        thread.reasoningEffort = configuration.reasoningEffort; thread.codexRuntimeConfiguration = configuration.codexRuntimeConfiguration
        thread.claudeRuntimeConfiguration = try configuration.claudeRuntimeConfiguration?.replacingWorkspace(workspacePath)
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
}
