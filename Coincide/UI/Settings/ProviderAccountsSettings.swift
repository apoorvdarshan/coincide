import AppKit
import CoincideKit
import SwiftUI

/// A provider's accounts (T3 Code's provider instances): the default one, which is the CLI's own setup, and any the
/// user added, each signing in with a login of its own or an API key from the Keychain. Threads pick one in the
/// model picker.
struct ProviderAccountsSection: View {
    let model: SettingsModel
    let kind: ProviderKind

    var body: some View {
        let methods = kind.accountAuthMethods
        Section {
            ForEach(model.accounts(kind)) { account in
                if account.isDefault {
                    DefaultAccountRow(model: model, account: account)
                } else {
                    AddedAccountRow(model: model, account: account)
                }
            }
            HStack(spacing: 8) {
                if methods.contains(.login) {
                    Button {
                        model.addAccount(kind, auth: .login)
                    } label: {
                        Label("Add Login Account", systemImage: "person.crop.circle.badge.plus")
                    }
                }
                if methods.contains(.apiKey) {
                    Button {
                        model.addAccount(kind, auth: .apiKey)
                    } label: {
                        Label("Add API Key Account", systemImage: "key")
                    }
                }
                Spacer()
            }
        } header: {
            Text("Accounts")
        } footer: {
            Text(Self.footer(kind))
        }
    }

    private static func footer(_ kind: ProviderKind) -> String {
        var text = String(
            localized: "Add as many accounts as you like and pick one per thread in the model picker. API keys are kept in the macOS Keychain.")
        if kind.accountHomeVariable != nil {
            text += " " + String(localized: "A login account signs in to \(kind.displayName) in a folder of its own, apart from your usual sign-in.")
        } else {
            text += " " + String(localized: "\(kind.displayName) can only keep one login, so added accounts use API keys.")
        }
        return text
    }
}

/// How an account's status reads: a colored dot and a short headline.
private struct AccountStatusLabel: View {
    let model: SettingsModel
    let account: ProviderAccount

    var body: some View {
        let (headline, color) = presentation
        HStack(spacing: 5) {
            if model.isBusy(account) {
                ProgressView().controlSize(.mini)
            } else {
                SettingsStatusDot(color: color, size: 7)
            }
            Text(headline).lineLimit(1).truncationMode(.middle)
        }
        .font(.caption)
        .foregroundStyle(.secondary)
    }

    private var presentation: (String, Color) {
        let status = model.accountStatus(account)
        let isKey = account.auth == .apiKey && !account.isDefault
        if model.isBusy(account) && status.state == .unknown { return (String(localized: "Checking…"), .secondary) }
        switch status.state {
        case .ready:
            let label = isKey ? String(localized: "API key") : String(localized: "Signed in")
            return ([label, status.account].compactMap { $0 }.joined(separator: " · "), .green)
        case .notAuthenticated:
            if isKey && !model.hasAPIKey(account) { return (String(localized: "No API key"), .orange) }
            return (isKey ? String(localized: "Key not accepted") : String(localized: "Not signed in"), .orange)
        case .notInstalled:
            return (String(localized: "Not installed"), Color(nsColor: .tertiaryLabelColor))
        case .error:
            return ([String(localized: "Unavailable"), status.message].compactMap { $0 }.joined(separator: " · "), .red)
        case .unknown:
            return (String(localized: "Not checked"), Color(nsColor: .tertiaryLabelColor))
        }
    }
}

private struct DefaultAccountRow: View {
    let model: SettingsModel
    let account: ProviderAccount

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "person.crop.circle")
                .font(.title3)
                .foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(account.name).fontWeight(.medium)
                    SettingsTag(text: String(localized: "Default"), tint: Color(nsColor: Theme.ink))
                }
                Text("\(account.provider.displayName)’s own sign-in and settings, as set up on this Mac.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                AccountStatusLabel(model: model, account: account)
            }
            Spacer(minLength: 8)
        }
        .padding(.vertical, 2)
    }
}

private struct AddedAccountRow: View {
    let model: SettingsModel
    let account: ProviderAccount
    @State private var name = ""
    @State private var key = ""
    @State private var adminKey = ""
    @State private var problem: String?
    @State private var confirmsRemoval = false
    @FocusState private var nameFocused: Bool

    var body: some View {
        let kind = account.provider
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
                Image(systemName: account.auth == .apiKey ? "key.fill" : "person.crop.circle.fill")
                    .font(.title3)
                    .foregroundStyle(.secondary)
                VStack(alignment: .leading, spacing: 3) {
                    TextField("Account name", text: $name, prompt: Text(kind.displayName))
                        .labelsHidden()
                        .focused($nameFocused)
                        .onSubmit(commitName)
                        .frame(maxWidth: 260)
                    AccountStatusLabel(model: model, account: account)
                }
                Spacer(minLength: 8)
                Button(role: .destructive) {
                    confirmsRemoval = true
                } label: {
                    Image(systemName: "minus.circle.fill")
                }
                .buttonStyle(.borderless)
                .pointerCursor()
                .foregroundStyle(.red)
                .help(Text("Remove account"))
                .accessibilityLabel(Text("Remove \(account.name)"))
            }
            if kind.accountAuthMethods.count > 1 {
                ThemedPicker(
                    selection: Binding(get: { account.auth }, set: { auth in model.updateAccount(account) { $0.auth = auth } }),
                    options: kind.accountAuthMethods.map { ThemedPicker.Option($0, Self.title($0, kind)) }
                ) {
                    Text("Sign in with")
                }
            }
            switch account.auth {
            case .login: loginControls
            case .apiKey: keyControls
            }
            if let problem {
                Text(problem).font(.caption).foregroundStyle(.red)
            }
        }
        .padding(.vertical, 4)
        .onAppear { name = account.name }
        .onChange(of: nameFocused) { _, focused in if !focused { commitName() } }
        .onChange(of: account.name) { _, value in if !nameFocused { name = value } }
        .confirmationDialog(
            Text("Remove “\(account.name)”?"), isPresented: $confirmsRemoval
        ) {
            Button("Remove Account", role: .destructive) { model.removeAccount(account) }
        } message: {
            Text("Its API key and sign-in are deleted from this Mac. Threads that used it continue with \(account.provider.displayName)’s default account.")
        }
    }

    @ViewBuilder private var loginControls: some View {
        HStack(spacing: 8) {
            Button {
                model.signIn(account)
            } label: {
                Label("Sign In…", systemImage: "person.badge.key")
            }
            Button {
                model.checkAccount(account)
            } label: {
                Label("Check Again", systemImage: "arrow.clockwise")
            }
            .disabled(model.isBusy(account))
            Spacer()
        }
        Text("Opens a terminal that runs \(account.provider.displayName)’s sign-in for this account only.")
            .font(.caption)
            .foregroundStyle(.secondary)
    }

    @ViewBuilder private var keyControls: some View {
        let kind = account.provider
        let hasKey = model.hasAPIKey(account)
        if kind.apiKeyChoices.count > 1 {
            ThemedPicker(
                selection: Binding(
                    get: { account.keyVariable ?? "" },
                    set: { variable in model.updateAccount(account) { $0.apiKeyVariable = variable } }),
                options: kind.apiKeyChoices.map { ThemedPicker.Option($0.variable, $0.name) }
            ) {
                Text("Key for")
                Text(verbatim: account.keyVariable ?? "")
            }
        }
        HStack(spacing: 6) {
            SecureField(
                "API key", text: $key,
                prompt: Text(hasKey ? String(localized: "Saved in the Keychain") : String(localized: "Paste the API key"))
            )
            .labelsHidden()
            .font(.callout.monospaced())
            .onSubmit(saveKey)
            .onChange(of: key) { problem = nil }
            Button(hasKey ? String(localized: "Replace") : String(localized: "Save"), action: saveKey)
                .disabled(key.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || model.isBusy(account))
            if hasKey {
                Button(String(localized: "Remove Key"), role: .destructive) { model.removeAPIKey(for: account) }
                    .disabled(model.isBusy(account))
            }
        }
        if UsageInsights.takesAdminKey(account) {
            adminKeyControls
        }
    }

    /// The optional Admin API key, which reads the organization's usage and cost reports for Settings › Usage.
    @ViewBuilder private var adminKeyControls: some View {
        let hasAdminKey = model.hasAdminKey(account)
        VStack(alignment: .leading, spacing: 4) {
            Text("Admin API key (optional)")
                .font(.callout)
            HStack(spacing: 6) {
                SecureField(
                    "Admin API key", text: $adminKey,
                    prompt: Text(hasAdminKey ? String(localized: "Saved in the Keychain") : String(localized: "Paste an Admin API key"))
                )
                .labelsHidden()
                .font(.callout.monospaced())
                .onSubmit(saveAdminKey)
                .onChange(of: adminKey) { problem = nil }
                Button(hasAdminKey ? String(localized: "Replace") : String(localized: "Save"), action: saveAdminKey)
                    .disabled(adminKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                if hasAdminKey {
                    Button(String(localized: "Remove Admin Key"), role: .destructive) { model.removeAdminKey(for: account) }
                }
            }
            Text("Read-only access to your organization’s usage and cost reports, shown in Settings › Usage. Kept in the Keychain and sent only to Anthropic.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func saveAdminKey() {
        let value = adminKey
        guard !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        adminKey = ""
        Task { problem = await model.saveAdminKey(value, for: account) }
    }

    private func saveKey() {
        let value = key
        guard !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        Task {
            problem = await model.saveAPIKey(value, for: account)
            if problem == nil { key = "" }
        }
    }

    private func commitName() {
        let value = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else {
            name = account.name
            return
        }
        name = value
        model.updateAccount(account) { $0.name = value }
    }

    private static func title(_ auth: ProviderAccountAuth, _ kind: ProviderKind) -> String {
        switch auth {
        case .login: String(localized: "\(kind.displayName) login")
        case .apiKey: String(localized: "API key")
        }
    }
}
