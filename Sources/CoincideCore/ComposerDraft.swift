import Foundation

/// A draft belongs to the exact native workspace shown when the action began.
/// It deliberately contains no runtime/provider state or complete CodingThread.
public struct ComposerDraftSnapshot: Codable, Sendable, Equatable {
    public let threadID: UUID
    public let projectID: UUID
    public let workspacePath: String
    public let text: String
    public let attachments: [ChatAttachment]
    public init(threadID: UUID, projectID: UUID, workspacePath: String, text: String, attachments: [ChatAttachment]) {
        self.threadID = threadID; self.projectID = projectID; self.workspacePath = workspacePath
        self.text = text; self.attachments = attachments
    }
    public func matches(_ other: Self) -> Bool {
        threadID == other.threadID && projectID == other.projectID && workspacePath.utf8.elementsEqual(other.workspacePath.utf8)
            && text.utf8.elementsEqual(other.text.utf8) && Self.sameAttachments(attachments, other.attachments)
    }
    public static func sameAttachments(_ lhs: [ChatAttachment], _ rhs: [ChatAttachment]) -> Bool {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        return (try? encoder.encode(lhs)) == (try? encoder.encode(rhs))
    }
}

/// Heap storage avoids growing every WorkspaceCommand enum payload. Encoding
/// stays flat and persists the exact expected ownership/text/reference bytes.
public struct ComposerDraftReplacement: Codable, Sendable, Equatable {
    private final class Storage: Sendable {
        let expected: ComposerDraftSnapshot
        let text: String
        let attachments: [ChatAttachment]
        init(expected: ComposerDraftSnapshot, text: String, attachments: [ChatAttachment]) {
            self.expected = expected; self.text = text; self.attachments = attachments
        }
    }
    private let storage: Storage
    public var expected: ComposerDraftSnapshot { storage.expected }
    public var text: String { storage.text }
    public var attachments: [ChatAttachment] { storage.attachments }
    public init(expected: ComposerDraftSnapshot, text: String, attachments: [ChatAttachment]) {
        storage = .init(expected: expected, text: text, attachments: attachments)
    }
    public static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.expected.matches(rhs.expected) && lhs.text.utf8.elementsEqual(rhs.text.utf8)
            && ComposerDraftSnapshot.sameAttachments(lhs.attachments, rhs.attachments)
    }
    private enum CodingKeys: String, CodingKey { case threadID, projectID, workspacePath, expectedText, expectedAttachments, text, attachments }
    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.init(expected: .init(threadID: try c.decode(UUID.self, forKey: .threadID), projectID: try c.decode(UUID.self, forKey: .projectID),
            workspacePath: try c.decode(String.self, forKey: .workspacePath), text: try c.decode(String.self, forKey: .expectedText),
            attachments: try c.decode([ChatAttachment].self, forKey: .expectedAttachments)), text: try c.decode(String.self, forKey: .text),
            attachments: try c.decode([ChatAttachment].self, forKey: .attachments))
    }
    public func encode(to encoder: any Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(expected.threadID, forKey: .threadID); try c.encode(expected.projectID, forKey: .projectID)
        try c.encode(expected.workspacePath, forKey: .workspacePath); try c.encode(expected.text, forKey: .expectedText)
        try c.encode(expected.attachments, forKey: .expectedAttachments); try c.encode(text, forKey: .text); try c.encode(attachments, forKey: .attachments)
    }
}
