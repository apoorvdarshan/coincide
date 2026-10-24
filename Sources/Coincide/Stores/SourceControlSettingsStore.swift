import CoincideCore
import Foundation
import Observation

/// Existing source-control credential state used by background Git integration.
@MainActor @Observable
final class SourceControlSettingsStore {
    private(set) var report: SourceControlDiscoveryReport?
    private(set) var isScanning = false
    private(set) var hasSavedToken = false
    private(set) var tokenError: String?
    private(set) var tokenMessage: String?
    @ObservationIgnored private let discovery: @Sendable ([String]) async -> SourceControlDiscoveryReport
    @ObservationIgnored private let tokens: SourceControlTokenAccess
    @ObservationIgnored private let overrides: GitHubCredentialOverrides
    @ObservationIgnored private var scanID = UUID()
    static let tokenHost = "github.com"

    init(discovery: @escaping @Sendable ([String]) async -> SourceControlDiscoveryReport = { await SourceControlDiscovery().scan(hosts: $0) },
         tokens: SourceControlTokenAccess = .keychain, overrides: GitHubCredentialOverrides = .shared) {
        self.discovery = discovery; self.tokens = tokens; self.overrides = overrides
        hasSavedToken = overrides.hasToken(for: Self.tokenHost)
    }

    func rescan(hosts: [String]) async {
        let id = UUID(); scanID = id; isScanning = true
        defer { if scanID == id { isScanning = false } }
        let value = await discovery(hosts)
        guard scanID == id else { return }
        report = value
    }

    /// Reads the saved token into memory so `gh` children can use it. Never displays it.
    func loadSavedToken() {
        do {
            let token = try tokens.read(Self.tokenHost)
            overrides.set(token, host: Self.tokenHost); hasSavedToken = token != nil; tokenError = nil
        } catch { tokenError = error.localizedDescription }
    }
    func saveToken(_ token: String) -> Bool {
        let value = token.trimmingCharacters(in: .whitespacesAndNewlines)
        guard SourceControlTokenStore.validToken(value) else { tokenError = String(localized: "Enter a GitHub token without spaces or line breaks."); return false }
        do {
            try tokens.write(value, Self.tokenHost)
            overrides.set(value, host: Self.tokenHost); hasSavedToken = true; tokenError = nil
            tokenMessage = String(localized: "Saved in Keychain. GitHub CLI uses it for github.com.")
            return true
        } catch { tokenError = error.localizedDescription; return false }
    }
    func removeToken() {
        do {
            try tokens.remove(Self.tokenHost)
            overrides.set(nil, host: Self.tokenHost); hasSavedToken = false; tokenError = nil
            tokenMessage = String(localized: "Removed. GitHub CLI uses its own sign-in again.")
        } catch { tokenError = error.localizedDescription }
    }

    /// GitHub-like hosts from registered project remotes.
    static func projectHosts(_ projects: [WorkspaceProject]) -> [String] {
        Array(Set(projects.compactMap { project -> String? in
            guard let identity = project.repositoryIdentity, ["github", "unknown"].contains(identity.provider) else { return nil }
            return identity.canonicalKey.split(separator: "/").first.map { String($0).lowercased() }
        })).sorted()
    }
}
