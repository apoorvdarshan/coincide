import Foundation

/// Captured only in Engine; the complete launch plan and incarnation proof
/// never arrive from a client request.
struct RemoteProjectScriptNativeState: Codable, Sendable {
    private struct Payload: Codable, Sendable {
        let target: RemoteWorkspaceTarget; let projectPath: String; let projectIncarnation, threadIncarnation, generationID: UUID
        let run: ThreadProjectScriptRun?; let hasOwnedJob: Bool
    }
    private let storage: [Payload]
    var target: RemoteWorkspaceTarget { storage[0].target }; var projectPath: String { storage[0].projectPath }
    var projectIncarnation: UUID { storage[0].projectIncarnation }; var threadIncarnation: UUID { storage[0].threadIncarnation }
    var generationID: UUID { storage[0].generationID }; var run: ThreadProjectScriptRun? { storage[0].run }; var hasOwnedJob: Bool { storage[0].hasOwnedJob }
    init(target: RemoteWorkspaceTarget, projectPath: String, projectIncarnation: UUID, threadIncarnation: UUID, generationID: UUID, run: ThreadProjectScriptRun?, hasOwnedJob: Bool) {
        storage = [.init(target: target, projectPath: projectPath, projectIncarnation: projectIncarnation, threadIncarnation: threadIncarnation,
            generationID: generationID, run: run, hasOwnedJob: hasOwnedJob)]
    }
    init(from decoder: any Decoder) throws { storage = [try Payload(from: decoder)] }
    func encode(to encoder: any Encoder) throws { try storage[0].encode(to: encoder) }
}
struct RemoteProjectScriptPreparation: Codable, Sendable {
    let native: RemoteProjectScriptNativeState
    let action: RemoteProjectScriptAction
    var target: RemoteWorkspaceTarget { native.target }
    var requiresBoundRoot: Bool { action.requiresBoundRoot }
    var scope: RemotePullRequestScope {
        action.requiresBoundRoot ? .init(mutatingPaths: Array(Set([target.workspacePath, native.projectPath])), coordinationPaths: []) : .init(mutatingPaths: [], coordinationPaths: [])
    }
}
struct RemoteProjectScriptNativeOutput: Sendable {
    let value: ProjectScriptOutputSnapshot?
    let retention: RemoteProjectScriptOutputRetention
}
struct RemoteProjectScriptOutputOwner: Codable, Sendable {
    private struct Payload: Codable, Sendable { let target: RemoteWorkspaceTarget; let projectIncarnation, threadIncarnation, generationID, runID: UUID }
    private let storage: [Payload]
    var target: RemoteWorkspaceTarget { storage[0].target }; var projectIncarnation: UUID { storage[0].projectIncarnation }
    var threadIncarnation: UUID { storage[0].threadIncarnation }; var generationID: UUID { storage[0].generationID }; var runID: UUID { storage[0].runID }
    init(_ native: RemoteProjectScriptNativeState, runID: UUID) {
        storage = [.init(target: native.target, projectIncarnation: native.projectIncarnation, threadIncarnation: native.threadIncarnation, generationID: native.generationID, runID: runID)]
    }
    init(from decoder: any Decoder) throws { storage = [try Payload(from: decoder)] }
    func encode(to encoder: any Encoder) throws { try storage[0].encode(to: encoder) }
}

actor RemoteProjectScriptService {
    private struct ReviewEntry {
        let claim: RemoteProjectScriptClaim; let native: RemoteProjectScriptNativeState; let review: RemoteProjectScriptReview
        let contents: [UUID: (RemoteProjectScriptContentReference, Data)]; let bytes: Int
    }
    private struct OutputEntry { let reference: RemoteProjectScriptOutputReference; let owner: RemoteProjectScriptOutputOwner; let bytes: Int }
    private let environmentID: UUID, hostID = UUID()
    private let engine: WorkspaceEngine
    private var reviews: [UUID: ReviewEntry] = [:], reviewOrder: [UUID] = [], bytes = 0
    private var outputs: [UUID: OutputEntry] = [:], outputOrder: [UUID] = []
    private var outputBytes = 0
    private var closing = false
    init(environmentID: UUID, engine: WorkspaceEngine) { self.environmentID = environmentID; self.engine = engine }
    private func require(_ target: RemoteWorkspaceTarget) throws {
        guard !closing else { throw RemoteProjectScriptFailure(.unavailable) }
        guard target.environmentID == environmentID else { throw RemoteProjectScriptFailure(.invalidTarget) }
    }
    func read(_ request: RemoteProjectScriptReadRequest) async throws -> RemoteProjectScriptReadResult {
        try require(request.target)
        let native = try await engine.readRemoteProjectScript(request.target, generationID: request.generationID)
        try Task.checkCancellation(); try require(request.target)
        guard let run = native.run else { return .init(target: request.target, hostID: hostID, generationID: request.generationID, script: nil) }
        let output = try outputReference(native)
        let review = run.canApprove && run.plan != nil ? try review(native) : nil
        let canStop = ![.stopping, .skipped].contains(run.phase) && (native.hasOwnedJob || [.discovering, .starting, .running].contains(run.phase))
        let state = RemoteProjectScriptState(runID: run.id, phase: run.phase, commandExit: run.commandExit, error: run.error,
            startedAt: run.startedAt, endedAt: run.endedAt, review: review,
            canApprove: run.canApprove && request.target.rootID != nil,
            canStop: canStop, canSkip: run.canSkip, canRetry: run.canRetry && request.target.rootID != nil, output: output)
        let result = RemoteProjectScriptReadResult(target: request.target, hostID: hostID, generationID: request.generationID, script: state)
        guard try RemoteProjectScriptProtocol.payload(result).count <= RemoteProjectScriptProtocol.maximumResultBytes else { throw RemoteProjectScriptFailure(.limitExceeded) }
        return result
    }
    private func review(_ native: RemoteProjectScriptNativeState) throws -> RemoteProjectScriptReview {
        guard let run = native.run, let plan = run.plan else { throw RemoteProjectScriptFailure(.staleReview) }
        struct Proof: Encodable { let target: RemoteWorkspaceTarget; let project, thread, generation: UUID; let plan: ProjectScriptExecutionPlan }
        let payload = try RemoteProjectScriptProtocol.payload(Proof(target: native.target, project: native.projectIncarnation,
            thread: native.threadIncarnation, generation: native.generationID, plan: plan))
        let digest = RemoteProjectionProtocol.digest(payload)
        if let previous = reviews.values.first(where: { $0.claim.digest == digest }) { return previous.review }
        let claim = RemoteProjectScriptClaim(id: UUID(), digest: digest, target: native.target, generationID: native.generationID, runID: run.id, hostID: hostID)
        var contents: [UUID: (RemoteProjectScriptContentReference, Data)] = [:]
        func text(_ value: String, kind: RemoteProjectScriptContentReference.Kind) -> RemoteProjectScriptText {
            var prefix = Data(value.utf8.prefix(8_192))
            while String(data: prefix, encoding: .utf8) == nil { prefix.removeLast() }
            guard value.utf8.count > prefix.count else { return .init(preview: value) }
            let data = Data(value.utf8), reference = RemoteProjectScriptContentReference(id: UUID(), kind: kind, totalBytes: data.count, digest: RemoteProjectionProtocol.digest(data))
            contents[reference.id] = (reference, data)
            return .init(preview: String(decoding: prefix, as: UTF8.self), content: reference)
        }
        let review = RemoteProjectScriptReview(claim: claim, name: text(plan.script.name, kind: .name), command: text(plan.script.command, kind: .command),
            projectRoot: plan.projectRoot, workspacePath: plan.workspacePath, shellPath: plan.shellPath, runsAsynchronously: plan.script.runsAsynchronously)
        let retained = try RemoteProjectScriptProtocol.payload(native).count + RemoteProjectScriptProtocol.payload(review).count + contents.values.reduce(0) { $0 + $1.1.count }
        guard retained <= 16 * 1_024 * 1_024 else { throw RemoteProjectScriptFailure(.limitExceeded) }
        while reviewOrder.count >= 64 || bytes + retained > 16 * 1_024 * 1_024 {
            guard !reviewOrder.isEmpty else { throw RemoteProjectScriptFailure(.limitExceeded) }
            let old = reviewOrder.removeFirst(); if let entry = reviews.removeValue(forKey: old) { bytes -= entry.bytes }
        }
        reviews[claim.id] = .init(claim: claim, native: native, review: review, contents: contents, bytes: retained)
        reviewOrder.append(claim.id); bytes += retained
        return review
    }
    private func outputReference(_ native: RemoteProjectScriptNativeState) throws -> RemoteProjectScriptOutputReference {
        guard let run = native.run else { throw RemoteProjectScriptFailure(.invalidTarget) }
        if let old = outputs.values.first(where: { entry in
            entry.owner.threadIncarnation == native.threadIncarnation && entry.owner.projectIncarnation == native.projectIncarnation &&
            entry.reference.generationID == native.generationID && entry.reference.runID == run.id && RemoteLifecycleProtocol.same(entry.reference.target, native.target)
        }) { return old.reference }
        let reference = RemoteProjectScriptOutputReference(id: UUID(), target: native.target, generationID: native.generationID, runID: run.id, hostID: hostID)
        let owner = RemoteProjectScriptOutputOwner(native, runID: run.id)
        let retained = try RemoteProjectScriptProtocol.payload(owner).count + RemoteProjectScriptProtocol.payload(reference).count
        guard retained <= 2 * 1_024 * 1_024 else { throw RemoteProjectScriptFailure(.limitExceeded) }
        while outputOrder.count >= 64 || outputBytes + retained > 2 * 1_024 * 1_024 {
            guard !outputOrder.isEmpty else { throw RemoteProjectScriptFailure(.limitExceeded) }
            if let old = outputs.removeValue(forKey: outputOrder.removeFirst()) { outputBytes -= old.bytes }
        }
        outputs[reference.id] = .init(reference: reference, owner: owner, bytes: retained); outputOrder.append(reference.id); outputBytes += retained
        return reference
    }
    func content(_ request: RemoteProjectScriptContentRequest) throws -> RemoteProjectScriptContentResult {
        try require(request.claim.target)
        guard request.claim.hostID == hostID else { throw RemoteProjectScriptFailure(.staleHost) }
        guard let entry = reviews[request.claim.id], RemoteLifecycleProtocol.same(entry.claim, request.claim),
              let (reference, data) = entry.contents[request.reference.id], reference == request.reference else { throw RemoteProjectScriptFailure(.staleReview) }
        guard request.offset >= 0, request.offset <= data.count, (1...RemoteProjectScriptProtocol.maximumContentBytes).contains(request.maximumBytes) else { throw RemoteProjectScriptFailure(.invalidRequest) }
        let end = min(data.count, request.offset + request.maximumBytes), complete = end == data.count
        return .init(claim: request.claim, reference: reference, offset: request.offset,
            data: Data(data.dropFirst(request.offset).prefix(end - request.offset)), nextOffset: complete ? nil : end, complete: complete)
    }
    func output(_ request: RemoteProjectScriptOutputRequest) async throws -> RemoteProjectScriptOutputResult {
        try require(request.reference.target)
        guard request.reference.hostID == hostID else { throw RemoteProjectScriptFailure(.staleHost) }
        guard let entry = outputs[request.reference.id], RemoteLifecycleProtocol.same(entry.reference, request.reference) else { throw RemoteProjectScriptFailure(.invalidTarget) }
        let value = try await engine.readRemoteProjectScriptOutput(entry.owner)
        try Task.checkCancellation(); try require(request.reference.target)
        let sequence = value.value?.sequence ?? 0
        guard sequence <= 9_007_199_254_740_991, request.afterSequence.map({ $0 <= sequence }) ?? true else { throw RemoteProjectScriptFailure(.invalidRequest) }
        let result = RemoteProjectScriptOutputResult(reference: request.reference, sequence: sequence, text: value.value?.text ?? "",
            truncated: value.value?.truncated ?? false, isClosed: value.value?.isClosed ?? (value.retention == .notRetained), retention: value.retention)
        guard try RemoteProjectScriptProtocol.payload(result).count <= RemoteProjectScriptProtocol.maximumResultBytes else { throw RemoteProjectScriptFailure(.limitExceeded) }
        return result
    }
    func prepare(_ command: RemoteEnvironmentCommand) async throws -> RemoteEnvironmentPreparation {
        guard case .projectScript(let target, let action) = command else { throw RemoteProjectScriptFailure(.invalidRequest) }
        try require(target)
        if case .approve(let claim) = action {
            guard claim.hostID == hostID else { throw RemoteProjectScriptFailure(.staleHost) }
            guard let entry = reviews[claim.id], RemoteLifecycleProtocol.same(entry.claim, claim),
                  RemoteLifecycleProtocol.same(target, claim.target) else { throw RemoteProjectScriptFailure(.staleReview) }
            return .projectScript(.init(native: entry.native, action: action))
        }
        let native = try await engine.readRemoteProjectScript(target, generationID: action.generationID)
        try Task.checkCancellation(); try require(target)
        guard native.run?.id == action.runID else { throw RemoteProjectScriptFailure(.invalidTarget) }
        return .projectScript(.init(native: native, action: action))
    }
    func close() { closing = true; reviews = [:]; reviewOrder = []; outputs = [:]; outputOrder = []; bytes = 0; outputBytes = 0 }
}
