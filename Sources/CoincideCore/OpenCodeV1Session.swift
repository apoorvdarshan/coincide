import Foundation
import CryptoKit
import OSLog

/// Fixed messages never include native payloads, server URLs or credentials.
public enum OpenCodeV1SessionError: Error, Sendable, Equatable, LocalizedError {
    case closed, busy, invalidConfiguration, wrongSession, unsupportedInput
    case rejected, uncertainDelivery, connectionLost, invalidResponse, staleRequest

    public var errorDescription: String? {
        switch self {
        case .closed: "The OpenCode 1 connection is closed."
        case .busy: "OpenCode has active work. Stop or finish it before sending another message."
        case .invalidConfiguration: "The captured OpenCode model, agent or permission settings could not be verified."
        case .wrongSession: "The OpenCode conversation does not match this workspace."
        case .unsupportedInput: "This input exceeds the native OpenCode request limit or uses an unsupported attachment."
        case .rejected: "OpenCode rejected this input before accepting it."
        case .uncertainDelivery: "OpenCode may have accepted this request. The queue is paused; do not resend it automatically."
        case .connectionLost: "The OpenCode event connection was lost. Inspect native work before continuing."
        case .invalidResponse: "OpenCode returned a response that could not be verified safely."
        case .staleRequest: "This OpenCode request is no longer pending on this connection."
        }
    }
}

protocol OpenCodeV1SessionTransport: Sendable {
    func connect() async throws -> AsyncThrowingStream<OpenCodeSSEEvent, any Error>
    func inventory(directory: URL) async throws -> OpenCodeMetadataSnapshot
    func commands(directory: URL) async throws -> ProviderCommandInventory
    func agentPermissionRules(directory: URL, agentID: String) async throws -> [OpenCodeV1PermissionRule]
    func request(method: String, path: [String], body: JSONValue?) async throws -> OpenCodeHTTPResponse
    func request(method: String, path: [String], query: [URLQueryItem], body: JSONValue?) async throws -> OpenCodeHTTPResponse
    func configureAppMCPRedaction(_ connection: AppMCPConnection) async throws
    func prepareAppMCP() async throws
    func close() async
}

extension OpenCodeV1SessionTransport {
    func configureAppMCPRedaction(_ connection: AppMCPConnection) async throws {}
    func prepareAppMCP() async throws { throw OpenCodeAppMCP.failure() }
    func commands(directory: URL) async throws -> ProviderCommandInventory { throw ProviderCommandError(.unsupported) }
    func request(method: String, path: [String], query: [URLQueryItem], body: JSONValue?) async throws -> OpenCodeHTTPResponse {
        guard query.isEmpty else { throw ProviderHistoryError(.unsupported) }
        return try await request(method: method, path: path, body: body)
    }
    func agentPermissionRules(directory: URL, agentID: String) async throws -> [OpenCodeV1PermissionRule] { [] }
}

/// Generation 1 has native messages and session-idle signals, not a durable
/// inbox or execution IDs. A successful POST alone never completes a run.
public actor OpenCodeV1Session: ProviderSession {
    public nonisolated let supportsAppMCP = true
    private var appMCPConnection: AppMCPConnection?
    private var appMCPConfiguring = false
    private let logger = Logger(subsystem: "com.apoorvdarshan.coincide", category: "OpenCodeV1")
    public nonisolated let events: AsyncStream<ProviderEvent>
    private let continuation: AsyncStream<ProviderEvent>.Continuation
    private let cwd: URL
    private let historyWorkspacePath: String
    private let configuration: OpenCodeConfiguration
    private let transport: any OpenCodeV1SessionTransport
    private var connecting: Task<Void, any Error>?
    private var reader: Task<Void, Never>?
    private var connected = false
    private var closing = false
    private var closeTask: Task<Void, Never>?
    private var uncertain = false
    private var sessionID: String?
    private var preparing: UUID?
    private var stoppedPreparations: Set<UUID> = []
    private var activeRunID: UUID?
    private var runs: [UUID: OpenCodeV1Run] = [:]
    private var inFlightSends: Set<UUID> = []
    private var nativeOwners: [String: UUID] = [:]
    private var messageOwners: [ProviderEntityKey: UUID] = [:]
    private var userMessages: Set<ProviderEntityKey> = []
    private var historicalMessages: Set<ProviderEntityKey> = []
    private var projectors: [OpenCodeV1ProjectionOwner: OpenCodeV1Projection] = [:]
    private var earlyParts: [ProviderEntityKey: [OpenCodeV1Event]] = [:]
    private var earlyPartBytes = 0
    private var childParents: [String: String] = [:]
    private var childCalls: [String: OpenCodeV1ChildCall] = [:]
    private var earlyChildren: [String: [OpenCodeV1Event]] = [:]
    private var earlyChildBytes = 0
    private var backgroundActive: Set<String> = []
    private var pending: [JSONValue: OpenCodeV1PendingRequest] = [:]
    private var answering: Set<JSONValue> = []
    private var settledRequests: [ProviderEntityKey] = []
    private var policies: [String: [OpenCodeV1PermissionRule]] = [:]
    private var grants: [String: [OpenCodeV1PermissionRule]] = [:]
    private var requests: [UUID: Task<OpenCodeHTTPResponse, any Error>] = [:]
    private var reconciliation: [UUID: Task<Void, Never>] = [:]
    private var reconciliationGenerations: [UUID: Int] = [:]
    private var steering: [String: OpenCodeV1SteeringInput] = [:]
    private var steeringTasks: [String: Task<ProviderSteeringReceipt, any Error>] = [:]
    private var lastMessageMillis: UInt64 = 0
    private var messageCounter: UInt64 = 0
    private var historyToken: UUID?
    private var historyTask: Task<OpenCodeV1HistorySnapshot, any Error>?
    private var historySources = Set<String>()
    private var historyInterference = false
    private var historyMayHaveWritten = false
    private var historyUnsafe = false
    private var historyCandidateID: String?

    public init(executable: URL, cwd: URL, configuration: OpenCodeConfiguration) {
        let pair = AsyncStream<ProviderEvent>.makeStream()
        events = pair.stream; continuation = pair.continuation
        self.cwd = cwd.standardizedFileURL.resolvingSymlinksInPath()
        historyWorkspacePath = cwd.standardizedFileURL.path
        self.configuration = configuration
        transport = OpenCodeV1OwnedRuntime(executable: executable, cwd: cwd, configuration: configuration)
    }

    init(cwd: URL, configuration: OpenCodeConfiguration, transport: any OpenCodeV1SessionTransport) {
        let pair = AsyncStream<ProviderEvent>.makeStream()
        events = pair.stream; continuation = pair.continuation
        self.cwd = cwd.standardizedFileURL.resolvingSymlinksInPath()
        historyWorkspacePath = cwd.standardizedFileURL.path
        self.configuration = configuration; self.transport = transport
    }

    public func configureAppMCP(_ connection: AppMCPConnection) async throws {
        guard !closing, !connected, connecting == nil, reader == nil, appMCPConnection == nil,
              preparing == nil, sessionID == nil else { throw OpenCodeAppMCP.failure() }
        appMCPConfiguring = true
        defer { appMCPConfiguring = false }
        appMCPConnection = connection
        do { try await transport.configureAppMCPRedaction(connection) }
        catch { throw OpenCodeAppMCP.failure() }
        guard !closing else { throw OpenCodeAppMCP.failure() }
    }

    public func openCodeInventory() async throws -> OpenCodeMetadataSnapshot {
        try await connect()
        let inventory = try await transport.inventory(directory: cwd)
        guard !closing, inventory.server.generation == .v1 else { throw OpenCodeV1SessionError.invalidConfiguration }
        return inventory
    }

    public func models() async throws -> [ProviderModel] {
        try await openCodeInventory().models.filter(\.enabled).map {
            .init(id: $0.selection.catalogID, name: $0.name,
                  openCodeSelection: $0.selection, openCodeVariants: $0.variants)
        }
    }

    public func providerCommands(forceReload: Bool = false) async throws -> ProviderCommandInventory {
        try await connect()
        let inventory = try await transport.commands(directory: cwd)
        guard !closing, !uncertain, CodexSkillInventory.sameWorkspace(inventory.cwd, historyWorkspacePath) else { throw ProviderCommandError(.unavailable) }
        try inventory.validate()
        return .init(cwd: historyWorkspacePath, commands: inventory.commands, skills: inventory.skills,
            problems: inventory.problems, checkedAt: inventory.checkedAt)
    }

    public func openCodeV1HistorySnapshot(threadID: String) async throws -> OpenCodeV1HistorySnapshot {
        try await withHistory(sourceID: threadID, timeout: .seconds(30)) { token in
            try await self.readHistorySnapshot(threadID, token: token)
        }
    }

    public func applyOpenCodeV1History(review: OpenCodeV1HistoryReviewEvidence, kind: ConversationHistoryKind,
                                      configuration captured: ProviderConfiguration,
                                      candidate: @escaping @Sendable (OpenCodeV1HistoryCandidate) async throws -> Void) async throws -> ProviderConversationSnapshot {
        try review.validate(); try OpenCodeConfigurationValidation.configuration(captured)
        guard review.source.matchesBinding(captured), captured.openCodeConfiguration?.runtimeIdentity == configuration.runtimeIdentity,
              captured.workspacePath == historyWorkspacePath, let selected = captured.openCodeConfiguration else {
            throw ProviderHistoryError(.invalidRequest)
        }
        guard let selectedIndex = review.inputs.firstIndex(where: { $0.openingMessageID == review.selectedOpeningMessageID }) else {
            throw ProviderHistoryError(.invalidRequest)
        }
        let expectedBoundary: ProviderHistoryBoundary
        if kind == .rewindBeforeRun { expectedBoundary = .beforeMessage(review.selectedOpeningMessageID) }
        else if selectedIndex + 1 < review.inputs.count { expectedBoundary = .beforeMessage(review.inputs[selectedIndex + 1].openingMessageID) }
        else { expectedBoundary = .head }
        guard review.boundary == expectedBoundary else { throw ProviderHistoryError(.invalidRequest) }
        let sourceID = review.source.reference.nativeThreadID
        let result = try await withHistory(sourceID: sourceID, timeout: .seconds(90)) { token in
            let current = try await self.readHistorySnapshot(sourceID, token: token)
            guard current == review.source, !current.hasRevert else { throw ProviderHistoryError(.historyChanged) }
            try await self.checkHistory(token)
            // Resolve the captured agent policy before any clone mutation. No
            // catalog, create, prompt or source-setting operation is needed.
            let agent = try await self.transport.agentPermissionRules(directory: self.cwd, agentID: selected.agentID)
            try await self.checkHistory(token)
            let rules = Self.permissionRules(captured.permission, agent: selected.agentID, native: agent)
            return try await self.copyHistory(review, kind: kind, rules: rules, token: token, candidate: candidate)
        }
        return try .init(reference: result.reference, workspacePath: result.workspacePath, historyMode: .messageOrdered, openCodeV1: result)
    }

    public func inspectOpenCodeV1HistoryCandidate(review: OpenCodeV1HistoryReviewEvidence,
        candidate: OpenCodeV1HistoryCandidate, configuration captured: ProviderConfiguration) async throws -> ProviderConversationSnapshot {
        try review.validate(); try review.validateCandidate(candidate)
        try OpenCodeConfigurationValidation.configuration(captured)
        guard review.source.matchesBinding(captured), captured.openCodeConfiguration?.runtimeIdentity == configuration.runtimeIdentity,
              captured.workspacePath == historyWorkspacePath, let selected = captured.openCodeConfiguration else {
            throw ProviderHistoryError(.invalidRequest)
        }
        let sourceID = review.source.reference.nativeThreadID, cloneID = candidate.reference.nativeThreadID
        let result = try await withHistory(sourceID: sourceID, timeout: .seconds(30)) { token in
            let source = try await self.readHistorySnapshot(sourceID, token: token)
            guard source == review.source, !source.hasRevert else { throw ProviderHistoryError(.historyChanged) }
            let agent = try await self.transport.agentPermissionRules(directory: self.cwd, agentID: selected.agentID)
            try await self.checkHistory(token)
            let rules = Self.permissionRules(captured.permission, agent: selected.agentID, native: agent)
            let before = try OpenCodeV1HistoryWire.session(try await self.historyCall(token, path: ["session", cloneID]), id: cloneID, directory: self.cwd.path)
            guard before.permissions == rules else { throw ProviderHistoryError(.historyChanged) }
            let observed = try await self.readHistorySnapshot(cloneID, token: token)
            guard observed.sessionDigest == before.digest else { throw ProviderHistoryError(.historyChanged) }
            // A rewind cuts at the selected opening; a fork cuts at its next
            // opening or head. Reproof preserves that exact action boundary.
            let kind: ConversationHistoryKind = review.boundary == .beforeMessage(review.selectedOpeningMessageID) ? .rewindBeforeRun : .forkAfterRun
            try review.validateResult(observed, kind: kind)
            let after = try await self.readHistorySnapshot(sourceID, token: token)
            guard after == source else { throw ProviderHistoryError(.historyChanged) }
            return observed
        }
        return try .init(reference: result.reference, workspacePath: result.workspacePath, historyMode: .messageOrdered, openCodeV1: result)
    }

    private func withHistory(sourceID: String, timeout: Duration,
        operation: @escaping @Sendable (UUID) async throws -> OpenCodeV1HistorySnapshot) async throws -> OpenCodeV1HistorySnapshot {
        try Task.checkCancellation(); try OpenCodeV1HistoryWire.identifier(sourceID, prefix: "ses_")
        guard !closing, !uncertain, historyToken == nil, preparing == nil, activeRunID == nil,
              inFlightSends.isEmpty, backgroundActive.isEmpty, pending.isEmpty, answering.isEmpty,
              reconciliation.isEmpty, sessionID == nil || sessionID == sourceID else { throw ProviderHistoryError(.notIdle) }
        let token = UUID()
        historyToken = token; historySources = [sourceID]; historyInterference = false; historyMayHaveWritten = false
        let task = Task {
            try await withThrowingTaskGroup(of: OpenCodeV1HistorySnapshot.self) { group in
                group.addTask { try await operation(token) }
                group.addTask { try await Task.sleep(for: timeout); throw ProviderHistoryError(.limitExceeded) }
                defer { group.cancelAll() }
                guard let value = try await group.next() else { throw ProviderHistoryError(.invalidResponse) }
                return value
            }
        }
        historyTask = task
        defer {
            if historyToken == token {
                historyToken = nil; historyTask = nil; historySources = []; historyMayHaveWritten = false; historyCandidateID = nil
            }
        }
        do { return try await withTaskCancellationHandler { try await task.value } onCancel: { task.cancel() } }
        catch {
            if historyMayHaveWritten { throw ProviderHistoryError(.outcomeUncertain) }
            throw error
        }
    }

    private func checkHistory(_ token: UUID) throws {
        try Task.checkCancellation()
        guard !closing, !uncertain, historyToken == token else { throw CancellationError() }
        guard !historyInterference else { throw ProviderHistoryError(.historyChanged) }
    }

    private func historyCall(_ token: UUID, method: String = "GET", path: [String], query: [URLQueryItem] = [],
                             body: JSONValue? = nil) async throws -> OpenCodeHTTPResponse {
        try checkHistory(token)
        let value = try await call(method: method, path: path, query: query, body: body)
        try checkHistory(token); return value
    }

    private func historyQuiet(_ sourceID: String, token: UUID) async throws -> Set<String> {
        var queue = [sourceID], linked: Set<String> = [sourceID], bytes = 0
        while !queue.isEmpty {
            let parent = queue.removeFirst()
            let response = try await historyCall(token, path: ["session", parent, "children"])
            bytes += response.body.count
            guard bytes <= OpenCodeV1HistoryWire.maximumPageBytes,
                  let rows = try OpenCodeV1HistoryWire.json(response).array, rows.count <= 256 else { throw ProviderHistoryError(.limitExceeded) }
            for row in rows {
                guard row["parentID"] == .string(parent), let id = row["id"].string,
                      let directory = row["directory"].string, OpenCodeV1HistoryWire.sameDirectory(directory, cwd.path),
                      linked.insert(id).inserted, linked.count <= 256 else { throw ProviderHistoryError(.invalidResponse) }
                try OpenCodeV1HistoryWire.identifier(id, prefix: "ses_")
                queue.append(id)
            }
        }
        historySources.formUnion(linked)
        let statuses = try OpenCodeV1Protocol.statuses(try await historyCall(token, path: ["session", "status"]))
        guard linked.allSatisfy({ statuses[$0] == nil || statuses[$0] == .idle }), backgroundActive.isEmpty,
              activeRunID == nil, pending.isEmpty, answering.isEmpty else { throw ProviderHistoryError(.notIdle) }
        for tail in ["permission", "question"] {
            guard let rows = try OpenCodeV1HistoryWire.json(try await historyCall(token, path: [tail])).array,
                  rows.count <= 4_096 else { throw ProviderHistoryError(.invalidResponse) }
            for row in rows {
                let owner = try OpenCodeV1HistoryWire.identifier(row["sessionID"], prefix: "ses_")
                guard !linked.contains(owner) else { throw ProviderHistoryError(.notIdle) }
            }
        }
        return linked
    }

    private func historyRecords(_ sourceID: String, token: UUID) async throws -> [OpenCodeV1HistoryMessage] {
        var pages: [[JSONValue]] = [], cursor: String?, cursors = Set<String>(), messages = Set<String>(), bytes = 0
        for _ in 0..<OpenCodeV1HistoryWire.maximumPages {
            var query = [URLQueryItem(name: "limit", value: "200")]
            if let cursor { query.append(.init(name: "before", value: cursor)) }
            let response = try await historyCall(token, path: ["session", sourceID, "message"], query: query)
            bytes += response.body.count
            guard bytes <= OpenCodeV1HistoryWire.maximumBytes else { throw ProviderHistoryError(.limitExceeded) }
            let page = try OpenCodeV1HistoryWire.page(response)
            for row in page.values {
                let id = try OpenCodeV1HistoryWire.identifier(row["info"]["id"], prefix: "msg_")
                guard messages.insert(id).inserted, messages.count <= OpenCodeV1HistoryWire.maximumMessages else { throw ProviderHistoryError(.invalidResponse) }
            }
            pages.append(page.values)
            if page.before == nil {
                return try OpenCodeV1HistoryWire.records(pages.reversed().flatMap { $0 }, sessionID: sourceID)
            }
            guard let next = page.before, cursors.insert(next).inserted else { throw ProviderHistoryError(.invalidResponse) }
            cursor = next
        }
        throw ProviderHistoryError(.limitExceeded)
    }

    private func readHistorySnapshot(_ sourceID: String, token: UUID) async throws -> OpenCodeV1HistorySnapshot {
        try await connect(); try checkHistory(token)
        let first = try OpenCodeV1HistoryWire.session(try await historyCall(token, path: ["session", sourceID]), id: sourceID, directory: cwd.path)
        let firstChildren = try await historyQuiet(sourceID, token: token)
        let before = try await historyRecords(sourceID, token: token)
        let after = try await historyRecords(sourceID, token: token)
        let lastChildren = try await historyQuiet(sourceID, token: token)
        let last = try OpenCodeV1HistoryWire.session(try await historyCall(token, path: ["session", sourceID]), id: sourceID, directory: cwd.path)
        guard first == last, before == after, firstChildren == lastChildren else { throw ProviderHistoryError(.historyChanged) }
        return try .init(reference: .init(provider: .opencode, nativeThreadID: sourceID), runtimeIdentity: configuration.runtimeIdentity,
            workspacePath: historyWorkspacePath, projectID: last.projectID, workspaceID: last.workspaceID,
            sessionDigest: last.digest, messages: after, hasRevert: last.hasRevert)
    }

    private func copyHistory(_ review: OpenCodeV1HistoryReviewEvidence, kind: ConversationHistoryKind,
        rules: [OpenCodeV1PermissionRule], token: UUID,
        candidate: @escaping @Sendable (OpenCodeV1HistoryCandidate) async throws -> Void) async throws -> OpenCodeV1HistorySnapshot {
        let sourceID = review.source.reference.nativeThreadID
        let body: JSONValue
        switch review.boundary {
        case .head: body = .object([:])
        case .beforeMessage(let cut):
            guard let first = review.source.messages.firstIndex(where: { $0.id >= cut }), first == review.retainedMessageCount,
                  review.source.messages[first].id == cut else { throw ProviderHistoryError(.invalidRequest) }
            body = .object(["messageID": .string(cut)])
        default: throw ProviderHistoryError(.invalidRequest)
        }
        try checkHistory(token)
        historyMayHaveWritten = true; historyUnsafe = true
        do {
            let response = try await historyCall(token, method: "POST", path: ["session", sourceID, "fork"], body: body)
            let clone = try OpenCodeV1HistoryWire.session(response, directory: cwd.path)
            guard clone.id != sourceID, clone.projectID == review.source.projectID, clone.workspaceID == review.source.workspaceID,
                  !clone.hasRevert else { throw ProviderHistoryError(.invalidResponse) }
            let observed = try OpenCodeV1HistoryCandidate(reference: .init(provider: .opencode, nativeThreadID: clone.id),
                sourceInventoryDigest: review.source.inventoryDigest, runtimeIdentity: configuration.runtimeIdentity,
                workspacePath: historyWorkspacePath, boundary: review.boundary)
            try review.validateCandidate(observed)
            // The app must durably record this exact newly observed ID BEFORE
            // any follow-up GET or settings write. No event adopts it early.
            try await candidate(observed); try checkHistory(token)
            historyCandidateID = clone.id
            let copied = try await readHistorySnapshot(clone.id, token: token)
            try review.validateResult(copied, kind: kind)
            let updated = try OpenCodeV1HistoryWire.session(try await historyCall(token, method: "PATCH", path: ["session", clone.id],
                body: .object(["permission": .array(rules.map(\.json))])), id: clone.id, directory: cwd.path)
            guard updated.permissions == rules else { throw ProviderHistoryError(.invalidResponse) }
            let verified = try OpenCodeV1HistoryWire.session(try await historyCall(token, path: ["session", clone.id]), id: clone.id, directory: cwd.path)
            guard verified == updated, verified.permissions == rules else { throw ProviderHistoryError(.invalidResponse) }
            let result = try await readHistorySnapshot(clone.id, token: token)
            guard result.sessionDigest == verified.digest else { throw ProviderHistoryError(.historyChanged) }
            try review.validateResult(result, kind: kind)
            let source = try await readHistorySnapshot(sourceID, token: token)
            guard source == review.source else { throw ProviderHistoryError(.historyChanged) }
            return result
        } catch { throw ProviderHistoryError(.outcomeUncertain) }
    }

    private func connect() async throws {
        guard !appMCPConfiguring else { throw OpenCodeAppMCP.failure() }
        try Task.checkCancellation()
        guard !closing else { throw OpenCodeV1SessionError.closed }
        guard !uncertain else { throw OpenCodeV1SessionError.connectionLost }
        if connected { return }
        if let connecting { try await connecting.value; try Task.checkCancellation(); return }
        try configuration.validate()
        guard configuration.generation == .v1 else { throw OpenCodeV1SessionError.invalidConfiguration }
        let task = Task { try await self.initialize() }
        connecting = task
        do { try await task.value; connecting = nil; try Task.checkCancellation() }
        catch { connecting = nil; throw error }
    }

    private func initialize() async throws {
        do {
            let stream = try await transport.connect()
            guard !closing else { throw CancellationError() }
            reader = Task { [weak self] in
                var failureCategory = "sse-eof"
                do {
                    for try await frame in stream {
                        guard !Task.isCancelled else { return }
                        await self?.consume(frame)
                    }
                } catch let failure as OpenCodeSSEConnectionError {
                    failureCategory = failure.diagnosticCategory
                } catch let failure as OpenCodeProtocolError {
                    switch failure {
                    case .invalidEvent: failureCategory = "sse-invalid-event"
                    case .eventLimitExceeded: failureCategory = "sse-parser-limit-exceeded"
                    case .closed: failureCategory = "sse-parser-closed"
                    default: failureCategory = "sse-protocol-error"
                    }
                } catch is CancellationError {
                    failureCategory = "sse-cancelled"
                } catch {
                    // Descriptions, NSError userInfo and raw native transport
                    // errors can contain private request data. Log no values.
                    failureCategory = "sse-unknown-error"
                }
                await self?.streamEnded(category: failureCategory)
            }
            connected = true
        } catch {
            await transport.close()
            throw error is CancellationError ? CancellationError() : OpenCodeV1SessionError.connectionLost
        }
    }

    public func send(text: String, thread: CodingThread) async throws {
        try await send(input: .init(text: text), thread: thread)
    }

    public func send(input: ProviderInput, thread: CodingThread) async throws {
        guard !closing, !uncertain else { throw OpenCodeV1SessionError.closed }
        guard preparing == nil, activeRunID == nil, historyToken == nil, !historyUnsafe else { throw OpenCodeV1SessionError.busy }
        let captured = thread.activeRun?.configuration ?? ProviderConfiguration(thread: thread)
        guard let selected = captured.openCodeConfiguration,
              selected.runtimeIdentity == configuration.runtimeIdentity,
              URL(fileURLWithPath: captured.workspacePath).standardizedFileURL.resolvingSymlinksInPath() == cwd else {
            throw OpenCodeV1SessionError.invalidConfiguration
        }
        try selected.validate()
        let runID = thread.activeRun?.id ?? UUID(), token = UUID()
        guard !inFlightSends.contains(runID) else { throw OpenCodeV1SessionError.busy }
        let inputID = nextMessageID()
        let parts = try Self.parts(input)
        preparing = token; inFlightSends.insert(runID)
        defer {
            if preparing == token { preparing = nil }
            stoppedPreparations.remove(token); inFlightSends.remove(runID)
        }
        var posted = false
        do {
            try await connect(); try requirePreparation(token)
            if appMCPConnection != nil {
                try await transport.prepareAppMCP(); try requirePreparation(token)
            }
            let command: ProviderCommandSelection?
            if try ProviderCommandCatalog.requiresInventory(input.text) {
                let catalog: ProviderCommandInventory?
                do { catalog = try await providerCommands() }
                catch let error as ProviderCommandError where error.kind == .unsupported {
                    // Only an unsupported discovery endpoint means no known
                    // intent. A resolver's explicit refusal must never become
                    // an ordinary prompt after its native skill was recognized.
                    catalog = nil
                }
                try requirePreparation(token)
                command = try catalog.flatMap { try ProviderCommandCatalog.v1Selection(in: input.text, inventory: $0) }
            } else { command = nil }
            let compact = command?.name == "compact"
            guard !compact || (command?.arguments.isEmpty == true && input.images.isEmpty) else { throw OpenCodeV1SessionError.unsupportedInput }
            let inventory = try await openCodeInventory(); try requirePreparation(token)
            let model = try Self.resolveModel(selected.model, inventory: inventory)
            guard inventory.agents.contains(where: { $0.id == selected.agentID && $0.mode != .subagent && !$0.hidden }) else {
                throw OpenCodeV1SessionError.invalidConfiguration
            }
            let agentRules = try await transport.agentPermissionRules(directory: cwd, agentID: selected.agentID)
            try requirePreparation(token)
            let rules = Self.permissionRules(captured.permission, agent: selected.agentID, native: agentRules, appMCP: appMCPConnection != nil)
            let nativeID = try await ensureSession(captured: captured, rules: rules, token: token)
            try requirePreparation(token)
            let before = try OpenCodeV1Protocol.statuses(try await call(method: "GET", path: ["session", "status"]))
            try requirePreparation(token)
            guard before[nativeID] == nil || before[nativeID] == .idle else { throw OpenCodeV1SessionError.busy }
            let mergedRules = rules + (grants[nativeID] ?? [])
            let updated = try OpenCodeV1Protocol.session(try await call(method: "PATCH", path: ["session", nativeID],
                body: .object(["permission": .array(mergedRules.map(\.json))])), expectedID: nativeID, directory: cwd.path)
            try requirePreparation(token)
            guard updated.permissions == mergedRules, !updated.hasRevert else { throw OpenCodeV1SessionError.invalidConfiguration }
            policies[nativeID] = mergedRules
            let after = try OpenCodeV1Protocol.statuses(try await call(method: "GET", path: ["session", "status"]))
            try requirePreparation(token)
            guard after[nativeID] == nil || after[nativeID] == .idle else { throw OpenCodeV1SessionError.busy }
            var body: [String: JSONValue] = ["messageID": .string(inputID),
                "agent": .string(selected.agentID), "parts": .array(parts)]
            if let model {
                body["model"] = .object(["providerID": .string(model.providerID), "modelID": .string(model.id)])
                if let variant = model.variant { body["variant"] = .string(variant) }
            }
            if let command {
                body = ["messageID": .string(inputID), "agent": .string(selected.agentID),
                    "command": .string(command.name), "arguments": .string(command.arguments)]
                if let model {
                    body["model"] = .string(model.providerID + "/" + model.id)
                    if let variant = model.variant { body["variant"] = .string(variant) }
                }
                let files = parts.filter { $0["type"] == .string("file") }
                if !files.isEmpty { body["parts"] = .array(files) }
            }
            if compact {
                guard let compactModel = model ?? (inventory.defaults.count == 1 ? inventory.defaults.first : nil) else { throw OpenCodeV1SessionError.invalidConfiguration }
                body = ["providerID": .string(compactModel.providerID), "modelID": .string(compactModel.id), "auto": .bool(false)]
            }
            let prompt = JSONValue.object(body)
            guard try JSONEncoder().encode(prompt).count <= 4 * 1_024 * 1_024 else { throw OpenCodeV1SessionError.unsupportedInput }
            trimRuns()
            guard runs.count < 256 else { throw OpenCodeV1SessionError.invalidResponse }
            runs[runID] = .init(id: runID, sessionID: nativeID, inputID: inputID, autonomous: false)
            runs[runID]?.compaction = compact
            runs[runID]?.nativeCommand = command != nil
            runs[runID]?.configuration = captured
            runs[runID]?.model = model
            runs[runID]?.agentID = selected.agentID
            nativeOwners[nativeID] = runID; activeRunID = runID
            let inputKey = Self.messageKey(nativeID, inputID)
            if !compact { messageOwners[inputKey] = runID; userMessages.insert(inputKey) }
            let key = OpenCodeV1ProjectionOwner(sessionID: nativeID, runID: runID)
            projectors[key] = .init(instanceID: selected.instanceID, sessionID: nativeID)
            preparing = nil; posted = true
            let endpoint = compact ? "summarize" : command == nil ? "prompt_async" : "command"
            let response = try await call(method: "POST", path: ["session", nativeID, endpoint], body: prompt)
            guard !closing, !uncertain else { throw CancellationError() }
            if compact {
                guard try Self.commandJSON(response) == .bool(true) else { throw OpenCodeV1SessionError.invalidResponse }
                // summarize returns only after its native loop has settled. No
                // caller message ID exists for this internal compaction input.
                finish(runID, state: runs[runID]?.stopped == true ? .interrupted : .idle)
                return
            } else if command != nil {
                let value = try Self.commandJSON(response)
                let message = try OpenCodeV1Protocol.message(value["info"])
                guard message.sessionID == nativeID, message.role == "assistant", message.parentID == inputID,
                      let rows = value["parts"].array, rows.count <= 8_192 else { throw OpenCodeV1SessionError.invalidResponse }
                try await receive(message, event: .init(kind: .messageUpdated, sessionID: nativeID, message: message))
                for row in rows {
                    let part = try OpenCodeV1Protocol.part(row)
                    guard part.sessionID == nativeID, part.messageID == message.id else { throw OpenCodeV1SessionError.invalidResponse }
                    try await consume(.init(kind: .partUpdated, sessionID: nativeID, part: part))
                }
            } else {
                guard response.status == 204 else { throw OpenCodeV1SessionError.invalidResponse }
            }
            if var run = runs[runID], !run.stopped {
                run.accepted = true; runs[runID] = run
                announce(runID); reconcileEarlyIdle(runID)
            }
        } catch {
            if posted {
                if connected, !closing, !uncertain, let run = runs[runID], run.inputObserved, run.assistantObserved { return }
                if error is OpenCodeV1RejectedResponse, runs[runID]?.inputObserved != true {
                    if activeRunID == runID { activeRunID = nil }
                    runs.removeValue(forKey: runID)
                    throw OpenCodeV1SessionError.rejected
                }
                failConnection(.uncertainDelivery)
                throw OpenCodeV1SessionError.uncertainDelivery
            }
            if error is CancellationError || stoppedPreparations.contains(token) { throw CancellationError() }
            if let safe = error as? OpenCodeAppMCPError { throw safe }
            if let safe = error as? OpenCodeV1SessionError { throw safe }
            throw OpenCodeV1SessionError.invalidResponse
        }
    }

    public func steeringCapabilities() async -> ProviderSteeringCapabilities {
        pruneSteering()
        guard !closing, !uncertain, connected, preparing == nil, historyToken == nil, !historyUnsafe,
              let id = activeRunID, let run = runs[id], !run.autonomous, !run.compaction, !run.nativeCommand,
              !run.finished, !run.stopped, run.accepted, run.inputObserved, run.announced,
              run.configuration != nil, run.pendingSteeringID == nil,
              !pending.values.contains(where: { $0.owner == id }), run.steeringCount < 128, steering.count < 1_024 else {
            return .init(unavailableReason: ProviderSteeringError(.noActiveTurn).localizedDescription)
        }
        return .init(supportsActiveSteering: true)
    }

    /// Legacy v1 accepts a new user message on its current native loop. The
    /// opening message remains our observed turn reference; no expected-turn
    /// parameter or independent native execution identity is invented.
    public func steer(input: ProviderInput, thread: CodingThread, expectedTurnID: String,
                      clientMessageID: String) async throws -> ProviderSteeringReceipt {
        try Task.checkCancellation()
        try ProviderSteeringValidation.id(clientMessageID); try ProviderSteeringValidation.input(input)
        guard !closing, !uncertain, connected, preparing == nil, historyToken == nil, !historyUnsafe,
              let owner = activeRunID, let run = runs[owner], !run.autonomous, !run.compaction, !run.nativeCommand,
              !run.finished, !run.stopped, run.accepted, run.inputObserved, run.announced,
              run.inputID == expectedTurnID, thread.provider == .opencode, thread.providerThreadID == run.sessionID,
              thread.activeRun?.id == owner, thread.activeRun?.nativeTurnID == expectedTurnID,
              let captured = run.configuration, let agentID = run.agentID, thread.activeRun?.configuration == captured,
              captured.openCodeConfiguration?.runtimeIdentity == configuration.runtimeIdentity,
              URL(fileURLWithPath: captured.workspacePath).standardizedFileURL.resolvingSymlinksInPath() == cwd,
              !pending.values.contains(where: { $0.owner == owner }) else { throw ProviderSteeringError(.staleTarget) }
        let parts = try Self.parts(input)
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        let encoded = try encoder.encode(JSONValue.array(parts))
        guard encoded.count <= 4 * 1_024 * 1_024 - 16_384 else { throw ProviderSteeringError(.invalidRequest) }
        let fingerprint = SHA256.hash(data: encoded).map { String(format: "%02x", $0) }.joined()
        if let previous = steering[clientMessageID] {
            guard previous.owner == owner, previous.fingerprint == fingerprint else { throw ProviderSteeringError(.invalidRequest) }
            if let task = steeringTasks[clientMessageID] { return try await task.value }
            guard !previous.rejected else { throw ProviderSteeringError(.rejected) }
            guard previous.accepted || previous.observed else { throw ProviderSteeringError(.outcomeUncertain) }
            return try .init(turnID: run.inputID)
        }
        guard run.pendingSteeringID == nil, run.steeringCount < 128, steering.count < 1_024 else { throw ProviderSteeringError(.staleTarget) }
        // Native slash commands have a blocking, distinct admission contract.
        // They cannot silently become ordinary steers while a turn is active.
        if try ProviderCommandCatalog.requiresInventory(input.text) {
            let catalog = try await providerCommands()
            guard try ProviderCommandCatalog.v1Selection(in: input.text, inventory: catalog) == nil else { throw ProviderSteeringError(.unsupported) }
        }
        if appMCPConnection != nil { try await transport.prepareAppMCP() }
        guard !closing, !uncertain, activeRunID == owner, var current = runs[owner], !current.finished, !current.stopped,
              current.inputID == expectedTurnID, current.pendingSteeringID == nil,
              !pending.values.contains(where: { $0.owner == owner }) else { throw ProviderSteeringError(.staleTarget) }
        let nativeID = nextMessageID()
        current.generation += 1; current.steeringCount += 1
        current.pendingSteeringID = nativeID; current.steeringAccepted = false; current.steeringObserved = false; current.idleEarly = false
        runs[owner] = current
        steering[clientMessageID] = .init(owner: owner, nativeID: nativeID, fingerprint: fingerprint)
        let key = Self.messageKey(run.sessionID, nativeID)
        messageOwners[key] = owner; userMessages.insert(key)
        var fields: [String: JSONValue] = ["messageID": .string(nativeID), "agent": .string(agentID), "parts": .array(parts)]
        if let model = run.model {
            fields["model"] = .object(["providerID": .string(model.providerID), "modelID": .string(model.id)])
            if let variant = model.variant { fields["variant"] = .string(variant) }
        }
        let body = JSONValue.object(fields)
        let task = Task { try await self.submitSteering(clientMessageID, owner: owner, body: body) }
        steeringTasks[clientMessageID] = task
        continuation.yield(.steeringCapabilitiesChanged)
        return try await withTaskCancellationHandler { try await task.value } onCancel: { task.cancel() }
    }

    private func submitSteering(_ clientID: String, owner: UUID, body: JSONValue) async throws -> ProviderSteeringReceipt {
        defer { steeringTasks.removeValue(forKey: clientID) }
        guard let initial = steering[clientID], let run = runs[owner], activeRunID == owner, !run.finished, !run.stopped,
              run.pendingSteeringID == initial.nativeID, !closing, !uncertain,
              !pending.values.contains(where: { $0.owner == owner }) else {
            if let entry = steering[clientID], !entry.posted {
                steering[clientID]?.rejected = true
                if var current = runs[owner], current.pendingSteeringID == entry.nativeID {
                    current.pendingSteeringID = nil; runs[owner] = current
                    reconcileEarlyIdle(owner)
                }
                if let nativeSession = runs[owner]?.sessionID {
                    let key = Self.messageKey(nativeSession, entry.nativeID)
                    messageOwners.removeValue(forKey: key); userMessages.remove(key)
                }
                continuation.yield(.steeringCapabilitiesChanged)
            }
            throw ProviderSteeringError(.staleTarget)
        }
        steering[clientID]?.posted = true
        do {
            let response = try await call(method: "POST", path: ["session", run.sessionID, "prompt_async"], body: body)
            guard response.status == 204 else { throw OpenCodeV1SessionError.invalidResponse }
            steering[clientID]?.accepted = true
            markSteeringAccepted(owner: owner, nativeID: initial.nativeID)
            return try .init(turnID: run.inputID)
        } catch {
            if steering[clientID]?.observed == true {
                steering[clientID]?.accepted = true
                markSteeringAccepted(owner: owner, nativeID: initial.nativeID)
                return try .init(turnID: run.inputID)
            }
            if error is OpenCodeV1RejectedResponse {
                steering[clientID]?.rejected = true
                if var current = runs[owner], current.pendingSteeringID == initial.nativeID {
                    current.pendingSteeringID = nil; runs[owner] = current
                    reconcileEarlyIdle(owner)
                }
                continuation.yield(.steeringCapabilitiesChanged)
                throw ProviderSteeringError(.rejected)
            }
            if !closing { failConnection(.uncertainDelivery) }
            throw ProviderSteeringError(.outcomeUncertain)
        }
    }

    private func markSteeringAccepted(owner: UUID, nativeID: String) {
        guard var run = runs[owner], run.pendingSteeringID == nativeID else { return }
        run.steeringAccepted = true; runs[owner] = run
        releaseSteeringAdmission(owner)
    }

    private func releaseSteeringAdmission(_ owner: UUID) {
        guard var run = runs[owner], run.pendingSteeringID != nil, run.steeringAccepted, run.steeringObserved else { return }
        if run.idleEarly { reconcileEarlyIdle(owner) }
        else { run.pendingSteeringID = nil; runs[owner] = run; continuation.yield(.steeringCapabilitiesChanged) }
    }

    private func pruneSteering() {
        steering = steering.filter { steeringTasks[$0.key] != nil || runs[$0.value.owner] != nil }
    }

    private static func commandJSON(_ response: OpenCodeHTTPResponse) throws -> JSONValue {
        let type = response.headers["content-type"]?.split(separator: ";").first?.trimmingCharacters(in: .whitespaces).lowercased()
        guard response.status == 200, let type, type == "application/json" || type.hasSuffix("+json"),
              response.body.count <= 4_194_304,
              let value = try? JSONDecoder().decode(JSONValue.self, from: response.body) else { throw OpenCodeV1SessionError.invalidResponse }
        return value
    }

    private func ensureSession(captured: ProviderConfiguration, rules: [OpenCodeV1PermissionRule], token: UUID) async throws -> String {
        let existing = sessionID ?? captured.nativeThreadID
        if let cached = sessionID, let requested = captured.nativeThreadID, cached != requested { throw OpenCodeV1SessionError.wrongSession }
        let info: OpenCodeV1SessionInfo
        if let existing {
            try Self.identifier(existing)
            info = try OpenCodeV1Protocol.session(try await call(method: "GET", path: ["session", existing]), expectedID: existing, directory: cwd.path)
        } else {
            // The native ID is generated by the server. A lost response cannot
            // be recovered by a guessed title/time or a second create request.
            let response: OpenCodeHTTPResponse
            do { response = try await call(method: "POST", path: ["session"], body: .object(["permission": .array(rules.map(\.json))])) }
            catch {
                if error is OpenCodeV1RejectedResponse { throw OpenCodeV1SessionError.rejected }
                failConnection(.uncertainDelivery); throw OpenCodeV1SessionError.uncertainDelivery
            }
            do { info = try OpenCodeV1Protocol.session(response, directory: cwd.path) }
            catch { failConnection(.uncertainDelivery); throw OpenCodeV1SessionError.uncertainDelivery }
        }
        try requirePreparation(token)
        guard info.parentID == nil, !info.hasRevert else { throw OpenCodeV1SessionError.wrongSession }
        if sessionID == nil {
            let messages = try OpenCodeV1Protocol.messages(try await call(method: "GET", path: ["session", info.id, "message"]), sessionID: info.id)
            try requirePreparation(token)
            for message in messages { historicalMessages.insert(Self.messageKey(info.id, message.info.id)) }
        }
        sessionID = info.id; continuation.yield(.thread(info.id))
        return info.id
    }

    private func requirePreparation(_ token: UUID) throws {
        try Task.checkCancellation()
        guard !closing, !uncertain, preparing == token, !stoppedPreparations.contains(token) else { throw CancellationError() }
    }

    private func call(method: String, path: [String], query: [URLQueryItem] = [], body: JSONValue? = nil) async throws -> OpenCodeHTTPResponse {
        try Task.checkCancellation()
        guard !closing else { throw CancellationError() }
        let id = UUID(), transport = transport
        let task = Task { try await transport.request(method: method, path: path, query: query, body: body) }
        requests[id] = task
        defer { requests.removeValue(forKey: id) }
        return try await withTaskCancellationHandler {
            let response = try await task.value
            try Task.checkCancellation()
            if [400, 401, 403, 404, 409, 422].contains(response.status) { throw OpenCodeV1RejectedResponse() }
            return response
        } onCancel: { task.cancel() }
    }

    private func consume(_ inbound: OpenCodeSSEEvent) async {
        guard !closing, !uncertain else { return }
        do {
            let frame = try appMCPConnection.map { try $0.redactingOpenCodeEvent(inbound) } ?? inbound
            guard let event = try OpenCodeV1Protocol.decode(frame) else { return }
            if historyToken != nil, event.session?.parentID.map({ historySources.contains($0) }) == true { historyInterference = true }
            if historyToken != nil, event.sessionID.map({ historySources.contains($0) }) == true {
                // Preserve normal event projection even when a concurrent
                // native writer invalidates this read-only/history attempt.
                let ownCloneSettings = event.kind == .sessionUpdated && event.sessionID == historyCandidateID
                if !ownCloneSettings && event.kind != .sessionIdle && !(event.kind == .sessionStatus && event.status == .idle) {
                    historyInterference = true
                }
            }
            try await consume(event)
        } catch { failConnection(.invalidResponse) }
    }

    private func consume(_ event: OpenCodeV1Event) async throws {
        guard !closing, !uncertain else { return }
        if event.kind == .instanceDisposed || event.kind == .globalDisposed { throw OpenCodeV1SessionError.connectionLost }
        guard let nativeID = event.sessionID else {
            if event.kind == .sessionError { throw OpenCodeV1SessionError.connectionLost }
            return
        }
        if let info = event.session, let parent = info.parentID, nativeOwners[parent] != nil {
            guard childParents.count < 256 || childParents[nativeID] != nil else { throw OpenCodeV1SessionError.invalidResponse }
            childParents[nativeID] = parent
        }
        guard nativeID == sessionID || nativeOwners[nativeID] != nil || childParents[nativeID] != nil else { return }
        if nativeID != sessionID, nativeOwners[nativeID] == nil {
            try bufferChild(event, nativeID: nativeID); return
        }
        if event.kind == .permissionReplied || event.kind == .questionReplied || event.kind == .questionRejected {
            if let id = event.requestID { dismiss(nativeID: id, session: nativeID) }
            return
        }
        if let message = event.message {
            try await receive(message, event: event)
            return
        }
        let messageID = event.part?.messageID ?? event.messageID ?? event.permission?.toolMessageID ?? event.question?.toolMessageID
        let owner = messageID.flatMap { messageOwners[Self.messageKey(nativeID, $0)] } ?? nativeOwners[nativeID]
        guard let owner, runs[owner] != nil else { return }
        if let part = event.part {
            let key = Self.messageKey(nativeID, part.messageID)
            if userMessages.contains(key) { return }
            if messageOwners[key] == nil {
                if historicalMessages.contains(key) { return }
                try bufferPart(event, key: key); return
            }
        } else if event.kind == .partDelta, let messageID, userMessages.contains(Self.messageKey(nativeID, messageID)) {
            return
        } else if event.kind == .partDelta, let messageID, messageOwners[Self.messageKey(nativeID, messageID)] == nil {
            let key = Self.messageKey(nativeID, messageID)
            if !historicalMessages.contains(key) { try bufferPart(event, key: key) }
            return
        }
        if let permission = event.permission { try receive(permission, owner: owner); return }
        if let question = event.question { try receive(question, owner: owner); return }
        switch event.kind {
        case .sessionStatus:
            if event.status == .busy || event.status == .retry { backgroundActive.insert(nativeID) }
            if event.status == .idle { try endNativeSession(nativeID, owner: owner, failed: false, interrupted: false) }
        case .sessionIdle: try endNativeSession(nativeID, owner: owner, failed: false, interrupted: false)
        case .sessionError:
            try endNativeSession(nativeID, owner: owner, failed: event.errorName != "MessageAbortedError", interrupted: event.errorName == "MessageAbortedError")
        case .sessionDeleted:
            backgroundActive.remove(nativeID)
            if nativeID == sessionID { throw OpenCodeV1SessionError.wrongSession }
            try endNativeSession(nativeID, owner: owner, failed: false, interrupted: true)
        default: try await project(event, owner: owner)
        }
    }

    private func receive(_ message: OpenCodeV1Message, event: OpenCodeV1Event) async throws {
        let key = Self.messageKey(message.sessionID, message.id)
        if historicalMessages.contains(key) { return }
        guard messageOwners.count < 8_192 || messageOwners[key] != nil else { throw OpenCodeV1SessionError.invalidResponse }
        if message.role == "user" { userMessages.insert(key) }
        var owner = messageOwners[key]
        if message.role == "assistant", let parent = message.parentID,
           let original = owner, let supplied = messageOwners[Self.messageKey(message.sessionID, parent)], original != supplied {
            throw OpenCodeV1SessionError.invalidResponse
        }
        if message.role == "assistant", owner == nil, let parent = message.parentID {
            owner = messageOwners[Self.messageKey(message.sessionID, parent)]
            if let owner { messageOwners[key] = owner }
        }
        if message.role == "user", owner == nil, let existing = nativeOwners[message.sessionID], message.sessionID != sessionID {
            owner = existing; messageOwners[key] = existing
        }
        if message.role == "user", owner == nil, message.sessionID == sessionID, activeRunID == nil, preparing == nil {
            // A real new native user message can prove autonomous work. Merely
            // seeing busy/idle cannot bind an unsent client input to that work.
            let id = UUID()
            runs[id] = .init(id: id, sessionID: message.sessionID, inputID: message.id, autonomous: true,
                             accepted: true, inputObserved: true)
            activeRunID = id; nativeOwners[message.sessionID] = id
            messageOwners[key] = id; owner = id
            continuation.yield(.activity(.init(id: id, state: .running, finishesRun: false)))
        }
        guard let owner, var run = runs[owner] else { return }
        if message.role == "user", message.id == run.inputID {
            run.inputObserved = true; runs[owner] = run; announce(owner); reconcileEarlyIdle(owner)
        }
        if message.role == "assistant", message.sessionID == run.sessionID {
            run.assistantObserved = true; run.inputObserved = true
            if message.completed { run.accepted = true; run.inputObserved = true }
            runs[owner] = run; announce(owner)
        }
        if message.sessionID == run.sessionID,
           message.role == "user" || (message.role == "assistant" && message.completed),
           let nativeID = message.role == "user" ? message.id : message.parentID,
           let clientID = steering.first(where: { $0.value.owner == owner && $0.value.nativeID == nativeID })?.key {
            guard steering[clientID]?.rejected != true else { failConnection(.uncertainDelivery); return }
            steering[clientID]?.observed = true
            if var active = runs[owner], active.pendingSteeringID == nativeID {
                active.steeringObserved = true
                if message.role == "assistant" { active.steeringAccepted = true; steering[clientID]?.accepted = true }
                runs[owner] = active
                releaseSteeringAdmission(owner)
            }
            continuation.yield(.context(runID: owner, event: .associateEntity(.init(sessionID: run.sessionID, type: "user_message", id: nativeID), clientMessageID: clientID)))
        }
        try await project(event, owner: owner)
        let waiting = earlyParts.removeValue(forKey: key) ?? []
        earlyPartBytes -= waiting.reduce(0) { $0 + Self.eventBytes($1) }
        for event in waiting { try await consume(event) }
    }

    private func project(_ event: OpenCodeV1Event, owner: UUID) async throws {
        guard let nativeID = event.sessionID else { return }
        let key = OpenCodeV1ProjectionOwner(sessionID: nativeID, runID: owner)
        var projector = projectors[key] ?? .init(instanceID: configuration.instanceID, sessionID: nativeID)
        let updates = try projector.apply(event)
        projectors[key] = projector
        for update in updates { publish(update, owner: owner) }
        if let part = event.part, let tool = part.tool, tool.name == "task", let child = tool.childSessionID,
           projector.isTaskCall(messageID: part.messageID, callID: tool.callID) {
            if let old = childCalls[child] {
                guard old.owner == owner, old.parentID == nativeID,
                      old.messageID == part.messageID, old.callID == tool.callID else { throw OpenCodeV1SessionError.invalidResponse }
                return
            }
            guard childCalls.count < 256 || childCalls[child] != nil else { throw OpenCodeV1SessionError.invalidResponse }
            childCalls[child] = .init(parentID: nativeID, owner: owner, messageID: part.messageID, callID: tool.callID)
            childParents[child] = nativeID; nativeOwners[child] = owner
            // Install the full parent policy without dropping native task-agent
            // recursion restrictions inherited by a freshly created child.
            let info = try OpenCodeV1Protocol.session(try await call(method: "GET", path: ["session", child]), expectedID: child, directory: cwd.path)
            guard info.parentID == nativeID else { throw OpenCodeV1SessionError.wrongSession }
            let parentRules = policies[nativeID] ?? []
            let own = (info.permissions ?? []).filter {
                !parentRules.contains($0) && ($0.action == "deny" ||
                    ($0.action == "allow" && $0.pattern != "*" && ["edit", "external_directory"].contains($0.permission)))
            }
            let rules = parentRules + own
            _ = try OpenCodeV1Protocol.session(try await call(method: "PATCH", path: ["session", child], body: .object(["permission": .array(rules.map(\.json))])), expectedID: child, directory: cwd.path)
            policies[child] = rules
            let waiting = earlyChildren.removeValue(forKey: child) ?? []
            earlyChildBytes -= waiting.reduce(0) { $0 + Self.eventBytes($1) }
            for event in waiting { try await consume(event) }
        }
    }

    private func publish(_ update: ProviderEntityUpdate, owner: UUID) {
        if owner == activeRunID, runs[owner]?.finished == false {
            continuation.yield(.context(runID: owner, event: .entity(update)))
        } else { continuation.yield(.runEntity(runID: owner, update: update)) }
    }

    private func announce(_ id: UUID) {
        guard var run = runs[id], !run.compaction, run.inputObserved, !run.announced, !run.finished else { return }
        run.announced = true; runs[id] = run
        continuation.yield(.context(runID: id, event: .turn(run.inputID)))
    }

    private func endNativeSession(_ nativeID: String, owner: UUID, failed: Bool, interrupted: Bool) throws {
        backgroundActive.remove(nativeID)
        if nativeID != runs[owner]?.sessionID {
            if let link = childCalls[nativeID] {
                let key = OpenCodeV1ProjectionOwner(sessionID: link.parentID, runID: link.owner)
                if var projector = projectors[key] {
                    let updates = try projector.childCompleted(messageID: link.messageID, callID: link.callID,
                        childSessionID: nativeID, outcome: interrupted ? .interrupted : failed ? .failed : .completed)
                    projectors[key] = projector
                    for update in updates { publish(update, owner: link.owner) }
                }
            }
            return
        }
        guard var run = runs[owner], !run.finished else { return }
        if run.compaction {
            // A session idle frame carries no compaction input identity. The
            // exact owned summarize response, or explicit Stop, settles it.
            if interrupted || run.stopped { finish(owner, state: .interrupted) }
            else if failed { throw OpenCodeV1SessionError.uncertainDelivery }
            return
        }
        if failed || interrupted {
            if run.pendingSteeringID != nil, !run.steeringObserved { failConnection(.uncertainDelivery); return }
            guard run.inputObserved else { throw OpenCodeV1SessionError.invalidResponse }
            finish(owner, state: interrupted || run.stopped ? .interrupted : .failed); return
        }
        if run.pendingSteeringID != nil {
            run.idleEarly = true; runs[owner] = run
            releaseSteeringAdmission(owner); return
        }
        guard run.accepted, run.inputObserved else {
            run.idleEarly = true; runs[owner] = run; return
        }
        finish(owner, state: run.stopped ? .interrupted : .idle)
    }

    private func reconcileEarlyIdle(_ id: UUID) {
        guard !closing, !uncertain, let run = runs[id], !run.finished, !run.stopped, run.idleEarly,
              run.accepted, run.inputObserved, reconciliation[id] == nil,
              run.pendingSteeringID == nil || (run.steeringAccepted && run.steeringObserved) else { return }
        let generation = run.generation
        reconciliationGenerations[id] = generation
        reconciliation[id] = Task { [weak self] in await self?.reconcileIdle(id, generation: generation) }
    }

    private func reconcileIdle(_ id: UUID, generation: Int) async {
        defer {
            if reconciliationGenerations[id] == generation {
                reconciliation.removeValue(forKey: id); reconciliationGenerations.removeValue(forKey: id)
            }
            // A newer admission may have invalidated this read. Keep every
            // request owned and joined, then reconcile its successor if needed.
            reconcileEarlyIdle(id)
        }
        do {
            guard let run = runs[id] else { return }
            let statuses = try OpenCodeV1Protocol.statuses(try await call(method: "GET", path: ["session", "status"]))
            guard !closing, !uncertain, var current = runs[id], !current.finished, !current.stopped,
                  current.generation == generation, current.accepted, current.inputObserved,
                  current.pendingSteeringID == nil || (current.steeringAccepted && current.steeringObserved) else { return }
            current.idleEarly = false; current.pendingSteeringID = nil; runs[id] = current
            continuation.yield(.steeringCapabilitiesChanged)
            if statuses[run.sessionID] == nil || statuses[run.sessionID] == .idle { finish(id, state: .idle) }
        } catch {
            guard !closing, let current = runs[id], !current.finished, current.generation == generation else { return }
            failConnection(.connectionLost)
        }
    }

    private func finish(_ id: UUID, state: ThreadState) {
        guard var run = runs[id], !run.finished else { return }
        run.finished = true; runs[id] = run
        if activeRunID == id { activeRunID = nil }
        if run.autonomous {
            continuation.yield(.activity(.init(id: id, state: .idle,
                stopReason: .string(state == .idle ? "end_turn" : state == .interrupted ? "cancelled" : "error"))))
        } else {
            if state == .failed {
                continuation.yield(.context(runID: id, event: .message(.init(id: "opencode-v1-failure-" + id.uuidString,
                    role: .system, text: "OpenCode could not complete this turn."))))
            }
            continuation.yield(.context(runID: id, event: .completed(state)))
        }
    }

    public func interrupt() async throws {
        guard historyToken == nil else { throw ProviderHistoryError(.notIdle) }
        if let token = preparing { stoppedPreparations.insert(token) }
        guard !closing else { throw CancellationError() }
        if let id = activeRunID, var run = runs[id] {
            run.stopped = true; run.generation += 1; runs[id] = run
            let ownedSteering = steering.filter { $0.value.owner == id }
            for clientID in ownedSteering.keys { steeringTasks[clientID]?.cancel() }
            let unknownSteering = ownedSteering.values.contains { $0.posted && !$0.observed && !$0.rejected }
            if unknownSteering || (!run.inputObserved && !run.assistantObserved) {
                // The native abort may race a POST still entering the server.
                // Do not report known cancellation or leave a delayed POST alive.
                failConnection(.uncertainDelivery); await close()
                throw OpenCodeV1SessionError.uncertainDelivery
            }
        }
        guard let root = sessionID else { return }
        try Self.boolean(try await call(method: "POST", path: ["session", root, "abort"], body: .object([:])))
        try await abortDescendants(root)
    }

    private func abortDescendants(_ root: String) async throws {
        var queue = [root], seen: Set<String> = [root]
        let deadline = ContinuousClock.now + .seconds(15)
        while !queue.isEmpty {
            guard ContinuousClock.now < deadline, seen.count <= 256 else { throw OpenCodeV1SessionError.invalidResponse }
            let parent = queue.removeFirst()
            let children = try OpenCodeV1Protocol.children(try await call(method: "GET", path: ["session", parent, "children"]), parentID: parent, directory: cwd.path)
            for child in children where seen.insert(child.id).inserted {
                queue.append(child.id)
                try Self.boolean(try await call(method: "POST", path: ["session", child.id, "abort"], body: .object([:])))
            }
        }
    }

    private func receive(_ permission: OpenCodeV1Permission, owner: UUID) throws {
        let key = Self.requestKey(permission.sessionID, permission.id)
        guard !settledRequests.contains(key) else { return }
        if pending.values.contains(where: { $0.nativeID == permission.id && $0.sessionID == permission.sessionID }) { return }
        guard pending.count < 256 else { throw OpenCodeV1SessionError.invalidResponse }
        let id = JSONValue.string("opencode-v1-request-" + UUID().uuidString)
        let request = permission.approval(localID: id)
        pending[id] = .init(request: request, owner: owner, sessionID: permission.sessionID,
                            nativeID: permission.id, permission: permission, question: nil)
        continuation.yield(.sessionApproval(request))
    }

    private func receive(_ question: OpenCodeV1Question, owner: UUID) throws {
        guard !settledRequests.contains(Self.requestKey(question.sessionID, question.id)) else { return }
        if pending.values.contains(where: { $0.nativeID == question.id && $0.sessionID == question.sessionID }) { return }
        guard pending.count < 256 else { throw OpenCodeV1SessionError.invalidResponse }
        let id = JSONValue.string("opencode-v1-request-" + UUID().uuidString)
        let request = question.approval(localID: id)
        pending[id] = .init(request: request, owner: owner, sessionID: question.sessionID,
                            nativeID: question.id, permission: nil, question: question)
        continuation.yield(.sessionApproval(request))
    }

    public func respond(_ request: ApprovalRequest, allow: Bool) async throws {
        let entry = try pendingEntry(request)
        if let permission = entry.permission {
            try await reply(entry, path: ["permission", entry.nativeID, "reply"], body: permission.replyBody(decision: allow ? .once : .reject))
        } else if !allow, entry.question != nil {
            try await reply(entry, path: ["question", entry.nativeID, "reject"], body: .object([:]))
        } else { throw OpenCodeV1SessionError.staleRequest }
    }

    public func answer(_ request: ApprovalRequest, answers: [String: String]) async throws {
        let entry = try pendingEntry(request)
        guard let question = entry.question else { throw OpenCodeV1SessionError.staleRequest }
        try await reply(entry, path: ["question", entry.nativeID, "reply"], body: question.answerBody(answers: answers))
    }

    public func selectAnswers(_ request: ApprovalRequest, selections: [String: [String]]) async throws {
        let entry = try pendingEntry(request)
        guard let question = entry.question else { throw OpenCodeV1SessionError.staleRequest }
        try await reply(entry, path: ["question", entry.nativeID, "reply"], body: question.answerBody(selections: selections))
    }

    public func choose(_ request: ApprovalRequest, optionID: String) async throws {
        let entry = try pendingEntry(request)
        guard let permission = entry.permission else { throw OpenCodeV1SessionError.staleRequest }
        if optionID == "conversation" {
            guard !permission.always.isEmpty, answering.insert(request.id).inserted else { throw OpenCodeV1SessionError.staleRequest }
            var rules = policies[entry.sessionID] ?? []
            for pattern in permission.always {
                let rule = OpenCodeV1PermissionRule(permission: permission.permission, pattern: pattern, action: "allow")
                if !rules.contains(rule) { rules.append(rule) }
            }
            guard rules.count <= 1_024 else { answering.remove(request.id); throw OpenCodeV1SessionError.invalidResponse }
            do {
                let updated = try OpenCodeV1Protocol.session(try await call(method: "PATCH", path: ["session", entry.sessionID], body: .object(["permission": .array(rules.map(\.json))])), expectedID: entry.sessionID, directory: cwd.path)
                guard updated.permissions == rules else { throw OpenCodeV1SessionError.invalidResponse }
                grants[entry.sessionID] = rules.filter { !(policies[entry.sessionID] ?? []).contains($0) }
                policies[entry.sessionID] = rules
                try await reply(entry, path: ["permission", entry.nativeID, "reply"], body: permission.replyBody(decision: .once), reserved: true)
            } catch { answering.remove(request.id); throw error }
            return
        }
        let decision: OpenCodeV1Permission.Decision
        switch optionID { case "once": decision = .once; case "always": decision = .always; case "reject": decision = .reject; default: throw OpenCodeV1SessionError.staleRequest }
        try await reply(entry, path: ["permission", entry.nativeID, "reply"], body: permission.replyBody(decision: decision,
            message: decision == .reject ? "The user declined this action. Do not retry it through another tool." : nil))
    }

    private func pendingEntry(_ request: ApprovalRequest) throws -> OpenCodeV1PendingRequest {
        guard !closing, !uncertain, let entry = pending[request.id], entry.request == request else { throw OpenCodeV1SessionError.staleRequest }
        return entry
    }

    private func reply(_ entry: OpenCodeV1PendingRequest, path: [String], body: JSONValue, reserved: Bool = false) async throws {
        guard !closing, !uncertain, pending[entry.request.id]?.request == entry.request else { throw OpenCodeV1SessionError.staleRequest }
        if !reserved, !answering.insert(entry.request.id).inserted { throw OpenCodeV1SessionError.staleRequest }
        do { try Self.boolean(try await call(method: "POST", path: path, body: body)) }
        catch {
            if pending[entry.request.id] == nil { return }
            if error is OpenCodeV1RejectedResponse { answering.remove(entry.request.id) }
            else { failConnection(.uncertainDelivery) }
            throw OpenCodeV1SessionError.invalidResponse
        }
        // The event, not a local request completion, settles the native request.
        // Keep the answer reservation until that exact replied/rejected notice.
    }

    private func dismiss(nativeID: String, session: String) {
        let key = Self.requestKey(session, nativeID)
        if !settledRequests.contains(key) { settledRequests.append(key) }
        if settledRequests.count > 1_024 { settledRequests.removeFirst(256) }
        for (id, entry) in pending where entry.sessionID == session && entry.nativeID == nativeID {
            pending.removeValue(forKey: id); answering.remove(id)
            continuation.yield(.sessionApprovalDismissed(id))
        }
    }

    private func bufferPart(_ event: OpenCodeV1Event, key: ProviderEntityKey) throws {
        let size = Self.eventBytes(event)
        guard earlyParts.values.reduce(0, { $0 + $1.count }) < 256, earlyPartBytes + size <= 2 * 1_024 * 1_024 else { throw OpenCodeV1SessionError.invalidResponse }
        earlyParts[key, default: []].append(event); earlyPartBytes += size
    }

    private func bufferChild(_ event: OpenCodeV1Event, nativeID: String) throws {
        let size = Self.eventBytes(event)
        guard earlyChildren.values.reduce(0, { $0 + $1.count }) < 256, earlyChildBytes + size <= 2 * 1_024 * 1_024 else { throw OpenCodeV1SessionError.invalidResponse }
        earlyChildren[nativeID, default: []].append(event); earlyChildBytes += size
    }

    private func streamEnded(category: String) {
        guard !closing, !uncertain else { return }
        // `category` is selected solely from fixed local literals or the
        // finite OpenCodeSSEConnectionError allowlist, never an error payload.
        let run = activeRunID?.uuidString ?? "none"
        logger.error("Event stream ended: category=\(category, privacy: .public) run=\(run, privacy: .public)")
        failConnection(.connectionLost)
    }

    private func failConnection(_ error: OpenCodeV1SessionError) {
        guard !closing, !uncertain else { return }
        uncertain = true; continuation.yield(.connectionClosed(error.localizedDescription))
    }

    public func close() async {
        if let closeTask { await closeTask.value; return }
        closing = true
        let task = Task { await self.finishClose() }
        closeTask = task; await task.value
    }

    private func finishClose() async {
        if let token = preparing { stoppedPreparations.insert(token) }
        connecting?.cancel()
        let owned = Array(requests.values), reconciles = Array(reconciliation.values)
        let ownedSteering = Array(steeringTasks.values)
        for task in ownedSteering { task.cancel() }
        let ownedHistory = historyTask
        ownedHistory?.cancel()
        for request in owned { request.cancel() }
        for task in reconciles { task.cancel() }
        let transport = transport
        let nativeIDs = connected ? Set(nativeOwners.keys).union(sessionID.map { [$0] } ?? []) : []
        let stop = Task {
            for id in nativeIDs.sorted() { _ = try? await transport.request(method: "POST", path: ["session", id, "abort"], body: .object([:])) }
        }
        let deadline = Task {
            do { try await Task.sleep(for: .seconds(2)) } catch { return }
            await transport.close()
        }
        await stop.value; deadline.cancel(); await deadline.value
        await transport.close()
        for request in owned { _ = try? await request.value }
        for task in reconciles { await task.value }
        for task in ownedSteering { _ = await task.result }
        if let ownedHistory { _ = await ownedHistory.result }
        if let connecting { _ = try? await connecting.value }
        reader?.cancel(); await reader?.value
        continuation.finish()
    }

    private func trimRuns() {
        guard runs.count >= 128 else { return }
        let retained = Set(backgroundActive.compactMap { nativeOwners[$0] }).union(pending.values.map(\.owner)).union(inFlightSends)
        for id in runs.keys where id != activeRunID && runs[id]?.finished == true && !retained.contains(id) { runs.removeValue(forKey: id) }
        guard runs.count < 256 else { return }
        messageOwners = messageOwners.filter { runs[$0.value] != nil }
        userMessages = userMessages.filter { messageOwners[$0] != nil }
        projectors = projectors.filter { runs[$0.key.runID] != nil }
        nativeOwners = nativeOwners.filter { runs[$0.value] != nil }
        childCalls = childCalls.filter { runs[$0.value.owner] != nil }
        childParents = childParents.filter { childCalls[$0.key] != nil || nativeOwners[$0.value] != nil }
    }

    private func nextMessageID() -> String {
        let now = UInt64(max(0, Date().timeIntervalSince1970 * 1_000))
        if now > lastMessageMillis { lastMessageMillis = now; messageCounter = 0 }
        messageCounter += 1
        let timestamp = (lastMessageMillis &* 4_096 &+ messageCounter) & 0xffffffffffff
        let alphabet = Array("0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz")
        let suffix = String((0..<28).map { _ in alphabet.randomElement()! })
        return "msg_" + String(format: "%012llx", timestamp) + suffix
    }

    private static func resolveModel(_ selected: OpenCodeModelSelection?, inventory: OpenCodeMetadataSnapshot) throws -> OpenCodeModelSelection? {
        // /provider.default contains one default per provider, not the actual
        // agent/history/config default. Omission delegates that choice natively.
        guard let model = selected else { return nil }
        guard
              let row = inventory.models.first(where: { $0.selection.providerID == model.providerID && $0.selection.id == model.id && $0.enabled }),
              model.variant == nil || row.variants.contains(model.variant!) else { throw OpenCodeV1SessionError.invalidConfiguration }
        return model
    }

    private static func permissionRules(_ permission: PermissionMode, agent: String, native: [OpenCodeV1PermissionRule], appMCP: Bool = false) -> [OpenCodeV1PermissionRule] {
        func rule(_ name: String, _ action: String) -> OpenCodeV1PermissionRule { .init(permission: name, pattern: "*", action: action) }
        func rule(_ name: String, _ pattern: String, _ action: String) -> OpenCodeV1PermissionRule { .init(permission: name, pattern: pattern, action: action) }
        var result: [OpenCodeV1PermissionRule]
        if permission == .fullAccess { result = [rule("*", "allow")] }
        else {
            let restricted = ["bash", "edit", "webfetch", "websearch", "codesearch", "external_directory", "doom_loop"]
            result = [rule("*", "deny")] + restricted.map { rule($0, "deny") }
            result += [rule("*", "ask")] + restricted.map { rule($0, "ask") }
            result += ["question", "read", "glob", "grep", "lsp", "todowrite", "task", "skill"].map { rule($0, "allow") }
            result += [rule("read", "*.env", "ask"), rule("read", "*.env.*", "ask"), rule("read", "*.env.example", "allow")]
            if permission == .autoAcceptEdits { result.append(rule("edit", "allow")) }
        }
        // Session policy must not erase the selected native agent's explicit
        // restrictions; plan-specific path allowances remain narrow and ordered.
        if agent == "plan", !native.contains(where: { $0.permission == "edit" && $0.pattern == "*" && $0.action == "deny" }) {
            result.append(rule("edit", "deny"))
        }
        result += native.filter {
            $0.action == "deny" || ($0.action == "allow" && $0.pattern != "*" && ["edit", "external_directory"].contains($0.permission))
        }
        // The owned app tool already checks captured permissions and exact run
        // authority. This narrow native allowance cannot authorize other MCP servers.
        if appMCP { result.append(rule(OpenCodeAppMCP.serverName + "_*", "allow")) }
        return result
    }

    private static func parts(_ input: ProviderInput) throws -> [JSONValue] {
        guard input.text.utf8.count <= 2 * 1_024 * 1_024, input.images.count <= 100,
              !input.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !input.images.isEmpty,
              input.images.allSatisfy({ $0.data.count <= 20 * 1_024 * 1_024 && ["image/png", "image/jpeg", "image/gif", "image/webp"].contains($0.mimeType) }) else { throw OpenCodeV1SessionError.unsupportedInput }
        var parts: [JSONValue] = []
        if !input.text.isEmpty { parts.append(.object(["type": .string("text"), "text": .string(input.text)])) }
        parts += input.images.map { .object(["type": .string("file"), "mime": .string($0.mimeType), "url": .string("data:" + $0.mimeType + ";base64," + $0.data.base64EncodedString())]) }
        return parts
    }

    private static func boolean(_ response: OpenCodeHTTPResponse) throws {
        guard response.status == 200, (try? JSONDecoder().decode(JSONValue.self, from: response.body)) == .bool(true) else { throw OpenCodeV1SessionError.invalidResponse }
    }
    private static func identifier(_ id: String) throws {
        guard !id.isEmpty, id.utf8.count <= 1_024, !id.contains("/"), !id.contains("\\"), !id.unicodeScalars.contains(where: { $0.value < 32 || $0.value == 127 }) else { throw OpenCodeV1SessionError.wrongSession }
    }
    private static func messageKey(_ session: String, _ id: String) -> ProviderEntityKey { .init(sessionID: session, type: "message", id: id) }
    private static func requestKey(_ session: String, _ id: String) -> ProviderEntityKey { .init(sessionID: session, type: "request", id: id) }
    private static func eventBytes(_ event: OpenCodeV1Event) -> Int {
        var count = 16_384 + (event.part?.text?.utf8.count ?? 0) + (event.delta?.utf8.count ?? 0)
        if let tool = event.part?.tool {
            count += (try? JSONEncoder().encode(tool.input).count) ?? 4_194_304
            count += (tool.output?.utf8.count ?? 0) + (tool.title?.utf8.count ?? 0)
        }
        if let permission = event.permission { count += (permission.patterns + permission.always).reduce(0) { $0 + $1.utf8.count } }
        if let question = event.question {
            for item in question.questions {
                count += item.question.utf8.count + item.header.utf8.count
                count += item.options.reduce(0) { $0 + $1.label.utf8.count + $1.description.utf8.count }
            }
        }
        if let info = event.session { count += (info.permissions ?? []).reduce(0) { $0 + $1.permission.utf8.count + $1.pattern.utf8.count + 64 } }
        return count
    }
}

private struct OpenCodeV1Run {
    let id: UUID
    let sessionID: String
    let inputID: String
    let autonomous: Bool
    var compaction = false
    var nativeCommand = false
    var configuration: ProviderConfiguration?
    var model: OpenCodeModelSelection?
    var agentID: String?
    var pendingSteeringID: String?
    var steeringAccepted = false
    var steeringObserved = false
    var steeringCount = 0
    var accepted = false
    var inputObserved = false
    var assistantObserved = false
    var announced = false
    var idleEarly = false
    var stopped = false
    var finished = false
    var generation = 0
}

private struct OpenCodeV1SteeringInput {
    let owner: UUID
    let nativeID: String
    let fingerprint: String
    var posted = false
    var accepted = false
    var observed = false
    var rejected = false
}

private struct OpenCodeV1ProjectionOwner: Hashable { let sessionID: String; let runID: UUID }
private struct OpenCodeV1ChildCall { let parentID: String; let owner: UUID; let messageID: String; let callID: String }
private struct OpenCodeV1PendingRequest {
    let request: ApprovalRequest
    let owner: UUID
    let sessionID: String
    let nativeID: String
    let permission: OpenCodeV1Permission?
    let question: OpenCodeV1Question?
}
private struct OpenCodeV1RejectedResponse: Error {}

private actor OpenCodeV1OwnedRuntime: OpenCodeV1SessionTransport {
    private let owner: OpenCodeOwnedServer
    private let cwd: URL
    private var client: OpenCodeHTTPClient?
    private var metadata: OpenCodeMetadataConnection?
    private var stream: OpenCodeSSEConnection?
    private var closing = false
    private var appMCPConnection: AppMCPConnection?
    private var appMCP: OpenCodeAppMCP?

    func configureAppMCPRedaction(_ connection: AppMCPConnection) throws {
        guard !closing, client == nil, appMCPConnection == nil else { throw OpenCodeAppMCP.failure() }
        appMCPConnection = connection
    }

    func prepareAppMCP() async throws {
        guard !closing, let appMCP else { throw OpenCodeAppMCP.failure() }
        try await appMCP.prepare()
        guard !closing else { throw OpenCodeAppMCP.failure() }
    }

    init(executable: URL, cwd: URL, configuration: OpenCodeConfiguration) {
        let canonical = cwd.standardizedFileURL.resolvingSymlinksInPath()
        self.cwd = canonical
        owner = .init(executable: executable, generation: .v1, cwd: canonical)
    }

    func connect() async throws -> AsyncThrowingStream<OpenCodeSSEEvent, any Error> {
        guard !closing, client == nil else { throw OpenCodeV1SessionError.closed }
        do {
            let endpoint = try await owner.start()
            guard !closing else { throw CancellationError() }
            let client = try OpenCodeHTTPClient(origin: endpoint.origin, credential: endpoint.credential)
            self.client = client
            if let connection = appMCPConnection {
                try await client.configureAppMCPRedaction(connection)
                appMCP = OpenCodeAppMCP(client: client, generation: .v1, directory: cwd, connection: connection)
            }
            let metadata = OpenCodeMetadataConnection(client: client, expectedGeneration: .v1, ownedProcessIdentifier: endpoint.processIdentifier)
            self.metadata = metadata
            _ = try await metadata.identify()
            guard !closing else { throw CancellationError() }
            let stream = try await OpenCodeSSEConnection.open(client: client, generation: .v1, directory: cwd)
            self.stream = stream
            guard !closing else { throw CancellationError() }
            return stream.events
        } catch { await close(); throw error }
    }

    func inventory(directory: URL) async throws -> OpenCodeMetadataSnapshot {
        guard !closing, let metadata else { throw OpenCodeV1SessionError.closed }
        return try await metadata.inventory(directory: directory)
    }

    func commands(directory: URL) async throws -> ProviderCommandInventory {
        guard !closing, let metadata else { throw OpenCodeV1SessionError.closed }
        return try await metadata.commands(directory: directory)
    }

    func agentPermissionRules(directory: URL, agentID: String) async throws -> [OpenCodeV1PermissionRule] {
        let response = try await request(method: "GET", path: ["agent"], body: nil)
        guard response.status == 200, let value = try? JSONDecoder().decode(JSONValue.self, from: response.body),
              let entries = value.array, entries.count <= 512,
              let agent = entries.first(where: { $0["name"] == .string(agentID) }) else { throw OpenCodeV1SessionError.invalidConfiguration }
        if agent["permission"] == .null { return [] }
        return try OpenCodeV1Protocol.permissionRules(agent["permission"])
    }

    func request(method: String, path: [String], body: JSONValue?) async throws -> OpenCodeHTTPResponse {
        try await request(method: method, path: path, query: [], body: body)
    }

    func request(method: String, path: [String], query: [URLQueryItem], body: JSONValue?) async throws -> OpenCodeHTTPResponse {
        guard !closing, let client else { throw OpenCodeV1SessionError.closed }
        guard !query.contains(where: { $0.name == "directory" }) else { throw OpenCodeV1SessionError.invalidConfiguration }
        return try await client.request(method: method, path: path, query: query + [.init(name: "directory", value: cwd.path)],
            body: try body.map { try JSONEncoder().encode($0) },
            maximumBytes: path.last == "message" && query.isEmpty ? 16 * 1_024 * 1_024 : 4 * 1_024 * 1_024)
    }

    func close() async {
        closing = true
        await appMCP?.close()
        appMCP = nil; appMCPConnection = nil
        await stream?.close(); await metadata?.close(); await client?.close(); await owner.close()
    }
}
