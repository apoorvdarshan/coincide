import AppKit
import CoincideCore
import Foundation
import Observation
import UniformTypeIdentifiers

private struct RemoteAttachmentContentKey: Hashable { let environmentID: UUID; let projectID: UUID; let threadID: UUID; let metadata: Data }

/// Downloaded host IDs are never looked up in AttachmentStore. Verified bytes
/// are imported as a fresh local UUID, and only that private URL may be opened.
@MainActor @Observable
final class RemoteAttachmentContentStore {
    typealias Transport = @MainActor (RemoteAttachmentTarget) -> (UUID, RemoteAttachmentsTransport)?
    private var progress: [RemoteAttachmentContentKey: Double] = [:]
    @ObservationIgnored private let persistence: RemoteAttachmentDraftPersistence
    @ObservationIgnored private let transport: Transport
    @ObservationIgnored private let localReference: @MainActor (RemoteAttachmentTarget, ChatAttachment) -> ChatAttachment?
    @ObservationIgnored private let isLocal: @MainActor (RemoteAttachmentTarget, ChatAttachment) -> Bool
    @ObservationIgnored private let reportError: @MainActor (String) -> Void
    @ObservationIgnored private var cache: [RemoteAttachmentContentKey: ChatAttachment] = [:]
    @ObservationIgnored private var downloads: [RemoteAttachmentContentKey: Task<ChatAttachment, any Error>] = [:]
    @ObservationIgnored private var waiters: [(UUID, CheckedContinuation<Void, any Error>)] = []
    @ObservationIgnored private var active = 0

    init(persistence: RemoteAttachmentDraftPersistence, transport: @escaping Transport,
         localReference: @escaping @MainActor (RemoteAttachmentTarget, ChatAttachment) -> ChatAttachment?,
         isLocal: @escaping @MainActor (RemoteAttachmentTarget, ChatAttachment) -> Bool,
         reportError: @escaping @MainActor (String) -> Void) {
        self.persistence = persistence; self.transport = transport; self.localReference = localReference; self.isLocal = isLocal; self.reportError = reportError
    }
    func remoteAccess(target: RemoteAttachmentTarget, epoch: UUID) -> AttachmentAccess {
        .init(id: "remote-\(target.environmentID)-\(target.threadID)-\(epoch)",
            data: { [self] in try await data(target: target, reference: $0, epoch: epoch) },
            open: { [self] in await open($0, target: target, epoch: epoch) }, copyImage: { [self] in await copy($0, target: target, epoch: epoch) },
            save: { [self] in save($0, target: target, epoch: epoch) },
            cancelDownload: { [weak self] in self?.downloads[Self.key(target, $0)]?.cancel() },
            transferProgress: { [weak self] in self?.progress[Self.key(target, $0)] })
    }
    func localAccess(target: RemoteAttachmentTarget) -> AttachmentAccess {
        .init(id: "remote-local-copy-\(target.environmentID)-\(target.threadID)",
            data: { [self] value in
                guard isLocal(target, value) else { throw RemoteAttachmentFailure(.invalidTarget) }; return try await persistence.data(value)
            },
            open: { [self] value in if isLocal(target, value) { await open(value, target: nil) } },
            copyImage: { [self] value in if isLocal(target, value) { await copy(value, target: nil) } },
            save: { [self] value in if isLocal(target, value) { save(value, target: nil) } })
    }
    func data(target: RemoteAttachmentTarget, reference: ChatAttachment, epoch: UUID? = nil) async throws -> Data {
        let local = try await cachedReference(target: target, reference: reference, epoch: epoch)
        return try await persistence.data(local)
    }
    private func cachedReference(target: RemoteAttachmentTarget, reference: ChatAttachment, epoch: UUID? = nil) async throws -> ChatAttachment {
        try AttachmentLimits.validate([reference])
        let key = Self.key(target, reference)
        if let existing = cache[key] { return existing }
        if let existing = localReference(target, reference) { return existing }
        guard let (owner, transport) = self.transport(target) else { throw RemoteAttachmentFailure(.unavailable) }
        guard epoch == nil || epoch == owner else { throw CancellationError() }
        if let task = downloads[key] { return try await task.value }
        let task: Task<ChatAttachment, any Error> = Task { [weak self] in
            guard let self else { throw CancellationError() }
            try await self.acquire(); defer { self.release() }
            var bytes = Data(); bytes.reserveCapacity(reference.byteCount)
            repeat {
                try Task.checkCancellation()
                guard self.transport(target)?.0 == owner else { throw CancellationError() }
                let value = try await transport.download(.init(target: target, attachmentID: reference.id, offset: bytes.count))
                guard self.transport(target)?.0 == owner, Self.same(value.target, target), Self.same(value.attachment, reference),
                      value.offset == bytes.count, value.data.count <= RemoteAttachmentProtocol.maximumChunkBytes,
                      value.data.count <= reference.byteCount - bytes.count,
                      value.eof == (bytes.count + value.data.count == reference.byteCount),
                      !value.data.isEmpty || value.eof else { throw RemoteAttachmentFailure(.integrity) }
                bytes.append(value.data)
                self.progress[key] = reference.byteCount == 0 ? 1 : Double(bytes.count) / Double(reference.byteCount)
                if value.eof { break }
            } while bytes.count <= reference.byteCount
            try Task.checkCancellation()
            guard bytes.count == reference.byteCount, RemoteAttachmentsStore.digest(bytes) == reference.digest else { throw RemoteAttachmentFailure(.integrity) }
            let local = try await self.persistence.importData(bytes, name: reference.name)
            guard local.digest == reference.digest, local.byteCount == reference.byteCount else { throw RemoteAttachmentFailure(.integrity) }
            return local
        }
        downloads[key] = task
        defer { downloads.removeValue(forKey: key); progress.removeValue(forKey: key) }
        let result = try await task.value
        cache[key] = result
        if cache.count > 512 { cache.removeValue(forKey: cache.keys.first!) }
        return result
    }
    private func acquire() async throws {
        try Task.checkCancellation()
        if active < 2 { active += 1; return }
        let id = UUID()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
                if Task.isCancelled { continuation.resume(throwing: CancellationError()) }
                else { waiters.append((id, continuation)) }
            }
        } onCancel: { Task { @MainActor [weak self] in
            guard let self, let index = self.waiters.firstIndex(where: { $0.0 == id }) else { return }
            self.waiters.remove(at: index).1.resume(throwing: CancellationError())
        } }
    }
    private func release() {
        if !waiters.isEmpty { waiters.removeFirst().1.resume() }
        else { active -= 1 }
    }
    func cancelAll() { downloads.values.forEach { $0.cancel() } }
    func remember(target: RemoteAttachmentTarget, remote: ChatAttachment, local: ChatAttachment) {
        guard remote.digest == local.digest, remote.byteCount == local.byteCount else { return }
        cache[Self.key(target, remote)] = local
    }

    private func reference(_ value: ChatAttachment, target: RemoteAttachmentTarget?, epoch: UUID? = nil) async throws -> ChatAttachment {
        if let target { return try await cachedReference(target: target, reference: value, epoch: epoch) }
        return value
    }
    private func open(_ value: ChatAttachment, target: RemoteAttachmentTarget?, epoch: UUID? = nil) async {
        do {
            let local = try await reference(value, target: target, epoch: epoch); _ = try await persistence.data(local)
            try Task.checkCancellation()
            let url = try await persistence.url(local)
            if !NSWorkspace.shared.open(url) { throw RemoteAttachmentFailure(.unavailable) }
        } catch { report(error) }
    }
    private func copy(_ value: ChatAttachment, target: RemoteAttachmentTarget?, epoch: UUID? = nil) async {
        do {
            let local = try await reference(value, target: target, epoch: epoch), bytes = try await persistence.data(local)
            try Task.checkCancellation()
            guard value.isImage, let image = NSImage(data: bytes) else { throw RemoteAttachmentFailure(.integrity) }
            NSPasteboard.general.clearContents(); NSPasteboard.general.writeObjects([image])
        } catch { report(error) }
    }
    private func save(_ value: ChatAttachment, target: RemoteAttachmentTarget?, epoch: UUID? = nil) {
        let panel = NSSavePanel(); panel.nameFieldStringValue = value.name
        if let type = UTType(mimeType: value.mimeType) { panel.allowedContentTypes = [type] }
        panel.begin { [weak self] response in
            guard response == .OK, let self, let url = panel.url else { return }
            Task {
                do {
                    let local = try await self.reference(value, target: target, epoch: epoch), bytes = try await self.persistence.data(local)
                    try Task.checkCancellation()
                    let scoped = url.startAccessingSecurityScopedResource(); defer { if scoped { url.stopAccessingSecurityScopedResource() } }
                    try bytes.write(to: url, options: .atomic)
                } catch { self.report(error) }
            }
        }
    }
    private func report(_ error: any Error) {
        if error is CancellationError { return }
        reportError((error as? RemoteAttachmentFailure)?.localizedDescription ?? (error as? RemoteEnvironmentClientError)?.localizedDescription ?? "The attachment could not be opened or saved. Its private copy was preserved.")
    }
    private static func key(_ target: RemoteAttachmentTarget, _ value: ChatAttachment) -> RemoteAttachmentContentKey {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        return .init(environmentID: target.environmentID, projectID: target.projectID, threadID: target.threadID, metadata: (try? encoder.encode(value)) ?? Data())
    }
    private static func same<T: Encodable>(_ lhs: T, _ rhs: T) -> Bool {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        return (try? encoder.encode(lhs)) == (try? encoder.encode(rhs))
    }
}
