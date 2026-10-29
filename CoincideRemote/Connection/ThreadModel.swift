import CoincideRemoteKit
import Foundation
import Observation

/// An open thread: the newest part of its transcript, kept in step with the Mac, and its turn.
@MainActor
@Observable
final class ThreadModel: Identifiable {
    let id: UUID
    var summary: RemoteThreadSummary?
    private(set) var items: [RemoteItem] = []
    private(set) var hasEarlier = false
    var turn = RemoteTurnState()
    private(set) var turnChanges: [String: [RemoteChangedFile]] = [:]
    var isLoading = false
    var isLoadingEarlier = false
    var isRemoved = false
    var error: String?
    /// The item at the top of the screen, so the scroll position survives the layout changing (an iPad window
    /// resizing, a Duo folding).
    var scrollAnchor: UUID?
    /// Whether the view follows new items to the bottom.
    var followsBottom = true
    /// Tool groups the user expanded, by their first item's id.
    var expanded: Set<UUID> = []

    init(id: UUID, summary: RemoteThreadSummary?) {
        self.id = id
        self.summary = summary
    }

    var hasLoaded: Bool { !items.isEmpty || summary?.itemCount == 0 }

    func apply(_ transcript: RemoteTranscript) {
        summary = transcript.thread
        items = transcript.items
        hasEarlier = transcript.hasEarlier
        turn = transcript.turn
        turnChanges = transcript.turnChanges
        isRemoved = false
    }

    /// Adds or replaces items by id, placing new ones by their index in the whole transcript. Items older than the
    /// first one loaded are left for `loadEarlier`.
    func apply(_ updates: [RemoteItem], count: Int) {
        for item in updates {
            if let position = items.lastIndex(where: { $0.id == item.id }) {
                items[position] = item
                continue
            }
            let first = items.first?.index ?? item.index
            guard item.index >= first else { continue }
            if let last = items.last, item.index > last.index {
                items.append(item)
            } else {
                let position = items.firstIndex { $0.index > item.index } ?? items.count
                items.insert(item, at: position)
            }
        }
    }

    func prepend(_ page: RemoteItemPage) {
        let known = Set(items.map(\.id))
        items.insert(contentsOf: page.items.filter { !known.contains($0.id) }, at: 0)
        hasEarlier = page.hasEarlier
    }

    /// Approvals and questions waiting for the user.
    var waitingItems: [RemoteItem] { items.filter { $0.isWaiting && ($0.kind == .approval || $0.kind == .question) } }

    func changes(forTurnOpenedBy itemID: UUID) -> [RemoteChangedFile] { turnChanges[itemID.uuidString] ?? [] }
}
