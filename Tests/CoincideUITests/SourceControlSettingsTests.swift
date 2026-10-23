import AppKit
import CoincideCore
import SwiftUI
import Testing
@testable import Coincide

private final class TokenVault: @unchecked Sendable {
    let lock = NSLock(); var values: [String: String] = [:]
    var access: SourceControlTokenAccess {
        .init(read: { host in self.lock.withLock { self.values[host] } },
              write: { token, host in self.lock.withLock { self.values[host] = token } },
              remove: { host in self.lock.withLock { _ = self.values.removeValue(forKey: host) } })
    }
}

@MainActor private func fixtureReport() -> SourceControlDiscoveryReport {
    .init(git: .init(name: "Git", path: "/usr/bin/git", version: "2.39.5", minimumVersion: nil, error: nil),
          gh: .init(name: "GitHub CLI", path: "/opt/homebrew/bin/gh", version: "2.80.0", minimumVersion: SourceControlDiscovery.minimumGitHubCLI, error: nil),
          hosts: [.init(host: "github.com", accounts: [.init(host: "github.com", login: "octocat", authenticated: true, active: true, tokenSource: "keyring")], usedByProjects: true),
                  .init(host: "ghe.example.invalid", accounts: [], usedByProjects: true)],
          structuredStatus: false, authError: nil, scannedAt: Date())
}

@MainActor @Test func sourceControlSettingsRescanAndTokenStayInKeychainAccessAndMemoryOnly() async throws {
    let vault = TokenVault(), overrides = GitHubCredentialOverrides()
    final class Counter: @unchecked Sendable { let lock = NSLock(); var hosts: [[String]] = [] }
    let counter = Counter()
    let model = SourceControlSettingsStore(discovery: { hosts in counter.lock.withLock { counter.hosts.append(hosts) }; return await MainActor.run { fixtureReport() } },
                                           tokens: vault.access, overrides: overrides)
    await model.rescan(hosts: ["github.com", "ghe.example.invalid"])
    #expect(model.report?.hosts.count == 2 && !model.isScanning && counter.hosts == [["github.com", "ghe.example.invalid"]])
    #expect(model.report?.gh.meetsMinimum == false && model.report?.hosts.first?.effectiveAccount?.login == "octocat")
    #expect(!model.saveToken("bad token") && model.tokenError != nil && vault.values.isEmpty)
    #expect(model.saveToken("  fixture-synthetic-value-0123  ") && model.hasSavedToken && overrides.hasToken(for: "github.com"))
    #expect(vault.values["github.com"] == "fixture-synthetic-value-0123")
    let reloaded = GitHubCredentialOverrides()
    let other = SourceControlSettingsStore(discovery: { _ in await MainActor.run { fixtureReport() } }, tokens: vault.access, overrides: reloaded)
    #expect(!other.hasSavedToken); other.loadSavedToken(); #expect(other.hasSavedToken && reloaded.hasToken(for: "github.com"))
    model.removeToken()
    #expect(!model.hasSavedToken && !overrides.hasToken(for: "github.com") && vault.values.isEmpty)
    let project = WorkspaceProject(path: "/tmp/project")
    #expect(SourceControlSettingsStore.projectHosts([project]).isEmpty)
}

@MainActor @Test func sourceControlSettingsFitsTheSettingsWindowInBothAppearances() async throws {
    _ = NSApplication.shared
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("coincide-scm-settings-" + UUID().uuidString)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let store = WorkspaceStore(databaseURL: root.appendingPathComponent("workspace.sqlite"))
    let model = SourceControlSettingsStore(discovery: { _ in await MainActor.run { fixtureReport() } }, tokens: TokenVault().access, overrides: GitHubCredentialOverrides())
    await model.rescan(hosts: [])
    let suite = "coincide.scm.settings." + UUID().uuidString, defaults = try #require(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }
    for scheme in [ColorScheme.light, .dark] {
        let controller = NSHostingController(rootView: SourceControlSettingsView(store: store, model: model, preferences: .init(defaults: defaults))
            .environment(\.colorScheme, scheme).frame(width: 620, height: 460))
        let size = controller.sizeThatFits(in: CGSize(width: 620, height: 460))
        #expect(size.width <= 621 && size.height <= 461)
    }
    await store.shutdown()
}
