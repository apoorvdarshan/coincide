import Foundation
import Testing
@testable import CoincideCore

@Test func conversationExportContainsOnlyCurrentPublicHistoryAndWhitelistedAttachmentMetadata() throws {
    var thread = CodingThread(project: WorkspaceProject(path: "/private/runtime-path"))
    thread.title = "A portable conversation"
    thread.providerThreadID = "private-provider-session"
    thread.draft = "unsent-private-draft"
    thread.providerMetadata = .object(["token": .string("private-runtime-token")])
    thread.agentConfiguration = ["secret": .string("private-agent-secret")]
    var user = ChatMessage(id: "private-message-id", role: .user, text: "Visible question", attachments: [
        ChatAttachment(id: UUID(), name: "/private/source/report.txt", mimeType: "text/plain", byteCount: 12,
                       digest: "private-content-digest", fileExtension: "txt")
    ])
    user.submissionError = "private-diagnostic"
    user.providerEntity = ProviderEntity(key: .init(sessionID: "private-native-id", type: "user_message", id: "private-entity-id"),
        fields: .object(["_meta": .object(["credential": .string("private-entity-token")])]))
    var removed = ChatMessage(role: .assistant, text: "private-rewound-answer")
    removed.removedByHistoryOperationID = UUID()
    var mismatchedThought = ChatMessage(role: .tool, text: "private-old-import-reasoning")
    mismatchedThought.providerEntity = ProviderEntity(key: .init(sessionID: "native", type: "agent_thought", id: "thought"))
    thread.messages = [user, ChatMessage(role: .reasoning, text: "private-reasoning"),
                       ChatMessage(role: .assistant, text: "Visible answer"), removed, mismatchedThought,
                       ChatMessage(role: .system, text: "Visible notice")]
    for format in ConversationExportFormat.allCases {
        let artifact = try ConversationExport.make(thread: thread, format: format)
        let text = String(decoding: artifact.data, as: UTF8.self)
        #expect(artifact.messageCount == 3)
        #expect(!text.contains("private-"))
        #expect(!text.contains("/private/"))
        #expect(text.contains("Visible question") && text.contains("Visible answer") && text.contains("Visible notice"))
        #expect(text.contains("report") && text.contains("text/plain") && text.contains("12"))
        #expect(artifact.fileExtension == format.fileExtension)
    }
    let json = try JSONDecoder().decode(JSONValue.self, from: ConversationExport.make(thread: thread, format: .json).data)
    #expect(Set(json.object!.keys) == ["schemaVersion", "application", "title", "createdAt", "updatedAt", "messages", "truncatedToolMessages"])
    #expect(Set(json["messages"].array![0].object!.keys) == ["role", "text", "createdAt", "toolTextTruncated", "attachments"])
    #expect(Set(json["messages"].array![0]["attachments"].array![0].object!.keys) == ["name", "mimeType", "byteCount"])
}

@Test func conversationExportBoundsToolOutputOnAUnicodeBoundaryAndReportsTruncation() throws {
    var thread = CodingThread(project: WorkspaceProject(path: "/fixture"))
    thread.messages = [ChatMessage(role: .user, text: "完整"), ChatMessage(role: .tool, text: "🦉🦉🦉"),
                       ChatMessage(role: .assistant, text: "Done")]
    let artifact = try ConversationExport.make(thread: thread, format: .json, limits: .init(toolTextBytes: 6))
    let json = try JSONDecoder().decode(JSONValue.self, from: artifact.data)
    #expect(artifact.messageCount == 3 && artifact.truncatedToolMessages == 1)
    #expect(json["messages"].array![1]["text"] == .string("🦉"))
    #expect(json["messages"].array![1]["toolTextTruncated"] == .bool(true))
    #expect(json["messages"].array![0]["text"] == .string("完整"))
    let markdown = try ConversationExport.make(thread: thread, format: .markdown, limits: .init(toolTextBytes: 6))
    #expect(String(decoding: markdown.data, as: UTF8.self).contains("Tool output truncated"))
}

@Test func conversationExportRefusesOversizedPublicHistoryInsteadOfSilentlyDroppingUserMessages() throws {
    var thread = CodingThread(project: WorkspaceProject(path: "/fixture"))
    thread.messages = [ChatMessage(role: .user, text: "hello"), ChatMessage(role: .assistant, text: "world")]
    #expect(throws: CoincideError.self) { try ConversationExport.make(thread: thread, format: .json, limits: .init(messages: 1)) }
    #expect(throws: CoincideError.self) { try ConversationExport.make(thread: thread, format: .json, limits: .init(totalTextBytes: 9)) }
    #expect(throws: CoincideError.self) { try ConversationExport.make(thread: thread, format: .json, limits: .init(outputBytes: 1)) }
}

@Test func conversationExportPreservesChronologyAndLiteralToolCodeFences() throws {
    var thread = CodingThread(project: WorkspaceProject(path: "/fixture"))
    thread.messages = [ChatMessage(role: .user, text: "**First**"),
                       ChatMessage(role: .tool, text: "```\n# Untrusted heading\n```"),
                       ChatMessage(role: .assistant, text: "Last")]
    for index in thread.messages.indices { thread.messages[index].createdAt = Date(timeIntervalSince1970: Double(index)) }
    let text = String(decoding: try ConversationExport.make(thread: thread, format: .markdown).data, as: UTF8.self)
    #expect(text.contains("## User · 1970-01-01T00:00:00Z\n\n**First**"))
    #expect(text.contains("    ```\n    # Untrusted heading\n    ```"))
    #expect(text.range(of: "**First**")!.lowerBound < text.range(of: "Untrusted heading")!.lowerBound)
    #expect(text.range(of: "Untrusted heading")!.lowerBound < text.range(of: "Last")!.lowerBound)
}

@Test func conversationExportFilenamesCannotEscapeTheSaveDirectory() {
    #expect(ConversationExport.filename(title: "../../secret\\token:\u{0}\nchat", format: .json) == "secret-token---chat.json")
    #expect(ConversationExport.filename(title: ".. / \\ ..", format: .markdown) == "Conversation.md")
    let name = ConversationExport.filename(title: String(repeating: "a", count: 1_000), format: .markdown)
    #expect(name.count == 123)
    #expect(ConversationExport.filename(title: "日本語の会話", format: .json) == "日本語の会話.json")
    #expect(ConversationExport.filename(title: String(repeating: "🦉", count: 120), format: .json).utf8.count <= 185)
}
