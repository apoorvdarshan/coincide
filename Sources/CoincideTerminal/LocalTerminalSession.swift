import AppKit
import CoincideCore
import Darwin
import Observation
import SwiftTerm

public enum TerminalLifecycle: Equatable, Sendable {
    case running, closing, exited(Int32?), failed(String)
}

/// Why a tab shows saved output without a connected shell.
public enum TerminalDetachment: String, Codable, Equatable, Sendable {
    /// Restored after a window close or app restart.
    case restart
    /// Closed at an idle prompt when its conversation settled.
    case idle
}

/// Actions from a terminal's context menu or its focused key equivalents.
public enum TerminalCommand: Equatable, Sendable {
    case newTerminal, splitRight, splitDown, close, clear, find, jumpToLatest, jumpToTop, pageUp, pageDown, resume

    /// Key equivalents handled while a terminal has keyboard focus (T3 `terminalFocus`
    /// defaults): ⌘D, ⇧⌘D, ⌘N, ⌘W, ⌘K, ⌘F, ⇧⌘Home/End and ⇧PageUp/PageDown.
    public static func keyCommand(characters: String?, modifiers: NSEvent.ModifierFlags) -> TerminalCommand? {
        let flags = modifiers.intersection([.command, .shift, .option, .control])
        guard let scalars = characters?.lowercased().unicodeScalars, scalars.count == 1, let key = scalars.first?.value else { return nil }
        let command: NSEvent.ModifierFlags = [.command], shifted: NSEvent.ModifierFlags = [.command, .shift]
        switch key {
        case 0x64 where flags == command: return .splitRight            // d
        case 0x64 where flags == shifted: return .splitDown
        case 0x6e where flags == command: return .newTerminal           // n
        case 0x77 where flags == command: return .close                 // w
        case 0x6b where flags == command: return .clear                 // k
        case 0x66 where flags == command: return .find                  // f
        case UInt32(NSEndFunctionKey) where flags == shifted: return .jumpToLatest
        case UInt32(NSHomeFunctionKey) where flags == shifted: return .jumpToTop
        case UInt32(NSPageUpFunctionKey) where flags == [.shift]: return .pageUp
        case UInt32(NSPageDownFunctionKey) where flags == [.shift]: return .pageDown
        default: return nil
        }
    }
}

/// Owns one native terminal emulator and its PTY. Hiding its view does not end the shell.
@MainActor @Observable
public final class LocalTerminalSession: Identifiable, LocalProcessTerminalViewDelegate {
    public let id: UUID
    public let directory: String
    public let workspaceIdentity: TerminalWorkspaceIdentity?
    public let originalWorkspacePath: String
    /// Saved output without a connected shell, and why.
    public private(set) var detachment: TerminalDetachment?
    public var isRestored: Bool { detachment != nil }
    /// The command name or the program-set (OSC) title.
    public private(set) var title = "Terminal"
    /// The drawer's "Terminal N" number within its conversation.
    public private(set) var ordinal: Int?
    public private(set) var lifecycle = TerminalLifecycle.running
    public private(set) var activity = TerminalProcessActivity.idle
    /// Changes when a fresh shell replaces the emulator view in this tab.
    public private(set) var displayGeneration = UUID()
    @ObservationIgnored public private(set) var view: LocalProcessTerminalView
    @ObservationIgnored public private(set) var shellPath: String?
    @ObservationIgnored private(set) var idleExecutableIdentity: TerminalShellExecutableIdentity?
    @ObservationIgnored public var onCommand: (@MainActor (LocalTerminalSession, TerminalCommand) -> Void)?
    @ObservationIgnored public var onOpenLink: (@MainActor (LocalTerminalSession, String) -> Void)?
    @ObservationIgnored public var onExit: (@MainActor (LocalTerminalSession, Int32?) -> Void)?
    /// A click in this terminal, used to make its pane the selected one.
    @ObservationIgnored public var onActivate: (@MainActor (LocalTerminalSession) -> Void)?
    @ObservationIgnored private var closeTask: Task<Void, Never>?
    @ObservationIgnored private let commandTitle: String?
    @ObservationIgnored private var programTitle: String?
    @ObservationIgnored private var reportedDirectory: String?
    @ObservationIgnored private let counter = TerminalActivityCounter()
    @ObservationIgnored private var appearance: TerminalAppearance?
    @ObservationIgnored private var appliedAppearance: AppliedAppearance?
    @ObservationIgnored private var focusRequested = false
    @ObservationIgnored private var historyCache: (mark: UInt64, history: TerminalStyledText.History)?
    @ObservationIgnored private var idleObservation: (proof: TerminalIdleProcessProof, generation: UUID, mark: UInt64)?
    @ObservationIgnored private var hasSentInput = false
    @ObservationIgnored private var blockedPromptOrigin: TerminalPromptOrigin?
    private struct AppliedAppearance: Equatable { let appearance: TerminalAppearance; let dark: Bool; let contrast: Bool }

    public init(directory: URL, executable: String? = nil, arguments: [String] = ["-l"],
                environmentOverrides: [String: String] = [:], unsetEnvironment: Set<String> = [],
                commandTitle: String? = nil, ordinal: Int? = nil, workspaceIdentity: TerminalWorkspaceIdentity? = nil) throws {
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: directory.path, isDirectory: &isDirectory), isDirectory.boolValue else {
            throw CoincideError("The terminal workspace folder is unavailable.")
        }
        id = UUID()
        let launchDirectory = directory.standardizedFileURL.path
        guard workspaceIdentity?.matchesDirectory(launchDirectory) ?? true else { throw CoincideError("This terminal workspace changed. Open a new terminal instead.") }
        self.directory = launchDirectory
        self.workspaceIdentity = workspaceIdentity
        originalWorkspacePath = workspaceIdentity?.workspacePath ?? launchDirectory
        self.commandTitle = commandTitle.map(Self.cleanTitle)
        self.ordinal = ordinal
        if let commandTitle = self.commandTitle { title = commandTitle }
        view = Self.makeView()
        attach(view)
        try launch(executable: executable, arguments: arguments, environmentOverrides: environmentOverrides, unsetEnvironment: unsetEnvironment)
    }

    /// Restoring display output never starts a process, runs a command or sends
    /// saved terminal control sequences back through a PTY. Styled history holds
    /// only text and SGR attributes (see `TerminalStyledText`).
    public init(restoring archive: TerminalTabArchive) {
        id = archive.id; directory = archive.directory; workspaceIdentity = archive.workspaceIdentity
        originalWorkspacePath = archive.workspacePath
        detachment = archive.closedWhileIdle == true ? .idle : .restart
        let savedTitle = Self.cleanTitle(archive.title)
        title = savedTitle; ordinal = archive.ordinal
        commandTitle = archive.isCommand ? savedTitle : nil
        if !archive.isCommand, savedTitle != "Terminal" { programTitle = savedTitle }
        lifecycle = .exited(archive.exitCode)
        view = Self.makeView()
        attach(view)
        let styled = archive.styledText.map(TerminalStyledText.sanitized)
        view.feed(text: (styled ?? TerminalTabArchive.displayText(archive.text)).replacingOccurrences(of: "\n", with: "\r\n"))
        if let styled { historyCache = (counter.value, .init(styled: styled, plain: archive.text)) }
    }

    private static func makeView() -> LocalProcessTerminalView {
        var options = TerminalOptions(); options.scrollback = TerminalStyledText.lineLimit
        let view = WorkspaceTerminalView(frame: CGRect(x: 0, y: 0, width: 800, height: 260),
            font: .monospacedSystemFont(ofSize: 12, weight: .regular), options: options)
        // Publish this untouched emulator through its native reset callback
        // before any process, saved output, or input can reach it. SwiftTerm's
        // initial setup need not emit a cursor/buffer callback on its own.
        view.softReset()
        view.nativeForegroundColor = .textColor; view.nativeBackgroundColor = .textBackgroundColor
        view.setAccessibilityLabel("Workspace terminal")
        TerminalKeyCommands.install()
        return view
    }

    private func attach(_ view: LocalProcessTerminalView) {
        view.processDelegate = self
        (view as? WorkspaceTerminalView)?.owner = self
        let counter = counter
        view.setProcessOutputHandler { counter.increment() }
    }

    private func launch(executable: String?, arguments: [String], environmentOverrides: [String: String], unsetEnvironment: Set<String>) throws {
        var environment = ProcessChannel.environment()
        for key in unsetEnvironment { environment.removeValue(forKey: key) }
        environment.merge(environmentOverrides) { _, new in new }
        environment["TERM"] = "xterm-256color"
        environment["COLORTERM"] = "truecolor"
        environment["PWD"] = directory
        let strings = environment.map { "\($0.key)=\($0.value)" }
        let candidates = TerminalShell.candidates(requested: executable)
        for shell in candidates {
            let idleExecutable = TerminalShellExecutableIdentity.capture(shellPath: shell)
            let result = ProcessChannel.withChildLaunch {
                view.process.startProcessChecked(executable: shell, args: arguments, environment: strings, currentDirectory: directory)
            }
            if case .success = result {
                shellPath = shell; idleExecutableIdentity = idleExecutable; lifecycle = .running; return
            }
        }
        throw CoincideError(candidates.isEmpty ? "No shell is available. Checked $SHELL, your login shell, /bin/zsh, /bin/bash and /bin/sh."
                                               : "The terminal shell could not start.")
    }

    public func archive(threadID: UUID, workspacePath: String) -> TerminalTabArchive {
        let capture = capture(threadID: threadID, workspacePath: workspacePath), history = capture.history()
        remember(history, mark: capture.mark)
        return capture.archive(history: history)
    }

    /// Archive metadata captured now; history comes from the cache or is encoded
    /// later by the caller, off the main actor when it wants.
    public func capture(threadID: UUID, workspacePath: String) -> TerminalTabCapture {
        let code: Int32? = if case .exited(let code) = lifecycle { code } else { nil }
        let mark = counter.value
        return .init(sessionID: id, threadID: threadID, workspacePath: originalWorkspacePath, directory: directory,
                     title: programTitle ?? commandTitle ?? "Terminal", isCommand: isCommand, exitCode: code, ordinal: ordinal,
                     closedWhileIdle: detachment == .idle, workspaceIdentity: workspaceIdentity, mark: mark,
                     cached: historyCache.flatMap { $0.mark == mark ? $0.history : nil }, view: view)
    }
    /// Keeps encoded history for the activity mark it was captured at.
    public func remember(_ history: TerminalStyledText.History, mark: UInt64) {
        if let historyCache, historyCache.mark >= mark { return }
        historyCache = (mark, history)
    }

    /// Styled scrollback, re-encoded only after new output.
    public func styledHistory() -> String { currentHistory().styled }

    private func currentHistory() -> TerminalStyledText.History {
        let capture = capture(threadID: id, workspacePath: directory), history = capture.history()
        remember(history, mark: capture.mark)
        return history
    }

    public func showFind() {
        let item = NSMenuItem(); item.tag = Int(NSTextFinder.Action.showFindInterface.rawValue)
        view.performTextFinderAction(item)
    }

    /// Applies font family, size and theme colors to a live or restored tab without restarting it.
    public func apply(_ appearance: TerminalAppearance) {
        let key = AppliedAppearance(appearance: appearance, dark: appearance.isDark(appearance: view.effectiveAppearance),
                                    contrast: NSWorkspace.shared.accessibilityDisplayShouldIncreaseContrast)
        self.appearance = appearance
        guard key != appliedAppearance else { return }
        appliedAppearance = key
        appearance.apply(to: view)
    }
    public func setFontSize(_ size: Double) {
        var next = appearance ?? .init(); next.fontSize = TerminalAppearance.clampedSize(size); apply(next)
    }
    fileprivate func effectiveAppearanceChanged() {
        appliedAppearance = nil
        if let appearance { apply(appearance) }
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
    /// Running a command: a script tab, or a shell with a child process (polled).
    public var isBusy: Bool { lifecycle == .running && (isCommand || activity.hasRunningSubprocess) }
    /// The tab label: script name, then the running child (T3), then a program title, then "Terminal N".
    public var displayTitle: String {
        if let commandTitle { return commandTitle }
        if lifecycle == .running, activity.hasRunningSubprocess, let label = activity.label { return label }
        if let programTitle { return programTitle }
        return ordinal.map { "Terminal \($0)" } ?? "Terminal"
    }
    public var visibleText: String { view.visibleRowsText(0..<view.terminalDimensions.rows).joined(separator: "\n") }
    /// Output batches and observed input; unchanged marks mean no observed activity.
    public var activityMark: UInt64 { counter.value }
    /// Only a supported, currently armed native OSC 133 prompt qualifies. A
    /// prior prompt remains blocked after input until a new prompt is observed.
    public var hasIdlePrompt: Bool {
        guard let prompt = (view as? WorkspaceTerminalView)?.promptReference.origin(armedOnly: true) else { return false }
        guard hasSentInput else { return true }
        guard let blockedPromptOrigin else { return false }
        return prompt != blockedPromptOrigin
    }
    fileprivate func recordInput() {
        blockedPromptOrigin = (view as? WorkspaceTerminalView)?.promptReference.origin(armedOnly: false)
        hasSentInput = true; idleObservation = nil; counter.increment()
    }

    func updateActivity(_ sample: TerminalProcessActivity) {
        if activity != sample { activity = sample }
    }
    func recordIdleObservation(_ proof: TerminalIdleProcessProof, generation: UUID, mark: UInt64) -> Bool {
        guard lifecycle == .running, !isCommand, processID == proof.pid, displayGeneration == generation,
              activityMark == mark, !hasForegroundCommand, hasIdlePrompt else { return false }
        idleObservation = (proof, generation, mark); return true
    }

    /// The directory used to resolve relative links: the foreground job's or the
    /// shell's working directory, then the last OSC 7 report, then the launch folder.
    public var currentDirectory: String {
        if lifecycle == .running, let live = TerminalProcessInspector.currentDirectory(shellPID: processID) { return live }
        return reportedDirectory ?? directory
    }

    /// Makes this terminal first responder now, or when its view next joins a window.
    /// Views are not focused merely by being shown again, so a starting or
    /// re-attached terminal does not take typing away from the composer.
    public func requestFocus() {
        if let window = view.window { window.makeFirstResponder(view) } else { focusRequested = true }
    }
    fileprivate func viewDidJoinWindow() {
        guard focusRequested, let window = view.window else { return }
        focusRequested = false; window.makeFirstResponder(view)
    }

    /// Completes when the bytes reach the PTY, not when the command finishes.
    public func send(_ text: String) async throws {
        guard lifecycle == .running else { throw CoincideError("This terminal is no longer running.") }
        recordInput()
        try await withCheckedThrowingContinuation { (result: CheckedContinuation<Void, any Error>) in
            view.process.send(data: Array(text.utf8)[...]) { response in
                switch response {
                case .success: result.resume()
                case .failure(let error): result.resume(throwing: CoincideError("Terminal input failed: \(error)"))
                }
            }
        }
    }

    /// Clears the screen the way T3 does: Ctrl-L to the shell, which redraws its prompt.
    public func clear() {
        guard lifecycle == .running else { return }
        recordInput(); view.send(data: [0x0c][...])
    }
    public func jumpToLatest() { view.scroll(toPosition: 1) }
    public func jumpToTop() { view.scroll(toPosition: 0) }

    public func close() {
        guard lifecycle == .running else { return }
        idleObservation = nil
        lifecycle = .closing
        let pid = processID
        let foreground = tcgetpgrp(view.process.childfd)
        // forkpty creates an owned session. Signal its group so foreground commands
        // do not survive a closed tab. Never signal the application's process group.
        if pid > 0, foreground > 0, foreground != pid, getsid(foreground) == pid { kill(-foreground, SIGHUP) }
        if pid > 0, getpgid(pid) == pid { kill(-pid, SIGHUP) }
        view.terminate()
        let view = view
        closeTask = Task { [self] in
            try? await Task.sleep(for: .seconds(1))
            if pid > 0, foreground > 0, foreground != pid, getsid(foreground) == pid { kill(-foreground, SIGKILL) }
            if pid > 0, view.process.shellPid == pid, view.process.running {
                if getpgid(pid) == pid { kill(-pid, SIGKILL) } else { kill(pid, SIGKILL) }
            }
            // Keep directory ownership until SwiftTerm has observed child exit.
            // Sending SIGKILL alone does not establish that the process drained.
            // SwiftTerm clears shellPid when reaping starts, before its final
            // output drain and lifecycle callback.
            while view.process.running || view.process.windingDown {
                try? await Task.sleep(for: .milliseconds(10))
            }
            closeTask = nil
        }
    }

    /// Closes the shell but keeps its output in the tab, for idle closure on Settle.
    @discardableResult public func detachIdle() -> Bool {
        guard lifecycle == .running, !isCommand, !hasForegroundCommand, hasIdlePrompt, let observed = idleObservation,
              observed.generation == displayGeneration, observed.mark == activityMark, observed.proof.pid == processID,
              tcgetpgrp(view.process.childfd) == processID,
              TerminalProcessInspector.idleProof(shellPID: processID, expectedExecutable: idleExecutableIdentity) == observed.proof else { return false }
        detachment = .idle
        close()
        return true
    }

    /// Starts a fresh shell in this tab after saved or exited output. The previous
    /// styled history stays above a dim separator; no saved command is replayed.
    /// Automatic resumption passes `focus: false` so typing stays where it is.
    public func resumeShell(executable: String? = nil, arguments: [String] = ["-l"], environmentOverrides: [String: String] = [:],
                            unsetEnvironment: Set<String> = [], focus: Bool = true) throws {
        guard !isCommand, closeTask == nil else { throw CoincideError("This terminal cannot start a new shell yet.") }
        switch lifecycle {
        case .exited, .failed: break
        case .running, .closing: throw CoincideError("This terminal is still running.")
        }
        guard workspaceIdentity?.matchesDirectory(directory) ?? true else {
            throw CoincideError("This terminal workspace changed. Open a new terminal instead.")
        }
        let history = currentHistory().styled
        let previous = view
        let next = Self.makeView()
        next.frame = previous.frame
        next.feed(text: history.replacingOccurrences(of: "\n", with: "\r\n"))
        if !history.isEmpty { next.feed(text: "\r\n\u{1b}[2m── " + String(localized: "Restored output · new shell") + " ──\u{1b}[0m\r\n") }
        previous.processDelegate = nil; (previous as? WorkspaceTerminalView)?.owner = nil
        previous.setProcessOutputHandler(nil); historyCache = nil
        view = next; attach(next)
        appliedAppearance = nil
        if let appearance { apply(appearance) }
        activity = .idle; detachment = nil; displayGeneration = UUID(); hasSentInput = false; blockedPromptOrigin = nil
        focusRequested = focus
        do { try launch(executable: executable, arguments: arguments, environmentOverrides: environmentOverrides, unsetEnvironment: unsetEnvironment) }
        catch { lifecycle = .failed(error.localizedDescription); throw error }
    }

    /// Wait for the bounded shutdown escalation after a tab or project has been closed.
    public func waitForClose() async { await closeTask?.value }

    fileprivate func perform(_ command: TerminalCommand) -> Bool {
        switch command {
        case .clear: guard lifecycle == .running else { return false }; clear()
        case .find: showFind()
        case .jumpToLatest, .jumpToTop, .pageUp, .pageDown:
            // Full-screen programs keep their navigation keys.
            if view.terminalInputStateSnapshot()?.isAlternateBuffer == true { return false }
            switch command {
            case .jumpToLatest: jumpToLatest()
            case .jumpToTop: jumpToTop()
            case .pageUp: view.pageUp()
            default: view.pageDown()
            }
        default:
            guard let onCommand else { return false }
            onCommand(self, command)
        }
        return true
    }

    fileprivate func contextMenu() -> NSMenu {
        let menu = NSMenu(title: String(localized: "Terminal"))
        func item(_ title: String, _ key: String = "", _ modifiers: NSEvent.ModifierFlags = [.command], enabled: Bool = true,
                  _ action: @escaping @MainActor () -> Void) {
            let handler = TerminalMenuAction(action)
            let item = NSMenuItem(title: title, action: #selector(TerminalMenuAction.run(_:)), keyEquivalent: key)
            item.keyEquivalentModifierMask = modifiers
            // The menu item's target is weak; its represented object keeps the handler alive.
            item.target = handler; item.representedObject = handler; item.isEnabled = enabled
            menu.addItem(item)
        }
        menu.autoenablesItems = false
        let view = view
        let end = Unicode.Scalar(UInt32(NSEndFunctionKey)).map { String(Character($0)) } ?? ""
        item(String(localized: "Copy"), "c", enabled: view.selectionActive) { view.copy(view) }
        item(String(localized: "Paste"), "v", enabled: lifecycle == .running) { view.paste(view) }
        item(String(localized: "Select All"), "a") { view.selectAll(nil) }
        item(String(localized: "Jump to Latest"), end, [.command, .shift]) { [weak self] in self?.jumpToLatest() }
        item(String(localized: "Clear"), "k", enabled: lifecycle == .running) { [weak self] in self?.clear() }
        item(String(localized: "Find…"), "f") { [weak self] in self?.showFind() }
        if onCommand != nil {
            menu.addItem(.separator())
            if isRestored || (!isCommand && lifecycle != .running && lifecycle != .closing) {
                item(String(localized: "Start Shell Here"), enabled: !isCommand) { [weak self] in _ = self?.perform(.resume) }
            }
            item(String(localized: "New Terminal"), "n") { [weak self] in _ = self?.perform(.newTerminal) }
            item(String(localized: "Split Right"), "d") { [weak self] in _ = self?.perform(.splitRight) }
            item(String(localized: "Split Down"), "d", [.command, .shift]) { [weak self] in _ = self?.perform(.splitDown) }
            menu.addItem(.separator())
            item(String(localized: "Close Terminal"), "w") { [weak self] in _ = self?.perform(.close) }
        }
        return menu
    }

    public func sizeChanged(source: LocalProcessTerminalView, newCols: Int, newRows: Int) {}
    public func setTerminalTitle(source: LocalProcessTerminalView, title: String) {
        guard source === view, commandTitle == nil else { return }
        let clean = Self.cleanTitle(title)
        programTitle = clean == "Terminal" ? nil : clean
        self.title = clean
    }
    private static func cleanTitle(_ title: String) -> String {
        let clean = title.unicodeScalars.filter { !CharacterSet.controlCharacters.contains($0) }
        return clean.isEmpty ? "Terminal" : String(String.UnicodeScalarView(clean).prefix(120))
    }
    public func hostCurrentDirectoryUpdate(source: TerminalView, directory: String?) {
        guard source === view, let directory else { return }
        let path = URL(string: directory).flatMap { $0.isFileURL ? $0.path : nil } ?? directory
        if path.hasPrefix("/"), !path.contains("\0"), path.utf8.count <= 16_384 { reportedDirectory = path }
    }
    public func processTerminated(source: TerminalView, exitCode: Int32?) {
        guard source === view else { return }
        let natural = lifecycle == .running
        lifecycle = .exited(exitCode); activity = .idle
        if natural { onExit?(self, exitCode) }
    }
    public func processFailedToStart(source: TerminalView, error: LocalProcessError) {
        guard source === view else { return }
        lifecycle = .failed("Shell could not start: \(error)")
    }
    fileprivate func activateLink(_ link: String) {
        if let onOpenLink { onOpenLink(self, link); return }
        guard case .web(let url) = TerminalLinkTarget.resolve(link, currentDirectory: currentDirectory) else { return }
        NSWorkspace.shared.open(url)
    }
}

private final class WorkspaceTerminalView: LocalProcessTerminalView {
    nonisolated let promptReference = TerminalPromptReference()
    weak var owner: LocalTerminalSession?
    nonisolated override func showCursor(source: Terminal) { promptReference.bind(source); super.showCursor(source: source) }
    nonisolated override func hideCursor(source: Terminal) { promptReference.bind(source); super.hideCursor(source: source) }
    nonisolated override func bufferActivated(source: Terminal) { promptReference.bind(source); super.bufferActivated(source: source) }
    nonisolated override func cursorStyleChanged(source: Terminal, newStyle: CursorStyle) {
        promptReference.bind(source); super.cursorStyleChanged(source: source, newStyle: newStyle)
    }
    override func send(source: TerminalView, data: ArraySlice<UInt8>) {
        guard source === self, owner?.lifecycle == .running else { return }
        if !data.isEmpty { owner?.recordInput() }
        super.send(source: source, data: data)
    }
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window != nil { owner?.viewDidJoinWindow() }
    }
    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        owner?.effectiveAppearanceChanged()
    }
    override func menu(for event: NSEvent) -> NSMenu? { owner?.contextMenu() }
    override func insertText(_ string: Any, replacementRange: NSRange) {
        guard owner?.lifecycle == .running else { return }
        owner?.recordInput()
        super.insertText(string, replacementRange: replacementRange)
    }
    override func paste(_ sender: Any) {
        guard owner?.lifecycle == .running else { return }
        owner?.recordInput()
        super.paste(sender)
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
        owner?.activateLink(link)
    }
}

/// One tab's archive data. Metadata is captured on the main actor; when the
/// history is not cached it is encoded from SwiftTerm's thread-safe content
/// snapshot, so callers may do that work off the main actor.
public struct TerminalTabCapture: @unchecked Sendable {
    public let sessionID: UUID
    let threadID: UUID, workspacePath: String, directory: String, title: String
    let isCommand: Bool, exitCode: Int32?, ordinal: Int?, closedWhileIdle: Bool
    let workspaceIdentity: TerminalWorkspaceIdentity?
    public let mark: UInt64
    let cached: TerminalStyledText.History?
    /// Used only through `terminalContentSnapshot`, which SwiftTerm documents as callable from any thread.
    let view: TerminalView

    public func history() -> TerminalStyledText.History {
        if let cached { return cached }
        return view.terminalContentSnapshot(region: .history(maximumScrollbackRows: TerminalStyledText.lineLimit), buffer: .normal)
            .map(TerminalStyledText.encode) ?? .empty
    }
    public func archive(history: TerminalStyledText.History) -> TerminalTabArchive {
        .init(id: sessionID, threadID: threadID, workspacePath: workspacePath, directory: directory, title: title,
              text: history.plain, isCommand: isCommand, exitCode: exitCode,
              styledText: history.styled.isEmpty ? nil : history.styled, ordinal: ordinal, closedWhileIdle: closedWhileIdle ? true : nil,
              workspaceIdentity: workspaceIdentity)
    }
}

/// Terminal key equivalents run before menus only while a workspace terminal
/// is the key window's first responder; everything else passes through.
@MainActor private enum TerminalKeyCommands {
    static var monitor: Any?
    static func install() {
        guard monitor == nil else { return }
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .leftMouseDown, .rightMouseDown, .otherMouseDown]) { event in
            MainActor.assumeIsolated { handle(event) } ? nil : event
        }
    }
    private static func handle(_ event: NSEvent) -> Bool {
        guard let window = event.window else { return false }
        if event.type != .keyDown {
            // Observe only: a click selects the pane, and the view still receives it.
            guard let content = window.contentView,
                  var view = content.hitTest(content.superview?.convert(event.locationInWindow, from: nil) ?? event.locationInWindow) else { return false }
            while !(view is WorkspaceTerminalView), let parent = view.superview { view = parent }
            if let terminal = view as? WorkspaceTerminalView, let owner = terminal.owner {
                // Pointer reporting and semantic-prompt clicks may send native
                // input. A selection-only press conservatively holds this prompt.
                if owner.lifecycle == .running { owner.recordInput() }
                owner.onActivate?(owner)
            }
            return false
        }
        guard window.isKeyWindow, let view = window.firstResponder as? WorkspaceTerminalView,
              let owner = view.owner else { return false }
        if let command = TerminalCommand.keyCommand(characters: event.charactersIgnoringModifiers, modifiers: event.modifierFlags),
           owner.perform(command) { return true }
        // SwiftTerm delivers keyboard bytes directly to its process adapter,
        // bypassing the TerminalView delegate. Observe before passing them on.
        if owner.lifecycle == .running { owner.recordInput() }
        return false
    }
}

@MainActor private final class TerminalMenuAction: NSObject {
    let action: @MainActor () -> Void
    init(_ action: @escaping @MainActor () -> Void) { self.action = action }
    @objc func run(_ sender: Any?) { action() }
}
