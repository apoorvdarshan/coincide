import Foundation
import Testing
@testable import CoincideCore

private func tool(_ id: String, _ text: String) -> ChatMessage { .init(id: id, role: .tool, text: text) }
private func entity(_ fields: [String: JSONValue], type: String = "tool_call", id: String = "call-1") -> ChatMessage {
    var message = ChatMessage(id: "entity-\(id)", role: .tool, text: "")
    message.providerEntity = .init(key: .init(sessionID: "s", type: type, id: id), fields: .object(fields))
    message.text = message.providerEntity!.text
    return message
}
private func json(_ object: [String: JSONValue]) -> String { JSONValue.object(object).pretty }

@Test func codexCommandAndFileChangeTextBecomeCommandAndEditCards() {
    let command = TranscriptToolPresentation.card(for: tool("cmd", "$ npm test -- --watch=false\nPASS 3 suites\n"))
    #expect(command.kind == .command && command.subject == "npm test -- --watch=false" && command.title == "npm test -- --watch=false")
    #expect(command.output == "PASS 3 suites\n" && command.status == .unknown && command.exitCode == nil)
    #expect(TranscriptToolPresentation.card(for: tool("cmd", "$ swift build\n"), context: .init(runActive: true, trailing: true)).status == .running)
    #expect(TranscriptToolPresentation.card(for: tool("cmd", "$ ls\n")).output == nil)
    let changes = JSONValue.array([.object(["path": .string("/w/Sources/a.swift"), "kind": .object(["type": .string("update")]),
                                            "diff": .string("@@ -1 +1,2 @@\n-a\n+b\n+c\n")])])
    let edit = TranscriptToolPresentation.card(for: tool("fc", "File changes\n" + changes.pretty), context: .init(workspacePath: "/w"))
    #expect(edit.kind == .edit && edit.title == "Edited Sources/a.swift" && edit.stat == .init(files: 1, additions: 2, deletions: 1))
    #expect(edit.status == .completed && edit.paths == ["/w/Sources/a.swift"])
}

@Test func claudeToolUseCardsPairResultsAndClassifyEveryBuiltInTool() throws {
    let context = TranscriptToolContext(provider: .claude, workspacePath: "/repo")
    let bash = TranscriptToolPresentation.card(for: tool("toolu_1", "Bash\n" + json(["command": .string("git status"), "description": .string("Show status")])),
                                               result: tool("result-toolu_1", "On branch main"), context: context)
    #expect(bash.kind == .command && bash.subject == "git status" && bash.detail == "Show status" && bash.output == "On branch main" && bash.status == .completed)
    let failed = TranscriptToolPresentation.card(for: tool("toolu_2", "Read\n" + json(["file_path": .string("/repo/missing.swift")])),
                                                 result: tool("result-toolu_2", "<tool_use_error>File does not exist.</tool_use_error>"), context: context)
    #expect(failed.kind == .read && failed.status == .failed && failed.isFailure && failed.output == "File does not exist." && failed.title == "Read missing.swift")
    let edit = TranscriptToolPresentation.card(for: tool("toolu_3", "Edit\n" + json(["file_path": .string("/repo/a.swift"), "old_string": .string("let a = 1\nlet b = 2"), "new_string": .string("let a = 10\nlet b = 2")])), context: context)
    #expect(edit.kind == .edit && edit.title == "Edited a.swift" && edit.stat == .init(files: 1, additions: 1, deletions: 1))
    #expect(edit.changes[0].hunks[0].lines.allSatisfy { $0.oldLine == nil && $0.newLine == nil })
    let multi = TranscriptToolPresentation.card(for: tool("t4", "MultiEdit\n" + json(["file_path": .string("/repo/b.swift"), "edits": .array([
        .object(["old_string": .string("x"), "new_string": .string("y")]), .object(["old_string": .string("p\nq"), "new_string": .string("p")])])])), context: context)
    #expect(multi.changes.count == 1 && multi.changes[0].hunks.count == 2 && multi.stat == .init(files: 1, additions: 1, deletions: 2))
    let write = TranscriptToolPresentation.card(for: tool("t5", "Write\n" + json(["file_path": .string("/repo/new.md"), "content": .string("# A\nB\n")])), context: context)
    #expect(write.title == "Wrote new.md" && write.stat?.additions == 2)
    let cases: [(String, [String: JSONValue], TranscriptToolKind, String)] = [
        ("Grep", ["pattern": .string("TODO"), "path": .string("/repo/src")], .search, "Searched for TODO"),
        ("Glob", ["pattern": .string("**/*.swift")], .search, "Searched for **/*.swift"),
        ("LS", ["path": .string("/repo/Sources")], .search, "Listed Sources"),
        ("WebFetch", ["url": .string("https://example.com"), "prompt": .string("summarize")], .fetch, "Fetched https://example.com"),
        ("WebSearch", ["query": .string("swift testing")], .webSearch, "Searched the web for swift testing"),
        ("Task", ["description": .string("Explore auth"), "prompt": .string("long"), "subagent_type": .string("general")], .task, "Agent task · Explore auth"),
        ("mcp__github__create_issue", ["title": .string("Bug")], .mcp, "Called github · create_issue"),
        ("SomethingNew", ["cmd": .string("x")], .command, "x"),
    ]
    for (name, input, kind, title) in cases {
        let card = TranscriptToolPresentation.card(for: tool("t-\(name)", name + "\n" + json(input)), context: context)
        #expect(card.kind == kind && card.title == title, "\(name)")
    }
    let todo = TranscriptToolPresentation.card(for: tool("t6", "TodoWrite\n" + json(["todos": .array([
        .object(["content": .string("Write tests"), "status": .string("completed"), "activeForm": .string("Writing")]),
        .object(["content": .string("Ship"), "status": .string("in_progress")])])])), context: context)
    #expect(todo.kind == .todo && todo.todos.map(\.isCompleted) == [true, false] && todo.todos[1].isActive && todo.title == "Updated todos · 1 of 2 done")
    let plan = TranscriptToolPresentation.card(for: tool("t7", "ExitPlanMode\n" + json(["plan": .string("# Plan\n1. Do it")])), context: context)
    #expect(plan.kind == .plan && plan.plan == "# Plan\n1. Do it" && plan.status == .completed)
    let streaming = tool("t8", "Bash")
    #expect(TranscriptToolPresentation.card(for: streaming, context: .init(provider: .claude, runActive: true)).status == .running)
    #expect(TranscriptToolPresentation.card(for: streaming, context: .init(provider: .claude, runActive: false)).status == .unknown)
}

@Test func providerEntitiesBecomeCardsWithStatusDiffsLocationsAndHonestUnfinishedState() {
    let execute = entity(["title": .string("Run tests"), "kind": .string("execute"), "status": .string("completed"),
                          "rawInput": .object(["command": .array([.string("swift"), .string("test")])]),
                          "rawOutput": .object(["exitCode": .number(1), "stdout": .string("1 failure")])])
    let card = TranscriptToolPresentation.card(for: execute)
    #expect(card.kind == .command && card.subject == "swift test" && card.exitCode == 1 && card.isFailure && card.output == "1 failure")
    let diff = entity(["title": .string("Edit main.rs"), "kind": .string("edit"), "status": .string("completed"),
                       "content": .array([.object(["type": .string("diff"), "path": .string("/w/src/main.rs"), "oldText": .string("a\n"), "newText": .string("b\n")])]),
                       "locations": .array([.object(["path": .string("/w/src/main.rs"), "line": .number(1)])])])
    let edit = TranscriptToolPresentation.card(for: diff, context: .init(workspacePath: "/w"))
    #expect(edit.kind == .edit && edit.title == "Edited src/main.rs" && edit.stat == .init(files: 1, additions: 1, deletions: 1) && edit.paths.contains("/w/src/main.rs"))
    let pending = entity(["title": .string("Read file"), "kind": .string("read"), "status": .string("in_progress"),
                          "locations": .array([.object(["path": .string("/w/README.md")])])])
    #expect(TranscriptToolPresentation.card(for: pending, context: .init(runActive: true)).status == .running)
    #expect(TranscriptToolPresentation.card(for: pending, context: .init(runActive: false)).status == .unknown)
    #expect(TranscriptToolPresentation.card(for: pending, context: .init(workspacePath: "/w")).title == "Read README.md")
    let mcp = entity(["title": .string("docs.search"), "kind": .string("other"), "status": .string("failed"),
                      "rawInput": .object(["q": .string("x")]), "rawOutput": .object(["error": .string("denied")])])
    let mcpCard = TranscriptToolPresentation.card(for: mcp, context: .init(provider: .codex))
    #expect(mcpCard.kind == .mcp && mcpCard.title == "Called docs.search" && mcpCard.status == .failed)
    let pi = entity(["title": .string("bash"), "status": .string("completed"),
                     "content": .array([.object(["type": .string("content"), "content": .object(["type": .string("text"), "text": .string("ok")])])])])
    let piCard = TranscriptToolPresentation.card(for: pi, context: .init(provider: .pi))
    #expect(piCard.kind == .command && piCard.title == "Ran command" && piCard.output == "ok")
    let opencode = entity(["title": .string("src/app.ts"), "kind": .string("other"), "status": .string("completed"), "rawInput": .object(["filePath": .string("/w/src/app.ts")])])
    let openCard = TranscriptToolPresentation.card(for: opencode, context: .init(provider: .opencode, workspacePath: "/w"))
    #expect(openCard.kind == .read && openCard.subject == "/w/src/app.ts")
    let unknown = entity(["title": .string("Custom thing"), "status": .string("completed"), "rawInput": .object(["a": .number(1)])])
    let unknownCard = TranscriptToolPresentation.card(for: unknown)
    #expect(unknownCard.kind == .other && unknownCard.title == "Custom thing" && unknownCard.input != nil)
    let antigravity = entity(["title": .string("Running command"), "command": .string("make"), "exitCode": .number(0), "status": .string("completed")])
    #expect(TranscriptToolPresentation.card(for: antigravity).kind == .command)
}

@Test func plansAndTaskListsAreClassifiedForACPGrokAndPlanEntities() {
    let entries = entity(["entries": .array([.object(["content": .string("One"), "status": .string("completed")]),
                                             .object(["content": .string("Two"), "status": .string("pending")])])], type: "plan", id: "plan-1")
    let list = TranscriptToolPresentation.card(for: entries)
    #expect(list.kind == .todo && list.todos.map(\.text) == ["One", "Two"] && list.title == "Updated plan")
    let grok = entity(["content": .string("# Ship it\n- step")], type: "plan", id: "grok-proposed-plan-1")
    #expect(TranscriptToolPresentation.card(for: grok).kind == .plan && TranscriptToolPresentation.card(for: grok).plan == "# Ship it\n- step")
    let acpList = TranscriptToolPresentation.card(for: tool("acp-3-plan", "- [x] Done\n- [ ] Next"), context: .init(provider: .acp))
    #expect(acpList.kind == .todo && acpList.todos.map(\.isCompleted) == [true, false])
    let grokV1 = TranscriptToolPresentation.card(for: tool(UUID().uuidString, "## Plan\nDo the work"), context: .init(provider: .acp))
    #expect(grokV1.kind == .plan && grokV1.plan == "## Plan\nDo the work")
    let orphan = TranscriptToolPresentation.card(for: tool("result-missing", "output"))
    #expect(orphan.kind == .other && orphan.output == "output")
}

@Test func workLogSummariesMatchT3SentencesPluralsAndFailures() {
    func card(_ kind: TranscriptToolKind, path: String? = nil, failed: Bool = false) -> TranscriptToolCard {
        var value = TranscriptToolCard(kind: kind, name: "x", subject: path, status: failed ? .failed : .completed)
        if let path, kind == .edit { value.changes = [.init(path: path, additions: 1)] }
        return value
    }
    #expect(TranscriptToolPresentation.summary(cards: [card(.command), card(.command)]).text == "Ran 2 commands")
    #expect(TranscriptToolPresentation.summary(cards: [card(.read), card(.command), card(.read), card(.read)]).text == "Read 3 files and ran 1 command")
    #expect(TranscriptToolPresentation.summary(cards: [card(.edit, path: "a"), card(.edit, path: "a"), card(.edit, path: "b")]).text == "Changed 2 files")
    let mixed = TranscriptToolPresentation.summary(cards: [card(.read), card(.search), card(.command), card(.edit, path: "a"), card(.other, failed: true)])
    #expect(mixed.text == "Ran 1 command, changed 1 file, and performed 3 other actions" && mixed.failed)
    #expect(TranscriptToolPresentation.summary(cards: [card(.webSearch), card(.webSearch)]).text == "Searched the web 2 times")
    #expect(TranscriptToolPresentation.summary(cards: [card(.search)]).text == "Searched code 1 time")
    #expect(TranscriptToolPresentation.summary(cards: [], reasoningCount: 1).text == "Thought")
    #expect(TranscriptToolPresentation.summary(cards: [], reasoningCount: 3).text == "Thought (×3)")
    #expect(!TranscriptToolPresentation.summary(cards: [card(.other, failed: true), card(.read)]).failed)
}
