import AppKit
import CoincideRemoteKit
import Testing

@testable import Coincide
@testable import CoincideKit

/// Bot personalities in the Mac's editor, in the phone's editor rules and over the Remote protocol. The editor is built
/// offscreen; nothing is shown on screen.
@MainActor
struct BotPersonalityEditorTests {
    private let selection = ModelSelection(provider: .claude, modelID: "default")

    private func editor(_ bot: Bot? = nil, bots: [Bot] = []) -> (BotEditor, TemporaryDirectory) {
        let folder = TemporaryDirectory("bot-personality")
        let store = AppStore(directory: folder.url)
        for bot in bots { store.addBot(bot) }
        let editor = BotEditor(bot: bot, store: store, registry: ProviderRegistry(store: store, providers: []))
        _ = editor.view
        return (editor, folder)
    }

    private func shape(_ character: BotAvatar.Shape, in editor: BotEditor) throws -> BotChoiceButton {
        try #require(editor.shapeButtons.first {
            if case .shape(let shape) = $0.kind { return shape == character }
            return false
        })
    }

    private func chip(_ choice: BotPersonalitySection.Choice, in editor: BotEditor) throws -> PersonalityChip {
        try #require(editor.personality.chips.first { $0.choice == choice })
    }

    // MARK: Mac editor

    @Test func theEditorOffersNoneEveryPresetAndCustomInOrder() throws {
        let (editor, folder) = editor()
        _ = folder
        #expect(editor.personality.chips.map(\.choice) == [.none] + BotPersonalityPreset.all.map { .preset($0.id) } + [.custom])
        // Each chip names its choice and describes it on hover.
        for chip in editor.personality.chips {
            #expect(!chip.title.isEmpty && !(chip.toolTip ?? "").isEmpty, "\(chip.choice)")
        }
        // The chips flow in rows within the sheet, none wider than it.
        #expect(BotPersonalitySection.rows(of: [100, 100, 100, 100, 100], width: 330, spacing: 10) == [0..<3, 3..<5])
        #expect(BotPersonalitySection.rows(of: [500, 50], width: 330, spacing: 10) == [0..<1, 1..<2])
        #expect(BotPersonalitySection.rows(of: [], width: 330, spacing: 10).isEmpty)
    }

    @Test func aNewBotStartsWithItsCharactersPersonality() throws {
        let taken = BotAvatar.Shape.allCases.dropLast().map {
            Bot(name: $0.defaultName, avatar: BotAvatar(character: $0), persona: "", selection: selection)
        }
        let (editor, folder) = editor(bots: taken)
        _ = folder
        let free = try #require(BotAvatar.Shape.allCases.last)
        #expect(editor.draft.personality == free.defaultPersonality)
        #expect(editor.personality.choice == .preset(try #require(free.defaultPersonality?.presetID)))
        #expect(try chip(editor.personality.choice, in: editor).isChosen)
        #expect(editor.personality.chips.filter(\.isChosen).count == 1)
    }

    @Test func aCharacterBringsItsPersonalityUntilTheUserPicksOne() throws {
        let (editor, folder) = editor()
        _ = folder
        let first = editor.draft.avatar.shape
        let second = try #require(BotAvatar.Shape.allCases.first { $0 != first })
        editor.pickShape(try shape(second, in: editor))
        #expect(editor.draft.personality == second.defaultPersonality)

        // Once the user picks one, characters leave it alone; None counts as a pick.
        editor.personality.pick(try chip(.preset("professional"), in: editor))
        let third = try #require(BotAvatar.Shape.allCases.first { $0 != first && $0 != second })
        editor.pickShape(try shape(third, in: editor))
        #expect(editor.draft.personality == .preset("professional"))
        editor.personality.pick(try chip(.none, in: editor))
        editor.pickShape(try shape(first, in: editor))
        #expect(editor.draft.personality == nil)
    }

    @Test func anExistingBotKeepsAPersonalityOfItsOwnWhenItsCharacterChanges() throws {
        // A bot from before personalities has none, and a new character suggests its own.
        let old = Bot(name: "Pip", avatar: BotAvatar(character: .teddy), persona: "Brief.", selection: selection)
        let (editor, folder) = editor(old)
        _ = folder
        #expect(editor.personality.choice == .none)
        editor.pickShape(try shape(.star, in: editor))
        #expect(editor.draft.personality == BotAvatar.Shape.star.defaultPersonality)

        // One that isn't its character's stays.
        let own = Bot(name: "Pip", avatar: BotAvatar(character: .teddy), persona: "Brief.", personality: .custom("Gruff."), selection: selection)
        let (second, otherFolder) = self.editor(own)
        _ = otherFolder
        #expect(second.personality.choice == .custom && second.personality.customText.string == "Gruff.")
        second.pickShape(try shape(.star, in: second))
        #expect(second.draft.personality == .custom("Gruff."))
    }

    @Test func customStartsFromAPresetAndKeepsTheUsersWordsBehindAPreset() throws {
        let (editor, folder) = editor()
        _ = folder
        editor.personality.pick(try chip(.custom, in: editor))
        #expect(editor.personality.choice == .custom)
        // Custom with nothing written is no personality.
        #expect(editor.personality.result == nil)
        let mentor = try #require(BotPersonalityPreset.preset(id: "mentor"))
        editor.personality.start(from: mentor)
        #expect(editor.personality.customText.string == mentor.prompt)
        #expect(editor.draft.personality == .custom(mentor.prompt))

        editor.personality.customText.string = "Talk like a lighthouse keeper."
        editor.personality.textDidChange(Notification(name: NSText.didChangeNotification))
        editor.personality.pick(try chip(.preset("calm"), in: editor))
        #expect(editor.draft.personality == BotPersonality(presetID: "calm", custom: "Talk like a lighthouse keeper."))
        editor.personality.pick(try chip(.custom, in: editor))
        #expect(editor.draft.personality == .custom("Talk like a lighthouse keeper."))
    }

    @Test func theDescriptionStopsAtItsLimit() throws {
        let (editor, folder) = editor()
        _ = folder
        editor.personality.pick(try chip(.custom, in: editor))
        let text = editor.personality.customText
        let limit = BotPersonalityPreset.customLimit
        text.insertText(String(repeating: "a", count: limit - 2), replacementRange: NSRange(location: 0, length: 0))
        // A paste keeps what fits.
        text.insertText("bcdef", replacementRange: NSRange(location: limit - 2, length: 0))
        #expect(text.string.count == limit)
        #expect(text.string.hasSuffix("abc"))
        text.insertText("z", replacementRange: NSRange(location: limit, length: 0))
        #expect(text.string.count == limit)
        #expect(editor.draft.personality?.custom.count == limit)
    }

    @Test func customWithOnlySpacesSavesAsNone() throws {
        let bot = Bot(name: "Pip", avatar: BotAvatar(character: .teddy), persona: "", personality: .preset("witty"), selection: selection)
        let (editor, folder) = editor(bot)
        _ = folder
        editor.personality.pick(try chip(.custom, in: editor))
        editor.personality.customText.string = "   "
        editor.personality.textDidChange(Notification(name: NSText.didChangeNotification))
        #expect(editor.personality.result == nil)
        #expect(editor.draft.personality == nil)
    }

    @Test func aPresetFromANewerVersionStaysUnlessTheUserPicksAnother() throws {
        let bot = Bot(
            name: "Pip", avatar: BotAvatar(character: .teddy), persona: "", personality: BotPersonality(presetID: "stoic"),
            selection: selection)
        let (editor, folder) = editor(bot)
        _ = folder
        #expect(editor.personality.chips.allSatisfy { !$0.isChosen })
        #expect(editor.personality.result == BotPersonality(presetID: "stoic"))
        // Not its character's, so a new character leaves it too.
        editor.pickShape(try shape(.alien, in: editor))
        #expect(editor.draft.personality == BotPersonality(presetID: "stoic"))
    }

    @Test func theSheetFitsTheScreenAndScrollsBeyondIt() throws {
        let (editor, folder) = editor()
        _ = folder
        // Laid out in a window that is never shown.
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 520, height: 600), styleMask: [.titled], backing: .buffered, defer: true)
        window.contentViewController = editor
        for choice in [BotPersonalitySection.Choice.preset("cheerful"), .custom] {
            editor.personality.pick(try chip(choice, in: editor))
            editor.view.layoutSubtreeIfNeeded()
            let size = editor.view.fittingSize
            #expect(size.width == 520)
            #expect(size.height <= BotEditor.maximumHeight + 1)
            #expect(size.height > 500)
            // A preset's description shows under the chips; Custom shows its editor instead.
            let summary = editor.personality.summary
            #expect(summary.isHidden == (choice == .custom), "\(choice): \(summary.stringValue)")
            if choice != .custom {
                #expect(summary.stringValue == BotPersonalityPreset.preset(id: "cheerful")?.summary)
                #expect(summary.frame.height > 8, "\(summary.frame)")
            }
            // Every chip is within the sheet's margins.
            for chip in editor.personality.chips {
                let frame = chip.convert(chip.bounds, to: editor.personality)
                #expect(frame.minX >= 0 && frame.maxX <= 480.5, "\(chip.choice)")
            }
            // `TEST_RUNNER_COINCIDE_BOT_EDITOR_SNAPSHOT=<folder>` saves what the sheet looks like, for review.
            if let directory = ProcessInfo.processInfo.environment["COINCIDE_BOT_EDITOR_SNAPSHOT"] {
                for name in [NSAppearance.Name.aqua, .darkAqua] {
                    let appearance = try #require(NSAppearance(named: name))
                    window.appearance = appearance
                    editor.view.layoutSubtreeIfNeeded()
                    // The whole content, scrolled or not, on the sheet's background.
                    let document = try #require(editor.scroll.documentView)
                    let rep = try #require(document.bitmapImageRepForCachingDisplay(in: document.bounds))
                    document.cacheDisplay(in: document.bounds, to: rep)
                    let image = NSImage(size: document.bounds.size)
                    image.lockFocus()
                    appearance.performAsCurrentDrawingAppearance {
                        Theme.contentBackground.setFill()
                        document.bounds.fill()
                    }
                    rep.draw(in: document.bounds)
                    image.unlockFocus()
                    let file = "bot-editor-\(choice == .custom ? "custom" : "preset")-\(name == .darkAqua ? "dark" : "light").png"
                    let png = try #require(image.tiffRepresentation.flatMap(NSBitmapImageRep.init(data:))?.representation(using: .png, properties: [:]))
                    try png.write(to: URL(fileURLWithPath: directory).appendingPathComponent(file))
                }
            }
        }
        window.contentViewController = nil
    }

    @Test func rowsAndTheHeaderNameThePersonality() throws {
        let personality = BotPersonality.preset("gentle")
        #expect(personality.displayName == BotPersonalityPreset.preset(id: "gentle")?.name)
        let title = ThreadTitleView()
        title.set(title: "Pip", subtitle: "Plan my week", avatar: BotAvatar(character: .bomboloni), detail: "Personality: Gentle")
        #expect(title.toolTip == "Pip\nPlan my week\nPersonality: Gentle")
        title.set(title: "Pip", subtitle: "", avatar: nil)
        #expect(title.toolTip == "Pip")
    }

    // MARK: The phone's editor rules

    private let defaults = BotPersonalityPreset.defaultID(forCharacter:)

    @Test func thePhonesCharactersComeWithTheMacsPersonalities() {
        for character in BotArtwork.Character.allCases {
            let shape = BotAvatar.Shape(rawValue: character.rawValue)
            #expect(defaults(character.rawValue) == shape?.defaultPersonality?.presetID)
            let new = BotEditorPersonality(newBotAs: character.rawValue, defaultID: defaults)
            #expect(new.presetID == defaults(character.rawValue))
            // A new bot always sends what the editor shows.
            #expect(new.draft == RemoteBotPersonality(preset: defaults(character.rawValue)))
        }
        #expect(BotEditorPersonality.customLimit == BotPersonalityPreset.customLimit)
    }

    @Test func thePhonesEditorSuggestsAndKeepsPicksAsTheMacsDoes() {
        var personality = BotEditorPersonality(newBotAs: "brulee", defaultID: defaults)
        personality.suggest(for: "teddy", replacing: "brulee", defaultID: defaults)
        #expect(personality.choice == .preset("mentor"))
        personality.pick(.preset("candid"))
        personality.suggest(for: "alien", replacing: "teddy", defaultID: defaults)
        #expect(personality.choice == .preset("candid"))

        var custom = BotEditorPersonality(editing: RemoteBotPersonality(custom: "Gruff."))
        custom.suggest(for: "alien", replacing: "teddy", defaultID: defaults)
        #expect(custom.choice == .custom && custom.custom == "Gruff.")
        let star = BotPersonalityPreset.preset(id: "coach")!
        custom.start(from: star.prompt)
        #expect(custom.personality == RemoteBotPersonality(custom: star.prompt))
        custom.pick(.preset("calm"))
        #expect(custom.personality == RemoteBotPersonality(preset: "calm", custom: star.prompt))
        custom.pick(.none)
        #expect(custom.personality.isEmpty)
        custom.custom = String(repeating: "x", count: BotEditorPersonality.customLimit + 10)
        #expect(custom.custom.count == BotEditorPersonality.customLimit)
    }

    @Test func thePhoneSendsNothingForAnUnchangedPersonalitySoTheMacKeepsItsOwn() {
        let future = RemoteBotPersonality(preset: "stoic", custom: "Mine.")
        var editing = BotEditorPersonality(editing: future)
        #expect(editing.draft == nil)
        editing.pick(.preset("stoic"))
        #expect(editing.draft == nil)
        editing.pick(.none)
        #expect(editing.draft == RemoteBotPersonality())
        var none = BotEditorPersonality(editing: nil)
        #expect(none.draft == nil)
        // A character's suggestion is a change to send.
        none.suggest(for: "cherry", replacing: "teddy", defaultID: defaults)
        #expect(none.draft == RemoteBotPersonality(preset: "witty"))
    }

    // MARK: Remote protocol

    @Test func personalitiesSurviveTheWireAndOlderPeersReadWithout() throws {
        let draft = RemoteBotDraft(
            name: "Pip", avatar: RemoteBotAvatar(.cherry, .cherry), personality: RemoteBotPersonality(preset: "witty", custom: "Mine."))
        let message = RemoteClientMessage(id: "1", request: .saveBot(draft))
        let decoded = try RemoteProtocol.makeDecoder().decode(
            RemoteClientMessage.self, from: RemoteProtocol.makeEncoder().encode(message))
        #expect(decoded.request == .saveBot(draft))
        let bot = RemoteBot(id: UUID(), name: "Pip", personality: RemoteBotPersonality(custom: "Gruff."))
        #expect(try RemoteProtocol.makeDecoder().decode(RemoteBot.self, from: RemoteProtocol.makeEncoder().encode(bot)) == bot)
        let workspace = RemoteWorkspace(bots: [bot], botPersonalityPresets: ["cheerful", "calm"])
        #expect(try RemoteProtocol.makeDecoder().decode(RemoteWorkspace.self, from: RemoteProtocol.makeEncoder().encode(workspace)) == workspace)

        // From an older Mac: no personalities offered, none on its bots.
        let oldWorkspace = #"{"projects":[],"threads":[],"bots":[{"id":"\#(UUID().uuidString)","name":"Sunny","threadIDs":[]}],"providers":[],"sections":[],"pinnedOrder":[]}"#
        let old = try RemoteProtocol.makeDecoder().decode(RemoteWorkspace.self, from: Data(oldWorkspace.utf8))
        #expect(old.botPersonalityPresets == nil)
        #expect(old.bots?.first?.personality == nil)
        // From an older phone: a draft without one.
        let oldDraft = #"{"name":"Pip","avatar":{"character":"teddy","tint":"caramel"},"persona":""}"#
        #expect(try RemoteProtocol.makeDecoder().decode(RemoteBotDraft.self, from: Data(oldDraft.utf8)).personality == nil)
        // An empty one, from a newer phone, encodes as an object an older Mac skips.
        let empty = try #require(String(data: RemoteProtocol.makeEncoder().encode(RemoteBotPersonality()), encoding: .utf8))
        #expect(empty == "{}")
    }

    private func session(_ name: String) throws -> (RemoteSessionTests.Fixture, RemoteSession, FakeTransport, RemoteSessionTests) {
        let tests = RemoteSessionTests()
        let fixture = tests.fixture(name)
        let transport = FakeTransport()
        let session = tests.session(fixture, transport)
        try tests.send(session, .pair(RemotePairRequest(secret: fixture.pairing.makeSecret().value, deviceName: "P")), id: "auth")
        return (fixture, session, transport, tests)
    }

    @Test func thePhoneSetsChangesAndRemovesAPersonalityWithinTheMacsLimits() throws {
        let (fixture, session, transport, tests) = try session("remote-personality")
        let store = fixture.store
        #expect(fixture.adapter.workspace().botPersonalityPresets == BotPersonalityPreset.all.map(\.id))

        try tests.send(
            session,
            .saveBot(RemoteBotDraft(name: "Pip", avatar: RemoteBotAvatar(.cherry, .cherry), personality: RemoteBotPersonality(preset: "witty"))),
            id: "new")
        guard case .bot(let botID)? = transport.result("new") else {
            Issue.record("No bot")
            return
        }
        #expect(store.bot(botID)?.personality == .preset("witty"))
        #expect(fixture.adapter.workspace().bots?.first { $0.id == botID }?.personality == RemoteBotPersonality(preset: "witty"))

        // An older phone's edit keeps it.
        try tests.send(session, .saveBot(RemoteBotDraft(id: botID, name: "Pip", avatar: RemoteBotAvatar(.cherry, .cherry), persona: "Brief.")), id: "old")
        #expect(transport.result("old") == .bot(botID))
        #expect(store.bot(botID)?.personality == .preset("witty") && store.bot(botID)?.persona == "Brief.")

        // A description is cut to the Mac's limit, as the persona is.
        let long = String(repeating: "w", count: BotPersonalityPreset.customLimit + 500)
        try tests.send(
            session,
            .saveBot(RemoteBotDraft(id: botID, name: "Pip", avatar: RemoteBotAvatar(.cherry, .cherry), personality: RemoteBotPersonality(custom: long))),
            id: "custom")
        #expect(store.bot(botID)?.personality == .custom(String(long.prefix(BotPersonalityPreset.customLimit))))
        let persona = String(repeating: "j", count: Bot.personaLimit + 10)
        try tests.send(session, .saveBot(RemoteBotDraft(id: botID, name: "Pip", avatar: RemoteBotAvatar(.cherry, .cherry), persona: persona)), id: "persona")
        #expect(store.bot(botID)?.persona.count == Bot.personaLimit)

        // A preset this Mac doesn't have changes nothing.
        try tests.send(
            session,
            .saveBot(RemoteBotDraft(id: botID, name: "Renamed", avatar: RemoteBotAvatar(.cherry, .cherry), personality: RemoteBotPersonality(preset: "stoic"))),
            id: "unknown")
        #expect(transport.error("unknown")?.code == .badRequest)
        #expect(store.bot(botID)?.name == "Pip")

        // An empty one removes it.
        try tests.send(
            session,
            .saveBot(RemoteBotDraft(id: botID, name: "Pip", avatar: RemoteBotAvatar(.cherry, .cherry), personality: RemoteBotPersonality())),
            id: "none")
        #expect(store.bot(botID)?.personality == nil)

        // A new bot from an older phone has none.
        try tests.send(session, .saveBot(RemoteBotDraft(name: "Old", avatar: RemoteBotAvatar(.teddy, .caramel))), id: "oldNew")
        guard case .bot(let oldID)? = transport.result("oldNew") else {
            Issue.record("No bot")
            return
        }
        #expect(store.bot(oldID)?.personality == nil)
    }

    @Test func theAdapterChecksAndCapsAPersonality() throws {
        #expect(try RemoteStoreAdapter.personality(RemoteBotPersonality()) == nil)
        #expect(try RemoteStoreAdapter.personality(RemoteBotPersonality(preset: "", custom: "  ")) == nil)
        #expect(try RemoteStoreAdapter.personality(RemoteBotPersonality(preset: "calm", custom: "Mine.")) == BotPersonality(presetID: "calm", custom: "Mine."))
        let long = String(repeating: "x", count: BotPersonalityPreset.customLimit * 2)
        #expect(try RemoteStoreAdapter.personality(RemoteBotPersonality(custom: long))?.custom.count == BotPersonalityPreset.customLimit)
        #expect(throws: RemoteError.self) { try RemoteStoreAdapter.personality(RemoteBotPersonality(preset: "pirate")) }
    }
}
