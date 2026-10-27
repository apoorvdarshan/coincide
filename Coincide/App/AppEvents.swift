import Foundation
import CoincideKit

/// App-wide requests that cross view controllers. Post with `AppEvents`, observe with NotificationCenter.
extension Notification.Name {
    /// userInfo["threadID"]: UUID
    static let coincideOpenThread = Notification.Name("coincide.openThread")
    /// userInfo["projectID"]: UUID? (current project when missing)
    static let coincideNewThread = Notification.Name("coincide.newThread")
    static let coincideAddProject = Notification.Name("coincide.addProject")
    static let coincideToggleDiff = Notification.Name("coincide.toggleDiff")
    static let coincideToggleTerminal = Notification.Name("coincide.toggleTerminal")
    static let coincideToggleSidebar = Notification.Name("coincide.toggleSidebar")
    static let coincideFocusComposer = Notification.Name("coincide.focusComposer")
    static let coincideShowCommandPalette = Notification.Name("coincide.showCommandPalette")
    /// userInfo["section"]: String (SettingsSection raw value), optional;
    /// userInfo["provider"]: String (ProviderKind raw value), optional
    static let coincideShowSettings = Notification.Name("coincide.showSettings")
}

enum AppEvents {
    static func openThread(_ id: UUID) {
        NotificationCenter.default.post(name: .coincideOpenThread, object: nil, userInfo: ["threadID": id])
    }

    static func newThread(in projectID: UUID? = nil) {
        var info: [String: Any] = [:]
        if let projectID { info["projectID"] = projectID }
        NotificationCenter.default.post(name: .coincideNewThread, object: nil, userInfo: info)
    }

    static func showSettings(section: SettingsSection? = nil, provider: ProviderKind? = nil) {
        var info: [String: Any] = [:]
        if let section { info["section"] = section.rawValue }
        if let provider { info["provider"] = provider.rawValue }
        NotificationCenter.default.post(name: .coincideShowSettings, object: nil, userInfo: info)
    }

    static func post(_ name: Notification.Name, _ info: [String: Any] = [:]) {
        NotificationCenter.default.post(name: name, object: nil, userInfo: info)
    }
}
