import Foundation
import Security

/// Small secrets Coincide keeps for the browser, such as the Bitwarden session: the login Keychain in the app, memory
/// in tests.
public protocol SecretStore: Sendable {
    func read(_ account: String) -> String?
    func write(_ value: String, for account: String) throws
    func delete(_ account: String)
}

/// Generic passwords under one service of Coincide's own; never another app's items.
public nonisolated struct KeychainSecretStore: SecretStore {
    let service: String

    public init(service: String = CoincideIdentity.scoped("browser")) { self.service = service }

    private func query(_ account: String) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service, kSecAttrAccount as String: account]
    }

    public func read(_ account: String) -> String? {
        var query = query(account)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess, let data = item as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    public func write(_ value: String, for account: String) throws {
        let data = Data(value.utf8)
        let status = SecItemUpdate(query(account) as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        if status == errSecItemNotFound {
            var add = query(account)
            add[kSecValueData as String] = data
            add[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
            add[kSecAttrLabel as String] = "Coincide browser"
            guard SecItemAdd(add as CFDictionary, nil) == errSecSuccess else { throw PasswordProviderError.failed(String(localized: "The Keychain didn’t save the item.")) }
        } else if status != errSecSuccess {
            throw PasswordProviderError.failed(String(localized: "The Keychain didn’t save the item."))
        }
    }

    public func delete(_ account: String) { SecItemDelete(query(account) as CFDictionary) }

    /// Accounts saved under this service, without reading their secrets (no Keychain prompt).
    public func accounts() -> [String] {
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
            kSecReturnAttributes as String: true, kSecMatchLimit as String: kSecMatchLimitAll,
        ]
        query[kSecUseAuthenticationUI as String] = kSecUseAuthenticationUIFail
        var items: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &items) == errSecSuccess, let list = items as? [[String: Any]] else { return [] }
        return list.compactMap { $0[kSecAttrAccount as String] as? String }
    }
}

/// Secrets in memory, for tests.
public final class MemorySecretStore: SecretStore, @unchecked Sendable {
    private var values: [String: String] = [:]
    private let lock = NSLock()

    public init() {}
    public func read(_ account: String) -> String? { lock.withLock { values[account] } }
    public func write(_ value: String, for account: String) throws { lock.withLock { values[account] = value } }
    public func delete(_ account: String) { _ = lock.withLock { values.removeValue(forKey: account) } }
    public var allAccounts: [String] { lock.withLock { Array(values.keys) } }
}

/// A login saved in Coincide: its address, username and title are listed without unlocking anything; the password
/// and an optional TOTP seed are one Keychain item each login.
public nonisolated struct SavedLogin: Codable, Hashable, Sendable, Identifiable {
    public var id: UUID
    public var url: String
    public var username: String
    public var title: String
    public var created: Date

    public init(id: UUID = UUID(), url: String, username: String, title: String, created: Date = Date()) {
        self.id = id
        self.url = url
        self.username = username
        self.title = title
        self.created = created
    }
}

/// Coincide's own logins. The list (no secrets) is a JSON file beside the store's data; each secret is a Keychain
/// item named by the login's id.
public nonisolated struct CoincideLoginProvider: PasswordProvider {
    public let kind = PasswordManagerKind.coincide
    public let capabilities = PasswordCapabilities(lookupByDomain: true, totp: true)
    let index: URL
    let secrets: SecretStore

    private struct Stored: Codable {
        var password: String
        var totp: String?
    }

    /// The Keychain service the logins' secrets are kept under.
    public static let keychainService = CoincideIdentity.scoped("browser-logins")

    public init(directory: URL, secrets: SecretStore = KeychainSecretStore(service: CoincideLoginProvider.keychainService)) {
        index = directory.appendingPathComponent("browser-logins.json")
        self.secrets = secrets
    }

    public func status() async -> PasswordProviderStatus { .unlocked(account: nil) }

    public var saved: [SavedLogin] {
        (try? Data(contentsOf: index)).flatMap { try? JSONDecoder().decode([SavedLogin].self, from: $0) } ?? []
    }

    public func logins(for page: URL) async throws -> [LoginItem] {
        saved.map { LoginItem(source: .coincide, itemID: $0.id.uuidString, title: $0.title, username: $0.username, urls: [$0.url]) }
    }

    public func secret(for item: LoginItem) async throws -> LoginSecret {
        guard let login = saved.first(where: { $0.id.uuidString == item.itemID }), let text = secrets.read(login.id.uuidString),
            let stored = try? JSONDecoder().decode(Stored.self, from: Data(text.utf8))
        else { throw PasswordProviderError.notFound }
        return LoginSecret(username: login.username, password: stored.password, totp: stored.totp.flatMap { TOTP($0)?.code() })
    }

    /// Saves a login, replacing the password of one with the same address and username.
    @discardableResult
    public func save(url: URL, username: String, password: String, totpSeed: String? = nil, title: String? = nil) throws -> SavedLogin {
        guard let address = Self.origin(of: url) else { throw PasswordProviderError.failed(String(localized: "Only web pages’ logins can be saved.")) }
        var list = saved
        let login = list.first { $0.url == address && $0.username == username }
            ?? SavedLogin(url: address, username: username, title: title.flatMap { $0.isEmpty ? nil : String($0.prefix(200)) } ?? url.host ?? address)
        let stored = Stored(password: password, totp: totpSeed?.isEmpty == false ? totpSeed : nil)
        try secrets.write(String(decoding: try JSONEncoder().encode(stored), as: UTF8.self), for: login.id.uuidString)
        if !list.contains(login) { list.append(login) }
        try write(list)
        return login
    }

    /// Whether a login with these details is saved already (same address, username and password).
    public func isSaved(url: URL, username: String, password: String) -> Bool {
        guard let address = Self.origin(of: url), let login = saved.first(where: { $0.url == address && $0.username == username }),
            let text = secrets.read(login.id.uuidString),
            let stored = try? JSONDecoder().decode(Stored.self, from: Data(text.utf8))
        else { return false }
        return stored.password == password
    }

    public func delete(_ id: UUID) throws {
        secrets.delete(id.uuidString)
        try write(saved.filter { $0.id != id })
    }

    private func write(_ list: [SavedLogin]) throws {
        try FileManager.default.createDirectory(at: index.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONEncoder().encode(list).write(to: index, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: index.path)
    }

    /// Scheme, host and port: logins are saved per origin, like a browser.
    static func origin(of url: URL) -> String? {
        guard let scheme = url.scheme?.lowercased(), ["http", "https"].contains(scheme), let host = url.host, !host.isEmpty else { return nil }
        return "\(scheme)://\(host.lowercased())" + (url.port.map { ":\($0)" } ?? "")
    }
}
