import AppKit
import CoincideKit

/// Applies the light, dark or system appearance from settings to the whole app.
final class AppearanceController {
    static let shared = AppearanceController()

    private var token: ObservationToken?
    private var applied: AppearanceMode?

    /// Applies the saved appearance and keeps it in sync with settings. Called once at launch.
    func start() {
        guard token == nil else { return }
        apply(AppStore.shared.settings.appearance)
        token = AppStore.shared.observe { [weak self] change in
            guard change == .settings else { return }
            self?.apply(AppStore.shared.settings.appearance)
        }
    }

    private func apply(_ mode: AppearanceMode) {
        guard mode != applied else { return }
        applied = mode
        NSApp.appearance = mode.appearance
    }
}

extension AppearanceMode {
    /// The appearance to force, or nil to follow the system.
    var appearance: NSAppearance? {
        switch self {
        case .system: nil
        case .light: NSAppearance(named: .aqua)
        case .dark: NSAppearance(named: .darkAqua)
        }
    }
}
