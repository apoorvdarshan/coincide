import AppKit
import CoincideKit
import Testing

@testable import Coincide

/// The command-aware terminal: the shell integration's prompt and command marks (OSC 133), jumping between commands
/// and finding the last command's output. Shells run in a scratch home with no dotfiles; no window is shown.
@MainActor
@Suite(.serialized)
struct TerminalCommandTests {
    // MARK: Launch

    @Test func zshStartsThroughCoincidesZDOTDIRAndKeepsTheUsersOwn() throws {
        let folder = TemporaryDirectory("shell-integration")
        let plain = ShellIntegration.launch(shell: "/bin/zsh", environment: [:], folder: folder.url)
        #expect(plain.execName == "-zsh")
        #expect(plain.arguments.isEmpty)
        let zdotdir = try #require(plain.environment["ZDOTDIR"])
        #expect(FileManager.default.fileExists(atPath: zdotdir + "/.zshenv"))
        #expect(FileManager.default.fileExists(atPath: zdotdir + "/coincide-integration.zsh"))
        #expect(plain.environment["COINCIDE_ZSH_ZDOTDIR"] == nil)

        let own = ShellIntegration.launch(shell: "/bin/zsh", environment: ["ZDOTDIR": "/Users/me/.config/zsh"], folder: folder.url)
        #expect(own.environment["COINCIDE_ZSH_ZDOTDIR"] == "/Users/me/.config/zsh")
        let mode = try FileManager.default.attributesOfItem(atPath: zdotdir + "/.zshenv")[.posixPermissions] as? NSNumber
        #expect(mode?.intValue == 0o600)
    }

    @Test func bashReadsTheIntegrationAsItsRcFileAndOtherShellsStartAsBefore() {
        let folder = TemporaryDirectory("shell-integration")
        let bash = ShellIntegration.launch(shell: "/opt/homebrew/bin/bash", environment: [:], folder: folder.url)
        #expect(bash.arguments.first == "--rcfile")
        #expect(bash.arguments.last == "-i")
        #expect(FileManager.default.fileExists(atPath: bash.arguments[1]))
        #expect(bash.environment.isEmpty)

        let fish = ShellIntegration.launch(shell: "/opt/homebrew/bin/fish", environment: [:], folder: folder.url)
        #expect(fish == ShellIntegration.Launch(arguments: [], execName: "-fish", environment: [:]))
    }

    @Test func aFolderThatCantBeWrittenFallsBackToThePlainLoginShell() throws {
        let folder = TemporaryDirectory("shell-integration")
        let blocked = folder.url.appendingPathComponent("blocked")
        try Data().write(to: blocked)  // A file where the folder should be.
        let launch = ShellIntegration.launch(shell: "/bin/zsh", environment: [:], folder: blocked)
        #expect(launch == ShellIntegration.Launch(arguments: [], execName: "-zsh", environment: [:]))
    }

    @Test func theScriptsParse() throws {
        let folder = TemporaryDirectory("shell-integration")
        let zsh = ShellIntegration.launch(shell: "/bin/zsh", environment: [:], folder: folder.url).environment["ZDOTDIR"]!
        for file in ["/.zshenv", "/coincide-integration.zsh"] {
            #expect(try Self.run("/bin/zsh", ["-n", zsh + file]).status == 0, "\(file) doesn't parse")
        }
        let bash = ShellIntegration.launch(shell: "/bin/bash", environment: [:], folder: folder.url).arguments[1]
        #expect(try Self.run("/bin/bash", ["-n", bash]).status == 0)
    }

    private static func run(_ executable: String, _ arguments: [String]) throws -> (status: Int32, output: String) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        try process.run()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return (process.terminationStatus, String(decoding: data, as: UTF8.self))
    }

    // MARK: Live shells

    /// Starts `shell` with the integration in a scratch home, waits for its first prompt mark and runs `command`.
    private func runInShell(_ shell: String, _ command: String) async throws -> (ShellTerminalView, TemporaryDirectory) {
        let home = TemporaryDirectory("shell-integration-home")
        let launch = ShellIntegration.launch(shell: shell, environment: [:], folder: home.url.appendingPathComponent(".coincide"))
        var environment = ["HOME": home.url.path, "PATH": "/usr/bin:/bin", "TERM": "xterm-256color", "LANG": "en_US.UTF-8"]
        environment.merge(launch.environment) { _, new in new }
        let terminal = ShellTerminalView(font: Theme.monoFont)
        terminal.startProcess(
            executable: shell, args: launch.arguments, environment: environment.map { "\($0.key)=\($0.value)" },
            execName: launch.execName, currentDirectory: home.url.path)
        for _ in 0..<200 where !terminal.commands.hasMarks {
            try await Task.sleep(for: .milliseconds(25))
        }
        try #require(terminal.commands.hasMarks, "\(shell) never marked a prompt")
        terminal.send(txt: command + "\r")
        for _ in 0..<200 where terminal.commands.command != command || terminal.commands.isRunning {
            try await Task.sleep(for: .milliseconds(25))
        }
        // The next prompt's mark comes after the output.
        try await Task.sleep(for: .milliseconds(200))
        return (terminal, home)
    }

    @Test(arguments: ["/bin/zsh", "/bin/bash"])
    func aShellReportsItsCommandsAndTheirOutputIsFound(shell: String) async throws {
        let (terminal, home) = try await runInShell(shell, "printf 'first\\nsecond\\n'")
        defer {
            terminal.terminate()
            _ = home
        }
        #expect(terminal.commands.command == "printf 'first\\nsecond\\n'")
        #expect(terminal.commands.exitStatus == 0)
        let snapshot = terminal.terminalContentSnapshot(region: .history(maximumScrollbackRows: 100), buffer: .normal)
        let dump = (snapshot?.rows.map { "\($0.absoluteRow)\($0.isWrapped ? "w" : ""): \($0.text)" } ?? []).joined(separator: "\n")
        let output = try #require(
            terminal.lastCommandOutput(),
            "cursor \(snapshot?.cursorRow ?? -1), prompt lines \(terminal.commands.promptLines)\n\(dump)")
        #expect(output == "$ printf 'first\\nsecond\\n'\nfirst\nsecond")
    }

    @Test func zshPutsBackTheUsersZDOTDIR() async throws {
        let (terminal, home) = try await runInShell("/bin/zsh", "echo \"zdotdir=[$ZDOTDIR]\"")
        defer {
            terminal.terminate()
            _ = home
        }
        #expect(terminal.lastCommandOutput()?.hasSuffix("zdotdir=[]") == true)
    }

    // MARK: Marks

    @Test func marksUpdateTheCommandState() {
        var state = TerminalCommandState()
        func apply(_ code: Int, _ payload: String) -> Bool { state.apply(code: code, payload: Array(payload.utf8)) }
        #expect(apply(133, "A"))
        #expect(state.hasMarks && !state.isRunning)
        #expect(apply(1337, "CoincidePrompt=2"))
        #expect(state.promptLines == 2)
        #expect(apply(1337, "CoincideCommand=swift test"))
        #expect(apply(133, "C"))
        #expect(state.isRunning && state.command == "swift test")
        #expect(apply(133, "D;1"))
        #expect(!state.isRunning && state.exitStatus == 1)
        // Other sequences are left alone.
        #expect(!apply(0, "title"))
        #expect(!apply(1337, "File=inline=1"))
        #expect(apply(1337, "CoincidePrompt=9999"))
        #expect(state.promptLines == 50)
    }

    // MARK: Finding output

    private func lines(_ texts: [String]) -> [TerminalCommandOutput.Line] {
        TerminalCommandOutput.lines(texts.enumerated().map { ($0.element, $0.offset, false) })
    }

    @Test func theLastCommandsOutputRunsFromItsLineToTheNextPrompt() {
        let screen = lines(["~/repo $ ls", "README.md", "~/repo $ swift test", "Building…", "error: boom", "", "~/repo $ "])
        let output = TerminalCommandOutput.lastOutput(lines: screen, cursorRow: 6, promptLines: 1, command: "swift test", isRunning: false)
        #expect(output == "$ swift test\nBuilding…\nerror: boom")
    }

    @Test func aTwoLinePromptStaysOutOfTheOutput() {
        let screen = lines(["~/repo on main", "❯ make", "ok", "~/repo on main", "❯ "])
        let output = TerminalCommandOutput.lastOutput(lines: screen, cursorRow: 4, promptLines: 2, command: "make", isRunning: false)
        #expect(output == "$ make\nok")
    }

    @Test func aRunningCommandsOutputRunsToTheCursor() {
        let screen = lines(["$ npm run dev", "ready on :3000", "compiled"])
        let output = TerminalCommandOutput.lastOutput(lines: screen, cursorRow: 2, promptLines: 1, command: "npm run dev", isRunning: true)
        #expect(output == "$ npm run dev\nready on :3000\ncompiled")
    }

    @Test func aWrappedCommandLineIsStillFound() {
        let rows: [(text: String, row: Int, isWrapped: Bool)] = [
            ("$ echo a-very-long-arg", 10, false), ("ument", 11, true), ("a-very-long-argument", 12, false), ("$ ", 13, false),
        ]
        let output = TerminalCommandOutput.lastOutput(
            lines: TerminalCommandOutput.lines(rows), cursorRow: 13, promptLines: 1, command: "echo a-very-long-argument",
            isRunning: false)
        #expect(output == "$ echo a-very-long-argument\na-very-long-argument")
    }

    @Test func aCommandThatLeftTheScrollbackHasNoOutput() {
        let screen = lines(["line 1", "line 2", "$ "])
        #expect(TerminalCommandOutput.lastOutput(lines: screen, cursorRow: 2, promptLines: 1, command: "cat big.log", isRunning: false) == nil)
        #expect(TerminalCommandOutput.lastOutput(lines: screen, cursorRow: 2, promptLines: 1, command: "  ", isRunning: false) == nil)
    }

    // MARK: Keys

    private static func key(_ characters: String, keyCode: UInt16, flags: NSEvent.ModifierFlags) -> NSEvent {
        NSEvent.keyEvent(
            with: .keyDown, location: .zero, modifierFlags: flags, timestamp: 0, windowNumber: 0, context: nil,
            characters: characters, charactersIgnoringModifiers: characters, isARepeat: false, keyCode: keyCode)!
    }

    @Test func commandArrowsAndSendAreLeftAloneWithoutMarks() {
        let terminal = ShellTerminalView(font: Theme.monoFont)
        var sent = 0
        terminal.onSendLastCommand = { sent += 1 }
        #expect(!terminal.handleKeyDown(Self.key("\u{F700}", keyCode: 126, flags: .command)))
        #expect(!terminal.handleKeyDown(Self.key("l", keyCode: 37, flags: [.command, .shift])))
        #expect(sent == 0)
        #expect(KeyBindingsController.terminalKeys.contains { $0.shortcuts.contains(KeyShortcut("mod+arrowup")!) })
        #expect(KeyBindingsController.terminalKeys.contains { $0.shortcuts.contains(KeyShortcut("mod+shift+l")!) })
    }

    @Test func liveShellMarksEnableJumpingAndSending() async throws {
        let (terminal, home) = try await runInShell("/bin/zsh", "echo marked")
        defer {
            terminal.terminate()
            _ = home
        }
        var sent = 0
        terminal.onSendLastCommand = { sent += 1 }
        #expect(terminal.handleKeyDown(Self.key("\u{F700}", keyCode: 126, flags: .command)))
        #expect(terminal.handleKeyDown(Self.key("\u{F701}", keyCode: 125, flags: .command)))
        #expect(terminal.handleKeyDown(Self.key("l", keyCode: 37, flags: [.command, .shift])))
        #expect(sent == 1)
    }
}
