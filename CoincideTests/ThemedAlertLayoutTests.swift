import AppKit
import CoincideKit
import Testing

@testable import Coincide

/// Themed alerts fit their buttons: in a row when the titles fit, stacked full width when they don't, and never a
/// title wider than its button. Set `COINCIDE_ALERT_PNG_DIR` (`TEST_RUNNER_COINCIDE_ALERT_PNG_DIR` through
/// xcodebuild) to also write the rendered alerts there as PNGs to look at.
@Suite(.serialized)
struct ThemedAlertLayoutTests {
    // MARK: Layout decision

    @Test func shortTitlesSitInARowAtTheUsualWidth() {
        let layout = AlertButtonLayout(buttonWidths: [80, 72])
        #expect(layout.arrangement == .row)
        #expect(layout.contentWidth == AlertButtonLayout.minimumWidth)
    }

    @Test func titlesTooWideForTheUsualWidthWidenTheAlert() {
        // 160 + 140 + 72 and two gaps of 8: 388, past 336 but within 480.
        let layout = AlertButtonLayout(buttonWidths: [160, 140, 72])
        #expect(layout.arrangement == .row)
        #expect(layout.contentWidth == 388)
    }

    @Test func titlesTooWideForTheWidestAlertStack() {
        let layout = AlertButtonLayout(buttonWidths: [320, 200, 90])
        #expect(layout.arrangement == .stacked)
        #expect(layout.contentWidth == AlertButtonLayout.minimumWidth)
        // A single title wider than the usual width widens the stacked alert to fit it.
        #expect(AlertButtonLayout(buttonWidths: [400, 200, 90]).contentWidth == 400)
        #expect(AlertButtonLayout(buttonWidths: [600]).arrangement == .stacked)
        #expect(AlertButtonLayout(buttonWidths: [600]).contentWidth == 600)
    }

    @Test func exactlyTheWidestRowStillFits() {
        let layout = AlertButtonLayout(buttonWidths: [236, 236])
        #expect(layout.arrangement == .row)
        #expect(layout.contentWidth == 480)
        #expect(AlertButtonLayout(buttonWidths: [236, 237]).arrangement == .stacked)
    }

    @Test func buttonsAreNeverNarrowerThanTheirTitleOrTheMinimum() {
        #expect(AlertButtonLayout.buttonWidth(30) == AlertButtonLayout.minimumButtonWidth)
        #expect(AlertButtonLayout.buttonWidth(120.2) == 121)
    }

    @Test func stackedButtonsPutTheDefaultFirstAndCancelLast() {
        #expect(AlertButtonLayout.stackedOrder(count: 3, cancelIndex: 2) == [0, 1, 2])
        #expect(AlertButtonLayout.stackedOrder(count: 3, cancelIndex: 1) == [0, 2, 1])
        // Cancel as the default (Safe Links) stays on top.
        #expect(AlertButtonLayout.stackedOrder(count: 2, cancelIndex: 0) == [0, 1])
        #expect(AlertButtonLayout.stackedOrder(count: 2, cancelIndex: nil) == [0, 1])
        #expect(AlertButtonLayout.stackedOrder(count: 0, cancelIndex: nil).isEmpty)
    }

    // MARK: Rendered alerts

    /// The app's alerts with the longest of their titles, in English and two languages with long words.
    nonisolated static let alerts: [(name: String, message: String, info: String, buttons: [String])] = [
        (
            "rewind-en", "Edit from here?",
            "The conversation is rewound to before this message, which returns to the composer. “Revert Files Too” also puts files back the way they were before it, undoing any edits since.",
            ["Revert and Keep Changes", "Revert Files Too", "Cancel"]
        ),
        (
            "rewind-de", "Ab hier bearbeiten?",
            "Die Unterhaltung wird bis vor diese Nachricht zurückgesetzt und kehrt in den Editor zurück.",
            ["Zurücksetzen, Änderungen behalten", "Auch Dateien zurücksetzen", "Abbrechen"]
        ),
        (
            "rewind-fr", "Modifier à partir d'ici ?",
            "La conversation revient avant ce message, qui retourne dans la zone de saisie.",
            ["Revenir en arrière et garder les modifications", "Restaurer aussi les fichiers", "Annuler"]
        ),
        ("delete-en", "Delete “Fix the login bug”?", "You can undo this deletion until Coincide quits.", ["Delete", "Cancel"]),
        (
            "instructions-de", "Eine Datei für alle Agenten ausschalten?", "",
            ["Verknüpfungen durch Kopien ersetzen", "Verknüpfungen beibehalten", "Abbrechen"]
        ),
        (
            "push-fr", "Pousser vers main ?", "",
            ["Utiliser une branche de fonctionnalité", "Continuer sur feature/very-long-branch-name", "Annuler"]
        ),
        ("save-fr", "Enregistrer les modifications de AGENTS.md ?", "", ["Enregistrer", "Ne pas enregistrer", "Annuler"]),
        ("bot-en", "Delete “Reviewer”?", "", ["Keep Conversations", "Delete Conversations", "Cancel"]),
    ]

    @Test(arguments: ThemedAlertLayoutTests.alerts.map(\.name))
    func everyButtonFitsItsTitleAndStaysInsideTheAlert(name: String) throws {
        let spec = try #require(Self.alerts.first { $0.name == name })
        let alert = ThemedAlert()
        alert.messageText = spec.message
        alert.informativeText = spec.info
        for title in spec.buttons { alert.addButton(withTitle: title) }
        let panel = alert.makePanel()
        let content = try #require(panel.contentView)
        content.layoutSubtreeIfNeeded()

        let frames = alert.buttons.map { $0.convert($0.bounds, to: content) }
        let inset: CGFloat = 22
        for (button, frame) in zip(alert.buttons, frames) {
            #expect(frame.width + 0.5 >= button.intrinsicContentSize.width, "\(name): “\(button.title)” is clipped")
            #expect(frame.minX >= inset - 0.5 && frame.maxX <= content.bounds.width - inset + 0.5, "\(name): “\(button.title)” overflows")
            #expect(frame.minY >= 0 && frame.maxY <= content.bounds.height, "\(name): “\(button.title)” is outside the alert")
        }
        // No two buttons overlap.
        for (index, frame) in frames.enumerated() {
            for other in frames[(index + 1)...] { #expect(!frame.insetBy(dx: 0.5, dy: 0.5).intersects(other), "\(name)") }
        }
        let widths = alert.buttons.map { AlertButtonLayout.buttonWidth($0.intrinsicContentSize.width) }
        let layout = AlertButtonLayout(buttonWidths: widths)
        if layout.arrangement == .stacked {
            // Full width, the default on top.
            #expect(frames.allSatisfy { abs($0.width - layout.contentWidth) < 1 }, "\(name)")
            let top = try #require(frames.max { content.isFlipped ? $0.minY > $1.minY : $0.minY < $1.minY })
            #expect(top == frames[0], "\(name)")
        } else {
            // One row, the default at the trailing end.
            #expect(Set(frames.map { Int($0.midY.rounded()) }).count == 1, "\(name)")
            #expect(frames[0].maxX == frames.map(\.maxX).max(), "\(name)")
        }
        try writePNG(of: content, panel: panel, name: name)
    }

    @Test func theRewindAlertsStackInFrenchAndGermanButNotWithShortTitles() {
        func arrangement(_ titles: [String]) -> AlertButtonLayout.Arrangement {
            let buttons = titles.map { ThemedButton(title: $0, style: .secondary, target: nil, action: nil) }
            return AlertButtonLayout(buttonWidths: buttons.map { AlertButtonLayout.buttonWidth($0.intrinsicContentSize.width) }).arrangement
        }
        #expect(arrangement(["Revenir en arrière et garder les modifications", "Restaurer aussi les fichiers", "Annuler"]) == .stacked)
        #expect(arrangement(["Delete", "Cancel"]) == .row)
        #expect(arrangement(["Save", "Don't Save", "Cancel"]) == .row)
    }

    @Test func theQuitHintRendersInTheTheme() throws {
        let hud = QuitHintHUD()
        hud.progress = 0.6
        let content = try #require(hud.panel.contentView)
        content.layoutSubtreeIfNeeded()
        #expect(content.fittingSize.width >= 160)
        try writePNG(of: content, panel: hud.panel, name: "quit-hint")
    }

    /// Writes the view, in light and dark, when `COINCIDE_ALERT_PNG_DIR` names a folder.
    private func writePNG(of view: NSView, panel: NSWindow, name: String) throws {
        guard let folder = ProcessInfo.processInfo.environment["COINCIDE_ALERT_PNG_DIR"], !folder.isEmpty else { return }
        try FileManager.default.createDirectory(atPath: folder, withIntermediateDirectories: true)
        for (suffix, appearance) in [("light", NSAppearance.Name.aqua), ("dark", .darkAqua)] {
            panel.appearance = NSAppearance(named: appearance)
            view.needsDisplay = true
            view.layoutSubtreeIfNeeded()
            let rep = try #require(view.bitmapImageRepForCachingDisplay(in: view.bounds))
            NSAppearance(named: appearance)?.performAsCurrentDrawingAppearance {
                view.cacheDisplay(in: view.bounds, to: rep)
            }
            let data = try #require(rep.representation(using: .png, properties: [:]))
            try data.write(to: URL(fileURLWithPath: folder).appendingPathComponent("\(name)-\(suffix).png"))
        }
    }
}

/// ⌘W closes windows other than the main one, and is left to the menu bar (Delete Thread…) in the main window.
struct CloseShortcutTests {
    private func key(_ characters: String, _ modifiers: NSEvent.ModifierFlags, keyCode: UInt16) throws -> NSEvent {
        try #require(
            NSEvent.keyEvent(
                with: .keyDown, location: .zero, modifierFlags: modifiers, timestamp: 0, windowNumber: 0, context: nil,
                characters: characters, charactersIgnoringModifiers: characters, isARepeat: false, keyCode: keyCode))
    }

    private func window() -> NSWindow {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 200, height: 100), styleMask: [.titled, .closable], backing: .buffered, defer: true)
        window.isReleasedWhenClosed = false
        return window
    }

    @Test func commandWClosesAnotherWindowButNotTheMainOne() throws {
        let main = window()
        let settings = window()
        let commandW = try key("w", .command, keyCode: 13)
        #expect(CloseShortcut.window(toCloseFor: commandW, keyWindow: settings, mainWindow: main) === settings)
        #expect(CloseShortcut.window(toCloseFor: commandW, keyWindow: main, mainWindow: main) == nil)
        #expect(CloseShortcut.window(toCloseFor: commandW, keyWindow: nil, mainWindow: main) == nil)
        // Before the main window exists, any key window closes with ⌘W.
        #expect(CloseShortcut.window(toCloseFor: commandW, keyWindow: settings, mainWindow: nil) === settings)
    }

    @Test func otherKeysAreLeftAlone() throws {
        let main = window()
        let settings = window()
        for event in [try key("W", [.command, .shift], keyCode: 13), try key("w", [], keyCode: 13), try key("q", .command, keyCode: 12)] {
            #expect(CloseShortcut.window(toCloseFor: event, keyWindow: settings, mainWindow: main) == nil)
        }
    }
}
