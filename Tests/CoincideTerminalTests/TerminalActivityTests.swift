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

private let terminalActivityFixturePrompt = "\u{1b}]133;A;cl=line\u{7}ACTIVITY_FIXTURE_PROMPT> \u{1b}]133;B\u{7}"

@Test func terminalProcessDerivationMatchesT3SubprocessRules() {
    let shell: pid_t = 100
    #expect(TerminalProcessInspector.derive(shellPID: shell, shellName: "zsh", foregroundGroup: shell, children: [shell: []], names: [:]) == .idle)
    let foreground = TerminalProcessInspector.derive(shellPID: shell, shellName: "zsh", foregroundGroup: 200,
        children: [shell: [200]], names: [200: "/opt/homebrew/bin/node"])
    #expect(foreground.hasRunningSubprocess && foreground.label == "node")
    // A background job is still a running child.
    let background = TerminalProcessInspector.derive(shellPID: shell, shellName: "zsh", foregroundGroup: shell,
        children: [shell: [300]], names: [300: "vite"])
    #expect(background == .init(hasRunningSubprocess: true, label: "vite"))
    // Prompt themes fork the shell into a same-named helper with no children.
    let promptHelper = TerminalProcessInspector.derive(shellPID: shell, shellName: "-zsh", foregroundGroup: shell,
        children: [shell: [400], 400: []], names: [400: "zsh"])
    #expect(!promptHelper.hasRunningSubprocess && promptHelper.label == nil)
    #expect(!promptHelper.canCloseWhenIdle, "The quiet display heuristic cannot authorize killing a same-named shell child.")
    #expect(TerminalProcessInspector.derive(shellPID: shell, shellName: "zsh", foregroundGroup: shell,
        children: [shell: [400], 400: [401]], names: [400: "zsh"]).hasRunningSubprocess)
    #expect(TerminalProcessActivity(hasRunningSubprocess: false, label: "ignored").label == nil)
    #expect(TerminalProcessActivity(hasRunningSubprocess: true, label: "[kworker]").label == "kworker")
    #expect(TerminalProcessActivity(hasRunningSubprocess: true, label: "/usr/local/bin/node --inspect").label == "node")
    #expect(!foreground.canCloseWhenIdle && !background.canCloseWhenIdle)
    let missingChildren = TerminalProcessInspector.derive(shellPID: shell, shellName: "zsh", foregroundGroup: shell,
        children: [:], names: [:])
    let missingForeground = TerminalProcessInspector.derive(shellPID: shell, shellName: "zsh", foregroundGroup: nil,
        children: [shell: []], names: [:])
    #expect(!missingChildren.canCloseWhenIdle && !missingForeground.canCloseWhenIdle)
    #expect(!TerminalProcessActivity(hasRunningSubprocess: false).canCloseWhenIdle)
}

@Test(.timeLimit(.minutes(1)), arguments: [false, true]) @MainActor
func terminalIdleClosureRefusesMissingOrUnprovenProcessSamples(missingSample: Bool) async throws {
    let session = try LocalTerminalSession(directory: FileManager.default.temporaryDirectory, executable: "/bin/sh", arguments: [],
        environmentOverrides: ["PS1": terminalActivityFixturePrompt])
    let native = TerminalActivityMonitor(sessions: { [session] })
    let monitor = TerminalActivityMonitor(sampler: { _ in
        missingSample ? nil : .init(hasRunningSubprocess: false)
    }, sessions: { [session] })
    do {
        try await waitForActivity { await native.idleSessions([session]).count == 1 }
        #expect(await monitor.idleSessions([session]).isEmpty)
        #expect(session.lifecycle == .running && session.processID > 0)
    } catch { native.stop(); monitor.stop(); session.close(); await session.waitForClose(); throw error }
    native.stop(); monitor.stop(); session.close(); await session.waitForClose()
}

@Test(.timeLimit(.minutes(1))) @MainActor
func terminalIdleClosureRefusesAChildlessStartupShellBlockedInABuiltinWithoutAPrompt() async throws {
    let session = try LocalTerminalSession(directory: FileManager.default.temporaryDirectory, executable: "/bin/sh",
        arguments: ["-c", "printf 'BUILTIN_%s\\n' WAITING; read waiting"])
    let monitor = TerminalActivityMonitor(sessions: { [session] })
    do {
        try await waitForActivity { session.processID > 0 && session.visibleText.contains("BUILTIN_WAITING\n") }
        await monitor.refresh()
        #expect(!session.activity.hasRunningSubprocess, "No foreground or child job can distinguish this shell builtin from a prompt.")
        #expect(!session.hasIdlePrompt)
        #expect(await monitor.idleSessions([session]).isEmpty)
        #expect(session.lifecycle == .running && session.processID > 0)
    } catch { monitor.stop(); session.close(); await session.waitForClose(); throw error }
    monitor.stop(); session.close(); await session.waitForClose()
}

@Test(.timeLimit(.minutes(1))) @MainActor
func terminalNativeTextInputHoldsThePreviousPromptUntilAChildlessBuiltinReturns() async throws {
    let session = try LocalTerminalSession(directory: FileManager.default.temporaryDirectory, executable: "/bin/sh", arguments: [],
        environmentOverrides: ["PS1": terminalActivityFixturePrompt])
    let monitor = TerminalActivityMonitor(sessions: { [session] })
    do {
        try await waitForActivity {
            let idle = await monitor.idleSessions([session])
            return session.hasIdlePrompt && idle.count == 1
        }
        let mark = session.activityMark
        session.view.insertText("read value\n", replacementRange: .init(location: NSNotFound, length: 0))
        #expect(session.activityMark > mark, "Native text input must invalidate idle admission before PTY echo arrives.")
        #expect(!session.hasIdlePrompt)
        try await waitForActivity { session.visibleText.contains("read value") }
        await monitor.refresh()
        #expect(!session.activity.hasRunningSubprocess && !session.hasForegroundCommand)
        #expect(await monitor.idleSessions([session]).isEmpty)
        #expect(session.lifecycle == .running)
        session.view.insertText("fixture value\n", replacementRange: .init(location: NSNotFound, length: 0))
        try await waitForActivity {
            let idle = await monitor.idleSessions([session])
            return session.hasIdlePrompt && idle.count == 1
        }
        #expect(session.lifecycle == .running)
    } catch { monitor.stop(); session.close(); await session.waitForClose(); throw error }
    monitor.stop(); session.close(); await session.waitForClose()
}

@Test(.timeLimit(.minutes(1))) @MainActor
func terminalInputQueuedBeforeTheFirstPromptCannotAuthorizeIdleClosure() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("coincide-terminal-startup-gate-\(UUID())")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let gate = root.appendingPathComponent("release")
    let startup = "printf 'STARTUP_GATE_READY\\n'; while [ ! -f \"$1\" ]; do sleep 0.02; done; PS1=$2; export PS1; exec /bin/sh"
    let session = try LocalTerminalSession(directory: root, executable: "/bin/sh",
        arguments: ["-c", startup, "coincide-startup-gate", gate.path, terminalActivityFixturePrompt])
    let monitor = TerminalActivityMonitor(sessions: { [session] })
    do {
        try await waitForActivity { session.visibleText.contains("STARTUP_GATE_READY\n") }
        #expect(!session.hasIdlePrompt)
        try await session.send("read value\n")
        try Data().write(to: gate)
        try await waitForActivity { session.visibleText.contains("ACTIVITY_FIXTURE_PROMPT>") }
        try await waitForActivity {
            await monitor.refresh()
            return !session.activity.hasRunningSubprocess && !session.hasForegroundCommand
        }
        #expect(!session.hasIdlePrompt, "The initial prompt cannot release input queued before any prompt was observed.")
        #expect(await monitor.idleSessions([session]).isEmpty)
        #expect(session.lifecycle == .running)
        try await session.send("fixture value\n")
        try await waitForActivity {
            let idle = await monitor.idleSessions([session])
            return session.hasIdlePrompt && idle.count == 1
        }
        #expect(session.lifecycle == .running)
    } catch { monitor.stop(); session.close(); await session.waitForClose(); throw error }
    monitor.stop(); session.close(); await session.waitForClose()
}

@Test(.timeLimit(.minutes(1))) @MainActor
func terminalActivityMonitorDetectsARunningChildAndReturnsToQuiet() async throws {
    let session = try LocalTerminalSession(directory: FileManager.default.temporaryDirectory, executable: "/bin/sh", arguments: [],
        environmentOverrides: ["PS1": terminalActivityFixturePrompt])
    defer { session.close() }
    let monitor = TerminalActivityMonitor(interval: .milliseconds(50), quietSampleEvery: 3, sessions: { [session] })
    try await session.send("sleep 30\n")
    try await waitForActivity { await monitor.refresh(); return session.activity.hasRunningSubprocess }
    #expect(session.activity.label == "sleep" && session.isBusy && session.displayTitle == "sleep")
    try await session.send("\u{3}")
    try await waitForActivity { await monitor.refresh(); return !session.activity.hasRunningSubprocess && session.hasIdlePrompt }
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
