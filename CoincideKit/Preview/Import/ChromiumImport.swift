import CommonCrypto
import Foundation

/// Chromium-family browsers on macOS encrypt cookie values with AES-128-CBC, keyed from a password kept in the login
/// Keychain as "<Browser> Safe Storage" (PBKDF2-SHA1, salt "saltysalt", 1003 rounds, IV of 16 spaces). Values start
/// with "v10"; databases from schema version 24 on prefix the plaintext with the SHA-256 of the cookie's host.
public nonisolated struct ChromiumCookieDecryptor: Sendable {
    let key: Data

    public init(safeStoragePassword: Data) {
        key = Self.deriveKey(safeStoragePassword)
    }

    static func deriveKey(_ password: Data) -> Data {
        var key = [UInt8](repeating: 0, count: kCCKeySizeAES128)
        let salt = Array("saltysalt".utf8)
        password.withUnsafeBytes { raw in
            _ = CCKeyDerivationPBKDF(
                CCPBKDFAlgorithm(kCCPBKDF2), raw.baseAddress?.assumingMemoryBound(to: Int8.self), password.count,
                salt, salt.count, CCPseudoRandomAlgorithm(kCCPRFHmacAlgSHA1), 1003, &key, key.count)
        }
        return Data(key)
    }

    static let iv = Data(repeating: 0x20, count: kCCBlockSizeAES128)

    /// The cookie's value, or nil when it isn't one this key opens.
    public func decrypt(_ encrypted: Data, hostKey: String, schemaVersion: Int) -> String? {
        guard encrypted.count > 3 else { return nil }
        let prefix = encrypted.prefix(3)
        guard prefix == Data("v10".utf8) || prefix == Data("v11".utf8) else { return nil }
        guard var plain = Self.crypt(CCOperation(kCCDecrypt), Data(encrypted.dropFirst(3)), key: key) else { return nil }
        if schemaVersion >= 24 {
            guard plain.count >= 32 else { return nil }
            plain = Data(plain.dropFirst(32))
        }
        return String(data: plain, encoding: .utf8)
    }

    /// Encrypts like Chromium. For fixtures.
    public func encrypt(_ value: String, hostKey: String, schemaVersion: Int) -> Data {
        var plain = Data(value.utf8)
        if schemaVersion >= 24 {
            var digest = [UInt8](repeating: 0, count: Int(CC_SHA256_DIGEST_LENGTH))
            let host = Array(hostKey.utf8)
            CC_SHA256(host, CC_LONG(host.count), &digest)
            plain = Data(digest) + plain
        }
        return Data("v10".utf8) + (Self.crypt(CCOperation(kCCEncrypt), plain, key: key) ?? Data())
    }

    static func crypt(_ operation: CCOperation, _ input: Data, key: Data) -> Data? {
        var output = [UInt8](repeating: 0, count: input.count + kCCBlockSizeAES128)
        var moved = 0
        let status = input.withUnsafeBytes { inputBytes in
            key.withUnsafeBytes { keyBytes in
                iv.withUnsafeBytes { ivBytes in
                    CCCrypt(operation, CCAlgorithm(kCCAlgorithmAES), CCOptions(kCCOptionPKCS7Padding),
                        keyBytes.baseAddress, key.count, ivBytes.baseAddress, inputBytes.baseAddress, input.count,
                        &output, output.count, &moved)
                }
            }
        }
        guard status == kCCSuccess else { return nil }
        return Data(output.prefix(moved))
    }
}

/// Reads a Chromium profile folder: `Cookies` (or `Network/Cookies`), `History` and the `Bookmarks` JSON file.
public nonisolated enum ChromiumProfileReader {
    public static func cookiesFile(in profile: URL) -> URL? {
        let manager = FileManager.default
        for candidate in [profile.appendingPathComponent("Network/Cookies"), profile.appendingPathComponent("Cookies")]
        where manager.fileExists(atPath: candidate.path) { return candidate }
        return nil
    }

    /// The profile's cookies. `password` is the Safe Storage secret; nil reads only cookies stored unencrypted.
    static func cookies(in profile: URL, password: Data?) throws -> (cookies: [ImportedCookie], undecryptable: Int) {
        guard let file = cookiesFile(in: profile) else { return ([], 0) }
        let snapshot = try SQLiteSnapshot(copying: file)
        defer { snapshot.close() }
        let version = (try? snapshot.rows("SELECT value FROM meta WHERE key = 'version'").first?["value"]?.int).flatMap { $0 }
        let decryptor = password.map { ChromiumCookieDecryptor(safeStoragePassword: $0) }
        let columns = snapshot.columns(of: "cookies")
        let sameSite = columns.contains("samesite") ? "samesite" : "-1"
        let rows = try snapshot.rows(
            "SELECT host_key, name, value, encrypted_value, path, expires_utc, is_secure, is_httponly, \(sameSite) AS samesite FROM cookies")
        var cookies: [ImportedCookie] = []
        var failed = 0
        for row in rows {
            guard let host = row["host_key"]?.string, let name = row["name"]?.string, !host.isEmpty else { continue }
            var value = row["value"]?.string ?? ""
            if value.isEmpty, let encrypted = row["encrypted_value"]?.data, !encrypted.isEmpty {
                guard let decrypted = decryptor?.decrypt(encrypted, hostKey: host, schemaVersion: Int(version ?? 0)) else {
                    failed += 1
                    continue
                }
                value = decrypted
            }
            let sameSitePolicy: ImportedCookie.SameSite? =
                switch row["samesite"]?.int {
                case 0: ImportedCookie.SameSite.unrestricted
                case 1: .lax
                case 2: .strict
                default: nil
                }
            cookies.append(ImportedCookie(
                domain: host, name: name, value: value, path: row["path"]?.string ?? "/",
                expires: BrowserTime.chromium(row["expires_utc"]?.int ?? 0), isSecure: row["is_secure"]?.int == 1,
                isHTTPOnly: row["is_httponly"]?.int == 1, sameSite: sameSitePolicy))
        }
        return (cookies, failed)
    }

    static func history(in profile: URL, limit: Int) throws -> [BrowserHistoryItem] {
        let file = profile.appendingPathComponent("History")
        guard FileManager.default.fileExists(atPath: file.path) else { return [] }
        let snapshot = try SQLiteSnapshot(copying: file)
        defer { snapshot.close() }
        return try snapshot.rows(
            "SELECT url, title, visit_count, last_visit_time FROM urls WHERE hidden = 0 ORDER BY last_visit_time DESC", limit: limit
        ).compactMap { row in
            guard let url = row["url"]?.string, url.hasPrefix("http") else { return nil }
            return BrowserHistoryItem(url: url, title: row["title"]?.string ?? "", visitCount: Int(row["visit_count"]?.int ?? 1),
                lastVisit: BrowserTime.chromium(row["last_visit_time"]?.int ?? 0) ?? .distantPast)
        }
    }

    static func bookmarks(in profile: URL, browser: String) throws -> [BrowserBookmark] {
        let file = profile.appendingPathComponent("Bookmarks")
        guard FileManager.default.fileExists(atPath: file.path) else { return [] }
        let data = try Data(contentsOf: file)
        return parseBookmarks(data, browser: browser)
    }

    /// The `Bookmarks` file: `roots` of folders (`type: folder`, `children`) and bookmarks (`type: url`).
    static func parseBookmarks(_ data: Data, browser: String) -> [BrowserBookmark] {
        guard let roots = JSONValue.parse(data)?["roots"]?.object else { return [] }
        var result: [BrowserBookmark] = []
        func walk(_ node: JSONValue, folder: String) {
            switch node["type"]?.string {
            case "url":
                if let url = node["url"]?.string, url.hasPrefix("http") {
                    result.append(BrowserBookmark(url: url, title: node["name"]?.string ?? url, folder: folder))
                }
            default:
                let name = node["name"]?.string ?? ""
                let path = name.isEmpty ? folder : folder + " › " + name
                for child in node["children"]?.array ?? [] { walk(child, folder: path) }
            }
        }
        for key in roots.keys.sorted() where key != "sync_transaction_version" {
            if let root = roots[key] { walk(root, folder: browser) }
        }
        return result
    }
}
