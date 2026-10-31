import AppKit
import SwiftUI

/// Computer Use is owned by Coincide and shared by providers through a private connection for each thread.
struct ComputerUseSettingsView: View {
    @Bindable var controller: ComputerUseController

    init(controller: ComputerUseController = .shared) {
        self.controller = controller
    }

    var body: some View {
        Form {
            Section {
                SettingsPaneHeader(title: String(localized: "Computer Use")) {
                    SettingsIconTile(
                        symbol: SettingsSection.computerUse.symbolName, color: SettingsSection.computerUse.tint, size: 44)
                } subtitle: {
                    Text("Let agents see and interact with Mac apps through Coincide.")
                }
            }

            Section {
                Toggle(isOn: $controller.enabled) {
                    Text("Allow agents to use this Mac")
                    Text("Agents can view the screen and interact with apps while Computer Use is on. All providers use a private connection for each thread.")
                }
                Toggle(isOn: $controller.showsAgentCursor) {
                    Text("Show agent cursor")
                    Text("Shows where agents click and type, on whichever display they’re working on.")
                }
                LabeledContent("Status") {
                    Text(controller.stateDescription)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.trailing)
                }
                LabeledContent("Driver version") {
                    Text(controller.backendVersion)
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                }
            }

            Section {
                ComputerUsePermissionRow(
                    title: "Accessibility",
                    detail: "Lets Coincide read app controls, click and type.",
                    granted: controller.accessibilityGranted,
                    grantLabel: "Grant Accessibility access",
                    settingsLabel: "Open Accessibility settings",
                    request: controller.requestAccessibility,
                    openSettings: controller.openAccessibilitySettings)
                ComputerUsePermissionRow(
                    title: "Screen Recording",
                    detail: "Lets Coincide capture app windows and the screen for agents.",
                    granted: controller.screenRecordingGranted,
                    grantLabel: "Grant Screen Recording access",
                    settingsLabel: "Open Screen Recording settings",
                    request: controller.requestScreenRecording,
                    openSettings: controller.openScreenRecordingSettings)
                Text("Grant these permissions to Coincide in System Settings. Return here to refresh their status.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            } header: {
                Text("Permissions")
            }

            Section {
                if controller.activeThreadTitles.isEmpty {
                    Text("No threads are using this Mac.")
                        .foregroundStyle(.secondary)
                } else {
                    // Titles can repeat or change; a single text view keeps every title without assigning identity to it.
                    Label(controller.activeThreadTitles.joined(separator: "\n"), systemImage: "bubble.left")
                }
                HStack {
                    Button("Refresh") { controller.refresh() }
                    Spacer()
                    Button("Restart Computer Use") { controller.restart() }
                        .disabled(!controller.enabled)
                    Button("Stop Computer Use", role: .destructive) { controller.stop() }
                        .disabled(!controller.enabled && !controller.isRunning)
                }
                Text("Turning Computer Use off ends agents’ access. Computer Use also stops when Coincide quits.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            } header: {
                Text("Activity")
            }

            if let error = controller.lastError {
                Section {
                    Text(error)
                        .foregroundStyle(.red)
                        .textSelection(.enabled)
                } header: {
                    Text("Computer Use needs attention")
                }
            }
        }
        .formStyle(.grouped)
        .task { controller.refresh() }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            controller.refresh()
        }
    }
}

private struct ComputerUsePermissionRow: View {
    let title: LocalizedStringKey
    let detail: LocalizedStringKey
    let granted: Bool
    let grantLabel: LocalizedStringKey
    let settingsLabel: LocalizedStringKey
    let request: () -> Void
    let openSettings: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                Text(detail)
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            HStack {
                Label(granted ? "Allowed" : "Not allowed", systemImage: granted ? "checkmark.circle.fill" : "circle")
                    .foregroundStyle(granted ? .green : .secondary)
                Spacer(minLength: 8)
                if !granted {
                    Button("Grant Access") { request() }
                        .accessibilityLabel(grantLabel)
                }
                Button("Open System Settings") { openSettings() }
                    .accessibilityLabel(settingsLabel)
            }
        }
        .padding(.vertical, 2)
    }
}
