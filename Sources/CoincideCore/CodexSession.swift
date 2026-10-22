import Foundation

/// Native stdio client for the same Codex app-server protocol used by T3 Code.
public actor CodexSession: ProviderSession {
    public nonisolated let events: AsyncStream<ProviderEvent>
    private let continuation: AsyncStream<ProviderEvent>.Continuation
    private let rpc: JSONRPCConnection
    private let processWorkspace: URL
    private var eventTask: Task<Void, Never>?
    private var threadID: String?
    private var turnID: String?
    private var completedTurnIDs: [String] = []
    private var sendGeneration = 0
    private var initialized = false
    private var connectionTask: Task<Void, Never>?
    private var connectionWaiters: [UUID: CheckedContinuation<Void, any Error>] = [:]
    private var serverUserAgent: String?
    private var historyMutationInFlight = false
    private var historyMutationUncertain = false
    private var working = false
    private var shuttingDown = false
    private var eventRunID: UUID?
    private var activeConfiguration: ProviderConfiguration?
    private var steeringTask: ProviderSteeringTask?

    public init(executable: URL, cwd: URL, arguments: [String] = ["app-server", "--stdio"]) throws {
        let (events, continuation) = AsyncStream<ProviderEvent>.makeStream()
        self.events = events; self.continuation = continuation
        processWorkspace = cwd
        rpc = try JSONRPCConnection(executable: executable, arguments: arguments, cwd: cwd, maximumFrameSize: 128 * 1_024 * 1_024)
    }
    public func connect() async throws {
        try Task.checkCancellation()
        guard !shuttingDown else { throw CancellationError() }
        guard !initialized else { return }
        let id = UUID()
        try await withTaskCancellationHandler {
            try Task.checkCancellation()
            try await withCheckedThrowingContinuation { (waiter: CheckedContinuation<Void, any Error>) in
                guard !Task.isCancelled else { waiter.resume(throwing: CancellationError()); return }
                connectionWaiters[id] = waiter
                if connectionTask == nil {
                    connectionTask = Task {
                        do { try await self.initializeConnection(); self.finishConnection(.success(())) }
                        catch { self.finishConnection(.failure(error)) }
                    }
                }
            }
            try Task.checkCancellation()
        } onCancel: { Task { await self.cancelConnectionWaiter(id) } }
    }
    private func cancelConnectionWaiter(_ id: UUID) { connectionWaiters.removeValue(forKey: id)?.resume(throwing: CancellationError()) }
    private func finishConnection(_ result: Result<Void, any Error>) {
        connectionTask = nil
        let waiters = connectionWaiters; connectionWaiters = [:]
        for waiter in waiters.values { waiter.resume(with: result) }
    }
    private func initializeConnection() async throws {
        let stream = rpc.events
        eventTask = Task { [weak self] in
            for await event in stream { await self?.consume(event) }
        }
        do {
            let response = try await rpc.request("initialize", params: .object([
                "clientInfo": .object(["name": .string("coincide"), "title": .string("Coincide"), "version": .string("0.1.0")]),
                "capabilities": .object(["experimentalApi": .bool(true)])
            ]))
            guard !shuttingDown else { throw CancellationError() }
            serverUserAgent = response["userAgent"].string
            try await rpc.notify("initialized"); initialized = true
        } catch {
            // A failed handshake cannot leave a consumer behind for a second
            // initialization attempt on this same transport.
            shuttingDown = true; await rpc.close(); eventTask?.cancel(); eventTask = nil; continuation.finish()
            throw error
        }
    }
    public func historyCapabilities(threadID: String) async throws -> ProviderHistoryCapabilities {
        try ProviderHistoryValidation.id(threadID); try await connectForHistory()
        return try await CodexHistoryClient(rpc: rpc, userAgent: serverUserAgent).capabilities(threadID: threadID)
    }
    public func conversationSnapshot(threadID: String) async throws -> ProviderConversationSnapshot {
        try ProviderHistoryValidation.id(threadID); try await connectForHistory()
        return try await CodexHistoryClient(rpc: rpc, userAgent: serverUserAgent).snapshot(threadID: threadID)
    }
    public func historyPage(threadID: String, cursor: String? = nil, limit: Int = 100) async throws -> ProviderHistoryPage {
        try ProviderHistoryValidation.id(threadID); try await connectForHistory()
        return try await CodexHistoryClient(rpc: rpc, userAgent: serverUserAgent).page(threadID: threadID, cursor: cursor, limit: limit)
    }
    public func forkConversation(source: ProviderConversationReference, boundary: ProviderHistoryBoundary, configuration: ProviderConfiguration) async throws -> ProviderConversationSnapshot {
        // A fork belongs to a fresh target actor. It must never retarget the source runtime.
        guard !historyMutationUncertain else { throw ProviderHistoryError(.outcomeUncertain) }
        guard threadID == nil, !working, !historyMutationInFlight else { throw ProviderHistoryError(.notIdle) }
        historyMutationInFlight = true; defer { historyMutationInFlight = false }
        try await connectForHistory()
        do {
            let result = try await CodexHistoryClient(rpc: rpc, userAgent: serverUserAgent).fork(source: source, boundary: boundary, configuration: configuration)
            try Task.checkCancellation(); guard !shuttingDown else { throw CancellationError() }
            sendGeneration += 1
            threadID = result.reference.nativeThreadID; turnID = nil; completedTurnIDs = []
            return result
        } catch {
            if error is CancellationError || (error as? ProviderHistoryError)?.kind == .outcomeUncertain { historyMutationUncertain = true }
            throw error
        }
    }
    public func revertConversation(thread: ProviderConversationReference, beforeTurnID: String, expectedHeadTurnID: String) async throws -> ProviderConversationSnapshot {
        guard !historyMutationUncertain else { throw ProviderHistoryError(.outcomeUncertain) }
        guard !working, !historyMutationInFlight, threadID == nil || threadID == thread.nativeThreadID else { throw ProviderHistoryError(.notIdle) }
        historyMutationInFlight = true; defer { historyMutationInFlight = false }
        try await connectForHistory()
        do {
            let result = try await CodexHistoryClient(rpc: rpc, userAgent: serverUserAgent).revert(thread: thread, beforeTurnID: beforeTurnID, expectedHeadTurnID: expectedHeadTurnID)
            try Task.checkCancellation(); guard !shuttingDown else { throw CancellationError() }
            // Old delayed notifications retain their old run scope until an explicit
            // next send installs a new one; rewind never turns them into idle events.
            sendGeneration += 1
            threadID = result.reference.nativeThreadID; turnID = nil; completedTurnIDs = []
            return result
        } catch {
            if error is CancellationError || (error as? ProviderHistoryError)?.kind == .outcomeUncertain { historyMutationUncertain = true }
            throw error
        }
    }
    public func models() async throws -> [ProviderModel] {
        try await readModelCatalog(deadline: ContinuousClock.now + .seconds(30))
    }
    private func readModelCatalog(deadline: ContinuousClock.Instant) async throws -> [ProviderModel] {
        do {
            try Task.checkCancellation()
            try await connect()
            var cursor: String?
            var seenCursors: Set<String> = []
            var entries: [String: CodexModelCatalogEntry] = [:]
            var catalogOwners: [String: String] = [:]
            var models: [ProviderModel] = []
            var bytes = 0, rows = 0
            for _ in 0..<20 {
                try Task.checkCancellation()
                guard !shuttingDown, ContinuousClock.now < deadline else { throw CodexModelCatalogEntry.failure() }
                var params: [String: JSONValue] = ["limit": .number(100), "includeHidden": .bool(false)]
                if let cursor { params["cursor"] = .string(cursor) }
                let response = try await rpc.request("model/list", params: .object(params), timeout: ContinuousClock.now.duration(to: deadline))
                try Task.checkCancellation()
                guard !shuttingDown, ContinuousClock.now < deadline,
                      response.object != nil, let page = response["data"].array, page.count <= 100 else { throw CodexModelCatalogEntry.failure() }
                bytes += try JSONEncoder().encode(response).count; rows += page.count
                guard bytes <= 8 * 1_024 * 1_024, rows <= 2_000 else { throw CodexModelCatalogEntry.failure() }
                for item in page {
                    let entry = try CodexModelCatalogEntry(item), model = entry.model
                    if let previous = entries[model.id] {
                        guard previous == entry else { throw CodexModelCatalogEntry.failure() }
                    } else {
                        entries[model.id] = entry
                        if let catalogID = model.catalogID {
                            guard catalogOwners[catalogID] == nil || catalogOwners[catalogID] == model.id else { throw CodexModelCatalogEntry.failure() }
                            catalogOwners[catalogID] = model.id
                        }
                        if !entry.hidden { models.append(model) }
                    }
                }
                guard let next = try CodexModelCatalogEntry.string(response["nextCursor"], maximum: 4_096) else { return models }
                guard seenCursors.insert(next).inserted else { throw CodexModelCatalogEntry.failure() }
                cursor = next
            }
            throw CodexModelCatalogEntry.failure()
        } catch {
            if error is CancellationError || Task.isCancelled { throw CancellationError() }
            throw CodexModelCatalogEntry.failure()
        }
    }
    public func codexDefaultModelSelection() async throws -> CodexDefaultModelSelection {
        let deadline = ContinuousClock.now + .seconds(30)
        do {
            try Task.checkCancellation()
            guard processWorkspace.isFileURL, processWorkspace.host == nil || processWorkspace.host == "" || processWorkspace.host == "localhost",
                  processWorkspace.query == nil, processWorkspace.fragment == nil else { throw CodexModelCatalogEntry.failure() }
            let workspacePath = processWorkspace.standardizedFileURL.resolvingSymlinksInPath().path
            try await connect()
            let initial = try await readDefaultModelConfig(workspacePath: workspacePath, deadline: deadline)
            let catalog = try await readModelCatalog(deadline: deadline)
            let selectedModel: String
            if let configured = initial.model { selectedModel = configured }
            else {
                // Codex 0.163's models manager marks its picker-visible default
                // before app-server publishes this catalog. Never replace an
                // explicit cwd-config model with this fallback.
                guard CodexHistoryClient(rpc: rpc, userAgent: serverUserAgent).hasReviewedProfile else {
                    throw CodexModelCatalogEntry.failure()
                }
                let defaults = catalog.filter(\.isDefault)
                guard defaults.count == 1, let model = defaults.first else { throw CodexModelCatalogEntry.failure() }
                selectedModel = model.id
            }
            let advertised = catalog.first { $0.id == selectedModel }
            guard advertised != nil || initial.effort != nil else { throw CodexModelCatalogEntry.failure() }
            let effort = initial.effort ?? advertised?.codexDefaultReasoningEffort
            let final = try await readDefaultModelConfig(workspacePath: workspacePath, deadline: deadline)
            guard initial.model == final.model, initial.effort == final.effort, initial.modelProvider == final.modelProvider, !shuttingDown,
                  ContinuousClock.now < deadline else { throw CodexModelCatalogEntry.failure() }
            try Task.checkCancellation()
            return try .init(workspacePath: workspacePath, model: selectedModel, reasoningEffort: effort, catalogModel: advertised)
        } catch {
            if error is CancellationError || Task.isCancelled { throw CancellationError() }
            throw CoincideError("The Codex CLI default model could not be resolved safely. Refresh defaults and try again.")
        }
    }
    private func readDefaultModelConfig(workspacePath: String, deadline: ContinuousClock.Instant) async throws -> (model: String?, effort: String?, modelProvider: String?) {
        try Task.checkCancellation()
        guard !shuttingDown, ContinuousClock.now < deadline else { throw CodexModelCatalogEntry.failure() }
        let response = try await rpc.request("config/read", params: .object(["cwd": .string(workspacePath), "includeLayers": .bool(false)]),
                                             timeout: ContinuousClock.now.duration(to: deadline))
        try Task.checkCancellation()
        guard response.object != nil, response["config"].object != nil,
              try JSONEncoder().encode(response).count <= 4 * 1_024 * 1_024 else { throw CodexModelCatalogEntry.failure() }
        return (try CodexModelCatalogEntry.string(response["config"]["model"], maximum: 4_096),
                try CodexModelCatalogEntry.string(response["config"]["model_reasoning_effort"], maximum: 256),
                try CodexModelCatalogEntry.string(response["config"]["model_provider"], maximum: 4_096))
    }
    private func connectForHistory() async throws {
        do { try await connect() }
        catch is CancellationError { throw CancellationError() }
        catch let error as ProviderHistoryError { throw error }
        catch { throw ProviderHistoryError(.invalidResponse) }
    }
    public func send(text: String, thread: CodingThread) async throws {
        try await send(input: ProviderInput(text: text), thread: thread)
    }
    public func send(input: ProviderInput, thread: CodingThread) async throws {
        guard !historyMutationUncertain else { throw ProviderHistoryError(.outcomeUncertain) }
        guard !working, !historyMutationInFlight else { throw CoincideError("A turn or conversation history operation is already running in this thread.") }
        if let effort = thread.reasoningEffort {
            guard !effort.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, effort.utf8.count <= 256,
                  !effort.unicodeScalars.contains(where: { $0.value < 32 || $0.value == 127 }) else {
                throw CoincideError("The selected Codex reasoning effort is invalid.")
            }
        }
        working = true
        sendGeneration += 1
        let generation = sendGeneration, submittedRunID = thread.activeRun?.id
        eventRunID = submittedRunID
        activeConfiguration = .init(thread: thread)
        do {
            try await connect()
            if threadID == nil {
                var params: [String: JSONValue] = ["cwd": .string(thread.workspacePath),
                    "approvalPolicy": thread.permission.approvalPolicy, "approvalsReviewer": thread.permission.reviewer,
                    "sandbox": .string(thread.permission == .fullAccess ? "danger-full-access" : thread.permission == .supervised ? "read-only" : "workspace-write")]
                if !thread.model.isEmpty { params["model"] = .string(thread.model) }
                let response: JSONValue
                if let existing = thread.providerThreadID {
                    params["threadId"] = .string(existing)
                    response = try await rpc.request("thread/resume", params: .object(params))
                } else {
                    // Select the durable modern contract explicitly for new
                    // threads. Existing/legacy resumes are never migrated here.
                    if CodexHistoryClient(rpc: rpc, userAgent: serverUserAgent).hasReviewedProfile { params["historyMode"] = .string("paginated") }
                    response = try await rpc.request("thread/start", params: .object(params))
                    if params["historyMode"] == .string("paginated"), response["thread"]["historyMode"] != .string("paginated") {
                        throw ProviderHistoryError(.invalidResponse)
                    }
                }
                guard let id = response["thread"]["id"].string else { throw CoincideError("Codex did not return a thread id.") }
                threadID = id; emit(.thread(id))
            }
            var items: [JSONValue] = input.text.isEmpty ? [] : [.object(["type": .string("text"), "text": .string(input.text)])]
            items += input.images.map { .object(["type": .string("image"), "url": .string("data:\($0.mimeType);base64,\($0.data.base64EncodedString())")]) }
            var params: [String: JSONValue] = ["threadId": .string(threadID!), "cwd": .string(thread.workspacePath),
                "input": .array(items),
                "approvalPolicy": thread.permission.approvalPolicy, "approvalsReviewer": thread.permission.reviewer,
                "sandboxPolicy": thread.permission.sandbox(cwd: thread.workspacePath), "summary": .string("detailed")]
            if !thread.model.isEmpty { params["model"] = .string(thread.model) }
            if let effort = thread.reasoningEffort { params["effort"] = .string(effort) }
            let response = try await rpc.request("turn/start", params: .object(params))
            guard let id = response["turn"]["id"].string else { throw CoincideError("Codex did not return a turn id.") }
            if generation == sendGeneration, !completedTurnIDs.contains(id) { turnID = id; emit(.turn(id), runID: submittedRunID) }
        } catch { if generation == sendGeneration { working = false }; throw error }
    }
    public func steeringCapabilities() async -> ProviderSteeringCapabilities {
        guard initialized, CodexHistoryClient(rpc: rpc, userAgent: serverUserAgent).hasReviewedProfile,
              !shuttingDown, !historyMutationInFlight, !historyMutationUncertain else {
            return .init(unavailableReason: ProviderSteeringError(.unsupported).localizedDescription)
        }
        guard working, turnID != nil, threadID != nil, eventRunID != nil, activeConfiguration != nil else {
            return .init(unavailableReason: ProviderSteeringError(.noActiveTurn).localizedDescription)
        }
        return .init(supportsActiveSteering: true)
    }
    public func steer(input: ProviderInput, thread: CodingThread, expectedTurnID: String, clientMessageID: String) async throws -> ProviderSteeringReceipt {
        try Task.checkCancellation()
        try ProviderSteeringValidation.id(expectedTurnID); try ProviderSteeringValidation.id(clientMessageID)
        try ProviderSteeringValidation.input(input)
        // Keep frame writes owned even if the caller cancels. Cancelling a
        // partially written RPC frame would terminate the existing provider.
        while let previous = steeringTask {
            _ = try? await previous.task.value
            if steeringTask?.id == previous.id { steeringTask = nil }
            try Task.checkCancellation()
        }
        guard initialized, CodexHistoryClient(rpc: rpc, userAgent: serverUserAgent).hasReviewedProfile,
              !shuttingDown, !historyMutationInFlight, !historyMutationUncertain else { throw ProviderSteeringError(.unsupported) }
        guard working else { throw ProviderSteeringError(.noActiveTurn) }
        try ProviderSteeringValidation.target(thread, provider: .codex, configuration: activeConfiguration,
            runID: eventRunID, nativeThreadID: threadID, turnID: turnID, expectedTurnID: expectedTurnID)
        var items: [JSONValue] = input.text.isEmpty ? [] : [.object(["type": .string("text"), "text": .string(input.text), "text_elements": .array([])])]
        items += input.images.map { .object(["type": .string("image"), "url": .string("data:\($0.mimeType);base64,\($0.data.base64EncodedString())")]) }
        let params: JSONValue = .object(["threadId": .string(threadID!), "expectedTurnId": .string(expectedTurnID),
            "clientUserMessageId": .string(clientMessageID), "input": .array(items)])
        try ProviderSteeringValidation.frame(params); try Task.checkCancellation()
        let rpc = rpc, id = UUID()
        let task = Task {
            do {
                let response = try await rpc.request("turn/steer", params: params, timeout: .seconds(10))
                guard response["turnId"].string == expectedTurnID else { throw ProviderSteeringError(.outcomeUncertain) }
                return try ProviderSteeringReceipt(turnID: expectedTurnID)
            } catch let error as JSONRPCRemoteError where error.code == -32601 { throw ProviderSteeringError(.unsupported) }
            catch let error as JSONRPCRemoteError where error.code == -32602 { throw ProviderSteeringError(.rejected) }
            catch let error as ProviderSteeringError { throw error }
            catch { throw ProviderSteeringError(.outcomeUncertain) }
        }
        steeringTask = .init(id: id, task: task)
        defer { if steeringTask?.id == id { steeringTask = nil } }
        // An acknowledgement remains useful evidence if completion or caller
        // cancellation wins the race. It never reinstalls an active turn.
        return try await task.value
    }
    public func interrupt() async throws {
        guard let threadID, let turnID else { throw CoincideError("There is no active turn to stop.") }
        _ = try await rpc.request("turn/interrupt", params: .object(["threadId": .string(threadID), "turnId": .string(turnID)]))
    }
    public func respond(_ request: ApprovalRequest, allow: Bool) async throws {
        guard request.method == "item/commandExecution/requestApproval" || request.method == "item/fileChange/requestApproval" else {
            throw CoincideError("This request requires a different response form.")
        }
        try await rpc.respond(id: request.id, result: .object(["decision": .string(allow ? "accept" : "decline")]))
    }
    public func answer(_ request: ApprovalRequest, answers: [String: String]) async throws {
        guard request.method == "item/tool/requestUserInput" else { throw CoincideError("This is not a question request.") }
        let encoded = answers.mapValues { JSONValue.object(["answers": .array([.string($0)])]) }
        try await rpc.respond(id: request.id, result: .object(["answers": .object(encoded)]))
    }
    public func close() async {
        shuttingDown = true; let connecting = connectionTask; connecting?.cancel(); await rpc.close()
        _ = try? await steeringTask?.task.value; steeringTask = nil
        await connecting?.value; connectionTask = nil
        eventTask?.cancel(); eventTask = nil; continuation.finish()
    }
    private func consume(_ event: RPCEvent) async {
        switch event {
        case .callback(let work): await work()
        case .barrier(let complete): complete()
        case .disconnected(let reason):
            working = false
            if !shuttingDown { continuation.yield(.connectionClosed(reason)) }
            continuation.finish()
        case .request(let id, let method, let params):
            if ["item/commandExecution/requestApproval", "item/fileChange/requestApproval", "item/tool/requestUserInput"].contains(method) {
                emit(.approval(.init(id: id, method: method, params: params)))
            } else {
                try? await rpc.reject(id: id, message: "Coincide does not support this interactive request yet.")
                emit(.message(.init(role: .system, text: "Unsupported provider request: \(method). The request was declined.")))
            }
        case .notification(let method, let params):
            if let id = params["threadId"].string, let threadID, id != threadID { return }
            switch method {
            case "serverRequest/resolved": emit(.approvalDismissed(params["requestId"]))
            case "turn/started":
                if let id = params["turn"]["id"].string, !completedTurnIDs.contains(id), working { turnID = id; emit(.turn(id)) }
            case "item/agentMessage/delta", "item/reasoning/summaryTextDelta", "item/commandExecution/outputDelta":
                guard let id = params["itemId"].string, let delta = params["delta"].string else { return }
                let role: MessageRole = method.contains("reasoning") ? .reasoning : method.contains("commandExecution") ? .tool : .assistant
                emit(.delta(id: id, role: role, text: delta))
            case "item/started", "item/completed":
                let item = params["item"]
                guard let id = item["id"].string, let type = item["type"].string else { return }
                if type == "agentMessage", method == "item/completed", let text = item["text"].string {
                    emit(.message(.init(id: id, role: .assistant, text: text)))
                } else if type == "commandExecution" {
                    let command = item["command"].string ?? "Command"
                    let output = item["aggregatedOutput"].string ?? ""
                    emit(.message(.init(id: id, role: .tool, text: "$ \(command)\n\(output)")))
                } else if type == "fileChange", method == "item/completed" {
                    emit(.message(.init(id: id, role: .tool, text: "File changes\n\(item["changes"].pretty)")))
                }
            case "turn/completed":
                guard working, let completedID = params["turn"]["id"].string, !completedTurnIDs.contains(completedID) else { return }
                if let turnID, turnID != completedID { return }
                // Completion can precede both turn/started and the start response.
                // Preserve its real boundary before retiring the local active run.
                if turnID == nil { emit(.turn(completedID)) }
                working = false
                completedTurnIDs.append(completedID)
                if completedTurnIDs.count > 128 { completedTurnIDs.removeFirst() }
                turnID = nil
                let status = params["turn"]["status"].string
                if status == "failed" {
                    emit(.failure(params["turn"]["error"]["message"].string ?? "The provider turn failed."))
                } else { emit(.completed(status == "interrupted" ? .interrupted : .idle)) }
            case "error":
                if params["willRetry"] != .bool(true) { working = false; emit(.failure(params["error"]["message"].string ?? "Codex reported an error.")) }
            default: break
            }
        }
    }
    private func emit(_ event: ProviderEvent, runID: UUID? = nil) {
        if let id = runID ?? eventRunID { continuation.yield(.context(runID: id, event: event)) }
        else { continuation.yield(event) }
    }
    deinit { eventTask?.cancel() }
}
