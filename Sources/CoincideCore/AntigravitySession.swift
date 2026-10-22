import Foundation

/// Native Antigravity's flat ACP2 dialect. Prompt responses are authoritative
/// terminals, not intake ACKs. Native child IDs/turn IDs are never fabricated.
public actor AntigravitySession: ProviderSession {
    public nonisolated let events: AsyncStream<ProviderEvent>
    private let output: AsyncStream<ProviderEvent>.Continuation
    private let executable: URL, cwd: URL, stateRoot: URL
    private let installation: AntigravityInstallation
    private let configuration: AntigravityConfiguration
    private let permission: PermissionMode
    private let credentialProvider: @Sendable () async throws -> AntigravityRuntimeCredential?
    private let authorizationURLHandler: (@Sendable (AntigravityAuthorizationURL) async throws -> Void)?
    private var fileAccessGuard: AntigravityFileAccessGuard
    private var files: AntigravityClientFiles?
    private var connection: AntigravityConnection?
    private var runtime: AntigravityRuntime?
    private var initialization: JSONValue?
    private var reader: Task<Void, Never>?
    private var closeTask: Task<Void, Never>?
    private var closing = false, broken = false, openingSession = false
    private var preparing: UUID?
    private var nativeSessionID: String?
    private var setup: JSONValue = .object([:])
    private var defaultModel: String?
    private var activeID: UUID?
    private struct Run { let configuration: ProviderConfiguration; var projection: AntigravityProjection; var terminal = false; var stopped = false }
    private var runs: [UUID: Run] = [:]
    private var runOrder: [UUID] = []
    private var toolOwners: [String: UUID] = [:]
    private var promptTasks: [UUID: Task<Void, Never>] = [:]
    private struct Pending { let native: AntigravityPermissionRequest; let request: ApprovalRequest; let wireID: JSONValue; let owner: UUID }
    private var requests: [JSONValue: Pending] = [:]
    private var fileTasks: [UUID: Task<Void, Never>] = [:]
    private var stopWaiters: [UUID: [UUID: CheckedContinuation<Void, any Error>]] = [:]
    private var stopTasks: [UUID: Task<Void, Never>] = [:]
    private var stopTimers: [UUID: Task<Void, Never>] = [:]
    private struct Probe { let runtime: AntigravityRuntime; let connection: AntigravityConnection; let reader: Task<Void, Never>; let cwd: URL }
    private var probes: [UUID: Probe] = [:]
    private var probeCloseTasks: [UUID: Task<Void, Never>] = [:]
    private var modelsTask: Task<[ProviderModel], any Error>?

    public init(executable: URL, cwd: URL, configuration: AntigravityConfiguration, permission: PermissionMode = .supervised,
                fileAccessGuard: @escaping AntigravityFileAccessGuard = { _, _ in throw CoincideError("This Antigravity file request is not authorized for the workspace.") },
                credentialProvider: @escaping @Sendable () async throws -> AntigravityRuntimeCredential? = { nil },
                authorizationURLHandler: (@Sendable (AntigravityAuthorizationURL) async throws -> Void)? = nil,
                stateRoot: URL? = nil, installation: AntigravityInstallation = .shared) {
        self.executable = executable; self.cwd = cwd.standardizedFileURL.resolvingSymlinksInPath(); self.configuration = configuration
        self.permission = permission; self.fileAccessGuard = fileAccessGuard; self.credentialProvider = credentialProvider
        self.authorizationURLHandler = authorizationURLHandler; self.stateRoot = stateRoot ?? AntigravityRuntime.defaultStateRoot
        self.installation = installation
        (events, output) = AsyncStream.makeStream()
    }
    public func setFileAccessGuard(_ guardClosure: @escaping AntigravityFileAccessGuard) throws {
        guard connection == nil, preparing == nil, !closing else { throw AntigravityProtocol.failure() }; fileAccessGuard = guardClosure
    }
    private func connect() async throws -> AntigravityConnection {
        guard !closing, !broken else { throw AntigravityWireError(.closed) }
        if let connection { return connection }
        try configuration.validate()
        let credential = try await credentialProvider()
        guard !closing, !broken else { throw AntigravityWireError(.closed) }
        let ownedFiles = try AntigravityClientFiles(root: cwd, accessGuard: fileAccessGuard)
        let runtime: AntigravityRuntime
        do { runtime = try .init(executable: executable, configuration: configuration, cwd: cwd, stateRoot: stateRoot, credential: credential, installation: installation) }
        catch { await ownedFiles.close(); throw error }
        let host = try AntigravityConnection(runtime: runtime)
        self.runtime = runtime; connection = host; files = ownedFiles
        reader = Task { [weak self] in
            for await event in host.events {
                if case .callback(let callback) = event { await callback() }
                else { await self?.consume(event) }
            }
            await self?.sourceEnded()
        }
        do {
            let value = try await host.initialize(clientCapabilities: .object(["fs": .object(["readTextFile": .bool(true), "writeTextFile": .bool(true)]), "terminal": .bool(false)]))
            try AntigravityProtocol.validateInitialization(value, authMethod: configuration.authMethod.rawValue)
            _ = try await host.request("authenticate", params: .object(["methodId": .string(configuration.authMethod.rawValue)]), timeout: .seconds(90))
            guard !closing, !broken else { throw AntigravityWireError(.closed) }; initialization = value; return host
        } catch { await fail(); throw safe(error) }
    }
    private enum ProbeKind { case models, authenticate, health, logout }
    private func probe(_ kind: ProbeKind) async throws -> JSONValue {
        guard !closing else { throw AntigravityWireError(.closed) }
        try configuration.validate()
        let credential = try await credentialProvider()
        guard !closing else { throw AntigravityWireError(.closed) }
        let id = UUID(), directory = stateRoot.appendingPathComponent("probes/" + id.uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let runtime: AntigravityRuntime, host: AntigravityConnection
        do {
            runtime = try .init(executable: executable, configuration: configuration, cwd: directory, stateRoot: stateRoot, credential: credential, installation: installation)
            host = try .init(runtime: runtime, allowAuthorizationURLs: kind == .authenticate)
        } catch { try? FileManager.default.removeItem(at: directory); throw safe(error) }
        let consumer = Task { [weak self] in
            for await event in host.events {
                switch event {
                case .callback(let callback): await callback()
                case .authorizationURL(let url): await self?.probeAuthorization(url, host: host, enabled: kind == .authenticate)
                case .serverRequest(let requestID, _, _): try? await host.reject(id: requestID, code: -32601)
                default: break
                }
            }
        }
        probes[id] = .init(runtime: runtime, connection: host, reader: consumer, cwd: directory)
        var nativeID: String?
        do {
            let result = try await withTaskCancellationHandler {
                let info = try await host.initialize(clientCapabilities: .object(["fs": .object(["readTextFile": .bool(false), "writeTextFile": .bool(false)]), "terminal": .bool(false)]))
                try AntigravityProtocol.validateInitialization(info, authMethod: configuration.authMethod.rawValue)
                if kind == .health { return info }
                if kind == .logout {
                    guard info["agentCapabilities"]["auth"]["logout"].object != nil else { throw AntigravityWireError(.invalidRequest) }
                    _ = try await host.request("logout", timeout: .seconds(30)); return .object([:])
                }
                _ = try await host.request("authenticate", params: .object(["methodId": .string(configuration.authMethod.rawValue)]), timeout: kind == .authenticate ? .seconds(300) : .seconds(90))
                let result = try await host.request("session/new", params: .object(["cwd": .string(directory.path), "mcpServers": .array([])]), timeout: .seconds(90))
                nativeID = try AntigravityProtocol.string(result["sessionId"])
                _ = try AntigravityProtocol.models(result); return result
            } onCancel: { Task { await host.close() } }
            await closeProbe(id, sessionID: nativeID); return result
        } catch { await closeProbe(id, sessionID: nativeID); throw safe(error) }
    }
    private func probeAuthorization(_ url: AntigravityAuthorizationURL, host: AntigravityConnection, enabled: Bool) async {
        guard enabled, let authorizationURLHandler, !closing else { await host.close(); return }
        do { try await authorizationURLHandler(url) } catch { await host.close() }
    }
    private func closeProbe(_ id: UUID, sessionID: String? = nil) async {
        if let task = probeCloseTasks[id] { await task.value; return }
        guard let probe = probes[id] else { return }
        // Keep ownership visible while draining: close() must join probes whose
        // RPC already returned and whose native process is still shutting down.
        let task = Task {
            await probe.connection.close(); await probe.runtime.close(); probe.reader.cancel(); await probe.reader.value
            AntigravityClientFiles.cleanupDisposableSession(stateDirectory: probe.runtime.sessionStateDirectory, sessionID: sessionID, cwd: probe.cwd)
            try? FileManager.default.removeItem(at: probe.cwd)
        }
        probeCloseTasks[id] = task
        await task.value
        probes.removeValue(forKey: id); probeCloseTasks.removeValue(forKey: id)
    }
    public func models() async throws -> [ProviderModel] {
        if let modelsTask { return try await modelsTask.value }
        let task = Task { try AntigravityProtocol.models(await self.probe(.models)) }; modelsTask = task
        defer { modelsTask = nil }
        return try await withTaskCancellationHandler { try await task.value } onCancel: { task.cancel() }
    }
    public func authenticate() async throws -> [ProviderModel] { try AntigravityProtocol.models(await probe(.authenticate)) }
    public func logout() async throws { _ = try await probe(.logout) }
    public func healthCheck() async throws -> JSONValue {
        let value = try await probe(.health)
        return .object(["protocolVersion": value["protocolVersion"], "agentInfo": .object(["name": value["agentInfo"]["name"], "version": value["agentInfo"]["version"]])])
    }
    private func ensureSession(_ host: AntigravityConnection, resumeID: String?, owner: UUID) async throws {
        if let nativeSessionID { guard resumeID == nil || resumeID == nativeSessionID else { throw AntigravityProtocol.failure() }; return }
        openingSession = true; defer { openingSession = false }
        var params: [String: JSONValue] = ["cwd": .string(cwd.path), "mcpServers": .array([])]
        if let resumeID {
            guard initialization?["agentCapabilities"]["sessionCapabilities"]["resume"].object != nil else { throw AntigravityWireError(.invalidRequest) }
            params["sessionId"] = .string(resumeID)
        }
        let response = try await host.request(resumeID == nil ? "session/new" : "session/resume", params: .object(params), timeout: .seconds(90))
        try await host.flushEvents()
        guard !closing, !broken else { throw AntigravityWireError(.closed) }
        let id = try AntigravityProtocol.string(response["sessionId"] == .null ? .string(resumeID ?? "") : response["sessionId"])
        guard resumeID == nil || id == resumeID else { throw AntigravityProtocol.failure() }
        nativeSessionID = id; setup = AntigravityProtocol.metadata(response); defaultModel = AntigravityProtocol.currentModel(setup)
        output.yield(.context(runID: owner, event: .thread(id))); output.yield(.context(runID: owner, event: .configuration(setup)))
    }
    private func configure(_ host: AntigravityConnection, captured: ProviderConfiguration) async throws {
        guard let sessionID = nativeSessionID else { throw AntigravityProtocol.failure() }
        let desiredMode = AntigravityProtocol.mode(permission: captured.permission)
        if let option = AntigravityProtocol.selectOption(setup, category: "mode") {
            guard try AntigravityProtocol.options(option).contains(where: { $0["value"] == .string(desiredMode) }) else { throw AntigravityWireError(.invalidRequest) }
            let result = try await host.request("session/set_config_option", params: .object(["sessionId": .string(sessionID), "configId": .string(try AntigravityProtocol.optionID(option)), "value": .string(desiredMode)]))
            if result["configOptions"].array != nil { mergeMetadata("configOptions", result["configOptions"]) }
        } else {
            guard setup["modes"]["availableModes"].array?.contains(where: { $0["id"] == .string(desiredMode) }) == true else { throw AntigravityWireError(.invalidRequest) }
            _ = try await host.request("session/set_mode", params: .object(["sessionId": .string(sessionID), "modeId": .string(desiredMode)]))
            var modes = setup["modes"].object ?? [:]; modes["currentModeId"] = .string(desiredMode); mergeMetadata("modes", .object(modes))
        }
        try await host.flushEvents()
        guard AntigravityProtocol.currentMode(setup) == desiredMode else { throw AntigravityProtocol.failure() }
        if let model = captured.antigravityConfiguration?.model ?? defaultModel {
            guard try AntigravityProtocol.models(setup).contains(where: { $0.id == model }) else { throw AntigravityWireError(.invalidRequest) }
            let id = try AntigravityProtocol.selectOption(setup, category: "model").map(AntigravityProtocol.optionID) ?? "model"
            let result = try await host.request("session/set_config_option", params: .object(["sessionId": .string(sessionID), "configId": .string(id), "value": .string(model)]))
            if result["configOptions"].array != nil { mergeMetadata("configOptions", result["configOptions"]) }
            try await host.flushEvents()
            guard AntigravityProtocol.currentModel(setup) == model else { throw AntigravityProtocol.failure() }
        }
    }
    public func send(text: String, thread: CodingThread) async throws { try await send(input: .init(text: text), thread: thread) }
    public func send(input: ProviderInput, thread: CodingThread) async throws {
        try ProviderSteeringValidation.input(input)
        let captured = thread.activeRun?.configuration ?? .init(thread: thread)
        guard captured.provider == .antigravity, captured.antigravityConfiguration?.runtimeIdentity == configuration.runtimeIdentity,
              captured.permission == permission, URL(fileURLWithPath: captured.workspacePath).standardizedFileURL.resolvingSymlinksInPath() == cwd,
              activeID == nil, preparing == nil, !closing, !broken else { throw AntigravityWireError(.invalidRequest) }
        let token = UUID(), owner = thread.activeRun?.id ?? UUID(); preparing = token
        defer { if preparing == token { preparing = nil } }
        do {
            let host = try await connect()
            try await ensureSession(host, resumeID: captured.nativeThreadID, owner: owner)
            guard preparing == token, !closing, !broken else { throw AntigravityWireError(.cancelled) }
            try await configure(host, captured: captured)
            guard preparing == token, !closing, !broken, let sessionID = nativeSessionID else { throw AntigravityWireError(.cancelled) }
            if !input.images.isEmpty { guard initialization?["agentCapabilities"]["promptCapabilities"]["image"] == .bool(true) else { throw AntigravityWireError(.invalidRequest) } }
            try Task.checkCancellation(); try trim()
            var prompt: [JSONValue] = []
            if !input.text.isEmpty { prompt.append(.object(["type": .string("text"), "text": .string(input.text)])) }
            prompt += input.images.map { .object(["type": .string("image"), "mimeType": .string($0.mimeType), "data": .string($0.data.base64EncodedString())]) }
            runs[owner] = .init(configuration: captured, projection: .init(scope: "antigravity-\(configuration.instanceID)-\(sessionID)-\(owner)")); runOrder.append(owner); activeID = owner; preparing = nil
            let params = JSONValue.object(["sessionId": .string(sessionID), "prompt": .array(prompt)])
            promptTasks[owner] = Task { [weak self] in
                do { _ = try await host.request("session/prompt", params: params, timeout: .seconds(3_600), onResponse: { [weak self] result in await self?.promptResponse(result, owner: owner) }) }
                catch { /* Ordered response or closed owns all completion. */ }
                await self?.promptTaskFinished(owner)
            }
        } catch { await fail(); throw safe(error) }
    }
    private func promptTaskFinished(_ id: UUID) { promptTasks.removeValue(forKey: id) }
    private func promptResponse(_ result: Result<JSONValue, AntigravityWireError>, owner: UUID) async {
        guard let run = runs[owner], !run.terminal, activeID == owner, !closing, !broken else { return }
        do {
            let value = try result.get(), reason = try AntigravityProtocol.string(value["stopReason"], maximum: 128)
            let state: ThreadState
            if run.stopped || reason == "cancelled" { state = .interrupted }
            else if ["end_turn", "max_tokens", "max_turn_requests", "refusal"].contains(reason) { state = .idle }
            else { state = .failed; output.yield(.context(runID: owner, event: .message(.init(role: .system, text: "Antigravity could not complete this turn.")))) }
            finish(owner, state: state)
        } catch { await fail() }
    }
    private func consume(_ event: AntigravityWireEvent) async {
        guard !closing, !broken else { return }
        do {
            switch event {
            case .callback(let callback): await callback()
            case .closed: await fail()
            case .authorizationURL: await fail()
            case .notification(let method, let params):
                guard method == "session/update", params["sessionId"] == nativeSessionID.map(JSONValue.string) else { return }
                let update = params["update"], variant = update["sessionUpdate"].string
                if variant == "config_option_update" { mergeMetadata("configOptions", update["configOptions"]); return }
                if variant == "current_mode_update" {
                    var modes = setup["modes"].object ?? [:]; modes["currentModeId"] = update["currentModeId"]; mergeMetadata("modes", .object(modes)); return
                }
                guard !openingSession else { return }
                let toolID = update["toolCallId"].string
                let owner: UUID?
                if let toolID, let old = toolOwners[toolID] { owner = old }
                else if ["tool_call_update", "tool_call_content_chunk"].contains(variant ?? "") { return }
                else if let activeID {
                    owner = activeID
                    if let toolID, variant == "tool_call" {
                        guard toolOwners.count < 32_768 else { throw AntigravityWireError(.overflow) }; toolOwners[toolID] = activeID
                    }
                } else { return }
                guard let owner, var run = runs[owner] else { return }
                let updates = try run.projection.apply(update); runs[owner] = run
                for update in updates { project(update, owner: owner) }
            case .serverRequest(let wireID, let method, let params):
                guard params["sessionId"] == nativeSessionID.map(JSONValue.string) else { try await connection?.reject(id: wireID, code: -32602); return }
                if method == "fs/read_text_file" || method == "fs/write_text_file" { try serveFile(wireID: wireID, method: method, params: params); return }
                guard method == "session/request_permission" else { try await connection?.reject(id: wireID, code: -32601); return }
                let native = try AntigravityPermissionRequest(params: params)
                guard let owner = toolOwners[native.toolCallID] ?? activeID, runs[owner] != nil else { try await connection?.reject(id: wireID, code: -32602); return }
                guard requests.count < 64, !requests.values.contains(where: { $0.wireID == wireID }) else { throw AntigravityProtocol.failure() }
                let localID = JSONValue.string(UUID().uuidString), request = native.approval(localID: localID)
                requests[localID] = .init(native: native, request: request, wireID: wireID, owner: owner)
                output.yield(.sessionApproval(request))
            }
        } catch { await fail() }
    }
    private func mergeMetadata(_ key: String, _ value: JSONValue) {
        var fields = setup.object ?? [:]; fields[key] = AntigravityProtocol.metadata(value); setup = .object(fields)
        if let activeID { output.yield(.context(runID: activeID, event: .configuration(setup))) }
    }
    private func serveFile(wireID: JSONValue, method: String, params: JSONValue) throws {
        guard let host = connection, let files, fileTasks.count < 32 else { throw AntigravityProtocol.failure() }
        let id = UUID()
        fileTasks[id] = Task { [weak self] in
            do {
                let result: JSONValue
                if method == "fs/read_text_file" { result = try await files.read(params: params) }
                else { result = try await files.write(params: params) }
                try await host.respond(id: wireID, result: result)
            } catch { try? await host.reject(id: wireID, code: -32602) }
            await self?.fileTaskFinished(id)
        }
    }
    private func fileTaskFinished(_ id: UUID) { fileTasks.removeValue(forKey: id) }
    private func project(_ update: ProviderEntityUpdate, owner: UUID) {
        if activeID == owner { output.yield(.context(runID: owner, event: .entity(update))) }
        else { output.yield(.runEntity(runID: owner, update: update)) }
    }
    private func pending(_ request: ApprovalRequest) throws -> Pending {
        guard let value = requests[request.id], value.request == request else { throw AntigravityWireError(.invalidRequest) }; return value
    }
    private func reply(_ value: Pending, body: JSONValue) async throws {
        guard let connection, !closing, !broken else { throw AntigravityWireError(.closed) }
        requests.removeValue(forKey: value.request.id)
        do { try await connection.respond(id: value.wireID, result: body); output.yield(.sessionApprovalDismissed(value.request.id)) }
        catch { await fail(); throw safe(error) }
    }
    public func choose(_ request: ApprovalRequest, optionID: String) async throws { let value = try pending(request); try await reply(value, body: value.native.response(optionID: optionID)) }
    public func respond(_ request: ApprovalRequest, allow: Bool) async throws {
        let value = try pending(request)
        let body: JSONValue
        if value.native.isQuestion { guard !allow else { throw AntigravityWireError(.invalidRequest) }; body = try value.native.response(optionID: nil) }
        else { body = try value.native.decision(allow: allow) }
        try await reply(value, body: body)
    }
    public func answer(_ request: ApprovalRequest, answers: [String: String]) async throws { let value = try pending(request); try await reply(value, body: value.native.answer(answers: answers)) }
    public func selectAnswers(_ request: ApprovalRequest, selections: [String: [String]]) async throws { let value = try pending(request); try await reply(value, body: value.native.answer(selections: selections)) }
    public func interrupt() async throws {
        guard let activeID else { if preparing != nil { await fail(); throw AntigravityWireError(.cancelled) }; return }; try await interrupt(expectedRunID: activeID)
    }
    public func interrupt(expectedRunID: UUID) async throws {
        guard activeID == expectedRunID, let host = connection, let sessionID = nativeSessionID, !closing, !broken else { throw AntigravityWireError(.invalidRequest) }
        runs[expectedRunID]?.stopped = true
        let token = UUID()
        try await withTaskCancellationHandler {
            try Task.checkCancellation()
            try await withCheckedThrowingContinuation { continuation in
                stopWaiters[expectedRunID, default: [:]][token] = continuation
                stopTasks[token] = Task { [weak self] in
                    do { try await host.notify("session/cancel", params: .object(["sessionId": .string(sessionID)])) } catch { /* Fatal transport closure is ordered. */ }
                    await self?.stopTaskFinished(token)
                }
                stopTimers[token] = Task { [weak self] in do { try await Task.sleep(for: .seconds(15)) } catch { return }; await self?.stopExpired(expectedRunID, token: token) }
            }
        } onCancel: { Task { await self.stopExpired(expectedRunID, token: token) } }
    }
    private func stopTaskFinished(_ id: UUID) { stopTasks.removeValue(forKey: id) }
    private func stopExpired(_ id: UUID, token: UUID) async {
        guard let waiter = stopWaiters[id]?.removeValue(forKey: token) else { return }
        stopTimers.removeValue(forKey: token)?.cancel(); stopTasks[token]?.cancel(); waiter.resume(throwing: AntigravityWireError(.timedOut))
        if let run = runs[id], !run.terminal { await fail() }
    }
    private func finish(_ id: UUID, state: ThreadState) {
        guard var run = runs[id], !run.terminal else { return }
        for update in run.projection.finish() { project(update, owner: id) }; run.terminal = true; runs[id] = run
        if activeID == id { activeID = nil }
        for entry in requests.values where entry.owner == id { output.yield(.sessionApprovalDismissed(entry.request.id)) }
        requests = requests.filter { $0.value.owner != id }
        if let waiters = stopWaiters.removeValue(forKey: id) {
            for (token, waiter) in waiters { stopTimers.removeValue(forKey: token)?.cancel(); stopTasks[token]?.cancel(); waiter.resume() }
        }
        output.yield(.context(runID: id, event: .completed(state)))
    }
    private func trim() throws {
        while runOrder.count >= 32 {
            guard let id = runOrder.first(where: { runs[$0]?.terminal == true }) else { throw AntigravityWireError(.overflow) }
            runOrder.removeAll { $0 == id }; runs.removeValue(forKey: id); promptTasks.removeValue(forKey: id)?.cancel()
            // Retain bounded ownership tombstones: a late native update must
            // never be rebound to a newer foreground run after projection trim.
        }
    }
    private func sourceEnded() async { if !closing, !broken { await fail() } }
    private func fail() async {
        guard !closing, !broken else { return }; broken = true; preparing = nil
        if let activeID { output.yield(.context(runID: activeID, event: .connectionClosed(AntigravityProtocol.failureMessage))) }
        else { output.yield(.connectionClosed(AntigravityProtocol.failureMessage)) }
        activeID = nil
        for request in requests.values { output.yield(.sessionApprovalDismissed(request.request.id)) }; requests.removeAll()
        for group in stopWaiters.values { for waiter in group.values { waiter.resume(throwing: AntigravityWireError(.closed)) } }; stopWaiters.removeAll()
        for timer in stopTimers.values { timer.cancel() }; stopTimers.removeAll()
        for task in stopTasks.values { task.cancel() }
        if let connection { Task { await connection.close() } }
    }
    public func close() async {
        if let closeTask { await closeTask.value; return }; closing = true; preparing = nil; modelsTask?.cancel()
        let prompts = Array(promptTasks.values), fileJobs = Array(fileTasks.values), stops = Array(stopTasks.values), timers = Array(stopTimers.values)
        for task in prompts + fileJobs + stops + timers { task.cancel() }
        for group in stopWaiters.values { for waiter in group.values { waiter.resume(throwing: AntigravityWireError(.closed)) } }; stopWaiters.removeAll()
        for request in requests.values { output.yield(.sessionApprovalDismissed(request.request.id)) }; requests.removeAll()
        let host = connection, runtime = runtime, files = files, reader = reader, modelRead = modelsTask
        let probeIDs = Set(probes.keys).union(probeCloseTasks.keys)
        let task = Task {
            await files?.close() // Drain every delegated write before releasing Engine's runtime owner.
            await host?.close(); await runtime?.close()
            for task in prompts + fileJobs + stops + timers { await task.value }
            for id in probeIDs { await self.closeProbe(id) }; _ = await modelRead?.result
            reader?.cancel(); await reader?.value
        }
        closeTask = task; await task.value; output.finish()
    }
    private func safe(_ error: any Error) -> any Error {
        if let wire = error as? AntigravityWireError { return wire }; return AntigravityProtocol.failure()
    }
}
