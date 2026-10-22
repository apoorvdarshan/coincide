import Foundation

/// Native Pi JSONL RPC. The exact process, session file, and captured run own
/// output. ACKs are command admission; only settled+idle native evidence ends it.
public actor PiSession: ProviderSession {
    public nonisolated let events: AsyncStream<ProviderEvent>
    private let output: AsyncStream<ProviderEvent>.Continuation
    private let executable: URL
    private let cwd: URL
    private let configuration: PiConfiguration
    private let permission: PermissionMode
    private let arguments: [String]?
    private let requestTimeout: Duration
    private let steeringTimeout: Duration
    private var channel: ProcessChannel?
    private var reader: Task<Void, Never>?
    private var closeTask: Task<Void, Never>?
    private var decoder = NDJSONDecoder(maximumFrameSize: 128 * 1_024 * 1_024)
    private var scratch: URL?
    private var closing = false
    private var broken = false
    private var registered = false
    private var nativeID: String?
    private var baseline: PiState?
    private var appliedModel: PiModelSelection?
    private var appliedThinking: String?
    private var preparing: UUID?
    private var active: Run?
    private var generation: UInt64 = 0
    private var pending: [String: Pending] = [:]
    private var ui: [JSONValue: UI] = [:]
    private var nextID: UInt64 = 0
    private var settleTask: Task<Void, Never>?
    private var compacting = false
    private var steeringTasks: [UUID: Task<ProviderSteeringReceipt, any Error>] = [:]
    private var steeringMessages = Set<String>()
    private struct Pending {
        let command: String
        let runID: UUID?
        let continuation: CheckedContinuation<JSONValue, any Error>
        var timeout: Task<Void, Never>?
        var steering = false
        var writeStarted = false
    }
    private struct UI {
        let wireID: String
        let request: ApprovalRequest
        let expires: ContinuousClock.Instant?
        var responding = false
        var deadline: Task<Void, Never>?
    }
    private struct Run {
        let id: UUID
        let configuration: ProviderConfiguration
        var posted = false
        var started = false
        var interrupted = false
        var nativeAborted = false
        var failed = false
        var acknowledged = false
        var settleRequested = false
        var projection: PiProjection
    }
    public init(executable: URL, cwd: URL, configuration: PiConfiguration, permission: PermissionMode = .supervised) {
        self.executable = executable; self.cwd = cwd.standardizedFileURL.resolvingSymlinksInPath()
        self.configuration = configuration; self.permission = permission; self.arguments = nil
        requestTimeout = .seconds(15)
        steeringTimeout = .seconds(300)
        (events, output) = AsyncStream.makeStream()
    }
    /// Test-only literal invocation; production always owns --mode rpc and its
    /// approval extension. No shell interpolation or provider process reuse.
    init(executable: URL, cwd: URL, configuration: PiConfiguration, permission: PermissionMode = .supervised, arguments: [String], requestTimeout: Duration = .seconds(15), steeringTimeout: Duration = .seconds(300)) {
        self.executable = executable; self.cwd = cwd.standardizedFileURL.resolvingSymlinksInPath()
        self.configuration = configuration; self.permission = permission; self.arguments = arguments
        self.requestTimeout = requestTimeout
        self.steeringTimeout = steeringTimeout
        (events, output) = AsyncStream.makeStream()
    }
    private func connect() throws {
        guard !closing, !broken else { throw CoincideError(PiProtocol.failure) }
        guard channel == nil else { return }
        try configuration.validate()
        var args = arguments
        if args == nil {
            let root = FileManager.default.temporaryDirectory.appendingPathComponent("coincide-pi-\(UUID())", isDirectory: true)
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
            scratch = root
            let path = root.appendingPathComponent("permission.ts")
            try Data(PiProtocol.permissionExtension(permission).utf8).write(to: path, options: .atomic)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: path.path)
            args = ["--mode", "rpc", "--extension", path.path]
        }
        do {
            let process = try ProcessChannel(executable: executable, arguments: args ?? [], cwd: cwd, eventBufferLimit: 64)
            channel = process
            reader = Task { [weak self] in
                for await event in process.events { guard let self else { return }; await self.consume(event) }
                await self?.streamEnded()
            }
        } catch { if let scratch { try? FileManager.default.removeItem(at: scratch) }; scratch = nil; throw CoincideError(PiProtocol.failure) }
    }
    public func models() async throws -> [ProviderModel] {
        try connect()
        let result = try await request("get_available_models")
        return try PiProtocol.models(result)
    }
    public func send(text: String, thread: CodingThread) async throws { try await send(input: .init(text: text), thread: thread) }
    public func send(input: ProviderInput, thread: CodingThread) async throws {
        try ProviderSteeringValidation.input(input)
        let captured = thread.activeRun?.configuration ?? ProviderConfiguration(thread: thread)
        let resumeID = captured.nativeThreadID ?? thread.providerThreadID
        guard active == nil, preparing == nil, !closing, !broken, captured.provider == .pi,
              captured.piConfiguration?.runtimeIdentity == configuration.runtimeIdentity,
              captured.permission == permission,
              URL(fileURLWithPath: captured.workspacePath).standardizedFileURL.resolvingSymlinksInPath() == cwd else { throw CoincideError(PiProtocol.failure) }
        let token = UUID(); preparing = token
        defer { if preparing == token { preparing = nil } }
        try connect()
        let runID = thread.activeRun?.id ?? UUID()
        do {
            if !registered {
                if let resume = resumeID {
                    guard resume.hasPrefix("/"), resume.utf8.count <= 16_384, !resume.contains("\u{0}") else { throw CoincideError(PiProtocol.failure) }
                    let node = try PiProtocol.resumeHeader(resume, cwd: cwd)
                    let switched = try await request("switch_session", fields: ["sessionPath": .string(resume)], timeout: .seconds(60))
                    guard switched["cancelled"] == .bool(false) else { throw CoincideError(PiProtocol.rejected) }
                    let after = try PiProtocol.resumeHeader(resume, cwd: cwd)
                    guard node == after else { throw CoincideError(PiProtocol.failure) }
                }
                let observed = try PiProtocol.state(await request("get_state"))
                guard observed.idle, resumeID == nil || resumeID == observed.sessionFile else { throw CoincideError(PiProtocol.failure) }
                baseline = observed; nativeID = observed.sessionFile; registered = true
                appliedModel = observed.model; appliedThinking = observed.thinking
                emit(.thread(observed.sessionFile), runID: runID)
            }
            guard preparing == token, !closing, !broken, resumeID == nil || resumeID == nativeID else { throw CancellationError() }
            let selected = captured.piConfiguration?.model
            let targetModel = selected ?? baseline?.model
            if let targetModel, targetModel != appliedModel {
                let response = try await request("set_model", fields: ["provider": .string(targetModel.provider), "modelId": .string(targetModel.modelID)])
                guard response["provider"].string == targetModel.provider, response["id"].string == targetModel.modelID else { throw CoincideError(PiProtocol.failure) }
                appliedModel = targetModel
            } else if selected == nil, appliedModel != nil, baseline?.model == nil { throw CoincideError(PiProtocol.failure) }
            let thinking = captured.piConfiguration?.thinkingLevel ?? baseline?.thinking
            guard preparing == token, !closing, !broken else { throw CancellationError() }
            if let thinking, thinking != appliedThinking {
                _ = try await request("set_thinking_level", fields: ["level": .string(thinking)])
                appliedThinking = thinking
            }
            let observed = try PiProtocol.state(await request("get_state"))
            guard observed.sessionFile == nativeID, observed.idle,
                  targetModel == nil || observed.model == targetModel,
                  thinking == nil || observed.thinking == thinking,
                  preparing == token, !closing, !broken else { throw CoincideError(PiProtocol.failure) }
            try Task.checkCancellation()
            preparing = nil
            generation &+= 1
            steeringMessages.removeAll()
            active = .init(id: runID, configuration: captured, projection: .init(scope: "pi-\(configuration.instanceID)-\(observed.sessionFile)-\(runID)"))
            var fields: [String: JSONValue] = ["message": .string(input.text), "streamingBehavior": .string("steer")]
            if !input.images.isEmpty { fields["images"] = .array(input.images.map { .object(["type": .string("image"), "mimeType": .string($0.mimeType), "data": .string($0.data.base64EncodedString())]) }) }
            active?.posted = true
            // Async command response may be held by an extension dialog. The
            // ordered reader remains live; send completes after admission ACK.
            let acknowledgement = try await request("prompt", fields: fields, timeout: .seconds(300), runID: runID)
            if active?.id == runID {
                active?.acknowledged = true
                if acknowledgement["disposition"].string == "handled" { scheduleSettle(runID, allowNoStart: true) }
            }
        } catch {
            // Stronger than a command ACK: the exact owned run actually
            // settled and passed an idle probe while its RPC reply was lost.
            if error is PiObservedCompletion { return }
            if !registered, resumeID != nil { await failConnection() }
            if active?.id == runID {
                if error is PiRejected {
                    if active?.started == true { await failConnection() }
                    else { active = nil; emit(.failure(PiProtocol.rejected), runID: runID) }
                } else { await failConnection() }
            }
            if error is CancellationError { throw CancellationError() }
            throw CoincideError(error is PiRejected ? PiProtocol.rejected : PiProtocol.failure)
        }
    }
    public func steeringCapabilities() async -> ProviderSteeringCapabilities {
        guard !closing, !broken, registered, preparing == nil, let run = active,
              run.started, !run.interrupted, nativeID != nil else {
            return .init(unavailableReason: ProviderSteeringError(.noActiveTurn).localizedDescription)
        }
        guard !compacting, steeringTasks.isEmpty, !hasSteeringAdmission(run.id), steeringMessages.count < 64 else {
            return .init(unavailableReason: "Wait for Pi to finish its pending input or compaction before steering again.")
        }
        // Pi's tools finish before queued steering is consumed. There is no
        // native expected-turn CAS: this target is explicitly adapter-local.
        return .init(supportsActiveSteering: true, interruptsTools: false, target: .adapterRun(run.id))
    }
    public func steer(input: ProviderInput, thread: CodingThread, target: ProviderSteeringTarget,
                      clientMessageID: String) async throws -> ProviderSteeringReceipt {
        try Task.checkCancellation(); try target.validate()
        try ProviderSteeringValidation.id(clientMessageID); try ProviderSteeringValidation.input(input)
        guard case .adapterRun(let runID) = target else { throw ProviderSteeringError(.unsupported) }
        try requireSteeringTarget(thread, runID: runID)
        guard steeringMessages.count < 64, !steeringMessages.contains(clientMessageID), steeringTasks.isEmpty, !hasSteeringAdmission(runID) else {
            throw ProviderSteeringError(.rejected)
        }
        var fields: [String: JSONValue] = ["message": .string(input.text), "streamingBehavior": .string("steer")]
        var command = "prompt"
        let trimmed = input.text.trimmingCharacters(in: .whitespacesAndNewlines)
        let rest = trimmed.hasPrefix("/compact") ? String(trimmed.dropFirst("/compact".count)) : nil
        if let rest, rest.isEmpty || rest.first?.isWhitespace == true {
            guard input.images.isEmpty else { throw ProviderSteeringError(.invalidRequest) }
            command = "compact"; fields = [:]
            let instructions = rest.trimmingCharacters(in: .whitespacesAndNewlines)
            if !instructions.isEmpty { fields["customInstructions"] = .string(instructions) }
        }
        if !input.images.isEmpty {
            fields["images"] = .array(input.images.map { .object(["type": .string("image"), "mimeType": .string($0.mimeType), "data": .string($0.data.base64EncodedString())]) })
        }
        try ProviderSteeringValidation.frame(.object(fields))
        steeringMessages.insert(clientMessageID)
        let id = UUID(), payload = fields, nativeCommand = command
        let task = Task { try await self.submitSteering(command: nativeCommand, fields: payload, thread: thread, runID: runID) }
        steeringTasks[id] = task
        defer {
            steeringTasks.removeValue(forKey: id)
            if active?.id == runID { emit(.steeringCapabilitiesChanged, runID: runID) }
        }
        return try await withTaskCancellationHandler { try await task.value } onCancel: { task.cancel() }
    }
    private func requireSteeringTarget(_ thread: CodingThread, runID: UUID) throws {
        guard !closing, !broken, registered, preparing == nil, let run = active, run.started, !run.interrupted else {
            throw ProviderSteeringError(.noActiveTurn)
        }
        guard !compacting else { throw ProviderSteeringError(.unsupported) }
        guard run.id == runID, let presented = thread.activeRun, presented.id == runID,
              !presented.stopRequested, presented.nativeTurnID == nil,
              presented.configuration == run.configuration, run.configuration.provider == .pi, thread.provider == .pi,
              thread.providerThreadID == nativeID,
              run.configuration.nativeThreadID == nil || run.configuration.nativeThreadID == nativeID,
              run.configuration.piConfiguration?.runtimeIdentity == configuration.runtimeIdentity,
              run.configuration.permission == permission,
              URL(fileURLWithPath: run.configuration.workspacePath).standardizedFileURL.resolvingSymlinksInPath() == cwd else {
            throw ProviderSteeringError(.staleTarget)
        }
    }
    private func submitSteering(command: String, fields: [String: JSONValue], thread: CodingThread, runID: UUID) async throws -> ProviderSteeringReceipt {
        try Task.checkCancellation(); try requireSteeringTarget(thread, runID: runID)
        // Invalidate the old idle snapshot before handing anything to the
        // writer. Never reconfigure or start a new local run for this input.
        generation &+= 1; settleTask?.cancel(); settleTask = nil
        emit(.steeringCapabilitiesChanged, runID: runID)
        do {
            _ = try await request(command, fields: fields, timeout: steeringTimeout, runID: runID, steering: true)
            // Only an actual correlated native response reaches this point;
            // finish() deliberately cannot substitute observed run completion.
            return try .init(target: .adapterRun(runID), delivery: .acknowledged)
        } catch is PiRejected { throw ProviderSteeringError(.rejected) }
        catch let error as ProviderSteeringError { throw error }
        catch is CancellationError { throw CancellationError() }
        catch { throw ProviderSteeringError(.outcomeUncertain) }
    }
    private func hasSteeringAdmission(_ runID: UUID) -> Bool {
        pending.values.contains { $0.steering && $0.runID == runID }
    }
    private func steeringAdmissionRetired(_ runID: UUID?) {
        guard let runID, active?.id == runID else { return }
        emit(.steeringCapabilitiesChanged, runID: runID)
        if active?.settleRequested == true { scheduleSettle(runID) }
    }
    public func interrupt() async throws {
        let wasPreparing = preparing != nil
        preparing = nil
        guard !closing, !broken else { return }
        // A held lifecycle/model command can still mutate Pi after Stop.
        // Retire this runtime rather than admit a successor ahead of it.
        if wasPreparing { await failConnection(); throw CoincideError(PiProtocol.failure) }
        guard let run = active else { return }
        // An unresolved prompt may still be accepted after an idle/abort
        // observation. Pi cannot cancel that exact input by ID.
        if hasSteeringAdmission(run.id) { await failConnection(); throw CoincideError(PiProtocol.failure) }
        // An ACK can precede extension expansion/agent_start. Pi has no exact
        // prompt cancellation token; an idle read could precede that late work.
        guard run.started else { await failConnection(); throw CoincideError(PiProtocol.failure) }
        active?.interrupted = true; generation &+= 1; settleTask?.cancel()
        if compacting { await failConnection(); throw CoincideError(PiProtocol.failure) }
        do {
            _ = try await request("abort", runID: run.id)
            guard active?.id == run.id else { return }
            _ = try await request("clear_queue", runID: run.id)
            guard active?.id == run.id else { return }
            let state = try PiProtocol.state(await request("get_state", runID: run.id))
            guard state.sessionFile == nativeID, state.idle else { throw CoincideError(PiProtocol.failure) }
            if active?.id == run.id { finish(run.id, .interrupted) }
        } catch {
            if error is PiObservedCompletion { return }
            if active?.id == run.id { await failConnection() }
            throw CoincideError(PiProtocol.failure)
        }
    }
    public func interrupt(expectedRunID: UUID) async throws {
        guard active?.id == expectedRunID, preparing == nil, !closing, !broken else { throw CoincideError(PiProtocol.failure) }
        try await interrupt()
    }
    public func respond(_ request: ApprovalRequest, allow: Bool) async throws {
        let pending = try requireUI(request)
        let typed = try PiExtensionRequest.presentation(request)
        if typed.method == .confirm { try await replyUI(pending, payload: ["confirmed": .bool(allow)]) }
        else if !allow { try await replyUI(pending, payload: ["cancelled": .bool(true)]) }
        else { throw CoincideError(PiProtocol.rejected) }
    }
    public func answer(_ request: ApprovalRequest, answers: [String: String]) async throws {
        let pending = try requireUI(request), typed = try PiExtensionRequest.presentation(request)
        guard [.input, .editor].contains(typed.method), answers.count == 1, let answer = answers["value"], answer.utf8.count <= 1_048_576 else { throw CoincideError(PiProtocol.rejected) }
        try await replyUI(pending, payload: ["value": .string(answer)])
    }
    public func choose(_ request: ApprovalRequest, optionID: String) async throws {
        let pending = try requireUI(request), typed = try PiExtensionRequest.presentation(request)
        guard typed.method == .select, typed.options.contains(optionID) else { throw CoincideError(PiProtocol.rejected) }
        try await replyUI(pending, payload: ["value": .string(optionID)])
    }
    private func requireUI(_ request: ApprovalRequest) throws -> UI {
        guard let pending = ui[request.id], pending.request == request, !pending.responding,
              pending.expires.map({ $0 > .now }) ?? true, !closing, !broken else { throw CoincideError(PiProtocol.rejected) }
        return pending
    }
    private func replyUI(_ pendingUI: UI, payload: [String: JSONValue]) async throws {
        let localID = pendingUI.request.id
        ui[localID]?.responding = true
        do {
            var fields = payload; fields["type"] = .string("extension_ui_response"); fields["id"] = .string(pendingUI.wireID)
            try await write(.object(fields))
            ui.removeValue(forKey: localID)?.deadline?.cancel(); output.yield(.sessionApprovalDismissed(localID))
        } catch { await failConnection(); throw CoincideError(PiProtocol.failure) }
    }
    private func request(_ command: String, fields: [String: JSONValue] = [:], timeout: Duration? = nil, runID: UUID? = nil, steering: Bool = false) async throws -> JSONValue {
        guard pending.count < 64, !closing, !broken else {
            if steering { throw ProviderSteeringError(.rejected) }
            throw CoincideError(PiProtocol.failure)
        }
        nextID &+= 1; let id = "coincide-\(nextID)"
        let deadline = timeout ?? requestTimeout
        return try await withTaskCancellationHandler {
            try Task.checkCancellation()
            return try await withCheckedThrowingContinuation { continuation in
                pending[id] = .init(command: command, runID: runID, continuation: continuation)
                pending[id]?.steering = steering
                pending[id]?.timeout = Task { [weak self] in
                    do { try await Task.sleep(for: deadline) } catch { return }
                    await self?.requestFailed(id)
                }
                Task { [weak self] in
                    guard let self else { return }
                    var frame = fields; frame["type"] = .string(command); frame["id"] = .string(id)
                    do { try await self.writeRequest(id, frame: .object(frame)) } catch { await self.requestFailed(id, writeFailure: true) }
                }
            }
        } onCancel: { Task { await self.requestCancelled(id) } }
    }
    private func writeRequest(_ id: String, frame: JSONValue) async throws {
        // A settled run may have retired its missing response before this
        // queued command begins writing. Never send a stale abort afterward.
        guard let wait = pending[id] else { return }
        if wait.steering {
            guard active?.id == wait.runID, active?.interrupted == false, !closing, !broken else {
                pending.removeValue(forKey: id); wait.timeout?.cancel()
                wait.continuation.resume(throwing: ProviderSteeringError(.staleTarget)); return
            }
        }
        pending[id]?.writeStarted = true
        try await write(frame)
    }
    private func requestCancelled(_ id: String) async {
        guard let wait = pending[id] else { return }
        if wait.steering { await requestFailed(id) }
        else if ["get_state", "get_available_models"].contains(wait.command) {
            pending.removeValue(forKey: id); wait.timeout?.cancel()
            wait.continuation.resume(throwing: CancellationError())
        } else { await requestFailed(id) }
    }
    private func requestFailed(_ id: String, writeFailure: Bool = false) async {
        guard let wait = pending.removeValue(forKey: id) else { return }
        wait.timeout?.cancel()
        if wait.steering {
            wait.continuation.resume(throwing: ProviderSteeringError(wait.writeStarted ? .outcomeUncertain : .rejected))
            if wait.writeStarted || writeFailure { await failConnection() }
            else { steeringAdmissionRetired(wait.runID) }
            return
        }
        wait.continuation.resume(throwing: CoincideError(PiProtocol.failure))
        await failConnection()
    }
    private func write(_ frame: JSONValue) async throws {
        guard !closing, !broken, let channel else { throw CoincideError(PiProtocol.failure) }
        try await channel.writePayload { var bytes = try JSONEncoder().encode(frame); guard bytes.count <= 128 * 1_024 * 1_024 else { throw CoincideError(PiProtocol.failure) }; bytes.append(10); return bytes }
    }
    private func consume(_ event: ProcessEvent) async {
        guard !closing, !broken else { return }
        do {
            switch event {
            case .stderr: break // Never retain stderr, configuration, auth or errors from Pi.
            case .stdout(let data): for frame in try decoder.append(data) { try consume(frame) }
            case .exited: await failConnection()
            }
        } catch { await failConnection() }
    }
    private func consume(_ frame: JSONValue) throws {
        guard frame.object != nil, let type = frame["type"].string else { throw CoincideError(PiProtocol.failure) }
        if type == "response" {
            guard let id = frame["id"].string, let wait = pending[id] else { return }
            guard frame["command"].string == wait.command, case .bool(let success) = frame["success"] else { throw CoincideError(PiProtocol.failure) }
            pending.removeValue(forKey: id); wait.timeout?.cancel()
            if success { wait.continuation.resume(returning: frame["data"]) }
            else { wait.continuation.resume(throwing: PiRejected()) }
            if wait.steering { steeringAdmissionRetired(wait.runID) }
            return
        }
        if let file = frame["sessionFile"].string, file != nativeID { return }
        if let sessionID = frame["sessionId"].string, let expected = baseline?.sessionID, sessionID != expected { return }
        if type == "extension_ui_request" { try extensionUI(frame); return }
        if type == "agent_start" {
            guard active?.posted == true else { throw CoincideError(PiProtocol.failure) }
            generation &+= 1; settleTask?.cancel(); active?.started = true; active?.settleRequested = false
            active?.nativeAborted = false; active?.failed = false
            if let run = active { emit(.steeringCapabilitiesChanged, runID: run.id) }; return
        }
        guard var run = active, run.started else { return }
        if ["auto_compaction_start", "compaction_start", "auto_retry_start"].contains(type) { generation &+= 1; settleTask?.cancel() }
        if ["auto_compaction_start", "compaction_start"].contains(type) { compacting = true }
        if ["auto_compaction_end", "compaction_end"].contains(type) { compacting = false }
        if ["auto_compaction_start", "compaction_start", "auto_compaction_end", "compaction_end"].contains(type) { emit(.steeringCapabilitiesChanged, runID: run.id) }
        if type == "message_end", frame["message"]["role"].string == "assistant" {
            if frame["message"]["stopReason"].string == "error" { run.failed = true }
            if frame["message"]["stopReason"].string == "aborted" { run.nativeAborted = true }
        }
        if type == "auto_retry_end", frame["success"] == .bool(true) { run.failed = false }
        if type == "auto_retry_end", frame["success"] == .bool(false) { run.failed = true }
        let updates = try run.projection.apply(frame); active = run
        for update in updates { emit(.entity(update), runID: run.id) }
        if type == "extension_error" { emit(.message(.init(role: .system, text: "A Pi extension reported an error.")), runID: run.id) }
        if type == "agent_settled" {
            active?.settleRequested = true
            active?.nativeAborted = frame["aborted"] == .bool(true)
            scheduleSettle(run.id)
        }
        if ["auto_compaction_end", "compaction_end"].contains(type), active?.settleRequested == true { scheduleSettle(run.id) }
        // agent_end alone deliberately never completes a provider turn.
    }
    private func extensionUI(_ frame: JSONValue) throws {
        guard let method = frame["method"].string else { throw CoincideError(PiProtocol.failure) }
        if ["notify", "setStatus", "setWidget", "setTitle", "set_editor_text", "setEditorText", "setWorkingMessage"].contains(method) {
            if method == "notify", let text = frame["message"].string, text.utf8.count <= 16_384, let run = active { emit(.message(.init(role: .system, text: text)), runID: run.id) }
            return
        }
        guard PiExtensionRequest.Method(rawValue: method) != nil, ui.count < 64 else { throw CoincideError(PiProtocol.failure) }
        let wire = try PiProtocol.id(frame["id"])
        guard !ui.values.contains(where: { $0.wireID == wire }) else { throw CoincideError(PiProtocol.failure) }
        _ = try PiExtensionRequest(params: frame)
        let allowed = Set(["method", "title", "message", "options", "placeholder", "prefill"])
        let params = JSONValue.object((frame.object ?? [:]).filter { allowed.contains($0.key) })
        let request = ApprovalRequest(id: .string(UUID().uuidString), method: "pi/extension", params: params)
        let expires: ContinuousClock.Instant?
        if case .number(let milliseconds) = frame["timeout"] {
            guard milliseconds.isFinite, abs(milliseconds) <= 86_400_000 else { throw CoincideError(PiProtocol.failure) }
            expires = milliseconds == 0 ? nil : .now + .milliseconds(Int64(max(0, milliseconds)))
        } else { expires = nil }
        ui[request.id] = .init(wireID: wire, request: request, expires: expires)
        output.yield(.sessionApproval(request))
        if let expires {
            let localID = request.id
            ui[localID]?.deadline = Task { [weak self] in
                do { try await Task.sleep(until: expires, clock: .continuous) } catch { return }
                await self?.expireUI(localID)
            }
        }
    }
    private func expireUI(_ id: JSONValue) {
        guard let pending = ui.removeValue(forKey: id) else { return }
        pending.deadline?.cancel(); output.yield(.sessionApprovalDismissed(id))
    }
    private func scheduleSettle(_ id: UUID, allowNoStart: Bool = false) {
        guard active?.id == id, active?.started == true || allowNoStart, !hasSteeringAdmission(id) else { return }
        generation &+= 1; let captured = generation; settleTask?.cancel()
        settleTask = Task { [weak self] in
            guard let self else { return }
            do {
                // Native extensions can begin compaction immediately after settled.
                try await Task.sleep(for: .milliseconds(10))
                for attempt in 0..<3 {
                    let state = try PiProtocol.state(await self.request("get_state", runID: id))
                    if await self.settle(id, generation: captured, state: state) { return }
                    try Task.checkCancellation()
                    if attempt < 2 { try await Task.sleep(for: .milliseconds(100)) }
                }
                await self.failedSettle(id, generation: captured)
            } catch {
                if error is PiObservedCompletion { return }
                if !Task.isCancelled { await self.failConnection() }
            }
        }
    }
    private func settle(_ id: UUID, generation captured: UInt64, state: PiState) -> Bool {
        guard active?.id == id, captured == generation else { return true }
        guard state.sessionFile == nativeID, state.idle, let run = active, !hasSteeringAdmission(id) else { return false }
        finish(id, run.interrupted || run.nativeAborted ? .interrupted : run.failed ? .failed : .idle)
        return true
    }
    private func failedSettle(_ id: UUID, generation captured: UInt64) async {
        if active?.id == id, captured == generation { await failConnection() }
    }
    private func finish(_ id: UUID, _ state: ThreadState) {
        guard active?.id == id else { return }
        active = nil; compacting = false; generation &+= 1; settleTask = nil
        // Retire original-run RPC waiters using typed local completion proof,
        // never invent a wire acknowledgement or let their deadlines kill a
        // healthy successor. Unknown writes without this proof still fail shut.
        for key in pending.keys.filter({ pending[$0]?.runID == id && pending[$0]?.steering == false }) {
            if let wait = pending.removeValue(forKey: key) {
                wait.timeout?.cancel(); wait.continuation.resume(throwing: PiObservedCompletion())
            }
        }
        emit(.completed(state), runID: id)
    }
    private func emit(_ event: ProviderEvent, runID: UUID) { output.yield(.context(runID: runID, event: event)) }
    private func streamEnded() async { if !closing { await failConnection() } }
    private func failConnection() async {
        guard !broken, !closing else { return }; broken = true; preparing = nil; settleTask?.cancel()
        let run = active?.id; active = nil
        for wait in pending.values {
            wait.timeout?.cancel()
            if wait.steering { wait.continuation.resume(throwing: ProviderSteeringError(wait.writeStarted ? .outcomeUncertain : .rejected)) }
            else { wait.continuation.resume(throwing: CoincideError(PiProtocol.failure)) }
        }; pending.removeAll()
        for (id, pending) in ui { pending.deadline?.cancel(); output.yield(.sessionApprovalDismissed(id)) }; ui.removeAll()
        if let run { emit(.connectionClosed(PiProtocol.failure), runID: run) } else { output.yield(.connectionClosed(PiProtocol.failure)) }
        channel?.stop()
    }
    public func close() async {
        if let closeTask { await closeTask.value; return }
        closing = true; preparing = nil; settleTask?.cancel(); reader?.cancel()
        for wait in pending.values {
            wait.timeout?.cancel()
            if wait.steering { wait.continuation.resume(throwing: ProviderSteeringError(wait.writeStarted ? .outcomeUncertain : .rejected)) }
            else { wait.continuation.resume(throwing: CoincideError(PiProtocol.failure)) }
        }; pending.removeAll()
        for (id, pending) in ui { pending.deadline?.cancel(); output.yield(.sessionApprovalDismissed(id)) }; ui.removeAll(); active = nil
        let channel = channel, reader = reader, scratch = scratch, steering = Array(steeringTasks.values)
        for task in steering { task.cancel() }
        let task = Task {
            if let channel { await channel.stopAndDrain() }
            await reader?.value
            for task in steering { _ = await task.result }
            if let scratch { try? FileManager.default.removeItem(at: scratch) }
        }
        closeTask = task; await task.value; output.finish()
    }
}

private struct PiRejected: Error {}
private struct PiObservedCompletion: Error {}
