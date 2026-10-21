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
    private var initialized = false
    private var shuttingDown = false
    private var eventRunID: UUID?
    private var working = false
    private var requestedInterrupt = false
    private var messageID = ""
    private var initialization = JSONValue.null
    private var pendingApprovals: [JSONValue: ApprovalRequest] = [:]
    private var emittedAssistant = false

    public init(executable: URL, cwd: URL, resumeID: String? = nil, arguments: [String]? = nil) throws {
        let (events, continuation) = AsyncStream<ProviderEvent>.makeStream()
        self.events = events; self.continuation = continuation
        var args = arguments ?? ["--print", "--input-format", "stream-json", "--output-format", "stream-json",
            "--verbose", "--include-partial-messages", "--permission-prompt-tool", "stdio",
            "--allow-dangerously-skip-permissions"]
        if arguments == nil, let resumeID { args += ["--resume", resumeID] }
        rpc = try JSONRPCConnection(executable: executable, arguments: args, cwd: cwd, dialect: .claudeControl, maximumFrameSize: 128 * 1_024 * 1_024)
    }
    public func connect() async throws {
        guard !initialized else { return }
        logger.info("Claude connection starting")
        let stream = rpc.events
        reader = Task { [weak self] in for await event in stream { await self?.consume(event) } }
        do {
            initialization = try await rpc.request("initialize", params: .object(["hooks": .null]), timeout: .seconds(60))
        } catch {
            if error.localizedDescription == "initialize timed out." {
                throw CoincideError("Claude startup timed out. Check for a macOS file-access dialog, then try again. This attempt did not submit a model turn.")
            }
            throw error
        }
        initialized = true
        logger.info("Claude connection ready")
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
        guard !working else { throw CoincideError("A turn is already running in this thread.") }
        eventRunID = submittedRunID
        working = true; requestedInterrupt = false; emittedAssistant = false
        do {
            try await connect()
            _ = try await rpc.request("set_permission_mode", params: .object(["mode": .string(Self.permissionMode(thread.permission))]))
            _ = try await rpc.request("set_model", params: .object(["model": thread.model.isEmpty ? .null : .string(thread.model)]))
            let promptID = UUID().uuidString
            var images: [JSONValue] = input.images.map { image in
                .object(["type": .string("image"), "source": .object(["type": .string("base64"),
                    "media_type": .string(image.mimeType), "data": .string(image.data.base64EncodedString())])])
            }
            if !input.text.isEmpty { images.append(.object(["type": .string("text"), "text": .string(input.text)])) }
            let content: JSONValue = input.images.isEmpty ? .string(input.text) : .array(images)
            try await rpc.sendFrame(.object(["type": .string("user"), "uuid": .string(promptID),
                "message": .object(["role": .string("user"), "content": content]), "parent_tool_use_id": .null]))
            emit(.turn(promptID), runID: submittedRunID)
        } catch { working = false; throw error }
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
        shuttingDown = true; await rpc.close(); reader?.cancel(); reader = nil; continuation.finish()
    }
    private func consume(_ event: RPCEvent) async {
        switch event {
        case .barrier(let complete): complete()
        case .disconnected(let reason):
            if !shuttingDown { continuation.yield(.connectionClosed(reason)) }
            working = false; continuation.finish()
        case .request(let id, let method, let params):
            if method == "can_use_tool" {
                let request = ApprovalRequest(id: id, method: method, params: params)
                pendingApprovals[id] = request; emit(.approval(request))
            } else {
                try? await rpc.reject(id: id, message: "Coincide does not support this Claude control request yet.")
                emit(.message(.init(role: .system, text: "Unsupported Claude control request: \(method).")))
            }
        case .notification(let method, let frame):
            if let id = frame["session_id"].string { emit(.thread(id)) }
            switch method {
            case "control_cancel_request":
                let id = frame["request_id"]
                pendingApprovals.removeValue(forKey: id); emit(.approvalDismissed(id))
            case "stream_event": consumeStream(frame["event"])
            case "assistant": consumeAssistant(frame["message"])
            case "user":
                for block in frame["message"]["content"].array ?? [] where block["type"].string == "tool_result" {
                    let id = block["tool_use_id"].string ?? UUID().uuidString
                    let text = block["content"].string ?? (block["content"].array ?? []).compactMap { $0["text"].string }.joined(separator: "\n")
                    emit(.message(.init(id: "result-\(id)", role: .tool, text: text)))
                }
            case "result":
                working = false; pendingApprovals.removeAll()
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
    private func consumeStream(_ event: JSONValue) {
        switch event["type"].string {
        case "message_start": messageID = event["message"]["id"].string ?? UUID().uuidString
        case "content_block_start":
            let block = event["content_block"], id = blockID(index: event["index"])
            if block["type"].string == "tool_use" {
                let toolID = block["id"].string ?? id
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
    private func consumeAssistant(_ message: JSONValue) {
        let id = message["id"].string ?? UUID().uuidString
        for (index, block) in (message["content"].array ?? []).enumerated() {
            switch block["type"].string {
            case "text":
                emittedAssistant = true
                emit(.message(.init(id: "\(id)-\(index)", role: .assistant, text: block["text"].string ?? "")))
            case "thinking": emit(.message(.init(id: "\(id)-\(index)", role: .reasoning, text: block["thinking"].string ?? "")))
            case "tool_use":
                emit(.message(.init(id: block["id"].string ?? "\(id)-\(index)", role: .tool,
                    text: "\(block["name"].string ?? "Tool")\n\(block["input"].pretty)")))
            default: break
            }
        }
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
