import CoincideRemoteKit
import Foundation
import Security

/// A Mac this device has paired with. The token that proves it lives in the Keychain, never here.
struct SavedMac: Codable, Hashable, Identifiable {
    var serverID: String
    var name: String
    var hosts: [RemoteHostCandidate]
    var port: UInt16
    /// SHA-256 of the Mac's certificate, pinned at pairing.
    var fingerprint: String
    var deviceID: String
    /// The address that worked last, tried first next time.
    var lastHost: String?
    var pairedAt: Date
    var lastConnectedAt: Date?

    var id: String { serverID }
}

/// The Macs this device paired with, and their tokens.
@MainActor
final class SavedMacs {
    static let shared = SavedMacs()

    private let defaults: UserDefaults
    private let key = "savedMacs"
    private let lastKey = "lastMacID"
    private let keychainService = "com.apoorvdarshan.coincide.remote.token"

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    var all: [SavedMac] {
        guard let data = defaults.data(forKey: key), let macs = try? JSONDecoder().decode([SavedMac].self, from: data) else { return [] }
        return macs
    }

    var lastUsedID: String? {
        get { defaults.string(forKey: lastKey) }
        set { defaults.set(newValue, forKey: lastKey) }
    }

    func save(_ mac: SavedMac) {
        var macs = all.filter { $0.serverID != mac.serverID }
        macs.append(mac)
        defaults.set(try? JSONEncoder().encode(macs), forKey: key)
    }

    func remove(_ serverID: String) {
        defaults.set(try? JSONEncoder().encode(all.filter { $0.serverID != serverID }), forKey: key)
        deleteToken(for: serverID)
        if lastUsedID == serverID { lastUsedID = nil }
    }

    // MARK: Keychain

    private func query(_ serverID: String) -> [CFString: Any] {
        [kSecClass: kSecClassGenericPassword, kSecAttrService: keychainService, kSecAttrAccount: serverID]
    }

    func setToken(_ token: String, for serverID: String) {
        SecItemDelete(query(serverID) as CFDictionary)
        var attributes = query(serverID)
        attributes[kSecValueData] = Data(token.utf8)
        // Only on this device, and readable after the first unlock so reconnecting in the background works.
        attributes[kSecAttrAccessible] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        SecItemAdd(attributes as CFDictionary, nil)
    }

    func token(for serverID: String) -> String? {
        var request = query(serverID)
        request[kSecReturnData] = true
        request[kSecMatchLimit] = kSecMatchLimitOne
        var result: CFTypeRef?
        guard SecItemCopyMatching(request as CFDictionary, &result) == errSecSuccess, let data = result as? Data else { return nil }
        return String(decoding: data, as: UTF8.self)
    }

    func deleteToken(for serverID: String) {
        SecItemDelete(query(serverID) as CFDictionary)
    }
}
