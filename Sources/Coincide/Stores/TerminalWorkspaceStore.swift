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
    var selection: [UUID: UUID] = [:]
    init(executable: String? = nil, loginShell: Bool = true) {
        self.executable = executable; self.loginShell = loginShell
    }
    func add(for thread: CodingThread) throws {
        let session = try LocalTerminalSession(directory: URL(fileURLWithPath: thread.workspacePath), executable: executable,
                                               arguments: loginShell ? ["-l"] : [])
        sessions[thread.id, default: []].append(session)
        selection[thread.id] = session.id
    }
    @discardableResult func run(_ invocation: ProjectScriptInvocation, for thread: CodingThread) throws -> LocalTerminalSession {
        let session = try LocalTerminalSession(directory: invocation.directory, executable: executable,
            arguments: [loginShell ? "-lc" : "-c", invocation.command],
            environmentOverrides: invocation.environment, unsetEnvironment: ["T3CODE_PROJECT_ROOT", "T3CODE_WORKTREE_PATH"], commandTitle: invocation.name)
        sessions[thread.id, default: []].append(session)
        selection[thread.id] = session.id
        return session
    }
    func close(_ session: LocalTerminalSession, threadID: UUID) {
        session.close()
        sessions[threadID]?.removeAll { $0.id == session.id }
        if selection[threadID] == session.id { selection[threadID] = sessions[threadID]?.last?.id }
    }
    func closeAll() {
        _ = removeAll()
    }
    @discardableResult func remove(threadIDs: Set<UUID>) -> [LocalTerminalSession] {
        let closing = threadIDs.flatMap { sessions.removeValue(forKey: $0) ?? [] }
        for id in threadIDs { selection.removeValue(forKey: id) }
        for session in closing { session.close() }
        return closing
    }
    @discardableResult func removeAll() -> [LocalTerminalSession] {
        let closing = sessions.values.flatMap { $0 }
        for session in closing { session.close() }
        sessions.removeAll(); selection.removeAll()
        return closing
    }
}
