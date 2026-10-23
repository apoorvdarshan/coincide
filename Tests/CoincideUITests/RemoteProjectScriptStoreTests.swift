import AppKit
import CryptoKit
import Foundation
import SwiftUI
import Testing
@testable import Coincide
@testable import CoincideCore

private actor ScriptUIBoundary {
    private var enteredValue = false, released = false
    private var waiter: CheckedContinuation<Void, Never>?
    private var observers: [CheckedContinuation<Void, Never>] = []
    func pause() async { enteredValue = true; observers.forEach { $0.resume() }; observers = []; if !released { await withCheckedContinuation { waiter = $0 } } }
    func entered() async { if !enteredValue { await withCheckedContinuation { observers.append($0) } } }
    func release() { released = true; waiter?.resume(); waiter = nil }
}
private struct ScriptUIFixture: Sendable {
    let target: RemoteWorkspaceTarget, generation = UUID(), host = UUID(), run = UUID(), claimID = UUID(), referenceID = UUID(), outputID = UUID()
    let command = "printf '%s\\n' 'Private reviewed Unicode e\u{301} 🌍'\n" + String(repeating: "# retained complete command 🌍\n", count: 5_000)
    init() {
        let project = WorkspaceProject(path: "/remote/project"), thread = CodingThread(project: project)
        target = .init(environmentID: UUID(), projectID: project.id, threadID: thread.id, configuration: .init(thread: thread), rootID: UUID())
    }
    var claim: RemoteProjectScriptClaim { .init(id: claimID, digest: String(repeating: "a", count: 64), target: target, generationID: generation, runID: run, hostID: host) }
    var reference: RemoteProjectScriptContentReference { .init(id: referenceID, kind: .command, totalBytes: command.utf8.count,
        digest: SHA256.hash(data: Data(command.utf8)).map { String(format: "%02x", $0) }.joined()) }
    var review: RemoteProjectScriptReview { .init(claim: claim, name: .init(preview: "Reviewed cleanup"),
        command: .init(preview: String(command.prefix(32)), content: reference), projectRoot: target.workspacePath,
        workspacePath: target.workspacePath, shellPath: "/bin/zsh", runsAsynchronously: true) }
    var output: RemoteProjectScriptOutputReference { .init(id: outputID, target: target, generationID: generation, runID: run, hostID: host) }
    func state(running: Bool = false) -> RemoteProjectScriptState {
        .init(runID: run, phase: running ? .running : .awaitingApproval, commandExit: nil, error: nil,
            startedAt: running ? Date(timeIntervalSince1970: 1_800_000_000) : nil, endedAt: nil,
            review: running ? nil : review, canApprove: !running, canStop: running, canSkip: true, canRetry: false, output: output)
    }
}
private actor ScriptUIPeer {
    let fixture: ScriptUIFixture
    var mode = "valid", running = false
    private var contentGate: ScriptUIBoundary?, outputGate: ScriptUIBoundary?, controlGate: ScriptUIBoundary?
    private(set) var reads = 0, chunks = 0, outputs = 0
    private(set) var commands: [RemoteEnvironmentCommand] = []
    private(set) var wasCancelled = false
    init(_ fixture: ScriptUIFixture) { self.fixture = fixture }
    func configure(mode: String = "valid", running: Bool = false) { self.mode = mode; self.running = running }
    func holdContent(_ gate: ScriptUIBoundary) { contentGate = gate }
    func holdOutput(_ gate: ScriptUIBoundary) { outputGate = gate }
    func holdControl(_ gate: ScriptUIBoundary) { controlGate = gate }
    nonisolated var transport: RemoteProjectScriptTransport {
        .init(read: { await self.read($0) }, content: { await self.content($0) }, output: { await self.output($0) })
    }
    private func read(_ request: RemoteProjectScriptReadRequest) -> RemoteProjectScriptReadResult {
        reads += 1
        return .init(target: fixture.target, hostID: fixture.host, generationID: fixture.generation, script: fixture.state(running: running))
    }
    private func content(_ request: RemoteProjectScriptContentRequest) async -> RemoteProjectScriptContentResult {
        chunks += 1
        if let gate = contentGate { contentGate = nil; await gate.pause() }
        let data = Data(fixture.command.utf8), end = min(data.count, request.offset + request.maximumBytes)
        var chunk = Data(data.dropFirst(request.offset).prefix(end - request.offset))
        if mode == "digest", request.offset == 0 { chunk[chunk.startIndex] ^= 1 }
        let claim = mode == "scope" ? RemoteProjectScriptClaim(id: fixture.claim.id, digest: fixture.claim.digest, target: fixture.target,
            generationID: fixture.generation, runID: fixture.run, hostID: UUID()) : fixture.claim
        return .init(claim: claim, reference: fixture.reference, offset: request.offset, data: chunk,
            nextOffset: end == data.count ? nil : end, complete: end == data.count)
    }
    private func output(_ request: RemoteProjectScriptOutputRequest) async -> RemoteProjectScriptOutputResult {
        outputs += 1
        if let gate = outputGate { outputGate = nil; await gate.pause() }
        return .init(reference: fixture.output, sequence: 7, text: "Exact bounded output 🌍\n", truncated: true, isClosed: true, retention: .retained)
    }
    func perform(_ command: RemoteEnvironmentCommand) async -> Bool {
        commands.append(command)
        if let gate = controlGate { controlGate = nil; await gate.pause() }
        wasCancelled = Task.isCancelled
        return true
    }
}
@MainActor private func updateScriptStore(_ store: RemoteProjectScriptStore, fixture: ScriptUIFixture, peer: ScriptUIPeer, supported: Bool = true, canWrite: Bool = true) {
    store.update(environmentID: fixture.target.environmentID, target: fixture.target, generationID: fixture.generation,
        transport: peer.transport, supported: supported, canWrite: canWrite, perform: { await peer.perform($0) })
}

@MainActor @Test(.timeLimit(.minutes(1)), arguments: ["valid", "digest", "scope"])
func remoteProjectScriptFullReferencedReviewIsRequiredBeforeApprovalAndBindsOnlyTheHostClaim(mode: String) async throws {
    let f = ScriptUIFixture(), peer = ScriptUIPeer(f), store = RemoteProjectScriptStore(), gate = ScriptUIBoundary()
    await peer.configure(mode: mode); updateScriptStore(store, fixture: f, peer: peer); await store.refresh()
    #expect(!store.canApprove && store.review == nil)
    await peer.holdContent(gate)
    let loading = Task { await store.beginReview() }; await gate.entered()
    #expect(store.isReviewing && !store.canApprove && store.review == nil)
    await gate.release(); await loading.value
    if mode == "valid" {
        let review = try #require(store.review)
        #expect(review.command.utf8.elementsEqual(f.command.utf8) && store.canApprove)
        #expect(await store.approve(review))
        let commands = await peer.commands
        guard case .some(.projectScript(let target, .approve(let claim))) = commands.first else { Issue.record("Approval did not retain the opaque host claim"); await store.shutdown(); return }
        #expect(commands.count == 1 && target == f.target && claim == f.claim)
        #expect(await peer.chunks > 1)
    } else {
        #expect(store.review == nil && !store.canApprove && store.errorMessage != nil)
        #expect(await peer.commands.isEmpty)
    }
    await store.shutdown()
}

@MainActor @Test(.timeLimit(.minutes(1)))
func remoteProjectScriptLateOutputAndApprovalCannotCrossEnvironmentAttemptOrHelperScope() async throws {
    let first = ScriptUIFixture(), next = ScriptUIFixture(), oldPeer = ScriptUIPeer(first), newPeer = ScriptUIPeer(next)
    let store = RemoteProjectScriptStore(), gate = ScriptUIBoundary()
    updateScriptStore(store, fixture: first, peer: oldPeer); await store.refresh(); await store.beginReview()
    let oldReview = try #require(store.review)
    #expect(await oldPeer.outputs == 0)
    store.setOutputVisible(true); await oldPeer.holdOutput(gate)
    let output = Task { await store.refreshOutput() }; await gate.entered()
    updateScriptStore(store, fixture: next, peer: newPeer); await store.refresh()
    await gate.release(); await output.value; await store.drain()
    #expect(store.output == nil && store.state?.runID == next.run)
    #expect(await !store.approve(oldReview))
    #expect(await oldPeer.commands.isEmpty)
    #expect(await newPeer.commands.isEmpty)
    await store.shutdown()
}

@MainActor @Test(.timeLimit(.minutes(1)), arguments: [false, true])
func remoteProjectScriptMissingCheckoutKeepsExactStopSkipAndOutputButRejectsReplacementRoots(replaced: Bool) async throws {
    let f = ScriptUIFixture(), peer = ScriptUIPeer(f), store = RemoteProjectScriptStore()
    let returned = RemoteWorkspaceTarget(environmentID: f.target.environmentID, projectID: f.target.projectID,
        threadID: f.target.threadID, configuration: f.target.configuration, rootID: replaced ? UUID() : nil)
    let reference = RemoteProjectScriptOutputReference(id: f.outputID, target: returned, generationID: f.generation, runID: f.run, hostID: f.host)
    let state = RemoteProjectScriptState(runID: f.run, phase: .running, commandExit: nil, error: nil,
        startedAt: Date(timeIntervalSince1970: 1_800_000_000), endedAt: nil, review: nil,
        canApprove: false, canStop: true, canSkip: true, canRetry: false, output: reference)
    let transport = RemoteProjectScriptTransport(read: { _ in .init(target: returned, hostID: f.host, generationID: f.generation, script: state) },
        content: { _ in throw RemoteProjectScriptFailure(.staleReview) },
        output: { request in .init(reference: request.reference, sequence: 1, text: "Owned job output", truncated: false, isClosed: false, retention: .retained) })
    store.update(environmentID: f.target.environmentID, target: f.target, generationID: f.generation,
        transport: transport, supported: true, canWrite: true, perform: { await peer.perform($0) })
    await store.refreshPresentation()
    if replaced {
        #expect(store.state == nil && store.errorMessage != nil)
        #expect(await !store.stop(state))
        #expect(await peer.commands.isEmpty)
    } else {
        #expect(store.state == state && store.errorMessage == nil && !store.canApprove)
        await store.beginReview(); #expect(store.review == nil)
        store.setOutputVisible(true); await store.refreshOutput()
        #expect(store.output?.text == "Owned job output" && store.outputError == nil)
        #expect(await store.stop(state))
        #expect(await store.skip(state))
        #expect(await !store.retry(state))
        let commands = await peer.commands
        #expect(commands.count == 2)
        for command in commands {
            guard case .projectScript(let target, let action) = command else { Issue.record("Unexpected script command"); continue }
            #expect(target.rootID == nil && target == returned && action.generationID == f.generation && action.runID == f.run)
        }
    }
    await store.shutdown()
}

@MainActor @Test(.timeLimit(.minutes(1)))
func remoteProjectScriptPresentationCloseJoinsAnAcceptedStopWithoutCancellingOrRepeatingIt() async throws {
    let f = ScriptUIFixture(), peer = ScriptUIPeer(f), store = RemoteProjectScriptStore(), gate = ScriptUIBoundary()
    await peer.configure(running: true); updateScriptStore(store, fixture: f, peer: peer); await store.refresh()
    let state = try #require(store.state)
    await peer.holdControl(gate)
    let stop = Task { await store.stop(state) }; await gate.entered()
    let close = Task { await store.closePresentation() }; stop.cancel()
    await gate.release(); #expect(await stop.value); await close.value
    #expect(await !peer.wasCancelled)
    let commands = await peer.commands
    #expect(commands == [.projectScript(target: f.target, action: .stop(generationID: f.generation, runID: f.run))])
    updateScriptStore(store, fixture: f, peer: peer, canWrite: false)
    #expect(await !store.stop(state))
    #expect(await peer.commands.count == 1)
    await store.shutdown()
}

@MainActor @Test(.timeLimit(.minutes(1)))
func remoteProjectScriptOutputPollingRequiresDisclosureAndPresentationClosureJoinsItsReads() async throws {
    let f = ScriptUIFixture(), peer = ScriptUIPeer(f), sleep = ScriptUIBoundary(), output = ScriptUIBoundary()
    let store = RemoteProjectScriptStore(sleep: { _ in await sleep.pause(); try Task.checkCancellation() })
    await peer.configure(running: true); updateScriptStore(store, fixture: f, peer: peer)
    store.startPresentation(); await sleep.entered()
    #expect(await peer.reads == 1)
    #expect(await peer.outputs == 0)
    await peer.holdOutput(output); store.setOutputVisible(true); await output.entered()
    store.endPresentation()
    await output.release(); await sleep.release(); await store.drain()
    #expect(await peer.outputs == 1)
    #expect(store.output == nil)
    await store.shutdown()
}

@MainActor @Test(.timeLimit(.minutes(1)))
func remoteProjectScriptOldHelperDoesNotReadOrPollAndOffscreenViewsDoNotApproveCommands() async throws {
    enum Phase: String {
        case unsupportedCheck = "unsupported-check", metadata, hydration
        case lightBanner = "light-banner", lightSheet = "light-sheet"
        case darkBanner = "dark-banner", darkSheet = "dark-sheet", shutdown
    }
    enum Boundary: String { case begin, end }
    let clock = ContinuousClock(), started = clock.now
    func trace(_ phase: Phase, _ boundary: Boundary) {
        let elapsed = started.duration(to: clock.now).components
        let milliseconds = elapsed.seconds * 1_000 + elapsed.attoseconds / 1_000_000_000_000_000
        let line = "remote-script-ui-phase=\(phase.rawValue) boundary=\(boundary.rawValue) elapsed-ms=\(milliseconds)\n"
        try? FileHandle.standardError.write(contentsOf: Data(line.utf8))
    }
    let f = ScriptUIFixture(), peer = ScriptUIPeer(f), store = RemoteProjectScriptStore()
    trace(.unsupportedCheck, .begin)
    updateScriptStore(store, fixture: f, peer: peer, supported: false)
    await store.refresh(); await store.beginReview(); store.setOutputVisible(true); await store.refreshOutput()
    #expect(await peer.reads == 0)
    #expect(await peer.chunks == 0)
    #expect(await peer.outputs == 0)
    trace(.unsupportedCheck, .end)
    trace(.metadata, .begin)
    updateScriptStore(store, fixture: f, peer: peer); await store.refresh()
    trace(.metadata, .end)
    trace(.hydration, .begin)
    await store.beginReview()
    let loaded = try #require(store.review), reads = await peer.reads
    trace(.hydration, .end)
    updateScriptStore(store, fixture: f, peer: peer, supported: false)
    for scheme in [ColorScheme.light, .dark] {
        let bannerPhase: Phase = scheme == .light ? .lightBanner : .darkBanner
        let sheetPhase: Phase = scheme == .light ? .lightSheet : .darkSheet
        trace(bannerPhase, .begin)
        let banner = NSHostingController(rootView: RemoteProjectScriptPanel(store: store).frame(width: 420).environment(\.colorScheme, scheme))
        let size = banner.sizeThatFits(in: .init(width: 420, height: 1_000))
        trace(bannerPhase, .end)
        trace(sheetPhase, .begin)
        let sheet = NSHostingController(rootView: RemoteProjectScriptReviewSheet(store: store, value: loaded).environment(\.colorScheme, scheme))
        let review = sheet.sizeThatFits(in: .init(width: 520, height: 1_200))
        trace(sheetPhase, .end)
        #expect(size.width >= 400 && size.height > 40 && size.height < 1_000)
        #expect(review.width >= 500 && review.height > 200 && review.height < 1_200)
    }
    #expect(await peer.reads == reads)
    #expect(await peer.commands.isEmpty)
    trace(.shutdown, .begin)
    await store.shutdown()
    trace(.shutdown, .end)
}
