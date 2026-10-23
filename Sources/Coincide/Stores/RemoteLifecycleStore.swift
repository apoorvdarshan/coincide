import CoincideCore
import Foundation
import Observation

struct RemoteLifecycleTransport: Sendable {
    var read: @Sendable (RemoteLifecycleReadRequest) async throws -> RemoteLifecycleReadResult
    static func live(_ client: RemoteEnvironmentClient) -> Self { .init(read: { try await client.readLifecycle($0) }) }
}

/// All commands use the retained environment's original-ID pending journal.
/// This controller owns only metadata reads and joins explicit control work;
/// closing a sheet never cancels an accepted Stop/Resume/settlement admission.
@MainActor @Observable
final class RemoteLifecycleStore {
    typealias Perform = @MainActor @Sendable (RemoteEnvironmentCommand) async -> Bool
    private(set) var environmentID: UUID?
    private(set) var target: RemoteWorkspaceTarget?
    private(set) var state: RemoteLifecycleThreadState?
    private(set) var policy: WorkspaceLifecyclePolicy?
    private(set) var isLoading = false
    private(set) var isActing = false
    private(set) var connected = false
    private(set) var supported = false
    private(set) var writesAllowed = false
    private(set) var errorMessage: String?
    private(set) var notice: String?
    @ObservationIgnored private var transport: RemoteLifecycleTransport?
    @ObservationIgnored private var perform: Perform?
    @ObservationIgnored private var generation = UUID()
    @ObservationIgnored private var readID = UUID()
    @ObservationIgnored private var reads: [UUID: Task<RemoteLifecycleReadResult, any Error>] = [:]
    @ObservationIgnored private var controls: [UUID: Task<Bool, Never>] = [:]
    @ObservationIgnored private var sequence: Int64 = -1
    @ObservationIgnored private var closed = false
    var canRead: Bool { connected && supported && transport != nil && !closed }
    var canAct: Bool { canRead && writesAllowed && !isActing && !isLoading }
    var unavailableMessage: String? {
        if !supported { return "Update CoincideEnvironment on the remote Mac to enable conversation lifecycle controls." }
        if !connected { return "Reconnect to change this remote conversation or its automatic settlement policy." }
        if !writesAllowed { return "Check the current remote request's result before starting another action. Nothing is repeated automatically." }
        return nil
    }
    func update(environmentID: UUID?, target: RemoteWorkspaceTarget?, transport: RemoteLifecycleTransport?, supported: Bool,
                canWrite: Bool, perform: @escaping Perform) {
        let changed = self.environmentID != environmentID || !RemoteLifecycleProtocol.same(self.target, target)
        if changed { retireReads(); state = nil; notice = nil; errorMessage = nil }
        if self.environmentID != environmentID { policy = nil; sequence = -1 }
        self.environmentID = environmentID; self.target = target; self.transport = transport
        self.supported = supported; connected = transport != nil; writesAllowed = canWrite; self.perform = perform
        if transport == nil { retireReads() }
    }
    func refresh() async {
        guard canRead, let environmentID, let transport else { return }
        let owner = generation, id = UUID(), requested = target
        for task in reads.values { task.cancel() }
        readID = id; isLoading = true; errorMessage = nil
        let task = Task { try await transport.read(.init(environmentID: environmentID, target: requested)) }
        reads[id] = task
        defer {
            reads.removeValue(forKey: id)
            if generation == owner && readID == id { isLoading = false }
        }
        do {
            let result = try await withTaskCancellationHandler { try await task.value } onCancel: { task.cancel() }
            try Task.checkCancellation()
            guard generation == owner, readID == id, !closed else { return }
            guard result.environmentID == environmentID, result.sequence >= sequence,
                  Self.matches(result.thread?.capture.target, requested: requested) else { throw RemoteLifecycleFailure(.invalidTarget) }
            try result.policy.validate()
            if let value = result.thread {
                guard RemoteLifecycleProtocol.validDigest(value.capture.digest),
                      (value.settlementID == nil) == (value.settlementPhase == nil),
                      value.settlementID != nil || !value.resume.allowed else { throw RemoteLifecycleFailure(.invalidRequest) }
                try value.lifecycle?.validate()
            }
            state = result.thread; policy = result.policy; sequence = result.sequence
        } catch is CancellationError { }
        catch { if generation == owner && readID == id && !closed { errorMessage = error.localizedDescription } }
    }
    func settleWithoutScript(capture: RemoteLifecycleCapture) async -> Bool { await act(.settleWithoutScript, capture: capture) }
    func settleReviewingScript(capture: RemoteLifecycleCapture) async -> Bool { await act(.settleReviewingScript, capture: capture) }
    func resume(capture: RemoteLifecycleCapture) async -> Bool {
        guard let id = state?.settlementID else { return false }
        return await act(.resume(generationID: id), capture: capture)
    }
    func snooze(until: Date, capture: RemoteLifecycleCapture) async -> Bool { await act(.snooze(until: until), capture: capture) }
    func wake(capture: RemoteLifecycleCapture) async -> Bool { await act(.wake, capture: capture) }
    func setAutoSettle(enabled: Bool, capture: RemoteLifecycleCapture) async -> Bool { await act(.setAutoSettle(enabled: enabled), capture: capture) }
    func applyPolicy(_ value: WorkspaceLifecyclePolicy, expected: WorkspaceLifecyclePolicy, environmentID: UUID) async -> Bool {
        guard canAct, self.environmentID == environmentID else { return false }
        do { try value.validate(); try expected.validate() }
        catch { errorMessage = error.localizedDescription; return false }
        return await run(.lifecyclePolicy(policy: value, expected: expected))
    }
    private func act(_ action: RemoteLifecycleAction, capture: RemoteLifecycleCapture) async -> Bool {
        guard canAct, let state, RemoteLifecycleProtocol.same(state.capture, capture) else { return false }
        let allowed: Bool
        switch action {
        case .settleReviewingScript, .settleWithoutScript: allowed = state.settle.allowed
        case .resume: allowed = state.resume.allowed
        case .snooze(let until): allowed = state.snooze.allowed && until.timeIntervalSince1970.isFinite && until > Date()
        case .wake: allowed = state.wake.allowed
        case .setAutoSettle: allowed = true
        }
        guard allowed else { return false }
        return await run(.lifecycle(capture: state.capture, action: action))
    }
    private func run(_ command: RemoteEnvironmentCommand) async -> Bool {
        guard let perform, canAct else { return false }
        let owner = generation, id = UUID()
        isActing = true; errorMessage = nil; notice = nil
        let task = Task { await perform(command) }; controls[id] = task
        let accepted = await task.value // Deliberately not cancelled with the presenting view.
        controls.removeValue(forKey: id); isActing = !controls.isEmpty
        guard generation == owner, !closed else { return accepted }
        if accepted { await refresh() }
        else { notice = "Inspect the remote request's result before trying again. Nothing was sent a second time." }
        return accepted
    }
    private func retireReads() {
        generation = UUID(); readID = UUID(); isLoading = false
        for task in reads.values { task.cancel() }
    }
    func disconnect() {
        retireReads(); connected = false; writesAllowed = false; transport = nil; state = nil
    }
    func drain() async {
        while !reads.isEmpty { let pending = Array(reads.values); for task in pending { _ = await task.result }; await Task.yield() }
        while !controls.isEmpty { let pending = Array(controls.values); for task in pending { _ = await task.value }; await Task.yield() }
    }
    /// Closing a presentation cancels reads, joins accepted commands, and keeps
    /// the environment's durable pending journal owned by RemoteWorkspaceStore.
    func closePresentation() async { retireReads(); await drain() }
    func shutdown() async { closed = true; disconnect(); await drain() }
    func cancelShutdown() { closed = false }
    private static func matches(_ returned: RemoteWorkspaceTarget?, requested: RemoteWorkspaceTarget?) -> Bool {
        switch (returned, requested) {
        case (nil, nil): true
        case (let value?, let original?):
            value.environmentID == original.environmentID && value.projectID == original.projectID && value.threadID == original.threadID &&
            value.workspacePath.utf8.elementsEqual(original.workspacePath.utf8) && RemoteLifecycleProtocol.same(value.configuration, original.configuration) &&
            (original.rootID == nil || original.rootID == value.rootID)
        default: false
        }
    }
}
