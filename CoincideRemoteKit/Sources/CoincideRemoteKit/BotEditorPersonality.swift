import Foundation

/// The personality in the phone's bot editor, by the rules of the Mac's (`BotPersonalitySection`): none, a preset, or
/// the user's own description, which is kept while a preset is chosen so switching back to Custom finds it again.
/// Until the user picks one, a new character brings its own personality, as it brings its name. Presets go by id; the
/// iOS app has their names and text (`BotPersonalityPreset`) and passes in which personality each character comes with.
public struct BotEditorPersonality: Hashable, Sendable {
    public enum Choice: Hashable, Sendable {
        case none
        case preset(String)
        case custom
    }

    /// The most a description the user writes may hold, in characters, as on the Mac (`BotPersonalityPreset.customLimit`).
    public static let customLimit = 4_000

    public private(set) var choice: Choice
    /// The user's own description. Set it while Custom is chosen; it's cut to `customLimit`.
    public var custom: String {
        didSet { if custom.count > Self.customLimit { custom = String(custom.prefix(Self.customLimit)) } }
    }
    /// Whether the user picked one in the editor.
    public private(set) var userPicked = false
    /// What a bot being edited had, so saving it unchanged sends nothing and the Mac keeps the bot's own: one this
    /// phone can't show, say. Nil for a new bot, which always sends its personality.
    private let original: RemoteBotPersonality??

    /// A bot's personality, to edit.
    public init(editing personality: RemoteBotPersonality?) {
        choice = Self.choice(of: personality)
        custom = String((personality?.custom ?? "").prefix(Self.customLimit))
        original = .some(personality)
    }

    /// A new bot's: its character's own, as on the Mac.
    public init(newBotAs character: String, defaultID: (String) -> String?) {
        choice = defaultID(character).map(Choice.preset) ?? .none
        custom = ""
        original = nil
    }

    private static func choice(of personality: RemoteBotPersonality?) -> Choice {
        guard let personality, !personality.isEmpty else { return .none }
        if let preset = personality.preset, !preset.isEmpty { return .preset(preset) }
        return .custom
    }

    /// The preset chosen, by id.
    public var presetID: String? {
        if case .preset(let id) = choice { return id }
        return nil
    }

    public mutating func pick(_ choice: Choice) {
        userPicked = true
        self.choice = choice
    }

    /// Custom, starting from a preset's text for the user to make their own.
    public mutating func start(from prompt: String) {
        pick(.custom)
        custom = prompt
    }

    /// A new character brings its own personality while the user hasn't picked one, and the bot has none or the
    /// previous character's.
    public mutating func suggest(for character: String, replacing previous: String, defaultID: (String) -> String?) {
        guard !userPicked, choice == .none || presetID == defaultID(previous) else { return }
        choice = defaultID(character).map(Choice.preset) ?? .none
    }

    /// What the editor shows, to send: an empty personality for none.
    public var personality: RemoteBotPersonality {
        let text = custom.trimmingCharacters(in: .whitespacesAndNewlines)
        switch choice {
        case .none: return RemoteBotPersonality()
        case .preset(let id): return RemoteBotPersonality(preset: id, custom: text.isEmpty ? nil : text)
        case .custom: return RemoteBotPersonality(custom: text.isEmpty ? nil : text)
        }
    }

    /// The personality for the bot draft (`RemoteBotDraft.personality`): nil when a bot being edited keeps its own.
    public var draft: RemoteBotPersonality? {
        let personality = personality
        guard case .some(let original) = original else { return personality }
        let unchanged =
            Self.choice(of: original) == choice
            && (original?.custom ?? "").trimmingCharacters(in: .whitespacesAndNewlines) == (personality.custom ?? "")
        return unchanged ? nil : personality
    }
}
