import AppKit
import CoincideKit
import CoincideRemoteKit
import SwiftUI

/// Help & Community on the Mac: Settings › About, the Help menu and the command palette list `CommunityLink.allCases`
/// with these titles and symbols, so a link added there shows up in all three.
extension CommunityLink {
    /// The link's name in Settings and the palette.
    var title: String {
        switch self {
        case .reportIssue: String(localized: "Report an Issue")
        case .requestFeature: String(localized: "Request a Feature")
        }
    }

    /// What the link opens, under its name in Settings.
    var detail: String {
        switch self {
        case .reportIssue: String(localized: "Opens the bug report form on GitHub")
        case .requestFeature: String(localized: "Opens the feature request form on GitHub")
        }
    }

    /// The Help menu command, whose shortcut the user can set in Settings › Keyboard. Its title is the menu item's.
    var command: KeyCommand {
        switch self {
        case .reportIssue: .reportIssue
        case .requestFeature: .requestFeature
        }
    }

    var symbol: String {
        switch self {
        case .reportIssue: "ladybug.fill"
        case .requestFeature: "lightbulb.fill"
        }
    }

    var tint: Color {
        switch self {
        case .reportIssue: .red
        case .requestFeature: .orange
        }
    }

    /// Words the palette also finds the link by.
    var keywords: [String] {
        switch self {
        case .reportIssue: ["bug", "issue", "report", "problem", "crash", "broken", "feedback", "github", "help", "support"]
        case .requestFeature: ["feature", "request", "idea", "suggestion", "enhancement", "feedback", "github", "help"]
        }
    }

    /// The form with this Mac's versions of Coincide and macOS filled in.
    var macURL: URL {
        let info = Bundle.main.infoDictionary ?? [:]
        let coincide = Self.appVersion(info["CFBundleShortVersionString"] as? String, build: info["CFBundleVersion"] as? String)
        let macOS = "macOS " + Self.systemVersion(ProcessInfo.processInfo.operatingSystemVersion, build: Self.systemBuild)
        return url(coincideVersion: coincide, macOSVersion: macOS)
    }

    /// Opens the form in the default browser, where the user is signed in to GitHub.
    func open() {
        NSWorkspace.shared.open(macURL)
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
