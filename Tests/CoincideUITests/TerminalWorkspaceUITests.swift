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

private let terminalUIFixturePrompt = "\u{1b}]133;A;cl=line\u{7}UI_FIXTURE_PROMPT> \u{1b}]133;B\u{7}"

@MainActor private func restoredTerminalFixture(root: URL, thread: CodingThread, withIdentity: Bool = true) async throws -> (TerminalWorkspaceStore, LocalTerminalSession, URL) {
    let launches = root.appendingPathComponent("shell-launches"), executable = root.appendingPathComponent("private-shell")
    try Data("#!/bin/sh\nprintf 'launch\\n' >> '\(launches.path)'\nexec /bin/sh\n".utf8).write(to: executable)
    try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: executable.path)
    let archive = TerminalArchiveStore(root: root.appendingPathComponent("archive"))
    var saved = try await archive.claim()
    let identity = withIdentity ? try TerminalWorkspaceIdentity.capture(thread: thread) : nil
    saved.tabs = [.init(id: UUID(), threadID: thread.id, workspacePath: thread.workspacePath, directory: thread.workspacePath,
        title: "Saved checkout", text: "SAVED_OUTPUT_MUST_STAY_INERT\n", isCommand: false, exitCode: nil,
        workspaceIdentity: identity)]
    try await archive.save(saved); await archive.release(saved.id)
    let terminals = TerminalWorkspaceStore(executable: executable.path, loginShell: false)
    terminals.restore(from: archive, currentThreads: { [thread] }); await terminals.waitForRestoration()
    return (terminals, try #require(terminals.sessions[thread.id]?.first), launches)
}

private func terminalLaunchCount(_ file: URL) -> Int {
    ((try? String(contentsOf: file, encoding: .utf8)) ?? "").split(separator: "\n").count
}

@MainActor private func closeTerminalFixture(_ terminals: TerminalWorkspaceStore) async {
    for session in terminals.removeAll() { await session.waitForClose() }
    terminals.suspend(); await terminals.waitForPersistence()
}

/// Readiness that the terminal integration closure reads after it changes.
@MainActor private final class TerminalReadinessFlag { var value = false }

@Test(.timeLimit(.minutes(1))) @MainActor
func restoredTerminalReadinessChangeStartsExactlyOneFreshShellWithTheSamePaneIDs() async throws {
    let root = try terminalFixtureRoot("terminal-readiness"); defer { try? FileManager.default.removeItem(at: root) }
    let thread = CodingThread(project: .init(path: root.path))
    let (terminals, restored, launches) = try await restoredTerminalFixture(root: root, thread: thread)
    let ready = TerminalReadinessFlag()
    terminals.integration.thread = { $0 == thread.id ? thread : nil }
    terminals.integration.canOpen = { _ in ready.value }
    do {
        let ids = [restored.id]
        let blocked = terminals.resumeReadiness(for: thread, sessionIDs: ids, canOpen: ready.value, enabled: true)
        terminals.resumeRestoredPanes(blocked, for: thread)
        #expect(restored.processID == 0 && terminalLaunchCount(launches) == 0)
        #expect(!terminals.canResume(restored, thread: thread))
        ready.value = true
        let available = terminals.resumeReadiness(for: thread, sessionIDs: ids, canOpen: ready.value, enabled: true)
        #expect(available != blocked && available.sessionIDs == blocked.sessionIDs)
        terminals.resumeRestoredPanes(available, for: thread)
        try await waitTerminalUI { restored.processID > 0 && terminalLaunchCount(launches) == 1 }
        let processID = restored.processID
        terminals.resumeRestoredPanes(available, for: thread)
        #expect(restored.processID == processID && terminalLaunchCount(launches) == 1)
        #expect(restored.visibleText.contains("SAVED_OUTPUT_MUST_STAY_INERT"))
        try await restored.send("printf 'NEW_SHELL_ONLY\\n'\n")
        try await waitTerminalUI { restored.visibleText.contains("NEW_SHELL_ONLY\n") }
        #expect(terminals.sessions[thread.id]?.map(\.id) == ids)
    } catch { await closeTerminalFixture(terminals); throw error }
    await closeTerminalFixture(terminals)
}

@Test(.timeLimit(.minutes(1)), arguments: [false, true]) @MainActor
func savedTerminalCannotResumeIntoAMovedOrReplacedCheckout(replaceDirectory: Bool) async throws {
    let root = try terminalFixtureRoot("terminal-identity"); defer { try? FileManager.default.removeItem(at: root) }
    let checkout = root.appendingPathComponent("checkout-a"), other = root.appendingPathComponent("checkout-b")
    try FileManager.default.createDirectory(at: checkout, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: other, withIntermediateDirectories: true)
    var original = CodingThread(project: .init(path: root.path)); original.workspacePath = checkout.path
    let (terminals, restored, launches) = try await restoredTerminalFixture(root: root, thread: original)
    var current = original
    terminals.integration.thread = { $0 == current.id ? current : nil }
    let before = restored.visibleText
    let oldReadiness = terminals.resumeReadiness(for: original, sessionIDs: [restored.id], canOpen: true, enabled: true)
    do {
        if replaceDirectory {
            try FileManager.default.moveItem(at: checkout, to: root.appendingPathComponent("original-checkout-preserved"))
            try FileManager.default.createDirectory(at: checkout, withIntermediateDirectories: true)
        } else { current.workspacePath = other.path }
        terminals.resumeRestoredPanes(oldReadiness, for: original)
        let freshReadiness = terminals.resumeReadiness(for: current, sessionIDs: [restored.id], canOpen: true, enabled: true)
        terminals.resumeRestoredPanes(freshReadiness, for: current)
        #expect(!terminals.canResume(restored, thread: current))
        #expect(throws: (any Error).self) { try terminals.resume(restored, thread: current, focus: false) }
        #expect(restored.processID == 0 && terminalLaunchCount(launches) == 0)
        #expect(restored.visibleText == before && terminals.sessions[current.id]?.first === restored)
        // A new terminal captures the new checkout; it never repurposes the old pane.
        try terminals.add(for: current)
        let fresh = try #require(terminals.selected(in: current.id))
        try await waitTerminalUI { fresh.processID > 0 && terminalLaunchCount(launches) == 1 }
        #expect(fresh.id != restored.id && fresh.workspaceIdentity?.matches(thread: current) == true)
        #expect(restored.processID == 0 && restored.visibleText == before)
        let savedID = fresh.id
        for session in terminals.suspend() { await session.waitForClose() }
        await terminals.waitForPersistence()
        #expect(terminals.restorationError == nil)
        let reopened = TerminalWorkspaceStore(executable: root.appendingPathComponent("private-shell").path, loginShell: false)
        reopened.restore(from: TerminalArchiveStore(root: root.appendingPathComponent("archive")), currentThreads: { [current] })
        await reopened.waitForRestoration()
        do {
            #expect(reopened.restorationError == nil && reopened.sessions[current.id]?.count == 2)
            let oldPane = try #require(reopened.sessions[current.id]?.first { $0.id == restored.id })
            let newPane = try #require(reopened.sessions[current.id]?.first { $0.id == savedID })
            #expect(oldPane.originalWorkspacePath == original.workspacePath && oldPane.workspaceIdentity == restored.workspaceIdentity)
            #expect(oldPane.processID == 0 && oldPane.visibleText.contains("SAVED_OUTPUT_MUST_STAY_INERT"))
            #expect(!reopened.canResume(oldPane, thread: current) && reopened.canResume(newPane, thread: current))
            #expect(terminalLaunchCount(launches) == 1, "Cold restoration never launches or repurposes either saved pane.")
        } catch { await closeTerminalFixture(reopened); throw error }
        await closeTerminalFixture(reopened)
    } catch { await closeTerminalFixture(terminals); throw error }
    await closeTerminalFixture(terminals)
}

@Test(.timeLimit(.minutes(1))) @MainActor
func legacyTerminalArchiveRestoresOutputButRequiresANewTerminalInsteadOfResume() async throws {
    let root = try terminalFixtureRoot("terminal-legacy"); defer { try? FileManager.default.removeItem(at: root) }
    let thread = CodingThread(project: .init(path: root.path))
    let (terminals, restored, launches) = try await restoredTerminalFixture(root: root, thread: thread, withIdentity: false)
    do {
        #expect(restored.workspaceIdentity == nil && restored.visibleText.contains("SAVED_OUTPUT_MUST_STAY_INERT"))
        let readiness = terminals.resumeReadiness(for: thread, sessionIDs: [restored.id], canOpen: true, enabled: true)
        terminals.resumeRestoredPanes(readiness, for: thread)
        #expect(throws: (any Error).self) { try terminals.resume(restored, thread: thread, focus: false) }
        #expect(restored.processID == 0 && terminalLaunchCount(launches) == 0)
        try terminals.add(for: thread)
        let fresh = try #require(terminals.selected(in: thread.id))
        try await waitTerminalUI { fresh.processID > 0 && terminalLaunchCount(launches) == 1 }
        #expect(fresh.id != restored.id && restored.processID == 0)
    } catch { await closeTerminalFixture(terminals); throw error }
    await closeTerminalFixture(terminals)
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
    do {
        terminals.integration.environment = { _ in ["PS1": terminalUIFixturePrompt] }
        terminals.restore(from: archive, currentThreads: { [thread] }); await terminals.waitForRestoration()
        try terminals.add(for: thread)
        let idle = try #require(terminals.selected(in: thread.id))
        try await waitTerminalUI { idle.hasIdlePrompt }
        try await idle.send("printf 'IDLE_OUTPUT_KEPT\\n'\n")
        try await waitTerminalUI { idle.visibleText.contains("IDLE_OUTPUT_KEPT\n") && idle.hasIdlePrompt }
        try terminals.add(for: thread)
        let busy = try #require(terminals.selected(in: thread.id))
        try await busy.send("sleep 30\n")
        try await waitTerminalUI { busy.hasForegroundCommand }
        let script = try terminals.run(.init(script: try ProjectScript(name: "Server", command: "sleep 30"), projectRoot: root), for: thread)
        try terminals.add(for: thread)
        let background = try #require(terminals.selected(in: thread.id))
        try await background.send("sleep 30 & printf 'BACKGROUND_%s\\n' READY\n")
        try await waitTerminalUI { background.visibleText.contains("BACKGROUND_READY\n") && background.isBusy }
        try await Task.sleep(for: .milliseconds(300))
        #expect(await terminals.closeIdle(threadID: thread.id) == 1)
        #expect(idle.detachment == .idle && terminals.sessions[thread.id]?.contains { $0 === idle } == true)
        try await waitTerminalUI { if case .exited = idle.lifecycle { true } else { false } }
        #expect(idle.visibleText.contains("IDLE_OUTPUT_KEPT"))
        #expect(busy.lifecycle == .running && script.lifecycle == .running && background.lifecycle == .running)
        #expect(terminals.runningCount(threadID: thread.id) == 3)
        #expect(await terminals.closeIdle(threadID: thread.id) == 0)
        let closing = terminals.suspend(); await terminals.waitForPersistence()
        for session in closing { await session.waitForClose() }
        let restored = TerminalWorkspaceStore(executable: "/bin/sh", loginShell: false)
        restored.restore(from: archive, currentThreads: { [thread] }); await restored.waitForRestoration()
        #expect(restored.sessions[thread.id]?.first { $0.id == idle.id }?.detachment == .idle)
        restored.removeAll(); await restored.waitForPersistence(); restored.suspend(); await restored.waitForPersistence()
    } catch { await closeTerminalFixture(terminals); throw error }
    await closeTerminalFixture(terminals)
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
    #expect(files.first.map { URL(fileURLWithPath: $0.0).deletingLastPathComponent().deletingLastPathComponent().resolvingSymlinksInPath().path } == root.resolvingSymlinksInPath().path)
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
    let defaults = UserDefaults.standard, key = TerminalAppearance.closeIdleOnSettleKey
    let previousPreference = defaults.object(forKey: key)
    defaults.set(true, forKey: key)
    defer {
        if let previousPreference { defaults.set(previousPreference, forKey: key) }
        else { defaults.removeObject(forKey: key) }
    }
    let fixture = try await NativeSetupFixture.make(command: "exit 0")
    let store = fixture.store, id = fixture.thread.id
    let terminals = TerminalWorkspaceStore(executable: "/bin/sh", loginShell: false); store.registerTerminals(terminals)
    let inheritedEnvironment = terminals.integration.environment
    terminals.integration.environment = { inheritedEnvironment($0).merging(["PS1": terminalUIFixturePrompt]) { _, prompt in prompt } }
    do {
        let thread = try #require(store.thread(id))
        var staleIncarnation = thread; staleIncarnation.createdAt = thread.createdAt.addingTimeInterval(-1)
        #expect(store.canOpenTerminal(for: thread) && !store.canOpenTerminal(for: staleIncarnation))
        #expect(store.terminalEnvironment(for: thread) == [TerminalRuntimeEnvironment.projectRootKey: fixture.source.path])
        try terminals.add(for: thread)
        let idle = try #require(terminals.selected(in: id))
        try await waitTerminalUI { idle.hasIdlePrompt }
        try terminals.add(for: thread)
        let busy = try #require(terminals.selected(in: id))
        try await busy.send("sleep 30\n")
        try await waitTerminalUI { busy.hasForegroundCommand }
        try await Task.sleep(for: .milliseconds(300))
        #expect(store.openTerminalFile(fixture.source.appendingPathComponent("notes.txt").path, line: 1, column: nil, thread: thread) == nil)
        try await waitTerminalUI { fixture.editorHandoffs.plans.count == 1 }
        #expect(fixture.editorHandoffs.plans == [.defaultApplication(fixture.source.appendingPathComponent("notes.txt").resolvingSymlinksInPath())])
        #expect(store.fileNavigation == nil)
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
func terminalSplitStateSurvivesNativeSessionSettingsInBothAppearances() async throws {
    let root = try terminalFixtureRoot("terminal-session-settings"); defer { try? FileManager.default.removeItem(at: root) }
    let thread = CodingThread(project: .init(path: root.path))
    let terminals = TerminalWorkspaceStore(executable: "/bin/sh", loginShell: false)
    do {
        try terminals.add(for: thread)
        try terminals.split(for: thread, axis: .horizontal)
        let running = try #require(terminals.selected(in: thread.id))
        try await running.send("sleep 30\n")
        try await waitTerminalUI { running.hasForegroundCommand }
        let panes = terminals.sessions[thread.id, default: []].map(\.id)
        let layout = terminals.layout(for: thread.id)
        #expect(panes.count == 2 && layout.groups.count == 1)
        #expect(layout.groups.first?.sessionIDs == panes && layout.groups.first?.axis == .horizontal)
        let providerHome = root.appendingPathComponent("not-started-provider")
        let scope = ProviderSessionsScope(provider: .codex, executable: "/must-not-run", configurationDirectory: providerHome.path)
        for scheme in [ColorScheme.light, .dark] {
            let view = ScrollView { ProviderSessionsView(scope: scope, onImport: { Issue.record("Import requires an explicit action.") }).padding(20) }
                .environment(\.colorScheme, scheme)
            let controller = NSHostingController(rootView: view)
            let size = controller.sizeThatFits(in: .init(width: 600, height: 500))
            #expect(size.width <= 601 && size.height > 100 && size.height <= 501)
            #expect(terminals.layout(for: thread.id) == layout && running.lifecycle == .running)
            #expect(!FileManager.default.fileExists(atPath: providerHome.path))
        }
        #expect(TerminalActivityBadge.label(1) == "1 terminal process running. Open terminal")
        #expect(TerminalActivityBadge.label(3) == "3 terminal processes running. Open terminal")
    } catch { await closeTerminalFixture(terminals); throw error }
    await closeTerminalFixture(terminals)
}

@Test @MainActor
func retainedTerminalSizingIsBoundedFiniteAndIndependentForEachConversation() {
    let terminals = TerminalWorkspaceStore(executable: "/bin/sh", loginShell: false)
    let tall = UUID(), standard = UUID(), untouched = UUID()
    terminals.recordPanelHeight(420, threadID: tall)
    terminals.recordPanelHeight(5_000, threadID: standard)
    #expect(terminals.panelHeight(standard) == TerminalWindowArchive.panelHeightRange.upperBound)
    terminals.recordPanelHeight(-10, threadID: standard)
    #expect(terminals.panelHeight(standard) == TerminalWindowArchive.panelHeightRange.lowerBound)
    terminals.recordPanelHeight(TerminalWorkspaceStore.defaultPanelHeight, threadID: standard)
    terminals.recordPanelHeight(.nan, threadID: tall)
    terminals.recordPanelHeight(.infinity, threadID: tall)
    terminals.recordPanelHeight(421, threadID: tall)
    #expect(terminals.panelHeight(tall) == 420)
    #expect(terminals.panelHeight(standard) == TerminalWorkspaceStore.defaultPanelHeight)
    #expect(terminals.panelHeight(untouched) == TerminalWorkspaceStore.defaultPanelHeight)
    #expect(terminals.sessions.isEmpty && terminals.visibleThreads.isEmpty)
}
