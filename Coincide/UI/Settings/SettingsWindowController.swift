import AppKit
import CoincideKit
import SwiftUI

/// Top-level panes of the settings window, in sidebar order.
nonisolated enum SettingsSection: String, CaseIterable, Sendable {
    case general
    case providers
    case models
    case keyboard
    case about

    var title: String {
        switch self {
        case .general: String(localized: "General")
        case .providers: String(localized: "Providers")
        case .models: String(localized: "Models")
        case .keyboard: String(localized: "Keyboard")
        case .about: String(localized: "About")
        }
    }

    var symbolName: String {
        switch self {
        case .general: "gearshape.fill"
        case .providers: "terminal.fill"
        case .models: "cube.fill"
        case .keyboard: "keyboard.fill"
        case .about: "info"
        }
    }
}

/// The settings window: a SwiftUI sidebar of panes with one page per provider.
final class SettingsWindowController: NSWindowController, NSWindowDelegate {
    static let shared = SettingsWindowController(window: nil)

    private let model = SettingsModel()
    private var requestObserver: NSObjectProtocol?

    /// Opens the settings window, optionally on a section.
    func show(section: SettingsSection? = nil) {
        if let section { model.navigate(to: .section(section)) }
        present()
    }

    /// Opens the settings window on one provider's page.
    func show(provider: ProviderKind) {
        model.navigate(to: .provider(provider))
        present()
    }

    /// Handles `.coincideShowSettings` requests: `userInfo["section"]` is a `SettingsSection` raw value,
    /// `userInfo["provider"]` an optional `ProviderKind` raw value.
    func startHandlingRequests() {
        guard requestObserver == nil else { return }
        requestObserver = NotificationCenter.default.addObserver(
            forName: .coincideShowSettings, object: nil, queue: .main
        ) { [weak self] notification in
            let section = (notification.userInfo?["section"] as? String).flatMap(SettingsSection.init(rawValue:))
            let provider = (notification.userInfo?["provider"] as? String).flatMap(ProviderKind.init(rawValue:))
            MainActor.assumeIsolated {
                if let provider {
                    self?.show(provider: provider)
                } else {
                    self?.show(section: section)
                }
            }
        }
    }

    /// Shows the window without activating the app: it opens from the app's own menus and buttons, so the
    /// app is already active.
    private func present() {
        if window == nil { window = makeWindow() }
        model.resync()
        showWindow(nil)
    }

    private func makeWindow() -> NSWindow {
        let hosting = NSHostingController(rootView: SettingsRootView(model: model))
        // The window owns its size; SwiftUI content adapts to it.
        hosting.sizingOptions = []
        hosting.sceneBridgingOptions = [.toolbars]
        let window = NSWindow(contentViewController: hosting)
        window.styleMask = [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView]
        window.toolbarStyle = .unified
        window.tabbingMode = .disallowed
        window.collectionBehavior.insert(.fullScreenNone)
        window.isReleasedWhenClosed = false
        window.identifier = NSUserInterfaceItemIdentifier("settings")
        window.contentMinSize = NSSize(width: 760, height: 500)
        window.setContentSize(NSSize(width: 860, height: 640))
        window.delegate = self
        window.title = model.pane.title
        model.onPaneChange = { [weak window] pane in window?.title = pane.title }
        if !window.setFrameUsingName("CoincideSettings") { window.center() }
        window.setFrameAutosaveName("CoincideSettings")
        return window
    }

    func windowWillClose(_ notification: Notification) {
        model.searchText = ""
    }
}
