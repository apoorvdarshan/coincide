import AppKit
import CoincideKit
import Observation
import SwiftUI
import UniformTypeIdentifiers

/// Settings › Browser › Passwords' state: each manager's status, Coincide's saved logins and the sites agents may sign
/// in to.
@Observable
final class PasswordsSettingsModel {
    private(set) var statuses: [PasswordManagerKind: PasswordProviderStatus] = [:]
    private(set) var saved: [SavedLogin] = []
    private(set) var grants: [LoginGrant] = []
    private(set) var enabled: Set<PasswordManagerKind> = []
    var offersToSave = true { didSet { if offersToSave != oldValue { settings.update { $0.offersToSaveLogins = offersToSave } } } }
    var agentsUseManagers = true {
        didSet { if agentsUseManagers != oldValue { settings.update { $0.agentsUsePasswordManagers = agentsUseManagers } } }
    }
    var agentsSignInWithoutAsking = false {
        didSet {
            if agentsSignInWithoutAsking != oldValue { settings.update { $0.agentsSignInWithoutAsking = agentsSignInWithoutAsking } }
        }
    }
    var usesBitwardenPasskeys = true {
        didSet { if usesBitwardenPasskeys != oldValue { settings.update { $0.usesBitwardenPasskeys = usesBitwardenPasskeys } } }
    }
    var confirmsPasskeysWithTouchID = false {
        didSet {
            if confirmsPasskeysWithTouchID != oldValue { settings.update { $0.confirmsPasskeysWithTouchID = confirmsPasskeysWithTouchID } }
        }
    }
    var unlocking = false
    var unlockError: String?
    @ObservationIgnored let sessions: PreviewSessions
    @ObservationIgnored private var settings: BrowserSettingsStore { sessions.profile.settings }
    @ObservationIgnored private var observer: NSObjectProtocol?

    init(sessions: PreviewSessions = .shared) {
        self.sessions = sessions
        reloadSettings()
        observer = NotificationCenter.default.addObserver(forName: BrowserSettingsStore.didChange, object: sessions.profile.settings, queue: .main) {
            [weak self] _ in MainActor.assumeIsolated { self?.reloadSettings() }
        }
    }

    isolated deinit {
        if let observer { NotificationCenter.default.removeObserver(observer) }
    }

    private func reloadSettings() {
        enabled = Set(settings.settings.passwordManagers)
        grants = settings.settings.loginGrants.sorted { $0.site < $1.site }
        offersToSave = settings.settings.offersToSaveLogins
        agentsUseManagers = settings.settings.agentsUsePasswordManagers
        agentsSignInWithoutAsking = settings.settings.agentsSignInWithoutAsking
        usesBitwardenPasskeys = settings.settings.usesBitwardenPasskeys
        confirmsPasskeysWithTouchID = settings.settings.confirmsPasskeysWithTouchID
        saved = sessions.profile.logins.saved.sorted { $0.title.localizedStandardCompare($1.title) == .orderedAscending }
    }

    func refresh() async {
        for kind in PasswordManagerKind.allCases {
            guard let provider = sessions.vault.providers[kind] else { continue }
            statuses[kind] = await provider.status()
        }
        reloadSettings()
    }

    func setEnabled(_ kind: PasswordManagerKind, _ on: Bool) {
        settings.update { settings in
            settings.passwordManagers.removeAll { $0 == kind }
            if on { settings.passwordManagers.append(kind) }
        }
    }

    func unlockBitwarden(password: String) async {
        guard let bitwarden = sessions.vault.providers[.bitwarden] as? BitwardenProvider else { return }
        unlocking = true
        unlockError = nil
        do { try await bitwarden.unlock(password: password) } catch { unlockError = error.localizedDescription }
        unlocking = false
        await refresh()
    }

    func lockBitwarden() async {
        guard let bitwarden = sessions.vault.providers[.bitwarden] as? BitwardenProvider else { return }
        await bitwarden.lock()
        await refresh()
    }

    func delete(_ login: SavedLogin) {
        try? sessions.profile.logins.delete(login.id)
        reloadSettings()
    }

    func revoke(_ grant: LoginGrant) { sessions.vault.revoke(grant) }

    func revokeAll() { for grant in grants { sessions.vault.revoke(grant) } }

    // MARK: CSV

    private(set) var csvResult: String?

    /// Saves a password export's logins in Coincide's Keychain logins, turning those on.
    func importCSV(_ url: URL) {
        do {
            let parsed = try PasswordCSV.parse(try Data(contentsOf: url))
            let saved = try sessions.profile.logins.importLogins(parsed.logins)
            if !enabled.contains(.coincide) { setEnabled(.coincide, true) }
            csvResult = String(localized: "Logins imported: \(saved) · Rows skipped (no web address or password): \(parsed.skipped). Delete the CSV file now: it holds your passwords unencrypted.")
        } catch {
            csvResult = String(localized: "That file isn't a password export Coincide can read.")
        }
        reloadSettings()
    }

    func capabilityNote(_ kind: PasswordManagerKind) -> String? {
        guard let capabilities = sessions.vault.providers[kind]?.capabilities else { return nil }
        var missing: [String] = []
        if !capabilities.totp { missing.append(String(localized: "One-time codes aren’t available with this tool.")) }
        if !capabilities.lookupByDomain { missing.append(String(localized: "It can’t search by site, so Coincide matches its logins itself.")) }
        return missing.isEmpty ? nil : missing.joined(separator: " ")
    }
}

/// The Passwords sections of Settings › Browser.
struct PasswordsSettingsSection: View {
    @State private var model = PasswordsSettingsModel()
    @State private var bitwardenPassword = ""
    /// The allowed sites start folded away, so a long list doesn't push the rest of Settings down.
    @State private var showsGrants = false

    var body: some View {
        Group {
            Section {
                Text("Coincide connects to each password manager through its command-line tool, so you don’t need its browser extension. In the browser, Coincide types passwords and one-time codes into the page itself, after you allow it for the site.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                ForEach(PasswordManagerKind.allCases) { kind in managerRow(kind) }
                if model.enabled.contains(.bitwarden) {
                    Toggle(isOn: $model.usesBitwardenPasskeys) {
                        Text("Use passkeys from Bitwarden")
                        Text("When a site asks for a passkey you saved in Bitwarden, Coincide offers to sign in with it, and you confirm each sign-in. Coincide reads the passkey with Bitwarden’s tool on this Mac, only to answer the site, and never sends it anywhere else.")
                    }
                    if model.usesBitwardenPasskeys {
                        Toggle(isOn: $model.confirmsPasskeysWithTouchID) {
                            Text("Confirm passkey sign-ins with Touch ID")
                            Text("Coincide always asks for Touch ID or your Mac password after you click Sign In. When this is off, it asks only when the site requires it or the Bitwarden item has master password re-prompt on.")
                        }
                    }
                }
                Toggle(isOn: $model.agentsUseManagers) {
                    Text("Let agents use your unlocked password managers")
                    Text("Agents Coincide starts get Bitwarden’s unlocked session, so they can read any item with the bw command, such as API keys and tokens, without asking. Agents that are already running get it when they start again.")
                }
            } header: {
                Text("Passwords")
            }

            Section {
                LabeledContent {
                    Button("Import CSV…") {
                        let panel = NSOpenPanel()
                        panel.allowedContentTypes = [.commaSeparatedText]
                        panel.allowsMultipleSelection = false
                        if panel.runModal() == .OK, let url = panel.url { model.importCSV(url) }
                    }
                } label: {
                    Text("Import passwords from a CSV export")
                    Text("Chrome, Safari and Apple Passwords, Firefox, 1Password and Bitwarden exports work. The logins are saved in your Keychain as Coincide saved logins.")
                }
                if let result = model.csvResult {
                    Text(result).font(.callout).foregroundStyle(.secondary)
                }
            }

            if model.enabled.contains(.coincide) {
                Section {
                    Toggle(isOn: $model.offersToSave) {
                        Text("Offer to save logins")
                        Text("After you sign in on a page, Coincide asks whether to save the login in your Keychain.")
                    }
                    if model.saved.isEmpty {
                        Text("No saved logins yet.").foregroundStyle(.secondary)
                    }
                    ForEach(model.saved) { login in
                        HStack {
                            VStack(alignment: .leading, spacing: 1) {
                                Text(login.title).lineLimit(1)
                                Text("\(login.username) · \(login.url)").font(.caption).foregroundStyle(.secondary).lineLimit(1)
                            }
                            Spacer()
                            Button("Delete", role: .destructive) { model.delete(login) }
                        }
                    }
                } header: {
                    Text("Saved Logins")
                }
            }

            Section {
                Toggle(isOn: $model.agentsSignInWithoutAsking) {
                    Text("Let agents sign in on any site without asking")
                    Text("When an agent asks to sign in, Coincide types the login from your password manager right away, on every site, instead of asking you first. Agents still never see passwords or codes.")
                }
                if model.grants.isEmpty {
                    Text("When an agent asks to sign in and you choose Always for This Site, the site is listed here.")
                        .foregroundStyle(.secondary)
                } else {
                    DisclosureGroup(isExpanded: $showsGrants) {
                        ForEach(model.grants) { grant in
                            HStack(spacing: 8) {
                                Image(nsImage: PasswordManagerLogo.image(for: grant.source, size: 16))
                                VStack(alignment: .leading, spacing: 1) {
                                    Text(grant.site)
                                    Text([grant.itemTitle, grant.username, grant.source.displayName].filter { !$0.isEmpty }.joined(separator: " · "))
                                        .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                                }
                                Spacer()
                                Button("Revoke") { model.revoke(grant) }
                            }
                        }
                    } label: {
                        HStack {
                            VStack(alignment: .leading, spacing: 1) {
                                Text("\(model.grants.count) sites allowed")
                                if model.agentsSignInWithoutAsking {
                                    Text("These stay allowed if you turn the switch above off.")
                                        .font(.caption).foregroundStyle(.secondary)
                                }
                            }
                            .pointerCursorRow()
                            Spacer()
                            Button("Revoke All") { model.revokeAll() }
                        }
                    }
                }
            } header: {
                Text("Sites Agents Can Sign In To")
            }
        }
        .task { await model.refresh() }
    }

    @ViewBuilder private func managerRow(_ kind: PasswordManagerKind) -> some View {
        let status = model.statuses[kind]
        VStack(alignment: .leading, spacing: 8) {
            Toggle(isOn: Binding(get: { model.enabled.contains(kind) }, set: { model.setEnabled(kind, $0) })) {
                PasswordManagerLabel(logo: PasswordManagerLogo.image(for: kind, size: 20), name: kind.displayName,
                    caption: statusText(kind, status))
            }
            if let note = model.capabilityNote(kind) {
                Text(note).font(.caption).foregroundStyle(.secondary)
            }
            if status == .notInstalled, let install = kind.installCommand {
                HStack {
                    Text("Install with Homebrew:").font(.caption).foregroundStyle(.secondary)
                    Text(install).font(.caption.monospaced()).textSelection(.enabled)
                    SettingsCopyButton(text: install)
                }
            }
            if kind == .bitwarden, model.enabled.contains(.bitwarden) {
                bitwardenControls(status)
            }
        }
        .padding(.vertical, 2)
    }

    @ViewBuilder private func bitwardenControls(_ status: PasswordProviderStatus?) -> some View {
        switch status {
        case .locked:
            HStack {
                SecureField("Master password", text: $bitwardenPassword)
                    .textFieldStyle(ThemedTextFieldStyle())
                    .onSubmit(unlock)
                Button(model.unlocking ? "Unlocking…" : "Unlock", action: unlock)
                    .disabled(bitwardenPassword.isEmpty || model.unlocking)
            }
            Text("The password goes only to Bitwarden’s tool. Coincide keeps the session it returns in your Keychain until you lock it.")
                .font(.caption).foregroundStyle(.secondary)
            if let error = model.unlockError { Text(error).font(.caption).foregroundStyle(Color(nsColor: Theme.failure)) }
        case .unlocked:
            Button("Lock") { Task { await model.lockBitwarden() } }
        default:
            EmptyView()
        }
    }

    private func unlock() {
        let password = bitwardenPassword
        bitwardenPassword = ""
        Task { await model.unlockBitwarden(password: password) }
    }

    private func statusText(_ kind: PasswordManagerKind, _ status: PasswordProviderStatus?) -> String {
        switch status {
        case nil: return String(localized: "Checking…")
        case .notInstalled: return String(localized: "Not installed")
        case .needsSetup:
            return kind == .onePassword
                ? String(localized: "Turn on “Integrate with 1Password CLI” in 1Password › Settings › Developer.")
                : String(localized: "Run “bw login” in Terminal once, then unlock here.")
        case .locked: return String(localized: "Locked")
        case .unlocked(let account):
            if kind == .coincide { return String(localized: "Stored in your Keychain on this Mac") }
            return account.map { String(localized: "Unlocked as \($0)") } ?? String(localized: "Unlocked")
        case .unlocksOnUse(let account):
            let base = String(localized: "1Password asks you to unlock when Coincide first uses it.")
            return account.map { "\($0) · \(base)" } ?? base
        case .unavailable(let message): return message.isEmpty ? String(localized: "Unavailable") : message
        }
    }
}

/// A password manager's logo, name and status line, as Settings lists them.
struct PasswordManagerLabel: View {
    let logo: NSImage
    let name: String
    let caption: String

    var body: some View {
        HStack(spacing: 8) {
            Image(nsImage: logo)
            VStack(alignment: .leading, spacing: 1) {
                Text(name)
                Text(caption).font(.caption).foregroundStyle(.secondary)
            }
        }
    }
}
