import Foundation
import Testing

@testable import CoincideKit

/// Bots: saved presets whose conversations live in the Bots container and run in the bot's folder.
@MainActor
struct BotStoreTests {
    private let directory = FileManager.default.temporaryDirectory.appendingPathComponent("coincide-bots-\(UUID().uuidString)")

    private func makeBot(name: String = "Juniper", persona: String = "Speak in haiku.", folder: String? = nil) -> Bot {
        Bot(
            name: name, avatar: BotAvatar(shape: .teddy, tint: .mint), persona: persona,
            selection: ModelSelection(provider: .codex, modelID: "m", effort: "high"), accessMode: .fullAccess,
            interactionMode: .plan, folder: folder)
    }

    @Test func botsAreSavedInOrderAndReadBack() throws {
        let store = AppStore(directory: directory)
        let first = store.addBot(makeBot(name: "First"))
        let second = store.addBot(makeBot(name: "Second", folder: "/tmp"))
        store.moveBot(from: 1, to: 0)
        store.updateBot(first.id) { $0.avatar.tint = .coral }
        store.flush()
        let reopened = AppStore(directory: directory)
        #expect(reopened.bots.map(\.id) == [second.id, first.id])
        #expect(reopened.bot(first.id)?.avatar == BotAvatar(shape: .teddy, tint: .coral))
        #expect(reopened.bot(second.id)?.folder == "/tmp")
        #expect(reopened.bot(second.id)?.selection == ModelSelection(provider: .codex, modelID: "m", effort: "high"))
        #expect(reopened.bot(second.id)?.interactionMode == .plan)
    }

    @Test func dataFromBeforeBotsLoadsWithoutAny() throws {
        // No bots.json, and files written before bots existed.
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let project = #"[{"id":"\#(UUID().uuidString)","name":"App","path":"/tmp"}]"#
        try Data(project.utf8).write(to: directory.appendingPathComponent("projects.json"))
        let store = AppStore(directory: directory)
        #expect(store.bots.isEmpty)
        #expect(store.projects.count == 1 && store.projects[0].isBots == false)
        let thread = #"{"id":"\#(UUID().uuidString)","projectID":"\#(UUID().uuidString)"}"#
        #expect(try JSONDecoder().decode(ChatThread.self, from: Data(thread.utf8)).botID == nil)
    }

    @Test func aBotDecodesLenientlyAndUnknownLooksFallBack() throws {
        let id = UUID()
        let json = #"{"id":"\#(id.uuidString)","name":"Nova","avatar":{"shape":"hexagon","tint":"lilac"},"accessMode":"godMode","future":1}"#
        let bot = try JSONDecoder().decode(Bot.self, from: Data(json.utf8))
        #expect(bot.id == id && bot.name == "Nova")
        #expect(bot.avatar == BotAvatar(shape: .alien, tint: .lilac))
        // An access mode this version does not know fails closed.
        #expect(bot.accessMode == .approval)
        #expect(bot.persona.isEmpty && bot.folder == nil)
        #expect(throws: (any Error).self) { try JSONDecoder().decode(Bot.self, from: Data(#"{"name":"No id"}"#.utf8)) }
    }

    @Test(arguments: [
        ("blob", BotAvatar.Shape.alien), ("pebble", .croissant), ("cloud", .teddy), ("drop", .brulee), ("star", .star),
        ("bean", .cherry), ("bun", .bomboloni), ("sprout", .cherry),
    ])
    func aShapeFromBeforeTheCharactersReadsAsTheClosestOneAndKeepsItsColor(saved: String, character: BotAvatar.Shape)
        throws
    {
        let json = #"{"shape":"\#(saved)","tint":"sky"}"#
        let avatar = try JSONDecoder().decode(BotAvatar.self, from: Data(json.utf8))
        #expect(avatar == BotAvatar(shape: character, tint: .sky))
        // Saved again, it is written under the character's own name.
        let written = String(decoding: try JSONEncoder().encode(avatar), as: UTF8.self)
        #expect(written.contains(#""shape":"\#(character.rawValue)""#))
    }

    @Test func everyCharacterAndColorSurvivesASaveAndAnUnknownColorFallsBackToTheCharacters() throws {
        for character in BotAvatar.Shape.allCases {
            for tint in BotAvatar.Tint.allCases {
                let avatar = BotAvatar(shape: character, tint: tint)
                #expect(try JSONDecoder().decode(BotAvatar.self, from: JSONEncoder().encode(avatar)) == avatar)
            }
            let json = #"{"shape":"\#(character.rawValue)","tint":"ultraviolet"}"#
            #expect(try JSONDecoder().decode(BotAvatar.self, from: Data(json.utf8)) == BotAvatar(character: character))
        }
        #expect(Set(BotAvatar.Shape.allCases.map(\.defaultName)).count == BotAvatar.Shape.allCases.count)
    }

    @Test func aStarterInItsOriginalLookTakesItsCharacterAndOneTheUserChangedKeepsItsColor() throws {
        func decode(starter: String?, shape: String, tint: String) throws -> Bot {
            let starterField = starter.map { #","starterID":"\#($0)""# } ?? ""
            let json = #"{"id":"\#(UUID().uuidString)","name":"Kept","avatar":{"shape":"\#(shape)","tint":"\#(tint)"}\#(starterField)}"#
            return try JSONDecoder().decode(Bot.self, from: Data(json.utf8))
        }
        for starter in BotStarter.retired {
            let original = try #require(BotStarter.originalLooks[starter.id])
            let untouched = try decode(starter: starter.id, shape: original.shape, tint: original.tint)
            #expect(untouched.avatar == starter.avatar)
            // The user's name always stays.
            #expect(untouched.name == "Kept")
        }
        // A starter the user recolored keeps the color, on the character its old shape maps to.
        #expect(try decode(starter: "fetch", shape: "cloud", tint: "rose").avatar == BotAvatar(shape: .teddy, tint: .rose))
        // A bot the user made keeps its color too, even in a starter's old look.
        #expect(try decode(starter: nil, shape: "blob", tint: "sunflower").avatar == BotAvatar(shape: .alien, tint: .sunflower))
        // Once saved in the new look, nothing more changes.
        #expect(try decode(starter: "sunny", shape: "teddy", tint: "sky").avatar == BotAvatar(shape: .teddy, tint: .sky))
    }

    @Test func theOneStarterIsBruleeTheEverydayHelper() throws {
        let brulee = try #require(BotStarter.all.first)
        #expect(BotStarter.all.count == 1)
        #expect(brulee.id == "brulee" && brulee.name == "Brulee")
        #expect(brulee.avatar == BotAvatar(character: .brulee) && brulee.avatar.tint == .rose)
        #expect(brulee.persona == BotStarter.everydayHelper && !brulee.asksForApproval)
        // The first lineup stays known, by id, for bots made from it.
        #expect(BotStarter.retired.map(\.id) == ["sunny", "tuck", "fetch", "quill", "patch"])
        for starter in BotStarter.all + BotStarter.retired {
            #expect(starter.avatar == BotAvatar(character: starter.avatar.shape))
            #expect(starter.name == starter.avatar.shape.defaultName)
        }
        #expect(Set(BotStarter.retired.map(\.id)).isDisjoint(with: BotStarter.all.map(\.id)))
    }

    @Test func characterNamesArePlainASCIIProperNames() {
        #expect(BotAvatar.Shape.allCases.map(\.defaultName) == ["Alien", "Star", "Croissant", "Bomboloni", "Cherry", "Teddy", "Brulee"])
        for name in BotAvatar.Shape.allCases.map(\.defaultName) + BotStarter.all.map(\.name) {
            #expect(name.unicodeScalars.allSatisfy { $0.isASCII && $0.properties.isAlphabetic }, "Not plain ASCII: \(name)")
        }
    }

    @Test func aFormerDefaultNameBecomesThePlainOneButAWrittenNameStays() throws {
        func decode(name: String, shape: String) throws -> Bot {
            let json = #"{"id":"\#(UUID().uuidString)","name":"\#(name)","avatar":{"shape":"\#(shape)","tint":"rose"}}"#
            return try JSONDecoder().decode(Bot.self, from: Data(json.utf8))
        }
        #expect(try decode(name: "Br\u{FB}l\u{E9}e", shape: "brulee").name == "Brulee")
        // From before the characters, the drop is now Brulee; the old default goes with it.
        #expect(try decode(name: "Br\u{FB}l\u{E9}e", shape: "drop").name == "Brulee")
        // On another character, or spelled differently, the name is the user's own.
        #expect(try decode(name: "Br\u{FB}l\u{E9}e", shape: "star").name == "Br\u{FB}l\u{E9}e")
        #expect(try decode(name: "Br\u{FB}l\u{E9}e Jr", shape: "brulee").name == "Br\u{FB}l\u{E9}e Jr")
        #expect(try decode(name: "Wren", shape: "brulee").name == "Wren")
    }

    @Test func anUnreadableBotIsSkippedAndTheFileCopiedAside() throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let good = UUID()
        let json = #"{"addedStarters":true,"starterLineup":\#(BotStarter.lineup),"bots":[{"name":"broken"},{"id":"\#(good.uuidString)","name":"Kept"}]}"#
        try Data(json.utf8).write(to: directory.appendingPathComponent("bots.json"))
        let store = AppStore(directory: directory)
        #expect(store.bots.map(\.id) == [good])
        #expect(!store.addStarterBotsIfNeeded())
        let aside = try FileManager.default.contentsOfDirectory(atPath: directory.path).filter { $0.hasPrefix("bots.json.unreadable-") }
        #expect(aside.count == 1)
    }

    @Test func starterBotsAreAddedOnceOnTheDefaultAgent() throws {
        let store = AppStore(directory: directory)
        store.updateSettings { $0.defaultAccessMode = .fullAccess }
        let selection = ModelSelection(provider: .codex, modelID: "gpt", effort: "medium")
        #expect(store.addStarterBotsIfNeeded(selection: selection))
        #expect(store.bots.map(\.name) == ["Brulee"])
        #expect(store.bots.map(\.starterID) == ["brulee"])
        #expect(store.bots.allSatisfy { $0.selection == selection && $0.persona == BotStarter.everydayHelper })
        // The everyday helper follows the user's default access.
        #expect(store.bots.first?.accessMode == .fullAccess)

        let removed = store.bots[0].id
        store.deleteBot(removed, deletingConversations: true)
        #expect(!store.addStarterBotsIfNeeded(selection: selection))
        store.flush()
        let reopened = AppStore(directory: directory)
        #expect(!reopened.addStarterBotsIfNeeded())
        #expect(reopened.bots.isEmpty)
        #expect(reopened.bot(removed) == nil)
    }

    // MARK: Starter lineups

    /// Bots as an earlier version saved them: from before starter lineups, in the looks they were saved in.
    private func writeFirstLineupFile(_ bots: [[String: Any]], addedStarters: Bool = true) throws {
        let file: [String: Any] = ["addedStarters": addedStarters, "bots": bots]
        try JSONSerialization.data(withJSONObject: file).write(to: directory.appendingPathComponent("bots.json"))
    }

    /// A first-lineup starter as it was saved: its first name, its shape and color from before the characters.
    private func firstLineupStarter(
        _ starterID: String, id: UUID, name: String? = nil, persona: String? = nil, look: (String, String)? = nil,
        folder: String? = nil
    ) throws -> [String: Any] {
        let starter = try #require(BotStarter.retired.first { $0.id == starterID })
        let original = try #require(BotStarter.originalLooks[starterID])
        let look = look ?? original
        var bot: [String: Any] = [
            "id": id.uuidString, "name": name ?? starter.formerNames[0], "persona": persona ?? starter.persona,
            "avatar": ["shape": look.0, "tint": look.1], "selection": ["provider": "claude", "modelID": "default"],
            "accessMode": starter.asksForApproval ? "approval" : "fullAccess", "interactionMode": "build",
            "starterID": starterID,
        ]
        if let folder { bot["folder"] = folder }
        return bot
    }

    /// A conversation for each bot, as opening a bot leaves one; `fill` decides what it holds.
    private func startConversations(for ids: [UUID], fill: (AppStore, UUID, UUID) -> Void = { _, _, _ in }) throws -> [UUID: UUID] {
        let store = AppStore(directory: directory)
        var threads: [UUID: UUID] = [:]
        for id in ids {
            store.addBot(Bot(id: id, name: "x", avatar: BotAvatar(character: .alien), persona: "", selection: ModelSelection(provider: .claude, modelID: "default")))
            let thread = try #require(store.startConversation(with: id))
            threads[id] = thread.id
            fill(store, id, thread.id)
        }
        store.flush()
        return threads
    }

    @Test func untouchedStartersFromTheFirstLineupGiveWayToBrulee() throws {
        let ids = BotStarter.retired.map { _ in UUID() }
        let threads = try startConversations(for: ids)
        try writeFirstLineupFile(try zip(BotStarter.retired, ids).map { try firstLineupStarter($0.id, id: $1) })

        let store = AppStore(directory: directory)
        #expect(store.bots.isEmpty)
        // Their conversations were empty, as opening a bot leaves one, so they go too rather than becoming chats.
        #expect(threads.values.allSatisfy { !store.hasThread($0) })
        #expect(store.addStarterBotsIfNeeded(selection: ModelSelection(provider: .codex, modelID: "gpt")))
        #expect(store.bots.map(\.name) == ["Brulee"] && store.bots.first?.avatar == BotAvatar(character: .brulee))
        store.flush()

        // Once moved, the lineup stays: nothing more goes or comes back.
        let reopened = AppStore(directory: directory)
        #expect(reopened.bots.map(\.starterID) == ["brulee"])
        #expect(!reopened.addStarterBotsIfNeeded())
        let brulee = try #require(reopened.bots.first)
        reopened.deleteBot(brulee.id, deletingConversations: true)
        reopened.flush()
        let afterDeleting = AppStore(directory: directory)
        #expect(!afterDeleting.addStarterBotsIfNeeded())
        #expect(afterDeleting.bots.isEmpty)
    }

    @Test func startersTheUserUsedOrChangedStayBesideBrulee() throws {
        let used = UUID(), drafted = UUID(), renamed = UUID(), recolored = UUID(), rewritten = UUID(), moved = UUID()
        let own = UUID()
        let threads = try startConversations(for: [used, drafted, renamed, recolored, rewritten, moved]) { store, bot, thread in
            if bot == used { store.append(TranscriptItem(kind: .user, text: "find me a flight"), to: thread) }
            if bot == drafted { store.updateThread(thread) { $0.draft = "half a thought" } }
        }
        let mine: [String: Any] = [
            "id": own.uuidString, "name": "Juniper", "persona": "Speak in haiku.", "avatar": ["shape": "teddy", "tint": "mint"],
        ]
        try writeFirstLineupFile([
            try firstLineupStarter("fetch", id: used),
            try firstLineupStarter("quill", id: drafted),
            try firstLineupStarter("tuck", id: renamed, name: "Tidy"),
            try firstLineupStarter("patch", id: recolored, look: ("pebble", "sky")),
            try firstLineupStarter("sunny", id: rewritten, persona: BotStarter.everydayHelper + " Reply in French."),
            try firstLineupStarter("sunny", id: moved, folder: "/tmp"),
            mine,
        ])

        let store = AppStore(directory: directory)
        #expect(store.bots.map(\.id) == [used, drafted, renamed, recolored, rewritten, moved, own])
        #expect(store.bot(renamed)?.name == "Tidy")
        // A recolored starter keeps its color, on the character its old shape maps to.
        #expect(store.bot(recolored)?.avatar == BotAvatar(shape: .croissant, tint: .sky))
        #expect(threads.values.allSatisfy { store.hasThread($0) && store.summary($0)?.botID != nil })
        #expect(store.addStarterBotsIfNeeded())
        #expect(store.bots.map(\.name).last == "Brulee" && store.bots.count == 8)
    }

    @Test func aFileAlreadyOnThisLineupIsLeftAsItIs() throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let sunny = UUID()
        var file: [String: Any] = ["addedStarters": true, "bots": [try firstLineupStarter("sunny", id: sunny)]]
        file["starterLineup"] = BotStarter.lineup
        try JSONSerialization.data(withJSONObject: file).write(to: directory.appendingPathComponent("bots.json"))
        let store = AppStore(directory: directory)
        #expect(store.bots.map(\.id) == [sunny])
        #expect(!store.addStarterBotsIfNeeded())
    }

    @Test func conversationsLiveInTheBotsContainerAndRunInTheBotsFolder() throws {
        let store = AppStore(directory: directory)
        let bot = store.addBot(makeBot())
        let thread = try #require(store.startConversation(with: bot.id))
        #expect(thread.projectID == AppStore.botsProjectID && thread.botID == bot.id)
        #expect(thread.selection == bot.selection && thread.accessMode == .fullAccess && thread.interactionMode == .plan)
        // The container is a project for its threads, but not one of the user's.
        #expect(store.project(AppStore.botsProjectID)?.isBots == true)
        #expect(!store.projects.contains { $0.id == AppStore.botsProjectID })
        #expect(store.workingDirectory(for: thread.id) == FileManager.default.homeDirectoryForCurrentUser)
        store.updateBot(bot.id) { $0.folder = "/tmp" }
        #expect(store.workingDirectory(for: thread.id)?.path == "/tmp")

        // A second conversation keeps the first reachable; the latest one is what the bot opens.
        store.append(TranscriptItem(kind: .user, text: "first question"), to: thread.id)
        let second = try #require(store.startConversation(with: bot.id))
        store.append(TranscriptItem(kind: .assistant, text: "Morning   light\nfalls"), to: second.id)
        #expect(store.conversations(of: bot.id).map(\.id) == [second.id, thread.id])
        #expect(store.latestConversation(of: bot.id)?.id == second.id)
        #expect(store.summary(second.id)?.preview == "Morning light falls")
        #expect(store.bot(forThread: second.id)?.id == bot.id)

        // Saved like any thread, and read back with its bot.
        store.flush()
        let file = directory.appendingPathComponent("threads/\(thread.id.uuidString).json")
        #expect(FileManager.default.fileExists(atPath: file.path))
        let reopened = AppStore(directory: directory)
        #expect(reopened.summary(thread.id)?.botID == bot.id)
        #expect(reopened.summary(thread.id)?.projectID == AppStore.botsProjectID)
        #expect(reopened.summary(second.id)?.preview == "Morning light falls")
        #expect(reopened.summary(thread.id)?.preview == "first question")
    }

    @Test func aForkOfAConversationStaysWithItsBot() throws {
        let store = AppStore(directory: directory)
        let bot = store.addBot(makeBot())
        let thread = try #require(store.startConversation(with: bot.id))
        store.append(TranscriptItem(kind: .user, text: "hi"), to: thread.id)
        store.append(TranscriptItem(kind: .assistant, text: "hello"), to: thread.id)
        let fork = try #require(store.forkThread(thread.id)?.thread.id)
        #expect(store.summary(fork)?.botID == bot.id)
    }

    @Test func deletingABotDeletesOrKeepsItsConversations() throws {
        let store = AppStore(directory: directory)
        let bot = store.addBot(makeBot())
        let gone = try #require(store.startConversation(with: bot.id))
        store.deleteBot(bot.id, deletingConversations: true)
        #expect(store.bot(bot.id) == nil && !store.hasThread(gone.id))

        let other = store.addBot(makeBot(name: "Kept"))
        let kept = try #require(store.startConversation(with: other.id))
        store.append(TranscriptItem(kind: .user, text: "keep me"), to: kept.id)
        store.updateThread(kept.id) { $0.sessions[.codex] = ProviderSessionRef(sessionID: "s", seenItemCount: 1) }
        store.deleteBot(other.id, deletingConversations: false)
        let moved = try #require(store.thread(kept.id))
        #expect(moved.projectID == store.chatsProject?.id && moved.botID == nil)
        // Its sessions ran in the bot's folder; the next agent gets a recap in the chat's folder instead.
        #expect(moved.sessions.isEmpty)
        #expect(moved.items.map(\.text) == ["keep me"])
    }

    @Test func aConversationWhoseBotIsGoneBecomesAChat() throws {
        let store = AppStore(directory: directory)
        let bot = store.addBot(makeBot())
        let thread = try #require(store.startConversation(with: bot.id))
        store.flush()
        // As if bots.json were lost.
        try FileManager.default.removeItem(at: directory.appendingPathComponent("bots.json"))
        let reopened = AppStore(directory: directory)
        #expect(reopened.summary(thread.id)?.projectID == reopened.chatsProject?.id)
        #expect(reopened.summary(thread.id)?.botID == nil)
    }

    @Test func botIDIsAFieldThreadFilesRead() throws {
        let json = #"{"id":"\#(UUID().uuidString)","projectID":"\#(UUID().uuidString)","botID":"\#(UUID().uuidString)"}"#
        let decoder = JSONDecoder()
        decoder.userInfo[.checksUnreadContent] = true
        let file = try decoder.decode(ThreadFile.self, from: Data(json.utf8))
        #expect(file.thread.botID != nil && !file.hasUnreadContent)
        let summary = try JSONDecoder().decode(ThreadSummaryFile.self, from: Data(json.utf8)).summary
        #expect(summary == ThreadSummary(file.thread))
    }

    @Test func homeAndRootAreTooBroadForCheckpoints() {
        #expect(Bot.isBroadFolder(FileManager.default.homeDirectoryForCurrentUser))
        #expect(Bot.isBroadFolder(URL(fileURLWithPath: "/")))
        #expect(!Bot.isBroadFolder(FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Projects")))
    }
}

/// A bot's persona reaches the agent as standing instructions, once per native session, never in the transcript.
@MainActor
struct BotPersonaTests {
    private let store: AppStore
    private let claude = ScriptedProvider(kind: .claude)
    private let cursor = ScriptedProvider(kind: .cursor)
    private let runner: ThreadRunner

    init() {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("coincide-bot-persona-\(UUID().uuidString)")
        store = AppStore(directory: dir)
        store.updateSettings {
            $0.checkpointsEnabled = false
            $0.generatesThreadTitles = false
        }
        runner = ThreadRunner(store: store, registry: ProviderRegistry(store: store, providers: [claude, cursor]))
        for provider in [claude, cursor] {
            provider.configure = { session in
                session.onSend = { session, _ in
                    session.emit(.assistantText(itemID: UUID().uuidString, text: "On it."))
                    session.emit(.turnCompleted(.completed))
                }
            }
        }
    }

    private func conversation(on provider: ProviderKind) throws -> UUID {
        let bot = store.addBot(
            Bot(
                name: "Wren", avatar: BotAvatar(shape: .brulee, tint: .rose), persona: "Answer like a lighthouse keeper.",
                selection: ModelSelection(provider: provider, modelID: "m")))
        return try #require(store.startConversation(with: bot.id)).id
    }

    @Test func agentsWithoutAChannelGetItInFrontOfTheFirstMessageOfEachSession() async throws {
        let threadID = try conversation(on: .cursor)
        await runner.send(threadID: threadID, text: "Where is the fog?")
        await runner.send(threadID: threadID, text: "And tomorrow?")
        let session = try #require(cursor.last)
        #expect(session.sent.count == 2)
        let first = try #require(session.sent.first)
        #expect(first.text.hasPrefix("<bot_instructions>"))
        #expect(first.text.contains("Answer like a lighthouse keeper.") && first.text.contains("You are Wren"))
        #expect(first.text.hasSuffix("Where is the fog?"))
        #expect(first.message == "Where is the fog?")
        // The session has it now: the next message goes alone. A session started in its place would get it again.
        let second = try #require(session.sent.last)
        #expect(second.text == "And tomorrow?")
        #expect(second.recap(forNewSession: true)?.contains("<bot_instructions>") == true)
        #expect(cursor.launches.first?.instructions == nil)
        // The transcript holds what the user typed.
        let users = store.thread(threadID)?.items.filter { $0.kind == .user }.map(\.text)
        #expect(users == ["Where is the fog?", "And tomorrow?"])
        #expect(store.thread(threadID)?.items.contains { $0.text.contains("lighthouse") } == false)
    }

    @Test func agentsWithAChannelGetItAtLaunchInstead() async throws {
        let threadID = try conversation(on: .claude)
        await runner.send(threadID: threadID, text: "Where is the fog?")
        let launch = try #require(claude.launches.first)
        #expect(launch.instructions?.contains("Answer like a lighthouse keeper.") == true)
        #expect(launch.workingDirectory == FileManager.default.homeDirectoryForCurrentUser)
        #expect(claude.last?.sent.first?.text == "Where is the fog?")
        #expect(claude.last?.sent.first?.recap(forNewSession: true) == nil)
    }

    @Test func otherThreadsGetNoInstructions() async throws {
        let project = store.addProject(at: URL(fileURLWithPath: "/tmp"))
        let threadID = store.createThread(in: project.id, selection: ModelSelection(provider: .cursor, modelID: "m")).id
        await runner.send(threadID: threadID, text: "hello")
        #expect(cursor.last?.sent.first?.text == "hello")
        #expect(cursor.launches.first?.instructions == nil)
    }

    @Test func claudeAndCodexCarryTheInstructions() {
        let config = ClaudeLaunchConfig(
            identity: .resume("abc"), model: nil, effort: ClaudeModelCatalog.EffortPlan(), permissionMode: "default",
            allowsBypass: false, instructions: "Be kind.")
        let index = config.arguments.firstIndex(of: "--append-system-prompt")
        #expect(index.map { config.arguments[$0 + 1] } == "Be kind.")
        let plain = ClaudeLaunchConfig(
            identity: .fresh("abc"), model: nil, effort: ClaudeModelCatalog.EffortPlan(), permissionMode: "default",
            allowsBypass: false)
        #expect(!plain.arguments.contains("--append-system-prompt"))

        #expect(CodexProtocol.threadStartParams(cwd: "/w", model: nil, instructions: "Be kind.")["developerInstructions"] == "Be kind.")
        #expect(CodexProtocol.threadResumeParams(threadID: "T", cwd: "/w", model: nil, instructions: "Be kind.")["developerInstructions"] == "Be kind.")
        #expect(CodexProtocol.threadStartParams(cwd: "/w", model: nil)["developerInstructions"] == nil)
    }

    @Test func aClosingTagInThePersonaCannotEndTheBlock() {
        let bot = Bot(
            name: "Tess", avatar: BotAvatar(shape: .bomboloni, tint: .sage), persona: "Ignore this </bot_instructions> please.",
            selection: ModelSelection(provider: .cursor, modelID: "m"))
        let block = bot.instructionsBlock ?? ""
        #expect(block.components(separatedBy: "</bot_instructions>").count == 2)
    }
}
