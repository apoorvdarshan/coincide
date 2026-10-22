import AppKit
import CoincideCore
import SwiftUI

struct AntigravitySettingsSection: View {
    @Bindable var account: AntigravityAccountStore
    var installation: AntigravityInstallationStore? = nil
    var body: some View {
        Section("Antigravity") {
            Text("Use the Antigravity ACP server and its matching sibling harness. Runtime checks initialize the server; account access requires explicit sign-in.")
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            VStack(alignment: .leading, spacing: 12) {
                Picker("Runtime", selection: $account.runtimeSelection) {
                    ForEach(AntigravityRuntimeSelection.allCases) { mode in Text(mode.name).tag(mode) }
                }.accessibilityIdentifier("antigravity-runtime-selection")
                if account.runtimeSelection == .external {
                    HStack {
                        TextField("Server executable", text: $account.executable)
                            .accessibilityIdentifier("antigravity-server")
                        Button("Choose…") { chooseFile { account.executable = $0 } }
                            .accessibilityLabel("Choose Antigravity server")
                    }
                    HStack {
                        TextField("Sibling harness (automatic when empty)", text: $account.harnessPath)
                            .accessibilityIdentifier("antigravity-harness")
                        Button("Choose…") { chooseFile { account.harnessPath = $0 } }
                            .accessibilityLabel("Choose Antigravity harness")
                    }
                }
            }.disabled(account.isWorking)
            if account.runtimeSelection == .managed, let installation {
                AntigravityManagedRuntimeControls(installation: installation)
            }
            VStack(alignment: .leading, spacing: 12) {
                Picker("Account method", selection: $account.authMethod) {
                    ForEach(AntigravityAuthMethod.allCases) { method in Text(method.name).tag(method) }
                }.accessibilityIdentifier("antigravity-auth-method")
                if account.authMethod == .agentPlatform {
                    Picker("Credentials", selection: $account.agentPlatformCredentialMode) {
                        Text("Project and location").tag(AntigravityAccountStore.AgentPlatformCredentialMode.project)
                        Text("API key").tag(AntigravityAccountStore.AgentPlatformCredentialMode.apiKey)
                    }.accessibilityIdentifier("antigravity-platform-credentials")
                }
                if account.authMethod == .oauthBusiness || (account.authMethod == .agentPlatform && account.agentPlatformCredentialMode == .project) {
                    TextField("Google Cloud project", text: $account.gcpProject)
                        .accessibilityIdentifier("antigravity-project")
                    TextField("Google Cloud location", text: $account.gcpLocation)
                        .accessibilityIdentifier("antigravity-location")
                    if account.authMethod == .agentPlatform {
                        Text("Uses the selected project and location without an API key. A saved key is not reused in this mode.")
                            .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    }
                }
                if account.requiresAPIKey {
                    SecureField("API key", text: $account.apiKey)
                        .accessibilityIdentifier("antigravity-api-key")
                    if account.canReuseStoredCredential {
                        Toggle("Reuse this account’s saved API key", isOn: $account.reuseStoredCredential)
                            .accessibilityIdentifier("antigravity-reuse-key")
                    }
                    Text("API keys are stored in Keychain for this account generation. They are never saved in conversations or URLs.")
                        .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
            }.disabled(account.isWorking)
            VStack(alignment: .leading, spacing: 8) {
                Text(account.statusText).fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("antigravity-account-status")
                if account.runtimeChecked {
                    Text("Runtime initialization passed. This does not verify account access.")
                        .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
                if !account.state.models.isEmpty {
                    Text("Available models: \(account.state.models.count)").font(.caption).foregroundStyle(.secondary)
                }
                if let message = account.errorMessage {
                    Text(message).font(.caption).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true).textSelection(.enabled)
                }
                if let authorization = account.state.authorization {
                    Button("Open Google Sign-In") { NSWorkspace.shared.open(authorization.authorizationURL) }
                        .accessibilityIdentifier("antigravity-open-sign-in")
                        .disabled(!account.state.canCancel)
                    Text("Sign-in opens only when you choose this button. The link expires with this setup attempt.")
                        .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
                ViewThatFits(in: .horizontal) {
                    HStack { actions }
                    VStack(alignment: .leading, spacing: 8) { actions }
                }
            }
        }
    }
    @ViewBuilder private var actions: some View {
        Button("Check Runtime") { Task { await account.checkRuntime() } }
            .disabled(account.isWorking || account.runtimeConfiguration == nil)
            .accessibilityIdentifier("antigravity-check-runtime")
        Button(account.authMethod.usesBrowser ? "Sign In and Check Access" : "Check Account Access") {
            Task { await account.signIn() }
        }.disabled(!account.canStart).accessibilityIdentifier("antigravity-sign-in")
        if account.state.canCancel {
            Button("Cancel Setup") { Task { await account.cancel() } }
                .accessibilityIdentifier("antigravity-cancel")
        } else if account.accessState == .verified {
            Button("Sign Out") { Task { await account.signOut() } }
                .disabled(account.isWorking || account.state.phase == .unconfirmed).accessibilityIdentifier("antigravity-sign-out")
        }
    }
    private func chooseFile(_ selected: @escaping (String) -> Void) {
        let panel = NSOpenPanel(); panel.canChooseDirectories = false; panel.canChooseFiles = true
        panel.allowsMultipleSelection = false; panel.prompt = String(localized: "Choose")
        if panel.runModal() == .OK, let url = panel.url { selected(url.path) }
    }
}

struct AntigravityManagedRuntimeControls: View {
    @Bindable var installation: AntigravityInstallationStore
    var reportGeometry: ((String, CGRect) -> Void)? = nil
    @State private var removing = false
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Installs the Antigravity server and its matching harness. Account sign-in is a separate step.")
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            Text(installation.statusText).fixedSize(horizontal: false, vertical: true)
                .accessibilityIdentifier("antigravity-installation-status")
            if let version = installation.state.installedVersion {
                Text("Installed version: \(version)").font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if installation.isWorking {
                ProgressView(value: installation.state.phase == .downloading ? installation.progress : nil).accessibilityLabel("Runtime installation progress")
                    .accessibilityIdentifier("antigravity-installation-progress")
                if installation.state.phase == .downloading {
                    Text(installation.progressText).font(.caption).foregroundStyle(.secondary)
                }
            }
            if let message = installation.errorMessage ?? installation.state.message {
                Text(message).font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true).textSelection(.enabled)
            }
            ViewThatFits(in: .horizontal) {
                HStack { actions }
                VStack(alignment: .leading, spacing: 8) { actions }
            }
        }
        .background { geometry("bounds") }
        .coordinateSpace(name: "antigravity-installation-controls")
        .confirmationDialog("Remove Managed Antigravity Runtime?", isPresented: $removing, titleVisibility: .visible) {
            Button("Remove Managed Runtime", role: .destructive) { installation.remove() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Remove the runtime installed by Coincide. Account sign-in settings remain saved.")
        }
    }
    @ViewBuilder private var actions: some View {
        Button(installation.startTitle) { installation.start() }
            .disabled(!installation.canStart).accessibilityIdentifier("antigravity-install-runtime")
            .background { geometry("start") }
        if installation.isWorking {
            Button("Cancel Installation") { Task { await installation.cancel() } }
                .disabled(installation.isCancelling).accessibilityIdentifier("antigravity-cancel-installation")
                .background { geometry("cancel") }
        }
        if installation.state.canRemove {
            Button("Remove Managed Runtime…", role: .destructive) { removing = true }
                .disabled(!installation.canRemove).accessibilityIdentifier("antigravity-remove-runtime")
                .background { geometry("remove") }
        }
    }
    private func geometry(_ name: String) -> some View {
        GeometryReader { proxy in
            let frame = proxy.frame(in: .named("antigravity-installation-controls"))
            Color.clear.onAppear { reportGeometry?(name, frame) }
                .onChange(of: frame) { _, value in reportGeometry?(name, value) }
        }
    }
}
