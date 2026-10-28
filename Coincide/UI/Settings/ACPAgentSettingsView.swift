import AppKit
import CoincideKit
import SwiftUI

// MARK: Adding an agent

/// T3 Code's Add provider dialog for ACP agents: search the ACP Registry and add an agent at its published version,
/// or add a local ACP command.
struct AddACPAgentSheet: View {
    let model: SettingsModel
    @Environment(\.dismiss) private var dismiss
    @State private var mode: Mode = .registry

    enum Mode: Hashable {
        case registry
        case local
    }

    var body: some View {
        VStack(spacing: 0) {
            Picker("Source", selection: $mode) {
                Text("ACP Registry").tag(Mode.registry)
                Text("Local ACP Command").tag(Mode.local)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .padding([.horizontal, .top], 16)
            .padding(.bottom, 4)
            switch mode {
            case .registry: ACPRegistrySearchView(model: model, onAdded: added)
            case .local: ACPLocalCommandForm(model: model, onAdded: added, onCancel: { dismiss() })
            }
            if mode == .registry {
                Divider()
                HStack {
                    Spacer()
                    Button("Done") { dismiss() }
                        .keyboardShortcut(.cancelAction)
                }
                .padding(12)
            }
        }
        .frame(width: 600, height: 560)
    }

    private func added(_ kind: ProviderKind) {
        dismiss()
        model.navigate(to: .provider(kind))
    }
}

private struct ACPRegistrySearchView: View {
    let model: SettingsModel
    let onAdded: (ProviderKind) -> Void
    var catalog: ACPRegistryCatalog = .shared
    var tools: ACPRegistryTools = .shared
    @State private var query = ""
    @State private var results: [ACPRegistrySearchResult]?
    @State private var refreshed = false
    @State private var error: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            ACPThirdPartyNote()
            TextField("Search agents", text: $query, prompt: Text("Search agents"))
                .textFieldStyle(.roundedBorder)
            if let error {
                Text(error).font(.callout).foregroundStyle(.red).textSelection(.enabled)
            } else if let failure = catalog.failure, results?.isEmpty != false {
                Text(failure).font(.callout).foregroundStyle(.red)
            }
            if let results {
                if results.isEmpty {
                    ContentUnavailableView {
                        Label("No Compatible Agents", systemImage: "magnifyingglass")
                    } description: {
                        Text("Try a broader search.")
                    }
                } else {
                    List(results) { result in
                        ACPRegistryAgentRow(
                            result: result, isAdded: isAdded(result.agent.id), install: tools.installs[result.agent.id],
                            canAdd: tools.installs.isEmpty, add: { add(result) })
                    }
                    .listStyle(.inset)
                }
            } else {
                HStack {
                    Spacer()
                    ProgressView().controlSize(.small)
                    Text("Searching the ACP Registry…").foregroundStyle(.secondary)
                    Spacer()
                }
                .frame(maxHeight: .infinity)
            }
        }
        .padding(16)
        .task(id: query) {
            // The index is fetched once when the sheet opens; typing searches it, after T3 Code's pause.
            if !refreshed {
                await catalog.refresh()
                refreshed = true
            } else {
                try? await Task.sleep(for: .milliseconds(300))
            }
            guard !Task.isCancelled else { return }
            let found = await catalog.results(query)
            guard !Task.isCancelled else { return }
            results = found
        }
    }

    private func isAdded(_ agentID: String) -> Bool {
        model.settings.acpAgents.contains { $0.source == .registry && $0.registry?.agentID == agentID }
    }

    private func add(_ result: ACPRegistrySearchResult) {
        error = nil
        Task {
            do {
                onAdded(try await model.addRegistryAgent(result))
            } catch {
                self.error = error.localizedDescription
            }
        }
    }
}

/// Registry agents are third-party code, as T3 Code's documentation warns.
private struct ACPThirdPartyNote: View {
    var body: some View {
        Label {
            Text(
                "Registry agents are third-party code that runs on this Mac with your permissions. Review an agent’s source and license before you add it. Coincide checks a download against the SHA-256 the registry publishes, when it publishes one."
            )
        } icon: {
            Image(systemName: "exclamationmark.shield")
        }
        .font(.callout)
        .foregroundStyle(.secondary)
        .fixedSize(horizontal: false, vertical: true)
    }
}

private struct ACPRegistryAgentRow: View {
    let result: ACPRegistrySearchResult
    let isAdded: Bool
    let install: ACPRegistryTools.InstallState?
    let canAdd: Bool
    let add: () -> Void

    var body: some View {
        let agent = result.agent
        HStack(alignment: .top, spacing: 10) {
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(agent.name).fontWeight(.medium)
                    Text(SettingsFormat.version(agent.version) ?? agent.version)
                        .font(.caption.monospaced())
                        .foregroundStyle(.secondary)
                }
                if !agent.description.isEmpty {
                    Text(agent.description)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
                HStack(spacing: 6) {
                    SettingsTag(text: ACPRegistryFormat.distribution(result.distribution.kind), tint: .secondary)
                    SettingsTag(
                        text: result.distribution.hasChecksum ? String(localized: "SHA-256") : String(localized: "HTTPS only"),
                        tint: result.distribution.hasChecksum ? .green : .orange)
                    if let details = ACPRegistryFormat.credits(authors: agent.authors, license: agent.license) {
                        Text(details).lineLimit(1).truncationMode(.tail)
                    }
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }
            Spacer(minLength: 8)
            if let about = agent.aboutURL {
                Link(destination: about) { Image(systemName: "safari") }
                    .help(Text("About \(agent.name)"))
                    .accessibilityLabel(Text("About \(agent.name)"))
            }
            if let repository = agent.repository, repository != agent.aboutURL {
                Link(destination: repository) { Image(systemName: "chevron.left.forwardslash.chevron.right") }
                    .help(Text("Source code"))
                    .accessibilityLabel(Text("Source code of \(agent.name)"))
            }
            if let install {
                ProgressView().controlSize(.small)
                Text(ACPRegistryFormat.progress(install)).font(.caption).foregroundStyle(.secondary).monospacedDigit()
            } else {
                Button(isAdded ? String(localized: "Add Again") : String(localized: "Add"), action: add)
                    .disabled(!canAdd)
            }
        }
        .padding(.vertical, 4)
    }
}

/// T3 Code's local ACP command: an installed executable, literal arguments, a name and environment variables.
private struct ACPLocalCommandForm: View {
    let model: SettingsModel
    let onAdded: (ProviderKind) -> Void
    let onCancel: () -> Void
    @State private var name = ""
    @State private var command = ""
    @State private var arguments = ACPArgumentRows()
    @State private var variables = ACPVariableRows()
    @State private var problem: String?

    var body: some View {
        VStack(spacing: 0) {
            Form {
                Section {
                    TextField("Name", text: $name, prompt: Text(verbatim: "DeepSeek Harness"))
                    LabeledContent {
                        HStack(spacing: 6) {
                            TextField("Executable", text: $command, prompt: Text(verbatim: "dsh"))
                                .labelsHidden()
                                .font(.callout.monospaced())
                            Button("Choose…") { ACPExecutablePicker.choose(name: name) { command = $0 } }
                        }
                    } label: {
                        Text("Executable")
                        Text("A name on your shell’s PATH, or a full path.")
                    }
                } footer: {
                    Text("Coincide starts the executable directly, without a shell, and passes each argument exactly as written.")
                }
                ACPArgumentsEditor(rows: $arguments)
                Section {
                    ACPVariablesEditor(rows: $variables)
                } header: {
                    Text("Environment Variables")
                } footer: {
                    Text("Added to the agent’s environment on top of your login shell’s, for example an API key.")
                }
            }
            .formStyle(.grouped)
            Divider()
            HStack {
                if let problem {
                    Text(problem).font(.callout).foregroundStyle(.red).lineLimit(2)
                }
                Spacer()
                Button("Cancel", action: onCancel).keyboardShortcut(.cancelAction)
                Button("Add Agent", action: add)
                    .keyboardShortcut(.defaultAction)
                    .disabled(command.trimmingCharacters(in: .whitespaces).isEmpty)
            }
            .padding(12)
        }
    }

    private func add() {
        let executable = command.trimmingCharacters(in: .whitespacesAndNewlines)
        guard ACPAgentConfig.isValidCommand(executable) else {
            problem = String(localized: "Enter an executable name, or a full path that starts with /.")
            return
        }
        let environment: [String: String]
        switch variables.environment() {
        case .success(let value): environment = value
        case .failure(let failure):
            problem = failure.message
            return
        }
        let displayName = ACPAgentConfigName.from(name, executable: executable)
        let id = ACPAgentConfig.makeID(from: displayName, existing: Set(model.settings.acpAgents.map(\.id)))
        model.addACPAgent(
            ACPAgentConfig(id: id, name: displayName, source: .local, command: executable, arguments: arguments.values),
            environment: environment)
        onAdded(.acp(id))
    }
}

/// A name for a local command: what the user typed, else the executable's file name.
enum ACPAgentConfigName {
    static func from(_ typed: String, executable: String) -> String {
        let trimmed = typed.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? (executable as NSString).lastPathComponent : String(trimmed.prefix(80))
    }
}

// MARK: An added agent's page

/// The sections an added ACP agent's page shows above the common ones: what it runs, and its sign-in.
struct ACPAgentSections: View {
    let model: SettingsModel
    let agent: ACPAgentConfig

    var body: some View {
        ACPAgentDetailsSection(model: model, agent: agent)
        ACPAgentSignInSection(model: model, agent: agent, signIn: .shared(for: agent.kind))
    }
}

private struct ACPAgentDetailsSection: View {
    let model: SettingsModel
    let agent: ACPAgentConfig
    var catalog: ACPRegistryCatalog = .shared
    var tools: ACPRegistryTools = .shared
    @State private var name = ""
    @State private var command = ""
    @State private var arguments = ACPArgumentRows()
    @State private var confirmingRemoval = false
    @State private var argumentsEdited = false
    @State private var error: String?
    @FocusState private var focused: Field?

    private enum Field: Hashable {
        case name
        case command
    }

    var body: some View {
        Section {
            LabeledContent("Name") {
                TextField("Name", text: $name)
                    .labelsHidden()
                    .multilineTextAlignment(.trailing)
                    .focused($focused, equals: .name)
                    .onSubmit(commitName)
            }
            switch agent.source {
            case .local: localRows
            case .registry: registryRows
            }
            if let error {
                Text(error).font(.callout).foregroundStyle(.red).textSelection(.enabled)
            }
            HStack {
                Spacer()
                Button("Remove Agent…", role: .destructive) { confirmingRemoval = true }
                    .disabled(agent.registry.map { tools.isInstalling($0.agentID) } ?? false)
            }
        } header: {
            Text(agent.source == .registry ? String(localized: "ACP Registry Agent") : String(localized: "Local ACP Command"))
        } footer: {
            if agent.source == .registry {
                ACPThirdPartyNote()
            }
        }
        .onAppear {
            name = agent.name
            command = agent.command
            arguments = ACPArgumentRows(agent.arguments)
            if agent.source == .registry { _ = catalog.cachedIndex() }
        }
        .onChange(of: focused) { old, _ in
            if old == .name { commitName() }
            if old == .command { commitCommand() }
        }
        .onChange(of: arguments.values) { _, values in
            guard values != agent.arguments else { return }
            argumentsEdited = true
            model.updateACPAgent(agent.id, recheck: false) { $0.arguments = values }
        }
        .task(id: arguments.values) {
            // Checks the agent again once typing settles, not at every key.
            try? await Task.sleep(for: .seconds(1.5))
            guard !Task.isCancelled, argumentsEdited else { return }
            argumentsEdited = false
            model.check(agent.kind)
        }
        .alert(Text("Remove \(agent.displayName)?"), isPresented: $confirmingRemoval) {
            Button("Remove", role: .destructive) { model.removeACPAgent(agent.id) }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Its threads keep their history. Files Coincide installed for it are deleted once nothing uses them.")
        }
    }

    @ViewBuilder private var localRows: some View {
        LabeledContent {
            HStack(spacing: 6) {
                TextField("Executable", text: $command, prompt: Text(verbatim: "dsh"))
                    .labelsHidden()
                    .font(.callout.monospaced())
                    .focused($focused, equals: .command)
                    .onSubmit(commitCommand)
                Button("Choose…") {
                    ACPExecutablePicker.choose(name: agent.displayName) {
                        command = $0
                        commitCommand()
                    }
                }
            }
        } label: {
            Text("Executable")
            Text("A name on your shell’s PATH, or a full path.")
        }
        ACPArgumentsList(rows: $arguments)
    }

    @ViewBuilder private var registryRows: some View {
        if let install = agent.registry {
            let state = tools.installs[install.agentID]
            let latest = catalog.index?.agent(install.agentID)
            let isInstalled = ACPRegistryPaths.standard.validatedExecutable(for: install) != nil
            LabeledContent("Registry ID") {
                Text(install.agentID).monospaced().textSelection(.enabled)
            }
            LabeledContent("Version") {
                Text(SettingsFormat.version(install.version) ?? install.version).monospaced()
            }
            LabeledContent("Distribution") {
                Text(ACPRegistryFormat.installed(install))
            }
            if let license = install.license {
                LabeledContent("License") { Text(license).textSelection(.enabled) }
            }
            if install.website != nil || install.repository != nil {
                LabeledContent("Links") {
                    HStack(spacing: 12) {
                        if let website = install.website { Link("Website", destination: website) }
                        if let repository = install.repository { Link("Source Code", destination: repository) }
                    }
                }
            }
            LabeledContent {
                if let state {
                    HStack(spacing: 6) {
                        ProgressView().controlSize(.small)
                        Text(ACPRegistryFormat.progress(state)).monospacedDigit()
                    }
                } else if let latest, latest.version != install.version {
                    Button("Update to \(SettingsFormat.version(latest.version) ?? latest.version)") { reinstall(latest) }
                } else if !isInstalled, let latest {
                    Button("Reinstall") { reinstall(latest) }
                } else {
                    Button("Check for Updates") { Task { await catalog.refresh() } }
                        .disabled(catalog.isRefreshing)
                }
            } label: {
                Text("Installation")
                Text(isInstalled ? String(localized: "Installed in Coincide’s data folder.") : String(localized: "The installed files are missing."))
            }
        } else {
            Text("Coincide couldn’t read what was installed for this agent. Remove it and add it again from the ACP Registry.")
                .foregroundStyle(.red)
        }
    }

    private func reinstall(_ latest: ACPRegistryAgent) {
        error = nil
        Task {
            do {
                try await model.reinstallRegistryAgent(agent.id, from: latest)
            } catch {
                self.error = error.localizedDescription
            }
        }
    }

    private func commitName() {
        let value = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else {
            name = agent.name
            return
        }
        model.updateACPAgent(agent.id, recheck: false) { $0.name = String(value.prefix(80)) }
    }

    private func commitCommand() {
        let value = command.trimmingCharacters(in: .whitespacesAndNewlines)
        command = value
        guard ACPAgentConfig.isValidCommand(value) else {
            error = String(localized: "Enter an executable name, or a full path that starts with /.")
            return
        }
        error = nil
        model.updateACPAgent(agent.id) { $0.command = value }
    }
}

// MARK: Sign-in

private struct ACPAgentSignInSection: View {
    let model: SettingsModel
    let agent: ACPAgentConfig
    let signIn: ACPAgentSignIn
    @State private var confirmingSignOut = false

    var body: some View {
        let status = model.status(agent.kind)
        let canStart = model.isEnabled(agent.kind) && status.executable != nil && !signIn.isActive
        Section {
            if signIn.hasDiscovered {
                if signIn.methods.isEmpty {
                    Text("\(agent.displayName) doesn’t advertise a sign-in method. It may use its own configuration or environment variables.")
                        .foregroundStyle(.secondary)
                }
                ForEach(signIn.methods, id: \.id) { method in
                    ACPAuthMethodRow(method: method, canStart: canStart) { start(method) }
                }
                let automatic = signIn.methods.filter(\.isAgentDriven)
                if automatic.count > 1 || (agent.authMethodID != nil && !automatic.isEmpty) {
                    Picker(selection: authMethodBinding) {
                        Text("First the agent completes itself").tag(String?.none)
                        ForEach(automatic, id: \.id) { method in Text(method.name).tag(Optional(method.id)) }
                    } label: {
                        Text("Method for sessions")
                        Text("Used when a session finds the agent signed out.")
                    }
                }
            }
            if let url = signIn.pendingURL {
                VStack(alignment: .leading, spacing: 6) {
                    Text(url.absoluteString)
                        .font(.callout.monospaced())
                        .lineLimit(2)
                        .truncationMode(.middle)
                        .textSelection(.enabled)
                    HStack {
                        Button("Open in Browser") {
                            signIn.acceptPendingURL()
                            NSWorkspace.shared.open(url)
                        }
                        SettingsCopyButton(text: url.absoluteString, label: "Copy Sign-in Link")
                    }
                }
            }
            if let message = signIn.message {
                HStack(spacing: 6) {
                    if signIn.isActive { ProgressView().controlSize(.small) }
                    Text(message)
                        .font(.callout)
                        .foregroundStyle(signIn.phase == .failed ? .red : .secondary)
                        .textSelection(.enabled)
                }
            }
            HStack {
                if signIn.isActive {
                    Button("Cancel") { signIn.cancel() }
                } else {
                    Button(signIn.hasDiscovered ? String(localized: "Refresh Sign-in Methods") : String(localized: "Show Sign-in Methods")) {
                        Task { if let launch = await model.acpLaunch(agent.id) { signIn.discover(launch) } }
                    }
                    .disabled(!canStart)
                }
                Spacer()
                if signIn.canLogout && !signIn.methods.isEmpty {
                    Button("Sign Out…") { confirmingSignOut = true }
                        .disabled(!canStart)
                }
            }
        } header: {
            Text("Sign-in")
        } footer: {
            Text("Coincide starts \(agent.displayName) to sign in with its own methods. Credentials stay in the agent’s own store.")
        }
        .onChange(of: signIn.phase) { _, phase in
            if phase == .succeeded { model.check(agent.kind) }
        }
        .alert(Text("Sign out of \(agent.displayName)?"), isPresented: $confirmingSignOut) {
            Button("Sign Out", role: .destructive) {
                Task { if let launch = await model.acpLaunch(agent.id) { signIn.signOut(launch) } }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Running threads of this agent may stop working until you sign in again.")
        }
    }

    private var authMethodBinding: Binding<String?> {
        Binding(
            get: { agent.authMethodID },
            set: { value in model.updateACPAgent(agent.id, recheck: false) { $0.authMethodID = value } })
    }

    private func start(_ method: ACPAuthMethod) {
        Task {
            guard let launch = await model.acpLaunch(agent.id) else { return }
            switch method.type {
            case "terminal": ProviderSetupGuide.runInTerminal(ACPAgentSignIn.terminalCommand(method, launch))
            default: signIn.signIn(methodID: method.id, launch)
            }
        }
    }
}

private struct ACPAuthMethodRow: View {
    let method: ACPAuthMethod
    let canStart: Bool
    let start: () -> Void

    var body: some View {
        LabeledContent {
            switch method.type {
            case nil, "agent":
                Button("Sign in", action: start).disabled(!canStart)
            case "terminal":
                Button("Sign In in Terminal", action: start).disabled(!canStart)
            default:
                if let link = method.link {
                    Link("Get a Key", destination: link)
                }
            }
        } label: {
            Text(String(method.name.prefix(160)))
            if method.type == "env_var", !method.variables.isEmpty {
                Text("Set \(method.variables.joined(separator: ", ")) in Environment Variables below, then choose Check Again.")
            } else if let description = method.description.flatMap({ $0.isEmpty ? nil : $0 }) {
                Text(String(description.prefix(1_024)))
            }
        }
    }
}

// MARK: Shared pieces

/// Rows of literal arguments, kept in order.
struct ACPArgumentRows: Equatable {
    struct Row: Identifiable, Equatable {
        let id = UUID()
        var value: String
    }

    var rows: [Row]

    init(_ values: [String] = []) {
        rows = values.map { Row(value: $0) }
    }

    var values: [String] { rows.map(\.value) }
}

/// The arguments section of the local command form.
private struct ACPArgumentsEditor: View {
    @Binding var rows: ACPArgumentRows

    var body: some View {
        Section {
            ACPArgumentsList(rows: $rows)
        } header: {
            Text("Arguments")
        } footer: {
            Text("One argument per row, for example --profile and acp.")
        }
    }
}

/// One text field per argument, with add and remove buttons.
private struct ACPArgumentsList: View {
    @Binding var rows: ACPArgumentRows

    var body: some View {
        ForEach($rows.rows) { $row in
            HStack(spacing: 6) {
                TextField("Argument", text: $row.value, prompt: Text("argument"))
                    .labelsHidden()
                    .textFieldStyle(.roundedBorder)
                    .font(.callout.monospaced())
                Button {
                    rows.rows.removeAll { $0.id == row.id }
                } label: {
                    Image(systemName: "minus.circle.fill")
                }
                .buttonStyle(.borderless)
                .foregroundStyle(.red)
                .help(Text("Remove argument"))
                .accessibilityLabel(Text("Remove argument"))
            }
        }
        Button {
            rows.rows.append(.init(value: ""))
        } label: {
            Label("Add Argument", systemImage: "plus")
        }
    }
}

/// Environment variable rows for the local command form.
struct ACPVariableRows: Equatable {
    struct Row: Identifiable, Equatable {
        let id = UUID()
        var name = ""
        var value = ""
    }

    struct Problem: Error {
        let message: String
    }

    var rows: [Row] = []

    /// The named rows, or why they can't be saved.
    func environment() -> Result<[String: String], Problem> {
        var result: [String: String] = [:]
        for row in rows {
            let name = row.name.trimmingCharacters(in: .whitespaces)
            guard !name.isEmpty else { continue }
            guard name.wholeMatch(of: /[A-Za-z_][A-Za-z0-9_]*/) != nil else {
                return .failure(Problem(message: String(localized: "“\(name)” isn’t a valid name. Use letters, digits and underscores.")))
            }
            guard result[name] == nil else {
                return .failure(Problem(message: String(localized: "“\(name)” is set more than once.")))
            }
            result[name] = row.value
        }
        return .success(result)
    }
}

private struct ACPVariablesEditor: View {
    @Binding var rows: ACPVariableRows

    var body: some View {
        ForEach($rows.rows) { $row in
            HStack(spacing: 6) {
                TextField("Name", text: $row.name, prompt: Text(verbatim: "NAME"))
                    .labelsHidden()
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 160)
                Text(verbatim: "=").foregroundStyle(.tertiary)
                SecureField("Value", text: $row.value, prompt: Text("value"))
                    .labelsHidden()
                    .textFieldStyle(.roundedBorder)
                Button {
                    rows.rows.removeAll { $0.id == row.id }
                } label: {
                    Image(systemName: "minus.circle.fill")
                }
                .buttonStyle(.borderless)
                .foregroundStyle(.red)
                .help(Text("Remove variable"))
            }
            .font(.callout.monospaced())
        }
        Button {
            rows.rows.append(.init())
        } label: {
            Label("Add Variable", systemImage: "plus")
        }
    }
}

/// Picks an executable file with an open panel.
enum ACPExecutablePicker {
    static func choose(name: String, _ chosen: @escaping (String) -> Void) {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.treatsFilePackagesAsDirectories = true
        panel.showsHiddenFiles = true
        panel.message = name.isEmpty ? String(localized: "Choose the agent’s executable.") : String(localized: "Choose the \(name) executable.")
        panel.prompt = String(localized: "Choose")
        Task {
            let response: NSApplication.ModalResponse
            if let window = NSApp.keyWindow {
                response = await panel.beginSheetModal(for: window)
            } else {
                response = panel.runModal()
            }
            guard response == .OK, let url = panel.url else { return }
            chosen(url.path)
        }
    }
}

/// How registry details read in Settings.
enum ACPRegistryFormat {
    static func distribution(_ kind: ACPRegistryDistribution) -> String {
        switch kind {
        case .binary: String(localized: "Download")
        case .npx: String(localized: "npm package")
        case .uvx: String(localized: "Python package")
        }
    }

    static func installed(_ install: ACPRegistryInstall) -> String {
        switch install.distribution {
        case .binary:
            install.sha256 != nil
                ? String(localized: "Download, checked against the registry’s SHA-256")
                : String(localized: "Download over HTTPS (the registry publishes no SHA-256)")
        case .npx: String(localized: "npm package, installed in Coincide’s data folder")
        case .uvx: String(localized: "Python package, installed in Coincide’s data folder")
        }
    }

    static func credits(authors: [String], license: String?) -> String? {
        let parts = [authors.prefix(3).joined(separator: ", "), license ?? ""].filter { !$0.isEmpty }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    static func progress(_ state: ACPRegistryTools.InstallState) -> String {
        switch state.phase {
        case .downloading:
            let downloaded = state.downloadedBytes.formatted(.byteCount(style: .file))
            guard let total = state.totalBytes else { return String(localized: "Downloading \(downloaded)…") }
            return String(localized: "Downloading \(downloaded) of \(total.formatted(.byteCount(style: .file)))…")
        case .extracting: return String(localized: "Unpacking…")
        case .installingPackage: return String(localized: "Installing…")
        }
    }
}
