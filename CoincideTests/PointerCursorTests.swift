import AppKit
import CoincideKit
import Testing

@testable import Coincide

/// Settings › General › Pointing hand over clickable items (`PointerCursor`): the setting, and where AppKit's views get
/// the hand. The hand's cursor areas are recorded rather than added. Windows are borderless, offscreen and transparent,
/// and never ordered in.
@MainActor
@Suite(.serialized)
struct PointerCursorTests {
    /// Where `addPointerCursorRect` and the control hook put the hand.
    private final class HandRecorder {
        private(set) var rects: [(view: NSView, rect: NSRect)] = []

        func record(_ view: NSView, _ rect: NSRect) { rects.append((view, rect)) }

        func clear() { rects.removeAll() }

        func rects(in view: NSView) -> [NSRect] {
            rects.filter { $0.view === view }.map(\.rect)
        }

        /// The rects the hand gets in `view` when it sets its cursor areas again.
        func hands(_ view: NSView) -> [NSRect] {
            clear()
            view.resetCursorRects()
            return rects(in: view)
        }
    }

    /// A custom control that is clickable only sometimes.
    private final class TestChip: NSControl, PointerCursorControl {
        var clickable = true
        var isClickable: Bool { clickable }
    }

    /// A window that counts how often its cursor areas are redone, and which views it was told to redo.
    private final class RecordingWindow: NSWindow {
        private(set) var resets = 0
        private(set) var invalidated: [NSView] = []

        override func resetCursorRects() {
            resets += 1
            super.resetCursorRects()
        }

        override func invalidateCursorRects(for view: NSView) {
            invalidated.append(view)
            super.invalidateCursorRects(for: view)
        }
    }

    private static func offscreenWindow(holding views: [NSView]) -> RecordingWindow {
        let window = RecordingWindow(
            contentRect: NSRect(x: -20_000, y: -20_000, width: 400, height: 240), styleMask: [.borderless], backing: .buffered,
            defer: false)
        window.alphaValue = 0
        window.isReleasedWhenClosed = false
        let content = NSView(frame: NSRect(x: 0, y: 0, width: 400, height: 240))
        for (index, view) in views.enumerated() {
            view.frame = NSRect(x: 10, y: 10 + CGFloat(index) * 26, width: 120, height: 22)
            content.addSubview(view)
        }
        window.contentView = content
        return window
    }

    /// Runs `body` with the hooks installed, the setting `on` and the hand recorded, then puts everything back.
    private static func withRecorder(on: Bool = true, _ body: (HandRecorder) throws -> Void) rethrows {
        let cursor = PointerCursor.shared
        cursor.start()
        let savedAdd = cursor.addCursorRect
        let savedOn = cursor.isOn
        let recorder = HandRecorder()
        cursor.addCursorRect = { view, rect in recorder.record(view, rect) }
        cursor.setOn(on)
        defer {
            cursor.addCursorRect = savedAdd
            cursor.setOn(savedOn)
        }
        try body(recorder)
    }

    // MARK: Setting

    @Test func isOnByDefaultAndSurvivesUnreadableValues() throws {
        #expect(AppSettings().showsPointingHand)
        #expect(try JSONDecoder().decode(AppSettings.self, from: Data(#"{"fontSize": 15}"#.utf8)).showsPointingHand)
        for value in ["null", "3", #""no""#, "[]", "{}"] {
            let settings = try JSONDecoder().decode(
                AppSettings.self, from: Data(#"{"showsPointingHand": \#(value), "fontSize": 15, "holdToQuit": false}"#.utf8))
            #expect(settings.showsPointingHand, "\(value) turned it off")
            #expect(settings.fontSize == 15 && !settings.holdToQuit, "\(value) lost other settings")
        }
        var off = AppSettings()
        off.showsPointingHand = false
        let saved = try JSONEncoder().encode(off)
        #expect(try !JSONDecoder().decode(AppSettings.self, from: saved).showsPointingHand)
    }

    @Test func restoreDefaultsTurnsItBackOn() {
        var settings = AppSettings()
        settings.showsPointingHand = false
        GeneralSettingsView.restoreDefaults(in: &settings)
        #expect(settings.showsPointingHand)
    }

    @Test func settingsSearchFindsIt() throws {
        let entries = SettingsSearchResults.entries(kinds: [])
        for query in ["pointing hand", "pointer", "cursor", "hand", "clickable"] {
            #expect(entries.contains { $0.setting == .pointingHand && $0.matches(query) }, "\(query) doesn't find it")
        }
        let entry = try #require(entries.first { $0.setting == .pointingHand })
        #expect(entry.pane == .section(.general))
    }

    @Test func followsTheSettingWithoutARestart() {
        let store = AppStore.shared
        let saved = store.settings.showsPointingHand
        defer { store.updateSettings { $0.showsPointingHand = saved } }
        PointerCursor.shared.start()
        let window = Self.offscreenWindow(holding: [])
        defer { window.close() }

        store.updateSettings { $0.showsPointingHand = true }
        #expect(PointerCursor.shared.isOn)
        let resets = window.resets
        store.updateSettings { $0.showsPointingHand = false }
        #expect(!PointerCursor.shared.isOn)
        #expect(window.resets == resets + 1, "the open window kept its cursor areas")
        #expect(!PointerCursor.shared.showsHand())
        store.updateSettings { $0.showsPointingHand = true }
        #expect(PointerCursor.shared.isOn)
        #expect(window.resets == resets + 2)
        #expect(PointerCursor.shared.showsHand())
    }

    @Test func turningItOnOrOffRedoesTheCursorAreasOfOpenWindows() {
        let button = NSButton(title: "Run", target: nil, action: nil)
        let window = Self.offscreenWindow(holding: [button])
        defer { window.close() }
        Self.withRecorder(on: false) { recorder in
            recorder.clear()
            PointerCursor.shared.setOn(true)
            #expect(recorder.rects(in: button) == [button.bounds], "the open window's button got no hand")
            recorder.clear()
            PointerCursor.shared.setOn(false)
            #expect(recorder.rects(in: button).isEmpty)
        }
    }

    @Test func handNeedsTheSettingAndAnEnabledControl() {
        Self.withRecorder(on: true) { _ in
            #expect(PointerCursor.shared.showsHand())
            #expect(PointerCursor.shared.showsHand(enabled: true))
            #expect(!PointerCursor.shared.showsHand(enabled: false))
        }
        Self.withRecorder(on: false) { _ in
            #expect(!PointerCursor.shared.showsHand())
            #expect(!PointerCursor.shared.showsHand(enabled: true))
        }
    }

    // MARK: AppKit controls

    @Test func buttonsAndSegmentedControlsShowTheHandWhileEnabled() {
        let button = NSButton(title: "Run", target: nil, action: nil)
        let popUp = NSPopUpButton(frame: .zero, pullsDown: false)
        let checkbox = NSButton(checkboxWithTitle: "Include", target: nil, action: nil)
        let segmented = NSSegmentedControl(labels: ["One", "Two"], trackingMode: .selectOne, target: nil, action: nil)
        let window = Self.offscreenWindow(holding: [button, popUp, checkbox, segmented])
        defer { window.close() }
        Self.withRecorder(on: true) { recorder in
            for control in [button, popUp, checkbox, segmented] as [NSControl] {
                #expect(recorder.hands(control) == [control.bounds], "\(type(of: control)) has no hand")
                control.isEnabled = false
                #expect(recorder.hands(control).isEmpty, "disabled \(type(of: control)) shows the hand")
                control.isEnabled = true
                #expect(recorder.hands(control) == [control.bounds])
            }
        }
        Self.withRecorder(on: false) { recorder in
            for control in [button, popUp, checkbox, segmented] as [NSControl] {
                #expect(recorder.hands(control).isEmpty, "\(type(of: control)) shows the hand with the setting off")
            }
        }
    }

    @Test func textFieldsAndSlidersKeepTheirOwnCursors() {
        let field = NSTextField(string: "Type here")
        let label = NSTextField(labelWithString: "A label")
        let slider = NSSlider(value: 1, minValue: 0, maxValue: 2, target: nil, action: nil)
        let window = Self.offscreenWindow(holding: [field, label, slider])
        defer { window.close() }
        Self.withRecorder(on: true) { recorder in
            for control in [field, label, slider] as [NSControl] {
                #expect(recorder.hands(control).isEmpty, "\(type(of: control)) shows the hand")
                #expect(!PointerCursor.shared.showsHand(over: control))
            }
        }
    }

    @Test func customControlsShowTheHandWhenClickable() {
        let chip = TestChip(frame: .zero)
        let pickerChip = PickerChip(title: "High", isSelected: false) {}
        let window = Self.offscreenWindow(holding: [chip, pickerChip])
        defer { window.close() }
        Self.withRecorder(on: true) { recorder in
            #expect(recorder.hands(chip) == [chip.bounds])
            #expect(recorder.hands(pickerChip) == [pickerChip.bounds])
            chip.clickable = false
            #expect(recorder.hands(chip).isEmpty)
            chip.clickable = true
            chip.isEnabled = false
            #expect(recorder.hands(chip).isEmpty)
        }
        Self.withRecorder(on: false) { recorder in
            chip.isEnabled = true
            #expect(recorder.hands(chip).isEmpty)
            #expect(recorder.hands(pickerChip).isEmpty)
        }
    }

    @Test func enablingOrDisablingAControlRedoesItsCursorArea() {
        let button = NSButton(title: "Send", target: nil, action: nil)
        let window = Self.offscreenWindow(holding: [button])
        defer { window.close() }
        Self.withRecorder(on: true) { _ in
            button.isEnabled = false
            #expect(window.invalidated.contains { $0 === button })
            let count = window.invalidated.count
            button.isEnabled = false
            #expect(window.invalidated.count == count, "an unchanged state redid the cursor area")
            button.isEnabled = true
            #expect(window.invalidated.count == count + 1)
        }
    }

    // MARK: Other clickable views

    @Test func viewsAddTheHandOnlyWhenClickableAndOn() {
        let view = NSView(frame: NSRect(x: 0, y: 0, width: 40, height: 20))
        let window = Self.offscreenWindow(holding: [view])
        defer { window.close() }
        Self.withRecorder(on: true) { recorder in
            view.addPointerCursorRect()
            #expect(recorder.rects(in: view) == [view.bounds])
            recorder.clear()
            let part = NSRect(x: 4, y: 0, width: 10, height: 20)
            view.addPointerCursorRect(part)
            #expect(recorder.rects(in: view) == [part])
            recorder.clear()
            view.addPointerCursorRect(clickable: false)
            view.addPointerCursorRect(.zero)
            #expect(recorder.rects(in: view).isEmpty)
        }
        Self.withRecorder(on: false) { recorder in
            view.addPointerCursorRect()
            #expect(recorder.rects(in: view).isEmpty)
        }
    }

    @Test func tabsRowsAndMenuItemsShowTheHand() {
        let tab = TerminalTabItemView()
        let row = ThemedTableRowView()
        let note = ThemedTableRowView(isClickable: false)
        let item = ThemedMenuRowView()
        item.configure(.item(NSMenuItem(title: "Open", action: nil, keyEquivalent: "")))
        let disabled = ThemedMenuRowView()
        let unavailable = NSMenuItem(title: "Unavailable", action: nil, keyEquivalent: "")
        unavailable.isEnabled = false
        disabled.configure(.item(unavailable))
        let header = ThemedMenuRowView()
        header.configure(.header("Recent"))
        let back = ThemedMenuRowView()
        back.configure(.back("Models"))
        let window = Self.offscreenWindow(holding: [tab, row, note, item, disabled, header, back])
        defer { window.close() }
        Self.withRecorder(on: true) { recorder in
            for view in [tab, row, item, back] as [NSView] {
                #expect(recorder.hands(view) == [view.bounds], "\(type(of: view)) has no hand")
            }
            for view in [note, disabled, header] as [NSView] {
                #expect(recorder.hands(view).isEmpty, "\(type(of: view)) shows the hand")
            }
        }
        Self.withRecorder(on: false) { recorder in
            for view in [tab, row, item, back] as [NSView] {
                #expect(recorder.hands(view).isEmpty, "\(type(of: view)) shows the hand with the setting off")
            }
        }
    }

    @Test func threadCellsAndTheirLabelsShowTheHandUntilTheTitleIsEdited() throws {
        let cell = ThreadCell()
        let window = Self.offscreenWindow(holding: [cell])
        defer { window.close() }
        cell.frame = NSRect(x: 10, y: 10, width: 360, height: 28)
        cell.configure(ThreadRowModel(title: "Owned thread", place: "Fixture", provider: .codex,
            isPinned: false, isArchived: false, status: .idle, updatedAt: Date(), canArchive: true,
            toolTip: "Owned fixture", accessibilityLabel: "Owned thread"))
        cell.layoutSubtreeIfNeeded()
        let title = try #require(cell.textField as? SidebarThreadLabel)
        let labels = TerminalFocus.descendants(of: cell, as: SidebarThreadLabel.self)
        #expect(labels.count == 3)
        Self.withRecorder(on: true) { recorder in
            #expect(recorder.hands(cell) == [cell.bounds])
            for label in labels where !label.isHidden {
                #expect(recorder.hands(label) == [label.bounds])
            }
            title.isEditable = true
            title.isSelectable = true
            #expect(recorder.hands(title).isEmpty, "renaming must retain the text field's own cursor")
            title.isEditable = false
            title.isSelectable = false
            #expect(recorder.hands(title) == [title.bounds])
        }
        Self.withRecorder(on: false) { recorder in
            #expect(recorder.hands(cell).isEmpty)
            for label in labels { #expect(recorder.hands(label).isEmpty) }
        }
    }
}
