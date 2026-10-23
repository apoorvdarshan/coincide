import Foundation

/// One drawer tab: up to four terminals shown side by side (`horizontal`, Split
/// Right) or stacked (`vertical`, Split Down), as T3's terminal groups.
public struct TerminalGroup: Codable, Equatable, Sendable, Identifiable {
    public enum Axis: String, Codable, Sendable { case horizontal, vertical }
    public let id: UUID
    public var sessionIDs: [UUID]
    public var axis: Axis
    public init(id: UUID = UUID(), sessionIDs: [UUID], axis: Axis = .horizontal) {
        self.id = id; self.sessionIDs = sessionIDs; self.axis = axis
    }
}

/// Pure group bookkeeping for one conversation's terminals. Session existence
/// is owned elsewhere; `normalized(sessionIDs:)` reconciles the two.
public struct TerminalThreadLayout: Equatable, Sendable {
    public static let maximumPanesPerGroup = 4
    public private(set) var groups: [TerminalGroup]
    public init(groups: [TerminalGroup] = []) { self.groups = groups }

    public func group(containing session: UUID) -> TerminalGroup? { groups.first { $0.sessionIDs.contains(session) } }
    public func canSplit(_ session: UUID) -> Bool {
        (group(containing: session)?.sessionIDs.count ?? 0) < Self.maximumPanesPerGroup
    }

    /// A new tab containing only this session.
    public mutating func addGroup(_ session: UUID) {
        remove(session)
        groups.append(.init(id: groups.contains { $0.id == session } ? UUID() : session, sessionIDs: [session]))
    }

    /// Inserts `session` after `anchor` in the anchor's group, which adopts the
    /// latest split axis. Returns false at the four-pane limit or without an anchor.
    @discardableResult public mutating func split(_ session: UUID, after anchor: UUID, axis: TerminalGroup.Axis) -> Bool {
        guard session != anchor, let index = groups.firstIndex(where: { $0.sessionIDs.contains(anchor) }),
              groups[index].sessionIDs.count < Self.maximumPanesPerGroup, group(containing: session) == nil else { return false }
        let position = groups[index].sessionIDs.firstIndex(of: anchor).map { $0 + 1 } ?? groups[index].sessionIDs.endIndex
        groups[index].sessionIDs.insert(session, at: position)
        groups[index].axis = axis
        return true
    }

    /// Removes a session and returns the session that should be selected next:
    /// a neighbour in the same group, otherwise the last pane of the previous tab.
    @discardableResult public mutating func remove(_ session: UUID) -> UUID? {
        guard let index = groups.firstIndex(where: { $0.sessionIDs.contains(session) }),
              let position = groups[index].sessionIDs.firstIndex(of: session) else { return groups.last?.sessionIDs.last }
        groups[index].sessionIDs.remove(at: position)
        if !groups[index].sessionIDs.isEmpty {
            return groups[index].sessionIDs[min(position, groups[index].sessionIDs.count - 1)]
        }
        groups.remove(at: index)
        guard !groups.isEmpty else { return nil }
        return groups[max(0, index - 1)].sessionIDs.last
    }

    /// Drops unknown or duplicate sessions, caps groups at four panes and gives
    /// every remaining session without a group a tab of its own, in session order.
    public func normalized(sessionIDs: [UUID]) -> TerminalThreadLayout {
        let known = Set(sessionIDs)
        var seen = Set<UUID>(), groupIDs = Set<UUID>(), result: [TerminalGroup] = []
        // Fallback group IDs derive from their first session, so repeated
        // normalization keeps stable identities for views.
        func uniqueID(_ preferred: UUID, _ first: UUID) -> UUID {
            for candidate in [preferred, first] where groupIDs.insert(candidate).inserted { return candidate }
            var id = UUID(); while !groupIDs.insert(id).inserted { id = UUID() }; return id
        }
        for group in groups {
            let members = group.sessionIDs.filter { known.contains($0) && seen.insert($0).inserted }
            for chunk in stride(from: 0, to: members.count, by: Self.maximumPanesPerGroup) {
                let slice = Array(members[chunk..<min(members.count, chunk + Self.maximumPanesPerGroup)])
                result.append(.init(id: uniqueID(chunk == 0 ? group.id : slice[0], slice[0]), sessionIDs: slice, axis: group.axis))
            }
        }
        for session in sessionIDs where seen.insert(session).inserted {
            result.append(.init(id: uniqueID(session, session), sessionIDs: [session]))
        }
        return .init(groups: result)
    }
}
