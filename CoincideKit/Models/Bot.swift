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
        avatar = container.lenient(BotAvatar.self, forKey: .avatar) ?? BotAvatar(shape: .blob, tint: .sky)
        persona = container.lenient(String.self, forKey: .persona) ?? ""
        selection =
            container.lenient(ModelSelection.self, forKey: .selection) ?? ModelSelection(provider: .claude, modelID: "default")
        accessMode = container.lenient(AccessMode.self, forKey: .accessMode) ?? .approval
        interactionMode = container.lenient(InteractionMode.self, forKey: .interactionMode) ?? .build
        folder = container.lenient(String.self, forKey: .folder)
        createdAt = container.lenient(Date.self, forKey: .createdAt) ?? .distantPast
        starterID = container.lenient(String.self, forKey: .starterID)
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

/// A bot's look: a soft body shape with two eyes, in one of a few colors that read on dark and light themes alike.
public struct BotAvatar: Codable, Hashable, Sendable {
    public enum Shape: String, Codable, CaseIterable, Sendable {
        case blob, pebble, cloud, drop, star, bean, bun, sprout
    }

    public enum Tint: String, Codable, CaseIterable, Sendable {
        case sunflower, tangerine, coral, rose, lilac, sky, mint, sage
    }

    public var shape: Shape
    public var tint: Tint

    public nonisolated init(shape: Shape, tint: Tint) {
        self.shape = shape
        self.tint = tint
    }

    /// A shape or tint added later reads as the defaults, keeping the rest.
    public nonisolated init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        shape = container.lenient(Shape.self, forKey: .shape) ?? .blob
        tint = container.lenient(Tint.self, forKey: .tint) ?? .sky
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

    public nonisolated static var all: [BotStarter] {
        [
            BotStarter(
                id: "sunny", name: String(localized: "Sunny"), avatar: BotAvatar(shape: .blob, tint: .sunflower),
                persona: """
                    You are a cheerful everyday helper. Answer quick questions, explain things plainly, do small tasks \
                    on this Mac (convert a file, rename a batch of photos, work out a command) and suggest a better \
                    bot or a project thread when a job grows big. Prefer short answers with the key point first.
                    """,
                asksForApproval: false),
            BotStarter(
                id: "tuck", name: String(localized: "Tuck"), avatar: BotAvatar(shape: .bean, tint: .mint),
                persona: """
                    You are a tidy-up bot. You organize folders, starting with ~/Downloads and ~/Desktop: group files \
                    into sensible folders, find duplicates and large old files, and propose a plan before moving \
                    anything. Never delete files yourself. List what could go and ask first; when the user agrees, \
                    move files to the Trash rather than deleting them for good. Leave app data, Photos, Mail and \
                    hidden folders alone unless asked.
                    """,
                asksForApproval: true),
            BotStarter(
                id: "fetch", name: String(localized: "Fetch"), avatar: BotAvatar(shape: .cloud, tint: .sky),
                persona: """
                    You are a research scout. Look things up on the web and in local files, compare options and \
                    summarize what you found in a few bullet points with links to the sources. Say how sure you are \
                    and what you could not verify. Do not change files unless asked.
                    """,
                asksForApproval: false),
            BotStarter(
                id: "quill", name: String(localized: "Quill"), avatar: BotAvatar(shape: .drop, tint: .lilac),
                persona: """
                    You are a writing companion for emails, docs, READMEs, release notes and posts. Match the tone the \
                    user asks for, keep it clear and concise, and offer one or two alternatives for important lines. \
                    Put text meant to be pasted elsewhere in a fenced code block. Never send anything on the user's \
                    behalf.
                    """,
                asksForApproval: false),
            BotStarter(
                id: "patch", name: String(localized: "Patch"), avatar: BotAvatar(shape: .pebble, tint: .coral),
                persona: """
                    You are a Mac and developer-environment fixer. Diagnose broken toolchains, PATH and shell setup, \
                    Homebrew, Xcode, Git, SSH keys, disk space and stuck processes. Look before you change anything: \
                    explain the cause, show the commands you plan to run, and prefer reversible fixes. Ask before using \
                    sudo, removing packages or editing shell profiles.
                    """,
                asksForApproval: true),
        ]
    }

    /// A bot made from this starter, running on the user's default agent.
    public nonisolated func makeBot(selection: ModelSelection, accessMode: AccessMode, createdAt: Date = Date()) -> Bot {
        Bot(
            name: name, avatar: avatar, persona: persona, selection: selection,
            accessMode: asksForApproval ? .approval : accessMode, createdAt: createdAt, starterID: id)
    }
}
