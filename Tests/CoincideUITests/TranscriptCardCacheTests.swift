import AppKit
import CoincideCore
import Testing
@testable import Coincide

@MainActor @Test func transcriptCardCacheInvalidatesSameLengthCommandsInputsResultsAndUnicodeBytes() throws {
    let project = WorkspaceProject(path: "/private/transcript-cache"), cache = TranscriptCardCache()
    let thread = CodingThread(project: project), run = UUID(), scope = TranscriptCardScope(thread: thread, runID: run)
    let context = TranscriptToolContext(provider: .claude, workspacePath: thread.workspacePath)
    var message = ChatMessage(id: "call", role: .tool, text: "Bash\n{\"command\":\"echo one\"}")
    message.runReference = .init(threadID: thread.id, runID: run)
    var result = ChatMessage(id: "result-call", role: .tool, text: "one")
    result.runReference = message.runReference
    let first = cache.card(message, result, context, scope: scope)
    #expect(first.subject == "echo one" && first.output == "one")
    message.text = "Bash\n{\"command\":\"echo two\"}"; result.text = "two"
    let second = cache.card(message, result, context, scope: scope)
    #expect(second.subject == "echo two" && second.output == "two" && cache.count == 1)
    result.text = "six"
    #expect(cache.card(message, result, context, scope: scope).output == "six")
    func entity(_ command: String, _ output: String) -> ChatMessage {
        var value = ChatMessage(id: "entity", role: .tool, text: "unchanged display")
        value.providerEntity = .init(key: .init(sessionID: "session", type: "tool_call", id: "entity"), fields: .object([
            "kind": .string("execute"), "status": .string("completed"), "title": .string("Run"),
            "rawInput": .object(["command": .string(command)]), "rawOutput": .object(["stdout": .string(output)])]))
        return value
    }
    #expect(cache.card(entity("echo one", "one"), nil, context, scope: scope).subject == "echo one")
    let changed = cache.card(entity("echo two", "two"), nil, context, scope: scope)
    #expect(changed.subject == "echo two" && changed.output == "two")
    let composed = "é" + "e\u{301}", decomposed = "e\u{301}" + "é"
    #expect(composed == decomposed && composed.utf8.count == decomposed.utf8.count)
    message.text = "Bash\n{\"command\":\"" + composed + "\"}"
    _ = cache.card(message, nil, context, scope: scope)
    message.text = "Bash\n{\"command\":\"" + decomposed + "\"}"
    let exact = try #require(cache.card(message, nil, context, scope: scope).subject)
    #expect(exact.utf8.elementsEqual(decomposed.utf8))
}

@MainActor @Test func transcriptCardCacheSeparatesOriginalThreadRunBirthProjectAndRemoteHostScopes() {
    let project = WorkspaceProject(path: "/private/café"), thread = CodingThread(project: project), run = UUID(), cache = TranscriptCardCache()
    let context = TranscriptToolContext(provider: .codex, workspacePath: thread.workspacePath)
    let message = ChatMessage(id: "shared-provider-id", role: .tool, text: "$ echo value\nvalue")
    let original = TranscriptCardScope(thread: thread, runID: run)
    let canonicalPath = thread.workspacePath.precomposedStringWithCanonicalMapping
    let otherPath = thread.workspacePath.utf8.elementsEqual(canonicalPath.utf8)
        ? thread.workspacePath.decomposedStringWithCanonicalMapping : canonicalPath
    #expect(!otherPath.utf8.elementsEqual(thread.workspacePath.utf8))
    let scopes = [original,
        .init(threadID: UUID(), createdAt: thread.createdAt, projectID: thread.projectID, workspacePath: thread.workspacePath, runID: run),
        .init(threadID: thread.id, createdAt: thread.createdAt.addingTimeInterval(1), projectID: thread.projectID, workspacePath: thread.workspacePath, runID: run),
        .init(threadID: thread.id, createdAt: thread.createdAt, projectID: UUID(), workspacePath: thread.workspacePath, runID: run),
        .init(threadID: thread.id, createdAt: thread.createdAt, projectID: thread.projectID, workspacePath: thread.workspacePath, runID: UUID()),
        .init(threadID: thread.id, createdAt: thread.createdAt, projectID: thread.projectID, workspacePath: otherPath, runID: run),
        .init(threadID: thread.id, createdAt: thread.createdAt, projectID: thread.projectID, workspacePath: thread.workspacePath, runID: run, environmentID: UUID()),
        .init(threadID: thread.id, createdAt: thread.createdAt, projectID: thread.projectID, workspacePath: thread.workspacePath, runID: run, hostID: UUID())]
    for (index, scope) in scopes.enumerated() {
        #expect(cache.card(message, nil, context, scope: scope).subject == "echo value")
        #expect(cache.count == index + 1)
    }
    _ = cache.card(message, nil, context, scope: original)
    #expect(cache.count == scopes.count)
    #expect(cache.retainedBytes > 0 && cache.retainedBytes <= TranscriptCardCache.maximumBytes)
}

@MainActor @Test func transcriptCardCacheEvictsBoundedlyAndLargeOutputViewportRetainsExactReadOnlyText() throws {
    _ = NSApplication.shared
    let project = WorkspaceProject(path: "/private/transcript-capacity"), thread = CodingThread(project: project)
    let scope = TranscriptCardScope(thread: thread), cache = TranscriptCardCache(), context = TranscriptToolContext(provider: .codex)
    for index in 0...TranscriptCardCache.maximumEntries {
        _ = cache.card(.init(id: String(index), role: .tool, text: "$ true"), nil, context, scope: scope)
        #expect(cache.count <= TranscriptCardCache.maximumEntries && cache.retainedBytes <= TranscriptCardCache.maximumBytes)
    }
    let output = String(repeating: "Recorded e\u{301} 🌍\n", count: 5_000) + "exact final line"
    let scroll = TranscriptPlainTextViewport.makeScrollView(text: output)
    let text = try #require(scroll.documentView as? NSTextView)
    #expect(text.string.utf8.elementsEqual(output.utf8))
    #expect(!text.isEditable && text.isSelectable && text.layoutManager?.allowsNonContiguousLayout == true)
    #expect(scroll.hasHorizontalScroller && scroll.hasVerticalScroller)
}
