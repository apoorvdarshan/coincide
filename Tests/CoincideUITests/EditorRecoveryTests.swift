import Foundation
import Testing
@testable import Coincide
@testable import CoincideCore

private actor EditorRecoveryReadGate {
    private var waiting = false
    private var continuation: CheckedContinuation<Void, Never>?
    private var observers: [CheckedContinuation<Void, Never>] = []
    func pause() async {
        waiting = true; observers.forEach { $0.resume() }; observers = []
        await withCheckedContinuation { continuation = $0 }
    }
    func entered() async { if !waiting { await withCheckedContinuation { observers.append($0) } } }
    func release() { continuation?.resume(); continuation = nil }
}

@MainActor private struct EditorRecoveryNativeFixture {
    let root: URL, checkout: URL, database: URL
    let journal: EditorRecoveryJournal
    init() async throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("coincide-editor-recovery-\(UUID())").resolvingSymlinksInPath()
        checkout = root.appendingPathComponent("Checkout"); database = root.appendingPathComponent("workspace.sqlite")
        try FileManager.default.createDirectory(at: checkout, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try Data("Original file\n".utf8).write(to: checkout.appendingPathComponent("notes.txt"))
        let project = WorkspaceProject(path: checkout.path), thread = CodingThread(project: project)
        var snapshot = WorkspaceSnapshot(); snapshot.projects = [project]; snapshot.threads = [thread]
        try await WorkspaceDatabase(url: database).save(snapshot, event: "offline-editor-fixture")
        journal = .init(root: root.appendingPathComponent("Recovery"))
    }
    func open() async throws -> (WorkspaceStore, FileBrowserStore) {
        let engine = try WorkspaceEngine(url: database, providerFactory: { _ in throw CoincideError("The private editor fixture never starts providers.") }, identityResolver: { _ in nil })
        let store = WorkspaceStore(engine: engine); await store.load()
        let editor = FileBrowserStore(workspace: store, path: checkout.path, service: try store.fileService(path: checkout.path), recoveryJournal: journal)
        await editor.start(); return (store, editor)
    }
}

@MainActor @Test(.timeLimit(.minutes(1)))
func editorRecoveryNativeRestartRetainsExactTextAndOldRevisionRefusesChangedFilesUntilExplicitDiscard() async throws {
    let f = try await EditorRecoveryNativeFixture()
    defer { try? FileManager.default.removeItem(at: f.root) }
    let (firstStore, first) = try await f.open()
    let text = "  Recover e\u{301} 😀 工作\n trailing spaces  "
    #expect(await first.open("notes.txt")); first.setContents(text); await first.recovery.flush()
    #expect(first.recovery.isDurable && first.recovery.errorMessage == nil)
    #expect(try String(contentsOf: f.checkout.appendingPathComponent("notes.txt"), encoding: .utf8) == "Original file\n")
    await first.shutdown(); await firstStore.shutdown()
    let record = try #require(f.journal.load().first)
    try Data("External replacement\n".utf8).write(to: f.checkout.appendingPathComponent("notes.txt"), options: .atomic)
    let (secondStore, second) = try await f.open()
    do {
        #expect(second.recoveredDrafts.map(\.id) == [record.id])
        await second.restoreRecoveredDraft(record)
        #expect(Data(second.contents.utf8) == Data(text.utf8) && second.original == "Original file\n")
        #expect(second.hasExternalChanges && !second.recoveredRootUnavailable)
        await second.save()
        let recoveryCount = try f.journal.load().count
        #expect(second.isDirty && second.operationError != nil && recoveryCount == 1)
        #expect(try String(contentsOf: f.checkout.appendingPathComponent("notes.txt"), encoding: .utf8) == "External replacement\n")
        second.discardCurrentEdits(); await second.recovery.flush()
        #expect(try f.journal.load().isEmpty)
    } catch { await second.shutdown(); await secondStore.shutdown(); throw error }
    await second.shutdown(); await secondStore.shutdown()
}

@MainActor @Test(.timeLimit(.minutes(1)))
func editorRecoveryNativePositiveSaveClearsOnlyItsOwnDraftAndReplacedRootRemainsReadOnly() async throws {
    let f = try await EditorRecoveryNativeFixture()
    defer { try? FileManager.default.removeItem(at: f.root) }
    let (store, editor) = try await f.open()
    #expect(await editor.open("notes.txt")); editor.setContents("Positively saved"); await editor.recovery.flush(); await editor.save()
    let afterSave = try f.journal.load()
    #expect(!editor.isDirty && afterSave.isEmpty)
    editor.setContents("Unsent before folder replacement"); await editor.recovery.flush()
    let record = try #require(f.journal.load().first)
    await editor.shutdown(); await store.shutdown()
    try FileManager.default.moveItem(at: f.checkout, to: f.root.appendingPathComponent("Retained-original-folder"))
    try FileManager.default.createDirectory(at: f.checkout, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
    try Data("Replacement folder file".utf8).write(to: f.checkout.appendingPathComponent("notes.txt"))
    let (nextStore, next) = try await f.open()
    do {
        await next.restoreRecoveredDraft(record)
        #expect(next.contents == "Unsent before folder replacement" && next.recoveredRootUnavailable && !next.canWrite)
        await next.save(); #expect(try String(contentsOf: f.checkout.appendingPathComponent("notes.txt"), encoding: .utf8) == "Replacement folder file")
        #expect(try f.journal.load().count == 1)
    } catch { await next.shutdown(); await nextStore.shutdown(); throw error }
    await next.shutdown(); await nextStore.shutdown()
}

@MainActor @Test(.timeLimit(.minutes(1)))
func editorRecoveryCancelledRestoreCannotReplaceANewerLoadedAndEditedFileOrDeleteItsSavedDraft() async throws {
    let f = try await EditorRecoveryNativeFixture()
    defer { try? FileManager.default.removeItem(at: f.root) }
    try Data("Other baseline".utf8).write(to: f.checkout.appendingPathComponent("other.txt"))
    let (store, initial) = try await f.open()
    #expect(await initial.open("notes.txt")); initial.setContents("Retain older recovery"); await initial.recovery.flush()
    let saved = try #require(f.journal.load().first)
    await initial.shutdown()
    let gate = EditorRecoveryReadGate(), service = try store.fileService(path: f.checkout.path)
    let editor = FileBrowserStore(workspace: store, path: f.checkout.path, service: service, documentLoader: { path in
        if path == "notes.txt" { await gate.pause() }
        return try await service.readFile(relativePath: path)
    }, recoveryJournal: f.journal)
    let restoring = Task { await editor.restoreRecoveredDraft(saved) }
    await gate.entered(); restoring.cancel()
    #expect(await editor.open("other.txt"))
    let newest = "Newer loaded editor e\u{301} text  "
    editor.setContents(newest); await editor.recovery.flush()
    await gate.release(); await restoring.value
    #expect(editor.document?.relativePath == "other.txt" && editor.contents.utf8.elementsEqual(newest.utf8))
    let records = try f.journal.load()
    #expect(records.count == 2 && records.contains { $0.id == saved.id && $0.contents == "Retain older recovery" })
    #expect(records.contains { $0.relativePath == "other.txt" && $0.contents.utf8.elementsEqual(newest.utf8) })
    await editor.shutdown(); await store.shutdown()
}

private actor EditorRecoveryRemoteHost {
    let rootID = UUID()
    private var text = "Original remote bytes"
    private var revision = UUID()
    private var dropped = true
    private var requests: [RemoteWorkspaceMutationRequest] = []
    private var results: [UUID: RemoteWorkspaceOperation] = [:]
    nonisolated var transport: RemoteWorkspaceInspectorTransport {
        .init(bind: { target in await self.bind(target) }, read: { try await self.read($0) }, begin: { try await self.begin($0) },
            status: { await self.status($0) }, cancel: { await self.status($0) })
    }
    private func bind(_ target: RemoteWorkspaceTarget) -> RemoteWorkspaceTarget {
        .init(environmentID: target.environmentID, projectID: target.projectID, threadID: target.threadID, configuration: target.configuration, rootID: rootID)
    }
    private func document() -> RemoteWorkspaceDocument { .init(relativePath: "notes.txt", contents: text, byteLength: text.utf8.count, truncated: false, exists: true, revision: revision) }
    private func read(_ request: RemoteWorkspaceReadRequest) throws -> RemoteWorkspaceReadResult {
        switch request.query {
        case .readFile(let path, _, _):
            guard path == "notes.txt" else { throw RemoteWorkspaceFailure(.invalidRequest) }
            return .init(target: request.target, value: .document(document()))
        default: return .init(target: request.target, value: .entries(.init(entries: [], truncated: false)))
        }
    }
    private func begin(_ request: RemoteWorkspaceMutationRequest) throws -> RemoteWorkspaceOperation {
        guard case .saveFile(let path, let contents, let expected) = request.mutation, path == "notes.txt", expected == revision else { throw RemoteWorkspaceFailure(.conflict) }
        requests.append(request); text = contents; revision = UUID()
        let value = RemoteWorkspaceOperation(request: request, payloadDigest: "private-fixture", state: .finished, result: .document(document()), failure: nil, createdAt: Date(), updatedAt: Date())
        results[request.id] = value
        if dropped { dropped = false; throw RemoteEnvironmentClientError(.commandUncertain, commandID: request.id) }
        return value
    }
    private func status(_ request: RemoteWorkspaceMutationRequest) -> RemoteWorkspaceOperation? { results[request.id] }
    func count() -> Int { requests.count }
}

@MainActor @Test(.timeLimit(.minutes(1)))
func editorRecoveryRemoteLostSaveRestartAndLateReceiptPreserveNewerTextWithoutReplaying() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("coincide-editor-remote-\(UUID())").resolvingSymlinksInPath()
    defer { try? FileManager.default.removeItem(at: root) }
    let journal = EditorRecoveryJournal(root: root.appendingPathComponent("Recovery"))
    let pending = RemoteWorkspacePendingStore(root: root.appendingPathComponent("Pending")), host = EditorRecoveryRemoteHost()
    let project = WorkspaceProject(path: "/remote/opaque/cafe\u{301}")
    let thread = CodingThread(project: project), environment = UUID()
    let target = RemoteWorkspaceTarget(environmentID: environment, projectID: project.id, threadID: thread.id, configuration: .init(thread: thread))
    let first = RemoteWorkspaceInspectorModel(target: target, pendingStore: pending, recoveryJournal: journal)
    await first.session.connect(transport: host.transport, canMutate: true)
    #expect(await first.files.open("notes.txt"))
    first.files.setContents("Old explicitly saved text"); await first.files.flushRecovery(); await first.files.save()
    let afterDropped = try journal.load()
    #expect(first.session.pending != nil && afterDropped.count == 1)
    await first.files.flushRecovery(); await first.session.shutdown()
    let second = RemoteWorkspaceInspectorModel(target: target, pendingStore: pending, recoveryJournal: journal)
    await second.session.connect(transport: host.transport, canMutate: true)
    await second.files.refreshRecoveredDrafts()
    await second.files.restoreRecoveredDraft(try #require(second.files.recoveredDrafts.first))
    let latest = "Latest local e\u{301} 😀\nKeep every byte  "
    second.files.setContents(latest); await second.files.flushRecovery()
    #expect(await host.count() == 1)
    await second.session.checkResult(); await second.files.flushRecovery()
    #expect(second.files.contents.utf8.elementsEqual(latest.utf8) && second.files.buffer?.original == "Old explicitly saved text")
    let retained = try #require(journal.load().first)
    #expect(retained.contents.utf8.elementsEqual(latest.utf8) && retained.original == "Old explicitly saved text")
    let afterRecoveryBegins = await host.count()
    #expect(second.session.pending == nil && afterRecoveryBegins == 1)
    await second.files.save(); await second.files.flushRecovery()
    #expect(try journal.load().isEmpty)
    let afterExplicitSaveBegins = await host.count()
    #expect(afterExplicitSaveBegins == 2 && !second.files.isDirty)
    await second.session.shutdown()
}

@MainActor @Test(.timeLimit(.minutes(1)))
func editorRecoveryRemoteFolderIdentityMismatchKeepsDraftReadableAndForbidsSave() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("coincide-editor-remote-root-\(UUID())")
    defer { try? FileManager.default.removeItem(at: root) }
    let journal = EditorRecoveryJournal(root: root.appendingPathComponent("Recovery")), pending = RemoteWorkspacePendingStore(root: root.appendingPathComponent("Pending"))
    let host = EditorRecoveryRemoteHost(), other = EditorRecoveryRemoteHost()
    let project = WorkspaceProject(path: "/remote/opaque/workspace"), thread = CodingThread(project: project)
    let target = RemoteWorkspaceTarget(environmentID: UUID(), projectID: project.id, threadID: thread.id, configuration: .init(thread: thread))
    let first = RemoteWorkspaceInspectorModel(target: target, pendingStore: pending, recoveryJournal: journal)
    await first.session.connect(transport: host.transport, canMutate: true); #expect(await first.files.open("notes.txt"))
    first.files.setContents("Keep older folder draft"); await first.files.flushRecovery(); await first.session.shutdown()
    let next = RemoteWorkspaceInspectorModel(target: target, pendingStore: pending, recoveryJournal: journal)
    await next.session.connect(transport: other.transport, canMutate: true); await next.files.refreshRecoveredDrafts()
    await next.files.restoreRecoveredDraft(try #require(next.files.recoveredDrafts.first))
    #expect(next.files.contents == "Keep older folder draft" && next.files.recoveredRootChanged && !next.files.canSave)
    await next.files.save(); #expect(await other.count() == 0)
    #expect(try journal.load().count == 1)
    next.files.discardCurrentEdits(); await next.files.flushRecovery(); #expect(try journal.load().isEmpty)
    await next.session.shutdown()
}

@MainActor @Test(.timeLimit(.minutes(1)), arguments: [false, true])
func editorRecoveryLateSaveReceiptCannotRebaseOrRemoveAnotherRestoredDraftAtTheSamePath(replacedRoot: Bool) async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("coincide-editor-remote-receipt-\(UUID())")
    defer { try? FileManager.default.removeItem(at: root) }
    let journal = EditorRecoveryJournal(root: root.appendingPathComponent("Recovery")), pending = RemoteWorkspacePendingStore(root: root.appendingPathComponent("Pending"))
    let host = EditorRecoveryRemoteHost(), project = WorkspaceProject(path: "/remote/exact/editor-root")
    let thread = CodingThread(project: project)
    let target = RemoteWorkspaceTarget(environmentID: UUID(), projectID: project.id, threadID: thread.id, configuration: .init(thread: thread))
    let model = RemoteWorkspaceInspectorModel(target: target, pendingStore: pending, recoveryJournal: journal)
    await model.session.connect(transport: host.transport, canMutate: true)
    let bound = model.session.target
    let savedTarget = RemoteWorkspaceTarget(environmentID: bound.environmentID, projectID: bound.projectID, threadID: bound.threadID,
        configuration: bound.configuration, rootID: replacedRoot ? UUID() : bound.rootID)
    let text = "Same text as the pending save"
    let other = try EditorRecoveryRecord.remote(target: savedTarget,
        document: .init(relativePath: "notes.txt", contents: "Different recovered baseline", byteLength: 28, truncated: false, exists: true, revision: UUID()), contents: text)
    try journal.save(other, expectedVersion: nil)
    #expect(await model.files.open("notes.txt"))
    model.files.setContents(text); await model.files.flushRecovery(); await model.files.save()
    let request = try #require(model.session.pending)
    #expect(try journal.load().contains { $0.remoteOperationID == request.id && $0.id != other.id })
    model.files.discardCurrentEdits(); await model.files.flushRecovery()
    await model.files.restoreRecoveredDraft(other)
    #expect(model.files.buffer?.recovery.id == other.id)
    await model.session.checkResult(); await model.files.flushRecovery()
    #expect(model.files.contents == text && model.files.buffer?.original == "Different recovered baseline" && model.files.isDirty)
    #expect(try journal.load() == [other])
    #expect(model.session.pending == nil)
    #expect(await host.count() == 1)
    await model.session.shutdown()
}
