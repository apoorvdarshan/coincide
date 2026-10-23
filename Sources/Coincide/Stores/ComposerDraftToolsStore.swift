import AppKit
import CoincideCore
import Foundation
import Observation
import UniformTypeIdentifiers

enum ComposerDraftToolsOutcome: Sendable, Equatable { case applied, rejected, unknown }
@MainActor struct ComposerDraftToolsTransport {
    var snapshot: (UUID) -> ComposerDraftSnapshot?
    var replace: (UUID, ComposerDraftReplacement) async throws -> ComposerDraftToolsOutcome
    var receipt: (UUID, ComposerDraftReplacement) async throws -> ComposerDraftToolsOutcome?
    var importData: (Data, String) async throws -> ChatAttachment
    var verify: (ChatAttachment) async throws -> Void
    var canOperate: (UUID) -> Bool = { _ in true }
    var reportError: (UUID, String) -> Void = { _, _ in }
    var captureScope: (UUID) -> Data? = { _ in nil }
    var isCurrentScope: (UUID, Data?) -> Bool = { _, _ in true }
}

struct ComposerAttachmentImport: Identifiable {
    enum State: Equatable { case importing, failed, needsReattach, unconfirmed }
    let id: UUID
    let threadID: UUID
    let name: String
    var state: State
    var message: String?
}

/// Native draft tools never send a prompt. Each mutation is persisted with its
/// original command ID before admission; unknown results are checked explicitly.
@MainActor @Observable
final class ComposerDraftToolsStore {
    private(set) var entries: [ComposerStashEntry] = []
    private(set) var pending: [ComposerPendingMutation] = []
    private(set) var imports: [ComposerAttachmentImport] = []
    private(set) var errorMessage: String?
    private(set) var notice: String?
    private(set) var isLoaded = false
    private(set) var stopping = false
    @ObservationIgnored private let persistence: ComposerDraftPersistence
    @ObservationIgnored private var transport: ComposerDraftToolsTransport?
    @ObservationIgnored private var document = ComposerDraftToolsDocument()
    @ObservationIgnored private var metadataTail: Task<Void, any Error>?
    @ObservationIgnored private var jobs: [UUID: Task<Void, Never>] = [:]
    @ObservationIgnored private var jobScopes: [UUID: Data] = [:]
    @ObservationIgnored private var importScopes: [UUID: Data] = [:]
    @ObservationIgnored private var jobOwners: [UUID: UUID] = [:]
    @ObservationIgnored private var suspendedThreads: Set<UUID> = []
    @ObservationIgnored private var activeThreads: [UUID: Int] = [:]
    @ObservationIgnored private var dispatched: Set<UUID> = []
    @ObservationIgnored private var payloads: [UUID: Data] = [:]
    @ObservationIgnored private var references: [UUID: ChatAttachment] = [:]
    @ObservationIgnored private var pasteAnchors: [UUID: (ComposerDraftSnapshot, NSRange)] = [:]
    @ObservationIgnored private var reservedNames: [UUID: Set<String>] = [:]
    @ObservationIgnored private var importOwners: [UUID: ComposerDraftSnapshot] = [:]
    @ObservationIgnored private var captureTail: Task<Void, Never>?
    @ObservationIgnored private var importTail: Task<Void, Never>?
    @ObservationIgnored private var reservedBytes = 0
    private let maximumRetainedBytes = 80 * 1_024 * 1_024

    init(root: URL) { persistence = .init(root: root) }
    func bind(_ transport: ComposerDraftToolsTransport) { self.transport = transport }
    // Like the pinned native-environment stash, saved prompts can be explicitly
    // restored into another thread. References never cross this engine/store.
    func stashes(_ threadID: UUID) -> [ComposerStashEntry] { entries }
    func importItems(_ threadID: UUID) -> [ComposerAttachmentImport] { imports.filter { $0.threadID == threadID } }
    func unresolved(_ threadID: UUID) -> [ComposerPendingMutation] { pending.filter { $0.replacement.expected.threadID == threadID } }
    func isWorking(_ threadID: UUID) -> Bool { activeThreads[threadID, default: 0] > 0 }
    func hasUnresolved(_ threadID: UUID) -> Bool { !unresolved(threadID).isEmpty }
    func blocksSubmission(_ threadID: UUID) -> Bool { isWorking(threadID) || hasUnresolved(threadID) || !importItems(threadID).isEmpty }
    func clearError() { errorMessage = nil; notice = nil }
    func load() async {
        guard !stopping, !isLoaded else { return }
        do { try await updateDocument { _ in }; errorMessage = nil }
        catch { errorMessage = Self.message(error) }
    }

    @discardableResult func stash(threadID: UUID) -> Task<Void, Never>? {
        guard let transport, allowed(threadID), !isWorking(threadID), !hasUnresolved(threadID),
              let captured = transport.snapshot(threadID), !captured.text.isEmpty || !captured.attachments.isEmpty else { return nil }
        // Failed imports have not reached the draft; silently leaving them behind
        // would make the saved prompt look complete when it is not.
        guard importItems(threadID).isEmpty else { errorMessage = "Retry or remove unfinished attachments before stashing this prompt."; return nil }
        let entry = ComposerStashEntry(id: UUID(), createdAt: Date(), draft: captured)
        let operation = ComposerPendingMutation(id: UUID(), purpose: .stash(entry.id), replacement: .init(expected: captured, text: "", attachments: []), ownerScope: transport.captureScope(threadID))
        return own(threadID) { [self] owner in
            do {
                var evicted = false
                try await updateDocument { value in
                    value.entries.insert(entry, at: 0)
                    if value.entries.count > 20 {
                        let protected = Set(value.pending.compactMap { operation -> UUID? in
                            switch operation.purpose { case .stash(let id), .restore(let id): return id; case .attachment: return nil }
                        })
                        guard let oldest = value.entries.lastIndex(where: { !protected.contains($0.id) && $0.id != entry.id }) else {
                            throw CoincideError("Check the pending saved prompts before stashing another prompt.")
                        }
                        value.entries.remove(at: oldest); evicted = true
                    }
                    value.pending.append(operation)
                }
                if evicted { notice = "The oldest stashed prompt was removed. The stash keeps 20 prompts." }
                await dispatch(operation, owner: owner)
            } catch { errorMessage = Self.message(error) }
        }
    }

    @discardableResult func restore(_ entryID: UUID, threadID: UUID) -> Task<Void, Never>? {
        guard let transport, allowed(threadID), !isWorking(threadID), !hasUnresolved(threadID),
              let entry = entries.first(where: { $0.id == entryID }), !pending.contains(where: { $0.purpose == .restore(entryID) || $0.purpose == .stash(entryID) }) else { return nil }
        return own(threadID) { [self] owner in
            do {
                for reference in entry.draft.attachments { try Task.checkCancellation(); try await transport.verify(reference) }
                guard allowed(threadID), let latest = transport.snapshot(threadID) else {
                    throw CoincideError("The selected thread is no longer available. The saved prompt was kept.")
                }
                var attachments = latest.attachments
                for reference in entry.draft.attachments {
                    if let existing = attachments.first(where: { $0.id == reference.id }) {
                        guard ComposerDraftSnapshot.sameAttachments([existing], [reference]) else { throw CoincideError("A saved attachment reference changed. The stash was kept.") }
                    } else { attachments.append(reference) }
                }
                try AttachmentLimits.validate(attachments)
                let text = entry.draft.text.isEmpty ? latest.text : latest.text.isEmpty ? entry.draft.text : latest.text + "\n\n" + entry.draft.text
                let operation = ComposerPendingMutation(id: UUID(), purpose: .restore(entryID), replacement: .init(expected: latest, text: text, attachments: attachments), ownerScope: jobScopes[owner])
                try await updateDocument { value in
                    guard value.entries.contains(where: { $0.id == entryID }) else { throw CoincideError("This saved prompt was already restored or removed.") }
                    value.pending.append(operation)
                }
                await dispatch(operation, owner: owner)
            } catch is CancellationError { }
            catch { errorMessage = "The saved prompt was kept. " + Self.message(error) }
        }
    }

    @discardableResult func delete(_ entryID: UUID) -> Task<Void, Never>? {
        guard !stopping, let entry = entries.first(where: { $0.id == entryID }), !pending.contains(where: { $0.purpose == .restore(entryID) || $0.purpose == .stash(entryID) }) else { return nil }
        return own(entry.draft.threadID) { [self] _ in
            do { try await updateDocument { $0.entries.removeAll { $0.id == entryID } } }
            catch { errorMessage = Self.message(error) }
        }
    }

    /// Local adapters share the original-ID pending journal for selection and
    /// text expansion, without fabricating a CodingThread or native proof.
    @discardableResult func replaceSelection(_ replacement: ComposerDraftReplacement) -> Task<Void, Never>? {
        let id = replacement.expected.threadID
        guard allowed(id), !isWorking(id), !hasUnresolved(id), transport?.snapshot(id).map({ replacement.expected.matches($0) }) == true else { return nil }
        let operation = ComposerPendingMutation(id: UUID(), purpose: .attachment(UUID()), replacement: replacement, ownerScope: transport?.captureScope(id))
        return own(id) { [self] owner in
            do { try await updateDocument { $0.pending.append(operation) }; await dispatch(operation, owner: owner) }
            catch { errorMessage = Self.message(error) }
        }
    }
    @discardableResult func expandTextAttachment(_ reference: ChatAttachment, threadID: UUID,
        read: @escaping @MainActor (ChatAttachment) async throws -> Data) -> Task<Void, Never>? {
        guard allowed(threadID), !isWorking(threadID), !hasUnresolved(threadID), !reference.isImage,
              reference.byteCount <= 8 * 1_024 * 1_024, let expected = transport?.snapshot(threadID),
              expected.attachments.contains(where: { ComposerDraftSnapshot.sameAttachments([$0], [reference]) }) else { return nil }
        return own(threadID) { [self] owner in
            do {
                let bytes = try await read(reference)
                guard bytes.count == reference.byteCount, let text = String(data: bytes, encoding: .utf8),
                      allowed(threadID), transport?.snapshot(threadID).map({ expected.matches($0) }) == true else { throw CoincideError("The draft changed, or this attachment is not complete UTF-8 text. Its reference was kept.") }
                let expanded = expected.text.isEmpty ? text : expected.text + "\n\n" + text
                guard expanded.utf16.count <= ComposerPastePolicy.maximumInputLength else { throw CoincideError("This text exceeds the inline draft limit. Keep it attached or copy a smaller excerpt.") }
                let replacement = ComposerDraftReplacement(expected: expected, text: expanded, attachments: expected.attachments.filter { $0.id != reference.id })
                let operation = ComposerPendingMutation(id: UUID(), purpose: .attachment(UUID()), replacement: replacement, ownerScope: jobScopes[owner])
                try await updateDocument { $0.pending.append(operation) }; await dispatch(operation, owner: owner)
            } catch is CancellationError { }
            catch { errorMessage = Self.message(error) }
        }
    }

    @discardableResult func checkResult(_ commandID: UUID) -> Task<Void, Never>? {
        guard let operation = pending.first(where: { $0.id == commandID }), let transport, !stopping, !isWorking(operation.replacement.expected.threadID) else { return nil }
        return own(operation.replacement.expected.threadID) { [self] owner in
            dispatched.insert(owner); defer { dispatched.remove(owner) }
            do {
                guard let result = try await transport.receipt(operation.id, operation.replacement), result != .unknown else {
                    errorMessage = "The draft change is still unconfirmed. It has not been repeated."; return
                }
                try await settle(operation, result: result)
            } catch { errorMessage = "The draft change is still unconfirmed. It has not been repeated." }
        }
    }

    func importFiles(_ urls: [URL], threadID: UUID) {
        guard !urls.isEmpty else { return }
        guard allowed(threadID), let transport, let captured = transport.snapshot(threadID) else { return }
        guard reserveSlots(urls.count, snapshot: captured) else { return }
        for url in urls {
            let id = addImport(threadID, name: url.lastPathComponent, owner: captured)
            own(threadID) { [self] owner in
                do {
                    let data = try await capture { try await Task.detached { try Self.readSelection(url) }.value }
                    try Task.checkCancellation(); try retain(data, id: id)
                    await prepareImport(id, captured: captured, owner: owner)
                } catch is CancellationError { fail(id, message: "The file read was interrupted. Choose it again if its complete bytes were not captured.", unreadable: payloads[id] == nil) }
                catch { fail(id, message: Self.message(error), unreadable: payloads[id] == nil, report: true) }
            }
        }
    }
    func importProviders(_ providers: [NSItemProvider], threadID: UUID) {
        guard !providers.isEmpty else { return }
        guard allowed(threadID), let transport, let captured = transport.snapshot(threadID), reserveSlots(providers.count, snapshot: captured) else { return }
        for provider in providers {
            let id = addImport(threadID, name: provider.suggestedName ?? "Pasted attachment", owner: captured)
            own(threadID) { [self] owner in
                do {
                    let data: Data
                    if provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) {
                        let raw = try await capture { try await NativePasteData.load(provider, type: UTType.fileURL.identifier) }
                        guard let url = URL(dataRepresentation: raw, relativeTo: nil), url.isFileURL else { throw CoincideError("This is not a local file.") }
                        rename(id, to: url.lastPathComponent); data = try await capture { try await Task.detached { try Self.readSelection(url) }.value }
                    } else if let type = provider.registeredTypeIdentifiers.first(where: { UTType($0)?.conforms(to: .image) == true }) {
                        rename(id, to: provider.suggestedName ?? "Pasted image.\(UTType(type)?.preferredFilenameExtension ?? "png")")
                        data = try await capture { try await NativePasteData.load(provider, type: type) }
                    } else { throw CoincideError("Attach a supported image or local file.") }
                    try Task.checkCancellation(); try retain(data, id: id)
                    await prepareImport(id, captured: captured, owner: owner)
                } catch is CancellationError { fail(id, message: "The pasted attachment read was interrupted. Paste it again if its complete bytes were not captured.", unreadable: payloads[id] == nil) }
                catch { fail(id, message: Self.message(error), unreadable: payloads[id] == nil, report: true) }
            }
        }
    }
    @discardableResult func paste(_ text: String, threadID: UUID, selection: NSRange, expectedText: String) -> Bool {
        guard allowed(threadID), ComposerPastePolicy.folds(text, bypass: false, wouldExceedLimit: ComposerPastePolicy.exceedsInputLimit(text, text: expectedText, selection: selection)), let transport,
              let captured = transport.snapshot(threadID), captured.text.utf8.elementsEqual(expectedText.utf8),
              ComposerUTF16Selection.isValid(selection, in: expectedText), reserveSlots(1, snapshot: captured) else { return false }
        guard text.utf8.count <= AttachmentLimits.fileBytes, text.utf8.count <= maximumRetainedBytes - reservedBytes else {
            errorMessage = "The paste is too large to attach. Use Paste as Text or choose a smaller excerpt."; return false
        }
        let names = captured.attachments.map(\.name) + importItems(threadID).map(\.name) + Array(reservedNames[threadID, default: []])
        let name = ComposerPastePolicy.nextName(names); reservedNames[threadID, default: []].insert(name)
        let id = addImport(threadID, name: name, owner: captured)
        pasteAnchors[id] = (captured, selection)
        own(threadID) { [self] owner in
            do {
                let data = try await capture { await Task.detached { Data(text.utf8) }.value }
                try Task.checkCancellation(); try retain(data, id: id)
                await prepareImport(id, captured: captured, owner: owner)
            } catch { fail(id, message: Self.message(error), unreadable: payloads[id] == nil, report: !(error is CancellationError)) }
        }
        return true
    }
    @discardableResult func retryImport(_ id: UUID) -> Task<Void, Never>? {
        guard let item = imports.first(where: { $0.id == id && $0.state == .failed }), allowed(item.threadID),
              let original = importOwners[id], transport?.isCurrentScope(item.threadID, importScopes[id]) == true,
              payloads[id] != nil || references[id] != nil else { return nil }
        setState(id, .importing, nil)
        return own(item.threadID) { [self] owner in await prepareImport(id, captured: original, owner: owner) }
    }
    func removeImport(_ id: UUID) {
        guard !imports.contains(where: { $0.id == id && $0.state == .importing }),
              !pending.contains(where: { $0.purpose == .attachment(id) }) else { return }
        release(id)
    }
    func shutdown() async {
        stopping = true
        for (id, task) in jobs where !dispatched.contains(id) { task.cancel() }
        while !jobs.isEmpty { for task in Array(jobs.values) { await task.value } }
        _ = try? await metadataTail?.value
    }
    func cancelShutdown() { stopping = false }
    func suspend(threadIDs: Set<UUID>) async {
        suspendedThreads.formUnion(threadIDs)
        for (id, task) in jobs where threadIDs.contains(jobOwners[id] ?? UUID()) && !dispatched.contains(id) { task.cancel() }
        while true {
            let selected = jobs.filter { threadIDs.contains(jobOwners[$0.key] ?? UUID()) }.map(\.value)
            if selected.isEmpty { break }
            for task in selected { await task.value }
        }
    }
    func resume(threadIDs: Set<UUID>) { suspendedThreads.subtract(threadIDs) }
    /// Project deletion is explicit disposal of its transient selections, after
    /// every owned read and accepted command has joined. Saved prompts and
    /// original-ID receipts remain durable and available from the global stash.
    func forgetRemovedThreads(_ threadIDs: Set<UUID>) async {
        await suspend(threadIDs: threadIDs)
        for id in imports.filter({ threadIDs.contains($0.threadID) }).map(\.id) { release(id) }
        for id in threadIDs { reservedNames.removeValue(forKey: id) }
    }
    func flush() async {
        while !jobs.isEmpty { for task in Array(jobs.values) { await task.value } }
        _ = try? await metadataTail?.value
    }

    private func prepareImport(_ id: UUID, captured: ComposerDraftSnapshot, owner: UUID) async {
        let prior = importTail
        let task = Task { [self] in
            await prior?.value
            await prepareImportNow(id, captured: captured, owner: owner)
        }
        importTail = task
        await withTaskCancellationHandler { await task.value } onCancel: { task.cancel() }
    }
    private func prepareImportNow(_ id: UUID, captured: ComposerDraftSnapshot, owner: UUID) async {
        guard let transport, let item = imports.first(where: { $0.id == id }) else { return }
        do {
            try Task.checkCancellation()
            guard !hasUnresolved(item.threadID) else { throw CoincideError("Check the unconfirmed draft change before retrying this captured attachment.") }
            let reference: ChatAttachment
            if let value = references[id] { reference = value }
            else {
                guard let data = payloads[id] else { throw CoincideError("Choose this attachment again; its original bytes were not captured.") }
                reference = try await transport.importData(data, item.name); references[id] = reference
            }
            try Task.checkCancellation()
            guard allowed(item.threadID), let latest = transport.snapshot(item.threadID), Self.sameOwner(latest, captured) else {
                throw CoincideError("The attachment's original workspace changed. Its captured copy was kept.")
            }
            let text: String
            if let (anchor, range) = pasteAnchors[id], anchor.matches(latest), let replacement = ComposerPastePolicy.replacing(range, in: latest.text, with: "") { text = replacement.0 }
            else { text = latest.text }
            // A later paste/typing keeps its current text and selection; the
            // successfully captured attachment is simply added to that draft.
            var attachments = latest.attachments
            if !attachments.contains(where: { $0.id == reference.id }) { attachments.append(reference) }
            try AttachmentLimits.validate(attachments)
            let operation = ComposerPendingMutation(id: UUID(), purpose: .attachment(id), replacement: .init(expected: latest, text: text, attachments: attachments), ownerScope: jobScopes[owner])
            try await updateDocument { $0.pending.append(operation) }
            await dispatch(operation, owner: owner)
        } catch is CancellationError { fail(id, message: "Attachment import was interrupted. Its captured bytes are kept until you remove it.") }
        catch { fail(id, message: Self.message(error), report: true) }
    }
    private func dispatch(_ operation: ComposerPendingMutation, owner: UUID) async {
        guard let transport, allowed(operation.replacement.expected.threadID), !Task.isCancelled,
              transport.isCurrentScope(operation.replacement.expected.threadID, operation.ownerScope) else {
            // The command has never been handed to admission, so this is a
            // known refusal, not an unknown provider/draft outcome.
            try? await settle(operation, result: .rejected); return
        }
        dispatched.insert(owner); defer { dispatched.remove(owner) }
        let result: ComposerDraftToolsOutcome
        do { result = try await transport.replace(operation.id, operation.replacement) }
        catch { markUnknown(operation); return }
        do { try await settle(operation, result: result) }
        catch { errorMessage = "The draft change was recorded, but its local confirmation could not be saved. Check Result before trying again." }
    }
    private func settle(_ operation: ComposerPendingMutation, result: ComposerDraftToolsOutcome) async throws {
        guard result != .unknown else { markUnknown(operation); return }
        try await updateDocument { value in
            value.pending.removeAll { $0.id == operation.id }
            if result == .applied, case .restore(let entryID) = operation.purpose { value.entries.removeAll { $0.id == entryID } }
        }
        if case .attachment(let id) = operation.purpose {
            if result == .applied {
                if pasteAnchors[id] != nil, let item = imports.first(where: { $0.id == id }) {
                    notice = "Large paste attached as \(item.name). Use ⌘⇧V to paste text inline."
                }
                release(id)
            }
            else { fail(id, message: "The draft changed before the attachment was added. Retry to add the same captured copy to the current draft.") }
        }
        if result == .rejected { errorMessage = "The draft or workspace changed. Your current draft and saved prompt were kept." }
        else { errorMessage = nil }
    }
    private func markUnknown(_ operation: ComposerPendingMutation) {
        if case .attachment(let id) = operation.purpose { setState(id, .unconfirmed, "Check Result before retrying. This import has not been repeated.") }
        errorMessage = "The draft change is unconfirmed. Check Result; it will not be repeated automatically."
    }
    private func updateDocument(_ body: @escaping @MainActor (inout ComposerDraftToolsDocument) throws -> Void) async throws {
        let prior = metadataTail
        let task = Task { [self] in
            _ = try? await prior?.value
            if !isLoaded {
                document = try await persistence.load(); isLoaded = true; entries = document.entries; pending = document.pending
                restorePendingImports()
            }
            var next = document; try body(&next)
            try await persistence.save(next)
            document = next; entries = next.entries; pending = next.pending
        }
        metadataTail = task; try await task.value
    }
    @discardableResult private func own(_ threadID: UUID, _ body: @escaping @MainActor (UUID) async -> Void) -> Task<Void, Never> {
        let id = UUID(); activeThreads[threadID, default: 0] += 1; jobOwners[id] = threadID
        jobScopes[id] = transport?.captureScope(threadID)
        let task = Task { [self] in
            defer { jobs.removeValue(forKey: id); jobOwners.removeValue(forKey: id); jobScopes.removeValue(forKey: id); activeThreads[threadID, default: 1] -= 1 }
            await body(id)
        }
        jobs[id] = task; return task
    }
    private func reserveSlots(_ count: Int, snapshot: ComposerDraftSnapshot) -> Bool {
        guard count > 0, count <= AttachmentLimits.count - snapshot.attachments.count - importItems(snapshot.threadID).count,
              !hasUnresolved(snapshot.threadID) else {
            let message = "Attach up to 100 files, and check any unconfirmed draft changes first."
            errorMessage = message; transport?.reportError(snapshot.threadID, message); return false
        }
        return true
    }
    private func addImport(_ threadID: UUID, name: String, owner: ComposerDraftSnapshot) -> UUID {
        let id = UUID(); importOwners[id] = owner; importScopes[id] = transport?.captureScope(threadID)
        imports.append(.init(id: id, threadID: threadID, name: name, state: .importing)); return id
    }
    private func retain(_ data: Data, id: UUID) throws {
        guard data.count <= AttachmentLimits.fileBytes, data.count <= maximumRetainedBytes - reservedBytes else { throw CoincideError("Captured attachment retries are full. Remove a failed attachment before choosing more files.") }
        payloads[id] = data; reservedBytes += data.count
    }
    private func release(_ id: UUID) {
        if let data = payloads.removeValue(forKey: id) { reservedBytes -= data.count }
        references.removeValue(forKey: id); importScopes.removeValue(forKey: id); pasteAnchors.removeValue(forKey: id); importOwners.removeValue(forKey: id); imports.removeAll { $0.id == id }
    }
    private func rename(_ id: UUID, to name: String) {
        guard let index = imports.firstIndex(where: { $0.id == id }) else { return }
        let prior = imports[index]
        imports[index] = .init(id: id, threadID: prior.threadID, name: name, state: prior.state, message: prior.message)
    }
    private func setState(_ id: UUID, _ state: ComposerAttachmentImport.State, _ message: String?) {
        guard let index = imports.firstIndex(where: { $0.id == id }) else { return }
        imports[index].state = state; imports[index].message = message
    }
    private func fail(_ id: UUID, message: String, unreadable: Bool = false, report: Bool = false) {
        setState(id, unreadable ? .needsReattach : .failed, message)
        if report, let item = imports.first(where: { $0.id == id }) { transport?.reportError(item.threadID, message) }
    }
    private static func sameOwner(_ lhs: ComposerDraftSnapshot, _ rhs: ComposerDraftSnapshot) -> Bool {
        lhs.threadID == rhs.threadID && lhs.projectID == rhs.projectID && lhs.workspacePath.utf8.elementsEqual(rhs.workspacePath.utf8)
    }
    private func allowed(_ threadID: UUID) -> Bool { !stopping && !suspendedThreads.contains(threadID) && transport?.canOperate(threadID) == true }
    private func restorePendingImports() {
        for operation in pending {
            guard case .attachment(let id) = operation.purpose, !imports.contains(where: { $0.id == id }) else { continue }
            let prior = Set(operation.replacement.expected.attachments.map(\.id))
            guard let reference = operation.replacement.attachments.first(where: { !prior.contains($0.id) }) else { continue }
            let owner = operation.replacement.expected
            importOwners[id] = owner; importScopes[id] = operation.ownerScope; references[id] = reference
            imports.append(.init(id: id, threadID: owner.threadID, name: reference.name, state: .unconfirmed,
                message: "Check Result before retrying. This import has not been repeated."))
        }
    }
    private static func message(_ error: any Error) -> String {
        (error as? CoincideError)?.localizedDescription ?? "This draft action could not finish. Your existing draft and saved prompts were kept."
    }
    private func capture(_ body: @escaping @MainActor () async throws -> Data) async throws -> Data {
        let prior = captureTail
        let task = Task { await prior?.value; try Task.checkCancellation(); return try await body() }
        captureTail = Task { _ = try? await task.value }
        return try await withTaskCancellationHandler { try await task.value } onCancel: { task.cancel() }
    }
    nonisolated private static func readSelection(_ url: URL) throws -> Data {
        let scoped = url.startAccessingSecurityScopedResource(); defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        guard url.isFileURL, try url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile == true else { throw CoincideError("Attach a regular file, not a folder.") }
        let handle = try FileHandle(forReadingFrom: url); defer { try? handle.close() }
        var data = Data()
        while data.count <= AttachmentLimits.fileBytes {
            try Task.checkCancellation()
            let next = try handle.read(upToCount: min(256 * 1_024, AttachmentLimits.fileBytes + 1 - data.count)) ?? Data()
            if next.isEmpty { break }
            data.append(next)
        }
        guard data.count <= AttachmentLimits.fileBytes else { throw CoincideError("Files must be 50 MiB or smaller.") }
        return data
    }
}
