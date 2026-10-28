import Foundation

/// What lists, menus and background services need of a thread, without its transcript.
///
/// The store keeps one for every thread (`AppStore.threadSummaries`) and reads them at launch from a small
/// index, so the sidebar, the palette, the Dock menu and the worktree and checkpoint services never decode a
/// transcript. `AppStore.thread(_:)` reads the whole thread when something needs its items.
///
/// The fields match `ChatThread`'s, so code that only reads metadata works with either. `updatedAt` is the
/// thread's last activity: every appended item and every finished turn moves it.
public struct ThreadSummary: Codable, Hashable, Sendable, Identifiable {
    public var id: UUID
    public var projectID: UUID
    public var title: String
    public var createdAt: Date
    public var updatedAt: Date
    public var selection: ModelSelection
    public var accessMode: AccessMode
    public var interactionMode: InteractionMode
    public var isPinned: Bool
    public var isArchived: Bool
    public var snoozedUntil: Date?
    public var worktreePath: String?
    public var branch: String?
    /// Unsent composer text is waiting in the thread.
    public var hasDraft: Bool
    /// Number of transcript items.
    public var itemCount: Int
    public var hasUserMessages: Bool
    /// Agents with a native session for the thread, in a fixed order. Others than the selected one handed it off.
    public var sessionProviders: [ProviderKind]
    public var nativeSessionIDs: [ProviderKind: String]
    public var importedSession: ImportedSession?

    public nonisolated init(_ thread: ChatThread) {
        id = thread.id
        projectID = thread.projectID
        title = thread.title
        createdAt = thread.createdAt
        updatedAt = thread.updatedAt
        selection = thread.selection
        accessMode = thread.accessMode
        interactionMode = thread.interactionMode
        isPinned = thread.isPinned
        isArchived = thread.isArchived
        snoozedUntil = thread.snoozedUntil
        worktreePath = thread.worktreePath
        branch = thread.branch
        hasDraft = !(thread.draft ?? "").isEmpty || !(thread.draftContext ?? []).isEmpty
        itemCount = thread.items.count
        hasUserMessages = thread.hasUserMessages
        sessionProviders = Self.ordered(thread.sessions.keys)
        nativeSessionIDs = thread.sessions.mapValues(\.sessionID)
        importedSession = thread.importedSession
    }

    nonisolated static func ordered(_ providers: some Sequence<ProviderKind>) -> [ProviderKind] {
        providers.sorted { $0.rawValue < $1.rawValue }
    }

    /// Follows an item appended to the thread at `date`.
    mutating func noteAppended(_ item: TranscriptItem, at date: Date) {
        itemCount += 1
        if item.kind == .user { hasUserMessages = true }
        updatedAt = date
    }
}

/// A thread file read for its summary only.
///
/// It reads what `ChatThread.init(from:)` reads, with the same requirements and fallbacks, but of each item
/// only its id and kind, so the text of a long transcript is never turned into strings. That keeps rebuilding
/// the index (a first launch after updating, or files another version changed) cheap. `ThreadSummaryTests`
/// checks that both readings agree.
struct ThreadSummaryFile: Decodable {
    var summary: ThreadSummary

    nonisolated init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: FileKey.self)
        let key = FileKey.init(_:)
        let id = try container.decode(UUID.self, forKey: key("id"))
        let projectID = try container.decode(UUID.self, forKey: key("projectID"))
        let createdAt = container.lenient(Date.self, forKey: key("createdAt")) ?? .distantPast
        let items = container.lenientArray(ItemKind.self, forKey: key("items"))
        let sessions = container.lenientProviderMap(ProviderSessionRef.self, forKey: key("sessions"))
        var thread = ChatThread(
            id: id, projectID: projectID,
            title: container.lenient(String.self, forKey: key("title")) ?? String(localized: "New thread"),
            selection: container.lenient(ModelSelection.self, forKey: key("selection"))
                ?? ModelSelection(provider: .claude, modelID: "default"),
            accessMode: container.lenient(AccessMode.self, forKey: key("accessMode")) ?? .approval,
            interactionMode: container.lenient(InteractionMode.self, forKey: key("interactionMode")) ?? .build,
            isPinned: container.lenient(Bool.self, forKey: key("isPinned")) ?? false,
            isArchived: container.lenient(Bool.self, forKey: key("isArchived")) ?? false,
            worktreePath: container.lenient(String.self, forKey: key("worktreePath")),
            branch: container.lenient(String.self, forKey: key("branch")),
            draft: container.lenient(String.self, forKey: key("draft")),
            draftContext: container.lenientArray(MessageContext.self, forKey: key("draftContext")), createdAt: createdAt)
        thread.updatedAt = container.lenient(Date.self, forKey: key("updatedAt")) ?? createdAt
        thread.snoozedUntil = container.lenient(Date.self, forKey: key("snoozedUntil"))
        thread.importedSession = container.lenient(ImportedSession.self, forKey: key("importedSession"))
        summary = ThreadSummary(thread)
        summary.itemCount = items.count
        summary.hasUserMessages = items.contains { $0.kind == .user }
        summary.sessionProviders = ThreadSummary.ordered(sessions.keys)
        summary.nativeSessionIDs = sessions.mapValues(\.sessionID)
    }

    /// An item's kind, read with the requirements of `TranscriptItem.init(from:)`, so the same items count.
    private struct ItemKind: Decodable {
        var kind: TranscriptItem.Kind

        nonisolated init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: FileKey.self)
            _ = try container.decode(UUID.self, forKey: FileKey("id"))
            kind = try container.decode(TranscriptItem.Kind.self, forKey: FileKey("kind"))
        }
    }
}
