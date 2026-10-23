import Foundation
import Testing
@testable import CoincideCore

private struct LayoutFixture {
    var thread: CodingThread
    let start = Date(timeIntervalSince1970: 1_790_000_000)
    init() {
        thread = CodingThread(project: WorkspaceProject(path: "/tmp/coincide-layout"), model: "m")
        thread.provider = .claude; thread.workspacePath = "/tmp/coincide-layout"
    }
    @discardableResult mutating func run(_ status: ThreadRunStatus, opening: String?, start offset: TimeInterval, seconds: TimeInterval?) -> UUID {
        let id = UUID()
        let active = ActiveRun(id: id, configuration: .init(thread: thread), startedAt: start + offset)
        var record = ThreadRunRecord(run: active, origin: opening == nil ? .agent : .user, userMessageID: opening)
        record.status = status; record.messageAttributionVersion = 1
        if status.isTerminal { record.endedAt = start + offset + (seconds ?? 0); record.endReason = .providerCompleted }
        else { thread.activeRun = active }
        thread.runHistory = (thread.runHistory ?? []) + [record]
        return id
    }
    mutating func add(_ id: String, _ role: MessageRole, _ text: String, run: UUID?, at offset: TimeInterval) {
        var message = ChatMessage(id: id, role: role, text: text)
        message.createdAt = start + offset
        message.runReference = run.map { .init(threadID: thread.id, runID: $0) }
        thread.messages.append(message)
    }
}

private func bash(_ command: String) -> String { "Bash\n" + JSONValue.object(["command": .string(command)]).pretty }
private func kinds(_ rows: [TranscriptRow]) -> [String] {
    rows.map { row in
        switch row {
        case .message(let message, _): "message:\(message.id)"
        case .entry(let entry): "entry:\(entry.id)"
        case .group(let group): "group:\(group.entries.map(\.id).joined(separator: ","))"
        case .plan(let entry): "plan:\(entry.id)"
        case .fold(let fold): "fold:\(fold.label)"
        case .changes: "changes"
        }
    }
}

@Test func completedRunFoldsIntermediateWorkUnderWorkedForAndKeepsTheFinalResponseAndChanges() throws {
    var f = LayoutFixture()
    let run = f.run(.completed, opening: "u1", start: 0, seconds: 133)
    f.add("u1", .user, "Fix it", run: run, at: 0)
    f.add("r1", .reasoning, "**Looking**", run: run, at: 2)
    f.add("toolu_1", .tool, bash("swift test"), run: run, at: 3)
    f.add("result-toolu_1", .tool, "1 failure", run: run, at: 9)
    f.add("a1", .assistant, "Let me fix that.", run: run, at: 10)
    f.add("toolu_2", .tool, "Edit\n" + JSONValue.object(["file_path": .string("/tmp/coincide-layout/a.swift"), "old_string": .string("a"), "new_string": .string("b")]).pretty, run: run, at: 11)
    f.add("a2", .assistant, "Fixed.", run: run, at: 130)
    let rows = TranscriptLayout.rows(thread: f.thread)
    #expect(kinds(rows) == ["message:u1", "fold:Worked for 2m 13s", "message:a2", "changes"])
    guard case .fold(let fold) = rows[1], case .message(_, let user) = rows[0], case .message(_, let final) = rows[2],
          case .changes(let changes) = rows[3] else { Issue.record("Unexpected rows"); return }
    #expect(fold.hiddenCount == 4 && !fold.expanded && fold.runID == run)
    #expect(user.opensRun && user.runID == run && final.terminalResponse && !final.streaming)
    #expect(changes.checkpointRevision == nil && changes.cardChanges.map(\.path) == ["/tmp/coincide-layout/a.swift"])

    let expanded = TranscriptLayout.rows(thread: f.thread, options: .init(expandedFolds: [fold.id]))
    #expect(kinds(expanded) == ["message:u1", "fold:Worked for 2m 13s", "group:r1,toolu_1", "message:a1", "entry:toolu_2", "message:a2", "changes"])
    guard case .group(let group) = expanded[2] else { Issue.record("Expected a work group"); return }
    #expect(group.entries[1].result?.id == "result-toolu_1" && group.entries[1].card?.status == .completed)
    #expect(group.summary == "Ran 1 command" && !group.expanded && !group.live)
    let unfolded = TranscriptLayout.rows(thread: f.thread, options: .init(foldCompletedRuns: false))
    #expect(kinds(unfolded) == kinds(expanded).filter { !$0.hasPrefix("fold:") })
}

@Test func activeRunsStayExpandedWithLiveTrailingRowsAndUnattributedRowsNeverFold() {
    var f = LayoutFixture()
    f.add("legacy-user", .user, "Old", run: nil, at: 0)
    f.add("legacy-tool", .tool, bash("ls"), run: nil, at: 1)
    f.add("legacy-answer", .assistant, "Done", run: nil, at: 2)
    let run = f.run(.running, opening: "u1", start: 10, seconds: nil)
    f.add("u1", .user, "Go", run: run, at: 10)
    f.add("toolu_a", .tool, bash("make"), run: run, at: 11)
    f.add("result-toolu_a", .tool, "ok", run: run, at: 12)
    f.add("toolu_b", .tool, "Read\n" + JSONValue.object(["file_path": .string("/x")]).pretty, run: run, at: 13)
    let rows = TranscriptLayout.rows(thread: f.thread)
    #expect(kinds(rows) == ["message:legacy-user", "entry:legacy-tool", "message:legacy-answer", "message:u1", "group:toolu_a,toolu_b"])
    guard case .group(let group) = rows[4] else { Issue.record("Expected a live group"); return }
    #expect(group.live && group.entries[1].trailing && group.entries[1].card?.status == .running && group.entries[0].card?.status == .completed)
    f.add("a1", .assistant, "Streaming", run: run, at: 14)
    guard case .message(_, let meta) = TranscriptLayout.rows(thread: f.thread).last else { Issue.record("Expected the reply"); return }
    #expect(meta.streaming && !meta.terminalResponse)
}

@Test func steeringSplitsFoldsAndFailedTrailingWorkPlansAndNoticesStayVisible() {
    var f = LayoutFixture()
    let run = f.run(.completed, opening: "u1", start: 0, seconds: 300)
    f.add("u1", .user, "Start", run: run, at: 0)
    f.add("toolu_1", .tool, bash("one"), run: run, at: 5)
    f.add("a1", .assistant, "Working", run: run, at: 10)
    f.add("steer", .user, "Also do this", run: run, at: 60)
    f.thread.messages[f.thread.messages.count - 1].promptSteeringID = UUID()
    f.add("toolu_2", .tool, bash("two"), run: run, at: 70)
    f.add("plan", .tool, "ExitPlanMode\n" + JSONValue.object(["plan": .string("# Plan")]).pretty, run: run, at: 80)
    f.add("notice", .system, "The agent stopped: max tokens.", run: run, at: 85)
    f.add("a2", .assistant, "Done", run: run, at: 90)
    f.add("toolu_3", .tool, bash("cleanup"), run: run, at: 95)
    f.add("result-toolu_3", .tool, "<tool_use_error>denied</tool_use_error>", run: run, at: 96)
    let rows = TranscriptLayout.rows(thread: f.thread)
    #expect(kinds(rows) == ["message:u1", "fold:Worked for 5m", "message:steer", "fold:Continued for 4m", "plan:plan", "message:notice", "message:a2", "entry:toolu_3", "changes"].filter { $0 != "changes" })
}

@Test func interruptedRunsAndRemovedMessagesAreNotFolded() {
    var f = LayoutFixture()
    let stopped = f.run(.interrupted, opening: "u1", start: 0, seconds: 20)
    f.add("u1", .user, "Go", run: stopped, at: 0)
    f.add("toolu_1", .tool, bash("sleep 100"), run: stopped, at: 1)
    f.add("a1", .assistant, "Partial", run: stopped, at: 2)
    let removed = f.run(.completed, opening: "u2", start: 30, seconds: 5)
    f.add("u2", .user, "Removed", run: removed, at: 30)
    f.add("a2", .assistant, "Gone", run: removed, at: 31)
    let operation = UUID()
    for index in f.thread.messages.indices.suffix(2) { f.thread.messages[index].removedByHistoryOperationID = operation }
    f.thread.runHistory![1].removedByHistoryOperationID = operation
    #expect(kinds(TranscriptLayout.rows(thread: f.thread)) == ["message:u1", "entry:toolu_1", "message:a1"])
}

@Test func durationsAndElapsedLabelsMatchT3Formatting() {
    #expect(TranscriptDuration.format(0.0004) == "1ms")
    #expect(TranscriptDuration.format(0.5) == "500ms")
    #expect(TranscriptDuration.format(1.23) == "1.2s")
    #expect(TranscriptDuration.format(9.96) == "10s")
    #expect(TranscriptDuration.format(59.5) == "1m")
    #expect(TranscriptDuration.format(133) == "2m 13s")
    #expect(TranscriptDuration.format(3_600) == "1h")
    #expect(TranscriptDuration.format(3_725) == "1h 2m 5s")
    #expect(TranscriptDuration.format(-1) == "0ms")
    #expect(TranscriptDuration.elapsed(5.9) == "5s")
    #expect(TranscriptDuration.elapsed(65) == "1m 05s")
    #expect(TranscriptDuration.elapsed(3_725) == "1h 02m")
}

@Test func userMessagesCollapseAtT3ThresholdsCountingLinkLabels() {
    #expect(!TranscriptUserMessageCollapse.shouldCollapse(String(repeating: "a", count: 600)))
    #expect(TranscriptUserMessageCollapse.shouldCollapse(String(repeating: "a", count: 601)))
    #expect(!TranscriptUserMessageCollapse.shouldCollapse(Array(repeating: "line", count: 8).joined(separator: "\n")))
    #expect(TranscriptUserMessageCollapse.shouldCollapse(Array(repeating: "line", count: 9).joined(separator: "\n")))
    #expect(!TranscriptUserMessageCollapse.shouldCollapse(String(repeating: " \n", count: 50)))
    let link = "[a.swift](" + String(repeating: "x", count: 700) + ")"
    #expect(!TranscriptUserMessageCollapse.shouldCollapse(link))
    #expect(TranscriptUserMessageCollapse.visibleText("See [file](Sources/a.swift) and ![img](<a b.png>)") == "See file and img")
}

@Test func planTextHelpersMatchT3TitlesPreviewsFilenamesAndPrompts() {
    let plan = "# Ship the Login Flow!\n\n## Summary\n\n" + (1...14).map { "\($0). Step \($0)" }.joined(separator: "\n") + "\n"
    #expect(TranscriptPlanText.title(plan) == "Ship the Login Flow!")
    #expect(TranscriptPlanText.displayed(plan).hasPrefix("1. Step 1"))
    let preview = TranscriptPlanText.collapsedPreview(plan)
    #expect(preview.hasSuffix("10. Step 10\n\n...") && !preview.contains("Step 11"))
    #expect(TranscriptPlanText.filename(plan) == "ship-the-login-flow.md")
    #expect(TranscriptPlanText.filename("No heading") == "plan.md")
    #expect(TranscriptPlanText.exportContents("x\n\n") == "x\n")
    #expect(TranscriptPlanText.implementationPrompt("  # P\n- a \n") == "PLEASE IMPLEMENT THIS PLAN:\n# P\n- a")
    #expect(TranscriptPlanText.canCollapse(plan) == false && TranscriptPlanText.canCollapse(String(repeating: "x\n", count: 21)))
}

@Test func reasoningPreviewUsesTheNewestHeadingOrLineAndStaysBounded() {
    #expect(TranscriptReasoningPreview.line("**Reading files**\n\nI will open it.\n\n**Running tests**\n\nNow `swift test`.") == "Running tests")
    #expect(TranscriptReasoningPreview.line("First thought.\n- Then a **bold** step") == "Then a bold step")
    #expect(TranscriptReasoningPreview.line("## Heading only") == "Heading only")
    #expect(TranscriptReasoningPreview.line(String(repeating: "word ", count: 200)).count == 160)
    #expect(TranscriptReasoningPreview.line("") == "")
}

@Test func timestampsAreDayAwareWithFixedLocaleAndHourCycle() {
    let utc = TimeZone(identifier: "UTC")!, locale = Locale(identifier: "en_US")
    var calendar = Calendar(identifier: .gregorian); calendar.timeZone = utc
    let now = calendar.date(from: DateComponents(year: 2026, month: 6, day: 4, hour: 18))!
    let today = calendar.date(from: DateComponents(year: 2026, month: 6, day: 4, hour: 15, minute: 4))!
    func clean(_ value: String) -> String { value.replacingOccurrences(of: "\u{202F}", with: " ") }
    let twelve = TranscriptTimestamp(format: .twelveHour, locale: locale, timeZone: utc)
    let twentyFour = TranscriptTimestamp(format: .twentyFourHour, locale: locale, timeZone: utc)
    #expect(clean(twelve.dayAware(today, now: now)) == "3:04 PM")
    #expect(twentyFour.dayAware(today, now: now) == "15:04")
    #expect(clean(twelve.dayAware(today.addingTimeInterval(-86_400), now: now)) == "yesterday at 3:04 PM")
    #expect(clean(twelve.dayAware(today.addingTimeInterval(-3 * 86_400), now: now)) == "6/1 3:04 PM")
    #expect(clean(twentyFour.dayAware(calendar.date(byAdding: .year, value: -1, to: today)!, now: now)) == "6/4/2025 15:04")
    #expect(clean(twelve.tooltip(today)) == "3:04 PM, 4th June 2026")
    #expect(clean(twelve.tooltip(calendar.date(from: DateComponents(year: 2026, month: 1, day: 22, hour: 9))!)) == "9:00 AM, 22nd January 2026")
    #expect(clean(twelve.tooltip(calendar.date(from: DateComponents(year: 2026, month: 3, day: 11, hour: 9))!)).hasSuffix("11th March 2026"))
}
