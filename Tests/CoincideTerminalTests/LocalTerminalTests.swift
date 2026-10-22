import AppKit
import CoincideTerminal
import Darwin
import Testing

@MainActor
private func waitForTerminal(_ condition: () -> Bool) async throws {
    let end = ContinuousClock.now + .seconds(8)
    while !condition() {
        guard ContinuousClock.now < end else { throw TerminalTestTimeout() }
        try await Task.sleep(for: .milliseconds(20))
    }
}
private struct TerminalTestTimeout: Error {}

@Test(.timeLimit(.minutes(1))) @MainActor
func nativeTerminalUsesPTYWorkspaceAndPreservesFinalOutput() async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent("coincide terminal \(UUID())")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let session = try LocalTerminalSession(directory: directory, executable: "/bin/sh", arguments: [])
    defer { session.close() }
    try await session.send("test -t 0 && test -t 1 && printf 'PTY_READY\\n'; pwd; printf '\\033[32mTERMINAL_UNICODE_✓\\033[0m\\n'; exit 7\n")
    try await waitForTerminal { if case .exited = session.lifecycle { true } else { false } }
    #expect(session.lifecycle == .exited(7))
    #expect(session.visibleText.contains("PTY_READY"))
    #expect(session.visibleText.contains(directory.lastPathComponent))
    #expect(session.visibleText.contains("TERMINAL_UNICODE_✓"))
    #expect(!session.visibleText.contains("\u{1b}[32m"))
    #expect(session.view.accessibilityRole() == .textArea)
    #expect((session.view.accessibilityValue() as? String)?.contains("TERMINAL_UNICODE_✓") == true)
}

@Test(.timeLimit(.minutes(1))) @MainActor
func nativeTerminalResizesAndClosesOwnedProcess() async throws {
    let session = try LocalTerminalSession(directory: FileManager.default.temporaryDirectory, executable: "/bin/sh", arguments: [])
    defer { session.close() }
    session.view.setFrameSize(NSSize(width: 920, height: 380))
    let size = session.view.terminalDimensions
    try await session.send("stty size; printf 'RESIZE_DONE\\n'\n")
    try await waitForTerminal { session.visibleText.contains("RESIZE_DONE\n") }
    #expect(session.visibleText.contains("\(size.rows) \(size.cols)"))
    let pid = session.processID
    #expect(pid > 0)
    session.close(); session.close()
    try await waitForTerminal { if case .exited = session.lifecycle { true } else { false } }
    #expect(kill(pid, 0) == -1)
    await #expect(throws: (any Error).self) { try await session.send("echo unexpected\n") }
}

@Test @MainActor func nativeTerminalRejectsUnavailableWorkspace() {
    #expect(throws: (any Error).self) {
        try LocalTerminalSession(directory: URL(fileURLWithPath: "/does-not-exist/\(UUID())"))
    }
}

@Test(.timeLimit(.minutes(1))) @MainActor
func nativeTerminalInterruptKeepsShellAndCloseStopsForegroundJob() async throws {
    let session = try LocalTerminalSession(directory: FileManager.default.temporaryDirectory, executable: "/bin/sh", arguments: [])
    defer { session.close() }
    try await session.send("sleep 30\n")
    try await waitForTerminal { session.hasForegroundCommand }
    try await session.send("\u{3}")
    try await session.send("printf 'INTERRUPTED_OK\\n'\n")
    try await waitForTerminal { session.visibleText.contains("INTERRUPTED_OK\n") }
    #expect(session.lifecycle == .running)
    try await session.send("sleep 30\n")
    try await waitForTerminal { session.hasForegroundCommand }
    let child = tcgetpgrp(session.view.process.childfd)
    #expect(child > 0 && child != session.processID)
    session.close()
    try await waitForTerminal { kill(child, 0) == -1 }
}

@Test(.timeLimit(.minutes(1))) @MainActor
func commandTerminalUsesLiteralShellArgumentEnvironmentAndRetainsExitStatus() async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent("coincide command ' space \(UUID())")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let command = #"printf '%s\n' "$PWD" "$COINCIDE_SCRIPT_LITERAL" > 'result with spaces.txt'; printf '\033]0;Changed title\007SCRIPT_FINISHED\n'; exit 9"#
    let session = try LocalTerminalSession(directory: directory, executable: "/bin/sh", arguments: ["-c", command],
        environmentOverrides: ["COINCIDE_SCRIPT_LITERAL": "literal ' $(not evaluated) space"], commandTitle: "Fixture\nscript")
    defer { session.close() }
    try await waitForTerminal { if case .exited = session.lifecycle { true } else { false } }
    #expect(session.lifecycle == .exited(9) && session.isCommand && !session.hasForegroundCommand)
    #expect(session.title == "Fixturescript" && session.visibleText.contains("SCRIPT_FINISHED"))
    let result = try String(contentsOf: directory.appendingPathComponent("result with spaces.txt"), encoding: .utf8)
    #expect(result == directory.resolvingSymlinksInPath().path + "\nliteral ' $(not evaluated) space\n")
}

@Test(.timeLimit(.minutes(1))) @MainActor
func commandTerminalCloseRecognizesExecInItsOwnForegroundProcessGroup() async throws {
    let session = try LocalTerminalSession(directory: FileManager.default.temporaryDirectory, executable: "/bin/sh",
        arguments: ["-c", "printf 'COMMAND_OWN_GROUP_READY\\n'; exec sleep 120"], commandTitle: "Long script")
    defer { session.close() }
    try await waitForTerminal { session.visibleText.contains("COMMAND_OWN_GROUP_READY") }
    #expect(session.hasForegroundCommand, "A command exec'd into the shell's group must still require confirmation before closing.")
    let pid = session.processID
    session.close(); await session.waitForClose()
    try await waitForTerminal { if case .exited = session.lifecycle { true } else { false } }
    #expect(kill(pid, 0) == -1)
}
