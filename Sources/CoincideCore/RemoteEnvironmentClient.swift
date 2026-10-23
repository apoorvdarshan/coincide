import Foundation
import CryptoKit

public struct RemoteEnvironmentClientError: Error, Sendable, Equatable, LocalizedError {
    public enum Kind: Sendable, Equatable {
        case invalidConfiguration, trustRequired, wrongEnvironment, unsupported, invalidResponse, sequenceRegression
        case disconnected, closed, commandUncertain, commandAlreadyAttempted, limitExceeded
    }
    public let kind: Kind
    public let commandID: UUID?
    public init(_ kind: Kind, commandID: UUID? = nil) { self.kind = kind; self.commandID = commandID }
    public var errorDescription: String? {
        switch kind {
        case .invalidConfiguration: "Enter a valid SSH alias, port, absolute CoincideEnvironment helper path and remote data directory."
        case .trustRequired: "Review and trust this remote environment before connecting."
        case .wrongEnvironment: "This SSH connection reaches a different Coincide environment. The saved identity was preserved."
        case .unsupported: "This remote environment does not support the required protocol capabilities."
        case .invalidResponse: "The remote environment returned an invalid response."
        case .sequenceRegression: "The remote workspace is older than the last observed revision. Reconnect to the original environment."
        case .disconnected: "The remote connection closed. Check SSH access and the preinstalled environment helper."
        case .closed: "This remote environment client is closed."
        case .commandUncertain: "The remote command may have committed. Check its saved result before continuing; it will not be sent again automatically."
        case .commandAlreadyAttempted: "This command was already attempted. Check its saved result instead of sending it again."
        case .limitExceeded: "The remote environment connection exceeded a protocol limit."
        }
    }
}

public enum RemoteEnvironmentClientEvent: Sendable {
    case descriptor(RemoteEnvironmentDescriptor)
    case snapshot(RemoteEnvironmentSnapshot)
    case projectionChanged(RemoteProjectionInvalidation)
    case disconnected(RemoteEnvironmentClientError)
}

/// One trusted environment identity with replaceable, generation-fenced owned
/// stdio connections. A reconnect never replays a command or an uncertain input.
public actor RemoteEnvironmentClient {
    public typealias ConnectionFactory = @Sendable () throws -> JSONRPCConnection
    public nonisolated let events: AsyncStream<RemoteEnvironmentClientEvent>
    private let continuation: AsyncStream<RemoteEnvironmentClientEvent>.Continuation
    private let factory: ConnectionFactory
    private var expectedID: UUID?
    private var generation = UUID()
    private var rpc: JSONRPCConnection?
    private var reader: Task<Void, Never>?
    private var discovery: Task<RemoteEnvironmentDescriptor, any Error>?
    private var descriptor: RemoteEnvironmentDescriptor?
    private var latest: RemoteEnvironmentSnapshot?
    private var projectionMode = false
    private var projectionHostID: UUID?
    private var latestProjectionBinding: RemoteProjectionBinding?
    private var latestProjectionSequence: Int64?
    private struct ProjectionCursorClaim: Equatable {
        let query: Data
        let viewID: UUID
        let offset: Int
        let total: Int
    }
    private struct ProjectionPageRead {
        let query: Data
        let requestKey: Data
        let binding: RemoteProjectionBinding
        let cursor: UUID?
        let offset: Int
        let total: Int?
    }
    private var projectionCursors: [UUID: ProjectionCursorClaim] = [:]
    private var projectionReplies: [Data: (viewID: UUID, digest: String)] = [:]
    private var sequenceFloor: Int64 = 0
    private var connected = false
    private var subscribing = false
    private var closed = false
    private var closeTask: Task<Void, Never>?
    private var drains: [UUID: Task<Void, Never>] = [:]
    private var attemptedCommands: Set<UUID> = []
    private var activeRequests = 0
    private var activeWorkspaceBytes = 0
    private var attemptedWorkspaceOperations: Set<UUID> = []
    private var attemptedTerminalOpens: Set<UUID> = []
    private var terminalInputAttempts: [UUID: Int64] = [:]
    private var terminalInputInFlight: Set<UUID> = []
    private var haltedTerminalInputs: Set<UUID> = []
    private var pullRequestRepositories: [Data: GitHubRepository] = [:]

    public init(factory: @escaping ConnectionFactory, expectedEnvironmentID: UUID? = nil) {
        (events, continuation) = AsyncStream.makeStream(bufferingPolicy: .bufferingNewest(8))
        self.factory = factory; expectedID = expectedEnvironmentID
    }
    public func currentDescriptor() -> RemoteEnvironmentDescriptor? { descriptor }
    public func currentSnapshot() -> RemoteEnvironmentSnapshot? { latest }
    public func currentProjectionSequence() -> Int64? { latestProjectionSequence }
    public func isConnected() -> Bool { connected && !closed }
    public func expectedEnvironmentID() -> UUID? { expectedID }
    /// A caller replacing this client may carry forward its already-observed
    /// floor for this exact trusted identity. This is not a restart attestation.
    public func requireMinimumSequence(_ sequence: Int64, environmentID: UUID) throws {
        guard !closed, !connected, sequence >= 0, expectedID == environmentID,
              descriptor?.environmentID == environmentID else { throw RemoteEnvironmentClientError(.wrongEnvironment) }
        sequenceFloor = max(sequenceFloor, sequence)
    }

    public func discover() async throws -> RemoteEnvironmentDescriptor {
        guard !closed else { throw RemoteEnvironmentClientError(.closed) }
        if let descriptor, rpc != nil { return descriptor }
        if let discovery {
            let owned = generation, value = try await discovery.value
            guard !closed, generation == owned, rpc != nil else { throw CancellationError() }
            return value
        }
        let connection: JSONRPCConnection
        do { connection = try factory() } catch { throw RemoteEnvironmentClientError(.disconnected) }
        let owned = UUID(); generation = owned; rpc = connection
        sequenceFloor = max(sequenceFloor, latest?.sequence ?? 0)
        let stream = connection.events
        reader = Task { [weak self] in
            for await event in stream { await self?.consume(event, connection: connection, generation: owned) }
        }
        let task = Task { [weak self] in
            let raw = try await connection.request(RemoteEnvironmentProtocol.describeMethod, timeout: .seconds(30))
            let value = try RemoteEnvironmentProtocol.decode(RemoteEnvironmentDescriptor.self, from: raw)
            guard let self else { throw CancellationError() }
            try await self.acceptDescriptor(value, generation: owned)
            return value
        }
        discovery = task
        do {
            let value = try await task.value
            guard generation == owned, !closed, rpc != nil else { throw CancellationError() }
            discovery = nil; return value
        } catch {
            if generation == owned {
                discovery = nil
                let safe = error as? RemoteEnvironmentClientError ?? RemoteEnvironmentClientError(.disconnected)
                retire(safe)
                throw safe
            }
            throw CancellationError()
        }
    }
    /// Local acceptance only. This never sends a server request or changes SSH
    /// host-key/authentication settings, which remain the system SSH client's job.
    public func trust(environmentID: UUID) throws {
        guard !closed, let descriptor, rpc != nil else { throw RemoteEnvironmentClientError(.disconnected) }
        guard descriptor.environmentID == environmentID, expectedID == nil || expectedID == environmentID else {
            throw RemoteEnvironmentClientError(.wrongEnvironment)
        }
        expectedID = environmentID
    }
    public func connect() async throws -> RemoteEnvironmentSnapshot {
        let described = try await discover()
        guard expectedID == described.environmentID else { throw RemoteEnvironmentClientError(.trustRequired) }
        guard described.capabilities.supportsSubscriptions, described.capabilities.supportsCommandReceipts else {
            throw RemoteEnvironmentClientError(.unsupported)
        }
        if connected, let latest { return latest }
        let (connection, owned, environment) = try context(requireConnected: false)
        subscribing = true
        do {
            let value = try await requestSnapshot(RemoteEnvironmentProtocol.subscribeMethod, connection: connection, generation: owned, environmentID: environment)
            guard generation == owned else { throw CancellationError() }
            subscribing = false; connected = true
            return value
        } catch {
            if generation == owned { subscribing = false; retire(error as? RemoteEnvironmentClientError ?? .init(.disconnected)) }
            throw error as? RemoteEnvironmentClientError ?? RemoteEnvironmentClientError(.disconnected)
        }
    }
    public func snapshot() async throws -> RemoteEnvironmentSnapshot {
        guard !projectionMode else { throw RemoteEnvironmentClientError(.unsupported) }
        let (connection, owned, environment) = try context()
        return try await requestSnapshot(RemoteEnvironmentProtocol.snapshotMethod, connection: connection, generation: owned, environmentID: environment)
    }
    public func command(_ command: RemoteEnvironmentCommand, id: UUID = UUID()) async throws -> RemoteEnvironmentCommandResult {
        let (connection, owned, environment) = try context()
        if command.isWorktreeCommand, descriptor?.capabilities.supportsRemoteWorktrees != true {
            throw RemoteEnvironmentClientError(.unsupported)
        }
        if command.preparesAttachments, descriptor?.capabilities.supportsRemoteAttachments != true {
            throw RemoteEnvironmentClientError(.unsupported)
        }
        let changesCheckpointPolicy: Bool
        switch command {
        case .editThread(_, .checkpointPolicy, _): changesCheckpointPolicy = true
        case .createThread(_, _, _, _, _, _, let policy): changesCheckpointPolicy = policy != nil
        default: changesCheckpointPolicy = false
        }
        if changesCheckpointPolicy, descriptor?.capabilities.supportsRemoteCheckpoints != true { throw RemoteEnvironmentClientError(.unsupported) }
        if command.isCheckpointCommand, descriptor?.capabilities.supportsRemoteCheckpoints != true {
            throw RemoteEnvironmentClientError(.unsupported)
        }
        if case .checkpoint(let target, let action) = command {
            guard target.environmentID == environment, target.rootID != nil || !action.requiresBoundRoot else { throw RemoteCheckpointFailure(.invalidTarget) }
            if case .beginRestore(_, let digest) = action, !Self.isTerminalDigest(digest) { throw RemoteCheckpointFailure(.invalidRequest) }
        }
        if command.isPullRequestCommand, descriptor?.capabilities.supportsRemotePullRequests != true {
            throw RemoteEnvironmentClientError(.unsupported)
        }
        if case .pullRequest(let target, let action) = command {
            guard target.environmentID == environment, target.rootID != nil || !action.requiresBoundRoot else { throw RemotePullRequestFailure(.invalidTarget) }
            if case .begin(_, let digest) = action, !Self.isTerminalDigest(digest) { throw RemotePullRequestFailure(.invalidRequest) }
        }
        guard !attemptedCommands.contains(id) else { throw RemoteEnvironmentClientError(.commandAlreadyAttempted, commandID: id) }
        guard attemptedCommands.count < 4_096, activeRequests < RemoteEnvironmentProtocol.maximumPendingRequests else {
            throw RemoteEnvironmentClientError(.limitExceeded)
        }
        let request = RemoteEnvironmentCommandRequest(environmentID: environment, id: id, command: command)
        let bytes = try RemoteEnvironmentProtocol.payload(request)
        let payload = try JSONDecoder().decode(JSONValue.self, from: bytes)
        attemptedCommands.insert(id); activeRequests += 1
        defer { activeRequests -= 1 }
        do {
            let raw = try await connection.request(RemoteEnvironmentProtocol.commandMethod, params: payload, timeout: .seconds((command.isPullRequestCommand || command.isCheckpointCommand) ? 120 : 45))
            let result = try RemoteEnvironmentProtocol.decode(RemoteEnvironmentCommandResult.self, from: raw)
            guard generation == owned, rpc != nil else { throw CancellationError() }
            try validateReceipt(result.receipt, environmentID: result.environmentID, commandID: id)
            return result
        } catch {
            // Even a transport timeout/cancellation can follow a durable commit.
            // The caller's private pending journal owns exact receipt recovery.
            if generation == owned, nativeRejection(error) == nil, workspaceRejection(error) == nil {
                retire(error as? RemoteEnvironmentClientError ?? .init(.disconnected))
            }
            throw RemoteEnvironmentClientError(.commandUncertain, commandID: id)
        }
    }
    public func receipt(for command: RemoteEnvironmentCommand, id: UUID) async throws -> RemoteEnvironmentReceiptResult {
        let (connection, owned, environment) = try context()
        guard activeRequests < RemoteEnvironmentProtocol.maximumPendingRequests else { throw RemoteEnvironmentClientError(.limitExceeded) }
        let request = RemoteEnvironmentCommandRequest(environmentID: environment, id: id, command: command)
        let bytes = try RemoteEnvironmentProtocol.payload(request)
        guard attemptedCommands.count < 4_096 || attemptedCommands.contains(id) else { throw RemoteEnvironmentClientError(.limitExceeded) }
        attemptedCommands.insert(id)
        activeRequests += 1; defer { activeRequests -= 1 }
        do {
            let raw = try await connection.request(RemoteEnvironmentProtocol.receiptMethod,
                params: JSONDecoder().decode(JSONValue.self, from: bytes), timeout: .seconds((command.isPullRequestCommand || command.isCheckpointCommand) ? 120 : 30))
            let result = try RemoteEnvironmentProtocol.decode(RemoteEnvironmentReceiptResult.self, from: raw)
            guard generation == owned, rpc != nil else { throw CancellationError() }
            guard result.environmentID == environment else { throw RemoteEnvironmentClientError(.wrongEnvironment) }
            if let receipt = result.receipt { try validateReceipt(receipt, environmentID: result.environmentID, commandID: id) }
            return result
        } catch {
            if let rejection = workspaceRejection(error), generation == owned { throw rejection }
            if let rejection = nativeRejection(error), generation == owned { throw rejection }
            let safe = error as? RemoteEnvironmentClientError ?? RemoteEnvironmentClientError(.disconnected)
            if generation == owned { retire(safe) }
            throw safe
        }
    }
    public func bindCheckpointWorkspace(_ target: RemoteWorkspaceTarget) async throws -> RemoteWorkspaceTarget {
        let owned = generation
        let result: RemoteWorkspaceTarget = try await checkpointRequest(RemoteCheckpointProtocol.bindMethod, request: target, target: target, requiresBoundRoot: false)
        try validateWorkspaceResponse(generation: owned) {
            let expected = RemoteWorkspaceTarget(environmentID: target.environmentID, projectID: target.projectID, threadID: target.threadID,
                configuration: target.configuration, rootID: result.rootID)
            guard result.rootID != nil, target.rootID == nil || result.rootID == target.rootID,
                  try Self.samePullRequestTarget(result, expected) else { throw RemoteEnvironmentClientError(.invalidResponse) }
        }
        return result
    }
    public func readCheckpoints(_ request: RemoteCheckpointReadRequest) async throws -> RemoteCheckpointReadResult {
        if case .runDiff(_, _, _, let maximum) = request.query {
            guard (1...1_048_576).contains(maximum) else { throw RemoteCheckpointFailure(.invalidRequest) }
        }
        let owned = generation
        let result: RemoteCheckpointReadResult = try await checkpointRequest(RemoteCheckpointProtocol.readMethod, request: request, target: request.target)
        try validateWorkspaceResponse(generation: owned) {
            guard try Self.samePullRequestTarget(result.target, request.target) else { throw RemoteEnvironmentClientError(.invalidResponse) }
            switch (request.query, result.value) {
            case (.inventory, .inventory(let inventory)):
                guard Set(inventory.runs.map(\.id)).count == inventory.runs.count else { throw RemoteEnvironmentClientError(.invalidResponse) }
                var identities = Set<UUID>()
                for run in inventory.runs {
                    let attempts = [run.baseline] + run.previousPostRunAttempts + (run.postRun.map { [$0] } ?? [])
                    for attempt in attempts {
                        try ProviderHistoryValidation.path(attempt.workspacePath)
                        try attempt.validate(workspacePath: attempt.workspacePath)
                        guard identities.insert(attempt.id).inserted,
                              attempt.id != run.id else { throw RemoteEnvironmentClientError(.invalidResponse) }
                    }
                    let ids = Set(attempts.map(\.id))
                    guard run.restoreUnavailableReasons.allSatisfy({ ids.contains($0.key) && !$0.value.isEmpty && $0.value.utf8.count <= 2_048 && !$0.value.contains("\0") }) else { throw RemoteEnvironmentClientError(.invalidResponse) }
                }
            case (.runDiff(let id, let baseline, let post, let maximum), .diff(let diff)):
                guard diff.runID == id, diff.baselineAttemptID == baseline, diff.postRunAttemptID == post,
                      diff.patch.utf8.count <= maximum else { throw RemoteEnvironmentClientError(.invalidResponse) }
            default: throw RemoteEnvironmentClientError(.invalidResponse)
            }
        }
        return result
    }
    public func reviewCheckpointRestore(_ request: RemoteCheckpointReviewRequest) async throws -> RemoteCheckpointReview {
        let owned = generation
        let result: RemoteCheckpointReview = try await checkpointRequest(RemoteCheckpointProtocol.reviewMethod, request: request, target: request.target)
        try validateWorkspaceResponse(generation: owned) {
            let review = result.value
            try review.validate()
            guard try Self.samePullRequestTarget(result.target, request.target), result.id == review.id,
                  Self.isTerminalDigest(result.digest), result.digest == (try RemoteCheckpointProtocol.digest(target: result.target, value: review)),
                  review.threadID == request.target.threadID, review.projectID == request.target.projectID,
                  review.runID == request.runID, review.stage == request.stage, review.attemptID == request.attemptID,
                  review.workspacePath.utf8.elementsEqual(request.target.workspacePath.utf8),
                  review.gitReview.currentPlan.workspacePath.utf8.elementsEqual(request.target.workspacePath.utf8),
                  review.gitReview.targetReceipt.plan.workspacePath.utf8.elementsEqual(request.target.workspacePath.utf8) else {
                throw RemoteEnvironmentClientError(.invalidResponse)
            }
        }
        return result
    }
    public func discardCheckpointRestoreReview(_ request: RemoteCheckpointDiscardRequest) async throws -> RemoteCheckpointDiscardResult {
        guard Self.isTerminalDigest(request.digest) else { throw RemoteCheckpointFailure(.invalidRequest) }
        let owned = generation
        let result: RemoteCheckpointDiscardResult = try await checkpointRequest(RemoteCheckpointProtocol.discardMethod, request: request, target: request.target, requiresBoundRoot: false)
        try validateWorkspaceResponse(generation: owned) {
            guard try RemoteCheckpointProtocol.payload(result.request) == RemoteCheckpointProtocol.payload(request) else { throw RemoteEnvironmentClientError(.invalidResponse) }
        }
        return result
    }
    private func checkpointRequest<Request: Encodable & Sendable, Response: Decodable & Sendable>(
        _ method: String, request: Request, target: RemoteWorkspaceTarget, requiresBoundRoot: Bool = true
    ) async throws -> Response {
        let (connection, owned, environment) = try context()
        guard target.environmentID == environment else { throw RemoteEnvironmentClientError(.wrongEnvironment) }
        guard descriptor?.capabilities.supportsRemoteCheckpoints == true else { throw RemoteEnvironmentClientError(.unsupported) }
        guard target.rootID != nil || !requiresBoundRoot else { throw RemoteCheckpointFailure(.invalidTarget) }
        let bytes = try RemoteCheckpointProtocol.payload(request)
        guard bytes.count <= RemoteEnvironmentProtocol.maximumRequestBytes, activeRequests < RemoteEnvironmentProtocol.maximumPendingRequests,
              activeWorkspaceBytes + bytes.count <= RemoteEnvironmentProtocol.maximumQueuedRequestBytes else { throw RemoteEnvironmentClientError(.limitExceeded) }
        activeRequests += 1; activeWorkspaceBytes += bytes.count
        defer { activeRequests -= 1; activeWorkspaceBytes -= bytes.count }
        do {
            let raw = try await connection.request(method, params: JSONDecoder().decode(JSONValue.self, from: bytes), timeout: .seconds(120))
            guard generation == owned, rpc != nil else { throw CancellationError() }
            do { return try RemoteEnvironmentProtocol.decode(Response.self, from: raw) }
            catch { throw RemoteEnvironmentClientError(.invalidResponse) }
        } catch {
            if generation == owned {
                if let failure = error as? JSONRPCRemoteError, failure.code == -32_005,
                   let value = failure.data["kind"].string, let kind = RemoteCheckpointFailure.Kind(rawValue: value) { throw RemoteCheckpointFailure(kind) }
                if let failure = workspaceRejection(error) { throw failure }
                if let failure = nativeRejection(error) { throw failure }
                retire(error as? RemoteEnvironmentClientError ?? .init(.disconnected))
            }
            throw error as? RemoteEnvironmentClientError ?? RemoteEnvironmentClientError(.disconnected)
        }
    }
    public func bindPullRequestWorkspace(_ target: RemoteWorkspaceTarget) async throws -> RemoteWorkspaceTarget {
        let owned = generation
        let result: RemoteWorkspaceTarget = try await pullRequestRequest(RemotePullRequestProtocol.bindMethod, request: target, target: target, requiresBoundRoot: false)
        try validateWorkspaceResponse(generation: owned) {
            let expected = RemoteWorkspaceTarget(environmentID: target.environmentID, projectID: target.projectID, threadID: target.threadID,
                configuration: target.configuration, rootID: result.rootID)
            guard result.rootID != nil, target.rootID == nil || result.rootID == target.rootID,
                  try Self.samePullRequestTarget(result, expected) else { throw RemoteEnvironmentClientError(.invalidResponse) }
        }
        return result
    }
    public func readPullRequests(_ request: RemotePullRequestReadRequest) async throws -> RemotePullRequestReadResult {
        do {
            switch request.query {
            case .context: break
            case .list(let query): try query.validate()
            case .detail(let reference): try reference.validate()
            case .resolve(let text): guard GitHubValidation.text(text, maximum: 2_048) else { throw RemotePullRequestFailure(.invalidRequest) }
            }
        } catch { throw RemotePullRequestFailure(.invalidRequest) }
        let owned = generation, key = try Self.pullRequestKey(request.target), expected = pullRequestRepositories[try Self.pullRequestKey(request.target)]
        let result: RemotePullRequestReadResult = try await pullRequestRequest(RemotePullRequestProtocol.readMethod, request: request, target: request.target)
        try validateWorkspaceResponse(generation: owned) {
            guard try Self.samePullRequestTarget(result.target, request.target) else { throw RemoteEnvironmentClientError(.invalidResponse) }
            switch (request.query, result.value) {
            case (.context, .context(let context)):
                try context.validate()
                guard context.workspacePath.utf8.elementsEqual(request.target.workspacePath.utf8) else { throw RemoteEnvironmentClientError(.invalidResponse) }
            case (.list(let query), .page(let page)):
                guard page.items.count <= query.limit, Set(page.items.map(\.reference)).count == page.items.count,
                      Set(page.items.map(\.reference.repository)).count <= 1,
                      expected == nil || page.items.allSatisfy({ $0.reference.repository == expected }) else { throw RemoteEnvironmentClientError(.invalidResponse) }
                for item in page.items { try item.validate() }
            case (.detail(let reference), .detail(let detail)):
                try Self.validatePullRequestDetail(detail)
                guard detail.summary.reference == reference, expected == nil || reference.repository == expected else { throw RemoteEnvironmentClientError(.invalidResponse) }
            case (.resolve, .detail(let detail)):
                try Self.validatePullRequestDetail(detail)
                guard expected == nil || detail.summary.reference.repository == expected else { throw RemoteEnvironmentClientError(.invalidResponse) }
            default: throw RemoteEnvironmentClientError(.invalidResponse)
            }
        }
        if case .context(let context) = result.value {
            if pullRequestRepositories.count >= 128 { pullRequestRepositories.removeValue(forKey: pullRequestRepositories.keys.first!) }
            pullRequestRepositories[key] = context.repository
        }
        return result
    }
    public func reviewPullRequest(_ request: RemotePullRequestReviewRequest) async throws -> RemotePullRequestReview {
        try Self.validatePullRequestIntent(request.intent)
        let owned = generation
        let result: RemotePullRequestReview = try await pullRequestRequest(RemotePullRequestProtocol.reviewMethod, request: request,
            target: request.target, maximum: RemoteEnvironmentProtocol.maximumWorkspaceRequestBytes)
        try validateWorkspaceResponse(generation: owned) {
            guard try Self.samePullRequestTarget(result.target, request.target), result.id == result.value.id,
                  Self.isTerminalDigest(result.digest), result.digest == (try RemotePullRequestProtocol.digest(target: result.target, value: result.value)) else {
                throw RemoteEnvironmentClientError(.invalidResponse)
            }
            switch (request.intent, result.value) {
            case (.create(let title, let body, let base, let draft), .creation(let review)):
                try review.validate()
                guard review.context.workspacePath.utf8.elementsEqual(request.target.workspacePath.utf8),
                      review.title.utf8.elementsEqual(title.utf8), review.body.utf8.elementsEqual(body.utf8),
                      base == nil || review.baseBranch.utf8.elementsEqual(base!.utf8), review.isDraft == draft else { throw RemoteEnvironmentClientError(.invalidResponse) }
            case (.checkout(let reference, let mode, let submodules, let title), .checkout(let review)):
                try review.validate()
                let configuration = request.target.configuration, actual = review.targetConfiguration
                var expected = configuration
                expected.workspacePath = review.plan.destinationPath; expected.nativeThreadID = nil; expected.claudeLaunchSelection = nil
                if let source = configuration.claudeRuntimeConfiguration, let replacement = actual.claudeRuntimeConfiguration {
                    // The host supplies physical spelling. Passing it explicitly
                    // keeps this validation lexical; no remote path is resolved here.
                    expected.claudeRuntimeConfiguration = try source.replacingWorkspace(review.plan.destinationPath, physicalPath: replacement.workspacePath)
                }
                if let source = configuration.piConfiguration, let runtime = source.runtime, let replacement = actual.piConfiguration?.runtime {
                    expected.piConfiguration = .init(instanceID: source.instanceID, executable: source.executable, model: source.model,
                        thinkingLevel: source.thinkingLevel, runtime: try runtime.replacingWorkspace(review.plan.destinationPath, physicalPath: replacement.workspacePath))
                }
                guard review.projectID == request.target.projectID,
                      review.registeredWorkspacePath.utf8.elementsEqual(request.target.workspacePath.utf8),
                      review.plan.request.sourcePath.utf8.elementsEqual(request.target.workspacePath.utf8),
                      review.plan.request.reference == reference, review.plan.request.mode == mode, review.plan.request.submodules == submodules,
                      title == nil || review.title.utf8.elementsEqual(title!.utf8), !review.reviewSetup,
                      try RemotePullRequestProtocol.payload(actual) == RemotePullRequestProtocol.payload(expected) else { throw RemoteEnvironmentClientError(.invalidResponse) }
            default: throw RemoteEnvironmentClientError(.invalidResponse)
            }
        }
        return result
    }
    public func discardPullRequestReview(_ request: RemotePullRequestDiscardRequest) async throws -> RemotePullRequestDiscardResult {
        guard Self.isTerminalDigest(request.digest) else { throw RemotePullRequestFailure(.invalidRequest) }
        let owned = generation
        let result: RemotePullRequestDiscardResult = try await pullRequestRequest(RemotePullRequestProtocol.discardMethod, request: request, target: request.target)
        try validateWorkspaceResponse(generation: owned) {
            guard try RemotePullRequestProtocol.payload(result.request) == RemotePullRequestProtocol.payload(request) else { throw RemoteEnvironmentClientError(.invalidResponse) }
        }
        return result
    }
    private func pullRequestRequest<Request: Encodable & Sendable, Response: Decodable & Sendable>(
        _ method: String, request: Request, target: RemoteWorkspaceTarget, maximum: Int = RemoteEnvironmentProtocol.maximumRequestBytes,
        requiresBoundRoot: Bool = true
    ) async throws -> Response {
        let (connection, owned, environment) = try context()
        guard target.environmentID == environment else { throw RemoteEnvironmentClientError(.wrongEnvironment) }
        guard target.rootID != nil || !requiresBoundRoot else { throw RemotePullRequestFailure(.invalidTarget) }
        guard descriptor?.capabilities.supportsRemotePullRequests == true else { throw RemoteEnvironmentClientError(.unsupported) }
        let bytes = try RemotePullRequestProtocol.payload(request)
        guard bytes.count <= maximum, activeRequests < RemoteEnvironmentProtocol.maximumPendingRequests,
              activeWorkspaceBytes + bytes.count <= RemoteEnvironmentProtocol.maximumQueuedRequestBytes else { throw RemoteEnvironmentClientError(.limitExceeded) }
        activeRequests += 1; activeWorkspaceBytes += bytes.count
        defer { activeRequests -= 1; activeWorkspaceBytes -= bytes.count }
        do {
            let raw = try await connection.request(method, params: JSONDecoder().decode(JSONValue.self, from: bytes), timeout: .seconds(120))
            guard generation == owned, rpc != nil else { throw CancellationError() }
            do { return try RemoteEnvironmentProtocol.decode(Response.self, from: raw) }
            catch { throw RemoteEnvironmentClientError(.invalidResponse) }
        } catch {
            if generation == owned {
                if let failure = error as? JSONRPCRemoteError, failure.code == -32_004,
                   let value = failure.data["kind"].string, let kind = RemotePullRequestFailure.Kind(rawValue: value) { throw RemotePullRequestFailure(kind) }
                if let failure = workspaceRejection(error) { throw failure }
                if let failure = nativeRejection(error) { throw failure }
                retire(error as? RemoteEnvironmentClientError ?? .init(.disconnected))
            }
            throw error as? RemoteEnvironmentClientError ?? RemoteEnvironmentClientError(.disconnected)
        }
    }
    private static func pullRequestKey(_ target: RemoteWorkspaceTarget) throws -> Data { Data(SHA256.hash(data: try RemotePullRequestProtocol.payload(target))) }
    private static func samePullRequestTarget(_ a: RemoteWorkspaceTarget, _ b: RemoteWorkspaceTarget) throws -> Bool {
        try RemotePullRequestProtocol.payload(a) == RemotePullRequestProtocol.payload(b)
    }
    private static func validatePullRequestIntent(_ intent: RemotePullRequestIntent) throws {
        do {
            switch intent {
            case .create(let title, let body, let base, _):
                guard GitHubValidation.text(title, maximum: 4_096), GitHubValidation.text(body, maximum: 1_048_576, allowEmpty: true, multiline: true),
                      base.map(GitHubValidation.branch) ?? true else { throw RemotePullRequestFailure(.invalidRequest) }
            case .checkout(let reference, _, _, let title):
                try reference.validate()
                guard title.map({ GitHubValidation.text($0, maximum: 4_096) }) ?? true else { throw RemotePullRequestFailure(.invalidRequest) }
            }
        } catch { throw RemotePullRequestFailure(.invalidRequest) }
    }
    private static func validatePullRequestDetail(_ detail: GitHubPullRequestDetail) throws {
        try detail.validate()
        for check in detail.checks {
            guard GitHubValidation.text(check.name, maximum: 4_096), check.url.map(GitHubValidation.safeWebURL) ?? true else { throw RemoteEnvironmentClientError(.invalidResponse) }
        }
    }
    public func beginAttachmentUpload(_ request: RemoteAttachmentUploadRequest) async throws -> RemoteAttachmentUpload {
        try Self.validateUploadRequest(request)
        let owned = generation
        let result: RemoteAttachmentUpload = try await attachmentRequest(RemoteAttachmentProtocol.beginMethod,
            request: request, target: request.target, mutating: true)
        try validateWorkspaceResponse(generation: owned) { try Self.validateUpload(result, request: request) }
        return result
    }
    public func attachmentUploadStatus(_ request: RemoteAttachmentUploadRequest) async throws -> RemoteAttachmentUpload? {
        try Self.validateUploadRequest(request)
        let owned = generation
        let result: RemoteAttachmentUpload? = try await attachmentRequest(RemoteAttachmentProtocol.statusMethod,
            request: request, target: request.target)
        try validateWorkspaceResponse(generation: owned) { if let result { try Self.validateUpload(result, request: request) } }
        return result
    }
    public func appendAttachmentChunk(_ request: RemoteAttachmentChunkRequest) async throws -> RemoteAttachmentUpload {
        try Self.validateUploadRequest(request.upload)
        let chunk = RemoteAttachmentProtocol.maximumChunkBytes
        let chunks = (request.upload.byteCount + chunk - 1) / chunk
        guard request.index >= 0, request.index < chunks,
              request.data.count == min(chunk, request.upload.byteCount - request.index * chunk),
              Self.isTerminalDigest(request.digest),
              SHA256.hash(data: request.data).map({ String(format: "%02x", $0) }).joined() == request.digest else {
            throw RemoteAttachmentFailure(.invalidRequest)
        }
        let owned = generation
        let result: RemoteAttachmentUpload = try await attachmentRequest(RemoteAttachmentProtocol.appendMethod,
            request: request, target: request.upload.target, mutating: true)
        try validateWorkspaceResponse(generation: owned) {
            try Self.validateUpload(result, request: request.upload)
            guard result.receivedChunks.contains(request.index) || [.cancelled, .failed, .uncertain].contains(result.state) else {
                throw RemoteEnvironmentClientError(.invalidResponse)
            }
        }
        return result
    }
    public func finalizeAttachmentUpload(_ request: RemoteAttachmentUploadRequest) async throws -> RemoteAttachmentUpload {
        try Self.validateUploadRequest(request)
        let owned = generation
        let result: RemoteAttachmentUpload = try await attachmentRequest(RemoteAttachmentProtocol.finalizeMethod,
            request: request, target: request.target, mutating: true)
        try validateWorkspaceResponse(generation: owned) {
            try Self.validateUpload(result, request: request)
            guard result.state != .receiving else { throw RemoteEnvironmentClientError(.invalidResponse) }
        }
        return result
    }
    public func cancelAttachmentUpload(_ request: RemoteAttachmentUploadRequest) async throws -> RemoteAttachmentUpload? {
        try Self.validateUploadRequest(request)
        let owned = generation
        let result: RemoteAttachmentUpload? = try await attachmentRequest(RemoteAttachmentProtocol.cancelMethod,
            request: request, target: request.target, mutating: true)
        try validateWorkspaceResponse(generation: owned) {
            if let result {
                try Self.validateUpload(result, request: request)
                guard [.cancelled, .claimed, .uncertain].contains(result.state) else { throw RemoteEnvironmentClientError(.invalidResponse) }
            }
        }
        return result
    }
    public func downloadAttachment(_ request: RemoteAttachmentDownloadRequest) async throws -> RemoteAttachmentDownloadResult {
        guard request.offset >= 0, request.offset <= AttachmentLimits.fileBytes,
              (1...RemoteAttachmentProtocol.maximumChunkBytes).contains(request.maxBytes) else { throw RemoteAttachmentFailure(.invalidRequest) }
        let owned = generation
        let result: RemoteAttachmentDownloadResult = try await attachmentRequest(RemoteAttachmentProtocol.downloadMethod,
            request: request, target: request.target)
        try validateWorkspaceResponse(generation: owned) {
            try AttachmentLimits.validate([result.attachment])
            guard result.target == request.target, result.attachment.id == request.attachmentID,
                  result.offset == request.offset, request.offset <= result.attachment.byteCount,
                  result.data.count == min(request.maxBytes, result.attachment.byteCount - request.offset),
                  result.eof == (request.offset + result.data.count == result.attachment.byteCount) else {
                throw RemoteEnvironmentClientError(.invalidResponse)
            }
            if request.offset == 0 && result.eof {
                guard SHA256.hash(data: result.data).map({ String(format: "%02x", $0) }).joined() == result.attachment.digest else {
                    throw RemoteEnvironmentClientError(.invalidResponse)
                }
            }
        }
        return result
    }
    private func attachmentRequest<Request: Encodable & Sendable, Response: Decodable & Sendable>(
        _ method: String, request: Request, target: RemoteAttachmentTarget, mutating: Bool = false
    ) async throws -> Response {
        let (connection, owned, environment) = try context()
        guard target.environmentID == environment else { throw RemoteEnvironmentClientError(.wrongEnvironment) }
        guard descriptor?.capabilities.supportsRemoteAttachments == true else { throw RemoteEnvironmentClientError(.unsupported) }
        let bytes = try JSONEncoder().encode(request)
        guard bytes.count <= RemoteEnvironmentProtocol.maximumRequestBytes,
              activeRequests < RemoteEnvironmentProtocol.maximumPendingRequests,
              activeWorkspaceBytes + bytes.count <= RemoteEnvironmentProtocol.maximumQueuedRequestBytes else {
            throw RemoteEnvironmentClientError(.limitExceeded)
        }
        activeRequests += 1; activeWorkspaceBytes += bytes.count
        defer { activeRequests -= 1; activeWorkspaceBytes -= bytes.count }
        do {
            let raw = try await connection.request(method, params: JSONDecoder().decode(JSONValue.self, from: bytes), timeout: .seconds(45))
            guard generation == owned, rpc != nil else { throw CancellationError() }
            do { return try RemoteEnvironmentProtocol.decode(Response.self, from: raw) }
            catch { throw RemoteEnvironmentClientError(.invalidResponse) }
        } catch {
            if generation == owned {
                if let failure = error as? JSONRPCRemoteError, failure.code == -32_003,
                   let value = failure.data["kind"].string, let kind = RemoteAttachmentFailure.Kind(rawValue: value) {
                    throw RemoteAttachmentFailure(kind)
                }
                if let failure = workspaceRejection(error) { throw failure }
                if let failure = nativeRejection(error) { throw failure }
                retire(error as? RemoteEnvironmentClientError ?? .init(.disconnected))
            }
            if mutating { throw RemoteAttachmentFailure(.uncertain) }
            throw error as? RemoteEnvironmentClientError ?? RemoteEnvironmentClientError(.disconnected)
        }
    }
    private static func validateUploadRequest(_ request: RemoteAttachmentUploadRequest) throws {
        guard request.byteCount >= 0, request.byteCount <= AttachmentLimits.fileBytes,
              !request.name.isEmpty, request.name.utf8.count <= 1_024,
              !request.name.unicodeScalars.contains(where: { $0.value < 32 || $0.value == 127 }),
              isTerminalDigest(request.digest) else { throw RemoteAttachmentFailure(.invalidRequest) }
    }
    private static func validateUpload(_ value: RemoteAttachmentUpload, request: RemoteAttachmentUploadRequest) throws {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        let chunks = (request.byteCount + RemoteAttachmentProtocol.maximumChunkBytes - 1) / RemoteAttachmentProtocol.maximumChunkBytes
        guard try encoder.encode(value.request) == encoder.encode(request),
              value.receivedChunks.count <= chunks, Set(value.receivedChunks).count == value.receivedChunks.count,
              value.receivedChunks.allSatisfy({ $0 >= 0 && $0 < chunks }) else { throw RemoteEnvironmentClientError(.invalidResponse) }
        switch value.state {
        case .receiving, .finalizing:
            guard value.attachment == nil, value.failure == nil else { throw RemoteEnvironmentClientError(.invalidResponse) }
        case .ready, .claimed:
            guard let attachment = value.attachment, value.failure == nil, value.receivedChunks.count == chunks else {
                throw RemoteEnvironmentClientError(.invalidResponse)
            }
            try AttachmentLimits.validate([attachment])
        case .cancelled:
            guard value.attachment == nil else { throw RemoteEnvironmentClientError(.invalidResponse) }
        case .failed, .uncertain:
            guard value.failure != nil else { throw RemoteEnvironmentClientError(.invalidResponse) }
            if let attachment = value.attachment { try AttachmentLimits.validate([attachment]) }
        }
    }
    public func bindWorkspace(_ target: RemoteWorkspaceTarget) async throws -> RemoteWorkspaceTarget {
        let owned = generation
        let result: RemoteWorkspaceTarget = try await workspaceRequest(RemoteEnvironmentProtocol.workspaceBindMethod,
            request: target, environmentID: target.environmentID)
        try validateWorkspaceResponse(generation: owned) {
            guard Self.sameWorkspace(result, target), result.rootID != nil,
                  target.rootID == nil || target.rootID == result.rootID else { throw RemoteEnvironmentClientError(.invalidResponse) }
        }
        return result
    }
    public func worktreeCatalog(target: RemoteWorkspaceTarget) async throws -> RemoteWorktreeCatalog {
        _ = try context()
        guard descriptor?.capabilities.supportsRemoteWorktrees == true else { throw RemoteEnvironmentClientError(.unsupported) }
        let owned = generation
        let result: RemoteWorktreeCatalog = try await workspaceRequest(RemoteEnvironmentProtocol.worktreeCatalogMethod,
            request: RemoteWorktreeCatalogRequest(target: target), environmentID: target.environmentID)
        try validateWorkspaceResponse(generation: owned) {
            guard Self.sameWorkspace(result.target, target), result.target.configuration == target.configuration,
                  result.target.rootID == target.rootID,
                  result.branches.count <= 10_000, result.worktrees.count <= 10_000,
                  Set(result.branches.map { Data($0.ref.utf8) }).count == result.branches.count,
                  Set(result.worktrees.map { Data($0.path.utf8) }).count == result.worktrees.count else {
                throw RemoteEnvironmentClientError(.invalidResponse)
            }
            try WorktreeValidation.path(result.sourcePath)
            for branch in result.branches {
                guard branch.ref.hasPrefix("refs/heads/") else { throw RemoteEnvironmentClientError(.invalidResponse) }
                try WorktreeValidation.branch(branch.name)
            }
            for worktree in result.worktrees {
                try WorktreeValidation.path(worktree.path)
                guard !worktree.isBare, !worktree.isDetached, worktree.prunableReason == nil,
                      let branch = worktree.branch, let head = worktree.headCommit,
                      [40, 64].contains(head.utf8.count), head.utf8.allSatisfy({ (48...57).contains($0) || (65...70).contains($0) || (97...102).contains($0) }) else {
                    throw RemoteEnvironmentClientError(.invalidResponse)
                }
                try WorktreeValidation.branch(branch)
            }
        }
        return result
    }
    public func readWorkspace(_ request: RemoteWorkspaceReadRequest) async throws -> RemoteWorkspaceReadResult {
        guard request.target.rootID != nil else { throw RemoteWorkspaceFailure(.invalidTarget) }
        let owned = generation
        let result: RemoteWorkspaceReadResult = try await workspaceRequest(RemoteEnvironmentProtocol.workspaceReadMethod,
            request: request, environmentID: request.target.environmentID)
        try validateWorkspaceResponse(generation: owned) {
            guard Self.sameWorkspace(result.target, request.target), result.target.rootID == request.target.rootID else {
                throw RemoteEnvironmentClientError(.invalidResponse)
            }
            switch (request.query, result.value) {
            case (.list, .entries), (.searchPaths, .entries), (.searchContents, .contents),
                 (.gitDiff, .diff), (.gitBranches, .branches), (.gitRemotes, .remotes): break
            case (.gitStatus, .git(let snapshot)):
                guard snapshot.repositoryRoot.isFileURL, snapshot.repositoryRoot.path.utf8.elementsEqual(request.target.workspacePath.utf8) else {
                    throw RemoteEnvironmentClientError(.invalidResponse)
                }
            case (.readFile(let path, let allowMissing, let maximum), .document(let document)):
                guard path.utf8.elementsEqual(document.relativePath.utf8), document.byteLength >= 0,
                      document.contents.utf8.count <= min(2_000_000, maximum),
                      document.exists || allowMissing,
                      !document.exists || document.truncated || document.revision != nil else {
                    throw RemoteEnvironmentClientError(.invalidResponse)
                }
            default: throw RemoteEnvironmentClientError(.invalidResponse)
            }
        }
        return result
    }
    public func beginWorkspaceOperation(_ request: RemoteWorkspaceMutationRequest) async throws -> RemoteWorkspaceOperation {
        guard request.target.rootID != nil else { throw RemoteWorkspaceFailure(.invalidTarget) }
        _ = try context()
        guard !attemptedWorkspaceOperations.contains(request.id) else {
            throw RemoteEnvironmentClientError(.commandAlreadyAttempted, commandID: request.id)
        }
        guard attemptedWorkspaceOperations.count < 4_096 else { throw RemoteEnvironmentClientError(.limitExceeded) }
        _ = try RemoteWorkspaceJournal.payload(request)
        attemptedWorkspaceOperations.insert(request.id)
        let owned = generation
        let result: RemoteWorkspaceOperation = try await workspaceRequest(RemoteEnvironmentProtocol.workspaceBeginMethod,
            request: request, environmentID: request.target.environmentID, uncertainID: request.id)
        do { try validateWorkspaceResponse(generation: owned) { try validateWorkspaceOperation(result, request: request) } }
        catch { throw RemoteEnvironmentClientError(.commandUncertain, commandID: request.id) }
        return result
    }
    /// Lookup consumes this identity locally too: recovery cannot accidentally
    /// turn a nil result into permission to begin the old request again.
    public func workspaceOperation(_ request: RemoteWorkspaceMutationRequest) async throws -> RemoteWorkspaceOperation? {
        try recordWorkspaceAttempt(request)
        let owned = generation
        let result: RemoteWorkspaceOperation? = try await workspaceRequest(RemoteEnvironmentProtocol.workspaceOperationMethod,
            request: request, environmentID: request.target.environmentID)
        if let result { try validateWorkspaceResponse(generation: owned) { try validateWorkspaceOperation(result, request: request) } }
        return result
    }
    public func cancelWorkspaceOperation(_ request: RemoteWorkspaceMutationRequest) async throws -> RemoteWorkspaceOperation? {
        try recordWorkspaceAttempt(request)
        let owned = generation
        let result: RemoteWorkspaceOperation? = try await workspaceRequest(RemoteEnvironmentProtocol.workspaceCancelMethod,
            request: request, environmentID: request.target.environmentID)
        if let result { try validateWorkspaceResponse(generation: owned) { try validateWorkspaceOperation(result, request: request) } }
        return result
    }
    private func recordWorkspaceAttempt(_ request: RemoteWorkspaceMutationRequest) throws {
        guard attemptedWorkspaceOperations.count < 4_096 || attemptedWorkspaceOperations.contains(request.id) else {
            throw RemoteEnvironmentClientError(.limitExceeded)
        }
        _ = try RemoteWorkspaceJournal.payload(request)
        attemptedWorkspaceOperations.insert(request.id)
    }
    public func openTerminal(_ request: RemoteTerminalOpenRequest) async throws -> RemoteTerminalSnapshot {
        try terminalContext(request.target)
        try Self.validateTerminalSize(cols: request.cols, rows: request.rows)
        guard !attemptedTerminalOpens.contains(request.id) else {
            throw RemoteEnvironmentClientError(.commandAlreadyAttempted, commandID: request.id)
        }
        guard attemptedTerminalOpens.count < 4_096 else { throw RemoteEnvironmentClientError(.limitExceeded) }
        attemptedTerminalOpens.insert(request.id)
        let owned = generation
        let result: RemoteTerminalSnapshot = try await terminalRequest(RemoteEnvironmentProtocol.terminalOpenMethod,
            request: request, target: request.target, uncertainID: request.id)
        do {
            try validateWorkspaceResponse(generation: owned) {
                try Self.validateTerminalSnapshot(result, target: request.target)
                guard result.reference.terminalID == request.terminalID else { throw RemoteEnvironmentClientError(.invalidResponse) }
            }
        } catch { throw RemoteEnvironmentClientError(.commandUncertain, commandID: request.id) }
        return result
    }
    public func attachTerminal(_ reference: RemoteTerminalReference) async throws -> RemoteTerminalSnapshot {
        let owned = generation
        let result: RemoteTerminalSnapshot = try await terminalRequest(RemoteEnvironmentProtocol.terminalAttachMethod,
            request: reference, target: reference.target)
        try validateWorkspaceResponse(generation: owned) { try Self.validateTerminalSnapshot(result, reference: reference) }
        return result
    }
    public func listTerminals(_ target: RemoteWorkspaceTarget) async throws -> [RemoteTerminalSnapshot] {
        let owned = generation
        let result: [RemoteTerminalSnapshot] = try await terminalRequest(RemoteEnvironmentProtocol.terminalListMethod,
            request: target, target: target)
        try validateWorkspaceResponse(generation: owned) {
            guard result.count <= 4_096, Set(result.map(\.id)).count == result.count else { throw RemoteEnvironmentClientError(.invalidResponse) }
            for snapshot in result { try Self.validateTerminalSnapshot(snapshot, target: target) }
        }
        return result
    }
    public func readTerminal(_ request: RemoteTerminalReadRequest) async throws -> RemoteTerminalReadResult {
        guard request.afterSequence >= 0, (1...65_536).contains(request.maxBytes) else { throw RemoteTerminalFailure(.invalidRequest) }
        let owned = generation
        let result: RemoteTerminalReadResult = try await terminalRequest(RemoteEnvironmentProtocol.terminalReadMethod,
            request: request, target: request.reference.target)
        try validateWorkspaceResponse(generation: owned) {
            try Self.validateTerminalSnapshot(result.snapshot, reference: request.reference)
            guard result.data.count <= request.maxBytes, result.startSequence >= 0,
                  result.nextSequence >= result.startSequence,
                  result.nextSequence - result.startSequence == Int64(result.data.count),
                  result.nextSequence <= result.snapshot.outputSequence else { throw RemoteEnvironmentClientError(.invalidResponse) }
            if result.snapshot.state == .lost {
                guard result.gap, result.data.isEmpty, result.startSequence == 0, result.nextSequence == 0,
                      result.snapshot.outputSequence == 0, result.snapshot.inputHalted else { throw RemoteEnvironmentClientError(.invalidResponse) }
            } else if result.gap {
                guard result.startSequence == result.snapshot.retainedStartSequence,
                      result.startSequence > request.afterSequence else { throw RemoteEnvironmentClientError(.invalidResponse) }
            } else {
                guard result.startSequence == request.afterSequence,
                      result.startSequence >= result.snapshot.retainedStartSequence else { throw RemoteEnvironmentClientError(.invalidResponse) }
            }
        }
        return result
    }
    /// An attempt consumes its sequence before suspension. Only a receipt lookup
    /// may follow an uncertain write; reconnect never grants permission to resend.
    public func writeTerminal(_ request: RemoteTerminalInputRequest) async throws -> RemoteTerminalInputReceipt {
        try terminalContext(request.reference.target)
        let incarnation = request.reference.incarnation
        guard request.sequence > 0, request.sequence < Int64.max, !request.data.isEmpty,
              request.data.count <= 65_536 else { throw RemoteTerminalFailure(.invalidRequest) }
        guard !haltedTerminalInputs.contains(incarnation) else { throw RemoteTerminalFailure(.inputUncertain) }
        guard !terminalInputInFlight.contains(incarnation) else { throw RemoteTerminalFailure(.busy) }
        guard request.sequence > (terminalInputAttempts[incarnation] ?? 0) else { throw RemoteTerminalFailure(.inputExpired) }
        guard terminalInputAttempts[incarnation] != nil || terminalInputAttempts.count < 4_096 else {
            throw RemoteEnvironmentClientError(.limitExceeded)
        }
        terminalInputAttempts[incarnation] = request.sequence
        terminalInputInFlight.insert(incarnation)
        defer { terminalInputInFlight.remove(incarnation) }
        let owned = generation, digest = RemoteTerminalProtocol.inputDigest(request.data)
        do {
            let result: RemoteTerminalInputReceipt = try await terminalRequest(RemoteEnvironmentProtocol.terminalWriteMethod,
                request: request, target: request.reference.target)
            try validateWorkspaceResponse(generation: owned) {
                try Self.validateTerminalReceipt(result, reference: request.reference, sequence: request.sequence, digest: digest)
                guard result.byteCount == request.data.count else { throw RemoteEnvironmentClientError(.invalidResponse) }
            }
            if result.state != .delivered { haltedTerminalInputs.insert(incarnation) }
            return result
        } catch {
            haltedTerminalInputs.insert(incarnation)
            if let failure = error as? RemoteTerminalFailure { throw failure }
            throw RemoteTerminalFailure(.inputUncertain)
        }
    }
    public func terminalInputReceipt(_ request: RemoteTerminalInputReceiptRequest) async throws -> RemoteTerminalInputReceipt? {
        guard request.sequence > 0, Self.isTerminalDigest(request.digest) else { throw RemoteTerminalFailure(.invalidRequest) }
        let incarnation = request.reference.incarnation
        guard terminalInputAttempts[incarnation] != nil || terminalInputAttempts.count < 4_096 else {
            throw RemoteEnvironmentClientError(.limitExceeded)
        }
        terminalInputAttempts[incarnation] = max(terminalInputAttempts[incarnation] ?? 0, request.sequence)
        // Recovery is read-only even when lookup itself loses its response.
        // A subsequent connection must not turn that loss into writable state.
        haltedTerminalInputs.insert(incarnation)
        let owned = generation
        let result: RemoteTerminalInputReceipt? = try await terminalRequest(RemoteEnvironmentProtocol.terminalInputReceiptMethod,
            request: request, target: request.reference.target)
        if let result {
            try validateWorkspaceResponse(generation: owned) {
                try Self.validateTerminalReceipt(result, reference: request.reference, sequence: request.sequence, digest: request.digest)
            }
        }
        // A lookup cannot prove that a lost write never ran, including nil.
        if result?.state != .delivered { haltedTerminalInputs.insert(incarnation) }
        return result
    }
    public func resizeTerminal(_ request: RemoteTerminalResizeRequest) async throws -> RemoteTerminalSnapshot {
        try Self.validateTerminalSize(cols: request.cols, rows: request.rows)
        let owned = generation
        let result: RemoteTerminalSnapshot = try await terminalRequest(RemoteEnvironmentProtocol.terminalResizeMethod,
            request: request, target: request.reference.target)
        try validateWorkspaceResponse(generation: owned) {
            try Self.validateTerminalSnapshot(result, reference: request.reference)
            guard result.cols == request.cols, result.rows == request.rows else { throw RemoteEnvironmentClientError(.invalidResponse) }
        }
        return result
    }
    public func closeTerminal(_ reference: RemoteTerminalReference) async throws -> RemoteTerminalSnapshot {
        let owned = generation
        let result: RemoteTerminalSnapshot = try await terminalRequest(RemoteEnvironmentProtocol.terminalCloseMethod,
            request: reference, target: reference.target)
        try validateWorkspaceResponse(generation: owned) {
            try Self.validateTerminalSnapshot(result, reference: reference)
            guard [.exited, .failed, .lost].contains(result.state) else { throw RemoteEnvironmentClientError(.invalidResponse) }
        }
        return result
    }
    private func terminalContext(_ target: RemoteWorkspaceTarget) throws {
        let (_, _, environment) = try context()
        guard environment == target.environmentID else { throw RemoteEnvironmentClientError(.wrongEnvironment) }
        guard target.rootID != nil else { throw RemoteTerminalFailure(.invalidTarget) }
        guard descriptor?.capabilities.supportsRemoteTerminal == true else { throw RemoteEnvironmentClientError(.unsupported) }
    }
    private func terminalRequest<Request: Encodable & Sendable, Response: Decodable & Sendable>(
        _ method: String, request: Request, target: RemoteWorkspaceTarget, uncertainID: UUID? = nil
    ) async throws -> Response {
        try terminalContext(target)
        let (connection, owned, _) = try context()
        let bytes = try JSONEncoder().encode(request)
        guard bytes.count <= RemoteEnvironmentProtocol.maximumRequestBytes,
              activeRequests < RemoteEnvironmentProtocol.maximumPendingRequests,
              activeWorkspaceBytes + bytes.count <= RemoteEnvironmentProtocol.maximumQueuedRequestBytes else {
            throw RemoteEnvironmentClientError(.limitExceeded)
        }
        activeRequests += 1; activeWorkspaceBytes += bytes.count
        defer { activeRequests -= 1; activeWorkspaceBytes -= bytes.count }
        do {
            let raw = try await connection.request(method, params: JSONDecoder().decode(JSONValue.self, from: bytes), timeout: .seconds(30))
            guard generation == owned, rpc != nil else { throw CancellationError() }
            do { return try RemoteEnvironmentProtocol.decode(Response.self, from: raw) }
            catch { throw RemoteEnvironmentClientError(.invalidResponse) }
        } catch {
            if generation == owned {
                if let failure = error as? JSONRPCRemoteError, failure.code == -32_002,
                   let value = failure.data["kind"].string, let kind = RemoteTerminalFailure.Kind(rawValue: value) {
                    throw RemoteTerminalFailure(kind)
                }
                if let rejection = workspaceRejection(error) { throw rejection }
                if let rejection = nativeRejection(error) { throw rejection }
                retire(error as? RemoteEnvironmentClientError ?? .init(.disconnected))
            }
            if let uncertainID { throw RemoteEnvironmentClientError(.commandUncertain, commandID: uncertainID) }
            throw error as? RemoteEnvironmentClientError ?? RemoteEnvironmentClientError(.disconnected)
        }
    }
    private static func validateTerminalSize(cols: Int, rows: Int) throws {
        guard (1...1_000).contains(cols), (1...500).contains(rows) else { throw RemoteTerminalFailure(.invalidRequest) }
    }
    private static func isTerminalDigest(_ value: String) -> Bool {
        value.utf8.count == 64 && value.utf8.allSatisfy { (48...57).contains($0) || (97...102).contains($0) }
    }
    private static func sameTerminal(_ lhs: RemoteTerminalReference, _ rhs: RemoteTerminalReference) -> Bool {
        sameWorkspace(lhs.target, rhs.target) && lhs.target.rootID == rhs.target.rootID &&
            lhs.terminalID == rhs.terminalID && lhs.incarnation == rhs.incarnation
    }
    private static func validateTerminalSnapshot(_ value: RemoteTerminalSnapshot, reference: RemoteTerminalReference) throws {
        try validateTerminalSnapshot(value, target: reference.target)
        guard sameTerminal(value.reference, reference) else { throw RemoteEnvironmentClientError(.invalidResponse) }
    }
    private static func validateTerminalSnapshot(_ value: RemoteTerminalSnapshot, target: RemoteWorkspaceTarget) throws {
        guard sameWorkspace(value.reference.target, target), value.reference.target.rootID == target.rootID,
              target.rootID != nil, (1...1_000).contains(value.cols), (1...500).contains(value.rows),
              value.outputSequence >= 0, value.retainedStartSequence >= 0,
              value.outputSequence >= value.retainedStartSequence,
              value.outputSequence - value.retainedStartSequence <= 512 * 1_024,
              value.nextInputSequence > 0,
              (value.nextInputSequence == 1 ? value.inputDigest.isEmpty : isTerminalDigest(value.inputDigest)),
              value.exitCode == nil || [.closing, .exited, .failed].contains(value.state),
              value.exitSignal == nil || [.closing, .exited, .failed].contains(value.state) else {
            throw RemoteEnvironmentClientError(.invalidResponse)
        }
    }
    private static func validateTerminalReceipt(_ value: RemoteTerminalInputReceipt, reference: RemoteTerminalReference,
        sequence: Int64, digest: String) throws {
        guard sameTerminal(value.reference, reference), value.sequence == sequence, value.digest == digest,
              (1...65_536).contains(value.byteCount), isTerminalDigest(value.inputDigest) else {
            throw RemoteEnvironmentClientError(.invalidResponse)
        }
    }
    private func workspaceRequest<Request: Encodable & Sendable, Response: Decodable & Sendable>(
        _ method: String, request: Request, environmentID: UUID, uncertainID: UUID? = nil
    ) async throws -> Response {
        let (connection, owned, environment) = try context()
        guard environment == environmentID else { throw RemoteEnvironmentClientError(.wrongEnvironment) }
        guard descriptor?.capabilities.supportsWorkspaceFilesAndGit == true else { throw RemoteEnvironmentClientError(.unsupported) }
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        let bytes = try encoder.encode(request)
        guard bytes.count <= RemoteEnvironmentProtocol.maximumWorkspaceRequestBytes,
              activeRequests < RemoteEnvironmentProtocol.maximumPendingRequests,
              activeWorkspaceBytes + bytes.count <= RemoteEnvironmentProtocol.maximumQueuedRequestBytes else {
            throw RemoteEnvironmentClientError(.limitExceeded)
        }
        activeRequests += 1; activeWorkspaceBytes += bytes.count
        defer { activeRequests -= 1; activeWorkspaceBytes -= bytes.count }
        do {
            let raw = try await connection.request(method, params: JSONDecoder().decode(JSONValue.self, from: bytes), timeout: .seconds(30))
            guard generation == owned, rpc != nil else { throw CancellationError() }
            return try RemoteEnvironmentProtocol.decode(Response.self, from: raw)
        } catch {
            if generation == owned, let rejection = workspaceRejection(error) { throw rejection }
            if generation == owned, let rejection = nativeRejection(error) { throw rejection }
            let safe = error as? RemoteEnvironmentClientError ?? .init(.disconnected)
            if generation == owned { retire(safe) }
            if let uncertainID { throw RemoteEnvironmentClientError(.commandUncertain, commandID: uncertainID) }
            throw safe
        }
    }
    private func workspaceRejection(_ error: any Error) -> RemoteWorkspaceFailure? {
        guard let rpcError = error as? JSONRPCRemoteError, rpcError.code == -32_001,
              let value = rpcError.data["kind"].string, let kind = RemoteWorkspaceFailure.Kind(rawValue: value) else { return nil }
        return RemoteWorkspaceFailure(kind)
    }
    private func validateWorkspaceResponse(generation owned: UUID, _ body: () throws -> Void) throws {
        guard generation == owned, rpc != nil, !closed else { throw RemoteEnvironmentClientError(.disconnected) }
        do { try body() }
        catch {
            let safe = RemoteEnvironmentClientError(.invalidResponse)
            retire(safe); throw safe
        }
    }
    private func validateWorkspaceOperation(_ operation: RemoteWorkspaceOperation, request: RemoteWorkspaceMutationRequest) throws {
        guard try RemoteWorkspaceJournal.payload(operation.request) == RemoteWorkspaceJournal.payload(request),
              operation.payloadDigest == (try RemoteWorkspaceJournal.digest(request)),
              operation.createdAt.timeIntervalSince1970.isFinite, operation.updatedAt.timeIntervalSince1970.isFinite,
              operation.updatedAt >= operation.createdAt else { throw RemoteEnvironmentClientError(.invalidResponse) }
        switch operation.state {
        case .accepted, .running:
            guard operation.result == nil, operation.failure == nil else { throw RemoteEnvironmentClientError(.invalidResponse) }
        case .finished:
            guard (operation.result != nil) != (operation.failure != nil) else { throw RemoteEnvironmentClientError(.invalidResponse) }
            if let result = operation.result {
                switch request.mutation {
                case .createFile(let path, let text), .saveFile(let path, let text, _):
                    guard case .document(let document) = result, document.relativePath.utf8.elementsEqual(path.utf8),
                          document.contents.utf8.elementsEqual(text.utf8), document.exists, !document.truncated,
                          document.revision != nil, document.byteLength == text.utf8.count else { throw RemoteEnvironmentClientError(.invalidResponse) }
                default:
                    guard case .git(let snapshot) = result, snapshot.repositoryRoot.isFileURL,
                          snapshot.repositoryRoot.path.utf8.elementsEqual(request.target.workspacePath.utf8) else {
                        throw RemoteEnvironmentClientError(.invalidResponse)
                    }
                }
            }
        case .uncertain:
            guard operation.result == nil, operation.failure != nil else { throw RemoteEnvironmentClientError(.invalidResponse) }
        }
    }
    private static func sameWorkspace(_ lhs: RemoteWorkspaceTarget, _ rhs: RemoteWorkspaceTarget) -> Bool {
        lhs.environmentID == rhs.environmentID && lhs.projectID == rhs.projectID && lhs.threadID == rhs.threadID
            && lhs.workspacePath.utf8.elementsEqual(rhs.workspacePath.utf8)
    }
    public func reconnect() async throws -> RemoteEnvironmentSnapshot {
        guard !closed else { throw RemoteEnvironmentClientError(.closed) }
        retire(.init(.disconnected), notify: false, graceful: true)
        let owned = generation, cleanup = Array(drains.values)
        for task in cleanup { await task.value }
        guard !closed, generation == owned else { throw CancellationError() }
        return try await connect()
    }
    public func close() async {
        if let closeTask { await closeTask.value; return }
        closed = true; retire(.init(.closed), notify: false, graceful: true)
        let owned = Array(drains.values), continuation = continuation
        let task = Task {
            for cleanup in owned { await cleanup.value }
            continuation.finish()
        }
        closeTask = task; await task.value
    }
    private func acceptDescriptor(_ value: RemoteEnvironmentDescriptor, generation owned: UUID) throws {
        guard !closed, generation == owned, rpc != nil else { throw CancellationError() }
        guard value.protocolVersion == RemoteEnvironmentProtocol.version,
              value.capabilities.providers.count <= ProviderKind.allCases.count,
              Set(value.capabilities.providers).count == value.capabilities.providers.count else { throw RemoteEnvironmentClientError(.unsupported) }
        do { try SkillValidation.text(value.label, maximum: 256, empty: false) }
        catch { throw RemoteEnvironmentClientError(.invalidResponse) }
        guard expectedID == nil || expectedID == value.environmentID else { throw RemoteEnvironmentClientError(.wrongEnvironment) }
        descriptor = value; continuation.yield(.descriptor(value))
    }
    private func context(requireConnected: Bool = true) throws -> (JSONRPCConnection, UUID, UUID) {
        guard !closed else { throw RemoteEnvironmentClientError(.closed) }
        guard let rpc, let descriptor else { throw RemoteEnvironmentClientError(.disconnected) }
        guard let expectedID, expectedID == descriptor.environmentID else { throw RemoteEnvironmentClientError(.trustRequired) }
        guard !requireConnected || connected else { throw RemoteEnvironmentClientError(.disconnected) }
        return (rpc, generation, expectedID)
    }
    private func requestSnapshot(_ method: String, connection: JSONRPCConnection, generation owned: UUID, environmentID: UUID) async throws -> RemoteEnvironmentSnapshot {
        guard activeRequests < RemoteEnvironmentProtocol.maximumPendingRequests else { throw RemoteEnvironmentClientError(.limitExceeded) }
        activeRequests += 1; defer { activeRequests -= 1 }
        do {
            let raw = try await connection.request(method, params: RemoteEnvironmentProtocol.encode(
                RemoteEnvironmentSnapshotRequest(environmentID: environmentID, afterSequence: latest?.sequence)), timeout: .seconds(30))
            let value = try RemoteEnvironmentProtocol.decode(RemoteEnvironmentSnapshot.self, from: raw)
            guard generation == owned, rpc != nil else { throw CancellationError() }
            try acceptSnapshot(value)
            return latest ?? value
        } catch {
            let safe = error as? RemoteEnvironmentClientError ?? RemoteEnvironmentClientError(.disconnected)
            if generation == owned { retire(safe) }
            throw safe
        }
    }
    private func acceptSnapshot(_ value: RemoteEnvironmentSnapshot) throws {
        guard value.environmentID == expectedID else { throw RemoteEnvironmentClientError(.wrongEnvironment) }
        guard value.sequence >= 0 else { throw RemoteEnvironmentClientError(.invalidResponse) }
        guard value.sequence >= sequenceFloor else { throw RemoteEnvironmentClientError(.sequenceRegression) }
        try WorkspaceJournal.validate(value.workspace)
        if let latest {
            if value.sequence < latest.sequence { return }
            if value.sequence == latest.sequence {
                guard value.workspace == latest.workspace else { throw RemoteEnvironmentClientError(.invalidResponse) }
                return
            }
        }
        latest = value; continuation.yield(.snapshot(value))
    }
    private func validateReceipt(_ receipt: WorkspaceCommandReceipt, environmentID: UUID, commandID: UUID) throws {
        guard environmentID == expectedID else { throw RemoteEnvironmentClientError(.wrongEnvironment) }
        guard receipt.commandID == commandID, receipt.sequence >= 0, receipt.eventCount >= 0,
              receipt.acceptedAt.timeIntervalSince1970.isFinite,
              receipt.rejection.map({ $0.utf8.count <= 4_096 }) ?? true else { throw RemoteEnvironmentClientError(.invalidResponse) }
        if projectionMode {
            sequenceFloor = max(sequenceFloor, receipt.sequence)
            latestProjectionSequence = max(latestProjectionSequence ?? 0, receipt.sequence)
        }
    }
    private func nativeRejection(_ error: any Error) -> RemoteEnvironmentError? {
        guard let error = error as? JSONRPCRemoteError, error.code == -32_000,
              let raw = error.data["kind"].string, let kind = RemoteEnvironmentError.Kind(rawValue: raw),
              kind != .wrongEnvironment, kind != .identityInvalid else { return nil }
        // A v1 typed admission/collision refusal is a known response on a live
        // transport. Never expose its arbitrary wire message or replay it.
        return RemoteEnvironmentError(kind)
    }
    private func consume(_ event: RPCEvent, connection: JSONRPCConnection, generation owned: UUID) async {
        switch event {
        case .callback(let work): await work()
        case .barrier(let complete): complete()
        default:
            guard generation == owned, rpc != nil, !closed else { return }
            switch event {
            case .notification(let method, let params) where method == RemoteProjectionProtocol.changedNotification:
                guard projectionMode, expectedID != nil, connected || subscribing else { return }
                do { try acceptProjectionInvalidation(RemoteEnvironmentProtocol.decode(RemoteProjectionInvalidation.self, from: params)) }
                catch { retire(error as? RemoteEnvironmentClientError ?? .init(.invalidResponse)) }
            case .notification(let method, let params) where method == RemoteEnvironmentProtocol.snapshotNotification:
                guard !projectionMode, expectedID != nil, connected || subscribing else { return }
                do { try acceptSnapshot(RemoteEnvironmentProtocol.decode(RemoteEnvironmentSnapshot.self, from: params)) }
                catch { retire(error as? RemoteEnvironmentClientError ?? .init(.invalidResponse)) }
            case .request: retire(.init(.invalidResponse))
            case .disconnected: retire(.init(.disconnected))
            default: break
            }
        }
    }
    private func retire(_ error: RemoteEnvironmentClientError, notify: Bool = true, graceful: Bool = false) {
        pullRequestRepositories.removeAll()
        projectionMode = false; projectionHostID = nil; latestProjectionBinding = nil
        projectionCursors.removeAll(); projectionReplies.removeAll()
        let gracefulEnvironment = graceful && connected && descriptor?.environmentID == expectedID ? expectedID : nil
        generation = UUID(); connected = false; subscribing = false
        descriptor = nil; discovery?.cancel(); discovery = nil
        if let connection = rpc {
            let reading = reader, id = UUID()
            rpc = nil; reader = nil
            let task = Task { [weak self] in
                if let gracefulEnvironment {
                    // The v1 helper acknowledges only after its engine/providers
                    // drain. A failed/expired close still joins this exact child.
                    _ = try? await connection.request(RemoteEnvironmentProtocol.closeMethod,
                        params: RemoteEnvironmentProtocol.encode(RemoteEnvironmentSnapshotRequest(environmentID: gracefulEnvironment)), timeout: .seconds(10))
                }
                await connection.close(); await reading?.value
                await self?.finishedDrain(id)
            }
            drains[id] = task
        }
        if notify, !closed { continuation.yield(.disconnected(error)) }
    }
    private func finishedDrain(_ id: UUID) { drains.removeValue(forKey: id) }
    deinit { discovery?.cancel(); reader?.cancel(); continuation.finish() }
}

extension RemoteEnvironmentClient {
    public func connectProjection() async throws -> RemoteProjectionBinding {
        let described = try await discover()
        guard expectedID == described.environmentID else { throw RemoteEnvironmentClientError(.trustRequired) }
        guard described.capabilities.supportsBoundedProjections else { throw RemoteEnvironmentClientError(.unsupported) }
        let owned = generation, floor = sequenceFloor
        projectionMode = true; subscribing = true
        do {
            let request = RemoteProjectionOpenRequest(environmentID: described.environmentID, scope: .catalog, minimumSequence: floor)
            let result: RemoteProjectionBinding = try await projectionRequest(RemoteProjectionProtocol.subscribeMethod, request: request, requireConnected: false)
            guard result.environmentID == described.environmentID else {
                retire(.init(.wrongEnvironment)); throw RemoteEnvironmentClientError(.wrongEnvironment)
            }
            try validateWorkspaceResponse(generation: owned) { try validateProjectionBinding(result, scope: .catalog, minimum: floor) }
            subscribing = false; connected = true
            rememberProjection(result)
            return result
        } catch {
            if generation == owned { subscribing = false; retire(error as? RemoteEnvironmentClientError ?? .init(.disconnected)) }
            throw error
        }
    }
    public func reconnectProjection() async throws -> RemoteProjectionBinding {
        guard !closed else { throw RemoteEnvironmentClientError(.closed) }
        retire(.init(.disconnected), notify: false, graceful: true)
        let owned = generation, cleanup = Array(drains.values)
        for task in cleanup { await task.value }
        guard !closed, generation == owned else { throw CancellationError() }
        return try await connectProjection()
    }
    public func openProjection(scope: RemoteProjectionScope, minimumSequence: Int64? = nil) async throws -> RemoteProjectionBinding {
        let (_, owned, environment) = try context()
        let floor = max(sequenceFloor, minimumSequence ?? 0)
        guard minimumSequence.map({ $0 >= 0 }) ?? true else { throw RemoteProjectionFailure(.invalidRequest) }
        let result: RemoteProjectionBinding = try await projectionRequest(RemoteProjectionProtocol.openMethod,
            request: RemoteProjectionOpenRequest(environmentID: environment, scope: scope, minimumSequence: floor))
        guard result.environmentID == environment else {
            retire(.init(.wrongEnvironment)); throw RemoteEnvironmentClientError(.wrongEnvironment)
        }
        try validateWorkspaceResponse(generation: owned) { try validateProjectionBinding(result, scope: scope, minimum: floor) }
        rememberProjection(result)
        return result
    }
    public func projectionCatalog(_ request: RemoteProjectionCatalogRequest) async throws -> RemoteProjectionCatalogResult {
        try validateProjectionRequest(request.binding)
        guard request.binding.scope == .catalog else { throw RemoteProjectionFailure(.invalidRequest) }
        let owned = generation
        let expectation = try projectionPageRead(method: RemoteProjectionProtocol.catalogMethod, normalized: RemoteProjectionCatalogRequest(binding: request.binding, query: request.query), request: request,
            binding: request.binding, cursor: request.cursor)
        let result: RemoteProjectionCatalogResult = try await projectionRequest(RemoteProjectionProtocol.catalogMethod, request: request)
        try validateWorkspaceResponse(generation: owned) {
            switch (request.query, result) {
            case (.projects, .projects(let page)):
                try finishProjectionPage(page, expectation: expectation)
                for item in page.items { try Self.validateProjectSummary(item) }
            case (.threads(let project, let archived), .threads(let page)):
                try finishProjectionPage(page, expectation: expectation)
                for item in page.items {
                    try Self.validateThreadSummary(item)
                    guard project == nil || item.projectID == project, archived || !item.isArchived else { throw RemoteEnvironmentClientError(.invalidResponse) }
                }
            default: throw RemoteEnvironmentClientError(.invalidResponse)
            }
        }
        return result
    }
    public func projectionThread(_ request: RemoteProjectionThreadRequest) async throws -> RemoteProjectionThreadResult {
        try validateProjectionRequest(request.binding, threadID: request.threadID)
        let owned = generation
        let result: RemoteProjectionThreadResult = try await projectionRequest(RemoteProjectionProtocol.threadMethod, request: request)
        try validateWorkspaceResponse(generation: owned) {
            guard try Self.sameProjectionBinding(result.binding, request.binding), result.thread.summary.id == request.threadID else { throw RemoteEnvironmentClientError(.invalidResponse) }
            try Self.validateThreadSummary(result.thread.summary)
            try Self.validateProjectionReference(result.thread.configuration, kind: .configuration)
            try Self.validateProjectionReference(result.thread.draftAttachments, kind: .attachmentReferences)
            try Self.validateProjectionReference(result.thread.runtimeRequests, kind: .runtimeRequests)
            try Self.validateProjectionText(result.thread.draft, kind: .draft)
            guard result.thread.requestCount >= 0,
                  result.thread.activeRun.map({ $0.startedAt.timeIntervalSince1970.isFinite && ($0.runtimeID == nil || $0.runtimeID == result.thread.runtimeID) }) ?? true else { throw RemoteEnvironmentClientError(.invalidResponse) }
            for value in [result.thread.submit, result.thread.resumeQueue, result.thread.mutateFiles, result.thread.openTerminal, result.thread.chooseWorktree] { try Self.validateProjectionAvailability(value) }
            if let banner = result.thread.checkpointBanner {
                try Self.validateProjectionAttempt(banner.attempt)
                guard banner.stage == banner.attempt.stage, banner.title.utf8.count <= 2_048, banner.detail.utf8.count <= 8_192,
                      !(banner.canRetry || banner.canContinue) || (banner.stage == .postRun && [.failed, .interrupted].contains(banner.attempt.phase)) else { throw RemoteEnvironmentClientError(.invalidResponse) }
            }
            if let preparation = result.thread.preparation {
                try ProviderHistoryValidation.path(preparation.sourcePath); try ProviderHistoryValidation.path(preparation.destinationPath)
                if let error = preparation.error { try Self.validateProjectionText(error) }
                for warning in preparation.warnings { try Self.validateProjectionText(warning) }
            }
        }
        return result
    }
    public func projectionMessages(_ request: RemoteProjectionMessagesRequest) async throws -> RemoteProjectionMessagesResult {
        try validateProjectionRequest(request.binding, threadID: request.threadID, requiresHistory: true)
        let owned = generation
        let expectation = try projectionPageRead(method: RemoteProjectionProtocol.messagesMethod, normalized: RemoteProjectionMessagesRequest(binding: request.binding, threadID: request.threadID, newestFirst: request.newestFirst), request: request,
            binding: request.binding, cursor: request.cursor)
        let result: RemoteProjectionMessagesResult = try await projectionRequest(RemoteProjectionProtocol.messagesMethod, request: request)
        try validateWorkspaceResponse(generation: owned) {
            try finishProjectionPage(result, expectation: expectation)
            for item in result.items {
                try ProviderHistoryValidation.id(item.id)
                guard item.createdAt.timeIntervalSince1970.isFinite, item.attachmentCount >= 0 else { throw RemoteEnvironmentClientError(.invalidResponse) }
                try Self.validateProjectionText(item.text)
                if let attachments = item.attachments { try Self.validateProjectionReference(attachments, kind: .attachmentReferences) }
                guard item.attachmentCount == 0 || item.attachments != nil else { throw RemoteEnvironmentClientError(.invalidResponse) }
                if let error = item.submissionError { try Self.validateProjectionText(error) }
                if let title = item.title { try Self.validateProjectionText(title) }
                if let status = item.status { try Self.validateProjectionText(status) }
            }
        }
        return result
    }
    public func projectionRuns(_ request: RemoteProjectionRunsRequest) async throws -> RemoteProjectionRunsResult {
        try validateProjectionRequest(request.binding, threadID: request.threadID, requiresHistory: true)
        let owned = generation
        let expectation = try projectionPageRead(method: RemoteProjectionProtocol.runsMethod, normalized: RemoteProjectionRunsRequest(binding: request.binding, threadID: request.threadID), request: request,
            binding: request.binding, cursor: request.cursor)
        let result: RemoteProjectionRunsResult = try await projectionRequest(RemoteProjectionProtocol.runsMethod, request: request)
        try validateWorkspaceResponse(generation: owned) {
            try finishProjectionPage(result, expectation: expectation)
            for item in result.items {
                guard item.startedAt.timeIntervalSince1970.isFinite, item.endedAt.map({ $0.timeIntervalSince1970.isFinite }) ?? true,
                      item.turnCount >= 0, item.checkpointAttemptCount >= item.checkpointAttempts.count,
                      Set(item.checkpointAttempts.map(\.id)).count == item.checkpointAttempts.count,
                      item.checkpointAttemptsComplete == (item.checkpointAttemptCount == item.checkpointAttempts.count),
                      item.checkpointAttemptsComplete || item.checkpointAttemptsContent != nil else { throw RemoteEnvironmentClientError(.invalidResponse) }
                try ProviderHistoryValidation.path(item.workspacePath)
                try Self.validateProjectionText(item.model)
                if let reference = item.configuration { try Self.validateProjectionReference(reference, kind: .configuration) }
                if let reference = item.checkpointAttemptsContent { try Self.validateProjectionReference(reference, kind: .checkpointAttempts) }
                for attempt in item.checkpointAttempts { try Self.validateProjectionAttempt(attempt) }
                for availability in [item.checkpointDiff, item.fork, item.rewind] { try Self.validateProjectionAvailability(availability) }
            }
        }
        return result
    }
    public func projectionOperations(_ request: RemoteProjectionOperationsRequest) async throws -> RemoteProjectionOperationsResult {
        try validateProjectionRequest(request.binding, threadID: request.threadID)
        let owned = generation
        let expectation = try projectionPageRead(method: RemoteProjectionProtocol.operationsMethod, normalized: RemoteProjectionOperationsRequest(binding: request.binding, threadID: request.threadID), request: request,
            binding: request.binding, cursor: request.cursor)
        let result: RemoteProjectionOperationsResult = try await projectionRequest(RemoteProjectionProtocol.operationsMethod, request: request)
        try validateWorkspaceResponse(generation: owned) {
            try finishProjectionPage(result, expectation: expectation)
            for item in result.items {
                guard !item.phase.isEmpty, item.phase.utf8.count <= 64, item.updatedAt.timeIntervalSince1970.isFinite,
                      Self.isTerminalDigest(item.fingerprint), item.actions.count <= 32,
                      item.actions.keys.allSatisfy({ !$0.isEmpty && $0.utf8.count <= 64 }) else { throw RemoteEnvironmentClientError(.invalidResponse) }
                try Self.validateProjectionText(item.title)
                let phaseValid: Bool
                switch item.kind {
                case .conversationHistory: phaseValid = ConversationHistoryPhase(rawValue: item.phase) != nil
                case .checkpointRestore: phaseValid = RunCheckpointRestorePhase(rawValue: item.phase) != nil
                case .pullRequestCreation: phaseValid = PullRequestCreationPhase(rawValue: item.phase) != nil
                case .pullRequestCheckout: phaseValid = PullRequestCheckoutPhase(rawValue: item.phase) != nil
                case .promptSteering: phaseValid = PromptSteeringPhase(rawValue: item.phase) != nil
                case .worktreePreparation: phaseValid = ThreadWorkspacePreparationPhase(rawValue: item.phase) != nil
                case .settlement: phaseValid = ThreadSettlementPhase(rawValue: item.phase) != nil
                case .projectClone: phaseValid = ProjectClonePhase(rawValue: item.phase) != nil
                }
                guard phaseValid else { throw RemoteEnvironmentClientError(.invalidResponse) }
                for path in item.workspacePaths { try ProviderHistoryValidation.path(path) }
                for detail in item.details {
                    guard !detail.label.isEmpty, detail.label.utf8.count <= 512 else { throw RemoteEnvironmentClientError(.invalidResponse) }
                    try Self.validateProjectionText(detail.value)
                }
                for warning in item.warnings { try Self.validateProjectionText(warning) }
                if let reference = item.pullRequest { try reference.validate() }
                if let url = item.url {
                    guard let reference = item.pullRequest, GitHubValidation.pullRequestURL(url, reference: reference) else { throw RemoteEnvironmentClientError(.invalidResponse) }
                }
                if let error = item.error { try Self.validateProjectionText(error) }
                for action in item.actions.values { try Self.validateProjectionAvailability(action) }
            }
        }
        return result
    }
    public func projectionContent(_ request: RemoteProjectionContentRequest) async throws -> RemoteProjectionContentResult {
        try validateProjectionRequest(request.binding)
        try Self.validateProjectionReference(request.reference)
        guard request.offset >= 0, request.offset <= request.reference.totalBytes,
              request.offset == 0 || request.cursor != nil else { throw RemoteProjectionFailure(.invalidRequest) }
        let owned = generation
        let expectation = try projectionPageRead(method: RemoteProjectionProtocol.contentMethod,
            normalized: RemoteProjectionContentRequest(binding: request.binding, reference: request.reference), request: request,
            binding: request.binding, cursor: request.cursor)
        guard request.offset == expectation.offset, expectation.total == nil || expectation.total == request.reference.totalBytes else { throw RemoteProjectionFailure(.invalidRequest) }
        let result: RemoteProjectionContentResult = try await projectionRequest(RemoteProjectionProtocol.contentMethod, request: request)
        try validateWorkspaceResponse(generation: owned) {
            guard try Self.sameProjectionBinding(result.binding, request.binding),
                  try RemoteProjectionProtocol.payload(result.reference) == RemoteProjectionProtocol.payload(request.reference),
                  result.offset == request.offset, result.data.count <= RemoteProjectionProtocol.maximumContentChunkBytes,
                  result.data.count <= request.reference.totalBytes - request.offset,
                  result.complete == (request.offset + result.data.count == request.reference.totalBytes),
                  result.complete == (result.nextCursor == nil), result.complete || !result.data.isEmpty,
                  result.nextCursor == nil || result.nextCursor != request.cursor else { throw RemoteEnvironmentClientError(.invalidResponse) }
            let digest = RemoteProjectionProtocol.digest(try RemoteProjectionProtocol.payload(result))
            if let previous = projectionReplies[expectation.requestKey] {
                guard previous.viewID == result.binding.viewID, previous.digest == digest else { throw RemoteEnvironmentClientError(.invalidResponse) }
            }
            if let next = result.nextCursor {
                let claim = ProjectionCursorClaim(query: expectation.query, viewID: result.binding.viewID,
                    offset: result.offset + result.data.count, total: result.reference.totalBytes)
                guard projectionCursors[next] == nil || projectionCursors[next] == claim else { throw RemoteEnvironmentClientError(.invalidResponse) }
                guard projectionCursors[next] != nil || projectionCursors.count < 4_096 else { throw RemoteEnvironmentClientError(.limitExceeded) }
                projectionCursors[next] = claim
            }
            projectionReplies[expectation.requestKey] = (result.binding.viewID, digest)
        }
        return result
    }
    public func projectionDocument(_ reference: RemoteProjectionContentReference, binding: RemoteProjectionBinding,
                                   maximumBytes: Int = 32 * 1_024 * 1_024) async throws -> Data {
        guard maximumBytes >= 0, maximumBytes <= RemoteProjectionProtocol.maximumCacheBytes,
              reference.totalBytes <= maximumBytes else { throw RemoteEnvironmentClientError(.limitExceeded) }
        var bytes = Data(), cursor: UUID?, seen = Set<UUID>()
        let owned = generation
        repeat {
            try Task.checkCancellation()
            let page = try await projectionContent(.init(binding: binding, reference: reference, offset: bytes.count, cursor: cursor))
            guard generation == owned else { throw CancellationError() }
            bytes.append(page.data)
            if let next = page.nextCursor {
                guard seen.insert(next).inserted else { retire(.init(.invalidResponse)); throw RemoteEnvironmentClientError(.invalidResponse) }
            }
            cursor = page.nextCursor
        } while cursor != nil
        guard bytes.count == reference.totalBytes, RemoteProjectionProtocol.digest(bytes) == reference.digest else {
            retire(.init(.invalidResponse)); throw RemoteEnvironmentClientError(.invalidResponse)
        }
        return bytes
    }
    public func projectionRelease(_ request: RemoteProjectionReleaseRequest) async throws -> RemoteProjectionReleaseResult {
        try validateProjectionRequest(request.binding)
        let owned = generation
        let result: RemoteProjectionReleaseResult = try await projectionRequest(RemoteProjectionProtocol.releaseMethod, request: request)
        try validateWorkspaceResponse(generation: owned) {
            guard try Self.sameProjectionBinding(result.binding, request.binding) else { throw RemoteEnvironmentClientError(.invalidResponse) }
        }
        projectionCursors = projectionCursors.filter { $0.value.viewID != request.binding.viewID }
        projectionReplies = projectionReplies.filter { $0.value.viewID != request.binding.viewID }
        if latestProjectionBinding?.viewID == request.binding.viewID { latestProjectionBinding = nil }
        return result
    }
    private func projectionRequest<Request: Encodable & Sendable, Response: Decodable & Sendable>(
        _ method: String, request: Request, requireConnected: Bool = true
    ) async throws -> Response {
        let (connection, owned, _) = try context(requireConnected: requireConnected)
        guard descriptor?.capabilities.supportsBoundedProjections == true else { throw RemoteEnvironmentClientError(.unsupported) }
        let bytes = try RemoteProjectionProtocol.payload(request)
        guard bytes.count <= RemoteEnvironmentProtocol.maximumRequestBytes, activeRequests < RemoteEnvironmentProtocol.maximumPendingRequests,
              activeWorkspaceBytes + bytes.count <= RemoteEnvironmentProtocol.maximumQueuedRequestBytes else { throw RemoteEnvironmentClientError(.limitExceeded) }
        activeRequests += 1; activeWorkspaceBytes += bytes.count
        defer { activeRequests -= 1; activeWorkspaceBytes -= bytes.count }
        do {
            let raw = try await connection.request(method, params: JSONDecoder().decode(JSONValue.self, from: bytes), timeout: .seconds(120))
            guard generation == owned, rpc != nil else { throw CancellationError() }
            guard try RemoteProjectionProtocol.payload(raw).count <= RemoteProjectionProtocol.maximumResultBytes else { throw RemoteEnvironmentClientError(.invalidResponse) }
            do { return try RemoteEnvironmentProtocol.decode(Response.self, from: raw) }
            catch { throw RemoteEnvironmentClientError(.invalidResponse) }
        } catch {
            if generation == owned {
                if let failure = error as? JSONRPCRemoteError, failure.code == -32_006,
                   let value = failure.data["kind"].string, let kind = RemoteProjectionFailure.Kind(rawValue: value) {
                    if kind == .wrongEnvironment { retire(.init(.wrongEnvironment)); throw RemoteEnvironmentClientError(.wrongEnvironment) }
                    throw RemoteProjectionFailure(kind)
                }
                if let failure = workspaceRejection(error) { throw failure }
                if let failure = nativeRejection(error) { throw failure }
                retire(error as? RemoteEnvironmentClientError ?? .init(.disconnected))
            }
            throw error as? RemoteEnvironmentClientError ?? RemoteEnvironmentClientError(.disconnected)
        }
    }
    private func validateProjectionBinding(_ value: RemoteProjectionBinding, scope: RemoteProjectionScope, minimum: Int64) throws {
        guard value.environmentID == expectedID else { throw RemoteEnvironmentClientError(.wrongEnvironment) }
        guard value.sequence >= minimum, value.scope == scope, Self.isTerminalDigest(value.fingerprint),
              projectionHostID == nil || projectionHostID == value.hostID else { throw RemoteEnvironmentClientError(.invalidResponse) }
    }
    private func rememberProjection(_ value: RemoteProjectionBinding) {
        projectionHostID = value.hostID; latestProjectionBinding = value
        latestProjectionSequence = max(latestProjectionSequence ?? 0, value.sequence)
        sequenceFloor = max(sequenceFloor, value.sequence)
    }
    private func acceptProjectionInvalidation(_ value: RemoteProjectionInvalidation) throws {
        guard value.environmentID == expectedID else { throw RemoteEnvironmentClientError(.wrongEnvironment) }
        guard value.sequence >= 0, projectionHostID == nil || projectionHostID == value.hostID else { throw RemoteEnvironmentClientError(.invalidResponse) }
        // These are coalesced invalidation hints, not snapshot attestations.
        // A hint captured before a concurrently received command receipt can
        // arrive late; a fresh open still enforces the captured sequence floor.
        projectionHostID = value.hostID
        guard value.sequence >= (latestProjectionSequence ?? 0) else { return }
        latestProjectionSequence = value.sequence
        sequenceFloor = max(sequenceFloor, value.sequence)
        continuation.yield(.projectionChanged(value))
    }
    private func validateProjectionRequest(_ binding: RemoteProjectionBinding, threadID: UUID? = nil, requiresHistory: Bool = false) throws {
        guard binding.environmentID == expectedID else { throw RemoteEnvironmentClientError(.wrongEnvironment) }
        guard binding.sequence >= 0, Self.isTerminalDigest(binding.fingerprint), projectionHostID == nil || projectionHostID == binding.hostID else { throw RemoteProjectionFailure(.staleView) }
        switch binding.scope {
        case .catalog: if threadID != nil || requiresHistory { throw RemoteProjectionFailure(.invalidRequest) }
        case .thread(let id): guard threadID == nil || threadID == id else { throw RemoteProjectionFailure(.invalidRequest) }
        case .control(let id): guard !requiresHistory, threadID == nil || threadID == id else { throw RemoteProjectionFailure(.invalidRequest) }
        }
    }
    private func projectionPageRead<Normalized: Encodable, Request: Encodable>(
        method: String, normalized: Normalized, request: Request, binding: RemoteProjectionBinding, cursor: UUID?
    ) throws -> ProjectionPageRead {
        let query = Data(SHA256.hash(data: Data(method.utf8) + (try RemoteProjectionProtocol.payload(normalized))))
        let key = Data(SHA256.hash(data: Data(method.utf8) + (try RemoteProjectionProtocol.payload(request))))
        guard projectionReplies[key] != nil || projectionReplies.count < 4_096 else { throw RemoteEnvironmentClientError(.limitExceeded) }
        if let cursor {
            guard let claim = projectionCursors[cursor], claim.query == query, claim.viewID == binding.viewID else { throw RemoteProjectionFailure(.invalidRequest) }
            return .init(query: query, requestKey: key, binding: binding, cursor: cursor, offset: claim.offset, total: claim.total)
        }
        return .init(query: query, requestKey: key, binding: binding, cursor: nil, offset: 0, total: nil)
    }
    private func finishProjectionPage<Item: Codable & Sendable & Equatable & Identifiable>(
        _ page: RemoteProjectionPage<Item>, expectation: ProjectionPageRead
    ) throws {
        try Self.validateProjectionPage(page, binding: expectation.binding, first: expectation.cursor == nil)
        guard page.offset == expectation.offset, expectation.total == nil || page.totalCount == expectation.total,
              page.nextCursor == nil || page.nextCursor != expectation.cursor else { throw RemoteEnvironmentClientError(.invalidResponse) }
        let digest = RemoteProjectionProtocol.digest(try RemoteProjectionProtocol.payload(page))
        if let previous = projectionReplies[expectation.requestKey] {
            guard previous.viewID == page.binding.viewID, previous.digest == digest else { throw RemoteEnvironmentClientError(.invalidResponse) }
        }
        if let next = page.nextCursor {
            let claim = ProjectionCursorClaim(query: expectation.query, viewID: page.binding.viewID,
                offset: page.offset + page.items.count, total: page.totalCount)
            guard projectionCursors[next] == nil || projectionCursors[next] == claim else { throw RemoteEnvironmentClientError(.invalidResponse) }
            guard projectionCursors[next] != nil || projectionCursors.count < 4_096 else { throw RemoteEnvironmentClientError(.limitExceeded) }
            projectionCursors[next] = claim
        }
        projectionReplies[expectation.requestKey] = (page.binding.viewID, digest)
    }
    private static func sameProjectionBinding(_ first: RemoteProjectionBinding, _ second: RemoteProjectionBinding) throws -> Bool {
        try RemoteProjectionProtocol.payload(first) == RemoteProjectionProtocol.payload(second)
    }
    private static func validateProjectionPage<Item: Codable & Sendable & Equatable & Identifiable>(
        _ page: RemoteProjectionPage<Item>, binding: RemoteProjectionBinding, first: Bool
    ) throws {
        guard try sameProjectionBinding(page.binding, binding), page.offset >= 0, page.totalCount >= 0,
              !first || page.offset == 0, page.offset <= page.totalCount, page.items.count <= page.totalCount - page.offset,
              Set(page.items.map(\.id)).count == page.items.count,
              page.complete == (page.offset + page.items.count == page.totalCount), page.complete == (page.nextCursor == nil),
              page.complete || !page.items.isEmpty else { throw RemoteEnvironmentClientError(.invalidResponse) }
    }
    private static func validateProjectionReference(_ value: RemoteProjectionContentReference, kind: RemoteProjectionContentKind? = nil) throws {
        guard value.totalBytes >= 0, value.totalBytes <= RemoteProjectionProtocol.maximumCacheBytes,
              isTerminalDigest(value.digest), kind == nil || value.kind == kind else { throw RemoteEnvironmentClientError(.invalidResponse) }
    }
    private static func validateProjectionText(_ value: RemoteProjectionText, kind: RemoteProjectionContentKind = .text) throws {
        guard value.preview.utf8.count <= 65_536, value.complete || value.content != nil else { throw RemoteEnvironmentClientError(.invalidResponse) }
        if let reference = value.content {
            try validateProjectionReference(reference, kind: kind)
            guard value.preview.utf8.count <= reference.totalBytes else { throw RemoteEnvironmentClientError(.invalidResponse) }
            if value.complete { guard value.preview.utf8.count == reference.totalBytes, RemoteProjectionProtocol.digest(Data(value.preview.utf8)) == reference.digest else { throw RemoteEnvironmentClientError(.invalidResponse) } }
        }
    }
    private static func validateProjectionAvailability(_ value: RemoteProjectionAvailability) throws {
        guard value.reason.map({ !$0.isEmpty && $0.utf8.count <= 8_192 && !$0.contains("\0") }) ?? true,
              !value.allowed || value.reason == nil else { throw RemoteEnvironmentClientError(.invalidResponse) }
    }
    private static func validateProjectSummary(_ value: RemoteProjectSummary) throws {
        try ProviderHistoryValidation.path(value.workspacePath); try validateProjectionText(value.name)
        if let error = value.cloneError { try validateProjectionText(error) }
        guard value.createdAt.map({ $0.timeIntervalSince1970.isFinite }) ?? true,
              value.updatedAt.map({ $0.timeIntervalSince1970.isFinite }) ?? true else { throw RemoteEnvironmentClientError(.invalidResponse) }
    }
    private static func validateThreadSummary(_ value: RemoteThreadSummary) throws {
        try ProviderHistoryValidation.path(value.workspacePath); try validateProjectionText(value.title); try validateProjectionText(value.model)
        guard value.createdAt.timeIntervalSince1970.isFinite, value.updatedAt.timeIntervalSince1970.isFinite,
              value.providerName.utf8.count <= 512, value.messageCount >= 0, value.runCount >= 0, value.queueCount >= 0 else { throw RemoteEnvironmentClientError(.invalidResponse) }
    }
    private static func validateProjectionAttempt(_ value: RemoteCheckpointAttemptSummary) throws {
        try ProviderHistoryValidation.path(value.workspacePath)
        guard value.requestedAt.timeIntervalSince1970.isFinite, value.updatedAt.timeIntervalSince1970.isFinite,
              isTerminalDigest(value.digest), value.hasReceipt == (value.phase == .ready) else { throw RemoteEnvironmentClientError(.invalidResponse) }
        try validateProjectionAvailability(value.restore)
        if let error = value.error { try validateProjectionText(error) }
        if let warning = value.cleanupWarning { try validateProjectionText(warning) }
    }
}
