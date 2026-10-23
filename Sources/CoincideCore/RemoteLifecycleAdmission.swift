import Foundation

enum RemoteLifecycleAdmission {
    /// The Engine validates prepared server incarnations at its serialized
    /// admission boundary; this pure adapter then rechecks all snapshot fields.
    static func commands(_ request: RemoteEnvironmentCommandRequest, prepared: RemoteLifecyclePreparation,
                         snapshot: WorkspaceSnapshot) throws -> [EngineCommand] {
        switch (request.command, prepared.action) {
        case (.lifecyclePolicy(let policy, let expected), .policy(let saved, let previous)):
            guard RemoteLifecycleProtocol.same(policy, saved), RemoteLifecycleProtocol.same(expected, previous),
                  RemoteLifecycleProtocol.same(snapshot.workspaceLifecyclePolicy ?? .init(), expected) else { throw RemoteLifecycleFailure(.staleCapture) }
            do { try policy.validate() } catch { throw RemoteLifecycleFailure(.invalidRequest) }
            return [.client(.setWorkspaceLifecyclePolicy(policy))]
        case (.lifecycle(let capture, let action), .thread(let native, let saved, let accepted)):
            guard RemoteLifecycleProtocol.same(capture, saved), RemoteLifecycleProtocol.same(action, accepted),
                  capture.target.environmentID == request.environmentID,
                  RemoteLifecycleProtocol.same(capture.target, native.target),
                  let thread = snapshot.threads.first(where: { $0.id == native.target.threadID && $0.projectID == native.target.projectID }),
                  snapshot.projects.contains(where: { $0.id == thread.projectID }), !thread.isArchived,
                  thread.workspacePath.utf8.elementsEqual(native.target.workspacePath.utf8),
                  RemoteLifecycleProtocol.same(ProviderConfiguration(thread: thread), native.target.configuration),
                  RemoteLifecycleProtocol.same(thread.workspaceLifecycle, native.lifecycle),
                  thread.settlement?.id == native.settlementID, thread.settlement?.phase == native.settlementPhase,
                  !action.requiresBoundRoot || native.target.rootID != nil else { throw RemoteLifecycleFailure(.staleCapture) }
            switch action {
            case .settleWithoutScript:
                guard snapshot.canSettle(threadID: thread.id) else { throw RemoteLifecycleFailure(.busy) }
                return [.client(.settleThread(threadID: thread.id, expectedWorkspacePath: native.target.workspacePath, reviewScript: false))]
            case .resume(let id):
                guard thread.settlement?.id == id, thread.settlement?.phase == .settled else { throw RemoteLifecycleFailure(.staleCapture) }
                return [.client(.resumeThread(threadID: thread.id, generationID: id))]
            case .snooze(let until):
                return [.client(.workspaceLifecycle(.snooze(threadID: thread.id, until: until)))]
            case .wake:
                return [.client(.workspaceLifecycle(.wake(threadID: thread.id)))]
            case .setAutoSettle(let enabled):
                return [.client(.workspaceLifecycle(.setAutoSettle(threadID: thread.id, enabled: enabled)))]
            }
        default: throw RemoteLifecycleFailure(.invalidRequest)
        }
    }
}
