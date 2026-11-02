import CoincideRemoteKit
import Foundation
import Network
import Observation
import UIKit

/// The connection to one Mac and everything it reported: the sidebar, the open threads, the theme.
///
/// Connecting tries the Mac's addresses in order (the Bonjour service if it's on this network, the address that worked
/// last, local network addresses, then Tailscale) and authenticates with the token from pairing. A dropped connection
/// is retried with backoff and as soon as the app comes back to the foreground; while offline the last state stays
/// on screen, marked as such. A launch, a return to the app and a connection the system dropped reconnect quietly
/// (`RemoteReconnect`): nothing says "Connecting" or "Offline" unless that takes longer than the grace period
/// (`shownPhase`).
@MainActor
@Observable
final class RemoteClient {
    enum Phase: Equatable {
        case idle
        case connecting(String)
        case connected(String)
        case offline(String)
        /// The Mac no longer accepts this device (revoked or reset); pair again.
        case needsPairing(String)
    }

    private(set) var phase = Phase.idle
    /// The demo from the Connect screen is on screen (`startDemo()`): its banner shows, and nothing reaches a Mac.
    private(set) var isExploringDemo = false
    /// Within a quiet reconnect's grace period, or in the background (`RemoteReconnect.isQuiet`).
    private var isQuiet = false
    /// The phase when the quiet began, if the Mac was connected; what the screen goes on showing meanwhile.
    private var phaseBeforeQuiet: Phase?
    private(set) var mac: SavedMac?
    private(set) var server: RemoteServerInfo?
    /// The Mac's Settings, once asked for; they stay current through `settings` events.
    private(set) var macSettings: RemoteSettingsSnapshot?
    /// The Mac is too old to share its Settings.
    private(set) var macSettingsUnsupported = false
    var workspace = RemoteWorkspace()
    var includesArchived = false {
        didSet { if includesArchived != oldValue { Task { await refreshWorkspace() } } }
    }
    /// Threads open on screen, kept across layout changes so their scroll position and state survive.
    private(set) var threads: [UUID: ThreadModel] = [:]
    /// Unsent messages per thread.
    var drafts: [UUID: ComposerDraft] = [:]
    /// A message to show briefly, such as a failed action.
    var notice: String?
    /// Whether the user is at the Mac, as it last said, and when: while they are, alerts stay off this phone.
    @ObservationIgnored private(set) var macPresence: RemoteMacPresence?
    @ObservationIgnored private(set) var macPresenceReceivedAt: Date?
    /// Projects expanded or collapsed on this phone, kept for a Mac that doesn't remember it.
    private var localExpansion: [UUID: Bool] = RemoteClient.savedExpansion()
    /// Projects whose change the Mac hasn't confirmed yet, so an older snapshot doesn't undo it meanwhile.
    private var expansionInFlight: Set<UUID> = []

    let bonjour = BonjourBrowser()
    /// Image previews the Mac sent, within a memory budget.
    @ObservationIgnored let media = MediaCache()
    @ObservationIgnored private let saved = SavedMacs.shared
    @ObservationIgnored private var socket: RemoteSocket?
    @ObservationIgnored private var pending: [String: CheckedContinuation<RemoteResult, Error>] = [:]
    @ObservationIgnored private var connectTask: Task<Void, Never>?
    @ObservationIgnored private var receiveTask: Task<Void, Never>?
    @ObservationIgnored private var retryTask: Task<Void, Never>?
    @ObservationIgnored private var reconnect = RemoteReconnect()
    /// Ends `isQuiet` when the grace period does.
    @ObservationIgnored private var quietTask: Task<Void, Never>?
    @ObservationIgnored private var generation = 0

    /// What this phone reports about itself (`RemotePresence`); set by the app.
    @ObservationIgnored var presenceSource: (() -> RemotePresence)?
    /// An alert the Mac sent, and a thread the user saw somewhere.
    @ObservationIgnored var onNotify: ((RemoteNotification) -> Void)?
    @ObservationIgnored var onClearNotifications: ((UUID) -> Void)?
    /// Called after pairing with a Mac, the moment to ask for notification permission.
    @ObservationIgnored var onPaired: ((RemoteServerInfo) -> Void)?
    /// When the user last touched the app.
    @ObservationIgnored private(set) var lastInteraction = Date()
    @ObservationIgnored private var lastPresenceSentAt: Date?
    /// The Mac answered `presence` with `unsupported`: it's older than notification routing.
    @ObservationIgnored private var macIgnoresPresence = false

    var isConnected: Bool {
        if case .connected = phase { return true }
        return false
    }

    /// The phase the screen shows. While a reconnect is quiet (`RemoteReconnect`) it goes on showing what it did
    /// before: the Mac connected, or nil, nothing yet, when it wasn't (at launch, or after it went offline). So a quick
    /// reconnect on coming back to the app goes unseen while the last workspace stays on screen.
    var shownPhase: Phase? {
        guard isQuiet else { return phase }
        switch phase {
        case .connecting, .offline: return phaseBeforeQuiet
        case .idle, .connected, .needsPairing: return phase
        }
    }

    /// Whether the screen shows the Mac connected (`shownPhase`). Actions still wait for `isConnected`.
    var showsConnected: Bool {
        if case .connected = shownPhase { return true }
        return false
    }

    var savedMacs: [SavedMac] {
        if DemoData.isEnabled { return DemoData.isUnpaired && !DemoData.isExploring ? [] : [DemoData.mac] }
        return saved.all.sorted { ($0.lastConnectedAt ?? $0.pairedAt) > ($1.lastConnectedAt ?? $1.pairedAt) }
    }

    init() {
        #if DEBUG
        if DemoData.isEnabled {
            if DemoData.isUnpaired { return }
            mac = DemoData.mac
            server = DemoData.server
            workspace = DemoData.workspace
            phase = DemoData.phase
            macSettings = DemoData.isEmpty ? nil : DemoData.macSettings
            if DemoData.has("Attachments") {
                drafts[DemoData.threadID] = ComposerDraft(text: "Match these two screens", images: DemoData.draftImages)
            }
            return
        }
        // Pairs on launch with a code passed as `-CoincideRemotePair <code>`, for testing in the simulator.
        let arguments = ProcessInfo.processInfo.arguments
        if let index = arguments.firstIndex(of: "-CoincideRemotePair"), index + 1 < arguments.count,
            let payload = RemotePairingPayload.decode(arguments[index + 1])
        {
            bonjour.start()
            Task { try? await pair(payload) }
            return
        }
        #endif
        bonjour.start()
        // A launch connects quietly, as a return to the app does.
        if let id = saved.lastUsedID, let mac = saved.all.first(where: { $0.serverID == id }) ?? saved.all.first {
            connect(to: mac, quietly: true)
        } else if let mac = saved.all.first {
            connect(to: mac, quietly: true)
        }
    }

    // MARK: Connecting

    /// Connects to a Mac. As when the user picks it, "Connecting" shows at once; `quietly`, as at launch, nothing shows
    /// unless it takes longer than the grace period.
    func connect(to mac: SavedMac, quietly: Bool = false) {
        // The demo's Mac isn't there to connect to.
        if DemoData.isEnabled { return }
        if self.mac?.serverID != mac.serverID {
            threads = [:]
            workspace = RemoteWorkspace()
            server = nil
            media.clear()
        }
        self.mac = mac
        saved.lastUsedID = mac.serverID
        if quietly { reconnect.connectingQuietly(at: Date()) } else { reconnect.showNow() }
        updateQuiet()
        start()
    }

    /// Tries again now at the user's request (Try Again, Reconnect): "Connecting" shows at once.
    func reconnectIfNeeded() {
        if DemoData.isEnabled { return }
        guard mac != nil else { return }
        switch phase {
        case .offline, .idle:
            reconnect.showNow()
            updateQuiet()
            start()
        default:
            break
        }
    }

    /// The app came to the front. Back from the background it reconnects at once and quietly: iOS rarely keeps the
    /// socket through a suspension, and an attempt from before it may be waiting on a dead one. After a moment inactive
    /// (Control Center, a system alert) the socket is as it was: a Mac that's offline is tried again, and that shows.
    func becameActive() {
        if DemoData.isEnabled { return }
        let wasAway = reconnect.isInBackground
        reconnect.becameActive(at: Date())
        updateQuiet()
        guard mac != nil else { return }
        switch phase {
        case .offline, .idle: start()
        case .connecting where wasAway: start()
        case .connecting, .connected, .needsPairing: break
        }
    }

    /// The app went to the background: whatever the connection does meanwhile stays off screen until it's back.
    func enteredBackground() {
        if DemoData.isEnabled { return }
        reconnect.enteredBackground()
        updateQuiet()
    }

    func disconnect() {
        generation += 1
        connectTask?.cancel()
        retryTask?.cancel()
        receiveTask?.cancel()
        socket?.cancel()
        socket = nil
        failPending(RemoteError(.failed, String(localized: "Disconnected.")))
        reconnect.showNow()
        updateQuiet()
        phase = .idle
    }

    func forget(_ serverID: String) {
        if mac?.serverID == serverID {
            disconnect()
            mac = nil
            workspace = RemoteWorkspace()
            threads = [:]
            server = nil
        }
        saved.remove(serverID)
        if mac == nil, let next = savedMacs.first { connect(to: next) }
    }

    /// Adds an address to try, such as a Tailscale name the pairing code didn't have.
    func addHost(_ host: String, to serverID: String) {
        guard var mac = saved.all.first(where: { $0.serverID == serverID }) else { return }
        let trimmed = host.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !mac.hosts.contains(where: { $0.host == trimmed }) else { return }
        mac.hosts.append(RemoteHostCandidate(host: trimmed, kind: .manual))
        saved.save(mac)
        if self.mac?.serverID == serverID { self.mac = mac }
    }

    // MARK: The demo

    /// Opens the demo (`DemoData`): a sample Mac with projects, threads and bots, for App Review and anyone without their
    /// Mac at hand. Nothing in it reaches a Mac or the network (`request`); Coincide Pro and tips are the App Store's own.
    func startDemo() {
        disconnect()
        bonjour.stop()
        DemoData.isExploring = true
        isExploringDemo = true
        threads = [:]
        drafts = [:]
        media.clear()
        notice = nil
        mac = DemoData.mac
        server = DemoData.server
        workspace = DemoData.workspace
        macSettings = DemoData.macSettings
        macSettingsUnsupported = false
        phase = DemoData.phase
    }

    /// Leaves the demo for the Connect screen, or for the Mac used last when one is paired.
    func endDemo() {
        guard isExploringDemo else { return }
        DemoData.isExploring = false
        isExploringDemo = false
        threads = [:]
        drafts = [:]
        media.clear()
        notice = nil
        mac = nil
        server = nil
        workspace = RemoteWorkspace()
        macSettings = nil
        phase = .idle
        // A screenshot launch (`-CoincideRemoteDemo`) has no Macs to look for.
        if DemoData.isEnabled { return }
        bonjour.start()
        if let id = saved.lastUsedID, let mac = saved.all.first(where: { $0.serverID == id }) ?? saved.all.first {
            connect(to: mac)
        } else if let mac = saved.all.first {
            connect(to: mac)
        }
    }

    private func start() {
        guard let mac else { return }
        generation += 1
        let generation = generation
        connectTask?.cancel()
        retryTask?.cancel()
        receiveTask?.cancel()
        socket?.cancel()
        socket = nil
        guard let token = saved.token(for: mac.serverID) else {
            reconnect.showNow()
            updateQuiet()
            phase = .needsPairing(String(localized: "Pair this device with \(mac.name) again."))
            return
        }
        phase = .connecting(mac.name)
        connectTask = Task {
            let outcome = await self.establish(mac: mac, token: token, generation: generation)
            guard generation == self.generation else { return }
            switch outcome {
            case .connected:
                break
            case .rejected(let message):
                self.saved.deleteToken(for: mac.serverID)
                self.reconnect.showNow()
                self.updateQuiet()
                self.phase = .needsPairing(message)
            case .unreachable(let message, let transient):
                self.retry(transient: transient, message: message)
            }
        }
    }

    private enum Outcome {
        case connected
        case rejected(String)
        /// `transient`: the last address failed the way a suspension or a network change makes it fail.
        case unreachable(String, transient: Bool)
    }

    /// After a dropped connection or a failed attempt: again at once, and quietly, when the system dropped it
    /// (`RemoteReconnect.failed`); otherwise offline until the next try.
    private func retry(transient: Bool, message: String) {
        switch reconnect.failed(transient: transient, at: Date()) {
        case .retryNow:
            updateQuiet()
            start()
        case .retry(let delay):
            phase = .offline(message)
            scheduleRetry(after: delay)
        }
    }

    /// Brings `isQuiet` up to date, and ends it when the grace period does.
    private func updateQuiet() {
        let now = Date()
        let quiet = reconnect.isQuiet(at: now)
        if quiet != isQuiet {
            if quiet { phaseBeforeQuiet = isConnected ? phase : nil }
            isQuiet = quiet
        }
        quietTask?.cancel()
        quietTask = nil
        guard let remaining = reconnect.quietRemaining(at: now) else { return }
        quietTask = Task {
            try? await Task.sleep(for: .seconds(remaining))
            guard !Task.isCancelled else { return }
            self.updateQuiet()
        }
    }

    /// Addresses in the order to try them.
    private func targets(for mac: SavedMac) async -> [(String, UInt16)] {
        var result: [(String, UInt16)] = []
        if let found = bonjour.mac(serverID: mac.serverID), let resolved = await RemoteServiceResolver.resolve(found.endpoint) {
            result.append(resolved)
        }
        if let last = mac.lastHost { result.append((last, mac.port)) }
        for candidate in mac.hosts.sorted(by: { $0.kind < $1.kind }) { result.append((candidate.host, mac.port)) }
        var seen = Set<String>()
        return result.filter { seen.insert("\($0.0):\($0.1)").inserted }
    }

    private func establish(mac: SavedMac, token: String, generation: Int) async -> Outcome {
        // What a socket failure says: where to look. Network's own wording would read as an error code.
        let unreachable = String(localized: "\(mac.name) isn’t reachable. Make sure Coincide is open with Remote turned on.")
        var lastError = unreachable
        var transient = false
        for (host, port) in await targets(for: mac) {
            guard generation == self.generation, !Task.isCancelled else {
                return .unreachable(lastError, transient: transient)
            }
            let socket = RemoteSocket(target: .host(host, port: port), fingerprint: mac.fingerprint)
            switch await open(socket, generation: generation) {
            case .failure(let error):
                if error == .certificateMismatch {
                    return .rejected(error.message)
                }
                lastError = unreachable
                transient = error.isTransient
                continue
            case .success:
                break
            }
            guard generation == self.generation else {
                socket.cancel()
                return .unreachable(lastError, transient: transient)
            }
            do {
                let result = try await request(
                    .hello(RemoteHello(deviceID: mac.deviceID, token: token, appVersion: Self.appVersion)), timeout: .seconds(8))
                guard case .server(let info) = result else { throw RemoteError(.failed, String(localized: "Unexpected reply.")) }
                server = info
                var updated = mac
                updated.lastHost = host
                updated.lastConnectedAt = Date()
                updated.name = info.name
                saved.save(updated)
                self.mac = updated
                phase = .connected(info.name)
                reconnect.connected(at: Date())
                updateQuiet()
                macIgnoresPresence = false
                sendPresence()
                await refreshAfterConnecting()
                return .connected
            } catch let error as RemoteError where error.code == .unauthorized {
                socket.cancel()
                return .rejected(error.message)
            } catch {
                socket.cancel()
                // The Mac's own answer (or ours, such as no answer in time) says what happened; anything else doesn't.
                lastError = (error as? RemoteError)?.message ?? unreachable
                transient = false
            }
        }
        return .unreachable(lastError, transient: transient)
    }

    /// Connects the socket and starts reading from it; returns once it's connected or has failed. A socket's events
    /// have one reader, which stays for the life of the connection.
    private func open(_ socket: RemoteSocket, generation: Int) async -> Result<Void, RemoteSocketError> {
        let opening = Opening()
        let timeout = Task {
            try? await Task.sleep(for: .seconds(7))
            // Cancelled once the socket connected or failed.
            guard !Task.isCancelled else { return }
            socket.cancel()
        }
        defer { timeout.cancel() }
        return await withCheckedContinuation { continuation in
            opening.continuation = continuation
            receiveTask?.cancel()
            receiveTask = Task {
                for await event in socket.events {
                    switch event {
                    case .ready:
                        self.socket = socket
                        opening.resume(.success(()))
                    case .message(let data):
                        guard generation == self.generation else { continue }
                        self.receive(data)
                    case .closed(let error):
                        if opening.isWaiting {
                            opening.resume(.failure(error ?? .transport(String(localized: "Couldn’t connect."))))
                        } else {
                            self.closed(error, generation: generation)
                        }
                    }
                }
                // Stopped by a newer attempt (`start`) before the socket opened: close it, and end the wait for it.
                if opening.isWaiting {
                    socket.cancel()
                    opening.resume(.failure(.transport("cancelled")))
                }
            }
            socket.start()
        }
    }

    @MainActor
    private final class Opening {
        var continuation: CheckedContinuation<Result<Void, RemoteSocketError>, Never>?
        var isWaiting: Bool { continuation != nil }

        func resume(_ result: Result<Void, RemoteSocketError>) {
            continuation?.resume(returning: result)
            continuation = nil
        }
    }

    private func closed(_ error: RemoteSocketError?, generation: Int) {
        guard generation == self.generation else { return }
        socket = nil
        failPending(RemoteError(.failed, String(localized: "The connection to the Mac was lost.")))
        guard case .connected = phase else { return }
        // No error: the connection was cancelled underneath, which only the system does.
        retry(transient: error?.isTransient ?? true, message: String(localized: "The connection to the Mac was lost."))
    }

    private func scheduleRetry(after delay: TimeInterval) {
        retryTask?.cancel()
        retryTask = Task {
            try? await Task.sleep(for: .seconds(delay))
            guard !Task.isCancelled else { return }
            self.start()
        }
    }

    private func refreshAfterConnecting() async {
        await refreshWorkspace()
        for id in threads.keys { await load(id) }
    }

    // MARK: Pairing

    /// Pairs with the Mac in a scanned code, saves it and connects. Throws with a message to show.
    func pair(_ payload: RemotePairingPayload) async throws {
        guard payload.expiresAt > Date() else {
            throw RemoteError(.pairingFailed, String(localized: "This pairing code has expired. Show a new one on the Mac."))
        }
        endDemo()
        disconnect()
        let generation = generation
        var lastError = String(localized: "Couldn’t reach \(payload.name). Make sure this device is on the same network or on Tailscale.")
        var candidates: [(String, UInt16)] = []
        if let found = bonjour.mac(serverID: payload.serverID), let resolved = await RemoteServiceResolver.resolve(found.endpoint) {
            candidates.append(resolved)
        }
        candidates += payload.hosts.sorted { $0.kind < $1.kind }.map { ($0.host, payload.port) }
        for (host, port) in candidates {
            let socket = RemoteSocket(target: .host(host, port: port), fingerprint: payload.fingerprint)
            if case .failure(let error) = await open(socket, generation: generation) {
                // Only the pin failing says more than where to look.
                if error == .certificateMismatch { lastError = error.message }
                continue
            }
            phase = .connecting(payload.name)
            do {
                let result = try await request(
                    .pair(RemotePairRequest(secret: payload.secret, deviceName: UIDevice.current.name)), timeout: .seconds(10))
                guard case .paired(let paired) = result else { throw RemoteError(.failed, String(localized: "Unexpected reply.")) }
                saved.setToken(paired.token, for: payload.serverID)
                let mac = SavedMac(
                    serverID: payload.serverID, name: paired.server.name, hosts: payload.hosts, port: payload.port,
                    fingerprint: payload.fingerprint, deviceID: paired.deviceID, lastHost: host, pairedAt: Date(),
                    lastConnectedAt: Date())
                saved.save(mac)
                saved.lastUsedID = mac.serverID
                threads = [:]
                self.mac = mac
                server = paired.server
                phase = .connected(paired.server.name)
                reconnect.connected(at: Date())
                updateQuiet()
                macIgnoresPresence = false
                sendPresence()
                onPaired?(paired.server)
                await refreshAfterConnecting()
                return
            } catch let error as RemoteError {
                socket.cancel()
                self.socket = nil
                phase = .idle
                // A wrong or expired secret won't work at another address either.
                if error.code == .pairingFailed || error.code == .rateLimited { throw error }
                lastError = error.message
            }
        }
        phase = .idle
        if let mac { connect(to: mac) }
        throw RemoteError(.failed, lastError)
    }

    // MARK: Requests

    static var appVersion: String { Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0" }

    @discardableResult
    func request(_ request: RemoteRequest, timeout: Duration = .seconds(30)) async throws -> RemoteResult {
        // Whatever the Mac would act on needs Coincide Pro; without it the paywall shows instead (`ProGate`).
        if request.needsPro, !ProGate.allows() {
            throw RemoteError(.failed, String(localized: "Coincide Pro unlocks this."))
        }
        // The demo answers for its Mac, so nothing leaves the phone.
        if DemoData.isEnabled { return try DemoData.result(for: request) }
        guard let socket else { throw RemoteError(.failed, String(localized: "Not connected to the Mac.")) }
        let message = RemoteClientMessage(request: request)
        let data = try RemoteProtocol.makeEncoder().encode(message)
        let id = message.id
        let timer = Task {
            try? await Task.sleep(for: timeout)
            guard !Task.isCancelled else { return }
            self.finish(id, .failure(RemoteError(.failed, String(localized: "The Mac didn’t answer in time."))))
        }
        defer { timer.cancel() }
        return try await withCheckedThrowingContinuation { continuation in
            pending[id] = continuation
            socket.send(data)
        }
    }

    /// Runs a request and shows its error, if any, as a notice.
    @discardableResult
    func perform(_ request: RemoteRequest) async -> RemoteResult? {
        do {
            return try await self.request(request)
        } catch {
            notice = (error as? RemoteError)?.message ?? error.localizedDescription
            return nil
        }
    }

    private func finish(_ id: String, _ result: Result<RemoteResult, Error>) {
        guard let continuation = pending.removeValue(forKey: id) else { return }
        continuation.resume(with: result)
    }

    private func failPending(_ error: Error) {
        let waiting = pending
        pending = [:]
        for continuation in waiting.values { continuation.resume(throwing: error) }
    }

    private func receive(_ data: Data) {
        let message: RemoteServerMessage
        do {
            message = try RemoteProtocol.makeDecoder().decode(RemoteServerMessage.self, from: data)
        } catch {
            return
        }
        switch message {
        case .response(let id, let result): finish(id, .success(result))
        case .failure(let id, let error):
            if let id { finish(id, .failure(error)) } else { notice = error.message }
        case .event(let event): handle(event)
        case .unknown: break
        }
    }

    private func handle(_ event: RemoteEvent) {
        switch event {
        case .workspace(let workspace):
            apply(workspace)
        case .server(let info):
            server = info
        case .items(let threadID, let items, let count):
            threads[threadID]?.apply(items, count: count)
        case .transcript(let transcript):
            threads[transcript.thread.id]?.apply(transcript)
        case .turn(let threadID, let state):
            threads[threadID]?.turn = state
        case .threadRemoved(let id):
            threads[id]?.isRemoved = true
        case .notify(let notification):
            onNotify?(notification)
        case .settings(let snapshot):
            macSettings = snapshot
        case .clearNotifications(let threadID):
            onClearNotifications?(threadID)
        case .macPresence(let presence):
            macPresence = presence
            macPresenceReceivedAt = Date()
        case .revoked:
            if let mac {
                saved.deleteToken(for: mac.serverID)
                disconnect()
                phase = .needsPairing(String(localized: "\(mac.name) removed this device. Pair it again to connect."))
            }
        }
    }

    private func apply(_ workspace: RemoteWorkspace) {
        self.workspace = workspace
        for thread in workspace.threads { threads[thread.id]?.summary = thread }
    }

    // MARK: Presence

    /// Tells the Mac whether the app is in front, what it shows and how long since it was touched, so the Mac sends
    /// alerts where the user is. Returns the request, for a caller that must wait for it (going to the background).
    @discardableResult
    func sendPresence() -> Task<Void, Never>? {
        guard isConnected, !DemoData.isEnabled, !macIgnoresPresence, let presence = presenceSource?() else { return nil }
        lastPresenceSentAt = Date()
        return Task {
            do {
                try await request(.presence(presence), timeout: .seconds(10))
            } catch let error as RemoteError where error.code == .unsupported {
                macIgnoresPresence = true
            } catch {}
        }
    }

    /// The user touched the app: the Mac hears about it soon, so it knows which device was used last.
    func noteInteraction() {
        lastInteraction = Date()
        if let sent = lastPresenceSentAt, Date().timeIntervalSince(sent) < 15 { return }
        sendPresence()
    }

    // MARK: Workspace and threads

    func refreshWorkspace() async {
        guard isConnected else { return }
        if case .workspace(let workspace)? = try? await request(.workspace(includeArchived: includesArchived)) {
            apply(workspace)
        }
    }

    // MARK: Expanded projects

    /// Whether a project shows its threads: as the Mac's sidebar has it, or as the user left it here when the Mac
    /// doesn't say (an older Mac) or hasn't confirmed a change yet.
    func isExpanded(_ project: RemoteProject) -> Bool {
        if expansionInFlight.contains(project.id) { return localExpansion[project.id] ?? true }
        return project.isExpanded ?? localExpansion[project.id] ?? true
    }

    /// Expands or collapses a project here and in the Mac's sidebar.
    func setExpanded(_ project: RemoteProject, _ expanded: Bool) {
        localExpansion[project.id] = expanded
        UserDefaults.standard.set(
            Dictionary(uniqueKeysWithValues: localExpansion.map { ($0.key.uuidString, $0.value) }), forKey: Self.expansionKey)
        if DemoData.isEnabled {
            updateProject(project.id) { $0.isExpanded = $0.isExpanded.map { _ in expanded } }
            return
        }
        // An older Mac doesn't keep the choice; the phone does.
        guard project.isExpanded != nil, isConnected else { return }
        expansionInFlight.insert(project.id)
        Task {
            defer { expansionInFlight.remove(project.id) }
            do {
                try await request(.setProjectExpanded(projectID: project.id, expanded: expanded))
                updateProject(project.id) { $0.isExpanded = expanded }
            } catch {}
        }
    }

    private func updateProject(_ id: UUID, _ change: (inout RemoteProject) -> Void) {
        guard let index = workspace.projects.firstIndex(where: { $0.id == id }) else { return }
        change(&workspace.projects[index])
    }

    private static let expansionKey = "projects.expanded"

    private static func savedExpansion() -> [UUID: Bool] {
        let saved = UserDefaults.standard.dictionary(forKey: expansionKey) as? [String: Bool] ?? [:]
        return Dictionary(uniqueKeysWithValues: saved.compactMap { key, value in UUID(uuidString: key).map { ($0, value) } })
    }

    func summary(_ id: UUID) -> RemoteThreadSummary? { workspace.threads.first { $0.id == id } }

    func project(_ id: UUID) -> RemoteProject? { workspace.projects.first { $0.id == id } }

    func provider(_ id: String) -> RemoteProvider? { workspace.providers.first { $0.id == id } }

    /// The thread's model, opening it on the Mac's side when it's new.
    func thread(_ id: UUID) -> ThreadModel {
        if let model = threads[id] { return model }
        let model = ThreadModel(id: id, summary: summary(id))
        threads[id] = model
        Task { await load(id) }
        return model
    }

    func load(_ id: UUID) async {
        if DemoData.isEnabled, let model = threads[id], let summary = summary(id) {
            // `-CoincideRemoteDemoLoading`: the transcript never arrives, to show the thread loading.
            if DemoData.has("Loading") {
                model.isLoading = true
            } else {
                model.apply(DemoData.transcript(summary))
            }
            return
        }
        guard let model = threads[id], isConnected else { return }
        model.isLoading = true
        defer { model.isLoading = false }
        do {
            if case .transcript(let transcript) = try await request(.openThread(threadID: id, limit: 150)) {
                model.apply(transcript)
                model.error = nil
            }
            _ = try? await request(.markSeen(threadID: id))
        } catch {
            model.error = (error as? RemoteError)?.message ?? error.localizedDescription
        }
    }

    func loadEarlier(_ id: UUID) async {
        guard let model = threads[id], let first = model.items.first, model.hasEarlier, !model.isLoadingEarlier else { return }
        model.isLoadingEarlier = true
        defer { model.isLoadingEarlier = false }
        if case .items(let page)? = await perform(.loadEarlier(threadID: id, beforeIndex: first.index, limit: 150)) {
            model.prepend(page)
        }
    }

    /// Stops following a thread that left the screen.
    func close(_ id: UUID) {
        guard threads.removeValue(forKey: id) != nil, isConnected else { return }
        Task { _ = try? await request(.closeThread(threadID: id)) }
    }

    func markSeen(_ id: UUID) {
        guard isConnected else { return }
        Task { _ = try? await request(.markSeen(threadID: id)) }
    }

    func newThread(in projectID: UUID?) async -> UUID? {
        guard case .thread(let id)? = await perform(.newThread(projectID: projectID)) else { return nil }
        await refreshWorkspace()
        return id
    }

    /// A conversation with a bot, reusing an untouched one waiting there.
    func newBotConversation(_ botID: UUID) async -> UUID? {
        guard case .thread(let id)? = await performNewer(.newBotConversation(botID: botID)) else { return nil }
        await refreshWorkspace()
        return id
    }

    /// Creates or edits a bot on the Mac; its id when the Mac saved it.
    func saveBot(_ draft: RemoteBotDraft) async -> UUID? {
        guard case .bot(let id)? = await performNewer(.saveBot(draft)) else { return nil }
        await refreshWorkspace()
        return id
    }

    func deleteBot(_ botID: UUID, deletingConversations: Bool) async {
        guard await performNewer(.deleteBot(botID: botID, deletesConversations: deletingConversations)) != nil else { return }
        await refreshWorkspace()
    }

    /// Asks for the Mac's Settings, which then stay current.
    func loadMacSettings() async {
        if DemoData.isEnabled { return }
        guard isConnected else { return }
        do {
            if case .settings(let snapshot) = try await request(.settings) {
                macSettings = snapshot
                macSettingsUnsupported = false
            }
        } catch let error as RemoteError where error.code == .unsupported {
            macSettingsUnsupported = true
        } catch {}
    }

    func changeMacSetting(_ key: String, to value: RemoteSettingValue) async {
        if case .settings(let snapshot)? = await performNewer(.changeSetting(key: key, value: value)) { macSettings = snapshot }
    }

    /// Where a thread works and its branches, or nil from a Mac too old to say (the row then stays read only).
    func checkout(_ threadID: UUID) async -> RemoteCheckout? {
        if DemoData.isEnabled { return DemoData.checkout }
        guard isConnected, case .checkout(let checkout)? = try? await request(.checkout(threadID: threadID), timeout: .seconds(15))
        else { return nil }
        return checkout
    }

    /// Changes where a thread works or its branch; the updated checkout, or nil with the Mac's reason as a notice.
    func changeCheckout(_ threadID: UUID, _ action: RemoteCheckoutAction) async -> RemoteCheckout? {
        guard case .checkout(let checkout)? = await performNewer(.changeCheckout(threadID: threadID, action: action)) else { return nil }
        await refreshWorkspace()
        return checkout
    }

    /// A settings document's text, such as an instruction file. Throws what the Mac said, for the editor to show.
    func settingsDocument(_ key: String) async throws -> RemoteSettingsDocument {
        if DemoData.isEnabled { return DemoData.document(key) }
        guard case .settingsDocument(let document) = try await request(.settingsDocument(key: key)) else {
            throw RemoteError(.failed, String(localized: "The Mac didn’t send the file."))
        }
        return document
    }

    /// Saves a settings document; refused with `conflict` when it changed on the Mac since it was read.
    func saveSettingsDocument(_ document: RemoteSettingsDocument) async throws -> RemoteSettingsDocument {
        guard case .settingsDocument(let saved) = try await request(.saveSettingsDocument(document)) else {
            throw RemoteError(.failed, String(localized: "The Mac didn’t save the file."))
        }
        return saved
    }

    func performMacSettingsAction(_ key: String) async {
        if case .settings(let snapshot)? = await performNewer(.settingsAction(key: key)) { macSettings = snapshot }
    }

    /// Runs a request an older Mac may not know, saying so plainly when it doesn't.
    func performNewer(_ request: RemoteRequest) async -> RemoteResult? {
        do {
            return try await self.request(request)
        } catch let error as RemoteError where error.code == .unsupported {
            notice = String(localized: "Update Coincide on your Mac to do this from here.")
            return nil
        } catch {
            notice = (error as? RemoteError)?.message ?? error.localizedDescription
            return nil
        }
    }

    func act(_ action: RemoteThreadAction, on threadID: UUID) async {
        await perform(.threadAction(threadID: threadID, action: action))
    }

    func send(_ threadID: UUID, draft: ComposerDraft, alternate: Bool) async -> Bool {
        let images = draft.images.map { RemoteImage(name: $0.name, data: $0.data) }
        let request = RemoteSendRequest(
            threadID: threadID, text: draft.text, images: images, delivery: alternate ? .alternate : .automatic)
        guard case .delivery(let delivery)? = await perform(.send(request)) else { return false }
        switch delivery {
        case "queued": notice = String(localized: "Queued for after the current turn.")
        case "steered": notice = String(localized: "Sent into the current turn.")
        default: break
        }
        return true
    }
}

/// An unsent message.
struct ComposerDraft: Hashable {
    struct Image: Hashable, Identifiable {
        var id = UUID()
        var name: String
        var data: Data
    }

    var text = ""
    var images: [Image] = []

    var isEmpty: Bool { text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && images.isEmpty }
}
