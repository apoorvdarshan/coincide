import Foundation
import Observation

/// What starts a custom ACP agent outside a thread (`ProviderRegistry.acpLaunch(for:)`).
public struct ACPAgentLaunch: Sendable {
    public var name: String
    public var executable: URL
    public var arguments: [String]
    /// The full environment the agent runs with.
    public var environment: [String: String]
    /// The registry's part of it, which a Terminal sign-in also gets. The user's own variables (which may hold keys)
    /// never go into a Terminal command.
    public var registryEnvironment: [String: String]

    public nonisolated init(
        name: String, executable: URL, arguments: [String], environment: [String: String],
        registryEnvironment: [String: String] = [:]
    ) {
        self.name = name
        self.executable = executable
        self.arguments = arguments
        self.environment = environment
        self.registryEnvironment = registryEnvironment
    }
}

/// Signing in to a custom ACP agent from Settings with the methods it advertises (T3 Code's `AcpRegistryAuth`).
///
/// - An `agent` method: Coincide starts the agent and calls `authenticate`; the agent signs in by itself. When it
///   asks to open a page (a URL elicitation), Coincide shows the address and tells the agent to go on only once the
///   user opens it, as T3 Code waits for consent. A test session then confirms the sign-in.
/// - A `terminal` method runs its command in Terminal (`terminalCommand`), and Check Again confirms it.
/// - An `env_var` method needs the variables it names in the agent's environment variables.
///
/// Sign-in leaves credentials in the agent's own store; Coincide keeps none.
@MainActor
@Observable
public final class ACPAgentSignIn {
    public enum Phase: String, Sendable {
        case idle, discovering, signingIn, verifying, signingOut, succeeded, failed, cancelled
    }

    /// One per agent, so a sign-in keeps running while Settings shows another page.
    public static func shared(for kind: ProviderKind) -> ACPAgentSignIn {
        if let existing = instances[kind] { return existing }
        let created = ACPAgentSignIn()
        instances[kind] = created
        return created
    }

    private static var instances: [ProviderKind: ACPAgentSignIn] = [:]

    public private(set) var phase: Phase = .idle
    /// The methods the agent advertised the last time it started.
    public private(set) var methods: [ACPAuthMethod] = []
    public private(set) var hasDiscovered = false
    public private(set) var canLogout = false
    public private(set) var message: String?
    /// A page the agent asks the user to open, waiting for consent.
    public private(set) var pendingURL: URL?

    public var isActive: Bool { [.discovering, .signingIn, .verifying, .signingOut].contains(phase) }

    @ObservationIgnored private let makeTransport: ACPTransportFactory?
    @ObservationIgnored private let timeout: TimeInterval
    @ObservationIgnored private var flow: Flow?

    @MainActor
    private final class Flow {
        var process: ACPHelperProcess?
        var lease: ACPLaunchLease?
        var elicitation: ACPConnection.IncomingRequest?
        var timer: Task<Void, Never>?
        var workspace: URL?
    }

    /// `transport` replaces the real process in tests.
    public init(transport: ACPTransportFactory? = nil, timeout: TimeInterval = 300) {
        makeTransport = transport
        self.timeout = timeout
    }

    // MARK: Methods

    /// Starts the agent once to list its sign-in methods.
    public func discover(_ launch: ACPAgentLaunch) {
        begin(.discovering, String(localized: "Asking \(launch.name) how it signs in.")) { flow in
            let (_, initialized) = try await self.start(launch, flow: flow, elicitations: false)
            self.finish(flow, .idle, initialized.authMethods.isEmpty ? String(localized: "\(launch.name) doesn’t advertise a sign-in method.") : nil)
        }
    }

    /// Signs in with an `agent` method.
    public func signIn(methodID: String, _ launch: ACPAgentLaunch) {
        begin(.signingIn, String(localized: "Signing in to \(launch.name).")) { flow in
            let (process, initialized) = try await self.start(launch, flow: flow, elicitations: true)
            guard let method = initialized.authMethods.first(where: { $0.id == methodID }) else {
                return self.finish(flow, .failed, String(localized: "\(launch.name) no longer offers this sign-in method."))
            }
            guard method.isAgentDriven else {
                return self.finish(flow, .failed, String(localized: "This sign-in method can’t run inside Coincide."))
            }
            try await process.client.authenticate(methodID: methodID, timeout: self.timeout + 30)
            guard self.flow === flow else { return }
            self.pendingURL = nil
            self.phase = .verifying
            self.message = String(localized: "Checking that \(launch.name) is signed in.")
            let workspace = flow.workspace ?? FileManager.default.temporaryDirectory
            let setup = try await process.client.newSession(cwd: workspace, timeout: 60)
            if let id = setup.sessionID, initialized.closeSession { process.client.closeSession(id: id, timeout: 2) {} }
            self.finish(flow, .succeeded, String(localized: "Signed in to \(launch.name)."))
        }
    }

    /// Signs out with the agent's own `logout`, for an agent that advertises it.
    public func signOut(_ launch: ACPAgentLaunch) {
        begin(.signingOut, String(localized: "Signing out of \(launch.name).")) { flow in
            let (process, initialized) = try await self.start(launch, flow: flow, elicitations: false)
            guard initialized.canLogout, !initialized.authMethods.isEmpty else {
                return self.finish(flow, .failed, String(localized: "\(launch.name) can’t sign out from Coincide."))
            }
            try await process.client.logout(timeout: 60)
            self.finish(flow, .succeeded, String(localized: "Signed out of \(launch.name)."))
        }
    }

    /// Tells the agent to go on with the page it asked to open; the caller opens `pendingURL` in the browser.
    public func acceptPendingURL() {
        guard let flow, let request = flow.elicitation else { return }
        flow.elicitation = nil
        pendingURL = nil
        flow.process?.client.respondToElicitation(request, action: "accept")
        message = String(localized: "Finish signing in in your browser.")
    }

    /// Stops the running sign-in, discovery or sign-out.
    public func cancel() {
        guard let flow else { return }
        finish(flow, .cancelled, String(localized: "Sign-in was cancelled."))
    }

    // MARK: Terminal methods

    /// The command a `terminal` method runs, quoted for a shell (T3 Code's `terminalAuthCommand`): the method's and
    /// the registry's environment, then the agent's executable, its arguments and the method's arguments.
    public nonisolated static func terminalCommand(_ method: ACPAuthMethod, _ launch: ACPAgentLaunch) -> String {
        let environment = launch.registryEnvironment.merging(method.environment) { $1 }
            .filter { $0.key.range(of: #"^[A-Za-z_][A-Za-z0-9_]*$"#, options: .regularExpression) != nil }
            .sorted { $0.key < $1.key }.map { "\($0.key)=\(shellQuoted($0.value))" }
        let command = ([launch.executable.path] + launch.arguments + method.arguments).map(shellQuoted)
        return (environment + command).joined(separator: " ")
    }

    /// T3 Code's `shellDisplayToken`.
    nonisolated static func shellQuoted(_ token: String) -> String {
        token.range(of: #"^[A-Za-z0-9_@%+=:,./-]+$"#, options: .regularExpression) != nil
            ? token : "'" + token.replacingOccurrences(of: "'", with: #"'\''"#) + "'"
    }

    // MARK: Running

    private func begin(_ phase: Phase, _ message: String, _ body: @escaping @MainActor (Flow) async throws -> Void) {
        guard !isActive else { return }
        let flow = Flow()
        self.flow = flow
        self.phase = phase
        self.message = message
        pendingURL = nil
        flow.timer = Task { [weak self, timeout] in
            try? await Task.sleep(for: .seconds(timeout))
            guard !Task.isCancelled, let self, self.flow === flow else { return }
            self.finish(flow, .failed, String(localized: "Sign-in timed out. Try again."))
        }
        Task { [weak self] in
            do {
                try await body(flow)
            } catch {
                guard let self, self.flow === flow else { return }
                let text =
                    (error as? ACPError)?.code == ACPError.authRequired
                    ? String(localized: "The agent still needs a sign-in.") : error.localizedDescription
                self.finish(flow, .failed, text)
            }
        }
    }

    private func start(
        _ launch: ACPAgentLaunch, flow: Flow, elicitations: Bool
    ) async throws -> (ACPHelperProcess, ACPInitializeResult) {
        let workspace = FileManager.default.temporaryDirectory
            .appendingPathComponent("coincide-acp-signin-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)
        flow.workspace = workspace
        let process = ACPHelperProcess(
            executable: launch.executable, arguments: launch.arguments, workingDirectory: workspace,
            environment: launch.environment, name: launch.name, transport: makeTransport)
        flow.process = process
        flow.lease = ACPRegistryTools.shared.lease(for: launch.executable)
        if elicitations {
            process.client.onElicitation = { [weak self, weak flow, weak process] request, incoming in
                guard let self, let flow, self.flow === flow else {
                    process?.client.respondToElicitation(incoming, action: "cancel")
                    return
                }
                self.received(request, incoming, flow: flow)
            }
            process.client.onElicitationComplete = { [weak self, weak flow] _ in
                guard let self, let flow, self.flow === flow, flow.elicitation != nil else { return }
                flow.elicitation = nil
                self.pendingURL = nil
            }
        }
        try process.start()
        // As T3 Code signs in: no files or terminals, and pages to open only while signing in.
        let capabilities = ACPClientCapabilities(elicitationForms: false, elicitationURLs: elicitations)
        let initialized = try await process.client.initialize(capabilities: capabilities, clientInfo: ACPSession.clientInfo, timeout: 60)
        guard self.flow === flow else { throw CancellationError() }
        methods = Array(initialized.authMethods.prefix(32))
        canLogout = initialized.canLogout
        hasDiscovered = true
        return (process, initialized)
    }

    /// A page to open during sign-in: only a web address, one at a time, and only once the user agrees.
    private func received(_ request: ACPElicitationRequest, _ incoming: ACPConnection.IncomingRequest, flow: Flow) {
        guard request.mode == "url", flow.elicitation == nil, let text = request.url, text.utf8.count <= 2_048,
            let url = URL(string: text), ["https", "http"].contains(url.scheme?.lowercased() ?? ""), url.host?.isEmpty == false
        else {
            flow.process?.client.respondToElicitation(incoming, action: "decline")
            return
        }
        flow.elicitation = incoming
        pendingURL = url
        message = ACPToolCallState.nonEmpty(request.message).map { String($0.prefix(512)) }
            ?? String(localized: "Open the sign-in page to continue.")
    }

    private func finish(_ flow: Flow, _ phase: Phase, _ message: String?) {
        guard self.flow === flow else { return }
        self.flow = nil
        flow.timer?.cancel()
        if let request = flow.elicitation { flow.process?.client.respondToElicitation(request, action: "cancel") }
        flow.elicitation = nil
        self.phase = phase
        self.message = message
        pendingURL = nil
        let process = flow.process
        let workspace = flow.workspace
        let lease = flow.lease
        flow.lease = nil
        process?.stop()
        Task {
            await process?.waitForExit(timeout: 5)
            lease?.release()
            if let workspace { try? FileManager.default.removeItem(at: workspace) }
        }
    }
}
