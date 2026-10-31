import Foundation

/// A bot's character, color and name while the user edits them in Coincide Remote, picked by the rules of the Mac's bot
/// editor (`BotEditor`), so the two apps behave alike.
public struct BotEditorLook: Hashable, Sendable {
    public var character: BotArtwork.Character
    public var tint: BotArtwork.Tint
    public var name: String

    public init(character: BotArtwork.Character, tint: BotArtwork.Tint, name: String) {
        self.character = character
        self.tint = tint
        self.name = name
    }

    /// A character in its own color, with its name.
    public init(character: BotArtwork.Character) {
        self.init(character: character, tint: character.defaultTint, name: character.defaultName)
    }

    /// A new bot's look: a character none of the bots in `used` is yet when one is left, in its own color and with its
    /// name.
    public static func newBot(avoiding used: Set<BotArtwork.Character>) -> BotEditorLook {
        let characters = BotArtwork.Character.allCases
        let character = characters.filter { !used.contains($0) }.randomElement() ?? characters.randomElement() ?? .alien
        return BotEditorLook(character: character)
    }

    /// Picks `option`: it comes in its own color, and brings its name while the bot still has the previous character's
    /// (or none). A name the user wrote stays. The color can be changed afterwards.
    public mutating func pick(_ option: BotArtwork.Character) {
        guard option != character else { return }
        let written = name.trimmingCharacters(in: .whitespacesAndNewlines)
        if written.isEmpty || written == character.defaultName { name = option.defaultName }
        character = option
        tint = option.defaultTint
    }

    /// The color `option` shows in the character picker: the chosen character in the bot's color, every other in its
    /// own.
    public func pickerTint(for option: BotArtwork.Character) -> BotArtwork.Tint {
        option == character ? tint : option.defaultTint
    }
}
