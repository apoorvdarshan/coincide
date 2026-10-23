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
    private final class RemoteUndoRegistration {
        weak var window: NSWindow?; weak var store: RemoteThreadActionsStore?
        init(_ window: NSWindow, _ store: RemoteThreadActionsStore) { self.window = window; self.store = store }
    }
    private var remoteUndoRegistrations: [ObjectIdentifier: RemoteUndoRegistration] = [:]
    func registerRemoteUndo(_ store: RemoteThreadActionsStore, window: NSWindow) {
        guard controller(for: window) == nil else { return }
        remoteUndoRegistrations = remoteUndoRegistrations.filter { $0.value.window != nil && $0.value.store != nil }
        if let displaced = remoteUndoRegistrations[ObjectIdentifier(window)]?.store, displaced !== store { displaced.unbind(window: window) }
        remoteUndoRegistrations[ObjectIdentifier(window)] = .init(window, store); store.bind(window: window); installIfNeeded()
    }
    func unregisterRemoteUndo(_ store: RemoteThreadActionsStore, window: NSWindow) {
        if remoteUndoRegistrations[ObjectIdentifier(window)]?.store === store { remoteUndoRegistrations.removeValue(forKey: ObjectIdentifier(window)) }
        store.unbind(window: window)
    }
    private var monitor: Any?
    private var observers: [NSObjectProtocol] = []
    private var declined: (timestamp: TimeInterval, keyCode: UInt16, window: Int)?
    private struct EventIdentity: Hashable {
        let object: ObjectIdentifier
        let timestamp: TimeInterval
        let window: Int
        let keyCode: UInt16
        let type: UInt
        init(_ event: NSEvent) {
            object = ObjectIdentifier(event); timestamp = event.timestamp; window = event.windowNumber
            keyCode = event.keyCode; type = event.type.rawValue
        }
    }
    private struct Decision { let event: NSEvent; let handled: Bool; let declined: Bool }
    private var decisions: [EventIdentity: Decision] = [:]
    private var decisionOrder: [EventIdentity] = []
    private var retiredControllers: [ObjectIdentifier: MainWindowController] = [:]
    private var retirements: [ObjectIdentifier: Task<Void, Never>] = [:]

    func register(_ controller: MainWindowController, window: NSWindow) {
        if let remote = remoteUndoRegistrations.removeValue(forKey: ObjectIdentifier(window)) { remote.store?.unbind(window: window) }
        registrations = registrations.filter { $0.value.window != nil && $0.value.controller != nil }
        if let displaced = registrations[ObjectIdentifier(window)]?.controller,
           displaced !== controller, displaced.window === window {
            retire(displaced)
        }
        registrations[ObjectIdentifier(window)] = Registration(window, controller)
        controller.activate()
        controller.window = window
        installIfNeeded()
    }
    func controller(for window: NSWindow?) -> MainWindowController? {
        guard let window, let entry = registrations[ObjectIdentifier(window)], entry.window === window,
              let controller = entry.controller, controller.window === window, controller.isActive else { return nil }
        return controller
    }
    func unregister(_ controller: MainWindowController, window: NSWindow) {
        if registrations[ObjectIdentifier(window)]?.controller === controller { registrations.removeValue(forKey: ObjectIdentifier(window)) }
        if controller.window === window { retire(controller) }
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
        for entry in registrations.values { if let controller = entry.controller { retire(controller) } }
        for entry in remoteUndoRegistrations.values { if let window = entry.window { entry.store?.unbind(window: window) } }
        remoteUndoRegistrations.removeAll()
        registrations.removeAll(); decisions.removeAll(); decisionOrder.removeAll(); declined = nil
    }
    func shutdown() async {
        uninstall()
        while !retirements.isEmpty { for task in Array(retirements.values) { await task.value }; await Task.yield() }
    }
    private func retire(_ controller: MainWindowController) {
        controller.deactivate()
        let id = ObjectIdentifier(controller)
        guard retiredControllers[id] == nil else { return }
        retiredControllers[id] = controller
        retirements[id] = Task { [weak self, controller] in
            await controller.drain()
            self?.retiredControllers.removeValue(forKey: id); self?.retirements.removeValue(forKey: id)
        }
    }

    func context(for controller: MainWindowController, focus: KeyboardFocusKind) -> KeybindingContext {
        let store = controller.store, thread = store.selectedThread
        return KeybindingContext([
            "isDesktop": true, "isWeb": false,
            "threadUndoAvailable": controller.store.threadActionUndo.claimsShortcut(ownerID: controller.undoOwnerID),
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
        let identity = EventIdentity(event)
        if let decision = decisions[identity] {
            if decision.declined { decline(event) } else { declined = nil }
            return decision.handled ? nil : event
        }
        declined = nil
        let result = handleOnce(event)
        let decision = Decision(event: event, handled: result == nil, declined: declined != nil)
        decisions[identity] = decision; decisionOrder.append(identity)
        if decisionOrder.count > 64 { decisions.removeValue(forKey: decisionOrder.removeFirst()) }
        return result
    }
    /// The native terminal and app monitors share the exact event decision.
    /// New/close/split keys are owned by the configured engine even when unbound.
    func routeTerminalEvent(_ event: NSEvent) -> TerminalKeyEventDisposition {
        if handle(event) == nil { return .handled }
        switch TerminalCommand.keyCommand(characters: event.charactersIgnoringModifiers, modifiers: event.modifierFlags) {
        case .newTerminal?, .close?, .splitRight?, .splitDown?: return .passThrough
        default: return .useDefault
        }
    }
    func terminalKeyEquivalent(_ command: TerminalCommand, in window: NSWindow?) -> TerminalKeyEquivalent? {
        guard let window, window.isKeyWindow, let controller = controller(for: window), controller.canHandleInteraction,
              let keybindings else { return nil }
        let configured: KeybindingCommand
        switch command {
        case .newTerminal: configured = .terminalNew
        case .close: configured = .terminalClose
        case .splitRight: configured = .terminalSplit
        case .splitDown: configured = .terminalSplitVertical
        default: return nil
        }
        guard let shortcut = keybindings.shortcut(for: configured, context: context(for: controller, focus: .terminal)),
              let key = KeybindingsStore.keyEquivalent(shortcut.key) else { return nil }
        var modifiers: NSEvent.ModifierFlags = []
        if shortcut.usesCommand { modifiers.insert(.command) }
        if shortcut.control { modifiers.insert(.control) }
        if shortcut.option { modifiers.insert(.option) }
        if shortcut.shift { modifiers.insert(.shift) }
        return .init(characters: String(key.character), modifiers: modifiers)
    }
    private func handleOnce(_ event: NSEvent) -> NSEvent? {
        if let window = event.window, window.isKeyWindow, let remote = remoteUndoRegistrations[ObjectIdentifier(window)], remote.window === window,
           controller(for: window) == nil, let keybindings, let store = remote.store {
            return store.route(event, keybindings: keybindings) ? nil : event
        }
        guard let window = event.window, window.isKeyWindow, let controller = controller(for: window),
              controller.canHandleInteraction, let keybindings else { return event }
        let flags = event.modifierFlags
        let focus = KeyboardFocusKind.classify(window.firstResponder, composer: ComposerEditorRegistry.editor(in: window))
        if event.type == .flagsChanged {
            controller.syncJumpHints(window.attachedSheet == nil && controller.palette == nil && KeybindingResolver.showsThreadJumpHints(
                command: flags.contains(.command), control: flags.contains(.control), option: flags.contains(.option), shift: flags.contains(.shift),
                bindings: keybindings.keybindings, context: context(for: controller, focus: focus)))
            return event
        }
        guard event.type == .keyDown, window.attachedSheet == nil else { return event }
        if let text = window.firstResponder as? NSTextView, text.hasMarkedText() {
            controller.store.threadActionUndo.releaseShortcut(ownerID: controller.undoOwnerID)
            return event
        }
        let stroke = KeyStroke(keyCode: event.keyCode, characters: event.charactersIgnoringModifiers,
                               command: flags.contains(.command), control: flags.contains(.control), option: flags.contains(.option), shift: flags.contains(.shift))
        let context = context(for: controller, focus: controller.palette != nil ? .editableText : focus)
        let projectDefaults = controller.presentations.projectActions()?.defaults ?? []
        let command = keybindings.resolve(stroke, context: context, projectDefaults: projectDefaults)
        if command != .threadUndo { controller.store.threadActionUndo.releaseShortcut(ownerID: controller.undoOwnerID) }
        if command?.scriptID != nil {
            if stroke.command, !stroke.control, !stroke.option,
               !stroke.keys.isDisjoint(with: ["c", "x", "v", "a", "z"]),
               (window.firstResponder as? NSTextView).map({ $0.isEditable || $0.isSelectable }) == true {
                // Empty selections and unavailable clipboard contents disable a
                // native edit action; they never turn its key into a shell run.
                return event
            }
            // Project shortcuts yield to the current responder's native Edit,
            // Window and Quit actions, including the existing quit protection.
            if Self.nativeMenuOwns(stroke, menu: NSApp.mainMenu, window: window) { return event }
            if (focus == .fileEditor || focus == .terminal), stroke.command, !stroke.control, !stroke.option,
               !stroke.shift, stroke.keys.contains("f") {
                decline(event) // Preserve MenuCommandInvocation's native Find fallback.
                return event
            }
        }
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
                if keybindings.isBound(stroke, projectDefaults: projectDefaults) { decline(event) }
                return event
            }
        }
        if let command {
            guard controller.canPerform(command) else { decline(event); return nil }
            if !event.isARepeat || Self.repeats(command) { controller.perform(command) }
            return nil
        }
        if keybindings.isBound(stroke, projectDefaults: projectDefaults) { decline(event); return event }
        if TypeToFocus.shouldRedirect(focus: focus, hasSheet: window.attachedSheet != nil, overlayOpen: controller.find != nil,
                                      command: flags.contains(.command), control: flags.contains(.control), characters: event.characters),
           controller.focusComposer() {
            return event
        }
        return event
    }

    /// Traversal may auto-repeat while held; toggles never do.
    static func repeats(_ command: KeybindingCommand) -> Bool { command == .threadPrevious || command == .threadNext }

    private static func nativeMenuOwns(_ stroke: KeyStroke, menu: NSMenu?, window: NSWindow) -> Bool {
        guard let menu else { return false }
        let nativeActions: Set<String> = [
            "copy:", "cut:", "paste:", "pasteAsPlainText:", "pasteAndMatchStyle:", "selectAll:", "undo:", "redo:",
            "performTextFinderAction:", "performFindPanelAction:", "saveDocument:", "saveDocumentAs:", "revertDocumentToSaved:",
            "performClose:", "terminate:", "hide:", "hideOtherApplications:", "unhideAllApplications:",
            "miniaturize:", "performMiniaturize:", "performZoom:", "showPreferencesWindow:", "showSettingsWindow:"
        ]
        for item in menu.items where !item.isHidden {
            if let submenu = item.submenu, (item.isEnabled || menu.autoenablesItems), nativeMenuOwns(stroke, menu: submenu, window: window) { return true }
            guard !item.keyEquivalent.isEmpty, let action = item.action, nativeActions.contains(NSStringFromSelector(action)) else { continue }
            let modifiers = item.keyEquivalentModifierMask
            let shortcut = KeybindingShortcut(key: item.keyEquivalent.lowercased(), meta: modifiers.contains(.command),
                control: modifiers.contains(.control), shift: modifiers.contains(.shift) || item.keyEquivalent != item.keyEquivalent.lowercased(),
                option: modifiers.contains(.option))
            guard shortcut.matches(stroke), let target = NSApp.target(forAction: action, to: item.target, from: item) else { continue }
            if let view = target as? NSView, view.window !== window { continue }
            if let targetWindow = target as? NSWindow, targetWindow !== window { continue }
            // Autoenabled menu state may be stale until the next presentation.
            // Ask the current target before allowing a script to consume its key.
            if let validator = target as? NSMenuItemValidation {
                if validator.validateMenuItem(item) { return true }
            } else if let validator = target as? NSUserInterfaceValidations {
                if validator.validateUserInterfaceItem(item) { return true }
            } else if item.isEnabled { return true }
        }
        return false
    }

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
    static func dismantleNSView(_ view: RegistrationView, coordinator: ()) { view.unregister() }
    final class RegistrationView: NSView {
        weak var controller: MainWindowController?
        weak var dispatcher: KeyboardCommandDispatcher?
        private weak var registeredWindow: NSWindow?
        private weak var registeredController: MainWindowController?
        private weak var registeredDispatcher: KeyboardCommandDispatcher?
        init(controller: MainWindowController, dispatcher: KeyboardCommandDispatcher?) {
            self.controller = controller; self.dispatcher = dispatcher; super.init(frame: .zero)
        }
        required init?(coder: NSCoder) { nil }
        override func viewDidMoveToWindow() { super.viewDidMoveToWindow(); registerIfPossible() }
        func registerIfPossible() {
            if registeredWindow !== window || registeredController !== controller || registeredDispatcher !== dispatcher { unregister() }
            guard let window, let controller else { return }
            controller.window = window
            dispatcher?.register(controller, window: window)
            registeredWindow = window; registeredController = controller; registeredDispatcher = dispatcher
        }
        func unregister() {
            if let registeredWindow, let registeredController {
                if let registeredDispatcher { registeredDispatcher.unregister(registeredController, window: registeredWindow) }
                else if registeredController.window === registeredWindow { registeredController.deactivate() }
            }
            registeredWindow = nil; registeredController = nil; registeredDispatcher = nil
        }
    }
}
