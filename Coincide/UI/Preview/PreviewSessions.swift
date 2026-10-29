import AppKit
import CoincideKit

/// Every thread's browser, and the agent bridge to them.
///
/// Agent Control is per thread, defaulting to Settings › Browser. A thread with it on gets runtime instructions with a
/// private capability on each message; the browser itself is created only when the agent (or the panel) first uses
/// it, and runs headless offscreen until the panel shows it. Agents can open the panel (`show`) and hand the user a
/// step to do (`ask-user`), but never read cookies, storage or password values.
final class PreviewSessions {
    static let shared = PreviewSessions()
    let bridge: PreviewBridge
    let profile: BrowserProfile
    /// Asked to bring the thread's browser panel forward; true when the user can now see it. Set by the app; tests
    /// replace it.
    var reveal: (UUID) -> Bool = { _ in false }
    /// Tells the user an agent needs them in a thread they aren't looking at.
    var notifyUser: (UUID, String) -> Void = { _, _ in }
    private var sessions: [UUID: PreviewSession] = [:]
    private var observation: ObservationToken?
    private var settingsObserver: NSObjectProtocol?
    private var usesPrivateSessions: Bool
    static let sessionLimit = 8

    init(profile: BrowserProfile = .shared, bridge: PreviewBridge = PreviewBridge()) {
        self.profile = profile
        self.bridge = bridge
        usesPrivateSessions = profile.usesPrivateSessions
    }

    func start() {
        ThreadRunner.shared.ephemeralRuntimeContext = { [weak self] id in self?.runtimeContext(for: id) }
        observation = AppStore.shared.observe { [weak self] change in
            guard change == .threadList, let self else { return }
            for id in self.sessions.keys where AppStore.shared.summary(id) == nil { self.forget(id) }
            self.profile.settings.prune(keeping: Set(AppStore.shared.threadSummaries.keys))
        }
        settingsObserver = NotificationCenter.default.addObserver(
            forName: BrowserSettingsStore.didChange, object: profile.settings, queue: .main
        ) { [weak self] _ in MainActor.assumeIsolated { self?.settingsChanged() } }
        prepareBridgeIfNeeded()
    }

    func stop() {
        bridge.stop()
        for session in sessions.values { session.close() }
        sessions.removeAll()
        ThreadRunner.shared.ephemeralRuntimeContext = nil
        observation = nil
        if let settingsObserver { NotificationCenter.default.removeObserver(settingsObserver) }
        settingsObserver = nil
        profile.library.flush()
    }

    // MARK: Sessions

    func existingSession(for id: UUID) -> PreviewSession? { sessions[id] }

    func session(for id: UUID) -> PreviewSession {
        if let session = sessions[id] {
            session.lastUse = Date()
            return session
        }
        evictIfNeeded()
        let session = PreviewSession(dataStore: profile.makeDataStore(), isPrivate: usesPrivateSessions)
        let isPrivate = session.isPrivate
        session.onNavigate = { [weak self] url, title in
            UIState.shared.update { $0.previewAddresses[id.uuidString] = url.absoluteString }
            if !isPrivate { self?.profile.library.recordVisit(url: url, title: title) }
        }
        sessions[id] = session
        if let address = UIState.shared.values.previewAddresses[id.uuidString] { try? session.navigate(address) }
        PreviewParking.shared.park(session.webView)
        return session
    }

    /// Closes the least recently used browsers beyond the limit, sparing the one waiting on the user.
    private func evictIfNeeded() {
        guard sessions.count >= Self.sessionLimit else { return }
        let candidates = sessions.filter { $0.value.userTurn.request == nil && PreviewParking.shared.isParked($0.value.webView) }
        if let oldest = candidates.min(by: { $0.value.lastUse < $1.value.lastUse }) {
            sessions.removeValue(forKey: oldest.key)?.close()
        }
    }

    private func forget(_ id: UUID) {
        bridge.disable(threadID: id)
        sessions.removeValue(forKey: id)?.close()
        UIState.shared.update { $0.previewAddresses.removeValue(forKey: id.uuidString) }
    }

    /// Closes every browser, as when the storage they use changes. Pages reopen from their last address.
    func resetSessions() {
        for session in sessions.values { session.close() }
        sessions.removeAll()
        NotificationCenter.default.post(name: Self.sessionsReset, object: self)
    }

    static let sessionsReset = Notification.Name("coincide.previewSessionsReset")

    private func settingsChanged() {
        if profile.usesPrivateSessions != usesPrivateSessions {
            usesPrivateSessions = profile.usesPrivateSessions
            resetSessions()
        }
        // Revoke capabilities for threads whose Agent Control is now off.
        for id in AppStore.shared.threadSummaries.keys where bridge.access(for: id) != nil && !isAgentControlEnabled(id) {
            bridge.disable(threadID: id)
        }
        prepareBridgeIfNeeded()
        NotificationCenter.default.post(name: Self.agentControlChanged, object: self)
    }

    // MARK: Agent control

    static let agentControlChanged = Notification.Name("coincide.previewAgentControlChanged")

    func isAgentControlEnabled(_ id: UUID) -> Bool { profile.settings.settings.isAgentControlEnabled(for: id) }

    /// The user's choice for one thread, from the panel. Turning it off revokes the capability at once.
    func setAgentControl(_ enabled: Bool, for id: UUID) {
        profile.settings.update { settings in
            settings.agentControl[id.uuidString] = enabled == settings.agentControlByDefault ? nil : enabled
        }
        if !enabled { bridge.disable(threadID: id) }
        prepareBridgeIfNeeded()
    }

    /// Starts the loopback listener early when any thread may grant access, so instructions are ready for the first
    /// message.
    private func prepareBridgeIfNeeded() {
        let settings = profile.settings.settings
        guard !bridge.isReady, settings.agentControlByDefault || settings.agentControl.values.contains(true) else { return }
        Task { try? await bridge.prepare() }
    }

    /// The instructions added to a message sent in `id`, with its capability; nil when Agent Control is off there.
    func runtimeContext(for id: UUID) -> String? {
        guard isAgentControlEnabled(id) else {
            bridge.disable(threadID: id)
            return nil
        }
        return bridge.enableNow(threadID: id, handler: handler(for: id))?.instructions
    }

    /// Grants access now, waiting for the listener if needed. For the panel and tests.
    @discardableResult
    func enableAccess(for id: UUID) async throws -> PreviewBridge.Access {
        try await bridge.enable(threadID: id, handler: handler(for: id))
    }

    private func handler(for id: UUID) -> PreviewBridge.Handler {
        { [weak self] command, directory in
            guard let self else { throw PreviewError.unavailable }
            return try await self.perform(command, threadID: id, directory: directory)
        }
    }

    func perform(_ command: PreviewCommand, threadID id: UUID, directory: URL) async throws -> JSONValue {
        guard isAgentControlEnabled(id) else { throw PreviewError.unavailable }
        switch command {
        case .show:
            let session = session(for: id)
            session.lastAgentUse = Date()
            let visible = reveal(id)
            if !visible { notifyUser(id, String(localized: "The agent opened this thread’s browser for you.")) }
            return ["shown": .bool(visible)]
        case .askUser(let message, let timeout):
            let session = session(for: id)
            session.lastAgentUse = Date()
            let waiting = Task { await session.userTurn.ask(message, timeout: timeout) }
            // The banner exists before the panel looks for it.
            await Task.yield()
            if !reveal(id) { notifyUser(id, session.userTurn.request?.message ?? message) }
            let result = await waiting.value
            return ["result": .string(result.rawValue)]
        default:
            return try await session(for: id).perform(command, directory: directory)
        }
    }
}
