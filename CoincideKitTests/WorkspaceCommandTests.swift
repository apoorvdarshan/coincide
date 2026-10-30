import Foundation
import Testing
@testable import CoincideKit

@MainActor
struct WorkspaceCommandTests {
    private final class Provider: AgentProvider {
        let kind: ProviderKind = .codex
        let executableNames = ["sh"]
        let setupHint = ""
        var reads = 0
        var sessions = 0
        func detect(executable: URL?, environment: [String: String]) async -> ProviderStatus { ProviderStatus(state: .ready) }
        func models(status: ProviderStatus, environment: [String: String]) async -> [ModelOption] { [] }
        func makeSession(_ launch: AgentLaunch) -> AgentSession { sessions += 1; return UnimplementedSession(provider: kind) }
        func commands(executable: URL, environment: [String: String], directory: URL) async -> [ProviderCommand]? {
            reads += 1
            try? await Task.sleep(for: .milliseconds(30))
            return [ProviderCommand(name: directory.lastPathComponent, kind: .skill, path: directory.appendingPathComponent("SKILL.md").path, isSlashCommand: false)]
        }
    }

    @Test func skillsAreAvailableBeforeATurnAndNeverBorrowedFromAnotherWorkspace() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("commands-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = AppStore(directory: root)
        let provider = Provider()
        let registry = ProviderRegistry(store: store, providers: [provider])
        await registry.refresh()
        let first = root.appendingPathComponent("first")
        let second = root.appendingPathComponent("second")
        registry.updateCommands([ProviderCommand(name: "unrelated-project", kind: .skill)], for: .codex)
        #expect(registry.commands(for: .codex, account: nil, in: first).isEmpty)
        let one = Task { await registry.refreshCommands(for: .codex, account: nil, in: first) }
        let two = Task { await registry.refreshCommands(for: .codex, account: nil, in: first) }
        await one.value
        await two.value
        #expect(provider.reads == 1)
        #expect(provider.sessions == 0)
        #expect(registry.commands(for: .codex, account: nil, in: first).map(\.name) == ["first"])
        #expect(registry.commands(for: .codex, account: nil, in: second).isEmpty)
        await registry.refreshCommands(for: .codex, account: nil, in: second)
        #expect(provider.reads == 2)
        #expect(registry.commands(for: .codex, account: nil, in: second).map(\.name) == ["second"])
        #expect(registry.commands(for: .codex, account: nil, in: first).map(\.name) == ["first"])
    }
}
