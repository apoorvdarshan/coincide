import Foundation
import Testing

@testable import CoincideKit

/// A provider whose detection the test controls.
@MainActor
final class ProbedProvider: AgentProvider {
    let kind: ProviderKind
    let executableNames = ["sh"]
    let setupHint = ""
    var detections = 0
    var states: [ProviderStatus.State] = [.ready]
    var gate: Gate?

    init(kind: ProviderKind) { self.kind = kind }

    func detect(executable: URL?, environment: [String: String]) async -> ProviderStatus {
        detections += 1
        let state = states[min(detections - 1, states.count - 1)]
        await gate?.wait()
        return ProviderStatus(state: state)
    }

    func models(status: ProviderStatus, environment: [String: String]) async -> [ModelOption] {
        [ModelOption(provider: kind, modelID: "m\(detections)", displayName: "M")]
    }

    func makeSession(_ launch: AgentLaunch) -> AgentSession { UnimplementedSession(provider: kind) }
}

@MainActor
struct ProviderRegistryTests {
    private func makeRegistry(_ providers: [AgentProvider]) -> (AppStore, ProviderRegistry) {
        let store = AppStore(directory: FileManager.default.temporaryDirectory.appendingPathComponent("coincide-reg-\(UUID().uuidString)"))
        return (store, ProviderRegistry(store: store, providers: providers))
    }

    @Test func aRefreshAskedForDuringAnotherChecksAgainOnce() async throws {
        let provider = ProbedProvider(kind: .codex)
        let gate = Gate()
        provider.gate = gate
        let (store, registry) = makeRegistry([provider])
        let first = Task { await registry.refresh() }
        while provider.detections == 0 { try await Task.sleep(for: .milliseconds(5)) }
        #expect(registry.isRefreshing)
        // The user disables it while the first check runs; two more requests share one new check.
        store.updateSettings { $0.providers[.codex] = ProviderSettings(isEnabled: false) }
        let second = Task { await registry.refresh(.codex) }
        let third = Task { await registry.refresh() }
        try await Task.sleep(for: .milliseconds(30))
        gate.open()
        await first.value
        await second.value
        await third.value
        #expect(provider.detections == 1)
        #expect(registry.status(.codex).message == "Disabled in Settings")
        #expect(!registry.isRefreshing)
    }

    @Test func providersThatAreNotReadyAreCheckedAgain() async {
        let provider = ProbedProvider(kind: .cursor)
        provider.states = [.notAuthenticated, .ready]
        let ready = ProbedProvider(kind: .codex)
        let (_, registry) = makeRegistry([provider, ready])
        await registry.refresh()
        #expect(registry.status(.cursor).state == .notAuthenticated)
        // Checked moments ago: left alone.
        await registry.refreshUnavailable(olderThan: 60)
        #expect(provider.detections == 1)
        await registry.refreshUnavailable(olderThan: 0)
        #expect(registry.status(.cursor).state == .ready)
        #expect(registry.models(for: .cursor).map(\.modelID) == ["m2"])
        #expect(ready.detections == 1)
    }
}

struct ShellEnvironmentTests {
    private final class Counter: @unchecked Sendable {
        private let lock = NSLock()
        private var value = 0
        func next() -> Int { lock.withLock { value += 1; return value } }
        var count: Int { lock.withLock { value } }
    }

    @Test func concurrentCallersShareOneShell() async {
        let calls = Counter()
        let shell = ShellEnvironment {
            _ = calls.next()
            try? await Task.sleep(for: .milliseconds(100))
            return ["PATH": "/custom/bin", "COINCIDE_TEST_VALUE": "a\nb"]
        }
        async let a = shell.environment()
        async let b = shell.environment()
        async let c = shell.environment()
        let results = await [a, b, c]
        #expect(calls.count == 1)
        #expect(results.allSatisfy { $0["COINCIDE_TEST_VALUE"] == "a\nb" })
        #expect(results[0]["PATH"]?.hasPrefix("/custom/bin:") == true)
        #expect(results[0]["PATH"]?.contains("/usr/bin") == true)
        _ = await shell.environment()
        #expect(calls.count == 1)
    }

    @Test func aShellThatCannotBeReadIsAskedAgainLater() async {
        let calls = Counter()
        let shell = ShellEnvironment {
            _ = calls.next()
            return nil
        }
        let fallback = await shell.environment()
        #expect(fallback["PATH"]?.contains("/opt/homebrew/bin") == true)
        #expect(fallback["CLAUDECODE"] == nil)
        _ = await shell.environment()
        #expect(calls.count == 1)
        shell.invalidate()
        _ = await shell.environment()
        #expect(calls.count == 2)
    }

    @Test func envOutputIsReadBetweenTheMarkers() {
        let output = "Welcome!\n__COINCIDE_ENV_START__PATH=/a:/b\0MULTI=one\ntwo=2\0BAD KEY=x\0EMPTY=\0__COINCIDE_ENV_END__bye"
        let env = ShellEnvironment.parse(output)
        #expect(env == ["PATH": "/a:/b", "MULTI": "one\ntwo=2", "EMPTY": ""])
        #expect(ShellEnvironment.parse("no markers") == nil)
    }

    @Test func shellsAreStartedTheWayTheyAccept() {
        #expect(ShellEnvironment.arguments(forShell: "/bin/zsh", command: "c") == ["-l", "-i", "-c", "c"])
        #expect(ShellEnvironment.arguments(forShell: "/opt/homebrew/bin/fish", command: "c") == ["-l", "-c", "c"])
        #expect(ShellEnvironment.arguments(forShell: "/bin/tcsh", command: "c") == ["-c", "c"])
        #expect(ShellEnvironment.arguments(forShell: "/usr/local/bin/pwsh", command: "c")?.first == "-Login")
        #expect(ShellEnvironment.arguments(forShell: "/usr/local/bin/mystery", command: "c") == nil)
    }

    @Test func theLoginShellIsRead() async {
        let env = await ShellEnvironment.loginShellEnvironment()
        #expect(env?["PATH"]?.isEmpty == false)
        #expect(env?["HOME"] == NSHomeDirectory())
    }
}
