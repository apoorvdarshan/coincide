import Foundation
import Testing
@testable import Coincide
@testable import CoincideCore
@testable import CoincideTerminal

private actor RemoteTerminalBoundary {
    private var started = false
    private var released = false
    private var body: CheckedContinuation<Void, Never>?
    private var listeners: [CheckedContinuation<Void, Never>] = []
    func pause() async {
        started = true; for listener in listeners { listener.resume() }; listeners = []
        if released { return }
        await withCheckedContinuation { body = $0 }
    }
    func entered() async { if !started { await withCheckedContinuation { listeners.append($0) } } }
    func release() { released = true; body?.resume(); body = nil }
}

private actor RemoteTerminalPeer {
    enum OpenMode { case normal, dropped }
    let rootID = UUID()
    private var snapshots: [UUID: RemoteTerminalSnapshot] = [:]
    private var output: [UUID: Data] = [:]
    private var retainedStarts: [UUID: Int64] = [:]
    private var receipts: [Int64: RemoteTerminalInputReceipt] = [:]
    private var opens: [RemoteTerminalOpenRequest] = []
    private var inputs: [RemoteTerminalInputRequest] = []
    private var readCount = 0
    private var attachCount = 0
    private var closeCount = 0
    private var resizes: [RemoteTerminalResizeRequest] = []
    private var openMode = OpenMode.normal
    private var loseInputReply = false
    private var writeBoundary: RemoteTerminalBoundary?
    private var closeBoundary: RemoteTerminalBoundary?
    private var readBoundary: RemoteTerminalBoundary?
    private var readPauses: [Int64: RemoteTerminalBoundary] = [:]
    nonisolated var transport: RemoteTerminalTransport {
        .init(bind: { await self.bind($0) }, open: { try await self.open($0) }, attach: { try await self.attach($0) },
            list: { await self.list($0) }, read: { try await self.read($0) }, write: { try await self.write($0) },
            receipt: { try await self.receipt($0) }, resize: { try await self.resize($0) }, close: { try await self.close($0) })
    }
    func setDroppedOpen() { openMode = .dropped }
    func setLostInputReply() { loseInputReply = true }
    func holdWrite(_ boundary: RemoteTerminalBoundary) { writeBoundary = boundary }
    func holdClose(_ boundary: RemoteTerminalBoundary) { closeBoundary = boundary }
    func holdRead(_ boundary: RemoteTerminalBoundary) { readBoundary = boundary }
    func pauseRead(after: Int64, boundary: RemoteTerminalBoundary) { readPauses[after] = boundary }
    func counts() -> (opens: Int, inputs: Int, reads: Int, attaches: Int, closes: Int, resizes: Int) { (opens.count, inputs.count, readCount, attachCount, closeCount, resizes.count) }
    func written() -> [RemoteTerminalInputRequest] { inputs }
    func setForeground(_ reference: RemoteTerminalReference, value: Bool) { snapshots[reference.terminalID]?.hasForegroundCommand = value }
    func append(_ reference: RemoteTerminalReference, bytes: Data) {
        output[reference.terminalID, default: Data()].append(bytes)
        snapshots[reference.terminalID]?.outputSequence += Int64(bytes.count)
    }
    func setGap(_ reference: RemoteTerminalReference, start: Int64, bytes: Data) {
        retainedStarts[reference.terminalID] = start; output[reference.terminalID] = bytes
        snapshots[reference.terminalID]?.retainedStartSequence = start
        snapshots[reference.terminalID]?.outputSequence = start + Int64(bytes.count)
    }
    private func bind(_ target: RemoteWorkspaceTarget) -> RemoteWorkspaceTarget {
        .init(environmentID: target.environmentID, projectID: target.projectID, threadID: target.threadID,
            configuration: target.configuration, rootID: target.rootID ?? rootID)
    }
    private func open(_ request: RemoteTerminalOpenRequest) throws -> RemoteTerminalSnapshot {
        opens.append(request)
        let value = RemoteTerminalSnapshot(reference: .init(target: request.target, terminalID: request.terminalID, incarnation: UUID()),
            state: .running, cols: request.cols, rows: request.rows, outputSequence: 7, retainedStartSequence: 0,
            nextInputSequence: 1, inputDigest: "", inputHalted: false,
            hasForegroundCommand: false, exitCode: nil, exitSignal: nil)
        snapshots[request.terminalID] = value; output[request.terminalID] = Data("Ready\r\n".utf8)
        if openMode == .dropped { throw RemoteEnvironmentClientError(.commandUncertain, commandID: request.id) }
        return value
    }
    private func existing(_ reference: RemoteTerminalReference) throws -> RemoteTerminalSnapshot {
        let value = try #require(snapshots[reference.terminalID])
        guard value.reference == reference else { throw RemoteTerminalFailure(.staleIncarnation) }
        return value
    }
    private func attach(_ reference: RemoteTerminalReference) throws -> RemoteTerminalSnapshot { attachCount += 1; return try existing(reference) }
    private func list(_ target: RemoteWorkspaceTarget) -> [RemoteTerminalSnapshot] { snapshots.values.filter { $0.reference.target == target } }
    private func read(_ request: RemoteTerminalReadRequest) async throws -> RemoteTerminalReadResult {
        readCount += 1
        let snapshot = try existing(request.reference), start = max(request.afterSequence, snapshot.retainedStartSequence)
        let bytes = output[request.reference.terminalID] ?? Data(), offset = Int(start - snapshot.retainedStartSequence)
        let data = offset < bytes.count ? bytes.subdata(in: offset..<min(bytes.count, offset + request.maxBytes)) : Data()
        if let boundary = readBoundary { readBoundary = nil; await boundary.pause() }
        if let boundary = readPauses.removeValue(forKey: request.afterSequence) { await boundary.pause() }
        return .init(snapshot: snapshot, data: data, startSequence: start, nextSequence: start + Int64(data.count), gap: request.afterSequence < snapshot.retainedStartSequence)
    }
    private func write(_ request: RemoteTerminalInputRequest) async throws -> RemoteTerminalInputReceipt {
        var snapshot = try existing(request.reference)
        guard snapshot.nextInputSequence == request.sequence else { throw RemoteTerminalFailure(.inputCollision) }
        inputs.append(request)
        let digest = RemoteTerminalProtocol.inputDigest(request.data)
        snapshot.inputDigest = RemoteTerminalProtocol.chainedInputDigest(previous: snapshot.inputDigest, sequence: request.sequence, digest: digest)
        snapshot.nextInputSequence += 1; snapshots[request.reference.terminalID] = snapshot
        var receipt = RemoteTerminalInputReceipt(reference: request.reference, sequence: request.sequence, digest: digest,
            byteCount: request.data.count, inputDigest: snapshot.inputDigest, state: .delivered)
        receipts[request.sequence] = receipt
        if let boundary = writeBoundary { writeBoundary = nil; await boundary.pause() }
        if snapshots[request.reference.terminalID]?.state != .running { receipt.state = .uncertain; receipts[request.sequence] = receipt }
        if loseInputReply { throw RemoteTerminalFailure(.inputUncertain) }
        return receipt
    }
    private func receipt(_ request: RemoteTerminalInputReceiptRequest) throws -> RemoteTerminalInputReceipt? {
        if let receipt = receipts[request.sequence] {
            guard receipt.reference == request.reference, receipt.digest == request.digest else { throw RemoteTerminalFailure(.inputCollision) }
            return receipt
        }
        return nil
    }
    private func resize(_ request: RemoteTerminalResizeRequest) throws -> RemoteTerminalSnapshot {
        var value = try existing(request.reference); value.cols = request.cols; value.rows = request.rows
        snapshots[request.reference.terminalID] = value; resizes.append(request); return value
    }
    private func close(_ reference: RemoteTerminalReference) async throws -> RemoteTerminalSnapshot {
        var value = try existing(reference); closeCount += 1
        value.state = .closing; value.inputHalted = true; snapshots[reference.terminalID] = value
        if let boundary = closeBoundary { closeBoundary = nil; await boundary.pause() }
        value.state = .exited; value.exitCode = 0; value.hasForegroundCommand = false
        snapshots[reference.terminalID] = value
        return value
    }
}

@MainActor private func remoteTerminalTarget() -> RemoteWorkspaceTarget {
    let project = WorkspaceProject(path: "/remote-only/terminal-workspace"), thread = CodingThread(project: project)
    return .init(environmentID: UUID(), projectID: project.id, threadID: thread.id, configuration: .init(thread: thread))
}
@MainActor private func remoteTerminalEventually(_ predicate: @MainActor () async throws -> Bool) async throws {
    let deadline = ContinuousClock.now + .seconds(5)
    while try await !predicate() {
        guard ContinuousClock.now < deadline else { throw CoincideError("The owned remote terminal fixture did not reach its boundary.") }
        try await Task.sleep(for: .milliseconds(5))
    }
}

@Test(.timeLimit(.minutes(1))) @MainActor
func remoteTerminalSelectionHideAndReconnectNeverOpenAttachOrReplayImplicitly() async throws {
    let peer = RemoteTerminalPeer(), store = RemoteTerminalStore(), target = remoteTerminalTarget()
    defer { store.disconnect() }
    await store.select(target: target, transport: peer.transport)
    let initial = await peer.counts()
    #expect(initial.opens == 0 && initial.attaches == 0 && initial.reads == 0)
    await store.newTerminal()
    let tab = try #require(store.selected)
    try await remoteTerminalEventually { tab.renderer.transcriptText.contains("Ready") }
    #expect(!tab.renderer.hasCreatedView && store.hasLiveTerminals)
    store.panelVisible = false; store.panelVisible = true
    store.clearSelection(); await store.select(target: target, transport: peer.transport)
    let switched = await peer.counts()
    #expect(store.selected === tab && switched.opens == 1)
    store.disconnect(); #expect(!tab.renderer.isInteractive && !tab.isAttached)
    let before = await peer.counts()
    await store.select(target: target, transport: peer.transport)
    let reconnected = await peer.counts()
    #expect(reconnected.opens == 1 && reconnected.attaches == before.attaches && reconnected.reads == before.reads)
    #expect(!tab.renderer.isInteractive && store.selected === tab)
    await store.attach(tab)
    try await remoteTerminalEventually { tab.canInput }
    let attached = await peer.counts()
    #expect(attached.opens == 1 && attached.attaches == before.attaches + 1)
}

@Test(.timeLimit(.minutes(1))) @MainActor
func remoteTerminalInputIsBinaryOrderedAndUncertainReceiptNeverReenablesOrReplays() async throws {
    let peer = RemoteTerminalPeer(), store = RemoteTerminalStore(), target = remoteTerminalTarget()
    defer { store.disconnect() }
    await store.select(target: target, transport: peer.transport); await store.newTerminal()
    let tab = try #require(store.selected)
    let payloads = [Data("first".utf8), Data("second".utf8), Data([0, 255, 27, 13])]
    for data in payloads { store.enqueue(data, for: tab) }
    try await remoteTerminalEventually { await peer.counts().inputs == 3 && tab.inputTask == nil }
    let written = await peer.written()
    #expect(written.map(\.sequence) == [1, 2, 3] && written.map(\.data) == payloads)
    await peer.setLostInputReply()
    store.enqueue(Data("owned-uncertain".utf8), for: tab)
    store.enqueue(Data("must-never-flush".utf8), for: tab)
    try await remoteTerminalEventually { tab.inputBlocked && tab.inputTask == nil }
    let uncertainCounts = await peer.counts()
    #expect(uncertainCounts.inputs == 4 && tab.uncertainInput?.sequence == 4)
    await store.checkInputResult(tab)
    #expect(tab.inputBlocked && !tab.renderer.isInteractive)
    store.disconnect(); await store.select(target: target, transport: peer.transport); await store.attach(tab)
    #expect(tab.inputBlocked && !tab.renderer.isInteractive)
    store.enqueue(Data("also-never-send".utf8), for: tab)
    #expect(await peer.counts().inputs == 4)
}

@Test(.timeLimit(.minutes(1))) @MainActor
func remoteTerminalDroppedOpenUsesOnlyExplicitMetadataInspectionAndSameIncarnationAttach() async throws {
    let peer = RemoteTerminalPeer(), store = RemoteTerminalStore(), target = remoteTerminalTarget()
    defer { store.disconnect() }
    await peer.setDroppedOpen(); await store.select(target: target, transport: peer.transport); await store.newTerminal()
    let tab = try #require(store.selected)
    #expect(tab.openUnconfirmed && store.hasLiveTerminals && !store.canOpen)
    await store.newTerminal(); #expect(await peer.counts().opens == 1)
    await store.inspectOpenResult(tab)
    #expect(!tab.openUnconfirmed && !tab.isAttached && tab.reference != nil && !tab.renderer.isInteractive)
    await store.attach(tab)
    let counts = await peer.counts()
    #expect(tab.isAttached && counts.opens == 1)
}

@Test(.timeLimit(.minutes(1))) @MainActor
func remoteTerminalCloseConfirmsForegroundAndDoesNotDeadlockOnBlockedInputOrFlushQueuedKeys() async throws {
    let peer = RemoteTerminalPeer(), store = RemoteTerminalStore(), target = remoteTerminalTarget()
    defer { store.disconnect() }
    await store.select(target: target, transport: peer.transport); await store.newTerminal()
    let tab = try #require(store.selected), reference = try #require(tab.reference)
    await peer.setForeground(reference, value: true)
    #expect(await store.close(tab) == false)
    let beforeClose = await peer.counts()
    #expect(beforeClose.closes == 0 && tab.preparingClose)
    store.cancelClose(tab); #expect(tab.canInput)
    let writeBoundary = RemoteTerminalBoundary(), closeBoundary = RemoteTerminalBoundary()
    await peer.holdWrite(writeBoundary); await peer.holdClose(closeBoundary)
    store.enqueue(Data("first-in-flight".utf8), for: tab)
    await writeBoundary.entered()
    store.enqueue(Data("queued-never-send".utf8), for: tab)
    let closing = Task { await store.close(tab, confirmed: true) }
    await closeBoundary.entered()
    #expect(tab.isClosing && store.sessions.contains { $0 === tab })
    let closingCounts = await peer.counts()
    #expect(closingCounts.inputs == 1 && closingCounts.closes == 1)
    await writeBoundary.release(); await closeBoundary.release()
    let closed = await closing.value
    #expect(closed && store.sessions.isEmpty)
    #expect(await peer.counts().inputs == 1)
}

@Test(.timeLimit(.minutes(1))) @MainActor
func remoteTerminalGapResetsRetainedTailAndLateReadCannotReviveDisconnectedInput() async throws {
    let peer = RemoteTerminalPeer(), store = RemoteTerminalStore(), target = remoteTerminalTarget()
    defer { store.disconnect() }
    let boundary = RemoteTerminalBoundary(); await peer.holdRead(boundary)
    await store.select(target: target, transport: peer.transport); await store.newTerminal()
    let tab = try #require(store.selected), reference = try #require(tab.reference)
    await boundary.entered(); store.disconnect(); await boundary.release()
    #expect(tab.renderer.transcriptText.isEmpty && !tab.renderer.isInteractive)
    await peer.setGap(reference, start: 500, bytes: Data("Retained tail\u{1b}[6n".utf8))
    await store.select(target: target, transport: peer.transport); await store.attach(tab)
    try await remoteTerminalEventually { tab.renderer.transcriptText.contains("Retained tail") }
    #expect(tab.notice?.contains("expired") == true && !tab.renderer.transcriptText.contains("\u{1b}"))
    #expect(await peer.counts().inputs == 0)
    store.resize(tab, cols: 132, rows: 42)
    try await remoteTerminalEventually { await peer.counts().resizes == 1 }
    #expect(tab.snapshot?.cols == 132 && tab.snapshot?.rows == 42)
}

@Test(.timeLimit(.minutes(1))) @MainActor
func remoteTerminalRendererHasNoProcessAndColdReplayCannotSendQueriesClipboardOrLinks() async {
    let renderer = RemoteTerminalSession()
    var inputs: [Data] = []
    renderer.onInput = { inputs.append($0) }
    renderer.acceptOutput(Data("History\u{1b}[6n\u{1b}]52;c;YQ==\u{7}\u{1b}]8;;https://example.invalid\u{7}link\u{1b}]8;;\u{7}".utf8), reset: true)
    #expect(!renderer.hasCreatedView && inputs.isEmpty)
    let view = renderer.view
    renderer.setInteractive(true)
    await Task.yield(); await Task.yield()
    #expect(inputs.isEmpty && !renderer.transcriptText.contains("\u{1b}"))
    #expect(renderer.clipboardRead(source: view) == nil)
    renderer.requestOpenLink(source: view, link: "https://example.invalid", params: [:])
    renderer.send(source: view, data: Array("explicit-user-input".utf8)[...])
    #expect(inputs == [Data("explicit-user-input".utf8)])
    renderer.setInteractive(false); renderer.send(source: view, data: [0x41][...])
    #expect(inputs.count == 1)
    renderer.acceptOutput(Data(repeating: 0x61, count: RemoteTerminalSession.transcriptByteLimit + 100))
    #expect(renderer.transcriptText.utf8.count <= RemoteTerminalSession.transcriptByteLimit)
}

@Test(.timeLimit(.minutes(1))) @MainActor
func remoteTerminalGapKeepsEveryRetainedChunkInertUntilCapturedHighWater() async throws {
    let peer = RemoteTerminalPeer(), store = RemoteTerminalStore(), target = remoteTerminalTarget()
    defer { store.disconnect() }
    await store.select(target: target, transport: peer.transport); await store.newTerminal()
    let tab = try #require(store.selected), reference = try #require(tab.reference)
    try await remoteTerminalEventually { tab.afterSequence == 7 }
    _ = tab.renderer.view
    let boundary = RemoteTerminalBoundary()
    await peer.pauseRead(after: 500 + 65_536, boundary: boundary)
    var bytes = Data(repeating: 0x61, count: 65_536)
    let query = Data("\u{1b}[6n".utf8)
    bytes.append(query); bytes.append(Data(repeating: 0x62, count: 65_536 - query.count))
    bytes.append(Data("Last retained query\u{1b}[6n".utf8))
    await peer.setGap(reference, start: 500, bytes: bytes)
    await boundary.entered()
    #expect(tab.replayThrough == 500 + Int64(bytes.count) && !tab.canInput && !tab.renderer.isInteractive)
    #expect(await peer.counts().inputs == 0)
    await boundary.release()
    try await remoteTerminalEventually { tab.afterSequence == 500 + Int64(bytes.count) && tab.replayThrough == nil }
    await Task.yield(); await Task.yield()
    #expect(await peer.counts().inputs == 0)
    #expect(tab.canInput && tab.renderer.isInteractive)
}

@Test(.timeLimit(.minutes(1))) @MainActor
func remoteTerminalRendererReplayReplacesViewAndRejectsQueuedInputResizeAndTitleFromOldSource() {
    let renderer = RemoteTerminalSession()
    var inputs: [Data] = [], sizes: [(Int, Int)] = []
    renderer.onInput = { inputs.append($0) }; renderer.onResize = { sizes.append(($0, $1)) }
    let old = renderer.view, generation = renderer.displayGeneration
    renderer.setInteractive(true)
    renderer.acceptOutput(Data("Retained screen".utf8))
    renderer.prepareForReplay()
    #expect(renderer.displayGeneration != generation && !renderer.hasCreatedView && !renderer.isInteractive)
    let current = renderer.view
    renderer.setInteractive(true)
    #expect(current !== old)
    // SwiftTerm may deliver these callbacks asynchronously after the old feed.
    renderer.send(source: old, data: [0x1b, 0x5b, 0x31, 0x52][...])
    renderer.sizeChanged(source: old, newCols: 499, newRows: 499)
    renderer.setTerminalTitle(source: old, title: "Stale title")
    #expect(inputs.isEmpty && sizes.isEmpty && renderer.title != "Stale title")
    renderer.send(source: current, data: Array("explicit".utf8)[...])
    #expect(inputs == [Data("explicit".utf8)])
    let replayView = renderer.view, replayGeneration = renderer.displayGeneration
    renderer.acceptOutput(Data("Gap tail\u{1b}[6n".utf8), reset: true, inert: true)
    #expect(renderer.displayGeneration != replayGeneration && !renderer.hasCreatedView)
    renderer.send(source: replayView, data: [0x41][...])
    #expect(inputs.count == 1)
}
