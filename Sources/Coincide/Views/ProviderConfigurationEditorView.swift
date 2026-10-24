import AppKit
import CoincideCore
import SwiftUI

/// Embed in the main window's Settings content. Uses the selected runtime's
/// actual configuration namespace, never a parallel copy of its credentials.
struct ProviderConfigurationEditorView: View {
    let codex: CodexRuntimeConfiguration
    let claude: ClaudeRuntimeProfile
    let workspacePath: String?
    @State private var store: ProviderConfigurationEditorStore
    @State private var pendingProvider: ProviderKind?
    @State private var pendingScope: ProviderConfigurationScope?
    @State private var confirmDiscard = false

    init(codex: CodexRuntimeConfiguration, claude: ClaudeRuntimeProfile, workspacePath: String?, editor: ProviderConfigurationEditorStore? = nil) {
        self.codex = codex; self.claude = claude; self.workspacePath = workspacePath
        _store = State(initialValue: editor ?? ProviderConfigurationEditorStore())
    }

    private var identity: String {
        [codex.instanceID.uuidString, codex.homeDirectory ?? "", claude.instanceID.uuidString,
         claude.configurationDirectory ?? "", workspacePath ?? ""].joined(separator: "|")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            Text("Edit the settings used by your installed CLIs. These controls change the provider's own files; they are separate from Coincide's conversation controls.")
                .font(.system(size: 13)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            SettingsCard(title: "Configuration source") {
                SettingsRow(title: "Provider") {
                    Picker("Provider", selection: Binding<ProviderKind>(
                        get: { store.provider },
                        set: { provider in selectProvider(provider) }
                    )) {
                        Text("Codex").tag(ProviderKind.codex)
                        Text("Claude").tag(ProviderKind.claude)
                    }.labelsHidden().frame(width: 160).accessibilityIdentifier("configuration-provider")
                }
                SettingsDivider()
                SettingsRow(title: "Scope", subtitle: "Inherit removes an override from this file. Other scopes and organization policy still apply.") {
                    Picker("Scope", selection: Binding<ProviderConfigurationScope>(
                        get: { store.scope },
                        set: { scope in selectScope(scope) }
                    )) {
                        Text("User").tag(ProviderConfigurationScope.user)
                        Text("Shared project").tag(ProviderConfigurationScope.project)
                        if store.provider == .claude { Text("Project local").tag(ProviderConfigurationScope.local) }
                    }.labelsHidden().frame(width: 180).accessibilityIdentifier("configuration-scope")
                }
                if let document = store.document {
                    SettingsDivider()
                    VStack(alignment: .leading, spacing: 10) {
                        Text(document.sourceURL.path).font(.system(size: 12, design: .monospaced)).textSelection(.enabled)
                            .foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true).accessibilityIdentifier("configuration-source")
                        if document.resolvedURL != document.sourceURL.standardizedFileURL {
                            Text("Linked configuration — saves preserve the link.").font(.system(size: 12)).foregroundStyle(.secondary)
                        }
                        HStack(spacing: 10) {
                            Button(document.exists ? "Open source file" : "Show configuration folder", action: openSource)
                            Button("Reload") { reload(force: true) }.disabled(store.hasChanges).accessibilityIdentifier("configuration-reload")
                            Spacer()
                            if store.isBusy { ProgressView().controlSize(.small) }
                        }.buttonStyle(SettingsActionButtonStyle())
                        if !document.exists {
                            Text("This scope has no file yet. Saving a setting creates it.").font(.system(size: 12)).foregroundStyle(.secondary)
                        }
                    }.padding(.vertical, 14)
                }
            }.disabled(store.isBusy)

            // Load failures have no form; save results appear beside the Save button.
            if store.document == nil, let error = store.errorMessage { errorLabel(error) }
            if let document = store.document {
                ForEach(store.groups, id: \.self) { group in
                    let fields = document.fields.filter { $0.group == group }
                    SettingsCard(title: LocalizedStringKey(group)) {
                        ForEach(Array(fields.enumerated()), id: \.element.id) { index, field in
                            if index > 0 { SettingsDivider() }
                            fieldRow(field)
                        }
                    }
                }
                HStack(spacing: 10) {
                    Text(store.hasChanges ? "\(store.changes.count) unsaved settings" : "No unsaved changes")
                        .font(.system(size: 12)).foregroundStyle(.secondary)
                    Spacer()
                    Button("Discard") { store.discard() }.disabled(!store.hasChanges || store.isBusy).accessibilityIdentifier("configuration-discard")
                    Button("Save changes") { Task { await store.save() } }.disabled(!store.hasChanges || store.isBusy).accessibilityIdentifier("configuration-save")
                }.buttonStyle(SettingsActionButtonStyle())
                if let error = store.errorMessage { errorLabel(error) }
                if let message = store.message {
                    Label(message, systemImage: "checkmark.circle").font(.system(size: 13)).foregroundStyle(.secondary)
                        .accessibilityIdentifier("configuration-saved")
                }
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(document.notices, id: \.self) { Text($0).font(.system(size: 12)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true) }
                }
            }
            coverage
        }
        .task(id: identity) { await store.load(codex: codex, claude: claude, workspacePath: workspacePath) }
        .confirmationDialog("Discard unsaved configuration changes?", isPresented: $confirmDiscard) {
            Button("Discard changes", role: .destructive) {
                store.discard()
                if let provider = pendingProvider { store.provider = provider }
                if let scope = pendingScope { store.scope = scope }
                pendingProvider = nil; pendingScope = nil; reload()
            }
            Button("Keep editing", role: .cancel) { pendingProvider = nil; pendingScope = nil }
        } message: { Text("The provider's files have not been changed.") }
    }

    private func errorLabel(_ error: String) -> some View {
        Label(error, systemImage: "exclamationmark.triangle").font(.system(size: 13)).foregroundStyle(.orange)
            .fixedSize(horizontal: false, vertical: true).accessibilityIdentifier("configuration-error")
    }

    @ViewBuilder private func fieldRow(_ field: ProviderConfigurationField) -> some View {
        if !field.isEditable {
            SettingsRow(title: LocalizedStringKey(field.title), subtitle: "Advanced or sensitive value preserved. Open the source file to change it.") {
                Image(systemName: "lock.doc").foregroundStyle(.secondary)
            }
        } else if case .lines = field.control {
            VStack(alignment: .leading, spacing: 8) {
                Text(field.title).font(.system(size: 13))
                Text(field.detail).font(.system(size: 12)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                TextField("Inherit — one entry per line", text: binding(field), axis: .vertical)
                    .font(.system(size: 12, design: .monospaced)).textFieldStyle(.plain).lineLimit(2...7)
                    .padding(10).frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 8))
                    .overlay { RoundedRectangle(cornerRadius: 8).strokeBorder(ChatChrome.separator) }
                    .accessibilityLabel(field.title).accessibilityIdentifier("configuration-field-" + field.id)
            }.padding(.vertical, 14).disabled(store.isBusy)
        } else {
            SettingsRow(title: LocalizedStringKey(field.title), subtitle: LocalizedStringKey(field.detail)) {
                control(field).disabled(store.isBusy).accessibilityIdentifier("configuration-field-" + field.id)
            }
        }
    }
    @ViewBuilder private func control(_ field: ProviderConfigurationField) -> some View {
        switch field.control {
        case .toggle:
            Picker(field.title, selection: binding(field)) {
                Text("Inherit").tag("")
                Text("Enabled").tag("true")
                Text("Disabled").tag("false")
            }.labelsHidden().frame(width: 150)
        case .choice(let options):
            Picker(field.title, selection: binding(field)) {
                Text("Inherit").tag("")
                ForEach(options, id: \.self) { Text($0).tag($0) }
            }.labelsHidden().frame(width: 190)
        case .text, .integer:
            TextField("Inherit", text: binding(field)).textFieldStyle(.roundedBorder)
                .frame(width: 210).accessibilityLabel(field.title)
        case .lines: EmptyView()
        }
    }
    private var coverage: some View {
        SettingsCard(title: "CLI capabilities") {
            VStack(alignment: .leading, spacing: 10) {
                Text("Skills, slash commands, MCP servers, plugins and hooks have their own Settings pages. This editor manages common defaults and the configured enable states above. Source files remain the authority for advanced provider settings.")
                Text("Terminal-only display modes, terminal key bindings and interactive CLI screens are not embedded in Coincide. Transport flags such as stream-json, app-server and resume are managed by the app; arbitrary launch flags are not passed through. Remote control and cloud workflows are not connected here.")
                HStack(spacing: 16) {
                    Link("Codex configuration reference", destination: URL(string: "https://developers.openai.com/codex/config-reference")!)
                    Link("Claude settings reference", destination: URL(string: "https://code.claude.com/docs/en/settings")!)
                }
            }.font(.system(size: 12)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true).padding(.vertical, 14)
        }
    }
    private func binding(_ field: ProviderConfigurationField) -> Binding<String> {
        .init(get: { store.value(field) }, set: { store.setValue($0, for: field) })
    }
    private func selectProvider(_ provider: ProviderKind) {
        guard provider != store.provider else { return }
        if store.hasChanges { pendingProvider = provider; confirmDiscard = true }
        else { store.provider = provider; reload() }
    }
    private func selectScope(_ scope: ProviderConfigurationScope) {
        guard scope != store.scope else { return }
        if store.hasChanges { pendingScope = scope; confirmDiscard = true }
        else { store.scope = scope; reload() }
    }
    private func reload(force: Bool = false) { Task { await store.load(codex: codex, claude: claude, workspacePath: workspacePath, force: force) } }
    private func openSource() {
        guard let document = store.document else { return }
        if document.exists { NSWorkspace.shared.open(document.sourceURL) }
        else {
            var folder = document.sourceURL.deletingLastPathComponent()
            while !FileManager.default.fileExists(atPath: folder.path), folder.path != "/" { folder.deleteLastPathComponent() }
            NSWorkspace.shared.open(folder)
        }
    }
}
