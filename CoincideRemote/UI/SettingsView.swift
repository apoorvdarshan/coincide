import CoincideRemoteKit
import SwiftUI

/// A screen of Settings: this phone's own (its Macs, appearance, notifications, keyboard), one of the Mac's panes
/// (General through Computer Use, Providers), or About.
enum SettingsPane: Hashable {
    case macs, appearance, notifications, keyboard, about
    /// The Mac's scheduled tasks, which its Scheduled Tasks window lists.
    case scheduledTasks
    /// A pane of the Mac's Settings, by its page id.
    case mac(String)

    /// A pane by name, for launch arguments: `macs`, `appearance`, `notifications`, `keyboard`, `about`, or a Mac page id.
    static func named(_ name: String) -> SettingsPane {
        switch name {
        case "macs": .macs
        case "appearance": .appearance
        case "notifications": .notifications
        case "keyboard": .keyboard
        case "about": .about
        case "scheduledTasks": .scheduledTasks
        default: .mac(name)
        }
    }
}

/// Settings as the Mac's Settings window lays it out: a sidebar of panes with colored tiles, and the pane beside it in a
/// wide window (an iPad), or pushed over it in a narrow one (an iPhone, a folded Duo, Slide Over). Both read the same
/// selection, so a window changing width keeps the pane.
struct SettingsView: View {
    let isSplit: Bool
    @Environment(RemoteClient.self) private var client
    @Environment(Navigator.self) private var navigator

    var body: some View {
        @Bindable var navigator = navigator
        Group {
            if isSplit {
                NavigationSplitView {
                    SettingsSidebar(isSplit: true)
                        .navigationSplitViewColumnWidth(
                            min: RemoteLayout.listColumn.minimum, ideal: RemoteLayout.listColumn.ideal,
                            max: RemoteLayout.listColumn.maximum)
                } detail: {
                    NavigationStack {
                        SettingsPaneView(pane: navigator.settingsPane ?? .macs)
                    }
                    .id(navigator.settingsPane ?? .macs)
                }
                .navigationSplitViewStyle(.balanced)
            } else {
                NavigationStack {
                    SettingsSidebar(isSplit: false)
                        .navigationDestination(item: $navigator.settingsPane) { pane in SettingsPaneView(pane: pane) }
                }
            }
        }
        .task(id: client.isConnected) { await client.loadMacSettings() }
    }
}

/// The list of panes in the Mac Settings sidebar's look: flat rows on the theme's sidebar color, each with its colored
/// tile, under this phone's heading and then the Mac's.
struct SettingsSidebar: View {
    let isSplit: Bool
    @Environment(RemoteClient.self) private var client
    @Environment(Navigator.self) private var navigator
    @Environment(\.theme) private var theme

    var body: some View {
        List {
            SettingsMacCard(isSelected: isSelected(.macs)) { navigator.settingsPane = .macs }
                .sidebarRow()
            SidebarHeader(Text("Coincide Remote")).sidebarRow()
            row(.appearance, title: String(localized: "Appearance"), symbol: "paintpalette.fill", color: "indigo")
            row(.notifications, title: String(localized: "Notifications"), symbol: "bell.badge.fill", color: "red")
            row(.keyboard, title: String(localized: "Hardware Keyboard"), symbol: "keyboard.fill", color: "gray")
            if let snapshot = client.macSettings {
                SidebarHeader(Text(client.server?.name ?? String(localized: "Mac"))).sidebarRow()
                ForEach(snapshot.pages.filter { $0.group == .app && $0.id != "providers" }) { page in
                    row(.mac(page.id), title: page.title, symbol: page.symbol, color: page.color)
                }
                // The Mac's Scheduled Tasks window, with its panes.
                row(.scheduledTasks, title: String(localized: "Scheduled Tasks"), symbol: "calendar.badge.clock", color: "orange")
                SidebarHeader(Text("Providers")).sidebarRow()
                if let overview = snapshot.page("providers") {
                    row(.mac(overview.id), title: overview.title, symbol: overview.symbol, color: overview.color)
                }
                ForEach(snapshot.pages.filter { $0.group == .provider }) { page in
                    row(
                        .mac(page.id), title: page.title, logo: page.id.hasPrefix("provider.") ? String(page.id.dropFirst(9)) : nil,
                        symbol: page.symbol, color: page.color, status: page.status)
                }
            } else if client.macSettingsUnsupported {
                SidebarNote(text: String(localized: "Update Coincide on your Mac to change its settings here."), symbol: "arrow.down.circle")
                    .frame(minHeight: 44)
                    .sidebarRow()
            } else if client.isConnected {
                ProgressView().frame(maxWidth: .infinity, minHeight: 44).sidebarRow()
            }
            HelpCommunityRows()
            Spacer(minLength: 12).sidebarRow().accessibilityHidden(true)
            row(.about, title: String(localized: "About"), symbol: "info.circle.fill", color: "gray")
        }
        .sidebarList(theme)
        .navigationTitle("Settings")
        .navigationBarTitleDisplayMode(isSplit ? .inline : .large)
        .refreshable { await client.loadMacSettings() }
        #if DEBUG
        .onAppear {
            // Screenshots of a pane without taps: `-CoincideRemoteSettingsPane general` (or macs, appearance, …).
            if let name = DemoData.value(after: "-CoincideRemoteSettingsPane"), navigator.settingsPane == nil {
                navigator.settingsPane = SettingsPane.named(name)
            }
        }
        #endif
    }

    /// Side by side, the pane on screen (Macs until another is picked) is highlighted, as in the Mac's sidebar.
    private func isSelected(_ pane: SettingsPane) -> Bool { isSplit && (navigator.settingsPane ?? .macs) == pane }

    private func row(
        _ pane: SettingsPane, title: String, logo: String? = nil, symbol: String, color: String, status: String? = nil
    ) -> some View {
        Button { navigator.settingsPane = pane } label: {
            SettingsTileLabel(title: title, logo: logo, symbol: symbol, color: color, status: status)
        }
        .buttonStyle(SidebarRowButtonStyle(isSelected: isSelected(pane)))
        .accessibilityAddTraits(isSelected(pane) ? .isSelected : [])
        .sidebarRow()
    }
}

/// A pane's colored tile and title, as in the Mac Settings sidebar: an agent's own mark for a provider's pane, and the
/// provider's status dot. A row that opens a web page instead of a pane ends with an arrow, after the account or address
/// it opens when that is worth showing.
struct SettingsTileLabel: View {
    let title: String
    var logo: String?
    let symbol: String
    let color: String
    var status: String?
    var detail: String?
    var opensLink = false
    @Environment(\.theme) private var theme
    @ScaledMetric(relativeTo: .callout) private var tile: CGFloat = 26

    var body: some View {
        HStack(spacing: 10) {
            Group {
                if let logo {
                    AgentLogo(provider: logo, size: tile * 0.62)
                        .frame(width: tile, height: tile)
                        .background(RoundedRectangle(cornerRadius: tile * 0.26, style: .continuous).fill(theme.selection))
                } else {
                    Image(systemName: symbol)
                        .font(.system(size: tile * 0.5, weight: .semibold))
                        .foregroundStyle(.white)
                        .frame(width: tile, height: tile)
                        .background(
                            RoundedRectangle(cornerRadius: tile * 0.26, style: .continuous).fill(MacSettingsLabel.color(color).gradient))
                }
            }
            .accessibilityHidden(true)
            Text(title)
                .font(.callout)
                .foregroundStyle(theme.ink)
                .lineLimit(1)
            if AntigravityRisk.applies(toProvider: logo) { AntigravityRiskGlyph() }
            Spacer(minLength: 4)
            if let status {
                StatusDot(color: MacSettingsLabel.statusColor(status))
                    .accessibilityLabel(Text(MacSettingsLabel.statusLabel(status)))
            }
            if let detail {
                Text(verbatim: detail)
                    .font(.footnote)
                    .foregroundStyle(theme.secondaryInk)
                    .lineLimit(1)
            }
            if opensLink {
                Image(systemName: "arrow.up.right")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(theme.tertiaryInk)
                    .accessibilityHidden(true)
            }
        }
        .padding(.vertical, 2)
        .accessibilityElement(children: .combine)
    }
}

/// The Mac this phone drives, at the top of Settings like the account at the top of iOS Settings: its name and whether
/// it's connected. Opens the paired Macs.
struct SettingsMacCard: View {
    let isSelected: Bool
    let open: () -> Void
    @Environment(RemoteClient.self) private var client
    @Environment(\.theme) private var theme
    @ScaledMetric(relativeTo: .headline) private var tile: CGFloat = 40

    var body: some View {
        Button(action: open) {
            HStack(spacing: 12) {
                Image(systemName: "laptopcomputer")
                    .font(.system(size: tile * 0.44, weight: .medium))
                    .foregroundStyle(theme.ink)
                    .frame(width: tile, height: tile)
                    .background(Circle().fill(theme.selection))
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 2) {
                    Text(client.server?.name ?? client.mac?.name ?? String(localized: "No Mac"))
                        .font(.headline)
                        .foregroundStyle(theme.ink)
                        .lineLimit(1)
                    HStack(spacing: 6) {
                        StatusDot(color: statusColor)
                        Text(status).lineLimit(1)
                    }
                    .font(.footnote)
                    .foregroundStyle(theme.secondaryInk)
                }
                Spacer(minLength: 4)
            }
            .padding(.vertical, 8)
        }
        .buttonStyle(SidebarRowButtonStyle(isSelected: isSelected))
        .accessibilityElement(children: .combine)
        .accessibilityHint(Text("Shows the paired Macs"))
    }

    private var status: String {
        switch client.shownPhase {
        case .connected: String(localized: "Connected")
        // Nil: reconnecting quietly with nothing to go on showing, as at launch.
        case .connecting, nil: String(localized: "Connecting…")
        case .offline: String(localized: "Offline")
        case .needsPairing: String(localized: "Pair Again")
        case .idle: String(localized: "Not connected")
        }
    }

    private var statusColor: Color {
        switch client.shownPhase {
        case .connected: .green
        case .offline, .needsPairing: .orange
        case .connecting, .idle, nil: theme.tertiaryInk
        }
    }
}

/// One pane, drawn as a grouped form on the theme's colors.
struct SettingsPaneView: View {
    let pane: SettingsPane

    var body: some View {
        switch pane {
        case .macs: MacsSettingsPane()
        case .appearance: AppearanceSettingsPane()
        case .notifications: SettingsForm(title: String(localized: "Notifications")) { NotificationsSection() }
        case .keyboard: KeyboardSettingsPane()
        case .about: AboutSettingsPane()
        case .scheduledTasks: ScheduledTasksView()
        case .mac(let id):
            #if DEBUG
            // Screenshots of the instruction editor: `-CoincideRemoteSettingsPane document`.
            if id == "document", DemoData.isEnabled {
                SettingsDocumentEditor(key: "instructions.file./Users/apoorv/.config/coincide/AGENTS.md", title: "~/.config/coincide/AGENTS.md")
            } else {
                MacPaneView(pageID: id)
            }
            #else
            MacPaneView(pageID: id)
            #endif
        }
    }
}

/// A pane's grouped form: cards in the theme's surface color on its background, with an inline title.
struct SettingsForm<Content: View>: View {
    let title: String
    @ViewBuilder var content: Content
    @Environment(\.theme) private var theme

    var body: some View {
        Form {
            Group { content }
                .themedCards(theme)
        }
        .scrollContentBackground(.hidden)
        .background(theme.isDark ? theme.content : theme.sidebar)
        .navigationTitle(title)
        .navigationBarTitleDisplayMode(.inline)
    }
}

/// The Macs this phone is paired with: connect, add an address, forget, or pair another.
struct MacsSettingsPane: View {
    @Environment(RemoteClient.self) private var client
    @Environment(Navigator.self) private var navigator
    @Environment(\.theme) private var theme
    @State private var addingHostTo: SavedMac?
    @State private var newHost = ""
    @State private var forgetting: SavedMac?

    var body: some View {
        SettingsForm(title: String(localized: "Macs")) {
            Section {
                ForEach(client.savedMacs) { mac in
                    Button { client.connect(to: mac) } label: {
                        HStack(spacing: 12) {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(mac.name).foregroundStyle(theme.ink)
                                Text(status(mac)).font(.caption).foregroundStyle(theme.secondaryInk)
                                Text(mac.hosts.map(\.host).joined(separator: ", "))
                                    .font(.caption2.monospaced()).foregroundStyle(theme.secondaryInk).lineLimit(2)
                            }
                            Spacer()
                            if client.mac?.serverID == mac.serverID, client.showsConnected {
                                Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                                    .accessibilityLabel(Text("Connected"))
                            }
                        }
                    }
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
        }
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
    }

    private func status(_ mac: SavedMac) -> String {
        if client.mac?.serverID == mac.serverID {
            switch client.shownPhase {
            case .connected: return String(localized: "Connected")
            case .connecting, nil: return String(localized: "Connecting…")
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

/// The theme: the Mac's (by default) or one picked here.
struct AppearanceSettingsPane: View {
    @Environment(RemoteClient.self) private var client
    @Environment(AppearanceSettings.self) private var appearance

    var body: some View {
        @Bindable var appearance = appearance
        SettingsForm(title: String(localized: "Appearance")) {
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
                    .pickerStyle(.navigationLink)
                    Picker("Light Theme", selection: $appearance.lightThemeID) {
                        ForEach(RemotePalette.light) { palette in
                            ThemeSwatchLabel(palette: palette).tag(palette.id)
                        }
                    }
                    .pickerStyle(.navigationLink)
                }
            } footer: {
                if appearance.followsMac, let server = client.server {
                    Text("Following \(server.name): \(RemotePalette.dark(server.theme.darkThemeID).name) and \(RemotePalette.light(server.theme.lightThemeID).name).")
                }
            }
        }
    }
}

/// A hardware keyboard: whether Return sends, and the shortcuts Coincide Remote answers to.
struct KeyboardSettingsPane: View {
    @AppStorage("composer.returnSends") private var returnSends = true
    @Environment(\.theme) private var theme

    var body: some View {
        SettingsForm(title: String(localized: "Hardware Keyboard")) {
            Section {
                Toggle("Send with Return", isOn: $returnSends)
            } footer: {
                Text("Shift-Return starts a new line.")
            }
            Section("Shortcuts") {
                shortcut("New Thread", "⌘N")
                shortcut("Search Threads", "⌘F")
                shortcut("Send", returnSends ? "↩" : "⌘↩")
                shortcut("Stop", "⌘.")
                shortcut("Reconnect", "⌘R")
            }
        }
    }

    private func shortcut(_ title: LocalizedStringKey, _ keys: String) -> some View {
        LabeledContent {
            Text(keys).monospaced().foregroundStyle(theme.secondaryInk)
        } label: {
            Text(title)
        }
    }
}

/// Versions of both apps and the protocol between them.
struct AboutSettingsPane: View {
    @Environment(RemoteClient.self) private var client

    var body: some View {
        SettingsForm(title: String(localized: "About")) {
            Section {
                LabeledContent("Coincide Remote", value: RemoteClient.appVersion)
                if let server = client.server {
                    LabeledContent("Coincide on \(server.name)", value: server.appVersion)
                }
                if let rows = client.macSettings?.page("about")?.sections.flatMap(\.rows) {
                    ForEach(rows.filter { $0.id != "about.version" }) { row in LabeledContent(row.title, value: row.detail ?? "") }
                }
                LabeledContent("Protocol", value: "\(RemoteProtocol.version)")
            }
        }
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
                UIDevice.current.userInterfaceIdiom == .pad
                    ? Text("Notify this iPad when it’s locked") : Text("Notify this iPhone when it’s locked")
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
                VStack(alignment: .leading, spacing: 6) {
                    UIDevice.current.userInterfaceIdiom == .pad
                        ? Text("While you’re using this iPad and not your Mac, alerts come here instead. When it’s locked, they come through your iCloud account, only if you turn that on.")
                        : Text("While you’re using this iPhone and not your Mac, alerts come here instead. When it’s locked, they come through your iCloud account, only if you turn that on.")
                    UIDevice.current.userInterfaceIdiom == .pad
                        ? Text("When you’re at your Mac, Coincide notifies there instead of your iPad, so nothing shows twice.")
                        : Text("When you’re at your Mac, Coincide notifies there instead of your iPhone, so nothing shows twice.")
                }
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

/// Search in Settings, as the Mac's Settings search: the panes whose names match, then each matching setting with the
/// pane and section it's in. Tapping one opens its pane in Settings.
struct SettingsSearchResults: View {
    let query: String
    @Environment(RemoteClient.self) private var client
    @Environment(Navigator.self) private var navigator
    @Environment(\.theme) private var theme

    private struct Pane: Identifiable {
        var pane: SettingsPane
        var title: String
        var symbol: String
        var color: String
        var id: String { "\(pane)" }
    }

    private struct Hit: Identifiable {
        var pane: SettingsPane
        var title: String
        var place: String
        var id: String
    }

    var body: some View {
        let search = SearchMatch(query)
        let panes = allPanes.filter { search.isEmpty || search.matches($0.title) }
        let hits = search.isEmpty ? [] : settingHits(search)
        let links = search.isEmpty ? [] : CommunityLink.allCases.filter { search.matches(([$0.title] + $0.keywords).joined(separator: " ")) }
        List {
            if !panes.isEmpty {
                SidebarHeader(Text("Panes")).sidebarRow()
                ForEach(panes) { pane in
                    Button { open(pane.pane) } label: {
                        SettingsTileLabel(title: pane.title, symbol: pane.symbol, color: pane.color)
                    }
                    .buttonStyle(SidebarRowButtonStyle())
                    .sidebarRow()
                }
            }
            if !hits.isEmpty {
                SidebarHeader(Text("Settings")).sidebarRow()
                ForEach(hits) { hit in
                    Button { open(hit.pane) } label: {
                        VStack(alignment: .leading, spacing: 1) {
                            Text(hit.title).font(.callout).foregroundStyle(theme.ink).lineLimit(2)
                            Text(hit.place).font(.caption).foregroundStyle(theme.secondaryInk).lineLimit(1)
                        }
                        .padding(.vertical, 4)
                        .accessibilityElement(children: .combine)
                    }
                    .buttonStyle(SidebarRowButtonStyle())
                    .sidebarRow()
                }
            }
            if !links.isEmpty {
                SidebarHeader(Text("Help & Community")).sidebarRow()
                ForEach(links) { CommunityLinkRow(link: $0) }
            }
        }
        .sidebarList(theme)
        .overlay {
            if !search.isEmpty, panes.isEmpty, hits.isEmpty, links.isEmpty { ContentUnavailableView.search(text: query) }
        }
        .navigationTitle("Settings")
    }

    private var allPanes: [Pane] {
        var panes = [
            Pane(pane: .macs, title: String(localized: "Macs"), symbol: "laptopcomputer", color: "gray"),
            Pane(pane: .appearance, title: String(localized: "Appearance"), symbol: "paintpalette.fill", color: "indigo"),
            Pane(pane: .notifications, title: String(localized: "Notifications"), symbol: "bell.badge.fill", color: "red"),
            Pane(pane: .keyboard, title: String(localized: "Hardware Keyboard"), symbol: "keyboard.fill", color: "gray"),
        ]
        for page in client.macSettings?.pages ?? [] where page.group != .detail && page.group != .unknown {
            panes.append(Pane(pane: .mac(page.id), title: page.title, symbol: page.symbol, color: page.color))
        }
        panes.append(Pane(pane: .about, title: String(localized: "About"), symbol: "info.circle.fill", color: "gray"))
        return panes
    }

    /// Settings whose title or description matches, in every pane the Mac described (an agent's models included).
    private func settingHits(_ search: SearchMatch) -> [Hit] {
        var hits: [Hit] = []
        for page in client.macSettings?.pages ?? [] {
            for section in page.sections {
                for row in section.rows where row.kind != .unknown && search.matches(row.title, row.detail ?? "") {
                    let place = [page.title, section.title].compactMap(\.self).joined(separator: " › ")
                    hits.append(Hit(pane: .mac(page.id), title: row.title, place: place, id: row.id))
                }
            }
        }
        return Array(hits.prefix(60))
    }

    private func open(_ pane: SettingsPane) {
        navigator.settingsPane = pane
        navigator.searchText = ""
        navigator.tab = .settings
    }
}

/// One of the Mac's panes: Usage draws its dashboard with the pane's options under it; the rest are forms of rows.
struct MacPaneView: View {
    let pageID: String
    @Environment(RemoteClient.self) private var client

    var body: some View {
        if pageID == "usage" {
            UsageDashboardView(page: client.macSettings?.page("usage"))
        } else {
            MacSettingsPageView(pageID: pageID)
        }
    }
}
