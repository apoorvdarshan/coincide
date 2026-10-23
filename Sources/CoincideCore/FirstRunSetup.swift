import Foundation

/// Whether to show the welcome flow (T3 firstRun.logic.ts). Existing workspaces skip it.
public enum FirstRunDecision: Sendable, Equatable {
    case pending, app, wizard
    public static func decide(loaded: Bool, completed: Bool, projectCount: Int, threadCount: Int, enabled: Bool = true) -> Self {
        guard enabled else { return .app }
        guard loaded else { return .pending }
        if completed { return .app }
        return projectCount == 0 && threadCount == 0 ? .wizard : .app
    }
}

/// Install/sign-in readiness for the agents the welcome flow checks (T3
/// providerReadiness.logic.ts). A status command proves only what the CLI reports
/// about its own sign-in; it does not send a model request.
public enum ProviderReadiness: Sendable, Equatable {
    case checking
    case install
    case signIn(String?)
    case ready(String?)
    case attention(String)

    public enum Agent: String, CaseIterable, Identifiable, Sendable {
        case codex, claude
        public var id: String { rawValue }
        public var name: String { self == .codex ? "Codex" : "Claude Code" }
        public var executable: String { self == .codex ? "codex" : "claude" }
        /// The vendor's native installers, which keep the CLI's own updater working.
        public var installCommand: String {
            self == .codex ? "curl -fsSL https://chatgpt.com/codex/install.sh | sh" : "curl -fsSL https://claude.ai/install.sh | bash"
        }
        public var statusArguments: [String] { self == .codex ? ["login", "status"] : ["auth", "status"] }
        public func loginCommand(executable path: String? = nil) -> String {
            "\(Self.shellWord(path ?? executable)) \(self == .codex ? "login" : "auth login")"
        }
        static func shellWord(_ value: String) -> String {
            if value.range(of: #"^[A-Za-z0-9_./:-]+$"#, options: .regularExpression) != nil { return value }
            if value.hasPrefix("~/") { return "~/" + CLIShim.shellWord(String(value.dropFirst(2))) }
            return CLIShim.shellWord(value)
        }
    }

    public var isReady: Bool { if case .ready = self { true } else { false } }

    /// Exit status 0 means signed in. A non-zero status whose output says the user is
    /// signed out asks for sign-in; anything else needs attention rather than a guess.
    public static func classify(status: Int32?, output: String, timedOut: Bool) -> Self {
        let text = output.trimmingCharacters(in: .whitespacesAndNewlines)
        let firstLine = text.split(separator: "\n").first.map { String($0.prefix(200)) }
        if timedOut { return .attention(String(localized: "The sign-in check did not finish.")) }
        let lowered = text.lowercased()
        let signedOut = ["not logged in", "not signed in", "logged out", "signed out", "please log in", "please run", "\"loggedin\": false", "\"loggedin\":false"]
            .contains { lowered.contains($0) }
        if status == 0, !signedOut { return .ready(firstLine) }
        if signedOut { return .signIn(firstLine) }
        return .attention(firstLine.map { String(localized: "The sign-in check reported: \($0)") } ?? String(localized: "The sign-in check failed."))
    }

    /// Runs the CLI's own status command with a bounded timeout and output cap.
    public static func check(_ agent: Agent, executable: URL?, environment: [String: String], timeout: Duration = .seconds(10)) async -> Self {
        guard let executable else { return .install }
        let result = await BoundedProcess.run(executable: executable.path, arguments: agent.statusArguments, environment: environment,
                                              directory: FileManager.default.homeDirectoryForCurrentUser.path, timeout: timeout, outputLimit: 64 * 1024, mergeStandardError: true)
        if let error = result.launchError { return .attention(String(localized: "\(agent.name) could not start (system error \(error)).")) }
        return classify(status: result.status, output: String(decoding: result.output, as: UTF8.self), timedOut: result.timedOut || result.overflowed)
    }
}
