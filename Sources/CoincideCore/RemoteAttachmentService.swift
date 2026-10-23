import Foundation

/// One helper owns transfer jobs. Immutable staging/refs survive EOF, but no
/// finalize or provider command is automatically restarted after reconnection.
actor RemoteAttachmentService {
    private struct Job { let token: UUID; let task: Task<RemoteAttachmentUpload, any Error> }
    private let environmentID: UUID
    private let engine: WorkspaceEngine
    private let journal: RemoteAttachmentJournal
    private var jobs: [UUID: Job] = [:]
    private var cancelling: Set<UUID> = []
    private var closing = false
    private var closeTask: Task<Void, Never>?
    init(environmentID: UUID, engine: WorkspaceEngine, dataDirectory: URL) throws {
        self.environmentID = environmentID; self.engine = engine; journal = try .init(dataDirectory: dataDirectory)
    }
    private func check(_ target: RemoteAttachmentTarget) throws {
        guard !closing else { throw RemoteAttachmentFailure(.unavailable) }
        guard target.environmentID == environmentID else { throw RemoteAttachmentFailure(.invalidTarget) }
    }
    private func authorize(_ target: RemoteAttachmentTarget) async throws {
        try check(target); _ = try await engine.remoteAttachmentThread(target); try check(target)
    }
    func begin(_ request: RemoteAttachmentUploadRequest) async throws -> RemoteAttachmentUpload {
        try await authorize(request.target)
        try RemoteAttachmentJournal.validate(request)
        _ = try journal.insert(request)
        guard let value = try await status(request) else { throw RemoteAttachmentFailure(.notFound) }; return value
    }
    func append(_ request: RemoteAttachmentChunkRequest) async throws -> RemoteAttachmentUpload {
        try await authorize(request.upload.target)
        guard jobs[request.upload.id] == nil, !cancelling.contains(request.upload.id) else { throw RemoteAttachmentFailure(.busy) }
        return try journal.append(request).upload
    }
    func status(_ request: RemoteAttachmentUploadRequest) async throws -> RemoteAttachmentUpload? {
        try check(request.target)
        guard var entry = try journal.lookup(request) else { return nil }
        if let published = try await engine.remoteAttachmentRecord(request.target, id: entry.attachmentID) {
            try check(request.target)
            entry.candidate = published.attachment
            entry.upload.attachment = published.cancelled ? nil : published.attachment
            entry.upload.state = published.cancelled ? .cancelled : published.claimedBy == nil ? .ready : .claimed
            entry.upload.failure = published.cancelled ? .init(.cancelled) : nil
            if !published.cancelled { entry.upload.receivedChunks = Array(0..<RemoteAttachmentJournal.chunkCount(request)) }
            entry.digests = [:]; try journal.store(entry)
            if jobs[request.id] == nil {
                if published.cancelled { try await engine.attachments.removeUnclaimed(published.attachment) }
                try journal.clearStaging(entry)
            }
        }
        return entry.upload
    }
    func finalize(_ request: RemoteAttachmentUploadRequest) async throws -> RemoteAttachmentUpload {
        try await authorize(request.target)
        guard !cancelling.contains(request.id) else { throw RemoteAttachmentFailure(.busy) }
        guard let current = try await status(request) else { throw RemoteAttachmentFailure(.notFound) }
        guard !cancelling.contains(request.id) else { throw RemoteAttachmentFailure(.busy) }
        if [.ready, .claimed].contains(current.state) { return current }
        guard current.state != .cancelled else { throw RemoteAttachmentFailure(.cancelled) }
        if let job = jobs[request.id] { return try await job.task.value }
        guard jobs.count < 2 else { throw RemoteAttachmentFailure(.busy) }
        guard var entry = try journal.lookup(request), entry.digests.count == RemoteAttachmentJournal.chunkCount(request) else { throw RemoteAttachmentFailure(.integrity) }
        entry.upload.state = .finalizing; entry.upload.failure = nil; entry.upload.attachment = nil; try journal.store(entry)
        let token = UUID(), task = Task { try await self.performFinalize(request) }
        jobs[request.id] = .init(token: token, task: task)
        defer { if jobs[request.id]?.token == token { jobs.removeValue(forKey: request.id) } }
        return try await withTaskCancellationHandler { try await task.value } onCancel: { task.cancel() }
    }
    private func performFinalize(_ request: RemoteAttachmentUploadRequest) async throws -> RemoteAttachmentUpload {
        do {
            guard var entry = try journal.lookup(request) else { throw RemoteAttachmentFailure(.notFound) }
            let file = try journal.assemble(entry)
            try Task.checkCancellation()
            let reference = try await engine.attachments.importFile(file, name: request.name, reservedID: entry.attachmentID)
            entry.candidate = reference; try journal.store(entry)
            try Task.checkCancellation(); try check(request.target)
            try await engine.registerRemoteAttachment(request, attachment: reference)
            entry.upload.state = .ready; entry.upload.failure = nil; entry.upload.attachment = reference
            entry.upload.receivedChunks = Array(0..<RemoteAttachmentJournal.chunkCount(request)); entry.digests = [:]
            try journal.store(entry); try journal.clearStaging(entry)
            return entry.upload
        } catch {
            if var entry = try? journal.lookup(request), entry.upload.state != .cancelled {
                entry.upload.state = .uncertain; entry.upload.failure = .init(.uncertain); entry.upload.attachment = nil; try? journal.store(entry)
            }
            throw safe(error)
        }
    }
    func cancel(_ request: RemoteAttachmentUploadRequest) async throws -> RemoteAttachmentUpload? {
        try check(request.target)
        guard try journal.lookup(request) != nil else { return nil }
        cancelling.insert(request.id); defer { cancelling.remove(request.id) }
        if let job = jobs[request.id] { job.task.cancel(); _ = try? await job.task.value }
        guard var entry = try journal.lookup(request) else { return nil }
        if let row = try await engine.cancelRemoteAttachment(request.target, id: entry.attachmentID), row.claimedBy != nil {
            entry.upload.attachment = row.attachment; entry.upload.state = .claimed; entry.upload.failure = nil
            try journal.store(entry); return entry.upload
        }
        // SQLite cancellation serializes against the Engine claim transaction;
        // a committed message can never lose its blob through this path.
        entry.upload.state = .cancelled; entry.upload.failure = .init(.cancelled)
        entry.upload.attachment = nil
        try journal.store(entry)
        if let reference = entry.candidate { try await engine.attachments.removeUnclaimed(reference) }
        try journal.clearStaging(entry); entry.digests = [:]; entry.upload.receivedChunks = []; try journal.store(entry)
        return entry.upload
    }
    func download(_ request: RemoteAttachmentDownloadRequest) async throws -> RemoteAttachmentDownloadResult {
        try check(request.target)
        guard request.offset >= 0, (1...RemoteAttachmentProtocol.maximumChunkBytes).contains(request.maxBytes) else { throw RemoteAttachmentFailure(.invalidRequest) }
        let reference = try await engine.resolveRemoteAttachment(request.target, id: request.attachmentID)
        let bytes = try await engine.attachments.read(reference, offset: request.offset, maximumBytes: request.maxBytes)
        try check(request.target)
        return .init(target: request.target, attachment: reference, offset: request.offset, data: bytes,
            eof: request.offset + bytes.count == reference.byteCount)
    }
    private func safe(_ error: any Error) -> RemoteAttachmentFailure {
        if let error = error as? RemoteAttachmentFailure { return error }
        return .init(error is CancellationError ? .uncertain : .integrity)
    }
    func close() async {
        if let closeTask { await closeTask.value; return }
        closing = true
        let owned = Array(jobs.values)
        for job in owned { job.task.cancel() }
        let task = Task { for job in owned { _ = try? await job.task.value } }
        closeTask = task; await task.value
    }
}
