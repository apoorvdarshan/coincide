import Foundation

/// Opt-in ACP v2. A prompt response confirms insertion, not foreground completion.
/// The chosen protocol version applies to the entire existing stdio connection.
public actor ACP2Session: ProviderSession {
    public nonisolated let events: AsyncStream<ProviderEvent>
    private let continuation: AsyncStream<ProviderEvent>.Continuation
    private let rpc: JSONRPCConnection
    private let cwd: URL
    private let cancellationTimeout: Duration
    private let acceptanceTimeout: Duration
    private var initialization: JSONValue?
    private var connecting: Task<JSONValue, any Error>?
    private var reader: Task<Void, Never>?
    private var legacy: ACPSession?
    private var sessionSetup: Task<Void, any Error>?
    private var sessionID: String?
    private var ready = false
    private var creatingSession = false
    private var earlyEvents: [RPCEvent] = []
    private var setup: JSONValue = .object([:])
    private var defaults: JSONValue = .object([:])
    private var closing = false
    private var pending: [JSONValue: ApprovalRequest] = [:]
    private var activityID = UUID()
    private var nativeState: ProviderForegroundState = .idle
    private var submitting = false
    private var dispatched = false
    private var accepted = false
    private var rejected = false
    private var interrupted = false
    private var clientRunID: UUID?
    private var idleAfterDispatch: JSONValue?
    private var observedWork = false
    private var dispatch: ACP2Dispatch?
    private var promptTask: Task<Void, Never>?
    private var cancellationTimer: Task<Void, Never>?

    public init(executable: URL, arguments: [String], cwd: URL, cancellationTimeout: Duration = .seconds(10), acceptanceTimeout: Duration = .seconds(86_400)) throws {
        let pair = AsyncStream<ProviderEvent>.makeStream()
        events = pair.stream; continuation = pair.continuation; self.cwd = cwd; self.cancellationTimeout = cancellationTimeout
        self.acceptanceTimeout = acceptanceTimeout
        rpc = try JSONRPCConnection(executable: executable, arguments: arguments, cwd: cwd, dialect: .jsonRPC2, maximumFrameSize: 128 * 1_024 * 1_024)
    }
    @discardableResult public func connect() async throws -> JSONValue {
        guard !closing else { throw CancellationError() }
        if let initialization { return initialization }
        let task: Task<JSONValue, any Error>
        if let connecting { task = connecting }
        else {
            let rpc = rpc
            task = Task {
                let info: JSONValue = .object(["name": .string("coincide"), "title": .string("Coincide"), "version": .string("0.1.0")])
                return try await rpc.request("initialize", params: .object([
                    "protocolVersion": .number(2), "info": info, "capabilities": .object([:]),
                    // v1-only agents may select v1. Include its initialization
                    // fields so fallback needs neither a new process nor a retry.
                    "clientInfo": info, "clientCapabilities": .object([:])
                ]), timeout: .seconds(60))
            }
            connecting = task
        }
        let result = try await task.value
        guard !closing else { throw CancellationError() }
        if initialization == nil {
            guard result["protocolVersion"] == .number(1) || result["protocolVersion"] == .number(2) else {
                await rpc.close(); throw CoincideError("The agent selected an unsupported ACP protocol version.")
            }
            initialization = result
            if result["protocolVersion"] == .number(1) {
                let session = ACPSession(adopting: rpc, cwd: cwd, initialization: result); legacy = session
                reader = Task { [weak self] in for await event in session.events { await self?.forward(event) } }
            } else {
                guard result["info"]["name"].string != nil, result["info"]["version"].string != nil else {
                    initialization = nil; await rpc.close(); throw CoincideError("The ACP v2 agent did not provide its implementation information.")
                }
                let stream = rpc.events
                reader = Task { [weak self] in for await event in stream { await self?.consume(event) } }
            }
        }
        return result
    }
    private func forward(_ event: ProviderEvent) {
        if case .configuration(let value) = event {
            var metadata = value.object ?? [:]; metadata["protocolVersion"] = .number(1)
            continuation.yield(.configuration(.object(metadata)))
        } else { continuation.yield(event) }
    }
    private func ensureSession(resumeID: String?) async throws {
        if ready { return }
        if let sessionSetup { try await sessionSetup.value; return }
        let task = Task { try await self.createSession(resumeID: resumeID) }; sessionSetup = task
        do { try await task.value } catch { sessionSetup = nil; throw error }
    }
    private func createSession(resumeID: String?) async throws {
        let info = try await connect()
        guard info["capabilities"]["session"].object != nil else { throw CoincideError("This ACP v2 agent does not advertise session support.") }
        guard !closing else { throw CancellationError() }
        creatingSession = true; defer { creatingSession = false }
        var params: [String: JSONValue] = ["cwd": .string(cwd.path)]
        if let resumeID { params["sessionId"] = .string(resumeID); sessionID = resumeID }
        let response = try await rpc.request(resumeID == nil ? "session/new" : "session/resume", params: .object(params), timeout: .seconds(60))
        guard let id = resumeID ?? response["sessionId"].string, !id.isEmpty else { throw CoincideError("The agent did not return a session identity.") }
        sessionID = id; setup = response
        var object = setup.object ?? [:]; object["protocolVersion"] = .number(2); setup = .object(object)
        continuation.yield(.thread(id))
        await rpc.flushEvents()
        while !earlyEvents.isEmpty, !closing {
            let buffered = earlyEvents; earlyEvents = []
            for event in buffered { await consume(event, fromSetup: true) }
        }
        creatingSession = false
        guard !closing else { throw CancellationError() }
        defaults = setup; ready = true; continuation.yield(.configuration(setup))
    }
    public func models() async throws -> [ProviderModel] {
        _ = try await connect()
        if let legacy { return try await legacy.models() }
        try await ensureSession(resumeID: nil); return ACPConfigurationOptions.models(setup)
    }
    public func send(text: String, thread: CodingThread) async throws { try await send(input: .init(text: text), thread: thread) }
    public func send(input: ProviderInput, thread: CodingThread) async throws {
        guard !submitting, !closing else { throw CoincideError("A prompt is already in progress or the agent is closed.") }
        submitting = true; dispatched = false; accepted = false; rejected = false; interrupted = false
        clientRunID = thread.activeRun?.id; activityID = clientRunID ?? UUID(); idleAfterDispatch = nil; observedWork = false
        let token = activityID, runID = clientRunID
        do {
            _ = try await connect()
            if let legacy { submitting = false; try await legacy.send(input: input, thread: thread); return }
            try await ensureSession(resumeID: thread.providerThreadID)
            guard !closing, !interrupted, let sessionID else { throw CancellationError() }
            if !input.images.isEmpty, initialization?["capabilities"]["session"]["prompt"]["image"].object == nil {
                throw CoincideError("This agent does not advertise image input support.")
            }
            try await configure(thread, sessionID: sessionID)
            guard !closing, !interrupted else { throw CancellationError() }
            var blocks: [JSONValue] = input.images.map { .object(["type": .string("image"), "mimeType": .string($0.mimeType), "data": .string($0.data.base64EncodedString())]) }
            if !input.text.isEmpty { blocks.append(.object(["type": .string("text"), "text": .string(input.text)])) }
            let prompt = JSONValue.array(blocks), dispatch = ACP2Dispatch(), rpc = rpc
            let acceptanceTimeout = acceptanceTimeout
            self.dispatch = dispatch; dispatched = true; observedWork = nativeState != .idle
            promptTask = Task { [weak self] in
                do {
                    _ = try await rpc.request("session/prompt", params: .object(["sessionId": .string(sessionID), "prompt": prompt]),
                        timeout: acceptanceTimeout, onRegistered: { dispatch.register($0) }, onSent: { dispatch.finish(.success(())) }, onResponse: { [weak self] result in
                            switch result {
                            case .success(let response): await self?.promptAccepted(response, token: token)
                            case .failure(let error): await self?.promptRejected(error, token: token)
                            }
                        })
                    dispatch.finish(.success(()))
                } catch {
                    dispatch.finish(.failure(error))
                    if dispatch.requestID == nil { await self?.promptRejected(error, token: token) }
                }
            }
            try await dispatch.wait()
            announceTurn(token, runID: runID)
        } catch {
            if activityID == token, !closing {
                if interrupted {
                    rejected = true
                    if nativeState == .idle { idleAfterDispatch = .object(["stopReason": .string("cancelled")]) }
                    finishIfReady()
                } else { submitting = false }
            }
            throw error
        }
    }
    public func interrupt() async throws {
        if let legacy { try await legacy.interrupt(); return }
        guard !closing, let sessionID, submitting || nativeState != .idle else { throw CoincideError("There is no active agent work to stop.") }
        interrupted = true
        if submitting, !dispatched { rejected = true }
        if submitting, !accepted, let requestID = dispatch?.requestID {
            try await rpc.notify("$/cancel_request", params: .object(["requestId": requestID]))
        }
        try await rpc.notify("session/cancel", params: .object(["sessionId": .string(sessionID)]))
        if submitting, !dispatched, nativeState == .idle {
            idleAfterDispatch = .object(["stopReason": .string("cancelled")]); finishIfReady()
        }
        let requests = pending; pending = [:]
        for id in requests.keys {
            try await rpc.respond(id: id, result: .object(["outcome": .object(["outcome": .string("cancelled")])]))
            continuation.yield(.sessionApprovalDismissed(id))
        }
        guard submitting || nativeState != .idle else { return }
        let token = activityID, timeout = cancellationTimeout
        cancellationTimer?.cancel()
        cancellationTimer = Task { [weak self] in
            do { try await Task.sleep(for: timeout) } catch { return }; await self?.cancelTimedOut(token)
        }
    }
    public func respond(_ request: ApprovalRequest, allow: Bool) async throws {
        if let legacy { try await legacy.respond(request, allow: allow); return }
        let kind = allow ? "allow_once" : "reject_once"
        if let id = request.params["options"].array?.first(where: { $0["kind"].string == kind })?["optionId"].string { try await choose(request, optionID: id) }
        else if !allow { try await permission(request, outcome: .object(["outcome": .string("cancelled")])) }
        else { throw CoincideError("Choose one of the permission options offered by this agent.") }
    }
    public func choose(_ request: ApprovalRequest, optionID: String) async throws {
        if let legacy { try await legacy.choose(request, optionID: optionID); return }
        guard (request.params["options"].array ?? []).contains(where: { $0["optionId"].string == optionID }) else { throw CoincideError("This permission option is not available.") }
        try await permission(request, outcome: .object(["outcome": .string("selected"), "optionId": .string(optionID)]))
    }
    private func permission(_ request: ApprovalRequest, outcome: JSONValue) async throws {
        guard pending[request.id] == request, !closing else { throw CoincideError("This permission request is no longer pending.") }
        try await rpc.respond(id: request.id, result: .object(["outcome": outcome])); pending.removeValue(forKey: request.id)
        continuation.yield(.sessionApprovalDismissed(request.id))
    }
    public func answer(_ request: ApprovalRequest, answers: [String: String]) async throws {
        if let legacy { try await legacy.answer(request, answers: answers); return }
        throw CoincideError("This agent did not negotiate native question support.")
    }
    public func close() async {
        guard !closing else { return }; closing = true
        promptTask?.cancel(); connecting?.cancel(); sessionSetup?.cancel(); cancellationTimer?.cancel()
        if let legacy { await legacy.close() }
        else {
            if ready, let sessionID { _ = try? await rpc.request("session/close", params: .object(["sessionId": .string(sessionID)]), timeout: .seconds(1)) }
            await rpc.close()
        }
        reader?.cancel(); reader = nil; continuation.finish()
    }
    private func consume(_ event: RPCEvent, fromSetup: Bool = false) async {
        switch event {
        case .callback(let work): await work()
        case .barrier(let done): done()
        case .disconnected(let reason):
            if !closing {
                if submitting, !accepted, let clientRunID { continuation.yield(.submissionFailed(clientMessageID: "user-\(clientRunID)", reason: "The connection ended before the agent confirmed acceptance. This message will not be sent again automatically.")) }
                continuation.yield(.connectionClosed(reason))
            }
            continuation.finish()
        case .request(let id, let method, let params):
            if creatingSession, !fromSetup, params["sessionId"].string != nil { buffer(event); return }
            guard !closing, params["sessionId"].string == sessionID, method == "session/request_permission" else {
                try? await rpc.reject(id: id, message: "This client capability was not negotiated."); return
            }
            let request = ApprovalRequest(id: id, method: method, params: params); pending[id] = request
            continuation.yield(.sessionApproval(request))
        case .notification(let method, let params):
            if method == "$/cancel_request" {
                let id = params["requestId"]
                if pending.removeValue(forKey: id) != nil {
                    try? await rpc.respond(id: id, result: .object(["outcome": .object(["outcome": .string("cancelled")])]))
                    continuation.yield(.sessionApprovalDismissed(id))
                }; return
            }
            guard method == "session/update" else { return }
            if creatingSession, !fromSetup { buffer(event); return }
            guard params["sessionId"].string == sessionID, let sessionID, !closing else { return }
            let update = params["update"], variant = update["sessionUpdate"].string ?? ""
            switch variant {
            case "state_update": consumeState(update)
            case "config_option_update": metadata("configOptions", update["configOptions"])
            case "available_commands_update": metadata("availableCommands", update["availableCommands"])
            case "session_info_update": metadata("sessionInfo", update)
            case "usage_update": metadata("usage", update)
            case "notice": break // Live-only; never insert a notice into replayable history.
            default:
                do { continuation.yield(.entity(try .acp(update, sessionID: sessionID))) }
                catch { continuation.yield(.failure(error.localizedDescription)) }
            }
        }
    }
    private func buffer(_ event: RPCEvent) {
        guard earlyEvents.count < 1_024 else { continuation.yield(.failure("The agent sent too many updates before session setup completed.")); return }
        earlyEvents.append(event)
    }
    private func consumeState(_ update: JSONValue) {
        let previous = nativeState
        let state: ProviderForegroundState
        switch update["state"].string {
        case "running": state = .running
        case "requires_action": state = .requiresAction
        case "idle": state = .idle
        default: metadata("unknownForegroundState", update); return
        }
        if state != .idle, !submitting, previous == .idle { activityID = UUID(); interrupted = false }
        nativeState = state
        if state != .idle, dispatched { observedWork = true }
        if state == .idle, submitting {
            if (dispatched && observedWork) || (interrupted && rejected) { idleAfterDispatch = update }
            emitActivity(state, update: update, finishes: false)
            finishIfReady()
        } else {
            emitActivity(state, update: update, finishes: state == .idle && previous != .idle)
            if state == .idle { cancellationTimer?.cancel(); cancellationTimer = nil }
        }
    }
    private func promptAccepted(_ response: JSONValue, token: UUID) {
        guard !closing, submitting, activityID == token else { return }
        guard let id = response["messageId"].string, !id.isEmpty, let sessionID else {
            promptRejected(CoincideError("The agent did not confirm the inserted message identity. Its outcome remains uncertain; it will not be resent automatically."), token: token); return
        }
        accepted = true; promptTask = nil
        if let clientRunID { continuation.yield(.associateEntity(.init(sessionID: sessionID, type: "user_message", id: id), clientMessageID: "user-\(clientRunID)")) }
        announceTurn(token, runID: clientRunID); finishIfReady()
    }
    private func promptRejected(_ error: any Error, token: UUID) {
        guard !closing, submitting, activityID == token else { return }
        rejected = true; promptTask = nil
        let intentionalCancellation = interrupted && (error as? JSONRPCRemoteError)?.code == -32800
        if let clientRunID, !intentionalCancellation { continuation.yield(.submissionFailed(clientMessageID: "user-\(clientRunID)", reason: error.localizedDescription)) }
        announceTurn(token, runID: clientRunID)
        if nativeState == .idle {
            idleAfterDispatch = .object(["stopReason": .string(interrupted ? "cancelled" : "error"),
                "error": .object(["message": .string(error.localizedDescription)])])
        }
        finishIfReady()
    }
    private func finishIfReady() {
        guard !closing, submitting, dispatched || (interrupted && rejected), accepted || rejected, let idle = idleAfterDispatch else { return }
        announceTurn(activityID, runID: clientRunID)
        submitting = false; dispatched = false; idleAfterDispatch = nil; dispatch = nil
        cancellationTimer?.cancel(); cancellationTimer = nil
        emitActivity(.idle, update: idle, finishes: true)
    }
    private func emitActivity(_ state: ProviderForegroundState, update: JSONValue, finishes: Bool) {
        continuation.yield(.activity(.init(id: activityID, state: state, stopReason: update.object?["stopReason"], error: update.object?["error"], finishesRun: finishes)))
    }
    private func announceTurn(_ id: UUID, runID: UUID?) {
        if let runID { continuation.yield(.context(runID: runID, event: .turn(id.uuidString))) }
        else { continuation.yield(.turn(id.uuidString)) }
    }
    private func cancelTimedOut(_ token: UUID) async {
        guard !closing, activityID == token, interrupted, submitting || nativeState != .idle else { return }
        announceTurn(token, runID: clientRunID)
        emitActivity(.idle, update: .object(["stopReason": .string("cancelled")]), finishes: true)
        continuation.yield(.connectionClosed("The agent did not acknowledge cancellation; its process was stopped.")); await close()
    }
    private func metadata(_ field: String, _ value: JSONValue) {
        var object = setup.object ?? [:]; object[field] = value; setup = .object(object); continuation.yield(.configuration(setup))
    }
    private func configure(_ thread: CodingThread, sessionID: String) async throws {
        let initial = setup["configOptions"].array ?? []
        var requested = (thread.agentConfigValues ?? [:]).mapValues(JSONValue.string)
        requested.merge(thread.agentConfiguration ?? [:]) { _, new in new }
        let known = Set(initial.compactMap(ACPConfigurationOptions.id))
        guard Set(requested.keys).isSubset(of: known) else { throw CoincideError("An agent configuration option is no longer available.") }
        let modelID = initial.first(where: { $0["category"].string == "model" && $0["type"].string == "select" }).flatMap(ACPConfigurationOptions.id)
        let modeID = initial.first(where: { $0["category"].string == "mode" && $0["type"].string == "select" }).flatMap(ACPConfigurationOptions.id)
        if let modelID, !thread.model.isEmpty, requested[modelID] == nil { requested[modelID] = .string(thread.model) }
        if let modeID, let mode = thread.agentModeID, requested[modeID] == nil { requested[modeID] = .string(mode) }
        for old in initial {
            guard let id = ACPConfigurationOptions.id(old), let option = setup["configOptions"].array?.first(where: { ACPConfigurationOptions.id($0) == id }) else { continue }
            let value = requested[id] ?? defaults["configOptions"].array?.first(where: { ACPConfigurationOptions.id($0) == id })?["currentValue"]
            guard let value, value != option["currentValue"] else { continue }
            let type = option["type"].string
            if type == "select" {
                guard value.string != nil, ACPConfigurationOptions.values(option).contains(where: { $0["value"] == value }) else { throw CoincideError("The selected value for \(option["name"].string ?? id) is not available.") }
            } else if type == "boolean" {
                guard value == .bool(true) || value == .bool(false) else { throw CoincideError("This agent option needs a boolean value.") }
            } else { if requested[id] != nil { throw CoincideError("This agent configuration type is not supported yet.") }; continue }
            let result = try await rpc.request("session/set_config_option", params: .object(["sessionId": .string(sessionID), "configId": .string(id), "value": value, "type": .string(type == "boolean" ? "boolean" : "id")]))
            guard result["configOptions"].array != nil else { throw CoincideError("The agent did not return its updated configuration.") }
            metadata("configOptions", result["configOptions"])
        }
    }
}

private final class ACP2Dispatch: @unchecked Sendable {
    private let lock = NSLock()
    private var id: JSONValue?
    private var result: Result<Void, any Error>?
    private var waiter: CheckedContinuation<Void, any Error>?
    var requestID: JSONValue? { lock.lock(); defer { lock.unlock() }; return id }
    func register(_ id: JSONValue) { lock.lock(); self.id = id; lock.unlock() }
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
