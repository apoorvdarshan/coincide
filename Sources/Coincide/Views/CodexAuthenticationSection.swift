import CoincideCore
import SwiftUI

/// Account controls live inside Settings' native grouped form. Installing a
/// binary and selecting an authentication mode remain separate user actions.
struct CodexAuthenticationSection: View {
    @Bindable var authentication: CodexAuthenticationStore
    @Bindable var runtime: CodexRuntimeStore
    var reportGeometry: ((String, CGRect) -> Void)? = nil
    @Environment(\.openURL) private var openURL
    @State private var revealEmails = false
    @State private var signingOut: UUID?

    var body: some View {
        Section("Codex Authentication") {
            VStack(alignment: .leading, spacing: 12) {
                Picker("Sign-in", selection: $runtime.authenticationMode) {
                    Text("Existing CLI account").tag(CodexAuthenticationMode.cliDefault)
                    Text("ChatGPT through Coincide").tag(CodexAuthenticationMode.ownedChatGPT)
                }
                .accessibilityIdentifier("codex-authentication-mode")
                .disabled(authentication.isWorking || runtime.isApplying)

                if runtime.authenticationMode == .ownedChatGPT {
                    Text("Sign in explicitly with ChatGPT and allow token sharing. Coincide keeps this connection separate from the CLI’s saved sign-in. Installing or checking Codex does not authenticate an account.")
                        .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    TextField("Shared Codex home (absolute folder)", text: $runtime.homeDirectory)
                        .accessibilityIdentifier("codex-authentication-home")
                        .disabled(authentication.isWorking || runtime.isApplying)
                    Text("Choose a shared Codex home before enabling this connection. Conversation history stays in that home; authentication uses a separate private home. Existing files and CLI accounts are not migrated.")
                        .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                } else {
                    Text("Use the selected executable’s existing CLI authentication. Coincide does not sign in, change its account or migrate its credentials.")
                        .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }

                if runtime.hasUnappliedChanges {
                    Text("Choose Use Authentication to save this mode and runtime selection. Existing conversations and queued messages keep their captured settings.")
                        .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    Button(runtime.isApplying ? "Saving…" : "Use Authentication") {
                        Task { await runtime.applySelection() }
                    }
                    .disabled(!runtime.canApply || authentication.isWorking)
                    .accessibilityIdentifier("codex-authentication-apply")
                    .background { geometry("apply") }
                }

                if runtime.configuration.authenticationMode == .ownedChatGPT {
                    ownedAccount
                }
            }
            .background { geometry("bounds") }
            .coordinateSpace(name: "codex-authentication-controls")
        }
        .confirmationDialog("Sign Out of This ChatGPT Account?", isPresented: Binding(
            get: { signingOut != nil }, set: { if !$0 { signingOut = nil } }), titleVisibility: .visible) {
                if let profileID = signingOut {
                    Button("Sign Out", role: .destructive) {
                        signingOut = nil
                        Task { await authentication.signOut(profileID: profileID) }
                    }
                }
                Button("Cancel", role: .cancel) { signingOut = nil }
        } message: {
            Text("Remove this connection’s saved credential. Other accounts, CLI sign-ins and conversation history are kept. Pending input will not be replayed.")
        }
        .onChange(of: authentication.overview?.binding) { _, _ in revealEmails = false }
        .onChange(of: runtime.configuration.instanceID) { _, _ in revealEmails = false; signingOut = nil }
    }

    private var ownedAccount: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(authentication.statusText)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityIdentifier("codex-authentication-status")
            if let message = authentication.state.message {
                Text(message).font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true).textSelection(.enabled)
            }
            if authentication.isWorking {
                ProgressView().controlSize(.small).accessibilityLabel("Updating ChatGPT account")
            }
            if let url = authentication.authorizationURL {
                ViewThatFits(in: .horizontal) {
                    HStack { browserActions(url) }
                    VStack(alignment: .leading, spacing: 8) { browserActions(url) }
                }
                Text("Complete ChatGPT sign-in in your browser. If it did not open, choose Open ChatGPT Sign-In Again. The sign-in expires after five minutes.")
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            } else if authentication.canCancel {
                cancelButton
            }
            if !authentication.profiles.isEmpty {
                if authentication.profiles.contains(where: { $0.email != nil }) {
                    Toggle("Show account emails", isOn: $revealEmails)
                        .accessibilityIdentifier("codex-authentication-reveal-email")
                }
                ForEach(authentication.profiles) { profile in
                    profileRow(profile)
                }
            }
            ViewThatFits(in: .horizontal) {
                HStack { accountActions }
                VStack(alignment: .leading, spacing: 8) { accountActions }
            }
            if let error = authentication.errorMessage {
                Text(error).font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true).textSelection(.enabled)
                    .accessibilityIdentifier("codex-authentication-error")
            }
            Text("ChatGPT subscription allowance is not reported for this token-sharing connection. Check usage with the account you connected; a saved account is separate from a binary installation check.")
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                .accessibilityIdentifier("codex-authentication-usage-unsupported")
            Link("Open ChatGPT Usage", destination: URL(string: "https://chatgpt.com/#settings/Usage")!)
                .accessibilityIdentifier("codex-authentication-usage")
            Text("Account changes pause affected conversations. Drafts and queued input are preserved; sending resumes only through an explicit action.")
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
    }
    @ViewBuilder private var accountActions: some View {
        Button(authentication.profiles.isEmpty ? "Sign In with ChatGPT…" : "Add ChatGPT Account…") {
            Task { await authentication.startSignIn() }
        }
        .disabled(!authentication.canStart || runtime.hasUnappliedChanges)
        .accessibilityIdentifier("codex-authentication-sign-in")
        .background { geometry("sign-in") }
        Button(authentication.isRefreshing ? "Refreshing…" : "Refresh Saved Accounts") {
            Task { await authentication.refreshAccounts() }
        }
        .disabled(!authentication.canRefresh || runtime.hasUnappliedChanges)
        .accessibilityIdentifier("codex-authentication-refresh")
        .background { geometry("refresh") }
    }
    @ViewBuilder private func browserActions(_ url: URL) -> some View {
        Button("Open ChatGPT Sign-In Again") { openURL(url) }
            .accessibilityIdentifier("codex-authentication-open-browser")
            .background { geometry("browser") }
        if authentication.canCancel { cancelButton }
    }
    private var cancelButton: some View {
        Button(authentication.isCancelling ? "Cancelling…" : "Cancel Sign-In") {
            Task { await authentication.cancel() }
        }
        .disabled(!authentication.canCancel)
        .accessibilityIdentifier("codex-authentication-cancel")
        .background { geometry("cancel") }
    }
    private func profileRow(_ profile: CodexAccountProfile) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(profileTitle(profile)).font(.subheadline.weight(.medium))
                .fixedSize(horizontal: false, vertical: true).textSelection(.enabled)
            if authentication.isSelectedProfile(profile.id) {
                Text("Selected account").font(.caption).foregroundStyle(.secondary)
            } else if profile.isActive {
                Text("Active in saved accounts; choose Use Account for this connection.")
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            if profile.requiresReconnect {
                Text("Reconnect before using this saved account.").font(.caption).foregroundStyle(.secondary)
            } else if !profile.sharingEnabled {
                Text("Token sharing is disabled. Reconnect and allow sharing before selecting this account.")
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            } else if !profile.hasCredential {
                Text("Signed out; the account registration is retained.").font(.caption).foregroundStyle(.secondary)
            }
            ViewThatFits(in: .horizontal) {
                HStack { profileActions(profile) }
                VStack(alignment: .leading, spacing: 8) { profileActions(profile) }
            }
        }
        .padding(.vertical, 4)
        .accessibilityElement(children: .contain)
    }
    @ViewBuilder private func profileActions(_ profile: CodexAccountProfile) -> some View {
        if !authentication.isSelectedProfile(profile.id) {
            Button("Use Account") { Task { await authentication.selectProfile(profile.id) } }
                .disabled(!authentication.canSelectProfile(profile.id) || runtime.hasUnappliedChanges)
                .accessibilityIdentifier("codex-authentication-select-\(profile.id.uuidString)")
        }
        Button("Reconnect…") { Task { await authentication.reconnect(profileID: profile.id) } }
            .disabled(!authentication.canStart || runtime.hasUnappliedChanges)
            .accessibilityIdentifier("codex-authentication-reconnect-\(profile.id.uuidString)")
        if profile.hasCredential || profile.requiresReconnect {
            Button("Sign Out…") { signingOut = profile.id }
                .disabled(!authentication.canStart || runtime.hasUnappliedChanges)
                .accessibilityIdentifier("codex-authentication-sign-out-\(profile.id.uuidString)")
        }
    }
    private func profileTitle(_ profile: CodexAccountProfile) -> String {
        if revealEmails, let email = profile.email { return email }
        let ordinal = (authentication.profiles.firstIndex(where: { $0.id == profile.id }) ?? 0) + 1
        return String(localized: "ChatGPT account \(ordinal)")
    }
    private func geometry(_ name: String) -> some View {
        GeometryReader { proxy in
            Color.clear.onAppear { reportGeometry?(name, proxy.frame(in: .named("codex-authentication-controls"))) }
                .onChange(of: proxy.frame(in: .named("codex-authentication-controls"))) { _, frame in reportGeometry?(name, frame) }
        }
    }
}
