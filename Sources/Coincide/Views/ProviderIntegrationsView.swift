import AppKit
import CoincideCore
import SwiftUI

struct ProviderIntegrationsView: View {
    @Bindable var store: WorkspaceStore
    let kind: ProviderIntegrationKind
    @State private var query = ""
    @State private var provider: ProviderKind?
    @State private var libraryOnly = false
    @State private var selected: Set<String> = []
    @State private var removing: ProviderIntegrationItem?
    @State private var detail: ProviderIntegrationItem?
    @State private var actionError: String?
    private var model: ProviderIntegrationsStore { store.integrations }
    private var rows: [ProviderIntegrationItem] {
        model.items.filter {
            $0.kind == kind && (provider == nil || $0.provider == provider) && (!libraryOnly || $0.imported) &&
            (query.isEmpty || [$0.title, $0.name, $0.summary, $0.scope, $0.provider.name].contains { $0.localizedStandardContains(query) })
        }.sorted {
            if $0.imported != $1.imported { return $0.imported }
            return $0.title.localizedStandardCompare($1.title) == .orderedAscending
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            Text(explanation).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            if kind == .commands {
                SettingsCard(title: "Coincide commands") {
                    ForEach(Array(CoincideSlashCommand.allCases.enumerated()), id: \.element.id) { index, command in
                        if index > 0 { SettingsDivider() }
                        SettingsRow(title: LocalizedStringKey(command.token), subtitle: LocalizedStringKey(command.detail)) {
                            Button("Open") { store.runAppCommand(command) }.buttonStyle(SettingsActionButtonStyle())
                        }
                    }
                }
            }
            controls
            if let message = model.errorMessage ?? actionError {
                Label(message, systemImage: "exclamationmark.circle")
                    .foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            if model.isLoading && model.items.isEmpty {
                ProgressView("Reading your CLI integrations…").frame(maxWidth: .infinity).padding(32)
            } else if rows.isEmpty {
                ContentUnavailableView(query.isEmpty ? "No \(kind.title.lowercased()) found" : "No matches",
                    systemImage: icon, description: Text(query.isEmpty ? "Your selected Codex and Claude configurations appear here. Refresh after adding an integration in either CLI." : "Try another name or provider."))
                    .frame(maxWidth: .infinity).padding(.vertical, 20)
            } else {
                LazyVStack(spacing: 14) { ForEach(rows) { item in integrationRow(item) } }
            }
            if !model.issues.isEmpty {
                DisclosureGroup("Source notices (\(model.issues.count))") {
                    VStack(alignment: .leading, spacing: 12) {
                        ForEach(model.issues) { issue in
                            Text(issue.message).font(.system(size: 12)).foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }.padding(.top, 8)
                }.font(.system(size: 13))
            }
            SettingsCard(title: "Sources") {
                SettingsRow(title: "Project", subtitle: LocalizedStringKey(store.integrationScope.workspacePath ?? "User configuration only")) {
                    Button("Provider configuration") { store.showSettings(.configuration) }
                        .buttonStyle(SettingsActionButtonStyle())
                }
                if let checked = model.checkedAt {
                    SettingsDivider()
                    SettingsRow(title: "Last refreshed") { Text(checked, style: .time).foregroundStyle(.secondary) }
                }
            }
        }
        .task(id: store.integrationScope) { await model.refresh(scope: store.integrationScope) }
        .onChange(of: kind) { selected = []; detail = nil; actionError = nil }
        .onChange(of: store.integrationScope) { selected = []; detail = nil; removing = nil; actionError = nil }
        .onChange(of: model.items) {
            selected.formIntersection(model.items.filter { !$0.imported && $0.available }.map(\.id))
        }
        .alert("Remove from Coincide?", isPresented: Binding(get: { removing != nil }, set: { if !$0 { removing = nil } })) {
            Button("Cancel", role: .cancel) { removing = nil }
            Button("Remove", role: .destructive) {
                guard let item = removing else { return }; removing = nil
                Task { await perform { try await model.removeImport(item.id) } }
            }
        } message: { Text("The original \(removing?.provider.name ?? "CLI") integration stays in place.") }
        .sheet(item: $detail) { item in detailView(item) }
    }

    private var controls: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 10) {
                HStack(spacing: 8) {
                    Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                    TextField("Search \(kind.title.lowercased())", text: $query).textFieldStyle(.plain)
                        .accessibilityIdentifier("integration-search")
                    if !query.isEmpty {
                        Button { query = "" } label: { Image(systemName: "xmark.circle.fill") }
                            .buttonStyle(.plain).foregroundStyle(.secondary).accessibilityLabel("Clear integration search")
                    }
                }.padding(10).background(ChatChrome.composer, in: RoundedRectangle(cornerRadius: 10))
                Button { Task { await model.refresh(scope: store.integrationScope) } } label: {
                    Image(systemName: "arrow.clockwise").frame(width: 20, height: 20)
                }.buttonStyle(SettingsActionButtonStyle()).disabled(model.isLoading || model.isSaving)
                    .accessibilityLabel("Refresh integrations").accessibilityIdentifier("integration-refresh")
            }
            HStack(spacing: 10) {
                SettingsMenu(label: provider?.name ?? "All agents") {
                    Button("All agents") { provider = nil }
                    ForEach(ProviderKind.builtIn) { value in Button(value.name) { provider = value } }
                }.fixedSize().accessibilityLabel("Filter integration provider")
                SettingsMenu(label: libraryOnly ? "Coincide library" : "All sources") {
                    Button("All sources") { libraryOnly = false }
                    Button("Coincide library") { libraryOnly = true }
                }.fixedSize().accessibilityLabel("Filter integration source")
                Spacer(minLength: 4)
                if !selected.isEmpty {
                    Button("Import \(selected.count)") {
                        let ids = Array(selected)
                        Task { await perform { _ = try await model.importItems(ids); selected = [] } }
                    }.buttonStyle(SettingsActionButtonStyle()).disabled(model.isSaving || model.isLoading)
                        .accessibilityIdentifier("integration-import-selected")
                }
            }
        }
    }

    private func integrationRow(_ item: ProviderIntegrationItem) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top, spacing: 12) {
                if !item.imported {
                    Toggle("Select \(item.title)", isOn: Binding(get: { selected.contains(item.id) }, set: {
                        if $0 { selected.insert(item.id) } else { selected.remove(item.id) }
                    })).labelsHidden().toggleStyle(.checkbox).disabled(!item.available)
                }
                ProviderLogo(provider: item.provider, size: 20)
                VStack(alignment: .leading, spacing: 5) {
                    Text(verbatim: item.title).font(.system(size: 14, weight: .medium)).textSelection(.enabled)
                    if !item.summary.isEmpty {
                        Text(verbatim: item.summary).font(.system(size: 12)).foregroundStyle(.secondary).lineLimit(3)
                    }
                    Text([item.provider.name, item.scope, status(item)].filter { !$0.isEmpty }.joined(separator: " · "))
                        .font(.system(size: 11)).foregroundStyle(.secondary)
                }.frame(maxWidth: .infinity, alignment: .leading)
                Menu {
                    Button("Details") { detail = item }
                    if item.imported { Button("Remove from Coincide…", role: .destructive) { removing = item } }
                } label: { Image(systemName: "ellipsis").frame(width: 20, height: 20) }
                    .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
                    .accessibilityLabel("Options for \(item.title)")
            }
            HStack(spacing: 10) {
                if item.kind == .skills || item.kind == .commands {
                    Button("Use in chat") { Task { await use(item) } }
                        .buttonStyle(SettingsActionButtonStyle()).disabled(!canUse(item))
                        .accessibilityIdentifier("integration-use-" + item.id)
                } else {
                    if configurationDestination(item) != nil {
                        Button("Manage configuration") { manageConfiguration(item) }
                            .buttonStyle(SettingsActionButtonStyle())
                    } else {
                        Text("Managed in \(item.provider.name)").font(.system(size: 12)).foregroundStyle(.secondary)
                    }
                }
                Spacer(minLength: 8)
                if item.imported {
                    Label("In Coincide", systemImage: "checkmark").font(.system(size: 12)).foregroundStyle(.secondary)
                } else {
                    Button("Import") { Task { await perform { _ = try await model.importItems([item.id]) } } }
                        .buttonStyle(SettingsActionButtonStyle()).disabled(model.isSaving || model.isLoading || !item.available)
                        .accessibilityIdentifier("integration-import-" + item.id)
                }
            }
        }
        .padding(16).background(ChatChrome.settingsCard, in: RoundedRectangle(cornerRadius: 14))
        .overlay { RoundedRectangle(cornerRadius: 14).strokeBorder(ChatChrome.separator).allowsHitTesting(false) }
        .accessibilityElement(children: .contain).accessibilityIdentifier("integration-row-" + item.id)
    }

    private func canUse(_ item: ProviderIntegrationItem) -> Bool {
        guard item.imported, item.available, item.importMode == .copied || item.enabled, let thread = store.selectedThread else { return false }
        return item.importMode == .copied || thread.provider == item.provider
    }
    private func use(_ item: ProviderIntegrationItem) async {
        await perform { try await store.useIntegration(item) }
    }
    private func configurationDestination(_ item: ProviderIntegrationItem) -> ProviderConfigurationEditorStore.Destination? {
        guard model.scope == store.integrationScope,
              model.items.contains(where: { $0 == item }) else { return nil }
        return ProviderConfigurationEditorStore.destination(for: item, codex: store.integrationCodexConfiguration,
            claude: store.integrationClaudeProfile, workspacePath: store.integrationScope.workspacePath)
    }
    private func manageConfiguration(_ item: ProviderIntegrationItem) {
        guard let destination = configurationDestination(item) else { return }
        let scope = store.integrationScope
        let codex = store.integrationCodexConfiguration, claude = store.integrationClaudeProfile
        Task {
            await perform {
                guard store.integrationScope == scope, configurationDestination(item) == destination else {
                    throw CoincideError("The integration source changed. Refresh it before opening settings.")
                }
                try await store.configurationEditor.selectSource(destination, codex: codex, claude: claude, workspacePath: scope.workspacePath)
                guard store.integrationScope == scope, configurationDestination(item) == destination else {
                    throw CoincideError("The selected workspace changed. Choose the integration again.")
                }
                detail = nil
                store.showSettings(.configuration)
            }
        }
    }
    private func perform(_ action: () async throws -> Void) async {
        actionError = nil
        do { try await action() }
        catch { actionError = (error as? CoincideError)?.message ?? "The integration action could not be completed. Refresh and try again." }
    }
    private func status(_ item: ProviderIntegrationItem) -> String {
        if !item.available { return "Unavailable in this scope" }
        if item.importMode == .copied { return ProviderIntegrationImportMode.copied.title }
        if !item.enabled { return "Disabled in CLI" }
        return item.importMode?.title ?? "Available from CLI"
    }
    private func detailView(_ item: ProviderIntegrationItem) -> some View {
        VStack(alignment: .leading, spacing: 20) {
            HStack {
                ProviderLogo(provider: item.provider, size: 24)
                Text(verbatim: item.title).font(.system(size: 19, weight: .medium))
                Spacer()
                Button("Done") { detail = nil }.keyboardShortcut(.cancelAction)
            }
            Text(item.summary).foregroundStyle(.secondary).textSelection(.enabled)
            LabeledContent("Agent", value: item.provider.name)
            if item.title != item.name { LabeledContent("Identifier", value: item.name) }
            LabeledContent("Scope", value: item.scope)
            LabeledContent("Status", value: status(item))
            VStack(alignment: .leading, spacing: 6) {
                Text("Source").fontWeight(.medium)
                Text(item.sourcePath).font(.system(size: 12, design: .monospaced)).textSelection(.enabled)
                if let path = item.libraryPath {
                    Text("Coincide copy").fontWeight(.medium)
                    Text(path).font(.system(size: 12, design: .monospaced)).textSelection(.enabled)
                }
            }
            if item.importMode == .linked {
                Text("This entry follows the original CLI configuration. Its credentials stay with that CLI, and it only runs when that provider loads it.")
                    .foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            if configurationDestination(item) != nil {
                Button("Provider configuration") { manageConfiguration(item) }
                    .buttonStyle(SettingsActionButtonStyle())
            }
        }.padding(28).frame(width: 540).fixedSize(horizontal: false, vertical: true)
    }
    private var explanation: String {
        switch kind {
        case .skills: "Discover skills from Codex and Claude, save independent copies in Coincide, and add them to your chat."
        case .commands: "Browse your agents’ slash commands and reusable prompts. Use adds the instruction to your draft without sending it."
        case .mcp: "See MCP servers configured in your CLIs. Import keeps a link to their existing configuration and authentication."
        case .plugins: "See installed agent plugins and their source. Linked imports continue using the plugin’s original CLI configuration."
        case .hooks: "See the hooks configured for each agent. Hooks run through that CLI; browsing and importing never executes them."
        }
    }
    private var icon: String {
        switch kind { case .skills: "sparkles"; case .commands: "slash.circle"; case .mcp: "server.rack"; case .plugins: "puzzlepiece.extension"; case .hooks: "arrow.triangle.branch" }
    }
}
