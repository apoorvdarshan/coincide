import AppKit
import CoincideKit

enum SettingsSection: String, CaseIterable {
    case general
    case providers
    case models
    case keyboard
    case about
}

// STUB: replaced by the real SwiftUI settings window.
final class SettingsWindowController: NSWindowController {
    static let shared = SettingsWindowController(window: nil)

    func show(section: SettingsSection? = nil) {}
}
