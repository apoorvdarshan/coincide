import AppKit
import CoincideCore
import Foundation
import Observation

@MainActor @Observable
final class RemoteComposerStore {
    private(set) var tools: ComposerDraftToolsStore?
    private(set) var scope: RemoteComposerScope?
    private(set) var retainedDrafts: [RemoteComposerRecord] = []
    private(set) var selected: [ChatAttachment] = []
    private(set) var isLoading = false
    private(set) var errorMessage: String?
    private(set) var isSaving = false
    private var text = ""
    @ObservationIgnored private let root: URL
    @ObservationIgnored private var persistence: RemoteComposerPersistence?
    @ObservationIgnored private var environmentID: UUID?
    @ObservationIgnored private var host: [ChatAttachment] = []
    @ObservationIgnored private var locals: [ChatAttachment] = []
    @ObservationIgnored private var remoteAccess: AttachmentAccess?
    @ObservationIgnored private var localAccess: AttachmentAccess?
    @ObservationIgnored private var current: (@MainActor (RemoteComposerScope) -> Bool)?
    @ObservationIgnored private var publish: (@MainActor (RemoteComposerScope, String, String) -> Bool)?
    @ObservationIgnored private var currentText: (@MainActor () -> String)?
    @ObservationIgnored private var tail: Task<Bool, Never>?
    @ObservationIgnored private var reads: [UUID: Task<Data, any Error>] = [:]
    @ObservationIgnored private var actions: [UUID: Task<Void, Never>] = [:]
    @ObservationIgnored private var jobs: [UUID: Task<Void, Never>] = [:]
    @ObservationIgnored private var generation = UUID()
    @ObservationIgnored private var stopping = false
    init(root: URL) { self.root = root }
    var hasUnsavedDrafts: Bool { isSaving || errorMessage != nil || tools?.pending.isEmpty == false || tools?.imports.isEmpty == false }
    var hasAttachments: Bool { !selected.isEmpty }
    var canOperate: Bool { !stopping && !isLoading && scope.map { current?($0) == true } == true }
    var blocksSubmission: Bool { !canOperate || isSaving || errorMessage != nil || scope.map { tools?.blocksSubmission($0.threadID) == true } == true }
    var draft: String { text }

    func select(scope: RemoteComposerScope?, text initial: String, host: [ChatAttachment], locals: [ChatAttachment],
                remoteAccess: AttachmentAccess?, localAccess: AttachmentAccess?,
                isCurrent: @escaping @MainActor (RemoteComposerScope) -> Bool,
                publish: @escaping @MainActor (RemoteComposerScope, String, String) -> Bool, currentText: @escaping @MainActor () -> String) async {
        guard !stopping else { return }
        if let scope, self.scope?.matches(scope) == true, isLoading { return }
        let carried = self.scope.flatMap { old -> ComposerDraftSnapshot? in
            guard let scope, old.sameDraftIdentity(scope), old.hostID == scope.hostID else { return nil }; return snapshot(old)
        }
        let token = UUID(); generation = token
        guard let scope else { self.scope = nil; isLoading = false; return }
        if environmentID != scope.environmentID {
            await tools?.shutdown(); _ = await tail?.value
            guard generation == token, !stopping else { return }
            environmentID = scope.environmentID
            let directory = root.appendingPathComponent(scope.environmentID.uuidString.lowercased(), isDirectory: true)
            persistence = .init(root: directory); tools = .init(root: directory.appendingPathComponent("Stashes", isDirectory: true)); tail = nil
            bindTools()
        }
        self.current = isCurrent; self.publish = publish; self.currentText = currentText
        self.remoteAccess = remoteAccess; self.localAccess = localAccess
        let previousHost = Set(self.host.map(\.id))
        self.host = host; self.locals = locals
        if self.scope?.matches(scope) == true {
            // Newly captured native/legacy uploads are additive; a deliberately
            // deselected host ref remains deselected in the same source scope.
            let known = Set(selected.map(\.id))
            let additions = host.filter { !previousHost.contains($0.id) && !known.contains($0.id) }
            if !additions.isEmpty { mutate(text: text, attachments: selected + additions) }
            return
        }
        self.scope = scope; isLoading = true
        defer { if generation == token { isLoading = false } }
        do {
            guard let persistence else { return }
            _ = await tail?.value
            let saved = try await persistence.record(scope)
            guard generation == token, self.scope?.matches(scope) == true, !stopping, isCurrent(scope) else { return }
            if let carried {
                text = currentText(); selected = carried.attachments
                let known = Set(selected.map(\.id))
                selected += host.filter { !previousHost.contains($0.id) && !known.contains($0.id) }
                try AttachmentLimits.validate(selected)
                _ = try await persistence.write(.init(scope: scope, draft: snapshot(scope)), expected: saved?.draft)
            } else if let saved {
                selected = saved.draft.attachments
                if publish(scope, saved.draft.text, initial) { text = saved.draft.text }
                else { text = currentText(); _ = enqueue(record: .init(scope: scope, draft: snapshot(scope)), expected: saved.draft, persistence: persistence) }
            }
            else {
                text = initial; selected = host + locals
                try AttachmentLimits.validate(selected)
                let record = RemoteComposerRecord(scope: scope, draft: snapshot(scope))
                let result = try await persistence.write(record, expected: nil)
                guard result == .applied else { throw RemoteAttachmentFailure(.unavailable) }
            }
            retainedDrafts = try await persistence.records().filter { !$0.scope.matches(scope) && (!$0.draft.text.isEmpty || !$0.draft.attachments.isEmpty) }
            guard generation == token, !stopping else { return }
            errorMessage = nil; await tools?.load()
            guard generation == token, !stopping else { return }
            let latest = currentText()
            if !latest.utf8.elementsEqual(text.utf8) { mutate(text: latest, attachments: selected, publishing: false) }
        } catch { if generation == token { errorMessage = "The scoped remote draft could not be loaded or saved. Existing private drafts were kept." } }
    }
    private func bindTools() {
        tools?.bind(.init(snapshot: { [weak self] id in guard let self, self.canOperate, self.scope?.threadID == id, let scope = self.scope else { return nil }; return self.snapshot(scope) },
            replace: { [weak self] id, replacement in guard let self else { return .rejected }; return await self.replace(id, replacement) },
            receipt: { [weak self] id, replacement in
                guard let self, let persistence = self.persistence else { return nil }
                _ = await self.tail?.value
                let result = try await persistence.receipt(id, replacement: replacement)
                if result == .applied, let scope = self.scope, let saved = try await persistence.record(scope),
                   self.scope?.matches(scope) == true, saved.draft.matches(self.snapshot(scope)) { self.errorMessage = nil }
                return result
            },
            importData: { [weak self] bytes, name in guard let self, let persistence = self.persistence, self.canOperate else { throw CancellationError() }; return try await persistence.importData(bytes, name: name) },
            verify: { [weak self] reference in guard let self else { throw CancellationError() }; _ = try await self.data(reference) },
            canOperate: { [weak self] id in self?.canOperate == true && self?.scope?.threadID == id },
            reportError: { [weak self] _, message in self?.errorMessage = message },
            captureScope: { [weak self] id in guard let scope = self?.scope, scope.threadID == id else { return nil }; return try? RemoteComposerScope.bytes(scope) },
            isCurrentScope: { [weak self] id, bytes in guard let self, let scope = self.scope, scope.threadID == id, let bytes else { return false }; return (try? RemoteComposerScope.bytes(scope)) == bytes && self.canOperate }))
    }
    private func snapshot(_ scope: RemoteComposerScope) -> ComposerDraftSnapshot { .init(threadID: scope.threadID, projectID: scope.projectID, workspacePath: scope.workspacePath, text: text, attachments: selected) }
    func setText(_ value: String) { guard canOperate, !value.utf8.elementsEqual(text.utf8) else { return }; mutate(text: value, attachments: selected, publishing: false) }
    private func mutate(text value: String, attachments: [ChatAttachment], publishing: Bool = true) {
        guard let scope, let persistence, value.utf16.count <= 120_000 else { return }
        let before = snapshot(scope); text = value; selected = attachments
        let after = snapshot(scope)
        if publishing, publish?(scope, value, before.text) != true {
            text = currentText?() ?? before.text; selected = before.attachments; return
        }
        _ = enqueue(record: .init(scope: scope, draft: after), expected: before, persistence: persistence)
    }
    private func enqueue(record: RemoteComposerRecord, expected: ComposerDraftSnapshot, persistence: RemoteComposerPersistence,
                         commandID: UUID? = nil, replacement: ComposerDraftReplacement? = nil) -> Task<Bool, Never> {
        let previous = tail; isSaving = true
        let task = Task { [weak self] in
            _ = await previous?.value
            do {
                _ = try await persistence.write(record, expected: expected, commandID: commandID, replacement: replacement)
                if self?.scope?.matches(record.scope) == true { self?.errorMessage = nil }; return true
            } catch { if self?.scope?.matches(record.scope) == true { self?.errorMessage = "The local remote draft change is unconfirmed. Its original result can be checked; it has not been repeated." }; return false }
        }
        tail = task
        let observer = UUID()
        jobs[observer] = Task { [weak self] in
            _ = await task.value
            guard let self else { return }; self.jobs.removeValue(forKey: observer)
            if self.jobs.isEmpty { self.isSaving = false }
        }
        return task
    }
    private func replace(_ id: UUID, _ replacement: ComposerDraftReplacement) async -> ComposerDraftToolsOutcome {
        guard canOperate, let scope, let persistence, replacement.expected.matches(snapshot(scope)) else { return .rejected }
        do {
            // Stashing may remove the last live host reference. Capture each
            // original through its exact AttachmentAccess before clearing it.
            for reference in replacement.expected.attachments { _ = try await data(reference) }
            guard canOperate, self.scope?.matches(scope) == true, replacement.expected.matches(snapshot(scope)) else { return .rejected }
            let before = snapshot(scope)
            guard publish?(scope, replacement.text, before.text) == true else { return .rejected }
            text = replacement.text; selected = replacement.attachments
            let write = enqueue(record: .init(scope: scope, draft: snapshot(scope)), expected: before, persistence: persistence, commandID: id, replacement: replacement)
            return await write.value ? .applied : .unknown
        } catch is CancellationError { return .rejected }
        catch { if !stopping, self.scope?.matches(scope) == true { errorMessage = "The original attachment bytes could not be captured. The draft and saved prompt were kept." }; return .rejected }
    }
    func data(_ reference: ChatAttachment) async throws -> Data {
        guard let persistence else { throw RemoteAttachmentFailure(.unavailable) }
        if let bytes = try await persistence.data(reference) { return bytes }
        guard canOperate, let captured = scope else { throw RemoteAttachmentFailure(.unavailable) }
        let bytes: Data
        if host.contains(where: { ComposerDraftSnapshot.sameAttachments([$0], [reference]) }), let remoteAccess { bytes = try await remoteAccess.data(reference) }
        else if locals.contains(where: { ComposerDraftSnapshot.sameAttachments([$0], [reference]) }), let localAccess { bytes = try await localAccess.data(reference) }
        else { throw RemoteAttachmentFailure(.notFound) }
        guard canOperate, scope?.matches(captured) == true else { throw CancellationError() }
        _ = try await persistence.importData(bytes, name: reference.name, original: reference)
        return bytes
    }
    private func readContent(_ reference: ChatAttachment, scope captured: RemoteComposerScope?, copies: RemoteComposerPersistence?) async throws -> Data {
        guard !stopping, let copies else { throw CancellationError() }
        let id = UUID()
        let task = Task<Data, any Error> { [weak self] in
            guard let self else { throw CancellationError() }
            defer { self.reads.removeValue(forKey: id) }
            let bytes: Data
            if let saved = try await copies.data(reference) { bytes = saved }
            else {
                guard let captured, self.scope?.matches(captured) == true else { throw CancellationError() }
                bytes = try await self.data(reference)
            }
            try Task.checkCancellation(); guard !self.stopping else { throw CancellationError() }; return bytes
        }
        reads[id] = task
        return try await withTaskCancellationHandler { try await task.value } onCancel: { task.cancel() }
    }
    private func contentError(_ message: String, scope captured: RemoteComposerScope?) {
        guard !stopping, let captured, scope?.matches(captured) == true else { return }; errorMessage = message
    }
    private func contentAction(_ operation: @escaping @MainActor () async -> Void) async {
        guard !stopping else { return }; let id = UUID()
        let task = Task<Void, Never> { [weak self] in await operation(); _ = self?.actions.removeValue(forKey: id) }
        actions[id] = task; await task.value
    }
    var access: AttachmentAccess {
        let captured = scope, copies = persistence
        let read: @MainActor (ChatAttachment) async throws -> Data = { [weak self] reference in
            guard let self else { throw CancellationError() }
            return try await self.readContent(reference, scope: captured, copies: copies)
        }
        return .init(id: "remote-composer-" + (captured?.key ?? "unavailable"), data: read,
            open: { [weak self] reference in
                guard let self else { return }; await self.contentAction {
                do {
                    _ = try await read(reference); try Task.checkCancellation()
                    guard let url = try await copies?.url(reference) else { throw RemoteAttachmentFailure(.notFound) }
                    try Task.checkCancellation()
                    _ = NSWorkspace.shared.open(url)
                } catch { self.contentError("The verified private attachment copy could not be opened.", scope: captured) }
                }
            }, copyImage: { [weak self] reference in
                guard let self else { return }; await self.contentAction {
                do {
                    let bytes = try await read(reference); try Task.checkCancellation()
                    guard reference.isImage, let image = NSImage(data: bytes) else { throw RemoteAttachmentFailure(.integrity) }
                    NSPasteboard.general.clearContents(); NSPasteboard.general.writeObjects([image])
                } catch { self.contentError("The verified image could not be copied.", scope: captured) }
                }
            }, save: { [weak self] reference in
                let panel = NSSavePanel(); panel.nameFieldStringValue = reference.name
                panel.begin { response in
                    guard response == .OK, let url = panel.url else { return }
                    Task { @MainActor in
                        guard let self else { return }; await self.contentAction {
                        do {
                            let bytes = try await read(reference); try Task.checkCancellation()
                            let access = url.startAccessingSecurityScopedResource(); defer { if access { url.stopAccessingSecurityScopedResource() } }
                            try bytes.write(to: url, options: .atomic)
                        } catch { self.contentError("The verified private attachment copy could not be saved.", scope: captured) }
                        }
                    }
                }
            })
    }
    func copyRetainedDraft(_ record: RemoteComposerRecord, expectedScope: RemoteComposerScope) async {
        guard canOperate, let captured = scope, captured.matches(expectedScope), let tools, !tools.isWorking(captured.threadID), !tools.hasUnresolved(captured.threadID),
              record.scope.environmentID == captured.environmentID, let persistence else { return }
        do {
            for reference in record.draft.attachments {
                guard try await persistence.data(reference) != nil else { throw RemoteAttachmentFailure(.notFound) }
            }
            guard canOperate, scope?.matches(captured) == true else { return }
            let expected = snapshot(captured)
            let combined = record.draft.text.isEmpty ? text : text.isEmpty ? record.draft.text : text + "\n\n" + record.draft.text
            var references = selected
            for reference in record.draft.attachments {
                if let existing = references.first(where: { $0.id == reference.id }) {
                    guard ComposerDraftSnapshot.sameAttachments([existing], [reference]) else { throw RemoteAttachmentFailure(.collision) }
                } else { references.append(reference) }
            }
            try AttachmentLimits.validate(references)
            guard combined.utf16.count <= 120_000 else { throw RemoteAttachmentFailure(.limitExceeded) }
            await tools.replaceSelection(.init(expected: expected, text: combined, attachments: references))?.value
        } catch { if !stopping, scope?.matches(captured) == true { errorMessage = "The saved local draft was kept. A complete private attachment copy is unavailable, or the merged draft exceeds its limit." } }
    }
    func chooseAttachments() {
        guard canOperate, let captured = scope else { return }
        let panel = NSOpenPanel(); panel.canChooseDirectories = false; panel.canChooseFiles = true
        panel.allowsMultipleSelection = true; panel.prompt = "Attach"
        panel.begin { [weak self] response in
            guard response == .OK, let self, self.canOperate, self.scope?.matches(captured) == true else { return }
            self.tools?.importFiles(panel.urls, threadID: captured.threadID)
        }
    }
    func remove(_ id: UUID) { guard canOperate, let scope, let tools else { return }; tools.replaceSelection(.init(expected: snapshot(scope), text: text, attachments: selected.filter { $0.id != id })) }
    func expand(_ attachment: ChatAttachment) { guard let scope else { return }; tools?.expandTextAttachment(attachment, threadID: scope.threadID, read: { [weak self] in guard let self else { throw CancellationError() }; return try await self.data($0) }) }
    func flush() async -> Bool { _ = await tail?.value; while !jobs.isEmpty { for job in Array(jobs.values) { await job.value } }; return errorMessage == nil }
    func acknowledgeSubmission(_ input: RemoteComposerSubmission) async {
        guard environmentID == input.target.environmentID, let persistence else { return }
        let captured = RemoteComposerScope(environmentID: input.target.environmentID, hostID: input.hostID,
            threadID: input.target.threadID, projectID: input.target.projectID, threadCreatedAt: input.threadCreatedAt,
            projectCreatedAt: input.projectCreatedAt, workspacePath: input.expectedConfiguration.workspacePath,
            configuration: RemoteComposerScope.fingerprint(input.expectedConfiguration))
        if scope?.sameDraftIdentity(captured) == true {
            let remaining = (try? RemoteComposerScope.digest(RemoteComposerScope.bytes(selected))) == input.selectionDigest ? [] : selected
            let value = text.utf8.elementsEqual(input.text.utf8) ? "" : text
            mutate(text: value, attachments: remaining)
            _ = await tail?.value
        } else {
            _ = await tail?.value
            do {
                if let saved = try await persistence.record(captured) {
                    let remaining = (try? RemoteComposerScope.digest(RemoteComposerScope.bytes(saved.draft.attachments))) == input.selectionDigest ? [] : saved.draft.attachments
                    let value = saved.draft.text.utf8.elementsEqual(input.text.utf8) ? "" : saved.draft.text
                    let replacement = ComposerDraftSnapshot(threadID: captured.threadID, projectID: captured.projectID, workspacePath: captured.workspacePath, text: value, attachments: remaining)
                    _ = try await persistence.write(.init(scope: captured, draft: replacement), expected: saved.draft)
                }
            } catch { errorMessage = "The accepted request's local composer draft could not be saved. Its original request remains available for inspection." }
        }
    }
    func disconnect() { generation = UUID(); scope = nil; current = nil; currentText = nil; remoteAccess = nil; localAccess = nil }
    func shutdown() async {
        stopping = true; disconnect()
        let reads = Array(reads.values), actions = Array(actions.values)
        for task in reads { task.cancel() }; for task in actions { task.cancel() }
        await tools?.shutdown(); _ = await tail?.value
        for task in reads { _ = await task.result }; for task in actions { await task.value }
        for job in Array(jobs.values) { await job.value }
    }
    func cancelShutdown() { stopping = false; tools?.cancelShutdown() }
}
