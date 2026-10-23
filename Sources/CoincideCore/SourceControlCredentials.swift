import Foundation
import LocalAuthentication
import Security

/// An optional GitHub token saved by the person in Settings. It is stored only in the device
/// Keychain, never in argv, logs, preferences or the workspace database, and reaches `gh` only as
/// `GH_TOKEN` in the child environment for its exact host.
public enum SourceControlTokenStore {
    private static let service = "com.apoorvdarshan.coincide.source-control.github-token"

    public static func read(host: String) throws -> String? {
        var request = query(host)
        request[kSecReturnData as String] = true
        request[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(request as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = result as? Data, let text = String(data: data, encoding: .utf8), validToken(text) else { throw failure() }
        return text
    }
    public static func write(_ token: String, host: String) throws {
        guard validToken(token), validHost(host) else { throw CoincideError("Enter a GitHub token without spaces or line breaks.") }
        let request = query(host), data = Data(token.utf8)
        let updated = SecItemUpdate(request as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        if updated == errSecSuccess { return }
        guard updated == errSecItemNotFound else { throw failure() }
        var item = request
        item[kSecValueData as String] = data
        item[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        guard SecItemAdd(item as CFDictionary, nil) == errSecSuccess else { throw failure() }
    }
    public static func remove(host: String) throws {
        let status = SecItemDelete(query(host) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else { throw failure() }
    }
    public static func validToken(_ token: String) -> Bool {
        !token.isEmpty && token.utf8.count <= 1_024 && token.unicodeScalars.allSatisfy { $0.value > 32 && $0.value < 127 }
    }
    public static func validHost(_ host: String) -> Bool { (try? GitHubRepository(host: host, owner: "o", name: "r")) != nil && host == host.lowercased() }
    private static func query(_ host: String) -> [String: Any] {
        let context = LAContext()
        context.interactionNotAllowed = true
        return [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service, kSecAttrAccount as String: host.lowercased(),
                kSecAttrSynchronizable as String: false, kSecUseAuthenticationContext as String: context]
    }
    private static func failure() -> CoincideError { .init("The saved GitHub token could not be accessed securely. Check Keychain access and try again.") }
}

/// Injection keeps fixture tests independent of the user's Keychain.
public struct SourceControlTokenAccess: Sendable {
    public let read: @Sendable (String) throws -> String?
    public let write: @Sendable (String, String) throws -> Void
    public let remove: @Sendable (String) throws -> Void
    public init(read: @escaping @Sendable (String) throws -> String?, write: @escaping @Sendable (String, String) throws -> Void, remove: @escaping @Sendable (String) throws -> Void) {
        self.read = read; self.write = write; self.remove = remove
    }
    public static let keychain = Self(read: SourceControlTokenStore.read(host:), write: SourceControlTokenStore.write(_:host:), remove: SourceControlTokenStore.remove(host:))
}

/// In-memory tokens applied to `gh` children. Loaded from Keychain only after an explicit
/// Settings action or app launch in the signed app; empty by default.
public final class GitHubCredentialOverrides: @unchecked Sendable {
    public static let shared = GitHubCredentialOverrides()
    private let lock = NSLock()
    private var tokens: [String: String] = [:]
    public init() {}
    public func set(_ token: String?, host: String) {
        lock.lock(); defer { lock.unlock() }
        if let token, SourceControlTokenStore.validToken(token) { tokens[host.lowercased()] = token } else { tokens.removeValue(forKey: host.lowercased()) }
    }
    public func hasToken(for host: String) -> Bool { lock.lock(); defer { lock.unlock() }; return tokens[host.lowercased()] != nil }
    public var hosts: [String] { lock.lock(); defer { lock.unlock() }; return tokens.keys.sorted() }
    /// github.com and GHE.com use `GH_TOKEN`; other hosts use `GH_ENTERPRISE_TOKEN` with `GH_HOST`.
    func apply(to environment: inout [String: String], host: String) {
        lock.lock(); let token = tokens[host.lowercased()]; lock.unlock()
        guard let token else { return }
        if host == "github.com" || host.hasSuffix(".ghe.com") { environment["GH_TOKEN"] = token; environment.removeValue(forKey: "GITHUB_TOKEN") }
        else { environment["GH_HOST"] = host; environment["GH_ENTERPRISE_TOKEN"] = token; environment.removeValue(forKey: "GITHUB_ENTERPRISE_TOKEN") }
    }
}
