import Foundation
import Security

/// Only the selected instance/generation key is addressable. OAuth never consults
/// Keychain for an API key, and reads never request an authentication dialog.
public enum AntigravityCredentialStore {
    private static let service = "com.apoorvdarshan.coincide.antigravity.api-key"

    public static func read(configuration: AntigravityConfiguration) throws -> AntigravityRuntimeCredential? {
        guard !configuration.authMethod.usesBrowser else { return nil }
        var request = query(configuration)
        request[kSecReturnData as String] = true
        request[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(request as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = result as? Data, data.count <= 65_536,
              let text = String(data: data, encoding: .utf8),
              let credential = try? AntigravityRuntimeCredential(apiKey: text) else { throw failure() }
        return credential
    }

    public static func write(_ credential: AntigravityRuntimeCredential, configuration: AntigravityConfiguration) throws {
        guard !configuration.authMethod.usesBrowser else { throw failure() }
        let request = query(configuration)
        let data = Data(credential.value.utf8)
        let updated = SecItemUpdate(request as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        if updated == errSecSuccess { return }
        guard updated == errSecItemNotFound else { throw failure() }
        var item = request
        item[kSecValueData as String] = data
        item[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        guard SecItemAdd(item as CFDictionary, nil) == errSecSuccess else { throw failure() }
    }

    public static func remove(configuration: AntigravityConfiguration) throws {
        guard !configuration.authMethod.usesBrowser else { return }
        let status = SecItemDelete(query(configuration) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else { throw failure() }
    }

    private static func query(_ configuration: AntigravityConfiguration) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: service,
         kSecAttrAccount as String: configuration.instanceID.uuidString.lowercased() + "." + configuration.authGeneration.uuidString.lowercased(),
         kSecAttrSynchronizable as String: false,
         kSecUseAuthenticationUI as String: kSecUseAuthenticationUIFail]
    }

    private static func failure() -> CoincideError {
        .init("The Antigravity credential could not be accessed securely. Check Keychain access and try again.")
    }
}

/// Injection keeps fixture tests independent of the user's Keychain.
public struct AntigravityCredentialAccess: Sendable {
    public let read: @Sendable (AntigravityConfiguration) throws -> AntigravityRuntimeCredential?
    public let write: @Sendable (AntigravityRuntimeCredential, AntigravityConfiguration) throws -> Void
    public let remove: @Sendable (AntigravityConfiguration) throws -> Void
    public init(read: @escaping @Sendable (AntigravityConfiguration) throws -> AntigravityRuntimeCredential?,
                write: @escaping @Sendable (AntigravityRuntimeCredential, AntigravityConfiguration) throws -> Void,
                remove: @escaping @Sendable (AntigravityConfiguration) throws -> Void) {
        self.read = read; self.write = write; self.remove = remove
    }
    public static let keychain = Self(read: AntigravityCredentialStore.read(configuration:),
                                     write: AntigravityCredentialStore.write(_:configuration:),
                                     remove: AntigravityCredentialStore.remove(configuration:))
}
