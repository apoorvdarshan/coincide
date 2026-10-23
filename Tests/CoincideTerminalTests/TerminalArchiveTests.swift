import AppKit
import CoincideTerminal
import Darwin
import Testing

private func terminalArchiveFixture() throws -> URL {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("coincide-terminal-archive-\(UUID())")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    return root
}

@Test func terminalArchiveClaimsIndependentWindowsAndPreservesSelectionAcrossRestart() async throws {
    let root = try terminalArchiveFixture(); defer { try? FileManager.default.removeItem(at: root) }
    let service = TerminalArchiveStore(root: root.appendingPathComponent("history"))
    var first = try await service.claim(), second = try await service.claim()
    #expect(first.id != second.id)
    let thread = UUID(), tab = UUID()
    first.tabs = [.init(id: tab, threadID: thread, workspacePath: root.path, directory: root.path,
                       title: "Build", text: "unique output ✓", isCommand: true, exitCode: 7)]
    first.selection = [thread: tab]; first.panelVisible = true
    try await service.save(first)
    second.tabs = [.init(id: UUID(), threadID: thread, workspacePath: root.path, directory: root.path,
                        title: "Other window", text: "second", isCommand: false, exitCode: nil)]
    try await service.save(second)
    let third = try await service.claim(); #expect(third.id != first.id && third.id != second.id)
    await service.release(first.id)
    #expect(try await service.claim() == first)
    let restarted = TerminalArchiveStore(root: root.appendingPathComponent("history"))
    let a = try await restarted.claim(), b = try await restarted.claim()
    #expect(Set([a.id, b.id]) == [first.id, second.id])
    let restored = a.id == first.id ? a : b
    #expect(restored == first)
    let attrs = try FileManager.default.attributesOfItem(atPath: root.appendingPathComponent("history/\(first.id.uuidString.lowercased()).json").path)
    #expect((attrs[.posixPermissions] as? NSNumber)?.intValue == 0o600)
    first.tabs = []; first.selection = [:]
    try await service.save(first); await service.release(first.id)
    #expect(try await service.claim().id != first.id)
}

@Test func terminalArchiveRejectsCorruptionSymlinksAndUnownedWrites() async throws {
    let root = try terminalArchiveFixture(); defer { try? FileManager.default.removeItem(at: root) }
    let history = root.appendingPathComponent("history"), service = TerminalArchiveStore(root: history)
    var archive = try await service.claim()
    archive.tabs = [.init(id: UUID(), threadID: UUID(), workspacePath: root.path, directory: root.path,
                         title: "One", text: "preserved", isCommand: false, exitCode: nil)]
    try await service.save(archive); await service.release(archive.id)
    await #expect(throws: (any Error).self) { try await service.save(archive) }
    let file = history.appendingPathComponent(archive.id.uuidString.lowercased() + ".json")
    try Data("invalid".utf8).write(to: file)
    await #expect(throws: (any Error).self) { try await service.claim() }
    #expect(try String(contentsOf: file, encoding: .utf8) == "invalid")
    try FileManager.default.removeItem(at: file)
    let sentinel = root.appendingPathComponent("sentinel")
    try Data("do not read or overwrite".utf8).write(to: sentinel)
    try FileManager.default.createSymbolicLink(at: file, withDestinationURL: sentinel)
    await #expect(throws: (any Error).self) { try await service.claim() }
    #expect(try String(contentsOf: sentinel, encoding: .utf8) == "do not read or overwrite")
}

@Test @MainActor func terminalArchiveRestoresInertOutputWithoutLaunchingOrReplayingCommands() async throws {
    let root = try terminalArchiveFixture(); defer { try? FileManager.default.removeItem(at: root) }
    let tab = TerminalTabArchive(id: UUID(), threadID: UUID(), workspacePath: root.path,
        directory: root.appendingPathComponent("folder no longer present").path, title: "Saved script",
        text: "printf replayed > MUST_NOT_EXIST\noutput ✓\n\u{1b}]52;c;Y2xpcGJvYXJk\u{7}", isCommand: true, exitCode: 9)
    let restored = LocalTerminalSession(restoring: tab)
    #expect(restored.id == tab.id && restored.isRestored && restored.processID == 0)
    #expect(restored.lifecycle == .exited(9) && !restored.hasForegroundCommand)
    #expect(restored.visibleText.contains("output ✓"))
    #expect(!restored.visibleText.contains("\u{1b}"))
    #expect(!FileManager.default.fileExists(atPath: root.appendingPathComponent("MUST_NOT_EXIST").path))
    await #expect(throws: (any Error).self) { try await restored.send("exit\n") }
    restored.close(); await restored.waitForClose()
    #expect(restored.processID == 0)
    // Search uses the actual terminal buffer, including case and whole-word options.
    #expect(restored.view.findNext("output ✓"))
    #expect(!restored.view.findNext("missing marker"))
}

@Test func terminalArchiveBoundsUnicodeOutputAndRejectsInvalidOwnership() throws {
    let text = String(repeating: "🇮🇳漢字✓", count: 40_000) + "\nTAIL"
    let clean = TerminalTabArchive.displayText(text)
    #expect(clean.utf8.count <= TerminalTabArchive.textByteLimit && clean.hasSuffix("TAIL"))
    #expect(!clean.contains("�"))
    var archive = TerminalWindowArchive()
    archive.tabs = [.init(id: UUID(), threadID: UUID(), workspacePath: "relative", directory: "/tmp",
                         title: "Test", text: "test", isCommand: false, exitCode: nil)]
    #expect(throws: (any Error).self) { try archive.validate() }
    archive.tabs = [.init(id: UUID(), threadID: UUID(), workspacePath: "/tmp", directory: "/tmp",
                         title: "Test", text: "test", isCommand: false, exitCode: nil)]
    archive.selection = [UUID(): UUID()]
    #expect(throws: (any Error).self) { try archive.validate() }
}

@Test(.timeLimit(.minutes(1))) @MainActor
func terminalArchiveCapturesPTYScrollbackThenFindsTextOutsideViewport() async throws {
    let root = try terminalArchiveFixture(); defer { try? FileManager.default.removeItem(at: root) }
    let session = try LocalTerminalSession(directory: root, executable: "/bin/sh",
        arguments: ["-c", "printf 'FIRST_ARCHIVE_MARKER\\n'; i=0; while [ $i -lt 150 ]; do printf 'line %s\\n' \"$i\"; i=$((i + 1)); done; printf 'LAST_ARCHIVE_MARKER\\n'; exit 3"], commandTitle: "Scrollback")
    defer { session.close() }
    let deadline = ContinuousClock.now + .seconds(8)
    while session.lifecycle == .running && ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(20)) }
    #expect(session.lifecycle == .exited(3))
    #expect(!session.visibleText.contains("FIRST_ARCHIVE_MARKER"))
    let archive = session.archive(threadID: UUID(), workspacePath: root.path)
    #expect(archive.text.contains("FIRST_ARCHIVE_MARKER") && archive.text.contains("LAST_ARCHIVE_MARKER"))
    let restored = LocalTerminalSession(restoring: archive)
    #expect(restored.view.findNext("FIRST_ARCHIVE_MARKER"))
    #expect(restored.visibleText.contains("FIRST_ARCHIVE_MARKER"))
    #expect(restored.view.findPrevious("LAST_ARCHIVE_MARKER"))
    #expect(restored.lifecycle == .exited(3) && restored.processID == 0)
}
