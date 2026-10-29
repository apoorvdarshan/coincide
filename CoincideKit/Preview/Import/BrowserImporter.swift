import Foundation
import Security

/// Reads what the user chose from one browser profile. Runs off the main thread; nothing read leaves this Mac or is
/// logged, and cookie values stay inside `ImportedCookie`.
public nonisolated enum BrowserImporter {
    public static let historyLimit = 5_000

    /// Scans `profile` of `browser` for `kinds`. `safeStorage` returns a Chromium browser's cookie key from the
    /// Keychain (macOS asks the user first); it's asked only when cookies are wanted. `home` locates WebKit data.
    public static func scan(
        _ browser: BrowserCatalog.Detected, profile: BrowserCatalog.Profile, kinds: Set<BrowserImportKind>, home: URL,
        safeStorage: ([String]) -> Data?
    ) -> BrowserImportData {
        var data = BrowserImportData()
        let name = browser.definition.name
        func attempt(_ kind: BrowserImportKind, _ body: () throws -> Void) {
            guard kinds.contains(kind), browser.kinds.contains(kind) else { return }
            do { try body() } catch SQLiteSnapshot.Failure.missing {
                // Nothing of this kind in the profile.
            } catch SQLiteSnapshot.Failure.permissionDenied {
                data.problems.append(BrowserImportProblem(kind: kind, reason: .needsFullDiskAccess))
            } catch let problem as BrowserImportProblem {
                data.problems.append(problem)
            } catch {
                data.problems.append(BrowserImportProblem(kind: kind, reason: .unreadable))
            }
        }
        switch browser.definition.engine {
        case .chromium(let services):
            attempt(.cookies) {
                guard ChromiumProfileReader.cookiesFile(in: profile.folder) != nil else { return }
                let password = safeStorage(services)
                let read = try ChromiumProfileReader.cookies(in: profile.folder, password: password)
                data.cookies = read.cookies
                if read.undecryptable > 0 {
                    if password == nil { throw BrowserImportProblem(kind: .cookies, reason: .keyUnavailable) }
                    if read.cookies.isEmpty { throw BrowserImportProblem(kind: .cookies, reason: .undecryptable) }
                }
            }
            attempt(.history) { data.history = try ChromiumProfileReader.history(in: profile.folder, limit: historyLimit) }
            attempt(.bookmarks) { data.bookmarks = try ChromiumProfileReader.bookmarks(in: profile.folder, browser: name) }
        case .firefox:
            attempt(.cookies) { data.cookies = try FirefoxProfileReader.cookies(in: profile.folder) }
            attempt(.history) { data.history = try FirefoxProfileReader.history(in: profile.folder, limit: historyLimit) }
            attempt(.bookmarks) { data.bookmarks = try FirefoxProfileReader.bookmarks(in: profile.folder, browser: name) }
        case .webkit(let cookies, let history, let bookmarks, _):
            attempt(.cookies) {
                // The first file that exists; a refusal on it means Full Disk Access.
                for path in cookies {
                    let file = home.appendingPathComponent(path)
                    let read = try SafariDataReader.cookies(at: file)
                    if !read.isEmpty || FileManager.default.fileExists(atPath: file.path) {
                        data.cookies = read
                        break
                    }
                }
            }
            if let history {
                attempt(.history) { data.history = try SafariDataReader.history(at: home.appendingPathComponent(history), limit: historyLimit) }
            }
            if let bookmarks {
                attempt(.bookmarks) { data.bookmarks = try SafariDataReader.bookmarks(at: home.appendingPathComponent(bookmarks), browser: name) }
            }
        case .unsupported:
            break
        }
        return data
    }
}

/// Reads a Chromium browser's cookie key from the login Keychain. macOS shows its own prompt naming the item; the
/// user can deny it, and then no cookies are imported. The secret is returned to the caller only, never stored.
public nonisolated enum SafeStorageKeychain {
    public static func password(services: [String]) -> Data? {
        for service in services {
            let query: [String: Any] = [
                kSecClass as String: kSecClassGenericPassword,
                kSecAttrService as String: service,
                kSecReturnData as String: true,
                kSecMatchLimit as String: kSecMatchLimitOne,
            ]
            var item: CFTypeRef?
            let status = SecItemCopyMatching(query as CFDictionary, &item)
            if status == errSecSuccess, let data = item as? Data, !data.isEmpty { return data }
            // The user said no; don't ask again for the browser's other names.
            if status == errSecUserCanceled || status == errSecAuthFailed { return nil }
        }
        return nil
    }
}
