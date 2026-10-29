import Foundation

/// An app connected to the host. The host pushes it the events of the sessions it attached to.
@MainActor
public protocol AgentHostSubscriber: AnyObject {
    func deliver(_ push: AgentHostPush)
}

/// Something the user should hear about while no app is connected to see it.
public struct AgentHostAttention: Sendable, Hashable {
    public enum Kind: Sendable, Hashable {
        case approval(title: String)
        case question(title: String?)
        case finished
        case failed(String)
    }

    public var key: AgentSessionKey
    public var thread: AgentHostThreadInfo
    public var kind: Kind
}

/// When the host exits: never while something runs (a turn, a prompt waiting for an answer, background work),
/// at once when an app of another build asked it to (`retireWhenIdle`), and otherwise once no app has been
/// connected for `grace` seconds, so an app that relaunches or updates finds its idle sessions still there.
public struct AgentHostLifecycle: Sendable, Hashable {
    public var grace: TimeInterval

    public nonisolated init(grace: TimeInterval = 30) { self.grace = grace }

    public nonisolated func shouldExit(
        clients: Int, isBusy: Bool, retireRequested: Bool, idleSince: Date?, now: Date
    ) -> Bool {
        if isBusy { return false }
        if retireRequested { return true }
        guard clients == 0, let idleSince else { return false }
        return now.timeIntervalSince(idleSince) >= grace
    }
}

/// The host's engine: owns the provider sessions, logs their events and pushes them to attached apps. It knows
/// nothing of XPC (`CoincideAgentHost` wraps it), so tests drive it directly.
@MainActor
public final class AgentHostCore {
    public typealias SessionFactory = @MainActor (AgentLaunch, ProviderAccount) -> AgentSession?

    /// One app connection.
    public final class Client {
        weak var subscriber: AgentHostSubscriber?
        var attached: Set<AgentSessionKey> = []

        init(subscriber: AgentHostSubscriber) { self.subscriber = subscriber }
    }

    private final class Hosted {
        let key: AgentSessionKey
        let log: AgentEventLog
        var session: AgentSession?
        var thread: AgentHostThreadInfo
        var starting: Task<Void, Error>?
        var turnActive = false
        var pendingApprovals: [ApprovalRequest] = []
        var pendingQuestions: [UserInputRequest] = []

        init(key: AgentSessionKey, log: AgentEventLog, thread: AgentHostThreadInfo) {
            self.key = key
            self.log = log
            self.thread = thread
        }
    }

    public let build: String
    public let version: String
    public var lifecycle: AgentHostLifecycle
    /// Called once, when the host should exit; every session has been shut down by then.
    public var onExit: (() -> Void)?
    /// Called for what the user should hear about while no app is connected, when the app allowed it.
    public var onAttention: ((AgentHostAttention) -> Void)?
    public private(set) var retireRequested = false
    /// From the latest app's hello.
    public private(set) var notifiesWhileAppIsClosed = false

    private let logs: AgentEventLogStore
    private let makeSession: SessionFactory
    private var hosted: [AgentSessionKey: Hosted] = [:]
    private var clients: [ObjectIdentifier: Client] = [:]
    private var idleSince: Date?
    private var hasExited = false

    public init(
        logDirectory: URL, build: String, version: String, lifecycle: AgentHostLifecycle = AgentHostLifecycle(),
        now: Date = Date(), makeSession: @escaping SessionFactory
    ) {
        logs = AgentEventLogStore(directory: logDirectory)
        self.build = build
        self.version = version
        self.lifecycle = lifecycle
        self.makeSession = makeSession
        // Sessions an earlier run left are gone with its processes. Their logs stay until the app catches up;
        // one that did not end cleanly is ended now, so the app settles the turn it was running.
        for key in logs.existingKeys() {
            let log = logs.open(key)
            // Without a session, a log the app has applied entirely has nothing left to give.
            guard !log.backlog.isEmpty else {
                log.remove()
                continue
            }
            let record = Hosted(key: key, log: log, thread: AgentHostThreadInfo(title: "", projectName: nil))
            if !Self.isExit(log.lastEvent?.event) {
                log.append(.sessionExited(error: String(localized: "The agent host stopped unexpectedly.")), turnActive: false)
            }
            hosted[key] = record
        }
        idleSince = now
    }

    // MARK: Clients

    public func connect(_ subscriber: AgentHostSubscriber) -> Client {
        let client = Client(subscriber: subscriber)
        clients[ObjectIdentifier(client)] = client
        evaluateLifecycle()
        return client
    }

    public func disconnect(_ client: Client) {
        clients[ObjectIdentifier(client)] = nil
        evaluateLifecycle()
    }

    public var clientCount: Int { clients.count }

    public func hello(_ hello: AgentHostHello) -> AgentHostWelcome {
        notifiesWhileAppIsClosed = hello.notifiesWhileAppIsClosed
        return AgentHostWelcome(build: build, version: version, isBusy: isBusy, sessions: sessionInfos)
    }

    public func retireWhenIdle() {
        retireRequested = true
        evaluateLifecycle()
    }

    // MARK: Commands

    public func perform(_ command: AgentHostCommand, from client: Client) async -> AgentHostReply {
        switch command {
        case .start(let key, let launch, let account, let thread):
            return await start(key, launch: launch, account: account, thread: thread, client: client)
        case .send(let key, let input, let thread):
            guard let record = hosted[key], let session = record.session else { return notRunning }
            record.thread = thread
            record.turnActive = true
            // A note in the log that the turn started, so an app catching up from here knows it runs.
            note(record)
            evaluateLifecycle()
            do {
                try await session.send(input)
                return .ok
            } catch {
                if record.session === session, record.turnActive {
                    record.turnActive = false
                    note(record)
                    evaluateLifecycle()
                }
                return .failure(error.localizedDescription)
            }
        case .steer(let key, let input):
            guard let session = hosted[key]?.session else { return notRunning }
            do {
                try await session.steer(input)
                return .ok
            } catch {
                return .failure(error.localizedDescription)
            }
        case .respond(let key, let approvalID, let optionID, let text):
            guard let record = hosted[key], let session = record.session else { return notRunning }
            record.pendingApprovals.removeAll { $0.id == approvalID }
            session.respond(to: approvalID, optionID: optionID, text: text)
            evaluateLifecycle()
            return .ok
        case .answer(let key, let requestID, let answers):
            guard let record = hosted[key], let session = record.session else { return notRunning }
            record.pendingQuestions.removeAll { $0.id == requestID }
            session.answer(userInput: requestID, answers: answers)
            evaluateLifecycle()
            return .ok
        case .interrupt(let key):
            guard let record = hosted[key], let session = record.session else { return notRunning }
            // The app closes the turn's prompts when it stops it.
            record.pendingApprovals = []
            record.pendingQuestions = []
            session.interrupt()
            return .ok
        case .shutdown(let key):
            if let record = hosted.removeValue(forKey: key) {
                record.starting?.cancel()
                record.session?.shutdown()
                record.session = nil
                record.log.remove()
            }
            evaluateLifecycle()
            return .ok
        case .attach(let key, let after):
            client.attached.insert(key)
            if let record = hosted[key] {
                let backlog = record.log.events(after: after)
                if !backlog.isEmpty { client.subscriber?.deliver(.events(key: key, backlog)) }
            }
            return .ok
        case .acknowledge(let key, let sequence):
            acknowledge(key, through: sequence)
            return .ok
        case .list:
            return .sessions(sessionInfos)
        }
    }

    /// The app applied the session's events up to `sequence`. Synchronous, for an app that is quitting.
    public func acknowledge(_ key: AgentSessionKey, through sequence: Int) {
        guard let record = hosted[key] else { return }
        record.log.acknowledge(sequence)
        // An ended session whose every event the app applied has nothing left to keep.
        if record.session == nil, record.log.backlog.isEmpty {
            record.log.remove()
            hosted[key] = nil
        }
    }

    private var notRunning: AgentHostReply { .failure(AgentError.notRunning.localizedDescription) }

    private func start(
        _ key: AgentSessionKey, launch: AgentLaunch, account: ProviderAccount, thread: AgentHostThreadInfo, client: Client
    ) async -> AgentHostReply {
        // The app gets this session's events from now on; anything older it caught up on when it connected.
        client.attached.insert(key)
        if let record = hosted[key], record.session != nil {
            record.thread = thread
            if let starting = record.starting {
                do { try await starting.value } catch { return .failure(error.localizedDescription) }
            }
            return hosted[key]?.session == nil ? notRunning : .started(info(record))
        }
        guard let session = makeSession(launch, account) else { return .failure(AgentError.notInstalled(key.provider).localizedDescription) }
        let record = hosted[key] ?? Hosted(key: key, log: logs.open(key), thread: thread)
        record.thread = thread
        record.session = session
        record.turnActive = false
        record.pendingApprovals = []
        record.pendingQuestions = []
        hosted[key] = record
        session.onEvent = { [weak self, weak session, weak record] event in
            guard let self, let session, let record, record.session === session else { return }
            self.record(event, in: record)
        }
        let task = Task { try await session.start() }
        record.starting = task
        evaluateLifecycle()
        do {
            try await task.value
        } catch {
            if record.session === session {
                record.starting = nil
                record.session = nil
                session.shutdown()
                if record.log.backlog.isEmpty, hosted[key] === record {
                    record.log.remove()
                    hosted[key] = nil
                }
            }
            evaluateLifecycle()
            return .failure(error.localizedDescription)
        }
        record.starting = nil
        evaluateLifecycle()
        // Shut down while starting, or it exited right away.
        guard record.session === session else { return notRunning }
        return .started(info(record))
    }

    // MARK: Events

    private func record(_ event: AgentEvent, in record: Hosted) {
        switch event {
        case .approvalRequested(let request):
            record.pendingApprovals.removeAll { $0.id == request.id }
            record.pendingApprovals.append(request)
        case .approvalResolved(let id):
            record.pendingApprovals.removeAll { $0.id == id }
        case .userInputRequested(let request):
            record.pendingQuestions.removeAll { $0.id == request.id }
            record.pendingQuestions.append(request)
        case .userInputResolved(let id):
            record.pendingQuestions.removeAll { $0.id == id }
        case .agentTurnStarted:
            record.turnActive = true
        case .turnCompleted:
            record.turnActive = false
            record.pendingApprovals = []
            record.pendingQuestions = []
        case .sessionExited:
            record.turnActive = false
            record.pendingApprovals = []
            record.pendingQuestions = []
            record.session = nil
        default:
            break
        }
        let logged = record.log.append(event, turnActive: record.turnActive)
        push(logged, of: record)
        if !hasListener(record.key) { noteAttention(event, of: record) }
        evaluateLifecycle()
    }

    /// Logs a host note: no event, just whether the turn runs.
    private func note(_ record: Hosted) {
        push(record.log.append(nil, turnActive: record.turnActive), of: record)
    }

    private func push(_ event: LoggedAgentEvent, of record: Hosted) {
        for client in clients.values where client.attached.contains(record.key) {
            client.subscriber?.deliver(.events(key: record.key, [event]))
        }
    }

    private func hasListener(_ key: AgentSessionKey) -> Bool {
        clients.values.contains { $0.attached.contains(key) && $0.subscriber != nil }
    }

    private func noteAttention(_ event: AgentEvent, of record: Hosted) {
        guard notifiesWhileAppIsClosed, let onAttention else { return }
        let kind: AgentHostAttention.Kind
        switch event {
        case .approvalRequested(let request): kind = .approval(title: request.title)
        case .userInputRequested(let request): kind = .question(title: request.title ?? request.questions.first?.prompt)
        case .turnCompleted(.completed): kind = .finished
        case .turnCompleted(.failed(let message)): kind = .failed(message)
        default: return
        }
        onAttention(AgentHostAttention(key: record.key, thread: record.thread, kind: kind))
    }

    private static func isExit(_ event: AgentEvent?) -> Bool {
        if case .sessionExited = event { return true }
        return false
    }

    // MARK: State

    /// Something runs that exiting would stop.
    public var isBusy: Bool {
        hosted.values.contains { record in
            guard let session = record.session else { return false }
            return record.starting != nil || record.turnActive || !record.pendingApprovals.isEmpty
                || !record.pendingQuestions.isEmpty || (session as? BackgroundWorkReporting)?.hasBackgroundWork == true
        }
    }

    public var liveSessionCount: Int { hosted.values.count { $0.session != nil } }

    public var sessionInfos: [AgentHostSessionInfo] {
        hosted.values.sorted { $0.key.description < $1.key.description }.map(info)
    }

    private func info(_ record: Hosted) -> AgentHostSessionInfo {
        AgentHostSessionInfo(
            key: record.key, isLive: record.session != nil, sessionID: record.session?.sessionID,
            supportsSteering: record.session?.supportsSteering ?? false,
            hasBackgroundWork: (record.session as? BackgroundWorkReporting)?.hasBackgroundWork ?? false,
            lastSequence: record.log.lastSequence, acknowledgedSequence: record.log.acknowledgedSequence,
            turnWasActiveAtAcknowledged: record.log.turnWasActiveAtAcknowledged, isTurnActive: record.turnActive,
            pendingApprovals: record.pendingApprovals, pendingQuestions: record.pendingQuestions)
    }

    // MARK: Lifecycle

    /// Stops every agent process this process started and what they started, waiting briefly. Sessions stop
    /// their processes asynchronously, which an exiting host does not wait for otherwise.
    public nonisolated static func terminateChildProcesses() {
        ChildProcesses.terminateAllAndWait()
    }

    /// Exits when `lifecycle` says so. Runs after every change, and on a timer from the host (`tick`), since
    /// background work ends without an event.
    public func evaluateLifecycle(now: Date = Date()) {
        guard !hasExited else { return }
        let busy = isBusy
        if busy || !clients.isEmpty {
            idleSince = nil
        } else if idleSince == nil {
            idleSince = now
        }
        guard
            lifecycle.shouldExit(
                clients: clients.count, isBusy: busy, retireRequested: retireRequested, idleSince: idleSince, now: now)
        else { return }
        hasExited = true
        // Apps still connected (a retiring host) learn their sessions ended; the logs keep it for the others.
        for record in hosted.values {
            guard let session = record.session else { continue }
            self.record(.sessionExited(error: nil), in: record)
            session.shutdown()
        }
        onExit?()
    }
}
