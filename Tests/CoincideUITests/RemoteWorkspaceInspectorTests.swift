import Foundation
import Testing
@testable import Coincide
@testable import CoincideCore

private actor RemoteInspectorBoundary {
    private var waiting = false
    private var released = false
    private var body: CheckedContinuation<Void, Never>?
    private var observers: [CheckedContinuation<Void, Never>] = []
    func pause() async {
        waiting = true; for observer in observers { observer.resume() }; observers = []
        if released { return }
        await withCheckedContinuation { body = $0 }
    }
    func entered() async {
        if waiting { return }
        await withCheckedContinuation { observers.append($0) }
    }
    func release() { released = true; body?.resume(); body = nil }
}

private actor RemoteInspectorHost {
    enum Mode { case completed, droppedReply, running }
    let rootID = UUID()
    let pendingStore: RemoteWorkspacePendingStore
    private var documents: [Data: RemoteWorkspaceDocument] = [:]
    private var operations: [UUID: RemoteWorkspaceOperation] = [:]
    private var begins: [RemoteWorkspaceMutationRequest] = []
    private var checks: [RemoteWorkspaceMutationRequest] = []
    private var cancellations: [RemoteWorkspaceMutationRequest] = []
    private var reads: [RemoteWorkspaceReadRequest] = []
    private var mode = Mode.completed
    private var readBoundary: RemoteInspectorBoundary?
    private var persistedBeforeBegin = true

    init(pendingStore: RemoteWorkspacePendingStore) {
        self.pendingStore = pendingStore
        for path in ["first.txt", "second.txt", "Caf\u{00e9}.txt", "Cafe\u{0301}.txt"] {
            documents[Data(path.utf8)] = .init(relativePath: path, contents: "Original \(path)", byteLength: 32,
                truncated: false, exists: true, revision: UUID())
        }
    }
    nonisolated var transport: RemoteWorkspaceInspectorTransport {
        .init(bind: { try await self.bind($0) }, read: { try await self.read($0) }, begin: { try await self.begin($0) },
            status: { try await self.status($0) }, cancel: { try await self.cancel($0) })
    }
    func setMode(_ value: Mode) { mode = value }
    func replaceRevision(path: String, contents: String? = nil) throws -> UUID {
        let previous = try #require(documents[Data(path.utf8)]), revision = UUID()
        let text = contents ?? previous.contents
        documents[Data(path.utf8)] = .init(relativePath: path, contents: text, byteLength: text.utf8.count,
            truncated: false, exists: true, revision: revision)
        return revision
    }
    func holdNextRead(_ boundary: RemoteInspectorBoundary) { readBoundary = boundary }
    func counts() -> (Int, Int, Int) { (begins.count, checks.count, cancellations.count) }
    func didPersistBeforeBegin() -> Bool { persistedBeforeBegin }
    func requests() -> [RemoteWorkspaceMutationRequest] { begins }
    func readRequests() -> [RemoteWorkspaceReadRequest] { reads }

    private func bind(_ target: RemoteWorkspaceTarget) throws -> RemoteWorkspaceTarget {
        guard target.rootID == nil || target.rootID == rootID else { throw RemoteWorkspaceFailure(.staleRoot) }
        return .init(environmentID: target.environmentID, projectID: target.projectID, threadID: target.threadID,
            configuration: target.configuration, rootID: rootID)
    }
    private func read(_ request: RemoteWorkspaceReadRequest) async throws -> RemoteWorkspaceReadResult {
        reads.append(request)
        let value: RemoteWorkspaceValue
        switch request.query {
        case .readFile(let path, _, _):
            let document = try #require(documents[Data(path.utf8)])
            if let boundary = readBoundary { readBoundary = nil; await boundary.pause() }
            value = .document(document)
        case .list, .searchPaths:
            value = .entries(.init(entries: [.init(path: "first.txt", kind: .file), .init(path: "second.txt", kind: .file)], truncated: false))
        case .searchContents(let query, _, _, _, _):
            value = .contents(.init(matches: [.init(path: "first.txt", lineNumber: 2, lineContent: query, matchRanges: [])], truncated: false))
        case .gitStatus:
            value = .git(.init(repositoryRoot: URL(fileURLWithPath: "/remote-only/inspector-project"), branch: "main", head: String(repeating: "a", count: 40),
                isDetached: false, upstream: "origin/main", ahead: 0, behind: 0,
                changes: [.init(path: "Caf\u{00e9}.txt", previousPath: nil, indexStatus: "M", worktreeStatus: " ")]))
        case .gitBranches: value = .branches([.init(ref: "refs/heads/main", upstream: "origin/main")])
        case .gitRemotes: value = .remotes(["origin"])
        case .gitDiff(let file, let staged): value = .diff("Diff: \(file?.path ?? "all") \(staged)")
        }
        return .init(target: request.target, value: value)
    }
    private func begin(_ request: RemoteWorkspaceMutationRequest) async throws -> RemoteWorkspaceOperation {
        let saved = try await pendingStore.load(environmentID: request.target.environmentID, threadID: request.target.threadID)
        let durableMatches = try saved.map(Self.bytes) == Self.bytes(request)
        persistedBeforeBegin = persistedBeforeBegin && durableMatches
        begins.append(request)
        var result: RemoteWorkspaceValue = .done
        var failure: RemoteWorkspaceFailure?
        switch request.mutation {
        case .saveFile(let path, let contents, let revision):
            if documents[Data(path.utf8)]?.revision != revision { failure = .init(.conflict) }
            else {
                let value = RemoteWorkspaceDocument(relativePath: path, contents: contents, byteLength: contents.utf8.count,
                    truncated: false, exists: true, revision: UUID())
                documents[Data(path.utf8)] = value; result = .document(value)
            }
        case .createFile(let path, let contents):
            if documents[Data(path.utf8)] != nil { failure = .init(.conflict) }
            else {
                let value = RemoteWorkspaceDocument(relativePath: path, contents: contents, byteLength: contents.utf8.count,
                    truncated: false, exists: true, revision: UUID())
                documents[Data(path.utf8)] = value; result = .document(value)
            }
        default: break
        }
        let now = Date()
        let operation = RemoteWorkspaceOperation(request: request, payloadDigest: "owned-offline-digest",
            state: mode == .running ? .running : .finished, result: mode == .running || failure != nil ? nil : result, failure: failure, createdAt: now, updatedAt: now)
        operations[request.id] = operation
        if mode == .droppedReply { throw RemoteEnvironmentClientError(.commandUncertain, commandID: request.id) }
        return operation
    }
    private func status(_ request: RemoteWorkspaceMutationRequest) throws -> RemoteWorkspaceOperation? {
        checks.append(request)
        guard let operation = operations[request.id] else { return nil }
        guard try Self.bytes(operation.request) == Self.bytes(request) else { throw RemoteWorkspaceFailure(.commandCollision) }
        return operation
    }
    private func cancel(_ request: RemoteWorkspaceMutationRequest) throws -> RemoteWorkspaceOperation? {
        cancellations.append(request)
        guard var operation = try status(request) else { return nil }
        operation.state = .uncertain; operation.result = nil; operation.failure = .init(.interrupted); operation.updatedAt = Date()
        operations[request.id] = operation
        return operation
    }
    private static func bytes(_ value: RemoteWorkspaceMutationRequest) throws -> Data {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]; return try encoder.encode(value)
    }
}

@MainActor private struct RemoteInspectorFixture {
    let root: URL
    let pendingStore: RemoteWorkspacePendingStore
    let host: RemoteInspectorHost
    let model: RemoteWorkspaceInspectorModel
    let thread: CodingThread
    init() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("coincide-remote-inspector-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        pendingStore = RemoteWorkspacePendingStore(root: root)
        host = RemoteInspectorHost(pendingStore: pendingStore)
        let project = WorkspaceProject(path: "/remote-only/inspector-project"); thread = CodingThread(project: project)
        model = RemoteWorkspaceInspectorModel(target: .init(environmentID: UUID(), projectID: project.id,
            threadID: thread.id, configuration: .init(thread: thread)), pendingStore: pendingStore)
    }
    func remove() { model.session.disconnect(); try? FileManager.default.removeItem(at: root) }
    func connect() async { await model.session.connect(transport: host.transport, canMutate: true) }
}

@Test(.timeLimit(.minutes(1))) @MainActor
func remoteInspectorFileQueriesUseExactTargetAndRetainDirtyBuffersAcrossSelectionAndDisconnect() async throws {
    let f = try RemoteInspectorFixture(); defer { f.remove() }
    await f.connect()
    await f.model.files.reloadEntries()
    #expect(f.model.files.entries.count == 2)
    f.model.files.searchMode = .contents; f.model.files.query = "Remote needle"; f.model.files.caseSensitive = true
    await f.model.files.reloadEntries()
    #expect(f.model.files.contentMatches.first?.lineContent == "Remote needle")
    #expect(await f.model.files.open("first.txt"))
    f.model.files.setContents("First unsaved editor")
    #expect(await f.model.files.open("second.txt"))
    f.model.files.setContents("Second unsaved editor")
    #expect(await f.model.files.open("first.txt"))
    #expect(f.model.files.contents == "First unsaved editor" && f.model.hasUnsavedEdits)
    f.model.session.disconnect()
    f.model.files.setContents("Newer disconnected first editor")
    #expect(!f.model.files.canSave && f.model.files.canEdit)
    #expect(await f.model.files.open("second.txt"))
    #expect(f.model.files.contents == "Second unsaved editor")
    let requests = await f.host.readRequests()
    #expect(requests.allSatisfy { $0.target.environmentID == f.model.session.target.environmentID && $0.target.threadID == f.thread.id && $0.target.rootID != nil })
    #expect(requests.contains { if case .searchContents("Remote needle", 500, true, false, false) = $0.query { true } else { false } })
    #expect(await f.host.counts().0 == 0)
}

@Test(.timeLimit(.minutes(1))) @MainActor
func remoteInspectorLostSaveReplyKeepsExactIntentAndNewerUnicodeEditorThenReconcilesWithoutReplay() async throws {
    let f = try RemoteInspectorFixture(); defer { f.remove() }
    await f.connect(); #expect(await f.model.files.open("first.txt"))
    let originalRevision = try #require(f.model.files.document?.revision)
    let sent = "Saved Caf\u{00e9}", newer = "Saved Cafe\u{0301}"
    f.model.files.setContents(sent); await f.host.setMode(.droppedReply)
    await f.model.files.save()
    let request = try #require(f.model.session.pending)
    #expect(try await f.pendingStore.load(environmentID: request.target.environmentID, threadID: request.target.threadID)?.id == request.id)
    if case .saveFile("first.txt", let text, originalRevision) = request.mutation { #expect(Array(text.utf8) == Array(sent.utf8)) }
    else { Issue.record("Save must carry the original opaque revision.") }
    f.model.session.disconnect(); f.model.files.setContents(newer)
    await f.connect(); await f.model.files.save()
    #expect(await f.host.counts().0 == 1)
    await f.model.session.checkResult()
    #expect(f.model.session.pending == nil && f.model.files.isDirty)
    #expect(Array(f.model.files.contents.utf8) == Array(newer.utf8))
    #expect(f.model.files.buffer?.original.utf8.elementsEqual(sent.utf8) == true)
    #expect(f.model.files.document?.revision != originalRevision)
    #expect(await f.host.didPersistBeforeBegin())
    #expect(await f.host.counts().0 == 1)
}

@Test(.timeLimit(.minutes(1))) @MainActor
func remoteInspectorReloadAndDisconnectedReadNeverOverwriteNewerEditorText() async throws {
    let f = try RemoteInspectorFixture(); defer { f.remove() }
    await f.connect(); #expect(await f.model.files.open("first.txt"))
    f.model.files.setContents("Edits before explicit reload")
    let boundary = RemoteInspectorBoundary(); await f.host.holdNextRead(boundary)
    let reload = Task { await f.model.files.open("first.txt", reload: true, discardChanges: true) }
    await boundary.entered()
    f.model.files.setContents("Newer text typed while Reload waits")
    await boundary.release()
    #expect(await reload.value == false)
    #expect(f.model.files.contents == "Newer text typed while Reload waits")
    let disconnectBoundary = RemoteInspectorBoundary(); await f.host.holdNextRead(disconnectBoundary)
    let read = Task { await f.model.files.open("second.txt") }
    await disconnectBoundary.entered(); f.model.session.disconnect(); await disconnectBoundary.release()
    #expect(await read.value == false)
    #expect(f.model.files.selectedPath == "first.txt" && f.model.files.contents == "Newer text typed while Reload waits")
}

@Test(.timeLimit(.minutes(1))) @MainActor
func remoteInspectorSaveReacquiresExpiredRevisionWithoutDiscardingEditsAndRefusesChangedBase() async throws {
    let f = try RemoteInspectorFixture(); defer { f.remove() }
    await f.connect(); #expect(await f.model.files.open("first.txt"))
    let originalRevision = f.model.files.document?.revision
    f.model.files.setContents("Edited before reconnect")
    f.model.session.disconnect()
    let renewed = try await f.host.replaceRevision(path: "first.txt")
    #expect(renewed != originalRevision)
    await f.connect(); await f.model.files.save()
    #expect(!f.model.files.isDirty && f.model.files.contents == "Edited before reconnect")
    let request = try #require(await f.host.requests().first)
    if case .saveFile(_, _, let revision) = request.mutation { #expect(revision == renewed) }
    else { Issue.record("Expected an explicit guarded file save.") }
    f.model.files.setContents("Keep this newer local editor")
    _ = try await f.host.replaceRevision(path: "first.txt", contents: "Changed independently on remote Mac")
    await f.model.files.save()
    #expect(f.model.files.isDirty && f.model.files.contents == "Keep this newer local editor")
    #expect(f.model.files.buffer?.hasExternalChanges == true && f.model.files.operationError == RemoteWorkspaceFailure(.conflict).localizedDescription)
    #expect(await f.host.counts().0 == 1)
}

@Test(.timeLimit(.minutes(1))) @MainActor
func remoteInspectorMovedThreadRecoversOldExactRequestWithoutApplyingItToNewRootEditor() async throws {
    let f = try RemoteInspectorFixture(); defer { f.remove() }
    await f.connect(); #expect(await f.model.files.open("first.txt"))
    f.model.files.setContents("Submitted to the old root")
    await f.host.setMode(.droppedReply); await f.model.files.save()
    let pending = try #require(f.model.session.pending)
    f.model.session.disconnect()
    var thread = f.thread; thread.workspacePath = "/remote-only/another-worktree"
    let current = RemoteWorkspaceInspectorModel(target: .init(environmentID: pending.target.environmentID, projectID: thread.projectID,
        threadID: thread.id, configuration: .init(thread: thread)), pendingStore: f.pendingStore)
    defer { current.session.disconnect() }
    await current.session.connect(transport: f.host.transport, canMutate: true)
    #expect(current.session.canRead && !current.session.canMutate)
    #expect(current.session.pending?.id == pending.id && current.session.target.workspacePath == thread.workspacePath)
    _ = try await f.host.replaceRevision(path: "first.txt", contents: "Original new-root contents")
    #expect(await current.files.open("first.txt")); current.files.setContents("New-root unsaved editor")
    await current.session.checkResult()
    #expect(current.session.pending == nil && current.session.canMutate)
    #expect(current.files.buffer?.original == "Original new-root contents" && current.files.contents == "New-root unsaved editor")
    #expect(await f.host.counts().0 == 1)
}

@Test(.timeLimit(.minutes(1))) @MainActor
func remoteInspectorGitReadsAndLostCommitRecoveryPreserveNewerDraftAndExactDiffPaths() async throws {
    let f = try RemoteInspectorFixture(); defer { f.remove() }
    await f.connect(); await f.model.git.refresh()
    #expect(f.model.git.snapshot?.branch == "main" && f.model.git.branches.count == 1 && f.model.git.remotes == ["origin"])
    f.model.git.selected = "Cafe\u{0301}.txt"; await f.model.git.loadDiff()
    #expect(f.model.git.diff.isEmpty)
    f.model.git.selected = "Caf\u{00e9}.txt"; await f.model.git.loadDiff()
    #expect(f.model.git.diff == "Diff: Caf\u{00e9}.txt false")
    let sent = "Commit Caf\u{00e9}", newer = "Commit Cafe\u{0301}"
    f.model.git.commitMessage = sent; await f.host.setMode(.droppedReply); await f.model.git.commit()
    let request = try #require(f.model.session.pending)
    f.model.git.commitMessage = newer; f.model.session.disconnect(); await f.connect()
    await f.model.git.commit()
    #expect(await f.host.counts().0 == 1)
    await f.model.session.checkResult()
    #expect(f.model.session.pending == nil && Array(f.model.git.commitMessage.utf8) == Array(newer.utf8))
    #expect(await f.host.requests().first?.id == request.id)
    #expect(await f.host.counts().0 == 1)
}

@Test(.timeLimit(.minutes(1))) @MainActor
func remoteInspectorCancellationRetainsDraftAndDurableUncertaintyUntilExplicitDismissal() async throws {
    let f = try RemoteInspectorFixture(); defer { f.remove() }
    await f.connect(); #expect(await f.model.files.open("first.txt"))
    f.model.files.setContents("Keep the editor draft")
    f.model.git.commitMessage = "Keep the newer commit draft"
    await f.host.setMode(.running)
    await f.model.git.fetch("origin")
    let request = try #require(f.model.session.pending)
    await f.model.session.cancelOperation()
    #expect(f.model.session.operation?.state == .uncertain && f.model.session.pending?.id == request.id)
    #expect(await f.host.counts().2 == 1)
    #expect(f.model.files.contents == "Keep the editor draft" && f.model.git.commitMessage == "Keep the newer commit draft")
    await f.model.session.dismissOperation()
    #expect(f.model.session.pending == nil && f.model.hasUnsavedEdits)
    #expect(try await f.pendingStore.load(environmentID: request.target.environmentID, threadID: request.target.threadID) == nil)
    #expect(await f.host.counts().0 == 1)
}

@Test(.timeLimit(.minutes(1))) @MainActor
func remoteInspectorRetainsWorkspaceEditorsAcrossHideModelChangeAndConversationSelection() async throws {
    let f = try RemoteInspectorFixture(); defer { f.remove() }
    let coordinator = RemoteWorkspaceInspectorStore(pendingStore: f.pendingStore)
    let environment = f.model.session.target.environmentID
    await coordinator.select(environmentID: environment, thread: f.thread, client: nil, canMutate: false)
    let first = try #require(coordinator.selected)
    await first.session.connect(transport: f.host.transport, canMutate: true)
    #expect(await first.files.open("first.txt")); first.files.setContents("Retained through selection")
    first.git.commitMessage = "Retained commit draft"
    var secondThread = f.thread; secondThread.id = UUID()
    await coordinator.select(environmentID: environment, thread: secondThread, client: nil, canMutate: false)
    #expect(first.session.canMutate == false && coordinator.hasUnsavedEdits)
    var changedModel = f.thread; changedModel.model = "another-model"
    await coordinator.select(environmentID: environment, thread: changedModel, client: nil, canMutate: false)
    #expect(coordinator.selected === first)
    #expect(first.files.contents == "Retained through selection" && first.git.commitMessage == "Retained commit draft")
    var relocated = f.thread; relocated.workspacePath = "/remote-only/new-project-root"
    await coordinator.select(environmentID: environment, thread: relocated, client: nil, canMutate: false)
    let current = try #require(coordinator.selected)
    #expect(current !== first && coordinator.retainedEditors.contains(where: { $0 === first }))
    coordinator.showRetained(first)
    await coordinator.select(environmentID: environment, thread: relocated, client: nil, canMutate: true)
    #expect(coordinator.selected === first && !first.session.canRead && !first.session.canMutate)
    #expect(first.files.contents == "Retained through selection" && coordinator.canReturnToCurrent)
    await coordinator.returnToCurrent(); #expect(coordinator.selected === current)
    coordinator.clearSelection(); #expect(coordinator.hasUnsavedEdits)
    await coordinator.shutdown(); coordinator.cancelShutdown()
}
