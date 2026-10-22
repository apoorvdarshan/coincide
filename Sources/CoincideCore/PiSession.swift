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
    private var observedVersion: String?
    private var versionTask: Task<String, any Error>?
    private var prepared: Prepared?
    private var steeringPreparation: PiSteeringHistoryPreparation?
    private struct Prepared {
        let proof: PiRunHistoryPreparation
        let configuration: ProviderConfiguration
        let state: PiState
        let generation: UInt64
    }
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
        var history: PiRunHistoryEvidence?
        var admissionGeneration: UInt64?
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
            let environment: [String: String]
            if let runtime = configuration.runtime {
                guard executable.path == runtime.executable, try PiRuntimeConfiguration.physical(cwd.path) == runtime.workspacePath else { throw PiRuntimeConfiguration.invalid() }
                environment = try runtime.environment()
            } else { environment = ProcessChannel.environment() }
            let process = try ProcessChannel(executable: executable, arguments: args ?? [], cwd: cwd, environment: environment, eventBufferLimit: 64)
            channel = process
            reader = Task { [weak self] in
                for await event in process.events { guard let self else { return }; await self.consume(event) }
                await self?.streamEnded()
            }
        } catch { if let scratch { try? FileManager.default.removeItem(at: scratch) }; scratch = nil; throw CoincideError(PiProtocol.failure) }
    }
    public func models() async throws -> [ProviderModel] {
        if configuration.runtime != nil { _ = try await verifyVersion() }
        try connect()
        let result = try await request("get_available_models")
        return try PiProtocol.models(result)
    }
    private func verifyVersion() async throws -> String {
        if let observedVersion { return observedVersion }
        if let versionTask { return try await versionTask.value }
        guard let runtime = configuration.runtime, !closing, !broken else { throw PiRuntimeConfiguration.invalid() }
        let environment = try runtime.environment(), executable = executable, cwd = cwd
        let task = Task { try await Self.probeVersion(executable: executable, cwd: cwd, environment: environment) }
        versionTask = task
        defer { versionTask = nil }
        let version = try await withTaskCancellationHandler { try await task.value } onCancel: { task.cancel() }
        try Task.checkCancellation(); guard !closing, !broken else { throw CancellationError() }
        observedVersion = version; return version
    }
    private static func probeVersion(executable: URL, cwd: URL, environment: [String: String]) async throws -> String {
        // Pi reads bootstrap settings before --version. Preserve the selected
        // namespace; this is a no-model probe, not a claim of zero filesystem I/O.
        let process = try ProcessChannel(executable: executable, arguments: ["--version"], cwd: cwd, environment: environment, eventBufferLimit: 8)
        let deadline = Task {
            do { try await Task.sleep(for: .seconds(4)); process.stop() } catch { }
        }
        do {
            let bytes = try await withTaskCancellationHandler {
                var output = Data(), count = 0
                for await event in process.events {
                    switch event {
                    case .stdout(let data): count += data.count; output.append(data)
                    case .stderr(let data): count += data.count
                    case .exited: break
                    }
                    guard count <= 8_192 else { throw CoincideError(PiProtocol.failure) }
                    try Task.checkCancellation()
                }
                return output
            } onCancel: { process.stop() }
            deadline.cancel(); await deadline.value
            let status = await process.stopAndDrain()
            try Task.checkCancellation(); guard status == 0, !process.outputOverflowed else { throw CoincideError(PiProtocol.failure) }
            return try PiProtocol.observedVersion(bytes)
        } catch {
            deadline.cancel(); process.stop(); _ = await process.stopAndDrain(); await deadline.value
            throw error
        }
    }

    public func preparePiRun(input: ProviderInput, thread: CodingThread) async throws -> PiRunHistoryPreparation {
        try ProviderSteeringValidation.input(input)
        let captured = thread.activeRun?.configuration ?? ProviderConfiguration(thread: thread)
        guard let runID = thread.activeRun?.id, let runtime = captured.piConfiguration?.runtime,
              captured.provider == .pi, captured.piConfiguration?.runtimeIdentity == configuration.runtimeIdentity,
              captured.permission == permission, runtime.registeredWorkspacePath == captured.workspacePath,
              active == nil, preparing == nil, !closing, !broken,
              let openingID = thread.runHistory?.first(where: { $0.id == runID })?.userMessageID else { throw PiRuntimeConfiguration.invalid() }
        let token = UUID(); preparing = token
        do {
            let version = try await verifyVersion(); try connect()
            let resume = captured.nativeThreadID ?? thread.providerThreadID
            if !registered {
                if let resume {
                    let before = try PiProtocol.resumeHeader(resume, cwd: cwd)
                    let result = try await request("switch_session", fields: ["sessionPath": .string(resume)], timeout: .seconds(60))
                    guard result["cancelled"] == .bool(false), before == (try PiProtocol.resumeHeader(resume, cwd: cwd)) else { throw CoincideError(PiProtocol.rejected) }
                }
                let state = try PiProtocol.state(await request("get_state"))
                guard state.idle, resume == nil || resume == state.sessionFile else { throw CoincideError(PiProtocol.failure) }
                baseline = state; nativeID = state.sessionFile; registered = true
                appliedModel = state.model; appliedThinking = state.thinking
                emit(.thread(state.sessionFile), runID: runID)
            }
            guard preparing == token, !closing, !broken, resume == nil || resume == nativeID else { throw CancellationError() }
            let model = captured.piConfiguration?.model ?? baseline?.model
            if let model, model != appliedModel {
                let result = try await request("set_model", fields: ["provider": .string(model.provider), "modelId": .string(model.modelID)])
                guard result["provider"].string == model.provider, result["id"].string == model.modelID else { throw CoincideError(PiProtocol.failure) }
                appliedModel = model
            } else if captured.piConfiguration?.model == nil, appliedModel != nil, baseline?.model == nil { throw CoincideError(PiProtocol.failure) }
            guard preparing == token, !closing, !broken else { throw CancellationError() }
            let thinking = captured.piConfiguration?.thinkingLevel ?? baseline?.thinking
            if let thinking, thinking != appliedThinking {
                _ = try await request("set_thinking_level", fields: ["level": .string(thinking)]); appliedThinking = thinking
            }
            let before = try PiProtocol.state(await request("get_state"))
            let entries = try PiProtocol.entries(await request("get_entries"), state: before)
            let after = try PiProtocol.state(await request("get_state"))
            guard before == after, after.idle, after.sessionFile == nativeID,
                  model == nil || after.model == model, thinking == nil || after.thinking == thinking,
                  preparing == token, !closing, !broken, ui.isEmpty else { throw CoincideError(PiProtocol.historyFailure) }
            let opening = try PiHistoryInputEvidence(clientMessageID: openingID, inputDigest: PiHistoryInputEvidence.digest(input), kind: .opening)
            let proof = try PiRunHistoryPreparation(id: token, runID: runID, runtimeIdentity: configuration.runtimeIdentity,
                observedVersion: version, openingInput: opening, baseline: entries.observation)
            prepared = .init(proof: proof, configuration: captured, state: after, generation: generation)
            return proof
        } catch {
            if preparing == token { preparing = nil; prepared = nil }
            // Uncertain lifecycle/config writes cannot remain live for a successor.
            await failConnection(); throw error
        }
    }

    public func sendPreparedPi(input: ProviderInput, thread: CodingThread, preparation: PiRunHistoryPreparation) async throws {
        try preparation.validate(); try Task.checkCancellation()
        let captured = thread.activeRun?.configuration ?? ProviderConfiguration(thread: thread)
        guard let owned = prepared, owned.proof == preparation, preparing == preparation.id,
              preparation.runID == thread.activeRun?.id, owned.configuration == captured,
              try PiHistoryInputEvidence.digest(input) == preparation.inputDigest,
              let durable = thread.runHistory?.first(where: { $0.id == preparation.runID })?.pi,
              durable.preparation == preparation, durable.captureStatus == .prepared,
              durable.inputs == [preparation.openingInput], active == nil, generation == owned.generation,
              !closing, !broken else { throw CoincideError(PiProtocol.historyFailure) }
        try durable.validate()
        do {
            let state = try PiProtocol.state(await request("get_state"))
            let entries = try PiProtocol.entries(await request("get_entries"), state: state)
            guard state == owned.state, state.idle, entries.observation == preparation.baseline,
                  prepared?.proof == preparation, preparing == preparation.id, generation == owned.generation,
                  !closing, !broken, ui.isEmpty else { throw CoincideError(PiProtocol.historyFailure) }
            try Task.checkCancellation()
            prepared = nil; preparing = nil; generation &+= 1; steeringMessages.removeAll()
            active = .init(id: preparation.runID, configuration: captured, history: durable, admissionGeneration: generation,
                projection: .init(scope: "pi-\(configuration.instanceID)-\(preparation.nativeSessionFile)-\(preparation.runID)"))
            var fields: [String: JSONValue] = ["message": .string(input.text), "streamingBehavior": .string("steer")]
            if !input.images.isEmpty { fields["images"] = .array(input.images.map { .object(["type": .string("image"), "mimeType": .string($0.mimeType), "data": .string($0.data.base64EncodedString())]) }) }
            let acknowledgement = try await request("prompt", fields: fields, timeout: .seconds(300), runID: preparation.runID)
            if active?.id == preparation.runID {
                active?.acknowledged = true
                if acknowledgement["disposition"].string == "handled" { scheduleSettle(preparation.runID, allowNoStart: true) }
            }
        } catch {
            if error is PiObservedCompletion { return }
            await failConnection(); throw error
        }
    }
    public func send(text: String, thread: CodingThread) async throws { try await send(input: .init(text: text), thread: thread) }
    public func send(input: ProviderInput, thread: CodingThread) async throws {
        try ProviderSteeringValidation.input(input)
        let captured = thread.activeRun?.configuration ?? ProviderConfiguration(thread: thread)
        guard captured.piConfiguration?.runtime == nil else { throw CoincideError("Commit the prepared Pi input before sending it.") }
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
        guard !compacting, steeringTasks.isEmpty, steeringPreparation == nil, !hasSteeringAdmission(run.id), steeringMessages.count < 64 else {
            return .init(unavailableReason: "Wait for Pi to finish its pending input or compaction before steering again.")
        }
        // Pi's tools finish before queued steering is consumed. There is no
        // native expected-turn CAS: this target is explicitly adapter-local.
        return .init(supportsActiveSteering: true, interruptsTools: false, target: .adapterRun(run.id))
    }
    public func preparePiSteering(input: ProviderInput, thread: CodingThread, target: ProviderSteeringTarget,
                                 clientMessageID: String) async throws -> PiSteeringHistoryPreparation {
        try Task.checkCancellation(); try target.validate()
        guard configuration.runtime != nil, case .adapterRun(let runID) = target else { throw ProviderSteeringError(.unsupported) }
        try requireSteeringTarget(thread, runID: runID)
        guard steeringPreparation == nil, steeringTasks.isEmpty, !hasSteeringAdmission(runID),
              steeringMessages.count < 64, !steeringMessages.contains(clientMessageID),
              let history = active?.history else { throw ProviderSteeringError(.rejected) }
        let input = try PiHistoryInputEvidence.steering(clientMessageID: clientMessageID, input: input)
        let reservation = try PiSteeringHistoryPreparation(runID: runID, runPreparationID: history.preparation.id,
            runtimeIdentity: history.runtimeIdentity, input: input)
        steeringPreparation = reservation; generation &+= 1; settleTask?.cancel(); settleTask = nil
        emit(.steeringCapabilitiesChanged, runID: runID)
        return reservation
    }
    public func sendPreparedPiSteering(input: ProviderInput, thread: CodingThread, target: ProviderSteeringTarget,
                                      clientMessageID: String, preparation: PiSteeringHistoryPreparation) async throws -> ProviderSteeringReceipt {
        try preparation.validate()
        defer { releaseSteeringPreparation(preparation.id) }
        guard steeringPreparation == preparation, target == .adapterRun(preparation.runID),
              preparation.input == (try PiHistoryInputEvidence.steering(clientMessageID: clientMessageID, input: input)),
              active?.history?.preparation.id == preparation.runPreparationID else { throw ProviderSteeringError(.staleTarget) }
        return try await steer(input: input, thread: thread, target: target, clientMessageID: clientMessageID)
    }
    public func cancelPiSteeringPreparation(_ preparation: PiSteeringHistoryPreparation) async {
        guard steeringPreparation == preparation else { return }; releaseSteeringPreparation(preparation.id)
    }
    private func releaseSteeringPreparation(_ id: UUID) {
        guard let held = steeringPreparation, held.id == id else { return }
        steeringPreparation = nil
        guard !closing, !broken, active?.id == held.runID else { return }
        emit(.steeringCapabilitiesChanged, runID: held.runID)
        if active?.settleRequested == true { scheduleSettle(held.runID) }
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
        if configuration.runtime != nil {
            let expected = try PiHistoryInputEvidence.steering(clientMessageID: clientMessageID, input: input)
            guard steeringPreparation?.input == expected, steeringPreparation?.runID == runID,
                  steeringPreparation?.runPreparationID == active?.history?.preparation.id,
                  active?.history?.inputs.contains(expected) == true else { throw ProviderSteeringError(.staleTarget) }
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
            if let held = steeringPreparation, held.runID == runID, held.input.clientMessageID == clientMessageID { releaseSteeringPreparation(held.id) }
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
        if configuration.runtime != nil {
            guard let previous = run.history, let durable = thread.runHistory?.first(where: { $0.id == runID })?.pi,
                  durable.captureStatus == .prepared, durable.preparation == previous.preparation,
                  durable.inputs.count >= previous.inputs.count,
                  Array(durable.inputs.prefix(previous.inputs.count)) == previous.inputs else { throw ProviderSteeringError(.staleTarget) }
            try durable.validate(); active?.history = durable
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
        if let held = steeringPreparation { releaseSteeringPreparation(held.id) }
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
            if active?.id == run.id {
                guard await finishObserved(run.id, state: .interrupted, generation: generation, observed: state) else { throw CoincideError(PiProtocol.failure) }
            }
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
        if wait.command == "prompt", !wait.steering, let fence = active?.admissionGeneration {
            guard active?.id == wait.runID, active?.interrupted == false, generation == fence,
                  !closing, !broken else {
                pending.removeValue(forKey: id); wait.timeout?.cancel()
                wait.continuation.resume(throwing: CoincideError(PiProtocol.historyFailure)); return
            }
            active?.posted = true
        }
        pending[id]?.writeStarted = true
        try await write(frame)
    }
    private func requestCancelled(_ id: String) async {
        guard let wait = pending[id] else { return }
        if wait.steering { await requestFailed(id) }
        else if ["get_state", "get_entries", "get_available_models"].contains(wait.command) {
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
        guard active?.id == id, active?.started == true || allowNoStart, steeringPreparation == nil, !hasSteeringAdmission(id) else { return }
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
    private func settle(_ id: UUID, generation captured: UInt64, state: PiState) async -> Bool {
        guard active?.id == id, captured == generation else { return true }
        guard state.sessionFile == nativeID, state.idle, let run = active, !hasSteeringAdmission(id) else { return false }
        return await finishObserved(id, state: run.interrupted || run.nativeAborted ? .interrupted : run.failed ? .failed : .idle,
            generation: captured, observed: state)
    }
    private func finishObserved(_ id: UUID, state: ThreadState, generation captured: UInt64, observed: PiState) async -> Bool {
        guard let run = active, run.id == id, captured == generation else { return true }
        guard let history = run.history else { finish(id, state); return true }
        guard !compacting, ui.isEmpty, steeringPreparation == nil, !hasSteeringAdmission(id) else { return false }
        do {
            let raw = try await request("get_entries", runID: id)
            let after = try PiProtocol.state(await request("get_state", runID: id))
            guard active?.id == id, captured == generation else { return true }
            guard after == observed, after.idle, after.sessionFile == history.nativeSessionFile,
                  after.sessionID == history.nativeSessionID, !compacting, ui.isEmpty, steeringPreparation == nil, !hasSteeringAdmission(id) else { return false }
            let status: ThreadRunStatus = state == .interrupted ? .interrupted : state == .failed ? .failed : .completed
            let evidence: PiRunHistoryEvidence
            do {
                let entries = try PiProtocol.entries(raw, state: after)
                evidence = try Self.finalEvidence(history, entries: entries, status: status)
            } catch {
                // A completed run is real even when extensions or an unsupported
                // graph prevent a trustworthy native history attribution.
                evidence = try PiRunHistoryEvidence(preparation: history.preparation, inputs: history.inputs,
                    finalObservation: nil, openingUserEntryID: nil, nativeUserEntryIDs: [], captureStatus: .unavailable, terminalStatus: status)
            }
            emit(.piHistoryEvidence(evidence), runID: id)
            finish(id, state); return true
        } catch {
            if error is PiObservedCompletion || active?.id != id { return true }
            if !Task.isCancelled { await failConnection() }
            return true
        }
    }
    private static func finalEvidence(_ before: PiRunHistoryEvidence, entries: PiRuntimeEntries,
                                      status: ThreadRunStatus) throws -> PiRunHistoryEvidence {
        let window = try entries.observation.appendedWindow(since: before.preparation.baseline)
        if window.isEmpty, entries.observation == before.preparation.baseline {
            return try .init(preparation: before.preparation, inputs: before.inputs, finalObservation: entries.observation,
                openingUserEntryID: nil, nativeUserEntryIDs: [], captureStatus: .noNativeChange, terminalStatus: status)
        }
        let userIDs = window.filter(\.isUser).map(\.id), expected = before.inputs.filter { $0.kind != .compact }
        guard !userIDs.isEmpty, expected.count == userIDs.count else { throw PiHistoryGraphError(.invalidWindow) }
        let raw = Dictionary(uniqueKeysWithValues: entries.entries.map { ($0.id, $0) })
        var mapped = before.inputs, ordinal = 0
        for index in mapped.indices where mapped[index].kind != .compact {
            let native = userIDs[ordinal]; ordinal += 1
            guard let entry = raw[native], try PiProtocol.inputDigest(entry) == mapped[index].inputDigest else { throw PiHistoryGraphError(.invalidWindow) }
            mapped[index].nativeUserEntryID = native
        }
        return try .init(preparation: before.preparation, inputs: mapped, finalObservation: entries.observation,
            openingUserEntryID: userIDs.first, nativeUserEntryIDs: userIDs, captureStatus: .proven, terminalStatus: status)
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
        guard !broken, !closing else { return }; broken = true; preparing = nil; prepared = nil; steeringPreparation = nil; versionTask?.cancel(); settleTask?.cancel()
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
        closing = true; preparing = nil; prepared = nil; steeringPreparation = nil; versionTask?.cancel(); settleTask?.cancel(); reader?.cancel()
        for wait in pending.values {
            wait.timeout?.cancel()
            if wait.steering { wait.continuation.resume(throwing: ProviderSteeringError(wait.writeStarted ? .outcomeUncertain : .rejected)) }
            else { wait.continuation.resume(throwing: CoincideError(PiProtocol.failure)) }
        }; pending.removeAll()
        for (id, pending) in ui { pending.deadline?.cancel(); output.yield(.sessionApprovalDismissed(id)) }; ui.removeAll(); active = nil
        let channel = channel, reader = reader, scratch = scratch, steering = Array(steeringTasks.values), version = versionTask
        for task in steering { task.cancel() }
        let task = Task {
            if let channel { await channel.stopAndDrain() }
            await reader?.value
            for task in steering { _ = await task.result }
            if let version { _ = await version.result }
            if let scratch { try? FileManager.default.removeItem(at: scratch) }
        }
        closeTask = task; await task.value; output.finish()
    }
}

private struct PiRejected: Error {}
private struct PiObservedCompletion: Error {}
