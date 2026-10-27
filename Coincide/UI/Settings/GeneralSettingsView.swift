import AppKit
import CoincideKit
import Combine
import SwiftUI
import UserNotifications

struct GeneralSettingsView: View {
    let model: SettingsModel
    @State private var highlighted: SettingsRowID?
    @State private var confirmingReset = false

    var body: some View {
        ScrollViewReader { proxy in
            Form {
                Section {
                    LabeledContent("Appearance") {
                        AppearancePicker(selection: model.binding(\.appearance))
                    }
                    .settingsRevealable(.appearance, highlighted: highlighted)
                    FontSizeRow(size: model.binding(\.fontSize))
                        .settingsRevealable(.fontSize, highlighted: highlighted)
                }

                Section("Chat") {
                    Picker(selection: model.binding(\.sendOnReturn)) {
                        Text("Return").tag(true)
                        Text("Command-Return").tag(false)
                    } label: {
                        Text("Send messages with")
                        Text(
                            model.settings.sendOnReturn
                                ? String(localized: "Shift-Return inserts a new line.")
                                : String(localized: "Return inserts a new line."))
                    }
                    .settingsRevealable(.sendShortcut, highlighted: highlighted)
                    Toggle(isOn: model.binding(\.showReasoning)) {
                        Text("Show reasoning")
                        Text("Include the agent’s thinking in the transcript when the model shares it.")
                    }
                    .settingsRevealable(.showReasoning, highlighted: highlighted)
                    Toggle(isOn: model.binding(\.confirmBeforeDeletingThreads)) {
                        Text("Confirm before deleting threads")
                        Text("Ask before a thread and its history are deleted.")
                    }
                    .settingsRevealable(.confirmDelete, highlighted: highlighted)
                }

                Section("New Threads") {
                    DefaultModelRows(model: model, highlighted: highlighted)
                    Picker(selection: model.binding(\.defaultAccessMode)) {
                        ForEach(AccessMode.allCases, id: \.self) { mode in
                            Text(mode.displayName).tag(mode)
                        }
                    } label: {
                        Text("Access")
                        Text(
                            model.settings.defaultAccessMode == .fullAccess
                                ? String(localized: "Agents run commands and edit files without asking.")
                                : String(localized: "Agents ask before running commands or editing files."))
                    }
                    .settingsRevealable(.accessMode, highlighted: highlighted)
                }

                Section("Notifications") {
                    NotificationsRow(model: model)
                        .settingsRevealable(.notifications, highlighted: highlighted)
                }

                Section("Git") {
                    Toggle(isOn: model.binding(\.checkpointsEnabled)) {
                        Text("Create checkpoints")
                        Text("Snapshot the working tree before each turn so you can review or revert what it changed.")
                    }
                    .settingsRevealable(.checkpoints, highlighted: highlighted)
                    BranchPrefixRow(model: model)
                        .settingsRevealable(.branchPrefix, highlighted: highlighted)
                }

                Section("Agents") {
                    Picker(selection: model.binding(\.idleSessionTimeoutMinutes)) {
                        ForEach(idleTimeoutOptions, id: \.self) { minutes in
                            Text(SettingsFormat.minutes(minutes)).tag(minutes)
                        }
                    } label: {
                        Text("Close idle agents after")
                        Text("Agent processes idle this long shut down to free memory. Threads pick up where they left off.")
                    }
                    .settingsRevealable(.idleTimeout, highlighted: highlighted)
                }

                Section {
                    HStack {
                        Spacer()
                        Button("Restore Defaults…") { confirmingReset = true }
                    }
                }
            }
            .formStyle(.grouped)
            .modifier(SettingsRevealHandler(request: model.reveal, proxy: proxy, highlighted: $highlighted))
        }
        .confirmationDialog("Restore general settings to their defaults?", isPresented: $confirmingReset) {
            Button("Restore Defaults", role: .destructive, action: restoreDefaults)
        } message: {
            Text("Providers, custom models and the default model for new threads are kept.")
        }
    }

    private var idleTimeoutOptions: [Int] {
        Array(Set([5, 10, 15, 30, 60, 120, 240, model.settings.idleSessionTimeoutMinutes])).sorted()
    }

    private func restoreDefaults() {
        let defaults = AppSettings()
        model.update { settings in
            settings.appearance = defaults.appearance
            settings.fontSize = defaults.fontSize
            settings.sendOnReturn = defaults.sendOnReturn
            settings.showReasoning = defaults.showReasoning
            settings.confirmBeforeDeletingThreads = defaults.confirmBeforeDeletingThreads
            settings.defaultAccessMode = defaults.defaultAccessMode
            settings.notifyWhenInBackground = defaults.notifyWhenInBackground
            settings.checkpointsEnabled = defaults.checkpointsEnabled
            settings.worktreeBranchPrefix = defaults.worktreeBranchPrefix
            settings.idleSessionTimeoutMinutes = defaults.idleSessionTimeoutMinutes
        }
    }
}

// MARK: Appearance

private struct AppearancePicker: View {
    @Binding var selection: AppearanceMode

    var body: some View {
        HStack(spacing: 14) {
            ForEach(AppearanceMode.allCases, id: \.self) { mode in
                let isSelected = selection == mode
                Button {
                    selection = mode
                } label: {
                    VStack(spacing: 5) {
                        AppearanceThumbnail(mode: mode)
                            .frame(width: 68, height: 46)
                            .overlay {
                                RoundedRectangle(cornerRadius: 7, style: .continuous)
                                    .strokeBorder(
                                        isSelected ? Color.accentColor : Color(nsColor: .separatorColor),
                                        lineWidth: isSelected ? 2.5 : 1)
                            }
                        Text(mode.displayName)
                            .font(.caption)
                            .foregroundStyle(isSelected ? .primary : .secondary)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(mode.displayName)
                .accessibilityAddTraits(isSelected ? .isSelected : [])
            }
        }
        .padding(.vertical, 2)
    }
}

/// A miniature window on a wallpaper, in light, dark, or split for "follow the system".
private struct AppearanceThumbnail: View {
    let mode: AppearanceMode

    var body: some View {
        switch mode {
        case .light: MiniWindow(dark: false)
        case .dark: MiniWindow(dark: true)
        case .system:
            ZStack {
                MiniWindow(dark: false)
                MiniWindow(dark: true).mask(DiagonalHalf())
            }
        }
    }
}

private struct MiniWindow: View {
    let dark: Bool

    var body: some View {
        let wallpaper: [Color] =
            dark
            ? [Color(red: 0.20, green: 0.22, blue: 0.48), Color(red: 0.07, green: 0.08, blue: 0.20)]
            : [Color(red: 0.55, green: 0.72, blue: 0.99), Color(red: 0.93, green: 0.78, blue: 0.94)]
        let window = dark ? Color(white: 0.17) : Color(white: 0.98)
        let sidebar = dark ? Color(white: 0.25) : Color(white: 0.89)
        let line = dark ? Color(white: 0.42) : Color(white: 0.80)
        ZStack(alignment: .topLeading) {
            LinearGradient(colors: wallpaper, startPoint: .topLeading, endPoint: .bottomTrailing)
            HStack(spacing: 0) {
                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 2) {
                        ForEach([Color.red, .yellow, .green], id: \.self) { Circle().fill($0).frame(width: 3, height: 3) }
                    }
                    .padding(.bottom, 2)
                    ForEach(0..<3, id: \.self) { _ in Capsule().fill(line).frame(width: 12, height: 2) }
                }
                .padding(4)
                .frame(maxHeight: .infinity, alignment: .top)
                .background(sidebar)
                VStack(alignment: .trailing, spacing: 4) {
                    Capsule().fill(Color.accentColor).frame(width: 20, height: 5)
                    VStack(alignment: .leading, spacing: 2) {
                        Capsule().fill(line).frame(width: 26, height: 2)
                        Capsule().fill(line).frame(width: 20, height: 2)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .padding(5)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                .background(window)
            }
            .clipShape(RoundedRectangle(cornerRadius: 3, style: .continuous))
            .padding(.top, 8)
            .padding(.leading, 9)
        }
        .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
    }
}

nonisolated private struct DiagonalHalf: Shape {
    func path(in rect: CGRect) -> Path {
        Path { path in
            path.move(to: CGPoint(x: rect.maxX, y: rect.minY))
            path.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY))
            path.addLine(to: CGPoint(x: rect.minX, y: rect.maxY))
            path.closeSubpath()
        }
    }
}

private struct FontSizeRow: View {
    @Binding var size: Double

    var body: some View {
        LabeledContent {
            HStack(spacing: 8) {
                Text(verbatim: "A").font(.system(size: 10))
                Slider(value: $size, in: 11...20, step: 1)
                    .frame(width: 170)
                    .accessibilityLabel(Text("Font size"))
                    .accessibilityValue(Text("\(Int(size)) points"))
                Text(verbatim: "A").font(.system(size: 16))
                Text("\(Int(size)) pt")
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
                    .frame(minWidth: 38, alignment: .trailing)
            }
        } label: {
            Text("Font size")
            Text("Used for the transcript and the composer.")
        }
    }
}

// MARK: New threads

private struct DefaultModelRows: View {
    let model: SettingsModel
    let highlighted: SettingsRowID?

    var body: some View {
        let selection = model.settings.defaultSelection
        let current = model.defaultModel
        let groups = model.kinds.filter { model.isEnabled($0) && !(model.models[$0] ?? []).isEmpty }
        // Each item carries its provider's symbol, so models with the same name stay distinguishable.
        Picker(selection: modelBinding) {
            if current == nil {
                Label(selection.modelID, systemImage: selection.provider.symbolName).tag(selectionID)
            }
            ForEach(groups, id: \.self) { kind in
                Section {
                    ForEach(model.models[kind] ?? []) { option in
                        Label(option.displayName, systemImage: kind.symbolName).tag(option.id)
                    }
                } header: {
                    Text(groupTitle(kind))
                }
            }
        } label: {
            Text("Model")
            Text(caption(for: selection.provider))
        }
        .settingsRevealable(.defaultModel, highlighted: highlighted)

        if let current, !current.efforts.isEmpty {
            Picker(selection: effortBinding) {
                Text(
                    current.defaultEffort.map { String(localized: "Default (\(SettingsFormat.effort($0)))") }
                        ?? String(localized: "Default")
                )
                .tag(String?.none)
                ForEach(current.efforts, id: \.self) { effort in
                    Text(SettingsFormat.effort(effort)).tag(Optional(effort))
                }
            } label: {
                Text("Reasoning effort")
                Text("How long the model thinks before it answers.")
            }
        }
    }

    private var selectionID: String {
        let selection = model.settings.defaultSelection
        return "\(selection.provider.rawValue)/\(selection.modelID)"
    }

    private var modelBinding: Binding<String> {
        Binding(
            get: { selectionID },
            set: { id in
                guard let option = model.models.values.joined().first(where: { $0.id == id }) else { return }
                model.setDefaultModel(option)
            })
    }

    private var effortBinding: Binding<String?> {
        Binding(
            get: { model.settings.defaultSelection.effort },
            set: { effort in model.update { $0.defaultSelection.effort = effort } })
    }

    private func groupTitle(_ kind: ProviderKind) -> String {
        let status = model.status(kind)
        guard status.state != .ready else { return kind.displayName }
        return String(localized: "\(kind.displayName) – \(SettingsProviderStatus(model: model, kind: kind).headline)")
    }

    private func caption(for provider: ProviderKind) -> String {
        guard model.isEnabled(provider) else {
            return String(localized: "\(provider.displayName) is turned off. Turn it on in Providers or pick another model.")
        }
        switch model.status(provider).state {
        case .ready, .unknown:
            return String(localized: "New threads start with this model. You can switch models and agents in any thread.")
        default:
            return String(localized: "\(provider.displayName) isn’t ready yet. Set it up in Providers or pick another model.")
        }
    }
}

// MARK: Notifications

private struct NotificationsRow: View {
    let model: SettingsModel
    @State private var authorization: UNAuthorizationStatus?

    var body: some View {
        Group {
            Toggle(isOn: notifyBinding) {
                Text("Notify when Coincide is in the background")
                Text("Post a notification when a turn finishes, fails or needs your approval.")
            }
            if model.settings.notifyWhenInBackground && authorization == .denied {
                HStack(alignment: .firstTextBaseline) {
                    Label {
                        Text("Notifications are turned off for Coincide in System Settings.")
                            .foregroundStyle(.secondary)
                    } icon: {
                        Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                    }
                    Spacer()
                    Button("Open System Settings…", action: openNotificationSettings)
                }
            }
        }
        .task { await refresh() }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            Task { await refresh() }
        }
    }

    private var notifyBinding: Binding<Bool> {
        Binding(
            get: { model.settings.notifyWhenInBackground },
            set: { isOn in
                model.update { $0.notifyWhenInBackground = isOn }
                if isOn { Task { await requestAuthorizationIfNeeded() } }
            })
    }

    private func refresh() async {
        authorization = await UNUserNotificationCenter.current().notificationSettings().authorizationStatus
    }

    private func requestAuthorizationIfNeeded() async {
        await refresh()
        guard authorization == .notDetermined else { return }
        _ = try? await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound, .badge])
        await refresh()
    }

    private func openNotificationSettings() {
        let bundleID = Bundle.main.bundleIdentifier ?? ""
        if let url = URL(string: "x-apple.systempreferences:com.apple.Notifications-Settings.extension?id=\(bundleID)") {
            NSWorkspace.shared.open(url)
        }
    }
}

// MARK: Git

private struct BranchPrefixRow: View {
    let model: SettingsModel
    @State private var draft = ""
    @FocusState private var isFocused: Bool

    var body: some View {
        let problem = Self.problem(with: draft)
        LabeledContent {
            TextField("Branch prefix", text: $draft, prompt: Text("No prefix"))
                .labelsHidden()
                .textFieldStyle(.roundedBorder)
                .font(.body.monospaced())
                .frame(width: 170)
                .focused($isFocused)
                .onSubmit(commit)
        } label: {
            Text("Worktree branch prefix")
            if let problem {
                Text(problem).foregroundStyle(.red)
            } else {
                Text("New worktree branches are named like \(draft.trimmingCharacters(in: .whitespaces) + "fix-login").")
            }
        }
        .onAppear { draft = model.settings.worktreeBranchPrefix }
        .onChange(of: isFocused) { _, focused in if !focused { commit() } }
        .onChange(of: model.settings.worktreeBranchPrefix) { _, value in if !isFocused { draft = value } }
    }

    private func commit() {
        let value = draft.trimmingCharacters(in: .whitespaces)
        guard Self.problem(with: value) == nil else { return }
        draft = value
        if value != model.settings.worktreeBranchPrefix { model.update { $0.worktreeBranchPrefix = value } }
    }

    /// Why a prefix would make invalid git branch names, following `git check-ref-format`.
    static func problem(with prefix: String) -> String? {
        let value = prefix.trimmingCharacters(in: .whitespaces)
        if value.isEmpty { return nil }
        if value.contains(where: { $0.isWhitespace || $0.asciiValue.map { $0 < 0x20 || $0 == 0x7F } == true }) {
            return String(localized: "Branch names can’t contain spaces.")
        }
        if let character = value.first(where: { "~^:?*[\\".contains($0) }) {
            return String(localized: "Branch names can’t contain “\(String(character))”.")
        }
        if value.contains("..") || value.contains("@{") || value.contains("//") {
            return String(localized: "Branch names can’t contain “..”, “@{” or “//”.")
        }
        if value.hasPrefix("/") || value.hasPrefix("-") || value.hasPrefix(".") {
            return String(localized: "Branch names can’t start with “/”, “-” or “.”.")
        }
        if value.split(separator: "/").contains(where: { $0.hasPrefix(".") || $0.hasSuffix(".lock") }) {
            return String(localized: "Parts of a branch name can’t start with “.” or end with “.lock”.")
        }
        return nil
    }
}
