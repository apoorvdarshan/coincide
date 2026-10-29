import Foundation

/// Where a forked thread came from, as T3 Code records a fork's `forkedFrom` run and its lineage parent.
///
/// Kept in a small sidecar file next to the threads (`thread-lineage.json`), keyed by the fork's id, so a
/// thread file stays readable by versions that know nothing about forks.
public struct ThreadLineage: Codable, Hashable, Sendable {
    /// The thread the fork was made from.
    public var parentThreadID: UUID
    /// The parent's title when the fork was made, shown once the parent is renamed away or deleted.
    public var parentTitle: String
    /// The last item of the parent that the fork copied: where the fork branches off in the parent.
    public var parentItemID: UUID?
    /// The fork's copy of that item: where the fork's own conversation starts.
    public var forkItemID: UUID?
    public var forkedAt: Date

    public nonisolated init(parentThreadID: UUID, parentTitle: String, parentItemID: UUID?, forkItemID: UUID?, forkedAt: Date) {
        self.parentThreadID = parentThreadID
        self.parentTitle = parentTitle
        self.parentItemID = parentItemID
        self.forkItemID = forkItemID
        self.forkedAt = forkedAt
    }

    /// Only the parent is required; anything else this version cannot read falls back to a default.
    public nonisolated init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        parentThreadID = try container.decode(UUID.self, forKey: .parentThreadID)
        parentTitle = container.lenient(String.self, forKey: .parentTitle) ?? ""
        parentItemID = container.lenient(UUID.self, forKey: .parentItemID)
        forkItemID = container.lenient(UUID.self, forKey: .forkItemID)
        forkedAt = container.lenient(Date.self, forKey: .forkedAt) ?? .distantPast
    }

    /// The fork's last copied item still in `items` (the fork's transcript), which T3 follows with its
    /// "Forked from conversation" marker. When the fork was rewound into the copied history, that is the
    /// last item older than the fork. Nil when none of the copied history is left.
    public nonisolated func forkPoint(in items: [TranscriptItem]) -> UUID? {
        if let forkItemID, items.contains(where: { $0.id == forkItemID }) { return forkItemID }
        return items.last { $0.createdAt <= forkedAt }?.id
    }
}

/// A fork ready to add to the store: the new thread, its lineage, and which item it copied from which.
public struct ThreadForkPlan: Sendable {
    public var thread: ChatThread
    public var lineage: ThreadLineage
    /// Each copied item's id in the parent, mapped to its copy's id in the fork.
    public var itemIDs: [UUID: UUID]
}

/// T3 Code's thread fork, for Coincide's transcripts.
///
/// A fork is a new thread in the same project and folder with a copy of the conversation up to the end of
/// one turn (T3 forks from a run; the sidebar forks from the latest settled one). Every item gets a new id.
/// The model, access and interaction mode carry over; native sessions do not, so whichever agent runs the
/// fork's next turn receives the whole copied conversation as a recap (see `Handoff`).
public enum ThreadFork {
    /// T3 names a fork after its source.
    public nonisolated static func title(forkOf title: String) -> String {
        String(localized: "\(title) fork")
    }

    /// Whether `item` opens a turn: the user's messages do, except those steered into a running turn, and so do the
    /// notices of turns an agent started itself (`turnOpeners`, which only the app keeps).
    private nonisolated static func opensTurn(_ item: TranscriptItem, _ turnOpeners: Set<UUID>) -> Bool {
        item.opensUserTurn || turnOpeners.contains(item.id)
    }

    /// The items a fork through `itemID` copies: everything up to the end of the turn that holds `itemID`, or
    /// the whole transcript when it is nil. A turn that is still running cannot be forked, as in T3 (only
    /// settled runs can), so `runningTurnID` (the opening item of the running turn) and everything after it
    /// are left out. Nil when there is nothing to fork: an empty transcript, an unknown item, or an item of
    /// the running turn.
    public nonisolated static func forkableItems(
        in items: [TranscriptItem], through itemID: UUID?, runningTurnID: UUID? = nil, turnOpeners: Set<UUID> = []
    ) -> ArraySlice<TranscriptItem>? {
        let limit = runningTurnID.flatMap { id in items.firstIndex { $0.id == id } } ?? items.count
        var end = limit
        if let itemID {
            guard let index = items.firstIndex(where: { $0.id == itemID }), index < limit else { return nil }
            end = items[(index + 1)..<limit].firstIndex { opensTurn($0, turnOpeners) } ?? limit
        }
        guard end > 0 else { return nil }
        return items[..<end]
    }

    /// Whether `forkableItems` finds anything to fork.
    public nonisolated static func canFork(
        _ thread: ChatThread, through itemID: UUID?, runningTurnID: UUID? = nil, turnOpeners: Set<UUID> = []
    ) -> Bool {
        forkableItems(in: thread.items, through: itemID, runningTurnID: runningTurnID, turnOpeners: turnOpeners) != nil
    }

    /// Builds a fork of `source` through the turn holding `itemID` (the whole settled transcript when nil).
    /// Items copied while still running or waiting for an answer can no longer finish in the fork, so they
    /// end the way they do when the app quits: failed, or declined for approvals and questions.
    public nonisolated static func makeFork(
        of source: ChatThread, through itemID: UUID?, runningTurnID: UUID? = nil, turnOpeners: Set<UUID> = [],
        id: UUID = UUID(), now: Date = Date()
    ) -> ThreadForkPlan? {
        guard let slice = forkableItems(in: source.items, through: itemID, runningTurnID: runningTurnID, turnOpeners: turnOpeners)
        else { return nil }
        var itemIDs: [UUID: UUID] = [:]
        let items = slice.map { item -> TranscriptItem in
            var copy = item
            copy.id = UUID()
            itemIDs[item.id] = copy.id
            if copy.status == .running || copy.status == .waiting {
                copy.status = copy.kind == .approval || copy.kind == .question ? .declined : .failed
            }
            return copy
        }
        let thread = ChatThread(
            id: id, projectID: source.projectID, title: title(forkOf: source.title), selection: source.selection,
            accessMode: source.accessMode, interactionMode: source.interactionMode, items: items, sessions: [:],
            isPinned: false, isArchived: false, worktreePath: source.worktreePath, branch: source.branch, draft: nil,
            // A bot's fork is another conversation with the same bot.
            botID: source.botID, createdAt: now)
        let lineage = ThreadLineage(
            parentThreadID: source.id, parentTitle: source.title, parentItemID: slice.last?.id, forkItemID: items.last?.id,
            forkedAt: now)
        return ThreadForkPlan(thread: thread, lineage: lineage, itemIDs: itemIDs)
    }
}

// MARK: - Store

@MainActor
extension AppStore {
    /// Forks a thread (see `ThreadFork`) and adds the fork to the store, with its lineage. The fork is the
    /// most recently updated thread of its project. Returns nil, adding nothing, when there is nothing to fork.
    @discardableResult
    public func forkThread(
        _ sourceID: UUID, through itemID: UUID? = nil, runningTurnID: UUID? = nil, turnOpeners: Set<UUID> = []
    ) -> ThreadForkPlan? {
        guard let source = thread(sourceID), project(source.projectID) != nil,
            var plan = ThreadFork.makeFork(of: source, through: itemID, runningTurnID: runningTurnID, turnOpeners: turnOpeners)
        else { return nil }
        let id = createThread(in: source.projectID, selection: plan.thread.selection).id
        plan.thread.id = id
        let fork = plan.thread
        lineageStore.set(plan.lineage, for: id)
        updateThread(id) { $0 = fork }
        notify(.items(id, changed: [], appended: false))
        return plan
    }

    /// Where a thread was forked from, if it is a fork.
    public func lineage(of threadID: UUID) -> ThreadLineage? {
        lineageStore.lineage(of: threadID)
    }

    /// The thread a fork was made from, while it still exists. Its transcript is not read.
    public func parentThread(of threadID: UUID) -> ThreadSummary? {
        lineage(of: threadID).flatMap { summary($0.parentThreadID) }
    }

    /// The existing forks of a thread, oldest first. Their transcripts are not read.
    public func forks(of threadID: UUID) -> [(thread: ThreadSummary, lineage: ThreadLineage)] {
        lineageStore.children(of: threadID)
            .compactMap { id, lineage in summary(id).map { (thread: $0, lineage: lineage) } }
            .sorted { $0.lineage.forkedAt < $1.lineage.forkedAt }
    }

    /// The lineage sidecar of this store's folder. Records of threads that no longer exist are dropped when
    /// it is first read.
    var lineageStore: ThreadLineageStore {
        let key = directory.standardizedFileURL.path
        if let existing = lineageStores[key] { return existing }
        let store = ThreadLineageStore(directory: directory)
        store.prune(keeping: Set(threadSummaries.keys))
        lineageStores[key] = store
        return store
    }
}

/// Lineage sidecars by store folder: an extension cannot add storage to `AppStore`.
@MainActor private var lineageStores: [String: ThreadLineageStore] = [:]

/// Reads and writes `thread-lineage.json`: a JSON object from each fork's id to its `ThreadLineage`. The
/// file is small and changes only when a thread is forked, so it is written at once. Entries this version
/// cannot read are skipped; a file that cannot be read at all is set aside rather than replaced.
@MainActor
final class ThreadLineageStore {
    private(set) var records: [UUID: ThreadLineage] = [:]
    let url: URL

    init(directory: URL) {
        url = directory.appendingPathComponent("thread-lineage.json")
        guard let data = try? Data(contentsOf: url) else { return }
        do {
            let entries = try Self.decoder.decode([String: LenientEntry].self, from: data)
            for (key, entry) in entries {
                if let id = UUID(uuidString: key), let lineage = entry.lineage { records[id] = lineage }
            }
        } catch {
            NSLog("Coincide: could not read \(url.lastPathComponent): \(error)")
            let stamp = ISO8601DateFormatter().string(from: Date()).replacingOccurrences(of: ":", with: "-")
            try? FileManager.default.moveItem(at: url, to: url.appendingPathExtension("unreadable-\(stamp)"))
        }
    }

    /// A record, or nil when it cannot be read.
    private struct LenientEntry: Decodable {
        var lineage: ThreadLineage?

        nonisolated init(from decoder: Decoder) throws {
            lineage = try? ThreadLineage(from: decoder)
        }
    }

    func lineage(of threadID: UUID) -> ThreadLineage? { records[threadID] }

    func children(of threadID: UUID) -> [(UUID, ThreadLineage)] {
        records.filter { $0.value.parentThreadID == threadID }.map { ($0.key, $0.value) }
    }

    func set(_ lineage: ThreadLineage?, for threadID: UUID) {
        guard records[threadID] != lineage else { return }
        records[threadID] = lineage
        save()
    }

    /// Forgets the lineage of deleted forks. Parents are kept even when deleted: a fork still names its parent.
    func prune(keeping threadIDs: Set<UUID>) {
        let stale = records.keys.filter { !threadIDs.contains($0) }
        guard !stale.isEmpty else { return }
        for id in stale { records[id] = nil }
        save()
    }

    private func save() {
        do {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            let entries = Dictionary(uniqueKeysWithValues: records.map { ($0.key.uuidString, $0.value) })
            try Self.encoder.encode(entries).write(to: url, options: .atomic)
        } catch {
            NSLog("Coincide: failed to save \(url.lastPathComponent): \(error)")
        }
    }

    /// Dates are written as seconds since 2001, which keep the exact time of the fork (ISO 8601 would drop
    /// the fraction of a second that `ThreadLineage.forkPoint(in:)` compares with).
    private static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .deferredToDate
        encoder.outputFormatting = [.sortedKeys]
        return encoder
    }()

    /// Reads ISO 8601 dates too, as the rest of the store writes them.
    private static let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .custom { decoder in
            let container = try decoder.singleValueContainer()
            if let seconds = try? container.decode(Double.self) { return Date(timeIntervalSinceReferenceDate: seconds) }
            let text = try container.decode(String.self)
            guard let date = ISO8601DateFormatter().date(from: text) else {
                throw DecodingError.dataCorruptedError(in: container, debugDescription: "Not a date: \(text)")
            }
            return date
        }
        return decoder
    }()
}
