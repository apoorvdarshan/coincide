import CryptoKit
import Foundation

/// Fixed errors deliberately omit URLs, native payloads and provider credentials.
public enum OpenCodeV2SessionError: Error, Sendable, Equatable, LocalizedError {
    case closed, busy, invalidConfiguration, wrongSession, unsupportedInput
    case rejected, uncertainDelivery, connectionLost, invalidResponse, staleRequest

    public var errorDescription: String? {
        switch self {
        case .closed: "The OpenCode connection is closed."
        case .busy: "OpenCode already has active work. Stop or finish it before sending another message."
        case .invalidConfiguration: "The captured OpenCode configuration is unavailable or no longer matches this connection."
        case .wrongSession: "The OpenCode conversation does not match this workspace."
        case .unsupportedInput: "This input exceeds the native OpenCode request limit or uses an unsupported attachment."
        case .rejected: "OpenCode rejected this request before accepting the input."
        case .uncertainDelivery: "OpenCode may have accepted this input. The queue is paused; do not resend it automatically."
        case .connectionLost: "The OpenCode event connection was lost. The queue is paused; inspect native work before continuing."
        case .invalidResponse: "OpenCode returned a response that could not be verified safely."
        case .staleRequest: "This OpenCode request is no longer pending on this connection."
        }
    }
}

/// The production runtime and synthetic peers share the same adapter boundary.
/// A transport belongs to exactly one actor; credentials and endpoints stay here.
protocol OpenCodeV2SessionTransport: Sendable {
    func connect() async throws -> AsyncThrowingStream<OpenCodeSSEEvent, any Error>
    func inventory(directory: URL) async throws -> OpenCodeMetadataSnapshot
    func commands(directory: URL) async throws -> ProviderCommandInventory
    func agentPathRules(directory: URL, agentID: String) async throws -> [OpenCodeV2PermissionRule]
    func request(method: String, path: [String], body: JSONValue?) async throws -> OpenCodeHTTPResponse
    func request(method: String, path: [String], query: [URLQueryItem], body: JSONValue?) async throws -> OpenCodeHTTPResponse
    func configureAppMCPRedaction(_ connection: AppMCPConnection) async throws
    func prepareAppMCP() async throws
    func close() async
}

extension OpenCodeV2SessionTransport {
    func configureAppMCPRedaction(_ connection: AppMCPConnection) async throws {}
    func prepareAppMCP() async throws { throw OpenCodeAppMCP.failure() }
    func commands(directory: URL) async throws -> ProviderCommandInventory { throw ProviderCommandError(.unsupported) }
    func agentPathRules(directory: URL, agentID: String) async throws -> [OpenCodeV2PermissionRule] { [] }
    func request(method: String, path: [String], query: [URLQueryItem], body: JSONValue?) async throws -> OpenCodeHTTPResponse {
        guard query.isEmpty else { throw ProviderHistoryError(.unsupported) }
        return try await request(method: method, path: path, body: body)
    }
}

/// Native OpenCode 2 HTTP conversation. Admission, execution and stream ownership
/// are separate; neither an HTTP acknowledgement nor a step end completes a run.
public actor OpenCodeV2Session: ProviderSession {
    public nonisolated let supportsAppMCP = true
    private var appMCPConnection: AppMCPConnection?
    private var appMCPConfiguring = false
    public nonisolated let events: AsyncStream<ProviderEvent>
    private let continuation: AsyncStream<ProviderEvent>.Continuation
    private let cwd: URL
    private let historyWorkspacePath: String
    private let configuration: OpenCodeConfiguration
    private let transport: any OpenCodeV2SessionTransport
    private var connecting: Task<Void, any Error>?
    private var reader: Task<Void, Never>?
    private var connected = false
    private var closing = false
    private var closingTask: Task<Void, Never>?
    private var uncertain = false
    private var sessionID: String?
    private var preparing: UUID?
    private var stoppedPreparations: Set<UUID> = []
    private var activeRunID: UUID?
    private var inFlightSends: Set<UUID> = []
    private var runs: [UUID: OpenCodeNativeRun] = [:]
    private var owners: [String: UUID] = [:]
    private var assistantOwners: [ProviderEntityKey: UUID] = [:]
    private var assistantBuffer: [ProviderEntityKey: [OpenCodeV2Event]] = [:]
    private var assistantBufferBytes = 0
    private var projectors: [OpenCodeProjectionOwner: OpenCodeV2Projection] = [:]
    private var childParents: [String: String] = [:]
    private var childCalls: [String: OpenCodeChildCall] = [:]
    private var earlyChildFrames: [String: [OpenCodeSSEEvent]] = [:]
    private var earlyChildBytes = 0
    private var pending: [JSONValue: OpenCodePendingRequest] = [:]
    private var answering: Set<JSONValue> = []
    private var policies: [String: OpenCodeNativePolicy] = [:]
    private var sessionGrants: [String: [OpenCodeV2PermissionRule]] = [:]
    private var knownSubagentCalls: Set<ProviderEntityKey> = []
    private var requests: [UUID: Task<OpenCodeHTTPResponse, any Error>] = [:]
    private var seenEventIDs: [String] = []
    private var lastSequences: [String: Int] = [:]
    private var backgroundActive: Set<String> = []
    private var steers: [String: OpenCodeNativeSteer] = [:]
    private var steeringTasks: [String: Task<ProviderSteeringReceipt, any Error>] = [:]
    private var strandedSteers: Set<String> = []
    private var interrupting: UUID?
    private var historyToken: UUID?
    private var historyTask: Task<OpenCodeV2HistorySnapshot, any Error>?
    private var historyWatch: OpenCodeHistoryWatch?
    private var historyUnsafe = false
    private var historyMayHaveWritten = false
    private var commandScanSignals: Set<String> = []
    private var commandScanWaiters: [UUID: OpenCodeCommandScanWaiter] = [:]
    private var commandInputWaiters: [UUID: OpenCodeCommandInputWaiter] = [:]

    public init(executable: URL, cwd: URL, configuration: OpenCodeConfiguration) {
        let pair = AsyncStream<ProviderEvent>.makeStream()
        events = pair.stream; continuation = pair.continuation
        self.cwd = cwd.standardizedFileURL.resolvingSymlinksInPath()
        historyWorkspacePath = cwd.standardizedFileURL.path
        self.configuration = configuration
        transport = OpenCodeV2OwnedRuntime(executable: executable, cwd: cwd, configuration: configuration)
    }

    init(cwd: URL, configuration: OpenCodeConfiguration, transport: any OpenCodeV2SessionTransport) {
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
        // The HTTP identity can be ready before native model initialization.
        // Retry only its explicit temporary 503 observation, never a mutation,
        // authentication refusal, malformed response or admitted provider input.
        let deadline = ContinuousClock.now + .seconds(10)
        while true {
            try Task.checkCancellation()
            guard !closing else { throw CancellationError() }
            do {
                let value = try await transport.inventory(directory: cwd)
                guard !closing else { throw CancellationError() }
                return value
            } catch OpenCodeProtocolError.unavailable {
                guard ContinuousClock.now < deadline else { throw OpenCodeProtocolError.unavailable }
                try await Task.sleep(for: .milliseconds(250))
            }
        }
    }

    public func models() async throws -> [ProviderModel] {
        try await openCodeInventory().models.filter(\.enabled).map {
            .init(id: $0.selection.catalogID, name: $0.name,
                  openCodeSelection: $0.selection, openCodeVariants: $0.variants)
        }
    }

    public func providerCommands(forceReload: Bool = false) async throws -> ProviderCommandInventory {
        try await connect()
        var inventory = try await transport.commands(directory: cwd)
        var scanIncomplete = false
        // The first read starts the native background workspace scan. Listen
        // before it (connect above), then read once more after both updates or
        // the bounded deadline, matching the pinned native catalog contract.
        if inventory.commands.allSatisfy({ $0.source == "builtin" }),
           !inventory.problems.contains(where: { $0.component == .commands }) {
            scanIncomplete = !(await awaitCommandScan())
            try Task.checkCancellation()
            guard !closing, !uncertain else { throw ProviderCommandError(.unavailable) }
            inventory = try await transport.commands(directory: cwd)
        }
        guard !closing, !uncertain, CodexSkillInventory.sameWorkspace(inventory.cwd, historyWorkspacePath) else { throw ProviderCommandError(.unavailable) }
        try inventory.validate()
        var problems = inventory.problems
        if scanIncomplete {
            guard problems.count < 256 else { throw ProviderCommandError(.invalidResponse) }
            problems.append(.init(component: .commands, message: "The native workspace scan has not finished. Refresh before selecting missing commands or skills."))
        }
        return .init(cwd: historyWorkspacePath, commands: inventory.commands, skills: inventory.skills,
            problems: problems, checkedAt: inventory.checkedAt)
    }

    private func awaitCommandScan() async -> Bool {
        if commandScanSignals.count == 2 { return true }
        let id = UUID()
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                guard !Task.isCancelled, !closing, !uncertain else { continuation.resume(returning: false); return }
                if commandScanSignals.count == 2 { continuation.resume(returning: true); return }
                let deadline = Task { [weak self] in
                    do { try await Task.sleep(for: .seconds(10)) } catch { return }
                    await self?.finishCommandScan(id, ready: false)
                }
                commandScanWaiters[id] = .init(continuation: continuation, deadline: deadline)
            }
        } onCancel: { Task { await self.finishCommandScan(id, ready: false) } }
    }

    private func finishCommandScan(_ id: UUID, ready: Bool) {
        guard let waiter = commandScanWaiters.removeValue(forKey: id) else { return }
        waiter.deadline.cancel(); waiter.continuation.resume(returning: ready)
    }

    private func finishCommandScans(ready: Bool) {
        for id in Array(commandScanWaiters.keys) { finishCommandScan(id, ready: ready) }
    }

    public func openCodeV2HistorySnapshot(threadID: String) async throws -> OpenCodeV2HistorySnapshot {
        try await withHistory(sourceID: threadID, timeout: .seconds(30)) { token in
            try await self.readHistorySnapshot(threadID, token: token)
        }
    }

    public func applyOpenCodeV2History(review: OpenCodeV2HistoryReviewEvidence, kind: ConversationHistoryKind,
                                      configuration captured: ProviderConfiguration) async throws -> ProviderConversationSnapshot {
        try review.validate()
        try OpenCodeConfigurationValidation.configuration(captured)
        guard review.source.matchesBinding(captured), captured.openCodeConfiguration?.runtimeIdentity == configuration.runtimeIdentity,
              captured.workspacePath == historyWorkspacePath else { throw ProviderHistoryError(.invalidRequest) }
        let sourceID = review.source.reference.nativeThreadID
        let result = try await withHistory(sourceID: sourceID, timeout: .seconds(90)) { token in
            let current = try await self.readHistorySnapshot(sourceID, token: token)
            guard current == review.source, current.stage == nil else { throw ProviderHistoryError(.historyChanged) }
            try await self.checkHistory(token)
            if kind == .forkAfterRun {
                return try await self.forkHistory(review, token: token)
            }
            return try await self.revertHistory(review, token: token)
        }
        return try .init(reference: result.reference, workspacePath: result.workspacePath,
                         historyMode: .messageOrdered, openCodeV2: result)
    }

    public func clearOpenCodeV2HistoryStage(expected: OpenCodeV2HistorySnapshot) async throws -> OpenCodeV2HistorySnapshot {
        try expected.validate()
        guard expected.runtimeIdentity == configuration.runtimeIdentity, expected.workspacePath == historyWorkspacePath,
              let stage = expected.stage, stage.isHistoryOnly else { throw ProviderHistoryError(.invalidRequest) }
        return try await withHistory(sourceID: expected.reference.nativeThreadID, timeout: .seconds(60)) { token in
            let current = try await self.readHistorySnapshot(expected.reference.nativeThreadID, token: token)
            guard current == expected else { throw ProviderHistoryError(.historyChanged) }
            try await self.checkHistory(token)
            return try await self.clearHistory(expected, token: token)
        }
    }

    private func withHistory(sourceID: String, timeout: Duration,
        operation: @escaping @Sendable (UUID) async throws -> OpenCodeV2HistorySnapshot) async throws -> OpenCodeV2HistorySnapshot {
        try Task.checkCancellation(); try OpenCodeV2HistoryValidation.sessionID(sourceID)
        guard !closing, !uncertain, historyToken == nil, preparing == nil, activeRunID == nil, interrupting == nil,
              inFlightSends.isEmpty, steeringTasks.isEmpty, backgroundActive.isEmpty, pending.isEmpty,
              sessionID == nil || sessionID == sourceID else { throw ProviderHistoryError(.notIdle) }
        let token = UUID()
        historyToken = token; historyWatch = .init(sourceID: sourceID); historyMayHaveWritten = false
        let task = Task {
            try await withThrowingTaskGroup(of: OpenCodeV2HistorySnapshot.self) { group in
                group.addTask { try await operation(token) }
                group.addTask { try await Task.sleep(for: timeout); throw ProviderHistoryError(.limitExceeded) }
                defer { group.cancelAll() }
                guard let result = try await group.next() else { throw ProviderHistoryError(.invalidResponse) }
                return result
            }
        }
        historyTask = task
        defer {
            if historyToken == token { historyToken = nil; historyWatch = nil; historyTask = nil; historyMayHaveWritten = false }
        }
        do { return try await withTaskCancellationHandler { try await task.value } onCancel: { task.cancel() } }
        catch {
            // The deadline/caller may win the task group before the mutation's
            // own catch runs. Its durable dispatch fence must remain uncertain.
            if historyMayHaveWritten { throw ProviderHistoryError(.outcomeUncertain) }
            throw error
        }
    }

    private func checkHistory(_ token: UUID) throws {
        try Task.checkCancellation()
        guard historyToken == token, !closing, !uncertain else { throw CancellationError() }
        guard historyWatch?.interference == false else { throw ProviderHistoryError(.historyChanged) }
    }

    private func historyCall(_ token: UUID, method: String = "GET", path: [String], query: [URLQueryItem] = [],
                             body: JSONValue? = nil) async throws -> OpenCodeHTTPResponse {
        try checkHistory(token)
        let response = try await call(method: method, path: path, query: query, body: body)
        try checkHistory(token)
        return response
    }

    private func historyQuiet(_ sourceID: String, token: UUID) async throws {
        let active = try OpenCodeV2Protocol.activeSessions(try await historyCall(token, path: ["api", "session", "active"]))
        guard !active.contains(sourceID), backgroundActive.isEmpty, pending.isEmpty, activeRunID == nil else { throw ProviderHistoryError(.notIdle) }
        let linked = try await historyLinkedSessions(sourceID, token: token)
        guard active.isDisjoint(with: linked) else { throw ProviderHistoryError(.notIdle) }
        for id in linked.sorted() {
            for tail in ["inbox", "permission", "form"] {
                let response = try await historyCall(token, path: ["api", "session", id, tail])
                let value = try OpenCodeV2HistoryWire.json(response)
                guard let pending = value["data"].array, pending.count <= 4_096 else { throw ProviderHistoryError(.invalidResponse) }
                guard pending.isEmpty else { throw ProviderHistoryError(.notIdle) }
            }
        }
    }

    private func historyLinkedSessions(_ root: String, token: UUID) async throws -> Set<String> {
        // A fresh metadata actor has no live background map. Query only this
        // exact parent graph; foreign sessions are never enumerated or stopped.
        var result: Set<String> = [root], parents = [root], bytes = 0
        while !parents.isEmpty {
            let parent = parents.removeFirst()
            var cursor: String?, seen = Set<String>()
            for pageIndex in 0..<100 {
                var query = [URLQueryItem(name: "parentID", value: parent), .init(name: "limit", value: "100")]
                if let cursor { query.append(.init(name: "cursor", value: cursor)) }
                else { query.append(.init(name: "order", value: "asc")) }
                let response = try await historyCall(token, path: ["api", "session"], query: query)
                bytes += response.body.count
                guard bytes <= OpenCodeV2HistoryWire.maximumPageBytes else { throw ProviderHistoryError(.limitExceeded) }
                let value = try OpenCodeV2HistoryWire.json(response)
                guard let rows = value["data"].array, rows.count <= 100, value["cursor"].object != nil else { throw ProviderHistoryError(.invalidResponse) }
                for row in rows {
                    let id = try OpenCodeV2HistoryWire.messageOwner(row["id"], session: true)
                    guard row["parentID"] == .string(parent), result.insert(id).inserted else { throw ProviderHistoryError(.invalidResponse) }
                    guard result.count <= 256 else { throw ProviderHistoryError(.limitExceeded) }
                    parents.append(id)
                }
                if rows.isEmpty || value["cursor"]["next"] == .null { break }
                guard let next = value["cursor"]["next"].string, seen.insert(next).inserted else { throw ProviderHistoryError(.invalidResponse) }
                try ProviderHistoryValidation.cursor(next)
                guard pageIndex < 99 else { throw ProviderHistoryError(.limitExceeded) }
                cursor = next
            }
        }
        return result
    }

    private func historyRecords(_ sourceID: String, token: UUID) async throws -> [OpenCodeV2HistoryMessage] {
        var values: [JSONValue] = [], cursor: String?, cursors = Set<String>(), seen = Set<String>(), bytes = 0
        for _ in 0..<OpenCodeV2HistoryWire.maximumPages {
            var query = [URLQueryItem(name: "limit", value: "200")]
            if let cursor { query.append(.init(name: "cursor", value: cursor)) }
            else { query.append(.init(name: "order", value: "asc")) }
            let response = try await historyCall(token, path: ["api", "session", sourceID, "message"], query: query)
            bytes += response.body.count
            guard bytes <= OpenCodeV2HistoryWire.maximumBytes else { throw ProviderHistoryError(.limitExceeded) }
            let page = try OpenCodeV2HistoryWire.page(response)
            for value in page.values {
                guard seen.insert(try OpenCodeV2HistoryWire.messageOwner(value["id"])).inserted else { throw ProviderHistoryError(.invalidResponse) }
            }
            values += page.values
            guard values.count <= OpenCodeV2HistoryWire.maximumMessages else { throw ProviderHistoryError(.limitExceeded) }
            if page.values.isEmpty || page.next == nil { return try OpenCodeV2HistoryWire.records(values) }
            guard let next = page.next, cursors.insert(next).inserted else { throw ProviderHistoryError(.invalidResponse) }
            cursor = next
        }
        throw ProviderHistoryError(.limitExceeded)
    }

    private func readHistorySnapshot(_ sourceID: String, token: UUID) async throws -> OpenCodeV2HistorySnapshot {
        try await connect(); try checkHistory(token)
        let first = try OpenCodeV2HistoryWire.session(try await historyCall(token, path: ["api", "session", sourceID]), id: sourceID, directory: cwd.path)
        try await historyQuiet(sourceID, token: token)
        let before = try await historyRecords(sourceID, token: token)
        let after = try await historyRecords(sourceID, token: token)
        try await historyQuiet(sourceID, token: token)
        let last = try OpenCodeV2HistoryWire.session(try await historyCall(token, path: ["api", "session", sourceID]), id: sourceID, directory: cwd.path)
        guard first == last, before == after else { throw ProviderHistoryError(.historyChanged) }
        return try .init(reference: .init(provider: .opencode, nativeThreadID: sourceID), runtimeIdentity: configuration.runtimeIdentity,
                         workspacePath: historyWorkspacePath, messages: after, stage: last.stage, fork: last.fork)
    }

    private func forkHistory(_ review: OpenCodeV2HistoryReviewEvidence, token: UUID) async throws -> OpenCodeV2HistorySnapshot {
        let sourceID = review.source.reference.nativeThreadID
        let body: JSONValue
        switch review.boundary {
        case .head: body = .object([:])
        case .beforeMessage(let id): body = .object(["before": .string(id)])
        default: throw ProviderHistoryError(.invalidRequest)
        }
        // No blind mutation retries: a lost reply may have created an orphan.
        historyMayHaveWritten = true
        var admitted = false
        do {
            let response = try await historyCall(token, method: "POST", path: ["api", "session", sourceID, "fork"], body: body)
            admitted = true
            let value = try OpenCodeV2HistoryWire.json(response)
            let forkID = try OpenCodeV2HistoryWire.messageOwner(value["data"]["id"], session: true)
            guard forkID != sourceID else { throw ProviderHistoryError(.invalidResponse) }
            _ = try OpenCodeV2HistoryWire.session(response, id: forkID, directory: cwd.path)
            let observed = try await readHistorySnapshot(forkID, token: token)
            try review.validateResult(observed, kind: .forkAfterRun)
            // Copying does not authorize changing the source while publishing.
            let source = try await readHistorySnapshot(sourceID, token: token)
            guard source == review.source else { throw ProviderHistoryError(.historyChanged) }
            return observed
        } catch {
            if !admitted, Self.definitelyRejected(error) {
                historyMayHaveWritten = false
                throw ProviderHistoryError(.invalidRequest)
            }
            throw ProviderHistoryError(.outcomeUncertain)
        }
    }

    private func revertHistory(_ review: OpenCodeV2HistoryReviewEvidence, token: UUID) async throws -> OpenCodeV2HistorySnapshot {
        guard case .beforeMessage(let cut) = review.boundary else { throw ProviderHistoryError(.invalidRequest) }
        let sourceID = review.source.reference.nativeThreadID
        historyUnsafe = true; historyMayHaveWritten = true
        do {
            let response = try await historyCall(token, method: "POST", path: ["api", "session", sourceID, "revert", "stage"],
                body: .object(["messageID": .string(cut), "files": .bool(false)]))
            let stage = try OpenCodeV2HistoryWire.stageResponse(response)
            guard stage.messageID == cut, stage.isHistoryOnly else { throw ProviderHistoryError(.invalidResponse) }
            let staged = try await readHistorySnapshot(sourceID, token: token)
            guard staged.messages == review.source.messages, staged.stage == stage else { throw ProviderHistoryError(.historyChanged) }
            try Self.noContent(try await historyCall(token, method: "POST", path: ["api", "session", sourceID, "revert", "commit"]))
            let observed = try await readHistorySnapshot(sourceID, token: token)
            try review.validateResult(observed, kind: .rewindBeforeRun)
            historyUnsafe = false
            return observed
        } catch {
            // No hidden clear here: its empty execution appends a native idle
            // message whose durable receipt must reach the workspace. Explicit
            // clear/reconciliation owns that separate action after uncertainty.
            throw ProviderHistoryError(.outcomeUncertain)
        }
    }

    private func clearHistory(_ expected: OpenCodeV2HistorySnapshot, token: UUID) async throws -> OpenCodeV2HistorySnapshot {
        let sourceID = expected.reference.nativeThreadID
        historyUnsafe = true; historyMayHaveWritten = true; historyWatch?.clearing = true
        do {
            try Self.noContent(try await historyCall(token, method: "DELETE", path: ["api", "session", sourceID, "revert"]))
        } catch {
            // An exact observed maintenance terminal plus read-back can be
            // stronger than a lost HTTP ACK. Never resend DELETE.
            if error is CancellationError { throw ProviderHistoryError(.outcomeUncertain) }
        }
        do {
            while historyWatch?.terminalEventID == nil {
                try checkHistory(token)
                try await Task.sleep(for: .milliseconds(10))
            }
            guard let start = historyWatch?.startEventID, let terminal = historyWatch?.terminalEventID else { throw ProviderHistoryError(.outcomeUncertain) }
            let observed = try await readHistorySnapshot(sourceID, token: token)
            let receipt = try OpenCodeV2HistoryMaintenanceReceipt(priorInventoryDigest: expected.inventoryDigest,
                startEventID: start, terminalEventID: terminal, idleMessageID: "msg_" + terminal.dropFirst(4))
            guard observed.stage == nil, observed.messages.count == expected.messages.count + 1,
                  Array(observed.messages.dropLast()) == expected.messages,
                  observed.messages.last?.id == receipt.idleMessageID, observed.messages.last?.kind == .idle,
                  observed.messages.last?.isSettled == true else { throw ProviderHistoryError(.historyChanged) }
            let result = try OpenCodeV2HistorySnapshot(reference: observed.reference, runtimeIdentity: observed.runtimeIdentity,
                workspacePath: observed.workspacePath, messages: observed.messages, stage: nil, fork: observed.fork, maintenance: receipt)
            historyUnsafe = false; return result
        } catch { throw ProviderHistoryError(.outcomeUncertain) }
    }

    /// Maintenance execution has no user input or provider turn. Own its exact
    /// source/event boundaries and suppress it before ordinary run projection.
    private func observeHistoryEvent(_ envelope: JSONValue, sessionID observedID: String?) -> Bool {
        guard var watch = historyWatch, observedID == watch.sourceID, let type = envelope["type"].string else { return false }
        if type == "session.execution.started" || ["session.execution.succeeded", "session.execution.interrupted", "session.execution.failed"].contains(type) {
            guard watch.clearing, let eventID = envelope["id"].string, eventID.hasPrefix("evt_"),
                  (try? ProviderHistoryValidation.id(eventID)) != nil else {
                watch.interference = true; historyWatch = watch; return true
            }
            if type == "session.execution.started" {
                if watch.startEventID == nil { watch.startEventID = eventID }
                else if watch.startEventID != eventID { watch.interference = true }
            } else {
                if watch.startEventID == nil || watch.terminalEventID.map({ $0 != eventID }) == true { watch.interference = true }
                else { watch.terminalEventID = eventID }
            }
        } else if ["session.inbox.", "session.step.", "session.text.", "session.reasoning.", "session.tool.",
                    "session.compaction.", "session.form.", "session.permission."].contains(where: type.hasPrefix) {
            watch.interference = true
        }
        historyWatch = watch
        return true
    }

    private func connect() async throws {
        guard !appMCPConfiguring else { throw OpenCodeAppMCP.failure() }
        try Task.checkCancellation()
        guard !closing else { throw OpenCodeV2SessionError.closed }
        guard !uncertain else { throw OpenCodeV2SessionError.connectionLost }
        if connected { return }
        if let connecting { try await connecting.value; try Task.checkCancellation(); return }
        try configuration.validate()
        guard configuration.generation == .v2 else { throw OpenCodeV2SessionError.invalidConfiguration }
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
                do {
                    for try await frame in stream {
                        guard !Task.isCancelled else { return }
                        await self?.consume(frame)
                    }
                } catch { /* The transport may carry private server text. */ }
                await self?.streamEnded()
            }
            connected = true
        } catch {
            await transport.close()
            throw error is CancellationError ? CancellationError() : OpenCodeV2SessionError.connectionLost
        }
    }

    public func send(text: String, thread: CodingThread) async throws {
        try await send(input: .init(text: text), thread: thread)
    }

    public func contextInputDisposition(input: ProviderInput, thread: CodingThread) async throws -> ProviderContextInputDisposition {
        guard try ProviderCommandCatalog.requiresInventory(input.text) else { return .ordinary }
        let catalog: ProviderCommandInventory?
        do { catalog = try await providerCommands() }
        catch let error as ProviderCommandError where error.kind == .unsupported { catalog = nil }
        return try catalog.flatMap { try ProviderCommandCatalog.selection(in: input.text, inventory: $0) } == nil ? .ordinary : .nativeCommand
    }
    public func send(input: ProviderInput, thread: CodingThread) async throws {
        guard !closing, !uncertain else { throw OpenCodeV2SessionError.closed }
        guard preparing == nil, activeRunID == nil, interrupting == nil, historyToken == nil, !historyUnsafe else { throw OpenCodeV2SessionError.busy }
        let captured = thread.activeRun?.configuration ?? ProviderConfiguration(thread: thread)
        guard let selected = captured.openCodeConfiguration,
              selected.runtimeIdentity == configuration.runtimeIdentity,
              URL(fileURLWithPath: captured.workspacePath).standardizedFileURL.resolvingSymlinksInPath() == cwd else {
            throw OpenCodeV2SessionError.invalidConfiguration
        }
        try selected.validate()
        let token = UUID(), runID = thread.activeRun?.id ?? UUID()
        guard !inFlightSends.contains(runID) else { throw OpenCodeV2SessionError.busy }
        let inputID = Self.inputID(instance: selected.instanceID, run: runID)
        var promptBody = try Self.prompt(input, inputID: inputID)
        inFlightSends.insert(runID)
        preparing = token
        defer {
            inFlightSends.remove(runID)
            if preparing == token { preparing = nil }
            stoppedPreparations.remove(token)
        }
        var posted = false
        do {
            try await connect(); try requirePreparation(token)
            if appMCPConnection != nil {
                try await transport.prepareAppMCP(); try requirePreparation(token)
            }
            let catalog: ProviderCommandInventory?
            if try ProviderCommandCatalog.requiresInventory(input.text) {
                do { catalog = try await providerCommands() }
                catch let error as ProviderCommandError where error.kind == .unsupported { catalog = nil }
                try requirePreparation(token)
            } else { catalog = nil }
            let command = try catalog.flatMap { try ProviderCommandCatalog.selection(in: input.text, inventory: $0) }
            guard command == nil || input.historicalContext == nil else { throw OpenCodeV2SessionError.unsupportedInput }
            let skills = try catalog.map { try ProviderCommandCatalog.skillIDs(in: input.text, inventory: $0) } ?? []
            let compact = command?.name == "compact"
            guard !compact || (command?.arguments.isEmpty == true && input.images.isEmpty) else { throw OpenCodeV2SessionError.unsupportedInput }
            if !skills.isEmpty, var object = promptBody.object {
                object["skills"] = .array(skills.map { .object(["id": .string($0)]) }); promptBody = .object(object)
            }
            let inventory = try await openCodeInventory(); try requirePreparation(token)
            let model = try Self.resolveModel(selected.model, inventory: inventory)
            guard inventory.agents.contains(where: { $0.id == selected.agentID && $0.mode != .subagent && !$0.hidden }) else {
                throw OpenCodeV2SessionError.invalidConfiguration
            }
            let agentPaths = try await transport.agentPathRules(directory: cwd, agentID: selected.agentID)
            try requirePreparation(token)
            let grants = sessionID.flatMap { sessionGrants[$0] } ?? []
            let rules = Self.permissions(captured.permission, agentID: selected.agentID, agentPaths: agentPaths, grants: grants, appMCP: appMCPConnection != nil)
            let nativeID = try await ensureSession(thread: thread, captured: captured, selected: selected,
                                                   model: model, rules: rules, token: token)
            try requirePreparation(token)
            try await cancelStrandedSteers(sessionID: nativeID, token: token)
            let active = try OpenCodeV2Protocol.activeSessions(try await call(method: "GET", path: ["api", "session", "active"]))
            try requirePreparation(token)
            guard !active.contains(nativeID) else { throw OpenCodeV2SessionError.busy }
            let inbox = try OpenCodeV2Protocol.inbox(try await call(method: "GET", path: ["api", "session", nativeID, "inbox"]), sessionID: nativeID)
            try requirePreparation(token)
            guard inbox.isEmpty else { throw OpenCodeV2SessionError.busy }
            // Apply only this accepted input's captured controls. Future header
            // changes never alter an in-flight native turn.
            try await configure(sessionID: nativeID, selected: selected, model: model, rules: rules, token: token)
            policies[nativeID] = .init(permission: captured.permission, agentID: selected.agentID, agentPaths: agentPaths)
            let finalActive = try OpenCodeV2Protocol.activeSessions(try await call(method: "GET", path: ["api", "session", "active"]))
            try requirePreparation(token)
            guard !finalActive.contains(nativeID) else { throw OpenCodeV2SessionError.busy }
            let current = try OpenCodeV2Protocol.session(try await call(method: "GET", path: ["api", "session", nativeID]), expectedID: nativeID, directory: cwd.path)
            try requirePreparation(token)
            guard current.agentID == selected.agentID, current.model == model,
                  current.permissions?.map(\.json) == rules.array, !current.hasRevert else { throw OpenCodeV2SessionError.invalidConfiguration }
            let commandPriorIDs = command != nil && !compact ? try await commandMessageIDs(sessionID: nativeID, token: token) : []
            try requirePreparation(token)
            guard runs.count < 256 || activeRunID == nil else { throw OpenCodeV2SessionError.invalidResponse }
            trimRuns()
            runs[runID] = .init(id: runID, sessionID: nativeID, inputID: command != nil && !compact ? "" : inputID, autonomous: false)
            runs[runID]?.configuration = captured
            runs[runID]?.nativeCommand = command != nil && !compact
            runs[runID]?.compaction = compact
            runs[runID]?.commandPriorIDs = commandPriorIDs
            activeRunID = runID; owners[nativeID] = runID
            let projectionOwner = OpenCodeProjectionOwner(sessionID: nativeID, runID: runID)
            if projectors[projectionOwner] == nil { projectors[projectionOwner] = .init(instanceID: selected.instanceID, sessionID: nativeID) }
            preparing = nil
            posted = true
            let endpoint: String
            if compact {
                endpoint = "compact"
                promptBody = .object(["id": .string(inputID), "delivery": .string("queue")])
            } else if let command {
                endpoint = "command"
                var object = promptBody.object ?? [:]
                object.removeValue(forKey: "id"); object.removeValue(forKey: "resume")
                object["name"] = .string(command.name); object["text"] = .string(command.arguments)
                promptBody = .object(object)
            } else { endpoint = "prompt" }
            let response = try await call(method: "POST", path: ["api", "session", nativeID, endpoint], body: promptBody)
            guard !closing else { throw CancellationError() }
            if command != nil && !compact {
                try Self.noContent(response)
                // Command callbacks have no caller input ID. Only an actual
                // newly enqueued root user input can bind this local run. A
                // callback with no root input (or only a detached child) cannot
                // be reported as a completed user turn from HTTP 204 alone.
                try await awaitCommandInput(runID)
                try await verifyCommandInput(runID)
            } else {
                _ = try OpenCodeV2Protocol.admission(response, sessionID: nativeID, inputID: inputID,
                    type: compact ? "compaction" : "user")
            }
            if var run = runs[runID] {
                run.admitted = true; runs[runID] = run
                announceInput(runID)
                try flushBuffered(runID)
                finishIfReady(runID)
            }
        } catch {
            if posted {
                // Durable native delivery is stronger evidence than a delayed
                // HTTP acknowledgement. In particular, a completed predecessor's
                // lost reply cannot invalidate its already-running successor.
                if connected, !closing, !uncertain, let observed = runs[runID],
                   observed.delivered, observed.inputObserved, !observed.nativeCommand || observed.finished {
                    return
                }
                if Self.definitelyRejected(error), runs[runID]?.inputObserved != true {
                    if activeRunID == runID { activeRunID = nil }
                    runs.removeValue(forKey: runID)
                    throw OpenCodeV2SessionError.rejected
                }
                failConnection(.uncertainDelivery)
                throw OpenCodeV2SessionError.uncertainDelivery
            }
            if error is CancellationError || stoppedPreparations.contains(token) { throw CancellationError() }
            if let safe = error as? OpenCodeAppMCPError { throw safe }
            if let safe = error as? OpenCodeV2SessionError { throw safe }
            throw OpenCodeV2SessionError.invalidResponse
        }
    }

    public func steeringCapabilities() async -> ProviderSteeringCapabilities {
        pruneSteers()
        guard !closing, !uncertain, connected, preparing == nil, interrupting == nil, historyToken == nil, !historyUnsafe,
              let id = activeRunID, let run = runs[id], !run.autonomous, !run.compaction, !run.nativeCommand, !run.stopped, !run.finished,
              run.configuration != nil, run.started, run.delivered, run.announced,
              !pending.values.contains(where: { $0.owner == id }), run.steerIDs.count < 128, steers.count < 1_024 else {
            return .init(unavailableReason: ProviderSteeringError(.noActiveTurn).localizedDescription)
        }
        return .init(supportsActiveSteering: true)
    }

    public func steer(input: ProviderInput, thread: CodingThread, expectedTurnID: String,
                      clientMessageID: String) async throws -> ProviderSteeringReceipt {
        try input.requireNoHistoricalContextForSteering()
        try Task.checkCancellation()
        try ProviderSteeringValidation.id(clientMessageID)
        try ProviderSteeringValidation.input(input)
        guard !closing, !uncertain, connected, preparing == nil, interrupting == nil, historyToken == nil, !historyUnsafe,
              let id = activeRunID, let run = runs[id], !run.autonomous, !run.compaction, !run.nativeCommand, !run.finished, !run.stopped,
              run.started, run.delivered, run.announced, let captured = run.configuration,
              !pending.values.contains(where: { $0.owner == id }) else { throw ProviderSteeringError(.noActiveTurn) }
        try ProviderSteeringValidation.target(thread, provider: .opencode, configuration: captured, runID: id,
            nativeThreadID: run.sessionID, turnID: run.inputID, expectedTurnID: expectedTurnID)
        guard captured.openCodeConfiguration?.runtimeIdentity == configuration.runtimeIdentity,
              URL(fileURLWithPath: captured.workspacePath).standardizedFileURL.resolvingSymlinksInPath() == cwd else {
            throw ProviderSteeringError(.staleTarget)
        }
        let inboxID = try OpenCodeV2HistoryRunInput.steeringMessageID(instanceID: configuration.instanceID,
            sessionID: run.sessionID, runID: id, clientMessageID: clientMessageID)
        var body: JSONValue
        do {
            body = try Self.prompt(input, inputID: inboxID, delivery: "steer")
            if try ProviderCommandCatalog.requiresInventory(input.text) {
                let catalog = try await providerCommands()
                // Native commands cannot target this already-running turn.
                guard try ProviderCommandCatalog.selection(in: input.text, inventory: catalog) == nil else { throw ProviderSteeringError(.unsupported) }
                let skills = try ProviderCommandCatalog.skillIDs(in: input.text, inventory: catalog)
                if !skills.isEmpty, var object = body.object {
                    object["skills"] = .array(skills.map { .object(["id": .string($0)]) }); body = .object(object)
                }
                guard activeRunID == id, runs[id]?.finished == false, runs[id]?.stopped == false,
                      runs[id]?.inputID == expectedTurnID else { throw ProviderSteeringError(.staleTarget) }
            }
        } catch let safe as ProviderSteeringError { throw safe }
        catch { throw ProviderSteeringError(.invalidRequest) }
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        let fingerprint = Self.digest(String(decoding: try encoder.encode(body), as: UTF8.self))
        if let previous = steers[inboxID] {
            guard previous.runID == id, previous.fingerprint == fingerprint else { throw ProviderSteeringError(.invalidRequest) }
            if let task = steeringTasks[inboxID] { return try await waitForSteer(task) }
            if previous.rejected { throw ProviderSteeringError(.rejected) }
            guard previous.admitted || previous.observed else { throw ProviderSteeringError(.outcomeUncertain) }
            return try .init(turnID: run.inputID)
        }
        pruneSteers()
        guard run.steerIDs.count < 128, steers.count < 1_024 else { throw ProviderSteeringError(.rejected) }
        // Install exact ownership before the native write or its first event.
        steers[inboxID] = .init(runID: id, sessionID: run.sessionID, fingerprint: fingerprint)
        runs[id]?.steerIDs.insert(inboxID); runs[id]?.pendingSteers.insert(inboxID)
        let task = Task { try await self.submitSteer(inboxID: inboxID, originalTurnID: run.inputID, body: body) }
        steeringTasks[inboxID] = task
        defer { steeringTasks.removeValue(forKey: inboxID) }
        return try await waitForSteer(task)
    }

    private func waitForSteer(_ task: Task<ProviderSteeringReceipt, any Error>) async throws -> ProviderSteeringReceipt {
        try await withTaskCancellationHandler { try await task.value } onCancel: { task.cancel() }
    }

    private func submitSteer(inboxID: String, originalTurnID: String, body: JSONValue) async throws -> ProviderSteeringReceipt {
        guard let steer = steers[inboxID] else { throw ProviderSteeringError(.staleTarget) }
        var posted = false
        do {
            try Task.checkCancellation()
            guard !closing, !uncertain, activeRunID == steer.runID, runs[steer.runID]?.stopped == false,
                  runs[steer.runID]?.finished == false else { throw ProviderSteeringError(.staleTarget) }
            posted = true
            let response = try await call(method: "POST", path: ["api", "session", steer.sessionID, "prompt"], body: body)
            _ = try OpenCodeV2Protocol.admission(response, sessionID: steer.sessionID, inputID: inboxID)
            guard !closing, !uncertain else { throw ProviderSteeringError(.outcomeUncertain) }
            steers[inboxID]?.admitted = true
            return try .init(turnID: originalTurnID)
        } catch {
            // Exact native delivery wins over a late/lost acknowledgement,
            // including after this original run has already finished.
            if !closing, !uncertain, let observed = steers[inboxID], observed.observed {
                return try .init(turnID: originalTurnID)
            }
            if !posted || Self.definitelyRejected(error) {
                steers[inboxID]?.rejected = true
                runs[steer.runID]?.pendingSteers.remove(inboxID)
                strandedSteers.remove(inboxID)
                finishIfReady(steer.runID)
                if !posted { throw ProviderSteeringError(.staleTarget) }
                throw ProviderSteeringError(.rejected)
            }
            failConnection(.uncertainDelivery)
            throw ProviderSteeringError(.outcomeUncertain)
        }
    }

    private func cancelStrandedSteers(sessionID: String, token: UUID) async throws {
        for id in strandedSteers.sorted() where steers[id]?.sessionID == sessionID {
            // A DELETE cannot race an old POST which has not proved admission.
            guard steers[id]?.admitted == true || steers[id]?.observed == true else { throw OpenCodeV2SessionError.busy }
            try Self.noContent(try await call(method: "DELETE", path: ["api", "session", sessionID, "inbox", id]))
            try requirePreparation(token)
            strandedSteers.remove(id)
        }
    }

    private func pruneSteers() {
        steers = steers.filter { runs[$0.value.runID]?.finished != true || steeringTasks[$0.key] != nil || strandedSteers.contains($0.key) }
    }

    private func ensureSession(thread: CodingThread, captured: ProviderConfiguration, selected: OpenCodeConfiguration,
                               model: OpenCodeModelSelection, rules: JSONValue, token: UUID) async throws -> String {
        if let existing = sessionID {
            guard captured.nativeThreadID == nil || captured.nativeThreadID == existing else { throw OpenCodeV2SessionError.wrongSession }
            let response = try await call(method: "GET", path: ["api", "session", existing])
            let info = try OpenCodeV2Protocol.session(response, expectedID: existing, directory: cwd.path)
            guard info.parentID == nil, !info.hasRevert else { throw OpenCodeV2SessionError.wrongSession }
            try requirePreparation(token)
            return existing
        }
        let intended = captured.nativeThreadID ?? Self.sessionID(instance: selected.instanceID, thread: thread.id)
        try Self.identifier(intended)
        let existing = try await call(method: "GET", path: ["api", "session", intended], allowNotFound: true)
        try requirePreparation(token)
        let response: OpenCodeHTTPResponse
        if existing.status == 404, captured.nativeThreadID == nil {
            let body: JSONValue = .object([
                "id": .string(intended), "title": .string(thread.title.isEmpty ? "Coincide conversation" : String(thread.title.prefix(512))),
                "agent": .string(selected.agentID), "model": Self.modelBody(model),
                "location": .object(["directory": .string(cwd.path)]), "permissions": rules,
                "metadata": .object(["coincide": .object(["threadID": .string(thread.id.uuidString), "instanceID": .string(selected.instanceID.uuidString)])])
            ])
            do { response = try await call(method: "POST", path: ["api", "session"], body: body) }
            catch {
                failConnection(.uncertainDelivery)
                throw OpenCodeV2SessionError.uncertainDelivery
            }
        } else {
            if captured.nativeThreadID == nil {
                let value = try Self.json(existing)
                guard value["data"]["metadata"]["coincide"]["threadID"] == .string(thread.id.uuidString),
                      value["data"]["metadata"]["coincide"]["instanceID"] == .string(selected.instanceID.uuidString) else {
                    throw OpenCodeV2SessionError.wrongSession
                }
            }
            response = existing
        }
        let info = try OpenCodeV2Protocol.session(response, expectedID: intended, directory: cwd.path)
        try requirePreparation(token)
        guard info.parentID == nil, !info.hasRevert else { throw OpenCodeV2SessionError.wrongSession }
        sessionID = intended
        continuation.yield(.thread(intended))
        return intended
    }

    private func configure(sessionID: String, selected: OpenCodeConfiguration, model: OpenCodeModelSelection,
                           rules: JSONValue, token: UUID) async throws {
        try Self.noContent(try await call(method: "POST", path: ["api", "session", sessionID, "agent"], body: .object(["agent": .string(selected.agentID)])))
        try requirePreparation(token)
        try Self.noContent(try await call(method: "PATCH", path: ["api", "session", sessionID], body: .object(["permissions": rules])))
        try requirePreparation(token)
        try Self.noContent(try await call(method: "POST", path: ["api", "session", sessionID, "model"], body: .object(["model": Self.modelBody(model)])))
        try requirePreparation(token)
    }

    private func awaitCommandInput(_ id: UUID) async throws {
        if runs[id]?.inputObserved == true { return }
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
                guard !Task.isCancelled, !closing, !uncertain else { continuation.resume(throwing: CancellationError()); return }
                if runs[id]?.inputObserved == true { continuation.resume(); return }
                guard commandInputWaiters[id] == nil else { continuation.resume(throwing: OpenCodeV2SessionError.busy); return }
                let deadline = Task { [weak self] in
                    do { try await Task.sleep(for: .seconds(10)) } catch { return }
                    await self?.finishCommandInput(id, error: OpenCodeV2SessionError.uncertainDelivery)
                }
                commandInputWaiters[id] = .init(continuation: continuation, deadline: deadline)
            }
        } onCancel: { Task { await self.finishCommandInput(id, error: CancellationError()) } }
    }

    private func finishCommandInput(_ id: UUID, error: (any Error)?) {
        guard let waiter = commandInputWaiters.removeValue(forKey: id) else { return }
        waiter.deadline.cancel()
        if let error { waiter.continuation.resume(throwing: error) } else { waiter.continuation.resume() }
    }

    private func finishCommandInputs(error: any Error) {
        for id in Array(commandInputWaiters.keys) { finishCommandInput(id, error: error) }
    }

    private func verifyCommandInput(_ id: UUID) async throws {
        guard let run = runs[id], run.nativeCommand, run.inputObserved, !run.inputID.isEmpty else { throw OpenCodeV2SessionError.uncertainDelivery }
        let records = try await commandMessages(sessionID: run.sessionID, token: nil)
        let inbox = try OpenCodeV2Protocol.inbox(try await call(method: "GET", path: ["api", "session", run.sessionID, "inbox"]), sessionID: run.sessionID)
        guard !closing, !uncertain, let current = runs[id], current.inputID == run.inputID,
              !current.finished, inbox.allSatisfy({ $0.type == "user" && $0.id == run.inputID }) else { throw OpenCodeV2SessionError.uncertainDelivery }
        let newUsers = Set(records.filter { $0.kind == .user && !run.commandPriorIDs.contains($0.id) }.map(\.id))
            .union(inbox.map(\.id))
        guard newUsers == [run.inputID] else { throw OpenCodeV2SessionError.uncertainDelivery }
    }

    private func commandMessageIDs(sessionID: String, token: UUID) async throws -> Set<String> {
        Set(try await commandMessages(sessionID: sessionID, token: token).map(\.id))
    }

    private func commandMessages(sessionID: String, token: UUID?) async throws -> [OpenCodeV2HistoryMessage] {
        var values: [JSONValue] = [], ids = Set<String>(), cursor: String?, cursors = Set<String>(), bytes = 0
        for pageIndex in 0..<100 {
            var query = [URLQueryItem(name: "limit", value: "200")]
            if let cursor { query.append(.init(name: "cursor", value: cursor)) }
            else { query.append(.init(name: "order", value: "asc")) }
            let response = try await call(method: "GET", path: ["api", "session", sessionID, "message"], query: query)
            if let token { try requirePreparation(token) }
            else { try Task.checkCancellation(); guard !closing, !uncertain else { throw CancellationError() } }
            bytes += response.body.count
            guard bytes <= 16_777_216 else { throw OpenCodeV2SessionError.unsupportedInput }
            let page = try OpenCodeV2HistoryWire.page(response)
            for value in page.values {
                let id = try OpenCodeV2Bounds.messageID(value["id"])
                guard ids.insert(id).inserted, ids.count <= 10_000 else { throw OpenCodeV2SessionError.invalidResponse }
                values.append(value)
            }
            guard let next = page.next else { return try OpenCodeV2HistoryWire.records(values) }
            guard pageIndex < 99, cursors.insert(next).inserted else { throw OpenCodeV2SessionError.invalidResponse }
            cursor = next
        }
        throw OpenCodeV2SessionError.invalidResponse
    }

    private func requirePreparation(_ token: UUID) throws {
        try Task.checkCancellation()
        guard !closing, !uncertain, preparing == token, !stoppedPreparations.contains(token) else { throw CancellationError() }
    }

    private func call(method: String, path: [String], query: [URLQueryItem] = [], body: JSONValue? = nil, allowNotFound: Bool = false) async throws -> OpenCodeHTTPResponse {
        try Task.checkCancellation()
        guard !closing else { throw CancellationError() }
        let id = UUID(), transport = transport
        let task = Task { try await transport.request(method: method, path: path, query: query, body: body) }
        requests[id] = task
        defer { requests.removeValue(forKey: id) }
        return try await withTaskCancellationHandler {
            let response = try await task.value
            try Task.checkCancellation()
            if [400, 401, 403, 404, 409, 422].contains(response.status), !(allowNotFound && response.status == 404) {
                throw OpenCodeV2RejectedResponse(status: response.status)
            }
            return response
        } onCancel: { task.cancel() }
    }

    private func consume(_ inbound: OpenCodeSSEEvent) {
        guard !closing, !uncertain else { return }
        do {
            let frame = try appMCPConnection.map { try $0.redactingOpenCodeEvent(inbound) } ?? inbound
            // V2 broadcasts all native sessions. Unknown global owners must not
            // poison this actor's state or fill its retained ownership maps.
            guard let envelope = try? JSONDecoder().decode(JSONValue.self, from: Data(frame.data.utf8)) else {
                throw OpenCodeV2SessionError.invalidResponse
            }
            let data = envelope["data"]
            if let kind = envelope["type"].string, ["command.updated", "skill.updated"].contains(kind) {
                if envelope["location"]["directory"] == .string(cwd.path) {
                    commandScanSignals.insert(kind)
                    if commandScanSignals.count == 2 { finishCommandScans(ready: true) }
                }
                return
            }
            if let kind = envelope["type"].string,
               ["session.execution.started", "session.execution.succeeded", "session.execution.interrupted", "session.execution.failed"].contains(kind) {
                _ = try OpenCodeV2Bounds.sessionID(data["sessionID"])
            }
            let observedID = data["sessionID"].string ?? data["form"]["sessionID"].string
            let parentID = data["parentID"].string
            if observeHistoryEvent(envelope, sessionID: observedID) { return }
            if let child = observedID, child != sessionID, owners[child] == nil,
               let parent = childParents[child], owners[parent] != nil {
                let bytes = frame.data.utf8.count
                guard earlyChildFrames.values.reduce(0, { $0 + $1.count }) < 256,
                      earlyChildBytes + bytes <= 2 * 1_024 * 1_024 else { throw OpenCodeV2SessionError.invalidResponse }
                earlyChildFrames[child, default: []].append(frame); earlyChildBytes += bytes
                return
            }
            guard observedID.map({ $0 == sessionID || owners[$0] != nil }) == true || parentID.map({ owners[$0] != nil }) == true else { return }
            guard let event = try OpenCodeV2Protocol.decode(frame) else { return }
            if let id = event.id {
                if seenEventIDs.contains(id) { return }
                seenEventIDs.append(id); if seenEventIDs.count > 1_024 { seenEventIDs.removeFirst(256) }
            }
            if let durable = event.durable {
                if let previous = lastSequences[durable.aggregateID], durable.seq <= previous { return }
                lastSequences[durable.aggregateID] = durable.seq
            }
            try consume(event)
        } catch { failConnection(.invalidResponse) }
    }

    private func consume(_ event: OpenCodeV2Event) throws {
        guard !event.requiresReconciliation else { throw OpenCodeV2SessionError.invalidResponse }
        let nativeID = event.sessionID
        if let inbox = event.inboxID, var steer = steers[inbox], steer.sessionID == nativeID,
           [.inboxEnqueued, .inboxDelivered, .inboxCancelled].contains(event.kind) {
            steer.observed = true
            if event.kind == .inboxDelivered {
                steer.delivered = true; runs[steer.runID]?.pendingSteers.remove(inbox)
                // Delivery after the previous execution ended belongs to the
                // following execution. Its started event must clear the old end.
                if runs[steer.runID]?.terminal != nil { runs[steer.runID]?.awaitingSteerStart = true }
                strandedSteers.remove(inbox)
            } else if event.kind == .inboxCancelled, !steer.delivered {
                steer.cancelled = true; runs[steer.runID]?.pendingSteers.remove(inbox); strandedSteers.remove(inbox)
            }
            steers[inbox] = steer
            if event.kind == .inboxCancelled { finishIfReady(steer.runID) }
            return
        }
        if event.kind == .sessionCreated, let parent = event.session?.parentID, owners[parent] != nil {
            guard childParents.count < 256 || childParents[nativeID] != nil else { throw OpenCodeV2SessionError.invalidResponse }
            if let link = childCalls[nativeID], link.parentID != parent { throw OpenCodeV2SessionError.invalidResponse }
            childParents[nativeID] = parent
        }
        let assistant = event.assistantMessageID ?? event.permission?.messageID
        let priorOwner = assistant.flatMap { assistantOwners[.init(sessionID: nativeID, type: "assistant", id: $0)] }
        guard let owner = priorOwner ?? owners[nativeID], var run = runs[owner] else {
            if nativeID == sessionID, event.kind == .executionStarted, preparing == nil, activeRunID == nil {
                let id = UUID()
                var run = OpenCodeNativeRun(id: id, sessionID: nativeID, inputID: "", autonomous: true)
                run.started = true; run.admitted = true; run.delivered = true
                runs[id] = run; owners[nativeID] = id; activeRunID = id
                continuation.yield(.activity(.init(id: id, state: .running)))
            }
            return
        }
        let root = nativeID == run.sessionID
        if root {
            switch event.kind {
            case .inboxEnqueued, .inboxDelivered:
                if run.nativeCommand, event.kind == .inboxEnqueued, let inbox = event.inbox {
                    guard inbox.type == "user", !run.commandPriorIDs.contains(inbox.id),
                          run.inputID.isEmpty || run.inputID == inbox.id else { throw OpenCodeV2SessionError.uncertainDelivery }
                    run.inputID = inbox.id
                }
                if !run.inputID.isEmpty, event.inboxID == run.inputID {
                    run.inputObserved = true
                    if event.kind == .inboxDelivered { run.delivered = true }
                    runs[owner] = run
                    if run.nativeCommand { finishCommandInput(owner, error: nil) }
                    announceInput(owner); try flushBuffered(owner); finishIfReady(owner)
                }
                return
            case .inboxCancelled:
                if event.inboxID == run.inputID, !run.delivered {
                    run.stopped = true; run.admitted = true; run.terminal = .executionInterrupted
                    runs[owner] = run; finishIfReady(owner)
                }
                return
            case .executionStarted:
                if run.finished {
                    guard preparing == nil, activeRunID == nil else { return }
                    let id = UUID()
                    var next = OpenCodeNativeRun(id: id, sessionID: nativeID, inputID: "", autonomous: true)
                    next.started = true; next.admitted = true; next.delivered = true
                    runs[id] = next; owners[nativeID] = id; activeRunID = id
                    continuation.yield(.activity(.init(id: id, state: .running)))
                    return
                }
                run.started = true; run.terminal = nil; run.awaitingSteerStart = false; runs[owner] = run
                try flushBuffered(owner); finishIfReady(owner); return
            case .executionSucceeded, .executionInterrupted, .executionFailed:
                // An older execution can end after the new queue admission but
                // before that exact input is delivered. It cannot end this run.
                guard !run.finished else { return }
                guard run.delivered else {
                    run.started = false; runs[owner] = run
                    return
                }
                guard run.started, run.admitted || run.inputObserved else { throw OpenCodeV2SessionError.invalidResponse }
                run.terminal = event.kind; runs[owner] = run; finishIfReady(owner); return
            default: break
            }
            if run.finished {
                if priorOwner == owner { try project(event, owner: owner) }
                return
            }
            guard run.started, run.delivered, run.admitted || run.inputObserved else {
                try buffer(event, runID: owner); return
            }
        }
        try project(event, owner: owner)
    }

    private func announceInput(_ id: UUID) {
        guard var run = runs[id], !run.announced, !run.autonomous, !run.compaction, !run.inputID.isEmpty,
              run.admitted || run.inputObserved else { return }
        run.announced = true; runs[id] = run
        continuation.yield(.context(runID: id, event: .turn(run.inputID)))
    }

    private func buffer(_ event: OpenCodeV2Event, runID: UUID) throws {
        guard var run = runs[runID] else { return }
        let bytes = event.text?.utf8.count ?? 0
        guard run.buffer.count < 256, run.bufferBytes + bytes <= 2 * 1_024 * 1_024 else { throw OpenCodeV2SessionError.invalidResponse }
        run.buffer.append(event); run.bufferBytes += bytes; runs[runID] = run
    }

    private func flushBuffered(_ id: UUID) throws {
        guard var run = runs[id], run.started, run.delivered, run.admitted || run.inputObserved else { return }
        let buffered = run.buffer; run.buffer = []; run.bufferBytes = 0; runs[id] = run
        for event in buffered { try project(event, owner: id) }
    }

    private func project(_ event: OpenCodeV2Event, owner: UUID) throws {
        guard let run = runs[owner] else { return }
        let assistantID = event.assistantMessageID ?? event.permission?.messageID
        var waiting: [OpenCodeV2Event] = []
        var childFrames: [OpenCodeSSEEvent] = []
        if event.kind == .stepStarted, let assistant = event.assistantMessageID {
            guard assistantOwners.count < 4_096 else { throw OpenCodeV2SessionError.invalidResponse }
            let key = ProviderEntityKey(sessionID: event.sessionID, type: "assistant", id: assistant)
            assistantOwners[key] = owner
            waiting = assistantBuffer.removeValue(forKey: key) ?? []
            assistantBufferBytes -= waiting.reduce(0) { $0 + ($1.text?.utf8.count ?? 0) }
        } else if let assistantID {
            let key = ProviderEntityKey(sessionID: event.sessionID, type: "assistant", id: assistantID)
            if assistantOwners[key] == nil {
                let bytes = event.text?.utf8.count ?? 0
                guard assistantBuffer.values.reduce(0, { $0 + $1.count }) < 256,
                      assistantBufferBytes + bytes <= 2 * 1_024 * 1_024 else { throw OpenCodeV2SessionError.invalidResponse }
                assistantBuffer[key, default: []].append(event); assistantBufferBytes += bytes
                return
            }
        }
        if let assistant = event.assistantMessageID,
           let original = assistantOwners[.init(sessionID: event.sessionID, type: "assistant", id: assistant)], original != owner {
            return
        }
        if let tool = event.tool, let assistant = event.assistantMessageID, tool.name == "subagent" {
            guard knownSubagentCalls.count < 4_096 else { throw OpenCodeV2SessionError.invalidResponse }
            knownSubagentCalls.insert(Self.callKey(sessionID: event.sessionID, assistant: assistant, tool: tool.id))
        }
        if let tool = event.tool, let child = tool.childSessionID, let assistant = event.assistantMessageID,
           knownSubagentCalls.contains(Self.callKey(sessionID: event.sessionID, assistant: assistant, tool: tool.id)) {
            try Self.identifier(child)
            if let parent = childParents[child], parent != event.sessionID { throw OpenCodeV2SessionError.invalidResponse }
            if let previous = owners[child], previous != owner { throw OpenCodeV2SessionError.invalidResponse }
            guard owners.count < 256 else { throw OpenCodeV2SessionError.invalidResponse }
            owners[child] = owner
            childCalls[child] = .init(parentID: event.sessionID, assistantMessageID: assistant, toolID: tool.id)
            backgroundActive.insert(child)
            let childOwner = OpenCodeProjectionOwner(sessionID: child, runID: owner)
            if projectors[childOwner] == nil { projectors[childOwner] = .init(instanceID: configuration.instanceID, sessionID: child) }
            childFrames = earlyChildFrames.removeValue(forKey: child) ?? []
            earlyChildBytes -= childFrames.reduce(0) { $0 + $1.data.utf8.count }
        }
        if event.kind == .executionSucceeded || event.kind == .executionInterrupted || event.kind == .executionFailed {
            backgroundActive.remove(event.sessionID)
            if let link = childCalls[event.sessionID], var projector = projectors[.init(sessionID: link.parentID, runID: owner)] {
                let outcome: OpenCodeV2Projection.ChildOutcome = event.kind == .executionSucceeded ? .completed : event.kind == .executionFailed ? .failed : .interrupted
                let updates = try projector.childCompleted(assistantMessageID: link.assistantMessageID, toolID: link.toolID, childSessionID: event.sessionID, outcome: outcome)
                projectors[.init(sessionID: link.parentID, runID: owner)] = projector
                for update in updates { continuation.yield(.runEntity(runID: owner, update: update)) }
            }
        }
        if let permission = event.permission { try receive(permission, owner: owner) }
        if let form = event.form { try receive(form, owner: owner) }
        if event.kind == .permissionReplied || event.kind == .formReplied || event.kind == .formCancelled {
            if let nativeRequest = event.requestID { dismiss(nativeRequest: nativeRequest, session: event.sessionID) }
        }
        let projectionOwner = OpenCodeProjectionOwner(sessionID: event.sessionID, runID: owner)
        if projectors[projectionOwner] == nil { projectors[projectionOwner] = .init(instanceID: configuration.instanceID, sessionID: event.sessionID) }
        let updates = try projectors[projectionOwner]!.apply(event)
        for update in updates {
            if event.sessionID != run.sessionID || run.finished { continuation.yield(.runEntity(runID: owner, update: update)) }
            else { continuation.yield(.context(runID: owner, event: .entity(update))) }
        }
        for buffered in waiting { try project(buffered, owner: owner) }
        // Project the parent link before a buffered child terminal can settle it.
        // Replaying through consume preserves the native aggregate sequence gate.
        for frame in childFrames { consume(frame) }
    }

    private func finishIfReady(_ id: UUID) {
        guard var run = runs[id], !run.finished, let terminal = run.terminal,
              !run.nativeCommand || run.admitted,
              (run.started && run.delivered && (run.admitted || run.inputObserved)) || (run.stopped && !run.delivered) else { return }
        if terminal == .executionSucceeded, !run.stopped,
           (!run.pendingSteers.isEmpty || run.awaitingSteerStart) { return }
        strandedSteers.formUnion(run.pendingSteers)
        run.finished = true; runs[id] = run
        if activeRunID == id { activeRunID = nil }
        if run.autonomous {
            let reason = terminal == .executionSucceeded ? "end_turn" : terminal == .executionInterrupted ? "cancelled" : "error"
            continuation.yield(.activity(.init(id: id, state: .idle, stopReason: .string(reason))))
        } else if terminal == .executionFailed {
            // A native execution can fail while its connection and background
            // children remain healthy. Transport/protocol uncertainty uses the
            // separate connectionClosed path and still pauses reconciliation.
            let notice = ChatMessage(id: "opencode-execution-failure-" + id.uuidString, role: .system,
                                     text: "OpenCode could not complete this execution.")
            continuation.yield(.context(runID: id, event: .message(notice)))
            continuation.yield(.context(runID: id, event: .completed(.failed)))
        } else {
            continuation.yield(.context(runID: id, event: .completed(terminal == .executionInterrupted || run.stopped ? .interrupted : .idle)))
        }
    }

    public func interrupt(expectedRunID: UUID) async throws {
        guard activeRunID == expectedRunID else { throw ProviderSteeringError(.staleTarget) }
        try await interrupt()
    }

    public func interrupt() async throws {
        guard historyToken == nil else { throw OpenCodeV2SessionError.busy }
        guard interrupting == nil else { throw OpenCodeV2SessionError.busy }
        let stopToken = UUID(); interrupting = stopToken
        defer { if interrupting == stopToken { interrupting = nil } }
        if let token = preparing { stoppedPreparations.insert(token) }
        if let id = activeRunID, var run = runs[id] { run.stopped = true; runs[id] = run }
        guard !closing else { throw CancellationError() }
        let stoppedRunID = activeRunID
        if let id = stoppedRunID, let run = runs[id] {
            for inboxID in run.pendingSteers.sorted() {
                guard let steer = steers[inboxID], steer.admitted || steer.observed else {
                    failConnection(.uncertainDelivery); await close(); throw OpenCodeV2SessionError.uncertainDelivery
                }
                try Self.noContent(try await call(method: "DELETE", path: ["api", "session", steer.sessionID, "inbox", inboxID]))
                guard activeRunID == id || activeRunID == nil else { throw OpenCodeV2SessionError.staleRequest }
                strandedSteers.remove(inboxID)
            }
        }
        if let id = activeRunID, let run = runs[id], run.nativeCommand, !run.admitted {
            failConnection(.uncertainDelivery); await close(); throw OpenCodeV2SessionError.uncertainDelivery
        }
        if let id = activeRunID, let run = runs[id], !run.autonomous, !run.inputID.isEmpty {
            if !run.admitted && !run.inputObserved {
                // Cancellation cannot retract a POST which may still be entering
                // the native durable inbox. An early DELETE/idle interrupt could
                // otherwise succeed before that POST starts work. Preserve the
                // unknown delivery and drain this exact owned runtime instead.
                failConnection(.uncertainDelivery)
                await close()
                throw OpenCodeV2SessionError.uncertainDelivery
            }
            // Cancelling an owned inbox item is exact and is a native no-op once
            // delivered; it cannot remove an unrelated queued user input.
            try Self.noContent(try await call(method: "DELETE", path: ["api", "session", run.sessionID, "inbox", run.inputID]))
        }
        let nativeIDs = Set(backgroundActive).union(sessionID.map { [$0] } ?? [])
        for nativeID in nativeIDs.sorted() {
            guard activeRunID == stoppedRunID || activeRunID == nil else { throw OpenCodeV2SessionError.staleRequest }
            let response = try await call(method: "POST", path: ["api", "session", nativeID, "interrupt"], body: .object([:]))
            let value = try Self.json(response)
            guard case .bool = value["interrupted"] else { throw OpenCodeV2SessionError.invalidResponse }
        }
    }

    private func receive(_ permission: OpenCodeV2Permission, owner: UUID) throws {
        guard pending.count < 256 else { throw OpenCodeV2SessionError.invalidResponse }
        if pending.values.contains(where: { $0.sessionID == permission.sessionID && $0.nativeID == permission.id }) { return }
        let localID = JSONValue.string("opencode-request-" + UUID().uuidString)
        var request = permission.approval(localID: localID)
        if !permission.save.isEmpty, var params = request.params.object, var options = params["options"]?.array {
            options.insert(.object(["optionId": .string("session"), "name": .string("Allow for this conversation")]), at: 1)
            params["options"] = .array(options); request.params = .object(params)
        }
        pending[localID] = .init(request: request, owner: owner, sessionID: permission.sessionID, nativeID: permission.id, permission: permission, form: nil)
        continuation.yield(.sessionApproval(request))
    }

    private func receive(_ form: OpenCodeV2Form, owner: UUID) throws {
        guard pending.count < 256 else { throw OpenCodeV2SessionError.invalidResponse }
        if pending.values.contains(where: { $0.sessionID == form.sessionID && $0.nativeID == form.id }) { return }
        let localID = JSONValue.string("opencode-request-" + UUID().uuidString)
        let request = form.approval(localID: localID)
        pending[localID] = .init(request: request, owner: owner, sessionID: form.sessionID, nativeID: form.id, permission: nil, form: form)
        continuation.yield(.sessionApproval(request))
    }

    public func respond(_ request: ApprovalRequest, allow: Bool) async throws {
        guard let entry = pending[request.id], entry.request == request else { throw OpenCodeV2SessionError.staleRequest }
        if let permission = entry.permission {
            let body = try permission.replyBody(decision: allow ? .once : .reject)
            try await reply(entry, method: "POST", tail: ["permission", entry.nativeID, "reply"], body: body)
        } else if !allow, entry.form != nil {
            try await reply(entry, method: "DELETE", tail: ["form", entry.nativeID], body: nil)
        } else { throw OpenCodeV2SessionError.staleRequest }
    }

    public func answer(_ request: ApprovalRequest, answers: [String: String]) async throws {
        guard let entry = pending[request.id], entry.request == request, let form = entry.form else { throw OpenCodeV2SessionError.staleRequest }
        try await reply(entry, method: "POST", tail: ["form", entry.nativeID, "reply"], body: form.answerBody(answers: answers))
    }

    public func selectAnswers(_ request: ApprovalRequest, selections: [String: [String]]) async throws {
        guard let entry = pending[request.id], entry.request == request, let form = entry.form else { throw OpenCodeV2SessionError.staleRequest }
        try await reply(entry, method: "POST", tail: ["form", entry.nativeID, "reply"], body: form.answerBody(selections: selections))
    }

    public func choose(_ request: ApprovalRequest, optionID: String) async throws {
        if optionID == "session" {
            guard let entry = pending[request.id], entry.request == request, let permission = entry.permission, !permission.save.isEmpty else { throw OpenCodeV2SessionError.staleRequest }
            try claimAnswer(entry)
            defer { answering.remove(request.id) }
            let policy: OpenCodeNativePolicy
            if let existing = policies[entry.sessionID] { policy = existing }
            else {
                guard let run = runs[entry.owner], let rootPolicy = policies[run.sessionID] else { throw OpenCodeV2SessionError.staleRequest }
                let info = try OpenCodeV2Protocol.session(try await call(method: "GET", path: ["api", "session", entry.sessionID]), expectedID: entry.sessionID, directory: cwd.path)
                guard let agent = info.agentID else { throw OpenCodeV2SessionError.invalidResponse }
                policy = .init(permission: rootPolicy.permission, agentID: agent,
                               agentPaths: try await transport.agentPathRules(directory: cwd, agentID: agent))
                policies[entry.sessionID] = policy
            }
            var grants = sessionGrants[entry.sessionID] ?? []
            for resource in permission.save where !grants.contains(where: { $0.action == permission.action && $0.resource == resource }) {
                guard grants.count < 256 else { throw OpenCodeV2SessionError.invalidResponse }
                grants.append(.init(action: permission.action, resource: resource, effect: .allow))
            }
            let rules = Self.permissions(policy.permission, agentID: policy.agentID, agentPaths: policy.agentPaths, grants: grants, appMCP: appMCPConnection != nil)
            try Self.noContent(try await call(method: "PATCH", path: ["api", "session", entry.sessionID], body: .object(["permissions": rules])))
            sessionGrants[entry.sessionID] = grants
            try await reply(entry, method: "POST", tail: ["permission", entry.nativeID, "reply"], body: permission.replyBody(decision: .once), reserved: true)
            return
        }
        if optionID == "always" {
            guard let entry = pending[request.id], entry.request == request, let permission = entry.permission else { throw OpenCodeV2SessionError.staleRequest }
            try await reply(entry, method: "POST", tail: ["permission", entry.nativeID, "reply"], body: permission.replyBody(decision: .always))
            return
        }
        if optionID == "reject" {
            guard let entry = pending[request.id], entry.request == request, let permission = entry.permission else { throw OpenCodeV2SessionError.staleRequest }
            try claimAnswer(entry)
            defer { answering.remove(request.id) }
            // A declined tool should not be retried via a different command.
            // This note never resumes or starts provider execution on its own.
            _ = try? await call(method: "POST", path: ["api", "session", entry.sessionID, "synthetic"], body: .object([
                "id": .string("msg_coincide_decline_" + UUID().uuidString.replacingOccurrences(of: "-", with: "")),
                "text": .string("The user declined the requested action. Do not retry it or use another tool to perform it."),
                "delivery": .string("steer"), "resume": .bool(false)
            ]))
            try await reply(entry, method: "POST", tail: ["permission", entry.nativeID, "reply"],
                            body: permission.replyBody(decision: .reject, message: "The user declined this request."), reserved: true)
            return
        }
        guard optionID == "once" else { throw OpenCodeV2SessionError.staleRequest }
        try await respond(request, allow: true)
    }

    private func claimAnswer(_ entry: OpenCodePendingRequest) throws {
        guard !closing, !uncertain, pending[entry.request.id]?.request == entry.request,
              answering.insert(entry.request.id).inserted else { throw OpenCodeV2SessionError.staleRequest }
    }

    private func reply(_ entry: OpenCodePendingRequest, method: String, tail: [String], body: JSONValue?, reserved: Bool = false) async throws {
        guard !closing, !uncertain, pending[entry.request.id]?.request == entry.request else { throw OpenCodeV2SessionError.staleRequest }
        if !reserved { try claimAnswer(entry) }
        defer { answering.remove(entry.request.id) }
        do { try Self.noContent(try await call(method: method, path: ["api", "session", entry.sessionID] + tail, body: body)) }
        catch {
            if pending[entry.request.id] == nil { return } // Exact native replied/cancelled evidence already arrived.
            if !Self.definitelyRejected(error) { failConnection(.uncertainDelivery) }
            throw error is CancellationError ? CancellationError() : OpenCodeV2SessionError.invalidResponse
        }
        guard !closing else { throw CancellationError() }
        if pending.removeValue(forKey: entry.request.id) != nil { continuation.yield(.sessionApprovalDismissed(entry.request.id)) }
    }

    private func dismiss(nativeRequest: String, session: String) {
        for (id, request) in pending where request.nativeID == nativeRequest && request.sessionID == session {
            pending.removeValue(forKey: id); continuation.yield(.sessionApprovalDismissed(id))
        }
    }

    private func streamEnded() {
        guard !closing else { return }
        failConnection(.connectionLost)
    }

    private func failConnection(_ error: OpenCodeV2SessionError) {
        guard !closing, !uncertain else { return }
        uncertain = true
        finishCommandScans(ready: false)
        finishCommandInputs(error: error)
        continuation.yield(.connectionClosed(error.localizedDescription))
    }

    public func close() async {
        if let closingTask { await closingTask.value; return }
        closing = true
        finishCommandScans(ready: false)
        finishCommandInputs(error: CancellationError())
        let task = Task { await self.finishClose() }
        closingTask = task
        await task.value
    }

    private func finishClose() async {
        if let token = preparing { stoppedPreparations.insert(token) }
        connecting?.cancel()
        let ownedRequests = Array(requests.values)
        let ownedSteers = Array(steeringTasks.values)
        let ownedHistory = historyTask
        ownedHistory?.cancel()
        for task in ownedSteers { task.cancel() }
        for request in ownedRequests { request.cancel() }
        // A lost prompt response can still mean admitted native work. Best-effort
        // interruption uses only exact known IDs; a short transport-close deadline
        // prevents a server withholding replies from blocking owned cleanup.
        let transport = transport
        var nativeIDs = connected ? Set(backgroundActive).union(sessionID.map { [$0] } ?? []) : []
        if let watch = historyWatch, watch.clearing, watch.startEventID != nil, watch.terminalEventID == nil, !watch.interference {
            nativeIDs.insert(watch.sourceID)
        }
        let stop = Task {
            for id in nativeIDs.sorted() {
                _ = try? await transport.request(method: "POST", path: ["api", "session", id, "interrupt"], body: .object([:]))
            }
        }
        let deadline = Task {
            do { try await Task.sleep(for: .seconds(2)) }
            catch { return }
            await transport.close()
        }
        await stop.value
        deadline.cancel(); await deadline.value
        await transport.close()
        for request in ownedRequests { _ = try? await request.value }
        for task in ownedSteers { _ = try? await task.value }
        if let ownedHistory { _ = await ownedHistory.result }
        if let connecting { _ = try? await connecting.value }
        reader?.cancel(); await reader?.value
        continuation.finish()
    }

    private func trimRuns() {
        guard runs.count >= 128 else { return }
        let retained = Set(backgroundActive.compactMap { owners[$0] }).union(pending.values.map(\.owner)).union(inFlightSends)
            .union(steeringTasks.keys.compactMap { steers[$0]?.runID })
        for id in runs.keys where id != activeRunID && !retained.contains(id) && runs[id]?.finished == true { runs.removeValue(forKey: id) }
        assistantOwners = assistantOwners.filter { runs[$0.value] != nil }
        projectors = projectors.filter { runs[$0.key.runID] != nil }
        steers = steers.filter { runs[$0.value.runID] != nil || steeringTasks[$0.key] != nil || strandedSteers.contains($0.key) }
    }

    private static func resolveModel(_ selected: OpenCodeModelSelection?, inventory: OpenCodeMetadataSnapshot) throws -> OpenCodeModelSelection {
        guard let model = selected ?? inventory.defaults.first,
              let advertised = inventory.models.first(where: { $0.selection.providerID == model.providerID && $0.selection.id == model.id && $0.enabled }),
              model.variant == nil || advertised.variants.contains(model.variant!) else { throw OpenCodeV2SessionError.invalidConfiguration }
        // Native v2 resolves an omitted variant to its literal "default"
        // sentinel, which is intentionally absent from the variant inventory.
        // Capture that exact native request before creation/configuration so
        // readback remains strict; explicit advertised variants are unchanged.
        return .init(providerID: model.providerID, id: model.id, variant: model.variant ?? "default")
    }

    private static func permissions(_ permission: PermissionMode, agentID: String, agentPaths: [OpenCodeV2PermissionRule], grants: [OpenCodeV2PermissionRule], appMCP: Bool = false) -> JSONValue {
        var rules = permission == .fullAccess ? [rule("*", "allow")] : [rule("shell", "ask"), rule("edit", permission == .autoAcceptEdits ? "allow" : "ask"), rule("external_directory", "ask")]
        if permission != .fullAccess { rules += grants.map(\.json) }
        if agentID == "plan" { rules.append(rule("edit", "deny")) }
        if permission != .fullAccess || agentID == "plan" {
            rules += agentPaths.filter { $0.effect == .allow && $0.resource != "*" && ["edit", "external_directory"].contains($0.action) }.map(\.json)
        }
        if appMCP { rules.append(rule(OpenCodeAppMCP.serverName + "_*", "allow")) }
        return .array(rules)
    }

    private static func rule(_ action: String, _ effect: String) -> JSONValue {
        .object(["action": .string(action), "resource": .string("*"), "effect": .string(effect)])
    }

    private static func modelBody(_ model: OpenCodeModelSelection) -> JSONValue {
        var object: [String: JSONValue] = ["providerID": .string(model.providerID), "id": .string(model.id)]
        if let variant = model.variant { object["variant"] = .string(variant) }
        return .object(object)
    }

    private static func prompt(_ input: ProviderInput, inputID: String, delivery: String = "queue") throws -> JSONValue {
        guard input.text.utf8.count <= 2 * 1_024 * 1_024, input.images.count <= 100,
              input.images.allSatisfy({ $0.data.count <= 20 * 1_024 * 1_024 && ["image/png", "image/jpeg", "image/gif", "image/webp"].contains($0.mimeType) }) else {
            throw OpenCodeV2SessionError.unsupportedInput
        }
        var object: [String: JSONValue] = ["id": .string(inputID), "text": .string(try input.providerText()), "delivery": .string(delivery)]
        if delivery == "queue" { object["resume"] = .bool(true) }
        if !input.images.isEmpty {
            object["files"] = .array(input.images.map { .object(["uri": .string("data:" + $0.mimeType + ";base64," + $0.data.base64EncodedString())]) })
        }
        let body = JSONValue.object(object)
        guard try JSONEncoder().encode(body).count <= 4 * 1_024 * 1_024 else { throw OpenCodeV2SessionError.unsupportedInput }
        return body
    }

    private static func json(_ response: OpenCodeHTTPResponse) throws -> JSONValue {
        guard response.status == 200, let value = try? JSONDecoder().decode(JSONValue.self, from: response.body) else { throw OpenCodeV2SessionError.invalidResponse }
        return value
    }

    private static func noContent(_ response: OpenCodeHTTPResponse) throws {
        guard response.status == 204 else { throw OpenCodeV2SessionError.invalidResponse }
    }

    private static func definitelyRejected(_ error: any Error) -> Bool {
        error is OpenCodeV2RejectedResponse || (error as? OpenCodeHTTPError) == .requestBodyTooLarge || (error as? OpenCodeHTTPError) == .invalidPath
    }

    private static func identifier(_ value: String) throws {
        guard !value.isEmpty, value.utf8.count <= 1_024,
              !value.unicodeScalars.contains(where: { $0.value < 32 || $0.value == 127 }), !value.contains("/"), !value.contains("\\") else {
            throw OpenCodeV2SessionError.wrongSession
        }
    }

    private static func sessionID(instance: UUID, thread: UUID) -> String { "ses_coincide_" + digest(instance.uuidString + ":" + thread.uuidString) }
    private static func inputID(instance: UUID, run: UUID) -> String { "msg_coincide_" + digest(instance.uuidString + ":" + run.uuidString) }
    private static func digest(_ value: String) -> String { SHA256.hash(data: Data(value.utf8)).map { String(format: "%02x", $0) }.joined() }
    private static func callKey(sessionID: String, assistant: String, tool: String) -> ProviderEntityKey {
        .init(sessionID: sessionID, type: "subagent_call", id: String(decoding: (try? JSONEncoder().encode([assistant, tool])) ?? Data(), as: UTF8.self))
    }
}

private struct OpenCodeCommandInputWaiter {
    let continuation: CheckedContinuation<Void, any Error>
    let deadline: Task<Void, Never>
}

private struct OpenCodeCommandScanWaiter {
    let continuation: CheckedContinuation<Bool, Never>
    let deadline: Task<Void, Never>
}

private struct OpenCodeHistoryWatch {
    let sourceID: String
    var clearing = false
    var startEventID: String?
    var terminalEventID: String?
    var interference = false
}

private struct OpenCodeProjectionOwner: Hashable {
    let sessionID: String
    let runID: UUID
}

private struct OpenCodeNativeRun {
    let id: UUID
    let sessionID: String
    var inputID: String
    let autonomous: Bool
    var nativeCommand = false
    var compaction = false
    var commandPriorIDs: Set<String> = []
    var configuration: ProviderConfiguration?
    var steerIDs: Set<String> = []
    var pendingSteers: Set<String> = []
    var awaitingSteerStart = false
    var admitted = false
    var inputObserved = false
    var delivered = false
    var announced = false
    var started = false
    var stopped = false
    var finished = false
    var terminal: OpenCodeV2Event.Kind?
    var buffer: [OpenCodeV2Event] = []
    var bufferBytes = 0
}

private struct OpenCodeNativeSteer {
    let runID: UUID
    let sessionID: String
    let fingerprint: String
    var admitted = false
    var observed = false
    var delivered = false
    var cancelled = false
    var rejected = false
}

private struct OpenCodePendingRequest {
    let request: ApprovalRequest
    let owner: UUID
    let sessionID: String
    let nativeID: String
    let permission: OpenCodeV2Permission?
    let form: OpenCodeV2Form?
}

private struct OpenCodeChildCall {
    let parentID: String
    let assistantMessageID: String
    let toolID: String
}

private struct OpenCodeNativePolicy {
    let permission: PermissionMode
    let agentID: String
    let agentPaths: [OpenCodeV2PermissionRule]
}

private struct OpenCodeV2RejectedResponse: Error { let status: Int }

/// One production adapter owns one exact child and its volatile HTTP/SSE clients.
/// This initial lifetime does not connect to or close another actor's server.
private actor OpenCodeV2OwnedRuntime: OpenCodeV2SessionTransport {
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
        owner = .init(executable: executable, generation: configuration.generation, cwd: canonical)
    }

    func connect() async throws -> AsyncThrowingStream<OpenCodeSSEEvent, any Error> {
        guard !closing, client == nil else { throw OpenCodeV2SessionError.closed }
        do {
            let endpoint = try await owner.start()
            guard !closing else { throw CancellationError() }
            let client = try OpenCodeHTTPClient(origin: endpoint.origin, credential: endpoint.credential)
            self.client = client
            if let connection = appMCPConnection {
                try await client.configureAppMCPRedaction(connection)
                appMCP = OpenCodeAppMCP(client: client, generation: .v2, directory: cwd, connection: connection)
            }
            let metadata = OpenCodeMetadataConnection(client: client, expectedGeneration: .v2, ownedProcessIdentifier: endpoint.processIdentifier)
            self.metadata = metadata
            _ = try await metadata.identify()
            guard !closing else { throw CancellationError() }
            let stream = try await OpenCodeSSEConnection.open(client: client, generation: .v2, directory: cwd)
            self.stream = stream
            guard !closing else { throw CancellationError() }
            return stream.events
        } catch { await close(); throw error }
    }

    func inventory(directory: URL) async throws -> OpenCodeMetadataSnapshot {
        guard !closing, let metadata else { throw OpenCodeV2SessionError.closed }
        return try await metadata.inventory(directory: directory)
    }

    func commands(directory: URL) async throws -> ProviderCommandInventory {
        guard !closing, let metadata else { throw OpenCodeV2SessionError.closed }
        return try await metadata.commands(directory: directory)
    }

    func agentPathRules(directory: URL, agentID: String) async throws -> [OpenCodeV2PermissionRule] {
        guard !closing, let client else { throw OpenCodeV2SessionError.closed }
        let response = try await client.request(path: ["api", "agent"], query: [.init(name: "location[directory]", value: directory.path)])
        guard response.status == 200, let value = try? JSONDecoder().decode(JSONValue.self, from: response.body),
              let entries = try OpenCodeCatalog.located(value, directory: directory.path).array, entries.count <= 512,
              let agent = entries.first(where: { $0["id"] == .string(agentID) }) else { throw OpenCodeV2SessionError.invalidConfiguration }
        if agent["permissions"] == .null { return [] }
        return try OpenCodeV2Protocol.permissionRules(agent["permissions"])
    }

    func request(method: String, path: [String], body: JSONValue?) async throws -> OpenCodeHTTPResponse {
        try await request(method: method, path: path, query: [], body: body)
    }

    func request(method: String, path: [String], query: [URLQueryItem], body: JSONValue?) async throws -> OpenCodeHTTPResponse {
        guard !closing, let client else { throw OpenCodeV2SessionError.closed }
        return try await client.request(method: method, path: path, query: query, body: try body.map { try JSONEncoder().encode($0) })
    }

    func close() async {
        closing = true
        await appMCP?.close()
        appMCP = nil; appMCPConnection = nil
        await stream?.close(); await metadata?.close(); await client?.close(); await owner.close()
    }
}
