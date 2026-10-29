import Foundation

/// The background agent host: a LaunchAgent bundled in Coincide.app (`Contents/Helpers`) that owns provider
/// sessions and their processes, so agents keep working while Coincide quits, crashes or updates. The app is
/// its client over XPC, as T3 Code's UI is a client of the server that owns its provider sessions.
///
/// Who writes what: the host writes only its own folder (`AgentHostPaths.directory`), an event log per session.
/// The app stays the only writer of threads, settings and projects; it applies the events to the transcript
/// as they arrive, or from the log when it comes back.
public enum AgentHostIdentity {
    /// The Mach service the LaunchAgent's plist names, which launchd starts the host for on demand.
    public nonisolated static let machServiceName = "com.apoorvdarshan.coincide.agent-host"
    /// The plist in `Contents/Library/LaunchAgents`, registered with `SMAppService.agent(plistName:)`.
    public nonisolated static let plistName = "com.apoorvdarshan.coincide.agent-host.plist"
    public nonisolated static let bundleID = "com.apoorvdarshan.coincide.agent-host"
    public nonisolated static let appBundleID = "com.apoorvdarshan.coincide"
}

/// Where the host keeps its event logs: `agent-host` in Coincide's data folder, which the app never writes.
public enum AgentHostPaths {
    @MainActor public static func directory(in dataDirectory: URL = AppStore.defaultDirectory) -> URL {
        dataDirectory.appendingPathComponent("agent-host", isDirectory: true)
    }
}

/// What the app calls on the host. Every payload is JSON (`AgentHostWire`), so either side can add fields and
/// commands without changing this interface, which an older host or app must keep understanding. Never change
/// these selectors; add new ones instead.
@objc public protocol AgentHostXPC {
    /// The version handshake: an `AgentHostHello` in, an `AgentHostWelcome` back.
    func hello(_ request: Data, reply: @escaping @Sendable (Data) -> Void)
    /// One `AgentHostCommand` in, an `AgentHostReply` back once it is done.
    func perform(_ command: Data, reply: @escaping @Sendable (Data) -> Void)
    /// Exit as soon as nothing runs: no turn, no prompt waiting, no background work. Sent by an app of another
    /// build, so the host is replaced by its own once that can happen without stopping an agent.
    func retireWhenIdle()
}

/// What the host calls on the app: pushes (`AgentHostPush`) in the order they happened.
@objc public protocol AgentHostClientXPC {
    func receive(_ push: Data)
}

/// Versions both sides compare in the handshake. Raise `current` for any change to the wire format, and
/// `oldestSupported` only when this build can no longer talk to hosts or apps that old.
public enum AgentHostProtocolVersion {
    public nonisolated static let current = 1
    public nonisolated static let oldestSupported = 1
}

public struct AgentHostHello: Codable, Sendable, Hashable {
    public var protocolVersion: Int
    public var oldestSupportedProtocol: Int
    /// The app's `CFBundleVersion` and `CFBundleShortVersionString`.
    public var build: String
    public var version: String
    /// Whether the host may post notifications while no app is connected (`AppSettings.notifyWhenInBackground`).
    public var notifiesWhileAppIsClosed: Bool

    public nonisolated init(
        protocolVersion: Int = AgentHostProtocolVersion.current,
        oldestSupportedProtocol: Int = AgentHostProtocolVersion.oldestSupported, build: String, version: String,
        notifiesWhileAppIsClosed: Bool
    ) {
        self.protocolVersion = protocolVersion
        self.oldestSupportedProtocol = oldestSupportedProtocol
        self.build = build
        self.version = version
        self.notifiesWhileAppIsClosed = notifiesWhileAppIsClosed
    }
}

public struct AgentHostWelcome: Codable, Sendable, Hashable {
    public var protocolVersion: Int
    public var oldestSupportedProtocol: Int
    public var build: String
    public var version: String
    /// Something runs that exiting would stop: a turn, a prompt waiting for an answer, or background work.
    public var isBusy: Bool
    /// The sessions the host has, live or ended with events the app has not applied yet.
    public var sessions: [AgentHostSessionInfo]

    public nonisolated init(
        protocolVersion: Int = AgentHostProtocolVersion.current,
        oldestSupportedProtocol: Int = AgentHostProtocolVersion.oldestSupported, build: String, version: String,
        isBusy: Bool, sessions: [AgentHostSessionInfo]
    ) {
        self.protocolVersion = protocolVersion
        self.oldestSupportedProtocol = oldestSupportedProtocol
        self.build = build
        self.version = version
        self.isBusy = isBusy
        self.sessions = sessions
    }
}

/// What an app does with the host it reached, given both sides' versions.
public enum AgentHostCompatibility: Equatable, Sendable {
    /// Same build: use it.
    case use
    /// Another build that speaks a protocol both understand: use it, and have it exit once idle so the next
    /// connection starts this build's host.
    case useAndReplaceWhenIdle
    /// It speaks a protocol this app cannot, and nothing runs: have it exit now and connect again.
    case replaceNow
    /// It speaks a protocol this app cannot, and agents run in it: leave them be (they finish on their own,
    /// with their events logged), run new sessions in the app, and have the host exit once idle.
    case runInProcessUntilIdle

    public nonisolated static func evaluate(app: AgentHostHello, host: AgentHostWelcome) -> AgentHostCompatibility {
        let understood =
            host.protocolVersion >= app.oldestSupportedProtocol && app.protocolVersion >= host.oldestSupportedProtocol
        if understood { return host.build == app.build ? .use : .useAndReplaceWhenIdle }
        return host.isBusy ? .runInProcessUntilIdle : .replaceNow
    }
}

/// Identifies one hosted session: a thread's session with one provider, as `ThreadRunner` keys them.
public struct AgentSessionKey: Codable, Sendable, Hashable, CustomStringConvertible {
    public var threadID: UUID
    public var provider: ProviderKind

    public nonisolated init(threadID: UUID, provider: ProviderKind) {
        self.threadID = threadID
        self.provider = provider
    }

    /// Safe as a file name: `<thread>.<provider>`.
    public nonisolated var description: String { "\(threadID.uuidString).\(provider.rawValue)" }
}

/// What the host knows about one session, for the handshake and `list`.
public struct AgentHostSessionInfo: Codable, Sendable, Hashable {
    public var key: AgentSessionKey
    /// Its process runs; false for a session that ended while its events wait for the app.
    public var isLive: Bool
    public var sessionID: String?
    public var supportsSteering: Bool
    public var hasBackgroundWork: Bool
    /// The last event logged, and the last one the app said it applied.
    public var lastSequence: Int
    public var acknowledgedSequence: Int
    /// Whether a turn ran right after the event the app applied last: the app picks that turn up again when
    /// it catches up.
    public var turnWasActiveAtAcknowledged: Bool
    /// Whether a turn runs now.
    public var isTurnActive: Bool
    /// Approvals and questions waiting for an answer, which the app shows again even if it lost them.
    public var pendingApprovals: [ApprovalRequest]
    public var pendingQuestions: [UserInputRequest]
    /// The background work the session last reported (`AgentEvent.backgroundWork`), which the app shows again: the
    /// event that reported it may be one the app applied before it quit. Nil from a host older than this field.
    public var backgroundTasks: [BackgroundTask]?

    public nonisolated init(
        key: AgentSessionKey, isLive: Bool, sessionID: String?, supportsSteering: Bool, hasBackgroundWork: Bool,
        lastSequence: Int, acknowledgedSequence: Int, turnWasActiveAtAcknowledged: Bool, isTurnActive: Bool,
        pendingApprovals: [ApprovalRequest], pendingQuestions: [UserInputRequest], backgroundTasks: [BackgroundTask]? = nil
    ) {
        self.backgroundTasks = backgroundTasks
        self.key = key
        self.isLive = isLive
        self.sessionID = sessionID
        self.supportsSteering = supportsSteering
        self.hasBackgroundWork = hasBackgroundWork
        self.lastSequence = lastSequence
        self.acknowledgedSequence = acknowledgedSequence
        self.turnWasActiveAtAcknowledged = turnWasActiveAtAcknowledged
        self.isTurnActive = isTurnActive
        self.pendingApprovals = pendingApprovals
        self.pendingQuestions = pendingQuestions
    }

    /// Events the app has yet to apply.
    public nonisolated var hasBacklog: Bool { lastSequence > acknowledgedSequence }
}

/// Names the thread for a notification the host posts while the app is closed.
public struct AgentHostThreadInfo: Codable, Sendable, Hashable {
    public var title: String
    public var projectName: String?

    public nonisolated init(title: String, projectName: String?) {
        self.title = title
        self.projectName = projectName
    }
}

/// A command from the app. Unknown commands get `AgentHostReply.failure`, so an older host refuses a newer
/// command instead of misreading it.
public enum AgentHostCommand: Codable, Sendable {
    /// Starts the session for the key, or keeps the one already running (then `launch` is ignored).
    /// `account` picks the provider instance, as `ProviderRegistry.provider(_:account:)` does in the app.
    case start(key: AgentSessionKey, launch: AgentLaunch, account: ProviderAccount, thread: AgentHostThreadInfo)
    case send(key: AgentSessionKey, input: AgentTurnInput, thread: AgentHostThreadInfo)
    case steer(key: AgentSessionKey, input: AgentTurnInput)
    case respond(key: AgentSessionKey, approvalID: String, optionID: String, text: String?)
    case answer(key: AgentSessionKey, requestID: String, answers: [String: [String]])
    case interrupt(key: AgentSessionKey)
    /// Ends the session and forgets its log: the app has everything it needs.
    case shutdown(key: AgentSessionKey)
    /// Pushes the events after `sequence`, then every new one as it happens, until the connection ends.
    case attach(key: AgentSessionKey, after: Int)
    /// The app applied every event up to `sequence`; the log may drop them.
    case acknowledge(key: AgentSessionKey, sequence: Int)
    case list
    /// The user has seen the thread in the app: notifications the host posted about it can go.
    case clearNotifications(threadID: UUID)
}

public enum AgentHostReply: Codable, Sendable {
    case ok
    case started(AgentHostSessionInfo)
    case sessions([AgentHostSessionInfo])
    case failure(String)
}

/// What the host pushes to attached apps.
public enum AgentHostPush: Codable, Sendable {
    case events(key: AgentSessionKey, [LoggedAgentEvent])
}

/// JSON coding shared by both sides and the logs.
public enum AgentHostWire {
    public nonisolated static func encode<T: Encodable>(_ value: T) throws -> Data {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .millisecondsSince1970
        return try encoder.encode(value)
    }

    public nonisolated static func decode<T: Decodable>(_ type: T.Type, from data: Data) throws -> T {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .millisecondsSince1970
        return try decoder.decode(type, from: data)
    }
}

/// One logged event. `event` is nil when it was written by a newer host with a case this build does not know;
/// it still takes up its sequence number, so nothing after it is lost or applied twice.
public struct LoggedAgentEvent: Codable, Sendable, Hashable {
    public var sequence: Int
    public var date: Date
    public var event: AgentEvent?
    /// Whether a turn runs once this event is applied, so an app catching up from here knows.
    public var turnActive: Bool

    public nonisolated init(sequence: Int, date: Date, event: AgentEvent?, turnActive: Bool) {
        self.sequence = sequence
        self.date = date
        self.event = event
        self.turnActive = turnActive
    }

    private enum CodingKeys: String, CodingKey {
        case sequence, date, event, turnActive
    }

    public nonisolated init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        sequence = try container.decode(Int.self, forKey: .sequence)
        date = try container.decode(Date.self, forKey: .date)
        event = try? container.decodeIfPresent(AgentEvent.self, forKey: .event)
        turnActive = try container.decodeIfPresent(Bool.self, forKey: .turnActive) ?? false
    }
}
