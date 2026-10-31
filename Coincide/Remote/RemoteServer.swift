import CoincideKit
import CoincideRemoteKit
import Foundation
import Network
import Observation

/// Coincide Remote's settings on this Mac, in `remote.json` beside the store's data.
nonisolated struct RemoteSettings: Codable, Equatable, Sendable {
    /// Off by default: nothing listens until the user turns it on in Settings › General › Remote.
    var isEnabled = false
    /// The port last listened on, reused so saved connections keep working.
    var port: UInt16?
    /// Identifies this Mac to phones, on Bonjour and in their saved connections.
    var serverID = UUID().uuidString

    static func load(from directory: URL) -> RemoteSettings {
        let url = directory.appendingPathComponent("remote.json")
        guard let data = try? Data(contentsOf: url), let settings = try? JSONDecoder().decode(RemoteSettings.self, from: data) else {
            return RemoteSettings()
        }
        return settings
    }

    func save(to directory: URL) {
        let url = directory.appendingPathComponent("remote.json")
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try JSONEncoder().encode(self).write(to: url, options: .atomic)
        } catch {
            NSLog("Coincide: couldn’t save remote settings: \(error.localizedDescription)")
        }
    }
}

/// The server Coincide Remote connects to: a TLS WebSocket listener on the local network (and Tailscale), advertised
/// with Bonjour. It runs inside the app only while Remote is turned on, and the Mac works the same with or without
/// phones connected; everything a phone does goes through `RemoteStoreAdapter`.
@MainActor
@Observable
final class RemoteServer {
    static let shared = RemoteServer()

    enum Status: Equatable {
        case off
        case starting
        case running(port: UInt16)
        case failed(String)
    }

    private(set) var settings: RemoteSettings
    private(set) var status = Status.off
    private(set) var devices: [RemoteDevice] = []
    /// Where phones can reach this Mac.
    private(set) var candidates: [RemoteHostCandidate] = []
    private(set) var fingerprint: String?
    /// The pairing code on screen, until it's used or expires.
    private(set) var pairingPayload: RemotePairingPayload?
    /// The device that paired last, so the QR sheet can say so and close.
    private(set) var lastPairedDevice: RemoteDevice?
    private(set) var connectedDeviceIDs: Set<String> = []
    /// Paired phones with lock-screen alerts turned on, by device id, as they last reported. Kept across launches in
    /// `remote-alerts.json`, since the alerts are for when the phone isn't connected.
    private(set) var alertTargets: [String: PushTarget] = [:]

    @ObservationIgnored private let directory: URL
    @ObservationIgnored private lazy var pairing: RemotePairing = {
        let pairing = RemotePairing(storage: KeychainRemoteDeviceStorage())
        pairing.onChange = { [weak self] in self?.devicesChanged() }
        return pairing
    }()
    @ObservationIgnored private lazy var adapter = RemoteStoreAdapter()
    @ObservationIgnored private var listener: NWListener?
    @ObservationIgnored private var identity: RemoteIdentity?
    @ObservationIgnored private var connections: [ObjectIdentifier: RemoteConnection] = [:]
    @ObservationIgnored private var tailscaleName: String?
    @ObservationIgnored private var addressTimer: Timer?

    /// At most this many phones at once, counting connections still authenticating.
    static let maxConnections = 12

    init(directory: URL = AppStore.shared.directory) {
        self.directory = directory
        settings = RemoteSettings.load(from: directory)
        if let data = try? Data(contentsOf: directory.appendingPathComponent(Self.alertsFile)),
            let saved = try? JSONDecoder().decode([String: PushTarget].self, from: data)
        {
            alertTargets = saved
        }
    }

    private static let alertsFile = "remote-alerts.json"

    var isEnabled: Bool { settings.isEnabled }

    /// Starts the server when Remote is on. Called once at launch.
    func startIfEnabled() {
        guard settings.isEnabled else { return }
        start()
    }

    func setEnabled(_ enabled: Bool) {
        guard enabled != settings.isEnabled else { return }
        settings.isEnabled = enabled
        settings.save(to: directory)
        if enabled { start() } else { stop() }
    }

    // MARK: Listening

    private func start() {
        guard listener == nil else { return }
        status = .starting
        devices = pairing.pairedDevices
        do {
            let identity = try RemoteIdentity.loadOrCreate()
            self.identity = identity
            fingerprint = identity.fingerprint
            try listen(identity: identity, port: settings.port ?? RemoteProtocol.defaultPort)
        } catch {
            status = .failed(error.localizedDescription)
        }
        refreshAddresses()
        addressTimer?.invalidate()
        // Addresses change as the Mac moves between networks or Tailscale connects.
        addressTimer = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.refreshAddresses()
                self?.sendMacPresence()
            }
        }
    }

    private func listen(identity: RemoteIdentity, port: UInt16) throws {
        let tls = NWProtocolTLS.Options()
        guard let secIdentity = sec_identity_create(identity.identity) else { throw RemoteIdentityError.invalidCertificate }
        sec_protocol_options_set_local_identity(tls.securityProtocolOptions, secIdentity)
        sec_protocol_options_set_min_tls_protocol_version(tls.securityProtocolOptions, .TLSv13)
        let tcp = NWProtocolTCP.Options()
        tcp.enableKeepalive = true
        tcp.keepaliveIdle = 30
        let parameters = NWParameters(tls: tls, tcp: tcp)
        let websocket = NWProtocolWebSocket.Options()
        websocket.autoReplyPing = true
        websocket.maximumMessageSize = RemoteProtocol.maxMessageBytes
        parameters.defaultProtocolStack.applicationProtocols.insert(websocket, at: 0)
        parameters.includePeerToPeer = false
        let listener = try NWListener(using: parameters, on: NWEndpoint.Port(rawValue: port) ?? .any)
        listener.service = NWListener.Service(
            name: RemoteAddresses.computerName, type: RemoteProtocol.serviceType,
            txtRecord: NWTXTRecord(["id": settings.serverID, "v": "\(RemoteProtocol.version)"]))
        listener.stateUpdateHandler = { [weak self, weak listener] state in
            MainActor.assumeIsolated {
                guard let self, let listener, listener === self.listener else { return }
                self.listenerChanged(state, requestedPort: port)
            }
        }
        listener.newConnectionHandler = { [weak self] connection in
            MainActor.assumeIsolated { self?.accept(connection) }
        }
        self.listener = listener
        listener.start(queue: .main)
    }

    private func listenerChanged(_ state: NWListener.State, requestedPort: UInt16) {
        switch state {
        case .ready:
            let port = listener?.port?.rawValue ?? requestedPort
            status = .running(port: port)
            if settings.port != port {
                settings.port = port
                settings.save(to: directory)
            }
        case .failed(let error):
            listener?.cancel()
            listener = nil
            // The usual port is taken (another copy of Coincide, say): listen on any port and remember it.
            if case .posix(.EADDRINUSE) = error, requestedPort != 0, let identity {
                do { try listen(identity: identity, port: 0) } catch { status = .failed(error.localizedDescription) }
            } else {
                status = .failed(error.localizedDescription)
            }
        default:
            break
        }
    }

    func stop() {
        addressTimer?.invalidate()
        addressTimer = nil
        listener?.cancel()
        listener = nil
        for connection in connections.values { connection.session?.close() }
        connections = [:]
        connectedDeviceIDs = []
        pairingPayload = nil
        pairing.cancelSecret()
        status = .off
    }

    private func accept(_ connection: NWConnection) {
        let wrapper = RemoteConnection(connection)
        // Local network and Tailscale only.
        guard connections.count < Self.maxConnections, RemoteAddresses.isAllowedPeer(wrapper.peer) else {
            connection.cancel()
            return
        }
        let session = RemoteSession(transport: wrapper, adapter: adapter, pairing: pairing) { [weak self] in
            self?.serverInfo ?? RemoteServerInfo(serverID: "", name: "", appVersion: "")
        }
        wrapper.session = session
        session.onClose = { [weak self, weak wrapper] _ in
            guard let self, let wrapper else { return }
            self.connections[ObjectIdentifier(wrapper)] = nil
            self.updateConnectedDevices()
        }
        session.onPaired = { [weak self] device in
            self?.pairingPayload = nil
            self?.lastPairedDevice = device
        }
        session.onPresence = { [weak self] session, presence in
            guard let self, let deviceID = session.deviceID else { return }
            self.updateAlertTarget(deviceID, zone: presence.alertZone)
        }
        wrapper.onAuthenticated = { [weak self] in self?.updateConnectedDevices() }
        connections[ObjectIdentifier(wrapper)] = wrapper
        session.start()
        wrapper.start()
    }

    private var serverInfo: RemoteServerInfo {
        adapter.serverInfo(serverID: settings.serverID, name: RemoteAddresses.computerName)
    }

    private func updateConnectedDevices() {
        connectedDeviceIDs = Set(connections.values.compactMap { $0.session?.deviceID })
    }

    // MARK: Alerts

    /// What connected phones last said about themselves.
    var devicePresences: [DevicePresence] {
        connections.values.compactMap { $0.session?.presence }
    }

    /// Phones that may get lock-screen alerts; none while Remote is off.
    var pushTargets: [PushTarget] {
        guard settings.isEnabled else { return [] }
        return alertTargets.values.filter { pairing.isPaired($0.deviceID) }
    }

    /// Sends an alert to the device's live connections. False when none can take it.
    func deliver(_ notification: RemoteNotification, to deviceID: String) -> Bool {
        var delivered = false
        for connection in connections.values {
            guard let session = connection.session, session.deviceID == deviceID else { continue }
            if session.deliver(notification) { delivered = true }
        }
        return delivered
    }

    /// Tells connected phones whether the user is at this Mac (every half minute, with the address check), so they post
    /// no notifications of their own meanwhile.
    func sendMacPresence() {
        guard !connections.isEmpty else { return }
        let presence = MacActivity.current(visibleThreadID: nil).remote
        for connection in connections.values { connection.session?.sendMacPresence(presence) }
    }

    /// Tells connected phones the user saw the thread.
    func clearNotifications(_ threadID: UUID) {
        guard !connections.isEmpty else { return }
        adapter.clearNotifications(threadID)
    }

    private func updateAlertTarget(_ deviceID: String, zone: String?) {
        let updated = zone.map { PushTarget(deviceID: deviceID, zone: $0, lastActiveAt: Date()) }
        guard alertTargets[deviceID] != updated else { return }
        // A heartbeat only moves the time; save it at most every few minutes.
        if let updated, let old = alertTargets[deviceID], old.zone == updated.zone,
            updated.lastActiveAt.timeIntervalSince(old.lastActiveAt) < 300
        {
            alertTargets[deviceID]?.lastActiveAt = updated.lastActiveAt
            return
        }
        alertTargets[deviceID] = updated
        saveAlertTargets()
    }

    private func saveAlertTargets() {
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try JSONEncoder().encode(alertTargets).write(to: directory.appendingPathComponent(Self.alertsFile), options: .atomic)
        } catch {
            NSLog("Coincide: couldn’t save lock-screen alert settings: \(error.localizedDescription)")
        }
    }

    // MARK: Pairing

    /// Shows a new pairing code, valid for a few minutes and for one phone.
    func beginPairing() {
        guard case .running(let port) = status, let fingerprint else { return }
        let secret = pairing.makeSecret()
        lastPairedDevice = nil
        pairingPayload = RemotePairingPayload(
            serverID: settings.serverID, name: RemoteAddresses.computerName, hosts: candidates, port: port,
            fingerprint: fingerprint, secret: secret.value, expiresAt: secret.expiresAt)
    }

    func cancelPairing() {
        pairing.cancelSecret()
        pairingPayload = nil
    }

    func revoke(_ deviceID: String) {
        pairing.revoke(deviceID)
    }

    /// Makes a new certificate and forgets every paired device, which then pair again.
    func resetIdentity() {
        let wasRunning = listener != nil
        stop()
        pairing.revokeAll()
        RemoteIdentity.reset()
        identity = nil
        fingerprint = nil
        if wasRunning { start() }
    }

    private func devicesChanged() {
        devices = pairing.pairedDevices
        let stale = alertTargets.keys.filter { !pairing.isPaired($0) }
        if !stale.isEmpty {
            for id in stale { alertTargets[id] = nil }
            saveAlertTargets()
        }
        for connection in connections.values {
            guard let session = connection.session, let deviceID = session.deviceID, !pairing.isPaired(deviceID) else { continue }
            session.revoke()
        }
        updateConnectedDevices()
    }

    // MARK: Addresses

    func refreshAddresses() {
        candidates = RemoteAddresses.candidates(tailscaleName: tailscaleName)
        Task {
            let name = await RemoteAddresses.tailscaleDNSName()
            guard name != tailscaleName else { return }
            tailscaleName = name
            candidates = RemoteAddresses.candidates(tailscaleName: name)
        }
    }
}

/// A phone's WebSocket, handed to its session. Runs on the main queue, as the session and the store do.
@MainActor
final class RemoteConnection: RemoteTransport {
    private let connection: NWConnection
    var session: RemoteSession?
    var onAuthenticated: (() -> Void)?
    private var wasAuthenticated = false
    private var closing = false

    let peer: String

    init(_ connection: NWConnection) {
        self.connection = connection
        switch connection.endpoint {
        case .hostPort(let host, _): peer = "\(host)"
        default: peer = "\(connection.endpoint)"
        }
    }

    func start() {
        connection.stateUpdateHandler = { [weak self] state in
            MainActor.assumeIsolated {
                switch state {
                case .ready: self?.receive()
                case .failed, .cancelled: self?.session?.close()
                default: break
                }
            }
        }
        connection.start(queue: .main)
    }

    private func receive() {
        connection.receiveMessage { [weak self] content, context, _, error in
            MainActor.assumeIsolated {
                guard let self else { return }
                if error != nil {
                    self.session?.close()
                    return
                }
                let metadata = context?.protocolMetadata(definition: NWProtocolWebSocket.definition) as? NWProtocolWebSocket.Metadata
                if metadata?.opcode == .close {
                    self.session?.close()
                    return
                }
                if let content, metadata?.opcode == .text || metadata?.opcode == .binary {
                    self.session?.receive(content)
                    if !self.wasAuthenticated, self.session?.deviceID != nil {
                        self.wasAuthenticated = true
                        self.onAuthenticated?()
                    }
                }
                if self.session?.state != .closed { self.receive() }
            }
        }
    }

    func send(_ data: Data) {
        guard !closing else { return }
        let metadata = NWProtocolWebSocket.Metadata(opcode: .text)
        let context = NWConnection.ContentContext(identifier: "message", metadata: [metadata])
        connection.send(content: data, contentContext: context, isComplete: true, completion: .idempotent)
    }

    /// Sends a close frame after what's queued, then hangs up.
    func close() {
        guard !closing else { return }
        closing = true
        let metadata = NWProtocolWebSocket.Metadata(opcode: .close)
        metadata.closeCode = .protocolCode(.normalClosure)
        let context = NWConnection.ContentContext(identifier: "close", metadata: [metadata])
        connection.send(content: nil, contentContext: context, isComplete: true, completion: .contentProcessed { [connection] _ in
            connection.cancel()
        })
    }
}
