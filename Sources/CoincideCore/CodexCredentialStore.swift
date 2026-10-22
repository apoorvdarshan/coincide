import Foundation
import LocalAuthentication
import Security

/// Opaque credentials are stored outside workspace persistence. A successful
/// item replacement is atomic, but read/rotate/delete workflows require the
/// authentication coordinator's cross-process lease; this API offers no CAS.
public protocol CodexCredentialStorage: Sendable {
    func read(instanceID: UUID) throws -> Data?
    /// Atomic initial claim only; a duplicate preserves the existing item.
    func createIfAbsent(_ data: Data, instanceID: UUID) throws -> Bool
    func write(_ data: Data, instanceID: UUID) throws
    func delete(instanceID: UUID) throws
}

public enum CodexCredentialStorageError: Error, Sendable, Equatable, LocalizedError {
    case exceedsLimit, unavailable
    public var errorDescription: String? {
        switch self {
        case .exceedsLimit: String(localized: "The Codex credential exceeds its secure storage limit.")
        case .unavailable: String(localized: "The Codex credential could not be accessed securely. Check Keychain access before continuing.")
        }
    }
}

/// Initializing this value does not read Keychain, show an authentication dialog,
/// authenticate Codex, or inspect another account's credentials.
public struct KeychainCodexCredentialStorage: CodexCredentialStorage {
    public static let maximumBytes = 1_048_576
    private let api: CodexCredentialSecurityAPI
    public init() { api = .live }
    init(api: CodexCredentialSecurityAPI) { self.api = api }

    public func read(instanceID: UUID) throws -> Data? {
        let result = api.read(.init(instanceID: instanceID))
        if result.status == errSecItemNotFound { return nil }
        guard result.status == errSecSuccess, let data = result.data else { throw CodexCredentialStorageError.unavailable }
        guard data.count <= Self.maximumBytes else { throw CodexCredentialStorageError.exceedsLimit }
        return data
    }
    public func write(_ data: Data, instanceID: UUID) throws {
        guard data.count <= Self.maximumBytes else { throw CodexCredentialStorageError.exceedsLimit }
        let key = CodexCredentialKey(instanceID: instanceID)
        // Another process may add after our not-found update or remove after a
        // duplicate add. Retry only those exact-item races, with a fixed bound.
        for _ in 0..<3 {
            let updated = api.update(key, data)
            if updated == errSecSuccess { return }
            guard updated == errSecItemNotFound else { throw CodexCredentialStorageError.unavailable }
            let added = api.add(key, data)
            if added == errSecSuccess { return }
            guard added == errSecDuplicateItem else { throw CodexCredentialStorageError.unavailable }
        }
        throw CodexCredentialStorageError.unavailable
    }
    public func createIfAbsent(_ data: Data, instanceID: UUID) throws -> Bool {
        guard data.count <= Self.maximumBytes else { throw CodexCredentialStorageError.exceedsLimit }
        let status = api.add(.init(instanceID: instanceID), data)
        if status == errSecSuccess { return true }
        if status == errSecDuplicateItem { return false }
        throw CodexCredentialStorageError.unavailable
    }
    public func delete(instanceID: UUID) throws {
        let status = api.delete(.init(instanceID: instanceID))
        guard status == errSecSuccess || status == errSecItemNotFound else { throw CodexCredentialStorageError.unavailable }
    }
}

/// The injectable Security boundary passes value types only. CF dictionaries and
/// untyped Security results remain confined to the synchronous live adapter.
struct CodexCredentialKey: Sendable, Equatable {
    enum Protection: Sendable, Equatable { case afterFirstUnlockThisDeviceOnly }
    let service = "com.apoorvdarshan.coincide.codex-auth"
    let account: String
    let synchronizable = false
    let usesDataProtectionKeychain = true
    let allowsAuthenticationUI = false
    let protection: Protection = .afterFirstUnlockThisDeviceOnly
    init(instanceID: UUID) { account = instanceID.uuidString.lowercased() }
}
struct CodexCredentialSecurityAPI: Sendable {
    struct ReadResult: Sendable {
        let status: OSStatus
        let data: Data?
        init(_ status: OSStatus, data: Data? = nil) { self.status = status; self.data = data }
    }
    let read: @Sendable (CodexCredentialKey) -> ReadResult
    let update: @Sendable (CodexCredentialKey, Data) -> OSStatus
    let add: @Sendable (CodexCredentialKey, Data) -> OSStatus
    let delete: @Sendable (CodexCredentialKey) -> OSStatus

    static let live = Self(read: { key in
        var request = identity(key)
        request[kSecReturnData as String] = true
        request[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(request as CFDictionary, &result)
        return .init(status, data: status == errSecSuccess ? result as? Data : nil)
    }, update: { key, data in
        SecItemUpdate(identity(key) as CFDictionary, value(data) as CFDictionary)
    }, add: { key, data in
        var request = identity(key)
        for (attribute, attributeValue) in value(data) { request[attribute] = attributeValue }
        return SecItemAdd(request as CFDictionary, nil)
    }, delete: { key in
        SecItemDelete(identity(key) as CFDictionary)
    })
    private static func identity(_ key: CodexCredentialKey) -> [String: Any] {
        let context = LAContext()
        context.interactionNotAllowed = true
        // macOS honors accessibility without synchronization in this keychain.
        return [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: key.service,
         kSecAttrAccount as String: key.account,
         kSecAttrSynchronizable as String: key.synchronizable,
         kSecUseDataProtectionKeychain as String: key.usesDataProtectionKeychain,
         kSecUseAuthenticationContext as String: context]
    }
    private static func value(_ data: Data) -> [String: Any] {
        [kSecValueData as String: data,
         kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly]
    }
}
