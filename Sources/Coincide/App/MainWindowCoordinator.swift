import AppKit
import SwiftUI

/// Owns presentation intent, never a window or a second copy of the workspace.
/// The Commands environment outlives individual ContentViews, so its native
/// OpenWindowAction remains available after the last main window is closed.
@MainActor
final class MainWindowCoordinator {
    static let sceneID = "coincide-main"
    private var openAction: (@MainActor () -> Void)?
    private var resolvedAction: (@MainActor () -> Void)?
    private var relayInstallation: Task<Void, Never>?
    private var needsPresentation = false
    private var awaitingPresentation = false
    private var windows: [ObjectIdentifier: Registration] = [:]
    private let restoreExisting: (@MainActor () -> Bool)?
    var currentWindow: NSWindow? {
        let live = windows.values.compactMap(\.window)
        return live.first(where: \.isKeyWindow) ?? live.first(where: \.isVisible) ?? live.first
    }

    init(restoreExisting: (@MainActor () -> Bool)? = nil) { self.restoreExisting = restoreExisting }

    /// Resolving Commands.body must not publish view state. Registration is
    /// deferred and coalesced; a pending launch/reopen survives that ordering.
    @discardableResult
    func installOpenAction(_ action: @escaping @MainActor () -> Void) -> Task<Void, Never>? {
        resolvedAction = action
        if openAction != nil { openAction = action; return relayInstallation }
        if let relayInstallation { return relayInstallation }
        let task = Task { [weak self] in
            guard let self else { return }
            self.openAction = self.resolvedAction
            self.relayInstallation = nil
            if self.needsPresentation { self.presentIfNeeded() }
        }
        relayInstallation = task
        return task
    }

    func presentIfNeeded() {
        if restoreExisting?() ?? restoreRegisteredWindow() {
            needsPresentation = false; awaitingPresentation = false
            return
        }
        needsPresentation = true
        guard !awaitingPresentation, let openAction else { return }
        needsPresentation = false; awaitingPresentation = true
        openAction()
    }

    func newWindow() {
        guard let openAction else { needsPresentation = true; return }
        awaitingPresentation = true
        openAction()
    }

    func register(_ window: NSWindow) {
        let id = ObjectIdentifier(window)
        guard windows[id] == nil else { awaitingPresentation = false; return }
        let registration = Registration(window)
        let observer = NotificationCenter.default.addObserver(forName: NSWindow.willCloseNotification, object: window, queue: .main) { [weak self] _ in
            Task<Void, Never> { @MainActor [weak self] in _ = self?.windows.removeValue(forKey: id) }
        }
        registration.observer = CloseObservation(observer)
        windows[id] = registration
        needsPresentation = false; awaitingPresentation = false
    }

    private func restoreRegisteredWindow() -> Bool {
        windows = windows.filter { $0.value.window != nil }
        guard let window = currentWindow, window.isVisible || window.isMiniaturized else { return false }
        if window.isMiniaturized { window.deminiaturize(nil) }
        window.makeKeyAndOrderFront(nil)
        return true
    }

    private final class Registration {
        weak var window: NSWindow?
        var observer: CloseObservation?
        init(_ window: NSWindow) { self.window = window }
    }
    private final class CloseObservation: @unchecked Sendable {
        let observer: any NSObjectProtocol
        init(_ observer: any NSObjectProtocol) { self.observer = observer }
        deinit { NotificationCenter.default.removeObserver(observer) }
    }
}

@MainActor
struct MainWindowCommands<NewItemContent: View>: Commands {
    @Environment(\.openWindow) private var openWindow
    let coordinator: MainWindowCoordinator
    private let newWindowShortcut: KeyboardShortcut?
    private let allowsInvocation: @MainActor () -> Bool
    private let newItems: NewItemContent

    init(coordinator: MainWindowCoordinator, newWindowShortcut: KeyboardShortcut? = KeyboardShortcut("n", modifiers: [.command, .option]),
         allowsInvocation: @escaping @MainActor () -> Bool = { true },
         @ViewBuilder newItems: () -> NewItemContent) {
        self.coordinator = coordinator
        self.newWindowShortcut = newWindowShortcut
        self.allowsInvocation = allowsInvocation
        self.newItems = newItems()
    }

    var body: some Commands {
        let action = openWindow
        let _ = coordinator.installOpenAction { action(id: MainWindowCoordinator.sceneID) }
        // One owner for this placement: a separate replacing group removes
        // commands inserted after the replaced .newItem anchor on macOS.
        CommandGroup(replacing: .newItem) {
            newItems
            Button("New Window") { if allowsInvocation() { coordinator.newWindow() } }
                .keyboardShortcut(newWindowShortcut)
                .accessibilityIdentifier("main-window-new")
        }
    }
}

/// Only observes the NSWindow that SwiftUI created for the primary scene.
/// Settings and panels never become main-window candidates.
@MainActor
struct MainWindowRegistration: NSViewRepresentable {
    let coordinator: MainWindowCoordinator
    func makeNSView(context: Context) -> RegistrationView { RegistrationView(coordinator: coordinator) }
    func updateNSView(_ view: RegistrationView, context: Context) {
        view.coordinator = coordinator
        if let window = view.window { coordinator.register(window) }
    }
    final class RegistrationView: NSView {
        weak var coordinator: MainWindowCoordinator?
        init(coordinator: MainWindowCoordinator) { self.coordinator = coordinator; super.init(frame: .zero) }
        required init?(coder: NSCoder) { nil }
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if let window { coordinator?.register(window) }
        }
    }
}
