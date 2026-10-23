import AppKit
import CoincideCore
import CoincideTerminal
import SwiftUI

/// What holds keyboard focus, for `when` contexts and type-to-focus.
enum KeyboardFocusKind: Equatable, Sendable {
    case terminal, composer, fileEditor, editableText
    /// Lists, buttons and other controls keep their own typing behavior.
    case interactive
    /// The window, transcript background or read-only text.
    case passive

    var isEditable: Bool { self == .composer || self == .fileEditor || self == .editableText }

    @MainActor static func classify(_ responder: NSResponder?, composer: NSTextView?) -> KeyboardFocusKind {
        guard let responder else { return .passive }
        if LocalTerminalSession.isTerminalResponder(responder) { return .terminal }
        if let text = responder as? NSTextView {
            if let composer, text === composer { return .composer }
            if text.isFieldEditor { return .editableText }
            if text.accessibilityLabel() == "File editor" { return text.isEditable ? .fileEditor : .passive }
            return text.isEditable ? .editableText : .passive
        }
        if responder is NSTextField { return .editableText }
        if responder is NSControl || responder is NSTableView || responder is NSCollectionView { return .interactive }
        return .passive
    }
}

/// T3 `composerFocusRedirect`: printable typing with no editable or interactive
/// target and no floating layer goes to the composer.
enum TypeToFocus {
    static func shouldRedirect(focus: KeyboardFocusKind, hasSheet: Bool, overlayOpen: Bool, command: Bool, control: Bool, characters: String?) -> Bool {
        guard focus == .passive, !hasSheet, !overlayOpen, !control else { return false }
        if command { return characters?.lowercased() == "v" }
        guard let scalars = characters?.unicodeScalars, let first = scalars.first else { return false }
        // Function keys (arrows, F-keys) use the private-use range; controls include Return, Tab and Escape.
        return !CharacterSet.controlCharacters.contains(first) && !(0xF700...0xF8FF).contains(first.value) && first != " "
    }
}

/// Weak registry of each window's composer editor, published by ComposerSelectionBridge.
@MainActor
enum ComposerEditorRegistry {
    private final class Entry { weak var editor: NSTextView?; init(_ editor: NSTextView) { self.editor = editor } }
    private static var entries: [Entry] = []
    static func register(_ editor: NSTextView) {
        entries.removeAll { $0.editor == nil || $0.editor === editor }
        entries.append(Entry(editor))
    }
    static func unregister(_ editor: NSTextView) { entries.removeAll { $0.editor == nil || $0.editor === editor } }
    static func editor(in window: NSWindow) -> NSTextView? {
        entries.last { $0.editor?.window === window && $0.editor?.isEditable == true }?.editor
    }
}

/// One application-wide key monitor for main windows. It resolves keybindings with
/// the window's focus context before menus see the event, so `when` conditions and
/// user overrides apply. Unmatched keys pass through untouched.
@MainActor
final class KeyboardCommandDispatcher {
    weak var keybindings: KeybindingsStore?
    private final class Registration { weak var window: NSWindow?; weak var controller: MainWindowController?
        init(_ window: NSWindow, _ controller: MainWindowController) { self.window = window; self.controller = controller } }
    private var registrations: [ObjectIdentifier: Registration] = [:]
    private var monitor: Any?
    private var observers: [NSObjectProtocol] = []
    private var declined: (timestamp: TimeInterval, keyCode: UInt16, window: Int)?

    func register(_ controller: MainWindowController, window: NSWindow) {
        registrations = registrations.filter { $0.value.window != nil && $0.value.controller != nil }
        registrations[ObjectIdentifier(window)] = Registration(window, controller)
        controller.window = window
        installIfNeeded()
    }
    func controller(for window: NSWindow?) -> MainWindowController? {
        window.flatMap { registrations[ObjectIdentifier($0)]?.controller }
    }

    func installIfNeeded() {
        guard monitor == nil else { return }
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .flagsChanged]) { [weak self] event in
            let consumed = MainActor.assumeIsolated { self.map { $0.handle(event) == nil } ?? false }
            return consumed ? nil : event
        }
        observers.append(NotificationCenter.default.addObserver(forName: NSWindow.didResignKeyNotification, object: nil, queue: .main) { [weak self] note in
            let window = note.object as? NSWindow
            MainActor.assumeIsolated { self?.controller(for: window)?.syncJumpHints(false) }
        })
    }
    func uninstall() {
        if let monitor { NSEvent.removeMonitor(monitor) }; monitor = nil
        for observer in observers { NotificationCenter.default.removeObserver(observer) }; observers.removeAll()
    }

    func context(for controller: MainWindowController, focus: KeyboardFocusKind) -> KeybindingContext {
        let store = controller.store, thread = store.selectedThread
        return KeybindingContext([
            "isDesktop": true, "isWeb": false,
            "terminalFocus": focus == .terminal, "terminalOpen": controller.presentations.terminalVisible(),
            "editableFocus": focus.isEditable, "composerFocus": focus == .composer, "fileEditorFocus": focus == .fileEditor,
            "composerDraft": !(thread?.draft.isEmpty ?? true), "turnRunning": thread.map { store.isBusy($0.id) } ?? false,
            "draftThreadRoute": thread?.messages.isEmpty ?? false,
            "rightPanelOpen": store.inspectorVisible, "inspectorOpen": store.inspectorVisible,
            "commandPaletteOpen": controller.palette != nil, "threadFindOpen": controller.find != nil,
            "previewFocus": false, "previewOpen": false, "usagePageOpen": false, "modelPickerOpen": false,
        ])
    }

    /// Returns nil when the event was handled.
    func handle(_ event: NSEvent) -> NSEvent? {
        guard let window = event.window, let controller = controller(for: window), let keybindings else { return event }
        let flags = event.modifierFlags
        let focus = KeyboardFocusKind.classify(window.firstResponder, composer: ComposerEditorRegistry.editor(in: window))
        if event.type == .flagsChanged {
            controller.syncJumpHints(window.attachedSheet == nil && controller.palette == nil && KeybindingResolver.showsThreadJumpHints(
                command: flags.contains(.command), control: flags.contains(.control), option: flags.contains(.option), shift: flags.contains(.shift),
                bindings: keybindings.keybindings, context: context(for: controller, focus: focus)))
            return event
        }
        guard event.type == .keyDown, window.attachedSheet == nil else { return event }
        if let text = window.firstResponder as? NSTextView, text.hasMarkedText() { return event }
        let stroke = KeyStroke(keyCode: event.keyCode, characters: event.charactersIgnoringModifiers,
                               command: flags.contains(.command), control: flags.contains(.control), option: flags.contains(.option), shift: flags.contains(.shift))
        let context = context(for: controller, focus: controller.palette != nil ? .editableText : focus)
        let command = keybindings.resolve(stroke, context: context)
        if let palette = controller.palette {
            // The palette keeps focus: number shortcuts choose its entries and only a few commands act.
            switch command {
            case .some(let command) where command.threadJumpNumber != nil:
                if !event.isARepeat { palette.activate(number: command.threadJumpNumber!) }
                return nil
            case .commandPaletteToggle?: controller.closePalette(); return nil
            case .chatFind?: controller.closePalette(returnFocus: false); controller.openFind(); return nil
            case .threadCopyReference?: controller.closePalette(); controller.copyThreadReference(); return nil
            default:
                if keybindings.isBound(stroke) { decline(event) }
                return event
            }
        }
        if let command, controller.canPerform(command) {
            if !event.isARepeat || Self.repeats(command) { controller.perform(command) }
            return nil
        }
        if keybindings.isBound(stroke) { decline(event); return event }
        if TypeToFocus.shouldRedirect(focus: focus, hasSheet: window.attachedSheet != nil, overlayOpen: controller.find != nil,
                                      command: flags.contains(.command), control: flags.contains(.control), characters: event.characters),
           controller.focusComposer() {
            return event
        }
        return event
    }

    /// Traversal may auto-repeat while held; toggles never do.
    static func repeats(_ command: KeybindingCommand) -> Bool { command == .threadPrevious || command == .threadNext }

    private func decline(_ event: NSEvent) { declined = (event.timestamp, event.keyCode, event.windowNumber) }
    /// A menu key equivalent that matches a keybinding the dispatcher declined
    /// (its condition was false) must not run the menu's command instead.
    func declinedCurrentEvent() -> Bool {
        guard let event = NSApp.currentEvent, event.type == .keyDown, let declined else { return false }
        return declined.timestamp == event.timestamp && declined.keyCode == event.keyCode && declined.window == event.windowNumber
    }
}

/// Registers this window with the dispatcher and the controller.
struct MainWindowKeyboardRegistration: NSViewRepresentable {
    let controller: MainWindowController
    let dispatcher: KeyboardCommandDispatcher?
    func makeNSView(context: Context) -> RegistrationView { RegistrationView(controller: controller, dispatcher: dispatcher) }
    func updateNSView(_ view: RegistrationView, context: Context) {
        view.controller = controller; view.dispatcher = dispatcher; view.registerIfPossible()
    }
    final class RegistrationView: NSView {
        weak var controller: MainWindowController?
        weak var dispatcher: KeyboardCommandDispatcher?
        init(controller: MainWindowController, dispatcher: KeyboardCommandDispatcher?) {
            self.controller = controller; self.dispatcher = dispatcher; super.init(frame: .zero)
        }
        required init?(coder: NSCoder) { nil }
        override func viewDidMoveToWindow() { super.viewDidMoveToWindow(); registerIfPossible() }
        func registerIfPossible() {
            guard let window, let controller else { return }
            controller.window = window
            dispatcher?.register(controller, window: window)
        }
    }
}
