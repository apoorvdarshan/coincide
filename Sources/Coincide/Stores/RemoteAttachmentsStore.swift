import AppKit
import CoincideCore
import CryptoKit
import Foundation
import Observation
import UniformTypeIdentifiers

struct RemoteAttachmentsTransport: Sendable {
    var begin: @Sendable (RemoteAttachmentUploadRequest) async throws -> RemoteAttachmentUpload
    var status: @Sendable (RemoteAttachmentUploadRequest) async throws -> RemoteAttachmentUpload?
    var append: @Sendable (RemoteAttachmentChunkRequest) async throws -> RemoteAttachmentUpload
    var finalize: @Sendable (RemoteAttachmentUploadRequest) async throws -> RemoteAttachmentUpload
    var cancel: @Sendable (RemoteAttachmentUploadRequest) async throws -> RemoteAttachmentUpload?
    var download: @Sendable (RemoteAttachmentDownloadRequest) async throws -> RemoteAttachmentDownloadResult
    static func live(_ client: RemoteEnvironmentClient) -> Self {
        .init(begin: { try await client.beginAttachmentUpload($0) }, status: { try await client.attachmentUploadStatus($0) },
            append: { try await client.appendAttachmentChunk($0) }, finalize: { try await client.finalizeAttachmentUpload($0) },
            cancel: { try await client.cancelAttachmentUpload($0) }, download: { try await client.downloadAttachment($0) })
    }
}

struct RemoteAttachmentComposerSubmission {
    let target: RemoteAttachmentTarget
    let expectedDraftAttachments: [ChatAttachment]
    let uploadedAttachmentIDs: [UUID]
    let attachments: [ChatAttachment]
}

@MainActor @Observable
final class RemoteDraftAttachment: Identifiable {
    nonisolated let id: UUID
    let local: ChatAttachment
    var upload: RemoteAttachmentUploadRequest?
    var remote: RemoteAttachmentUpload?
    var requiresCheck: Bool
    var isUploading = false
    var isChecking = false
    var errorMessage: String?
    @ObservationIgnored var action = UUID()
    init(_ record: RemoteAttachmentEntryRecord) {
        id = record.local.id; local = record.local; upload = record.upload; remote = record.remote
        requiresCheck = record.upload != nil && ![.ready, .claimed, .cancelled, .failed].contains(record.remote?.state)
    }
    var record: RemoteAttachmentEntryRecord { .init(local: local, upload: upload, remote: remote) }
    var isReady: Bool { remote?.state == .ready && remote?.attachment != nil && !requiresCheck }
    var completedBytes: Int {
        guard let upload else { return 0 }
        return (remote?.receivedChunks ?? []).reduce(0) { total, index in
            total + min(RemoteAttachmentProtocol.maximumChunkBytes, max(0, upload.byteCount - index * RemoteAttachmentProtocol.maximumChunkBytes))
        }
    }
    var status: String {
        if isChecking { return "Checking upload…" }
        if isUploading { return remote?.state == .finalizing ? "Finishing upload…" : "Uploading…" }
        if requiresCheck { return "Upload result unconfirmed. Check it before continuing." }
        switch remote?.state {
        case .ready: return "Ready on remote Mac"
        case .claimed: return "Already submitted. Check the conversation request's result."
        case .cancelled: return "Upload cancelled. Local draft copy kept."
        case .failed: return "Upload failed. Local draft copy kept."
        case .receiving: return "Partially uploaded. Resume explicitly."
        case .finalizing, .uncertain: return "Upload result unconfirmed. Check it before continuing."
        case nil: return "Stored on this Mac"
        }
    }
}

@MainActor @Observable
final class RemoteAttachmentDraft: Identifiable {
    nonisolated let id: String
    let target: RemoteAttachmentTarget
    var entries: [RemoteDraftAttachment]
    var hostDraftAttachments: [ChatAttachment] = []
    init(_ record: RemoteAttachmentDraftRecord) {
        id = record.target.environmentID.uuidString + ":" + record.target.threadID.uuidString
        target = record.target; entries = record.entries.map(RemoteDraftAttachment.init)
    }
    var record: RemoteAttachmentDraftRecord { .init(target: target, entries: entries.map(\.record)) }
}

private struct RemoteAttachmentScopeKey: Hashable { let environmentID: UUID; let threadID: UUID }

/// The remote window retains this coordinator. UI mount, selection and reconnect
/// load private metadata only; uploads and receipt checks are explicit actions.
@MainActor @Observable
final class RemoteAttachmentsStore {
    private(set) var current: RemoteAttachmentDraft?
    private(set) var isLoading = false
    private(set) var errorMessage: String?
    private(set) var isPreparingSubmission = false
    private(set) var supported = false
    private(set) var connected = false
    private var importCount = 0
    private var uploadCount = 0
    private var pendingWrites = 0
    private var failedEnvironments: Set<UUID> = []
    @ObservationIgnored private let persistence: RemoteAttachmentDraftPersistence
    @ObservationIgnored private var drafts: [RemoteAttachmentScopeKey: RemoteAttachmentDraft] = [:]
    @ObservationIgnored private var loadedEnvironments: Set<UUID> = []
    @ObservationIgnored private var loadTasks: [UUID: Task<[RemoteAttachmentDraftRecord], any Error>] = [:]
    @ObservationIgnored private var transport: RemoteAttachmentsTransport?
    @ObservationIgnored private var clientIdentity: ObjectIdentifier?
    @ObservationIgnored private var environmentID: UUID?
    @ObservationIgnored private var lease = UUID()
    @ObservationIgnored private var selection = UUID()
    @ObservationIgnored private var stopping = false
    @ObservationIgnored private var imports: [UUID: Task<Void, Never>] = [:]
    @ObservationIgnored private var uploads: [UUID: (UUID, Task<Bool, Never>)] = [:]
    @ObservationIgnored private var writes: Task<Bool, Never>?
    @ObservationIgnored private var writeRevision = 0
    @ObservationIgnored private lazy var content = RemoteAttachmentContentStore(persistence: persistence,
        transport: { [weak self] target in
            guard let self, !self.stopping, self.connected, self.supported, self.environmentID == target.environmentID, let transport = self.transport else { return nil }
            return (self.lease, transport)
        }, localReference: { [weak self] target, reference in
            self?.drafts[Self.key(target)]?.entries.first(where: { entry in
                entry.remote?.attachment.map { Self.same($0, reference) } == true && entry.local.digest == reference.digest && entry.local.byteCount == reference.byteCount
            })?.local
        }, isLocal: { [weak self] target, reference in
            self?.drafts[Self.key(target)]?.entries.contains { Self.same($0.local, reference) } == true
        }, reportError: { [weak self] in self?.errorMessage = $0 })

    init(root: URL) { persistence = .init(root: root) }
    var entries: [RemoteDraftAttachment] { current?.entries ?? [] }
    var hostDraftAttachments: [ChatAttachment] { current?.hostDraftAttachments ?? [] }
    var hasAttachments: Bool { !entries.isEmpty || !hostDraftAttachments.isEmpty }
    var isImporting: Bool { importCount > 0 }
    var isUploading: Bool { uploadCount > 0 }
    var hasUnsavedDrafts: Bool { isImporting || pendingWrites > 0 || !failedEnvironments.isEmpty }
    var canImport: Bool { !stopping && !isLoading && supported && current != nil && !failedEnvironments.contains(current!.target.environmentID) }
    var canUpload: Bool { !stopping && supported && connected && transport != nil && !isLoading }
    var retainedDrafts: [RemoteAttachmentDraft] { drafts.values.filter { !$0.entries.isEmpty }.sorted { $0.id < $1.id } }

    func select(target: RemoteAttachmentTarget?, client: RemoteEnvironmentClient?, hostDraftAttachments: [ChatAttachment], supported: Bool) async {
        guard !stopping else { return }
        let identity = client.map(ObjectIdentifier.init)
        if identity != clientIdentity || target?.environmentID != environmentID {
            disconnect(); environmentID = target?.environmentID; clientIdentity = identity
            if let client { transport = .live(client); connected = true }
        }
        await select(target: target, transport: transport, hostDraftAttachments: hostDraftAttachments, supported: supported)
    }

    /// Injectable transport is only a typed byte protocol. No remote path is
    /// accepted by this coordinator or turned into a local file URL.
    func select(target: RemoteAttachmentTarget?, transport: RemoteAttachmentsTransport?, hostDraftAttachments: [ChatAttachment], supported: Bool) async {
        guard !stopping else { return }
        let owner = UUID(); selection = owner
        if environmentID != target?.environmentID { disconnect(); selection = owner }
        environmentID = target?.environmentID; self.transport = transport; connected = transport != nil; self.supported = supported
        guard let target else { current = nil; return }
        isLoading = !loadedEnvironments.contains(target.environmentID)
        defer { if selection == owner { isLoading = false } }
        do {
            try AttachmentLimits.validate(hostDraftAttachments)
            try await loadEnvironment(target.environmentID)
            guard selection == owner, !stopping else { return }
            let key = Self.key(target)
            let model: RemoteAttachmentDraft
            if let existing = drafts[key] {
                guard existing.target == target else { throw RemoteAttachmentFailure(.invalidTarget) }; model = existing
            } else { model = .init(.init(target: target, entries: [])); drafts[key] = model }
            model.hostDraftAttachments = hostDraftAttachments; current = model
        } catch { if selection == owner { current = nil; errorMessage = Self.safeMessage(error) } }
    }
    func clearSelection() { selection = UUID(); current = nil; isLoading = false }

    private func loadEnvironment(_ id: UUID) async throws {
        if loadedEnvironments.contains(id) { return }
        let task: Task<[RemoteAttachmentDraftRecord], any Error>
        if let existing = loadTasks[id] { task = existing }
        else { task = Task { [persistence] in try await persistence.load(environmentID: id) }; loadTasks[id] = task }
        do {
            let records = try await task.value
            if !loadedEnvironments.contains(id) {
                for record in records { drafts[Self.key(record.target)] = .init(record) }
                loadedEnvironments.insert(id)
            }
            loadTasks.removeValue(forKey: id)
        } catch { loadTasks.removeValue(forKey: id); failedEnvironments.insert(id); throw error }
    }

    func chooseAttachments() {
        guard canImport else { return }
        let panel = NSOpenPanel(); panel.canChooseDirectories = false; panel.canChooseFiles = true; panel.allowsMultipleSelection = true; panel.prompt = "Attach"
        let target = current?.target
        panel.begin { [weak self] response in
            guard response == .OK, let self, self.current?.target == target else { return }
            self.importAttachments(files: panel.urls)
        }
    }
    func importAttachments(files: [URL] = [], providers: [NSItemProvider] = []) {
        guard canImport, let draft = current else { return }
        guard files.count + providers.count <= AttachmentLimits.count else { errorMessage = "Attach up to 100 files per message."; return }
        let owner = UUID()
        importCount += 1
        imports[owner] = Task { [weak self, persistence] in
            guard let self else { return }
            defer { self.imports.removeValue(forKey: owner); self.importCount -= 1 }
            for file in files {
                do { try Task.checkCancellation(); try await self.add(try await persistence.importFile(file), to: draft) }
                catch is CancellationError { return }
                catch { self.errorMessage = Self.safeMessage(error) }
            }
            for provider in providers {
                do {
                    try Task.checkCancellation()
                    let reference: ChatAttachment
                    if provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) {
                        let bytes = try await NativePasteData.load(provider, type: UTType.fileURL.identifier)
                        guard let url = URL(dataRepresentation: bytes, relativeTo: nil), url.isFileURL else { throw RemoteAttachmentFailure(.invalidRequest) }
                        reference = try await persistence.importFile(url)
                    } else if let type = provider.registeredTypeIdentifiers.first(where: { UTType($0)?.conforms(to: .image) == true }) {
                        let bytes = try await NativePasteData.load(provider, type: type)
                        let suffix = UTType(type)?.preferredFilenameExtension ?? "png"
                        reference = try await persistence.importData(bytes, name: provider.suggestedName ?? "Pasted image.\(suffix)")
                    } else { continue }
                    try Task.checkCancellation(); try await self.add(reference, to: draft)
                } catch is CancellationError { return }
                catch { self.errorMessage = Self.safeMessage(error) }
            }
        }
    }
    /// Typed data import also lets focused tests exercise normalization without
    /// a picker, a pasteboard, or running a desktop window.
    func importData(_ data: Data, name: String) async {
        guard canImport, let draft = current else { return }
        importCount += 1; defer { importCount -= 1 }
        do { try await add(try await persistence.importData(data, name: name), to: draft) }
        catch { errorMessage = Self.safeMessage(error) }
    }
    /// Stages a verified immutable composer copy under the captured target.
    func stage(_ bytes: Data, reference: ChatAttachment, target: RemoteAttachmentTarget) async throws -> UUID {
        guard canImport, let draft = current, draft.target == target,
              bytes.count == reference.byteCount, Self.digest(bytes) == reference.digest else { throw RemoteAttachmentFailure(.invalidTarget) }
        let owner = lease
        if let existing = draft.entries.first(where: { $0.local.digest == reference.digest && $0.local.byteCount == reference.byteCount && $0.local.name.utf8.elementsEqual(reference.name.utf8) }) {
            _ = try await persistence.data(existing.local); return existing.id
        }
        let local = try await persistence.importData(bytes, name: reference.name)
        guard owner == lease, current === draft, !stopping else { throw CancellationError() }
        try await add(local, to: draft); return local.id
    }
    private func add(_ reference: ChatAttachment, to draft: RemoteAttachmentDraft) async throws {
        try Task.checkCancellation()
        try AttachmentLimits.validate(draft.entries.map(\.local) + draft.hostDraftAttachments + [reference])
        draft.entries.append(.init(.init(local: reference)))
        guard await persist(draft.target.environmentID) else { throw RemoteAttachmentFailure(.unavailable) }
    }
    func remove(_ id: UUID) {
        guard let target = current?.target else { return }; remove(id, target: target)
    }
    func remove(_ id: UUID, target: RemoteAttachmentTarget) {
        guard !stopping, let draft = drafts[Self.key(target)], draft.target == target, let entry = draft.entries.first(where: { $0.id == id }) else { return }
        let active = uploads[id]?.1; active?.cancel()
        let remote = entry.upload, transport = environmentID == target.environmentID ? transport : nil
        draft.entries.removeAll { $0 === entry }
        Task {
            _ = await persist(draft.target.environmentID)
            _ = await active?.value
            if let remote, let transport { _ = try? await transport.cancel(remote) }
        }
    }

    func prepareSubmission(selectedLocalIDs: Set<UUID>? = nil, selectedHostIDs: Set<UUID>? = nil) async -> RemoteAttachmentComposerSubmission? {
        guard !stopping, !isPreparingSubmission, !isImporting, let draft = current else { return nil }
        isPreparingSubmission = true; defer { isPreparingSubmission = false }
        let captured = draft.entries.filter { selectedLocalIDs?.contains($0.id) ?? true }
        let host = draft.hostDraftAttachments, target = draft.target, owner = lease
        let selectedHost = host.filter { selectedHostIDs?.contains($0.id) ?? true }
        do {
            try AttachmentLimits.validate(captured.map(\.local) + selectedHost)
            for entry in captured {
                guard draft.entries.contains(where: { $0 === entry }) else { throw CancellationError() }
                if !entry.isReady { guard await upload(entry.id, in: draft) else { return nil } }
            }
            guard owner == lease, current === draft, !stopping, captured.allSatisfy({ entry in draft.entries.contains { $0 === entry } }) else { return nil }
            let references = try captured.map { entry in
                guard entry.isReady, let reference = entry.remote?.attachment else { throw RemoteAttachmentFailure(.uncertain) }; return reference
            }
            try AttachmentLimits.validate(selectedHost + references)
            guard await persist(target.environmentID) else { return nil }
            return .init(target: target, expectedDraftAttachments: host, uploadedAttachmentIDs: references.map(\.id), attachments: selectedHost + references)
        } catch is CancellationError { return nil }
        catch { errorMessage = Self.safeMessage(error); return nil }
    }

    @discardableResult func upload(_ id: UUID) async -> Bool {
        guard let draft = current else { return false }; return await upload(id, in: draft)
    }
    private func upload(_ id: UUID, in draft: RemoteAttachmentDraft) async -> Bool {
        guard canUpload, let transport, let entry = draft.entries.first(where: { $0.id == id }) else { return false }
        if entry.isReady { return true }
        guard !entry.requiresCheck, entry.remote?.state != .claimed else { errorMessage = entry.status; return false }
        if let running = uploads[id] { return await running.1.value }
        guard uploads.count < 2 else { errorMessage = "Wait for an attachment upload to finish."; return false }
        let owner = lease, operation = UUID(); entry.action = operation
        let task = Task { [weak self] in
            guard let self else { return false }
            entry.isUploading = true; entry.errorMessage = nil
            defer {
                if self.uploads[id]?.0 == operation { self.uploads.removeValue(forKey: id); self.uploadCount -= 1 }
                if entry.action == operation { entry.isUploading = false }
            }
            do {
                let bytes = try await self.persistence.data(entry.local)
                try self.check(owner: owner, entry: entry, draft: draft)
                if entry.upload == nil || entry.remote?.state == .cancelled || entry.remote?.state == .failed {
                    entry.upload = .init(target: draft.target, name: entry.local.name, byteCount: bytes.count, digest: entry.local.digest); entry.remote = nil
                }
                guard let request = entry.upload, await self.persist(draft.target.environmentID) else { return false }
                try self.check(owner: owner, entry: entry, draft: draft)
                var result = try await transport.begin(request)
                try self.accept(result, request: request, entry: entry, draft: draft, owner: owner)
                if result.state == .ready { _ = await self.persist(draft.target.environmentID); return true }
                guard result.state == .receiving else { entry.requiresCheck = true; _ = await self.persist(draft.target.environmentID); return false }
                let count = (bytes.count + RemoteAttachmentProtocol.maximumChunkBytes - 1) / RemoteAttachmentProtocol.maximumChunkBytes
                let missing = (0..<count).filter { !result.receivedChunks.contains($0) }
                for start in stride(from: 0, to: missing.count, by: 4) {
                    try self.check(owner: owner, entry: entry, draft: draft)
                    let indices = Array(missing[start..<min(start + 4, missing.count)])
                    try await withThrowingTaskGroup(of: RemoteAttachmentUpload.self) { group in
                        for index in indices {
                            let offset = index * RemoteAttachmentProtocol.maximumChunkBytes
                            let chunk = bytes.subdata(in: offset..<min(offset + RemoteAttachmentProtocol.maximumChunkBytes, bytes.count))
                            let payload = RemoteAttachmentChunkRequest(upload: request, index: index, data: chunk, digest: Self.digest(chunk))
                            group.addTask { try await transport.append(payload) }
                        }
                        for try await next in group {
                            try self.accept(next, request: request, entry: entry, draft: draft, owner: owner)
                            // Replies from a bounded parallel window can arrive
                            // out of order; retain every confirmed chunk index.
                            let all = Set(result.receivedChunks).union(next.receivedChunks)
                            result = next; result.receivedChunks = all.sorted(); entry.remote = result
                        }
                    }
                }
                try self.check(owner: owner, entry: entry, draft: draft)
                entry.remote?.state = .finalizing
                result = try await transport.finalize(request)
                try self.accept(result, request: request, entry: entry, draft: draft, owner: owner)
                entry.requiresCheck = result.state != .ready && result.state != .cancelled && result.state != .failed && result.state != .claimed
                guard await self.persist(draft.target.environmentID) else { return false }
                return entry.isReady
            } catch {
                if self.lease == owner, entry.action == operation, draft.entries.contains(where: { $0 === entry }) {
                    if let request = entry.upload { entry.remote = .init(request: request, state: .uncertain); entry.requiresCheck = true }
                    entry.errorMessage = Self.safeMessage(error); self.errorMessage = entry.errorMessage
                    _ = await self.persist(draft.target.environmentID)
                }
                return false
            }
        }
        uploads[id] = (operation, task)
        uploadCount += 1
        return await task.value
    }

    func checkUpload(_ id: UUID) async {
        guard canUpload, let transport, let draft = current, let entry = draft.entries.first(where: { $0.id == id }),
              let request = entry.upload, !entry.isChecking, !entry.isUploading else { return }
        let owner = lease, action = UUID(); entry.action = action; entry.isChecking = true
        defer { if entry.action == action { entry.isChecking = false } }
        do {
            let result = try await transport.status(request)
            try check(owner: owner, entry: entry, draft: draft)
            guard entry.action == action else { return }
            if let result {
                try accept(result, request: request, entry: entry, draft: draft, owner: owner)
                entry.requiresCheck = [.uncertain, .finalizing].contains(result.state)
            } else { entry.remote = nil; entry.requiresCheck = false }
            _ = await persist(draft.target.environmentID)
        } catch { if lease == owner { entry.errorMessage = Self.safeMessage(error) } }
    }

    func cancelUpload(_ id: UUID) async {
        guard let draft = current, let entry = draft.entries.first(where: { $0.id == id }) else { return }
        let active = uploads[id]?.1; active?.cancel()
        guard canUpload, let transport, let request = entry.upload else { return }
        let owner = lease, action = UUID(); entry.action = action; entry.isChecking = true; entry.isUploading = false
        defer { if entry.action == action { entry.isChecking = false } }
        do {
            let result = try await transport.cancel(request)
            try check(owner: owner, entry: entry, draft: draft)
            guard entry.action == action else { return }
            if let result { try accept(result, request: request, entry: entry, draft: draft, owner: owner) }
            else { entry.remote = nil }
            entry.requiresCheck = result.map { ![.cancelled, .claimed, .ready, .failed].contains($0.state) } ?? false
            _ = await persist(draft.target.environmentID)
        } catch { if lease == owner { entry.requiresCheck = true; entry.errorMessage = Self.safeMessage(error); _ = await persist(draft.target.environmentID) } }
    }

    func acknowledge(target: RemoteAttachmentTarget, uploadedAttachmentIDs: [UUID]) async -> Bool {
        do { try await loadEnvironment(target.environmentID) }
        catch { errorMessage = Self.safeMessage(error); return false }
        guard let draft = drafts[Self.key(target)], draft.target == target else { return true }
        let ids = Set(uploadedAttachmentIDs)
        for entry in draft.entries {
            if let reference = entry.remote?.attachment, ids.contains(reference.id) { content.remember(target: target, remote: reference, local: entry.local) }
        }
        draft.entries.removeAll { $0.remote?.attachment.map { ids.contains($0.id) } == true }
        return await persist(target.environmentID)
    }

    private func check(owner: UUID, entry: RemoteDraftAttachment, draft: RemoteAttachmentDraft) throws {
        try Task.checkCancellation()
        guard owner == lease, !stopping, connected, draft.entries.contains(where: { $0 === entry }) else { throw CancellationError() }
    }
    private func accept(_ result: RemoteAttachmentUpload, request: RemoteAttachmentUploadRequest,
                        entry: RemoteDraftAttachment, draft: RemoteAttachmentDraft, owner: UUID) throws {
        try check(owner: owner, entry: entry, draft: draft)
        guard Self.same(result.request, request) else { throw RemoteAttachmentFailure(.collision) }
        let count = (request.byteCount + RemoteAttachmentProtocol.maximumChunkBytes - 1) / RemoteAttachmentProtocol.maximumChunkBytes
        guard result.receivedChunks.count <= count, Set(result.receivedChunks).count == result.receivedChunks.count,
              result.receivedChunks.allSatisfy({ $0 >= 0 && $0 < count }) else { throw RemoteAttachmentFailure(.integrity) }
        if [.ready, .claimed].contains(result.state) {
            guard let attachment = result.attachment else { throw RemoteAttachmentFailure(.integrity) }
            try AttachmentLimits.validate([attachment])
        } else if result.attachment != nil { throw RemoteAttachmentFailure(.integrity) }
        entry.remote = result; entry.requiresCheck = false; entry.errorMessage = result.failure?.localizedDescription
    }

    @discardableResult private func persist(_ environmentID: UUID) async -> Bool {
        let records = drafts.values.filter { $0.target.environmentID == environmentID && !$0.entries.isEmpty }.map(\.record)
        let previous = writes; pendingWrites += 1; writeRevision += 1
        let task = Task { [weak self, persistence] in
            _ = await previous?.value
            do {
                try await persistence.save(environmentID: environmentID, drafts: records)
                self?.failedEnvironments.remove(environmentID); return true
            } catch {
                self?.failedEnvironments.insert(environmentID)
                self?.errorMessage = "Attachment drafts could not be saved on this Mac. Their existing files were preserved. Keep this window open."
                return false
            }
        }
        writes = task
        let result = await task.value; pendingWrites -= 1; return result
    }

    func disconnect() {
        lease = UUID(); transport = nil; clientIdentity = nil; connected = false
        for (_, task) in uploads.values { task.cancel() }
        for draft in drafts.values { for entry in draft.entries where entry.upload != nil && ![.ready, .claimed, .cancelled, .failed].contains(entry.remote?.state) {
            entry.requiresCheck = true; entry.isUploading = false
        } }
        content.cancelAll()
    }
    func shutdown() async {
        stopping = true; disconnect()
        await content.drain()
        let importing = Array(imports.values); importing.forEach { $0.cancel() }; for task in importing { await task.value }
        let uploading = uploads.values.map(\.1); for task in uploading { _ = await task.value }
        while let task = writes { let revision = writeRevision; _ = await task.value; if revision == writeRevision { break } }
    }
    func cancelShutdown() { stopping = false }

    func access(target: RemoteAttachmentTarget) -> AttachmentAccess { content.remoteAccess(target: target, epoch: lease) }
    func localAccess(target: RemoteAttachmentTarget) -> AttachmentAccess { content.localAccess(target: target) }
    func localData(_ attachment: ChatAttachment) async throws -> Data { try await persistence.data(attachment) }
    func dismissError() { errorMessage = nil }

    nonisolated static func digest(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }
    private static func key(_ target: RemoteAttachmentTarget) -> RemoteAttachmentScopeKey { .init(environmentID: target.environmentID, threadID: target.threadID) }
    private static func same<T: Encodable>(_ lhs: T, _ rhs: T) -> Bool { bytes(lhs) == bytes(rhs) }
    private static func bytes<T: Encodable>(_ value: T) -> Data {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]; return (try? encoder.encode(value)) ?? Data()
    }
    private static func safeMessage(_ error: any Error) -> String {
        if let value = error as? RemoteAttachmentFailure { return value.localizedDescription }
        if let value = error as? RemoteEnvironmentClientError { return value.localizedDescription }
        if error is CancellationError { return "Attachment transfer stopped. The local draft copy was kept." }
        return "This attachment could not be read or transferred. The local draft copy was kept."
    }
}
