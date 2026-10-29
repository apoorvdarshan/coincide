import Foundation

/// Reads Firefox-family profiles (Firefox, LibreWolf, Zen, Floorp, Waterfox): `profiles.ini` lists them, and each
/// keeps unencrypted cookies in `cookies.sqlite` and history and bookmarks in `places.sqlite`.
public nonisolated enum FirefoxProfileReader {
    public struct Profile: Hashable, Sendable {
        public var name: String
        public var folder: URL
        public var isDefault: Bool
    }

    /// The profiles `profiles.ini` in `root` lists, default first.
    public static func profiles(in root: URL) -> [Profile] {
        guard let text = try? String(contentsOf: root.appendingPathComponent("profiles.ini"), encoding: .utf8) else { return [] }
        return parseProfiles(text, root: root)
    }

    static func parseProfiles(_ text: String, root: URL) -> [Profile] {
        var sections: [(name: String, fields: [String: String])] = []
        for raw in text.components(separatedBy: .newlines) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("["), line.hasSuffix("]") {
                sections.append((String(line.dropFirst().dropLast()), [:]))
            } else if let equals = line.firstIndex(of: "="), !sections.isEmpty, !line.hasPrefix(";"), !line.hasPrefix("#") {
                sections[sections.count - 1].fields[String(line[..<equals])] = String(line[line.index(after: equals)...])
            }
        }
        // Newer versions mark each installation's default in an [Install…] section.
        let installDefaults = Set(sections.filter { $0.name.hasPrefix("Install") }.compactMap { $0.fields["Default"] })
        var result: [Profile] = []
        for section in sections where section.name.hasPrefix("Profile") {
            guard let path = section.fields["Path"], !path.isEmpty, !path.contains("\0") else { continue }
            let folder = section.fields["IsRelative"] == "0"
                ? URL(fileURLWithPath: path, isDirectory: true)
                : root.appendingPathComponent(path, isDirectory: true)
            // A relative path must stay inside the browser's folder.
            if section.fields["IsRelative"] != "0" {
                guard folder.standardizedFileURL.path.hasPrefix(root.standardizedFileURL.path + "/") else { continue }
            }
            let isDefault = installDefaults.contains(path) || (installDefaults.isEmpty && section.fields["Default"] == "1")
            result.append(Profile(name: section.fields["Name"] ?? path, folder: folder, isDefault: isDefault))
        }
        return result.sorted { $0.isDefault && !$1.isDefault }
    }

    static func cookies(in profile: URL) throws -> [ImportedCookie] {
        let file = profile.appendingPathComponent("cookies.sqlite")
        guard FileManager.default.fileExists(atPath: file.path) else { return [] }
        let snapshot = try SQLiteSnapshot(copying: file)
        defer { snapshot.close() }
        let sameSite = snapshot.columns(of: "moz_cookies").contains("sameSite") ? "sameSite" : "-1"
        return try snapshot.rows("SELECT host, name, value, path, expiry, isSecure, isHttpOnly, \(sameSite) AS sameSite FROM moz_cookies")
            .compactMap { row in
                guard let host = row["host"]?.string, !host.isEmpty, let name = row["name"]?.string else { return nil }
                let policy: ImportedCookie.SameSite? =
                    switch row["sameSite"]?.int {
                    case 0: ImportedCookie.SameSite.unrestricted
                    case 1: .lax
                    case 2: .strict
                    default: nil
                    }
                return ImportedCookie(
                    domain: host, name: name, value: row["value"]?.string ?? "", path: row["path"]?.string ?? "/",
                    expires: BrowserTime.firefoxExpiry(row["expiry"]?.int ?? 0), isSecure: row["isSecure"]?.int == 1,
                    isHTTPOnly: row["isHttpOnly"]?.int == 1, sameSite: policy)
            }
    }

    static func history(in profile: URL, limit: Int) throws -> [BrowserHistoryItem] {
        let file = profile.appendingPathComponent("places.sqlite")
        guard FileManager.default.fileExists(atPath: file.path) else { return [] }
        let snapshot = try SQLiteSnapshot(copying: file)
        defer { snapshot.close() }
        return try snapshot.rows(
            "SELECT url, title, visit_count, last_visit_date FROM moz_places WHERE visit_count > 0 AND hidden = 0 ORDER BY last_visit_date DESC",
            limit: limit
        ).compactMap { row in
            guard let url = row["url"]?.string, url.hasPrefix("http") else { return nil }
            return BrowserHistoryItem(url: url, title: row["title"]?.string ?? "", visitCount: Int(row["visit_count"]?.int ?? 1),
                lastVisit: BrowserTime.firefoxVisit(row["last_visit_date"]?.int ?? 0) ?? .distantPast)
        }
    }

    static func bookmarks(in profile: URL, browser: String) throws -> [BrowserBookmark] {
        let file = profile.appendingPathComponent("places.sqlite")
        guard FileManager.default.fileExists(atPath: file.path) else { return [] }
        let snapshot = try SQLiteSnapshot(copying: file)
        defer { snapshot.close() }
        let folders = Dictionary(
            try snapshot.rows("SELECT id, parent, title FROM moz_bookmarks WHERE type = 2").compactMap { row -> (Int64, (Int64, String))? in
                guard let id = row["id"]?.int else { return nil }
                return (id, (row["parent"]?.int ?? 0, row["title"]?.string ?? ""))
            }, uniquingKeysWith: { first, _ in first })
        func path(_ parent: Int64) -> String {
            var names: [String] = []
            var current = parent
            var guardCount = 0
            while let folder = folders[current], guardCount < 32 {
                if !folder.1.isEmpty { names.insert(folder.1, at: 0) }
                current = folder.0
                guardCount += 1
            }
            return ([browser] + names).joined(separator: " › ")
        }
        return try snapshot.rows(
            "SELECT p.url AS url, b.title AS title, b.parent AS parent FROM moz_bookmarks b JOIN moz_places p ON b.fk = p.id WHERE b.type = 1"
        ).compactMap { row in
            guard let url = row["url"]?.string, url.hasPrefix("http") else { return nil }
            return BrowserBookmark(url: url, title: row["title"]?.string ?? url, folder: path(row["parent"]?.int ?? 0))
        }
    }
}
