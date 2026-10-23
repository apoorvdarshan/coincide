import Foundation

actor RemoteSteeringService {
    private struct View: Sendable {
        let target: RemoteWorkspaceTarget, capture: RemoteSteeringCapture
        let incarnation: UUID
        let queue: [RemoteQueuedInputSummary], operations: [RemoteSteeringOperationSummary]
        let contents: [UUID: Data], references: [UUID: RemoteSteeringContentReference]
        let bytes: Int
        var cursors: [UUID: (RemoteSteeringPageKind, Int)] = [:]
        var positions: [String: UUID] = [:]
    }
    private let environmentID: UUID, hostID: UUID
    private let engine: WorkspaceEngine
    private let workspace: RemoteWorkspaceService
    private var views: [UUID: View] = [:], order: [UUID] = []
    private var closing = false, reading = 0
    private var waiters: [CheckedContinuation<Void, Never>] = []
    init(environmentID: UUID, hostID: UUID, engine: WorkspaceEngine, workspace: RemoteWorkspaceService) { self.environmentID = environmentID; self.hostID = hostID; self.engine = engine; self.workspace = workspace }
    private func begin() throws { guard !closing else { throw RemoteEnvironmentError(.unavailable) }; reading += 1 }
    private func finish() { reading -= 1; if reading == 0 { let list = waiters; waiters = []; list.forEach { $0.resume() } } }
    private func lookup(_ binding: RemoteSteeringBinding, target: RemoteWorkspaceTarget) throws -> View {
        guard !closing, binding.environmentID == environmentID, binding.hostID == hostID,
              let view = views[binding.viewID], view.capture.binding == binding, RemoteLifecycleProtocol.same(target, view.target) else { throw RemoteEnvironmentAdmission.stale() }
        return view
    }
    func read(_ request: RemoteSteeringReadRequest) async throws -> RemoteSteeringReadResult {
        try begin(); defer { finish() }
        guard request.target.environmentID == environmentID else { throw RemoteEnvironmentError(.wrongEnvironment) }
        var target = request.target
        if target.rootID == nil { target = (try? await workspace.bindCheckpointTarget(target)) ?? target }
        let native = try await engine.readRemoteSteering(target)
        try Task.checkCancellation(); guard !closing else { throw CancellationError() }
        return try buildRead(target: target, native: native)
    }
    private struct ContentBuilder: Sendable {
        var contents: [UUID: Data] = [:]
        var references: [UUID: RemoteSteeringContentReference] = [:]
        var bytes: Int
    }
    private func content(_ data: Data, kind: RemoteSteeringContentReference.Kind, builder: inout ContentBuilder) throws -> RemoteSteeringContentReference {
        try Task.checkCancellation()
        builder.bytes += data.count + 2_048
        guard builder.bytes <= RemoteProjectionProtocol.maximumCacheBytes else { throw RemoteEnvironmentError(.limitExceeded) }
        while views.values.reduce(builder.bytes, { $0 + $1.bytes }) > RemoteProjectionProtocol.maximumCacheBytes {
            guard let old = order.first else { throw RemoteEnvironmentError(.limitExceeded) }
            views.removeValue(forKey: old); order.removeFirst()
        }
        let reference = RemoteSteeringContentReference(id: UUID(), kind: kind, totalBytes: data.count, digest: RemoteProjectionProtocol.digest(data))
        builder.contents[reference.id] = data; builder.references[reference.id] = reference
        return reference
    }
    private func buildRead(target: RemoteWorkspaceTarget, native: RemoteSteeringNativeRead) throws -> RemoteSteeringReadResult {
        let thread = native.thread
        var builder = ContentBuilder(bytes: try RemoteProjectionProtocol.payload(target).count + 8_192)
        var queue: [RemoteQueuedInputSummary] = []
        for input in thread.queuedTurns {
            try Task.checkCancellation()
            let reason = native.availability.canSteer ? nativeQueueReason(thread: thread, input: input, native: native) : native.availability.unavailableReason
            queue.append(.init(id: input.id, createdAt: input.createdAt, digest: try RemoteSteeringProtocol.digest(input), preview: preview(input.text, maximum: 512),
                text: try content(Data(input.text.utf8), kind: .text, builder: &builder), attachments: try content(try RemoteProjectionProtocol.payload(input.attachments ?? []), kind: .attachments, builder: &builder),
                attachmentCount: input.attachments?.count ?? 0, provider: input.configuration.provider, model: preview(input.configuration.model, maximum: 128), permission: input.configuration.permission,
                canSteer: target.rootID != nil && native.availability.canSteer && reason == nil, canEdit: target.rootID != nil && input.existingMessageID == nil && input.contextDelivery == nil,
                reason: reason ?? (input.contextDelivery != nil ? "This queued input owns a captured context delivery and cannot be edited in place." : nil)))
        }
        var operations: [RemoteSteeringOperationSummary] = []
        for operation in native.operations.reversed() {
            try Task.checkCancellation()
            operations.append(RemoteSteeringOperationSummary(id: operation.id, runID: operation.runID, digest: try RemoteSteeringProtocol.digest(operation), phase: operation.phase,
                preview: preview(operation.input.text, maximum: 512), text: try content(Data(operation.input.text.utf8), kind: .text, builder: &builder),
                attachments: try content(try RemoteProjectionProtocol.payload(operation.input.attachments ?? []), kind: .attachments, builder: &builder),
                error: operation.error, acknowledged: operation.acknowledgedAt != nil))
        }
        struct Identity: Encodable { let target: RemoteWorkspaceTarget; let incarnation: UUID; let queue: [RemoteQueuedInputSummary]; let operations: [RemoteSteeringOperationSummary]; let runID: UUID?; let runtimeID: UUID? }
        let digest = try RemoteSteeringProtocol.digest(Identity(target: target, incarnation: native.incarnation, queue: queue, operations: operations, runID: thread.activeRun?.id, runtimeID: thread.runtimeID))
        let binding = RemoteSteeringBinding(environmentID: environmentID, hostID: hostID, viewID: UUID(), threadID: thread.id, digest: digest)
        let capture = RemoteSteeringCapture(binding: binding, threadCreatedAt: thread.createdAt, projectCreatedAt: native.project.createdAt, runID: thread.activeRun?.id,
            runtimeID: thread.runtimeID, activeConfigurationDigest: try thread.activeRun.map { try RemoteSteeringProtocol.digest($0.configuration) }, queueRevision: try RemoteSteeringProtocol.queueRevision(thread.queuedTurns))
        struct RetainedMetadata: Encodable { let target: RemoteWorkspaceTarget; let capture: RemoteSteeringCapture; let incarnation: UUID; let queue: [RemoteQueuedInputSummary]; let operations: [RemoteSteeringOperationSummary]; let references: [UUID: RemoteSteeringContentReference] }
        let metadata = try RemoteProjectionProtocol.payload(RetainedMetadata(target: target, capture: capture, incarnation: native.incarnation, queue: queue, operations: operations, references: builder.references)).count
        // Reserve both opaque-token maps before any pagination can allocate them.
        let bytes = metadata + builder.contents.values.reduce(0) { $0 + $1.count } + (queue.count + operations.count + 2) * 256 + 2_048
        guard bytes <= RemoteProjectionProtocol.maximumCacheBytes else { throw RemoteEnvironmentError(.limitExceeded) }
        while views.count >= 8 || views.values.reduce(bytes, { $0 + $1.bytes }) > RemoteProjectionProtocol.maximumCacheBytes {
            guard let old = order.first else { throw RemoteEnvironmentError(.limitExceeded) }; views.removeValue(forKey: old); order.removeFirst()
        }
        views[binding.viewID] = .init(target: target, capture: capture, incarnation: native.incarnation, queue: queue, operations: operations, contents: builder.contents, references: builder.references, bytes: bytes)
        order.append(binding.viewID)
        do {
            let first = try page(binding: binding, target: target, kind: .queue, offset: 0, maximumItems: 32, maximumBytes: 96 * 1_024)
            let operationPage = try page(binding: binding, target: target, kind: .operations, offset: 0, maximumItems: 8, maximumBytes: 48 * 1_024)
            let result = RemoteSteeringReadResult(target: target, sequence: native.sequence, canSteer: target.rootID != nil && native.availability.canSteer,
                interruptsTools: native.availability.interruptsTools, reason: target.rootID == nil ? "The checkout is unavailable. Delivery history and acknowledgment remain available without resending." : native.availability.unavailableReason, page: first, operationPage: operationPage,
                activeModel: thread.activeRun.map { preview($0.configuration.model, maximum: 128) }, activePermission: thread.activeRun?.configuration.permission, operationCount: operations.count)
            try bounded(result); return result
        } catch { views.removeValue(forKey: binding.viewID); order.removeAll { $0 == binding.viewID }; throw error }
    }
    private func preview(_ value: String, maximum: Int) -> String {
        var bytes = Data(value.utf8.prefix(maximum))
        while !bytes.isEmpty { if let text = String(data: bytes, encoding: .utf8) { return text }; bytes.removeLast() }
        return ""
    }
    private func nativeQueueReason(thread: CodingThread, input: QueuedTurn, native: RemoteSteeringNativeRead) -> String? {
        guard input.existingMessageID == nil, let run = thread.activeRun else { return "This input is already reserved by another delivery." }
        var config = input.configuration; config.nativeThreadID = run.configuration.nativeThreadID; config.claudeLaunchSelection = run.configuration.claudeLaunchSelection
        return config == run.configuration ? nil : "This input captured different settings. Keep it queued or edit its text without changing its settings."
    }
    func page(_ request: RemoteSteeringPageRequest) throws -> RemoteSteeringPage {
        let view = try lookup(request.binding, target: request.target)
        guard let claim = view.cursors[request.cursor], claim.0 == request.kind else { throw RemoteEnvironmentAdmission.stale() }
        return try page(binding: request.binding, target: view.target, kind: claim.0, offset: claim.1, maximumItems: 128, maximumBytes: RemoteSteeringProtocol.maximumBytes)
    }
    private func page(binding: RemoteSteeringBinding, target: RemoteWorkspaceTarget, kind: RemoteSteeringPageKind, offset: Int, maximumItems: Int, maximumBytes: Int) throws -> RemoteSteeringPage {
        var view = try lookup(binding, target: target)
        let total = kind == .queue ? view.queue.count : view.operations.count
        guard offset >= 0, offset <= total else { throw RemoteEnvironmentAdmission.stale() }
        var end = offset
        func result(_ next: Int, cursor: UUID?) -> RemoteSteeringPage {
            .init(capture: view.capture, kind: kind, operations: kind == .operations ? Array(view.operations[offset..<next]) : [], offset: offset, totalCount: total,
                  items: kind == .queue ? Array(view.queue[offset..<next]) : [], nextCursor: cursor, complete: next == total)
        }
        while end < total, end - offset < maximumItems {
            let candidate = result(end + 1, cursor: end + 1 == total ? nil : UUID())
            guard try RemoteProjectionProtocol.payload(candidate).count <= maximumBytes else { break }; end += 1
        }
        guard end > offset || offset == total else { throw RemoteEnvironmentError(.limitExceeded) }
        let key = kind.rawValue + ":" + String(end)
        let cursor: UUID?
        if end < total { let id = view.positions[key] ?? UUID(); view.positions[key] = id; view.cursors[id] = (kind, end); cursor = id } else { cursor = nil }
        let value = result(end, cursor: cursor); views[binding.viewID] = view; try bounded(value); return value
    }
    func content(_ request: RemoteSteeringContentRequest) throws -> RemoteSteeringContentResult {
        let view = try lookup(request.binding, target: request.target)
        guard view.references[request.reference.id] == request.reference, let bytes = view.contents[request.reference.id],
              request.offset >= 0, request.offset <= bytes.count else { throw RemoteEnvironmentAdmission.stale() }
        let end = min(bytes.count, request.offset + 128 * 1_024)
        let result = RemoteSteeringContentResult(binding: request.binding, reference: request.reference, offset: request.offset,
            data: bytes.subdata(in: request.offset..<end), complete: end == bytes.count)
        try bounded(result); return result
    }
    func release(_ request: RemoteSteeringReleaseRequest) -> RemoteSteeringReleaseResult {
        guard let _ = try? lookup(request.binding, target: request.target) else { return .init(binding: request.binding, released: false) }
        views.removeValue(forKey: request.binding.viewID); order.removeAll { $0 == request.binding.viewID }; return .init(binding: request.binding, released: true)
    }
    func prepare(commandID: UUID, target: RemoteWorkspaceTarget, action: RemoteSteeringAction) async throws -> RemoteSteeringPreparation {
        try begin(); defer { finish() }
        let view = try lookup(action.capture.binding, target: target)
        guard view.capture == action.capture else { throw RemoteEnvironmentAdmission.stale() }
        switch action {
        case .steerComposer: guard view.capture.runID != nil else { throw RemoteEnvironmentAdmission.stale() }
        case .steerQueued(_, let id, let digest), .removeQueued(_, let id, let digest), .editQueued(_, let id, let digest, _, _, _, _):
            guard view.queue.contains(where: { $0.id == id && $0.digest == digest }) else { throw RemoteEnvironmentAdmission.stale() }
        case .moveQueued(_, let id, let beforeID, let revision):
            guard revision == view.capture.queueRevision, view.queue.contains(where: { $0.id == id }), beforeID == nil || view.queue.contains(where: { $0.id == beforeID }) else { throw RemoteEnvironmentAdmission.stale() }
        case .acknowledge(_, let id, let digest): guard view.operations.contains(where: { $0.id == id && $0.digest == digest }) else { throw RemoteEnvironmentAdmission.stale() }
        }
        if action.requiresRoot { try await workspace.validateCheckpointTarget(target, allowLocked: false) }
        let result = try await engine.prepareRemoteSteering(commandID: commandID, target: target, action: action, incarnation: view.incarnation)
        try Task.checkCancellation(); _ = try lookup(action.capture.binding, target: target); return result
    }
    private func bounded<T: Encodable>(_ value: T) throws { guard try RemoteProjectionProtocol.payload(value).count <= RemoteSteeringProtocol.maximumBytes else { throw RemoteEnvironmentError(.limitExceeded) } }
    func close() async { closing = true; views.removeAll(); order.removeAll(); if reading != 0 { await withCheckedContinuation { waiters.append($0) } } }
}
