import CoincideRemoteKit
import SwiftUI

struct SettingsView: View {
    @Environment(RemoteClient.self) private var client
    @Environment(AppearanceSettings.self) private var appearance
    @Environment(Navigator.self) private var navigator
    @Environment(\.theme) private var theme
    @State private var addingHostTo: SavedMac?
    @State private var newHost = ""
    @State private var forgetting: SavedMac?
    @AppStorage("composer.returnSends") private var returnSends = true

    var body: some View {
        Form {
            Group { sections }
                .themedCards(theme)
        }
        .scrollContentBackground(.hidden)
        .background(theme.isDark ? theme.content : theme.sidebar)
        .task(id: client.isConnected) { await client.loadMacSettings() }
        .navigationTitle("Settings")
        .navigationBarTitleDisplayMode(.large)
        .alert("Add an Address", isPresented: Binding(get: { addingHostTo != nil }, set: { if !$0 { addingHostTo = nil } })) {
            TextField("192.168.1.20 or mac.tailnet.ts.net", text: $newHost)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
            Button("Add") {
                if let mac = addingHostTo { client.addHost(newHost, to: mac.serverID) }
                newHost = ""
                addingHostTo = nil
            }
            Button("Cancel", role: .cancel) { addingHostTo = nil }
        } message: {
            Text("Coincide Remote tries it after the Mac’s own addresses.")
        }
        .confirmationDialog(
            "Forget “\(forgetting?.name ?? "")”?", isPresented: Binding(get: { forgetting != nil }, set: { if !$0 { forgetting = nil } }),
            titleVisibility: .visible
        ) {
            Button("Forget", role: .destructive) {
                if let mac = forgetting { client.forget(mac.serverID) }
                forgetting = nil
            }
        } message: {
            Text("To connect again, pair with the code the Mac shows. Revoke this device in the Mac’s Settings too.")
        }
        #if DEBUG
        // Screenshots of a pane without taps: `-CoincideRemoteSettingsPane general`.
        .navigationDestination(isPresented: .constant(DemoData.value(after: "-CoincideRemoteSettingsPane") != nil)) {
            MacSettingsPageView(pageID: DemoData.value(after: "-CoincideRemoteSettingsPane") ?? "")
        }
        #endif
    }

    @ViewBuilder private var sections: some View {
        @Bindable var appearance = appearance
            Section("Macs") {
                ForEach(client.savedMacs) { mac in
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(mac.name)
                            Text(status(mac)).font(.caption).foregroundStyle(theme.secondaryInk)
                            Text(mac.hosts.map(\.host).joined(separator: ", "))
                                .font(.caption2.monospaced()).foregroundStyle(theme.secondaryInk).lineLimit(2)
                        }
                        Spacer()
                        if client.mac?.serverID == mac.serverID, client.isConnected {
                            Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                                .accessibilityLabel(Text("Connected"))
                        }
                    }
                    .contentShape(Rectangle())
                    .onTapGesture { client.connect(to: mac) }
                    .contextMenu {
                        Button("Connect") { client.connect(to: mac) }
                        Button("Add Address…") { addingHostTo = mac }
                        Button("Forget", role: .destructive) { forgetting = mac }
                    }
                    .swipeActions {
                        Button("Forget", role: .destructive) { forgetting = mac }
                        Button("Address") { addingHostTo = mac }.tint(.indigo)
                    }
                    .accessibilityAction(named: Text("Add Address")) { addingHostTo = mac }
                    .accessibilityAction(named: Text("Forget")) { forgetting = mac }
                }
                Button {
                    navigator.showsConnect = true
                } label: {
                    Label("Pair Another Mac", systemImage: "plus")
                }
            }

            Section {
                Toggle("Use the Mac’s Theme", isOn: $appearance.followsMac)
                if !appearance.followsMac {
                    Picker("Appearance", selection: $appearance.mode) {
                        ForEach(AppearanceSettings.Mode.allCases) { Text($0.title).tag($0) }
                    }
                    Picker("Dark Theme", selection: $appearance.darkThemeID) {
                        ForEach(RemotePalette.dark) { palette in
                            ThemeSwatchLabel(palette: palette).tag(palette.id)
                        }
                    }
                    Picker("Light Theme", selection: $appearance.lightThemeID) {
                        ForEach(RemotePalette.light) { palette in
                            ThemeSwatchLabel(palette: palette).tag(palette.id)
                        }
                    }
                }
            } header: {
                Text("Appearance")
            } footer: {
                if appearance.followsMac, let server = client.server {
                    Text("Following \(server.name): \(RemotePalette.dark(server.theme.darkThemeID).name) and \(RemotePalette.light(server.theme.lightThemeID).name).")
                }
            }

            Section {
                Toggle("Send with Return", isOn: $returnSends)
            } footer: {
                Text("With a hardware keyboard. Shift-Return starts a new line.")
            }

            NotificationsSection()

            MacSettingsSections()

            Section("About") {
                LabeledContent("Coincide Remote", value: RemoteClient.appVersion)
                if let server = client.server {
                    LabeledContent("Coincide on \(server.name)", value: server.appVersion)
                }
                LabeledContent("Protocol", value: "\(RemoteProtocol.version)")
            }
    }

    private func status(_ mac: SavedMac) -> String {
        if client.mac?.serverID == mac.serverID {
            switch client.phase {
            case .connected: return String(localized: "Connected")
            case .connecting: return String(localized: "Connecting…")
            case .offline(let message): return message
            case .needsPairing(let message): return message
            case .idle: return String(localized: "Not connected")
            }
        }
        if let date = mac.lastConnectedAt {
            return String(localized: "Last connected \(date.formatted(.relative(presentation: .named)))")
        }
        return String(localized: "Paired")
    }
}

/// Alerts from the Mac: whether iOS allows them, and "Notify this iPhone when it's locked".
struct NotificationsSection: View {
    @Environment(RemoteClient.self) private var client
    @Environment(\.theme) private var theme
    @Environment(\.openURL) private var openURL
    @State private var alerts = PhoneAlerts.shared
    @State private var isUpdating = false

    var body: some View {
        Section {
            if alerts.authorization == .denied {
                Label {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Notifications are off for Coincide Remote")
                        Text("Alerts stay on your Mac. Turn notifications on in Settings to get them here.")
                            .font(.caption).foregroundStyle(theme.secondaryInk)
                    }
                } icon: {
                    Image(systemName: "bell.slash.fill").foregroundStyle(.orange)
                }
                Button("Open Settings") {
                    if let url = URL(string: UIApplication.openNotificationSettingsURLString) { openURL(url) }
                }
            }
            Toggle(isOn: Binding(get: { alerts.isLockScreenEnabled }, set: { enabled in
                isUpdating = true
                Task {
                    await alerts.setLockScreenAlerts(enabled)
                    isUpdating = false
                }
            })) {
                Text("Notify this iPhone when it’s locked")
            }
            .disabled(isUpdating)
            if alerts.isLockScreenEnabled, let status = statusLine {
                Label {
                    Text(status.text).font(.caption).foregroundStyle(theme.secondaryInk)
                } icon: {
                    Image(systemName: status.symbol).foregroundStyle(status.color)
                }
            }
        } header: {
            Text("Notifications")
        } footer: {
            if let server = client.server, server.notifies == false {
                Text("\(server.name) has notifications turned off, so it sends none here either.")
            } else {
                Text("While you’re using this iPhone and not your Mac, alerts come here instead. When it’s locked, they come through your iCloud account, only if you turn that on.")
            }
        }
        .task { await alerts.refreshAuthorization() }
    }

    private var statusLine: (text: String, symbol: String, color: Color)? {
        switch alerts.lockScreenStatus {
        case .off: nil
        case .settingUp: (String(localized: "Setting up…"), "hourglass", theme.secondaryInk)
        case .on: (String(localized: "On. Alerts arrive through your iCloud account."), "checkmark.circle.fill", .green)
        case .notificationsDenied:
            (String(localized: "Allow notifications for Coincide Remote in Settings first."), "exclamationmark.triangle.fill", .orange)
        case .unavailable(let message): (message, "icloud.slash", .orange)
        }
    }
}

struct ThemeSwatchLabel: View {
    let palette: RemotePalette

    var body: some View {
        Label {
            Text(palette.name)
        } icon: {
            RoundedRectangle(cornerRadius: 4)
                .fill(Color(hex: palette.content))
                .overlay(alignment: .leading) {
                    Rectangle().fill(Color(hex: palette.sidebar)).frame(width: 8)
                }
                .overlay(alignment: .bottomTrailing) {
                    Circle().fill(Color(hex: palette.accent)).frame(width: 6, height: 6).padding(3)
                }
                .overlay(RoundedRectangle(cornerRadius: 4).strokeBorder(Color(hex: palette.border)))
                .frame(width: 26, height: 18)
                .accessibilityHidden(true)
        }
    }
}

struct UsageView: View {
    @Environment(RemoteClient.self) private var client
    @Environment(\.theme) private var theme
    @State private var usage: [RemoteUsage]?

    var body: some View {
        List {
            if let usage {
                if usage.isEmpty {
                    Text("No agent has reported its usage limits yet.").foregroundStyle(theme.secondaryInk)
                }
                ForEach(usage) { entry in
                    Section {
                        ForEach(entry.windows) { window in
                            VStack(alignment: .leading, spacing: 6) {
                                HStack {
                                    Text(window.label)
                                    Spacer()
                                    Text("\(Int(window.usedPercent.rounded()))%").monospacedDigit()
                                }
                                ProgressView(value: min(max(window.usedPercent, 0), 100), total: 100)
                                    .tint(window.usedPercent >= 90 ? .red : window.usedPercent >= 70 ? .orange : theme.accent)
                                if let reset = window.resetsAt {
                                    Text("Resets \(reset.formatted(.relative(presentation: .named)))")
                                        .font(.caption).foregroundStyle(theme.secondaryInk)
                                }
                            }
                            .accessibilityElement(children: .combine)
                        }
                    } header: {
                        HStack(spacing: 6) {
                            AgentLogo(provider: entry.provider, size: 14)
                            Text(entry.accountName.map { "\(entry.providerName) · \($0)" } ?? entry.providerName)
                        }
                    }
                    .themedCards(theme)
                }
            } else {
                ProgressView()
            }
        }
        .scrollContentBackground(.hidden)
        .background(theme.isDark ? theme.content : theme.sidebar)
        .navigationTitle("Usage Limits")
        .refreshable { await load() }
        .task { await load() }
    }

    private func load() async {
        if case .usage(let result)? = await client.perform(.usageLimits) { usage = result }
    }
}
