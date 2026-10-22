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

public enum ProjectGroupingMode: String, Codable, CaseIterable, Identifiable, Sendable {
    case repository
    case repositoryPath = "repository_path"
    case separate
    public var id: String { rawValue }
    public var title: String {
        switch self {
        case .repository: "Repository"
        case .repositoryPath: "Repository and Folder"
        case .separate: "Separate Checkouts"
        }
    }
}

public struct ProjectGroupMemberReference: Codable, Identifiable, Sendable, Equatable {
    public let id: UUID
    public let path: String
    public init(id: UUID, path: String) { self.id = id; self.path = path }
    public init(project: WorkspaceProject) { id = project.id; path = project.path }
}

public struct ProjectGroup: Identifiable, Sendable, Equatable {
    public let key: String
    public var id: String { key }
    public let displayName: String
    public let representative: WorkspaceProject
    /// One representative per physical path. Stale alias registrations remain in memberProjectIDs.
    public let members: [WorkspaceProject]
    public let memberProjectIDs: [UUID]
    /// Every registration and its literal path, captured in canonical project order.
    public let memberProjectReferences: [ProjectGroupMemberReference]
}

public struct SidebarPreferences: Codable, Sendable, Equatable {
    public var sortMode: ProjectSortMode
    public var collapsedProjectIDs: [UUID]
    public var groupingMode: ProjectGroupingMode
    public var groupingOverrides: [String: ProjectGroupingMode]
    public var groupExpandedByKey: [String: Bool]
    public var activeProjectByGroup: [String: UUID]
    public var selectedThreadID: UUID?
    public init(sortMode: ProjectSortMode = .updatedAt, collapsedProjectIDs: [UUID] = [], groupingMode: ProjectGroupingMode = .repository,
                groupingOverrides: [String: ProjectGroupingMode] = [:], groupExpandedByKey: [String: Bool] = [:], activeProjectByGroup: [String: UUID] = [:], selectedThreadID: UUID? = nil) {
        self.sortMode = sortMode; self.collapsedProjectIDs = collapsedProjectIDs
        self.groupingMode = groupingMode; self.groupingOverrides = groupingOverrides
        self.groupExpandedByKey = groupExpandedByKey; self.activeProjectByGroup = activeProjectByGroup
        self.selectedThreadID = selectedThreadID
    }
    enum CodingKeys: String, CodingKey { case sortMode, collapsedProjectIDs, groupingMode, groupingOverrides, groupExpandedByKey, activeProjectByGroup, selectedThreadID }
    public init(from decoder: any Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        sortMode = try values.decodeIfPresent(ProjectSortMode.self, forKey: .sortMode) ?? .updatedAt
        collapsedProjectIDs = try values.decodeIfPresent([UUID].self, forKey: .collapsedProjectIDs) ?? []
        groupingMode = try values.decodeIfPresent(ProjectGroupingMode.self, forKey: .groupingMode) ?? .repository
        groupingOverrides = try values.decodeIfPresent([String: ProjectGroupingMode].self, forKey: .groupingOverrides) ?? [:]
        groupExpandedByKey = try values.decodeIfPresent([String: Bool].self, forKey: .groupExpandedByKey) ?? [:]
        activeProjectByGroup = try values.decodeIfPresent([String: UUID].self, forKey: .activeProjectByGroup) ?? [:]
        selectedThreadID = try values.decodeIfPresent(UUID.self, forKey: .selectedThreadID)
    }
    public func validate(projectIDs: Set<UUID>) throws {
        let collapsed = Set(collapsedProjectIDs)
        guard collapsed.count == collapsedProjectIDs.count else { throw CoincideError("A project cannot appear more than once in collapsed sidebar preferences.") }
        guard collapsed.isSubset(of: projectIDs) else { throw CoincideError("Collapsed sidebar preferences reference a project that does not exist.") }
        guard activeProjectByGroup.values.allSatisfy({ projectIDs.contains($0) }),
              [Array(groupingOverrides.keys), Array(groupExpandedByKey.keys), Array(activeProjectByGroup.keys)].joined().allSatisfy({ !$0.isEmpty && !$0.contains("\0") && $0.utf8.count <= 65_536 }) else {
            throw CoincideError("Project grouping preferences contain an invalid checkout or key.")
        }
    }
}

public extension WorkspaceSnapshot {
    var effectiveSidebarPreferences: SidebarPreferences { sidebarPreferences ?? SidebarPreferences() }
    func isProjectExpanded(_ id: UUID) -> Bool { !effectiveSidebarPreferences.collapsedProjectIDs.contains(id) }

    func physicalProjectKey(for id: UUID) -> String? { projects.first(where: { $0.id == id }).map(Self.physicalKey) }
    func isProjectGroupExpanded(_ key: String) -> Bool {
        guard let group = projectGroups.first(where: { $0.key == key }) else { return true }
        let preferences = effectiveSidebarPreferences
        return preferences.groupExpandedByKey[key] ?? !group.memberProjectIDs.contains(where: { preferences.collapsedProjectIDs.contains($0) })
    }
    var projectGroups: [ProjectGroup] {
        let preferences = effectiveSidebarPreferences
        var physical: [String: [WorkspaceProject]] = [:], physicalOrder: [String] = []
        for project in projects {
            let key = Self.physicalKey(project)
            if physical[key] == nil { physicalOrder.append(key) }
            physical[key, default: []].append(project)
        }
        var order: [String] = [], members: [String: [WorkspaceProject]] = [:], logicalByPhysical: [String: String] = [:]
        for physicalKey in physicalOrder {
            let aliases = physical[physicalKey]!
            let winner = aliases.reduce(aliases[0]) { Self.fresher($1, than: $0) ? $1 : $0 }
            let source = winner.repositoryIdentity != nil ? winner : aliases.filter { $0.repositoryIdentity != nil }.reduce(winner) { current, candidate in
                current.repositoryIdentity == nil || Self.fresher(candidate, than: current) ? candidate : current
            }
            let mode = preferences.groupingOverrides[physicalKey] ?? preferences.groupingMode
            let key: String
            if mode == .separate || source.repositoryIdentity == nil { key = physicalKey }
            else {
                let identity = source.repositoryIdentity!
                if mode == .repositoryPath, let relative = identity.projectRelativePath, !relative.isEmpty {
                    key = Self.groupKey("repository_path", [identity.groupingKey, relative])
                } else { key = Self.groupKey("repository", [identity.groupingKey]) }
            }
            logicalByPhysical[physicalKey] = key
            if members[key] == nil { order.append(key) }
            members[key, default: []].append(winner)
        }
        var ids: [String: [UUID]] = [:], references: [String: [ProjectGroupMemberReference]] = [:]
        for project in projects {
            guard let key = logicalByPhysical[Self.physicalKey(project)] else { continue }
            ids[key, default: []].append(project.id)
            references[key, default: []].append(.init(project: project))
        }
        return order.map { key in
            let values = members[key]!, representative = values[0]
            return .init(key: key, displayName: Self.groupName(values), representative: representative, members: values, memberProjectIDs: ids[key] ?? [], memberProjectReferences: references[key] ?? [])
        }
    }
    var orderedProjectGroups: [ProjectGroup] {
        let groups = projectGroups, mode = effectiveSidebarPreferences.sortMode
        guard mode != .manual, groups.count > 1 else { return groups }
        let groupByProject = Dictionary(uniqueKeysWithValues: groups.flatMap { group in group.memberProjectIDs.map { ($0, group.key) } })
        var withThreads: Set<String> = [], latest: [String: Double] = [:]
        for thread in threads where !thread.isArchived {
            guard let key = groupByProject[thread.projectID] else { continue }
            withThreads.insert(key)
            if let score = Self.threadSortTimestamp(thread, mode: mode) { latest[key] = max(latest[key] ?? score, score) }
        }
        return groups.enumerated().map { index, group in
            let fallback = mode == .createdAt ? Self.sortTimestamp(group.representative.createdAt) : Self.sortTimestamp(group.representative.updatedAt) ?? Self.sortTimestamp(group.representative.createdAt)
            return (group: group, score: withThreads.contains(group.key) ? latest[group.key] : fallback, index: index)
        }.sorted { left, right in
            switch (left.score, right.score) {
            case (.some(let a), .some(let b)):
                if a != b { return a > b }
                let title = left.group.displayName.localizedCompare(right.group.displayName)
                return title == .orderedSame ? left.group.key < right.group.key : title == .orderedAscending
            case (.some, .none): return true
            case (.none, .some): return false
            case (.none, .none): return left.index < right.index
            }
        }.map(\.group)
    }

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
            let timestamp = Self.threadSortTimestamp(thread, mode: mode)
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
    private static func threadSortTimestamp(_ thread: CodingThread, mode: ProjectSortMode) -> Double? {
        switch mode {
        case .updatedAt:
            let user = thread.visibleMessages.lazy.filter { $0.role == .user }.compactMap { sortTimestamp($0.createdAt) }.max()
            let queued = thread.queuedTurns.lazy.compactMap { sortTimestamp($0.createdAt) }.max()
            return [user, queued].compactMap { $0 }.max() ?? sortTimestamp(thread.updatedAt) ?? sortTimestamp(thread.createdAt)
        case .createdAt: return sortTimestamp(thread.createdAt)
        case .manual: return nil
        }
    }
    private static func groupKey(_ kind: String, _ parts: [String]) -> String { kind + ":" + parts.map { String($0.utf8.count) + ":" + $0 }.joined() }
    private static func physicalKey(_ project: WorkspaceProject) -> String { groupKey("checkout", [URL(fileURLWithPath: project.path).standardizedFileURL.path]) }
    private static func fresher(_ candidate: WorkspaceProject, than existing: WorkspaceProject) -> Bool {
        let a = sortTimestamp(candidate.updatedAt) ?? sortTimestamp(candidate.createdAt) ?? -.infinity
        let b = sortTimestamp(existing.updatedAt) ?? sortTimestamp(existing.createdAt) ?? -.infinity
        return a == b ? candidate.id.uuidString > existing.id.uuidString : a > b
    }
    private static func groupName(_ members: [WorkspaceProject]) -> String {
        guard members.count > 1 else { return members[0].name }
        let titles = Set(members.map { $0.name.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty })
        let displays = Set(members.compactMap { $0.repositoryIdentity?.groupingDisplayName })
        let names = Set(members.compactMap { $0.repositoryIdentity?.name })
        if titles.count == 1, let title = titles.first, !displays.contains(title), !names.contains(title) { return title }
        if displays.count == 1, let title = displays.first { return title }
        if names.count == 1, let title = names.first { return title }
        return members[0].name
    }
}

extension WorkspaceSnapshot {
    mutating func reconcileGroupingPreferences() {
        guard var preferences = sidebarPreferences else { return }
        let physical = Set(projects.map(Self.physicalKey)), groups = projectGroups
        let ids = Set(projects.map(\.id)), keys = Set(groups.map(\.key))
        preferences.collapsedProjectIDs.removeAll { !ids.contains($0) }
        if let selected = preferences.selectedThreadID, !threads.contains(where: { $0.id == selected }) { preferences.selectedThreadID = nil }
        preferences.groupingOverrides = preferences.groupingOverrides.filter { physical.contains($0.key) }
        preferences.groupExpandedByKey = preferences.groupExpandedByKey.filter { keys.contains($0.key) }
        preferences.activeProjectByGroup = preferences.activeProjectByGroup.filter { key, id in
            groups.contains { $0.key == key && $0.memberProjectIDs.contains(id) } && projects.contains { $0.id == id && ($0.clone == nil || $0.clone?.isReady == true) }
        }
        sidebarPreferences = preferences
    }
}
