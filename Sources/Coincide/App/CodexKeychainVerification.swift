import CoincideCore
import Foundation

/// Explicit signed-bundle acceptance check. The random synthetic item is never
/// a saved account, and a duplicate is preserved without reading or deleting it.
enum CodexKeychainVerification {
    static func run(storage: any CodexCredentialStorage = KeychainCodexCredentialStorage()) throws {
        let instanceID = UUID()
        let first = Data("Coincide synthetic Keychain acceptance item".utf8)
        let second = Data("Coincide synthetic Keychain acceptance update".utf8)
        guard try storage.createIfAbsent(first, instanceID: instanceID) else {
            throw CoincideError("The synthetic Keychain acceptance item already exists.")
        }
        do {
            guard try storage.read(instanceID: instanceID) == first else {
                throw CoincideError("The synthetic Keychain acceptance read did not match.")
            }
            try storage.write(second, instanceID: instanceID)
            guard try storage.read(instanceID: instanceID) == second else {
                throw CoincideError("The synthetic Keychain acceptance update did not match.")
            }
            try storage.delete(instanceID: instanceID)
            guard try storage.read(instanceID: instanceID) == nil else {
                throw CoincideError("The synthetic Keychain acceptance item was not removed.")
            }
        } catch {
            try? storage.delete(instanceID: instanceID)
            throw error
        }
    }
}
