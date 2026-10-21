import Foundation

public struct WorkspaceCommandError: LocalizedError, Sendable {
    public var message: String
    public init(_ message: String) { self.message = message }
    public var errorDescription: String? { message }
}
public enum WorkspaceCommitError: LocalizedError, Sendable {
    case commandIDCollision, effectIDCollision, revisionChanged
    public var errorDescription: String? {
        switch self {
        case .commandIDCollision: "This command ID was already used for different workspace changes."
        case .effectIDCollision: "This operation identity was already used. Start a new operation and try again."
        case .revisionChanged: "The workspace changed. Reload it before retrying this command."
        }
    }
}
