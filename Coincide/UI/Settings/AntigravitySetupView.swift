import AppKit
import CoincideKit
import SwiftUI

/// What the Antigravity setup sections need from the provider page.
struct AntigravitySetupContext {
    var status: ProviderStatus
    var isEnabled: Bool
    /// The custom executable path from Settings, if any.
    var customPath: String?
    /// Detects Antigravity again, after an install, sign-in or sign-out.
    var recheck: () -> Void
    /// The executable and environment a session would launch with.
    var launch: () async -> (executable: URL?, environment: [String: String])
}

/// Install Antigravity and sign in with Google, for the Antigravity provider page (T3 Code's
/// `ProviderSetupSection` and `ProviderAuthenticationSection`). Place it inside the page's `Form`.
struct AntigravitySetupSections: View {
    let context: AntigravitySetupContext
    var runtime: AntigravityRuntime = .shared
    var signIn: AntigravitySignIn = .shared

    var body: some View {
        AntigravityRuntimeSection(context: context, runtime: runtime, signIn: signIn)
        AntigravityAccountSection(context: context, runtime: runtime, signIn: signIn)
    }
}

// MARK: Runtime

private struct AntigravityRuntimeSection: View {
    let context: AntigravitySetupContext
    let runtime: AntigravityRuntime
    let signIn: AntigravitySignIn
    @State private var confirmingRemoval = false
    @State private var error: String?

    var body: some View {
        let state = runtime.state
        Section {
            LabeledContent {
                HStack(spacing: 8) {
                    if state.isRunning {
                        Button("Cancel") { runtime.cancel() }
                    } else if runtime.asset != nil {
                        Button(actionTitle(state)) {
                            error = nil
                            runtime.install()
                        }
                        .disabled(signIn.isActive || signIn.isSigningOut)
                    }
                    if state.canRemove && !state.isRunning {
                        Button {
                            confirmingRemoval = true
                        } label: {
                            Image(systemName: "trash")
                        }
                        .buttonStyle(.borderless)
                        .disabled(signIn.isActive || runtime.leaseCount > 0)
                        .help(Text("Remove Downloaded Runtime"))
                        .accessibilityLabel(Text("Remove Downloaded Runtime"))
                    }
                }
            } label: {
                Text("Runtime")
                Text(statusText(state))
                    .monospacedDigit()
            }
            if state.phase == .downloading, let total = state.totalBytes, total > 0 {
                ProgressView(value: Double(min(state.downloadedBytes, total)), total: Double(total))
                    .accessibilityLabel(Text("Antigravity download"))
            } else if state.isRunning {
                ProgressView().progressViewStyle(.linear)
            }
            if let message = error ?? notice(state) {
                Text(message)
                    .font(.callout)
                    .foregroundStyle(error != nil || state.phase == .failed ? .red : .secondary)
                    .textSelection(.enabled)
            }
            if let note = customPathNote {
                Text(note).font(.callout).foregroundStyle(.secondary)
            }
        } header: {
            Text("Antigravity Runtime")
        } footer: {
            Text(
                "Coincide downloads Google’s Antigravity runtime from dl.google.com, checks it against the release Coincide expects (size, SHA-256 and Google’s signature), and keeps it in Coincide’s data folder."
            )
        }
        .alert(Text("Remove the downloaded Antigravity runtime?"), isPresented: $confirmingRemoval) {
            Button("Remove", role: .destructive, action: remove)
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Your Google sign-in and thread history are kept. You can install the runtime again at any time.")
        }
        .onAppear { runtime.refresh() }
        .onChange(of: state.phase) { _, phase in
            if phase == .succeeded { context.recheck() }
        }
    }

    private func actionTitle(_ state: AntigravityInstallState) -> String {
        if state.installedVersion != nil {
            return state.isUpdateAvailable ? String(localized: "Update Antigravity") : String(localized: "Reinstall Antigravity")
        }
        if state.phase == .failed || state.phase == .cancelled { return String(localized: "Retry Installation") }
        return context.status.executable != nil ? String(localized: "Install Managed Runtime") : String(localized: "Install Antigravity")
    }

    /// T3 Code's installation status line.
    private func statusText(_ state: AntigravityInstallState) -> String {
        switch state.phase {
        case .downloading:
            let downloaded = state.downloadedBytes.formatted(.byteCount(style: .file))
            guard let total = state.totalBytes else { return String(localized: "Downloading \(downloaded)…") }
            return String(localized: "Downloading \(downloaded) of \(total.formatted(.byteCount(style: .file)))…")
        case .extracting: return String(localized: "Extracting Antigravity…")
        case .verifying: return String(localized: "Checking the downloaded runtime…")
        default: break
        }
        if let installed = state.installedVersion {
            if state.isUpdateAvailable, let version = state.version {
                return String(localized: "Version \(installed) installed. Version \(version) is available.")
            }
            return String(localized: "Version \(installed) installed.")
        }
        if runtime.asset == nil {
            return String(localized: "Google doesn’t publish an Antigravity runtime for this Mac.")
        }
        if context.status.executable != nil, !isCustomPath {
            return String(localized: "Using Antigravity found on your PATH.")
        }
        if let total = state.totalBytes {
            return String(localized: "Not installed. \(total.formatted(.byteCount(style: .file))) download.")
        }
        return String(localized: "Not installed.")
    }

    /// The last result worth showing once nothing runs: why it failed or that it was cancelled.
    private func notice(_ state: AntigravityInstallState) -> String? {
        guard !state.isRunning, state.phase == .failed || state.phase == .cancelled else { return nil }
        return state.message
    }

    private var isCustomPath: Bool {
        !(context.customPath ?? "").trimmingCharacters(in: .whitespaces).isEmpty
    }

    private var customPathNote: String? {
        guard isCustomPath else { return nil }
        return String(localized: "Antigravity runs from the custom path below. Installing here keeps that path; clear it to use the downloaded runtime.")
    }

    private func remove() {
        do {
            try runtime.remove(protecting: [context.customPath ?? ""])
            error = nil
            context.recheck()
        } catch {
            self.error = error.localizedDescription
        }
    }
}

// MARK: Google account

private struct AntigravityAccountSection: View {
    let context: AntigravitySetupContext
    let runtime: AntigravityRuntime
    let signIn: AntigravitySignIn
    @State private var callback = ""
    @State private var error: String?
    @State private var confirmingSignOut = false
    @State private var isStarting = false

    var body: some View {
        Section {
            LabeledContent {
                HStack(spacing: 8) {
                    if signIn.isActive {
                        Button("Cancel") { signIn.cancel() }
                    } else {
                        Button(signInTitle, action: start)
                            .disabled(!canSignIn)
                        if isSignedIn {
                            Button("Sign Out…") { confirmingSignOut = true }
                                .disabled(signIn.isSigningOut || runtime.state.isRunning)
                        }
                    }
                }
            } label: {
                Text("Google Account")
                Text(description)
            }
            if let request = signIn.authorization, signIn.phase == .waiting {
                linkRow(request.url)
                callbackRow
            }
            if let message = error ?? failure {
                Text(message)
                    .font(.callout)
                    .foregroundStyle(.red)
                    .textSelection(.enabled)
            }
        } header: {
            Text("Sign-in")
        } footer: {
            Text(
                "Antigravity uses your Google account’s subscription. Coincide keeps this sign-in in its own Antigravity profile, separate from ~/.gemini and any other Antigravity install."
            )
        }
        .alert(Text("Sign out of Google in Antigravity?"), isPresented: $confirmingSignOut) {
            Button("Sign Out", role: .destructive, action: signOut)
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Thread history is kept. Antigravity asks you to sign in again before its next turn.")
        }
        .onChange(of: signIn.phase) { _, phase in
            if phase == .waiting { callback = "" }
            if phase == .succeeded { context.recheck() }
        }
    }

    private var isSignedIn: Bool {
        if signIn.isActive { return false }
        if signIn.phase == .succeeded { return true }
        return context.status.state == .ready
    }

    private var canSignIn: Bool {
        context.isEnabled && !isStarting && !signIn.isSigningOut && !runtime.state.isRunning && context.status.executable != nil
            && context.status.state != .notInstalled
    }

    private var signInTitle: String {
        if isSignedIn { return String(localized: "Sign In Again") }
        if signIn.phase == .failed || signIn.phase == .cancelled { return String(localized: "Retry Sign-in") }
        return String(localized: "Sign in with Google")
    }

    /// T3 Code's account line.
    private var description: String {
        switch signIn.phase {
        case .starting: return signIn.message ?? String(localized: "Starting sign-in…")
        case .waiting: return String(localized: "Finish signing in in your browser.")
        case .verifying: return signIn.message ?? String(localized: "Checking your account…")
        default: break
        }
        if signIn.isSigningOut { return String(localized: "Signing out…") }
        if isSignedIn { return String(localized: "Signed in with Google.") }
        if !context.isEnabled { return String(localized: "Turn on Antigravity to sign in.") }
        if context.status.executable == nil || context.status.state == .notInstalled {
            return String(localized: "Install Antigravity first, then sign in with Google.")
        }
        if signIn.phase == .idle, let message = signIn.message { return message }
        return String(localized: "Not signed in.")
    }

    private var failure: String? {
        signIn.phase == .failed ? signIn.message : nil
    }

    private func linkRow(_ url: URL) -> some View {
        HStack(spacing: 8) {
            Text(url.absoluteString)
                .font(.callout.monospaced())
                .lineLimit(1)
                .truncationMode(.middle)
                .textSelection(.enabled)
                .help(url.absoluteString)
            Spacer(minLength: 8)
            Button("Open in Browser") { NSWorkspace.shared.open(url) }
            Button {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(url.absoluteString, forType: .string)
            } label: {
                Image(systemName: "doc.on.doc")
            }
            .buttonStyle(.borderless)
            .help(Text("Copy Sign-in Link"))
            .accessibilityLabel(Text("Copy Sign-in Link"))
        }
    }

    private var callbackRow: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                TextField("Address", text: $callback, prompt: Text(verbatim: "http://127.0.0.1:…/?state=…&code=…"))
                    .labelsHidden()
                    .textFieldStyle(.roundedBorder)
                    .font(.callout.monospaced())
                    .onSubmit(sendCallback)
                Button("Send", action: sendCallback)
                    .disabled(callback.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !signIn.acceptsCallback)
            }
            Text("Signing in from another device? After Google sign-in, paste the address its browser ends on.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private func start() {
        error = nil
        isStarting = true
        Task {
            defer { isStarting = false }
            let launch = await context.launch()
            guard let executable = launch.executable else {
                error = String(localized: "Install Antigravity first, then sign in with Google.")
                return
            }
            signIn.start(executable: executable, environment: launch.environment)
        }
    }

    private func sendCallback() {
        let text = callback
        error = nil
        Task {
            do {
                try await signIn.complete(callback: text)
                callback = ""
            } catch {
                self.error = error.localizedDescription
            }
        }
    }

    private func signOut() {
        error = nil
        Task {
            let launch = await context.launch()
            guard let executable = launch.executable else {
                error = String(localized: "Install Antigravity first, then sign in with Google.")
                return
            }
            do {
                try await signIn.signOut(executable: executable, environment: launch.environment)
            } catch {
                self.error = error.localizedDescription
            }
            context.recheck()
        }
    }
}
