import Foundation

/// `bots.json`: the user's bots, and whether the starters were offered.
struct BotsFile: Codable, Sendable {
    var addedStarters: Bool
    var bots: [Bot]
    /// Bots this version could not read, which loading leaves out (and copies the file aside for).
    var skipped = 0

    nonisolated init(addedStarters: Bool, bots: [Bot]) {
        self.addedStarters = addedStarters
        self.bots = bots
    }

    private enum CodingKeys: String, CodingKey {
        case addedStarters, bots
    }

    nonisolated init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        addedStarters = container.lenient(Bool.self, forKey: .addedStarters) ?? false
        let list = container.lenient(LenientList<Bot>.self, forKey: .bots)
        bots = list?.elements ?? []
        skipped = list?.skipped ?? 0
    }
}

/// Bots and their conversations (see `Bot`).
///
/// A bot's conversations are ordinary threads in the Bots container, which mirrors Chats: a project of Coincide's own
/// (`botsProject`), kept out of the user's projects, whose threads carry the bot's id (`ChatThread.botID`) and run in
/// the bot's folder (`workingDirectory(for:)`). The bots themselves are kept in `bots.json`.
extension AppStore {
    /// The Bots container's id, the same on every Mac, so it needs no saving.
    public nonisolated static let botsProjectID = UUID(uuidString: "B0B5B0B5-C01C-4D1E-B075-000000000001")!

    /// The home of bots' conversations. Its folder (`Bots` in Coincide's data folder) only stands in for a bot's own
    /// folder in places that ask a project for one.
    public var botsProject: Project {
        Project(
            id: Self.botsProjectID, name: String(localized: "Bots"),
            path: directory.appendingPathComponent("Bots", isDirectory: true).path, createdAt: .distantPast,
            isBots: true)
    }

    public func bot(_ id: UUID) -> Bot? { bots.first { $0.id == id } }

    /// The bot a thread is a conversation of, when it is one.
    public func bot(forThread threadID: UUID) -> Bot? {
        threadSummaries[threadID]?.botID.flatMap { bot($0) }
    }

    @discardableResult
    public func addBot(_ bot: Bot) -> Bot {
        bots.append(bot)
        saveBots()
        notify(.bots)
        return bot
    }

    public func updateBot(_ id: UUID, _ mutate: (inout Bot) -> Void) {
        guard let index = bots.firstIndex(where: { $0.id == id }) else { return }
        let before = bots[index]
        mutate(&bots[index])
        bots[index].id = id
        guard bots[index] != before else { return }
        saveBots()
        notify(.bots)
    }

    public func moveBot(from source: Int, to destination: Int) {
        guard bots.indices.contains(source) else { return }
        let bot = bots.remove(at: source)
        bots.insert(bot, at: min(max(0, destination), bots.count))
        saveBots()
        notify(.bots)
    }

    /// Removes a bot. Its conversations are deleted with it, or kept as chats: moved to Chats without the bot, and
    /// without their native sessions, which ran in the bot's folder; the next agent gets a recap instead. Live
    /// sessions are the caller's to end first (`ThreadRunner.shutdown(threadID:)`).
    public func deleteBot(_ id: UUID, deletingConversations: Bool) {
        guard bots.contains(where: { $0.id == id }) else { return }
        let conversations = threadSummaries.values.filter { $0.botID == id }.map(\.id)
        bots.removeAll { $0.id == id }
        saveBots()
        notify(.bots)
        if deletingConversations {
            for thread in conversations { deleteThread(thread) }
        } else {
            moveToChats(conversations)
        }
    }

    /// Adds the starter bots (`BotStarter.all`) the first time this is called, running on the user's default agent.
    /// Later calls do nothing, so starters the user deleted stay deleted. Returns whether it added them.
    @discardableResult
    public func addStarterBotsIfNeeded(selection: ModelSelection? = nil) -> Bool {
        guard !addedStarterBots else { return false }
        addedStarterBots = true
        let selection = selection ?? settings.defaultSelection
        let now = Date()
        // A bot the user already has (from a newer version, say) keeps its place; starters go after it.
        let existing = Set(bots.compactMap(\.starterID))
        for (offset, starter) in BotStarter.all.enumerated() where !existing.contains(starter.id) {
            bots.append(
                starter.makeBot(
                    selection: selection, accessMode: settings.defaultAccessMode,
                    createdAt: now.addingTimeInterval(Double(offset) / 1000)))
        }
        saveBots()
        notify(.bots)
        return true
    }

    /// A bot's conversations, the most recently active first. Archived ones are left out unless asked for.
    public func conversations(of botID: UUID, includeArchived: Bool = false) -> [ThreadSummary] {
        threadSummaries.values
            .filter { $0.botID == botID && (includeArchived || !$0.isArchived) }
            .sorted { $0.updatedAt > $1.updatedAt }
    }

    /// The conversation a bot's row opens: its most recently active one.
    public func latestConversation(of botID: UUID) -> ThreadSummary? {
        conversations(of: botID).first
    }

    /// Starts a new conversation with a bot, on its agent, model and modes. Its earlier conversations stay.
    @discardableResult
    public func startConversation(with botID: UUID, selection: ModelSelection? = nil) -> ChatThread? {
        guard let bot = bot(botID) else { return nil }
        let thread = ChatThread(
            projectID: Self.botsProjectID, title: String(localized: "New conversation"),
            selection: selection ?? bot.selection, accessMode: bot.accessMode, interactionMode: bot.interactionMode,
            botID: bot.id)
        insert(thread)
        return thread
    }

    /// Conversations whose bot is gone (deleted while one was set aside for Undo, or a `bots.json` that could not be
    /// read) become chats rather than disappearing from the sidebar.
    func rehomeOrphanedBotConversations() {
        let orphans = threadSummaries.values.filter { thread in
            thread.botID.map { id in !bots.contains { $0.id == id } } ?? (thread.projectID == Self.botsProjectID)
        }
        guard !orphans.isEmpty else { return }
        moveToChats(orphans.map(\.id))
    }

    private func moveToChats(_ threadIDs: [UUID]) {
        guard !threadIDs.isEmpty else { return }
        let chats = ensureChatsProject()
        for id in threadIDs {
            updateThread(id) { thread in
                thread.projectID = chats.id
                thread.botID = nil
                thread.sessions = [:]
                thread.accountSessions = nil
            }
        }
        notify(.threadList)
    }
}
