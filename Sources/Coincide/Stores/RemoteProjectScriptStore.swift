import CoincideCore
import CryptoKit
import Foundation
import Observation

struct RemoteProjectScriptTransport: Sendable {
    var read: @Sendable (RemoteProjectScriptReadRequest) async throws -> RemoteProjectScriptReadResult
    var content: @Sendable (RemoteProjectScriptContentRequest) async throws -> RemoteProjectScriptContentResult
    var output: @Sendable (RemoteProjectScriptOutputRequest) async throws -> RemoteProjectScriptOutputResult
    static func live(_ client: RemoteEnvironmentClient) -> Self {
        .init(read: { try await client.readProjectScript($0) }, content: { try await client.projectScriptContent($0) },
              output: { try await client.projectScriptOutput($0) })
    }
}
struct RemoteProjectScriptLoadedReview: Identifiable, Sendable, Equatable {
    let review: RemoteProjectScriptReview
    let name: String
    let command: String
    var id: UUID { review.claim.id }
}

@MainActor @Observable
final class RemoteProjectScriptStore {
    typealias Perform = @MainActor @Sendable (RemoteEnvironmentCommand) async -> Bool
    typealias Sleep = @Sendable (Duration) async throws -> Void
    private(set) var target: RemoteWorkspaceTarget?
    private(set) var generationID: UUID?
    private(set) var state: RemoteProjectScriptState?
    private(set) var review: RemoteProjectScriptLoadedReview?
    private(set) var output: RemoteProjectScriptOutputResult?
    private(set) var connected = false
    private(set) var supported = false
    private(set) var writesAllowed = false
    private(set) var isLoading = false
    private(set) var isReviewing = false
    private(set) var isActing = false
    private(set) var outputVisible = false
    private(set) var errorMessage: String?
    private(set) var outputError: String?
    private(set) var notice: String?
    private(set) var presentationID = UUID()
    @ObservationIgnored private var transport: RemoteProjectScriptTransport?
    @ObservationIgnored private var perform: Perform?
    @ObservationIgnored private var boundTarget: RemoteWorkspaceTarget?
    @ObservationIgnored private var hostID: UUID?
    @ObservationIgnored private var visible = false
    @ObservationIgnored private var closed = false
    @ObservationIgnored private var readID = UUID()
    @ObservationIgnored private var reviewID = UUID()
    private struct OwnedRead { let cancel: @Sendable () -> Void; let drain: Task<Void, Never> }
    @ObservationIgnored private var reads: [UUID: OwnedRead] = [:]
    @ObservationIgnored private var workers: [UUID: Task<Void, Never>] = [:]
    @ObservationIgnored private var controls: [UUID: Task<Bool, Never>] = [:]
    @ObservationIgnored private var metadataWorker: UUID?
    @ObservationIgnored private var outputWorker: UUID?
    @ObservationIgnored private var reviewRead: UUID?
    @ObservationIgnored private let sleep: Sleep
    init(sleep: Sleep? = nil) { self.sleep = sleep ?? Self.pause }
    private static func pause(_ duration: Duration) async throws { try await Task.sleep(for: duration) }
    var canRead: Bool { !closed && connected && supported && target != nil && generationID != nil && transport != nil }
    var canAct: Bool { canRead && writesAllowed && !isActing }
    var canApprove: Bool {
        canAct && boundTarget?.rootID != nil && !isReviewing && state?.canApprove == true && review.map { same($0.review.claim, state?.review?.claim) } == true
    }
    var unavailableMessage: String? {
        if !supported { return "Update the remote helper to review and run settle scripts." }
        if !connected { return "Reconnect to inspect this settle-script attempt. Nothing is run again automatically." }
        if !writesAllowed { return "Check the current remote request's result before starting another action." }
        return nil
    }
    func update(environmentID: UUID?, target: RemoteWorkspaceTarget?, generationID: UUID?, transport: RemoteProjectScriptTransport?,
                supported: Bool, canWrite: Bool, perform: @escaping Perform) {
        let changed = !same(self.target, target) || self.generationID != generationID || target?.environmentID != environmentID
        if changed {
            retire(); state = nil; review = nil; output = nil; boundTarget = nil; hostID = nil
            errorMessage = nil; outputError = nil; notice = nil; outputVisible = false
        }
        self.target = target; self.generationID = generationID; self.transport = transport; self.perform = perform
        connected = transport != nil && target?.environmentID == environmentID; self.supported = supported; writesAllowed = canWrite
        if !connected || !supported { retire() }
    }
    func refresh() async {
        guard canRead, let target, let generationID, let transport else { return }
        let owner = presentationID, id = UUID(); readID = id; isLoading = true; errorMessage = nil
        defer { if presentationID == owner && readID == id { isLoading = false } }
        do {
            let value = try await owned { try await transport.read(.init(target: target, generationID: generationID)) }
            try Task.checkCancellation()
            guard presentationID == owner, readID == id, canRead else { return }
            guard Self.matches(value.target, requested: target), value.generationID == generationID else { throw RemoteProjectScriptFailure(.invalidTarget) }
            if let script = value.script {
                guard script.output.hostID == value.hostID, script.output.generationID == generationID,
                      script.output.runID == script.runID, same(script.output.target, value.target) else { throw RemoteProjectScriptFailure(.invalidTarget) }
                if let plan = script.review {
                    guard plan.claim.hostID == value.hostID, plan.claim.generationID == generationID,
                          plan.claim.runID == script.runID, same(plan.claim.target, value.target),
                          plan.workspacePath.utf8.elementsEqual(value.target.workspacePath.utf8), RemoteLifecycleProtocol.validDigest(plan.claim.digest) else { throw RemoteProjectScriptFailure(.staleReview) }
                }
            }
            if !same(state?.output, value.script?.output) {
                cancelOutput(); output = nil; outputError = nil
                if state?.runID != value.script?.runID { outputVisible = false }
            }
            if !same(state?.review, value.script?.review) { closeReview() }
            boundTarget = value.target; hostID = value.hostID; state = value.script
            if outputVisible { startOutput() }
        } catch is CancellationError { }
        catch { if presentationID == owner && readID == id { errorMessage = error.localizedDescription } }
    }
    func refreshPresentation() async {
        await refresh()
        if visible { startMetadata() }
    }
    func beginReview() async {
        guard canRead, boundTarget?.rootID != nil, !isReviewing, let current = state, current.canApprove, let plan = current.review, let transport else { return }
        let owner = presentationID, id = UUID(); reviewID = id; isReviewing = true; errorMessage = nil
        defer { if presentationID == owner && reviewID == id { isReviewing = false } }
        do {
            let value = try await owned(review: true) {
                let name = try await Self.document(plan.name, kind: .name, claim: plan.claim, transport: transport)
                let command = try await Self.document(plan.command, kind: .command, claim: plan.claim, transport: transport)
                return RemoteProjectScriptLoadedReview(review: plan, name: name, command: command)
            }
            try Task.checkCancellation()
            guard presentationID == owner, reviewID == id, same(state?.review?.claim, plan.claim), state?.canApprove == true else { return }
            review = value
        } catch is CancellationError { }
        catch { if presentationID == owner && reviewID == id { errorMessage = error.localizedDescription } }
    }
    func closeReview() { if let reviewRead { reads[reviewRead]?.cancel() }; reviewID = UUID(); review = nil; isReviewing = false }
    func approve(_ value: RemoteProjectScriptLoadedReview) async -> Bool {
        guard canApprove, review == value, same(state?.review?.claim, value.review.claim) else { return false }
        return await act(.approve(value.review.claim), expected: state)
    }
    func stop(_ value: RemoteProjectScriptState) async -> Bool { await act(.stop(generationID: value.output.generationID, runID: value.runID), expected: value) }
    func skip(_ value: RemoteProjectScriptState) async -> Bool { await act(.skip(generationID: value.output.generationID, runID: value.runID), expected: value) }
    func retry(_ value: RemoteProjectScriptState) async -> Bool { await act(.retry(generationID: value.output.generationID, runID: value.runID), expected: value) }
    private func act(_ action: RemoteProjectScriptAction, expected: RemoteProjectScriptState?) async -> Bool {
        guard canAct, let expected, let current = state, same(current, expected), let boundTarget, let perform,
              action.runID == current.runID, action.generationID == generationID,
              !action.requiresBoundRoot || boundTarget.rootID != nil else { return false }
        let allowed: Bool
        switch action { case .approve: allowed = current.canApprove && canApprove; case .stop: allowed = current.canStop
        case .skip: allowed = current.canSkip; case .retry: allowed = current.canRetry }
        guard allowed else { return false }
        let owner = presentationID, id = UUID(); isActing = true; errorMessage = nil; notice = nil
        let task = Task { await perform(.projectScript(target: boundTarget, action: action)) }; controls[id] = task
        let accepted = await task.value // View dismissal/cancellation cannot undo accepted admission.
        controls.removeValue(forKey: id); isActing = !controls.isEmpty
        guard presentationID == owner, !closed else { return accepted }
        if accepted { review = nil; if visible { await refresh(); startMetadata() } }
        else { notice = "Inspect the remote request's result before trying again. The command was not repeated." }
        return accepted
    }
    func startPresentation() { visible = true; startMetadata(); if outputVisible { startOutput() } }
    func endPresentation() { visible = false; cancelWorkers(); cancelReads(); closeReview() }
    func closePresentation() async { endPresentation(); await drain() }
    func setOutputVisible(_ value: Bool) { outputVisible = value; if value { startOutput() } else { cancelOutput() } }
    func refreshOutput() async {
        guard canRead, outputVisible, let reference = state?.output, let transport else { return }
        let owner = presentationID, previous = same(output?.reference, reference) ? output : nil
        do {
            let value = try await owned { try await transport.output(.init(reference: reference, afterSequence: previous?.sequence)) }
            try Task.checkCancellation()
            guard presentationID == owner, outputVisible, same(state?.output, reference) else { return }
            guard same(value.reference, reference), value.text.utf8.count <= 65_536,
                  previous.map({ value.sequence >= $0.sequence }) ?? true,
                  value.retention == .retained || value.text.isEmpty else { throw RemoteProjectScriptFailure(.invalidRequest) }
            if let previous, value.sequence == previous.sequence, !same(value, previous) {
                let openedEmptyLog = previous.retention == .notStarted && value.retention == .retained &&
                    previous.text.isEmpty && value.text.isEmpty && !previous.truncated && !value.truncated && !previous.isClosed && !value.isClosed
                guard openedEmptyLog else { throw RemoteProjectScriptFailure(.invalidRequest) }
            }
            output = value; outputError = nil
        } catch is CancellationError { }
        catch { if presentationID == owner && outputVisible { outputError = error.localizedDescription } }
    }
    private func startMetadata() {
        guard visible, canRead, metadataWorker == nil else { return }
        let id = UUID(), owner = presentationID; metadataWorker = id
        workers[id] = Task { [weak self] in
            guard let self else { return }
            defer { self.workers.removeValue(forKey: id); if self.metadataWorker == id { self.metadataWorker = nil } }
            repeat {
                await self.refresh()
                guard !Task.isCancelled, self.presentationID == owner, self.visible, self.canRead, self.errorMessage == nil,
                      self.state.map({ [.discovering, .starting, .running, .stopping].contains($0.phase) || $0.canStop }) == true else { return }
                do { try await self.sleep(.seconds(1)) } catch { return }
            } while !Task.isCancelled
        }
    }
    private func startOutput() {
        guard visible, canRead, outputVisible, state != nil, outputWorker == nil else { return }
        let id = UUID(), owner = presentationID; outputWorker = id
        workers[id] = Task { [weak self] in
            guard let self else { return }
            defer { self.workers.removeValue(forKey: id); if self.outputWorker == id { self.outputWorker = nil } }
            repeat {
                await self.refreshOutput()
                guard !Task.isCancelled, self.presentationID == owner, self.visible, self.outputVisible, self.canRead,
                      self.outputError == nil, self.output?.isClosed != true, self.output?.retention != .notRetained else { return }
                if self.output?.retention == .notStarted, self.state.map({ [.starting, .running, .stopping].contains($0.phase) || $0.canStop }) != true { return }
                do { try await self.sleep(.seconds(1)) } catch { return }
            } while !Task.isCancelled
        }
    }
    private func cancelOutput() { if let outputWorker { workers[outputWorker]?.cancel() }; outputWorker = nil }
    private func cancelWorkers() { for task in workers.values { task.cancel() }; metadataWorker = nil; outputWorker = nil }
    private func cancelReads() { for value in reads.values { value.cancel() } }
    private func retire() { presentationID = UUID(); cancelWorkers(); cancelReads(); readID = UUID(); reviewID = UUID(); isLoading = false; isReviewing = false }
    func disconnect() { retire(); connected = false; writesAllowed = false; transport = nil; review = nil }
    func shutdown() async { closed = true; visible = false; disconnect(); await drain() }
    func cancelShutdown() { closed = false }
    func drain() async {
        while !workers.isEmpty || !reads.isEmpty || !controls.isEmpty {
            let workers = Array(workers.values), reads = Array(reads.values), controls = Array(controls.values)
            for task in workers { await task.value }; for read in reads { await read.drain.value }; for task in controls { _ = await task.value }
            await Task.yield()
        }
    }
    private func owned<T: Sendable>(review: Bool = false, _ operation: @escaping @Sendable () async throws -> T) async throws -> T {
        let id = UUID(), task = Task { try await operation() }
        reads[id] = .init(cancel: { task.cancel() }, drain: Task { _ = await task.result })
        if review { reviewRead = id }
        defer { reads.removeValue(forKey: id); if reviewRead == id { reviewRead = nil } }
        return try await withTaskCancellationHandler { try await task.value } onCancel: { task.cancel() }
    }
    private func same<T: Encodable>(_ lhs: T, _ rhs: T) -> Bool { RemoteLifecycleProtocol.same(lhs, rhs) }
    private static func matches(_ value: RemoteWorkspaceTarget, requested: RemoteWorkspaceTarget) -> Bool {
        value.environmentID == requested.environmentID && value.projectID == requested.projectID && value.threadID == requested.threadID &&
        value.workspacePath.utf8.elementsEqual(requested.workspacePath.utf8) && RemoteLifecycleProtocol.same(value.configuration, requested.configuration) &&
        // Losing physical checkout authority still permits exact-attempt
        // inspection, Stop and Skip. Never accept a different bound root;
        // Approve and Retry separately require the returned physical lease.
        (requested.rootID == nil || value.rootID == nil || value.rootID == requested.rootID)
    }
    private nonisolated static func document(_ text: RemoteProjectScriptText, kind: RemoteProjectScriptContentReference.Kind,
                                            claim: RemoteProjectScriptClaim, transport: RemoteProjectScriptTransport) async throws -> String {
        guard let reference = text.content else {
            guard !text.preview.isEmpty, text.preview.utf8.count <= 262_144, !text.preview.contains("\0") else { throw RemoteProjectScriptFailure(.invalidRequest) }
            return text.preview
        }
        guard reference.kind == kind, (1...262_144).contains(reference.totalBytes), RemoteLifecycleProtocol.validDigest(reference.digest) else { throw RemoteProjectScriptFailure(.limitExceeded) }
        var data = Data()
        while data.count < reference.totalBytes {
            try Task.checkCancellation()
            let offset = data.count, value = try await transport.content(.init(claim: claim, reference: reference, offset: offset))
            guard RemoteLifecycleProtocol.same(value.claim, claim), value.reference == reference, value.offset == offset,
                  !value.data.isEmpty, value.data.count <= RemoteProjectScriptProtocol.maximumContentBytes,
                  value.data.count <= reference.totalBytes - offset else { throw RemoteProjectScriptFailure(.invalidRequest) }
            data.append(value.data)
            guard value.complete == (data.count == reference.totalBytes), value.nextOffset == (value.complete ? nil : data.count) else { throw RemoteProjectScriptFailure(.invalidRequest) }
        }
        let bytes = data
        return try await Task.detached {
            guard SHA256.hash(data: bytes).map({ String(format: "%02x", $0) }).joined() == reference.digest,
                  let value = String(data: bytes, encoding: .utf8), !value.contains("\0"), Data(value.utf8).starts(with: Data(text.preview.utf8)) else { throw RemoteProjectScriptFailure(.invalidRequest) }
            return value
        }.value
    }
}
