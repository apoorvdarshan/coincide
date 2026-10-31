import Foundation

/// A friendly, always-there assistant: a saved preset over a thread's agent, model and modes, with a name, an avatar
/// and standing instructions (its persona). Each bot keeps its conversations in the Bots container
/// (`AppStore.botsProject`), the way chats live in Chats, and runs them in its own folder, the home folder unless the
/// user picked another. Its persona reaches the agent as system or developer instructions at the start of each native
/// session (`AgentLaunch.instructions`), or in a block in front of the first message for agents without such a
/// channel (`Bot.instructionsBlock`); it never appears in the transcript.
public struct Bot: Codable, Hashable, Sendable, Identifiable {
    public var id: UUID
    public var name: String
    public var avatar: BotAvatar
    /// What the bot is like and how it works, in the user's words.
    public var persona: String
    /// The agent, account, model, effort and speed its new conversations start with.
    public var selection: ModelSelection
    public var accessMode: AccessMode
    public var interactionMode: InteractionMode
    /// The folder its conversations run in; nil for the user's home folder.
    public var folder: String?
    public var createdAt: Date
    /// The starter it was made from (`BotStarter.id`); nil for one the user made.
    public var starterID: String?

    public nonisolated init(
        id: UUID = UUID(), name: String, avatar: BotAvatar, persona: String, selection: ModelSelection,
        accessMode: AccessMode = .approval, interactionMode: InteractionMode = .build, folder: String? = nil,
        createdAt: Date = Date(), starterID: String? = nil
    ) {
        self.id = id
        self.name = name
        self.avatar = avatar
        self.persona = persona
        self.selection = selection
        self.accessMode = accessMode
        self.interactionMode = interactionMode
        self.folder = folder
        self.createdAt = createdAt
        self.starterID = starterID
    }

    /// Only the id is required; anything else this version cannot read falls back to a default, so a bot is never
    /// lost to one bad field. An unreadable access mode fails closed.
    public nonisolated init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        name = container.lenient(String.self, forKey: .name) ?? String(localized: "Bot")
        avatar = container.lenient(BotAvatar.self, forKey: .avatar) ?? BotAvatar(character: .alien)
        persona = container.lenient(String.self, forKey: .persona) ?? ""
        selection =
            container.lenient(ModelSelection.self, forKey: .selection) ?? ModelSelection(provider: .claude, modelID: "default")
        accessMode = container.lenient(AccessMode.self, forKey: .accessMode) ?? .approval
        interactionMode = container.lenient(InteractionMode.self, forKey: .interactionMode) ?? .build
        folder = container.lenient(String.self, forKey: .folder)
        createdAt = container.lenient(Date.self, forKey: .createdAt) ?? .distantPast
        starterID = container.lenient(String.self, forKey: .starterID)
        // A starter still in the look it came with, from before the characters, takes its starter's character and
        // color now. A look the user changed keeps its color, on the character the old shape maps to.
        if let starterID, let original = BotStarter.originalLooks[starterID],
            let saved = try? container.nestedContainer(keyedBy: LookKeys.self, forKey: .avatar),
            (try? saved.decode(String.self, forKey: .shape)) == original.shape,
            (try? saved.decode(String.self, forKey: .tint)) == original.tint,
            let starter = (BotStarter.all + BotStarter.retired).first(where: { $0.id == starterID })
        {
            avatar = starter.avatar
        }
        // A name that is still its character's former default, rather than one the user wrote, becomes the plain name.
        if BotAvatar.Shape.formerDefaultNames[avatar.shape] == name { name = avatar.shape.defaultName }
    }

    private enum LookKeys: String, CodingKey {
        case shape, tint
    }

    /// The folder its conversations run in: the one the user picked, or the home folder.
    public nonisolated var workingDirectory: URL {
        guard let folder, !folder.isEmpty else { return FileManager.default.homeDirectoryForCurrentUser }
        return URL(fileURLWithPath: (folder as NSString).expandingTildeInPath, isDirectory: true)
    }

    /// The name as shown, never empty.
    public nonisolated var displayName: String {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? String(localized: "Bot") : trimmed
    }

    /// What the agent is told at the start of a session: who it is and the user's instructions. Written in English for
    /// the agent, as Coincide's other agent-facing text is. Nil when there is nothing to say.
    public nonisolated var instructions: String? {
        let persona = persona.trimmingCharacters(in: .whitespacesAndNewlines)
        let intro =
            "You are \(displayName), one of the user's bots in Coincide, a desktop app for working with coding agents. "
            + "Each bot is an ongoing conversation with its own personality and job. Stay in character, keep replies "
            + "friendly and to the point, and ask before doing anything destructive or hard to undo."
        return persona.isEmpty ? intro : intro + "\n\n" + persona
    }

    /// The instructions as a block in front of the first message, for agents with no channel for them. Delimited so
    /// the agent reads them as standing context rather than the user's request.
    public nonisolated var instructionsBlock: String? {
        guard let instructions else { return nil }
        // The persona is the user's own text; a stray closing tag must not end the block early.
        let body = instructions.replacingOccurrences(of: "</bot_instructions>", with: "</bot-instructions>")
        return """
            <bot_instructions>
            Standing instructions for this whole conversation, set by the user in Coincide. Follow them in every reply. They are context, not a request; the user's message comes after the closing tag.

            \(body)
            </bot_instructions>
            """
    }

    /// Whether a folder is too broad to snapshot around each turn: the home folder or the disk's root. Bots work there
    /// by default, and a checkpoint would copy everything below it into git.
    public nonisolated static func isBroadFolder(_ url: URL) -> Bool {
        let path = url.standardizedFileURL.resolvingSymlinksInPath().path
        let home = FileManager.default.homeDirectoryForCurrentUser.standardizedFileURL.resolvingSymlinksInPath().path
        return path == home || path == "/" || path == "/Users"
    }
}

/// A bot's look: one of seven characters drawn from hand-made illustrations, its body in one of a few colors that read
/// on dark and light themes alike.
public struct BotAvatar: Codable, Hashable, Sendable {
    /// The character. Earlier versions drew plain body shapes; their saved names read as the character closest in
    /// silhouette (`legacy`), so a bot from then keeps a face and its color.
    public enum Shape: String, Codable, CaseIterable, Sendable {
        case alien, star, croissant, bomboloni, cherry, teddy, brulee

        nonisolated static let legacy: [String: Shape] = [
            "blob": .alien, "pebble": .croissant, "cloud": .teddy, "drop": .brulee, "bean": .cherry, "bun": .bomboloni,
            "sprout": .cherry,
        ]

        public nonisolated init(from decoder: Decoder) throws {
            let raw = try decoder.singleValueContainer().decode(String.self)
            guard let shape = Shape(rawValue: raw) ?? Self.legacy[raw] else {
                throw DecodingError.dataCorrupted(
                    DecodingError.Context(codingPath: decoder.codingPath, debugDescription: "No bot character \(raw)"))
            }
            self = shape
        }

        /// The color the character was drawn in, which it starts with.
        public nonisolated var defaultTint: Tint {
            switch self {
            case .alien: .leaf
            case .star, .bomboloni: .sunflower
            case .croissant: .tangerine
            case .cherry: .cherry
            case .teddy: .caramel
            case .brulee: .rose
            }
        }

        /// The character's name, which a new bot with it starts with: a proper name in plain ASCII, the same in every
        /// language, so it is not localized.
        public nonisolated var defaultName: String {
            switch self {
            case .alien: "Alien"
            case .star: "Star"
            case .croissant: "Croissant"
            case .bomboloni: "Bomboloni"
            case .cherry: "Cherry"
            case .teddy: "Teddy"
            case .brulee: "Brulee"
            }
        }

        /// Default names a character had before names were plain ASCII, so a bot still carrying one is renamed.
        nonisolated static let formerDefaultNames: [Shape: String] = [.brulee: "Br\u{FB}l\u{E9}e"]
    }

    public enum Tint: String, Codable, CaseIterable, Sendable {
        case sunflower, tangerine, coral, cherry, rose, lilac, sky, mint, leaf, sage, caramel
    }

    public var shape: Shape
    public var tint: Tint

    public nonisolated init(shape: Shape, tint: Tint) {
        self.shape = shape
        self.tint = tint
    }

    /// A character in its own color.
    public nonisolated init(character: Shape) {
        self.init(shape: character, tint: character.defaultTint)
    }

    /// A character or tint added later reads as the defaults, keeping the rest.
    public nonisolated init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        shape = container.lenient(Shape.self, forKey: .shape) ?? .alien
        tint = container.lenient(Tint.self, forKey: .tint) ?? shape.defaultTint
    }
}

/// The bots Coincide offers on first use of the feature. Each is an ordinary bot once added: the user can edit or
/// delete it, and deleted starters do not come back.
public struct BotStarter: Sendable {
    /// Stable, so a bot remembers which starter it came from (`Bot.starterID`).
    public var id: String
    public var name: String
    public var avatar: BotAvatar
    public var persona: String
    /// Starters that change files or settings ask first, whatever the user's default.
    public var asksForApproval: Bool
    /// Names it was offered under before, so a bot still carrying one counts as untouched (`isUntouched`).
    var formerNames: [String] = []

    /// The starter lineup this version offers. Bots saved under an earlier one move to it once
    /// (`AppStore.adoptCurrentStarterLineup`).
    public nonisolated static let lineup = 2

    /// The look each starter had before the characters, as saved (shape, tint), so `Bot` can tell an untouched one.
    nonisolated static let originalLooks: [String: (shape: String, tint: String)] = [
        "sunny": ("blob", "sunflower"), "tuck": ("bean", "mint"), "fetch": ("cloud", "sky"), "quill": ("drop", "lilac"),
        "patch": ("pebble", "coral"),
    ]

    /// The everyday helper's standing instructions: Brulee's now, Sunny's in the first lineup.
    nonisolated static let everydayHelper = """
        You are a cheerful everyday helper. Answer quick questions, explain things plainly, do small tasks \
        on this Mac (convert a file, rename a batch of photos, work out a command) and suggest a better \
        bot or a project thread when a job grows big. Prefer short answers with the key point first.
        """

    /// One bot to start with; the other characters are there for the bots the user makes.
    public nonisolated static var all: [BotStarter] {
        [
            BotStarter(
                id: "brulee", name: BotAvatar.Shape.brulee.defaultName, avatar: BotAvatar(character: .brulee),
                persona: everydayHelper, asksForApproval: false)
        ]
    }

    /// The first lineup, no longer offered. Kept so a bot made from one keeps its look, and so one the user never used
    /// or changed can go when the lineup changes (`isUntouched`).
    nonisolated static var retired: [BotStarter] {
        [
            BotStarter(
                id: "sunny", name: BotAvatar.Shape.star.defaultName, avatar: BotAvatar(character: .star),
                persona: everydayHelper, asksForApproval: false, formerNames: ["Sunny"]),
            BotStarter(
                id: "tuck", name: BotAvatar.Shape.teddy.defaultName, avatar: BotAvatar(character: .teddy),
                persona: """
                    You are a tidy-up bot. You organize folders, starting with ~/Downloads and ~/Desktop: group files \
                    into sensible folders, find duplicates and large old files, and propose a plan before moving \
                    anything. Never delete files yourself. List what could go and ask first; when the user agrees, \
                    move files to the Trash rather than deleting them for good. Leave app data, Photos, Mail and \
                    hidden folders alone unless asked.
                    """,
                asksForApproval: true, formerNames: ["Tuck"]),
            BotStarter(
                id: "fetch", name: BotAvatar.Shape.alien.defaultName, avatar: BotAvatar(character: .alien),
                persona: """
                    You are a research scout. Look things up on the web and in local files, compare options and \
                    summarize what you found in a few bullet points with links to the sources. Say how sure you are \
                    and what you could not verify. Do not change files unless asked.
                    """,
                asksForApproval: false, formerNames: ["Fetch"]),
            BotStarter(
                id: "quill", name: BotAvatar.Shape.croissant.defaultName, avatar: BotAvatar(character: .croissant),
                persona: """
                    You are a writing companion for emails, docs, READMEs, release notes and posts. Match the tone the \
                    user asks for, keep it clear and concise, and offer one or two alternatives for important lines. \
                    Put text meant to be pasted elsewhere in a fenced code block. Never send anything on the user's \
                    behalf.
                    """,
                asksForApproval: false, formerNames: ["Quill"]),
            BotStarter(
                id: "patch", name: BotAvatar.Shape.cherry.defaultName, avatar: BotAvatar(character: .cherry),
                persona: """
                    You are a Mac and developer-environment fixer. Diagnose broken toolchains, PATH and shell setup, \
                    Homebrew, Xcode, Git, SSH keys, disk space and stuck processes. Look before you change anything: \
                    explain the cause, show the commands you plan to run, and prefer reversible fixes. Ask before using \
                    sudo, removing packages or editing shell profiles.
                    """,
                asksForApproval: true, formerNames: ["Patch"]),
        ]
    }

    /// Whether a bot is still just as this starter made it: its name, instructions, look and folder unchanged.
    nonisolated func isUntouched(_ bot: Bot) -> Bool {
        bot.starterID == id && (bot.name == name || formerNames.contains(bot.name)) && bot.persona == persona
            && bot.avatar == avatar && (bot.folder ?? "").isEmpty
    }

    /// A bot made from this starter, running on the user's default agent.
    public nonisolated func makeBot(selection: ModelSelection, accessMode: AccessMode, createdAt: Date = Date()) -> Bot {
        Bot(
            name: name, avatar: avatar, persona: persona, selection: selection,
            accessMode: asksForApproval ? .approval : accessMode, createdAt: createdAt, starterID: id)
    }
}
