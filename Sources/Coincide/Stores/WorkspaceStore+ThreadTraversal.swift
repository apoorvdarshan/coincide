import CoincideCore
import Foundation

enum ThreadTraversalDirection: Sendable { case previous, next }

enum ThreadTraversal {
    /// T3 `resolveAdjacentThreadId`: no wraparound; without a current thread,
    /// previous goes to the last thread and next to the first.
    static func adjacent<ID: Equatable>(in ids: [ID], current: ID?, direction: ThreadTraversalDirection) -> ID? {
        guard !ids.isEmpty else { return nil }
        guard let current else { return direction == .previous ? ids.last : ids.first }
        guard let index = ids.firstIndex(of: current) else { return nil }
        switch direction {
        case .previous: return index > 0 ? ids[index - 1] : nil
        case .next: return index + 1 < ids.count ? ids[index + 1] : nil
        }
    }
}

extension WorkspaceStore {
    /// Matches the Recents list, including its project, archive and search filters.
    var visibleThreadOrder: [UUID] { recentSidebarThreads.map(\.id) }

    func adjacentThread(_ direction: ThreadTraversalDirection) -> UUID? {
        ThreadTraversal.adjacent(in: visibleThreadOrder, current: selectedThreadID, direction: direction)
    }
    /// One-based `thread.jump.N` target among the visible rows.
    func threadForJump(_ number: Int) -> UUID? {
        let order = visibleThreadOrder
        return (1...9).contains(number) && order.indices.contains(number - 1) ? order[number - 1] : nil
    }
    /// Selects a thread the way notification and pull-request navigation do.
    @discardableResult func selectThread(_ id: UUID) -> Bool {
        guard let target = thread(id), snapshot.projects.contains(where: { $0.id == target.projectID }) else { return false }
        selectedProjectID = target.projectID; showArchived = target.isArchived; selectedThreadID = id
        showingSettings = false; modelPickerPresented = false
        return true
    }
    /// A history entry stays valid while its thread and project exist and the
    /// thread is not hidden by the current archive filter.
    func canNavigate(to id: UUID) -> Bool {
        guard let target = thread(id), !target.isArchived || showArchived else { return false }
        return snapshot.projects.contains { $0.id == target.projectID }
    }
}
