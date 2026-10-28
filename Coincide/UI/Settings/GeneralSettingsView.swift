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
                    ThemedPicker(
                        selection: model.binding(\.replyTypeface),
                        options: ReplyTypeface.allCases.map { .init($0, $0.displayName) }
                    ) {
                        Text("Reply font")
                        Text("The typeface of agents’ replies in the conversation.")
                    }
                    .settingsRevealable(.replyTypeface, highlighted: highlighted)
                    // Only the themes the chosen appearance can show: both with System. A search still reaches either.
                    if model.settings.appearance != .light || highlighted == .darkTheme {
                        ThemeGridRow(
                            title: String(localized: "Dark theme"), themes: AppTheme.dark, selection: model.binding(\.darkTheme),
                            isRevealed: highlighted == .darkTheme, onPick: showMode(of:))
                            .settingsRevealable(.darkTheme, highlighted: highlighted)
                    }
                    if model.settings.appearance != .dark || highlighted == .lightTheme {
                        ThemeGridRow(
                            title: String(localized: "Light theme"), themes: AppTheme.light, selection: model.binding(\.lightTheme),
                            isRevealed: highlighted == .lightTheme, onPick: showMode(of:))
                            .settingsRevealable(.lightTheme, highlighted: highlighted)
                    }
                }

                Section("Chat") {
                    ThemedPicker(
                        selection: model.binding(\.sendOnReturn),
                        options: [.init(true, String(localized: "Return")), .init(false, String(localized: "Command-Return"))]
                    ) {
                        Text("Send messages with")
                        Text(
                            model.settings.sendOnReturn
                                ? String(localized: "Shift-Return inserts a new line.")
                                : String(localized: "Return inserts a new line."))
                    }
                    .settingsRevealable(.sendShortcut, highlighted: highlighted)
                    ThemedPicker(
                        selection: model.binding(\.followUpBehavior),
                        options: FollowUpBehavior.allCases.map { .init($0, $0.displayName) }
                    ) {
                        Text("Follow-up behavior")
                        Text(followUpCaption)
                    }
                    .settingsRevealable(.followUpBehavior, highlighted: highlighted)
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
                    ThemedPicker(
                        selection: model.binding(\.defaultAccessMode),
                        options: AccessMode.allCases.map { .init($0, $0.displayName) }
                    ) {
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
                    ThemedPicker(
                        selection: model.binding(\.idleSessionTimeoutMinutes),
                        options: idleTimeoutOptions.map { .init($0, SettingsFormat.minutes($0)) }
                    ) {
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

    /// What a message sent while an agent works does, and the key that does the other for one message, as T3 Code's
    /// description of its follow-up behavior.
    private var followUpCaption: String {
        let sendOnReturn = model.settings.sendOnReturn
        switch model.settings.followUpBehavior {
        case .steer:
            return sendOnReturn
                ? String(
                    localized: "Messages sent while an agent works go into its current turn, if it can take them. Command-Return queues one for after the turn instead.")
                : String(
                    localized: "Messages sent while an agent works go into its current turn, if it can take them. Shift-Command-Return queues one for after the turn instead.")
        case .queue:
            return sendOnReturn
                ? String(
                    localized: "Messages sent while an agent works wait until its turn ends. Command-Return sends one into the current turn instead.")
                : String(
                    localized: "Messages sent while an agent works wait until its turn ends. Shift-Command-Return sends one into the current turn instead.")
        }
    }

    private var idleTimeoutOptions: [Int] {
        Array(Set([5, 10, 15, 30, 60, 120, 240, model.settings.idleSessionTimeoutMinutes])).sorted()
    }

    /// Picking a theme of the mode the app isn't showing switches to that mode, so the choice shows right away.
    private func showMode(of theme: AppTheme) {
        guard theme.isDark != NSApp.effectiveAppearance.isDark else { return }
        model.update { $0.appearance = theme.isDark ? .dark : .light }
    }

    private func restoreDefaults() {
        let defaults = AppSettings()
        model.update { settings in
            settings.appearance = defaults.appearance
            settings.fontSize = defaults.fontSize
            settings.replyTypeface = defaults.replyTypeface
            settings.darkTheme = defaults.darkTheme
            settings.lightTheme = defaults.lightTheme
            settings.sendOnReturn = defaults.sendOnReturn
            settings.followUpBehavior = defaults.followUpBehavior
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
        // Each item carries its agent's logo, so models with the same name stay distinguishable.
        let unknown: [ThemedPicker<String, TupleView<(Text, Text)>>.Option] =
            current == nil
            ? [.init(selectionID, selection.modelID, image: Theme.logo(for: selection.provider, size: 14))] : []
        let options =
            unknown
            + groups.flatMap { kind in
                (model.models[kind] ?? []).map { option in
                    ThemedPicker<String, TupleView<(Text, Text)>>.Option(
                        option.id, option.displayName, image: Theme.logo(for: kind, size: 14), group: groupTitle(kind))
                }
            }
        ThemedPicker(selection: modelBinding, options: options) {
            Text("Model")
            Text(caption(for: selection.provider))
        }
        .settingsRevealable(.defaultModel, highlighted: highlighted)

        if let current, !current.efforts.isEmpty {
            ThemedPicker(
                selection: effortBinding,
                options: [
                    .init(
                        String?.none,
                        current.defaultEffort.map { String(localized: "Default (\(SettingsFormat.effort($0)))") }
                            ?? String(localized: "Default"))
                ] + current.efforts.map { .init(Optional($0), SettingsFormat.effort($0)) }
            ) {
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

// MARK: Themes

/// One appearance's theme: a row with the current theme's picture and name that opens a grid of all of them.
private struct ThemeGridRow: View {
    let title: String
    let themes: [AppTheme]
    @Binding var selection: String
    /// A settings search led here, so the grid opens.
    var isRevealed = false
    /// Runs after a theme is picked.
    var onPick: (AppTheme) -> Void = { _ in }
    @State private var isExpanded = false

    private var current: AppTheme { themes.first { $0.id == selection } ?? themes[0] }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Button {
                withAnimation(.easeOut(duration: 0.15)) { isExpanded.toggle() }
            } label: {
                HStack(spacing: 10) {
                    Text(title)
                    Spacer(minLength: 12)
                    Image(nsImage: current.swatch(size: NSSize(width: 34, height: 22)))
                    Text(verbatim: current.name)
                        .foregroundStyle(.secondary)
                    Image(systemName: "chevron.right")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(.tertiary)
                        .rotationEffect(.degrees(isExpanded ? 90 : 0))
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityValue(Text(verbatim: current.name))
            if isExpanded {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 92), spacing: 10)], alignment: .leading, spacing: 10) {
                    ForEach(themes) { theme in
                        ThemeTile(theme: theme, isSelected: theme.id == selection) {
                            selection = theme.id
                            onPick(theme)
                        }
                    }
                }
            }
        }
        .padding(.vertical, 4)
        .onAppear { if isRevealed { isExpanded = true } }
        .onChange(of: isRevealed) { if isRevealed { isExpanded = true } }
    }
}

private struct ThemeTile: View {
    let theme: AppTheme
    let isSelected: Bool
    let choose: () -> Void
    @State private var isHovered = false

    var body: some View {
        Button(action: choose) {
            VStack(spacing: 6) {
                Image(nsImage: theme.swatch(size: NSSize(width: 84, height: 52)))
                    .overlay {
                        RoundedRectangle(cornerRadius: 6, style: .continuous)
                            .strokeBorder(isSelected ? Color(nsColor: Theme.ink) : .clear, lineWidth: 2)
                            .padding(-3)
                    }
                Text(verbatim: theme.name)
                    .font(.system(size: 11, weight: isSelected ? .semibold : .regular))
                    .foregroundStyle(isSelected ? .primary : .secondary)
                    .lineLimit(1)
            }
            .padding(.vertical, 4)
            .frame(maxWidth: .infinity)
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(isHovered ? Color.primary.opacity(0.05) : .clear))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
        .accessibilityLabel(Text(verbatim: theme.name))
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}
