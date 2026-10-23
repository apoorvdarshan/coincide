import AppKit
import CoincideCore
import CoincideTerminal
import Foundation
import Observation

/// How a window's terminals reach the rest of the app. WorkspaceStore installs
/// it when the window registers; tests and unregistered windows use the defaults.
struct TerminalIntegration {
    var thread: (@MainActor (UUID) -> CodingThread?)? = nil
    var canOpen: @MainActor (CodingThread) -> Bool = { _ in true }
    var environment: @MainActor (CodingThread) -> [String: String] = { _ in [:] }
    /// Opens a resolved file link; returns a message when it cannot.
    var openFile: @MainActor (_ path: String, _ line: Int?, _ column: Int?, CodingThread) -> String? = { path, _, _, _ in
        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)]); return nil
    }
    var openURL: @MainActor (URL) -> Void = { NSWorkspace.shared.open($0) }
    var report: @MainActor (String) -> Void = { _ in }
}

struct PendingTerminalClose: Identifiable {
    let id: UUID
    let session: LocalTerminalSession
    let threadID: UUID
    @MainActor init(session: LocalTerminalSession, threadID: UUID) { id = session.id; self.session = session; self.threadID = threadID }
}

/// A visible group's restoration work must run again when checkout readiness
/// changes, even though its saved pane IDs have not changed.
struct TerminalResumeReadiness: Hashable {
    let threadID: UUID
    let projectID: UUID
    let threadCreatedAt: Date
    let workspacePath: Data
    let preparationID: UUID?
    let sessionIDs: [UUID]
    let owner: Int
    let canOpen: Bool
    let enabled: Bool
    let isRestoring: Bool
    let suspended: Bool
}

/// Each native window owns its terminals; tabs survive hiding the panel and switching threads.
@MainActor @Observable
final class TerminalWorkspaceStore {
    static let defaultPanelHeight = 260.0
    private let executable: String?
    private let loginShell: Bool
    var sessions: [UUID: [LocalTerminalSession]] = [:]
    var selection: [UUID: UUID] = [:] { didSet { checkpoint() } }
    /// Split groups per conversation; sessions without a group get their own tab.
    private(set) var layouts: [UUID: TerminalThreadLayout] = [:]
    /// Conversations whose terminal drawer is open in this window.
    private(set) var visibleThreads: Set<UUID> = []
    var pendingClose: PendingTerminalClose?
    /// A short inline message, such as a terminal link to a missing file.
    var notice: String?
    private(set) var isRestoring = false
    private(set) var restorationError: String?
    var sessionWillClose: (@MainActor (LocalTerminalSession) -> Void)?
    @ObservationIgnored var integration = TerminalIntegration()
    private var panelHeights: [UUID: Double] = [:]
    @ObservationIgnored private var knownThreads: [UUID: CodingThread] = [:]
    @ObservationIgnored private var monitor: TerminalActivityMonitor?
    @ObservationIgnored private var archives: TerminalArchiveStore?
    @ObservationIgnored private var archiveID: UUID?
    @ObservationIgnored private var workspacePaths: [UUID: String] = [:]
    @ObservationIgnored private var persistence: Task<Void, Never>?
    @ObservationIgnored private var periodicSave: Task<Void, Never>?
    @ObservationIgnored private var restoration: Task<Void, Never>?
    @ObservationIgnored private var lastArchive: TerminalWindowArchive?
    @ObservationIgnored private var suspended = false
    private(set) var restorationGeneration = 0
    init(executable: String? = nil, loginShell: Bool = true, activitySampler: TerminalActivityMonitor.Sampler? = nil) {
        self.executable = executable; self.loginShell = loginShell
        let sessions: @MainActor () -> [LocalTerminalSession] = { [weak self] in self?.sessions.values.flatMap { $0 } ?? [] }
        monitor = activitySampler.map { .init(sampler: $0, sessions: sessions) } ?? .init(sessions: sessions)
    }

    // MARK: Drawer state

    func isVisible(_ threadID: UUID) -> Bool { visibleThreads.contains(threadID) }
    func setVisible(_ visible: Bool, threadID: UUID) {
        guard visible != visibleThreads.contains(threadID) else { return }
        if visible { visibleThreads.insert(threadID); selected(in: threadID)?.requestFocus() } else { visibleThreads.remove(threadID) }
        checkpoint()
    }
    /// Shows or hides this conversation's drawer, opening a first shell when it has none.
    func toggle(for thread: CodingThread, canOpen: Bool) throws {
        if isVisible(thread.id) { setVisible(false, threadID: thread.id); return }
        setVisible(true, threadID: thread.id)
        guard !isRestoring, sessions[thread.id, default: []].isEmpty, canOpen else { return }
        try add(for: thread)
    }
    func panelHeight(_ threadID: UUID) -> Double { panelHeights[threadID] ?? Self.defaultPanelHeight }
    /// Recorded when a resize ends, not on every drag step.
    func recordPanelHeight(_ height: Double, threadID: UUID) {
        guard height.isFinite else { return }
        let bounded = min(TerminalWindowArchive.panelHeightRange.upperBound, max(TerminalWindowArchive.panelHeightRange.lowerBound, height.rounded()))
        guard abs((panelHeights[threadID] ?? Self.defaultPanelHeight) - bounded) >= 2 else { return }
        panelHeights[threadID] = bounded; checkpoint()
    }

    func selected(in threadID: UUID) -> LocalTerminalSession? {
        let tabs = sessions[threadID, default: []]
        return tabs.first { $0.id == selection[threadID] } ?? tabs.first
    }
    func select(_ session: LocalTerminalSession, threadID: UUID, focus: Bool = true) {
        if selection[threadID] != session.id { selection[threadID] = session.id }
        if focus { session.requestFocus() }
    }
    func layout(for threadID: UUID) -> TerminalThreadLayout {
        (layouts[threadID] ?? .init()).normalized(sessionIDs: sessions[threadID, default: []].map(\.id))
    }
    func activeGroup(in threadID: UUID) -> TerminalGroup? {
        let layout = layout(for: threadID)
        return selected(in: threadID).flatMap { layout.group(containing: $0.id) } ?? layout.groups.first
    }
    func canSplit(in threadID: UUID) -> Bool {
        guard let selected = selected(in: threadID) else { return false }
        return layout(for: threadID).canSplit(selected.id)
    }
    /// Shells running a child process and running script tabs.
    func runningCount(threadID: UUID) -> Int { sessions[threadID, default: []].filter(\.isBusy).count }

    // MARK: Opening terminals

    func add(for thread: CodingThread) throws {
        try canCreate()
        let thread = try checkedThread(thread)
        let identity = try TerminalWorkspaceIdentity.capture(thread: thread)
        let session = try LocalTerminalSession(directory: URL(fileURLWithPath: thread.workspacePath), executable: executable,
            arguments: loginShell ? ["-l"] : [], environmentOverrides: integration.environment(thread),
            unsetEnvironment: TerminalRuntimeEnvironment.keys, ordinal: nextOrdinal(thread.id), workspaceIdentity: identity)
        var layout = layout(for: thread.id)
        register(session, thread: thread)
        layout.addGroup(session.id); layouts[thread.id] = layout
        show(session, threadID: thread.id)
    }
    /// Adds a pane after the selected terminal in its group (at most four).
    func split(for thread: CodingThread, axis: TerminalGroup.Axis) throws {
        guard let anchor = selected(in: thread.id) else { return try add(for: thread) }
        guard canSplit(in: thread.id) else {
            throw CoincideError("A terminal group holds at most \(TerminalThreadLayout.maximumPanesPerGroup) terminals.")
        }
        try canCreate()
        let thread = try checkedThread(thread)
        let identity = try TerminalWorkspaceIdentity.capture(thread: thread)
        let session = try LocalTerminalSession(directory: URL(fileURLWithPath: thread.workspacePath), executable: executable,
            arguments: loginShell ? ["-l"] : [], environmentOverrides: integration.environment(thread),
            unsetEnvironment: TerminalRuntimeEnvironment.keys, ordinal: nextOrdinal(thread.id), workspaceIdentity: identity)
        var layout = layout(for: thread.id)
        register(session, thread: thread)
        layout.split(session.id, after: anchor.id, axis: axis); layouts[thread.id] = layout
        show(session, threadID: thread.id)
    }
    @discardableResult func run(_ invocation: ProjectScriptInvocation, for thread: CodingThread) throws -> LocalTerminalSession {
        try canCreate()
        let thread = try checkedThread(thread)
        guard invocation.directory.standardizedFileURL.path.utf8.elementsEqual(thread.workspacePath.utf8) else {
            throw CoincideError("The script's reviewed checkout changed. Review it again before running it.")
        }
        let identity = try TerminalWorkspaceIdentity.capture(thread: thread, directory: invocation.directory)
        let session = try LocalTerminalSession(directory: invocation.directory, executable: executable,
            arguments: [loginShell ? "-lc" : "-c", invocation.command],
            environmentOverrides: invocation.environment, unsetEnvironment: TerminalRuntimeEnvironment.keys,
            commandTitle: invocation.name, workspaceIdentity: identity)
        var layout = layout(for: thread.id)
        register(session, thread: thread)
        layout.addGroup(session.id); layouts[thread.id] = layout
        selection[thread.id] = session.id
        return session
    }
    /// Starts a fresh shell in a tab showing saved or exited output.
    func resume(_ session: LocalTerminalSession, thread: CodingThread, focus: Bool = true) throws {
        let thread = try checkedThread(thread)
        guard canResume(session, thread: thread) else {
            throw CoincideError("This saved pane belongs to an unavailable or changed checkout. Open a new terminal instead.")
        }
        try session.resumeShell(executable: executable, arguments: loginShell ? ["-l"] : [],
                                environmentOverrides: integration.environment(thread), unsetEnvironment: TerminalRuntimeEnvironment.keys, focus: focus)
        knownThreads[thread.id] = thread
        monitor?.wake(); checkpoint()
    }
    func canResume(_ session: LocalTerminalSession, thread: CodingThread) -> Bool {
        guard !isRestoring, !suspended, !session.isCommand,
              sessions[thread.id]?.contains(where: { $0 === session }) == true,
              let current = try? checkedThread(thread),
              session.workspaceIdentity?.matchesDirectory(session.directory) == true,
              session.workspaceIdentity?.matches(thread: current) == true else { return false }
        switch session.lifecycle { case .exited, .failed: return true; case .running, .closing: return false }
    }
    func resumeReadiness(for thread: CodingThread, sessionIDs: [UUID], canOpen: Bool, enabled: Bool) -> TerminalResumeReadiness {
        .init(threadID: thread.id, projectID: thread.projectID, threadCreatedAt: thread.createdAt,
            workspacePath: Data(thread.workspacePath.utf8), preparationID: thread.workspacePreparation?.id,
            sessionIDs: sessionIDs, owner: restorationGeneration, canOpen: canOpen, enabled: enabled,
            isRestoring: isRestoring, suspended: suspended)
    }
    func resumeRestoredPanes(_ readiness: TerminalResumeReadiness, for thread: CodingThread) {
        guard !Task.isCancelled, readiness.enabled, readiness.canOpen,
              readiness == resumeReadiness(for: thread, sessionIDs: readiness.sessionIDs, canOpen: readiness.canOpen, enabled: readiness.enabled),
              let current = try? checkedThread(thread) else { return }
        for id in readiness.sessionIDs {
            guard let session = sessions[current.id]?.first(where: { $0.id == id }),
                  session.detachment == .restart, canResume(session, thread: current) else { continue }
            do { try resume(session, thread: current, focus: false) }
            catch { notice = error.localizedDescription }
        }
    }

    private func checkedThread(_ captured: CodingThread) throws -> CodingThread {
        let current: CodingThread
        if let resolve = integration.thread {
            guard let found = resolve(captured.id) else {
                throw CoincideError("This conversation is no longer available.")
            }
            current = found
        } else { current = captured }
        guard !suspended, !isRestoring, current.id == captured.id, current.projectID == captured.projectID,
              current.createdAt == captured.createdAt,
              current.workspacePath.utf8.elementsEqual(captured.workspacePath.utf8),
              current.workspacePreparation?.id == captured.workspacePreparation?.id,
              integration.canOpen(current) else {
            throw CoincideError("Terminals are unavailable while this conversation's checkout is changing.")
        }
        return current
    }

    // MARK: Closing terminals

    /// Asks for confirmation before stopping a running command.
    func requestClose(_ session: LocalTerminalSession, threadID: UUID) {
        if session.hasForegroundCommand || session.isBusy { pendingClose = .init(session: session, threadID: threadID) }
        else { close(session, threadID: threadID) }
    }
    func close(_ session: LocalTerminalSession, threadID: UUID) {
        closeOwned(session)
        var layout = layout(for: threadID)
        let next = layout.remove(session.id)
        sessions[threadID]?.removeAll { $0.id == session.id }
        if sessions[threadID]?.isEmpty == true { sessions.removeValue(forKey: threadID) }
        layouts[threadID] = sessions[threadID] == nil ? nil : layout
        if pendingClose?.session === session { pendingClose = nil }
        if selection[threadID] == session.id {
            if let next, sessions[threadID]?.contains(where: { $0.id == next }) == true { selection[threadID] = next }
            else if let last = sessions[threadID]?.last { selection[threadID] = last.id }
            else { selection.removeValue(forKey: threadID) }
        }
        checkpoint()
    }
    func closeAll() {
        _ = removeAll()
    }
    @discardableResult func remove(threadIDs: Set<UUID>) -> [LocalTerminalSession] {
        let closing = threadIDs.flatMap { sessions.removeValue(forKey: $0) ?? [] }
        for id in threadIDs {
            selection.removeValue(forKey: id); layouts.removeValue(forKey: id); visibleThreads.remove(id)
            panelHeights.removeValue(forKey: id); knownThreads.removeValue(forKey: id)
        }
        for session in closing { closeOwned(session) }
        checkpoint()
        return closing
    }
    @discardableResult func removeAll() -> [LocalTerminalSession] {
        let closing = sessions.values.flatMap { $0 }
        for session in closing { closeOwned(session) }
        sessions.removeAll(); selection.removeAll(); layouts.removeAll()
        checkpoint()
        return closing
    }

    /// T3's closeIdle: re-inspects each shell now, then closes only shells at an
    /// idle prompt whose activity did not change, keeping their output in the tab.
    /// Script tabs and shells running a command stay open.
    @discardableResult func closeIdle(threadID: UUID) async -> Int {
        guard !suspended, let monitor, let candidates = sessions[threadID], !candidates.isEmpty,
              let capturedThread = thread(threadID) else { return 0 }
        let owner = restorationGeneration
        let captures = Dictionary(uniqueKeysWithValues: candidates.map { session in
            (session.id, (session: session, identity: session.workspaceIdentity, pid: session.processID, mark: session.activityMark))
        })
        let idle = await monitor.idleSessions(candidates)
        guard !Task.isCancelled, !suspended, owner == restorationGeneration,
              let current = thread(threadID), current.projectID == capturedThread.projectID,
              current.createdAt == capturedThread.createdAt,
              current.workspacePath.utf8.elementsEqual(capturedThread.workspacePath.utf8),
              current.workspacePreparation?.id == capturedThread.workspacePreparation?.id else { return 0 }
        var closed = 0
        for session in idle {
            guard let capture = captures[session.id], capture.session === session, !session.isCommand,
                  session.lifecycle == .running, session.processID == capture.pid, session.activityMark == capture.mark,
                  sessions[threadID]?.contains(where: { $0 === session }) == true,
                  let identity = capture.identity, session.workspaceIdentity == identity, identity.matches(thread: current) else { continue }
            if session.detachIdle() { sessionWillClose?(session); closed += 1 }
        }
        if closed > 0 { checkpoint() }
        return closed
    }

    // MARK: Restoration and persistence

    func restore(from archives: TerminalArchiveStore, currentThreads: @escaping @MainActor () -> [CodingThread]) {
        guard suspended || (self.archives == nil && restoration == nil) else { return }
        let previousRestoration = restoration, previousPersistence = persistence
        if suspended { archiveID = nil; lastArchive = nil; workspacePaths.removeAll() }
        restorationGeneration += 1
        let owner = restorationGeneration
        self.archives = archives; isRestoring = true; suspended = false
        restoration = Task { [weak self] in
            guard let self else { return }
            defer { if self.restorationGeneration == owner { self.isRestoring = false; self.restoration = nil } }
            await previousRestoration?.value; await previousPersistence?.value
            guard self.restorationGeneration == owner, !self.suspended else { return }
            do {
                let saved = try await archives.claim()
                guard self.restorationGeneration == owner, !self.suspended else { await archives.release(saved.id); return }
                self.archiveID = saved.id
                let threads = Dictionary(uniqueKeysWithValues: currentThreads().map { ($0.id, $0) })
                for tab in saved.tabs {
                    // A checkout change does not erase output from its former
                    // panes. Their immutable saved path/identity remain intact;
                    // both resume paths refuse them in the new checkout.
                    guard let thread = threads[tab.threadID] else { continue }
                    let session = LocalTerminalSession(restoring: tab)
                    self.register(session, thread: thread)
                }
                var savedGroups: [UUID: [TerminalGroup]] = [:]
                for group in saved.groups ?? [] where self.sessions[group.threadID] != nil {
                    savedGroups[group.threadID, default: []].append(.init(id: group.id, sessionIDs: group.sessionIDs, axis: group.axis))
                }
                for (threadID, groups) in savedGroups {
                    self.layouts[threadID] = TerminalThreadLayout(groups: groups).normalized(sessionIDs: self.sessions[threadID, default: []].map(\.id))
                }
                self.selection = saved.selection.filter { threadID, id in self.sessions[threadID]?.contains { $0.id == id } == true }
                // Older files kept one window-wide flag; it applies to conversations with tabs.
                let visible = saved.visibleThreadIDs ?? (saved.panelVisible ? Array(self.sessions.keys) : [])
                self.visibleThreads = Set(visible.filter { threads[$0] != nil })
                self.panelHeights = (saved.panelHeights ?? [:]).filter { threads[$0.key] != nil }
                self.isRestoring = false; self.checkpoint()
                self.periodicSave = Task { [weak self] in
                    while !Task.isCancelled {
                        do { try await Task.sleep(for: .seconds(5)) } catch { return }
                        guard let self, self.restorationGeneration == owner, !self.suspended else { return }; self.checkpoint()
                    }
                }
            } catch {
                if self.restorationGeneration == owner {
                    self.restorationError = "Saved terminal output could not be restored. Existing files were preserved."
                }
            }
        }
    }

    func waitForRestoration() async { await restoration?.value }
    func waitForPersistence() async { await persistence?.value }

    /// Closing a window or quitting retains its display; closing a tab removes it.
    @discardableResult func suspend() -> [LocalTerminalSession] {
        guard !suspended else { return [] }
        checkpoint(); suspended = true; restorationGeneration += 1; isRestoring = false
        periodicSave?.cancel(); periodicSave = nil
        monitor?.stop()
        let closing = sessions.values.flatMap { $0 }
        for session in closing { closeOwned(session) }
        sessions.removeAll(); selection.removeAll(); layouts.removeAll(); visibleThreads.removeAll(); panelHeights.removeAll()
        knownThreads.removeAll(); pendingClose = nil; notice = nil
        if let archives, let archiveID {
            let previous = persistence
            persistence = Task { await previous?.value; await archives.release(archiveID) }
        }
        return closing
    }

    func dismissRestorationError() { restorationError = nil }

    // MARK: Session wiring

    private func register(_ session: LocalTerminalSession, thread: CodingThread) {
        workspacePaths[thread.id] = thread.workspacePath
        knownThreads[thread.id] = thread
        sessions[thread.id, default: []].append(session)
        session.onCommand = { [weak self] session, command in self?.perform(command, on: session) }
        session.onOpenLink = { [weak self] session, link in self?.openLink(link, from: session) }
        session.onExit = { [weak self] session, code in self?.shellExited(session, code: code) }
        session.onActivate = { [weak self] session in
            guard let self, let threadID = self.threadID(of: session) else { return }
            self.select(session, threadID: threadID, focus: false)
        }
        monitor?.wake()
    }
    private func show(_ session: LocalTerminalSession, threadID: UUID) {
        selection[threadID] = session.id
        if !visibleThreads.contains(threadID) { visibleThreads.insert(threadID); checkpoint() }
        session.requestFocus()
    }
    private func threadID(of session: LocalTerminalSession) -> UUID? {
        sessions.first { $0.value.contains { $0 === session } }?.key
    }
    private func thread(_ id: UUID) -> CodingThread? {
        if let resolve = integration.thread { return resolve(id) }
        return knownThreads[id]
    }
    private func nextOrdinal(_ threadID: UUID) -> Int {
        let used = Set(sessions[threadID, default: []].compactMap(\.ordinal))
        return (1...).first { !used.contains($0) } ?? 1
    }
    private func perform(_ command: TerminalCommand, on session: LocalTerminalSession) {
        guard let threadID = threadID(of: session) else { return }
        if command == .close { requestClose(session, threadID: threadID); return }
        guard let thread = thread(threadID), integration.canOpen(thread) else {
            integration.report(String(localized: "Terminals are unavailable while this conversation's checkout is changing.")); return
        }
        do {
            switch command {
            case .newTerminal: try add(for: thread)
            case .splitRight, .splitDown:
                selection[threadID] = session.id
                try split(for: thread, axis: command == .splitRight ? .horizontal : .vertical)
            case .resume: try resume(session, thread: thread)
            default: break
            }
        } catch { integration.report(error.localizedDescription) }
    }
    private func openLink(_ link: String, from session: LocalTerminalSession) {
        guard let target = TerminalLinkTarget.resolve(link, currentDirectory: session.currentDirectory) else {
            notice = String(localized: "Only web links and file paths open from the terminal."); return
        }
        switch target {
        case .web(let url): integration.openURL(url)
        case .file(let path, let line, let column):
            guard let threadID = threadID(of: session), let thread = thread(threadID) else { return }
            notice = integration.openFile(path, line, column, thread)
        }
    }
    /// A shell that exits cleanly closes its tab, as in T3. A failed exit stays
    /// visible with its status; script tabs always keep their result.
    private func shellExited(_ session: LocalTerminalSession, code: Int32?) {
        guard !session.isCommand, code == 0, let threadID = threadID(of: session) else { return }
        close(session, threadID: threadID)
        if sessions[threadID] == nil { setVisible(false, threadID: threadID) }
    }

    private func canCreate() throws {
        guard !isRestoring, !suspended else { throw CoincideError("Wait for terminal restoration to finish before starting a shell.") }
        guard sessions.values.reduce(0, { $0 + $1.count }) < 32 else { throw CoincideError("Close a terminal before opening more than 32 tabs in one window.") }
    }

    /// Captures tab metadata now and encodes changed scrollback off the main actor
    /// before the serialized save. The save also completes after the window closes.
    private func checkpoint() {
        guard let archives, let archiveID, !suspended, !isRestoring else { return }
        let threadIDs = sessions.keys.sorted { $0.uuidString < $1.uuidString }
        let captures = threadIDs.flatMap { threadID in
            (sessions[threadID] ?? []).map { $0.capture(threadID: threadID, workspacePath: workspacePaths[threadID] ?? $0.directory) }
        }
        let selection = selection, visible = visibleThreads.sorted { $0.uuidString < $1.uuidString }
        let groups = threadIDs.flatMap { threadID in
            layout(for: threadID).groups.map { TerminalGroupArchive(id: $0.id, threadID: threadID, sessionIDs: $0.sessionIDs, axis: $0.axis) }
        }
        let heights = panelHeights
        let previous = persistence
        persistence = Task { [weak self] in
            await previous?.value
            let histories = await Task.detached(priority: .utility) { captures.map { $0.history() } }.value
            var tabs: [TerminalTabArchive] = []
            for (capture, history) in zip(captures, histories) {
                self?.sessions.values.lazy.flatMap { $0 }.first { $0.id == capture.sessionID }?.remember(history, mark: capture.mark)
                tabs.append(capture.archive(history: history))
            }
            let validSelection = selection.filter { threadID, id in tabs.contains { $0.threadID == threadID && $0.id == id } }
            let archive = TerminalWindowArchive(id: archiveID, tabs: tabs, selection: validSelection, panelVisible: !visible.isEmpty,
                visibleThreadIDs: Array(visible.prefix(256)), panelHeights: heights.isEmpty ? nil : heights,
                groups: groups.count <= 32 ? groups : nil)
            if let self {
                guard archive != self.lastArchive else { return }
                self.lastArchive = archive
            }
            do { try await archives.save(archive) }
            catch { self?.lastArchive = nil; self?.restorationError = "Terminal output could not be saved for restart." }
        }
    }
    private func closeOwned(_ session: LocalTerminalSession) {
        session.close()
        sessionWillClose?(session)
    }
}
