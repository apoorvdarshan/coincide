import AppKit
import CoincideTerminal
import Darwin
import Testing

@MainActor
private func waitForActivity(_ condition: () async -> Bool) async throws {
    let end = ContinuousClock.now + .seconds(10)
    while !(await condition()) {
        guard ContinuousClock.now < end else { throw ActivityTimeout() }
        try await Task.sleep(for: .milliseconds(25))
    }
}
private struct ActivityTimeout: Error {}

@Test func terminalProcessDerivationMatchesT3SubprocessRules() {
    let shell: pid_t = 100
    #expect(TerminalProcessInspector.derive(shellPID: shell, shellName: "zsh", foregroundGroup: shell, children: [:], names: [:]) == .idle)
    let foreground = TerminalProcessInspector.derive(shellPID: shell, shellName: "zsh", foregroundGroup: 200,
        children: [shell: [200]], names: [200: "/opt/homebrew/bin/node"])
    #expect(foreground.hasRunningSubprocess && foreground.label == "node")
    // A background job is still a running child.
    let background = TerminalProcessInspector.derive(shellPID: shell, shellName: "zsh", foregroundGroup: shell,
        children: [shell: [300]], names: [300: "vite"])
    #expect(background == .init(hasRunningSubprocess: true, label: "vite"))
    // Prompt themes fork the shell into a same-named helper with no children.
    #expect(TerminalProcessInspector.derive(shellPID: shell, shellName: "-zsh", foregroundGroup: shell,
        children: [shell: [400], 400: []], names: [400: "zsh"]) == .idle)
    #expect(TerminalProcessInspector.derive(shellPID: shell, shellName: "zsh", foregroundGroup: shell,
        children: [shell: [400], 400: [401]], names: [400: "zsh"]).hasRunningSubprocess)
    #expect(TerminalProcessActivity(hasRunningSubprocess: false, label: "ignored").label == nil)
    #expect(TerminalProcessActivity(hasRunningSubprocess: true, label: "[kworker]").label == "kworker")
    #expect(TerminalProcessActivity(hasRunningSubprocess: true, label: "/usr/local/bin/node --inspect").label == "node")
}

@Test(.timeLimit(.minutes(1))) @MainActor
func terminalActivityMonitorDetectsARunningChildAndReturnsToQuiet() async throws {
    let session = try LocalTerminalSession(directory: FileManager.default.temporaryDirectory, executable: "/bin/sh", arguments: [])
    defer { session.close() }
    let monitor = TerminalActivityMonitor(interval: .milliseconds(50), quietSampleEvery: 3, sessions: { [session] })
    try await session.send("sleep 30\n")
    try await waitForActivity { await monitor.refresh(); return session.activity.hasRunningSubprocess }
    #expect(session.activity.label == "sleep" && session.isBusy && session.displayTitle == "sleep")
    try await session.send("\u{3}")
    try await waitForActivity { await monitor.refresh(); return !session.activity.hasRunningSubprocess }
    #expect(!session.isBusy)
    // Closing idle shells re-samples now and requires an unchanged activity mark.
    #expect(await monitor.idleSessions([session]).map(\.id) == [session.id])
    try await session.send("sleep 30\n")
    try await waitForActivity { await monitor.idleSessions([session]).isEmpty && session.activity.hasRunningSubprocess }
    monitor.stop()
}

@Test @MainActor func terminalActivityMonitorSkipsQuietSessionsUntilActivityChanges() async throws {
    let counter = SampleCounter()
    let session = try LocalTerminalSession(directory: FileManager.default.temporaryDirectory, executable: "/bin/sh", arguments: [])
    defer { session.close() }
    try await waitForActivity { session.processID > 0 }
    try await Task.sleep(for: .milliseconds(200))
    let monitor = TerminalActivityMonitor(quietSampleEvery: 4, sampler: { _ in counter.increment(); return .idle }, sessions: { [session] })
    let mark = session.activityMark
    for _ in 0..<2 { await monitor.refresh() }
    guard session.activityMark == mark else { return } // Late prompt output restarts the quiet window.
    #expect(counter.value == 2)
    for _ in 0..<3 { await monitor.refresh() }
    #expect(counter.value == 2, "Quiet sessions are re-sampled every fourth tick.")
    await monitor.refresh()
    #expect(counter.value == 3)
    session.clear()
    await monitor.refresh()
    #expect(counter.value == 4, "Input or output wakes sampling immediately.")
}

private final class SampleCounter: @unchecked Sendable {
    private let lock = NSLock(); private var count = 0
    func increment() { lock.withLock { count += 1 } }
    var value: Int { lock.withLock { count } }
}

@Test func terminalShellCandidatesFallBackInT3Order() {
    let candidates = TerminalShell.candidates(requested: "/does/not/exist", environment: ["SHELL": "/also/missing"], accountShell: nil)
    #expect(candidates.first == "/bin/zsh" && candidates.contains("/bin/sh"))
    #expect(Set(candidates).count == candidates.count)
    #expect(TerminalShell.candidates(requested: "/bin/sh", environment: [:], accountShell: "/bin/sh").first == "/bin/sh")
    #expect(!TerminalShell.candidates(requested: "/tmp", environment: [:], accountShell: nil).contains("/tmp"))
}

@Test func terminalKeyCommandsMatchT3FocusedTerminalDefaults() {
    #expect(TerminalCommand.keyCommand(characters: "d", modifiers: [.command]) == .splitRight)
    #expect(TerminalCommand.keyCommand(characters: "D", modifiers: [.command, .shift]) == .splitDown)
    #expect(TerminalCommand.keyCommand(characters: "n", modifiers: [.command]) == .newTerminal)
    #expect(TerminalCommand.keyCommand(characters: "w", modifiers: [.command]) == .close)
    #expect(TerminalCommand.keyCommand(characters: "k", modifiers: [.command]) == .clear)
    #expect(TerminalCommand.keyCommand(characters: "f", modifiers: [.command]) == .find)
    let end = String(Character(Unicode.Scalar(UInt32(NSEndFunctionKey))!))
    #expect(TerminalCommand.keyCommand(characters: end, modifiers: [.command, .shift, .function, .numericPad]) == .jumpToLatest)
    let pageUp = String(Character(Unicode.Scalar(UInt32(NSPageUpFunctionKey))!))
    #expect(TerminalCommand.keyCommand(characters: pageUp, modifiers: [.shift, .function]) == .pageUp)
    #expect(TerminalCommand.keyCommand(characters: "d", modifiers: [.command, .option]) == nil)
    #expect(TerminalCommand.keyCommand(characters: "c", modifiers: [.command]) == nil, "Copy stays with the responder chain.")
    #expect(TerminalCommand.keyCommand(characters: "l", modifiers: [.control]) == nil, "Ctrl-L reaches the shell.")
    #expect(TerminalCommand.keyCommand(characters: pageUp, modifiers: [.function]) == nil)
}
