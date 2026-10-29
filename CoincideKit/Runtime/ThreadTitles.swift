import Foundation

/// Names a new thread from its first message with the user's own agent, as T3 Code does, so it can be recognized
/// weeks later. Until the agent answers, and when it can't, the thread keeps the start of the message.
///
/// The agent looks at the title again twice in the thread's life (`TitleRefresh`): once its first reply shows what a
/// short first message was about, and after the fifth turn, when the thread may have moved on. Each look sends only
/// the title and a few hundred characters of the conversation, and keeps the title when it still fits. A thread the
/// user named is never titled by the agent again.
@MainActor
enum ThreadTitles {
    /// How long the agent may take before the thread keeps its title.
    static var timeout: TimeInterval = 90

    /// The user turns after which the agent looks at the title a second time.
    static let laterRefreshTurns = 5

    /// How much of each part of the conversation a refresh sends.
    nonisolated static let refreshTitleLimit = 100
    nonisolated static let refreshMessageLimit = 300
    nonisolated static let refreshReplyLimit = 300

    /// First titles being asked for, so a refresh waits for its thread's first title rather than racing it.
    private static var firstTitles: [UUID: Task<Void, Never>] = [:]

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

    /// After a turn completed: has the agent look at the title again when a refresh is due, in the background.
    /// Returns the refresh it started.
    @discardableResult
    static func refreshIfDue(threadID: UUID, store: AppStore, registry: ProviderRegistry) -> TitleRefresh? {
        guard store.settings.generatesThreadTitles, let thread = store.thread(threadID),
            let due = dueRefresh(for: thread), let cwd = store.workingDirectory(for: threadID),
            let parts = RefreshParts(thread)
        else { return nil }
        // Counted when asked, so a relaunch, a failure or a quick next turn never asks twice.
        store.updateThread(threadID) { $0.titleRefreshes = ($0.titleRefreshes ?? []) + [due] }
        let selection = titleSelection(for: thread.selection, registry: registry)
        let first = firstTitles[threadID]
        Task {
            // The first title, still on its way, is the one to look at.
            await first?.value
            guard store.settings.generatesThreadTitles, let summary = store.summary(threadID), !summary.isTitleCustom
            else { return }
            let title = summary.title
            let reply = await AgentPrompt.run(
                refreshPrompt(title: title, parts: parts), selection: selection, cwd: cwd, timeout: timeout,
                registry: registry)
            apply(reply, to: threadID, replacing: title, store: store)
        }
        return due
    }

    /// The refresh a thread is due after a completed turn, if any: the first after its first completed turn, the
    /// second after its fifth, each once. None for a thread the user named, an archived one, or one from before
    /// refreshes (`titleRefreshes` is nil).
    static func dueRefresh(for thread: ChatThread) -> TitleRefresh? {
        guard !thread.isTitleCustom, !thread.isArchived, let done = thread.titleRefreshes else { return nil }
        let due: TitleRefresh = thread.items.count(where: \.opensUserTurn) >= laterRefreshTurns ? .fifthTurn : .firstReply
        return done.contains(due) ? nil : due
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
