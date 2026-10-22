import Foundation
import OSLog

/// Implements Claude Code's bidirectional stream-json protocol directly in Swift.
/// The wire envelopes follow Anthropic's published Agent SDK transport.
public actor ClaudeSession: ProviderSession {
    private let logger = Logger(subsystem: "com.apoorvdarshan.coincide", category: "Claude")
    public nonisolated let events: AsyncStream<ProviderEvent>
    private let continuation: AsyncStream<ProviderEvent>.Continuation
    private let rpc: JSONRPCConnection
    private var reader: Task<Void, Never>?
    private var closeTask: Task<Void, Never>?
    private var connecting: Task<JSONValue, any Error>?
    private var connectingID: UUID?
    private var initialized = false
    private var shuttingDown = false
    private var eventRunID: UUID?
    private var working = false
    private var requestedInterrupt = false
    private var messageID = ""
    private var initialization = JSONValue.null
    private var pendingApprovals: [JSONValue: ApprovalRequest] = [:]
    private var emittedAssistant = false
    private var activeTurnID: String?
    private var activeNativeThreadID: String?
    /// This process stays bound to one root conversation, including between runs.
    private var nativeThreadID: String?
    private var activeConfiguration: ProviderConfiguration?
    private var turnGeneration = 0
    private var steeringTask: ProviderSteeringTask?
    private var steeringSubmitted = false
    private var activeRootSubagentTools: Set<String> = []
    private var activeSubagentTasks: [String: String] = [:]
    private var steerEchoes: [String] = []

    public init(executable: URL, cwd: URL, resumeID: String? = nil, arguments: [String]? = nil) throws {
        let (events, continuation) = AsyncStream<ProviderEvent>.makeStream()
        self.events = events; self.continuation = continuation
        var args = arguments ?? ["--print", "--input-format", "stream-json", "--output-format", "stream-json",
            "--verbose", "--include-partial-messages", "--permission-prompt-tool", "stdio",
            "--allow-dangerously-skip-permissions"]
        if arguments == nil, let resumeID { args += ["--resume", resumeID] }
        nativeThreadID = resumeID
        rpc = try JSONRPCConnection(executable: executable, arguments: args, cwd: cwd, dialect: .claudeControl,
            maximumFrameSize: 128 * 1_024 * 1_024, drainProcessOnClose: true)
    }
    public func connect() async throws {
        guard !shuttingDown else { throw CoincideError("The Claude connection is closed.") }
        guard !initialized else { return }
        if connecting == nil {
            logger.info("Claude connection starting")
            if reader == nil {
                let stream = rpc.events
                reader = Task { [weak self] in for await event in stream { await self?.consume(event) } }
            }
            let rpc = rpc
            connectingID = UUID()
            connecting = Task { try await rpc.request("initialize", params: .object(["hooks": .null]), timeout: .seconds(60)) }
        }
        guard let connecting else { throw CoincideError("The Claude connection is closed.") }
        let attemptID = connectingID
        defer { if connectingID == attemptID { self.connecting = nil; connectingID = nil } }
        do {
            let result = try await connecting.value
            guard !shuttingDown else { throw CoincideError("The Claude connection is closed.") }
            try Task.checkCancellation()
            if !initialized {
                initialization = result; initialized = true
                logger.info("Claude connection ready")
            }
        } catch {
            if error.localizedDescription == "initialize timed out." {
                throw CoincideError("Claude startup timed out. Check for a macOS file-access dialog, then try again. This attempt did not submit a model turn.")
            }
            throw error
        }
    }
    public func models() async throws -> [ProviderModel] {
        try await connect()
        return (initialization["models"].array ?? []).compactMap {
            guard let id = $0["value"].string ?? $0["id"].string else { return nil }
            return ProviderModel(id: id, name: $0["displayName"].string ?? id)
        }
    }
    public static func permissionMode(_ mode: PermissionMode) -> String {
        switch mode {
        case .supervised: "default"
        case .autoAcceptEdits: "acceptEdits"
        case .auto: "auto"
        case .fullAccess: "bypassPermissions"
        }
    }
    public func send(text: String, thread: CodingThread) async throws {
        try await send(input: ProviderInput(text: text), thread: thread)
    }
    public func send(input: ProviderInput, thread: CodingThread) async throws {
        let submittedRunID = thread.activeRun?.id
        guard !shuttingDown else { throw CoincideError("The Claude connection is closed.") }
        guard !working else { throw CoincideError("A turn is already running in this thread.") }
        if let expected = thread.providerThreadID, let nativeThreadID, expected != nativeThreadID {
            throw CoincideError("The Claude conversation changed. Open a connection for the selected conversation before sending.")
        }
        if nativeThreadID == nil { nativeThreadID = thread.providerThreadID }
        eventRunID = submittedRunID
        working = true; requestedInterrupt = false; emittedAssistant = false
        turnGeneration += 1
        let generation = turnGeneration
        activeConfiguration = .init(thread: thread); activeNativeThreadID = thread.providerThreadID ?? nativeThreadID
        activeTurnID = nil; steeringSubmitted = false; clearRootSubagents(); activeSubagentTasks = [:]
        do {
            try await connect()
            _ = try await rpc.request("set_permission_mode", params: .object(["mode": .string(Self.permissionMode(thread.permission))]))
            _ = try await rpc.request("set_model", params: .object(["model": thread.model.isEmpty ? .null : .string(thread.model)]))
            let promptID = UUID().uuidString
            activeTurnID = promptID
            var images: [JSONValue] = input.images.map { image in
                .object(["type": .string("image"), "source": .object(["type": .string("base64"),
                    "media_type": .string(image.mimeType), "data": .string(image.data.base64EncodedString())])])
            }
            if !input.text.isEmpty { images.append(.object(["type": .string("text"), "text": .string(input.text)])) }
            let content: JSONValue = input.images.isEmpty ? .string(input.text) : .array(images)
            try await rpc.sendFrame(.object(["type": .string("user"), "uuid": .string(promptID),
                "message": .object(["role": .string("user"), "content": content]), "parent_tool_use_id": .null]))
            emit(.turn(promptID), runID: submittedRunID)
        } catch { if generation == turnGeneration { working = false; activeTurnID = nil }; throw error }
    }
    public func steeringCapabilities() async -> ProviderSteeringCapabilities {
        guard initialized, !shuttingDown else { return .init(unavailableReason: ProviderSteeringError(.unsupported).localizedDescription) }
        guard working, !requestedInterrupt, activeTurnID != nil, activeNativeThreadID != nil, eventRunID != nil else {
            return .init(unavailableReason: ProviderSteeringError(.noActiveTurn).localizedDescription)
        }
        guard activeRootSubagentTools.isEmpty else {
            return .init(interruptsTools: true, unavailableReason: "This turn has active agents that this connection cannot safely move to the background. Queue the message instead.")
        }
        return .init(supportsActiveSteering: true, interruptsTools: true)
    }
    public func steer(input: ProviderInput, thread: CodingThread, expectedTurnID: String, clientMessageID: String) async throws -> ProviderSteeringReceipt {
        try Task.checkCancellation()
        try ProviderSteeringValidation.id(expectedTurnID); try ProviderSteeringValidation.id(clientMessageID)
        try ProviderSteeringValidation.input(input)
        while let previous = steeringTask {
            _ = try? await previous.task.value
            if steeringTask?.id == previous.id { steeringTask = nil }
            try Task.checkCancellation()
        }
        guard initialized, !shuttingDown else { throw ProviderSteeringError(.unsupported) }
        guard working, !requestedInterrupt else { throw ProviderSteeringError(.noActiveTurn) }
        guard activeRootSubagentTools.isEmpty else { throw ProviderSteeringError(.unsupported) }
        try ProviderSteeringValidation.target(thread, provider: .claude, configuration: activeConfiguration,
            runID: eventRunID, nativeThreadID: activeNativeThreadID, turnID: activeTurnID, expectedTurnID: expectedTurnID)
        var content: [JSONValue] = input.images.map { image in
            .object(["type": .string("image"), "source": .object(["type": .string("base64"),
                "media_type": .string(image.mimeType), "data": .string(image.data.base64EncodedString())])])
        }
        if !input.text.isEmpty { content.append(.object(["type": .string("text"), "text": .string(input.text)])) }
        // Fresh transport UUIDs avoid mistaking an old CLI transcript echo for
        // this delivery. The app's durable message ID is not an idempotency key.
        let promptID = UUID().uuidString, id = UUID()
        let frame: JSONValue = .object(["type": .string("user"), "uuid": .string(promptID), "priority": .string("now"),
            "message": .object(["role": .string("user"), "content": input.images.isEmpty ? .string(input.text) : .array(content)]),
            "parent_tool_use_id": .null])
        try ProviderSteeringValidation.frame(frame); try Task.checkCancellation()
        let task = Task {
            try await self.submitSteeringFrame(frame, thread: thread, expectedTurnID: expectedTurnID)
        }
        steeringTask = .init(id: id, task: task)
        defer { if steeringTask?.id == id { steeringTask = nil } }
        let receipt = try await task.value
        if steerEchoes.contains(promptID) { return try .init(turnID: expectedTurnID) }
        return receipt
    }
    private func submitSteeringFrame(_ frame: JSONValue, thread: CodingThread, expectedTurnID: String) async throws -> ProviderSteeringReceipt {
        // The task can start after another actor event. Repeat the exact owner
        // check immediately before handing this frame to the live transport.
        guard working, !requestedInterrupt, !shuttingDown else { throw ProviderSteeringError(.noActiveTurn) }
        guard activeRootSubagentTools.isEmpty else { throw ProviderSteeringError(.unsupported) }
        try ProviderSteeringValidation.target(thread, provider: .claude, configuration: activeConfiguration,
            runID: eventRunID, nativeThreadID: activeNativeThreadID, turnID: activeTurnID, expectedTurnID: expectedTurnID)
        steeringSubmitted = true
        do {
            try await rpc.sendFrame(frame)
            return try ProviderSteeringReceipt(turnID: expectedTurnID, delivery: .submitted)
        } catch { throw ProviderSteeringError(.outcomeUncertain) }
    }
    public func interrupt() async throws {
        guard working else { throw CoincideError("There is no active Claude turn to stop.") }
        requestedInterrupt = true
        do { _ = try await rpc.request("interrupt") }
        catch { requestedInterrupt = false; throw error }
    }
    public func respond(_ request: ApprovalRequest, allow: Bool) async throws {
        guard pendingApprovals[request.id] != nil else { throw CoincideError("This approval is no longer pending.") }
        let response: JSONValue = allow
            ? .object(["behavior": .string("allow"), "updatedInput": request.params["input"]])
            : .object(["behavior": .string("deny"), "message": .string("Declined by the user in Coincide.")])
        try await rpc.respond(id: request.id, result: response)
        pendingApprovals.removeValue(forKey: request.id)
    }
    public func answer(_ request: ApprovalRequest, answers: [String: String]) async throws {
        guard pendingApprovals[request.id] != nil, request.isQuestion else { throw CoincideError("This question is no longer pending.") }
        var input = request.params["input"].object ?? [:]
        input["answers"] = .object(answers.mapValues(JSONValue.string))
        try await rpc.respond(id: request.id, result: .object(["behavior": .string("allow"), "updatedInput": .object(input)]))
        pendingApprovals.removeValue(forKey: request.id)
    }
    public func close() async {
        if let closeTask { await closeTask.value; return }
        shuttingDown = true; working = false
        connecting?.cancel()
        let rpc = rpc, reading = reader, steering = steeringTask?.task, initializing = connecting, continuation = continuation
        let task = Task {
            await rpc.close()
            _ = try? await initializing?.value
            _ = try? await steering?.value
            reading?.cancel(); await reading?.value
            continuation.finish()
        }
        closeTask = task
        await task.value
        reader = nil; steeringTask = nil
    }
    private func consume(_ event: RPCEvent) async {
        switch event {
        case .callback(let work): await work()
        case .barrier(let complete): complete()
        case .disconnected(let reason):
            if !shuttingDown { continuation.yield(.connectionClosed(reason)) }
            working = false; continuation.finish()
        case .request(let id, let method, let params):
            guard !shuttingDown else { return }
            if method == "can_use_tool" {
                let request = ApprovalRequest(id: id, method: method, params: params)
                pendingApprovals[id] = request; emit(.approval(request))
            } else {
                try? await rpc.reject(id: id, message: "Coincide does not support this Claude control request yet.")
                emit(.message(.init(role: .system, text: "Unsupported Claude control request: \(method).")))
            }
        case .notification(let method, let frame):
            guard !shuttingDown else { return }
            let isRoot = frame["parent_tool_use_id"] == .null
            if isRoot, let id = frame["session_id"].string {
                // Child IDs and stale root frames must never retarget this
                // process or finish another root conversation's active run.
                guard nativeThreadID == nil || nativeThreadID == id else { return }
                nativeThreadID = id
                if working, activeNativeThreadID == nil { activeNativeThreadID = id }
                emit(.thread(id))
            }
            switch method {
            case "control_cancel_request":
                let id = frame["request_id"]
                pendingApprovals.removeValue(forKey: id); emit(.approvalDismissed(id))
            case "stream_event": consumeStream(frame["event"], isRoot: isRoot)
            case "assistant": consumeAssistant(frame["message"], isRoot: isRoot)
            case "user":
                if isRoot, let uuid = frame["uuid"].string {
                    steerEchoes.append(uuid); if steerEchoes.count > 128 { steerEchoes.removeFirst() }
                }
                for block in frame["message"]["content"].array ?? [] where block["type"].string == "tool_result" {
                    let id = block["tool_use_id"].string ?? UUID().uuidString
                    if isRoot { removeRootSubagent(id) }
                    let text = block["content"].string ?? (block["content"].array ?? []).compactMap { $0["text"].string }.joined(separator: "\n")
                    emit(.message(.init(id: "result-\(id)", role: .tool, text: text)))
                }
            case "system":
                if isRoot, frame["subtype"] == .string("task_started"), let taskID = frame["task_id"].string {
                    let toolID = frame["tool_use_id"].string ?? "task:" + taskID
                    activeSubagentTasks[taskID] = toolID; insertRootSubagent(toolID)
                } else if frame["subtype"] == .string("task_notification"), let taskID = frame["task_id"].string,
                          ["completed", "failed", "stopped"].contains(frame["status"].string ?? ""),
                          let toolID = activeSubagentTasks.removeValue(forKey: taskID) {
                    removeRootSubagent(toolID)
                }
            case "result":
                // Steering can leave several aborted query segments queued
                // ahead of a Stop result. Completion is one fact for the live
                // root query; late segments and child results cannot repeat it.
                guard isRoot, working else { return }
                if steeringSubmitted, !requestedInterrupt,
                   ["aborted_tools", "aborted_streaming"].contains(frame["terminal_reason"].string ?? "") { return }
                working = false; pendingApprovals.removeAll()
                activeTurnID = nil; steeringSubmitted = false; clearRootSubagents(); activeSubagentTasks = [:]
                if requestedInterrupt { emit(.completed(.interrupted)) }
                else if frame["is_error"] == .bool(true) {
                    let errors = (frame["errors"].array ?? []).compactMap(\.string).joined(separator: "\n")
                    emit(.failure(errors.isEmpty ? frame["result"].string ?? "Claude could not complete the turn." : errors))
                } else {
                    if !emittedAssistant, let result = frame["result"].string, !result.isEmpty {
                        emit(.message(.init(role: .assistant, text: result)))
                    }
                    emit(.completed(.idle))
                }
            default: break
            }
        }
    }
    private func consumeStream(_ event: JSONValue, isRoot: Bool) {
        switch event["type"].string {
        case "message_start": messageID = event["message"]["id"].string ?? UUID().uuidString
        case "content_block_start":
            let block = event["content_block"], id = blockID(index: event["index"])
            if block["type"].string == "tool_use" {
                let toolID = block["id"].string ?? id
                observeRootSubagent(block, id: toolID, isRoot: isRoot)
                emit(.message(.init(id: toolID, role: .tool, text: block["name"].string ?? "Tool")))
            } else if let text = block["text"].string, !text.isEmpty {
                emittedAssistant = true; emit(.delta(id: id, role: .assistant, text: text))
            }
        case "content_block_delta":
            let delta = event["delta"], id = blockID(index: event["index"])
            if let text = delta["text"].string { emittedAssistant = true; emit(.delta(id: id, role: .assistant, text: text)) }
            else if let text = delta["thinking"].string { emit(.delta(id: id, role: .reasoning, text: text)) }
        default: break
        }
    }
    private func consumeAssistant(_ message: JSONValue, isRoot: Bool) {
        let id = message["id"].string ?? UUID().uuidString
        for (index, block) in (message["content"].array ?? []).enumerated() {
            switch block["type"].string {
            case "text":
                emittedAssistant = true
                emit(.message(.init(id: "\(id)-\(index)", role: .assistant, text: block["text"].string ?? "")))
            case "thinking": emit(.message(.init(id: "\(id)-\(index)", role: .reasoning, text: block["thinking"].string ?? "")))
            case "tool_use":
                observeRootSubagent(block, id: block["id"].string ?? "\(id)-\(index)", isRoot: isRoot)
                emit(.message(.init(id: block["id"].string ?? "\(id)-\(index)", role: .tool,
                    text: "\(block["name"].string ?? "Tool")\n\(block["input"].pretty)")))
            default: break
            }
        }
    }
    private func observeRootSubagent(_ block: JSONValue, id: String, isRoot: Bool) {
        guard isRoot, working, ["agent", "task"].contains(block["name"].string?.lowercased() ?? "") else { return }
        insertRootSubagent(id)
    }
    private func insertRootSubagent(_ id: String) {
        if activeRootSubagentTools.insert(id).inserted { emit(.steeringCapabilitiesChanged) }
    }
    private func removeRootSubagent(_ id: String) {
        if activeRootSubagentTools.remove(id) != nil { emit(.steeringCapabilitiesChanged) }
    }
    private func clearRootSubagents() {
        guard !activeRootSubagentTools.isEmpty else { return }
        activeRootSubagentTools.removeAll(); emit(.steeringCapabilitiesChanged)
    }
    private func blockID(index: JSONValue) -> String {
        if case .number(let index) = index { return "\(messageID)-\(Int(index))" }
        return "\(messageID)-0"
    }
    private func emit(_ event: ProviderEvent, runID: UUID? = nil) {
        if let id = runID ?? eventRunID { continuation.yield(.context(runID: id, event: event)) }
        else { continuation.yield(event) }
    }
    deinit { reader?.cancel() }
}
