import AppKit
import Testing

@testable import Coincide
@testable import CoincideKit

/// The bot editor laid out in the window AppKit makes for a sheet (`presentAsSheet` makes it with
/// `NSWindow(contentViewController:)`): its content shows, scrolls only when it is taller than the screen has room for,
/// and reaches VoiceOver. Headless: the window is borderless, transparent and far off every screen, never shown.
@MainActor
struct BotEditorLayoutTests {
    nonisolated private static let selection = ModelSelection(provider: .claude, modelID: "default")
    /// A bot to edit, like the starter Brulee, with a personality of its own.
    nonisolated private static let brulee = Bot(
        name: "Brulee", avatar: BotAvatar(character: .brulee), persona: "Plans the week.", personality: .preset("cheerful"),
        selection: selection)

    private struct Sheet {
        let editor: BotEditor
        let window: NSWindow
        let folder: TemporaryDirectory

        var content: NSView { window.contentView! }

        /// Where `view` is in the window's content, in its coordinates.
        func frame(of view: NSView) -> NSRect { content.convert(view.bounds, from: view) }

        /// Whether `view` is laid out with a size and shows inside the window, not scrolled out of it.
        func shows(_ view: NSView) -> Bool {
            let frame = frame(of: view)
            let visible = content.convert(editor.scroll.contentView.bounds, from: editor.scroll.contentView)
            return frame.width > 0 && frame.height > 0 && content.bounds.contains(frame) && visible.contains(frame)
        }
    }

    private func sheet(editing bot: Bot?, maximumHeight: CGFloat) -> Sheet {
        let folder = TemporaryDirectory("bot-editor-layout")
        let store = AppStore(directory: folder.url)
        let editor = BotEditor(
            bot: bot, store: store, registry: ProviderRegistry(store: store, providers: []), maximumHeight: maximumHeight)
        let window = NSWindow(contentViewController: editor)
        window.styleMask = [.borderless]
        window.alphaValue = 0
        window.setFrameOrigin(NSPoint(x: -20_000, y: -20_000))
        window.layoutIfNeeded()
        return Sheet(editor: editor, window: window, folder: folder)
    }

    private func buttons(titled title: String, in view: NSView) -> [NSButton] {
        ((view as? NSButton).map { $0.title == title ? [$0] : [] } ?? []) + view.subviews.flatMap { buttons(titled: title, in: $0) }
    }

    /// The labels and titles of everything VoiceOver reaches in `element`, all the way down.
    private func accessibleNames(in element: Any) -> [String] {
        let names: [String?]
        let children: [Any]?
        switch element {
        case let window as NSWindow:
            (names, children) = ([], window.accessibilityChildren())
        case let view as NSView:
            (names, children) = ([view.accessibilityLabel(), view.accessibilityTitle()], view.accessibilityChildren())
        // Controls answer through their cells, with the label set on the control.
        case let cell as NSCell:
            (names, children) = (
                [cell.accessibilityLabel(), cell.accessibilityTitle(), cell.controlView?.accessibilityLabel()], cell.accessibilityChildren())
        case let other as NSAccessibilityElement:
            (names, children) = ([other.accessibilityLabel(), other.accessibilityTitle()], other.accessibilityChildren())
        default:
            (names, children) = ([], nil)
        }
        return names.compactMap { $0 }.filter { !$0.isEmpty } + (children ?? []).flatMap { accessibleNames(in: $0) }
    }

    /// A screen with room for everything: the sheet is as tall as its content and doesn't scroll.
    @Test(arguments: [nil, BotEditorLayoutTests.brulee] as [Bot?])
    func theSheetShowsAllItsContentWhenTheScreenHasRoom(editing bot: Bot?) throws {
        let sheet = sheet(editing: bot, maximumHeight: 2_000)
        let editor = sheet.editor
        let document = try #require(editor.scroll.documentView)
        #expect(sheet.content.frame.width >= 520)
        #expect(document.frame.height > 500)
        #expect(abs(sheet.content.frame.height - document.frame.height) <= 1, "\(sheet.content.frame) \(document.frame)")
        #expect(editor.scroll.documentVisibleRect.height >= document.frame.height - 1)
        #expect(editor.scroll.verticalScroller?.isHidden ?? true)
        let save = try #require(buttons(titled: bot == nil ? "Create Bot" : "Save", in: sheet.content).first)
        let cancel = try #require(buttons(titled: "Cancel", in: sheet.content).first)
        for view in [editor.nameField, editor.persona, save, cancel] + editor.personality.chips as [NSView] {
            #expect(sheet.shows(view), "\(type(of: view)) \(sheet.frame(of: view)) in \(sheet.content.frame)")
        }
        // Nothing in the layout is left to chance.
        #expect(!editor.scroll.hasAmbiguousLayout && !document.hasAmbiguousLayout)

        // VoiceOver reaches the fields, the personality's chips and the buttons.
        let names = accessibleNames(in: sheet.window)
        let characters = BotAvatar.Shape.allCases.map(BotAvatarArt.name(of:))
        for name in ["Name", "Instructions", "Cancel", save.title] + characters + editor.personality.chips.map(\.title) {
            #expect(names.contains(name), "\(name) not in \(names)")
        }

        // A personality that shows more (Custom's editor) makes the sheet taller to fit.
        let before = sheet.content.frame.height
        editor.personality.pick(try #require(editor.personality.chips.first { $0.choice == .custom }))
        sheet.window.layoutIfNeeded()
        #expect(sheet.content.frame.height > before)
        #expect(abs(sheet.content.frame.height - document.frame.height) <= 1)
        #expect(sheet.shows(editor.personality.customText.enclosingScrollView!))
        #expect(sheet.shows(save))
        sheet.window.contentViewController = nil
    }

    /// A screen too short for it: the sheet takes the room there is and scrolls the rest, from the top.
    @Test(arguments: [nil, BotEditorLayoutTests.brulee] as [Bot?])
    func theSheetScrollsWhenTheScreenIsShorterThanItsContent(editing bot: Bot?) throws {
        let sheet = sheet(editing: bot, maximumHeight: 420)
        let editor = sheet.editor
        let document = try #require(editor.scroll.documentView)
        #expect(abs(sheet.content.frame.height - 420) <= 1, "\(sheet.content.frame)")
        #expect(sheet.content.frame.width >= 520)
        // Not squeezed to fit: the content keeps its height, and scrolls.
        #expect(document.frame.height > 600)
        #expect(!editor.scroll.hasAmbiguousLayout && !document.hasAmbiguousLayout)
        // It starts at the top, with the name.
        #expect(sheet.shows(editor.nameField), "\(sheet.frame(of: editor.nameField)) in \(sheet.content.frame)")
        let save = try #require(buttons(titled: bot == nil ? "Create Bot" : "Save", in: sheet.content).first)
        #expect(!sheet.shows(save))
        // And scrolls down to the buttons.
        save.scrollToVisible(save.bounds)
        sheet.window.layoutIfNeeded()
        #expect(sheet.shows(save), "\(sheet.frame(of: save)) in \(sheet.content.frame)")
        sheet.window.contentViewController = nil
    }
}
