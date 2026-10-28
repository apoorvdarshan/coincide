import Foundation
import Network
import Observation

/// A sign-in problem, with a message that is safe to show as it is.
public struct AntigravitySignInError: LocalizedError, Equatable {
    public var message: String

    public nonisolated init(_ message: String) {
        self.message = message
    }

    public nonisolated var errorDescription: String? { message }
}

/// Google sign-in for Antigravity's private profile, started from Settings (T3 Code's `AntigravityAuth`).
///
/// Coincide starts Antigravity in a throwaway folder and asks it to sign in with Google. Antigravity
/// would open a browser; the profile's browser helper hands the link to Coincide instead, which shows
/// it with Open and Copy buttons. When the browser runs on this Mac, Google's answer reaches the agent
/// directly. When it runs elsewhere, the user pastes the address the browser ended on, and Coincide
/// checks it belongs to this sign-in and forwards it to the agent's loopback port. Only the agent's own
/// answer counts as success; Coincide then opens a session to check access and load the models.
@MainActor
@Observable
public final class AntigravitySignIn {
    public enum Phase: String, Sendable {
        case idle, starting, waiting, verifying, succeeded, failed, cancelled
    }

    public static let shared = AntigravitySignIn()

    public private(set) var phase: Phase = .idle
    /// The Google sign-in link, while Coincide waits for the user to finish in a browser.
    public private(set) var authorization: AntigravityAuthorization?
    public private(set) var message: String?
    public private(set) var expiresAt: Date?
    public private(set) var isSigningOut = false
    /// Models the account may use, found by the last successful sign-in.
    public private(set) var models: [ModelOption] = []

    public var isActive: Bool { phase == .starting || phase == .waiting || phase == .verifying }
    /// Whether a pasted address can be sent now.
    public var acceptsCallback: Bool { phase == .waiting && authorization != nil && flow?.callbackSent == false }

    @ObservationIgnored private let profile: AntigravityProfile
    @ObservationIgnored private let runtime: AntigravityRuntime?
    @ObservationIgnored private let makeTransport: ACPTransportFactory?
    @ObservationIgnored private let forward: @Sendable (URL) async throws -> Void
    @ObservationIgnored private let timeout: TimeInterval
    @ObservationIgnored private let noResponseHint: TimeInterval
    @ObservationIgnored private var flow: Flow?

    /// How much longer than the sign-in itself the agent's `authenticate` request may wait.
    private static let requestTimeoutMargin: TimeInterval = 60

    /// `runtime` leases the downloaded release the agent runs from; `transport` and `forward` replace
    /// the real process and HTTP delivery in tests.
    public init(
        profile: AntigravityProfile = .standard, runtime: AntigravityRuntime? = .shared, transport: ACPTransportFactory? = nil,
        forward: @escaping @Sendable (URL) async throws -> Void = { try await AntigravityCallback.forward($0) },
        timeout: TimeInterval = 300, noResponseHint: TimeInterval = 30
    ) {
        self.profile = profile
        self.runtime = runtime
        makeTransport = transport
        self.forward = forward
        self.timeout = timeout
        self.noResponseHint = noResponseHint
    }

    @MainActor
    private final class Flow {
        var process: AntigravityAgentProcess?
        var pending: AntigravityAuthorization?
        var callbackSent = false
        var task: Task<Void, Never>?
        var timer: Task<Void, Never>?
        var stage = "initialize"
    }

    // MARK: Signing in

    /// Starts Google sign-in with `executable`. Does nothing while a sign-in or sign-out runs.
    public func start(executable: URL, environment: [String: String]) {
        guard !isActive, !isSigningOut else { return }
        let flow = Flow()
        self.flow = flow
        phase = .starting
        authorization = nil
        message = String(localized: "Starting Google sign-in.")
        expiresAt = Date().addingTimeInterval(timeout)
        flow.timer = Task { [weak self, noResponseHint, timeout] in
            try? await Task.sleep(for: .seconds(noResponseHint))
            guard let self, self.flow === flow else { return }
            if self.phase == .starting {
                // A healthy agent shows the link within seconds; Antigravity's Python has no IPv4
                // fallback, so a network with broken IPv6 waits about two minutes per request.
                self.message = String(
                    localized:
                        "Antigravity hasn’t reached Google after 30 seconds. Check this Mac’s network connection; broken IPv6 is a common cause.")
            }
            try? await Task.sleep(for: .seconds(max(0, timeout - noResponseHint)))
            guard !Task.isCancelled, self.flow === flow else { return }
            self.finish(
                flow, .failed,
                self.phase == .starting
                    ? String(localized: "Antigravity couldn’t reach Google. Check this Mac’s network connection, then start sign-in again.")
                    : String(localized: "Google sign-in expired. Start sign-in again."))
        }
        flow.task = Task { [weak self] in await self?.run(flow, executable: executable, environment: environment) }
    }

    /// Stops the running sign-in. Google is not told; the link simply stops working.
    public func cancel() {
        guard let flow else { return }
        finish(flow, .cancelled, String(localized: "Google sign-in was cancelled."))
    }

    /// Sends the address the browser ended on to the waiting agent (for a browser on another device).
    /// Throws, with a message to show, when the address does not belong to this sign-in or cannot be
    /// delivered. Success here is not yet a sign-in: that comes from the agent.
    public func complete(callback text: String) async throws {
        guard let flow, let pending = flow.pending, !flow.callbackSent, phase == .waiting else {
            throw AntigravitySignInError(
                flow?.callbackSent == true
                    ? String(localized: "The sign-in response was already sent. Wait for Google to finish.")
                    : String(localized: "Wait for the Google sign-in link before you paste an address."))
        }
        if let expiresAt, Date() >= expiresAt {
            throw AntigravitySignInError(String(localized: "Google sign-in expired. Start sign-in again."))
        }
        let callback = try AntigravityCallback.validate(text.trimmingCharacters(in: .whitespacesAndNewlines), for: pending)
        flow.callbackSent = true
        phase = .verifying
        authorization = nil
        message = String(localized: "Waiting for Google to finish sign-in.")
        do {
            try await forward(callback)
        } catch {
            let message = String(localized: "Couldn’t deliver the sign-in response. Start sign-in again.")
            finish(flow, .failed, message)
            throw AntigravitySignInError(message)
        }
    }

    private func run(_ flow: Flow, executable: URL, environment: [String: String]) async {
        let workspace = FileManager.default.temporaryDirectory
            .appendingPathComponent("coincide-antigravity-setup-\(UUID().uuidString)", isDirectory: true)
        var sessionID: String?
        do {
            try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)
            try await profile.prepare(environment: environment)
            guard self.flow === flow else { return cleanUp(flow, workspace: workspace, sessionID: nil) }
            let process = AntigravityAgentProcess(
                executable: executable, workingDirectory: workspace,
                environment: profile.environment(environment, harness: AntigravityFlavor.harnessURL(for: executable)),
                transport: makeTransport, lease: runtime?.lease(for: executable))
            flow.process = process
            process.onOutputLine = { [weak self, weak flow] line in
                guard let self, let flow else { return }
                self.received(line, flow: flow)
            }
            try process.start()
            let initialized = try await process.client.initialize(
                capabilities: ACPClientCapabilities(), clientInfo: ACPSession.clientInfo, timeout: 180)
            flow.stage = "authenticate"
            // The flow's timer ends the wait with the right explanation (Google unreachable, or the link expired) and
            // stops the agent, which fails this request. The request's own timeout only backs that up, so it must
            // not run out first: it starts later and would report a bare "sign-in failed".
            try await process.client.authenticate(
                methodID: AntigravityFlavor.authMethodID, timeout: timeout + Self.requestTimeoutMargin)
            guard self.flow === flow else { return cleanUp(flow, workspace: workspace, sessionID: nil) }
            flow.pending = nil
            phase = .verifying
            authorization = nil
            message = String(localized: "Checking Antigravity access and models.")
            flow.stage = "session/new"
            let setup = try await process.client.newSession(cwd: workspace, timeout: 60)
            sessionID = setup.sessionID
            guard self.flow === flow else { return cleanUp(flow, workspace: workspace, sessionID: sessionID) }
            let models = AntigravityFlavor().models(initialize: initialized, setup: setup)
            self.models = models
            AntigravityFlavor.knownModels[profile.geminiHome.path] = models
            finish(flow, .succeeded, String(localized: "Signed in with Google."))
        } catch {
            if self.flow === flow { finish(flow, .failed, Self.failureMessage(error, stage: flow.stage)) }
        }
        cleanUp(flow, workspace: workspace, sessionID: sessionID)
    }

    /// Picks up the sign-in link from either the agent's own line or the browser helper.
    private func received(_ line: String, flow: Flow) {
        guard self.flow === flow, phase == .starting || phase == .waiting,
            let text = AntigravityFlavor.authorizationText(in: line), let request = AntigravityAuthorization.parse(text)
        else { return }
        if let pending = flow.pending {
            guard pending.url != request.url else { return }
            finish(flow, .failed, String(localized: "Antigravity started more than one Google sign-in request. Start sign-in again."))
            return
        }
        flow.pending = request
        authorization = request
        phase = .waiting
        message = String(
            localized:
                "Open the Google sign-in page and finish there. If your browser is on another device, paste the address it ends on here.")
    }

    private func finish(_ flow: Flow, _ phase: Phase, _ message: String) {
        guard self.flow === flow else { return }
        self.flow = nil
        self.phase = phase
        self.message = message
        authorization = nil
        expiresAt = nil
        flow.pending = nil
        flow.timer?.cancel()
        // Fails the agent's pending requests, so `run` ends at once.
        flow.process?.stop()
    }

    private func cleanUp(_ flow: Flow, workspace: URL, sessionID: String?) {
        let process = flow.process
        process?.stop()
        let profile = profile
        Task {
            await process?.waitForExit(timeout: 5)
            if let sessionID { profile.removeSessionFiles(sessionID: sessionID, cwd: workspace) }
            try? FileManager.default.removeItem(at: workspace)
        }
    }

    /// T3 Code's `safeAuthFailure`: what went wrong, without anything the agent printed.
    nonisolated static func failureMessage(_ error: Error, stage: String) -> String {
        if let error = error as? AntigravityProfileError { return error.message }
        if let error = error as? AntigravitySignInError { return error.message }
        if let error = error as? ACPError {
            if error.message.contains("SUBSCRIPTION_REQUIRED") {
                return String(localized: "Google requires an eligible Antigravity subscription for this account.")
            }
            if error.message.range(of: "access_denied|denied access|cancelled", options: [.regularExpression, .caseInsensitive]) != nil {
                return String(localized: "Google sign-in wasn’t approved. Start sign-in again.")
            }
            if stage == "session/new", error.code == ACPError.internalError {
                return String(localized: "Antigravity signed in, but couldn’t start a session or load models.")
            }
        }
        return String(localized: "Google sign-in failed. Start sign-in again.")
    }

    // MARK: Signing out

    /// Signs the private profile out of Google with Antigravity's own `logout`, which removes only
    /// the credentials of the profile's sign-in method. Cancels a sign-in that is running.
    public func signOut(executable: URL, environment: [String: String]) async throws {
        guard !isSigningOut else { return }
        if let flow { finish(flow, .cancelled, String(localized: "Google sign-in was cancelled by sign-out.")) }
        isSigningOut = true
        defer { isSigningOut = false }
        let workspace = FileManager.default.temporaryDirectory
            .appendingPathComponent("coincide-antigravity-setup-\(UUID().uuidString)", isDirectory: true)
        var process: AntigravityAgentProcess?
        defer {
            process?.stop()
            Task { [process] in
                await process?.waitForExit(timeout: 5)
                try? FileManager.default.removeItem(at: workspace)
            }
        }
        do {
            try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)
            try await profile.prepare(environment: environment)
            let started = AntigravityAgentProcess(
                executable: executable, workingDirectory: workspace,
                environment: profile.environment(environment, harness: AntigravityFlavor.harnessURL(for: executable)),
                transport: makeTransport, lease: runtime?.lease(for: executable))
            process = started
            try started.start()
            let initialized = try await started.client.initialize(
                capabilities: ACPClientCapabilities(), clientInfo: ACPSession.clientInfo, timeout: 90)
            guard initialized.canLogout else {
                throw AntigravitySignInError(String(localized: "This Antigravity version can’t sign out. Update Antigravity."))
            }
            _ = try await started.client.connection.request("logout", params: [:], timeout: 90)
        } catch {
            let text =
                (error as? AntigravitySignInError)?.message ?? (error as? AntigravityProfileError)?.message
                ?? String(localized: "Antigravity sign-out failed. Try again.")
            phase = .failed
            message = text
            throw AntigravitySignInError(text)
        }
        models = []
        AntigravityFlavor.knownModels[profile.geminiHome.path] = nil
        // The quota checks' access token belongs to the account that just signed out.
        AntigravityUsageProbe.shared.clear()
        phase = .idle
        message = String(localized: "Signed out of Google.")
    }
}

// MARK: - Callback

/// Checks and delivers the address a browser ended on after Google sign-in (T3 Code's
/// `antigravityCallback.ts`).
public enum AntigravityCallback {
    /// The callback for `pending`: its loopback origin and path, its state, and exactly one code or
    /// error from Google. Throws with a message to show otherwise.
    public nonisolated static func validate(_ text: String, for pending: AntigravityAuthorization) throws -> URL {
        guard text.utf8.count <= AntigravityAuthorization.maxLength else {
            throw AntigravitySignInError(String(localized: "The sign-in response address is too long."))
        }
        guard let callback = URLComponents(string: text), callback.scheme != nil, callback.host != nil, let url = callback.url else {
            throw AntigravitySignInError(String(localized: "Paste the complete address from the Google sign-in page."))
        }
        let mismatch = AntigravitySignInError(String(localized: "This address doesn’t belong to the current sign-in."))
        guard let expected = URLComponents(string: pending.redirectURI), callback.scheme?.lowercased() == "http",
            callback.host == "127.0.0.1", callback.port == expected.port, path(callback) == path(expected),
            callback.user == nil, callback.password == nil, callback.fragment == nil
        else { throw mismatch }
        guard AntigravityAuthorization.formValues(callback, "state") == [pending.state] else { throw mismatch }
        let codes = AntigravityAuthorization.formValues(callback, "code")
        let errors = AntigravityAuthorization.formValues(callback, "error")
        guard (codes.count == 1 && codes[0] != "" && errors.isEmpty) || (errors.count == 1 && errors[0] != "" && codes.isEmpty) else {
            throw AntigravitySignInError(String(localized: "The address must contain one Google sign-in response."))
        }
        let issuers = AntigravityAuthorization.formValues(callback, "iss")
        guard issuers.isEmpty || issuers == ["https://accounts.google.com"] else {
            throw AntigravitySignInError(String(localized: "The address isn’t a Google sign-in response."))
        }
        return url
    }

    private nonisolated static func path(_ components: URLComponents) -> String {
        components.percentEncodedPath.isEmpty ? "/" : components.percentEncodedPath
    }

    /// Sends one `GET` to the agent's loopback listener, with no proxy and no redirects, and succeeds
    /// on a 2xx answer.
    public nonisolated static func forward(_ callback: URL, timeout: TimeInterval = 10) async throws {
        let failed = AntigravitySignInError(String(localized: "Couldn’t deliver the sign-in response. Start sign-in again."))
        guard let components = URLComponents(url: callback, resolvingAgainstBaseURL: false), components.host == "127.0.0.1",
            let port = components.port, let endpointPort = NWEndpoint.Port(rawValue: UInt16(clamping: port)), port > 0, port <= 65_535
        else { throw failed }
        let target = path(components) + (components.percentEncodedQuery.map { "?" + $0 } ?? "")
        guard target.unicodeScalars.allSatisfy({ $0.isASCII && $0.value > 0x20 && $0.value < 0x7F }) else { throw failed }
        let request = "GET \(target) HTTP/1.1\r\nHost: 127.0.0.1:\(port)\r\nAccept: */*\r\nConnection: close\r\n\r\n"
        let exchange = LoopbackExchange(port: endpointPort, request: Data(request.utf8))
        let status = try await AntigravityInstaller.withTimeout(
            timeout, timeoutError: AntigravitySignInError(String(localized: "The sign-in response timed out. Start sign-in again."))
        ) {
            try await withTaskCancellationHandler {
                try await exchange.run()
            } onCancel: {
                exchange.cancel()
            }
        }
        guard (200..<300).contains(status) else { throw failed }
    }

    /// One HTTP/1.1 request over a fresh TCP connection to 127.0.0.1; returns the status code once the
    /// server has sent its whole answer.
    private final class LoopbackExchange: @unchecked Sendable {
        private let connection: NWConnection
        private let request: Data
        private let queue = DispatchQueue(label: "coincide.antigravity.callback")
        private let lock = NSLock()
        private var continuation: CheckedContinuation<Int, Error>?
        private var response = Data()

        nonisolated init(port: NWEndpoint.Port, request: Data) {
            let parameters = NWParameters.tcp
            parameters.preferNoProxies = true
            connection = NWConnection(host: "127.0.0.1", port: port, using: parameters)
            self.request = request
        }

        nonisolated func run() async throws -> Int {
            try await withCheckedThrowingContinuation { continuation in
                lock.withLock { self.continuation = continuation }
                connection.stateUpdateHandler = { [weak self] state in
                    switch state {
                    case .ready: self?.send()
                    case .failed, .waiting: self?.finish(nil)
                    case .cancelled: self?.finish(nil)
                    default: break
                    }
                }
                connection.start(queue: queue)
            }
        }

        nonisolated func cancel() {
            finish(nil)
        }

        private nonisolated func send() {
            connection.send(
                content: request,
                completion: .contentProcessed { [weak self] error in
                    if error != nil { self?.finish(nil) } else { self?.receive() }
                })
        }

        private nonisolated func receive() {
            connection.receive(minimumIncompleteLength: 1, maximumLength: 65_536) { [weak self] data, _, isComplete, error in
                guard let self else { return }
                if let data { self.lock.withLock { self.response.append(data) } }
                let size = self.lock.withLock { self.response.count }
                if isComplete || size >= 1 << 20 {
                    self.finish(self.statusCode())
                } else if error != nil {
                    self.finish(nil)
                } else {
                    self.receive()
                }
            }
        }

        private nonisolated func statusCode() -> Int? {
            let head = lock.withLock { response.prefix(64) }
            let line = String(decoding: head, as: UTF8.self).split(separator: "\r\n", maxSplits: 1).first ?? ""
            let parts = line.split(separator: " ")
            guard parts.count >= 2, parts[0].hasPrefix("HTTP/1."), let code = Int(parts[1]), (100...599).contains(code) else { return nil }
            return code
        }

        private nonisolated func finish(_ status: Int?) {
            let continuation = lock.withLock { () -> CheckedContinuation<Int, Error>? in
                defer { self.continuation = nil }
                return self.continuation
            }
            connection.cancel()
            guard let continuation else { return }
            if let status {
                continuation.resume(returning: status)
            } else {
                continuation.resume(throwing: AntigravitySignInError(String(localized: "Couldn’t deliver the sign-in response. Start sign-in again.")))
            }
        }
    }
}
