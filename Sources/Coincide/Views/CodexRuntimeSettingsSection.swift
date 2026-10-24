import AppKit
import CoincideCore
import SwiftUI

struct CodexRuntimeSettingsSection: View {
    @Bindable var runtime: CodexRuntimeStore
    var reportGeometry: ((String, CGRect) -> Void)? = nil
    @State private var advanced = false
    @State private var removing = false

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            SettingsCard(title: "Codex runtime") {
                SettingsRow(title: "Runtime", subtitle: "Choose which Codex CLI to use.") {
                    SettingsMenu(label: runtime.selection.name) {
                        ForEach(CodexRuntimeSelection.allCases) { selection in
                            Button { runtime.selection = selection } label: {
                                if selection == runtime.selection { Label(selection.name, systemImage: "checkmark") }
                                else { Text(selection.name) }
                            }
                        }
                    }
                    .accessibilityIdentifier("codex-runtime-selection")
                    .disabled(runtime.isApplying)
                }
                if runtime.selection == .custom {
                    SettingsDivider()
                    SettingsRow(title: "Executable") {
                        HStack(spacing: 8) { executableField; chooseExecutable }
                    }.disabled(runtime.isApplying)
                }
                SettingsDivider()
                SettingsRow(title: "Currently using") {
                    Text(runtime.configuration.selection.name)
                        .foregroundStyle(.secondary)
                        .accessibilityIdentifier("codex-runtime-saved-selection")
                }
                if let inspected = runtime.inspected {
                    SettingsDivider()
                    inspection(inspected)
                } else if runtime.isChecking {
                    SettingsDivider()
                    SettingsRow(title: "Checking runtime…") {
                        ProgressView().controlSize(.small)
                    }
                }
                SettingsDivider()
                SettingsRow(title: "Apply runtime", subtitle: "Applies to future chats. Existing chats keep their runtime.") {
                    HStack(spacing: 8) { selectionActions }
                }
                if let message = runtime.errorMessage {
                    SettingsDivider()
                    Text(message).font(.system(size: 12)).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true).textSelection(.enabled)
                        .padding(.vertical, 14).accessibilityIdentifier("codex-runtime-error")
                }
            }
            if runtime.selection == .managed { managedRuntime }
            SettingsCard(title: nil) {
                DisclosureGroup("Advanced", isExpanded: $advanced) {
                    SettingsRow(title: "Codex home", subtitle: "Leave empty to use the CLI default. Accounts and history are not copied.") {
                        TextField(runtime.authenticationMode == .ownedChatGPT
                                  ? String(localized: "Absolute shared folder")
                                  : String(localized: "Default"), text: $runtime.homeDirectory)
                            .textFieldStyle(.roundedBorder).frame(minWidth: 150, maxWidth: 300)
                            .accessibilityIdentifier("codex-runtime-home")
                    }.disabled(runtime.isApplying)
                    if let home = runtime.configuration.homeDirectory {
                        SettingsDivider()
                        SettingsRow(title: "Saved home") {
                            Text(home).foregroundStyle(.secondary).textSelection(.enabled)
                                .fixedSize(horizontal: false, vertical: true).frame(maxWidth: 320, alignment: .trailing)
                        }
                    }
                    if let inspected = runtime.inspected {
                        SettingsDivider()
                        SettingsRow(title: "Runtime source") { Text(inspected.source.name).foregroundStyle(.secondary) }
                        SettingsDivider()
                        SettingsRow(title: "Executable path") {
                            Text(inspected.executable.path).foregroundStyle(.secondary).textSelection(.enabled)
                                .fixedSize(horizontal: false, vertical: true).frame(maxWidth: 320, alignment: .trailing)
                        }
                    }
                }.font(.system(size: 13)).padding(.vertical, 14)
            }
        }
        .background { geometry("bounds") }
        .coordinateSpace(name: "codex-runtime-controls")
        .confirmationDialog("Remove Managed Codex?", isPresented: $removing, titleVisibility: .visible) {
            Button("Remove Managed Codex", role: .destructive) { runtime.removeManagedRuntime() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Removes the package installed by Coincide. Accounts, homes and custom executables are kept. A runtime in use cannot be removed.")
        }
    }
    private var executableField: some View {
        TextField("Path or command", text: $runtime.executable)
            .textFieldStyle(.roundedBorder).frame(minWidth: 150, maxWidth: 280)
            .accessibilityIdentifier("codex-runtime-executable")
    }
    private var chooseExecutable: some View {
        Button("Choose…") {
            let panel = NSOpenPanel(); panel.canChooseFiles = true; panel.canChooseDirectories = false
            panel.allowsMultipleSelection = false; panel.prompt = String(localized: "Choose")
            if panel.runModal() == .OK, let url = panel.url { runtime.executable = url.path }
        }.buttonStyle(SettingsActionButtonStyle())
            .accessibilityLabel("Choose Codex executable")
            .accessibilityIdentifier("codex-runtime-choose-executable")
    }
    private var managedRuntime: some View {
        SettingsCard(title: "Managed installation") {
            SettingsRow(title: "Codex package", subtitle: "Download and manage a separate CLI for Coincide.") {
                Text(runtime.installationStatus).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("codex-installation-status")
            }
            if let installed = runtime.state.installedVersion {
                SettingsDivider()
                SettingsRow(title: "Installed version") { Text(installed).foregroundStyle(.secondary) }
            }
            if let target = runtime.state.version, target != runtime.state.installedVersion {
                SettingsDivider()
                SettingsRow(title: "Available package") { Text(target).foregroundStyle(.secondary) }
            }
            if runtime.state.phase.isWorking || runtime.isCancelling {
                VStack(alignment: .leading, spacing: 6) {
                    ProgressView(value: runtime.progress).accessibilityLabel("Codex installation progress")
                        .accessibilityIdentifier("codex-installation-progress")
                    if runtime.state.phase == .downloading {
                        Text(runtime.progressText).font(.system(size: 12)).foregroundStyle(.secondary)
                    }
                }.padding(.vertical, 14)
            }
            if let message = runtime.state.message {
                Text(message).font(.system(size: 12)).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true).textSelection(.enabled).padding(.vertical, 14)
            }
            SettingsDivider()
            SettingsRow(title: "Installation") { HStack(spacing: 8) { installationActions } }
        }
    }
    private func inspection(_ result: CodexInstallationExecutable) -> some View {
        SettingsRow(title: "Runtime check", subtitle: "Checks the executable. Account status is shown separately.") {
            VStack(alignment: .trailing, spacing: 4) {
                Text("Executable ready").accessibilityIdentifier("codex-runtime-check-status")
                if let version = result.version {
                    Text(version).font(.system(size: 12)).foregroundStyle(.secondary)
                        .accessibilityIdentifier("codex-runtime-observed-version")
                } else { Text("Version not reported").font(.system(size: 12)).foregroundStyle(.secondary) }
            }
        }
    }
    @ViewBuilder private var selectionActions: some View {
        Button(runtime.isApplying ? "Applying…" : "Use Runtime") { Task { await runtime.applySelection() } }
            .buttonStyle(SettingsActionButtonStyle())
            .disabled(!runtime.canApply).accessibilityIdentifier("codex-runtime-apply")
            .background { geometry("apply") }
        Button("Check Runtime") { Task { await runtime.checkRuntime() } }
            .buttonStyle(SettingsActionButtonStyle())
            .disabled(!runtime.canCheck).accessibilityIdentifier("codex-runtime-check")
            .background { geometry("check") }
    }
    @ViewBuilder private var installationActions: some View {
        Button(runtime.installationTitle) { runtime.startInstallation() }
            .buttonStyle(SettingsActionButtonStyle())
            .disabled(!runtime.canStartInstallation).accessibilityIdentifier("codex-install-runtime")
            .background { geometry("install") }
        if runtime.state.phase.isWorking || runtime.isCancelling {
            Button("Cancel Installation") { Task { await runtime.cancelInstallation() } }
                .buttonStyle(SettingsActionButtonStyle())
                .disabled(runtime.isCancelling).accessibilityIdentifier("codex-cancel-installation")
                .background { geometry("cancel") }
        }
        if runtime.state.canRemove {
            Button("Remove…", role: .destructive) { removing = true }
                .buttonStyle(SettingsActionButtonStyle())
                .accessibilityLabel("Remove Managed Codex")
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
