import Foundation

/// Native stdio client for the same Codex app-server protocol used by T3 Code.
public actor CodexSession: ProviderSession {
    public nonisolated let events: AsyncStream<ProviderEvent>
    private let continuation: AsyncStream<ProviderEvent>.Continuation
    private let rpc: JSONRPCConnection
    private var eventTask: Task<Void, Never>?
    private var threadID: String?
    private var turnID: String?
    private var completedTurnIDs: [String] = []
    private var sendGeneration = 0
    private var initialized = false
    private var working = false
    private var shuttingDown = false
    private var eventRunID: UUID?

    public init(executable: URL, cwd: URL, arguments: [String] = ["app-server", "--stdio"]) throws {
        let (events, continuation) = AsyncStream<ProviderEvent>.makeStream()
        self.events = events; self.continuation = continuation
        rpc = try JSONRPCConnection(executable: executable, arguments: arguments, cwd: cwd, maximumFrameSize: 128 * 1_024 * 1_024)
    }
    public func connect() async throws {
        guard !initialized else { return }
        let stream = rpc.events
        eventTask = Task { [weak self] in
            for await event in stream { await self?.consume(event) }
        }
        _ = try await rpc.request("initialize", params: .object([
            "clientInfo": .object(["name": .string("coincide"), "title": .string("Coincide"), "version": .string("0.1.0")]),
            "capabilities": .object(["experimentalApi": .bool(true)])
        ]))
        try await rpc.notify("initialized"); initialized = true
    }
    public func models() async throws -> [ProviderModel] {
        try await connect()
        let response = try await rpc.request("model/list", params: .object(["limit": .number(100)]))
        return (response["data"].array ?? []).compactMap {
            guard let id = $0["model"].string ?? $0["id"].string else { return nil }
            return ProviderModel(id: id, name: $0["displayName"].string ?? id)
        }
    }
    public func send(text: String, thread: CodingThread) async throws {
        try await send(input: ProviderInput(text: text), thread: thread)
    }
    public func send(input: ProviderInput, thread: CodingThread) async throws {
        guard !working else { throw CoincideError("A turn is already running in this thread.") }
        working = true
        sendGeneration += 1
        let generation = sendGeneration, submittedRunID = thread.activeRun?.id
        eventRunID = submittedRunID
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
                } else { response = try await rpc.request("thread/start", params: .object(params)) }
                guard let id = response["thread"]["id"].string else { throw CoincideError("Codex did not return a thread id.") }
                threadID = id; emit(.thread(id))
            }
            var items: [JSONValue] = input.text.isEmpty ? [] : [.object(["type": .string("text"), "text": .string(input.text)])]
            items += input.images.map { .object(["type": .string("image"), "url": .string("data:\($0.mimeType);base64,\($0.data.base64EncodedString())")]) }
            var params: [String: JSONValue] = ["threadId": .string(threadID!), "cwd": .string(thread.workspacePath),
                "input": .array(items),
                "approvalPolicy": thread.permission.approvalPolicy, "approvalsReviewer": thread.permission.reviewer,
                "sandboxPolicy": thread.permission.sandbox(cwd: thread.workspacePath)]
            if !thread.model.isEmpty { params["model"] = .string(thread.model) }
            let response = try await rpc.request("turn/start", params: .object(params))
            guard let id = response["turn"]["id"].string else { throw CoincideError("Codex did not return a turn id.") }
            if generation == sendGeneration, !completedTurnIDs.contains(id) { turnID = id; emit(.turn(id), runID: submittedRunID) }
        } catch { if generation == sendGeneration { working = false }; throw error }
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
        shuttingDown = true; await rpc.close(); eventTask?.cancel(); eventTask = nil; continuation.finish()
    }
    private func consume(_ event: RPCEvent) async {
        switch event {
        case .callback(let work): await work()
        case .barrier(let complete): complete()
        case .disconnected(let reason):
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
