import Foundation
import Testing
@testable import CoincideCore

private struct LifecycleCoreFixture: Sendable {
    let environmentID = UUID(), rootID = UUID(), projectIncarnation = UUID(), threadIncarnation = UUID()
    var snapshot: WorkspaceSnapshot
    init(snoozed: Bool = false) {
        let project = WorkspaceProject(path: "/tmp/coincide-lifecycle-main")
        var thread = CodingThread(project: project, model: "Private lifecycle model")
        thread.workspacePath = "/tmp/coincide-lifecycle-worktree"; thread.draft = "Keep unsent draft e\u{301}"
        if snoozed { thread.workspaceLifecycle = .init(snoozedUntil: Date().addingTimeInterval(3_600), snoozedAt: Date()) }
        snapshot = .init(); snapshot.projects = [project]; snapshot.threads = [thread]
    }
    var target: RemoteWorkspaceTarget {
        .init(environmentID: environmentID, projectID: snapshot.projects[0].id, threadID: snapshot.threads[0].id,
              configuration: .init(thread: snapshot.threads[0]), rootID: rootID)
    }
    func native(_ target: RemoteWorkspaceTarget? = nil) -> RemoteLifecycleNativeRead {
        let thread = snapshot.threads[0]
        return .init(sequence: 42, policy: snapshot.workspaceLifecyclePolicy ?? .init(), state: .init(target: target ?? self.target,
            projectIncarnation: projectIncarnation, threadIncarnation: threadIncarnation, lifecycle: thread.workspaceLifecycle,
            settlementID: thread.settlement?.id, settlementPhase: thread.settlement?.phase,
            settle: .init(allowed: snapshot.canSettle(threadID: thread.id)), resume: .init(allowed: thread.settlement?.phase == .settled),
            snooze: .init(allowed: true), wake: .init(allowed: thread.workspaceLifecycle?.snoozedUntil != nil)))
    }
    func service() -> RemoteLifecycleService {
        .init(environmentID: environmentID, read: { target in
            if let target { return native(target) }
            return .init(sequence: 42, policy: snapshot.workspaceLifecyclePolicy ?? .init())
        }, bind: { $0 })
    }
}

@Test func remoteLifecycleHostClaimsRejectFabricatedAndChangedDescriptorsWithoutExposingIncarnations() async throws {
    let f = LifecycleCoreFixture(), service = f.service()
    let result = try await service.read(.init(environmentID: f.environmentID, target: f.target))
    let state = try #require(result.thread), capture = state.capture
    let prepared = try await service.prepare(capture, action: .settleWithoutScript)
    guard case .thread(let native, let saved, .settleWithoutScript) = prepared.action else { Issue.record("Wrong native lifecycle preparation"); return }
    #expect(saved == capture && native.threadIncarnation == f.threadIncarnation && native.projectIncarnation == f.projectIncarnation)
    let wire = String(decoding: try RemoteLifecycleProtocol.payload(result), as: UTF8.self)
    #expect(!wire.contains(f.threadIncarnation.uuidString) && !wire.contains(f.projectIncarnation.uuidString) && !wire.contains("Incarnation"))
    let invented = RemoteLifecycleCapture(id: UUID(), digest: capture.digest, target: capture.target)
    await #expect(throws: RemoteLifecycleFailure(.staleCapture)) { try await service.prepare(invented, action: .wake) }
    var configuration = capture.target.configuration; configuration.model += " changed"
    let changedTarget = RemoteWorkspaceTarget(environmentID: f.environmentID, projectID: capture.target.projectID,
        threadID: capture.target.threadID, configuration: configuration, rootID: capture.target.rootID)
    let changed = RemoteLifecycleCapture(id: capture.id, digest: capture.digest, target: changedTarget)
    await #expect(throws: RemoteLifecycleFailure(.staleCapture)) { try await service.prepare(changed, action: .settleWithoutScript) }
    let foreign = RemoteLifecycleReadRequest(environmentID: UUID(), target: f.target)
    await #expect(throws: RemoteLifecycleFailure(.invalidTarget)) { try await service.read(foreign) }
    await service.close()
}

@Test func remoteLifecycleWakeUsesOriginalUUIDAndChangesOnlyAttentionWithoutStartingInputOrScripts() async throws {
    let f = LifecycleCoreFixture(snoozed: true), service = f.service()
    let state = try #require(await service.read(.init(environmentID: f.environmentID, target: f.target)).thread)
    let preparation = try await service.prepare(state.capture, action: .wake)
    let request = RemoteEnvironmentCommandRequest(environmentID: f.environmentID, command: .lifecycle(capture: state.capture, action: .wake))
    let commands = try RemoteLifecycleAdmission.commands(request, prepared: preparation, snapshot: f.snapshot)
    #expect(commands.count == 1)
    guard case .some(.client(.workspaceLifecycle(.wake(let threadID)))) = commands.first else {
        Issue.record("Wake must translate only to an attention command"); await service.close(); return
    }
    #expect(threadID == f.target.threadID)
    let decision = try WorkspaceDecision.make(.remoteEnvironment(request, preparation: .lifecycle(preparation)), id: request.id, snapshot: f.snapshot, now: Date())
    let before = f.snapshot.threads[0], after = decision.snapshot.threads[0]
    #expect(after.workspaceLifecycle?.snoozedUntil == nil && after.workspaceLifecycle?.snoozedAt == nil)
    #expect(after.draft == before.draft && after.messages == before.messages && after.queuedTurns == before.queuedTurns)
    #expect(after.settlement == nil && after.runtimeID == nil && after.activeRun == nil && decision.effects.isEmpty)
    await service.close()
}

@Test(arguments: ["configuration", "metadata", "settlement", "project", "policy"])
func remoteLifecycleFinalAdmissionRefusesChangedScopeAndPolicyWithoutASecondIntent(change: String) async throws {
    let f = LifecycleCoreFixture(snoozed: true), service = f.service()
    let state = try #require(await service.read(.init(environmentID: f.environmentID, target: f.target)).thread)
    let prepared = try await service.prepare(state.capture, action: .wake)
    let request = RemoteEnvironmentCommandRequest(environmentID: f.environmentID, command: .lifecycle(capture: state.capture, action: .wake))
    var changed = f.snapshot
    switch change {
    case "configuration": changed.threads[0].model += " changed"
    case "metadata": changed.threads[0].workspaceLifecycle?.snoozedUntil?.addTimeInterval(60)
    case "settlement": changed.threads[0].settlement = .init()
    case "project": changed.projects = []
    default:
        let expected = WorkspaceLifecyclePolicy(), next = WorkspaceLifecyclePolicy(afterDays: nil, onMerge: false)
        let policy = try await service.preparePolicy(next, expected: expected)
        changed.workspaceLifecyclePolicy = .init(afterDays: 14, onMerge: true)
        let command = RemoteEnvironmentCommandRequest(environmentID: f.environmentID, command: .lifecyclePolicy(policy: next, expected: expected))
        #expect(throws: RemoteLifecycleFailure(.staleCapture)) { try RemoteLifecycleAdmission.commands(command, prepared: policy, snapshot: changed) }
        await service.close(); return
    }
    #expect(throws: RemoteLifecycleFailure(.staleCapture)) { try RemoteLifecycleAdmission.commands(request, prepared: prepared, snapshot: changed) }
    await service.close()
}

@Test func remoteLifecycleClaimsAreBoundedAndCloseCannotPublishALateRead() async throws {
    let f = LifecycleCoreFixture(), service = f.service()
    let first = try #require(await service.read(.init(environmentID: f.environmentID, target: f.target)).thread?.capture)
    for _ in 0..<64 { _ = try await service.read(.init(environmentID: f.environmentID, target: f.target)) }
    await #expect(throws: RemoteLifecycleFailure(.staleCapture)) { try await service.prepare(first, action: .settleWithoutScript) }
    await service.close()
    await #expect(throws: RemoteLifecycleFailure(.unavailable)) { try await service.read(.init(environmentID: f.environmentID)) }
    let boundary = LifecycleCoreBoundary()
    let late = RemoteLifecycleService(environmentID: f.environmentID, read: { target in
        await boundary.pause(); return f.native(target)
    }, bind: { $0 })
    let task = Task { try await late.read(.init(environmentID: f.environmentID, target: f.target)) }
    await boundary.entered(); await late.close(); await boundary.release()
    await #expect(throws: RemoteLifecycleFailure(.unavailable)) { try await task.value }
}

private actor LifecycleCoreBoundary {
    private var waiting = false, released = false
    private var continuation: CheckedContinuation<Void, Never>?
    private var observers: [CheckedContinuation<Void, Never>] = []
    func pause() async {
        waiting = true; observers.forEach { $0.resume() }; observers = []
        if !released { await withCheckedContinuation { continuation = $0 } }
    }
    func entered() async { if !waiting { await withCheckedContinuation { observers.append($0) } } }
    func release() { released = true; continuation?.resume(); continuation = nil }
}
