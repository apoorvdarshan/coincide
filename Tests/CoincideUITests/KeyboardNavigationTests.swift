import AppKit
import CoincideCore
import Foundation
import Testing
@testable import Coincide

/// An unloaded store with a fixed snapshot: two project groups, a pinned and an
/// archived thread, and manual order so the sidebar order is deterministic.
@MainActor func keyboardFixtureStore() throws -> (store: WorkspaceStore, root: URL, projects: [WorkspaceProject], threads: [String: CodingThread]) {
    _ = NSApplication.shared
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("coincide-keyboard-" + UUID().uuidString)
    var projects: [WorkspaceProject] = []
    for name in ["Alpha", "Beta"] {
        let path = root.appendingPathComponent(name)
        try FileManager.default.createDirectory(at: path, withIntermediateDirectories: true)
        projects.append(WorkspaceProject(path: path.path))
    }
    func thread(_ title: String, _ project: Int, updated: Double, pinned: Bool = false, archived: Bool = false, text: String? = nil) -> CodingThread {
        var value = CodingThread(project: projects[project]); value.title = title
        value.updatedAt = Date(timeIntervalSince1970: updated); value.isPinned = pinned; value.isArchived = archived
        if let text { value.messages = [ChatMessage(role: .user, text: text), ChatMessage(role: .assistant, text: "Answer about \(title)")] }
        return value
    }
    let threads: [String: CodingThread] = [
        "a-pinned": thread("Pinned planning", 0, updated: 10, pinned: true, text: "Remember the café deployment checklist"),
        "a-new": thread("Newest alpha", 0, updated: 300),
        "a-old": thread("Older alpha", 0, updated: 200),
        "a-archived": thread("Archived alpha", 0, updated: 400, archived: true),
        "b-one": thread("Beta work", 1, updated: 250, text: "Investigate flaky tests"),
    ]
    let store = WorkspaceStore(databaseURL: root.appendingPathComponent("workspace.sqlite"))
    store.snapshot.projects = projects
    store.snapshot.threads = Array(threads.values).sorted { $0.title < $1.title }
    store.snapshot.sidebarPreferences = SidebarPreferences(sortMode: .manual)
    store.isLoading = false
    return (store, root, projects, threads)
}

@MainActor @Test func threadTraversalFollowsSidebarOrderWithoutWrapAndJumpsToVisibleRows() throws {
    let f = try keyboardFixtureStore(); defer { try? FileManager.default.removeItem(at: f.root) }
    let store = f.store, t = f.threads
    let expected = [t["a-pinned"]!.id, t["a-new"]!.id, t["a-old"]!.id, t["b-one"]!.id]
    #expect(store.visibleThreadOrder == expected)
    #expect(store.visibleThreadOrder == store.orderedProjectGroups.flatMap { store.sidebarThreads(groupKey: $0.key).map(\.id) })
    // No selection: previous goes to the last row and next to the first.
    #expect(store.adjacentThread(.previous) == expected.last && store.adjacentThread(.next) == expected.first)
    store.selectedThreadID = expected[0]
    #expect(store.adjacentThread(.previous) == nil && store.adjacentThread(.next) == expected[1])
    store.selectedThreadID = expected[3]
    #expect(store.adjacentThread(.next) == nil && store.adjacentThread(.previous) == expected[2])
    #expect(store.threadForJump(1) == expected[0] && store.threadForJump(4) == expected[3] && store.threadForJump(5) == nil && store.threadForJump(10) == nil)
    // Search narrows the order exactly like the sidebar.
    store.search = "beta"
    #expect(store.visibleThreadOrder == [expected[3]])
    store.search = ""
    // A collapsed group keeps only its selected row.
    let alphaKey = store.orderedProjectGroups[0].key
    store.snapshot.sidebarPreferences?.groupExpandedByKey[alphaKey] = false
    store.selectedThreadID = expected[1]
    #expect(store.visibleThreadOrder == [expected[1], expected[3]])
    #expect(store.selectThread(expected[3]) && store.selectedProjectID == f.projects[1].id && store.selectedThreadID == expected[3])
    #expect(!store.selectThread(UUID()))
    #expect(ThreadTraversal.adjacent(in: [Int](), current: nil, direction: .next) == nil && ThreadTraversal.adjacent(in: [1, 2], current: 9, direction: .next) == nil)
}

@Test func navigationHistoryMovesLikeABrowserAndSkipsStaleThreads() {
    let a = UUID(), b = UUID(), c = UUID(), d = UUID()
    var history = ThreadNavigationHistory()
    history.visit(a); history.visit(b); history.visit(c)
    #expect(history.goBack { _ in true } == b && history.goBack { _ in true } == a)
    #expect(history.goForward { _ in true } == b && history.current == b)
    // History-driven selection is already current, so its selection change records nothing.
    history.visit(b)
    #expect(history.back == [a] && history.forward == [c])
    // A new visit clears forward history.
    history.visit(d)
    #expect(history.forward.isEmpty && !history.canGoForward { _ in true })
    // Stale entries are dropped while moving back.
    #expect(history.goBack { $0 != b } == a && history.back.isEmpty && history.forward == [d])
    var capped = ThreadNavigationHistory()
    for _ in 0..<60 { capped.visit(UUID()) }
    #expect(capped.back.count == ThreadNavigationHistory.limit)
    var repeated = ThreadNavigationHistory()
    repeated.visit(a); repeated.visit(nil); repeated.visit(a)
    #expect(repeated.back == [a] && repeated.current == a && !repeated.canGoBack { _ in true })
}

@Test func closedViewPlansDropMissingAndOpenEntriesStopAtUnreadyAndRestoreNewestFirst() {
    let ids = (0..<4).map { _ in UUID() }
    func entry(_ index: Int, _ tab: InspectorTab = .files) -> ClosedViewEntry { .init(threadID: ids[index], workspacePath: "/w\(index)", tab: tab) }
    var history = ClosedViewHistory()
    for index in 0..<4 { history.record(entry(index)) }
    history.record(entry(1))
    #expect(history.entries.map(\.threadID) == [ids[0], ids[2], ids[3], ids[1]])
    let states: [UUID: ReopenOwnerState] = [ids[1]: .missing, ids[3]: .ready(alreadyOpen: true), ids[2]: .ready(alreadyOpen: false), ids[0]: .ready(alreadyOpen: false)]
    let plan = ClosedViewHistory.plan(history.entries) { states[$0.threadID]! }
    #expect(plan.drop.map(\.threadID) == [ids[1], ids[3]] && plan.restore?.threadID == ids[2])
    #expect(history.takeNext { states[$0.threadID]! }?.threadID == ids[2] && history.entries.map(\.threadID) == [ids[0]])
    // An entry whose workspace is not ready stays for a later attempt.
    #expect(history.takeNext { _ in .notReady } == nil && history.entries.count == 1)
    for index in 0..<30 { history.record(.init(threadID: UUID(), workspacePath: "/\(index)", tab: .changes)) }
    #expect(history.entries.count == ClosedViewHistory.limit)
}

@MainActor @Test func threadFindMatchesFoldCaseAndDiacriticsWrapsAndFollowsStreaming() {
    let first = ChatMessage(id: "m1", role: .user, text: "Deploy the Café build, then the cafe docs")
    let tool = ChatMessage(id: "t1", role: .tool, text: "cafe output is not searched")
    var reply = ChatMessage(id: "m2", role: .assistant, text: "No match yet")
    let model = ThreadFindModel(threadID: UUID(), messages: [first, tool, reply])
    model.query = "CAFE"
    #expect(model.matches == [.init(messageID: "m1", occurrence: 0), .init(messageID: "m1", occurrence: 1)] && model.status == "1 of 2")
    model.next(); #expect(model.current?.occurrence == 1)
    model.next(); #expect(model.current?.occurrence == 0 && model.status == "1 of 2")
    model.previous(); #expect(model.current?.occurrence == 1)
    // Streaming text adds matches without moving the current one.
    reply.text = "Café is ready"
    model.update(messages: [first, tool, reply])
    #expect(model.matches.count == 3 && model.current == .init(messageID: "m1", occurrence: 1) && model.matchedMessageIDs == ["m1", "m2"])
    model.query = "zzz"
    #expect(model.matches.isEmpty && model.current == nil && model.status == "No results")
    model.query = ""
    #expect(model.status.isEmpty && ThreadFindModel.matches(in: [first], query: "  ").isEmpty)
}

@Test func paletteRankingPrefersExactThenPrefixThenContainsAndHonorsRecencyAndSecondary() {
    func item(_ id: String, _ terms: [String], recency: Double? = nil, secondary: Bool = false) -> PaletteItem {
        PaletteItem(id: id, title: terms.first ?? id, searchTerms: terms, searchRecency: recency, isSecondary: secondary, kind: .action {})
    }
    let actions = PaletteGroup(id: "actions", title: "Actions", items: [
        item("contains", ["Open the terminal"]), item("prefix", ["Terminal settings"]), item("exact", ["terminal"]),
        item("secondary-exact", ["terminal"], secondary: true), item("later-term", ["Other", "terminal panel"]),
    ])
    let recent = PaletteGroup(id: "recent-threads", title: "Recent Threads", items: [item("recent", ["terminal recent"])])
    #expect(CommandPaletteSearch.filter([actions, recent], query: "", inSubmenu: false).map(\.id) == ["actions", "recent-threads"])
    let ranked = CommandPaletteSearch.filter([actions, recent], query: "Terminal", inSubmenu: false)
    #expect(ranked.map(\.id) == ["actions"])
    #expect(ranked[0].items.map(\.id) == ["exact", "prefix", "contains", "later-term", "secondary-exact"])
    // Every token must appear; ">" limits results to actions.
    #expect(CommandPaletteSearch.filter([actions], query: "open terminal", inSubmenu: false).first?.items.map(\.id) == ["contains"])
    let threads = [item("old", ["Fix login"], recency: 1), item("new", ["Fix logout"], recency: 2)]
    let searched = CommandPaletteSearch.filter([actions, recent], query: "fix", inSubmenu: false, threads: threads)
    #expect(searched.map(\.id) == ["threads-search"] && searched[0].items.map(\.id) == ["new", "old"])
    #expect(CommandPaletteSearch.filter([actions, recent], query: ">", inSubmenu: false, threads: threads).map(\.id) == ["actions"])
    #expect(CommandPaletteSearch.filter([actions, recent], query: ">fix", inSubmenu: false, threads: threads).isEmpty)
    // Inside a submenu, every group in the view is searched.
    #expect(CommandPaletteSearch.filter([recent], query: "recent", inSubmenu: true).map(\.id) == ["recent-threads"])
    #expect(CommandPaletteSearch.normalize("  Café\tDÉPLOY ") == "cafe deploy")
    #expect(CommandPaletteSearch.snippet(in: String(repeating: "x", count: 60) + " Needle here", query: "needle", radius: 5) == "…xxxx Needle here")
}

@Test func paletteSearchStateRestoresTheParentQueryWhenLeavingASubmenu() {
    var state = CommandPaletteSearchState()
    state.setQuery("new")
    state.push(PaletteView(id: "a", title: "A", groups: [], initialQuery: "seed"))
    #expect(state.query == "seed" && state.current?.id == "a")
    state.push(PaletteView(id: "b", title: "B", groups: []))
    #expect(state.query.isEmpty && state.back() && state.query == "seed" && state.back() && state.query == "new" && !state.back())
    state.reset(query: "x")
    #expect(state.query == "x" && state.current == nil)
}

@MainActor @Test func paletteItemsListRecentThreadsSearchMessagesAndStartThreadsInAChosenProject() throws {
    let f = try keyboardFixtureStore(); defer { try? FileManager.default.removeItem(at: f.root) }
    let store = f.store
    for index in 0..<14 {
        var extra = CodingThread(project: f.projects[1]); extra.title = "Extra \(index)"; extra.updatedAt = Date(timeIntervalSince1970: 1_000 + Double(index))
        store.snapshot.threads.append(extra)
    }
    store.selectedThreadID = f.threads["a-new"]!.id
    let controller = MainWindowController(store: store)
    let root = CommandPaletteItems.sources(for: controller, query: "")
    let recent = try #require(root.root.first { $0.id == "recent-threads" })
    #expect(recent.items.count == CommandPaletteSearch.recentThreadLimit && recent.items.first?.title == "Extra 13")
    #expect(!root.root.flatMap(\.items).contains { $0.title == "Archived alpha" } && root.threads.isEmpty)
    let actions = try #require(root.root.first { $0.id == "actions" }).items
    #expect(actions.contains { $0.id == "action:find-thread" && $0.shortcut == .chatFind })
    #expect(actions.contains { $0.id == "action:copy-thread-reference" } && actions.first?.title == "New Thread in Alpha")
    #expect(!actions.contains { $0.id == "action:stop" } && !actions.contains { $0.id == "action:reopen" })
    // One character does not search messages; two characters show a message snippet.
    #expect(CommandPaletteItems.sources(for: controller, query: "c").threads.allSatisfy { $0.snippet == nil })
    let cafe = CommandPaletteItems.sources(for: controller, query: "cafe deployment").threads
    let match = try #require(cafe.first { $0.id == "thread:\(f.threads["a-pinned"]!.id.uuidString)" })
    #expect(match.snippet?.contains("café deployment") == true)
    let filtered = CommandPaletteSearch.filter(root.root, query: "cafe deployment", inSubmenu: false, threads: cafe)
    #expect(filtered.map(\.id) == ["threads-search"] && filtered[0].items.first?.title == "Pinned planning")
    let projects = CommandPaletteItems.projectItems(controller)
    #expect(projects.map(\.title) == ["Alpha", "Beta"])
    // New Thread In… lists every checkout in sidebar order.
    let view = CommandPaletteItems.newThreadInView(controller)
    #expect(view.groups[0].items.map(\.subtitle) == f.projects.map(\.path))
    let appearance = CommandPaletteItems.appearanceView(controller).groups[0].items
    #expect(appearance.map(\.title) == ["System", "Light", "Dark"] && appearance.filter(\.isChecked).count == 1)
}

@MainActor @Test func paletteModelNavigatesSubmenusNumbersAndClosesBackToTheComposer() throws {
    var ran: [String] = [], dismissed = 0
    let sub = PaletteView(id: "sub", title: "Sub", groups: [.init(id: "s", title: "S", items: [
        PaletteItem(id: "s1", title: "First", searchTerms: ["First"], kind: .action { ran.append("s1") }),
        PaletteItem(id: "s2", title: "Second", searchTerms: ["Second"], isDisabled: true, kind: .action { ran.append("s2") }),
        PaletteItem(id: "s3", title: "Third", searchTerms: ["Third"], kind: .action { ran.append("s3") }),
    ])])
    let model = CommandPaletteModel(source: { _ in
        .init(root: [.init(id: "actions", title: "Actions", items: [
            PaletteItem(id: "a", title: "Alpha", searchTerms: ["Alpha"], kind: .action { ran.append("a") }),
            PaletteItem(id: "sub", title: "Open Sub", searchTerms: ["Open Sub"], kind: .submenu(sub)),
        ])])
    }, dismiss: { _ in dismissed += 1 })
    model.query = "open"
    #expect(model.highlighted?.id == "sub")
    model.activateHighlighted()
    #expect(model.breadcrumb == "Sub" && model.query.isEmpty && dismissed == 0)
    // Disabled entries are not numbered or highlighted.
    #expect(model.selectableItems.map(\.id) == ["s1", "s3"])
    model.move(1); #expect(model.highlighted?.id == "s3")
    model.move(5); #expect(model.highlighted?.id == "s3")
    #expect(model.back() && model.query == "open" && model.breadcrumb == nil)
    #expect(!model.activate(number: 5))
    model.query = ""
    #expect(model.activate(number: 1) && ran == ["a"] && dismissed == 1)
}

@Test func keybindingSettingsRowsDetectSourcesConflictsSearchAndRecording() {
    let custom = KeybindingResolver.merge(KeybindingResolver.compile([
        .init(key: "mod+k", command: .threadPin, when: "!terminalFocus"),
        .init(key: "mod+l", command: .script("test")),
    ]))
    let rows = KeybindingsSettingsModel.rows(custom)
    let pin = rows.first { $0.command == .threadPin }!, palette = rows.first { $0.command == .commandPaletteToggle }!
    #expect(pin.source == .custom && pin.defaultKey == "mod+shift+p" && pin.canReset && pin.canRemove)
    #expect(palette.source == .default && !palette.canRemove && !palette.canReset)
    #expect(rows.first { $0.command == .script("test") }?.source == .project)
    #expect(pin.conflicts == ["Command Palette"] && palette.conflicts == ["Thread: Pin"])
    // Different conditions on the same keys do not conflict; an empty condition conflicts with any.
    let split = rows.first { $0.command == .terminalSplit }!
    #expect(split.conflicts.isEmpty && rows.first { $0.command == .diffToggle }!.conflicts.isEmpty)
    #expect(KeybindingsSettingsModel.conflictLabels(rows, rowID: nil, shortcut: KeybindingShortcut(parsing: "mod+d"), when: "") == ["Inspector: Show Changes", "Terminal: Split"])
    #expect(KeybindingsSettingsModel.filter(rows, query: "⌘K").map(\.command).sorted() == [.commandPaletteToggle, .threadPin])
    #expect(KeybindingsSettingsModel.filter(rows, query: "project").contains { $0.command == .script("test") })
    #expect(KeybindingsSettingsModel.groups(rows).map(\.title).first == "Navigation")
    #expect(KeybindingsSettingsModel.parseWhen("") == .empty && KeybindingsSettingsModel.parseWhen("a &&") != .empty)
    if case .valid(_, let unknown) = KeybindingsSettingsModel.parseWhen("terminalFocus || mystery") { #expect(unknown == ["mystery"]) } else { Issue.record("Expected a valid condition") }
    if case .invalid = KeybindingsSettingsModel.parseWhen("a &&") { } else { Issue.record("Expected an invalid condition") }
    // Recording keeps US shifted glyphs as their key plus Shift, and Command as `mod`.
    #expect(KeybindingsSettingsModel.recordedKey(keyCode: 18, characters: "!", command: true, control: false, option: false, shift: true) == "mod+shift+1")
    #expect(KeybindingsSettingsModel.recordedKey(keyCode: 33, characters: "{", command: true, control: false, option: false, shift: true) == "mod+shift+[")
    #expect(KeybindingsSettingsModel.recordedKey(keyCode: 0, characters: "å", command: true, control: false, option: true, shift: false) == "mod+alt+a")
    #expect(KeybindingsSettingsModel.recordedKey(keyCode: 49, characters: " ", command: false, control: true, option: false, shift: false) == "ctrl+space")
    #expect(KeybindingsSettingsModel.recordedKey(keyCode: 53, characters: "\u{1b}", command: true, control: false, option: false, shift: false) == "mod+esc")
    #expect(KeybindingsSettingsModel.recordedKey(keyCode: 126, characters: "\u{F700}", command: false, control: false, option: true, shift: false) == "alt+arrowup")
    #expect(KeybindingsSettingsModel.commandOptions.contains(.chatFind) && !KeybindingsSettingsModel.commandOptions.contains(.init("preview.toggle")))
}

@Test func keybindingNoticesReportIssuesAndThrottleSuccess() {
    var controller = KeybindingsNoticeController()
    let start = Date(timeIntervalSince1970: 1_000)
    #expect(controller.handle(.init(), now: start) == .success)
    #expect(controller.handle(.init(), now: start.addingTimeInterval(1)) == nil)
    #expect(controller.handle(.init(), now: start.addingTimeInterval(2.1)) == .success)
    let issue = KeybindingsConfigState(issues: [.init(kind: .invalidEntry, index: 0, message: "Bad"), .init(kind: .malformedConfig, message: "Second")])
    #expect(controller.handle(issue, now: start.addingTimeInterval(2.2)) == .invalid("Entry 1: Bad"))
}

@Test func appearanceCycleWritesTheSharedSettingInSystemLightDarkOrder() throws {
    let suite = "coincide-appearance-" + UUID().uuidString
    let defaults = try #require(UserDefaults(suiteName: suite)); defer { defaults.removePersistentDomain(forName: suite) }
    #expect(AppearanceMode.next(after: nil) == .light && AppearanceMode.next(after: "bogus") == .light && AppearanceMode.next(after: "dark") == .system)
    #expect(AppearanceMode.cycle(defaults) == .light && defaults.string(forKey: "appearance") == "light")
    #expect(AppearanceMode.cycle(defaults) == .dark && AppearanceMode.cycle(defaults) == .system && AppearanceMode.current(defaults) == .system)
}
