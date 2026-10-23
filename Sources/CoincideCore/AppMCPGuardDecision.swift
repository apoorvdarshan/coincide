import Foundation

extension WorkspaceDecision {
    /// Keep provider configuration/thread copies out of the common router's
    /// debug frame while unrelated history commands validate their full ledger.
    @inline(never)
    static func reduceAppMCPCommand(_ command: EngineCommand, id: UUID, snapshot: WorkspaceSnapshot, now: Date) throws -> Self {
        switch command {
        case .appMCPRequestGuard(let threadID, let runtimeID, let runID, let request):
            guard request.isQuestion, let thread = snapshot.threads.first(where: { $0.id == threadID }),
                  thread.runtimeID == runtimeID, thread.activeRun?.id == runID,
                  thread.runtimeRequests.contains(where: { $0.request == request && !$0.responding }) else {
                throw WorkspaceCommandError("The pending question changed. Read the current request before answering it.")
            }
            return Self(snapshot: snapshot)
        case .appMCPTargetGuard(let threadID, let configuration):
            guard let thread = snapshot.threads.first(where: { $0.id == threadID }), ProviderConfiguration(thread: thread) == configuration else {
                throw WorkspaceCommandError("The target configuration changed. Read it again before configuring this conversation.")
            }
            return Self(snapshot: snapshot)
        case .appMCP(let authority, let commands):
            return try AppMCPAdmission.reduce(authority: authority, commands: commands, id: id, snapshot: snapshot, now: now)
        default: throw WorkspaceCommandError("This workspace command was routed incorrectly.")
        }
    }
}
