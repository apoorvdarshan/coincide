import AppKit
import CoincideKit
import SwiftTerm

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

    private var shellPID: pid_t = 0
    private var launchedAt = Date.distantPast
    private var pendingInput: [UInt8] = []
    private var isClosed = false
    private var refreshScheduled = false
    private var settleTimer: Timer?

    init(number: Int, directory: URL, missingDirectory: URL?) {
        self.number = number
        self.directory = directory
        paneView = TerminalPaneView(terminalView: ShellTerminalView(font: Theme.monoFont))
        terminalView.setAccessibilityLabel(title)
        if let missingDirectory {
            let notice = String(localized: "\(missingDirectory.path) no longer exists. Starting in \(directory.path).")
            terminalView.feed(text: "\u{1b}[2m\(notice)\u{1b}[0m\r\n")
        }
        terminalView.linkDirectory = { [weak self] in self?.directory ?? FileManager.default.homeDirectoryForCurrentUser }
        terminalView.onOutput = { [weak self] in self?.scheduleRefresh() }
        terminalView.onExit = { [weak self] status in self?.shellExited(status: status) }
        terminalView.onInputWhileStopped = { [weak self] data in self?.inputWhileStopped(data) }
        paneView.onRestart = { [weak self] in self?.restart() }
    }

    var terminalView: ShellTerminalView { paneView.terminalView }

    var title: String { foregroundCommand ?? String(localized: "Terminal \(number)") }

    /// Running something that closing the terminal would stop.
    var isBusy: Bool { state == .running && foregroundCommand != nil }

    // MARK: Lifecycle

    /// Resolves the login-shell environment, then starts the user's shell as a login shell.
    func start() {
        state = .starting
        Task { [weak self] in
            let environment = await ShellEnvironment.shared.environment()
            self?.launch(environment: environment)
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
        let loginName = "-" + (shell as NSString).lastPathComponent
        TerminalLaunch.withDefaultPipeSignal {
            terminalView.startProcess(
                executable: shell, args: [], environment: TerminalLaunch.environment(from: environment, directory: directory),
                execName: loginName, currentDirectory: directory.path)
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
final class ShellTerminalView: LocalProcessTerminalView {
    var onOutput: (() -> Void)?
    /// The raw `waitpid` status of the shell.
    var onExit: ((Int32) -> Void)?
    /// Input that arrived while no shell was running.
    var onInputWhileStopped: ((ArraySlice<UInt8>) -> Void)?
    var onFocus: (() -> Void)?
    var onCommand: ((TerminalCommand) -> Void)?
    var contextMenu: (() -> NSMenu?)?
    /// Relative link paths resolve against this, normally the shell's directory.
    var linkDirectory: () -> URL = { FileManager.default.homeDirectoryForCurrentUser }

    init(font: NSFont) {
        super.init(frame: NSRect(x: 0, y: 0, width: 640, height: 320), font: font, options: TerminalOptions(scrollback: 10_000))
        // SwiftTerm's local-process view answers OSC 52 clipboard queries with the system clipboard and
        // lets output replace it, so any program shown here (a remote host over ssh included) could read
        // or overwrite the clipboard unasked. Ignore OSC 52 entirely, as T3 Code's terminal does. A handler
        // registered here runs instead of the built-in one for the view's whole life: the parser is never
        // recreated, not even by a reset.
        getTerminal().registerOscHandler(code: 52) { _ in }
        // Option composes characters as everywhere else on the Mac; the keys that need Meta are mapped below.
        optionAsMetaKey = false
        TerminalTheme.apply(to: self)
        setAccessibilityLabel(String(localized: "Terminal"))
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

    override func dataReceived(slice: ArraySlice<UInt8>) {
        super.dataReceived(slice: slice)
        onOutput?()
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

    override func bell(source: Terminal) {
        guard window != nil, !isHiddenOrHasHiddenAncestor else { return }
        super.bell(source: source)
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        contextMenu?()
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
        let editsLine = process.running && !hasMarkedText() && getTerminal().keyboardEnhancementFlags.isEmpty

        switch (flags, Int(event.keyCode)) {
        case ([.command, .option], Self.leftArrow), ([.command, .option], Self.upArrow):
            return perform(.focusPane(offset: -1))
        case ([.command, .option], Self.rightArrow), ([.command, .option], Self.downArrow):
            return perform(.focusPane(offset: 1))
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

    private static let leftArrow = 123
    private static let rightArrow = 124
    private static let downArrow = 125
    private static let upArrow = 126
    private static let deleteKey = 51
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

    init(terminalView: ShellTerminalView) {
        self.terminalView = terminalView
        super.init(frame: .zero)
        wantsLayer = true
        layer?.masksToBounds = true
        addSubview(terminalView)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    override var isFlipped: Bool { true }

    override var wantsUpdateLayer: Bool { true }

    override func updateLayer() {
        layer?.backgroundColor = TerminalTheme.background.cgColor
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
