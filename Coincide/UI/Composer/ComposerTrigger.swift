import CoincideKit
import Foundation

/// The word before the caret when it asks for completions: `@path` or `/command`.
nonisolated struct ComposerTrigger: Equatable, Sendable {
    enum Kind: Sendable {
        case path
        case command
    }

    var kind: Kind
    /// What follows the `@` or `/`.
    var query: String
    /// UTF-16 range of the whole word, `@` or `/` included.
    var range: NSRange

    /// Finds the trigger in the word that ends at `cursor`, a UTF-16 offset into `text`.
    static func detect(in text: String, cursor: Int) -> ComposerTrigger? {
        let string = text as NSString
        let cursor = min(max(cursor, 0), string.length)
        var start = cursor
        while start > 0, !isWhitespace(string.character(at: start - 1)) { start -= 1 }
        guard start < cursor else { return nil }
        let range = NSRange(location: start, length: cursor - start)
        let query = string.substring(with: NSRange(location: start + 1, length: cursor - start - 1))
        switch string.character(at: start) {
        case 0x40:  // @
            return ComposerTrigger(kind: .path, query: query, range: range)
        case 0x2F:  // /
            // A second slash anywhere in the word makes it a path such as /usr/bin, not a command.
            var end = cursor
            while end < string.length, !isWhitespace(string.character(at: end)) { end += 1 }
            let word = string.substring(with: NSRange(location: start + 1, length: end - start - 1))
            return word.contains("/") ? nil : ComposerTrigger(kind: .command, query: query, range: range)
        default:
            return nil
        }
    }

    static func isWhitespace(_ character: unichar) -> Bool {
        guard let scalar = Unicode.Scalar(character) else { return false }
        return CharacterSet.whitespacesAndNewlines.contains(scalar)
    }

    /// How a file is mentioned in a message: `@path`, quoted when the path has spaces.
    static func mention(_ path: String) -> String {
        path.contains(where: \.isWhitespace) ? "@\"\(path)\"" : "@" + path
    }
}

/// Commands typed as `/name` in the composer. They change the thread instead of being sent.
nonisolated enum ComposerCommand: Hashable, Sendable {
    case model
    case plan
    case build
    /// Shows the selected agent's subscription limits (T3 Code's `/usage-limits`).
    case usageLimits
    /// Continues the thread with another agent, such as `/codex`.
    case agent(ProviderKind)

    /// The built-in commands followed by one per agent the user can switch to. `/usage-limits` is offered when the
    /// selected agent reported its limits, `/plan` and `/build` when it has a plan mode.
    static func available(agents: [ProviderKind], usageLimits: Bool = false, planMode: Bool = true) -> [ComposerCommand] {
        [.model] + (planMode ? [.plan, .build] : []) + (usageLimits ? [.usageLimits] : []) + agents.map { .agent($0) }
    }

    var name: String {
        switch self {
        case .model: "model"
        case .plan: "plan"
        case .build: "build"
        case .usageLimits: "usage-limits"
        case .agent(let provider): provider.commandName
        }
    }

    var title: String { "/" + name }

    var summary: String {
        switch self {
        case .model: String(localized: "Switch the agent or model for this thread")
        case .plan: String(localized: "Switch this thread into plan mode")
        case .build: String(localized: "Switch this thread back to build mode")
        case .usageLimits: String(localized: "Show this agent's usage limits")
        case .agent(let provider): String(localized: "Continue this thread with \(provider.displayName)")
        }
    }

    var symbolName: String {
        switch self {
        case .model: "cpu"
        case .plan: "pencil.and.ruler"
        case .build: "hammer"
        case .usageLimits: "gauge.with.needle"
        case .agent(let provider): provider.symbolName
        }
    }

    /// Commands matching `query`, best match first.
    static func matching(_ query: String, in commands: [ComposerCommand]) -> [ComposerCommand] {
        let query = query.lowercased()
        guard !query.isEmpty else { return commands }
        let ranked = commands.enumerated().compactMap { index, command -> (rank: Int, index: Int, command: ComposerCommand)? in
            let names = command.names
            if names.contains(query) { return (0, index, command) }
            if names.contains(where: { $0.hasPrefix(query) }) { return (1, index, command) }
            if names.contains(where: { $0.contains(query) }) { return (2, index, command) }
            if command.summary.lowercased().contains(query) { return (3, index, command) }
            return nil
        }
        return ranked.sorted { ($0.rank, $0.index) < ($1.rank, $1.index) }.map(\.command)
    }

    /// The command when the whole message is one, such as `/plan`.
    static func standalone(_ text: String, in commands: [ComposerCommand]) -> ComposerCommand? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard trimmed.hasPrefix("/") else { return nil }
        let name = String(trimmed.dropFirst())
        return commands.first { $0.names.contains(name) }
    }

    /// The command's name plus aliases; `/default` is T3 Code's name for build mode.
    private var names: [String] {
        self == .build ? [name, "default"] : [name]
    }
}

/// One row of the completion popup.
nonisolated enum ComposerSuggestion: Equatable, Sendable {
    case file(ComposerFileEntry)
    case command(ComposerCommand)
}
