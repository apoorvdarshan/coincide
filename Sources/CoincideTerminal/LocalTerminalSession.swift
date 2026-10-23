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
    public let id: UUID
    public let directory: String
    public let isRestored: Bool
    public private(set) var title = "Terminal"
    public private(set) var lifecycle = TerminalLifecycle.running
    @ObservationIgnored public let view: LocalProcessTerminalView
    @ObservationIgnored private var closeTask: Task<Void, Never>?
    @ObservationIgnored private let commandTitle: String?

    public init(directory: URL, executable: String? = nil, arguments: [String] = ["-l"],
                environmentOverrides: [String: String] = [:], unsetEnvironment: Set<String> = [], commandTitle: String? = nil) throws {
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: directory.path, isDirectory: &isDirectory), isDirectory.boolValue else {
            throw CoincideError("The terminal workspace folder is unavailable.")
        }
        let requested = executable ?? ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh"
        guard let shell = ProcessChannel.findExecutable(requested) else { throw CoincideError("The selected shell is unavailable.") }
        id = UUID(); isRestored = false
        self.directory = directory.standardizedFileURL.path
        self.commandTitle = commandTitle.map(Self.cleanTitle)
        if let commandTitle = self.commandTitle { title = commandTitle }
        view = Self.makeView()
        view.processDelegate = self
        var environment = ProcessChannel.environment()
        for key in unsetEnvironment { environment.removeValue(forKey: key) }
        environment.merge(environmentOverrides) { _, new in new }
        environment["TERM"] = "xterm-256color"
        environment["COLORTERM"] = "truecolor"
        environment["PWD"] = self.directory
        ProcessChannel.withChildLaunch {
            view.startProcess(executable: shell.path, args: arguments,
                              environment: environment.map { "\($0.key)=\($0.value)" }, currentDirectory: self.directory)
        }
    }

    /// Restoring display output never starts a process, runs a command or sends
    /// saved terminal control sequences back through a PTY.
    public init(restoring archive: TerminalTabArchive) {
        id = archive.id; directory = archive.directory; isRestored = true
        let savedTitle = Self.cleanTitle(archive.title)
        title = savedTitle
        commandTitle = archive.isCommand ? savedTitle : nil
        lifecycle = .exited(archive.exitCode)
        view = Self.makeView(); view.processDelegate = self
        view.feed(text: TerminalTabArchive.displayText(archive.text).replacingOccurrences(of: "\n", with: "\r\n"))
    }

    private static func makeView() -> LocalProcessTerminalView {
        var options = TerminalOptions(); options.scrollback = 5_000
        let view = WorkspaceTerminalView(frame: CGRect(x: 0, y: 0, width: 800, height: 260),
            font: .monospacedSystemFont(ofSize: 12, weight: .regular), options: options)
        view.nativeForegroundColor = .textColor; view.nativeBackgroundColor = .textBackgroundColor
        view.setAccessibilityLabel("Workspace terminal")
        return view
    }

    public func archive(threadID: UUID, workspacePath: String) -> TerminalTabArchive {
        let code: Int32? = if case .exited(let code) = lifecycle { code } else { nil }
        return .init(id: id, threadID: threadID, workspacePath: workspacePath, directory: directory,
            title: title, text: String(decoding: view.getBufferAsData(kind: .normal), as: UTF8.self),
            isCommand: isCommand, exitCode: code)
    }

    /// Focuses the terminal now, or once its view joins a window. Restoration and
    /// thread switches never call this, so they leave the composer's focus alone.
    /// - Parameter origin: the responder that had focus when the user asked; an
    ///   unknown origin (no key window) focuses on attach.
    public func requestFocus(from origin: NSResponder? = NSApp.keyWindow?.firstResponder) {
        guard let view = view as? WorkspaceTerminalView else { return }
        if let window = view.window { window.makeFirstResponder(view); return }
        view.pendingFocus = .init(origin: origin, hasOrigin: origin != nil)
    }
    /// Whether a responder is a native terminal view, for keyboard focus contexts.
    public static func isTerminalResponder(_ responder: NSResponder?) -> Bool { responder is TerminalView }

    public func showFind() {
        let item = NSMenuItem(); item.tag = Int(NSTextFinder.Action.showFindInterface.rawValue)
        view.performTextFinderAction(item)
    }

    public func setFontSize(_ size: Double) {
        let bounded = min(24, max(9, size.isFinite ? size : 12))
        guard view.font.pointSize != bounded else { return }
        view.font = .monospacedSystemFont(ofSize: bounded, weight: .regular)
    }

    public var processID: pid_t { view.process.shellPid }
    public var isCommand: Bool { commandTitle != nil }
    public var hasForegroundCommand: Bool {
        guard lifecycle == .running else { return false }
        // A shell executing a script may exec its final command into its own process
        // group. Closing that tab still needs the running-command confirmation.
        if commandTitle != nil { return true }
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
            // Keep directory ownership until SwiftTerm has observed child exit.
            // Sending SIGKILL alone does not establish that the process drained.
            // SwiftTerm clears shellPid when reaping starts, before its final
            // output drain and lifecycle callback. This session never relaunches.
            while view.process.running || view.process.windingDown {
                try? await Task.sleep(for: .milliseconds(10))
            }
            closeTask = nil
        }
    }

    /// Wait for the bounded shutdown escalation after a tab or project has been closed.
    public func waitForClose() async { await closeTask?.value }

    public func sizeChanged(source: LocalProcessTerminalView, newCols: Int, newRows: Int) {}
    public func setTerminalTitle(source: LocalProcessTerminalView, title: String) {
        guard commandTitle == nil else { return }
        self.title = Self.cleanTitle(title)
    }
    private static func cleanTitle(_ title: String) -> String {
        let clean = title.unicodeScalars.filter { !CharacterSet.controlCharacters.contains($0) }
        return clean.isEmpty ? "Terminal" : String(String.UnicodeScalarView(clean).prefix(120))
    }
    public func hostCurrentDirectoryUpdate(source: TerminalView, directory: String?) {}
    public func processTerminated(source: TerminalView, exitCode: Int32?) { lifecycle = .exited(exitCode) }
    public func processFailedToStart(source: TerminalView, error: LocalProcessError) { lifecycle = .failed("Shell could not start: \(error)") }
}

private final class WorkspaceTerminalView: LocalProcessTerminalView {
    struct PendingFocus { weak var origin: NSResponder?; let hasOrigin: Bool; let deadline = Date().addingTimeInterval(3) }
    var pendingFocus: PendingFocus?
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        // An explicit open focuses the terminal once it is attached, unless the
        // user has moved focus elsewhere (for example back to typing) meanwhile.
        guard let window, let pending = pendingFocus else { return }
        pendingFocus = nil
        let current = window.firstResponder
        guard Date() < pending.deadline, !pending.hasOrigin || current === pending.origin || current === window || current == nil else { return }
        window.makeFirstResponder(self)
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
