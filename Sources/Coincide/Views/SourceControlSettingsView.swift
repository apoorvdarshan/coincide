import AppKit
import CoincideCore
import Observation
import SwiftUI

/// Settings → Source Control: detected tools and versions, per-host GitHub CLI sign-in status with
/// Rescan, an optional Keychain-only token, automatic fetch/pull and merge-credit preferences.
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

struct SourceControlSettingsView: View {
    @Bindable var store: WorkspaceStore
    @State private var model: SourceControlSettingsStore
    @State private var token = ""
    @State private var revision = 0
    @AppStorage(SourceControlPreferenceKeys.fetchInterval) private var fetchInterval = GitAutomaticFetchInterval.seconds30.rawValue
    @AppStorage(SourceControlPreferenceKeys.autoPullDefault) private var autoPullDefault = false
    @AppStorage(SourceControlPreferenceKeys.removeAgentCredits) private var removeAgentCredits = false
    private let preferences: SourceControlSyncPreferences

    init(store: WorkspaceStore, model: SourceControlSettingsStore? = nil, preferences: SourceControlSyncPreferences = .init()) {
        self.store = store; self.preferences = preferences
        _model = State(initialValue: model ?? SourceControlSettingsStore())
    }

    var body: some View {
        Form {
            Section("Tools") {
                if let report = model.report {
                    toolRow(report.git)
                    toolRow(report.gh)
                    if report.gh.meetsMinimum == false {
                        Text("GitHub CLI \(SourceControlDiscovery.minimumGitHubCLI) or newer reports sign-in status per host. Older versions use a text fallback.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                } else if model.isScanning { ProgressView("Scanning…").controlSize(.small) }
                HStack {
                    Button(model.isScanning ? "Scanning…" : "Rescan") { Task { await rescan() } }.disabled(model.isScanning)
                        .accessibilityIdentifier("source-control-rescan")
                    if let date = model.report?.scannedAt { Text("Last scanned \(date, format: .dateTime.hour().minute().second())").font(.caption).foregroundStyle(.secondary) }
                }
            }
            Section("GitHub Accounts") {
                if let report = model.report {
                    ForEach(report.hosts) { host in hostRow(host) }
                    if let error = report.authError { Text(error).font(.caption).foregroundStyle(.secondary) }
                } else { Text("Rescan to read GitHub CLI sign-in status.").foregroundStyle(.secondary) }
                Text("Sign in with GitHub CLI in Terminal, then choose Rescan. Coincide never reads or stores CLI credentials.").font(.caption).foregroundStyle(.secondary)
            }
            Section("GitHub Token (Optional)") {
                if model.hasSavedToken {
                    LabeledContent("Saved token", value: String(localized: "In use for github.com"))
                    Button("Remove Saved Token", role: .destructive) { model.removeToken(); Task { await rescan() } }
                        .accessibilityIdentifier("source-control-remove-token")
                } else {
                    SecureField("Personal access token", text: $token).accessibilityIdentifier("source-control-token")
                    Button("Save Token") { if model.saveToken(token) { token = ""; Task { await rescan() } } }
                        .disabled(token.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty).accessibilityIdentifier("source-control-save-token")
                }
                if let message = model.tokenMessage { Text(message).font(.caption).foregroundStyle(.secondary) }
                if let error = model.tokenError { Text(error).font(.caption).foregroundStyle(.red) }
                Text("A saved token is kept only in this Mac's Keychain and takes precedence over GitHub CLI's own sign-in for github.com pull request actions. It is passed to GitHub CLI only in its environment, never in arguments or logs.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("Automatic Fetch and Pull") {
                Picker("Fetch automatically", selection: $fetchInterval) {
                    ForEach(GitAutomaticFetchInterval.allCases) { Text($0.title).tag($0.rawValue) }
                }.accessibilityIdentifier("source-control-fetch-interval")
                Toggle("Pull the default branch automatically", isOn: $autoPullDefault).accessibilityIdentifier("source-control-auto-pull")
                Text("Fetches the open conversation's checkout from its upstream remote. Auto-pull only fast-forwards the default branch when it is clean, has an upstream and has no local commits ahead. Busy, held or edited checkouts are skipped.")
                    .font(.caption).foregroundStyle(.secondary)
                if !store.snapshot.projects.isEmpty {
                    DisclosureGroup("Project overrides") {
                        let _ = revision
                        ForEach(store.snapshot.projects) { project in
                            Picker(project.name, selection: Binding(get: { preferences.override(for: project.id) },
                                                                    set: { preferences.setOverride($0, for: project.id); revision += 1 })) {
                                Text("Use default (\(autoPullDefault ? String(localized: "On") : String(localized: "Off")))").tag(GitAutoPullOverride.inherit)
                                Text("Always pull").tag(GitAutoPullOverride.enabled)
                                Text("Never pull").tag(GitAutoPullOverride.disabled)
                            }.help(project.path)
                        }
                    }
                }
            }
            Section("Pull Requests") {
                Toggle("Remove agent credits when merging", isOn: $removeAgentCredits).accessibilityIdentifier("source-control-remove-agent-credits")
                Text("Removes recognized coding-agent co-author and “Generated with” lines from GitHub merge and squash commit messages. Human co-authors stay credited; the confirmation shows the exact message.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .accessibilityIdentifier("source-control-settings")
        .task { if model.report == nil { await rescan() } }
    }

    private func rescan() async { await model.rescan(hosts: SourceControlSettingsStore.projectHosts(store.snapshot.projects)) }

    private func toolRow(_ tool: SourceControlToolStatus) -> some View {
        LabeledContent(tool.name) {
            VStack(alignment: .trailing, spacing: 2) {
                if let version = tool.version {
                    Label(version, systemImage: tool.meetsMinimum == false ? "exclamationmark.triangle" : "checkmark.circle")
                        .foregroundStyle(tool.meetsMinimum == false ? .orange : .green)
                } else { Text(tool.isInstalled ? (tool.error ?? String(localized: "Unknown version")) : String(localized: "Not installed")).foregroundStyle(.secondary) }
                if let path = tool.path { Text(path).font(.caption.monospaced()).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle) }
            }
        }.accessibilityIdentifier("source-control-tool-\(tool.name)")
    }

    private func hostRow(_ host: SourceControlHostStatus) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(host.host).font(.body.monospaced())
                if host.usedByProjects { Text("In projects").font(.caption2).padding(.horizontal, 5).padding(.vertical, 1).background(.quaternary, in: Capsule()) }
                Spacer()
                if let account = host.effectiveAccount {
                    Label(account.login, systemImage: "person.crop.circle.badge.checkmark").foregroundStyle(.green)
                } else {
                    Label("Not signed in", systemImage: "person.crop.circle.badge.xmark").foregroundStyle(.secondary)
                    Button("Copy Sign-In Command") {
                        NSPasteboard.general.clearContents(); NSPasteboard.general.setString("gh auth login --hostname \(host.host)", forType: .string)
                    }.controlSize(.small).help("Copies gh auth login --hostname \(host.host)")
                }
            }
            ForEach(host.accounts) { account in
                HStack(spacing: 6) {
                    Image(systemName: account.authenticated ? "checkmark.circle" : "xmark.circle").foregroundStyle(account.authenticated ? .green : .red)
                    Text(account.login)
                    if account.active { Text("Active").font(.caption2).foregroundStyle(.secondary) }
                    if let source = account.tokenSource { Text(source).font(.caption2.monospaced()).foregroundStyle(.secondary) }
                    if let error = account.error { Text(error).font(.caption2).foregroundStyle(.red).lineLimit(1) }
                }.font(.caption)
            }
        }.accessibilityElement(children: .combine).accessibilityIdentifier("source-control-host-\(host.host)")
    }
}
