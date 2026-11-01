import Foundation

/// Coincide's public pages and accounts, for both apps. Plain links: nothing here is fetched.
public enum CoincideLinks {
    public static let repository = URL(string: "https://github.com/apoorvdarshan/coincide")!
    /// The Discord server's permanent invite.
    public static let discordInvite = URL(string: "https://discord.gg/DETrbhDVqw")!
    /// Channels of the Discord server, which open once the user has joined it.
    public static let discordHelp = URL(string: "https://discord.com/channels/1566352780862427258/1566353949336797275")!
    public static let discordBugReports = URL(string: "https://discord.com/channels/1566352780862427258/1566353951299862598")!
    public static let discordFeatureRequests = URL(
        string: "https://discord.com/channels/1566352780862427258/1566353955494039602")!
    public static let x = URL(string: "https://x.com/apoorvdarshan")!
    public static let xHandle = "@apoorvdarshan"
    public static let instagram = URL(string: "https://instagram.com/apoorvcodes")!
    public static let instagramHandle = "@apoorvcodes"
    /// Coincide's showcase page on LinkedIn.
    public static let linkedIn = URL(string: "https://www.linkedin.com/showcase/coincide-dev")!
    public static let privacyPolicy = URL(string: "https://coincide.dev/privacy")!
    public static let termsOfService = URL(string: "https://coincide.dev/terms")!
    public static let contactEmail = "apoorv@fud-ai.app"
    public static let contact = URL(string: "mailto:\(contactEmail)")!
    /// Coincide Remote's "Write a Review" page on the App Store, opened when the in-app review prompt was asked for
    /// recently (`RemoteReview`). Nil until the app is on the App Store, so Rate always asks for the prompt.
    public static let remoteAppStoreReview: URL? = nil
}

/// Help & Community, as both apps list it in Settings and the Mac also in its Help menu and command palette: help and
/// reports, the Discord server and the source code, the developer's accounts, and contact and legal pages. Each app
/// supplies the titles and symbols; every place lists `allCases`, so a link added here shows up in all of them.
///
/// Report an Issue and Request a Feature offer a choice: the repository's GitHub issue form, or the Discord channel
/// whose slash command files the same public issue for people without a GitHub account. A bug report's form fills in
/// only its version fields, with the versions of the apps and systems involved, never logs, paths or account names.
public enum CommunityLink: String, CaseIterable, Sendable, Identifiable {
    case getHelp
    /// The bug report form (`bug_report.yml`), or `/bug` on Discord.
    case reportIssue
    /// The feature request form (`feature_request.yml`), or `/feature` on Discord.
    case requestFeature
    case joinDiscord
    case starOnGitHub
    case x
    case instagram
    case linkedIn
    case contact
    case privacyPolicy
    case termsOfService

    /// How the links are grouped, in order: under Help & Community, Follow, and Contact & Legal.
    public enum Group: String, CaseIterable, Sendable {
        case community
        case follow
        case contact
    }

    public var id: String { rawValue }

    public var group: Group {
        switch self {
        case .getHelp, .reportIssue, .requestFeature, .joinDiscord, .starOnGitHub: .community
        case .x, .instagram, .linkedIn: .follow
        case .contact, .privacyPolicy, .termsOfService: .contact
        }
    }

    /// The links of `group`, in order.
    public static func links(in group: Group) -> [CommunityLink] { allCases.filter { $0.group == group } }

    /// The issue form's file in `.github/ISSUE_TEMPLATE`, for the two that open one.
    public var template: String? {
        switch self {
        case .reportIssue: "bug_report.yml"
        case .requestFeature: "feature_request.yml"
        default: nil
        }
    }

    /// The Discord channel offered beside the GitHub form, for the two that offer one.
    public var discordChannel: URL? {
        switch self {
        case .reportIssue: CoincideLinks.discordBugReports
        case .requestFeature: CoincideLinks.discordFeatureRequests
        default: nil
        }
    }

    /// The slash command that files the report in `discordChannel`.
    public var slashCommand: String? {
        switch self {
        case .reportIssue: "/bug"
        case .requestFeature: "/feature"
        default: nil
        }
    }

    /// Ids of the bug report form's fields that a link fills in.
    public enum Field {
        public static let macOSVersion = "macos-version"
        public static let coincideVersion = "coincide-version"
    }

    /// Longest value a link puts in a field; the forms' version fields are one line.
    public static let maxFieldLength = 120

    /// Where the link goes; for a report, its GitHub form. A bug report fills in its "Coincide version" and "macOS
    /// version" fields with what is given; empty values are left out, and nothing else takes any.
    public func url(coincideVersion: String? = nil, macOSVersion: String? = nil) -> URL {
        switch self {
        case .getHelp: return CoincideLinks.discordHelp
        case .joinDiscord: return CoincideLinks.discordInvite
        case .starOnGitHub: return CoincideLinks.repository
        case .x: return CoincideLinks.x
        case .instagram: return CoincideLinks.instagram
        case .linkedIn: return CoincideLinks.linkedIn
        case .contact: return CoincideLinks.contact
        case .privacyPolicy: return CoincideLinks.privacyPolicy
        case .termsOfService: return CoincideLinks.termsOfService
        case .reportIssue, .requestFeature: break
        }
        var components = URLComponents(
            url: CoincideLinks.repository.appendingPathComponent("issues/new"), resolvingAgainstBaseURL: false)!
        var items = [URLQueryItem(name: "template", value: template)]
        if self == .reportIssue {
            for (field, value) in [(Field.coincideVersion, coincideVersion), (Field.macOSVersion, macOSVersion)] {
                guard let value = Self.fieldValue(value) else { continue }
                items.append(URLQueryItem(name: field, value: value))
            }
        }
        components.queryItems = items
        // URLComponents leaves "+" alone in queries, where GitHub reads it as a space.
        components.percentEncodedQuery = components.percentEncodedQuery?.replacingOccurrences(of: "+", with: "%2B")
        return components.url!
    }

    /// A field's value on one line, trimmed and cut to `maxFieldLength`; nil when nothing is left.
    static func fieldValue(_ value: String?) -> String? {
        guard let value else { return nil }
        let line = value.components(separatedBy: .newlines).joined(separator: " ").trimmingCharacters(in: .whitespaces)
        guard !line.isEmpty else { return nil }
        return String(line.prefix(maxFieldLength))
    }

    // MARK: Versions

    /// An app's version as the form's placeholder writes it: "0.1.0 (1)", or just "0.1.0" without a build number.
    public static func appVersion(_ version: String?, build: String?) -> String? {
        let version = fieldValue(version)
        let build = fieldValue(build)
        switch (version, build) {
        case let (version?, build?): return "\(version) (\(build))"
        case let (version?, nil): return version
        default: return nil
        }
    }

    /// A system's version as Apple writes it, "26.1" or "26.1.2", followed by its build when known: "26.1 (25B78)".
    public static func systemVersion(_ version: OperatingSystemVersion, build: String? = nil) -> String {
        var number = "\(version.majorVersion).\(version.minorVersion)"
        if version.patchVersion != 0 { number += ".\(version.patchVersion)" }
        guard let build = fieldValue(build) else { return number }
        return "\(number) (\(build))"
    }

    /// The bug report's "Coincide version" from Coincide Remote: the Mac's Coincide when the phone knows it, then the
    /// phone's own app and system, "0.1.0 (12) · Coincide Remote 1.0 (3) on iOS 26.1".
    public static func remoteCoincideVersion(mac: String?, remote: String, system: String, systemName: String = "iOS") -> String {
        let phone = "Coincide Remote \(remote) on \(systemName) \(system)"
        guard let mac = fieldValue(mac) else { return phone }
        return "\(mac) · \(phone)"
    }
}

/// Rate Coincide Remote: iOS's own review prompt, which it shows only a few times a year, so a second tap soon after
/// opens the App Store's review page instead, once the app has one (`CoincideLinks.remoteAppStoreReview`). Only when
/// the user taps Rate; the app never asks on its own.
public enum RemoteReview {
    /// How long after asking for the prompt a tap opens the App Store page instead.
    public static let promptInterval: TimeInterval = 122 * 24 * 60 * 60

    /// The App Store page to open, or nil to ask for the prompt.
    public static func storePage(lastPrompt: Date?, now: Date = Date(), page: URL? = CoincideLinks.remoteAppStoreReview) -> URL? {
        guard let page, let lastPrompt, now.timeIntervalSince(lastPrompt) < promptInterval else { return nil }
        return page
    }
}
