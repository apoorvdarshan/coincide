import Foundation

/// A session `ThreadRunner` can let go of when the app quits without ending it: the agent keeps working elsewhere.
@MainActor
public protocol DetachableAgentSession: AgentSession {
    /// Stops delivering events here; the session itself goes on.
    func detach()
}

/// The app's side of the agent host: makes sessions that run there, routes the host's pushes to them in order,
/// and tells the host how far the app got, so the host's log can let go of those events.
///
/// Delivery is at most once into the transcript: an event is acknowledged once it reached `ThreadRunner`, which
/// keeps it in memory until `AppStore` writes it. A crash before that write loses that moment of output, but not
/// the turn: pending prompts and whether a turn runs come back from the host's own state (`adopt`).
///
/// Events are applied in sequence. One that skips ahead means pushes went missing, and the app catches up from
/// the host's log (`resync`) instead of going on without them. It also checks with the host when a running turn
/// has been quiet for a while or a stop goes unconfirmed, so a thread never looks busy after its agent finished.
@MainActor
public final class AgentHostClient {
    public let transport: AgentHostTransport
    private var sessions: [AgentSessionKey: RemoteAgentSession] = [:]
    /// The last event applied per session.
    private var applied: [AgentSessionKey: Int] = [:]
    private var pendingAcknowledgements: Set<AgentSessionKey> = []
    public private(set) var isConnected = true
    /// The last event per adopted session the host recorded before the app took it up again.
    private var backlogEnd: [AgentSessionKey: Int] = [:]
    /// True while events the host recorded with no app attached are being applied, and while the prompts still
    /// waiting are shown again. The host notified about those itself, so the app must not notify again.
    public private(set) var isApplyingBacklog = false
    /// Called once the connection ended, after every session reported its end.
    public var onDisconnect: (() -> Void)?
    /// When each session last heard from the host.
    private var lastHeard: [AgentSessionKey: Date] = [:]
    /// Sessions being caught up from the host's log.
    private var resyncing: Set<AgentSessionKey> = []
    private var watchdog: Task<Void, Never>?
    /// How long a running turn may stay quiet before the app checks with the host that it missed nothing.
    public var quietTurnCheckInterval: TimeInterval = 20
    /// How long after a stop the app checks with the host, if the turn has not ended by then. Shorter than
    /// `ThreadRunner`'s stop timeout, so a confirmation that went missing is found before the turn is given up on.
    public var interruptCheckDelay: TimeInterval = 2

    public init(transport: AgentHostTransport) {
        self.transport = transport
        transport.onPush = { [weak self] push in self?.receive(push) }
        transport.onDisconnect = { [weak self] in self?.disconnected() }
    }

    isolated deinit {
        watchdog?.cancel()
    }

    /// A new session that runs in the host. `thread` names the thread for the host's notifications.
    public func makeSession(
        key: AgentSessionKey, launch: AgentLaunch, account: ProviderAccount, thread: @escaping () -> AgentHostThreadInfo
    ) -> RemoteAgentSession {
        let session = RemoteAgentSession(
            key: key, client: self, mode: .new(launch: launch, account: account), thread: thread)
        register(session)
        // A new session only gets events from now on, never a replay. The host may have removed the key's log since
        // the previous session ended (a stop, an idle shutdown, or everything applied after a relaunch), and a host
        // older than this app numbers the new log from 1 again: how far the previous session got must not hide the
        // new one's events.
        applied[key] = nil
        backlogEnd[key] = nil
        return session
    }

    /// A session the host kept running (or that ended while the app was away), to take up again. Its events after
    /// what the app applied arrive once `attach` is called, after the caller wired `onEvent`.
    public func adopt(_ info: AgentHostSessionInfo, thread: @escaping () -> AgentHostThreadInfo) -> RemoteAgentSession {
        let session = RemoteAgentSession(key: info.key, client: self, mode: .adopted(info), thread: thread)
        applied[info.key] = info.acknowledgedSequence
        backlogEnd[info.key] = info.lastSequence
        register(session)
        return session
    }

    /// Catches an adopted session up: the events it missed, then every new one. The prompts still waiting are
    /// shown again afterwards, so one the app lost (a crash before it saved them) can still be answered.
    public func attach(_ session: RemoteAgentSession) async {
        // The background work it runs, first: the event that reported it may be one the app applied before it quit,
        // and any later report comes with the events that follow.
        if case .adopted(let info) = session.mode {
            let tasks = Self.backgroundTasks(of: info)
            if !tasks.isEmpty { session.deliver(.backgroundWork(tasks)) }
        }
        let after = applied[session.key] ?? 0
        guard (try? await transport.run(.attach(key: session.key, after: after))) != nil else { return }
        guard case .adopted(let info) = session.mode, sessions[session.key] === session else { return }
        isApplyingBacklog = true
        defer { isApplyingBacklog = false }
        for request in info.pendingApprovals { session.deliver(.approvalRequested(request)) }
        for request in info.pendingQuestions { session.deliver(.userInputRequested(request)) }
    }

    /// What an adopted session runs in the background. A host older than the list only says whether it runs
    /// anything, which shows as one unnamed task until the session reports its work again.
    nonisolated static func backgroundTasks(of info: AgentHostSessionInfo) -> [BackgroundTask] {
        guard info.isLive else { return [] }
        if let tasks = info.backgroundTasks { return tasks }
        return info.hasBackgroundWork ? [BackgroundTask(id: "coincide.unlisted", title: String(localized: "Background work"), kind: .other)] : []
    }

    /// Ends a session the app no longer wants, such as one of a deleted thread.
    public func discard(_ key: AgentSessionKey) {
        forget(key)
        Task { _ = try? await transport.perform(.shutdown(key: key)) }
    }

    /// Sends the acknowledgements still waiting and waits for the host to have them. Call when quitting, after
    /// `ThreadRunner.detachHostedSessions()`, so the next launch does not apply those events again.
    public func flushAcknowledgements(timeout: TimeInterval = 1) {
        var pending: [AgentSessionKey: Int] = [:]
        for key in pendingAcknowledgements { pending[key] = applied[key] }
        pendingAcknowledgements = []
        transport.acknowledgeSynchronously(pending, timeout: timeout)
    }

    private func register(_ session: RemoteAgentSession) {
        // A previous session of the key stops receiving; the host keeps one per key.
        sessions[session.key]?.isDetached = true
        sessions[session.key] = session
        lastHeard[session.key] = Date()
        startWatchdog()
    }

    /// Stops routing the key's events. How far the app got is kept, so its last events are still acknowledged.
    func forget(_ key: AgentSessionKey) {
        sessions[key] = nil
        lastHeard[key] = nil
    }

    // MARK: Pushes

    private func receive(_ push: AgentHostPush) {
        switch push {
        case .events(let key, let events):
            lastHeard[key] = Date()
            for logged in events {
                if let last = applied[key] {
                    // Replays and live pushes can overlap; each event is applied once.
                    guard logged.sequence > last else { continue }
                    // Pushes went missing. The log still has them, since only applied events are acknowledged:
                    // they come again with this one and the ones after it.
                    guard logged.sequence == last + 1 else {
                        Task { await resync(key) }
                        break
                    }
                }
                applied[key] = logged.sequence
                isApplyingBacklog = logged.sequence <= (backlogEnd[key] ?? 0)
                if let event = logged.event { sessions[key]?.deliver(event) }
                isApplyingBacklog = false
            }
            acknowledgeSoon(key)
        }
    }

    /// One acknowledgement per session for everything applied in this turn of the main run loop.
    private func acknowledgeSoon(_ key: AgentSessionKey) {
        guard pendingAcknowledgements.insert(key).inserted else { return }
        DispatchQueue.main.async { [weak self] in
            MainActor.assumeIsolated {
                guard let self, self.pendingAcknowledgements.remove(key) != nil, let sequence = self.applied[key] else { return }
                let transport = self.transport
                Task { _ = try? await transport.perform(.acknowledge(key: key, sequence: sequence)) }
            }
        }
    }

    // MARK: Catching up

    /// Brings the key's session in line with the host: replays from the host's log the events the app is missing,
    /// then settles what the log can no longer tell, such as a turn or session that ended without the app hearing.
    public func resync(_ key: AgentSessionKey) async {
        guard isConnected, sessions[key] != nil, resyncing.insert(key).inserted else { return }
        defer { resyncing.remove(key) }
        guard case .sessions(let infos)? = try? await transport.perform(.list), let session = sessions[key] else { return }
        lastHeard[key] = Date()
        guard let info = infos.first(where: { $0.key == key }) else {
            // The host has nothing for the key: its session ended and every event was acknowledged, so a turn the
            // app still runs can only be one whose end it missed.
            if session.isTurnPending, !session.isStarting { session.deliver(.sessionExited(error: nil)) }
            return
        }
        var after = applied[key] ?? info.acknowledgedSequence
        // A log numbered from 1 again (a host older than this app removed the previous one), or events the log
        // no longer has: what it still has is what the app can catch up on.
        if info.lastSequence < after || info.acknowledgedSequence > after { after = info.acknowledgedSequence }
        if info.lastSequence > after {
            applied[key] = after
            _ = try? await transport.perform(.attach(key: key, after: after))
        }
        guard sessions[key] === session, (applied[key] ?? 0) >= info.lastSequence else { return }
        if !info.isLive {
            session.deliver(.sessionExited(error: nil))
        } else if !info.isTurnActive, session.isTurnPending, session.sendsInFlight == 0 {
            // The host's turn is over, yet the app never learned how it ended.
            session.deliver(.turnCompleted(.completed))
        }
    }

    /// Checks on running turns that have been quiet for a while, for as long as any session is routed here.
    private func startWatchdog() {
        guard watchdog == nil else { return }
        watchdog = Task { [weak self] in
            while !Task.isCancelled {
                let interval = self?.quietTurnCheckInterval ?? 20
                try? await Task.sleep(for: .seconds(max(0.01, interval / 2)))
                guard let self, self.isConnected, !self.sessions.isEmpty else {
                    self?.watchdog = nil
                    return
                }
                let now = Date()
                for (key, session) in self.sessions where session.isTurnPending {
                    guard now.timeIntervalSince(self.lastHeard[key] ?? .distantPast) >= interval else { continue }
                    Task { await self.resync(key) }
                }
            }
        }
    }

    /// After a stop: a turn that has not ended shortly afterwards may have ended without the app hearing.
    func checkAfterInterrupt(_ key: AgentSessionKey) {
        let delay = interruptCheckDelay
        Task { [weak self] in
            try? await Task.sleep(for: .seconds(delay))
            guard let self, self.sessions[key]?.isTurnPending == true else { return }
            await self.resync(key)
        }
    }

    private func disconnected() {
        guard isConnected else { return }
        isConnected = false
        watchdog?.cancel()
        watchdog = nil
        let ended = sessions.values
        sessions = [:]
        for session in ended where !session.isDetached {
            session.deliver(.sessionExited(error: String(localized: "Lost the connection to Coincide’s agent host.")))
        }
        onDisconnect?()
    }
}

/// A session that runs in the agent host, driven over the app's connection to it.
@MainActor
public final class RemoteAgentSession: DetachableAgentSession, BackgroundWorkReporting {
    enum Mode {
        case new(launch: AgentLaunch, account: ProviderAccount)
        case adopted(AgentHostSessionInfo)
    }

    public let key: AgentSessionKey
    public var provider: ProviderKind { key.provider }
    public private(set) var sessionID: String?
    public var onEvent: ((AgentEvent) -> Void)?
    public private(set) var supportsSteering = false
    public private(set) var hasBackgroundWork = false
    let mode: Mode
    var isDetached = false
    /// A turn runs as far as this side knows: one was sent, adopted mid-way or started by the agent, and its end
    /// has not arrived.
    private(set) var isTurnPending = false
    /// `send`s the host has not answered yet; until it does, the host may not know the turn started.
    private(set) var sendsInFlight = 0
    /// A new session whose `start` has not finished: the host may not have it yet.
    private(set) var isStarting = false
    private weak var client: AgentHostClient?
    private let thread: () -> AgentHostThreadInfo

    init(key: AgentSessionKey, client: AgentHostClient, mode: Mode, thread: @escaping () -> AgentHostThreadInfo) {
        self.key = key
        self.client = client
        self.mode = mode
        self.thread = thread
        if case .adopted(let info) = mode {
            sessionID = info.sessionID
            supportsSteering = info.supportsSteering
            hasBackgroundWork = info.hasBackgroundWork
            isTurnPending = info.hasBacklog ? info.turnWasActiveAtAcknowledged : info.isTurnActive
        }
    }

    func deliver(_ event: AgentEvent) {
        guard !isDetached else { return }
        switch event {
        case .sessionStarted(let id), .sessionContinued(let id): sessionID = id
        case .backgroundWork(let tasks): hasBackgroundWork = !tasks.isEmpty
        case .agentTurnStarted: isTurnPending = true
        case .turnCompleted: isTurnPending = false
        case .sessionExited:
            hasBackgroundWork = false
            isTurnPending = false
            client?.forget(key)
        default: break
        }
        onEvent?(event)
    }

    private var transport: AgentHostTransport {
        get throws {
            guard let client, client.isConnected, !isDetached else { throw AgentHostError.disconnected }
            return client.transport
        }
    }

    public func start() async throws {
        guard case .new(let launch, let account) = mode else { return }
        let transport = try transport
        isStarting = true
        defer { isStarting = false }
        let reply = try await transport.perform(.start(key: key, launch: launch, account: account, thread: thread()))
        switch reply {
        case .started(let info):
            sessionID = info.sessionID ?? sessionID
            supportsSteering = info.supportsSteering
        case .failure(let message):
            throw AgentError.providerError(message)
        default:
            throw AgentHostError.unreadableReply
        }
    }

    public func send(_ input: AgentTurnInput) async throws {
        let transport = try transport
        isTurnPending = true
        sendsInFlight += 1
        defer { sendsInFlight -= 1 }
        do {
            try await transport.run(.send(key: key, input: input, thread: thread()))
        } catch {
            isTurnPending = false
            throw error
        }
    }

    public func steer(_ input: AgentTurnInput) async throws {
        try await transport.run(.steer(key: key, input: input))
    }

    public func respond(to approvalID: String, optionID: String) {
        respond(to: approvalID, optionID: optionID, text: nil)
    }

    public func respond(to approvalID: String, optionID: String, text: String?) {
        perform(.respond(key: key, approvalID: approvalID, optionID: optionID, text: text))
    }

    public func answer(userInput requestID: String, answers: [String: [String]]) {
        perform(.answer(key: key, requestID: requestID, answers: answers))
    }

    public func interrupt() {
        perform(.interrupt(key: key))
        client?.checkAfterInterrupt(key)
    }

    public func shutdown() {
        guard !isDetached else { return }
        isDetached = true
        client?.discard(key)
    }

    public func detach() {
        isDetached = true
    }

    /// Commands without a result. Sent in order: each starts on the main actor as it is made.
    private func perform(_ command: AgentHostCommand) {
        guard let transport = try? transport else { return }
        Task { _ = try? await transport.perform(command) }
    }
}
