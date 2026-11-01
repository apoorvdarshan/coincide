import AppKit
import CoincideKit
import CoincideRemoteKit
import SwiftUI

/// Help & Community on the Mac: Settings › About, the Help menu and the command palette list `CommunityLink.allCases`
/// with these titles and symbols, so a link added there shows up in all three.
extension CommunityLink {
    /// The link's name in Settings.
    var title: String {
        switch self {
        case .getHelp: String(localized: "Get Help")
        case .reportIssue: String(localized: "Report an Issue")
        case .requestFeature: String(localized: "Request a Feature")
        case .joinDiscord: String(localized: "Join the Discord")
        case .starOnGitHub: String(localized: "Star on GitHub")
        case .x: "X"
        case .instagram: "Instagram"
        case .linkedIn: "LinkedIn"
        case .contact: String(localized: "Contact")
        case .privacyPolicy: String(localized: "Privacy Policy")
        case .termsOfService: String(localized: "Terms of Service")
        }
    }

    /// The line under its name in Settings.
    var detail: String {
        switch self {
        case .getHelp: String(localized: "Ask in the help channel on Discord")
        case .reportIssue, .requestFeature: String(localized: "On GitHub or Discord")
        case .joinDiscord: "discord.gg/DETrbhDVqw"
        case .starOnGitHub: String(localized: "Coincide is open source under the MIT License")
        case .x: CoincideLinks.xHandle
        case .instagram: CoincideLinks.instagramHandle
        case .linkedIn: "linkedin.com/showcase/coincide-dev"
        case .contact: CoincideLinks.contactEmail
        case .privacyPolicy: "coincide.dev/privacy"
        case .termsOfService: "coincide.dev/terms"
        }
    }

    /// The Help menu item and palette command, naming the account or address where Settings shows it underneath. The
    /// two that ask GitHub or Discord end in an ellipsis.
    var menuTitle: String {
        switch self {
        case .getHelp: String(localized: "Get Help on Discord")
        case .reportIssue, .requestFeature: command?.title ?? title
        case .x: "X: \(CoincideLinks.xHandle)"
        case .instagram: "Instagram: \(CoincideLinks.instagramHandle)"
        case .contact: String(localized: "Contact: \(CoincideLinks.contactEmail)")
        default: title
        }
    }

    /// The menu command whose shortcut the user can set in Settings › Keyboard, for the two that have one.
    var command: KeyCommand? {
        switch self {
        case .reportIssue: .reportIssue
        case .requestFeature: .requestFeature
        default: nil
        }
    }

    var symbol: String {
        switch self {
        case .getHelp: "questionmark.bubble.fill"
        case .reportIssue: "ladybug.fill"
        case .requestFeature: "lightbulb.fill"
        case .joinDiscord: "bubble.left.and.bubble.right.fill"
        case .starOnGitHub: "star.fill"
        case .x: "at"
        case .instagram: "camera.fill"
        case .linkedIn: "person.2.fill"
        case .contact: "envelope.fill"
        case .privacyPolicy: "hand.raised.fill"
        case .termsOfService: "doc.text.fill"
        }
    }

    var tint: Color {
        switch self {
        case .getHelp: .teal
        case .reportIssue: .red
        case .requestFeature: .orange
        case .joinDiscord: .indigo
        case .starOnGitHub: .gray
        case .x: .black
        case .instagram: .pink
        case .linkedIn: .blue
        case .contact: .cyan
        case .privacyPolicy: .blue
        case .termsOfService: .gray
        }
    }

    /// Words the palette and Settings search also find the link by.
    var keywords: [String] {
        let words: [String]
        switch self {
        case .getHelp: words = ["help", "support", "question", "discord", "community", "ask"]
        case .reportIssue:
            words = [String(localized: "Bug"), String(localized: "Feedback"), "bug", "issue", "report", "problem", "crash",
                     "broken", "feedback", "github", "discord", "help", "support"]
        case .requestFeature:
            words = [String(localized: "Idea"), String(localized: "Feedback"), "feature", "request", "idea", "suggestion",
                     "enhancement", "feedback", "github", "discord", "help"]
        case .joinDiscord: words = ["discord", "community", "chat", "server", "join", "invite"]
        case .starOnGitHub: words = ["github", "star", "source", "code", "open source", "license", "mit", "repository"]
        case .x: words = ["x", "twitter", "follow", "social", CoincideLinks.xHandle]
        case .instagram: words = ["instagram", "follow", "social", CoincideLinks.instagramHandle]
        case .linkedIn: words = ["linkedin", "follow", "social", "company"]
        case .contact: words = ["contact", "email", "mail", "support", CoincideLinks.contactEmail]
        case .privacyPolicy: words = ["privacy", "policy", "data", "legal"]
        case .termsOfService: words = ["terms", "service", "legal", "conditions"]
        }
        return words + [String(localized: "Help")]
    }

    /// The heading the links of `group` are under in Settings.
    static func title(of group: Group) -> String {
        switch group {
        case .community: String(localized: "Help & Community")
        case .follow: String(localized: "Follow")
        case .contact: String(localized: "Contact & Legal")
        }
    }

    /// Where the link goes from this Mac: a bug report's form has this Mac's versions of Coincide and macOS filled in.
    var macURL: URL {
        let info = Bundle.main.infoDictionary ?? [:]
        let coincide = Self.appVersion(info["CFBundleShortVersionString"] as? String, build: info["CFBundleVersion"] as? String)
        let macOS = "macOS " + Self.systemVersion(ProcessInfo.processInfo.operatingSystemVersion, build: Self.systemBuild)
        return url(coincideVersion: coincide, macOSVersion: macOS)
    }

    /// Opens the link in the default browser (the mail app for Contact). Report an Issue and Request a Feature first
    /// ask whether to use GitHub or Discord.
    func open() {
        guard let discord = discordChannel else {
            NSWorkspace.shared.open(macURL)
            return
        }
        let alert = ThemedAlert()
        alert.alertStyle = .informational
        alert.messageText = title
        alert.informativeText = choiceMessage
        alert.addButton(withTitle: String(localized: "GitHub"))
        alert.addButton(withTitle: String(localized: "Discord"))
        alert.addButton(withTitle: String(localized: "Cancel"))
        switch alert.runModal() {
        case .alertFirstButtonReturn: NSWorkspace.shared.open(macURL)
        case .alertSecondButtonReturn: NSWorkspace.shared.open(discord)
        default: break
        }
    }

    /// What the GitHub or Discord question explains.
    var choiceMessage: String {
        switch self {
        case .reportIssue:
            String(localized: "Fill in the bug report form on GitHub, or use /bug in the bug reports channel on Discord. Channel links work once you’ve joined the server. Reports sent on Discord become public GitHub issues and need no GitHub account.")
        case .requestFeature:
            String(localized: "Fill in the feature request form on GitHub, or use /feature in the feature requests channel on Discord. Channel links work once you’ve joined the server. Requests sent on Discord become public GitHub issues and need no GitHub account.")
        default: ""
        }
    }

    /// The build of macOS running, such as "25B78".
    private static var systemBuild: String? {
        var size = 0
        guard sysctlbyname("kern.osversion", nil, &size, nil, 0) == 0, size > 0 else { return nil }
        var buffer = [CChar](repeating: 0, count: size)
        guard sysctlbyname("kern.osversion", &buffer, &size, nil, 0) == 0 else { return nil }
        return String(decoding: buffer.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
    }
}
