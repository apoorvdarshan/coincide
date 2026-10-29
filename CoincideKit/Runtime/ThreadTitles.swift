import Foundation

/// Names a new thread from its first message with the user's own agent, as T3 Code does, so it can be recognized
/// weeks later. Until the agent answers, and when it can't, the thread keeps the start of the message.
@MainActor
enum ThreadTitles {
    /// How long the agent may take before the thread keeps its first title.
    static var timeout: TimeInterval = 90

    /// Asks the agent for a title and sets it, unless the thread was renamed meanwhile.
    static func generate(
        threadID: UUID, message: String, provisional: String, selection: ModelSelection, cwd: URL, store: AppStore,
        registry: ProviderRegistry
    ) async {
        let reply = await AgentPrompt.run(
            prompt(message: message), selection: titleSelection(for: selection, registry: registry), cwd: cwd,
            timeout: timeout, registry: registry)
        guard let reply, let title = title(fromReply: reply), store.summary(threadID)?.title == provisional else { return }
        store.updateThread(threadID) { $0.title = title }
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

    /// T3 Code's title brief, trimmed to what applies before the agent has done any work.
    static func prompt(message: String) -> String {
        """
        Generate a title that will help the user recognize this coding thread weeks later.
        Answer with only a JSON object with the key "title": no prose, no code fences. Do not run tools or edit files.

        Before answering, silently reduce the request to its subject (what system, feature or problem it is about) and \
        outcome (what the user wants to understand or change). Title those; leave out instructions about how the agent \
        should work.

        Rules:
        - 3 to 8 words, fewer than 40 characters.
        - A compact noun phrase or clear action phrase, in sentence case.
        - Capture the umbrella goal when the request lists several symptoms or steps.
        - Leave out models, agents, tools and output formats unless they are the topic.
        - Do not claim the work is done, and do not copy and truncate the message.
        - No quotes, labels, filler or trailing punctuation.

        The user's first message:
        <message>
        \(String(message.prefix(4_000)))
        </message>
        """
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
