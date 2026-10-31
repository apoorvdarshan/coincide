import CoincideKit
import CoincideRemoteKit
import Foundation

/// A paired phone as the Mac keeps it: never the token itself, only its SHA-256.
nonisolated struct RemotePairedDevice: Codable, Hashable, Sendable {
    var device: RemoteDevice
    var tokenHash: String
}

/// Where paired devices are kept.
protocol RemoteDeviceStorage {
    func load() -> [RemotePairedDevice]
    func save(_ devices: [RemotePairedDevice])
}

/// Paired devices in the login Keychain, as one item.
nonisolated struct KeychainRemoteDeviceStorage: RemoteDeviceStorage {
    let keychain = KeychainStore(service: CoincideIdentity.scoped("remote"))

    func load() -> [RemotePairedDevice] {
        guard let json = (try? keychain.value(for: "devices")) ?? nil else { return [] }
        return (try? JSONDecoder().decode([RemotePairedDevice].self, from: Data(json.utf8))) ?? []
    }

    func save(_ devices: [RemotePairedDevice]) {
        guard let data = try? JSONEncoder().encode(devices) else { return }
        do {
            try keychain.set(String(decoding: data, as: UTF8.self), for: "devices", label: "Coincide Remote devices")
        } catch {
            NSLog("Coincide: couldn’t save paired devices: \(error.localizedDescription)")
        }
    }
}

final class MemoryRemoteDeviceStorage: RemoteDeviceStorage {
    var devices: [RemotePairedDevice] = []
    func load() -> [RemotePairedDevice] { devices }
    func save(_ devices: [RemotePairedDevice]) { self.devices = devices }
}

/// Pairing and authentication for the remote server.
///
/// Pairing: "Pair iPhone" makes a one-time secret that the QR code carries. It expires after `secretLifetime`, works
/// once, and is thrown away after `maxFailuresPerSecret` wrong guesses. A phone that presents it gets a device id and a
/// random 256-bit token, which it keeps in its Keychain; the Mac keeps only the token's hash.
///
/// Rate limits: each address may fail pairing or authentication `maxFailuresPerWindow` times per `failureWindow`, and
/// all addresses together `maxGlobalFailuresPerWindow` times, before further attempts are refused without checking.
@MainActor
final class RemotePairing {
    struct Secret {
        var value: String
        var expiresAt: Date
        var failures = 0
    }

    static let secretLifetime: TimeInterval = 5 * 60
    static let maxFailuresPerSecret = 5
    static let failureWindow: TimeInterval = 60
    static let maxFailuresPerWindow = 5
    static let maxGlobalFailuresPerWindow = 20

    private let storage: RemoteDeviceStorage
    private let now: () -> Date
    private(set) var secret: Secret?
    private(set) var devices: [RemotePairedDevice]
    private var failures: [String: [Date]] = [:]
    private var globalFailures: [Date] = []
    /// Called after devices change, such as a phone pairing or being revoked.
    var onChange: (() -> Void)?

    init(storage: RemoteDeviceStorage, now: @escaping () -> Date = Date.init) {
        self.storage = storage
        self.now = now
        devices = storage.load()
    }

    var pairedDevices: [RemoteDevice] { devices.map(\.device).sorted { $0.pairedAt > $1.pairedAt } }

    /// A new one-time secret, replacing any earlier one.
    func makeSecret() -> Secret {
        let secret = Secret(value: RemoteCrypto.randomToken(bytes: 24), expiresAt: now().addingTimeInterval(Self.secretLifetime))
        self.secret = secret
        return secret
    }

    func cancelSecret() { secret = nil }

    var hasLiveSecret: Bool { secret.map { $0.expiresAt > now() } ?? false }

    /// Trades the secret for a device and its token. `peer` identifies the address for rate limiting.
    func pair(secret candidate: String, deviceName: String, peer: String) -> Result<(RemoteDevice, String), RemoteError> {
        guard !isLimited(peer) else { return .failure(RemoteError(.rateLimited, String(localized: "Too many attempts. Wait a minute and try again."))) }
        guard var current = secret, current.expiresAt > now() else {
            secret = nil
            noteFailure(peer)
            return .failure(RemoteError(.pairingFailed, String(localized: "This pairing code has expired. Show a new one on the Mac.")))
        }
        guard RemoteCrypto.constantTimeEquals(candidate, current.value) else {
            current.failures += 1
            secret = current.failures >= Self.maxFailuresPerSecret ? nil : current
            noteFailure(peer)
            return .failure(RemoteError(.pairingFailed, String(localized: "The pairing code didn’t match. Show a new one on the Mac.")))
        }
        // Single use.
        secret = nil
        let token = RemoteCrypto.randomToken(bytes: 32)
        let name = deviceName.trimmingCharacters(in: .whitespacesAndNewlines)
        let device = RemoteDevice(
            id: UUID().uuidString, name: name.isEmpty ? String(localized: "iPhone") : String(name.prefix(80)), pairedAt: now(),
            lastSeenAt: now())
        devices.append(RemotePairedDevice(device: device, tokenHash: RemoteCrypto.sha256Hex(token)))
        storage.save(devices)
        onChange?()
        return .success((device, token))
    }

    /// The device the token belongs to, or an error. A success marks the device as seen now.
    func authenticate(deviceID: String, token: String, peer: String) -> Result<RemoteDevice, RemoteError> {
        guard !isLimited(peer) else { return .failure(RemoteError(.rateLimited, String(localized: "Too many attempts. Wait a minute and try again."))) }
        let hash = RemoteCrypto.sha256Hex(token)
        guard let index = devices.firstIndex(where: { $0.device.id == deviceID }),
            RemoteCrypto.constantTimeEquals(devices[index].tokenHash, hash)
        else {
            noteFailure(peer)
            return .failure(RemoteError(.unauthorized, String(localized: "This Mac no longer knows this device. Pair it again.")))
        }
        devices[index].device.lastSeenAt = now()
        storage.save(devices)
        onChange?()
        return .success(devices[index].device)
    }

    func isPaired(_ deviceID: String) -> Bool { devices.contains { $0.device.id == deviceID } }

    func revoke(_ deviceID: String) {
        devices.removeAll { $0.device.id == deviceID }
        storage.save(devices)
        onChange?()
    }

    func revokeAll() {
        devices = []
        storage.save(devices)
        onChange?()
    }

    // MARK: Rate limiting

    func isLimited(_ peer: String) -> Bool {
        prune()
        return (failures[peer]?.count ?? 0) >= Self.maxFailuresPerWindow || globalFailures.count >= Self.maxGlobalFailuresPerWindow
    }

    private func noteFailure(_ peer: String) {
        let date = now()
        failures[peer, default: []].append(date)
        globalFailures.append(date)
    }

    private func prune() {
        let cutoff = now().addingTimeInterval(-Self.failureWindow)
        globalFailures.removeAll { $0 < cutoff }
        for (peer, dates) in failures {
            let kept = dates.filter { $0 >= cutoff }
            failures[peer] = kept.isEmpty ? nil : kept
        }
    }
}
