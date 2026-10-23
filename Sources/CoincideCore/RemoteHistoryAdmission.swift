import Foundation

struct RemoteHistoryScope: Codable, Sendable {
    let mutatingPaths: [String]
    let coordinationPaths: [String]
}
struct RemoteHistoryPreparedReview: Codable, Sendable {
    let target: RemoteWorkspaceTarget
    let native: ConversationHistoryReview
    let digest: String
}
struct RemoteHistoryMaintenanceReview: Codable, Sendable {
    let id: UUID
    let target: RemoteWorkspaceTarget
    let operation: ConversationHistoryOperation
    let expected: OpenCodeV2HistorySnapshot
    let digest: String
}
struct RemoteHistoryPreparation: Codable, Sendable {
    enum Action: Codable, Sendable {
        case begin(ConversationHistoryReview, digest: String, title: String?)
        case reconcile(ConversationHistoryOperation, ConversationHistoryReconciliation)
        case files(ConversationHistoryOperation, GitCheckpointRestoreInspection)
        case acknowledge(ConversationHistoryOperation)
        case recall(ConversationHistoryOperation, ChatMessage)
        case dismiss(ConversationHistoryOperation)
        case maintenance(ConversationHistoryOperation, ConversationHistoryMaintenanceAttempt, reviewID: UUID, digest: String)
        case cancelPi(ConversationHistoryOperation)
        case respondPi(ConversationHistoryOperation, sessionID: UUID, request: ApprovalRequest, response: ProviderApprovalResponse)
        case claudeResume(ClaudeResumeSelection, ThreadRunRecord, ClaudeResumeInspection)
        case piFresh(PiFreshSessionIntent, ThreadRunRecord, PiFreshSessionInspection)
    }
    let target: RemoteWorkspaceTarget
    let incarnation: UUID
    let action: Action
    var allowsLockedTarget: Bool { if case .begin = action { false } else { true } }
    var requiresBoundRoot: Bool {
        switch action { case .acknowledge, .recall, .dismiss, .cancelPi, .respondPi: false; default: true }
    }
    var scope: RemoteHistoryScope {
        if case .begin(let review, _, _) = action, let files = review.files {
            return .init(mutatingPaths: [files.gitReview.currentPlan.repositoryPath, files.gitReview.currentPlan.commonDirectoryPath],
                         coordinationPaths: [files.gitReview.currentPlan.commonDirectoryPath])
        }
        return .init(mutatingPaths: [], coordinationPaths: [])
    }
}
enum RemoteHistoryAdmission {
    static func commands(_ request: RemoteEnvironmentCommandRequest, preparation: RemoteEnvironmentPreparation,
                         snapshot: WorkspaceSnapshot) throws -> [EngineCommand] {
        guard case .history(let target, let action) = request.command, case .history(let captured) = preparation,
              target.environmentID == request.environmentID,
              try RemoteHistoryProtocol.payload(target) == RemoteHistoryProtocol.payload(captured.target),
              !action.requiresBoundRoot || target.rootID != nil,
              let thread = snapshot.threads.first(where: { $0.id == target.threadID && $0.projectID == target.projectID }),
              !thread.isArchived, thread.workspacePath.utf8.elementsEqual(target.workspacePath.utf8),
              try RemoteHistoryProtocol.payload(ProviderConfiguration(thread: thread)) == RemoteHistoryProtocol.payload(target.configuration) else { throw RemoteEnvironmentAdmission.stale() }
        func operation(_ expected: ConversationHistoryOperation, id: UUID) throws {
            guard expected.id == id, expected.review.sourceThreadID == thread.id, expected.review.projectID == thread.projectID,
                  let current = snapshot.conversationHistoryOperation(id),
                  try RemoteHistoryProtocol.payload(current) == RemoteHistoryProtocol.payload(expected) else { throw RemoteEnvironmentAdmission.stale() }
        }
        switch (action, captured.action) {
        case (.begin(let id, let digest, let title), .begin(let review, let expectedDigest, let expectedTitle)):
            guard review.id == id, digest == expectedDigest, try RemoteHistoryProtocol.payload(title) == RemoteHistoryProtocol.payload(expectedTitle),
                  review.sourceThreadID == thread.id, review.projectID == thread.projectID,
                  review.sourceIncarnation == captured.incarnation else { throw RemoteEnvironmentAdmission.stale() }
            return [.conversationHistoryAccepted(review: review, title: title)]
        case (.inspectProvider(let id), .reconcile(let expected, let result)),
             (.keepOpenCodeV1Original(let id), .reconcile(let expected, let result)),
             (.keepPiOriginal(let id), .reconcile(let expected, let result)):
            try operation(expected, id: id)
            switch (action, result) {
            case (.keepOpenCodeV1Original, .openCodeV1NotAdopted):
                guard expected.review.openCodeV1 != nil else { throw RemoteEnvironmentAdmission.stale() }
            case (.keepPiOriginal, .piOriginalKept):
                guard expected.review.pi != nil else { throw RemoteEnvironmentAdmission.stale() }
            case (.inspectProvider, .openCodeV1NotAdopted), (.inspectProvider, .piOriginalKept): throw RemoteEnvironmentAdmission.stale()
            case (.inspectProvider, _): break
            default: throw RemoteEnvironmentAdmission.stale()
            }
            return [.conversationHistoryReconciled(operationID: id, incarnation: captured.incarnation, result: result)]
        case (.inspectFiles(let id), .files(let expected, let result)):
            try operation(expected, id: id)
            return [.conversationHistoryFilesInspected(operationID: id, incarnation: captured.incarnation, result: result)]
        case (.acknowledgeFiles(let id), .acknowledge(let expected)):
            try operation(expected, id: id); return [.client(.acknowledgeConversationHistoryFiles(operationID: id))]
        case (.recallPrompt(let id), .recall(let expected, let message)):
            try operation(expected, id: id)
            guard let run = thread.runHistory?.first(where: { $0.id == expected.review.runID }),
                  run.origin == .user, run.userMessageID == message.id,
                  let current = thread.messages.first(where: { $0.id == message.id }),
                  try RemoteHistoryProtocol.payload(current) == RemoteHistoryProtocol.payload(message) else { throw RemoteEnvironmentAdmission.stale() }
            return [.client(.recallConversationHistoryPrompt(operationID: id))]
        case (.dismissRecall(let id), .dismiss(let expected)):
            try operation(expected, id: id); return [.client(.dismissConversationHistoryRecall(operationID: id))]
        case (.clearMaintenance(let id, let reviewID, let digest), .maintenance(let expected, let attempt, let savedID, let savedDigest)):
            try operation(expected, id: id)
            guard reviewID == savedID, digest == savedDigest, expected.review.openCodeV2 != nil else { throw RemoteEnvironmentAdmission.stale() }
            return [.conversationHistoryMaintenanceAccepted(operationID: id, attempt: attempt, incarnation: captured.incarnation)]
        case (.cancelPi(let id), .cancelPi(let expected)):
            try operation(expected, id: id)
            guard expected.review.pi != nil, expected.isPending else { throw RemoteEnvironmentAdmission.stale() }
            return [.conversationHistoryPiCancelled(operationID: id, incarnation: captured.incarnation)]
        case (.respondPi(let id, let sessionID, let request, let response), .respondPi(let expected, let savedSession, let savedRequest, let savedResponse)):
            try operation(expected, id: id)
            guard expected.review.pi != nil, expected.phase == .dispatching, expected.piControls?.sessionID == sessionID,
                  expected.piControls?.requests.contains(where: { $0.id == request.id && !$0.responding && (try? RemoteHistoryProtocol.payload($0.request)) == (try? RemoteHistoryProtocol.payload(request)) }) == true,
                  sessionID == savedSession, try RemoteHistoryProtocol.payload(request) == RemoteHistoryProtocol.payload(savedRequest),
                  try RemoteHistoryProtocol.payload(response) == RemoteHistoryProtocol.payload(savedResponse) else { throw RemoteEnvironmentAdmission.stale() }
            return [.conversationHistoryPiControlResponding(operationID: id, sessionID: sessionID, requestID: request.id,
                response: response, incarnation: captured.incarnation)]
        case (.inspectClaudeResume(let id, let consumer), .claudeResume(let selection, let run, let result)):
            guard selection.id == id, run.id == consumer, thread.claudeResumeSelection == selection,
                  thread.claudeResumeConsumerRunID == consumer, let current = thread.runHistory?.first(where: { $0.id == consumer }),
                  try RemoteHistoryProtocol.payload(current) == RemoteHistoryProtocol.payload(run) else { throw RemoteEnvironmentAdmission.stale() }
            return [.claudeResumeInspected(threadID: thread.id, incarnation: captured.incarnation, selection: selection, run: run, result: result)]
        case (.acknowledgePiFreshUnwritten(let id, let consumer), .piFresh(let intent, let run, .unwritten)),
             (.confirmPiFreshPersisted(let id, let consumer), .piFresh(let intent, let run, .persisted)):
            guard intent.id == id, run.id == consumer, thread.piFreshSessionIntent == intent, thread.piFreshConsumerRunID == consumer,
                  let current = thread.runHistory?.first(where: { $0.id == consumer }),
                  try RemoteHistoryProtocol.payload(current) == RemoteHistoryProtocol.payload(run) else { throw RemoteEnvironmentAdmission.stale() }
            guard case .piFresh(_, _, let result) = captured.action else { throw RemoteEnvironmentAdmission.stale() }
            return [.piFreshSessionResolved(threadID: thread.id, incarnation: captured.incarnation, intent: intent, consumerRunID: consumer, inspection: result)]
        default: throw RemoteEnvironmentAdmission.stale()
        }
    }
}
