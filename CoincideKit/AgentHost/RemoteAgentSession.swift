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

    public init(transport: AgentHostTransport) {
        self.transport = transport
        transport.onPush = { [weak self] push in self?.receive(push) }
        transport.onDisconnect = { [weak self] in self?.disconnected() }
    }

    /// A new session that runs in the host. `thread` names the thread for the host's notifications.
    public func makeSession(
        key: AgentSessionKey, launch: AgentLaunch, account: ProviderAccount, thread: @escaping () -> AgentHostThreadInfo
    ) -> RemoteAgentSession {
        let session = RemoteAgentSession(
            key: key, client: self, mode: .new(launch: launch, account: account), thread: thread)
        register(session)
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
        let after = applied[session.key] ?? 0
        guard (try? await transport.run(.attach(key: session.key, after: after))) != nil else { return }
        guard case .adopted(let info) = session.mode, sessions[session.key] === session else { return }
        isApplyingBacklog = true
        defer { isApplyingBacklog = false }
        for request in info.pendingApprovals { session.deliver(.approvalRequested(request)) }
        for request in info.pendingQuestions { session.deliver(.userInputRequested(request)) }
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
    }

    /// Stops routing the key's events. How far the app got is kept, so its last events are still acknowledged.
    func forget(_ key: AgentSessionKey) {
        sessions[key] = nil
    }

    // MARK: Pushes

    private func receive(_ push: AgentHostPush) {
        switch push {
        case .events(let key, let events):
            for logged in events {
                // Replays and live pushes can overlap; each event is applied once.
                guard logged.sequence > (applied[key] ?? 0) else { continue }
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

    private func disconnected() {
        guard isConnected else { return }
        isConnected = false
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
        }
    }

    func deliver(_ event: AgentEvent) {
        guard !isDetached else { return }
        switch event {
        case .sessionStarted(let id), .sessionContinued(let id): sessionID = id
        case .backgroundWork(let tasks): hasBackgroundWork = !tasks.isEmpty
        case .sessionExited:
            hasBackgroundWork = false
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
        try await transport.run(.send(key: key, input: input, thread: thread()))
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
