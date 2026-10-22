import Foundation

/// Native MSP adapter. An admission ACK never completes a run, permission
/// intent is verified before prompts, and background items retain their owner.
public actor MuseSession: ProviderSession {
    public nonisolated let events: AsyncStream<ProviderEvent>
    private let output: AsyncStream<ProviderEvent>.Continuation
    private let executable: URL
    private let cwd: URL
    private let configuration: MuseConfiguration
    private let permission: PermissionMode
    private var connection: MuseMSPConnection?
    private var initialization: MuseInitializeResult?
    private var reader: Task<Void, Never>?
    private var closeTask: Task<Void, Never>?
    private var metadataTask: Task<[ProviderModel], any Error>?
    private var metadataConnection: MuseMSPConnection?
    private var preparing: UUID?
    private var nativeSessionID: String?
    private var pendingSessionID: String?
    private var baselineModel: String?
    private var baselineIsNativeDefault = false
    private var authorityReady = false
    private var catalog: [ProviderModel] = []
    private var closing = false
    private var broken = false
    private var activeID: UUID?
    private var runs: [UUID: Run] = [:]
    private var runOrder: [UUID] = []
    private var commandOwners: [String: UUID] = [:]
    private var turnOwners: [String: UUID] = [:]
    private var itemOwners: [String: UUID] = [:]
    private var itemRevisions: [String: Int] = [:]
    private var turnTasks: [UUID: Task<Void, Never>] = [:]
    private var approvals: [String: Approval] = [:]
    private var questions: [String: Question] = [:]
    private var bufferedRequests: [(String, JSONValue)] = []
    private var bufferedRequestBytes = 0
    private var settledApprovals: Set<String> = []
    private var settledQuestions: Set<String> = []
    private var stopWaiters: [UUID: [UUID: CheckedContinuation<Void, any Error>]] = [:]
    private var stopTimers: [UUID: Task<Void, Never>] = [:]
    private var stopCommands: [UUID: Task<Void, Never>] = [:]
    private struct Run {
        let id: UUID
        let commandID: String
        let configuration: ProviderConfiguration
        var turnID: String?
        var terminal: ThreadState?
        var stopRequested = false
        var openItems: Set<String> = []
        var projection: MuseProjection
    }
    private struct Approval {
        let native: MuseApprovalRequest
        let raw: JSONValue
        let request: ApprovalRequest
        var responding = false
    }
    private struct Question {
        let native: MuseUserInputRequest
        let request: ApprovalRequest
        var responding = false
    }
    public init(executable: URL, cwd: URL, configuration: MuseConfiguration, permission: PermissionMode = .supervised) {
        self.executable = executable; self.cwd = cwd.standardizedFileURL.resolvingSymlinksInPath()
        self.configuration = configuration; self.permission = permission
        (events, output) = AsyncStream.makeStream()
    }
    private var profile: String { permission == .fullAccess ? ":unrestricted" : ":ask-me" }
    private var approvalMode: String { permission == .fullAccess ? "allowAll" : "promptUnmatched" }
    private func validateRuntime() throws {
        guard !closing, !broken, permission == .supervised || permission == .fullAccess else { throw MuseMSPError(.invalidInput) }
        try configuration.validate()
    }
    public func models() async throws -> [ProviderModel] {
        try validateRuntime()
        if let metadataTask { return try await metadataTask.value }
        let host = try MuseMSPConnection(executable: executable, arguments: ["serve", "--disable-shell", "--disable-write", "--no-session-log"], cwd: cwd)
        metadataConnection = host
        let consumer = Task { for await event in host.events { if case .callback(let callback) = event { await callback() } } }
        let task = Task {
            do {
                _ = try await host.initialize(userInputDialogs: false)
                let value = try await host.query("model/list")
                let rows = try MuseProtocol.models(value)
                await host.close(); consumer.cancel(); await consumer.value; return rows
            } catch {
                await host.close(); consumer.cancel(); await consumer.value; throw error
            }
        }
        metadataTask = task
        defer { metadataTask = nil; metadataConnection = nil }
        return try await withTaskCancellationHandler { try await task.value } onCancel: { task.cancel(); Task { await host.close() } }
    }
    private func connect() async throws -> MuseMSPConnection {
        try validateRuntime()
        if let connection, initialization != nil { return connection }
        guard connection == nil else { throw MuseMSPError(.invalidInput) }
        var args = ["serve", "--trust-workspace"]
        if permission == .fullAccess { args.append("--disable-sandbox") }
        let host = try MuseMSPConnection(executable: executable, arguments: args, cwd: cwd)
        connection = host
        reader = Task { [weak self] in
            for await event in host.events {
                guard let self else { return }
                if case .callback(let callback) = event { await callback() }
                else { await self.consume(event) }
            }
            await self?.streamEnded()
        }
        do {
            let initialized = try await host.initialize(userInputDialogs: true)
            guard !closing, !broken else { throw MuseMSPError(.closed) }
            initialization = initialized
            catalog = try MuseProtocol.models(await host.query("model/list"))
            return host
        } catch { await failConnection(); throw Self.safe(error) }
    }
    public func send(text: String, thread: CodingThread) async throws { try await send(input: .init(text: text), thread: thread) }
    public func send(input: ProviderInput, thread: CodingThread) async throws {
        try ProviderSteeringValidation.input(input)
        let captured = thread.activeRun?.configuration ?? ProviderConfiguration(thread: thread)
        guard captured.provider == .muse, captured.museConfiguration?.runtimeIdentity == configuration.runtimeIdentity,
              captured.permission == permission, activeID == nil, preparing == nil,
              URL(fileURLWithPath: captured.workspacePath).standardizedFileURL.resolvingSymlinksInPath() == cwd else { throw MuseMSPError(.invalidInput) }
        let preparation = UUID(); preparing = preparation
        defer { if preparing == preparation { preparing = nil } }
        let host = try await connect(), id = thread.activeRun?.id ?? UUID()
        do {
            let selection = captured.museConfiguration?.model
            let defaults = catalog.filter(\.isDefault)
            guard selection != nil || defaults.count <= 1 else { throw MuseMSPError(.protocolViolation) }
            let resumeID = captured.nativeThreadID ?? thread.providerThreadID
            let targetModel: String?
            if let selection { targetModel = selection.modelID }
            else if let declared = defaults.first?.museSelection?.modelID { targetModel = declared }
            else if nativeSessionID != nil {
                guard baselineIsNativeDefault, let baselineModel else { throw MuseDefaultUnavailable() }
                targetModel = baselineModel
            } else {
                guard resumeID == nil else { throw MuseDefaultUnavailable() }
                targetModel = nil // Fresh native default is observed after start.
            }
            try await ensureSession(host, resumeID: resumeID, modelID: targetModel, owner: id)
            guard let sessionID = nativeSessionID, preparing == preparation, !closing, !broken else { throw MuseMSPError(.cancelled) }
            let observed = try MuseProtocol.session(await host.query("session/read", params: .object(["sessionId": .string(sessionID), "excludeItems": .bool(true)])), expectedID: sessionID, workspaceRoot: cwd.path, requiredProfile: profile)
            guard preparing == preparation, !closing, !broken else { throw MuseMSPError(.cancelled) }
            guard observed.activeTurnID == nil, observed.status == "idle" else { throw MuseUnfinishedSession() }
            if let mode = observed.approvalMode, mode != approvalMode { throw MuseMSPError(.profileUnproven) }
            if let targetModel, observed.modelID != targetModel {
                _ = try await host.command("session/setModel", params: .object(["sessionId": .string(sessionID), "model": .object(["providerId": .string("meta"), "modelId": .string(targetModel)])]), commandID: host.mintCommandID())
                let effective = try MuseProtocol.session(await host.query("session/read", params: .object(["sessionId": .string(sessionID), "excludeItems": .bool(true)])), expectedID: sessionID, workspaceRoot: cwd.path, requiredProfile: profile)
                guard effective.modelID == targetModel, effective.activeTurnID == nil, effective.status == "idle" else { throw MuseMSPError(.protocolViolation) }
            }
            guard preparing == preparation, !closing, !broken, approvals.isEmpty, questions.isEmpty else { throw MuseMSPError(.invalidInput) }
            try Task.checkCancellation(); try trimRuns()
            let command = await host.mintCommandID()
            var parts: [JSONValue] = []
            if !input.text.isEmpty { parts.append(.object(["type": .string("text"), "text": .string(input.text)])) }
            for image in input.images { parts.append(.object(["type": .string("image"), "mediaType": .string(image.mimeType), "base64Data": .string(image.data.base64EncodedString())])) }
            var params: [String: JSONValue] = ["sessionId": .string(sessionID), "input": .array(parts), "displayText": .string(input.text), "ifBusy": .string("queue"), "workspaceRoots": .array([.string(cwd.path)])]
            let row = catalog.first { $0.museSelection?.modelID == (targetModel ?? observed.modelID) }
            let effort = captured.museConfiguration?.reasoningEffort ?? row?.defaultReasoningEffort
            if let effort { params["reasoningEffort"] = .string(effort) }
            // Include envelope headroom under MSP's actual 10 MiB frame cap.
            guard try JSONEncoder().encode(JSONValue.object(params)).count < MuseProtocol.maximumFrameBytes - 16_384 else { throw MuseMSPError(.invalidInput) }
            runs[id] = .init(id: id, commandID: command, configuration: captured, projection: .init(scope: "muse-\(configuration.instanceID)-\(sessionID)-\(id)"))
            runOrder.append(id); commandOwners[command] = id; activeID = id; preparing = nil
            let body = JSONValue.object(params)
            turnTasks[id] = Task { [weak self] in
                guard let self else { return }
                do {
                    _ = try await host.command("turn/start", params: body, commandID: command, onResponse: { [weak self] result in await self?.admission(result, runID: id, commandID: command) })
                } catch {
                    // The continuation may resume ahead of preceding native
                    // notifications. Ordered onResponse/closed delivery owns
                    // failure; this task must not overtake a real terminal.
                }
                await self.commandFinished(id)
            }
        } catch {
            if nativeSessionID == nil, pendingSessionID != nil { await failConnection() }
            else if !(error is MuseUnfinishedSession), !(error is MuseDefaultUnavailable) {
                let native = error as? MuseMSPError
                let knownUnsent = native?.kind == .invalidInput || native?.kind == .remoteFailure
                if !knownUnsent { await failConnection() }
            }
            throw Self.safe(error)
        }
    }
    private func ensureSession(_ host: MuseMSPConnection, resumeID: String?, modelID: String?, owner: UUID) async throws {
        if let nativeSessionID {
            guard resumeID == nil || resumeID == nativeSessionID else { throw MuseMSPError(.invalidInput) }; return
        }
        let sessionID: String
        if let resumeID { sessionID = resumeID } else { sessionID = await host.mintCommandID() }
        _ = try MuseProtocol.identity(.string(sessionID))
        pendingSessionID = sessionID
        var fields: [String: JSONValue] = ["sessionId": .string(sessionID)]
        if resumeID != nil {
            fields["excludeItems"] = .bool(true)
            if initialization?.supportsResumePermissionProfile == true { fields["permissionProfile"] = .string(profile) }
        } else {
            fields["workspaceRoot"] = .string(cwd.path); fields["workspaceRoots"] = .array([.string(cwd.path)])
            fields["providerId"] = .string("meta"); fields["approvalMode"] = .string(approvalMode); fields["permissionProfile"] = .string(profile)
            if let modelID { fields["modelId"] = .string(modelID) }
        }
        let result = try await host.command(resumeID == nil ? "session/start" : "session/resume", params: .object(fields), commandID: host.mintCommandID())
        guard !closing, !broken, preparing != nil else { throw MuseMSPError(.cancelled) }
        var observed = try MuseProtocol.session(result, expectedID: sessionID, workspaceRoot: cwd.path)
        if observed.profileID == nil {
            observed = try MuseProtocol.session(await host.query("session/read", params: .object(["sessionId": .string(sessionID), "excludeItems": .bool(true)])), expectedID: sessionID, workspaceRoot: cwd.path)
        }
        guard observed.profileID == profile else { throw MuseMSPError(.profileUnproven) }
        nativeSessionID = sessionID; pendingSessionID = nil; baselineModel = observed.modelID
        baselineIsNativeDefault = resumeID == nil && modelID == nil
        output.yield(.context(runID: owner, event: .thread(sessionID)))
        do {
            let ack = try await host.command("session/setApprovalMode", params: .object(["sessionId": .string(sessionID), "mode": .string(approvalMode)]), commandID: host.mintCommandID())
            guard ack["effectiveMode"]["mode"].string == approvalMode, ["completed", "noop"].contains(ack["applyOutcome"].string ?? "") else { throw MuseMSPError(.profileUnproven) }
        }
        authorityReady = true
        let buffered = bufferedRequests; bufferedRequests.removeAll(); bufferedRequestBytes = 0
        for (method, raw) in buffered { if method == "approval" { try showApproval(raw) } else { try showQuestion(raw) } }
        if (result["pendingRequests"].array?.isEmpty == false) {
            let pending = try await host.query("approval/listPending", params: .object(["sessionId": .string(sessionID)]))
            for raw in pending["approvals"].array ?? [] { try showApproval(raw) }
            for raw in pending["userInputs"].array ?? [] { try showQuestion(raw) }
        }
    }
    private func admission(_ result: Result<JSONValue, MuseMSPError>, runID: UUID, commandID: String) async {
        guard let run = runs[runID], run.terminal == nil, run.commandID == commandID, !closing, !broken else { return }
        do {
            let value = try result.get(), admission = try MuseProtocol.turnAdmission(value, expectedCommandID: commandID)
            // App FIFO must not become a hidden native steer into foreign work.
            guard admission.disposition != "steered" else { throw MuseMSPError(.protocolViolation) }
            try bindTurn(admission.turnID, to: runID)
        } catch { await commandFailed(runID, error: error) }
    }
    private func bindTurn(_ turnID: String, to runID: UUID) throws {
        guard let run = runs[runID], run.terminal == nil else { return }
        if let old = turnOwners[turnID], old != runID { throw MuseMSPError(.protocolViolation) }
        if let previous = run.turnID, previous != turnID { throw MuseMSPError(.protocolViolation) }
        runs[runID]?.turnID = turnID; turnOwners[turnID] = runID
        output.yield(.context(runID: runID, event: .turn(turnID)))
    }
    private func commandFinished(_ id: UUID) { turnTasks.removeValue(forKey: id) }
    private func commandFailed(_ id: UUID, error: any Error) async {
        guard let run = runs[id], run.terminal == nil, !closing, !broken else { return }
        if let failure = error as? MuseMSPError, failure.kind == .remoteFailure, failure.code == -32602 || failure.nativeKind == "commandRejected" || failure.nativeKind == "invalidParams" || failure.nativeKind == "authRequired" {
            guard run.turnID == nil else { await failConnection(); return }
            runs[id]?.terminal = .failed; if activeID == id { activeID = nil }
            output.yield(.context(runID: id, event: .failure("Muse did not accept the turn. Check its installation, sign-in, and selected options.")))
        } else { await failConnection() }
    }
    private func consume(_ event: MuseMSPEvent) async {
        guard !closing, !broken else { return }
        do {
            switch event {
            case .callback(let callback): await callback()
            case .closed: await failConnection()
            case .serverRequest(let id, let method, let params):
                guard ["approval/request", "userInput/request"].contains(method), params["sessionId"].string == (nativeSessionID ?? pendingSessionID) else { throw MuseMSPError(.protocolViolation) }
                try request(method == "approval/request" ? "approval" : "question", params: params)
                try await connection?.acknowledgePresentation(id: id)
            case .notification(let method, let params): try consume(method: method, params: params)
            }
        } catch { await failConnection() }
    }
    private func consume(method: String, params: JSONValue) throws {
        if ["turn/started", "turn/completed", "view/gap"].contains(method) { _ = try MuseProtocol.identity(params["sessionId"]) }
        if method == "view/gap", params["sessionId"].string == (nativeSessionID ?? pendingSessionID) { throw MuseMSPError(.protocolViolation) }
        guard params["sessionId"].string == (nativeSessionID ?? pendingSessionID) else { return }
        if ["approval/requested", "approval/updated"].contains(method) { try request("approval", params: params); return }
        if method == "userInput/requested" { try request("question", params: params); return }
        if method == "approval/resolved" {
            let id = try MuseProtocol.text(params["approvalId"], maximum: 4_096)
            guard settledApprovals.count < 4_096 else { throw MuseMSPError(.overflow) }; settledApprovals.insert(id)
            if let entry = approvals.removeValue(forKey: id) { output.yield(.sessionApprovalDismissed(entry.request.id)) }; return
        }
        if method == "userInput/settled" {
            let id = try MuseProtocol.text(params["userInputId"], maximum: 4_096)
            guard settledQuestions.count < 4_096 else { throw MuseMSPError(.overflow) }; settledQuestions.insert(id)
            if let entry = questions.removeValue(forKey: id) { output.yield(.sessionApprovalDismissed(entry.request.id)) }; return
        }
        if method == "turn/started" {
            let command = try MuseProtocol.identity(params["commandId"], command: true)
            guard let owner = commandOwners[command], let run = runs[owner], run.terminal == nil else { return }
            try bindTurn(MuseProtocol.identity(params["turnId"]), to: owner); return
        }
        if method == "turn/completed" {
            let turn = try MuseProtocol.identity(params["turnId"])
            // Fresh turn IDs equal their submitting command; this permits a
            // real terminal before ACK while refusing unrelated session turns.
            guard let owner = turnOwners[turn] ?? commandOwners[turn], let run = runs[owner], run.terminal == nil else { return }
            try bindTurn(turn, to: owner)
            let terminal = params["terminal"].string
            guard ["completed", "cancelled", "failed"].contains(terminal) else { throw MuseMSPError(.protocolViolation) }
            finish(owner, terminal == "completed" ? .idle : terminal == "cancelled" ? .interrupted : .failed); return
        }
        if ["item/started", "item/updated", "item/completed"].contains(method) {
            let item = params["item"], itemID = try MuseProtocol.text(item["itemId"], maximum: 4_096)
            guard let turn = item["turnId"].string, let owner = turnOwners[turn] ?? commandOwners[turn], var run = runs[owner] else { return }
            if let old = itemOwners[itemID], old != owner { throw MuseMSPError(.protocolViolation) }
            let revision = try MuseProtocol.integer(item["revision"], minimum: 1)
            if let prior = itemRevisions[itemID], prior >= revision { return }
            itemRevisions[itemID] = revision
            itemOwners[itemID] = owner
            if item["status"].string == "inProgress" { run.openItems.insert(itemID) } else { run.openItems.remove(itemID) }
            let updates = try run.projection.apply(method: method, params: params); runs[owner] = run
            for update in updates { project(update, owner: owner) }; return
        }
        if method == "item/delta" {
            let id = try MuseProtocol.text(params["itemId"], maximum: 4_096)
            guard let owner = itemOwners[id], var run = runs[owner] else { return }
            let updates = try run.projection.apply(method: method, params: params); runs[owner] = run
            for update in updates { project(update, owner: owner) }
        }
        // Status, foregroundCompleted, usage, and cursor reuse never settle a run.
    }
    private func project(_ update: ProviderEntityUpdate, owner: UUID) {
        if activeID == owner { output.yield(.context(runID: owner, event: .entity(update))) }
        else { output.yield(.runEntity(runID: owner, update: update)) }
    }
    private func request(_ method: String, params: JSONValue) throws {
        if !authorityReady {
            guard pendingSessionID != nil || nativeSessionID != nil, bufferedRequests.count < 64 else { throw MuseMSPError(.overflow) }
            // Validate presentation, but never let the user grant an older
            // session authority until its selected profile has been proved.
            if method == "approval" { _ = try MuseApprovalRequest(params: params) } else { _ = try MuseUserInputRequest(params: params) }
            let size = try JSONEncoder().encode(params).count
            guard bufferedRequestBytes + size <= 1_048_576 else { throw MuseMSPError(.overflow) }
            bufferedRequestBytes += size; bufferedRequests.append((method, params)); return
        }
        if method == "approval" { try showApproval(params) } else { try showQuestion(params) }
    }
    private func showApproval(_ raw: JSONValue) throws {
        let id = try MuseProtocol.text(raw["approvalId"], maximum: 4_096)
        if settledApprovals.contains(id) { return }
        var merged = approvals[id]?.raw.object ?? [:]
        for (key, value) in raw.object ?? [:] { merged[key] = value }
        let native = try MuseApprovalRequest(params: .object(merged))
        guard native.sessionID == (nativeSessionID ?? pendingSessionID), approvals.count < 64 || approvals[id] != nil else { throw MuseMSPError(.overflow) }
        if approvals[id]?.native == native { return }
        if let old = approvals[id] { output.yield(.sessionApprovalDismissed(old.request.id)) }
        let request = native.approval(localID: .string(UUID().uuidString))
        approvals[id] = .init(native: native, raw: .object(merged), request: request)
        output.yield(.sessionApproval(request))
    }
    private func showQuestion(_ raw: JSONValue) throws {
        let native = try MuseUserInputRequest(params: raw), id = native.userInputID
        if settledQuestions.contains(id) { return }
        guard native.sessionID == (nativeSessionID ?? pendingSessionID), questions.count < 64 || questions[id] != nil else { throw MuseMSPError(.overflow) }
        if questions[id]?.native == native { return }
        if let old = questions[id] { output.yield(.sessionApprovalDismissed(old.request.id)) }
        let request = native.approval(localID: .string(UUID().uuidString))
        questions[id] = .init(native: native, request: request); output.yield(.sessionApproval(request))
    }
    public func choose(_ request: ApprovalRequest, optionID: String) async throws {
        guard let entry = approvals.values.first(where: { $0.request == request }), !entry.responding else { throw MuseMSPError(.invalidInput) }
        try await decide(entry, body: entry.native.decisionBody(choiceID: optionID))
    }
    public func respond(_ request: ApprovalRequest, allow: Bool) async throws {
        if let entry = approvals.values.first(where: { $0.request == request }), !entry.responding {
            if allow {
                guard let once = entry.native.choices.first(where: { $0.decision == "approved" && $0.scope == "once" }) else { throw MuseMSPError(.invalidInput) }
                try await decide(entry, body: entry.native.decisionBody(choiceID: once.id))
            } else { try await decide(entry, body: entry.native.declineBody()) }; return
        }
        guard !allow, let entry = questions.values.first(where: { $0.request == request }), !entry.responding else { throw MuseMSPError(.invalidInput) }
        try await answerQuestion(entry, body: entry.native.cancelBody(), cancel: true)
    }
    private func decide(_ entry: Approval, body: JSONValue) async throws {
        guard let connection, !closing, !broken else { throw MuseMSPError(.closed) }
        let id = entry.native.approvalID; approvals[id]?.responding = true
        do {
            _ = try await connection.command("approval/decide", params: withSession(body), commandID: connection.mintCommandID())
            // A terminal:false ACK can precede a new native requirement. Only
            // actual updated/resolved notifications replace/dismiss this row.
        } catch {
            if settledApprovals.contains(id) || approvals[id]?.request.id != entry.request.id { return }
            approvals[id]?.responding = false; throw Self.safe(error)
        }
    }
    public func answer(_ request: ApprovalRequest, answers: [String: String]) async throws {
        let entry = try question(request); try await answerQuestion(entry, body: entry.native.answerBody(answers: answers))
    }
    public func selectAnswers(_ request: ApprovalRequest, selections: [String: [String]]) async throws { try await selectAnswers(request, selections: selections, notes: [:]) }
    public func selectAnswers(_ request: ApprovalRequest, selections: [String: [String]], notes: [String: String]) async throws {
        let entry = try question(request); try await answerQuestion(entry, body: entry.native.answerBody(selections: selections, notes: notes))
    }
    private func question(_ request: ApprovalRequest) throws -> Question {
        guard let entry = questions.values.first(where: { $0.request == request }), !entry.responding else { throw MuseMSPError(.invalidInput) }; return entry
    }
    private func answerQuestion(_ entry: Question, body: JSONValue, cancel: Bool = false) async throws {
        guard let connection, !closing, !broken else { throw MuseMSPError(.closed) }
        let id = entry.native.userInputID; questions[id]?.responding = true
        do { _ = try await connection.command(cancel ? "userInput/cancel" : "userInput/answer", params: withSession(body), commandID: connection.mintCommandID()) }
        catch {
            if settledQuestions.contains(id) || questions[id]?.request.id != entry.request.id { return }
            questions[id]?.responding = false; throw Self.safe(error)
        }
    }
    private func withSession(_ body: JSONValue) throws -> JSONValue {
        guard let nativeSessionID else { throw MuseMSPError(.closed) }
        var object = body.object ?? [:]; object["sessionId"] = .string(nativeSessionID); return .object(object)
    }
    public func interrupt() async throws {
        guard let activeID else {
            if preparing != nil { await failConnection(); throw MuseMSPError(.cancelled) }; return
        }
        try await interrupt(expectedRunID: activeID)
    }
    public func interrupt(expectedRunID: UUID) async throws {
        guard let connection, let sessionID = nativeSessionID, activeID == expectedRunID, !closing, !broken else { throw MuseMSPError(.invalidInput) }
        guard let turn = runs[expectedRunID]?.turnID else { await failConnection(); throw MuseMSPError(.closed) }
        let commandID = await connection.mintCommandID()
        if runs[expectedRunID]?.terminal != nil { return }
        guard activeID == expectedRunID, runs[expectedRunID]?.turnID == turn, !closing, !broken else { throw MuseMSPError(.invalidInput) }
        runs[expectedRunID]?.stopRequested = true
        try await waitForTerminal(expectedRunID, connection: connection, sessionID: sessionID, turnID: turn, commandID: commandID)
    }
    private func interruptResponse(_ result: Result<JSONValue, MuseMSPError>, runID: UUID, turnID: String, commandID: String) async {
        guard let run = runs[runID], run.terminal == nil, run.turnID == turnID, activeID == runID, !closing, !broken else { return }
        do {
            let value = try result.get()
            guard value["commandId"] == .string(commandID), value["turnId"] == .string(turnID), value["status"] == .string("accepted") else { throw MuseMSPError(.protocolViolation) }
        } catch { await failConnection() }
    }
    private func waitForTerminal(_ id: UUID, connection: MuseMSPConnection, sessionID: String, turnID: String, commandID: String) async throws {
        guard let run = runs[id] else { throw MuseMSPError(.invalidInput) }
        if run.terminal != nil { return }
        let waiter = UUID()
        try await withTaskCancellationHandler {
            try Task.checkCancellation()
            try await withCheckedThrowingContinuation { continuation in
                stopWaiters[id, default: [:]][waiter] = continuation
                // Register the terminal proof waiter before writing Stop. The
                // raw RPC continuation can overtake earlier notifications, so
                // only its ordered callback is allowed to apply failure.
                stopCommands[waiter] = Task { [weak self] in
                    do {
                        _ = try await connection.command("turn/interrupt", params: .object(["sessionId": .string(sessionID), "turnId": .string(turnID)]), commandID: commandID, onResponse: { [weak self] result in
                            await self?.interruptResponse(result, runID: id, turnID: turnID, commandID: commandID)
                        })
                    } catch { /* Ordered onResponse or closed owns failure. */ }
                    await self?.stopCommandFinished(waiter)
                }
                stopTimers[waiter] = Task { [weak self] in
                    do { try await Task.sleep(for: .seconds(15)) } catch { return }
                    await self?.stopTimedOut(id, waiter: waiter)
                }
            }
        } onCancel: { Task { await self.stopTimedOut(id, waiter: waiter) } }
    }
    private func stopCommandFinished(_ waiter: UUID) { stopCommands.removeValue(forKey: waiter) }
    private func stopTimedOut(_ id: UUID, waiter: UUID) async {
        guard let continuation = stopWaiters[id]?.removeValue(forKey: waiter) else { return }
        stopTimers.removeValue(forKey: waiter)?.cancel()
        stopCommands[waiter]?.cancel()
        continuation.resume(throwing: MuseMSPError(.timedOut))
        if let run = runs[id], run.terminal == nil { await failConnection() }
    }
    private func finish(_ id: UUID, _ state: ThreadState) {
        guard let run = runs[id], run.terminal == nil else { return }
        runs[id]?.terminal = state; if activeID == id { activeID = nil }
        if let waiters = stopWaiters.removeValue(forKey: id) {
            for (key, continuation) in waiters {
                stopTimers.removeValue(forKey: key)?.cancel(); stopCommands[key]?.cancel(); continuation.resume()
            }
        }
        output.yield(.context(runID: id, event: .completed(state)))
    }
    private func trimRuns() throws {
        while runOrder.count >= 16 {
            guard let old = runOrder.first(where: { runs[$0]?.terminal != nil && runs[$0]?.openItems.isEmpty == true }) else { throw MuseMSPError(.overflow) }
            runOrder.removeAll { $0 == old }; runs.removeValue(forKey: old); turnTasks.removeValue(forKey: old)?.cancel()
            commandOwners = commandOwners.filter { $0.value != old }; turnOwners = turnOwners.filter { $0.value != old }; itemOwners = itemOwners.filter { $0.value != old }
            itemRevisions = itemRevisions.filter { itemOwners[$0.key] != nil }
        }
    }
    private func failConnection() async {
        guard !broken, !closing else { return }; broken = true; preparing = nil
        if let activeID { output.yield(.context(runID: activeID, event: .connectionClosed("The Muse connection could not confirm its state. Reopen it before continuing."))) }
        else { output.yield(.connectionClosed("The Muse connection could not confirm its state. Reopen it before continuing.")) }
        activeID = nil
        for waiters in stopWaiters.values { for continuation in waiters.values { continuation.resume(throwing: MuseMSPError(.closed)) } }; stopWaiters.removeAll()
        for timer in stopTimers.values { timer.cancel() }; stopTimers.removeAll()
        for command in stopCommands.values { command.cancel() }
        for entry in approvals.values { output.yield(.sessionApprovalDismissed(entry.request.id)) }; approvals.removeAll()
        for entry in questions.values { output.yield(.sessionApprovalDismissed(entry.request.id)) }; questions.removeAll()
        if let connection { Task { await connection.close() } }
    }
    private func streamEnded() async { if !closing, !broken { await failConnection() } }
    public func close() async {
        if let closeTask { await closeTask.value; return }
        closing = true; preparing = nil; metadataTask?.cancel()
        let pendingTurnTasks = Array(turnTasks.values), pendingStopCommands = Array(stopCommands.values), pendingStopTimers = Array(stopTimers.values)
        for task in pendingTurnTasks { task.cancel() }; turnTasks.removeAll()
        for waiters in stopWaiters.values { for continuation in waiters.values { continuation.resume(throwing: MuseMSPError(.closed)) } }; stopWaiters.removeAll()
        for timer in pendingStopTimers { timer.cancel() }; stopTimers.removeAll()
        for command in pendingStopCommands { command.cancel() }; stopCommands.removeAll()
        for entry in approvals.values { output.yield(.sessionApprovalDismissed(entry.request.id)) }; approvals.removeAll()
        for entry in questions.values { output.yield(.sessionApprovalDismissed(entry.request.id)) }; questions.removeAll()
        let connection = connection, metadata = metadataConnection, reader = reader, metadataTask = metadataTask
        let task = Task {
            await connection?.close(); await metadata?.close(); _ = await metadataTask?.result
            for command in pendingStopCommands { await command.value }
            for timer in pendingStopTimers { await timer.value }
            for turn in pendingTurnTasks { await turn.value }
            reader?.cancel(); await reader?.value
        }
        closeTask = task; await task.value; output.finish()
    }
    private static func safe(_ error: any Error) -> any Error {
        if let known = error as? MuseMSPError { return known }
        if error is MuseUnfinishedSession { return error }
        if error is MuseDefaultUnavailable { return error }
        return MuseMSPError(.protocolViolation)
    }
}

private struct MuseUnfinishedSession: LocalizedError {
    var errorDescription: String? { "Muse has unfinished native work. Resolve its pending requests before sending a new message." }
}
private struct MuseDefaultUnavailable: LocalizedError {
    var errorDescription: String? { "Choose a Muse model. The host did not advertise a default for this conversation." }
}
