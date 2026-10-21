import AppKit
import CoincideCore
import Darwin
import Observation
import SwiftTerm

public enum TerminalLifecycle: Equatable, Sendable {
    case running, closing, exited(Int32?), failed(String)
}

/// Owns one native terminal emulator and its PTY. Hiding its view does not end the shell.
@MainActor @Observable
public final class LocalTerminalSession: Identifiable, LocalProcessTerminalViewDelegate {
    public let id = UUID()
    public let directory: String
    public private(set) var title = "Terminal"
    public private(set) var lifecycle = TerminalLifecycle.running
    @ObservationIgnored public let view: LocalProcessTerminalView
    @ObservationIgnored private var closeTask: Task<Void, Never>?

    public init(directory: URL, executable: String? = nil, arguments: [String] = ["-l"]) throws {
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: directory.path, isDirectory: &isDirectory), isDirectory.boolValue else {
            throw CoincideError("The terminal workspace folder is unavailable.")
        }
        let requested = executable ?? ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh"
        guard let shell = ProcessChannel.findExecutable(requested) else { throw CoincideError("The selected shell is unavailable.") }
        self.directory = directory.standardizedFileURL.path
        var options = TerminalOptions()
        options.scrollback = 5_000
        view = WorkspaceTerminalView(frame: CGRect(x: 0, y: 0, width: 800, height: 260),
                                     font: .monospacedSystemFont(ofSize: 12, weight: .regular), options: options)
        view.nativeForegroundColor = .textColor
        view.nativeBackgroundColor = .textBackgroundColor
        view.setAccessibilityLabel("Workspace terminal")
        view.processDelegate = self
        var environment = ProcessChannel.environment()
        environment["TERM"] = "xterm-256color"
        environment["COLORTERM"] = "truecolor"
        environment["PWD"] = self.directory
        view.startProcess(executable: shell.path, args: arguments,
                          environment: environment.map { "\($0.key)=\($0.value)" }, currentDirectory: self.directory)
    }

    public var processID: pid_t { view.process.shellPid }
    public var hasForegroundCommand: Bool {
        let group = tcgetpgrp(view.process.childfd)
        return group > 0 && group != processID
    }
    public var visibleText: String { view.visibleRowsText(0..<view.terminalDimensions.rows).joined(separator: "\n") }

    /// Completes when the bytes reach the PTY, not when the command finishes.
    public func send(_ text: String) async throws {
        guard lifecycle == .running else { throw CoincideError("This terminal is no longer running.") }
        try await withCheckedThrowingContinuation { (result: CheckedContinuation<Void, any Error>) in
            view.process.send(data: Array(text.utf8)[...]) { response in
                switch response {
                case .success: result.resume()
                case .failure(let error): result.resume(throwing: CoincideError("Terminal input failed: \(error)"))
                }
            }
        }
    }

    public func close() {
        guard lifecycle == .running else { return }
        lifecycle = .closing
        let pid = processID
        let foreground = tcgetpgrp(view.process.childfd)
        // forkpty creates an owned session. Signal its group so foreground commands
        // do not survive a closed tab. Never signal the application's process group.
        if pid > 0, foreground > 0, foreground != pid, getsid(foreground) == pid { kill(-foreground, SIGHUP) }
        if pid > 0, getpgid(pid) == pid { kill(-pid, SIGHUP) }
        view.terminate()
        closeTask = Task { [self] in
            try? await Task.sleep(for: .seconds(1))
            if pid > 0, foreground > 0, foreground != pid, getsid(foreground) == pid { kill(-foreground, SIGKILL) }
            if pid > 0, processID == pid, view.process.running {
                if getpgid(pid) == pid { kill(-pid, SIGKILL) } else { kill(pid, SIGKILL) }
            }
            closeTask = nil
        }
    }

    /// Wait for the bounded shutdown escalation after a tab or project has been closed.
    public func waitForClose() async { await closeTask?.value }

    public func sizeChanged(source: LocalProcessTerminalView, newCols: Int, newRows: Int) {}
    public func setTerminalTitle(source: LocalProcessTerminalView, title: String) {
        let clean = title.unicodeScalars.filter { !CharacterSet.controlCharacters.contains($0) }
        self.title = String(String.UnicodeScalarView(clean)).isEmpty ? "Terminal" : String(String.UnicodeScalarView(clean).prefix(120))
    }
    public func hostCurrentDirectoryUpdate(source: TerminalView, directory: String?) {}
    public func processTerminated(source: TerminalView, exitCode: Int32?) { lifecycle = .exited(exitCode) }
    public func processFailedToStart(source: TerminalView, error: LocalProcessError) { lifecycle = .failed("Shell could not start: \(error)") }
}

private final class WorkspaceTerminalView: LocalProcessTerminalView {
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if let window { window.makeFirstResponder(self) }
    }
    override func isAccessibilityElement() -> Bool { true }
    override func accessibilityRole() -> NSAccessibility.Role? { .textArea }
    override func accessibilityValue() -> Any? {
        visibleRowsText(0..<terminalDimensions.rows).joined(separator: "\n")
    }
    override func accessibilityPerformPress() -> Bool {
        guard let window else { return false }
        return window.makeFirstResponder(self)
    }
    override func requestOpenLink(source: TerminalView, link: String, params: [String: String]) {
        guard let url = URL(string: link), ["http", "https"].contains(url.scheme?.lowercased() ?? "") else { return }
        NSWorkspace.shared.open(url)
    }
}
