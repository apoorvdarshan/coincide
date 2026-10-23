import CoincideCore
import Foundation

/// A retained row owns its original source, never the current selection's IDs.
struct TranscriptActionSource: Equatable {
    let threadID: UUID
    let threadCreatedAt: Date
    let projectID: UUID
    let projectCreatedAt: Date?
    let projectPath: Data
    let workspacePath: Data
    let configuration: Data
    let preparationID: UUID?
    let runID: UUID?
    let runtimeID: UUID?
    let settlementID: UUID?
    let message: ChatMessage
    let messageRevision: Data

    init?(thread: CodingThread, project: WorkspaceProject, message: ChatMessage) {
        guard let configuration = Self.bytes(ProviderConfiguration(thread: thread)),
              let revision = Self.bytes(message) else { return nil }
        threadID = thread.id; threadCreatedAt = thread.createdAt; projectID = project.id
        projectCreatedAt = project.createdAt; projectPath = Data(project.path.utf8)
        workspacePath = Data(thread.workspacePath.utf8); self.configuration = configuration
        preparationID = thread.workspacePreparation?.id; runID = thread.activeRun?.id
        runtimeID = thread.runtimeID; settlementID = thread.settlement?.id
        self.message = message; messageRevision = revision
    }

    func matches(thread: CodingThread, project: WorkspaceProject) -> Bool {
        guard thread.id == threadID, thread.createdAt == threadCreatedAt, thread.projectID == projectID,
              project.id == projectID, project.createdAt == projectCreatedAt,
              Data(project.path.utf8) == projectPath, Data(thread.workspacePath.utf8) == workspacePath,
              Self.bytes(ProviderConfiguration(thread: thread)) == configuration,
              thread.workspacePreparation?.id == preparationID, thread.activeRun?.id == runID,
              thread.runtimeID == runtimeID, thread.settlement?.id == settlementID else { return false }
        let matches = thread.visibleMessages.filter { $0.id.utf8.elementsEqual(message.id.utf8) }
        return matches.count == 1 && matches.first.map { Self.bytes($0) == messageRevision && $0.text.utf8.elementsEqual(message.text.utf8) } == true
    }

    private static func bytes<T: Encodable>(_ value: T) -> Data? {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        return try? encoder.encode(value)
    }

    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.threadID == rhs.threadID && lhs.threadCreatedAt == rhs.threadCreatedAt && lhs.projectID == rhs.projectID &&
        lhs.projectCreatedAt == rhs.projectCreatedAt && lhs.projectPath == rhs.projectPath && lhs.workspacePath == rhs.workspacePath &&
        lhs.configuration == rhs.configuration && lhs.preparationID == rhs.preparationID && lhs.runID == rhs.runID &&
        lhs.runtimeID == rhs.runtimeID && lhs.settlementID == rhs.settlementID && lhs.messageRevision == rhs.messageRevision
    }
}
