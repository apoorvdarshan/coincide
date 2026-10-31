import AppKit
import CoincideKit
import ObjectiveC
import Observation
import SwiftUI

/// Settings › General › Pointing hand over clickable items (`AppSettings.showsPointingHand`): the pointing-hand cursor
/// over what can be clicked, as on the web, in place of the arrow. On by default. Turned off, every cursor is the one
/// AppKit and SwiftUI show on their own, and either way the change shows at once.
///
/// One mechanism per kind of view, rather than cursor code in each:
/// - AppKit's buttons (pop-up buttons, checkboxes, toolbar and disclosure buttons included) and segmented controls get
///   the hand from a hook on `NSControl.resetCursorRects()` while they're enabled (`showsHand(over:)`). A hook on
///   `NSControl.isEnabled` redoes a control's cursor area when it changes, so a control that is disabled shows the
///   arrow right away. Custom controls opt in with `PointerCursorControl`.
/// - Other clickable AppKit views (tabs, list rows, menu rows, chips) call `addPointerCursorRect(_:clickable:)` from
///   their own `resetCursorRects()`.
/// - SwiftUI's buttons, toggles, links and rows use `pointerCursor()`, which `ThemedButtonStyle` and the themed switch,
///   checkbox and picker apply for every view that uses them.
///
/// Text views, text fields, the terminal and web views never get it: they keep the I-beam and the cursors they set
/// themselves. Links in text show AppKit's own pointing hand whatever the setting, as they always have.
@Observable
final class PointerCursor {
    static let shared = PointerCursor()

    /// Whether the setting is on. A SwiftUI view that reads it is redrawn when it changes.
    private(set) var isOn = true

    /// Adds the hand's cursor area to a view. Tests replace it to see where the hand would show.
    @ObservationIgnored var addCursorRect: (NSView, NSRect) -> Void = { view, rect in
        view.addCursorRect(rect, cursor: .pointingHand)
    }

    @ObservationIgnored private var token: ObservationToken?
    private static var hooksInstalled = false

    /// Installs the AppKit hooks and follows the setting from now on. Called once at launch; later calls do nothing.
    func start(store: AppStore = .shared) {
        guard token == nil else { return }
        Self.installHooks()
        isOn = store.settings.showsPointingHand
        Self.resetCursorRectsOfAllWindows()
        token = store.observe { [weak self, weak store] change in
            guard change == .settings, let store else { return }
            self?.setOn(store.settings.showsPointingHand)
        }
    }

    /// Turns the hand on or off and redoes every window's cursor areas, so the change shows without a restart.
    func setOn(_ on: Bool) {
        guard on != isOn else { return }
        isOn = on
        Self.resetCursorRectsOfAllWindows()
    }

    /// Has every window set its views' cursor areas again.
    private static func resetCursorRectsOfAllWindows() {
        for window in NSApplication.shared.windows { window.resetCursorRects() }
    }

    /// Whether something clickable shows the hand now: the setting is on and the thing is `enabled`.
    func showsHand(enabled: Bool = true) -> Bool {
        isOn && enabled
    }

    /// Whether `control` shows the hand: while the setting is on, an enabled button or segmented control, or a custom
    /// control (`PointerCursorControl`) that is clickable now. Status items in the menu bar and the title bar's window
    /// buttons keep the arrow, as they do everywhere on macOS. Text fields, sliders and other controls aren't clicked like
    /// a button, so they keep their own cursors.
    func showsHand(over control: NSControl) -> Bool {
        guard showsHand(enabled: control.isEnabled) else { return false }
        switch control {
        case let control as PointerCursorControl: return control.isClickable
        case is NSStatusBarButton: return false
        case let button as NSButton: return !Self.isWindowButton(button)
        case is NSSegmentedControl: return true
        default: return false
        }
    }

    /// The close, minimize and zoom buttons of the button's window.
    private static func isWindowButton(_ button: NSButton) -> Bool {
        guard let window = button.window else { return false }
        let kinds: [NSWindow.ButtonType] = [.closeButton, .miniaturizeButton, .zoomButton]
        return kinds.contains { window.standardWindowButton($0) === button }
    }

    /// Whether a control can show the hand at all, whatever its state: one whose cursor area needs redoing when it's
    /// enabled or disabled.
    private static func canShowHand(_ control: NSControl) -> Bool {
        control is PointerCursorControl || control is NSButton || control is NSSegmentedControl
    }

    // MARK: AppKit hooks

    /// After `NSControl.resetCursorRects()`, which sets the cursor areas a control has of its own (a text field's I-beam),
    /// adds the hand over the controls `showsHand(over:)` picks. After `NSControl.isEnabled` changes, redoes the control's
    /// cursor areas.
    private static func installHooks() {
        guard !hooksInstalled else { return }
        hooksInstalled = true

        let reset = #selector(NSView.resetCursorRects)
        if let method = class_getInstanceMethod(NSControl.self, reset) {
            typealias Reset = @convention(c) (NSObject, Selector) -> Void
            let original = unsafeBitCast(method_getImplementation(method), to: Reset.self)
            let replacement: @convention(block) (NSObject) -> Void = { object in
                original(object, reset)
                guard let control = object as? NSControl else { return }
                MainActor.assumeIsolated { PointerCursor.shared.addHand(to: control) }
            }
            override(reset, of: NSControl.self, method: method, with: imp_implementationWithBlock(replacement))
        }

        let setEnabled = #selector(setter: NSControl.isEnabled)
        if let method = class_getInstanceMethod(NSControl.self, setEnabled) {
            typealias SetEnabled = @convention(c) (NSObject, Selector, ObjCBool) -> Void
            let original = unsafeBitCast(method_getImplementation(method), to: SetEnabled.self)
            let replacement: @convention(block) (NSObject, ObjCBool) -> Void = { object, enabled in
                let control = object as? NSControl
                let wasEnabled = control?.isEnabled
                original(object, setEnabled, enabled)
                guard let control, let wasEnabled, wasEnabled != control.isEnabled else { return }
                MainActor.assumeIsolated { PointerCursor.shared.enabledDidChange(control) }
            }
            override(setEnabled, of: NSControl.self, method: method, with: imp_implementationWithBlock(replacement))
        }
    }

    /// Gives `cls` `imp` for `selector`: added to it when it only inherits `method`, so its superclass keeps the original,
    /// otherwise in place of its own.
    private static func override(_ selector: Selector, of cls: AnyClass, method: Method, with imp: IMP) {
        if !class_addMethod(cls, selector, imp, method_getTypeEncoding(method)) {
            method_setImplementation(method, imp)
        }
    }

    private func addHand(to control: NSControl) {
        guard showsHand(over: control) else { return }
        addCursorRect(control, control.bounds)
    }

    private func enabledDidChange(_ control: NSControl) {
        guard isOn, Self.canShowHand(control), let window = control.window else { return }
        window.invalidateCursorRects(for: control)
    }
}

/// A custom control clicked like a button. It shows the pointing hand while it's enabled and `isClickable`
/// (`PointerCursor`); AppKit's buttons and segmented controls need no conformance.
protocol PointerCursorControl: NSControl {
    /// Whether a click does something now, besides the control being enabled. True unless the control says otherwise.
    var isClickable: Bool { get }
}

extension PointerCursorControl {
    var isClickable: Bool { true }
}

extension NSView {
    /// For `resetCursorRects()`: the pointing hand over `rect` (the bounds unless given) while Settings › General ›
    /// Pointing hand over clickable items is on and `clickable` is true (`PointerCursor`). Buttons, segmented controls and
    /// `PointerCursorControl`s get it without this.
    func addPointerCursorRect(_ rect: NSRect? = nil, clickable: Bool = true) {
        let rect = rect ?? bounds
        guard PointerCursor.shared.showsHand(enabled: clickable), !rect.isEmpty else { return }
        PointerCursor.shared.addCursorRect(self, rect)
    }
}

extension View {
    /// The pointing hand over this view while it's enabled and Settings › General › Pointing hand over clickable items
    /// is on (`PointerCursor`), for SwiftUI's buttons, toggles, links and rows.
    func pointerCursor() -> some View {
        modifier(PointerCursorModifier())
    }

    /// `pointerCursor()` over the whole width of a list row, its empty end included.
    func pointerCursorRow() -> some View {
        frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
            .pointerCursor()
    }
}

private struct PointerCursorModifier: ViewModifier {
    @Environment(\.isEnabled) private var isEnabled

    func body(content: Content) -> some View {
        content.pointerStyle(PointerCursor.shared.showsHand(enabled: isEnabled) ? .link : nil)
    }
}
