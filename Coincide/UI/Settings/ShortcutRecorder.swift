import AppKit
import CoincideKit
import SwiftUI

/// A shortcut field like those in System Settings › Keyboard: it shows a shortcut and, once clicked, records the next
/// key combination. While it records, Escape cancels, Delete removes the shortcut, Tab moves on and no menu command
/// runs, as T3 Code suppresses its shortcuts while one is captured.
final class ShortcutRecorderView: NSView {
    static let width: CGFloat = 112
    static let height: CGFloat = 22
    /// From the top of a field `height` tall to its text's baseline, for lining it up with other text.
    static let baselineOffset: CGFloat = {
        let label = makeLabel()
        label.stringValue = "⌘K"
        return (height - label.intrinsicContentSize.height) / 2 + label.firstBaselineOffsetFromTop
    }()

    var shortcut: KeyShortcut? {
        didSet { if shortcut != oldValue { refresh() } }
    }
    /// The command the shortcut is for, for VoiceOver.
    var commandTitle = ""
    /// Called with the recorded shortcut, or nil when the user removed it.
    var onChange: ((KeyShortcut?) -> Void)?
    var onRecordingChange: ((Bool) -> Void)?

    private(set) var isRecording = false
    private var heldModifiers: KeyModifiers = []
    /// A short note in place of the shortcut, such as "Add ⌘ or ⌃".
    private var hint: String?
    private var hintTask: Task<Void, Never>?
    private var monitor: Any?
    private var resignObserver: NSObjectProtocol?
    private let label = ShortcutRecorderView.makeLabel()

    private static func makeLabel() -> NSTextField {
        let label = NSTextField(labelWithString: "")
        label.alignment = .center
        label.lineBreakMode = .byTruncatingTail
        label.font = .systemFont(ofSize: NSFont.smallSystemFontSize + 1, weight: .medium)
        label.translatesAutoresizingMaskIntoConstraints = false
        return label
    }

    override init(frame: NSRect) {
        super.init(frame: frame)
        addSubview(label)
        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 6),
            label.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -6),
            label.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
        toolTip = String(localized: "Click to record a new shortcut")
        refresh()
    }

    required init?(coder: NSCoder) { fatalError() }

    override var intrinsicContentSize: NSSize { NSSize(width: Self.width, height: Self.height) }

    /// The text's baseline, so Auto Layout can line the field up with a label.
    override var firstBaselineOffsetFromTop: CGFloat { Self.baselineOffset + (bounds.height - Self.height) / 2 }

    override var lastBaselineOffsetFromBottom: CGFloat { bounds.height - firstBaselineOffsetFromTop }

    override var acceptsFirstResponder: Bool { true }
    override var canBecomeKeyView: Bool { true }
    override var focusRingMaskBounds: NSRect { bounds }

    override func drawFocusRingMask() {
        NSBezierPath(roundedRect: bounds, xRadius: 6, yRadius: 6).fill()
    }

    override func draw(_ dirtyRect: NSRect) {
        let path = NSBezierPath(roundedRect: bounds.insetBy(dx: 0.5, dy: 0.5), xRadius: 6, yRadius: 6)
        (isRecording ? Theme.sidebarSelection : Theme.raisedFill).setFill()
        path.fill()
        (isRecording ? Theme.ink : Theme.surfaceBorder).setStroke()
        path.lineWidth = 1
        path.stroke()
    }

    // MARK: Starting and stopping

    override func mouseDown(with event: NSEvent) {
        if isRecording {
            stopRecording()
        } else {
            startRecording()
        }
    }

    override func keyDown(with event: NSEvent) {
        // Space or Return starts recording from the keyboard, like pressing a button.
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
        heldModifiers = KeyModifiers(NSEvent.modifierFlags)
        // A local monitor sees keys before the menu bar does, so recording can take any shortcut that reaches the app.
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .flagsChanged, .leftMouseDown, .rightMouseDown]) {
            [weak self] event in
            self?.handle(event) ?? event
        }
        resignObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.didResignKeyNotification, object: window, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.stopRecording() }
        }
        onRecordingChange?(true)
        refresh()
    }

    private func stopRecording() {
        guard isRecording else { return }
        isRecording = false
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
        if let resignObserver { NotificationCenter.default.removeObserver(resignObserver) }
        resignObserver = nil
        heldModifiers = []
        hintTask?.cancel()
        hint = nil
        onRecordingChange?(false)
        refresh()
    }

    // MARK: Recording

    private func handle(_ event: NSEvent) -> NSEvent? {
        guard isRecording else { return event }
        switch event.type {
        case .flagsChanged:
            heldModifiers = KeyModifiers(event.modifierFlags)
            refresh()
            return event
        case .keyDown:
            guard event.window === window else { return event }
            return record(event) ? nil : event
        default:
            // A click anywhere else ends recording, and goes ahead.
            if event.window !== window || !bounds.contains(convert(event.locationInWindow, from: nil)) { stopRecording() }
            return event
        }
    }

    /// Handles a key press while recording. Returns false to let it through.
    private func record(_ event: NSEvent) -> Bool {
        if event.isARepeat { return true }
        let modifiers = KeyModifiers(event.modifierFlags)
        switch (modifiers, event.keyCode) {
        case ([], 0x35):  // Escape
            stopRecording()
            return true
        case ([], 0x33), ([], 0x75):  // Delete, Forward Delete
            stopRecording()
            onChange?(nil)
            return true
        case ([], 0x30), ([.shift], 0x30):  // Tab, Shift-Tab
            stopRecording()
            return false
        default:
            break
        }
        guard let shortcut = KeyShortcut(event: event) else {
            NSSound.beep()
            return true
        }
        guard shortcut.isUsableInMenus else {
            // Without Command or Control the shortcut would take the key from every text field.
            showHint(String(localized: "Add ⌘ or ⌃"))
            NSSound.beep()
            return true
        }
        stopRecording()
        onChange?(shortcut)
        return true
    }

    private func showHint(_ text: String) {
        hint = text
        refresh()
        hintTask?.cancel()
        hintTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(1.5))
            guard !Task.isCancelled, let self else { return }
            self.hint = nil
            self.refresh()
        }
    }

    // MARK: Display

    private func refresh() {
        if isRecording {
            if let hint {
                label.stringValue = hint
                label.textColor = .systemOrange
            } else if !heldModifiers.isEmpty {
                label.stringValue = Self.glyphs(heldModifiers)
                label.textColor = .labelColor
            } else {
                label.stringValue = String(localized: "Type Shortcut")
                label.textColor = .secondaryLabelColor
            }
        } else if let shortcut {
            label.stringValue = shortcut.displayString
            label.textColor = .labelColor
        } else {
            label.stringValue = String(localized: "None")
            label.textColor = .tertiaryLabelColor
        }
        needsDisplay = true
        NSAccessibility.post(element: self, notification: .valueChanged)
    }

    private static func glyphs(_ modifiers: KeyModifiers) -> String {
        var glyphs = ""
        if modifiers.contains(.control) { glyphs += "⌃" }
        if modifiers.contains(.option) { glyphs += "⌥" }
        if modifiers.contains(.shift) { glyphs += "⇧" }
        if modifiers.contains(.command) { glyphs += "⌘" }
        return glyphs
    }

    // MARK: Accessibility

    override func isAccessibilityElement() -> Bool { true }
    override func accessibilityRole() -> NSAccessibility.Role? { .button }
    override func accessibilityLabel() -> String? { String(localized: "Shortcut for \(commandTitle)") }

    override func accessibilityValue() -> Any? {
        if isRecording { return String(localized: "Recording. Type the new shortcut.") }
        return shortcut?.spokenDescription ?? String(localized: "None")
    }

    override func accessibilityHelp() -> String? {
        String(localized: "Records a new shortcut. Escape cancels; Delete removes the shortcut.")
    }

    override func accessibilityPerformPress() -> Bool {
        if isRecording {
            stopRecording()
        } else {
            startRecording()
        }
        return true
    }
}

/// `ShortcutRecorderView` for SwiftUI.
struct ShortcutRecorder: NSViewRepresentable {
    let shortcut: KeyShortcut?
    let commandTitle: String
    var onRecordingChange: (Bool) -> Void = { _ in }
    let onChange: (KeyShortcut?) -> Void

    func makeNSView(context: Context) -> ShortcutRecorderView {
        ShortcutRecorderView(frame: NSRect(x: 0, y: 0, width: ShortcutRecorderView.width, height: ShortcutRecorderView.height))
    }

    func updateNSView(_ view: ShortcutRecorderView, context: Context) {
        view.commandTitle = commandTitle
        view.onChange = onChange
        view.onRecordingChange = onRecordingChange
        view.shortcut = shortcut
    }
}
