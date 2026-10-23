import AppKit
import CoincideCore
import CoincideTerminal
import Darwin
import SwiftUI
import Testing
@testable import Coincide

@MainActor private func waitTerminalUI(_ condition: () async throws -> Bool) async throws {
    let deadline = ContinuousClock.now + .seconds(10)
    while try await !condition() {
        guard ContinuousClock.now < deadline else { throw CoincideError("The terminal fixture did not settle.") }
        try await Task.sleep(for: .milliseconds(20))
    }
}

@MainActor private func terminalFixtureRoot(_ name: String) throws -> URL {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("coincide-\(name)-\(UUID())").resolvingSymlinksInPath()
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    return root
}

@Test(.timeLimit(.minutes(1))) @MainActor
func terminalSplitGroupsPerThreadVisibilityAndHeightsSurviveWindowRestore() async throws {
    let root = try terminalFixtureRoot("terminal-split"); defer { try? FileManager.default.removeItem(at: root) }
    let archive = TerminalArchiveStore(root: root.appendingPathComponent("archive"))
    let thread = CodingThread(project: .init(path: root.path)), other = CodingThread(project: .init(path: root.path))
    let first = TerminalWorkspaceStore(executable: "/bin/sh", loginShell: false)
    first.restore(from: archive, currentThreads: { [thread, other] }); await first.waitForRestoration()
    try first.add(for: thread)
    #expect(first.isVisible(thread.id) && !first.isVisible(other.id))
    let anchor = try #require(first.selected(in: thread.id))
    #expect(anchor.ordinal == 1 && anchor.displayTitle == "Terminal 1")
    try first.split(for: thread, axis: .horizontal)
    try first.split(for: thread, axis: .vertical)
    try first.split(for: thread, axis: .vertical)
    let group = try #require(first.activeGroup(in: thread.id))
    #expect(group.sessionIDs.count == 4 && group.axis == .vertical && !first.canSplit(in: thread.id))
    #expect(throws: (any Error).self) { try first.split(for: thread, axis: .horizontal) }
    #expect(first.sessions[thread.id]?.compactMap(\.ordinal) == [1, 2, 3, 4])
    try first.add(for: thread)
    #expect(first.layout(for: thread.id).groups.map(\.sessionIDs.count) == [4, 1])
    let closing = try #require(first.sessions[thread.id]?[1])
    first.select(closing, threadID: thread.id, focus: false)
    first.close(closing, threadID: thread.id)
    #expect(first.layout(for: thread.id).groups.map(\.sessionIDs.count) == [3, 1])
    #expect(first.selected(in: thread.id)?.id == group.sessionIDs[2], "Closing a pane selects its neighbour in the group.")
    first.recordPanelHeight(333, threadID: thread.id)
    first.setVisible(true, threadID: other.id); first.setVisible(false, threadID: other.id)
    let expectedGroups = first.layout(for: thread.id).groups
    for session in first.suspend() { await session.waitForClose() }
    await first.waitForPersistence()

    let second = TerminalWorkspaceStore(executable: "/bin/sh", loginShell: false)
    second.restore(from: archive, currentThreads: { [thread, other] }); await second.waitForRestoration()
    #expect(second.layout(for: thread.id).groups == expectedGroups)
    #expect(second.isVisible(thread.id) && !second.isVisible(other.id) && second.panelHeight(thread.id) == 333)
    #expect(second.panelHeight(other.id) == TerminalWorkspaceStore.defaultPanelHeight)
    #expect(second.sessions[thread.id]?.allSatisfy { $0.detachment == .restart && $0.processID == 0 } == true)
    #expect(second.sessions[thread.id]?.compactMap(\.ordinal) == [1, 3, 4, 5])
    second.removeAll(); await second.waitForPersistence(); second.suspend(); await second.waitForPersistence()
}

@Test(.timeLimit(.minutes(1))) @MainActor
func plainTerminalsGetT3RuntimeVariablesAndCleanShellExitsCloseTheirTab() async throws {
    let root = try terminalFixtureRoot("terminal-env"); defer { try? FileManager.default.removeItem(at: root) }
    let worktree = root.appendingPathComponent("worktree")
    try FileManager.default.createDirectory(at: worktree, withIntermediateDirectories: true)
    var thread = CodingThread(project: .init(path: root.path)); thread.workspacePath = worktree.path
    let terminals = TerminalWorkspaceStore(executable: "/bin/sh", loginShell: false)
    terminals.integration.environment = { TerminalRuntimeEnvironment.variables(projectRoot: root.path, workspacePath: $0.workspacePath) }
    try terminals.add(for: thread)
    let shell = try #require(terminals.selected(in: thread.id))
    // Long paths wrap in the emulator, so the shell compares them and prints a short marker.
    try await shell.send("[ \"$T3CODE_PROJECT_ROOT\" = '\(root.path)' ] && [ \"$T3CODE_WORKTREE_PATH\" = '\(worktree.path)' ] && printf 'ENV_%s\\n' MATCHED\n")
    try await waitTerminalUI { shell.visibleText.contains("ENV_MATCHED") }
    try await shell.send("exit 0\n")
    try await waitTerminalUI { terminals.sessions[thread.id] == nil }
    #expect(!terminals.isVisible(thread.id), "The drawer hides when its last shell exits cleanly.")
    try terminals.add(for: thread)
    let failing = try #require(terminals.selected(in: thread.id))
    try await failing.send("exit 3\n")
    try await waitTerminalUI { failing.lifecycle == .exited(3) }
    try await Task.sleep(for: .milliseconds(100))
    #expect(terminals.sessions[thread.id]?.first === failing, "A failed shell keeps its tab and status.")
    let script = try ProjectScript(name: "Quick", command: "exit 0")
    let command = try terminals.run(.init(script: script, projectRoot: root, worktreePath: worktree), for: thread)
    try await waitTerminalUI { command.lifecycle == .exited(0) }
    try await Task.sleep(for: .milliseconds(100))
    #expect(terminals.sessions[thread.id]?.contains { $0 === command } == true, "Script tabs keep their result.")
    for session in terminals.removeAll() { await session.waitForClose() }
}

@Test(.timeLimit(.minutes(1))) @MainActor
func closingIdleTerminalsKeepsOutputAndLeavesRunningCommandsOpen() async throws {
    let root = try terminalFixtureRoot("terminal-idle"); defer { try? FileManager.default.removeItem(at: root) }
    let archive = TerminalArchiveStore(root: root.appendingPathComponent("archive"))
    let thread = CodingThread(project: .init(path: root.path))
    let terminals = TerminalWorkspaceStore(executable: "/bin/sh", loginShell: false)
    terminals.restore(from: archive, currentThreads: { [thread] }); await terminals.waitForRestoration()
    try terminals.add(for: thread)
    let idle = try #require(terminals.selected(in: thread.id))
    try await idle.send("printf 'IDLE_OUTPUT_KEPT\\n'\n")
    try await waitTerminalUI { idle.visibleText.contains("IDLE_OUTPUT_KEPT\n") }
    try terminals.add(for: thread)
    let busy = try #require(terminals.selected(in: thread.id))
    try await busy.send("sleep 30\n")
    try await waitTerminalUI { busy.hasForegroundCommand }
    let script = try terminals.run(.init(script: try ProjectScript(name: "Server", command: "sleep 30"), projectRoot: root), for: thread)
    try await Task.sleep(for: .milliseconds(300))
    #expect(await terminals.closeIdle(threadID: thread.id) == 1)
    #expect(idle.detachment == .idle && terminals.sessions[thread.id]?.contains { $0 === idle } == true)
    try await waitTerminalUI { if case .exited = idle.lifecycle { true } else { false } }
    #expect(idle.visibleText.contains("IDLE_OUTPUT_KEPT"))
    #expect(busy.lifecycle == .running && script.lifecycle == .running)
    #expect(terminals.runningCount(threadID: thread.id) == 2)
    #expect(await terminals.closeIdle(threadID: thread.id) == 0)
    let closing = terminals.suspend(); await terminals.waitForPersistence()
    for session in closing { await session.waitForClose() }
    let restored = TerminalWorkspaceStore(executable: "/bin/sh", loginShell: false)
    restored.restore(from: archive, currentThreads: { [thread] }); await restored.waitForRestoration()
    #expect(restored.sessions[thread.id]?.first { $0.id == idle.id }?.detachment == .idle)
    restored.removeAll(); await restored.waitForPersistence(); restored.suspend(); await restored.waitForPersistence()
}

@Test(.timeLimit(.minutes(1))) @MainActor
func terminalLinksRouteFilesAndWebLinksAndRefuseOtherSchemes() async throws {
    let root = try terminalFixtureRoot("terminal-links"); defer { try? FileManager.default.removeItem(at: root) }
    let thread = CodingThread(project: .init(path: root.path))
    let terminals = TerminalWorkspaceStore(executable: "/bin/sh", loginShell: false)
    var files: [(String, Int?, Int?)] = [], urls: [URL] = []
    terminals.integration.openFile = { path, line, column, _ in files.append((path, line, column)); return path.hasSuffix("missing.txt") ? "missing" : nil }
    terminals.integration.openURL = { urls.append($0) }
    try terminals.add(for: thread)
    let shell = try #require(terminals.selected(in: thread.id))
    try await waitTerminalUI { shell.processID > 0 }
    shell.view.requestOpenLink(source: shell.view, link: "src/app.swift:12:4:", params: [:])
    shell.view.requestOpenLink(source: shell.view, link: "https://example.com/docs).", params: [:])
    #expect(files.count == 1 && files.first?.0.hasSuffix("/src/app.swift") == true && files.first?.1 == 12 && files.first?.2 == 4)
    #expect(files.first.map { URL(fileURLWithPath: $0.0).deletingLastPathComponent().deletingLastPathComponent().resolvingSymlinksInPath().path } == root.path)
    #expect(urls == [URL(string: "https://example.com/docs")!] && terminals.notice == nil)
    shell.view.requestOpenLink(source: shell.view, link: "missing.txt:1", params: [:])
    #expect(terminals.notice == "missing")
    terminals.notice = nil
    shell.view.requestOpenLink(source: shell.view, link: "ssh://example.com/repo", params: [:])
    #expect(terminals.notice != nil && urls.count == 1 && files.count == 2)
    for session in terminals.removeAll() { await session.waitForClose() }
}

@Test(.timeLimit(.minutes(1))) @MainActor
func settlingAConversationClosesIdleTerminalsAndRoutesWorkspaceFileLinks() async throws {
    let fixture = try await NativeSetupFixture.make(command: "exit 0")
    let store = fixture.store, id = fixture.thread.id
    let terminals = TerminalWorkspaceStore(executable: "/bin/sh", loginShell: false); store.registerTerminals(terminals)
    do {
        let thread = try #require(store.thread(id))
        #expect(store.terminalEnvironment(for: thread) == [TerminalRuntimeEnvironment.projectRootKey: fixture.source.path])
        try terminals.add(for: thread)
        let idle = try #require(terminals.selected(in: id))
        try terminals.add(for: thread)
        let busy = try #require(terminals.selected(in: id))
        try await busy.send("sleep 30\n")
        try await waitTerminalUI { busy.hasForegroundCommand }
        try await Task.sleep(for: .milliseconds(300))
        #expect(store.openTerminalFile(fixture.source.appendingPathComponent("notes.txt").path, line: 1, column: nil, thread: thread) == nil)
        #expect(store.fileNavigation?.path == "notes.txt" && store.fileNavigation?.line == 1 && store.inspectorVisible)
        #expect(store.openTerminalFile(fixture.source.appendingPathComponent("gone.txt").path, line: nil, column: nil, thread: thread) != nil)
        try await store.settleThread(id)
        #expect(idle.detachment == .idle && busy.lifecycle == .running)
        #expect(store.runningTerminalCount(threadID: id) == 1)
        terminals.setVisible(false, threadID: id)
        store.showTerminals(threadID: id)
        #expect(terminals.isVisible(id) && store.selectedThreadID == id)
    } catch { for session in terminals.removeAll() { await session.waitForClose() }; store.unregisterTerminals(terminals); await fixture.cleanup(); throw error }
    for session in terminals.removeAll() { await session.waitForClose() }
    store.unregisterTerminals(terminals)
    await fixture.cleanup()
}

@Test(.timeLimit(.minutes(1))) @MainActor
func terminalPanelAndSettingsFitInBothAppearances() async throws {
    let root = try terminalFixtureRoot("terminal-panel"); defer { try? FileManager.default.removeItem(at: root) }
    let thread = CodingThread(project: .init(path: root.path))
    let terminals = TerminalWorkspaceStore(executable: "/bin/sh", loginShell: false)
    try terminals.add(for: thread)
    try terminals.split(for: thread, axis: .horizontal)
    let running = try #require(terminals.selected(in: thread.id))
    try await running.send("sleep 30\n")
    terminals.notice = "“missing.txt” was not found."
    for scheme in [ColorScheme.light, .dark] {
        let panel = TerminalPanel(terminals: terminals, thread: thread, canAdd: { true }, report: { Issue.record("Unexpected report: \($0)") }, hide: {})
            .frame(width: 720, height: 300).environment(\.colorScheme, scheme)
        let hosting = NSHostingView(rootView: panel)
        let window = NSWindow(contentRect: .init(x: -10_000, y: -10_000, width: 720, height: 300), styleMask: .borderless, backing: .buffered, defer: false)
        window.appearance = NSAppearance(named: scheme == .light ? .aqua : .darkAqua)
        window.isReleasedWhenClosed = false; window.contentView = hosting
        hosting.layoutSubtreeIfNeeded(); try await Task.sleep(for: .milliseconds(100)); hosting.layoutSubtreeIfNeeded()
        let panes = terminals.sessions[thread.id, default: []].map(\.view)
        #expect(panes.count == 2 && panes.allSatisfy { $0.window === window && $0.frame.width > 100 && $0.frame.height > 60 })
        #expect(panes[0].convert(panes[0].bounds, to: nil).maxX <= panes[1].convert(panes[1].bounds, to: nil).minX + 1, "Split Right places panes side by side.")
        window.close()
        let settings = Form { TerminalSettingsSection() }.formStyle(.grouped).environment(\.colorScheme, scheme)
        let controller = NSHostingController(rootView: settings)
        let size = controller.sizeThatFits(in: .init(width: 600, height: 900))
        #expect(size.width <= 601 && size.height > 100 && size.height <= 900)
    }
    #expect(TerminalActivityBadge.label(1) == "1 terminal process running. Open terminal")
    #expect(TerminalActivityBadge.label(3) == "3 terminal processes running. Open terminal")
    for session in terminals.removeAll() { await session.waitForClose() }
}

@MainActor private final class DrawerHeights { var value: [UUID: CGFloat] = [:] }

@Test(.timeLimit(.minutes(1))) @MainActor
func terminalDrawerAppliesEachConversationsSavedHeight() async throws {
    let terminals = TerminalWorkspaceStore(executable: "/bin/sh", loginShell: false)
    let tall = UUID(), standard = UUID(), measured = DrawerHeights()
    terminals.recordPanelHeight(420, threadID: tall)
    terminals.recordPanelHeight(5_000, threadID: standard); terminals.recordPanelHeight(TerminalWorkspaceStore.defaultPanelHeight, threadID: standard)
    #expect(terminals.panelHeight(tall) == 420 && terminals.panelHeight(standard) == TerminalWorkspaceStore.defaultPanelHeight)
    for threadID in [tall, standard] {
        let view = TerminalDrawerSplit(terminals: terminals, threadID: threadID, showsDrawer: true) {
            Color.red
        } drawer: {
            Color.blue.background(GeometryReader { proxy in
                Color.clear.onAppear { measured.value[threadID] = proxy.size.height }
                    .onChange(of: proxy.size.height) { _, height in measured.value[threadID] = height }
            })
        }.frame(width: 600, height: 900)
        let hosting = NSHostingView(rootView: view)
        let window = NSWindow(contentRect: .init(x: -10_000, y: -10_000, width: 600, height: 900), styleMask: .borderless, backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; window.contentView = hosting
        hosting.layoutSubtreeIfNeeded(); try await Task.sleep(for: .milliseconds(100)); hosting.layoutSubtreeIfNeeded()
        window.close()
    }
    #expect(measured.value[tall] == 420 && measured.value[standard] == CGFloat(TerminalWorkspaceStore.defaultPanelHeight))
}
