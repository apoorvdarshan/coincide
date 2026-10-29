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

    public nonisolated var errorDescription: String? {
        switch self {
        case .disconnected: String(localized: "Lost the connection to Coincide’s agent host.")
        case .unreadableReply: String(localized: "Coincide’s agent host sent a reply this version can’t read.")
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

    /// The hello for launch, before any window shows, waiting at most `timeout` seconds. The app needs to know
    /// which threads the host still runs agents for before it reads their transcripts.
    public func helloSynchronously(_ hello: AgentHostHello, timeout: TimeInterval) -> AgentHostWelcome? {
        guard let connection, let data = try? AgentHostWire.encode(hello) else { return nil }
        let box = ReplyBox()
        let proxy = connection.remoteObjectProxyWithErrorHandler { _ in box.finish(nil) } as? AgentHostXPC
        proxy?.hello(data) { box.finish($0) }
        guard let reply = box.wait(timeout: timeout) else { return nil }
        return try? AgentHostWire.decode(AgentHostWelcome.self, from: reply)
    }

    private func call(_ body: (AgentHostXPC, @escaping @Sendable (Data) -> Void) -> Void) async throws -> Data {
        guard let connection else { throw AgentHostError.disconnected }
        return try await withCheckedThrowingContinuation { continuation in
            let once = Once(continuation)
            let proxy = connection.remoteObjectProxyWithErrorHandler { _ in once.resume(throwing: AgentHostError.disconnected) }
            guard let host = proxy as? AgentHostXPC else {
                once.resume(throwing: AgentHostError.disconnected)
                return
            }
            body(host) { once.resume(returning: $0) }
        }
    }

    /// XPC calls either the reply or the error handler; this makes sure the continuation resumes once.
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

        nonisolated func wait(timeout: TimeInterval) -> Data? {
            guard semaphore.wait(timeout: .now() + timeout) == .success else { return nil }
            lock.lock()
            defer { lock.unlock() }
            return data
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
