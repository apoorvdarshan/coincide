import Darwin
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

@Test(.timeLimit(.minutes(1)))
func providerReadinessChecksCapturedHomesAndNeverLaunchesOwnedAccountAuthentication() async throws {
    let pointer = try #require(realpath(FileManager.default.temporaryDirectory.path, nil))
    let temporary = URL(fileURLWithPath: String(cString: pointer), isDirectory: true); free(pointer)
    let root = temporary.appendingPathComponent("coincide-captured-readiness-" + UUID().uuidString)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let tool = root.appendingPathComponent("private-cli"), home = root.appendingPathComponent("selected home"), config = root.appendingPathComponent("selected config")
    try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: config, withIntermediateDirectories: true)
    let body = """
    #!/bin/sh
    [ "$PWD" = "$EXPECTED_CWD" ] || exit 20
    case "$1 $2" in
      'login status') [ "$CODEX_HOME" = "$EXPECTED_HOME" ] || exit 21 ;;
      'auth status') [ "$CLAUDE_CONFIG_DIR" = "$EXPECTED_CONFIG" ] || exit 22 ;;
      *) exit 23 ;;
    esac
    printf 'Captured profile ready'
    """
    try body.write(to: tool, atomically: true, encoding: .utf8)
    try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: tool.path)
    let codex = CodexRuntimeConfiguration(selection: .custom, executable: tool.path, homeDirectory: home.path)
    let environment = ["CODEX_HOME": home.path, "CLAUDE_CONFIG_DIR": config.path, "EXPECTED_HOME": home.path,
                       "EXPECTED_CONFIG": config.path, "EXPECTED_CWD": root.path]
    let capturedCodex = ProviderReadiness.Capture(scope: .codex(codex), executable: tool, environment: environment, directory: root.path)
    #expect(await ProviderReadiness.check(capturedCodex) == .ready("Captured profile ready"))
    #expect(capturedCodex.loginCommand?.contains("CODEX_HOME=" + CLIShim.shellWord(home.path)) == true)
    let claude = ClaudeRuntimeConfiguration(executable: tool.path, configurationDirectory: config.path, workspacePath: root.path)
    let capturedClaude = ProviderReadiness.Capture(scope: .claude(claude), executable: tool, environment: environment, directory: root.path)
    #expect(await ProviderReadiness.check(capturedClaude) == .ready("Captured profile ready"))
    #expect(capturedClaude.loginCommand?.contains("CLAUDE_CONFIG_DIR=" + CLIShim.shellWord(config.path)) == true)

    let marker = root.appendingPathComponent("must-not-launch")
    try ("#!/bin/sh\n/usr/bin/touch " + CLIShim.shellWord(marker.path) + "\nexit 0\n").write(to: tool, atomically: true, encoding: .utf8)
    let owned = CodexRuntimeConfiguration(selection: .custom, executable: tool.path, homeDirectory: home.path, authenticationMode: .ownedChatGPT)
    let verified = ProviderReadiness.Capture(scope: .codex(owned), executable: tool, environment: environment, directory: root.path,
                                             resultOverride: .ready("Selected account verified"))
    #expect(await ProviderReadiness.check(verified) == .ready("Selected account verified"))
    let unverified = ProviderReadiness.Capture(scope: .codex(owned), executable: tool, environment: environment, directory: root.path)
    if case .attention = await ProviderReadiness.check(unverified) {} else { Issue.record("An unverified owned account must use its account controller.") }
    #expect(verified.loginCommand == nil && unverified.loginCommand == nil)
    #expect(!FileManager.default.fileExists(atPath: marker.path), "Readiness never starts or materializes owned authentication.")
}
