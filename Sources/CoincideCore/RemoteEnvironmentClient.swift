import Foundation

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
    private var sequenceFloor: Int64 = 0
    private var connected = false
    private var subscribing = false
    private var closed = false
    private var closeTask: Task<Void, Never>?
    private var drains: [UUID: Task<Void, Never>] = [:]
    private var attemptedCommands: Set<UUID> = []
    private var activeRequests = 0

    public init(factory: @escaping ConnectionFactory, expectedEnvironmentID: UUID? = nil) {
        (events, continuation) = AsyncStream.makeStream(bufferingPolicy: .bufferingNewest(8))
        self.factory = factory; expectedID = expectedEnvironmentID
    }
    public func currentDescriptor() -> RemoteEnvironmentDescriptor? { descriptor }
    public func currentSnapshot() -> RemoteEnvironmentSnapshot? { latest }
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
        let (connection, owned, environment) = try context()
        return try await requestSnapshot(RemoteEnvironmentProtocol.snapshotMethod, connection: connection, generation: owned, environmentID: environment)
    }
    public func command(_ command: RemoteEnvironmentCommand, id: UUID = UUID()) async throws -> RemoteEnvironmentCommandResult {
        let (connection, owned, environment) = try context()
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
            let raw = try await connection.request(RemoteEnvironmentProtocol.commandMethod, params: payload, timeout: .seconds(45))
            let result = try RemoteEnvironmentProtocol.decode(RemoteEnvironmentCommandResult.self, from: raw)
            guard generation == owned, rpc != nil else { throw CancellationError() }
            try validateReceipt(result.receipt, environmentID: result.environmentID, commandID: id)
            return result
        } catch {
            // Even a transport timeout/cancellation can follow a durable commit.
            // The caller's private pending journal owns exact receipt recovery.
            if generation == owned, nativeRejection(error) == nil { retire(error as? RemoteEnvironmentClientError ?? .init(.disconnected)) }
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
                params: JSONDecoder().decode(JSONValue.self, from: bytes), timeout: .seconds(30))
            let result = try RemoteEnvironmentProtocol.decode(RemoteEnvironmentReceiptResult.self, from: raw)
            guard generation == owned, rpc != nil else { throw CancellationError() }
            guard result.environmentID == environment else { throw RemoteEnvironmentClientError(.wrongEnvironment) }
            if let receipt = result.receipt { try validateReceipt(receipt, environmentID: result.environmentID, commandID: id) }
            return result
        } catch {
            if let rejection = nativeRejection(error), generation == owned { throw rejection }
            let safe = error as? RemoteEnvironmentClientError ?? RemoteEnvironmentClientError(.disconnected)
            if generation == owned { retire(safe) }
            throw safe
        }
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
            case .notification(let method, let params) where method == RemoteEnvironmentProtocol.snapshotNotification:
                guard expectedID != nil, connected || subscribing else { return }
                do { try acceptSnapshot(RemoteEnvironmentProtocol.decode(RemoteEnvironmentSnapshot.self, from: params)) }
                catch { retire(error as? RemoteEnvironmentClientError ?? .init(.invalidResponse)) }
            case .request: retire(.init(.invalidResponse))
            case .disconnected: retire(.init(.disconnected))
            default: break
            }
        }
    }
    private func retire(_ error: RemoteEnvironmentClientError, notify: Bool = true, graceful: Bool = false) {
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
