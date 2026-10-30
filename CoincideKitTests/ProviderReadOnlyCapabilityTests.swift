import Foundation
import Testing
@testable import CoincideKit

/// Explicit capability audit: version, sign-in, model/command catalogs only. Never sends a user prompt.
@MainActor
@Suite(.enabled(if: ProcessInfo.processInfo.environment["COINCIDE_READ_ONLY_CAPABILITIES"] == "1"), .serialized)
struct ProviderReadOnlyCapabilityTests {
    @Test(arguments: ProviderKind.allCases)
    func installedProviderCatalogs(kind: ProviderKind) async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("coincide-capabilities-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        let store = AppStore(directory: folder)
        let provider = ProviderRegistry.builtInProvider(kind, store: store)
        let registry = ProviderRegistry(store: store, providers: [provider])
        defer { if kind == .opencode { OpenCodeServerPool.shared.shutdownAll() } }
        await registry.refresh()
        let status = registry.status(kind)
        #expect(status.state == .ready, "Capability audit: \(kind.rawValue) is \(status.state)")
        let models = registry.models(for: kind)
        #expect(!models.isEmpty)
        if kind == .antigravity { #expect(models.count > 1, "The signed-in account must expose its native catalog") }
        let directory = URL(fileURLWithPath: ProcessInfo.processInfo.environment["COINCIDE_CAPABILITY_CWD"] ?? FileManager.default.homeDirectoryForCurrentUser.path)
        await registry.refreshCommands(for: kind, account: nil, in: directory)
        let commands = registry.commands(for: kind, account: nil, in: directory)
        print("CAPABILITIES \(kind.rawValue): models=\(models.count), slash=\(commands.filter(\.isSlashCommand).count), skills=\(commands.filter { $0.kind == .skill }.count)")
        if kind == .codex { #expect(commands.contains(where: { $0.kind == .skill })) }
    }
}
