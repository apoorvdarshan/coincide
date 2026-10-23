import Foundation

enum RemoteThreadActionsAdmission {
    static func commands(_ request: RemoteEnvironmentCommandRequest, prepared: RemoteEnvironmentPreparation, snapshot: WorkspaceSnapshot) throws -> [EngineCommand] {
        guard case .threadAction(let action) = request.command, case .threadActions(let native) = prepared, native.binding == action.binding else { throw RemoteEnvironmentAdmission.stale() }
        switch action {
        case .setPinned(let capture, let value), .setArchived(let capture, let value):
            guard let originalCapture = native.capture, RemoteLifecycleProtocol.same(originalCapture, capture), let expected = native.expected,
                  let thread = snapshot.threads.first(where: { $0.id == capture.target.threadID }),
                  let project = snapshot.projects.first(where: { $0.id == thread.projectID }),
                  ThreadActionUndoClaim.exact(expected, ThreadActionUndoClaim.State(thread: thread, project: project, draft: false)),
                  thread.activeRun?.id == capture.runID, thread.runtimeID == capture.runtimeID else { throw RemoteEnvironmentAdmission.stale() }
            if case .setPinned = action { return [.client(.editThread(thread.id, .pinned(value)))] }
            return [.client(.editThread(thread.id, .archived(value)))]
        case .undo(_, _, _, let ids):
            guard !native.claims.isEmpty, native.claims.map(\.id) == ids, native.deadline.map({ $0 > Date() }) == true else { throw RemoteEnvironmentAdmission.stale() }
            return [.remoteThreadUndo(native)]
        }
    }
}
