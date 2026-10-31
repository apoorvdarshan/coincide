import AppKit
import CoincideKit
import SwiftTerm
import Synchronization

/// One shell in a pseudo-terminal. It keeps running while its view is off screen.
final class TerminalSession {
    enum State: Equatable {
        case starting
        case running
        /// `code` is nil when the shell was killed by a signal or could not be started.
        case exited(code: Int32?)
    }

    let id = UUID()
    /// "Terminal N", the lowest number free in its thread when it was created.
    let number: Int
    let paneView: TerminalPaneView
    private(set) var state = State.starting
    /// The shell's current directory, followed as the user changes it.
    private(set) var directory: URL
    /// The job in the foreground, while the user runs something other than the shell itself.
    private(set) var foregroundCommand: String?

    /// Title, directory or state changed.
    var onChange: (() -> Void)?
    /// The shell exited on its own. `keepOpen` is true when it failed right after starting, so the
    /// pane stays to show why.
    var onExit: ((_ keepOpen: Bool) -> Void)?

    /// Variables added to the shell's environment, such as a project script's folders.
    private let extraEnvironment: [String: String]
    private var shellPID: pid_t = 0
    private var launchedAt = Date.distantPast
    private var pendingInput: [UInt8] = []
    private var isClosed = false
    private var refreshScheduled = false
    private var settleTimer: Timer?

    init(number: Int, directory: URL, missingDirectory: URL?, environment: [String: String] = [:]) {
        self.number = number
        self.directory = directory
        extraEnvironment = environment
        paneView = TerminalPaneView(terminalView: ShellTerminalView(font: Theme.monoFont))
        terminalView.setAccessibilityLabel(title)
        if let missingDirectory {
            let notice = String(localized: "\(missingDirectory.path) no longer exists. Starting in \(directory.path).")
            terminalView.feed(text: "\u{1b}[2m\(notice)\u{1b}[0m\r\n")
        }
        terminalView.linkDirectory = { [weak self] in self?.directory ?? FileManager.default.homeDirectoryForCurrentUser }
        terminalView.onOutput = { [weak self] in self?.scheduleRefresh() }
        terminalView.onExit = { [weak self] status in self?.shellExited(status: status) }
        terminalView.onProgressChange = { [weak self] in self?.onChange?() }
        terminalView.onInputWhileStopped = { [weak self] data in self?.inputWhileStopped(data) }
        paneView.onRestart = { [weak self] in self?.restart() }
    }

    var terminalView: ShellTerminalView { paneView.terminalView }

    var title: String { foregroundCommand ?? String(localized: "Terminal \(number)") }

    /// Running something that closing the terminal would stop.
    var isBusy: Bool { state == .running && foregroundCommand != nil }

    /// The progress the running program reports (OSC 9;4), shown on its tab.
    var progress: TerminalProgress? { terminalView.progress }

    // MARK: Lifecycle

    /// Resolves the login-shell environment, then starts the user's shell as a login shell.
    func start() {
        state = .starting
        Task { [weak self] in
            let environment = await ShellEnvironment.shared.environment()
            self?.launch(environment: environment)
        }
    }

    /// Types `command` into the shell and presses Return, once the shell is up.
    func run(_ command: String) {
        let input = Array((command + "\r").utf8)
        switch state {
        case .starting: pendingInput.append(contentsOf: input)
        case .running: terminalView.process?.send(data: input[...])
        case .exited: break
        }
    }

    func restart() {
        guard case .exited = state, !isClosed else { return }
        paneView.hideExitBanner()
        terminalView.feed(text: "\r\n")
        start()
    }

    /// Stops the shell for good: hangs it up like a closed terminal window, then reaps it.
    func close() {
        guard !isClosed else { return }
        isClosed = true
        settleTimer?.invalidate()
        guard state == .running else { return }
        let process = terminalView.process!
        TerminalProcess.hangUp(shell: shellPID, terminal: process.childfd)
        // Closes the pty and stops SwiftTerm's exit monitor; the shell is reaped here instead.
        process.terminate()
        TerminalProcess.reap(shellPID)
    }

    private func launch(environment: [String: String]) {
        guard !isClosed, state == .starting else { return }
        let shell = TerminalLaunch.shellPath
        // Prompt and command marks (ShellIntegration), for jumping between commands and sending one's output.
        let integration = ShellIntegration.launch(
            shell: shell, environment: environment, folder: ShellIntegration.folder(in: AppStore.shared.directory))
        let extra = integration.environment.merging(extraEnvironment) { _, script in script }
        TerminalLaunch.withDefaultPipeSignal {
            terminalView.startProcess(
                executable: shell, args: integration.arguments,
                environment: TerminalLaunch.environment(from: environment, directory: directory, extra: extra),
                execName: integration.execName, currentDirectory: directory.path)
        }
        let process = terminalView.process!
        guard process.running else {
            state = .exited(code: nil)
            paneView.showExitBanner(message: String(localized: "Could not start \(shell)."))
            onChange?()
            return
        }
        // Keep this terminal's pty out of shells and agents started later.
        _ = fcntl(process.childfd, F_SETFD, FD_CLOEXEC)
        shellPID = process.shellPid
        launchedAt = Date()
        state = .running
        if !pendingInput.isEmpty {
            process.send(data: pendingInput[...])
            pendingInput = []
        }
        onChange?()
    }

    private func shellExited(status: Int32) {
        guard !isClosed, state == .running else { return }
        let code = TerminalProcess.exitCode(fromWaitStatus: status)
        state = .exited(code: code)
        foregroundCommand = nil
        settleTimer?.invalidate()
        let failedToStart = code != 0 && Date().timeIntervalSince(launchedAt) < 2
        if failedToStart {
            let message =
                code.map { String(localized: "Process exited with code \($0).") } ?? String(localized: "Process terminated.")
            terminalView.feed(text: "\r\n\u{1b}[2m[\(message)]\u{1b}[0m\r\n")
            paneView.showExitBanner(message: message)
        }
        onChange?()
        onExit?(failedToStart)
    }

    private func inputWhileStopped(_ data: ArraySlice<UInt8>) {
        switch state {
        case .starting:
            // Typed before the environment resolved; the shell gets it once it starts.
            pendingInput.append(contentsOf: data)
        case .exited:
            if data.contains(13) { restart() }
        case .running:
            break
        }
    }

    // MARK: Status

    /// Re-reads the foreground job and the shell's directory.
    func refreshStatus() {
        guard state == .running, let process = terminalView.process else { return }
        let command = TerminalProcess.foregroundCommand(shell: shellPID, terminal: process.childfd)
        let current = TerminalProcess.currentDirectory(of: shellPID) ?? directory
        guard command != foregroundCommand || current != directory else { return }
        foregroundCommand = command
        directory = current
        terminalView.setAccessibilityLabel(title)
        onChange?()
    }

    /// Output usually means a job started, finished or changed directory. Coalesce bursts, then check
    /// once more after the terminal settles, for jobs that start without printing anything.
    private func scheduleRefresh() {
        guard !refreshScheduled else { return }
        refreshScheduled = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { [weak self] in
            guard let self else { return }
            self.refreshScheduled = false
            self.refreshStatus()
            self.settleTimer?.invalidate()
            self.settleTimer = Timer.scheduledTimer(withTimeInterval: 1.5, repeats: false) { [weak self] _ in
                MainActor.assumeIsolated { self?.refreshStatus() }
            }
        }
    }
}

/// What a terminal asks its controller to do, from a shortcut or the exit banner.
enum TerminalCommand {
    case newTab
    case split(TerminalTab.Layout)
    case close
    case selectTab(offset: Int)
    /// Moves focus to the previous or next pane of the tab.
    case focusPane(offset: Int)
}

/// SwiftTerm's local-process view, themed for Coincide and wired to its session.
final class ShellTerminalView: LocalProcessTerminalView, ComposerSelectionSource {
    var onOutput: (() -> Void)?
    /// Attaches the selected output to the composer's message.
    var onAddSelection: (() -> Void)?
    /// The raw `waitpid` status of the shell.
    var onExit: ((Int32) -> Void)?
    /// Input that arrived while no shell was running.
    var onInputWhileStopped: ((ArraySlice<UInt8>) -> Void)?
    var onFocus: (() -> Void)?
    var onCommand: ((TerminalCommand) -> Void)?
    var contextMenu: (() -> NSMenu?)?
    /// Relative link paths resolve against this, normally the shell's directory.
    var linkDirectory: () -> URL = { FileManager.default.homeDirectoryForCurrentUser }

    /// Whether the terminal should draw with Metal, read when it joins a window and when settings change. Tests replace it.
    static var prefersGPURendering: () -> Bool = { AppStore.shared.settings.terminalGPURendering }

    private var delegateProxy: ShellTerminalDelegate?
    private var settingsObservation: ObservationToken?
    private var oscObservation: TerminalOscObservation?
    /// What the shell integration reported: prompt marks, the last command line, whether one runs.
    private(set) var commands = TerminalCommandState()
    /// Sends the last command's output to the composer.
    var onSendLastCommand: (() -> Void)?
    /// The newest progress report (OSC 9;4), until the program removes it or goes quiet for `TerminalProgress.timeout`.
    private(set) var progress: TerminalProgress? {
        didSet { if progress != oldValue { onProgressChange?() } }
    }
    var onProgressChange: (() -> Void)?
    private var progressTimer: Timer?
    /// Opacity of the terminal's background over a translucent pane (Settings › General › Translucent terminal).
    static let translucentOpacity: CGFloat = 0.82
    /// Whether the terminal's background lets the desktop show through, read when settings change. Tests replace it.
    static var prefersTranslucency: () -> Bool = { AppStore.shared.settings.terminalTranslucentBackground }

    init(font: NSFont) {
        super.init(frame: NSRect(x: 0, y: 0, width: 640, height: 320), font: font, options: TerminalOptions(scrollback: 10_000))
        // SwiftTerm's local-process view answers OSC 52 clipboard queries with the system clipboard and
        // lets output replace it, so any program shown here (a remote host over ssh included) could read
        // or overwrite the clipboard unasked. Ignore OSC 52 entirely, as T3 Code's terminal does: the view's
        // delegate is a stand-in that passes every other call on to the view and leaves the clipboard ones to
        // SwiftTerm's defaults, which do nothing.
        let proxy = ShellTerminalDelegate(view: self)
        delegateProxy = proxy
        terminalDelegate = proxy
        // SwiftTerm parses output on its I/O thread; a batch only tells the session to look at the shell again.
        let signal = OutputSignal()
        setProcessOutputHandler { [weak self] in
            signal.post { self?.onOutput?() }
        }
        // Option composes characters as everywhere else on the Mac; the keys that need Meta are mapped below.
        optionAsMetaKey = false
        TerminalTheme.apply(to: self)
        setAccessibilityLabel(String(localized: "Terminal"))
        settingsObservation = AppStore.shared.observe { [weak self] change in
            guard change == .settings, let self else { return }
            self.updateRenderer()
            let opacity = Self.prefersTranslucency() ? Self.translucentOpacity : 1
            if self.backgroundOpacity != opacity { self.backgroundOpacity = opacity }
        }
        // The shell integration's marks arrive as OSC sequences, copied to a private queue in order.
        // OSC 9;4 progress goes to the tab as well as SwiftTerm's own bar.
        oscObservation = observeOscEvents { [weak self] event in
            guard event.code == 133 || event.code == 1337 || event.code == 9 else { return }
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard let self else { return }
                    if event.code == 9 {
                        if let report = TerminalProgress.parse(event.payload) { self.showProgress(report) }
                    } else {
                        _ = self.commands.apply(code: event.code, payload: event.payload)
                    }
                }
            }
        }
        progressBarColor = .controlAccentColor
        backgroundOpacity = Self.prefersTranslucency() ? Self.translucentOpacity : 1
    }

    /// Shows `report` (nil removes it), clearing it if no other report follows within the timeout.
    func showProgress(_ report: TerminalProgress?) {
        progressTimer?.invalidate()
        progressTimer = nil
        progress = report
        guard report != nil else { return }
        progressTimer = Timer.scheduledTimer(withTimeInterval: TerminalProgress.timeout, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated { self?.showProgress(nil) }
        }
    }

    /// The newest command line the shell integration reported, with what it printed, or nil when there is none or
    /// it has left the scrollback.
    func lastCommandOutput() -> String? {
        guard let command = commands.command,
            let snapshot = terminalContentSnapshot(region: .history(maximumScrollbackRows: 10_000), buffer: .normal)
        else { return nil }
        let lines = TerminalCommandOutput.lines(snapshot.rows.map { ($0.text, $0.absoluteRow, $0.isWrapped) })
        return TerminalCommandOutput.lastOutput(
            lines: lines, cursorRow: snapshot.cursorRow, promptLines: commands.promptLines, command: command,
            isRunning: commands.isRunning)
    }

    /// Scrolls to the previous (`offset` -1) or next prompt the shell marked; past the last, to the bottom.
    func jumpToCommand(offset: Int) {
        if let row = offset < 0 ? previousSemanticPromptRow() : nextSemanticPromptRow() {
            scrollTo(row: row)
        } else if offset > 0 {
            scrollToBottom()
        }
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    override var hasFocus: Bool {
        get { super.hasFocus }
        set {
            super.hasFocus = newValue
            if newValue { onFocus?() }
        }
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        updateRenderer()
    }

    /// Draws with SwiftTerm's Metal renderer while Settings › General › GPU rendering is on, and with Core Graphics
    /// when it is off or Metal can't start here (no device, or a pipeline that fails to build). Metal starts once the
    /// view is in a window, as SwiftTerm requires; leaving the window keeps the renderer for when it comes back.
    func updateRenderer() {
        let wanted = Self.prefersGPURendering()
        guard wanted != isUsingMetalRenderer, !wanted || window != nil else { return }
        do {
            try setUseMetal(wanted)
        } catch {
            // Core Graphics keeps drawing. Turning Metal off mid-frame reports the renderer busy; try once more then.
            if !wanted { DispatchQueue.main.async { [weak self] in try? self?.setUseMetal(false) } }
        }
    }

    override func processTerminated(_ source: LocalProcess, exitCode: Int32?) {
        onExit?(exitCode ?? 0)
    }

    override func send(source: TerminalView, data: ArraySlice<UInt8>) {
        if process.running {
            super.send(source: source, data: data)
        } else {
            onInputWhileStopped?(data)
        }
    }

    override func requestOpenLink(source: TerminalView, link: String, params: [String: String]) {
        TerminalLinks.open(link, relativeTo: linkDirectory(), from: window)
    }

    /// A bell from a terminal the user can't see (a background tab, a hidden panel) stays silent.
    var canRingBell: Bool { window != nil && !isHiddenOrHasHiddenAncestor }

    override func menu(for event: NSEvent) -> NSMenu? {
        ThemedContextMenu.show(contextMenu?(), for: event, in: window)
    }

    /// The selected text with the buffer lines it spans, counting from 1, or nil when nothing is selected. SwiftTerm no
    /// longer exposes the selection's rows, so they are found by matching the text against the buffer; they are nil
    /// when the text appears more than once or spans a wrapped line.
    func selectedLines() -> (text: String, first: Int?, last: Int?)? {
        guard let text = selectedText else { return nil }
        let buffer = String(decoding: getBufferAsData(), as: UTF8.self)
        let rows = TerminalSelectionRows.locate(text, in: buffer)
        return (text, rows.map { $0.lowerBound + 1 }, rows.map { $0.upperBound + 1 })
    }

    var addToComposerTitle: String { String(localized: "Add Selection to Composer") }

    /// The selection's text, or nil when nothing but whitespace is selected.
    var selectedText: String? {
        guard selectionActive, let text = getSelection(), text.contains(where: { !$0.isWhitespace }) else { return nil }
        return text
    }

    var canAddSelectionToComposer: Bool { onAddSelection != nil && selectedText != nil }

    func addSelectionToComposer() {
        onAddSelection?()
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        TerminalTheme.apply(to: self)
    }

    /// Clears the scrollback and asks the program to redraw, like Command-K in Terminal.
    func clear() {
        clearScrollback()
        send(txt: "\u{0c}")
    }

    func scrollToBottom() {
        scroll(toPosition: 1)
    }

    var isScrolledUp: Bool { canScroll && scrollPosition < 1 }

    // MARK: Keys

    /// Handles the keys SwiftTerm leaves to the host while this view has focus: T3 Code's terminal
    /// shortcuts and the macOS line-editing keys. Returns true when the event was used.
    func handleKeyDown(_ event: NSEvent) -> Bool {
        let flags = event.modifierFlags.intersection([.command, .option, .control, .shift])
        let key = event.charactersIgnoringModifiers?.lowercased() ?? ""
        let editsLine = process.running && !hasMarkedText() && keyboardEnhancementFlags.isEmpty

        // SwiftTerm drops input to a process that isn't running, so typing before the shell starts or after it exits
        // reaches the session here: held until the shell starts, or Return to restart it.
        if !process.running, let onInputWhileStopped, flags.isDisjoint(with: [.command, .control]), !hasMarkedText(),
            let typed = Self.typedBytes(event)
        {
            onInputWhileStopped(typed[...])
            return true
        }

        switch (flags, Int(event.keyCode)) {
        case ([.command, .option], Self.leftArrow), ([.command, .option], Self.upArrow):
            return perform(.focusPane(offset: -1))
        case ([.command, .option], Self.rightArrow), ([.command, .option], Self.downArrow):
            return perform(.focusPane(offset: 1))
        case ([.command], Self.upArrow) where commands.hasMarks:
            jumpToCommand(offset: -1)
            return true
        case ([.command], Self.downArrow) where commands.hasMarks:
            jumpToCommand(offset: 1)
            return true
        case ([.command], Self.leftArrow) where editsLine:
            send(txt: "\u{01}")
            return true
        case ([.command], Self.rightArrow) where editsLine:
            send(txt: "\u{05}")
            return true
        case ([.command], Self.deleteKey) where editsLine:
            send(txt: "\u{15}")
            return true
        case ([.option], Self.leftArrow) where editsLine:
            send(txt: "\u{1b}b")
            return true
        case ([.option], Self.rightArrow) where editsLine:
            send(txt: "\u{1b}f")
            return true
        case ([.option], Self.deleteKey) where editsLine:
            send(txt: "\u{1b}\u{7f}")
            return true
        default:
            break
        }

        switch (flags, key) {
        case ([.command], "c"), ([.command], "v"), ([.command], "a"), ([.command], "f"), ([.command], "g"),
            ([.command, .shift], "g"):
            // Prefer the menu bar so its item highlights; fall back when it has no such item.
            if NSApp.mainMenu?.performKeyEquivalent(with: event) == true { return true }
            return performEditingKey(key, shift: flags.contains(.shift))
        case ([.command], "t"), ([.command], "n"):
            return perform(.newTab)
        case ([.command], "d"):
            return perform(.split(.sideBySide))
        case ([.command, .shift], "d"):
            return perform(.split(.stacked))
        case ([.command], "w"):
            return perform(.close)
        case ([.command], "k"):
            clear()
            return true
        case ([.command, .shift], "l"):
            guard let onSendLastCommand, lastCommandOutput() != nil else { return false }
            onSendLastCommand()
            return true
        case ([.command, .shift], "["), ([.command, .shift], "{"):
            return perform(.selectTab(offset: -1))
        case ([.command, .shift], "]"), ([.command, .shift], "}"):
            return perform(.selectTab(offset: 1))
        default:
            return false
        }
    }

    private func perform(_ command: TerminalCommand) -> Bool {
        guard let onCommand else { return false }
        onCommand(command)
        return true
    }

    private func performEditingKey(_ key: String, shift: Bool) -> Bool {
        switch key {
        // Copying an empty selection would clear the clipboard.
        case "c": if selectionActive { copy(self) }
        case "v": paste(self)
        case "a": selectAll(self)
        case "f": performTextFinderAction(Self.finderItem(.showFindInterface))
        default: performTextFinderAction(Self.finderItem(shift ? .previousMatch : .nextMatch))
        }
        return true
    }

    private static func finderItem(_ action: NSTextFinder.Action) -> NSMenuItem {
        let item = NSMenuItem()
        item.tag = action.rawValue
        return item
    }

    /// The text a key press types, as the shell would receive it; nil for arrows, function keys and the like.
    static func typedBytes(_ event: NSEvent) -> [UInt8]? {
        guard let characters = event.characters, !characters.isEmpty,
            !characters.unicodeScalars.contains(where: { (0xF700...0xF8FF).contains($0.value) })
        else { return nil }
        return Array(characters.utf8)
    }

    private static let leftArrow = 123
    private static let rightArrow = 124
    private static let downArrow = 125
    private static let upArrow = 126
    private static let deleteKey = 51
}

/// `ShellTerminalView`'s SwiftTerm delegate. It passes every call on to the view except the OSC 52 clipboard ones,
/// which fall to SwiftTerm's defaults: a copy does nothing and a read is refused. The Kitty clipboard protocol stays
/// off too, as SwiftTerm leaves it unless a host opts in.
final class ShellTerminalDelegate: TerminalViewDelegate {
    private weak var view: ShellTerminalView?

    init(view: ShellTerminalView) {
        self.view = view
    }

    func sizeChanged(source: TerminalView, newCols: Int, newRows: Int) {
        view?.sizeChanged(source: source, newCols: newCols, newRows: newRows)
    }

    func setTerminalTitle(source: TerminalView, title: String) {
        view?.setTerminalTitle(source: source, title: title)
    }

    func hostCurrentDirectoryUpdate(source: TerminalView, directory: String?) {
        view?.hostCurrentDirectoryUpdate(source: source, directory: directory)
    }

    func send(source: TerminalView, data: ArraySlice<UInt8>) {
        view?.send(source: source, data: data)
    }

    func scrolled(source: TerminalView, position: Double) {
        view?.scrolled(source: source, position: position)
    }

    func requestOpenLink(source: TerminalView, link: String, params: [String: String]) {
        view?.requestOpenLink(source: source, link: link, params: params)
    }

    func bell(source: TerminalView) {
        if view?.canRingBell == true { NSSound.beep() }
    }

    func rangeChanged(source: TerminalView, startY: Int, endY: Int) {
        view?.rangeChanged(source: source, startY: startY, endY: endY)
    }

    func programStatusChanged(source: TerminalView, records: [TerminalProgramStatus]) {
        view?.programStatusChanged(source: source, records: records)
    }
}

/// Coalesces SwiftTerm's output notifications, which arrive for every parsed batch on its I/O thread, into one
/// main-thread call at a time, so a flood of output never queues a flood of main-thread work.
nonisolated final class OutputSignal: Sendable {
    private let pending = Mutex(false)

    func post(_ body: @escaping @MainActor @Sendable () -> Void) {
        let isFirst = pending.withLock { pending in
            defer { pending = true }
            return !pending
        }
        guard isFirst else { return }
        DispatchQueue.main.async {
            self.pending.withLock { $0 = false }
            MainActor.assumeIsolated { body() }
        }
    }
}

/// Finds the buffer rows a terminal selection covers from its text, for the line numbers sent with it.
enum TerminalSelectionRows {
    /// The zero-based rows of `buffer` (one per line) that `selection` spans, counting blank lines it starts or ends
    /// with. Found only when unambiguous: the selection's first non-blank line ends a row, its middle lines are whole
    /// rows and its last starts a row (trailing spaces aside), or a single line lies within one row, at exactly one
    /// place in the buffer. Nil otherwise, such as for text selected across a line the terminal wrapped.
    nonisolated static func locate(_ selection: String, in buffer: String) -> ClosedRange<Int>? {
        let lines = Self.lines(selection)
        guard let first = lines.firstIndex(where: { !$0.isEmpty }), let last = lines.lastIndex(where: { !$0.isEmpty })
        else { return nil }
        let core = Array(lines[first...last])
        var rows = Self.lines(buffer)
        if rows.last?.isEmpty == true { rows.removeLast() }
        guard core.count <= rows.count else { return nil }
        var match: Int?
        for start in 0...(rows.count - core.count) where matches(core, rows[start..<start + core.count]) {
            guard match == nil else { return nil }
            match = start
        }
        guard let match, match >= first else { return nil }
        return (match - first)...(match + core.count - 1 + (lines.count - 1 - last))
    }

    private nonisolated static func matches(_ core: [String], _ rows: ArraySlice<String>) -> Bool {
        let rows = Array(rows)
        guard core.count > 1 else { return rows[0].contains(core[0]) }
        guard rows[0].hasSuffix(core[0]), rows[rows.count - 1].hasPrefix(core[core.count - 1]) else { return false }
        return core[1..<core.count - 1].elementsEqual(rows[1..<rows.count - 1])
    }

    private nonisolated static func lines(_ text: String) -> [String] {
        text.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")
            .split(separator: "\n", omittingEmptySubsequences: false)
            .map { String($0.reversed().drop { $0 == " " || $0 == "\t" }.reversed()) }
    }
}

/// Sends key events aimed at a focused terminal through `ShellTerminalView.handleKeyDown` before the
/// menu bar or SwiftTerm see them.
enum TerminalKeyRouter {
    private static var monitor: Any?

    static func install() {
        guard monitor == nil else { return }
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            guard let terminal = event.window?.firstResponder as? ShellTerminalView else { return event }
            return terminal.handleKeyDown(event) ? nil : event
        }
    }
}

/// Holds one terminal view. The terminal never shrinks below a usable size, so collapsing the panel
/// clips it instead of reflowing the shell's output, and a floating glass bar offers a restart after
/// a failed start.
final class TerminalPaneView: NSView {
    static let minimumTerminalSize = NSSize(width: 160, height: 60)
    /// Keeps text off the pane's edges; the right side leaves room for the overlay scroller.
    private static let insets = NSEdgeInsets(top: 6, left: 8, bottom: 2, right: 2)

    let terminalView: ShellTerminalView
    var onRestart: (() -> Void)?
    private var exitBanner: (glass: FlatSurfaceView, content: NSView)?

    /// The desktop, blurred, behind a translucent terminal; nil while it is opaque.
    private(set) var material: NSVisualEffectView?
    private var settingsObservation: ObservationToken?

    init(terminalView: ShellTerminalView) {
        self.terminalView = terminalView
        super.init(frame: .zero)
        wantsLayer = true
        layer?.masksToBounds = true
        addSubview(terminalView)
        updateTranslucency()
        settingsObservation = AppStore.shared.observe { [weak self] change in
            if change == .settings { self?.updateTranslucency() }
        }
    }

    /// Puts the blurred desktop behind the terminal while Translucent terminal is on, and takes it away when off.
    func updateTranslucency() {
        let translucent = ShellTerminalView.prefersTranslucency()
        guard translucent != (material != nil) else { return }
        if translucent {
            let view = NSVisualEffectView()
            view.material = .underWindowBackground
            view.blendingMode = .behindWindow
            view.state = .followsWindowActiveState
            view.frame = bounds
            view.autoresizingMask = [.width, .height]
            addSubview(view, positioned: .below, relativeTo: terminalView)
            material = view
        } else {
            material?.removeFromSuperview()
            material = nil
        }
        needsDisplay = true
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    override var isFlipped: Bool { true }

    override var wantsUpdateLayer: Bool { true }

    override func updateLayer() {
        layer?.backgroundColor = material == nil ? TerminalTheme.background.cgColor : NSColor.clear.cgColor
    }

    override func layout() {
        super.layout()
        layoutContent()
    }

    override func resizeSubviews(withOldSize oldSize: NSSize) {
        super.resizeSubviews(withOldSize: oldSize)
        layoutContent()
    }

    private func layoutContent() {
        let insets = Self.insets
        terminalView.frame = NSRect(
            x: insets.left, y: insets.top,
            width: max(bounds.width - insets.left - insets.right, Self.minimumTerminalSize.width),
            height: max(bounds.height - insets.top - insets.bottom, Self.minimumTerminalSize.height))
        if let exitBanner {
            let size = exitBanner.content.fittingSize
            exitBanner.glass.frame = NSRect(
                x: max(8, (bounds.width - size.width) / 2), y: max(8, bounds.height - size.height - 14), width: size.width,
                height: size.height)
        }
    }

    func showExitBanner(message: String) {
        hideExitBanner()
        let label = NSTextField(labelWithString: message)
        label.font = Theme.smallFont
        label.textColor = .secondaryLabelColor
        let restart = ThemedButton(title: String(localized: "Restart"), style: .primary, target: self, action: #selector(restartShell))
        let close = ThemedButton(title: String(localized: "Close"), target: self, action: #selector(closePane))
        for button in [restart, close] {
            button.bezelStyle = .glass
            button.controlSize = .small
        }
        let stack = NSStackView(views: [label, restart, close])
        stack.spacing = 8
        stack.edgeInsets = NSEdgeInsets(top: 6, left: 14, bottom: 6, right: 8)
        let banner = FlatSurfaceView()
        banner.cornerRadius = 16
        banner.contentView = stack
        banner.setAccessibilityElement(true)
        banner.setAccessibilityRole(.group)
        banner.setAccessibilityLabel(message)
        addSubview(banner)
        exitBanner = (banner, stack)
        needsLayout = true
    }

    func hideExitBanner() {
        exitBanner?.glass.removeFromSuperview()
        exitBanner = nil
    }

    @objc private func restartShell() {
        onRestart?()
    }

    @objc private func closePane() {
        terminalView.onCommand?(.close)
    }
}
