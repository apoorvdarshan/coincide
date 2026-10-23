import Foundation

enum RemoteProjectScriptAdmission {
    static func commands(_ request: RemoteEnvironmentCommandRequest, preparation: RemoteEnvironmentPreparation,
                         snapshot: WorkspaceSnapshot) throws -> [EngineCommand] {
        guard case .projectScript(let target, let action) = request.command, case .projectScript(let prepared) = preparation,
              target.environmentID == request.environmentID, RemoteLifecycleProtocol.same(target, prepared.target),
              RemoteLifecycleProtocol.same(action, prepared.action), !action.requiresBoundRoot || target.rootID != nil,
              let thread = snapshot.threads.first(where: { $0.id == target.threadID && $0.projectID == target.projectID }),
              snapshot.projects.contains(where: { $0.id == target.projectID }),
              thread.workspacePath.utf8.elementsEqual(target.workspacePath.utf8),
              RemoteLifecycleProtocol.same(ProviderConfiguration(thread: thread), target.configuration),
              thread.settlement?.id == action.generationID, thread.settlement?.phase == .settled,
              let run = thread.settlement?.script, run.id == action.runID else { throw RemoteProjectScriptFailure(.invalidTarget) }
        switch action {
        case .approve(let claim):
            guard let plan = prepared.native.run?.plan, claim.runID == run.id, claim.generationID == thread.settlement?.id,
                  RemoteLifecycleProtocol.same(claim.target, target), run.canApprove,
                  RemoteLifecycleProtocol.same(run.plan, plan) else { throw RemoteProjectScriptFailure(.staleReview) }
            return [.client(.approveProjectScript(threadID: thread.id, runID: run.id, expectedPlan: plan))]
        case .stop: return [.client(.stopProjectScript(threadID: thread.id, runID: run.id))]
        case .skip: return [.client(.skipProjectScript(threadID: thread.id, runID: run.id))]
        case .retry: return [.client(.retryProjectScript(threadID: thread.id, runID: run.id))]
        }
    }
}
