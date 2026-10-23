import AppKit
import SwiftUI
import Testing
@testable import Coincide
@testable import CoincideCore

@MainActor private func size<V: View>(_ view: V, width: CGFloat, scheme: ColorScheme = .light) -> CGSize {
    NSHostingController(rootView: view.environment(\.colorScheme, scheme)).sizeThatFits(in: .init(width: width, height: 4_000))
}

private func sampleCards() -> [TranscriptToolCard] {
    var command = TranscriptToolCard(kind: .command, name: "Bash", title: "swift test --parallel", subject: "swift test --parallel", status: .completed)
    command.output = (1...600).map { "Test case \($0) passed" }.joined(separator: "\n"); command.exitCode = 1
    var edit = TranscriptToolCard(kind: .edit, name: "Edit", title: "Edited Sources/App.swift", status: .completed)
    edit.changes = [TranscriptLineDiff.change(path: "/w/Sources/App.swift", old: (1...30).map { "line \($0)" }.joined(separator: "\n"),
                                              new: (1...30).map { $0 == 15 ? "changed \($0)" : "line \($0)" }.joined(separator: "\n"), numbered: true)]
    var todo = TranscriptToolCard(kind: .todo, name: "TodoWrite", title: "Updated todos · 1 of 2 done", status: .completed)
    todo.todos = [.init(text: "Write the parser", status: "completed"), .init(text: "Render a very long task description that wraps in narrow columns", status: "in_progress")]
    var failed = TranscriptToolCard(kind: .read, name: "Read", title: "Read missing.swift", status: .failed); failed.output = "File does not exist."
    var mcp = TranscriptToolCard(kind: .mcp, name: "docs.search", title: "Called docs.search", status: .running); mcp.input = "{\n  \"q\" : \"x\"\n}"
    return [command, edit, todo, failed, mcp]
}

@MainActor @Test func toolCardsReasoningFoldsAndGroupsFitNarrowAndWideColumnsInBothAppearances() {
    _ = NSApplication.shared
    for scheme in [ColorScheme.light, .dark] {
        for width in [CGFloat(320), 720] {
            for card in sampleCards() {
                let collapsed = size(ToolCardView(card: card, workspacePath: "/w", expanded: .constant(false)), width: width, scheme: scheme)
                let expanded = size(ToolCardView(card: card, workspacePath: "/w", expanded: .constant(true)), width: width, scheme: scheme)
                #expect(collapsed.width <= width + 1 && collapsed.height > 10 && collapsed.height < 60, "\(card.title)")
                #expect(expanded.width <= width + 1 && expanded.height > collapsed.height, "\(card.title)")
                #expect(expanded.height < 1_200, "Output must stay bounded: \(card.title)")
            }
            let thinking = size(ReasoningRowView(text: "**Reading files**\n\nSome *markdown* body.", live: true, duration: nil, expanded: .constant(false)), width: width, scheme: scheme)
            let thought = size(ReasoningRowView(text: "**Reading files**\n\nSome *markdown* body.", live: false, duration: 4, expanded: .constant(true)), width: width, scheme: scheme)
            #expect(thinking.height > 0 && thought.height > thinking.height && thought.width <= width + 1)
            let fold = TranscriptTurnFold(id: "fold", runID: UUID(), label: "Worked for 2m 13s", hiddenCount: 6, expanded: false)
            #expect(size(TurnFoldRow(fold: fold, toggle: {}), width: width, scheme: scheme).height < 40)
            let entries = sampleCards().prefix(3).enumerated().map { index, card in
                TranscriptEntry(message: .init(id: "m\(index)", role: .tool, text: ""), result: nil, card: card, runID: nil, runActive: false, trailing: false)
            }
            for expandedGroup in [false, true] {
                let group = TranscriptWorkGroup(id: "group-m0", entries: Array(entries), summary: "Ran 1 command, changed 1 file, and performed 1 other action",
                                                hasFailure: true, expanded: expandedGroup)
                let measured = size(TranscriptWorkGroupView(group: group, toggle: {}) { ToolCardView(card: $0.card!, expanded: .constant(false)) }, width: width, scheme: scheme)
                #expect(measured.width <= width + 1 && (expandedGroup ? measured.height > 60 : measured.height < 40))
            }
            let changes = TranscriptTurnChanges(runID: UUID(), checkpointRevision: nil, cardChanges: sampleCards()[1].changes)
            #expect(size(TurnChangesFooter(changes: changes, workspacePath: "/w"), width: width, scheme: scheme).height < 60)
        }
    }
}

@MainActor @Test func longUserMessagesCollapseAndExpandWhileShortOnesStayWhole() {
    _ = NSApplication.shared
    let long = (1...40).map { "Pasted log line \($0) with [file](Sources/a.swift)" }.joined(separator: "\n")
    let collapsed = size(UserMessageBody(text: long, expanded: .constant(false)), width: 480)
    let expanded = size(UserMessageBody(text: long, expanded: .constant(true)), width: 480)
    #expect(collapsed.height <= UserMessageBody.collapsedHeight + 40 && expanded.height > collapsed.height + 200)
    let short = "Fix the **build**"
    #expect(size(UserMessageBody(text: short, expanded: .constant(false)), width: 480) == size(UserMessageBody(text: short, expanded: .constant(true)), width: 480))
}

@MainActor @Test func planCardsShowACollapsedPreviewUntilExpanded() {
    _ = NSApplication.shared
    let plan = "# Migrate storage\n\n" + (1...30).map { "\($0). Step \($0) with some detail" }.joined(separator: "\n")
    for scheme in [ColorScheme.light, .dark] {
        let collapsed = size(PlanCardView(plan: plan, workspacePath: "/w", expanded: .constant(false)), width: 600, scheme: scheme)
        let expanded = size(PlanCardView(plan: plan, workspacePath: "/w", expanded: .constant(true)), width: 600, scheme: scheme)
        #expect(collapsed.width <= 601 && expanded.height > collapsed.height + 150)
    }
    let short = "# Small\n- one"
    #expect(size(PlanCardView(plan: short, expanded: .constant(false)), width: 600) == size(PlanCardView(plan: short, expanded: .constant(true)), width: 600))
}

@MainActor @Test func messageActionsBarHidesUnavailableActionsAndFitsNarrowColumns() {
    _ = NSApplication.shared
    let message = ChatMessage(id: "m", role: .user, text: "Hello")
    var actions = TranscriptMessageActions(timestamps: .init(format: .twentyFourHour, locale: Locale(identifier: "en_US"), timeZone: TimeZone(identifier: "UTC")!))
    let bare = size(MessageActionsBar(message: message, role: .user, actions: actions, visible: true), width: 320)
    actions.editFromHere = {}; actions.editUnavailableReason = "Finish the current turn first."
    let withEdit = size(MessageActionsBar(message: message, role: .user, actions: actions, steered: true, visible: true), width: 320)
    #expect(bare.width <= 321 && withEdit.width > bare.width && withEdit.height < 30)
    let settings = size(VStack(alignment: .leading) { TranscriptSettings() }, width: 480)
    #expect(settings.height > 0)
}

@MainActor @Test(.timeLimit(.minutes(1)))
func transcriptActionsRouteToReviewedHistoryAndImplementPlanOnlyFillsTheDraft() async throws {
    _ = NSApplication.shared
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("coincide-transcript-" + UUID().uuidString)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let project = WorkspaceProject(path: root.path)
    var thread = CodingThread(project: project, model: "gpt")
    let start = Date(timeIntervalSince1970: 1_790_000_000), runID = UUID()
    var record = ThreadRunRecord(run: ActiveRun(id: runID, configuration: .init(thread: thread), startedAt: start), origin: .user, userMessageID: "u1")
    record.status = .completed; record.endedAt = start + 30; record.endReason = .providerCompleted; record.messageAttributionVersion = 1
    var user = ChatMessage(id: "u1", role: .user, text: "Do it"), answer = ChatMessage(id: "a1", role: .assistant, text: "Done")
    user.runReference = .init(threadID: thread.id, runID: runID); answer.runReference = user.runReference
    user.createdAt = start; answer.createdAt = start + 29
    let legacy = ChatMessage(id: "legacy", role: .assistant, text: "Earlier")
    thread.messages = [legacy, user, answer]; thread.runHistory = [record]
    var snapshot = WorkspaceSnapshot(); snapshot.projects = [project]; snapshot.threads = [thread]
    let database = root.appendingPathComponent("workspace.sqlite")
    _ = try await WorkspaceDatabase(url: database).commit(snapshot, event: "transcript-fixture", commandID: UUID())
    let store = WorkspaceStore(databaseURL: database); await store.load()
    let loaded = try #require(store.thread(thread.id))
    var presented: [TranscriptSheetRequest] = []
    let view = TranscriptRowsView(store: store, thread: loaded, state: TranscriptViewState(), present: { presented.append($0) })
    let rows = TranscriptLayout.rows(thread: loaded)
    guard case .message(_, let userMeta)? = rows.first(where: { $0.id == "u1" }), case .message(_, let answerMeta)? = rows.first(where: { $0.id == "a1" }),
          case .message(_, let legacyMeta)? = rows.first(where: { $0.id == "legacy" }) else { Issue.record("Missing rows"); await store.shutdown(); return }
    let edit = view.actions(user, userMeta), fork = view.actions(answer, answerMeta), none = view.actions(legacy, legacyMeta)
    #expect(edit.editFromHere != nil && edit.forkFromHere == nil && fork.forkFromHere != nil && fork.editFromHere == nil)
    #expect(none.editFromHere == nil && none.forkFromHere == nil && none.viewChanges == nil)
    #expect(edit.editUnavailableReason == store.conversationHistoryUnavailableReason(threadID: thread.id, runID: runID, kind: .rewindBeforeRun))
    #expect(fork.forkUnavailableReason == store.conversationHistoryUnavailableReason(threadID: thread.id, runID: runID, kind: .forkAfterRun))
    #expect(fork.viewChanges == nil, "No ready checkpoints were saved for this run.")
    edit.editFromHere?(); fork.forkFromHere?()
    #expect(presented == [.history(runID, .rewindBeforeRun), .history(runID, .forkAfterRun)])
    view.implementPlan("# Plan\n- step\n")
    #expect(store.thread(thread.id)?.draft == "PLEASE IMPLEMENT THIS PLAN:\n# Plan\n- step")
    #expect(store.thread(thread.id)?.messages == loaded.messages && store.thread(thread.id)?.queuedTurns.isEmpty == true)
    let hosted = NSHostingController(rootView: ScrollView { LazyVStack(alignment: .leading, spacing: 28) { view } }.frame(width: 600, height: 400))
    hosted.view.layoutSubtreeIfNeeded()
    #expect(hosted.sizeThatFits(in: .init(width: 600, height: 400)).height > 0)
    await store.shutdown()
}

/// `COINCIDE_RENDER_TRANSCRIPT=1` writes light and dark previews of the cards for review.
@MainActor @Test func transcriptCardPreviewsRenderOnRequest() async throws {
    guard ProcessInfo.processInfo.environment["COINCIDE_RENDER_TRANSCRIPT"] == "1" else { return }
    _ = NSApplication.shared
    let cards = sampleCards()
    let plan = "# Migrate storage\n\n" + (1...14).map { "\($0). Step \($0) with **detail**" }.joined(separator: "\n")
    let fold = TranscriptTurnFold(id: "fold", runID: UUID(), label: "Worked for 2m 13s", hiddenCount: 6, expanded: false)
    let entries = cards.prefix(3).enumerated().map { TranscriptEntry(message: .init(id: "m\($0.offset)", role: .tool, text: ""), result: nil, card: $0.element, runID: nil, runActive: false, trailing: false) }
    let content = VStack(alignment: .leading, spacing: 22) {
        UserMessageBody(text: (1...12).map { "Line \($0) of a pasted **log** with [a.swift](Sources/a.swift)" }.joined(separator: "\n"), expanded: .constant(false))
            .padding(.horizontal, 18).padding(.vertical, 12).background(Color.primary.opacity(0.065), in: RoundedRectangle(cornerRadius: 22))
        MessageActionsBar(message: .init(id: "u", role: .user, text: "x"), role: .user, actions: .init(timestamps: .init(), editFromHere: {}), steered: true, visible: true)
        TurnFoldRow(fold: fold, toggle: {})
        ForEach(Array(cards.enumerated()), id: \.offset) { index, card in ToolCardView(card: card, workspacePath: "/w", expanded: .constant(index < 2)) }
        TranscriptWorkGroupView(group: .init(id: "g", entries: Array(entries), summary: "Ran 1 command, changed 1 file, and performed 1 other action", hasFailure: false, expanded: false), toggle: {}) { ToolCardView(card: $0.card!, expanded: .constant(false)) }
        ReasoningRowView(text: "**Reading files**\n\nChecking the parser.", live: true, duration: nil, expanded: .constant(false))
        ReasoningRowView(text: "**Reading files**\n\nChecking the parser.", live: false, duration: 4, expanded: .constant(false))
        TurnChangesFooter(changes: .init(runID: UUID(), checkpointRevision: nil, cardChanges: cards[1].changes), workspacePath: "/w")
        PlanCardView(plan: plan, workspacePath: "/w", expanded: .constant(false))
    }.padding(24).frame(width: 720)
    for scheme in [ColorScheme.light, .dark] {
        let appearance = try #require(NSAppearance(named: scheme == .light ? .aqua : .darkAqua))
        let hosting = NSHostingView(rootView: content.environment(\.colorScheme, scheme).background(Color(nsColor: .windowBackgroundColor)))
        let height = hosting.fittingSize.height
        let window = NSWindow(contentRect: .init(x: -10_000, y: -10_000, width: 720, height: height), styleMask: .borderless, backing: .buffered, defer: false)
        window.appearance = appearance; hosting.appearance = appearance; window.isReleasedWhenClosed = false; window.contentView = hosting
        defer { window.close() }
        hosting.layoutSubtreeIfNeeded(); try await Task.sleep(for: .milliseconds(300)); hosting.layoutSubtreeIfNeeded()
        let bitmap = try #require(hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds))
        appearance.performAsCurrentDrawingAppearance { hosting.cacheDisplay(in: hosting.bounds, to: bitmap) }
        let path = FileManager.default.temporaryDirectory.appendingPathComponent("coincide-transcript-\(scheme == .light ? "light" : "dark").png")
        try #require(bitmap.representation(using: .png, properties: [:])).write(to: path)
        print("Transcript preview: \(path.path)")
    }
}
