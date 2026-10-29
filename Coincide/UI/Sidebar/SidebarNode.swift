import AppKit
import CoincideKit

/// An outline item. Nodes are classes cached by id, so NSOutlineView keeps tracking the same object
/// (and its selection and expansion) across reloads.
final class SidebarNode: NSObject {
    enum Kind: Hashable {
        /// The "Pinned" section header, above Projects: pinned threads of every project and of Chats.
        case pinned
        /// The "Projects" section header.
        case header
        /// The "Chats" section header, backed by the existing project-free chat store.
        case chats(UUID)
        case project(UUID)
        case thread(UUID)
        /// "Show N more" under a project whose list is cut short.
        case showMore(UUID)
        case showLess(UUID)
        /// "No threads yet" under an empty project.
        case empty(UUID)
    }

    let kind: Kind
    var children: [SidebarNode] = []
    /// Threads hidden behind a `showMore` row.
    var hiddenThreadIDs: [UUID] = []

    init(_ kind: Kind) {
        self.kind = kind
    }

    var threadID: UUID? {
        if case .thread(let id) = kind { return id }
        return nil
    }

    var projectID: UUID? {
        switch kind {
        case .chats(let id), .project(let id), .showMore(let id), .showLess(let id), .empty(let id): id
        case .pinned, .header, .thread: nil
        }
    }

    var isSelectable: Bool { threadID != nil }

    /// The top-level section this node heads.
    var section: SidebarSection? {
        switch kind {
        case .pinned: .pinned
        case .header: .projects
        case .chats: .chats
        default: nil
        }
    }

    var isSection: Bool {
        switch kind {
        case .pinned, .header, .chats: true
        default: false
        }
    }
}

/// Hands out one node per kind, so identity survives rebuilding the tree.
struct SidebarNodeCache {
    let pinned = SidebarNode(.pinned)
    let header = SidebarNode(.header)
    private var nodes: [SidebarNode.Kind: SidebarNode] = [:]

    mutating func node(_ kind: SidebarNode.Kind) -> SidebarNode {
        if let node = nodes[kind] { return node }
        let node = SidebarNode(kind)
        nodes[kind] = node
        return node
    }

    func existing(_ kind: SidebarNode.Kind) -> SidebarNode? { nodes[kind] }

    /// Drops nodes for projects and threads that no longer exist.
    mutating func prune(keeping projectIDs: Set<UUID>, threadIDs: Set<UUID>) {
        nodes = nodes.filter { kind, _ in
            switch kind {
            case .pinned, .header: true
            case .thread(let id): threadIDs.contains(id)
            case .chats(let id), .project(let id), .showMore(let id), .showLess(let id), .empty(let id): projectIDs.contains(id)
            }
        }
    }
}
