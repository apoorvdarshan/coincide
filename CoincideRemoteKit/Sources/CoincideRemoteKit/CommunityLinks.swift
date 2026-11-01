import Foundation

/// The Help & Community links both apps offer, in Settings and (on the Mac) the Help menu and the command palette:
/// the repository's GitHub issue forms (`.github/ISSUE_TEMPLATE`). Each app supplies its own titles and symbols.
///
/// A bug report fills in only the form's version fields, with the versions of the apps and systems involved. It never
/// carries logs, paths, account names or anything else from the device.
public enum CommunityLink: String, CaseIterable, Sendable, Identifiable {
    /// The bug report form (`bug_report.yml`).
    case reportIssue
    /// The feature request form (`feature_request.yml`).
    case requestFeature

    public var id: String { rawValue }

    public static let repository = URL(string: "https://github.com/apoorvdarshan/coincide")!

    /// The issue form's file in `.github/ISSUE_TEMPLATE`.
    public var template: String {
        switch self {
        case .reportIssue: "bug_report.yml"
        case .requestFeature: "feature_request.yml"
        }
    }

    /// Ids of the bug report form's fields that a link fills in.
    public enum Field {
        public static let macOSVersion = "macos-version"
        public static let coincideVersion = "coincide-version"
    }

    /// Longest value a link puts in a field; the forms' version fields are one line.
    public static let maxFieldLength = 120

    /// The form's page on GitHub. A bug report fills in its "Coincide version" and "macOS version" fields with what is
    /// given; empty values are left out, and a feature request takes none.
    public func url(coincideVersion: String? = nil, macOSVersion: String? = nil) -> URL {
        var components = URLComponents(url: Self.repository.appendingPathComponent("issues/new"), resolvingAgainstBaseURL: false)!
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
