import CoincideCore
import CoincideTerminal
import Foundation
import Observation

/// Each native window owns its terminals; tabs survive hiding the panel and switching threads.
@MainActor @Observable
final class TerminalWorkspaceStore {
    var sessions: [UUID: [LocalTerminalSession]] = [:]
    var selection: [UUID: UUID] = [:]
    func add(for thread: CodingThread) throws {
        let session = try LocalTerminalSession(directory: URL(fileURLWithPath: thread.workspacePath))
        sessions[thread.id, default: []].append(session)
        selection[thread.id] = session.id
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
