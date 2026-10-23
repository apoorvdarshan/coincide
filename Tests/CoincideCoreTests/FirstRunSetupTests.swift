import Foundation
import Testing
@testable import CoincideCore

@Test func firstRunDecisionShowsSetupOnlyForAFreshLoadedWorkspace() {
    #expect(FirstRunDecision.decide(loaded: false, completed: false, projectCount: 0, threadCount: 0) == .pending)
    #expect(FirstRunDecision.decide(loaded: true, completed: false, projectCount: 0, threadCount: 0) == .wizard)
    #expect(FirstRunDecision.decide(loaded: true, completed: true, projectCount: 0, threadCount: 0) == .app)
    #expect(FirstRunDecision.decide(loaded: true, completed: false, projectCount: 1, threadCount: 0) == .app)
    #expect(FirstRunDecision.decide(loaded: true, completed: false, projectCount: 0, threadCount: 2) == .app)
    #expect(FirstRunDecision.decide(loaded: true, completed: false, projectCount: 0, threadCount: 0, enabled: false) == .app)
}

@Test func providerReadinessClassifiesStatusOutputWithoutGuessing() {
    #expect(ProviderReadiness.classify(status: 0, output: "Logged in using ChatGPT\n", timedOut: false) == .ready("Logged in using ChatGPT"))
    #expect(ProviderReadiness.classify(status: 1, output: "Not logged in", timedOut: false) == .signIn("Not logged in"))
    #expect(ProviderReadiness.classify(status: 0, output: #"{"loggedIn": false}"#, timedOut: false) == .signIn(#"{"loggedIn": false}"#))
    #expect(ProviderReadiness.classify(status: nil, output: "", timedOut: true) == .attention("The sign-in check did not finish."))
    if case .attention(let detail) = ProviderReadiness.classify(status: 2, output: "unknown subcommand", timedOut: false) {
        #expect(detail.contains("unknown subcommand"))
    } else { Issue.record("An unrecognized failure must ask for attention.") }
}

@Test func providerReadinessCommandsQuoteCustomExecutablePaths() {
    #expect(ProviderReadiness.Agent.codex.loginCommand() == "codex login")
    #expect(ProviderReadiness.Agent.claude.loginCommand(executable: "/opt/homebrew/bin/claude") == "/opt/homebrew/bin/claude auth login")
    #expect(ProviderReadiness.Agent.claude.loginCommand(executable: "/Users/me/My Tools/claude") == "'/Users/me/My Tools/claude' auth login")
    #expect(ProviderReadiness.Agent.codex.loginCommand(executable: "~/it's/codex") == "~/'it'\"'\"'s/codex' login")
    #expect(ProviderReadiness.Agent.codex.installCommand.hasPrefix("curl -fsSL https://chatgpt.com/codex/install.sh"))
    #expect(ProviderReadiness.Agent.claude.installCommand == "curl -fsSL https://claude.ai/install.sh | bash")
}

@Test(.timeLimit(.minutes(1)))
func providerReadinessChecksFakeExecutablesWithBoundedStatusCommands() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("coincide-readiness-" + UUID().uuidString)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    func fake(_ name: String, _ body: String) throws -> URL {
        let url = root.appendingPathComponent(name)
        try ("#!/bin/sh\n" + body + "\n").write(to: url, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
        return url
    }
    let signedIn = try fake("codex-in", "[ \"$1 $2\" = 'login status' ] || exit 9\necho 'Logged in using ChatGPT' >&2")
    let signedOut = try fake("claude-out", "[ \"$1 $2\" = 'auth status' ] || exit 9\necho 'Not logged in. Run claude auth login.'; exit 1")
    let hanging = try fake("codex-hang", "exec /bin/sleep 30")
    #expect(await ProviderReadiness.check(.codex, executable: nil, environment: [:]) == .install)
    #expect(await ProviderReadiness.check(.codex, executable: signedIn, environment: ["PATH": "/usr/bin:/bin"]) == .ready("Logged in using ChatGPT"))
    #expect(await ProviderReadiness.check(.claude, executable: signedOut, environment: ["PATH": "/usr/bin:/bin"]) == .signIn("Not logged in. Run claude auth login."))
    let started = ContinuousClock.now
    #expect(await ProviderReadiness.check(.codex, executable: hanging, environment: [:], timeout: .milliseconds(300)) == .attention("The sign-in check did not finish."))
    #expect(started.duration(to: .now) < .seconds(5))
}
