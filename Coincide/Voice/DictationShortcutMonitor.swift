import AppKit
import CoincideKit

/// Watches for the dictation shortcut while the composer's window is key, and turns presses into start, stop and
/// cancel through `DictationTriggerMachine`. Installed only while Settings › Voice › Keyboard shortcut is on; with it
/// off, Coincide watches no keys for dictation at all. A local monitor sees only Coincide's own events, never other apps'.
final class DictationShortcutMonitor {
    /// What the shortcut asks for.
    var onAction: ((DictationTriggerMachine.Action) -> Void)?

    private var monitor: Any?
    private weak var window: NSWindow?
    private var shortcut: DictationShortcut = .default
    private var machine = DictationTriggerMachine(mode: .both, isLoneModifier: true)
    private var holdTimer: Timer?
    private var resignObserver: NSObjectProtocol?

    var isInstalled: Bool { monitor != nil }

    /// Starts watching `window`'s key events for `shortcut`.
    func install(window: NSWindow, shortcut: DictationShortcut, mode: DictationShortcutMode, isRecording: Bool) {
        if monitor != nil, self.window === window, self.shortcut == shortcut, machine.mode == mode { return }
        uninstall()
        self.window = window
        self.shortcut = shortcut
        machine = DictationTriggerMachine(mode: mode, isLoneModifier: shortcut.isLoneModifier)
        if isRecording { machine.recordingStarted() }
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .keyUp, .flagsChanged]) { [weak self] event in
            guard let self else { return event }
            return handle(event)
        }
        resignObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.didResignKeyNotification, object: window, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                // A key let go in another window would never come back as a release.
                self?.holdTimer?.invalidate()
                self?.machine.reset()
            }
        }
    }

    func uninstall() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
        if let resignObserver { NotificationCenter.default.removeObserver(resignObserver) }
        resignObserver = nil
        holdTimer?.invalidate()
        holdTimer = nil
        machine.reset()
    }

    /// Keeps the shortcut's idea of dictation in step when the button, an error or Escape in the text started or ended it.
    func recordingStarted() { machine.recordingStarted() }
    func recordingEnded() { machine.recordingEnded() }

    // MARK: Events

    private func handle(_ event: NSEvent) -> NSEvent? {
        guard let window, event.window === window, window.isKeyWindow, window.attachedSheet == nil else { return event }
        let now = event.timestamp
        switch event.type {
        case .flagsChanged:
            guard case .modifier(let key) = shortcut else { return event }
            let held = Self.modifiers(event.modifierFlags)
            let flag = Self.flag(for: key)
            if held == flag, !machine.isPressed {
                perform(machine.triggerDown(at: now))
            } else if machine.isPressed, !held.contains(flag) {
                perform(machine.triggerUp(at: now))
            } else if machine.isPressed, held != flag {
                perform(machine.otherInput(at: now))
            }
            return event
        case .keyDown:
            if event.keyCode == 0x35, machine.isRecording {  // Escape
                perform(machine.escape())
                return nil
            }
            switch shortcut {
            case .modifier:
                if machine.isPressed { perform(machine.otherInput(at: now)) }
                return event
            case .keys(let keys):
                guard Self.matches(event, keys) else { return event }
                if !event.isARepeat { perform(machine.triggerDown(at: now)) }
                return nil
            }
        case .keyUp:
            guard case .keys(let keys) = shortcut, machine.isPressed, event.keyCode == Self.keyCode(of: event, matching: keys) else {
                return event
            }
            perform(machine.triggerUp(at: now))
            return nil
        default:
            return event
        }
    }

    private func perform(_ action: DictationTriggerMachine.Action) {
        switch action {
        case .none: return
        case .scheduleHoldCheck(let delay):
            holdTimer?.invalidate()
            holdTimer = Timer.scheduledTimer(withTimeInterval: delay, repeats: false) { [weak self] _ in
                MainActor.assumeIsolated {
                    guard let self else { return }
                    self.perform(self.machine.holdCheck(at: ProcessInfo.processInfo.systemUptime))
                }
            }
        case .start, .stop, .cancel:
            holdTimer?.invalidate()
            onAction?(action)
        }
    }

    /// Command, Option, Control, Shift and Fn, ignoring Caps Lock and the keypad and arrow flags.
    private static func modifiers(_ flags: NSEvent.ModifierFlags) -> NSEvent.ModifierFlags {
        flags.intersection([.command, .option, .control, .shift, .function])
    }

    private static func flag(for key: DictationModifierKey) -> NSEvent.ModifierFlags {
        switch key {
        case .fn: .function
        case .control: .control
        case .option: .option
        case .shift: .shift
        case .command: .command
        }
    }

    /// The key press is `shortcut`, with exactly its modifiers.
    private static func matches(_ event: NSEvent, _ shortcut: KeyShortcut) -> Bool {
        guard let pressed = KeyShortcut(event: event) else { return false }
        return pressed == shortcut
    }

    /// Releases carry no modifiers worth trusting (they may already be up), so a release matches by its key alone.
    private static func keyCode(of event: NSEvent, matching shortcut: KeyShortcut) -> UInt16? {
        let pressed = KeyShortcut.recorded(
            keyCode: event.keyCode, character: event.characters(byApplyingModifiers: []), modifiers: shortcut.modifiers)
        return pressed?.key == shortcut.key ? event.keyCode : nil
    }
}

/// macOS's own use of the 🌐 key (System Settings › Keyboard › "Press 🌐 key to"), which also acts when Fn is the
/// dictation shortcut. Coincide only reads it, to suggest changing it; it never changes the system's setting.
enum SystemFnKeyUsage: Equatable {
    case doNothing
    case changeInputSource
    case showEmoji
    case startDictation
    /// Not set or unreadable; macOS then does something by default.
    case unknown

    static var current: SystemFnKeyUsage {
        let value = CFPreferencesCopyAppValue("AppleFnUsageType" as CFString, "com.apple.HIToolbox" as CFString)
        guard let number = value as? NSNumber else { return .unknown }
        switch number.intValue {
        case 0: return .doNothing
        case 1: return .changeInputSource
        case 2: return .showEmoji
        case 3: return .startDictation
        default: return .unknown
        }
    }

    var displayName: String {
        switch self {
        case .doNothing: String(localized: "Do Nothing")
        case .changeInputSource: String(localized: "Change Input Source")
        case .showEmoji: String(localized: "Show Emoji & Symbols")
        case .startDictation: String(localized: "Start Dictation")
        case .unknown: ""
        }
    }

    static func openKeyboardSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.Keyboard-Settings.extension") { NSWorkspace.shared.open(url) }
    }
}

/// How menus and the command palette name the dictation shortcut.
enum DictationMenu {
    /// "Hold or tap 🌐 fn", "Tap ⌥Space"; nil when the shortcut is off.
    static func subtitle(for voice: VoiceSettings) -> String? {
        guard voice.isEnabled, voice.shortcutEnabled else { return nil }
        let keys = voice.shortcut.displayString
        return switch voice.shortcutMode {
        case .both: String(localized: "Hold or tap \(keys)")
        case .hold: String(localized: "Hold \(keys)")
        case .tap: String(localized: "Tap \(keys)")
        }
    }
}
