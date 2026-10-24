import Foundation

public enum ConversationExportFormat: String, CaseIterable, Sendable, Codable {
    case markdown, json
    public var fileExtension: String { self == .markdown ? "md" : "json" }
}

public struct ConversationExportArtifact: Sendable {
    public let data: Data
    public let format: ConversationExportFormat
    public let suggestedFilename: String
    public let messageCount: Int
    public let truncatedToolMessages: Int
    public var fileExtension: String { format.fileExtension }
}

/// A portable public transcript, not a serialization of the provider/runtime.
/// Visible message text is exported as written and may contain information the
/// user placed in the conversation. No credential/configuration store is read.
public enum ConversationExport {
    struct Limits {
        var messages = 50_000
        var totalTextBytes = 32 * 1_024 * 1_024
        var toolTextBytes = 256 * 1_024
        var outputBytes = 128 * 1_024 * 1_024
    }

    public static func make(thread: CodingThread, format: ConversationExportFormat) throws -> ConversationExportArtifact {
        try make(thread: thread, format: format, limits: Limits())
    }

    static func make(thread: CodingThread, format: ConversationExportFormat, limits: Limits) throws -> ConversationExportArtifact {
        var messages: [PublicMessage] = [], textBytes = 0, truncatedTools = 0
        for message in thread.messages {
            // Never resurrect a rewound message or export private reasoning,
            // even if an older imported entity has an inconsistent role.
            guard message.removedByHistoryOperationID == nil, message.role != .reasoning,
                  message.providerEntity?.role != .reasoning else { continue }
            guard messages.count < limits.messages else { throw tooLarge }
            let text: String, truncated: Bool
            if message.role == .tool {
                let bounded = TranscriptOutputTail.head(message.text, maxLines: .max, maxBytes: limits.toolTextBytes)
                text = bounded.text; truncated = bounded.truncated
            } else { text = message.text; truncated = false }
            guard text.utf8.count <= limits.totalTextBytes - textBytes else { throw tooLarge }
            textBytes += text.utf8.count
            if truncated { truncatedTools += 1 }
            let attachments = message.attachments ?? []
            guard attachments.count <= AttachmentLimits.count else { throw tooLarge }
            let publicAttachments = attachments.map {
                PublicAttachment(name: attachmentName($0.name), mimeType: singleLine($0.mimeType, limit: 128),
                                 byteCount: max(0, $0.byteCount))
            }
            for attachment in publicAttachments {
                let size = attachment.name.utf8.count + attachment.mimeType.utf8.count
                guard size <= limits.totalTextBytes - textBytes else { throw tooLarge }
                textBytes += size
            }
            messages.append(PublicMessage(role: message.role.rawValue, text: text,
                createdAt: message.createdAt, toolTextTruncated: truncated,
                attachments: publicAttachments))
        }
        let document = PublicConversation(schemaVersion: 1, application: "Coincide",
            title: String(String.UnicodeScalarView(thread.title.unicodeScalars.prefix(4_096))), createdAt: thread.createdAt,
            updatedAt: thread.updatedAt, messages: messages, truncatedToolMessages: truncatedTools)
        let data: Data
        switch format {
        case .json:
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
            data = try encoder.encode(document)
        case .markdown: data = Data(markdown(document).utf8)
        }
        guard data.count <= limits.outputBytes else { throw tooLarge }
        return ConversationExportArtifact(data: data, format: format,
            suggestedFilename: filename(title: document.title, format: format),
            messageCount: messages.count, truncatedToolMessages: truncatedTools)
    }

    public static func filename(title: String, format: ConversationExportFormat) -> String {
        let unsafe = CharacterSet.controlCharacters.union(CharacterSet(charactersIn: "/\\:*?\"<>|"))
        let cleaned = title.unicodeScalars.prefix(120).map { unsafe.contains($0) ? "-" : String($0) }.joined()
        let bounded = TranscriptOutputTail.head(cleaned, maxLines: .max, maxBytes: 180).text
        let stem = bounded.split(whereSeparator: \.isWhitespace).joined(separator: " ")
            .trimmingCharacters(in: CharacterSet(charactersIn: ". -"))
        return (stem.isEmpty ? "Conversation" : stem) + "." + format.fileExtension
    }

    private static var tooLarge: CoincideError { CoincideError("This conversation is too large to export in one file. No export was written.") }

    private static func attachmentName(_ name: String) -> String {
        let basename = name.replacingOccurrences(of: "\\", with: "/").split(separator: "/").last.map(String.init) ?? "Attachment"
        return singleLine(basename, limit: 1_024)
    }

    private static func singleLine(_ text: String, limit: Int) -> String {
        String(text.unicodeScalars.prefix(limit).map { CharacterSet.controlCharacters.contains($0) ? " " : String($0) }.joined())
    }

    private static func markdown(_ document: PublicConversation) -> String {
        let dates = ISO8601DateFormatter()
        var lines = ["# " + escaped(singleLine(document.title, limit: 4_096)), "",
                     "Exported from Coincide. Attachment files, private reasoning and provider configuration are excluded.", "",
                     "Created: \(dates.string(from: document.createdAt))", "Updated: \(dates.string(from: document.updatedAt))", ""]
        for message in document.messages {
            let role = message.role == "system" ? "Notice" : message.role.capitalized
            lines += ["## \(role) · \(dates.string(from: message.createdAt))", ""]
            if !message.text.isEmpty {
                // Indentation keeps tool output literal, including nested code
                // fences. User/assistant Markdown retains its original markup.
                lines += [message.role == "tool" ? message.text.components(separatedBy: "\n").map { "    " + $0 }.joined(separator: "\n") : message.text, ""]
            }
            if message.toolTextTruncated { lines += ["*Tool output truncated in this export.*", ""] }
            if !message.attachments.isEmpty {
                lines += message.attachments.map { "- Attachment: \(escaped($0.name)) (\(escaped($0.mimeType)), \($0.byteCount) bytes; file not included)" }
                lines.append("")
            }
        }
        return lines.joined(separator: "\n") + "\n"
    }

    private static func escaped(_ text: String) -> String {
        var result = ""
        for character in text {
            if "\\`*_{}[]()#+-.!|<>".contains(character) { result.append("\\") }
            result.append(character)
        }
        return result
    }

    // Explicit allowlists: adding a property to CodingThread, ChatMessage or
    // ChatAttachment can never silently expand the export's private surface.
    private struct PublicConversation: Encodable {
        let schemaVersion: Int
        let application: String
        let title: String
        let createdAt: Date
        let updatedAt: Date
        let messages: [PublicMessage]
        let truncatedToolMessages: Int
    }
    private struct PublicMessage: Encodable {
        let role: String
        let text: String
        let createdAt: Date
        let toolTextTruncated: Bool
        let attachments: [PublicAttachment]
    }
    private struct PublicAttachment: Encodable {
        let name: String
        let mimeType: String
        let byteCount: Int
    }
}
