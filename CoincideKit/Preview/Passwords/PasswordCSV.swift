import Foundation

/// Password exports in CSV: Chrome and other Chromium browsers (`name,url,username,password,note`), Safari and Apple
/// Passwords (`Title,URL,Username,Password,Notes,OTPAuth`), Firefox (`url,username,password,httpRealm,…`), 1Password
/// (`Title,Url,Username,Password,OTPAuth,…`) and Bitwarden (`…,name,…,login_uri,login_username,login_password,login_totp`).
/// Columns are found by name, so other exports with similar headers work too.
public nonisolated enum PasswordCSV {
    public struct Login: Sendable, Equatable, CustomStringConvertible, CustomDebugStringConvertible, CustomReflectable {
        public var url: URL
        public var username: String
        public var title: String
        fileprivate(set) var password: String
        fileprivate(set) var totpSeed: String?

        public var description: String { "PasswordCSV.Login(\(username) at \(url.host ?? ""), secrets redacted)" }
        public var debugDescription: String { description }
        public var customMirror: Mirror { Mirror(self, children: ["url": url, "username": username, "password": "<redacted>"]) }
        /// Whether `text` contains the password or TOTP seed. For tests.
        public func appears(in text: String) -> Bool { text.contains(password) || (totpSeed.map { text.contains($0) } ?? false) }
    }

    public struct Result: Sendable {
        public var logins: [Login] = []
        /// Rows without a web address or a password.
        public var skipped = 0
    }

    enum Failure: Error { case notCSV, noColumns }

    static let urlColumns = ["url", "login_uri", "website", "web site", "login url", "uri"]
    static let usernameColumns = ["username", "login_username", "user name", "login", "email", "user"]
    static let passwordColumns = ["password", "login_password"]
    static let titleColumns = ["title", "name"]
    static let totpColumns = ["otpauth", "login_totp", "totp", "otp"]

    public static func parse(_ data: Data) throws -> Result {
        guard var text = String(data: data, encoding: .utf8) else { throw Failure.notCSV }
        if text.hasPrefix("\u{FEFF}") { text.removeFirst() }
        let rows = records(text)
        guard let header = rows.first?.map({ $0.trimmingCharacters(in: .whitespaces).lowercased() }) else { throw Failure.notCSV }
        func column(_ names: [String]) -> Int? { names.lazy.compactMap { header.firstIndex(of: $0) }.first }
        guard let urlColumn = column(urlColumns), let passwordColumn = column(passwordColumns) else { throw Failure.noColumns }
        let usernameColumn = column(usernameColumns), titleColumn = column(titleColumns), totpColumn = column(totpColumns)
        var result = Result()
        for row in rows.dropFirst() where !(row.count == 1 && row[0].isEmpty) {
            func value(_ index: Int?) -> String { index.flatMap { $0 < row.count ? row[$0] : nil }?.trimmingCharacters(in: .whitespaces) ?? "" }
            let address = value(urlColumn), password = value(passwordColumn)
            guard !password.isEmpty, let url = webURL(address) else {
                result.skipped += 1
                continue
            }
            let totp = value(totpColumn)
            result.logins.append(Login(url: url, username: value(usernameColumn), title: value(titleColumn).isEmpty ? (url.host ?? "") : value(titleColumn),
                password: password, totpSeed: totp.isEmpty ? nil : totp))
        }
        return result
    }

    /// An http(s) address, adding `https://` to a bare host as exports sometimes write them.
    static func webURL(_ text: String) -> URL? {
        guard !text.isEmpty else { return nil }
        let candidate = text.contains("://") ? text : "https://" + text
        guard let url = URL(string: candidate), ["http", "https"].contains(url.scheme?.lowercased() ?? ""), url.host?.isEmpty == false
        else { return nil }
        return url
    }

    /// RFC 4180 records: quoted fields may hold commas, doubled quotes and line breaks.
    static func records(_ text: String) -> [[String]] {
        var rows: [[String]] = []
        var row: [String] = []
        var field = ""
        var quoted = false
        var iterator = Array(text.unicodeScalars).makeIterator()
        var pending: Unicode.Scalar?
        func next() -> Unicode.Scalar? {
            if let scalar = pending { pending = nil; return scalar }
            return iterator.next()
        }
        while let scalar = next() {
            if quoted {
                if scalar == "\"" {
                    if let following = next() {
                        if following == "\"" { field.unicodeScalars.append("\"") } else { quoted = false; pending = following }
                    } else {
                        quoted = false
                    }
                } else {
                    field.unicodeScalars.append(scalar)
                }
                continue
            }
            switch scalar {
            case "\"" where field.isEmpty: quoted = true
            case ",":
                row.append(field)
                field = ""
            case "\r":
                break
            case "\n":
                row.append(field)
                rows.append(row)
                row = []
                field = ""
            default: field.unicodeScalars.append(scalar)
            }
        }
        if !field.isEmpty || !row.isEmpty {
            row.append(field)
            rows.append(row)
        }
        return rows
    }
}

extension CoincideLoginProvider {
    /// Saves the logins of a CSV export. Returns how many were saved.
    public func importLogins(_ logins: [PasswordCSV.Login]) throws -> Int {
        var count = 0
        for login in logins {
            try save(url: login.url, username: login.username, password: login.password, totpSeed: login.totpSeed, title: login.title)
            count += 1
        }
        return count
    }
}
