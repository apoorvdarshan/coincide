import Foundation
import CoincideKit

/// App-wide requests that cross view controllers. Post with `AppEvents`, observe with NotificationCenter.
/// Each request has one handler: the main window controller, except where noted.
extension Notification.Name {
    /// userInfo["threadID"]: UUID
    static let coincideOpenThread = Notification.Name("coincide.openThread")
    /// userInfo["projectID"]: UUID? (current project when missing)
    static let coincideNewThread = Notification.Name("coincide.newThread")
    static let coincideAddProject = Notification.Name("coincide.addProject")
    /// Opens the diff inspector on one turn's changes.
    /// userInfo["threadID"]: UUID, ["turnID"]: UUID (the turn's user item id), ["path"]: String? (file to select)
    static let coincideShowTurnDiff = Notification.Name("coincide.showTurnDiff")
    static let coincideToggleTerminal = Notification.Name("coincide.toggleTerminal")
    /// Handled by the composer.
    static let coincideFocusComposer = Notification.Name("coincide.focusComposer")
    /// Attaches context to the composer's message, from the terminal or the diff. Handled by the composer.
    /// userInfo["threadID"]: UUID, ["context"]: MessageContext
    static let coincideAddComposerContext = Notification.Name("coincide.addComposerContext")
    /// Attaches images already saved in the attachments folder (an appshot) to the composer's message. Handled by the
    /// composer. userInfo["threadID"]: UUID, ["images"]: [ComposerAttachment]
    static let coincideAddComposerImages = Notification.Name("coincide.addComposerImages")
    /// Writes `#123` into the composer, as picking the pull request from the `#` list does. Handled by the composer.
    /// userInfo["pullRequest"]: PullRequestSummary
    static let coincideMentionPullRequest = Notification.Name("coincide.mentionPullRequest")
    /// Handled by the settings window controller.
    /// userInfo["section"]: String (SettingsSection raw value), optional;
    /// userInfo["provider"]: String (ProviderKind raw value), optional
    static let coincideShowSettings = Notification.Name("coincide.showSettings")
    /// The sidebar's sorting or threads per project changed elsewhere (Coincide Remote). Handled by the sidebar.
    static let coincideSidebarLayoutChanged = Notification.Name("coincide.sidebarLayoutChanged")
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

    static func showTurnDiff(threadID: UUID, turnID: UUID, path: String?) {
        var info: [String: Any] = ["threadID": threadID, "turnID": turnID]
        if let path { info["path"] = path }
        NotificationCenter.default.post(name: .coincideShowTurnDiff, object: nil, userInfo: info)
    }

    static func mentionPullRequest(_ pullRequest: PullRequestSummary) {
        NotificationCenter.default.post(name: .coincideMentionPullRequest, object: nil, userInfo: ["pullRequest": pullRequest])
    }

    static func showSettings(section: SettingsSection? = nil, provider: ProviderKind? = nil) {
        var info: [String: Any] = [:]
        if let section { info["section"] = section.rawValue }
        if let provider { info["provider"] = provider.rawValue }
        NotificationCenter.default.post(name: .coincideShowSettings, object: nil, userInfo: info)
    }

    /// Adds `context` to the message being written in `threadID`.
    static func addToComposer(_ context: MessageContext, threadID: UUID) {
        NotificationCenter.default.post(
            name: .coincideAddComposerContext, object: nil, userInfo: ["threadID": threadID, "context": context])
    }

    /// Adds `images`, already in the attachments folder, to the message being written in `threadID`.
    static func addToComposer(images: [ComposerAttachment], threadID: UUID) {
        NotificationCenter.default.post(
            name: .coincideAddComposerImages, object: nil, userInfo: ["threadID": threadID, "images": images])
    }

    static func post(_ name: Notification.Name, _ info: [String: Any] = [:]) {
        NotificationCenter.default.post(name: name, object: nil, userInfo: info)
    }
}
