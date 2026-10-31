import AppKit
import CoincideKit
import SwiftUI

/// The dictation shortcut's field in Settings › Voice. Like `ShortcutRecorderView`, but it also records a modifier
/// pressed and let go on its own (Fn, ⌥…), and takes keys with Option, since dictation's shortcut isn't a menu item.
/// Escape cancels; Tab moves on.
final class DictationShortcutRecorderView: NSView {
    var shortcut: DictationShortcut = .default {
        didSet { if shortcut != oldValue { refresh() } }
    }
    var onChange: ((DictationShortcut) -> Void)?

    private(set) var isRecording = false
    private var monitor: Any?
    /// The modifier pressed alone so far, which becomes the shortcut if it's let go before any other key.
    private var loneModifier: DictationModifierKey?
    private var heldGlyphs = ""
    private var hint: String?
    private var hintTask: Task<Void, Never>?
    private let label = NSTextField(labelWithString: "")

    override init(frame: NSRect) {
        super.init(frame: frame)
        label.alignment = .center
        label.lineBreakMode = .byTruncatingTail
        label.font = .systemFont(ofSize: NSFont.smallSystemFontSize + 1, weight: .medium)
        label.translatesAutoresizingMaskIntoConstraints = false
        addSubview(label)
        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 6),
            label.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -6),
            label.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
        toolTip = String(localized: "Click, then press a key with modifiers, or press and let go of one modifier such as Fn")
        refresh()
    }

    required init?(coder: NSCoder) { fatalError() }

    override var intrinsicContentSize: NSSize { NSSize(width: ShortcutRecorderView.width, height: ShortcutRecorderView.height) }
    override var acceptsFirstResponder: Bool { true }
    override var canBecomeKeyView: Bool { true }
    override var focusRingMaskBounds: NSRect { bounds }
    override func drawFocusRingMask() { NSBezierPath(roundedRect: bounds, xRadius: 6, yRadius: 6).fill() }

    override func draw(_ dirtyRect: NSRect) {
        let path = NSBezierPath(roundedRect: bounds.insetBy(dx: 0.5, dy: 0.5), xRadius: 6, yRadius: 6)
        (isRecording ? Theme.sidebarSelection : Theme.raisedFill).setFill()
        path.fill()
        (isRecording ? Theme.ink : Theme.surfaceBorder).setStroke()
        path.lineWidth = 1
        path.stroke()
    }

    override func resetCursorRects() {
        addPointerCursorRect()
    }

    override func mouseDown(with event: NSEvent) {
        if isRecording { stopRecording() } else { startRecording() }
    }

    override func keyDown(with event: NSEvent) {
        if !isRecording, KeyModifiers(event.modifierFlags).isEmpty, [0x31, 0x24, 0x4C].contains(event.keyCode) {
            startRecording()
            return
        }
        super.keyDown(with: event)
    }

    override func resignFirstResponder() -> Bool {
        stopRecording()
        return super.resignFirstResponder()
    }

    override func viewWillMove(toWindow newWindow: NSWindow?) {
        if newWindow == nil { stopRecording() }
        super.viewWillMove(toWindow: newWindow)
    }

    private func startRecording() {
        guard !isRecording, let window else { return }
        if window.firstResponder !== self, !window.makeFirstResponder(self) { return }
        isRecording = true
        loneModifier = nil
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .flagsChanged, .leftMouseDown]) { [weak self] event in
            self?.handle(event) ?? event
        }
        refresh()
    }

    private func stopRecording() {
        guard isRecording else { return }
        isRecording = false
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
        loneModifier = nil
        heldGlyphs = ""
        hint = nil
        refresh()
    }

    private func handle(_ event: NSEvent) -> NSEvent? {
        guard isRecording else { return event }
        switch event.type {
        case .flagsChanged:
            let flags = event.modifierFlags.intersection([.command, .option, .control, .shift, .function])
            heldGlyphs = Self.glyphs(flags)
            if let key = Self.lone(flags) {
                // One modifier is down on its own; it's the shortcut if it's let go before anything else.
                loneModifier = loneModifier == nil || loneModifier == key ? key : nil
            } else if flags.isEmpty, let key = loneModifier {
                stopRecording()
                onChange?(.modifier(key))
                return event
            } else {
                loneModifier = nil
            }
            refresh()
            return event
        case .keyDown:
            guard event.window === window else { return event }
            loneModifier = nil
            if event.isARepeat { return nil }
            let modifiers = KeyModifiers(event.modifierFlags)
            if modifiers.isEmpty, event.keyCode == 0x35 {  // Escape
                stopRecording()
                return nil
            }
            if modifiers.subtracting(.shift).isEmpty, event.keyCode == 0x30 {  // Tab
                stopRecording()
                return event
            }
            guard let keys = KeyShortcut(event: event), DictationShortcut.isUsable(keys) else {
                showHint(String(localized: "Add ⌘, ⌃ or ⌥"))
                NSSound.beep()
                return nil
            }
            stopRecording()
            onChange?(.keys(keys))
            return nil
        default:
            if event.window !== window || !bounds.contains(convert(event.locationInWindow, from: nil)) { stopRecording() }
            return event
        }
    }

    private static func lone(_ flags: NSEvent.ModifierFlags) -> DictationModifierKey? {
        switch flags {
        case .function: .fn
        case .control: .control
        case .option: .option
        case .shift: .shift
        case .command: .command
        default: nil
        }
    }

    private static func glyphs(_ flags: NSEvent.ModifierFlags) -> String {
        var text = ""
        if flags.contains(.function) { text += "fn" }
        if flags.contains(.control) { text += "⌃" }
        if flags.contains(.option) { text += "⌥" }
        if flags.contains(.shift) { text += "⇧" }
        if flags.contains(.command) { text += "⌘" }
        return text
    }

    private func showHint(_ text: String) {
        hint = text
        refresh()
        hintTask?.cancel()
        hintTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(1.5))
            guard !Task.isCancelled, let self else { return }
            hint = nil
            refresh()
        }
    }

    private func refresh() {
        if isRecording {
            if let hint {
                label.stringValue = hint
                label.textColor = .systemOrange
            } else if !heldGlyphs.isEmpty {
                label.stringValue = heldGlyphs
                label.textColor = .labelColor
            } else {
                label.stringValue = String(localized: "Type Shortcut")
                label.textColor = .secondaryLabelColor
            }
        } else {
            label.stringValue = shortcut.displayString
            label.textColor = .labelColor
        }
        needsDisplay = true
        NSAccessibility.post(element: self, notification: .valueChanged)
    }

    override func isAccessibilityElement() -> Bool { true }
    override func accessibilityRole() -> NSAccessibility.Role? { .button }
    override func accessibilityLabel() -> String? { String(localized: "Dictation shortcut") }
    override func accessibilityValue() -> Any? {
        isRecording ? String(localized: "Recording. Type the new shortcut.") : shortcut.spokenDescription
    }
    override func accessibilityPerformPress() -> Bool {
        if isRecording { stopRecording() } else { startRecording() }
        return true
    }
}

struct DictationShortcutRecorder: NSViewRepresentable {
    let shortcut: DictationShortcut
    let onChange: (DictationShortcut) -> Void

    func makeNSView(context: Context) -> DictationShortcutRecorderView {
        DictationShortcutRecorderView(
            frame: NSRect(x: 0, y: 0, width: ShortcutRecorderView.width, height: ShortcutRecorderView.height))
    }

    func updateNSView(_ view: DictationShortcutRecorderView, context: Context) {
        view.onChange = onChange
        view.shortcut = shortcut
    }
}

/// What else a dictation shortcut runs into, for Settings › Voice. Dictation's monitor sees keys before the menu bar, so
/// while the composer's window is key it takes a key from a menu command that has it.
enum DictationShortcutConflicts {
    static func warnings(
        for shortcut: DictationShortcut, appshots: AppshotSettings = AppStore.shared.settings.appshots,
        bindings: KeyBindingsController = .shared
    ) -> [String] {
        guard case .keys(let keys) = shortcut else {
            // Appshots' both-⌘ chord is a ⌘ pressed and let go on its own, which a lone ⌘ shortcut would also take.
            if shortcut == .modifier(.command), appshots.enabled, appshots.trigger == .bothCommandKeys {
                return [String(localized: "Pressing both ⌘ keys for Appshots would also start dictation. Choose another key.")]
            }
            return []
        }
        var warnings: [String] = []
        if appshots.enabled, appshots.activeShortcut?.keyShortcut == keys {
            warnings.append(String(localized: "Appshots uses \(keys.displayString) in every app, so it won’t reach dictation. Choose another key."))
        }
        if let reserved = ReservedShortcut.macOS.first(where: { $0.shortcut == keys }) {
            warnings.append(String(localized: "macOS uses \(keys.displayString) for \(reserved.title), so Coincide may never see it."))
        }
        if let command = bindings.bindings.command(runBy: keys), bindings.menuShortcut(for: command) == keys {
            warnings.append(String(localized: "Dictation takes \(keys.displayString) from \(command.title) while you’re in a thread."))
        } else if let fixed = bindings.fixedMenuShortcuts().first(where: { $0.shortcut == keys }) {
            warnings.append(String(localized: "Dictation takes \(keys.displayString) from \(fixed.title) while you’re in a thread."))
        }
        if keys.modifiers.isDisjoint(with: [.command, .control]), keys.modifiers.contains(.option) {
            warnings.append(
                String(localized: "\(keys.displayString) normally types a character, such as a non-breaking space for ⌥Space. In Coincide’s windows it starts dictation instead."))
        }
        return warnings
    }
}
