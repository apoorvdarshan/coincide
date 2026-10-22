import AppKit
import CoincideCore
import SwiftUI

struct CodexRuntimeSettingsSection: View {
    @Bindable var runtime: CodexRuntimeStore
    var reportGeometry: ((String, CGRect) -> Void)? = nil
    @State private var advanced = false
    @State private var removing = false

    var body: some View {
        Section("Codex Runtime") {
            VStack(alignment: .leading, spacing: 12) {
                Text("Choose the Codex executable for future requests. Installing or checking a binary does not sign in or verify account access.")
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                Picker("Runtime", selection: $runtime.selection) {
                    ForEach(CodexRuntimeSelection.allCases) { selection in Text(selection.name).tag(selection) }
                }.accessibilityIdentifier("codex-runtime-selection")
                    .disabled(runtime.isApplying)
                if runtime.selection == .existingCLI {
                    Text(runtime.authenticationMode == .cliDefault
                         ? String(localized: "Uses codex from the existing command-line environment. Your current CLI account and configuration remain in place.")
                         : String(localized: "Uses codex from the existing command-line environment. ChatGPT authentication is configured separately below."))
                        .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                } else if runtime.selection == .custom {
                    ViewThatFits(in: .horizontal) {
                        HStack { executableField; chooseExecutable }
                        VStack(alignment: .leading, spacing: 8) { executableField; chooseExecutable }
                    }.disabled(runtime.isApplying)
                } else {
                    managedRuntime
                }
                DisclosureGroup("Advanced: Codex Home", isExpanded: $advanced) {
                    VStack(alignment: .leading, spacing: 8) {
                        TextField(runtime.authenticationMode == .ownedChatGPT
                                  ? String(localized: "Shared Codex home (absolute folder)")
                                  : String(localized: "Codex home (optional absolute folder)"), text: $runtime.homeDirectory)
                            .accessibilityIdentifier("codex-runtime-home")
                        Text(runtime.authenticationMode == .cliDefault
                             ? String(localized: "Leave empty to inherit the CLI’s CODEX_HOME. Choosing another folder does not copy accounts, settings, or conversation history.")
                             : String(localized: "An absolute shared home is required for Coincide-owned authentication. Choosing a folder does not migrate CLI accounts or history."))
                            .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    }.disabled(runtime.isApplying)
                }
                Text("Selected runtime: \(runtime.configuration.selection.name)")
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("codex-runtime-saved-selection")
                if let home = runtime.configuration.homeDirectory {
                    Text("Selected Codex home: \(home)")
                        .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true).textSelection(.enabled)
                }
                if let inspected = runtime.inspected {
                    inspection(inspected)
                } else if runtime.isChecking {
                    HStack { ProgressView().controlSize(.small); Text("Checking the selected executable…") }
                }
                if runtime.hasUnappliedChanges {
                    Text("Changes apply only when you choose Use Runtime. Existing conversations keep their captured runtime.")
                        .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
                if let message = runtime.errorMessage {
                    Text(message).font(.caption).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true).textSelection(.enabled)
                        .accessibilityIdentifier("codex-runtime-error")
                }
                ViewThatFits(in: .horizontal) {
                    HStack { selectionActions }
                    VStack(alignment: .leading, spacing: 8) { selectionActions }
                }
            }
            .background { geometry("bounds") }
            .coordinateSpace(name: "codex-runtime-controls")
        }
        .confirmationDialog("Remove Managed Codex?", isPresented: $removing, titleVisibility: .visible) {
            Button("Remove Managed Codex", role: .destructive) { runtime.removeManagedRuntime() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Remove only the Codex package installed by Coincide. CLI accounts, Codex homes, and custom executables remain saved. A runtime still in use cannot be removed.")
        }
    }
    private var executableField: some View {
        TextField("Executable path or command", text: $runtime.executable)
            .accessibilityIdentifier("codex-runtime-executable")
    }
    private var chooseExecutable: some View {
        Button("Choose Executable…") {
            let panel = NSOpenPanel(); panel.canChooseFiles = true; panel.canChooseDirectories = false
            panel.allowsMultipleSelection = false; panel.prompt = String(localized: "Choose")
            if panel.runModal() == .OK, let url = panel.url { runtime.executable = url.path }
        }.accessibilityIdentifier("codex-runtime-choose-executable")
    }
    private var managedRuntime: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Installs a pinned Codex CLI package. Available features depend on the executable’s actual version; a package verification does not verify account access.")
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            Text(runtime.installationStatus).fixedSize(horizontal: false, vertical: true)
                .accessibilityIdentifier("codex-installation-status")
            if let installed = runtime.state.installedVersion {
                Text("Managed package version: \(installed)")
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            if let target = runtime.state.version, target != runtime.state.installedVersion {
                Text("Package to install: \(target)")
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            Text("The pinned 0.156.1 package does not support Coincide’s reviewed Codex conversation history or in-flight steering. Those controls require a supported newer CLI.")
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            if runtime.state.phase.isWorking || runtime.isCancelling {
                ProgressView(value: runtime.progress).accessibilityLabel("Codex installation progress")
                    .accessibilityIdentifier("codex-installation-progress")
                if runtime.state.phase == .downloading {
                    Text(runtime.progressText).font(.caption).foregroundStyle(.secondary)
                }
            }
            if let message = runtime.state.message {
                Text(message).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
            }
            ViewThatFits(in: .horizontal) {
                HStack { installationActions }
                VStack(alignment: .leading, spacing: 8) { installationActions }
            }
        }
    }
    private func inspection(_ result: CodexInstallationExecutable) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Executable check passed").accessibilityIdentifier("codex-runtime-check-status")
            Text("Source: \(result.source.name)").font(.caption).foregroundStyle(.secondary)
            if let version = result.version {
                Text("Observed version: \(version)").font(.caption).foregroundStyle(.secondary)
                    .accessibilityIdentifier("codex-runtime-observed-version")
            } else {
                Text("The executable did not report a version.").font(.caption).foregroundStyle(.secondary)
            }
            Text(result.executable.path).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
            Text("Account access has not been checked. Refresh the Codex account section separately.")
                .font(.caption).foregroundStyle(.secondary)
        }.fixedSize(horizontal: false, vertical: true)
    }
    @ViewBuilder private var selectionActions: some View {
        Button(runtime.isApplying ? "Applying Runtime…" : "Use Runtime") { Task { await runtime.applySelection() } }
            .disabled(!runtime.canApply).accessibilityIdentifier("codex-runtime-apply")
            .background { geometry("apply") }
        Button("Check Runtime") { Task { await runtime.checkRuntime() } }
            .disabled(!runtime.canCheck).accessibilityIdentifier("codex-runtime-check")
            .background { geometry("check") }
    }
    @ViewBuilder private var installationActions: some View {
        Button(runtime.installationTitle) { runtime.startInstallation() }
            .disabled(!runtime.canStartInstallation).accessibilityIdentifier("codex-install-runtime")
            .background { geometry("install") }
        if runtime.state.phase.isWorking || runtime.isCancelling {
            Button("Cancel Installation") { Task { await runtime.cancelInstallation() } }
                .disabled(runtime.isCancelling).accessibilityIdentifier("codex-cancel-installation")
                .background { geometry("cancel") }
        }
        if runtime.state.canRemove {
            Button("Remove Managed Codex…", role: .destructive) { removing = true }
                .disabled(!runtime.canRemove).accessibilityIdentifier("codex-remove-runtime")
                .background { geometry("remove") }
        }
    }
    private func geometry(_ name: String) -> some View {
        GeometryReader { proxy in
            let frame = proxy.frame(in: .named("codex-runtime-controls"))
            Color.clear.onAppear { reportGeometry?(name, frame) }
                .onChange(of: frame) { _, value in reportGeometry?(name, value) }
        }
    }
}
