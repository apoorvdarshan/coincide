import AppKit
import Foundation
import SwiftUI
import Testing
@testable import Coincide
@testable import CoincideCore

private actor LifecycleStoreBoundary {
    private var reached = false, released = false
    private var continuation: CheckedContinuation<Void, Never>?
    private var observers: [CheckedContinuation<Void, Never>] = []
    func pause() async {
        reached = true; observers.forEach { $0.resume() }; observers = []
        if !released { await withCheckedContinuation { continuation = $0 } }
    }
    func entered() async { if !reached { await withCheckedContinuation { observers.append($0) } } }
    func release() { released = true; continuation?.resume(); continuation = nil }
}

private actor LifecycleStorePeer {
    private var readBoundary: LifecycleStoreBoundary?
    private var controlBoundary: LifecycleStoreBoundary?
    private(set) var commands: [RemoteEnvironmentCommand] = []
    private(set) var requests: [RemoteLifecycleReadRequest] = []
    private(set) var commandWasCancelled = false
    private var accepted = true
    nonisolated var transport: RemoteLifecycleTransport { .init(read: { try await self.read($0) }) }
    func holdRead(_ value: LifecycleStoreBoundary) { readBoundary = value }
    func holdControl(_ value: LifecycleStoreBoundary, accepted: Bool) { controlBoundary = value; self.accepted = accepted }
    private func read(_ request: RemoteLifecycleReadRequest) async throws -> RemoteLifecycleReadResult {
        requests.append(request)
        let value: RemoteLifecycleThreadState?
        if let target = request.target {
            value = .init(capture: .init(id: UUID(), digest: String(repeating: "a", count: 64), target: target),
                lifecycle: .init(snoozedUntil: Date().addingTimeInterval(3_600), snoozedAt: Date()), settlementID: nil,
                settlementPhase: nil, settle: .init(allowed: true), resume: .init(allowed: false),
                snooze: .init(allowed: true), wake: .init(allowed: true))
        } else { value = nil }
        if let boundary = readBoundary { readBoundary = nil; await boundary.pause() }
        return .init(environmentID: request.environmentID, sequence: 100, policy: .init(afterDays: 14, onMerge: false), thread: value)
    }
    func perform(_ command: RemoteEnvironmentCommand) async -> Bool {
        commands.append(command)
        if let boundary = controlBoundary { controlBoundary = nil; await boundary.pause() }
        commandWasCancelled = Task.isCancelled
        return accepted
    }
}

private func lifecycleStoreTarget(environmentID: UUID = UUID()) -> RemoteWorkspaceTarget {
    let project = WorkspaceProject(path: "/tmp/coincide-remote-lifecycle-ui")
    let thread = CodingThread(project: project)
    return .init(environmentID: environmentID, projectID: project.id, threadID: thread.id, configuration: .init(thread: thread), rootID: UUID())
}
@MainActor private func updateLifecycleStore(_ store: RemoteLifecycleStore, target: RemoteWorkspaceTarget,
                                             peer: LifecycleStorePeer, canWrite: Bool = true) {
    store.update(environmentID: target.environmentID, target: target, transport: peer.transport, supported: true, canWrite: canWrite,
        perform: { await peer.perform($0) })
}

@MainActor @Test(.timeLimit(.minutes(1)))
func remoteLifecycleControlsFenceOldConversationAndEnvironmentPolicyWithoutSending() async throws {
    let store = RemoteLifecycleStore(), peer = LifecycleStorePeer(), first = lifecycleStoreTarget(), second = lifecycleStoreTarget()
    updateLifecycleStore(store, target: first, peer: peer); await store.refresh()
    let old = try #require(store.state?.capture), policy = try #require(store.policy)
    updateLifecycleStore(store, target: second, peer: peer); await store.refresh()
    #expect(await !store.wake(capture: old))
    #expect(await !store.applyPolicy(.disabled, expected: policy, environmentID: first.environmentID))
    #expect(await peer.commands.isEmpty)
    let current = try #require(store.state?.capture)
    #expect(await store.wake(capture: current))
    let commands = await peer.commands
    #expect(commands == [.lifecycle(capture: current, action: .wake)])
    await store.shutdown()
}

@MainActor @Test(.timeLimit(.minutes(1)))
func remoteLifecycleLateCancelledReadCannotReplaceANewerEnvironmentOrItsPolicy() async throws {
    let store = RemoteLifecycleStore(), peer = LifecycleStorePeer(), boundary = LifecycleStoreBoundary()
    let first = lifecycleStoreTarget(), second = lifecycleStoreTarget()
    updateLifecycleStore(store, target: first, peer: peer); await peer.holdRead(boundary)
    let oldRead = Task { await store.refresh() }; await boundary.entered()
    updateLifecycleStore(store, target: second, peer: peer); await store.refresh()
    let current = try #require(store.state?.capture)
    #expect(current.target.environmentID == second.environmentID)
    await boundary.release(); await oldRead.value; await store.drain()
    #expect(store.state?.capture == current && store.environmentID == second.environmentID)
    let commands = await peer.commands
    #expect(store.policy?.afterDays == 14 && commands.isEmpty)
    await store.shutdown()
}

@MainActor @Test(.timeLimit(.minutes(1)), arguments: [true, false])
func remoteLifecycleClosingPresentationJoinsExplicitControlAndNeverReplaysUnknownResult(accepted: Bool) async throws {
    let store = RemoteLifecycleStore(), peer = LifecycleStorePeer(), target = lifecycleStoreTarget(), boundary = LifecycleStoreBoundary()
    updateLifecycleStore(store, target: target, peer: peer); await store.refresh()
    let capture = try #require(store.state?.capture)
    await peer.holdControl(boundary, accepted: accepted)
    let action = Task { await store.wake(capture: capture) }; await boundary.entered()
    let close = Task { await store.closePresentation() }
    await Task.yield(); action.cancel()
    await boundary.release()
    #expect(await action.value == accepted); await close.value
    #expect(await !peer.commandWasCancelled)
    #expect(await peer.commands == [.lifecycle(capture: capture, action: .wake)])
    updateLifecycleStore(store, target: target, peer: peer, canWrite: false)
    #expect(await !store.wake(capture: capture))
    #expect(await peer.commands.count == 1)
    await store.shutdown()
}

@MainActor @Test(.timeLimit(.minutes(1)))
func remoteLifecycleNativeControlsAndEnvironmentPolicyFitBothAppearancesWithoutAnyWindow() async throws {
    let store = RemoteLifecycleStore(), peer = LifecycleStorePeer(), target = lifecycleStoreTarget()
    updateLifecycleStore(store, target: target, peer: peer); await store.refresh()
    let policy = try #require(store.policy), reads = await peer.requests.count
    for scheme in [ColorScheme.light, .dark] {
        let controls = NSHostingController(rootView: RemoteLifecycleControls(store: store).frame(width: 560).environment(\.colorScheme, scheme))
        let settings = NSHostingController(rootView: RemoteLifecycleSettingsSheet(store: store, environmentID: target.environmentID,
            policy: policy, close: {}).environment(\.colorScheme, scheme))
        let size = controls.sizeThatFits(in: .init(width: 560, height: 1_000))
        let form = settings.sizeThatFits(in: .init(width: 500, height: 1_000))
        #expect(size.width > 300 && size.height > 60 && size.height < 1_000)
        #expect(form.width >= 480 && form.height > 200 && form.height < 1_000)
    }
    let afterReads = await peer.requests.count, commands = await peer.commands
    #expect(afterReads == reads && commands.isEmpty)
    await store.shutdown()
}
