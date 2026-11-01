import CoincideRemoteKit
import SwiftUI

/// The Mac Settings sidebar's tile colors and provider status dots, by the names the Mac sends.
enum MacSettingsLabel {
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
        case "pink": .pink
        case "yellow": .yellow
        case "black": .black
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
            if AntigravityRisk.applies(toPage: pageID) {
                Section { AntigravityRiskNotice() }.themedCards(theme)
            }
            ForEach(page?.sections ?? []) { section in
                Section {
                    ForEach(section.rows) { row in MacSettingsRowView(row: row) }
                } header: {
                    if let title = section.title { Text(title) }
                } footer: {
                    if let footer = section.footer { Text(footer) }
                }
                .themedCards(theme)
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
    @State private var confirming = false

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
                // Clearing data or removing something asks first, as the Mac does.
                if row.isDestructive == true { confirming = true } else { Task { await client.performMacSettingsAction(row.id) } }
            } label: {
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(row.title).foregroundStyle(row.isDestructive == true && row.action == nil ? Color.red : theme.ink)
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
            .confirmationDialog(Text(row.title), isPresented: $confirming, titleVisibility: .visible) {
                Button(row.action ?? row.title, role: .destructive) { Task { await client.performMacSettingsAction(row.id) } }
                Button("Cancel", role: .cancel) {}
            } message: {
                if let detail = row.detail { Text(detail) } else { Text("This can’t be undone.") }
            }
        case .document:
            NavigationLink { SettingsDocumentEditor(key: row.id, title: row.title) } label: {
                VStack(alignment: .leading, spacing: 2) {
                    Text(row.title).font(.callout.monospaced()).foregroundStyle(theme.ink).lineLimit(1).truncationMode(.head)
                    if let detail = row.detail, !detail.isEmpty {
                        Text(detail).font(.caption).foregroundStyle(theme.secondaryInk).lineLimit(2)
                    }
                }
                .padding(.vertical, 2)
            }
            .disabled(!client.isConnected)
        case .usage:
            NavigationLink { UsageDashboardView() } label: { Label(row.title, systemImage: "gauge.with.dots.needle.33percent") }
        case .page:
            if let target = row.target {
                NavigationLink { MacSettingsPageView(pageID: target) } label: {
                    HStack {
                        Text(row.title)
                        if AntigravityRisk.applies(toPage: target) { AntigravityRiskGlyph() }
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
