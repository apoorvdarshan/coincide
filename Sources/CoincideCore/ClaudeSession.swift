import Foundation
import OSLog

/// Implements Claude Code's bidirectional stream-json protocol directly in Swift.
/// The wire envelopes follow Anthropic's published Agent SDK transport.
public actor ClaudeSession: ProviderSession {
    private let logger = Logger(subsystem: "com.apoorvdarshan.coincide", category: "Claude")
    public nonisolated let events: AsyncStream<ProviderEvent>
    public nonisolated let supportsAppMCP: Bool
    private let continuation: AsyncStream<ProviderEvent>.Continuation
    private let rpc: JSONRPCConnection
    private let runtimeConfiguration: ClaudeRuntimeConfiguration?
    private let launchSelection: ClaudeResumeSelection?
    private var appMCPConnection: AppMCPConnection?
    private var appMCPRedaction: Task<Void, any Error>?
    private var historyEvidence: ClaudeRunHistoryEvidence?
    private var submittedOpening = false
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
    private struct PendingApproval {
        let request: ApprovalRequest
        let generation: Int
    }
    private var pendingApprovals: [JSONValue: PendingApproval] = [:]
    // A native question ID cannot be recycled into a later question in this process.
    private var resolvedApprovalIDs: Set<JSONValue> = []
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
    private var attemptedSteeringInputIDs: Set<String> = []

    public init(executable: URL, cwd: URL, resumeID: String? = nil, arguments: [String]? = nil,
                configuration: ClaudeRuntimeConfiguration? = nil, launchSelection: ClaudeResumeSelection? = nil) throws {
        let (events, continuation) = AsyncStream<ProviderEvent>.makeStream()
        self.events = events; self.continuation = continuation
        supportsAppMCP = configuration != nil && arguments == nil
        runtimeConfiguration = configuration; self.launchSelection = launchSelection
        var environment: [String: String]?
        if let configuration {
            try configuration.validate()
            guard executable.path == configuration.executable,
                  try ClaudeRuntimeValidation.physical(cwd.path, allowMissing: false) == configuration.workspacePath,
                  try ClaudeRuntimeValidation.configurationDirectory(configuration.configurationDirectorySelection) == configuration.configurationDirectory else { throw ClaudeRuntimeConfiguration.invalid() }
            var capturedEnvironment = ProcessChannel.environment()
            switch configuration.configurationDirectorySelection {
            case .defaultHome(let home):
                capturedEnvironment.removeValue(forKey: "CLAUDE_CONFIG_DIR")
                capturedEnvironment["HOME"] = home
            case .explicitDirectory(let path): capturedEnvironment["CLAUDE_CONFIG_DIR"] = path
            }
            capturedEnvironment["CLAUDE_CODE_PROJECT_DIR_NAME"] = configuration.projectDirectoryName
            capturedEnvironment.removeValue(forKey: "CLAUDE_CODE_DISABLE_PRECOMPACT_SKIP")
            environment = capturedEnvironment
        }
        var args = arguments ?? ["--print", "--input-format", "stream-json", "--output-format", "stream-json",
            "--verbose", "--include-partial-messages", "--permission-prompt-tool", "stdio",
            "--allow-dangerously-skip-permissions"]
        if let launchSelection {
            guard let configuration, arguments == nil else { throw ClaudeRuntimeConfiguration.invalid() }
            try launchSelection.validate(runtime: configuration)
            let store = try ClaudeTranscriptStore(configurationDirectory: URL(fileURLWithPath: configuration.configurationDirectory),
                workspace: URL(fileURLWithPath: configuration.workspacePath), projectDirectoryName: configuration.projectDirectoryName)
            switch launchSelection.kind {
            case .resumeAt:
                let snapshot = try store.read(sessionID: launchSelection.nativeSessionID)
                guard snapshot.location == launchSelection.reviewedLocation, snapshot.revision == launchSelection.reviewedRevision else {
                    throw ClaudeTranscriptStoreError(.sourceChanged)
                }
                args += ["--resume", launchSelection.nativeSessionID, "--resume-session-at=\(launchSelection.cursor!)"]
                // resumeDropsTurn is NOT enabled without a separate verified CLI
                // profile; selecting a local cursor does not claim that guard.
            case .freshSession:
                do {
                    _ = try store.read(sessionID: launchSelection.nativeSessionID)
                    throw ClaudeTranscriptStoreError(.collision)
                } catch let error as ClaudeTranscriptStoreError where error.kind == .notFound {}
                args += ["--session-id", launchSelection.nativeSessionID]
            }
            nativeThreadID = launchSelection.nativeSessionID
        } else {
            if arguments == nil, let resumeID { args += ["--resume", resumeID] }
            nativeThreadID = resumeID
        }
        rpc = try JSONRPCConnection(executable: executable, arguments: args, cwd: cwd, dialect: .claudeControl,
            maximumFrameSize: 128 * 1_024 * 1_024, environment: environment, drainProcessOnClose: true)
    }
    public func configureAppMCP(_ connection: AppMCPConnection) async throws {
        guard supportsAppMCP, !shuttingDown, !initialized, connecting == nil, appMCPConnection == nil else {
            throw Self.appMCPFailure()
        }
        appMCPConnection = connection
        let rpc = rpc
        let redaction = Task { try await rpc.configureAppMCPRedaction(connection) }
        appMCPRedaction = redaction
        try await redaction.value
        guard !shuttingDown else { throw Self.appMCPFailure() }
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
            let rpc = rpc, appMCP = appMCPConnection, redaction = appMCPRedaction
            connectingID = UUID()
            connecting = Task {
                try await redaction?.value
                let result = try await rpc.request("initialize", params: .object(["hooks": .null]), timeout: .seconds(60))
                if let appMCP {
                    do {
                        try Task.checkCancellation()
                        // Only this private, normal-path process owns dynamic
                        // registration. Settings/plugin servers remain native;
                        // never copy their potentially credential-bearing config.
                        let status = try await rpc.request("mcp_status")
                        try Self.validateAppMCPStatus(status)
                        let server: JSONValue = .object(["type": .string("http"),
                            "url": .string(appMCP.endpoint.absoluteString),
                            "headers": .object(["Authorization": .string(appMCP.authorizationHeader)]),
                            "timeout": .number(660_000)])
                        let registered = try await rpc.request("mcp_set_servers", params: .object([
                            "servers": .object(["coincide": server])]), timeout: .seconds(90))
                        try Self.validateAppMCPRegistration(registered)
                        try Task.checkCancellation()
                    } catch {
                        // Native status/control errors can echo headers. A
                        // partial/unknown registration cannot admit a prompt.
                        await rpc.close()
                        throw Self.appMCPFailure()
                    }
                }
                return result
            }
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
    private static func appMCPFailure() -> CoincideError {
        .init("Claude could not configure the app tools. This attempt did not submit a model turn.")
    }
    private static func validateAppMCPStatus(_ response: JSONValue) throws {
        guard let servers = response["mcpServers"].array, servers.count <= 256 else { throw appMCPFailure() }
        var names: Set<String> = []
        for server in servers {
            guard let name = server["name"].string, !name.isEmpty, name.utf8.count <= 512,
                  names.insert(name.lowercased()).inserted, name.lowercased() != "coincide" else { throw appMCPFailure() }
            // set_mcp_servers replaces other dynamic/SDK servers. A fresh
            // normal launch should have none; refuse rather than remove one.
            let source = server["source"].string ?? server["scope"].string
            guard let source, !source.isEmpty, source != "dynamic", source != "sdk" else { throw appMCPFailure() }
        }
    }
    private static func validateAppMCPRegistration(_ response: JSONValue) throws {
        guard response["added"].array == [.string("coincide")],
              response["removed"].array == [], let errors = response["errors"].object, errors.isEmpty else {
            throw appMCPFailure()
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
        let captured = thread.activeRun?.configuration ?? ProviderConfiguration(thread: thread)
        guard !shuttingDown else { throw CoincideError("The Claude connection is closed.") }
        guard !working else { throw CoincideError("A turn is already running in this thread.") }
        let expectedNative = captured.claudeLaunchSelection?.nativeSessionID ?? captured.nativeThreadID ?? thread.providerThreadID
        if let expected = expectedNative, let nativeThreadID, expected != nativeThreadID {
            throw CoincideError("The Claude conversation changed. Open a connection for the selected conversation before sending.")
        }
        if let runtimeConfiguration {
            guard captured.provider == .claude, captured.claudeRuntimeConfiguration == runtimeConfiguration,
                  captured.claudeLaunchSelection == launchSelection else { throw ClaudeRuntimeConfiguration.invalid() }
        } else if captured.claudeRuntimeConfiguration != nil || captured.claudeLaunchSelection != nil { throw ClaudeRuntimeConfiguration.invalid() }
        if nativeThreadID == nil { nativeThreadID = expectedNative }
        eventRunID = submittedRunID
        working = true; requestedInterrupt = false; emittedAssistant = false
        turnGeneration += 1
        let generation = turnGeneration
        activeConfiguration = captured; activeNativeThreadID = expectedNative ?? nativeThreadID
        activeTurnID = nil; steeringSubmitted = false; clearRootSubagents(); activeSubagentTasks = [:]
        submittedOpening = false
        attemptedSteeringInputIDs = []
        if let submittedRunID, let runtimeConfiguration {
            historyEvidence = try .init(runID: submittedRunID, runtimeIdentity: runtimeConfiguration.runtimeIdentity)
        } else { historyEvidence = nil }
        do {
            try await connect()
            guard ownsPreparing(generation) else { throw CancellationError() }
            _ = try await rpc.request("set_permission_mode", params: .object(["mode": .string(Self.permissionMode(captured.permission))]))
            guard ownsPreparing(generation) else { throw CancellationError() }
            _ = try await rpc.request("set_model", params: .object(["model": captured.model.isEmpty ? .null : .string(captured.model)]))
            guard ownsPreparing(generation) else { throw CancellationError() }
            await rpc.flushEvents()
            guard ownsPreparing(generation) else { throw CancellationError() }
            let promptID = submittedRunID.map(ClaudeInputIdentity.opening(runID:)) ?? UUID().uuidString
            activeTurnID = promptID
            var images: [JSONValue] = input.images.map { image in
                .object(["type": .string("image"), "source": .object(["type": .string("base64"),
                    "media_type": .string(image.mimeType), "data": .string(image.data.base64EncodedString())])])
            }
            if !input.text.isEmpty { images.append(.object(["type": .string("text"), "text": .string(input.text)])) }
            let content: JSONValue = input.images.isEmpty ? .string(input.text) : .array(images)
            submittedOpening = true
            try await rpc.sendFrame(.object(["type": .string("user"), "uuid": .string(promptID),
                "message": .object(["role": .string("user"), "content": content]), "parent_tool_use_id": .null]))
            emit(.turn(promptID), runID: submittedRunID)
        } catch { if generation == turnGeneration { working = false; activeTurnID = nil; submittedOpening = false }; throw error }
    }
    public func steeringCapabilities() async -> ProviderSteeringCapabilities {
        guard initialized, !shuttingDown else { return .init(unavailableReason: ProviderSteeringError(.unsupported).localizedDescription) }
        guard working, !requestedInterrupt, activeTurnID != nil, activeNativeThreadID != nil, eventRunID != nil else {
            return .init(unavailableReason: ProviderSteeringError(.noActiveTurn).localizedDescription)
        }
        guard activeRootSubagentTools.isEmpty else {
            return .init(interruptsTools: true, unavailableReason: "This turn has active agents that this connection cannot safely move to the background. Queue the message instead.")
        }
        guard attemptedSteeringInputIDs.count < ClaudeRunHistoryEvidence.maximumInputs - 1 else {
            return .init(unavailableReason: "This turn reached its retained input limit. Queue the next message instead.")
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
        // The native UUID is bound to the already-persisted authored row. It is
        // prospective history ownership, never a provider idempotency promise.
        let promptID = try ClaudeInputIdentity.steering(messageID: clientMessageID), id = UUID()
        guard !attemptedSteeringInputIDs.contains(promptID) else { throw ProviderSteeringError(.outcomeUncertain) }
        guard attemptedSteeringInputIDs.count < ClaudeRunHistoryEvidence.maximumInputs - 1 else { throw ProviderSteeringError(.unsupported) }
        try historyEvidence?.registerSteering(messageID: clientMessageID)
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
        guard let inputID = frame["uuid"].string, attemptedSteeringInputIDs.insert(inputID).inserted else { throw ProviderSteeringError(.outcomeUncertain) }
        steeringSubmitted = true
        do {
            try await rpc.sendFrame(frame)
            return try ProviderSteeringReceipt(turnID: expectedTurnID, delivery: .submitted)
        } catch { throw ProviderSteeringError(.outcomeUncertain) }
    }
    public func interrupt() async throws {
        guard working else { throw CoincideError("There is no active Claude turn to stop.") }
        requestedInterrupt = true
        let generation = turnGeneration
        do { _ = try await rpc.request("interrupt") }
        catch { if generation == turnGeneration { requestedInterrupt = false }; throw error }
    }
    public func respond(_ request: ApprovalRequest, allow: Bool) async throws {
        try validatePending(request)
        guard !request.isClaudeQuestion || !allow else {
            throw CoincideError("Answer Claude's questions before submitting them.")
        }
        let response: JSONValue = allow
            ? .object(["behavior": .string("allow"), "updatedInput": request.params["input"]])
            : .object(["behavior": .string("deny"), "message": .string(request.isClaudeQuestion
                ? "User cancelled the questions in Coincide." : "Declined by the user in Coincide.")])
        try await submitResponse(request, result: response)
    }
    public func answer(_ request: ApprovalRequest, answers: [String: String]) async throws {
        try validatePending(request)
        let question = try ClaudeQuestionRequest(request: request)
        try await submitResponse(request, result: question.response(answers: answers))
    }
    public func selectAnswers(_ request: ApprovalRequest, selections: [String: [String]]) async throws {
        try await selectAnswers(request, selections: selections, notes: [:])
    }
    public func selectAnswers(_ request: ApprovalRequest, selections: [String: [String]], notes: [String: String]) async throws {
        try validatePending(request)
        let question = try ClaudeQuestionRequest(request: request)
        try await submitResponse(request, result: question.response(selections: selections, notes: notes))
    }
    private func validatePending(_ request: ApprovalRequest) throws {
        guard !shuttingDown, let pending = pendingApprovals[request.id], Self.sameRequest(pending.request, request),
              pending.generation == turnGeneration else { throw CoincideError("This Claude request is no longer pending.") }
        if request.isClaudeQuestion {
            guard working, submittedOpening, activeTurnID != nil, !requestedInterrupt else {
                throw CoincideError("This Claude question is no longer pending.")
            }
        }
    }
    private func submitResponse(_ request: ApprovalRequest, result: JSONValue) async throws {
        // Remove before the transport await so concurrent clicks and replays
        // cannot send a second answer if the write's outcome is uncertain.
        try validatePending(request)
        pendingApprovals.removeValue(forKey: request.id)
        if request.isClaudeQuestion { resolvedApprovalIDs.insert(request.id) }
        try await rpc.respond(id: request.id, result: result)
    }
    private static func sameRequest(_ lhs: ApprovalRequest, _ rhs: ApprovalRequest) -> Bool {
        // String equality folds canonically equivalent Unicode. Wire question
        // keys and native inputs must retain their exact original spelling.
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        guard let left = try? encoder.encode(lhs), let right = try? encoder.encode(rhs) else { return false }
        return left == right
    }
    public func close() async {
        if let closeTask { await closeTask.value; return }
        shuttingDown = true; working = false; pendingApprovals.removeAll()
        connecting?.cancel()
        let rpc = rpc, reading = reader, steering = steeringTask?.task, initializing = connecting,
            redaction = appMCPRedaction, continuation = continuation
        let task = Task {
            await rpc.close()
            _ = try? await redaction?.value
            _ = try? await initializing?.value
            _ = try? await steering?.value
            reading?.cancel(); await reading?.value
            continuation.finish()
        }
        closeTask = task
        await task.value
        reader = nil; steeringTask = nil; appMCPConnection = nil; appMCPRedaction = nil
    }
    private func consume(_ event: RPCEvent) async {
        switch event {
        case .callback(let work): await work()
        case .barrier(let complete): complete()
        case .disconnected(let reason):
            if !shuttingDown { continuation.yield(.connectionClosed(reason)) }
            working = false; pendingApprovals.removeAll(); continuation.finish()
        case .request(let id, let method, let params):
            guard !shuttingDown else { return }
            if method == "can_use_tool" {
                let request = ApprovalRequest(id: id, method: method, params: params)
                guard let requestID = id.string, !requestID.isEmpty, requestID.utf8.count <= 1_024,
                      !requestID.contains("\0"),
                      resolvedApprovalIDs.count < 16_384, !resolvedApprovalIDs.contains(id) else {
                    try? await rpc.reject(id: id, message: "Claude sent an invalid or resolved control request."); return
                }
                if let pending = pendingApprovals[id] {
                    if Self.sameRequest(pending.request, request), pending.generation == turnGeneration { return }
                    pendingApprovals.removeValue(forKey: id)
                    if pending.request.isClaudeQuestion || request.isClaudeQuestion { resolvedApprovalIDs.insert(id) }
                    emit(.approvalDismissed(id))
                    try? await rpc.reject(id: id, message: "Claude changed a pending control request."); return
                }
                guard pendingApprovals.count < 64 else {
                    try? await rpc.reject(id: id, message: "Claude has too many pending control requests."); return
                }
                if request.isClaudeQuestion {
                    guard working, submittedOpening, activeTurnID != nil, !requestedInterrupt,
                          (try? ClaudeQuestionRequest(request: request)) != nil else {
                        resolvedApprovalIDs.insert(id)
                        try? await rpc.reject(id: id, message: "Claude sent an invalid or inactive question request."); return
                    }
                }
                pendingApprovals[id] = .init(request: request, generation: turnGeneration)
                emit(.approval(request))
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
            if isRoot { observeHistoryFrame(frame, method: method) }
            switch method {
            case "control_cancel_request":
                let id = frame["request_id"]
                if let pending = pendingApprovals.removeValue(forKey: id) {
                    if pending.request.isClaudeQuestion { resolvedApprovalIDs.insert(id) }; emit(.approvalDismissed(id))
                }
            case "stream_event":
                guard !isRoot || !working || submittedOpening else { return }
                consumeStream(frame["event"], isRoot: isRoot)
            case "assistant":
                guard !isRoot || !working || submittedOpening else { return }
                consumeAssistant(frame["message"], isRoot: isRoot)
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
                guard isRoot, working, submittedOpening, resultBelongsToCurrentInput(frame) else { return }
                if steeringSubmitted, !requestedInterrupt,
                   ["aborted_tools", "aborted_streaming"].contains(frame["terminal_reason"].string ?? "") { return }
                let terminal: ThreadRunStatus = requestedInterrupt ? .interrupted : (frame["is_error"] == .bool(true) ? .failed : .completed)
                finishHistory(terminal)
                working = false
                for (id, pending) in pendingApprovals where pending.request.isClaudeQuestion { resolvedApprovalIDs.insert(id) }
                pendingApprovals.removeAll()
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
    private func ownsPreparing(_ generation: Int) -> Bool {
        generation == turnGeneration && working && !requestedInterrupt && !shuttingDown && !Task.isCancelled
    }
    private func stampedInputIDs(_ frame: JSONValue) -> [String] {
        if let inputs = frame["user_message_uuids"].array, inputs.count <= 64 {
            return inputs.compactMap(\.string)
        }
        return frame["user_message_uuid"].string.map { [$0] } ?? []
    }
    private func resultBelongsToCurrentInput(_ frame: JSONValue) -> Bool {
        let stamped = stampedInputIDs(frame)
        guard !stamped.isEmpty else { return true } // Older native producers omit stamps.
        let registered = historyEvidence?.registeredInputIDs ?? ([activeTurnID].compactMap { $0 } + Array(attemptedSteeringInputIDs))
        return stamped.contains(where: { registered.contains($0) })
    }
    private func observeHistoryFrame(_ frame: JSONValue, method: String) {
        guard working, !shuttingDown, var evidence = historyEvidence, evidence.runID == eventRunID,
              let sessionID = frame["session_id"].string, nativeThreadID == sessionID,
              frame["replayed"] != .bool(true), frame["isReplay"] != .bool(true) else { return }
        let old = evidence
        do {
            // Root init is a session observation, never proof an input was sent.
            guard submittedOpening || (method == "system" && frame["subtype"].string == "init") else { return }
            let stamped = stampedInputIDs(frame)
            if !stamped.isEmpty, !stamped.contains(where: { evidence.registeredInputIDs.contains($0) }) { return }
            var observed = stamped.filter { evidence.registeredInputIDs.contains($0) }
            if method == "user", let input = frame["uuid"].string, evidence.registeredInputIDs.contains(input), !observed.contains(input) { observed.append(input) }
            for input in observed where !steerEchoes.contains(input) {
                steerEchoes.append(input); if steerEchoes.count > 128 { steerEchoes.removeFirst() }
            }
            // Both required native envelope owners must be present. Nested API
            // message.id and sidechain UUIDs are never history cursor evidence.
            let assistantID = method == "assistant" && frame.object?.keys.contains("parent_tool_use_id") == true
                && frame["parent_tool_use_id"] == .null ? frame["uuid"].string : nil
            try evidence.observe(nativeSessionID: sessionID, inputIDs: observed, rootAssistantMessageID: assistantID)
            historyEvidence = evidence
            if evidence != old { emit(.claudeHistoryEvidence(evidence), runID: evidence.runID) }
        } catch {
            // Keep the ordinary transcript, but an incomplete native audit must
            // never later acquire a successful terminal boundary by omission.
            historyEvidence = nil
        }
    }
    private func finishHistory(_ status: ThreadRunStatus) {
        guard var evidence = historyEvidence, evidence.runID == eventRunID else { return }
        do {
            try evidence.finish(status); historyEvidence = evidence
            emit(.claudeHistoryEvidence(evidence), runID: evidence.runID)
        } catch { historyEvidence = nil }
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
