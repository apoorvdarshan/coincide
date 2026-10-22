import Foundation
import Security
import Testing
@testable import CoincideCore

/// Security's entire boundary is replaced. These tests never call SecItem APIs,
/// access the user's Keychain, or encode actual provider credentials.
private final class FakeCodexCredentialKeychain: @unchecked Sendable {
    enum Kind: Sendable, Equatable { case read, update, add, delete }
    struct Call: Sendable { let kind: Kind; let key: CodexCredentialKey; let data: Data? }
    private let lock = NSLock()
    private var values: [String: Data] = [:]
    private var recorded: [Call] = []
    private var reads: [CodexCredentialSecurityAPI.ReadResult] = []
    private var updates: [OSStatus] = [], additions: [OSStatus] = [], deletions: [OSStatus] = []
    var calls: [Call] { lock.withLock { recorded } }
    func readResults(_ responses: [CodexCredentialSecurityAPI.ReadResult]) { lock.withLock { reads = responses } }
    func updateStatuses(_ responses: [OSStatus]) { lock.withLock { updates = responses } }
    func addStatuses(_ responses: [OSStatus]) { lock.withLock { additions = responses } }
    func deleteStatuses(_ responses: [OSStatus]) { lock.withLock { deletions = responses } }
    func stored(_ id: UUID) -> Data? { lock.withLock { values[id.uuidString.lowercased()] } }
    var api: CodexCredentialSecurityAPI {
        .init(read: { key in
            self.lock.withLock {
                self.recorded.append(.init(kind: .read, key: key, data: nil))
                if !self.reads.isEmpty { return self.reads.removeFirst() }
                return self.values[key.account].map { .init(errSecSuccess, data: $0) } ?? .init(errSecItemNotFound)
            }
        }, update: { key, data in
            self.lock.withLock {
                self.recorded.append(.init(kind: .update, key: key, data: data))
                let status = self.updates.isEmpty
                    ? (self.values[key.account] == nil ? errSecItemNotFound : errSecSuccess) : self.updates.removeFirst()
                if status == errSecSuccess { self.values[key.account] = data }
                return status
            }
        }, add: { key, data in
            self.lock.withLock {
                self.recorded.append(.init(kind: .add, key: key, data: data))
                let status = self.additions.isEmpty
                    ? (self.values[key.account] == nil ? errSecSuccess : errSecDuplicateItem) : self.additions.removeFirst()
                if status == errSecSuccess { self.values[key.account] = data }
                else if status == errSecDuplicateItem, self.values[key.account] == nil {
                    // A deterministic other-writer insertion between our
                    // not-found update and duplicate add.
                    self.values[key.account] = Data([0x51])
                }
                return status
            }
        }, delete: { key in
            self.lock.withLock {
                self.recorded.append(.init(kind: .delete, key: key, data: nil))
                let status = self.deletions.isEmpty
                    ? (self.values[key.account] == nil ? errSecItemNotFound : errSecSuccess) : self.deletions.removeFirst()
                if status == errSecSuccess { self.values.removeValue(forKey: key.account) }
                return status
            }
        })
    }
}

@Test func codexCredentialStorageIsLazyOpaqueAndConfinedToTheExactInstance() throws {
    let keychain = FakeCodexCredentialKeychain(), storage = KeychainCodexCredentialStorage(api: keychain.api)
    let first = UUID(uuidString: "ABCDEF12-3456-4789-ABCD-0123456789AB")!, second = UUID()
    #expect(keychain.calls.isEmpty, "Constructing credential storage cannot read or initialize an account.")
    #expect(try storage.read(instanceID: first) == nil)
    let binary = Data([0x00, 0xFF, 0x80, 0x01, 0x00]), other = Data([0x10, 0x20])
    try storage.write(binary, instanceID: first); try storage.write(other, instanceID: second)
    #expect(try storage.read(instanceID: first) == binary)
    #expect(try storage.read(instanceID: second) == other)
    try storage.delete(instanceID: first); try storage.delete(instanceID: first)
    #expect(try storage.read(instanceID: first) == nil)
    #expect(try storage.read(instanceID: second) == other, "Deleting one account cannot enumerate or remove any other instance.")
    for call in keychain.calls {
        #expect(call.key.service == "com.apoorvdarshan.coincide.codex-auth")
        #expect(call.key.account == first.uuidString.lowercased() || call.key.account == second.uuidString.lowercased())
        #expect(call.key.synchronizable == false && call.key.usesDataProtectionKeychain && !call.key.allowsAuthenticationUI)
        #expect(call.key.protection == .afterFirstUnlockThisDeviceOnly)
    }
    let account = try #require(keychain.calls.first?.key.account)
    #expect(account == first.uuidString.lowercased())
    #expect(account != first.uuidString, "The deliberately uppercase UUID fixture must become a canonical lowercase account key.")
}

@Test func codexCredentialStorageHandlesTheExactByteLimitAndRejectsOversizeBeforeMutation() throws {
    let keychain = FakeCodexCredentialKeychain(), storage = KeychainCodexCredentialStorage(api: keychain.api), id = UUID()
    try storage.write(Data(), instanceID: id)
    #expect(try storage.read(instanceID: id) == Data(), "The byte layer does not reinterpret an empty value as a missing item.")
    let maximum = Data(repeating: 0xA3, count: KeychainCodexCredentialStorage.maximumBytes)
    try storage.write(maximum, instanceID: id)
    #expect(try storage.read(instanceID: id) == maximum)
    let calls = keychain.calls.count
    #expect(throws: CodexCredentialStorageError.exceedsLimit) {
        try storage.write(Data(repeating: 0x00, count: KeychainCodexCredentialStorage.maximumBytes + 1), instanceID: id)
    }
    #expect(keychain.calls.count == calls && keychain.stored(id) == maximum)
    keychain.readResults([.init(errSecSuccess, data: Data(repeating: 0x00, count: KeychainCodexCredentialStorage.maximumBytes + 1))])
    #expect(throws: CodexCredentialStorageError.exceedsLimit) { try storage.read(instanceID: id) }
    #expect(keychain.stored(id) == maximum, "Rejecting an oversized read must not delete or truncate the stored item.")
}

@Test func codexCredentialStorageInitialClaimIsAddOnlyAndPreservesAnExistingItem() throws {
    let keychain = FakeCodexCredentialKeychain(), storage = KeychainCodexCredentialStorage(api: keychain.api), id = UUID()
    let first = Data([0x01]), second = Data([0x02])
    #expect(try storage.createIfAbsent(first, instanceID: id))
    #expect(try !storage.createIfAbsent(second, instanceID: id))
    #expect(keychain.calls.map(\.kind) == [.add, .add])
    #expect(keychain.stored(id) == first)
    keychain.addStatuses([errSecMissingEntitlement])
    #expect(throws: CodexCredentialStorageError.unavailable) { try storage.createIfAbsent(second, instanceID: id) }
    #expect(keychain.stored(id) == first)
}

@Test func codexCredentialStorageRecoversAnAddRaceWithoutDeletingTheOtherWritersItem() throws {
    let keychain = FakeCodexCredentialKeychain(), storage = KeychainCodexCredentialStorage(api: keychain.api), id = UUID()
    keychain.updateStatuses([errSecItemNotFound, errSecSuccess]); keychain.addStatuses([errSecDuplicateItem])
    let bytes = Data([0x11, 0x22, 0x33])
    try storage.write(bytes, instanceID: id)
    #expect(keychain.calls.map(\.kind) == [.update, .add, .update])
    #expect(keychain.calls.allSatisfy { $0.key == CodexCredentialKey(instanceID: id) && $0.data == bytes })
    #expect(keychain.stored(id) == bytes)
    // No read-and-compare is implied: a later writer may atomically replace the
    // same instance. Full credential rotation is owned by the external lease.
    try storage.write(Data([0x44]), instanceID: id)
    #expect(keychain.calls.last?.kind == .update && keychain.stored(id) == Data([0x44]))
}

@Test func codexCredentialStorageBoundsRepeatedRacesAndNeverFallsBackToDelete() {
    let keychain = FakeCodexCredentialKeychain(), storage = KeychainCodexCredentialStorage(api: keychain.api), id = UUID()
    keychain.updateStatuses(Array(repeating: errSecItemNotFound, count: 10))
    keychain.addStatuses(Array(repeating: errSecDuplicateItem, count: 10))
    #expect(throws: CodexCredentialStorageError.unavailable) { try storage.write(Data([0x11]), instanceID: id) }
    #expect(keychain.calls.map(\.kind) == [.update, .add, .update, .add, .update, .add])
    #expect(keychain.calls.allSatisfy { $0.key.account == id.uuidString.lowercased() })
    #expect(keychain.stored(id) == Data([0x51]), "An unconfirmed write preserves the concurrent item; it never deletes then recreates it.")
}

@Test(arguments: [errSecInteractionNotAllowed, errSecAuthFailed, errSecMissingEntitlement, errSecParam])
func codexCredentialStorageFailsClosedOnSecurityErrorsWithoutPromptingOrRetrying(status: OSStatus) throws {
    let keychain = FakeCodexCredentialKeychain(), storage = KeychainCodexCredentialStorage(api: keychain.api), id = UUID()
    let existing = Data([0x90, 0x91]); try storage.write(existing, instanceID: id)
    keychain.readResults([.init(status)])
    #expect(throws: CodexCredentialStorageError.unavailable) { try storage.read(instanceID: id) }
    keychain.updateStatuses([status]); let beforeWrite = keychain.calls.count
    #expect(throws: CodexCredentialStorageError.unavailable) { try storage.write(Data([0x55]), instanceID: id) }
    #expect(keychain.calls.count == beforeWrite + 1 && keychain.calls.last?.kind == .update)
    keychain.deleteStatuses([status])
    #expect(throws: CodexCredentialStorageError.unavailable) { try storage.delete(instanceID: id) }
    #expect(keychain.stored(id) == existing)
    #expect(!CodexCredentialStorageError.unavailable.localizedDescription.contains(String(status)))
    #expect(keychain.calls.allSatisfy { !$0.key.allowsAuthenticationUI && !$0.key.synchronizable })
}

@Test func codexCredentialStorageRejectsSuccessWithoutBytesAndTreatsOnlyNotFoundAsAbsent() throws {
    let keychain = FakeCodexCredentialKeychain(), storage = KeychainCodexCredentialStorage(api: keychain.api), id = UUID()
    keychain.readResults([.init(errSecSuccess), .init(errSecItemNotFound), .init(errSecDecode)])
    #expect(throws: CodexCredentialStorageError.unavailable) { try storage.read(instanceID: id) }
    #expect(try storage.read(instanceID: id) == nil)
    #expect(throws: CodexCredentialStorageError.unavailable) { try storage.read(instanceID: id) }
    #expect(keychain.calls.map(\.kind) == [.read, .read, .read])
}
