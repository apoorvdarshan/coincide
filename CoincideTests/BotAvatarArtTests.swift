import AppKit
import CoincideRemoteKit
import Testing

@testable import Coincide
@testable import CoincideKit

/// The bot characters, drawn offscreen into bitmaps, and the editor's character picker. Nothing is shown on screen.
@MainActor
struct BotAvatarArtTests {
    /// Draws `avatar` centered in a bitmap with a margin around its square, and returns the bitmap.
    private func render(_ avatar: BotAvatar, size: CGFloat, openness: CGFloat = 1, margin: CGFloat = 8) -> NSBitmapImageRep {
        let side = Int(size + margin * 2)
        let rep = NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: side, pixelsHigh: side, bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
            isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
        let context = NSGraphicsContext(bitmapImageRep: rep)!
        let cg = context.cgContext
        // The art draws top down, as in the app's flipped views.
        cg.translateBy(x: 0, y: CGFloat(side))
        cg.scaleBy(x: 1, y: -1)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: cg, flipped: true)
        BotAvatarArt.draw(avatar, in: CGRect(x: margin, y: margin, width: size, height: size), openness: openness)
        NSGraphicsContext.restoreGraphicsState()
        return rep
    }

    /// Pixels with any real paint, inside the square (`margin` in from the edges) or outside it.
    private func painted(_ rep: NSBitmapImageRep, inside: Bool, margin: Int) -> Int {
        guard let data = rep.bitmapData else { return 0 }
        var count = 0
        for y in 0..<rep.pixelsHigh {
            for x in 0..<rep.pixelsWide {
                let isInside = (margin..<rep.pixelsWide - margin).contains(x) && (margin..<rep.pixelsHigh - margin).contains(y)
                guard isInside == inside, data[y * rep.bytesPerRow + x * 4 + 3] > 25 else { continue }
                count += 1
            }
        }
        return count
    }

    @Test(arguments: BotAvatar.Shape.allCases)
    func everyCharacterFillsItsSquareAtEverySizeAndColorWithoutSpillingOut(_ character: BotAvatar.Shape) {
        for size: CGFloat in [16, 26, 56, 128] {
            // Every color at the sizes the app uses most; the large one in the character's own color.
            for tint in size > 56 ? [character.defaultTint] : BotAvatar.Tint.allCases {
                let rep = render(BotAvatar(shape: character, tint: tint), size: size)
                let area = Int(size * size)
                // A character covers a good part of its square, whatever its silhouette.
                #expect(painted(rep, inside: true, margin: 8) > area / 5, "\(character) at \(size) in \(tint)")
                // Nothing but antialiasing reaches past the square's edge.
                #expect(painted(rep, inside: false, margin: 7) == 0, "\(character) spills out at \(size) in \(tint)")
            }
        }
    }

    @Test(arguments: BotAvatar.Shape.allCases)
    func everyCharacterBlinks(_ character: BotAvatar.Shape) {
        for size: CGFloat in [16, 26, 56] {
            let open = render(BotAvatar(character: character), size: size)
            let shut = render(BotAvatar(character: character), size: size, openness: 0.12)
            #expect(open.tiffRepresentation != shut.tiffRepresentation, "\(character) does not blink at \(size)")
        }
    }

    @Test func recoloringChangesTheCharactersBody() {
        for character in BotAvatar.Shape.allCases {
            let other = BotAvatar.Tint.allCases.first { $0 != character.defaultTint }!
            let own = render(BotAvatar(character: character), size: 56)
            let recolored = render(BotAvatar(shape: character, tint: other), size: 56)
            #expect(own.tiffRepresentation != recolored.tiffRepresentation, "\(character) ignores its color")
        }
    }

    // MARK: Editor

    private func editor(bots: [Bot] = []) -> (BotEditor, TemporaryDirectory) {
        let folder = TemporaryDirectory("bot-editor")
        let store = AppStore(directory: folder.url)
        for bot in bots { store.addBot(bot) }
        let editor = BotEditor(bot: nil, store: store, registry: ProviderRegistry(store: store, providers: []))
        _ = editor.view
        return (editor, folder)
    }

    private func button(_ character: BotAvatar.Shape, in editor: BotEditor) throws -> BotChoiceButton {
        try #require(editor.shapeButtons.first {
            if case .shape(let shape) = $0.kind { return shape == character }
            return false
        })
    }

    @Test func aNewBotIsACharacterNoBotIsYetInItsOwnColorAndName() throws {
        let selection = ModelSelection(provider: .claude, modelID: "default")
        let taken = BotAvatar.Shape.allCases.dropLast().map {
            Bot(name: $0.defaultName, avatar: BotAvatar(character: $0), persona: "", selection: selection)
        }
        let (editor, folder) = editor(bots: taken)
        _ = folder
        let free = try #require(BotAvatar.Shape.allCases.last)
        #expect(editor.draft.avatar == BotAvatar(character: free))
        #expect(editor.nameField.stringValue == free.defaultName)
        #expect(editor.shapeButtons.count == BotAvatar.Shape.allCases.count)
    }

    @Test func pickingACharacterBringsItsColorAndItsNameUnlessTheUserNamedTheBot() throws {
        let (editor, folder) = editor()
        _ = folder
        let first = editor.draft.avatar.shape
        let second = try #require(BotAvatar.Shape.allCases.first { $0 != first })
        editor.pickShape(try button(second, in: editor))
        #expect(editor.draft.avatar == BotAvatar(character: second))
        #expect(editor.nameField.stringValue == second.defaultName)
        // The chosen character shows in the bot's color, the others in their own.
        for choice in editor.shapeButtons {
            guard case .shape(let shape) = choice.kind else { continue }
            #expect(choice.isChosen == (shape == second))
            #expect(choice.tint == shape.defaultTint)
        }

        editor.nameField.stringValue = "Biscuit"
        let third = try #require(BotAvatar.Shape.allCases.first { $0 != first && $0 != second })
        editor.pickShape(try button(third, in: editor))
        #expect(editor.draft.avatar.shape == third)
        #expect(editor.nameField.stringValue == "Biscuit")
    }

    // MARK: Coincide Remote's editor

    /// Coincide Remote's look (`BotEditorLook`) next to the Mac editor's draft: same character, color, name and picker
    /// colors.
    private func expectSame(
        _ look: BotEditorLook, _ editor: BotEditor, sourceLocation: SourceLocation = #_sourceLocation
    ) {
        #expect(look.character.rawValue == editor.draft.avatar.shape.rawValue, sourceLocation: sourceLocation)
        #expect(look.tint.rawValue == editor.draft.avatar.tint.rawValue, sourceLocation: sourceLocation)
        #expect(look.name == editor.nameField.stringValue, sourceLocation: sourceLocation)
        for choice in editor.shapeButtons {
            guard case .shape(let shape) = choice.kind, let character = BotArtwork.Character(rawValue: shape.rawValue) else {
                continue
            }
            #expect(look.pickerTint(for: character).rawValue == choice.tint.rawValue, "\(shape)", sourceLocation: sourceLocation)
        }
    }

    @Test func thePhonesEditorShowsAndPicksCharactersAsTheMacsDoes() throws {
        let (editor, folder) = editor()
        _ = folder
        let start = try #require(BotArtwork.Character(rawValue: editor.draft.avatar.shape.rawValue))
        var look = BotEditorLook(character: start)
        expectSame(look, editor)
        // Every character the picker offers is in its own color, not the bot's (a pink alien, star and teddy before).
        for option in BotArtwork.Character.allCases where option != start {
            #expect(look.pickerTint(for: option) == option.defaultTint)
        }

        // Picking each character in turn brings its color and name.
        for option in BotArtwork.Character.allCases.reversed() where option != start {
            look.pick(option)
            editor.pickShape(try button(try #require(BotAvatar.Shape(rawValue: option.rawValue)), in: editor))
            expectSame(look, editor)
            #expect(look == BotEditorLook(character: option))
        }

        // A color the user picks shows on the chosen character only, and the next pick brings that one's own color.
        look.tint = .sky
        let sky = BotChoiceButton(kind: .tint(.sky), target: editor, action: NSSelectorFromString("pickTint:"))
        _ = editor.perform(NSSelectorFromString("pickTint:"), with: sky)
        expectSame(look, editor)
        let chosen = look.character
        #expect(look.pickerTint(for: chosen) == .sky)
        let next = try #require(BotArtwork.Character.allCases.first { $0 != chosen })
        look.pick(next)
        editor.pickShape(try button(try #require(BotAvatar.Shape(rawValue: next.rawValue)), in: editor))
        expectSame(look, editor)
        #expect(look.tint == next.defaultTint)

        // A name the user wrote stays; an emptied one takes the next character's.
        look.name = "Biscuit"
        editor.nameField.stringValue = "Biscuit"
        let third = try #require(BotArtwork.Character.allCases.first { $0 != next })
        look.pick(third)
        editor.pickShape(try button(try #require(BotAvatar.Shape(rawValue: third.rawValue)), in: editor))
        expectSame(look, editor)
        #expect(look.name == "Biscuit")
        look.name = " "
        editor.nameField.stringValue = " "
        look.pick(next)
        editor.pickShape(try button(try #require(BotAvatar.Shape(rawValue: next.rawValue)), in: editor))
        expectSame(look, editor)
        #expect(look.name == next.defaultName)
        // Picking the chosen character again changes nothing.
        look.tint = .lilac
        look.pick(next)
        #expect(look.tint == .lilac)
    }

    @Test func thePhonesNewBotIsACharacterNoBotIsYet() {
        let all = Set(BotArtwork.Character.allCases)
        for free in BotArtwork.Character.allCases {
            #expect(BotEditorLook.newBot(avoiding: all.subtracting([free])) == BotEditorLook(character: free))
        }
        // With every character taken, any of them in its own color and name.
        let any = BotEditorLook.newBot(avoiding: all)
        #expect(any == BotEditorLook(character: any.character))
    }
}
