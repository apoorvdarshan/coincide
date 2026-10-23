import Foundation

/// Closed presentation references only. Native source/configuration proof is
/// resolved by the owning host and rechecked at the journal decision boundary.
public final class RemoteTranscriptPlanCommand: Sendable {
    public let target: RemoteWorkspaceTarget
    public let binding: RemoteProjectionBinding
    public let messageID: String
    public let presentation: RemoteProjectionContentReference
    public let destination: TranscriptPlanDestination?
    init(target: RemoteWorkspaceTarget, binding: RemoteProjectionBinding, messageID: String,
         presentation: RemoteProjectionContentReference, destination: TranscriptPlanDestination? = nil) {
        self.target = target; self.binding = binding; self.messageID = messageID; self.presentation = presentation; self.destination = destination
    }
}
extension RemoteEnvironmentCommand {
    public var transcriptPlanCommand: RemoteTranscriptPlanCommand? {
        switch self {
        case .implementTranscriptPlan(let target, let binding, let messageID, let presentation):
            .init(target: target, binding: binding, messageID: messageID, presentation: presentation)
        case .implementTranscriptPlanInNewConversation(let target, let binding, let messageID, let presentation, let destinationID):
            .init(target: target, binding: binding, messageID: messageID, presentation: presentation,
                  destination: .init(threadID: destinationID))
        default: nil
        }
    }
}
