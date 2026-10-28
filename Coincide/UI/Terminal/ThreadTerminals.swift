import AppKit
import CoincideKit

/// A terminal tab: one session, or up to four shown side by side or stacked (T3 Code's terminal group).
final class TerminalTab {
    enum Layout {
        case sideBySide
        case stacked
    }

    let id = UUID()
    fileprivate(set) var sessions: [TerminalSession]
    fileprivate(set) var layout = Layout.sideBySide
    fileprivate(set) var activeSessionID: UUID
    /// Shows the sessions. The view controller keeps it in sync with `sessions` and `layout`.
    let contentView = TerminalTabContentView()

    fileprivate init(session: TerminalSession) {
        sessions = [session]
        activeSessionID = session.id
    }

    var activeSession: TerminalSession? { sessions.first { $0.id == activeSessionID } ?? sessions.first }
}

/// The terminal tabs of one thread. Their shells keep running while another thread is shown.
final class ThreadTerminals {
    static let maximumSessionsPerTab = 4

    enum Change {
        /// Tabs or sessions were added, removed or activated.
        case tabs
        /// A session's title, directory or state changed.
        case session(TerminalSession)
    }

    let threadID: UUID
    private(set) var tabs: [TerminalTab] = []
    private(set) var activeTabID: UUID?
    var onChange: ((Change) -> Void)?

    init(threadID: UUID) {
        self.threadID = threadID
    }

    var activeTab: TerminalTab? { tabs.first { $0.id == activeTabID } ?? tabs.first }
    var activeSession: TerminalSession? { activeTab?.activeSession }
    var sessions: [TerminalSession] { tabs.flatMap(\.sessions) }
    var canSplit: Bool { (activeTab?.sessions.count ?? 0) < Self.maximumSessionsPerTab }

    func tab(containing session: TerminalSession) -> TerminalTab? {
        tabs.first { tab in tab.sessions.contains { $0 === session } }
    }

    // MARK: Changes

    /// The session each project script last ran in, by script.
    private var scriptSessions: [UUID: UUID] = [:]

    @discardableResult
    func addTab(environment: [String: String] = [:]) -> TerminalSession {
        let session = makeSession(environment: environment)
        let tab = TerminalTab(session: session)
        tabs.append(tab)
        activeTabID = tab.id
        onChange?(.tabs)
        return session
    }

    /// Adds a session next to the active one. The whole tab takes the new layout, as in T3 Code.
    /// Returns nil when the tab is full.
    @discardableResult
    func split(_ layout: TerminalTab.Layout) -> TerminalSession? {
        guard let tab = activeTab else { return addTab() }
        guard tab.sessions.count < Self.maximumSessionsPerTab else { return nil }
        let session = makeSession()
        let anchor = tab.sessions.firstIndex { $0.id == tab.activeSessionID } ?? tab.sessions.count - 1
        tab.sessions.insert(session, at: anchor + 1)
        tab.layout = layout
        tab.activeSessionID = session.id
        onChange?(.tabs)
        return session
    }

    func activate(_ session: TerminalSession) {
        guard let tab = tab(containing: session), tab.id != activeTabID || tab.activeSessionID != session.id else { return }
        tab.activeSessionID = session.id
        activeTabID = tab.id
        onChange?(.tabs)
    }

    func activate(_ tab: TerminalTab) {
        guard tab.id != activeTabID, tabs.contains(where: { $0 === tab }) else { return }
        activeTabID = tab.id
        onChange?(.tabs)
    }

    /// Moves to the tab `offset` places away, wrapping around.
    func selectTab(offset: Int) {
        guard tabs.count > 1, let tab = activeTab, let index = tabs.firstIndex(where: { $0 === tab }) else { return }
        activate(tabs[(index + offset % tabs.count + tabs.count) % tabs.count])
    }

    /// Stops the session's shell and removes it.
    func close(_ session: TerminalSession) {
        session.close()
        remove(session)
    }

    func close(_ tab: TerminalTab) {
        guard let index = tabs.firstIndex(where: { $0 === tab }) else { return }
        tab.sessions.forEach { $0.close() }
        tabs.remove(at: index)
        if activeTabID == tab.id { activeTabID = tabs.isEmpty ? nil : tabs[min(index, tabs.count - 1)].id }
        onChange?(.tabs)
    }

    func closeAll() {
        guard !tabs.isEmpty else { return }
        sessions.forEach { $0.close() }
        tabs = []
        activeTabID = nil
        onChange?(.tabs)
    }

    private func remove(_ session: TerminalSession) {
        guard let tab = tab(containing: session), let tabIndex = tabs.firstIndex(where: { $0 === tab }),
            let index = tab.sessions.firstIndex(where: { $0 === session })
        else { return }
        tab.sessions.remove(at: index)
        if tab.sessions.isEmpty {
            tabs.remove(at: tabIndex)
            if activeTabID == tab.id { activeTabID = tabs.isEmpty ? nil : tabs[min(tabIndex, tabs.count - 1)].id }
        } else if tab.activeSessionID == session.id {
            tab.activeSessionID = tab.sessions[min(index, tab.sessions.count - 1)].id
        }
        onChange?(.tabs)
    }

    /// Runs a project script in the terminal it ran in last when that terminal is idle again, as T3 Code does, else in
    /// a new tab, and shows that terminal.
    func run(_ script: ProjectScript, environment: [String: String]) {
        let previous = scriptSessions[script.id].flatMap { id in sessions.first { $0.id == id } }
        let session: TerminalSession
        if let previous, previous.state == .running, !previous.isBusy {
            session = previous
            activate(previous)
        } else {
            session = addTab(environment: environment)
        }
        scriptSessions[script.id] = session.id
        session.run(script.command)
    }

    private func makeSession(environment: [String: String] = [:]) -> TerminalSession {
        let used = Set(sessions.map(\.number))
        let number = (1...).first { !used.contains($0) }!
        let start = TerminalLaunch.directory(for: threadID)
        let session = TerminalSession(
            number: number, directory: start.url, missingDirectory: start.missing, environment: environment)
        session.onChange = { [weak self, weak session] in
            guard let self, let session else { return }
            self.onChange?(.session(session))
        }
        // As in T3 Code, a shell that exits closes its terminal, unless it failed right away.
        session.onExit = { [weak self, weak session] keepOpen in
            guard let self, let session, !keepOpen else { return }
            self.remove(session)
        }
        session.start()
        return session
    }
}

/// Owns every thread's terminals for the life of the app, and stops their shells when the thread is
/// deleted or the app quits.
final class TerminalSessionManager {
    static let shared = TerminalSessionManager()

    private var terminalsByThread: [UUID: ThreadTerminals] = [:]
    private var storeToken: ObservationToken?
    private var quitObserver: NSObjectProtocol?

    private init() {
        storeToken = AppStore.shared.observe { [weak self] change in
            switch change {
            case .threadList, .projects: self?.closeDeletedThreads()
            case .settings: self?.applyFont()
            default: break
            }
        }
        quitObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.willTerminateNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.stopAllShells() }
        }
        TerminalKeyRouter.install()
    }

    /// Terminals running a command that quitting would stop.
    var busySessionCount: Int { terminalsByThread.values.reduce(0) { $0 + $1.sessions.filter(\.isBusy).count } }

    func terminals(for threadID: UUID) -> ThreadTerminals {
        if let existing = terminalsByThread[threadID] { return existing }
        let terminals = ThreadTerminals(threadID: threadID)
        terminalsByThread[threadID] = terminals
        return terminals
    }

    private func closeDeletedThreads() {
        for (threadID, terminals) in terminalsByThread where !AppStore.shared.hasThread(threadID) {
            terminalsByThread[threadID] = nil
            terminals.closeAll()
        }
    }

    /// The app is quitting: only the processes matter now, not the tabs.
    private func stopAllShells() {
        for session in terminalsByThread.values.flatMap(\.sessions) { session.close() }
    }

    private func applyFont() {
        let font = Theme.monoFont
        for session in terminalsByThread.values.flatMap(\.sessions) where session.terminalView.font != font {
            session.terminalView.font = font
        }
    }
}

/// Lays out a tab's panes side by side or stacked with thin dividers, sharing the space equally
/// whenever a pane is added or removed.
final class TerminalTabContentView: NSSplitView {
    private var needsEqualSizes = false

    init() {
        super.init(frame: .zero)
        dividerStyle = .thin
        isVertical = true
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    override var dividerColor: NSColor { .separatorColor }

    func show(_ panes: [NSView], layout: TerminalTab.Layout) {
        let vertical = layout == .sideBySide
        guard subviews != panes || isVertical != vertical else { return }
        // Panes that stay are only reordered, so their terminals keep their window and focus.
        subviews = panes
        isVertical = vertical
        needsEqualSizes = true
        needsLayout = true
    }

    override func layout() {
        super.layout()
        guard needsEqualSizes, bounds.width > 0, bounds.height > 0 else { return }
        needsEqualSizes = false
        let count = arrangedSubviews.count
        guard count > 1 else { return }
        let length = (isVertical ? bounds.width : bounds.height) - dividerThickness * CGFloat(count - 1)
        let paneLength = length / CGFloat(count)
        for divider in 0..<(count - 1) {
            setPosition(paneLength * CGFloat(divider + 1) + dividerThickness * CGFloat(divider), ofDividerAt: divider)
        }
    }
}
