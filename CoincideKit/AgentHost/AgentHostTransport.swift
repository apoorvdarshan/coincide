import Foundation
import Security

/// The app's line to the agent host: XPC to the LaunchAgent, or the host's engine itself in tests.
@MainActor
public protocol AgentHostTransport: AnyObject {
    /// Pushes from the host, in the order it sent them.
    var onPush: ((AgentHostPush) -> Void)? { get set }
    /// Called once when the connection ends: the host exited, crashed or refused the app.
    var onDisconnect: (() -> Void)? { get set }
    func hello(_ hello: AgentHostHello) async throws -> AgentHostWelcome
    func perform(_ command: AgentHostCommand) async throws -> AgentHostReply
    func retireWhenIdle()
    func invalidate()
    /// Tells the host how far the app got and waits until it knows, at most `timeout` seconds: for quitting, when
    /// a message sent the usual way could be lost as the app exits.
    func acknowledgeSynchronously(_ acknowledgements: [AgentSessionKey: Int], timeout: TimeInterval)
}

extension AgentHostTransport {
    /// Performs a command that only succeeds or fails.
    public func run(_ command: AgentHostCommand) async throws {
        if case .failure(let message) = try await perform(command) { throw AgentError.providerError(message) }
    }
}

public enum AgentHostError: LocalizedError, Sendable {
    case disconnected
    case unreadableReply
    /// The agent session runs in another process (`AgentSessionLocks`), which this one must not start a second time.
    case runningElsewhere(AgentSessionOwner.Role?)
    /// The provider session already runs in the host for another thread.
    case runningInAnotherThread

    public nonisolated var errorDescription: String? {
        switch self {
        case .disconnected: String(localized: "Lost the connection to Coincide’s agent host.")
        case .unreadableReply: String(localized: "Coincide’s agent host sent a reply this version can’t read.")
        case .runningElsewhere(.app):
            String(localized: "This agent is still running in Coincide, so it can’t be started a second time.")
        case .runningElsewhere:
            String(
                localized: "This agent is still running in Coincide’s agent host, which Coincide can’t reach right now. Coincide shows its work once it reconnects, or once the agent finishes.")
        case .runningInAnotherThread:
            String(localized: "This agent session is already running in another thread.")
        }
    }
}

extension AgentHostIdentity {
    /// The Team ID the running process is signed with, nil for an ad-hoc or unsigned build. Both sides only talk
    /// to code signed by the same team, so such a build cannot use the host.
    public nonisolated static func currentTeam() -> String? {
        var code: SecCode?
        guard SecCodeCopySelf([], &code) == errSecSuccess, let code else { return nil }
        var staticCode: SecStaticCode?
        guard SecCodeCopyStaticCode(code, [], &staticCode) == errSecSuccess, let staticCode else { return nil }
        var info: CFDictionary?
        guard SecCodeCopySigningInformation(staticCode, SecCSFlags(rawValue: kSecCSSigningInformation), &info) == errSecSuccess,
            let team = (info as? [String: Any])?[kSecCodeInfoTeamIdentifier as String] as? String, !team.isEmpty
        else { return nil }
        return team
    }

    /// Code signed by `team` with `identifier`, for `NSXPCConnection.setCodeSigningRequirement(_:)`.
    public nonisolated static func requirement(identifier: String, team: String) -> String {
        "anchor apple generic and identifier \"\(identifier)\" and certificate leaf[subject.OU] = \"\(team)\""
    }
}

/// XPC to the LaunchAgent's Mach service. The host is started by launchd on the first message.
@MainActor
public final class XPCAgentHostTransport: NSObject, AgentHostTransport, AgentHostClientXPC {
    public var onPush: ((AgentHostPush) -> Void)?
    public var onDisconnect: (() -> Void)?
    private var connection: NSXPCConnection?

    /// `requirement` is what the host must be signed with (`AgentHostIdentity.requirement`).
    public init(machServiceName: String = AgentHostIdentity.machServiceName, requirement: String) {
        super.init()
        let connection = NSXPCConnection(machServiceName: machServiceName, options: [])
        connection.remoteObjectInterface = NSXPCInterface(with: AgentHostXPC.self)
        connection.exportedInterface = NSXPCInterface(with: AgentHostClientXPC.self)
        connection.exportedObject = self
        connection.setCodeSigningRequirement(requirement)
        // An interrupted connection would reach a new host that knows nothing of this app's attachments, so
        // either way the connection is over and the app connects afresh.
        connection.interruptionHandler = { [weak connection] in connection?.invalidate() }
        connection.invalidationHandler = { [weak self] in
            DispatchQueue.main.async { MainActor.assumeIsolated { self?.didDisconnect() } }
        }
        self.connection = connection
        connection.resume()
    }

    private func didDisconnect() {
        guard connection != nil else { return }
        // The connection holds its exported object, this; letting go of it ends the cycle.
        connection?.exportedObject = nil
        connection = nil
        let handler = onDisconnect
        onDisconnect = nil
        handler?()
    }

    public func invalidate() {
        connection?.invalidate()
    }

    nonisolated public func receive(_ push: Data) {
        guard let decoded = try? AgentHostWire.decode(AgentHostPush.self, from: push) else { return }
        // The main queue keeps pushes in the order they arrived.
        DispatchQueue.main.async { MainActor.assumeIsolated { self.onPush?(decoded) } }
    }

    public func hello(_ hello: AgentHostHello) async throws -> AgentHostWelcome {
        let data = try AgentHostWire.encode(hello)
        let reply = try await call { proxy, reply in proxy.hello(data, reply: reply) }
        do {
            return try AgentHostWire.decode(AgentHostWelcome.self, from: reply)
        } catch {
            throw AgentHostError.unreadableReply
        }
    }

    public func perform(_ command: AgentHostCommand) async throws -> AgentHostReply {
        let data = try AgentHostWire.encode(command)
        let reply = try await call { proxy, reply in proxy.perform(data, reply: reply) }
        do {
            return try AgentHostWire.decode(AgentHostReply.self, from: reply)
        } catch {
            throw AgentHostError.unreadableReply
        }
    }

    public func retireWhenIdle() {
        (connection?.remoteObjectProxy as? AgentHostXPC)?.retireWhenIdle()
    }

    /// How a hello at launch went.
    public enum HelloOutcome {
        case welcome(AgentHostWelcome)
        /// The connection failed or the reply was unreadable. Among the causes: macOS refused the host's signature
        /// because an update replaced its files while it ran (`retireUnverifiedHost`).
        case refused
        /// No answer in time: the host may be starting, or busy.
        case timedOut
    }

    /// The hello for launch, before any window shows, waiting at most `timeout` seconds. The app needs to know
    /// which threads the host still runs agents for before it reads their transcripts.
    public func helloSynchronously(_ hello: AgentHostHello, timeout: TimeInterval) -> HelloOutcome {
        guard let connection, let data = try? AgentHostWire.encode(hello) else { return .refused }
        let box = ReplyBox()
        let proxy = connection.remoteObjectProxyWithErrorHandler { @Sendable _ in box.finish(nil) } as? AgentHostXPC
        proxy?.hello(data) { @Sendable reply in box.finish(reply) }
        switch box.wait(timeout: timeout) {
        case .timedOut:
            return .timedOut
        case .finished(let reply):
            guard let reply, let welcome = try? AgentHostWire.decode(AgentHostWelcome.self, from: reply) else { return .refused }
            return .welcome(welcome)
        }
    }

    /// Asks whatever answers on the host's Mach service to exit once nothing runs in it, without checking its
    /// signature, which is what refused it. For a host the app could not accept: a host whose files an update replaced
    /// while it ran no longer passes macOS's signature check, so the app can't use it, and each attempt to connect
    /// would keep it from ever exiting idle. The message carries no data, so nothing reaches a host that isn't ours.
    public static func retireUnverifiedHost(machServiceName: String = AgentHostIdentity.machServiceName) {
        let connection = NSXPCConnection(machServiceName: machServiceName, options: [])
        connection.remoteObjectInterface = NSXPCInterface(with: AgentHostXPC.self)
        connection.resume()
        (connection.remoteObjectProxyWithErrorHandler { @Sendable _ in } as? AgentHostXPC)?.retireWhenIdle()
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(2))
            connection.invalidate()
        }
    }

    public func acknowledgeSynchronously(_ acknowledgements: [AgentSessionKey: Int], timeout: TimeInterval) {
        guard let connection, !acknowledgements.isEmpty else { return }
        let deadline = Date().addingTimeInterval(timeout)
        for (key, sequence) in acknowledgements {
            guard let data = try? AgentHostWire.encode(AgentHostCommand.acknowledge(key: key, sequence: sequence)) else { continue }
            let box = ReplyBox()
            let proxy = connection.remoteObjectProxyWithErrorHandler { @Sendable _ in box.finish(nil) } as? AgentHostXPC
            proxy?.perform(data) { @Sendable reply in box.finish(reply) }
            guard case .finished(_?) = box.wait(timeout: max(0, deadline.timeIntervalSinceNow)) else { return }
        }
    }

    private func call(_ body: (AgentHostXPC, @escaping @Sendable (Data) -> Void) -> Void) async throws -> Data {
        guard let connection else { throw AgentHostError.disconnected }
        return try await withCheckedThrowingContinuation { continuation in
            let once = Once(continuation)
            let proxy = connection.remoteObjectProxyWithErrorHandler { @Sendable _ in once.resume(throwing: AgentHostError.disconnected) }
            guard let host = proxy as? AgentHostXPC else {
                once.resume(throwing: AgentHostError.disconnected)
                return
            }
            body(host) { once.resume(returning: $0) }
        }
    }

    /// XPC calls either the reply or the error handler; this makes sure the continuation resumes once. The handlers are
    /// `@Sendable` so they don't inherit main-actor isolation: XPC calls them on its own queue, where an isolation
    /// check would trap (a failed hello at launch crashed the app this way).
    private final class Once: @unchecked Sendable {
        private let lock = NSLock()
        private var continuation: CheckedContinuation<Data, Error>?

        nonisolated init(_ continuation: CheckedContinuation<Data, Error>) { self.continuation = continuation }

        nonisolated func resume(returning data: Data) { take()?.resume(returning: data) }
        nonisolated func resume(throwing error: Error) { take()?.resume(throwing: error) }

        private nonisolated func take() -> CheckedContinuation<Data, Error>? {
            lock.lock()
            defer { lock.unlock() }
            let taken = continuation
            continuation = nil
            return taken
        }
    }

    private final class ReplyBox: @unchecked Sendable {
        private let semaphore = DispatchSemaphore(value: 0)
        private let lock = NSLock()
        private var data: Data?
        private var done = false

        nonisolated func finish(_ value: Data?) {
            lock.lock()
            guard !done else {
                lock.unlock()
                return
            }
            done = true
            data = value
            lock.unlock()
            semaphore.signal()
        }

        enum Outcome {
            /// The reply, or nil when the error handler ran instead.
            case finished(Data?)
            case timedOut
        }

        nonisolated func wait(timeout: TimeInterval) -> Outcome {
            guard semaphore.wait(timeout: .now() + timeout) == .success else { return .timedOut }
            lock.lock()
            defer { lock.unlock() }
            return .finished(data)
        }
    }
}

/// The host's engine in this process, as if over XPC: for tests, which cannot register a LaunchAgent.
@MainActor
public final class InProcessAgentHostTransport: AgentHostTransport, AgentHostSubscriber {
    public var onPush: ((AgentHostPush) -> Void)?
    public var onDisconnect: (() -> Void)?
    public let core: AgentHostCore
    private var client: AgentHostCore.Client?

    public init(core: AgentHostCore) {
        self.core = core
        client = core.connect(self)
    }

    public func deliver(_ push: AgentHostPush) {
        // Through the wire format, so tests catch what XPC would not carry.
        guard let data = try? AgentHostWire.encode(push), let decoded = try? AgentHostWire.decode(AgentHostPush.self, from: data)
        else { return }
        onPush?(decoded)
    }

    public func hello(_ hello: AgentHostHello) async throws -> AgentHostWelcome {
        guard client != nil else { throw AgentHostError.disconnected }
        return core.hello(hello)
    }

    public func perform(_ command: AgentHostCommand) async throws -> AgentHostReply {
        guard let client else { throw AgentHostError.disconnected }
        let data = try AgentHostWire.encode(command)
        return await core.perform(try AgentHostWire.decode(AgentHostCommand.self, from: data), from: client)
    }

    public func retireWhenIdle() { core.retireWhenIdle() }

    public func acknowledgeSynchronously(_ acknowledgements: [AgentSessionKey: Int], timeout: TimeInterval) {
        for (key, sequence) in acknowledgements { core.acknowledge(key, through: sequence) }
    }

    /// Ends the connection, as the app quitting does.
    public func invalidate() {
        guard let client else { return }
        self.client = nil
        core.disconnect(client)
        let handler = onDisconnect
        onDisconnect = nil
        handler?()
    }
}
