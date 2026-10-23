import AppKit
import CoincideTerminal
import Darwin
import Testing

@MainActor
private func waitUntil(_ condition: () -> Bool) async throws {
    let end = ContinuousClock.now + .seconds(8)
    while !condition() {
        guard ContinuousClock.now < end else { throw StyledTimeout() }
        try await Task.sleep(for: .milliseconds(20))
    }
}
private struct StyledTimeout: Error {}

@Test func styledTerminalHistoryKeepsOnlyTextAndSGR() {
    let hostile = "ok \u{1b}[31mred\u{1b}[0m\u{1b}]52;c;Y2xpcA==\u{7}\u{1b}[6n\u{1b}[?1049h\u{1b}P+q544e\u{1b}\\\u{1b}[38;2;1;2;3mtrue\u{1b}[0m\r\n\u{7}end"
    let clean = TerminalStyledText.sanitized(hostile)
    #expect(clean.contains("\u{1b}[31mred\u{1b}[0m") && clean.contains("\u{1b}[38;2;1;2;3mtrue"))
    #expect(!clean.contains("\u{1b}]") && !clean.contains("\u{1b}[6n") && !clean.contains("\u{1b}[?1049h") && !clean.contains("\u{1b}P"))
    #expect(!clean.contains("\u{7}") && !clean.contains("\r"))
    #expect(TerminalStyledText.sanitized(clean) == clean)
    #expect(TerminalStyledText.plainText(clean) == "ok redtrue\nend")
    #expect(!TerminalStyledText.plainText(clean).contains("\u{1b}"))
    let long = String(repeating: "line ✓\n", count: 200_000)
    let bounded = TerminalStyledText.bounded(long)
    #expect(bounded.utf8.count <= TerminalStyledText.byteLimit && bounded.hasPrefix("line ✓") && bounded.hasSuffix("line ✓\n"))
}

@Test @MainActor func restoredTerminalReplaysStyledHistoryWithoutQueriesOrProcesses() throws {
    let root = FileManager.default.temporaryDirectory
    let styled = "plain \u{1b}[0;1;31mBOLD_RED\u{1b}[0m after\nsecond \u{1b}[0;32mGREEN\u{1b}[0m"
    let archive = TerminalTabArchive(id: UUID(), threadID: UUID(), workspacePath: root.path, directory: root.path, title: "zsh",
        text: "plain BOLD_RED after\nsecond GREEN", isCommand: false, exitCode: nil, styledText: styled + "\u{1b}[6n\u{1b}]0;x\u{7}", ordinal: 2)
    #expect(archive.styledText == styled, "Archive construction removes whole query and OSC sequences.")
    let restored = LocalTerminalSession(restoring: archive)
    #expect(restored.isRestored && restored.detachment == .restart && restored.processID == 0 && restored.ordinal == 2)
    #expect(restored.visibleText.contains("plain BOLD_RED after") && restored.visibleText.contains("second GREEN"))
    let snapshot = try #require(restored.view.terminalContentSnapshot(region: .history(maximumScrollbackRows: 100), buffer: .normal))
    let red = try #require(snapshot.rows.flatMap(\.cells).first { $0.text == "B" })
    #expect(red.attribute.style.contains(.bold) && red.attribute.fg == .ansi256(code: 1))
    // Re-archiving a restored tab without new output keeps the saved styled text.
    #expect(restored.archive(threadID: archive.threadID, workspacePath: root.path).styledText == archive.styledText)
    let idle = TerminalTabArchive(id: UUID(), threadID: UUID(), workspacePath: root.path, directory: root.path, title: "T",
                                  text: "kept", isCommand: false, exitCode: 0, closedWhileIdle: true)
    #expect(LocalTerminalSession(restoring: idle).detachment == .idle)
}

@Test(.timeLimit(.minutes(1))) @MainActor
func liveTerminalArchivesStyledHistoryAndResumesAFreshShellInTheSameTab() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("coincide-styled-\(UUID())")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let live = try LocalTerminalSession(directory: root, executable: "/bin/sh", arguments: [], ordinal: 1)
    try await live.send("printf '\\033[1;35mSTYLED_MARKER\\033[0m done\\n'; exit 4\n")
    try await waitUntil { live.lifecycle == .exited(4) }
    let archive = live.archive(threadID: UUID(), workspacePath: root.path)
    let styled = try #require(archive.styledText)
    #expect(styled.contains("\u{1b}[0;1;35mSTYLED_MARKER") && archive.text.contains("STYLED_MARKER done"))
    #expect(archive.ordinal == 1 && TerminalStyledText.sanitized(styled) == styled)

    let restored = LocalTerminalSession(restoring: archive)
    let id = restored.id, generation = restored.displayGeneration
    try restored.resumeShell(executable: "/bin/sh", arguments: [], environmentOverrides: ["COINCIDE_RESUMED": "yes"])
    #expect(restored.id == id && restored.displayGeneration != generation && !restored.isRestored)
    #expect(restored.lifecycle == .running && restored.processID > 0)
    try await restored.send("printf 'RESUMED_%s\\n' \"$COINCIDE_RESUMED\"; pwd\n")
    try await waitUntil { restored.visibleText.contains("RESUMED_yes") }
    let text = String(decoding: restored.view.getBufferAsData(kind: .normal), as: UTF8.self)
    #expect(text.contains("STYLED_MARKER done") && text.contains("Restored output"))
    #expect(restored.visibleText.contains(root.lastPathComponent))
    restored.close(); await restored.waitForClose()
    #expect(throws: (any Error).self, "Script tabs never start a shell again.") {
        try LocalTerminalSession(restoring: .init(id: UUID(), threadID: UUID(), workspacePath: root.path, directory: root.path,
            title: "Build", text: "x", isCommand: true, exitCode: 0)).resumeShell(executable: "/bin/sh", arguments: [])
    }
}

@Test(.timeLimit(.minutes(1))) @MainActor
func terminalShellFallsBackFromAnUnavailableExecutable() async throws {
    let session = try LocalTerminalSession(directory: FileManager.default.temporaryDirectory, executable: "/does/not/exist/\(UUID())", arguments: [])
    defer { session.close() }
    #expect(session.lifecycle == .running && session.processID > 0)
    #expect(session.shellPath.map { FileManager.default.isExecutableFile(atPath: $0) } == true)
    try await session.send("printf 'FALLBACK_SHELL_OK\\n'\n")
    try await waitUntil { session.visibleText.contains("FALLBACK_SHELL_OK\n") }
}

@Test @MainActor func terminalContextMenuOffersT3ActionsAndDisablesInputForSavedOutput() throws {
    let root = FileManager.default.temporaryDirectory
    let restored = LocalTerminalSession(restoring: .init(id: UUID(), threadID: UUID(), workspacePath: root.path, directory: root.path,
        title: "Terminal", text: "saved", isCommand: false, exitCode: nil))
    var commands: [TerminalCommand] = []
    let event = try #require(NSEvent.mouseEvent(with: .rightMouseDown, location: .zero, modifierFlags: [], timestamp: 0,
        windowNumber: 0, context: nil, eventNumber: 0, clickCount: 1, pressure: 1))
    let display = try #require(restored.view.menu(for: event))
    #expect(display.items.map(\.title) == ["Copy", "Paste", "Select All", "Jump to Latest", "Clear", "Find…"])
    #expect(display.items.first { $0.title == "Paste" }?.isEnabled == false && display.items.first { $0.title == "Clear" }?.isEnabled == false)
    restored.onCommand = { _, command in commands.append(command) }
    let menu = try #require(restored.view.menu(for: event))
    let titles = menu.items.filter { !$0.isSeparatorItem }.map(\.title)
    #expect(titles.suffix(5) == ["Start Shell Here", "New Terminal", "Split Right", "Split Down", "Close Terminal"])
    #expect(menu.items.first { $0.title == "Split Down" }?.keyEquivalentModifierMask == [.command, .shift])
    for title in ["Split Right", "Close Terminal", "Start Shell Here"] {
        let item = try #require(menu.items.first { $0.title == title })
        _ = (item.target as? NSObject)?.perform(item.action, with: item)
    }
    #expect(commands == [.splitRight, .close, .resume])
}
