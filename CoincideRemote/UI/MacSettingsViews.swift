import CoincideRemoteKit
import SwiftUI

/// The Mac's Settings panes in Settings, under the Mac's name: General through Computer Use, then Providers and About.
struct MacSettingsSections: View {
    @Environment(RemoteClient.self) private var client
    @Environment(\.theme) private var theme

    var body: some View {
        if let snapshot = client.macSettings {
            Section {
                ForEach(snapshot.pages.filter { $0.group == .app && $0.id != "providers" }) { page in
                    NavigationLink { MacSettingsPageView(pageID: page.id) } label: { MacSettingsLabel(page: page) }
                }
            } header: {
                Text(client.server?.name ?? "Mac")
            }
            Section("Providers") {
                if let overview = snapshot.page("providers") {
                    NavigationLink { MacSettingsPageView(pageID: overview.id) } label: { MacSettingsLabel(page: overview) }
                }
                ForEach(snapshot.pages.filter { $0.group == .provider }) { page in
                    NavigationLink { MacSettingsPageView(pageID: page.id) } label: { MacSettingsLabel(page: page) }
                }
            }
            if let about = snapshot.page("about") {
                Section {
                    NavigationLink { MacSettingsPageView(pageID: about.id) } label: { MacSettingsLabel(page: about) }
                }
            }
        } else if client.macSettingsUnsupported {
            Section {
                Label("Update Coincide on your Mac to change its settings here.", systemImage: "arrow.down.circle")
                    .foregroundStyle(theme.secondaryInk)
            }
        } else if client.isConnected {
            Section {
                ProgressView().frame(maxWidth: .infinity)
            }
        }
    }
}

/// A pane's colored tile and title, as in the Mac's sidebar, with a provider's status dot.
struct MacSettingsLabel: View {
    let page: RemoteSettingsPage

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: page.symbol)
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: 28, height: 28)
                .background(RoundedRectangle(cornerRadius: 7, style: .continuous).fill(Self.color(page.color)))
                .accessibilityHidden(true)
            Text(page.title)
            Spacer()
            if let status = page.status {
                Circle()
                    .fill(Self.statusColor(status))
                    .frame(width: 8, height: 8)
                    .accessibilityLabel(Text(Self.statusLabel(status)))
            }
        }
    }

    static func color(_ name: String) -> Color {
        switch name {
        case "indigo": .indigo
        case "purple": .purple
        case "green": .green
        case "teal": .teal
        case "brown": .brown
        case "cyan": .cyan
        case "blue": .blue
        case "orange": .orange
        case "red": .red
        default: .gray
        }
    }

    static func statusColor(_ status: String) -> Color {
        switch status {
        case "ready", "ok": .green
        case "off": .gray
        case "error": .red
        default: .orange
        }
    }

    static func statusLabel(_ status: String) -> String {
        switch status {
        case "ready", "ok": String(localized: "Ready")
        case "off": String(localized: "Off")
        default: String(localized: "Needs attention")
        }
    }
}

/// One Mac Settings pane, drawn the iOS way. Changes go to the Mac at once and come back live.
struct MacSettingsPageView: View {
    let pageID: String
    @Environment(RemoteClient.self) private var client
    @Environment(\.theme) private var theme

    var body: some View {
        let page = client.macSettings?.page(pageID)
        Form {
            ForEach(page?.sections ?? []) { section in
                Section {
                    ForEach(section.rows) { row in MacSettingsRowView(row: row) }
                } header: {
                    if let title = section.title { Text(title) }
                } footer: {
                    if let footer = section.footer { Text(footer) }
                }
            }
        }
        .scrollContentBackground(.hidden)
        .background(theme.isDark ? theme.content : theme.sidebar)
        .navigationTitle(page?.title ?? "")
        .navigationBarTitleDisplayMode(.inline)
        .refreshable { await client.loadMacSettings() }
        .task { await client.loadMacSettings() }
    }
}

/// A setting row by kind. Kinds this version doesn't know are left out.
struct MacSettingsRowView: View {
    let row: RemoteSettingsRow
    @Environment(RemoteClient.self) private var client
    @Environment(\.theme) private var theme
    @State private var text = ""

    var body: some View {
        switch row.kind {
        case .toggle:
            Toggle(isOn: Binding(get: { row.value?.bool ?? false }, set: { change(.bool($0)) })) {
                titled
            }
            .disabled(isDisabled)
        case .choice:
            if (row.options ?? []).count > 6 {
                picker.pickerStyle(.navigationLink).disabled(isDisabled)
            } else {
                picker.pickerStyle(.menu).disabled(isDisabled)
            }
        case .number:
            let value = row.value?.number ?? 0
            Stepper(value: Binding(get: { value }, set: { change(.number($0)) }), in: (row.minimum ?? 0)...(row.maximum ?? 1_000),
                    step: row.step ?? 1) {
                LabeledContent(row.title) {
                    Text("\(value.formatted(.number.precision(.fractionLength(0...1)))) \(row.unit ?? "")")
                        .monospacedDigit()
                }
            }
            .disabled(isDisabled)
        case .text:
            LabeledContent(row.title) {
                TextField(row.title, text: $text)
                    .multilineTextAlignment(.trailing)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .onSubmit { change(.string(text)) }
            }
            .onAppear { text = row.value?.string ?? "" }
            .onChange(of: row.value) { text = row.value?.string ?? "" }
            .disabled(isDisabled)
        case .info:
            LabeledContent(row.title, value: row.detail ?? "")
        case .status:
            LabeledContent {
                Text(row.detail ?? "").foregroundStyle(theme.secondaryInk)
            } label: {
                Label {
                    Text(row.title)
                } icon: {
                    Image(systemName: row.state == "ok" ? "checkmark.circle.fill" : row.state == "off" ? "circle" : "exclamationmark.circle.fill")
                        .foregroundStyle(MacSettingsLabel.statusColor(row.state ?? "warning"))
                }
            }
        case .action:
            Button(role: row.isDestructive == true ? .destructive : nil) {
                Task { await client.performMacSettingsAction(row.id) }
            } label: {
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(row.title).foregroundStyle(theme.ink)
                        if let detail = row.detail { Text(detail).font(.caption).foregroundStyle(theme.secondaryInk) }
                    }
                    Spacer()
                    if row.finishesOnMac == true {
                        Label("Opens on your Mac", systemImage: "macbook").labelStyle(.iconOnly).foregroundStyle(theme.secondaryInk)
                    } else if let action = row.action {
                        Text(action).foregroundStyle(theme.secondaryInk)
                    }
                }
            }
            .disabled(isDisabled || !client.isConnected)
            .accessibilityHint(row.finishesOnMac == true ? Text("Opens this on your Mac") : Text(""))
        case .usage:
            NavigationLink { UsageView() } label: { Label(row.title, systemImage: "gauge.with.dots.needle.33percent") }
        case .page:
            if let target = row.target {
                NavigationLink { MacSettingsPageView(pageID: target) } label: {
                    HStack {
                        Text(row.title)
                        Spacer()
                        if let detail = row.detail { Text(detail).foregroundStyle(theme.secondaryInk) }
                        if let state = row.state {
                            Circle().fill(MacSettingsLabel.statusColor(state)).frame(width: 8, height: 8)
                        }
                    }
                }
            }
        case .link:
            if let url = row.url.flatMap(URL.init(string:)) { Link(row.title, destination: url) }
        case .unknown:
            EmptyView()
        }
    }

    private var picker: some View {
        Picker(selection: Binding(get: { row.value?.string ?? "" }, set: { change(.string($0)) })) {
            ForEach(row.options ?? []) { option in Text(option.title).tag(option.id) }
        } label: {
            titled
        }
    }

    @ViewBuilder private var titled: some View {
        if let detail = row.detail {
            VStack(alignment: .leading, spacing: 2) {
                Text(row.title)
                Text(detail).font(.caption).foregroundStyle(theme.secondaryInk)
            }
        } else {
            Text(row.title)
        }
    }

    private var isDisabled: Bool { row.isEnabled == false || !client.isConnected }

    private func change(_ value: RemoteSettingValue) {
        guard value != row.value else { return }
        Task { await client.changeMacSetting(row.id, to: value) }
    }
}
