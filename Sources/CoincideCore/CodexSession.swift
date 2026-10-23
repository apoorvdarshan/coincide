import Foundation

/// Native stdio client for the same Codex app-server protocol used by T3 Code.
public actor CodexSession: ProviderSession {
    public nonisolated let events: AsyncStream<ProviderEvent>
    public nonisolated let supportsAppMCP = true
    private let continuation: AsyncStream<ProviderEvent>.Continuation
    private let rpc: JSONRPCConnection
    private let processWorkspace: URL
    private let installationLease: CodexInstallationLease?
    private let runtimeConfiguration: CodexRuntimeConfiguration?
    private var closeTask: Task<Void, Never>?
    private var eventTask: Task<Void, Never>?
    private var threadID: String?
    private var turnID: String?
    private var completedTurnIDs: [String] = []
    private var sendGeneration = 0
    private var initialized = false
    private var connectionTask: Task<Void, Never>?
    private var connectionWaiters: [UUID: CheckedContinuation<Void, any Error>] = [:]
    private var serverUserAgent: String?
    private var historyMutationInFlight = false
    private var historyMutationUncertain = false
    private var working = false
    private var shuttingDown = false
    private var eventRunID: UUID?
    private var activeConfiguration: ProviderConfiguration?
    /// Only overrides this actor actually attempted. A later explicit reset
    /// clears that sticky native setting without changing an untouched default.
    private var requestedServiceTier: String?
    private var serviceTierHistoryObserved = false
    private var requestedInteractionMode: CodexInteractionMode?
    private var planProjection = CodexPlanProjection()
    private var steeringTask: ProviderSteeringTask?
    private var accountRevision = UUID()
    private var accountReadID: UUID?
    private var accountUsageProjection: (value: CodexUsageSnapshot?, invalidated: Bool)?
    private var appMCP: AppMCPConnection?
    private var appMCPConfiguring = false
    private static let appMCPServerName = "coincide"
    private var nativeRunOwners: [String: UUID] = [:]
    private var nativeRunOwnerOrder: [String] = []
    private var mcpApprovals: [JSONValue: ApprovalRequest] = [:]

    public init(executable: URL, cwd: URL, arguments: [String] = ["app-server", "--stdio"],
                environment: [String: String]? = nil, installationLease: CodexInstallationLease? = nil,
                runtimeConfiguration: CodexRuntimeConfiguration? = nil) throws {
        try runtimeConfiguration?.validate()
        guard installationLease == nil || installationLease?.resolved.executable == executable else { throw CodexRuntimeConfiguration.invalid() }
        let (events, continuation) = AsyncStream<ProviderEvent>.makeStream()
        self.events = events; self.continuation = continuation
        processWorkspace = cwd
        self.installationLease = installationLease
        self.runtimeConfiguration = runtimeConfiguration
        rpc = try JSONRPCConnection(executable: executable, arguments: arguments, cwd: cwd, maximumFrameSize: 128 * 1_024 * 1_024,
                                    environment: environment, drainProcessOnClose: true)
    }
    /// The header is an ephemeral stdio override. It is never a process argument,
    /// environment value, native config write, or durable provider configuration.
    public func configureAppMCP(_ connection: AppMCPConnection) async throws {
        guard !shuttingDown, !initialized, connectionTask == nil, eventTask == nil,
              !working, threadID == nil, appMCP == nil, !appMCPConfiguring else { throw Self.appMCPFailure() }
        let checked: AppMCPConnection
        do { checked = try .init(endpoint: connection.endpoint, authorizationHeader: connection.authorizationHeader,
            scopeID: connection.scopeID, requiredToolName: connection.requiredToolName) }
        catch { throw Self.appMCPFailure() }
        appMCPConfiguring = true
        defer { appMCPConfiguring = false }
        appMCP = checked
        try await rpc.configureAppMCPRedaction(checked)
        guard !shuttingDown, !initialized, connectionTask == nil, eventTask == nil else { throw Self.appMCPFailure() }
    }
    public func connect() async throws {
        try Task.checkCancellation()
        guard !shuttingDown else { throw CancellationError() }
        guard !appMCPConfiguring else { throw Self.appMCPFailure() }
        guard !initialized else { return }
        let id = UUID()
        try await withTaskCancellationHandler {
            try Task.checkCancellation()
            try await withCheckedThrowingContinuation { (waiter: CheckedContinuation<Void, any Error>) in
                guard !Task.isCancelled else { waiter.resume(throwing: CancellationError()); return }
                connectionWaiters[id] = waiter
                if connectionTask == nil {
                    connectionTask = Task {
                        do { try await self.initializeConnection(); self.finishConnection(.success(())) }
                        catch { self.finishConnection(.failure(error)) }
                    }
                }
            }
            try Task.checkCancellation()
        } onCancel: { Task { await self.cancelConnectionWaiter(id) } }
    }
    private func cancelConnectionWaiter(_ id: UUID) { connectionWaiters.removeValue(forKey: id)?.resume(throwing: CancellationError()) }
    private func finishConnection(_ result: Result<Void, any Error>) {
        connectionTask = nil
        let waiters = connectionWaiters; connectionWaiters = [:]
        for waiter in waiters.values { waiter.resume(with: result) }
    }
    private func initializeConnection() async throws {
        let stream = rpc.events
        eventTask = Task { [weak self] in
            for await event in stream { await self?.consume(event) }
        }
        do {
            let response = try await rpc.request("initialize", params: .object([
                "clientInfo": .object(["name": .string("coincide"), "title": .string("Coincide"), "version": .string("0.1.0")]),
                "capabilities": .object(["experimentalApi": .bool(true)])
            ]))
            guard !shuttingDown else { throw CancellationError() }
            serverUserAgent = response["userAgent"].string
            try await rpc.notify("initialized"); initialized = true
        } catch {
            // A failed handshake cannot leave a consumer behind for a second
            // initialization attempt on this same transport.
            shuttingDown = true; await rpc.close(); eventTask?.cancel(); eventTask = nil; continuation.finish()
            throw error
        }
    }
    public func historyCapabilities(threadID: String) async throws -> ProviderHistoryCapabilities {
        try ProviderHistoryValidation.id(threadID); try await connectForHistory()
        return try await CodexHistoryClient(rpc: rpc, userAgent: serverUserAgent).capabilities(threadID: threadID)
    }
    public func conversationSnapshot(threadID: String) async throws -> ProviderConversationSnapshot {
        try ProviderHistoryValidation.id(threadID); try await connectForHistory()
        return try await CodexHistoryClient(rpc: rpc, userAgent: serverUserAgent).snapshot(threadID: threadID)
    }
    public func historyPage(threadID: String, cursor: String? = nil, limit: Int = 100) async throws -> ProviderHistoryPage {
        try ProviderHistoryValidation.id(threadID); try await connectForHistory()
        return try await CodexHistoryClient(rpc: rpc, userAgent: serverUserAgent).page(threadID: threadID, cursor: cursor, limit: limit)
    }
    public func forkConversation(source: ProviderConversationReference, boundary: ProviderHistoryBoundary, configuration: ProviderConfiguration) async throws -> ProviderConversationSnapshot {
        try validateRuntimeBinding(configuration)
        // A fork belongs to a fresh target actor. It must never retarget the source runtime.
        guard !historyMutationUncertain else { throw ProviderHistoryError(.outcomeUncertain) }
        guard threadID == nil, !working, !historyMutationInFlight else { throw ProviderHistoryError(.notIdle) }
        historyMutationInFlight = true; defer { historyMutationInFlight = false }
        try await connectForHistory()
        do {
            let result = try await CodexHistoryClient(rpc: rpc, userAgent: serverUserAgent).fork(source: source, boundary: boundary, configuration: configuration)
            try Task.checkCancellation(); guard !shuttingDown else { throw CancellationError() }
            sendGeneration += 1
            threadID = result.reference.nativeThreadID; turnID = nil; completedTurnIDs = []
            return result
        } catch {
            if error is CancellationError || (error as? ProviderHistoryError)?.kind == .outcomeUncertain { historyMutationUncertain = true }
            throw error
        }
    }
    public func revertConversation(thread: ProviderConversationReference, beforeTurnID: String, expectedHeadTurnID: String) async throws -> ProviderConversationSnapshot {
        guard !historyMutationUncertain else { throw ProviderHistoryError(.outcomeUncertain) }
        guard !working, !historyMutationInFlight, threadID == nil || threadID == thread.nativeThreadID else { throw ProviderHistoryError(.notIdle) }
        historyMutationInFlight = true; defer { historyMutationInFlight = false }
        try await connectForHistory()
        do {
            let result = try await CodexHistoryClient(rpc: rpc, userAgent: serverUserAgent).revert(thread: thread, beforeTurnID: beforeTurnID, expectedHeadTurnID: expectedHeadTurnID)
            try Task.checkCancellation(); guard !shuttingDown else { throw CancellationError() }
            // Old delayed notifications retain their old run scope until an explicit
            // next send installs a new one; rewind never turns them into idle events.
            sendGeneration += 1
            threadID = result.reference.nativeThreadID; turnID = nil; completedTurnIDs = []
            return result
        } catch {
            if error is CancellationError || (error as? ProviderHistoryError)?.kind == .outcomeUncertain { historyMutationUncertain = true }
            throw error
        }
    }
    public func models() async throws -> [ProviderModel] {
        try await readModelCatalog(deadline: ContinuousClock.now + .seconds(30))
    }
    public func codexSkills(forceReload: Bool = false) async throws -> ProviderSkillInventory {
        let deadline = ContinuousClock.now + .seconds(30)
        do {
            try Task.checkCancellation(); try await connect()
            guard !shuttingDown, ContinuousClock.now < deadline else { throw ProviderSkillError(.unavailable) }
            let response = try await rpc.request("skills/list", params: .object([
                "cwds": .array([.string(processWorkspace.path)]), "forceReload": .bool(forceReload)
            ]), timeout: ContinuousClock.now.duration(to: deadline))
            try Task.checkCancellation()
            guard !shuttingDown, ContinuousClock.now < deadline else { throw ProviderSkillError(.unavailable) }
            return try CodexSkillInventory.decode(response, cwd: processWorkspace.path)
        } catch is CancellationError { throw CancellationError() }
        catch let error as JSONRPCRemoteError where error.code == -32601 || error.code == -32602 { throw ProviderSkillError(.unsupported) }
        catch let error as ProviderSkillError { throw error }
        catch { throw ProviderSkillError(.unavailable) }
    }
    public func codexAccountSnapshot() async throws -> CodexAccountSnapshot {
        try await readCodexAccountSnapshot(timeout: .seconds(30))
    }
    func readCodexAccountSnapshot(timeout: Duration) async throws -> CodexAccountSnapshot {
        try Task.checkCancellation()
        guard accountReadID == nil else { throw Self.accountReadFailure() }
        let id = UUID(), deadline = ContinuousClock.now + timeout
        accountReadID = id
        defer { if accountReadID == id { accountReadID = nil; accountUsageProjection = nil } }
        do {
            try await connect()
            // Startup can announce the CLI's existing account after initialize.
            // Retry one discarded observation on this same owned connection,
            // within the original deadline; never accept a continually changing
            // identity or treat a notice itself as a complete account.
            for _ in 0..<2 {
                accountUsageProjection = nil
                // Account notifications invalidate the entire observation. A usage
                // response must never be attributed to an identity read before a
                // concurrent sign-in/account switch.
                await rpc.flushEvents()
                let revision = accountRevision
                let initial = try CodexAccountParser.account(try await readAccountRPC(deadline: deadline))
                var usage: CodexAccountUsage = .unsupported
                if initial.kind == .chatgpt {
                    accountUsageProjection = (nil, false)
                    do {
                        try requireAccountRead(deadline: deadline)
                        _ = try await rpc.request("account/rateLimits/read", params: .object([:]),
                            timeout: ContinuousClock.now.duration(to: deadline), onResponse: { [weak self] result in
                                await self?.acceptAccountUsageResponse(result, readID: id)
                            })
                        await rpc.flushEvents()
                        if let projection = accountUsageProjection, !projection.invalidated, let value = projection.value {
                            usage = .available(value)
                        } else { usage = .probeFailed(previous: nil) }
                    } catch is CancellationError { throw CancellationError() }
                    catch let error as JSONRPCRemoteError where error.code == -32601 || error.code == -32602 {
                        usage = .unsupported
                    } catch { usage = .probeFailed(previous: nil) }
                }
                let final = try CodexAccountParser.account(try await readAccountRPC(deadline: deadline))
                await rpc.flushEvents()
                try requireAccountRead(deadline: deadline)
                guard initial == final, accountRevision == revision else { continue }
                if case .available = usage {
                    // Apply only notifications ordered after the full limits reply.
                    // Sparse patches keep other buckets and absent window fields.
                    if let projection = accountUsageProjection, !projection.invalidated, let value = projection.value {
                        guard initial.accountID == nil || value.accountID == nil || initial.accountID == value.accountID else {
                            throw Self.accountReadFailure()
                        }
                        usage = .available(value)
                    } else { usage = .probeFailed(previous: nil) }
                }
                return .init(identity: final, usage: usage, checkedAt: .now)
            }
            throw Self.accountReadFailure()
        } catch {
            if error is CancellationError || Task.isCancelled { throw CancellationError() }
            // Never display raw RPC errors or provider-supplied account data.
            throw Self.accountReadFailure()
        }
    }
    private static func accountReadFailure() -> CoincideError {
        CoincideError("The Codex account could not be refreshed. Check the CLI sign-in and try again.")
    }
    private func requireAccountRead(deadline: ContinuousClock.Instant) throws {
        try Task.checkCancellation()
        guard !shuttingDown, ContinuousClock.now < deadline else { throw Self.accountReadFailure() }
    }
    private func readAccountRPC(deadline: ContinuousClock.Instant) async throws -> JSONValue {
        try requireAccountRead(deadline: deadline)
        let response = try await rpc.request("account/read", params: .object(["refreshToken": .bool(false)]),
                                             timeout: ContinuousClock.now.duration(to: deadline))
        try requireAccountRead(deadline: deadline)
        return response
    }
    private func acceptAccountUsageResponse(_ result: Result<JSONValue, any Error>, readID: UUID) {
        guard accountReadID == readID else { return }
        if case .success(let value) = result, let parsed = try? CodexAccountParser.usage(value) {
            accountUsageProjection = (parsed, false)
        } else { accountUsageProjection = (nil, true) }
    }
    private func readModelCatalog(deadline: ContinuousClock.Instant) async throws -> [ProviderModel] {
        do {
            try Task.checkCancellation()
            try await connect()
            var cursor: String?
            var seenCursors: Set<String> = []
            var entries: [String: CodexModelCatalogEntry] = [:]
            var catalogOwners: [String: String] = [:]
            var models: [ProviderModel] = []
            var bytes = 0, rows = 0
            for _ in 0..<20 {
                try Task.checkCancellation()
                guard !shuttingDown, ContinuousClock.now < deadline else { throw CodexModelCatalogEntry.failure() }
                var params: [String: JSONValue] = ["limit": .number(100), "includeHidden": .bool(false)]
                if let cursor { params["cursor"] = .string(cursor) }
                let response = try await rpc.request("model/list", params: .object(params), timeout: ContinuousClock.now.duration(to: deadline))
                try Task.checkCancellation()
                guard !shuttingDown, ContinuousClock.now < deadline,
                      response.object != nil, let page = response["data"].array, page.count <= 100 else { throw CodexModelCatalogEntry.failure() }
                bytes += try JSONEncoder().encode(response).count; rows += page.count
                guard bytes <= 8 * 1_024 * 1_024, rows <= 2_000 else { throw CodexModelCatalogEntry.failure() }
                for item in page {
                    let entry = try CodexModelCatalogEntry(item), model = entry.model
                    if let previous = entries[model.id] {
                        guard previous == entry else { throw CodexModelCatalogEntry.failure() }
                    } else {
                        entries[model.id] = entry
                        if let catalogID = model.catalogID {
                            guard catalogOwners[catalogID] == nil || catalogOwners[catalogID] == model.id else { throw CodexModelCatalogEntry.failure() }
                            catalogOwners[catalogID] = model.id
                        }
                        if !entry.hidden { models.append(model) }
                    }
                }
                guard let next = try CodexModelCatalogEntry.string(response["nextCursor"], maximum: 4_096) else {
                    let supportedModes: [CodexInteractionMode]? = CodexHistoryClient(rpc: rpc, userAgent: serverUserAgent).hasReviewedProfile ? [.default, .plan] : nil
                    return models.map { model in
                        var value = model; value.codexInteractionModes = supportedModes
                        if runtimeConfiguration?.authenticationMode == .ownedChatGPT { value.codexServiceTiers = nil }
                        return value
                    }
                }
                guard seenCursors.insert(next).inserted else { throw CodexModelCatalogEntry.failure() }
                cursor = next
            }
            throw CodexModelCatalogEntry.failure()
        } catch {
            if error is CancellationError || Task.isCancelled { throw CancellationError() }
            throw CodexModelCatalogEntry.failure()
        }
    }
    public func codexDefaultModelSelection() async throws -> CodexDefaultModelSelection {
        let deadline = ContinuousClock.now + .seconds(30)
        do {
            try Task.checkCancellation()
            guard processWorkspace.isFileURL, processWorkspace.host == nil || processWorkspace.host == "" || processWorkspace.host == "localhost",
                  processWorkspace.query == nil, processWorkspace.fragment == nil else { throw CodexModelCatalogEntry.failure() }
            let workspacePath = processWorkspace.standardizedFileURL.resolvingSymlinksInPath().path
            try await connect()
            let initial = try await readDefaultModelConfig(workspacePath: workspacePath, deadline: deadline)
            let catalog = try await readModelCatalog(deadline: deadline)
            let selectedModel: String
            if let configured = initial.model { selectedModel = configured }
            else {
                // Codex 0.163's models manager marks its picker-visible default
                // before app-server publishes this catalog. Never replace an
                // explicit cwd-config model with this fallback.
                guard CodexHistoryClient(rpc: rpc, userAgent: serverUserAgent).hasReviewedProfile else {
                    throw CodexModelCatalogEntry.failure()
                }
                let defaults = catalog.filter(\.isDefault)
                guard defaults.count == 1, let model = defaults.first else { throw CodexModelCatalogEntry.failure() }
                selectedModel = model.id
            }
            let advertised = catalog.first { $0.id == selectedModel }
            guard advertised != nil || initial.effort != nil else { throw CodexModelCatalogEntry.failure() }
            let effort = initial.effort ?? advertised?.codexDefaultReasoningEffort
            let final = try await readDefaultModelConfig(workspacePath: workspacePath, deadline: deadline)
            guard initial.model == final.model, initial.effort == final.effort, initial.modelProvider == final.modelProvider, !shuttingDown,
                  ContinuousClock.now < deadline else { throw CodexModelCatalogEntry.failure() }
            try Task.checkCancellation()
            return try .init(workspacePath: workspacePath, model: selectedModel, reasoningEffort: effort, catalogModel: advertised)
        } catch {
            if error is CancellationError || Task.isCancelled { throw CancellationError() }
            throw CoincideError("The Codex CLI default model could not be resolved safely. Refresh defaults and try again.")
        }
    }
    private func readDefaultModelConfig(workspacePath: String, deadline: ContinuousClock.Instant) async throws -> (model: String?, effort: String?, modelProvider: String?) {
        try Task.checkCancellation()
        guard !shuttingDown, ContinuousClock.now < deadline else { throw CodexModelCatalogEntry.failure() }
        let response = try await rpc.request("config/read", params: .object(["cwd": .string(workspacePath), "includeLayers": .bool(false)]),
                                             timeout: ContinuousClock.now.duration(to: deadline))
        try Task.checkCancellation()
        guard response.object != nil, response["config"].object != nil,
              try JSONEncoder().encode(response).count <= 4 * 1_024 * 1_024 else { throw CodexModelCatalogEntry.failure() }
        return (try CodexModelCatalogEntry.string(response["config"]["model"], maximum: 4_096),
                try CodexModelCatalogEntry.string(response["config"]["model_reasoning_effort"], maximum: 256),
                try CodexModelCatalogEntry.string(response["config"]["model_provider"], maximum: 4_096))
    }
    private func connectForHistory() async throws {
        do { try await connect() }
        catch is CancellationError { throw CancellationError() }
        catch let error as ProviderHistoryError { throw error }
        catch { throw ProviderHistoryError(.invalidResponse) }
    }
    public func send(text: String, thread: CodingThread) async throws {
        try await send(input: ProviderInput(text: text), thread: thread)
    }
    public func send(input: ProviderInput, thread: CodingThread) async throws {
        let captured = thread.activeRun?.configuration ?? ProviderConfiguration(thread: thread)
        let selectedServiceTier = try CodexServiceTier.selected(in: captured)
        let selectedInteractionMode = try CodexInteractionMode.selected(in: captured)
        try validateRuntimeBinding(captured)
        guard !historyMutationUncertain else { throw ProviderHistoryError(.outcomeUncertain) }
        guard !working, !historyMutationInFlight else { throw CoincideError("A turn or conversation history operation is already running in this thread.") }
        if let effort = captured.reasoningEffort {
            guard !effort.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, effort.utf8.count <= 256,
                  !effort.unicodeScalars.contains(where: { $0.value < 32 || $0.value == 127 }) else {
                throw CoincideError("The selected Codex reasoning effort is invalid.")
            }
        }
        working = true
        sendGeneration += 1
        let generation = sendGeneration, submittedRunID = thread.activeRun?.id
        eventRunID = submittedRunID
        activeConfiguration = captured
        let requiresAppMCP = appMCP != nil
        var promptAttempted = false
        do {
            if !serviceTierHistoryObserved {
                serviceTierHistoryObserved = true
                if let nativeID = captured.nativeThreadID,
                   let previous = thread.runHistory?.reversed().first(where: { record in
                       record.id != thread.activeRun?.id && record.status.isTerminal && record.configuration.provider == .codex &&
                       record.providerThreadID?.utf8.elementsEqual(nativeID.utf8) == true &&
                       record.configuration.codexRuntimeBinding == captured.codexRuntimeBinding
                   }) {
                    // A saved run in this exact native/home scope proves the
                    // override belongs to Coincide. Foreign history and the new
                    // active run never authorize resetting a CLI-owned default.
                    requestedServiceTier = try CodexServiceTier.selected(in: previous.configuration)
                }
            }
            try await connect()
            try requireSend(generation)
            var metadata = thread.providerMetadata?.object ?? [:]
            let modesSupported = CodexHistoryClient(rpc: rpc, userAgent: serverUserAgent).hasReviewedProfile
            metadata["codexInteractionModes"] = .object([
                "supported": .bool(modesSupported), "profile": modesSupported ? .string("codex-0.163") : .null,
                "modes": .array(modesSupported ? [.string("default"), .string("plan")] : [])
            ])
            emit(.configuration(.object(metadata)))
            let effectiveInteractionMode = selectedInteractionMode ?? (requestedInteractionMode == nil ? nil : .default)
            var collaborationMode: JSONValue?
            if let mode = effectiveInteractionMode {
                guard CodexHistoryClient(rpc: rpc, userAgent: serverUserAgent).hasReviewedProfile else {
                    throw CoincideError("This Codex app-server profile does not support the reviewed Plan and Default controls.")
                }
                var model = captured.model, effort = captured.reasoningEffort
                if model.isEmpty {
                    let resolved = try await codexDefaultModelSelection()
                    try requireSend(generation)
                    guard URL(fileURLWithPath: resolved.workspacePath).standardizedFileURL.resolvingSymlinksInPath()
                        == URL(fileURLWithPath: captured.workspacePath).standardizedFileURL.resolvingSymlinksInPath() else {
                        throw CodexModelCatalogEntry.failure()
                    }
                    model = resolved.model; effort = effort ?? resolved.reasoningEffort
                }
                collaborationMode = try mode.wire(model: model, effort: effort)
            }
            if let selectedServiceTier {
                let catalog = try await readModelCatalog(deadline: ContinuousClock.now + .seconds(30))
                try requireSend(generation)
                guard let model = catalog.first(where: { $0.id.utf8.elementsEqual(captured.model.utf8) }) else { throw CodexServiceTier.invalid() }
                try CodexServiceTier.validate(selectedServiceTier, model: model)
            }
            if threadID == nil {
                if appMCP != nil {
                    do { try await requireAppMCPNamespaceAvailable(); try requireSend(generation) }
                    catch { try await failAppMCPPreparation(error) }
                }
                var params: [String: JSONValue] = ["cwd": .string(captured.workspacePath),
                    "approvalPolicy": captured.permission.approvalPolicy, "approvalsReviewer": captured.permission.reviewer,
                    "sandbox": .string(captured.permission == .fullAccess ? "danger-full-access" : captured.permission == .supervised ? "read-only" : "workspace-write")]
                if !captured.model.isEmpty { params["model"] = .string(captured.model) }
                if let appMCP {
                    // Override only our dotted server slot. Inherited/launch
                    // argument MCP servers remain untouched in the native config.
                    params["config"] = .object(["mcp_optional_startup_grace_ms": .number(10_000),
                        "mcp_servers." + Self.appMCPServerName: .object([
                            "url": .string(appMCP.endpoint.absoluteString), "tool_timeout_sec": .number(3_900),
                            "http_headers": .object(["Authorization": .string(appMCP.authorizationHeader)])])])
                }
                let response: JSONValue
                do {
                    if let existing = captured.nativeThreadID {
                        params["threadId"] = .string(existing)
                        response = try await rpc.request("thread/resume", params: .object(params))
                    } else {
                        // Select the durable modern contract explicitly for new
                        // threads. Existing/legacy resumes are never migrated here.
                        if CodexHistoryClient(rpc: rpc, userAgent: serverUserAgent).hasReviewedProfile { params["historyMode"] = .string("paginated") }
                        response = try await rpc.request("thread/start", params: .object(params))
                        if params["historyMode"] == .string("paginated"), response["thread"]["historyMode"] != .string("paginated") {
                            throw ProviderHistoryError(.invalidResponse)
                        }
                    }
                    try requireSend(generation)
                    guard let id = response["thread"]["id"].string, !id.isEmpty, id.utf8.count <= 4_096 else { throw Self.appMCPFailure() }
                    if appMCP != nil, let expected = captured.nativeThreadID, id != expected { throw Self.appMCPFailure() }
                    threadID = id; emit(.thread(id))
                } catch {
                    if appMCP != nil { try await failAppMCPPreparation(error) }
                    throw error
                }
            }
            if appMCP != nil {
                do { try await requireAppMCPReady(); try requireSend(generation) }
                catch { try await failAppMCPPreparation(error) }
            }
            try requireSend(generation)
            var items: [JSONValue] = try input.providerTextBlocks().map { .object(["type": .string("text"), "text": .string($0)]) }
            items += input.images.map { .object(["type": .string("image"), "url": .string("data:\($0.mimeType);base64,\($0.data.base64EncodedString())")]) }
            var params: [String: JSONValue] = ["threadId": .string(threadID!), "cwd": .string(captured.workspacePath),
                "input": .array(items),
                "approvalPolicy": captured.permission.approvalPolicy, "approvalsReviewer": captured.permission.reviewer,
                "sandboxPolicy": captured.permission.sandbox(cwd: captured.workspacePath), "summary": .string("detailed")]
            if !captured.model.isEmpty { params["model"] = .string(captured.model) }
            if let effort = captured.reasoningEffort { params["effort"] = .string(effort) }
            if let collaborationMode { params["collaborationMode"] = collaborationMode }
            if let selectedServiceTier { params["serviceTier"] = .string(selectedServiceTier) }
            else if requestedServiceTier != nil { params["serviceTier"] = .null }
            // Keep an uncertain start's tier capture: if its response is lost,
            // the next explicit default must still clear our prior override.
            requestedServiceTier = selectedServiceTier
            if let effectiveInteractionMode { requestedInteractionMode = effectiveInteractionMode }
            promptAttempted = true
            let response = try await rpc.request("turn/start", params: .object(params))
            guard let id = response["turn"]["id"].string else { throw CoincideError("Codex did not return a turn id.") }
            if generation == sendGeneration, !completedTurnIDs.contains(id) {
                rememberNativeRun(id, runID: submittedRunID); turnID = id; emit(.turn(id), runID: submittedRunID)
            }
        } catch {
            if generation == sendGeneration { working = false }
            if requiresAppMCP, !promptAttempted { try await failAppMCPPreparation(error) }
            throw error
        }
    }
    private func failAppMCPPreparation(_ error: any Error) async throws -> Never {
        let cancelled = error is CancellationError || Task.isCancelled
        await close()
        if cancelled { throw CancellationError() }
        throw Self.appMCPFailure()
    }
    private func requireSend(_ generation: Int) throws {
        try Task.checkCancellation()
        guard !shuttingDown, generation == sendGeneration, working else { throw CancellationError() }
    }
    private static func appMCPFailure() -> CoincideError {
        .init("The Codex app tool connection could not be confirmed. No prompt was sent.")
    }
    private func appMCPStatuses(threadID: String? = nil) async throws -> [JSONValue] {
        var rows: [JSONValue] = [], cursor: String?, seen: Set<String> = [], bytes = 0
        for _ in 0..<10 {
            try Task.checkCancellation()
            guard !shuttingDown else { throw Self.appMCPFailure() }
            var params: [String: JSONValue] = ["serverName": .string(Self.appMCPServerName), "detail": .string("toolsAndAuthOnly"), "limit": .number(100)]
            if let threadID { params["threadId"] = .string(threadID) }
            if let cursor { params["cursor"] = .string(cursor) }
            let response = try await rpc.request("mcpServerStatus/list", params: .object(params), timeout: .seconds(15))
            try MCPProtocol.validateJSON(response)
            guard let page = response["data"].array, page.count <= 100 else { throw Self.appMCPFailure() }
            bytes += try JSONEncoder().encode(response).count
            guard bytes <= 1_048_576 else { throw Self.appMCPFailure() }
            for row in page {
                guard let name = row["name"].string, MCPProtocol.text(name, maximum: 256) else { throw Self.appMCPFailure() }
                if name == Self.appMCPServerName { rows.append(row) }
            }
            if response["nextCursor"] == .null { return rows }
            guard let next = response["nextCursor"].string, MCPProtocol.text(next, maximum: 4_096), seen.insert(next).inserted else { throw Self.appMCPFailure() }
            cursor = next
        }
        throw Self.appMCPFailure()
    }
    private func requireAppMCPNamespaceAvailable() async throws {
        guard try await appMCPStatuses().isEmpty else { throw Self.appMCPFailure() }
    }
    private func requireAppMCPReady() async throws {
        guard let appMCP, let threadID else { throw Self.appMCPFailure() }
        let rows = try await appMCPStatuses(threadID: threadID)
        guard rows.count == 1, let row = rows.first, let tools = row["tools"].object,
              !tools.isEmpty, tools.count <= 256, row["toolsError"] == .null,
              tools.values.contains(where: { $0["name"].string == appMCP.requiredToolName }) else { throw Self.appMCPFailure() }
        // Older native catalog responses omit these newer observations. The
        // scoped initialized tool catalog remains required on every profile;
        // present status/identity fields must never contradict it.
        if row["runtimeStatus"] != .null, row["runtimeStatus"].string != "connected" { throw Self.appMCPFailure() }
        if let origin = row["httpOrigin"].string,
           origin != "http://127.0.0.1:\(appMCP.endpoint.port!)" { throw Self.appMCPFailure() }
        if row["httpOrigin"] != .null, row["httpOrigin"].string == nil { throw Self.appMCPFailure() }
        if row["serverInfo"] != .null, row["serverInfo"]["name"].string != "Coincide" { throw Self.appMCPFailure() }
        for tool in tools.values {
            guard let name = tool["name"].string, MCPProtocol.text(name, maximum: 128), tool["inputSchema"].object != nil else { throw Self.appMCPFailure() }
        }
    }
    public func steeringCapabilities() async -> ProviderSteeringCapabilities {
        guard initialized, CodexHistoryClient(rpc: rpc, userAgent: serverUserAgent).hasReviewedProfile,
              !shuttingDown, !historyMutationInFlight, !historyMutationUncertain else {
            return .init(unavailableReason: ProviderSteeringError(.unsupported).localizedDescription)
        }
        guard working, turnID != nil, threadID != nil, eventRunID != nil, activeConfiguration != nil else {
            return .init(unavailableReason: ProviderSteeringError(.noActiveTurn).localizedDescription)
        }
        return .init(supportsActiveSteering: true)
    }
    public func steer(input: ProviderInput, thread: CodingThread, expectedTurnID: String, clientMessageID: String) async throws -> ProviderSteeringReceipt {
        try input.requireNoHistoricalContextForSteering()
        try Task.checkCancellation()
        try ProviderSteeringValidation.id(expectedTurnID); try ProviderSteeringValidation.id(clientMessageID)
        try ProviderSteeringValidation.input(input)
        // Keep frame writes owned even if the caller cancels. Cancelling a
        // partially written RPC frame would terminate the existing provider.
        while let previous = steeringTask {
            _ = try? await previous.task.value
            if steeringTask?.id == previous.id { steeringTask = nil }
            try Task.checkCancellation()
        }
        guard initialized, CodexHistoryClient(rpc: rpc, userAgent: serverUserAgent).hasReviewedProfile,
              !shuttingDown, !historyMutationInFlight, !historyMutationUncertain else { throw ProviderSteeringError(.unsupported) }
        guard working else { throw ProviderSteeringError(.noActiveTurn) }
        try ProviderSteeringValidation.target(thread, provider: .codex, configuration: activeConfiguration,
            runID: eventRunID, nativeThreadID: threadID, turnID: turnID, expectedTurnID: expectedTurnID)
        var items: [JSONValue] = input.text.isEmpty ? [] : [.object(["type": .string("text"), "text": .string(input.text), "text_elements": .array([])])]
        items += input.images.map { .object(["type": .string("image"), "url": .string("data:\($0.mimeType);base64,\($0.data.base64EncodedString())")]) }
        let params: JSONValue = .object(["threadId": .string(threadID!), "expectedTurnId": .string(expectedTurnID),
            "clientUserMessageId": .string(clientMessageID), "input": .array(items)])
        try ProviderSteeringValidation.frame(params); try Task.checkCancellation()
        let rpc = rpc, id = UUID()
        let task = Task {
            do {
                let response = try await rpc.request("turn/steer", params: params, timeout: .seconds(10))
                guard response["turnId"].string == expectedTurnID else { throw ProviderSteeringError(.outcomeUncertain) }
                return try ProviderSteeringReceipt(turnID: expectedTurnID)
            } catch let error as JSONRPCRemoteError where error.code == -32601 { throw ProviderSteeringError(.unsupported) }
            catch let error as JSONRPCRemoteError where error.code == -32602 { throw ProviderSteeringError(.rejected) }
            catch let error as ProviderSteeringError { throw error }
            catch { throw ProviderSteeringError(.outcomeUncertain) }
        }
        steeringTask = .init(id: id, task: task)
        defer { if steeringTask?.id == id { steeringTask = nil } }
        // An acknowledgement remains useful evidence if completion or caller
        // cancellation wins the race. It never reinstalls an active turn.
        return try await task.value
    }
    public func interrupt() async throws {
        guard let threadID, let turnID else { throw CoincideError("There is no active turn to stop.") }
        _ = try await rpc.request("turn/interrupt", params: .object(["threadId": .string(threadID), "turnId": .string(turnID)]))
    }
    public func respond(_ request: ApprovalRequest, allow: Bool) async throws {
        if request.method == CodexMCPApproval.method {
            guard !shuttingDown, working, mcpApprovals[request.id] == request,
                  let approval = request.codexMCPApproval, approval.threadID == threadID,
                  approval.turnID == turnID, nativeRunOwners[approval.turnID] == eventRunID else {
                throw CoincideError("This Codex app-tool approval is no longer awaiting a response.")
            }
            mcpApprovals.removeValue(forKey: request.id)
            try await rpc.respond(id: request.id, result: approval.response(allow: allow))
            return
        }
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
        if let closeTask { await closeTask.value; return }
        let task = Task { [self] in await finishClose() }
        closeTask = task; await task.value
    }
    private func finishClose() async {
        shuttingDown = true; let connecting = connectionTask; connecting?.cancel(); await rpc.close()
        _ = try? await steeringTask?.task.value; steeringTask = nil
        await connecting?.value; connectionTask = nil
        let reading = eventTask; reading?.cancel(); await reading?.value; eventTask = nil; continuation.finish()
        appMCP = nil; mcpApprovals.removeAll()
        installationLease?.release()
    }
    private func validateRuntimeBinding(_ configuration: ProviderConfiguration) throws {
        if let runtimeConfiguration, configuration.codexRuntimeBinding != runtimeConfiguration {
            throw CoincideError("This input belongs to another Codex runtime or home. Reopen the intended conversation before sending it.")
        }
    }
    private func consume(_ event: RPCEvent) async {
        switch event {
        case .callback(let work): await work()
        case .barrier(let complete): complete()
        case .disconnected(let reason):
            working = false
            if !shuttingDown { continuation.yield(.connectionClosed(reason)) }
            continuation.finish()
        case .request(let id, let method, let params):
            if method == CodexMCPApproval.method {
                let request = ApprovalRequest(id: id, method: method, params: params)
                guard !shuttingDown, working, let runID = eventRunID,
                      let approval = request.codexMCPApproval, approval.threadID == threadID,
                      approval.turnID == turnID, nativeRunOwners[approval.turnID] == runID,
                      mcpApprovals.count < 64,
                      mcpApprovals[id] == nil || mcpApprovals[id] == request else {
                    if mcpApprovals.removeValue(forKey: id) != nil { emit(.approvalDismissed(id)) }
                    try? await rpc.respond(id: id, result: .object(["action": .string("decline"), "content": .null, "_meta": .null]))
                    emit(.message(.init(role: .system, text: "The Codex MCP request could not be matched to a supported approval in the current turn and was declined.")))
                    return
                }
                if mcpApprovals[id] == nil {
                    mcpApprovals[id] = request
                    emit(.approval(request), runID: runID)
                }
            } else if ["item/commandExecution/requestApproval", "item/fileChange/requestApproval", "item/tool/requestUserInput"].contains(method) {
                emit(.approval(.init(id: id, method: method, params: params)))
            } else {
                try? await rpc.reject(id: id, message: "Coincide does not support this interactive request yet.")
                emit(.message(.init(role: .system, text: "Unsupported provider request: \(method). The request was declined.")))
            }
        case .notification(let method, let params):
            if method == "account/updated" {
                // Even a malformed account-change notice invalidates a pending
                // read. It is not a complete identity and is never persisted.
                accountRevision = UUID(); accountUsageProjection = (nil, true)
                return
            }
            if method == "account/rateLimits/updated" {
                if let projection = accountUsageProjection, let current = projection.value {
                    do {
                        guard case .rateLimitsUpdated(let update) = try CodexAccountParser.notification(method: method, params: params) else {
                            accountUsageProjection = (nil, true); return
                        }
                        accountUsageProjection = (try CodexAccountParser.merging(update, into: current), projection.invalidated)
                    } catch { accountUsageProjection = (nil, true) }
                }
                return
            }
            if let id = params["threadId"].string, let threadID, id != threadID { return }
            switch method {
            case "serverRequest/resolved":
                mcpApprovals.removeValue(forKey: params["requestId"])
                emit(.approvalDismissed(params["requestId"]))
            case "turn/started":
                if let id = params["turn"]["id"].string, !completedTurnIDs.contains(id), working {
                    rememberNativeRun(id, runID: eventRunID); turnID = id; emit(.turn(id))
                }
            case "item/plan/delta", "turn/plan/updated":
                projectPlan(method: method, params: params)
            case "item/agentMessage/delta", "item/reasoning/summaryTextDelta", "item/commandExecution/outputDelta":
                guard let id = params["itemId"].string, let delta = params["delta"].string else { return }
                let role: MessageRole = method.contains("reasoning") ? .reasoning : method.contains("commandExecution") ? .tool : .assistant
                emit(.delta(id: id, role: role, text: delta))
            case "item/started", "item/completed":
                let item = params["item"]
                guard let id = item["id"].string, let type = item["type"].string else { return }
                if type == "plan" {
                    projectPlan(method: method, params: params)
                } else if type == "agentMessage", method == "item/completed", let text = item["text"].string {
                    emit(.message(.init(id: id, role: .assistant, text: text)))
                } else if type == "commandExecution" {
                    let command = item["command"].string ?? "Command"
                    let output = item["aggregatedOutput"].string ?? ""
                    emit(.message(.init(id: id, role: .tool, text: "$ \(command)\n\(output)")))
                } else if type == "fileChange", method == "item/completed" {
                    emit(.message(.init(id: id, role: .tool, text: "File changes\n\(item["changes"].pretty)")))
                } else if type == "mcpToolCall" {
                    projectMCPTool(item, params: params)
                }
            case "turn/completed":
                guard working, let completedID = params["turn"]["id"].string, !completedTurnIDs.contains(completedID) else { return }
                if let turnID, turnID != completedID { return }
                // Completion can precede both turn/started and the start response.
                // Preserve its real boundary before retiring the local active run.
                if turnID == nil { emit(.turn(completedID)) }
                rememberNativeRun(completedID, runID: eventRunID)
                if let owner = nativeRunOwners[completedID] {
                    for update in planProjection.terminal(turnID: completedID) { emitPlan(update, owner: owner) }
                }
                mcpApprovals = mcpApprovals.filter { $0.value.codexMCPApproval?.turnID != completedID }
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
    private func rememberNativeRun(_ nativeTurnID: String, runID: UUID?) {
        guard let runID, nativeTurnID.utf8.count <= 4_096,
              nativeRunOwners[nativeTurnID] == nil || nativeRunOwners[nativeTurnID] == runID else { return }
        if nativeRunOwners[nativeTurnID] == nil { nativeRunOwnerOrder.append(nativeTurnID) }
        nativeRunOwners[nativeTurnID] = runID
        if nativeRunOwnerOrder.count > 128 { nativeRunOwners.removeValue(forKey: nativeRunOwnerOrder.removeFirst()) }
    }
    private func projectPlan(method: String, params: JSONValue) {
        guard let session = threadID, params["threadId"].string?.utf8.elementsEqual(session.utf8) == true,
              let nativeTurn = params["turnId"].string,
              let originalTurn = nativeRunOwnerOrder.first(where: { $0.utf8.elementsEqual(nativeTurn.utf8) }),
              let owner = nativeRunOwners[originalTurn] else { return }
        do {
            if let update = try planProjection.project(method, params: params, sessionID: session) { emitPlan(update, owner: owner) }
        } catch {
            // Lost/malformed plan state cannot be repaired by guessing a final
            // message or replaying input. Close only this owned transport.
            working = false; historyMutationUncertain = true
            continuation.yield(.connectionClosed("The Codex plan stream could not be represented safely. Reopen the conversation before continuing."))
            Task { await self.close() }
        }
    }
    private func emitPlan(_ update: ProviderEntityUpdate, owner: UUID) {
        if working, eventRunID == owner { emit(.entity(update), runID: owner) }
        else { continuation.yield(.runEntity(runID: owner, update: update)) }
    }
    private func projectMCPTool(_ item: JSONValue, params: JSONValue) {
        guard let session = threadID, let nativeTurn = params["turnId"].string, let runID = nativeRunOwners[nativeTurn],
              let id = item["id"].string, MCPProtocol.text(id, maximum: 4_096),
              let server = item["server"].string, MCPProtocol.text(server, maximum: 256),
              let tool = item["tool"].string, MCPProtocol.text(tool, maximum: 256),
              let nativeStatus = item["status"].string, ["inProgress", "completed", "failed"].contains(nativeStatus),
              let bytes = try? JSONEncoder().encode(item), bytes.count <= MCPProtocol.maximumBodyBytes else { return }
        let output: JSONValue
        let result = item["result"]
        if item["error"] != .null {
            output = .object(["error": item["error"]["message"], "result": result["structuredContent"] != .null ? result["structuredContent"] : result["content"]])
        } else { output = result["structuredContent"] != .null ? result["structuredContent"] : result["content"] }
        let key = ProviderEntityKey(sessionID: session, type: "tool_call", id: id)
        emit(.entity(.patch(key, .object(["title": .string(server + "." + tool), "kind": .string("other"),
            "status": .string(nativeStatus == "inProgress" ? "in_progress" : nativeStatus),
            "rawInput": item["arguments"], "rawOutput": output]))), runID: runID)
    }
    private func emit(_ event: ProviderEvent, runID: UUID? = nil) {
        if let id = runID ?? eventRunID { continuation.yield(.context(runID: id, event: event)) }
        else { continuation.yield(event) }
    }
    deinit {
        eventTask?.cancel()
        let rpc = rpc, lease = installationLease
        Task { await rpc.close(); lease?.release() }
    }
}
