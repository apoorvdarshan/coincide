import CoincideCore
import CoincideTerminal
import Foundation
import Observation

/// Each native window owns its terminals; tabs survive hiding the panel and switching threads.
@MainActor @Observable
final class TerminalWorkspaceStore {
    private let executable: String?
    private let loginShell: Bool
    var sessions: [UUID: [LocalTerminalSession]] = [:]
    var selection: [UUID: UUID] = [:] { didSet { checkpoint() } }
    var panelVisible = false { didSet { checkpoint() } }
    private(set) var isRestoring = false
    private(set) var restorationError: String?
    var sessionWillClose: (@MainActor (LocalTerminalSession) -> Void)?
    @ObservationIgnored private var archives: TerminalArchiveStore?
    @ObservationIgnored private var archiveID: UUID?
    @ObservationIgnored private var workspacePaths: [UUID: String] = [:]
    @ObservationIgnored private var persistence: Task<Void, Never>?
    @ObservationIgnored private var periodicSave: Task<Void, Never>?
    @ObservationIgnored private var restoration: Task<Void, Never>?
    @ObservationIgnored private var lastArchive: TerminalWindowArchive?
    @ObservationIgnored private var suspended = false
    @ObservationIgnored private var restorationGeneration = 0
    init(executable: String? = nil, loginShell: Bool = true) {
        self.executable = executable; self.loginShell = loginShell
    }
    func add(for thread: CodingThread) throws {
        try canCreate()
        let session = try LocalTerminalSession(directory: URL(fileURLWithPath: thread.workspacePath), executable: executable,
                                               arguments: loginShell ? ["-l"] : [])
        workspacePaths[thread.id] = thread.workspacePath
        sessions[thread.id, default: []].append(session)
        selection[thread.id] = session.id
        session.requestFocus()
    }
    @discardableResult func run(_ invocation: ProjectScriptInvocation, for thread: CodingThread) throws -> LocalTerminalSession {
        try canCreate()
        let session = try LocalTerminalSession(directory: invocation.directory, executable: executable,
            arguments: [loginShell ? "-lc" : "-c", invocation.command],
            environmentOverrides: invocation.environment, unsetEnvironment: ["T3CODE_PROJECT_ROOT", "T3CODE_WORKTREE_PATH"], commandTitle: invocation.name)
        workspacePaths[thread.id] = thread.workspacePath
        sessions[thread.id, default: []].append(session)
        selection[thread.id] = session.id
        session.requestFocus()
        return session
    }
    /// An explicit open or tab switch focuses that terminal (T3 keyboard focus).
    func requestFocus(threadID: UUID) {
        let tabs = sessions[threadID] ?? []
        (tabs.first { $0.id == selection[threadID] } ?? tabs.first)?.requestFocus()
    }
    func close(_ session: LocalTerminalSession, threadID: UUID) {
        closeOwned(session)
        sessions[threadID]?.removeAll { $0.id == session.id }
        if selection[threadID] == session.id { selection[threadID] = sessions[threadID]?.last?.id }
        checkpoint()
    }
    func closeAll() {
        _ = removeAll()
    }
    @discardableResult func remove(threadIDs: Set<UUID>) -> [LocalTerminalSession] {
        let closing = threadIDs.flatMap { sessions.removeValue(forKey: $0) ?? [] }
        for id in threadIDs { selection.removeValue(forKey: id) }
        for session in closing { closeOwned(session) }
        checkpoint()
        return closing
    }
    @discardableResult func removeAll() -> [LocalTerminalSession] {
        let closing = sessions.values.flatMap { $0 }
        for session in closing { closeOwned(session) }
        sessions.removeAll(); selection.removeAll()
        checkpoint()
        return closing
    }
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
                    guard let thread = threads[tab.threadID], thread.workspacePath == tab.workspacePath else { continue }
                    self.workspacePaths[thread.id] = thread.workspacePath
                    self.sessions[thread.id, default: []].append(.init(restoring: tab))
                }
                self.selection = saved.selection.filter { threadID, id in self.sessions[threadID]?.contains { $0.id == id } == true }
                self.panelVisible = saved.panelVisible
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
        let closing = sessions.values.flatMap { $0 }
        for session in closing { closeOwned(session) }
        sessions.removeAll(); selection.removeAll()
        if let archives, let archiveID {
            let previous = persistence
            persistence = Task { await previous?.value; await archives.release(archiveID) }
        }
        return closing
    }

    func dismissRestorationError() { restorationError = nil }

    private func canCreate() throws {
        guard !isRestoring, !suspended else { throw CoincideError("Wait for terminal restoration to finish before starting a shell.") }
        guard sessions.values.reduce(0, { $0 + $1.count }) < 32 else { throw CoincideError("Close a terminal before opening more than 32 tabs in one window.") }
    }

    private func checkpoint() {
        guard let archives, let archiveID, !suspended, !isRestoring else { return }
        let tabs = sessions.keys.sorted { $0.uuidString < $1.uuidString }.flatMap { threadID in
            (sessions[threadID] ?? []).map { $0.archive(threadID: threadID, workspacePath: workspacePaths[threadID] ?? $0.directory) }
        }
        let validSelection = selection.filter { threadID, id in tabs.contains { $0.threadID == threadID && $0.id == id } }
        let archive = TerminalWindowArchive(id: archiveID, tabs: tabs, selection: validSelection, panelVisible: panelVisible)
        guard archive != lastArchive else { return }; lastArchive = archive
        let previous = persistence
        persistence = Task { [weak self] in
            await previous?.value
            do { try await archives.save(archive) }
            catch { self?.lastArchive = nil; self?.restorationError = "Terminal output could not be saved for restart." }
        }
    }
    private func closeOwned(_ session: LocalTerminalSession) {
        session.close()
        sessionWillClose?(session)
    }
}
