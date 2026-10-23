import Foundation

/// These server-only identities are captured inside the Engine actor. They are
/// prepared host data, never decoded from a client's command payload.
struct RemoteLifecycleNativeState: Codable, Sendable {
    private struct Payload: Codable, Sendable {
        let target: RemoteWorkspaceTarget
        let projectIncarnation, threadIncarnation: UUID
        let lifecycle: ThreadWorkspaceLifecycle?
        let settlementID: UUID?
        let settlementPhase: ThreadSettlementPhase?
        let settle, resume, snooze, wake: RemoteProjectionAvailability
    }
    private let storage: [Payload]
    var target: RemoteWorkspaceTarget { storage[0].target }
    var projectIncarnation: UUID { storage[0].projectIncarnation }
    var threadIncarnation: UUID { storage[0].threadIncarnation }
    var lifecycle: ThreadWorkspaceLifecycle? { storage[0].lifecycle }
    var settlementID: UUID? { storage[0].settlementID }
    var settlementPhase: ThreadSettlementPhase? { storage[0].settlementPhase }
    var settle: RemoteProjectionAvailability { storage[0].settle }
    var resume: RemoteProjectionAvailability { storage[0].resume }
    var snooze: RemoteProjectionAvailability { storage[0].snooze }
    var wake: RemoteProjectionAvailability { storage[0].wake }
    init(target: RemoteWorkspaceTarget, projectIncarnation: UUID, threadIncarnation: UUID, lifecycle: ThreadWorkspaceLifecycle?,
         settlementID: UUID?, settlementPhase: ThreadSettlementPhase?, settle: RemoteProjectionAvailability,
         resume: RemoteProjectionAvailability, snooze: RemoteProjectionAvailability, wake: RemoteProjectionAvailability) {
        storage = [.init(target: target, projectIncarnation: projectIncarnation, threadIncarnation: threadIncarnation,
            lifecycle: lifecycle, settlementID: settlementID, settlementPhase: settlementPhase, settle: settle, resume: resume, snooze: snooze, wake: wake)]
    }
    init(from decoder: any Decoder) throws { storage = [try Payload(from: decoder)] }
    func encode(to encoder: any Encoder) throws { try storage[0].encode(to: encoder) }
    func exposed(_ capture: RemoteLifecycleCapture) -> RemoteLifecycleThreadState {
        let missingRoot = RemoteProjectionAvailability(allowed: false, reason: "Reopen this remote workspace before settling or resuming it.")
        return .init(capture: capture, lifecycle: lifecycle, settlementID: settlementID, settlementPhase: settlementPhase,
            settle: target.rootID == nil ? missingRoot : settle, resume: target.rootID == nil ? missingRoot : resume, snooze: snooze, wake: wake)
    }
}

struct RemoteLifecycleNativeRead: Sendable {
    let sequence: Int64
    let policy: WorkspaceLifecyclePolicy
    let state: RemoteLifecycleNativeState?
    init(sequence: Int64, policy: WorkspaceLifecyclePolicy, state: RemoteLifecycleNativeState? = nil) {
        self.sequence = sequence; self.policy = policy; self.state = state
    }
}

struct RemoteLifecyclePreparation: Codable, Sendable {
    enum Action: Codable, Sendable {
        case thread(RemoteLifecycleNativeState, RemoteLifecycleCapture, RemoteLifecycleAction)
        case policy(WorkspaceLifecyclePolicy, expected: WorkspaceLifecyclePolicy)
    }
    let action: Action
    var target: RemoteWorkspaceTarget? { if case .thread(let state, _, _) = action { state.target } else { nil } }
    var requiresBoundRoot: Bool { if case .thread(_, _, let value) = action { value.requiresBoundRoot } else { false } }
}

actor RemoteLifecycleService {
    typealias Read = @Sendable (RemoteWorkspaceTarget?) async throws -> RemoteLifecycleNativeRead
    typealias Bind = @Sendable (RemoteWorkspaceTarget) async throws -> RemoteWorkspaceTarget
    private struct Claim { let capture: RemoteLifecycleCapture; let native: RemoteLifecycleNativeState; let bytes: Int }
    private let environmentID: UUID
    private let readNative: Read
    private let bindRoot: Bind
    private var claims: [UUID: Claim] = [:]
    private var order: [UUID] = []
    private var retainedBytes = 0
    private var closing = false
    init(environmentID: UUID, read: @escaping Read, bind: @escaping Bind) {
        self.environmentID = environmentID; readNative = read; bindRoot = bind
    }
    init(environmentID: UUID, engine: WorkspaceEngine, workspace: RemoteWorkspaceService) {
        self.environmentID = environmentID
        readNative = { try await engine.readRemoteLifecycle($0) }
        bindRoot = { try await workspace.bindCheckpointTarget($0) }
    }
    func read(_ request: RemoteLifecycleReadRequest) async throws -> RemoteLifecycleReadResult {
        guard request.environmentID == environmentID, request.target.map({ $0.environmentID == environmentID }) ?? true else { throw RemoteLifecycleFailure(.invalidTarget) }
        guard !closing else { throw RemoteLifecycleFailure(.unavailable) }
        var target = request.target
        if let requested = target {
            // Attention controls remain usable if a checkout is missing or held.
            // Physical actions still require the host-issued bound root below.
            do { target = try await bindRoot(requested) }
            catch is CancellationError { throw CancellationError() }
            catch { target = .init(environmentID: requested.environmentID, projectID: requested.projectID,
                threadID: requested.threadID, configuration: requested.configuration) }
        }
        let native = try await readNative(target)
        guard !closing else { throw RemoteLifecycleFailure(.unavailable) }
        guard native.sequence >= 0 else { throw RemoteLifecycleFailure(.invalidRequest) }
        try native.policy.validate()
        let state: RemoteLifecycleThreadState?
        if let value = native.state, let target {
            guard RemoteLifecycleProtocol.same(value.target, target) else { throw RemoteLifecycleFailure(.invalidTarget) }
            let id = UUID(), bytes = try RemoteLifecycleProtocol.payload(value)
            guard bytes.count <= RemoteLifecycleProtocol.maximumResultBytes else { throw RemoteLifecycleFailure(.limitExceeded) }
            let capture = RemoteLifecycleCapture(id: id, digest: RemoteProjectionProtocol.digest(bytes), target: target)
            while order.count >= 64 || retainedBytes + bytes.count > 2 * 1_024 * 1_024 {
                guard !order.isEmpty else { throw RemoteLifecycleFailure(.limitExceeded) }
                let oldest = order.removeFirst(); if let old = claims.removeValue(forKey: oldest) { retainedBytes -= old.bytes }
            }
            claims[id] = .init(capture: capture, native: value, bytes: bytes.count); order.append(id); retainedBytes += bytes.count
            state = value.exposed(capture)
        } else {
            guard target == nil, native.state == nil else { throw RemoteLifecycleFailure(.invalidTarget) }
            state = nil
        }
        let result = RemoteLifecycleReadResult(environmentID: environmentID, sequence: native.sequence, policy: native.policy, thread: state)
        guard try RemoteLifecycleProtocol.payload(result).count <= RemoteLifecycleProtocol.maximumResultBytes else { throw RemoteLifecycleFailure(.limitExceeded) }
        return result
    }
    func prepare(_ capture: RemoteLifecycleCapture, action: RemoteLifecycleAction) throws -> RemoteLifecyclePreparation {
        guard !closing else { throw RemoteLifecycleFailure(.unavailable) }
        guard capture.target.environmentID == environmentID else { throw RemoteLifecycleFailure(.invalidTarget) }
        guard let claim = claims[capture.id], RemoteLifecycleProtocol.same(claim.capture, capture) else { throw RemoteLifecycleFailure(.staleCapture) }
        if action.requiresBoundRoot, capture.target.rootID == nil { throw RemoteLifecycleFailure(.invalidTarget) }
        switch action {
        case .settleReviewingScript, .settleWithoutScript: guard claim.native.settle.allowed else { throw RemoteLifecycleFailure(.busy) }
        case .resume(let id): guard id == claim.native.settlementID, claim.native.resume.allowed else { throw RemoteLifecycleFailure(.staleCapture) }
        case .snooze(let until):
            guard until.timeIntervalSince1970.isFinite, until > Date() else { throw RemoteLifecycleFailure(.invalidRequest) }
            guard claim.native.snooze.allowed else { throw RemoteLifecycleFailure(.busy) }
        case .wake: guard claim.native.wake.allowed else { throw RemoteLifecycleFailure(.staleCapture) }
        case .setAutoSettle: break
        }
        return .init(action: .thread(claim.native, claim.capture, action))
    }
    func preparePolicy(_ policy: WorkspaceLifecyclePolicy, expected: WorkspaceLifecyclePolicy) throws -> RemoteLifecyclePreparation {
        guard !closing else { throw RemoteLifecycleFailure(.unavailable) }
        do { try policy.validate(); try expected.validate() } catch { throw RemoteLifecycleFailure(.invalidRequest) }
        return .init(action: .policy(policy, expected: expected))
    }
    func close() { closing = true; claims = [:]; order = []; retainedBytes = 0 }
}
