import Foundation

/// Names a new thread from its first message with the user's own agent, as T3 Code does, so it can be recognized
/// weeks later. Until the agent answers, and when it can't, the thread keeps the start of the message.
///
/// Naming ends with one look at the title once the first reply shows what a short first message was about
/// (`TitleRefresh.firstReply`). Only when the user keeps titles up to date (`AppSettings.updatesThreadTitles`) does
/// the agent look again, every few turns and minutes of a thread in use, much as Claude Code renames a session as its
/// topic moves on. Every look follows a turn the user started that just completed: never a launch, a timer or an idle
/// thread. Each sends only the title and a few hundred characters of the conversation, and keeps the title when it
/// still fits. A thread the user named is never titled by the agent again.
@MainActor
enum ThreadTitles {
    /// How long the agent may take before the thread keeps its title.
    static var timeout: TimeInterval = 90

    /// Naming's look comes only while a thread is within this many turns.
    static let namingTurns = 5
    /// While titles are kept up to date: the turns and the time between looks, and the most looks a thread gets.
    static let updateTurns = 5
    static let updateInterval: TimeInterval = 10 * 60
    static let maximumUpdates = 12

    /// How much of each part of the conversation a refresh sends.
    nonisolated static let refreshTitleLimit = 100
    nonisolated static let refreshMessageLimit = 300
    nonisolated static let refreshReplyLimit = 300

    /// First titles being asked for, so a refresh waits for its thread's first title rather than racing it.
    private static var firstTitles: [UUID: Task<Void, Never>] = [:]
    /// Threads with a look under way, so a thread never has two at once.
    private static var refreshing: Set<UUID> = []

    /// Whether the agent is looking at the thread's title again right now.
    static func isRefreshing(_ threadID: UUID) -> Bool { refreshing.contains(threadID) }

    /// Asks the agent for a first title in the background (see `generate`).
    static func start(
        threadID: UUID, message: String, provisional: String, selection: ModelSelection, cwd: URL, store: AppStore,
        registry: ProviderRegistry
    ) {
        firstTitles[threadID] = Task {
            await generate(
                threadID: threadID, message: message, provisional: provisional, selection: selection, cwd: cwd,
                store: store, registry: registry)
            firstTitles[threadID] = nil
        }
    }

    /// Asks the agent for a title and sets it, unless the thread was renamed meanwhile.
    static func generate(
        threadID: UUID, message: String, provisional: String, selection: ModelSelection, cwd: URL, store: AppStore,
        registry: ProviderRegistry
    ) async {
        let reply = await AgentPrompt.run(
            prompt(message: message), selection: titleSelection(for: selection, registry: registry), cwd: cwd,
            timeout: timeout, registry: registry)
        apply(reply, to: threadID, replacing: provisional, store: store)
    }

    /// The agent the thread uses, with its lightest model and reasoning when the catalog has one meant for quick
    /// work (Claude's Haiku, Codex's Luna), as T3 Code titles with a small model.
    static func titleSelection(for selection: ModelSelection, registry: ProviderRegistry) -> ModelSelection {
        let models = registry.models(for: selection.provider, account: selection.accountID)
        let quick = models.first { model in
            let id = model.modelID.lowercased()
            return id.contains("haiku") || id.contains("luna") || id.contains("mini") || id.contains("flash")
        }
        let model = quick ?? registry.model(for: selection)
        // The thread's account pays for its title too.
        return ModelSelection(
            provider: selection.provider, modelID: model?.modelID ?? selection.modelID,
            effort: model?.efforts.first ?? selection.effort, accountID: selection.accountID)
    }

    // MARK: Refreshes

    /// After a turn the user started completed: has the agent look at the title again when a look is due, in the
    /// background. Returns the look it started.
    @discardableResult
    static func refreshIfDue(threadID: UUID, store: AppStore, registry: ProviderRegistry, now: Date = Date()) -> TitleRefresh? {
        guard store.settings.generatesThreadTitles, !refreshing.contains(threadID), let thread = store.thread(threadID),
            let due = dueRefresh(
                for: thread, isFork: store.lineage(of: threadID) != nil, updates: store.settings.updatesThreadTitles,
                now: now),
            let cwd = store.workingDirectory(for: threadID),
            let parts = RefreshParts(thread)
        else { return nil }
        // Counted when asked, so a relaunch, a failure or a quick next turn never asks twice.
        let turns = thread.items.count(where: \.opensUserTurn)
        store.updateThread(threadID) {
            $0.titleRefreshes = ($0.titleRefreshes ?? []) + [due]
            $0.titleCheckTurns = turns
            $0.titleCheckedAt = now
        }
        refreshing.insert(threadID)
        let selection = titleSelection(for: thread.selection, registry: registry)
        let first = firstTitles[threadID]
        Task {
            defer { refreshing.remove(threadID) }
            // The first title, still on its way, is the one to look at.
            await first?.value
            guard wants(due, store: store), let summary = store.summary(threadID), !summary.isTitleCustom else { return }
            let title = summary.title
            let reply = await AgentPrompt.run(
                refreshPrompt(title: title, parts: parts), selection: selection, cwd: cwd, timeout: timeout,
                registry: registry)
            // Turned off while the agent thought: the answer is dropped.
            guard wants(due, store: store) else { return }
            apply(reply, to: threadID, replacing: title, store: store)
        }
        return due
    }

    /// Whether the settings still ask for this look.
    private static func wants(_ refresh: TitleRefresh, store: AppStore) -> Bool {
        store.settings.generatesThreadTitles && (refresh != .update || store.settings.updatesThreadTitles)
    }

    /// The look a thread is due after a turn the user started completed, if any. None for a thread the user named or
    /// an archived one.
    ///
    /// Naming's look (`firstReply`) comes at the first completed turn, once, while the thread is within its first
    /// `namingTurns`. With `updates` on, another (`update`) comes once `updateTurns` more turns and `updateInterval`
    /// have passed since the last look, up to `maximumUpdates`, so a thread nobody writes in is never looked at.
    ///
    /// A thread from before looks were counted (`titleRefreshes` is nil) joins in at its next completed turn, never at
    /// launch. Imports and forks (`isFork`) came with their messages and the titles that went with them, and keep those.
    static func dueRefresh(for thread: ChatThread, isFork: Bool, updates: Bool, now: Date) -> TitleRefresh? {
        guard !thread.isTitleCustom, !thread.isArchived else { return nil }
        guard let done = thread.titleRefreshes ?? (thread.importedSession == nil && !isFork ? [] : nil) else { return nil }
        let turns = thread.items.count(where: \.opensUserTurn)
        if !done.contains(.firstReply), !done.contains(.fifthTurn), turns < namingTurns { return .firstReply }
        guard updates, done.count(where: { $0 == .update }) < maximumUpdates else { return nil }
        // Without a recorded look: naming's came at the first turn, an older version's at the fifth.
        let last = thread.titleCheckTurns ?? (done.contains(.fifthTurn) ? namingTurns : done.contains(.firstReply) ? 1 : 0)
        guard turns - last >= updateTurns else { return nil }
        if let checked = thread.titleCheckedAt, now.timeIntervalSince(checked) < updateInterval { return nil }
        return .update
    }

    /// What a refresh tells the agent about the thread, each part trimmed.
    struct RefreshParts: Equatable {
        var firstMessage: String
        /// Nil while the latest message is the first one.
        var latestMessage: String?
        var latestReply: String

        init(firstMessage: String, latestMessage: String?, latestReply: String) {
            self.firstMessage = firstMessage
            self.latestMessage = latestMessage
            self.latestReply = latestReply
        }

        /// Nil for a thread without a message to go by.
        init?(_ thread: ChatThread) {
            let messages = thread.items.indices.filter { thread.items[$0].kind == .user && !thread.items[$0].text.isEmpty }
            guard let first = messages.first, let latest = messages.last else { return nil }
            firstMessage = ThreadTitles.clip(thread.items[first].text, to: ThreadTitles.refreshMessageLimit)
            latestMessage = latest == first ? nil : ThreadTitles.clip(thread.items[latest].text, to: ThreadTitles.refreshMessageLimit)
            let reply = thread.items[(latest + 1)...].filter { $0.kind == .assistant }.map(\.text).joined(separator: "\n")
            latestReply = ThreadTitles.clip(reply, to: ThreadTitles.refreshReplyLimit)
        }
    }

    /// The text on one line, at most `limit` characters.
    nonisolated static func clip(_ text: String, to limit: Int) -> String {
        let line = text.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        return line.count > limit ? String(line.prefix(limit - 1)) + "…" : line
    }

    // MARK: Prompts

    /// T3 Code's title brief, trimmed to what applies before the agent has done any work.
    static func prompt(message: String) -> String {
        """
        Generate a title that will help the user recognize this coding thread weeks later.
        Answer with only a JSON object with the key "title": no prose, no code fences. Do not run tools or edit files.

        Before answering, silently reduce the request to its subject (what system, feature or problem it is about) and \
        outcome (what the user wants to understand or change). Title those; leave out instructions about how the agent \
        should work.

        \(rules)

        The user's first message:
        <message>
        \(String(message.prefix(4_000)))
        </message>
        """
    }

    /// The same brief for a thread under way: keep the title while it fits, else a better one.
    static func refreshPrompt(title: String, parts: RefreshParts) -> String {
        var conversation = """
            The user's first message:
            <message>
            \(parts.firstMessage)
            </message>
            """
        if let latest = parts.latestMessage {
            conversation += """

                The user's latest message:
                <message>
                \(latest)
                </message>
                """
        }
        if !parts.latestReply.isEmpty {
            conversation += """

                The start of the agent's latest reply:
                <reply>
                \(parts.latestReply)
                </reply>
                """
        }
        return """
            Check the title of a coding thread, so the user can recognize the thread weeks later.
            Answer with only a JSON object with the key "title": no prose, no code fences. Do not run tools or edit files.

            If the current title still fits the thread's subject, answer with it unchanged. Otherwise give a better one: \
            silently reduce the thread to its subject (what system, feature or problem it is about) and outcome (what the \
            user wants to understand or change), and title those, leaving out instructions about how the agent should work.

            \(rules)

            The current title:
            <title>
            \(clip(title, to: refreshTitleLimit))
            </title>

            \(conversation)
            """
    }

    private static let rules = """
        Rules:
        - 3 to 8 words, fewer than 40 characters.
        - A compact noun phrase or clear action phrase, in sentence case.
        - Capture the umbrella goal when the request lists several symptoms or steps.
        - Leave out models, agents, tools and output formats unless they are the topic.
        - Do not claim the work is done, and do not copy and truncate the message.
        - No quotes, labels, filler or trailing punctuation.
        """

    // MARK: Replies

    /// Sets the title in the agent's reply, unless the thread's title is no longer `previous` (renamed, or titled
    /// again meanwhile) or the user named it. Returns whether it did. An unusable reply changes nothing.
    @discardableResult
    static func apply(_ reply: String?, to threadID: UUID, replacing previous: String, store: AppStore) -> Bool {
        guard let reply, let title = title(fromReply: reply), let summary = store.summary(threadID),
            summary.title == previous, !summary.isTitleCustom, title != previous
        else { return false }
        store.updateThread(threadID) { $0.title = title }
        return true
    }

    /// The title in the agent's JSON reply, tidied: one line, no quotes or trailing punctuation, at most 60 characters.
    static func title(fromReply reply: String) -> String? {
        guard let raw = GitWriter.extractJSON(reply, requiredKeys: ["title"])?["title"]?.string else { return nil }
        var title = raw.split(whereSeparator: \.isNewline).first.map(String.init) ?? ""
        title = title.trimmingCharacters(in: .whitespaces.union(CharacterSet(charactersIn: "\"'“”‘’`")))
        while let last = title.last, ".!:;,".contains(last) { title.removeLast() }
        title = title.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        guard !title.isEmpty else { return nil }
        return title.count > 60 ? String(title.prefix(59)).trimmingCharacters(in: .whitespaces) + "…" : title
    }
}

extension AppStore {
    /// Names a thread as the user asked. The agent leaves its title alone from then on.
    public func renameThread(_ id: UUID, to title: String) {
        updateThread(id) {
            $0.title = title
            $0.titledByUser = true
        }
    }
}
