import AppKit
import CoincideKit
import SwiftUI

// MARK: Overview

struct ProvidersSettingsView: View {
    let model: SettingsModel

    var body: some View {
        Form {
            Section {
                SettingsPaneHeader(title: String(localized: "Providers")) {
                    SettingsIconTile(symbol: SettingsSection.providers.symbolName, color: SettingsSection.providers.tint, size: 44)
                } subtitle: {
                    Text("Coincide runs each agent’s own command-line tool with the account you already signed in to. It never sells or proxies tokens.")
                }
            }
            Section {
                ForEach(model.kinds, id: \.self) { kind in
                    ProviderSummaryRow(model: model, kind: kind)
                }
            } footer: {
                HStack {
                    LastCheckedLabel(model: model)
                    Spacer()
                    Button {
                        model.checkAll()
                    } label: {
                        Label("Check All Again", systemImage: "arrow.clockwise")
                    }
                    .disabled(model.isCheckingAll)
                }
                .padding(.top, 4)
            }
        }
        .formStyle(.grouped)
    }
}

private struct ProviderSummaryRow: View {
    let model: SettingsModel
    let kind: ProviderKind

    var body: some View {
        let presentation = SettingsProviderStatus(model: model, kind: kind)
        let status = model.status(kind)
        let details = [presentation.headline, SettingsFormat.version(status.version), status.account].compactMap { $0 }
        HStack(spacing: 12) {
            SettingsProviderIcon(kind: kind, size: 30)
                .opacity(model.isEnabled(kind) ? 1 : 0.55)
            VStack(alignment: .leading, spacing: 2) {
                Text(kind.displayName)
                    .fontWeight(.medium)
                HStack(spacing: 5) {
                    SettingsStatusDot(color: presentation.color, size: 7)
                    Text(details.joined(separator: " · "))
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }
            Spacer(minLength: 8)
            if model.isChecking(kind) && model.isEnabled(kind) {
                ProgressView().controlSize(.small)
            }
            Toggle(isOn: enabledBinding(model, kind)) {
                Text("Use \(kind.displayName)")
            }
            .labelsHidden()
            .toggleStyle(.switch)
            .controlSize(.small)
            Button {
                model.navigate(to: .provider(kind))
            } label: {
                Image(systemName: "chevron.right")
                    .foregroundStyle(.tertiary)
            }
            .buttonStyle(.borderless)
            .accessibilityLabel(Text("Show \(kind.displayName) settings"))
        }
        .padding(.vertical, 2)
        .contentShape(Rectangle())
        .onTapGesture { model.navigate(to: .provider(kind)) }
    }
}

private struct LastCheckedLabel: View {
    let model: SettingsModel

    var body: some View {
        if model.isCheckingAll {
            HStack(spacing: 6) {
                ProgressView().controlSize(.small)
                Text("Checking providers…")
            }
            .foregroundStyle(.secondary)
        } else if let lastChecked = model.lastChecked {
            TimelineView(.periodic(from: .now, by: 30)) { context in
                Text("Last checked \(lastChecked.formatted(.relative(presentation: .named, unitsStyle: .wide)))")
                    .foregroundStyle(.secondary)
                    .id(context.date)
            }
        }
    }
}

private func enabledBinding(_ model: SettingsModel, _ kind: ProviderKind) -> Binding<Bool> {
    Binding(
        get: { model.isEnabled(kind) },
        set: { isOn in model.updateProvider(kind) { $0.isEnabled = isOn } })
}

// MARK: Provider page

struct ProviderSettingsView: View {
    let model: SettingsModel
    let kind: ProviderKind

    var body: some View {
        let status = model.status(kind)
        let needsSetup = model.isEnabled(kind) && (status.state == .notInstalled || status.state == .notAuthenticated)
        Form {
            Section {
                ProviderHeader(model: model, kind: kind)
            }
            Section {
                Toggle(isOn: enabledBinding(model, kind)) {
                    Text("Use \(kind.displayName)")
                    Text("Offer its models in the model picker and let threads run it.")
                }
            }
            if needsSetup {
                ProviderSetupSection(model: model, kind: kind)
            }
            if model.isEnabled(kind) && (status.executable != nil || status.version != nil || status.account != nil) {
                ProviderDetailsSection(status: status)
            }
            if kind == .cursor && model.isEnabled(kind) {
                CursorUsageSection(model: model)
            }
            Section("Executable") {
                ExecutablePathRow(model: model, kind: kind)
            }
            ProviderModelsSection(model: model, kind: kind)
            EnvironmentSection(model: model, kind: kind)
            if !needsSetup {
                ProviderSetupSection(model: model, kind: kind)
            }
        }
        .formStyle(.grouped)
    }
}

/// Icon, title and description at the top of a pane, like System Settings.
struct SettingsPaneHeader<Icon: View, Subtitle: View>: View {
    let title: String
    @ViewBuilder let icon: Icon
    @ViewBuilder let subtitle: Subtitle

    var body: some View {
        HStack(alignment: .center, spacing: 14) {
            icon
            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(.title2.weight(.semibold))
                subtitle
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
        }
        .padding(.vertical, 4)
    }
}

private struct ProviderHeader: View {
    let model: SettingsModel
    let kind: ProviderKind

    var body: some View {
        let status = model.status(kind)
        let presentation = SettingsProviderStatus(model: model, kind: kind)
        let checking = model.isChecking(kind)
        HStack(alignment: .center, spacing: 14) {
            SettingsPaneHeader(title: kind.displayName) {
                SettingsProviderIcon(kind: kind, size: 48)
            } subtitle: {
                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 6) {
                        SettingsStatusDot(color: presentation.color)
                        Text(presentation.headline)
                        if let version = SettingsFormat.version(status.version) {
                            Text(version).monospaced()
                        }
                    }
                    if let message = status.message, !message.isEmpty, message != model.setupHint(kind),
                        model.isEnabled(kind)
                    {
                        SettingsInlineCode(text: message)
                            .font(.caption)
                            .textSelection(.enabled)
                    }
                }
            }
            Button {
                model.check(kind, reloadEnvironment: true)
            } label: {
                Label("Check Again", systemImage: "arrow.clockwise")
                    .opacity(checking ? 0 : 1)
                    .overlay { if checking { ProgressView().controlSize(.small) } }
            }
            .disabled(checking || !model.isEnabled(kind))
            .help(Text("Look for \(kind.displayName) again and reload its models"))
        }
    }
}

private struct ProviderDetailsSection: View {
    let status: ProviderStatus

    var body: some View {
        Section("Details") {
            if let version = SettingsFormat.version(status.version) {
                LabeledContent("Version") {
                    Text(version).monospaced().textSelection(.enabled)
                }
            }
            if let account = status.account, !account.isEmpty {
                LabeledContent("Account") {
                    Text(account).textSelection(.enabled)
                }
            }
            LabeledContent("Location") {
                if let url = status.executable {
                    HStack(spacing: 6) {
                        Text(url.path)
                            .font(.callout.monospaced())
                            .lineLimit(1)
                            .truncationMode(.middle)
                            .textSelection(.enabled)
                            .help(url.path)
                        Button {
                            NSWorkspace.shared.activateFileViewerSelecting([url])
                        } label: {
                            Image(systemName: "arrow.right.circle.fill")
                        }
                        .buttonStyle(.borderless)
                        .foregroundStyle(.secondary)
                        .help(Text("Show in Finder"))
                        .accessibilityLabel(Text("Show in Finder"))
                    }
                } else {
                    Text("Not found").foregroundStyle(.secondary)
                }
            }
        }
    }
}

/// T3 Code's "Cursor account usage" switch: the Cursor CLI keeps its login in the Keychain, and Coincide reads it
/// for the plan's limits only once the user turns this on.
private struct CursorUsageSection: View {
    let model: SettingsModel

    var body: some View {
        Section("Usage Limits") {
            Toggle(
                isOn: Binding(
                    get: { model.settings.cursorKeychainUsageEnabled },
                    set: { isOn in
                        model.update { $0.cursorKeychainUsageEnabled = isOn }
                        model.check(.cursor)
                    })
            ) {
                Text("Show account usage")
                Text(
                    "Read your Cursor CLI login from the macOS Keychain to show your plan’s monthly limits in the composer. macOS may ask you to allow access."
                )
            }
        }
    }
}

// MARK: Executable

private struct ExecutablePathRow: View {
    let model: SettingsModel
    let kind: ProviderKind
    @State private var draft = ""
    @FocusState private var isFocused: Bool

    var body: some View {
        let saved = model.providerSettings(kind).executablePath ?? ""
        let name = model.executableNames(kind).first ?? kind.rawValue
        LabeledContent {
            HStack(spacing: 6) {
                TextField("Executable path", text: $draft, prompt: Text(verbatim: name))
                    .labelsHidden()
                    .textFieldStyle(.roundedBorder)
                    .font(.callout.monospaced())
                    .focused($isFocused)
                    .onSubmit(commit)
                    .frame(minWidth: 200)
                Button("Choose…", action: choose)
            }
        } label: {
            Text("Custom path")
            if !saved.isEmpty && !Self.isExecutable(saved) {
                Text("There’s no executable file at this path.").foregroundStyle(.red)
            } else {
                Text("Leave empty to look for `\(name)` on your shell’s PATH.")
            }
        }
        .onAppear { draft = saved }
        .onChange(of: isFocused) { _, focused in if !focused { commit() } }
        .onChange(of: saved) { _, value in if !isFocused { draft = value } }
    }

    private func commit() {
        let value = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        draft = value
        model.updateProvider(kind) { $0.executablePath = value.isEmpty ? nil : value }
    }

    private func choose() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.treatsFilePackagesAsDirectories = true
        panel.showsHiddenFiles = true
        panel.message = String(localized: "Choose the \(kind.displayName) executable.")
        panel.prompt = String(localized: "Choose")
        if let current = model.status(kind).executable {
            panel.directoryURL = current.deletingLastPathComponent()
        }
        Task {
            let response: NSApplication.ModalResponse
            if let window = NSApp.keyWindow {
                response = await panel.beginSheetModal(for: window)
            } else {
                response = panel.runModal()
            }
            guard response == .OK, let url = panel.url else { return }
            draft = url.path
            commit()
        }
    }

    static func isExecutable(_ path: String) -> Bool {
        FileManager.default.isExecutableFile(atPath: (path as NSString).expandingTildeInPath)
    }
}

// MARK: Models

private struct ProviderModelsSection: View {
    let model: SettingsModel
    let kind: ProviderKind
    @State private var draft = ""
    @State private var error: String?

    private struct Row: Identifiable {
        let option: ModelOption
        let isCustom: Bool
        var id: String { option.id }
    }

    var body: some View {
        let rows = self.rows
        let defaultSelection = model.settings.defaultSelection
        Section {
            if rows.isEmpty {
                Text(
                    model.isEnabled(kind)
                        ? String(localized: "Models appear here once \(kind.displayName) is installed and signed in.")
                        : String(localized: "Turn on \(kind.displayName) to load its models.")
                )
                .foregroundStyle(.secondary)
            }
            ForEach(rows) { row in
                SettingsModelRow(
                    option: row.option, isCustom: row.isCustom,
                    isDefault: defaultSelection.provider == kind && defaultSelection.modelID == row.option.modelID,
                    onRemove: { model.removeCustomModel(row.option.modelID, from: kind) })
            }
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    TextField("Custom model ID", text: $draft, prompt: Text(Self.placeholder(kind)))
                        .labelsHidden()
                        .textFieldStyle(.roundedBorder)
                        .font(.callout.monospaced())
                        .onSubmit(add)
                        .onChange(of: draft) { error = nil }
                    Button("Add", action: add)
                        .disabled(draft.trimmingCharacters(in: .whitespaces).isEmpty)
                }
                if let error {
                    Text(error).font(.caption).foregroundStyle(.red)
                }
            }
        } header: {
            Text("Models")
        } footer: {
            Text("Add model IDs that \(kind.displayName) accepts but doesn’t list. Custom models appear in the model picker.")
        }
    }

    private var rows: [Row] {
        let discovered = model.discoveredModels[kind] ?? []
        let custom = model.providerSettings(kind).customModels
        return discovered.map { Row(option: $0, isCustom: custom.contains($0.modelID)) }
            + custom.filter { id in !discovered.contains { $0.modelID == id } }.map {
                Row(option: ModelOption(provider: kind, modelID: $0, displayName: $0), isCustom: true)
            }
    }

    private func add() {
        error = model.addCustomModel(draft, to: kind)
        if error == nil { draft = "" }
    }

    private static func placeholder(_ kind: ProviderKind) -> String {
        switch kind {
        case .claude: "claude-sonnet-5"
        case .codex: "gpt-5.5-codex"
        case .cursor: "claude-sonnet-4-6"
        case .grok: "grok-4.7"
        case .opencode: "openai/gpt-5"
        case .pi: "anthropic/claude-sonnet-5"
        case .antigravity: "gemini-3-pro"
        case .fx: "anthropic/claude-sonnet-5.5"
        case .muse: "muse-spark-1.3-contributor"
        }
    }
}

struct SettingsModelRow: View {
    let option: ModelOption
    let isCustom: Bool
    let isDefault: Bool
    var onRemove: (() -> Void)?

    var body: some View {
        HStack(spacing: 8) {
            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 6) {
                    Text(option.displayName)
                    if isDefault { SettingsTag(text: String(localized: "Default"), tint: .accentColor) }
                    if isCustom { SettingsTag(text: String(localized: "Custom"), tint: .secondary) }
                }
                if option.displayName != option.modelID {
                    Text(option.modelID)
                        .font(.caption.monospaced())
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                }
            }
            Spacer(minLength: 8)
            SettingsModelCapabilities(option: option)
            if isCustom, let onRemove {
                Button(action: onRemove) {
                    Image(systemName: "minus.circle.fill")
                }
                .buttonStyle(.borderless)
                .foregroundStyle(.red)
                .help(Text("Remove custom model"))
                .accessibilityLabel(Text("Remove \(option.modelID)"))
            }
        }
    }
}

/// Small glyphs for a model's context window, reasoning efforts and image input.
struct SettingsModelCapabilities: View {
    let option: ModelOption

    var body: some View {
        HStack(spacing: 8) {
            if let context = SettingsFormat.contextWindow(option.contextWindow) {
                Label(context, systemImage: "text.alignleft")
                    .help(Text("Context window: \(context) tokens"))
            }
            if !option.efforts.isEmpty {
                Image(systemName: "brain")
                    .help(Text("Reasoning effort: \(option.efforts.map(SettingsFormat.effort).joined(separator: ", "))"))
                    .accessibilityLabel(Text("Supports reasoning effort"))
            }
            if option.supportsImages {
                Image(systemName: "photo")
                    .help(Text("Accepts images"))
                    .accessibilityLabel(Text("Accepts images"))
            }
        }
        .labelStyle(CompactLabelStyle())
        .font(.caption)
        .foregroundStyle(.secondary)
    }
}

private struct CompactLabelStyle: LabelStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: 2) {
            configuration.icon
            configuration.title.monospacedDigit()
        }
    }
}

struct SettingsTag: View {
    let text: String
    let tint: Color

    var body: some View {
        Text(text)
            .font(.caption2.weight(.medium))
            .foregroundStyle(tint)
            .padding(.horizontal, 5)
            .padding(.vertical, 1)
            .background(Capsule().fill(tint.opacity(0.14)))
    }
}

// MARK: Environment

private struct EnvironmentSection: View {
    let model: SettingsModel
    let kind: ProviderKind

    private struct Variable: Identifiable, Equatable {
        let id = UUID()
        var name: String
        var value: String
    }

    private enum Field: Hashable {
        case name(UUID)
        case value(UUID)
    }

    @State private var variables: [Variable] = []
    @State private var revealed: Set<UUID> = []
    @State private var problem: String?
    @FocusState private var focus: Field?

    var body: some View {
        Section {
            ForEach($variables) { $variable in
                HStack(spacing: 6) {
                    TextField("Name", text: $variable.name, prompt: Text(verbatim: "NAME"))
                        .labelsHidden()
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 180)
                        .focused($focus, equals: .name(variable.id))
                        .onSubmit(commit)
                    Text(verbatim: "=").foregroundStyle(.tertiary)
                    valueField($variable)
                    if Self.isSecret(variable.name) {
                        Button {
                            if revealed.remove(variable.id) == nil { revealed.insert(variable.id) }
                        } label: {
                            Image(systemName: revealed.contains(variable.id) ? "eye.slash" : "eye")
                        }
                        .buttonStyle(.borderless)
                        .help(revealed.contains(variable.id) ? Text("Hide value") : Text("Show value"))
                    }
                    Button {
                        variables.removeAll { $0.id == variable.id }
                        commit()
                    } label: {
                        Image(systemName: "minus.circle.fill")
                    }
                    .buttonStyle(.borderless)
                    .foregroundStyle(.red)
                    .help(Text("Remove variable"))
                    .accessibilityLabel(Text("Remove \(variable.name)"))
                }
                .font(.callout.monospaced())
            }
            HStack {
                Button {
                    let variable = Variable(name: "", value: "")
                    variables.append(variable)
                    focus = .name(variable.id)
                } label: {
                    Label("Add Variable", systemImage: "plus")
                }
                if let problem {
                    Spacer()
                    Text(problem).font(.caption).foregroundStyle(.red)
                }
            }
        } header: {
            Text("Environment Variables")
        } footer: {
            Text("Added to \(kind.displayName)’s environment on top of your login shell’s, for example API keys or a custom base URL.")
        }
        .onAppear {
            variables = model.providerSettings(kind).environment
                .sorted { $0.key < $1.key }
                .map { Variable(name: $0.key, value: $0.value) }
        }
        .onChange(of: focus) { commit() }
    }

    @ViewBuilder private func valueField(_ variable: Binding<Variable>) -> some View {
        let id = variable.wrappedValue.id
        if Self.isSecret(variable.wrappedValue.name) && !revealed.contains(id) {
            SecureField("Value", text: variable.value, prompt: Text("value"))
                .labelsHidden()
                .textFieldStyle(.roundedBorder)
                .focused($focus, equals: .value(id))
                .onSubmit(commit)
        } else {
            TextField("Value", text: variable.value, prompt: Text("value"))
                .labelsHidden()
                .textFieldStyle(.roundedBorder)
                .focused($focus, equals: .value(id))
                .onSubmit(commit)
        }
    }

    /// Saves the variables when they are valid. Rows without a name are kept on screen but not saved.
    private func commit() {
        let named = variables.compactMap { variable -> (String, String)? in
            let name = variable.name.trimmingCharacters(in: .whitespaces)
            return name.isEmpty ? nil : (name, variable.value)
        }
        if let invalid = named.first(where: { $0.0.wholeMatch(of: /[A-Za-z_][A-Za-z0-9_]*/) == nil }) {
            problem = String(localized: "“\(invalid.0)” isn’t a valid name. Use letters, digits and underscores.")
            return
        }
        var seen = Set<String>()
        if let duplicate = named.first(where: { !seen.insert($0.0).inserted }) {
            problem = String(localized: "“\(duplicate.0)” is set more than once.")
            return
        }
        problem = nil
        let environment = Dictionary(named, uniquingKeysWith: { _, last in last })
        model.updateProvider(kind) { $0.environment = environment }
    }

    private static func isSecret(_ name: String) -> Bool {
        let upper = name.uppercased()
        return ["KEY", "TOKEN", "SECRET", "PASSWORD", "CREDENTIAL"].contains { upper.contains($0) }
    }
}

// MARK: Setup

private struct ProviderSetupSection: View {
    let model: SettingsModel
    let kind: ProviderKind

    var body: some View {
        let hint = model.setupHint(kind)
        let guide = ProviderSetupGuide(
            kind: kind, hint: hint, executableNames: model.executableNames(kind),
            executableOverride: model.providerSettings(kind).executablePath)
        Section {
            if !hint.isEmpty {
                SettingsInlineCode(text: hint)
            }
            ForEach(guide.commands) { command in
                CommandRow(command: command)
            }
            if let note = guide.note {
                SettingsInlineCode(text: note)
                    .foregroundStyle(.secondary)
            }
            if let website = guide.website {
                Link(destination: website) {
                    Label("\(kind.displayName) Website", systemImage: "safari")
                }
            }
        } header: {
            Text("Setup")
        } footer: {
            Text("After installing or signing in, choose Check Again.")
        }
    }
}

private struct CommandRow: View {
    let command: ProviderSetupGuide.Command

    var body: some View {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 4) {
                Text(command.label)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text(command.text)
                    .font(.callout.monospaced())
                    .textSelection(.enabled)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 5)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(RoundedRectangle(cornerRadius: 6, style: .continuous).fill(.background.secondary))
            }
            SettingsCopyButton(text: command.text)
                .labelStyle(.iconOnly)
                .buttonStyle(.borderless)
            Button {
                ProviderSetupGuide.runInTerminal(command.text)
            } label: {
                Label("Run in Terminal", systemImage: "terminal")
            }
            .labelStyle(.iconOnly)
            .buttonStyle(.borderless)
            .help(Text("Run in Terminal"))
        }
    }
}
