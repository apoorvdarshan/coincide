import Foundation

/// Direct ACP v1 over JSON-RPC 2.0 stdio. Optional client filesystem, terminal,
/// authentication, and elicitation capabilities are not advertised until implemented.
public actor ACPSession: ProviderSession {
    public nonisolated let events: AsyncStream<ProviderEvent>
    private let continuation: AsyncStream<ProviderEvent>.Continuation
    private let rpc: JSONRPCConnection
    private let cwd: URL
    private let cancellationTimeout: Duration
    private let integration: ACPIntegration?
    private var copilot = CopilotACPBridge()
    private var copilotRunID: UUID?
    private var copilotChildren: [String: CopilotACPChildUpdate] = [:]
    private var copilotChildSegments: [String: Int] = [:]
    private var reader: Task<Void, Never>?
    private var connecting: Task<JSONValue, any Error>?
    private var sessionSetup: Task<Void, any Error>?
    private var sessionReady = false
    private var initialization: JSONValue?
    private var sessionID: String?
    private var setup: JSONValue = .object([:])
    private var defaults: JSONValue = .object([:])
    private var loadingHistory = false
    private var closing = false
    private var working = false
    private var interrupted = false
    private var runID: UUID?
    private var generation = UUID()
    private var segment = 0
    private var announcedTurn = false
    private var promptTask: Task<Void, Never>?
    private var cancellationTimer: Task<Void, Never>?
    private var pending: [JSONValue: ApprovalRequest] = [:]
    private var cursorWireIDs: [JSONValue: JSONValue] = [:]
    private var cursorNotifications = CursorACPNotifications()
    private var tools: [String: JSONValue] = [:]

    public init(executable: URL, arguments: [String], cwd: URL, cancellationTimeout: Duration = .seconds(10), integration: ACPIntegration? = nil) throws {
        let pair = AsyncStream<ProviderEvent>.makeStream()
        events = pair.stream; continuation = pair.continuation; self.cwd = cwd
        self.cancellationTimeout = cancellationTimeout
        self.integration = integration
        rpc = try JSONRPCConnection(executable: executable, arguments: arguments, cwd: cwd,
                                    dialect: .jsonRPC2, maximumFrameSize: 128 * 1_024 * 1_024)
    }
    /// A negotiated v1 fallback adopts the existing transport; it never launches
    /// another process or consumes the same stream as a second adapter.
    init(adopting rpc: JSONRPCConnection, cwd: URL, initialization: JSONValue, integration: ACPIntegration? = nil) {
        let pair = AsyncStream<ProviderEvent>.makeStream()
        events = pair.stream; continuation = pair.continuation; self.cwd = cwd
        self.rpc = rpc; self.initialization = initialization; cancellationTimeout = .seconds(10)
        self.integration = integration
    }
    @discardableResult public func connect() async throws -> JSONValue {
        guard !closing else { throw CancellationError() }
        if reader == nil {
            let stream = rpc.events
            reader = Task { [weak self] in for await event in stream { await self?.consume(event) } }
        }
        if let initialization { return initialization }
        if let connecting {
            let result = try await connecting.value; guard !closing else { throw CancellationError() }
            initialization = result; return result
        }
        let rpc = rpc, capabilities = integration?.clientCapabilities ?? .object([:])
        let task = Task<JSONValue, any Error> {
            let result = try await rpc.request("initialize", params: .object([
                "protocolVersion": .number(1), "clientCapabilities": capabilities,
                "clientInfo": .object(["name": .string("coincide"), "title": .string("Coincide"), "version": .string("0.1.0")])
            ]), timeout: .seconds(60))
            guard result["protocolVersion"] == .number(1) else {
                await rpc.close(); throw CoincideError("This agent requires an ACP version Coincide does not support yet.")
            }
            return result
        }
        connecting = task
        do { let result = try await task.value; guard !closing else { throw CancellationError() }; initialization = result; return result }
        catch { connecting = nil; throw error }
    }
    private func ensureSession(resumeID: String?) async throws {
        if sessionReady { return }
        if let sessionSetup { try await sessionSetup.value; return }
        let task = Task { try await self.createSession(resumeID: resumeID) }; sessionSetup = task
        do { try await task.value } catch { sessionSetup = nil; throw error }
    }
    private func createSession(resumeID: String?) async throws {
        let info = try await connect()
        guard !closing else { throw CancellationError() }
        if sessionID != nil { return }
        var params: [String: JSONValue] = ["cwd": .string(cwd.path), "mcpServers": .array([])]
        let response: JSONValue
        if let resumeID {
            guard info["agentCapabilities"]["loadSession"] == .bool(true) else {
                throw CoincideError("This agent cannot resume its saved session. Start a new conversation to avoid losing its context.")
            }
            loadingHistory = true; sessionID = resumeID; params["sessionId"] = .string(resumeID)
            do {
                response = try await rpc.request("session/load", params: .object(params), timeout: .seconds(60))
                // Loading agents replay history before responding. Drain the notification
                // consumer before accepting new output, preserving our journal's transcript.
                await rpc.flushEvents(); loadingHistory = false
            } catch { loadingHistory = false; sessionID = nil; throw error }
        } else {
            response = try await rpc.request("session/new", params: .object(params), timeout: .seconds(60))
            guard let id = response["sessionId"].string, !id.isEmpty else { throw CoincideError("The agent did not return a session identity.") }
            sessionID = id
        }
        guard !closing, let sessionID else { throw CancellationError() }
        setup = response
        defaults = response
        sessionReady = true
        emit(.thread(sessionID)); emit(.configuration(setup))
    }
    public func models() async throws -> [ProviderModel] {
        try await ensureSession(resumeID: nil)
        return ACPConfigurationOptions.models(setup)
    }
    public func acpConnectionInfo() async throws -> ACPConnectionInfo {
        try Task.checkCancellation()
        let value = try await connect()
        try Task.checkCancellation()
        return try ACPConnectionInfo(value)
    }
    public func configuration() async throws -> JSONValue {
        try await ensureSession(resumeID: nil); return setup
    }
    public func send(text: String, thread: CodingThread) async throws {
        try await send(input: ProviderInput(text: text), thread: thread)
    }
    public func send(input: ProviderInput, thread: CodingThread) async throws {
        guard !working, !closing else { throw CoincideError("A turn is already running or the agent is closed.") }
        working = true; interrupted = false; runID = thread.activeRun?.id; generation = UUID(); segment = 0; announcedTurn = false; tools = [:]
        cursorNotifications = CursorACPNotifications()
        let token = generation
        do {
            try await ensureSession(resumeID: thread.providerThreadID)
            guard !closing, let sessionID else { throw CancellationError() }
            if !input.images.isEmpty, initialization?["agentCapabilities"]["promptCapabilities"]["image"] != .bool(true) {
                throw CoincideError("This agent does not advertise image input support.")
            }
            try await configure(thread, sessionID: sessionID)
            // A configuration reply can resume its waiter before earlier wire
            // notifications have drained. They still belong to the old work.
            if integration == .copilot { await rpc.flushEvents() }
            guard !closing, !interrupted else { throw CancellationError() }
            if integration == .copilot {
                let owner = runID ?? token
                try copilot.beginRun(sessionID: sessionID, runID: owner); copilotRunID = owner
            }
            var blocks: [JSONValue] = input.images.map {
                .object(["type": .string("image"), "mimeType": .string($0.mimeType), "data": .string($0.data.base64EncodedString())])
            }
            if !input.text.isEmpty { blocks.append(.object(["type": .string("text"), "text": .string(input.text)])) }
            let dispatch = ACPDispatch(), rpc = rpc
            promptTask = Task { [weak self] in
                do {
                    let result = try await rpc.request("session/prompt", params: .object([
                        "sessionId": .string(sessionID), "prompt": .array(blocks)
                    ]), timeout: .seconds(86_400), onSent: { dispatch.finish(.success(())) })
                    dispatch.finish(.success(()))
                    await rpc.flushEvents()
                    await self?.promptFinished(result, token: token)
                } catch {
                    dispatch.finish(.failure(error)); await self?.promptFailed(error, token: token)
                }
            }
            // The start effect settles when the frame is written, not when the model
            // finishes. Permission responses and stops keep their reserved capacity.
            try await dispatch.wait()
            if generation == token, working { announceTurn() }
        } catch { if generation == token { working = false; finishCopilotRun() }; throw error }
    }
    public func interrupt() async throws {
        guard working, let sessionID, !closing else { throw CoincideError("There is no active agent turn to stop.") }
        interrupted = true
        try await rpc.notify("session/cancel", params: .object(["sessionId": .string(sessionID)]))
        let requests = pending, wireIDs = cursorWireIDs; pending = [:]; cursorWireIDs = [:]
        for (id, _) in requests {
            try await rpc.respond(id: wireIDs[id] ?? id, result: .object(["outcome": .object(["outcome": .string("cancelled")])]))
            emit(.approvalDismissed(id))
        }
        // Agents must resolve the prompt after cancellation. A stalled agent must
        // not leave the conversation running forever or keep approvals open.
        let token = generation
        let cancellationTimeout = cancellationTimeout
        cancellationTimer?.cancel()
        cancellationTimer = Task { [weak self] in
            do { try await Task.sleep(for: cancellationTimeout) } catch { return }
            await self?.cancelTimedOut(token: token)
        }
    }
    public func respond(_ request: ApprovalRequest, allow: Bool) async throws {
        if let method = CursorACPMethod.canonical(request.method) {
            guard integration == .cursor else { throw ACPIntegrationValidation.failure() }
            let outcome: String
            if method == CursorACPMethod.question {
                guard !allow, request.cursorQuestion != nil else { throw ACPIntegrationValidation.failure() }
                outcome = "skipped"
            } else {
                guard request.cursorPlan != nil else { throw ACPIntegrationValidation.failure() }
                outcome = allow ? "accepted" : "rejected"
            }
            try await finishCursorRequest(request, result: CursorACPMethod.outcome(outcome)); return
        }
        let kind = allow ? "allow_once" : "reject_once"
        if let id = request.params["options"].array?.first(where: { $0["kind"].string == kind })?["optionId"].string {
            try await choose(request, optionID: id)
        } else if !allow { try await finishPermission(request, outcome: .object(["outcome": .string("cancelled")])) }
        else { throw CoincideError("Choose one of the permission options offered by this agent.") }
    }
    public func choose(_ request: ApprovalRequest, optionID: String) async throws {
        guard (request.params["options"].array ?? []).contains(where: { $0["optionId"].string == optionID }) else { throw CoincideError("This permission option is not available.") }
        try await finishPermission(request, outcome: .object(["outcome": .string("selected"), "optionId": .string(optionID)]))
    }
    private func finishPermission(_ request: ApprovalRequest, outcome: JSONValue) async throws {
        guard pending[request.id] == request, !closing, !interrupted else { throw CoincideError("This permission request is no longer pending.") }
        let token = generation
        try await rpc.respond(id: request.id, result: .object(["outcome": outcome]))
        if generation == token, pending[request.id] == request {
            pending.removeValue(forKey: request.id); emit(.approvalDismissed(request.id))
        }
    }
    public func answer(_ request: ApprovalRequest, answers: [String: String]) async throws {
        throw CoincideError("This agent did not negotiate native question support.")
    }
    public func selectAnswers(_ request: ApprovalRequest, selections: [String: [String]]) async throws {
        guard integration == .cursor, let question = request.cursorQuestion else { throw ACPIntegrationValidation.failure() }
        try await finishCursorRequest(request, result: question.response(for: selections))
    }
    private func finishCursorRequest(_ request: ApprovalRequest, result: JSONValue) async throws {
        guard integration == .cursor, working, !closing, !interrupted, pending[request.id] == request,
              let wireID = cursorWireIDs[request.id] else {
            throw CoincideError("This Cursor request is no longer pending.")
        }
        let token = generation
        try await rpc.respond(id: wireID, result: result)
        if generation == token, pending[request.id] == request {
            pending.removeValue(forKey: request.id); cursorWireIDs.removeValue(forKey: request.id); emit(.approvalDismissed(request.id))
        }
    }
    public func close() async {
        guard !closing else { return }; closing = true
        promptTask?.cancel(); connecting?.cancel(); sessionSetup?.cancel(); cancellationTimer?.cancel(); await rpc.close()
        reader?.cancel(); reader = nil; pending = [:]; cursorWireIDs = [:]; copilot.reset(); copilotChildren = [:]; copilotChildSegments = [:]; continuation.finish()
    }
    private func consume(_ event: RPCEvent) async {
        switch event {
        case .callback(let work):
            if integration == .copilot { copilot.invalidatePendingDeltas() }
            await work()
        case .barrier(let complete): complete()
        case .disconnected(let reason):
            if !closing { continuation.yield(.connectionClosed(reason)) }
            working = false; continuation.finish()
        case .request(let id, let method, let params):
            if integration == .copilot { copilot.invalidatePendingDeltas() }
            if integration == .cursor, let canonical = CursorACPMethod.canonical(method) {
                guard working, !closing, !loadingHistory, !interrupted, sessionReady,
                      params["sessionId"] == .null || params["sessionId"].string == sessionID else {
                    try? await rpc.respond(id: id, result: CursorACPMethod.outcome("cancelled")); return
                }
                guard pending.count < 1_024, pending[id] == nil, !cursorWireIDs.values.contains(id) else {
                    continuation.yield(.connectionClosed("Cursor reused a pending request identity.")); await close(); return
                }
                do {
                    var safe = canonical == CursorACPMethod.question
                        ? try CursorACPQuestionRequest(params: params).parameters.object!
                        : try CursorACPPlanRequest(params: params).parameters.object!
                    safe["sessionId"] = sessionID.map(JSONValue.string)
                    let localID: JSONValue = .string("cursor-request-\(UUID())")
                    let request = ApprovalRequest(id: localID, method: canonical, params: .object(safe))
                    announceTurn(); pending[localID] = request; cursorWireIDs[localID] = id; emit(.approval(request))
                } catch { try? await rpc.reject(id: id, message: "Cursor sent an unsupported question or plan request.") }
                return
            }
            guard method == "session/request_permission", params["sessionId"].string == sessionID, working, !loadingHistory, !interrupted else {
                if method == "session/request_permission" {
                    try? await rpc.respond(id: id, result: .object(["outcome": .object(["outcome": .string("cancelled")])]))
                } else { try? await rpc.reject(id: id, message: "This client capability was not negotiated.") }
                return
            }
            guard pending.count < 1_024, pending[id] == nil, !cursorWireIDs.values.contains(id) else {
                continuation.yield(.connectionClosed("The agent reused a pending request identity.")); await close(); return
            }
            announceTurn()
            var enriched = params.object ?? [:]
            if let toolID = params["toolCall"]["toolCallId"].string {
                var call = tools[toolID]?.object ?? [:]
                for (key, value) in params["toolCall"].object ?? [:] where value != .null { call[key] = value }
                enriched["toolCall"] = .object(call)
            }
            let request = ApprovalRequest(id: id, method: method, params: .object(enriched))
            pending[id] = request; emit(.approval(request))
        case .notification(let method, let params):
            if method == "$/cancel_request" {
                let wireID = params["requestId"]
                if let localID = cursorWireIDs.first(where: { $0.value == wireID })?.key {
                    cursorWireIDs.removeValue(forKey: localID); pending.removeValue(forKey: localID)
                    emit(.approvalDismissed(localID))
                } else if pending.removeValue(forKey: wireID) != nil { emit(.approvalDismissed(wireID)) }
                return
            }
            if integration == .cursor, CursorACPNotifications.handles(method) {
                guard working, !closing, !loadingHistory, !interrupted, sessionReady, let sessionID,
                      params["sessionId"] == .null || params["sessionId"].string == sessionID else { return }
                do {
                    if let update = try cursorNotifications.consume(method: method, params: params, sessionID: sessionID, runID: runID ?? generation) {
                        emit(.entity(update))
                    }
                } catch { emit(.failure("Cursor returned an invalid activity notification.")); await close() }
                return
            }
            var notification = params
            if integration == .copilot {
                do {
                    for child in try copilot.consumeNotification(method: method, params: params) { publishCopilotChild(child) }
                    guard method == "session/update", params["sessionId"].string == sessionID, !loadingHistory else { return }
                    guard let routed = try copilot.routeSessionUpdate(params) else { return }
                    for child in routed.children { publishCopilotChild(child) }
                    if routed.child { try publishCopilotUpdate(routed); return }
                    var fields = params.object ?? [:]; fields["update"] = routed.update; notification = .object(fields)
                } catch {
                    continuation.yield(.connectionClosed(CopilotACPBridge.failureMessage)); await close(); return
                }
            }
            guard method == "session/update", notification["sessionId"].string == sessionID, !loadingHistory else { return }
            let update = notification["update"], kind = update["sessionUpdate"].string ?? ""
            if kind == "current_mode_update" { setMetadata(section: "modes", field: "currentModeId", value: update["currentModeId"]); return }
            if kind == "config_option_update" { setMetadata(field: "configOptions", value: update["configOptions"]); return }
            if kind == "available_commands_update" { setMetadata(field: "availableCommands", value: update["availableCommands"]); return }
            if kind == "tool_call" || kind == "tool_call_update" {
                guard let id = update["toolCallId"].string, let sessionID else { return }
                var tool = tools[id]?.object ?? [:]
                for (key, value) in update.object ?? [:] where value != .null { tool[key] = value }
                tools[id] = .object(tool)
                if working, kind == "tool_call" { segment += 1 }
                var patch = (update.object ?? [:]).filter { $0.value != .null }
                patch["sessionUpdate"] = .string("tool_call_update")
                do { emit(.entity(try .acp(.object(patch), sessionID: sessionID))) }
                catch { emit(.failure(error.localizedDescription)) }
                return
            }
            guard working else { return }; announceTurn()
            switch kind {
            case "agent_message_chunk", "agent_thought_chunk":
                let role: MessageRole = kind == "agent_thought_chunk" ? .reasoning : .assistant
                if update["content"]["type"].string == "text", let text = update["content"]["text"].string {
                    let nativeID = "segment-\(segment)-\(update["messageId"].string ?? "message")"
                    emit(.delta(id: "acp-\(generation)-\(role.rawValue)-\(nativeID)", role: role, text: text))
                } else {
                    emit(.message(.init(role: .system, text: "This agent returned \(update["content"]["type"].string ?? "unknown") content that the native transcript cannot display yet.")))
                }
            case "plan":
                let text = (update["entries"].array ?? []).map { "- [\($0["status"].string == "completed" ? "x" : " ")] \($0["content"].string ?? "")" }.joined(separator: "\n")
                emit(.message(.init(id: "acp-\(generation)-plan", role: .tool, text: text)))
            case "user_message_chunk": break // The durable client command already owns the user message.
            default: setMetadata(field: "lastSessionUpdate", value: update)
            }
        }
    }
    private func promptFinished(_ result: JSONValue, token: UUID) {
        guard generation == token, working, !closing else { return }
        working = false; promptTask = nil
        finishCopilotRun()
        cancellationTimer?.cancel(); cancellationTimer = nil
        for id in pending.keys { emit(.approvalDismissed(id)) }; pending = [:]; cursorWireIDs = [:]
        let reason = result["stopReason"].string ?? "unknown"
        if interrupted || reason == "cancelled" { emit(.completed(.interrupted)) }
        else if ["end_turn", "max_tokens", "max_turn_requests", "refusal"].contains(reason) {
            if reason != "end_turn" { emit(.message(.init(role: .system, text: "The agent stopped: \(reason.replacingOccurrences(of: "_", with: " "))."))) }
            emit(.completed(.idle))
        } else { emit(.failure("The agent returned an unrecognized stop reason: \(reason).")) }
    }
    private func promptFailed(_ error: any Error, token: UUID) {
        guard generation == token, working, !closing else { return }; working = false; promptTask = nil
        finishCopilotRun()
        for id in pending.keys { emit(.approvalDismissed(id)) }; pending = [:]; cursorWireIDs = [:]
        cancellationTimer?.cancel(); cancellationTimer = nil
        emit(.failure(error.localizedDescription))
    }
    private func cancelTimedOut(token: UUID) async {
        guard generation == token, working, interrupted, !closing else { return }
        working = false; emit(.completed(.interrupted))
        emit(.connectionClosed("The agent did not acknowledge cancellation; its process was stopped.")); await close()
    }
    private func announceTurn() {
        guard !announcedTurn else { return }; announcedTurn = true; emit(.turn(generation.uuidString))
    }
    private func finishCopilotRun() {
        if let sessionID, let owner = copilotRunID { copilot.finishRun(sessionID: sessionID, runID: owner) }
        copilotRunID = nil
    }
    private func publishCopilotChild(_ child: CopilotACPChildUpdate) {
        copilotChildren[child.childSessionID] = child
        emit(.runEntity(runID: child.runID, update: child.entityUpdate))
    }
    private func publishCopilotUpdate(_ routed: CopilotACPRoutedUpdate) throws {
        guard let child = copilotChildren[routed.sessionID], child.runID == routed.runID, child.sessionID == sessionID,
              child.status == .running else { return }
        let kind = routed.update["sessionUpdate"].string ?? ""
        var update = routed.update.object ?? [:]
        let metadata: JSONValue = .object(["github.com/copilot": .object([
            "parentSessionId": .string(child.sessionID), "parentRunID": .string(child.runID.uuidString),
            "parentToolCallId": .string(child.toolCallID), "taskTitle": .string(child.title ?? "Copilot task")])])
        if kind == "tool_call" || kind == "tool_call_update" {
            if kind == "tool_call" { copilotChildSegments[routed.sessionID, default: 0] += 1 }
            update["sessionUpdate"] = .string("tool_call_update")
            var fields = update["_meta"]?.object ?? [:]; fields["github.com/copilot"] = metadata["github.com/copilot"]
            update["_meta"] = .object(fields)
        } else if kind == "agent_message_chunk" || kind == "agent_thought_chunk" {
            guard routed.update["content"]["type"] == .string("text") else { return }
            let messageID = try ACPIntegrationValidation.string(routed.update["messageId"], maximum: 4_096)
                ?? "copilot-\(child.runID)-segment-\(copilotChildSegments[routed.sessionID, default: 0])"
            update["messageId"] = .string(messageID)
            let type = kind == "agent_message_chunk" ? "agent_message" : "agent_thought"
            let key = ProviderEntityKey(sessionID: routed.sessionID, type: type, id: messageID)
            emit(.runEntity(runID: child.runID, update: .patch(key, .object(["_meta": metadata]))))
        } else { return }
        emit(.runEntity(runID: child.runID, update: try .acp(.object(update), sessionID: routed.sessionID)))
    }
    private func configure(_ thread: CodingThread, sessionID: String) async throws {
        // Unrecognized option types keep their agent defaults; they cannot hide
        // a supported selector in the same semantic category.
        let initial = (setup["configOptions"].array ?? []).filter { $0["type"].string == "select" }
        let modelOptionID = initial.first(where: { $0["category"].string == "model" })?["id"].string
        let modeOptionID = initial.first(where: { $0["category"].string == "mode" })?["id"].string
        let known = Set(initial.compactMap { $0["id"].string })
        guard Set((thread.agentConfigValues ?? [:]).keys).union((thread.agentConfiguration ?? [:]).keys).isSubset(of: known),
              (thread.agentConfiguration ?? [:]).values.allSatisfy({ $0.string != nil }) else { throw CoincideError("An agent configuration option or value is no longer available.") }
        for original in initial {
            guard let id = original["id"].string, original["type"].string == "select" else { continue }
            guard let option = setup["configOptions"].array?.first(where: { $0["id"].string == id }) else {
                if thread.agentConfigValues?[id] != nil { throw CoincideError("The agent removed a selected configuration option.") }; continue
            }
            var requested = thread.agentConfiguration?[id]?.string ?? thread.agentConfigValues?[id]
            if id == modelOptionID, requested == nil, !thread.model.isEmpty { requested = thread.model }
            if id == modeOptionID, requested == nil { requested = thread.agentModeID }
            if requested == nil { requested = defaults["configOptions"].array?.first(where: { $0["id"].string == id })?["currentValue"].string }
            guard let requested, option["currentValue"].string != requested else { continue }
            guard ACPConfigurationOptions.values(option).contains(where: { $0["value"].string == requested }) else {
                throw CoincideError("The selected value for \(option["name"].string ?? id) is no longer available.")
            }
            let result = try await rpc.request("session/set_config_option", params: .object([
                "sessionId": .string(sessionID), "configId": .string(id), "value": .string(requested)
            ]))
            guard result["configOptions"].array != nil else { throw CoincideError("The agent did not return its updated configuration.") }
            setMetadata(field: "configOptions", value: result["configOptions"])
        }
        if modelOptionID == nil, let model = thread.model.isEmpty ? defaults["models"]["currentModelId"].string : thread.model,
           setup["models"]["currentModelId"].string != model {
            guard ACPConfigurationOptions.models(setup).contains(where: { $0.id == model }) else { throw CoincideError("The selected model is not available from this agent.") }
            _ = try await rpc.request("session/set_model", params: .object(["sessionId": .string(sessionID), "modelId": .string(model)]))
            setMetadata(section: "models", field: "currentModelId", value: .string(model))
        }
        if modeOptionID == nil, let mode = thread.agentModeID ?? defaults["modes"]["currentModeId"].string,
           setup["modes"]["currentModeId"].string != mode {
            guard (setup["modes"]["availableModes"].array ?? []).contains(where: { $0["id"].string == mode }) else { throw CoincideError("The selected mode is not available from this agent.") }
            _ = try await rpc.request("session/set_mode", params: .object(["sessionId": .string(sessionID), "modeId": .string(mode)]))
            setMetadata(section: "modes", field: "currentModeId", value: .string(mode))
        }
    }
    private func setMetadata(section: String? = nil, field: String, value: JSONValue) {
        var object = setup.object ?? [:]
        if let section { var nested = object[section]?.object ?? [:]; nested[field] = value; object[section] = .object(nested) }
        else { object[field] = value }
        setup = .object(object); emit(.configuration(setup))
    }
    private func emit(_ event: ProviderEvent) {
        // Session configuration and connection lifecycle remain meaningful while
        // idle. The engine still fences them by the owning runtime identity.
        switch event {
        case .configuration, .thread, .connectionClosed, .entity, .runEntity, .associateEntity: continuation.yield(event); return
        default: break
        }
        if let runID { continuation.yield(.context(runID: runID, event: event)) }
        else { continuation.yield(event) }
    }
}

/// A prompt may fail before its frame is sent. Resume the dispatch waiter once
/// from either path; model completion itself remains owned by the session actor.
private final class ACPDispatch: @unchecked Sendable {
    private let lock = NSLock()
    private var result: Result<Void, any Error>?
    private var waiter: CheckedContinuation<Void, any Error>?
    func finish(_ result: Result<Void, any Error>) {
        lock.lock(); guard self.result == nil else { lock.unlock(); return }
        self.result = result; let waiter = waiter; self.waiter = nil; lock.unlock(); waiter?.resume(with: result)
    }
    func wait() async throws {
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                lock.lock(); if let result { lock.unlock(); continuation.resume(with: result) }
                else { waiter = continuation; lock.unlock() }
            }
        } onCancel: { self.finish(.failure(CancellationError())) }
    }
}
