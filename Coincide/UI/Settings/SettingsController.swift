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

/// Settings, shown as a page in the main window rather than a window of their own: the rail's gear, ⌘, the command
/// palette and every link to settings open it there, on the page they name.
final class SettingsController {
    static let shared = SettingsController()

    let model = SettingsModel()
    private var requestObserver: NSObjectProtocol?

    private var mainWindow: MainWindowController? {
        NSApp.windows.lazy.compactMap { $0.windowController as? MainWindowController }.first
    }

    /// Opens settings, optionally on a section.
    func show(section: SettingsSection? = nil) {
        if let section { model.navigate(to: .section(section)) }
        present()
    }

    /// Opens settings on one provider's page.
    func show(provider: ProviderKind) {
        model.navigate(to: .provider(provider))
        present()
    }

    /// Opens settings, or goes back to the conversation when they are open (⌘, and the rail's gear).
    func toggle() {
        guard let mainWindow else { return }
        if mainWindow.isShowingSettings {
            mainWindow.hideSettingsPage()
        } else {
            present()
        }
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

    private func present() {
        model.resync()
        mainWindow?.showSettingsPage(model: model)
    }
}
