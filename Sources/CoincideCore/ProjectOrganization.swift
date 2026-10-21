import Foundation

public enum ProjectSortMode: String, Codable, CaseIterable, Identifiable, Sendable {
    case updatedAt = "updated_at"
    case createdAt = "created_at"
    case manual = "manual"
    public var id: String { rawValue }
    public var title: String {
        switch self {
        case .updatedAt: "Last user message"
        case .createdAt: "Created at"
        case .manual: "Manual"
        }
    }
}

public struct SidebarPreferences: Codable, Sendable, Equatable {
    public var sortMode: ProjectSortMode
    public var collapsedProjectIDs: [UUID]
    public init(sortMode: ProjectSortMode = .updatedAt, collapsedProjectIDs: [UUID] = []) {
        self.sortMode = sortMode; self.collapsedProjectIDs = collapsedProjectIDs
    }
    public func validate(projectIDs: Set<UUID>) throws {
        let collapsed = Set(collapsedProjectIDs)
        guard collapsed.count == collapsedProjectIDs.count else { throw CoincideError("A project cannot appear more than once in collapsed sidebar preferences.") }
        guard collapsed.isSubset(of: projectIDs) else { throw CoincideError("Collapsed sidebar preferences reference a project that does not exist.") }
    }
}

public extension WorkspaceSnapshot {
    var effectiveSidebarPreferences: SidebarPreferences { sidebarPreferences ?? SidebarPreferences() }
    func isProjectExpanded(_ id: UUID) -> Bool { !effectiveSidebarPreferences.collapsedProjectIDs.contains(id) }

    /// Rendering order is derived from the complete snapshot, independent of visible search results.
    /// The stored project array remains the user's manual order when switching between sort modes.
    var orderedProjects: [WorkspaceProject] {
        let mode = effectiveSidebarPreferences.sortMode
        guard mode != .manual, projects.count > 1 else { return projects }
        let projectIDs = Set(projects.map(\.id))
        var projectsWithThreads: Set<UUID> = []
        var latest: [UUID: Double] = [:]
        for thread in threads where !thread.isArchived && projectIDs.contains(thread.projectID) {
            projectsWithThreads.insert(thread.projectID)
            let timestamp: Double?
            switch mode {
            case .updatedAt:
                // Streaming, metadata changes, and assistant messages can advance updatedAt.
                // Queued turns are accepted user activity even before their messages enter history.
                let user = thread.messages.lazy.filter { $0.role == .user }.compactMap { Self.sortTimestamp($0.createdAt) }.max()
                let queued = thread.queuedTurns.lazy.compactMap { Self.sortTimestamp($0.createdAt) }.max()
                timestamp = [user, queued].compactMap { $0 }.max()
                    ?? Self.sortTimestamp(thread.updatedAt) ?? Self.sortTimestamp(thread.createdAt)
            case .createdAt: timestamp = Self.sortTimestamp(thread.createdAt)
            case .manual: timestamp = nil
            }
            if let timestamp { latest[thread.projectID] = max(latest[thread.projectID] ?? timestamp, timestamp) }
        }
        let scored = projects.enumerated().map { index, project in
            let timestamp: Double?
            if projectsWithThreads.contains(project.id) { timestamp = latest[project.id] }
            else if mode == .createdAt { timestamp = Self.sortTimestamp(project.createdAt) }
            else { timestamp = Self.sortTimestamp(project.updatedAt) ?? Self.sortTimestamp(project.createdAt) }
            return (project: project, timestamp: timestamp, index: index)
        }
        return scored.sorted { left, right in
            switch (left.timestamp, right.timestamp) {
            case (.some(let first), .some(let second)):
                if first != second { return first > second }
                let comparison = left.project.name.localizedCompare(right.project.name)
                if comparison != .orderedSame { return comparison == .orderedAscending }
                if left.project.id != right.project.id { return left.project.id.uuidString < right.project.id.uuidString }
                return left.index < right.index
            case (.some, .none): return true
            case (.none, .some): return false
            case (.none, .none): return left.index < right.index
            }
        }.map(\.project)
    }
    private static func sortTimestamp(_ date: Date?) -> Double? {
        guard let value = date?.timeIntervalSinceReferenceDate, value.isFinite else { return nil }
        return value
    }
}
