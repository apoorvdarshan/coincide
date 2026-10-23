import AppKit
import CoincideCore
import SwiftUI

extension ProjectScriptIcon {
    var systemImage: String {
        switch self {
        case .play: "play.fill"
        case .test: "flask"
        case .lint: "checklist"
        case .configure: "wrench.and.screwdriver"
        case .build: "hammer"
        case .debug: "ladybug"
        }
    }
    var title: String {
        switch self {
        case .play: String(localized: "Play")
        case .test: String(localized: "Test")
        case .lint: String(localized: "Lint")
        case .configure: String(localized: "Configure")
        case .build: String(localized: "Build")
        case .debug: String(localized: "Debug")
        }
    }
}

/// Requests from the quick-run control that need a window-level sheet.
struct ProjectActionsRequests {
    var review: (CodingThread, String?) -> Void
    var addAction: (WorkspaceProject) -> Void
    var settings: (WorkspaceProject) -> Void
}

/// T3's project actions split button: the remembered or primary script runs directly, and the menu lists
/// every action with role labels and shortcuts. App-owned actions run with their displayed digest pinned;
/// t3.json scripts open the review sheet first because their command comes from the checkout.
struct ProjectActionsToolbarControl: View {
    let store: WorkspaceStore
    let terminals: TerminalWorkspaceStore
    let commands: ProjectActionCommands
    let keybindings: KeybindingsStore?
    let requests: ProjectActionsRequests
    @State private var loaded: (key: LoadKey, configuration: ProjectConfiguration?, warning: String?)?
    @State private var commandOwner = UUID()
    @Environment(MainWindowController.self) private var controller: MainWindowController?
    private var thread: CodingThread? { store.selectedThread }
    private var project: WorkspaceProject? { thread.flatMap { thread in store.snapshot.projects.first { $0.id == thread.projectID } } }
    private var settings: ProjectSettingsStore { store.projectSettings }
    private var available: Bool { thread.map { store.canOpenTerminal(for: $0) } ?? false }
    private struct LoadKey: Hashable {
        let threadID: UUID?
        let threadCreatedAt: Date?
        let projectID: UUID?
        let projectCreatedAt: Date?
        let settingsKeys: [Data]
        let workspacePath: Data
        let preparationID: UUID?
        let available: Bool
    }
    private var loadKey: LoadKey {
        .init(threadID: thread?.id, threadCreatedAt: thread?.createdAt, projectID: thread?.projectID,
              projectCreatedAt: project?.createdAt, settingsKeys: project.map { ProjectSettingsKey.candidates(for: $0).map { Data($0.utf8) } } ?? [],
              workspacePath: Data((thread?.workspacePath ?? "").utf8), preparationID: thread?.workspacePreparation?.id, available: available)
    }
    private var catalog: ProjectScriptCatalog {
        let configuration = loaded?.key == loadKey ? loaded?.configuration : nil
        return .init(actions: project.map { settings.document(for: $0).actions } ?? nil, configuration: configuration)
    }
    var body: some View {
        let catalog = catalog
        let sourceThread = thread
        let sourceProject = project
        let signature = registrationSignature(catalog)
        let primary = project.flatMap { catalog.primary(preferredID: settings.lastInvokedScriptID(for: $0)) }
        let primarySource = primary.flatMap { entry in sourceThread.flatMap { ProjectActionCommands.Source(store: store, thread: $0, entry: entry) } }
        Group {
            if let primary, available {
                Menu { menuItems(catalog) } label: {
                    Label(String(localized: "Run \(primary.script.name)"), systemImage: primary.script.icon.systemImage)
                } primaryAction: { if let primarySource { commands.perform(.script(primary.id), expected: primarySource) } }
                .help(primary.action == nil ? String(localized: "Review and run \(primary.script.name) from t3.json") : String(localized: "Run \(primary.script.name)"))
                .accessibilityLabel(Text("Run \(primary.script.name)"))
                .accessibilityIdentifier("project-actions-run")
            } else {
                Menu { menuItems(catalog) } label: { Label("Actions", systemImage: "wrench.and.screwdriver") }
                    .help("Project actions").accessibilityLabel("Project actions")
                    .accessibilityIdentifier("project-actions-menu")
            }
        }
        .disabled(thread == nil || commands.isRunning)
        .task(id: signature) { if !Task.isCancelled { register(catalog, thread: sourceThread, project: sourceProject) } }
        .onDisappear { commands.unregister(owner: commandOwner) }
        .task(id: loadKey) { await loadConfiguration() }
        .task(id: loadKey) { if let project { await settings.load(project) } }
    }

    @ViewBuilder private func menuItems(_ catalog: ProjectScriptCatalog) -> some View {
        let originalThread = thread
        let originalProject = project
        if !catalog.scripts.isEmpty {
            Section(catalog.origin == .projectActions ? String(localized: "Project Actions") : String(localized: "t3.json Scripts")) {
                ForEach(catalog.scripts) { entry in
                    let source = thread.flatMap { ProjectActionCommands.Source(store: store, thread: $0, entry: entry) }
                    Button { if let source { commands.perform(.script(entry.id), expected: source) } } label: {
                        HStack {
                            Label(entry.menuLabel, systemImage: entry.script.icon.systemImage)
                            if let hint = shortcutLabel(for: entry) { Text(verbatim: hint).foregroundStyle(.secondary) }
                        }
                    }.disabled(!available)
                }
            }
        }
        let previews = catalog.scripts.filter { $0.script.previewURL != nil }
        if !previews.isEmpty {
            Section("Preview") {
                ForEach(previews) { entry in
                    let source = thread.flatMap { ProjectActionCommands.Source(store: store, thread: $0, entry: entry) }
                    Button { if let source { openPreview(entry.script, source: source) } } label: { Label("Open Preview for \(entry.script.name)", systemImage: "safari") }
                }
            }
        }
        if catalog.origin == .projectActions, !catalog.importable.isEmpty, let project {
            Section("Import from t3.json") {
                ForEach(Array(catalog.importable.enumerated()), id: \.offset) { _, script in
                    let capture = settings.capture(for: project)
                    Button { importScript(script, project: project, capture: capture) } label: { Label(script.name, systemImage: "square.and.arrow.down") }
                }
            }
        }
        Divider()
        if let project {
            Button("Add Action…") { if let originalThread, ProjectActionCommands.targetIsCurrent(store: store, thread: originalThread, project: project) { requests.addAction(project) } }
        }
        if let thread = originalThread { Button("Run Script…") { if let originalProject, ProjectActionCommands.targetIsCurrent(store: store, thread: thread, project: originalProject) { requests.review(thread, nil) } }.disabled(!available).accessibilityIdentifier("project-scripts") }
        if let project { Button("Project Settings…") { if let originalThread, ProjectActionCommands.targetIsCurrent(store: store, thread: originalThread, project: project) { requests.settings(project) } } }
        if let warning = loaded?.warning, loaded?.key == loadKey { Text(warning) }
    }

    private struct RegistrationSignature: Hashable {
        let sources: [ProjectActionCommands.Source]
        let shortcuts: [ProjectActionShortcut?]
        let available: Bool
        let controllerID: ObjectIdentifier?
    }
    private func registrationSignature(_ catalog: ProjectScriptCatalog) -> RegistrationSignature {
        .init(sources: catalog.scripts.compactMap { entry in thread.flatMap { ProjectActionCommands.Source(store: store, thread: $0, entry: entry) } },
              shortcuts: catalog.scripts.map(\.shortcut), available: available, controllerID: controller.map(ObjectIdentifier.init))
    }
    private func register(_ catalog: ProjectScriptCatalog, thread: CodingThread?, project: WorkspaceProject?) {
        guard let thread, let project else { commands.unregister(owner: commandOwner); return }
        let store = store, terminals = terminals, requests = requests, settings = settings
        let controller = controller
        commands.replace(owner: commandOwner, bindings: catalog.scripts.compactMap { entry in
            guard let source = ProjectActionCommands.Source(store: store, thread: thread, entry: entry) else { return nil }
            return .init(source: source, shortcut: entry.shortcut,
                isAllowed: { [weak controller] in controller?.canHandleInteraction == true && source.isCurrent(in: store) && store.canOpenTerminal(for: thread) },
                invoke: {
                    guard source.isCurrent(in: store) else { return }
                    guard let action = entry.action else { requests.review(thread, entry.id); return }
                    try await store.projectScripts().run(action, thread: thread, in: terminals)
                    settings.rememberInvokedScript(action.id, for: project)
                    terminals.setVisible(true, threadID: thread.id)
                }, report: { store.errorMessage = $0.localizedDescription })
        })
    }
    private func shortcutLabel(for entry: ResolvedProjectScript) -> String? {
        let command = KeybindingCommand.script(entry.id)
        if let keybindings {
            return keybindings.shortcut(for: command, context: .menu, projectDefaults: commands.defaults)?.label
        }
        return KeybindingResolver.shortcut(for: command, in: KeybindingResolver.merge(KeybindingDefaults.resolved, defaults: commands.defaults))?.label
    }
    private func loadConfiguration() async {
        guard let thread, available else { loaded = nil; return }
        let key = loadKey
        do {
            let context = try await store.projectScripts().load(for: thread)
            try Task.checkCancellation()
            loaded = (key, context.document.configuration, context.document.warning ?? context.settingsError)
        } catch { if !Task.isCancelled { loaded = (key, nil, nil) } }
    }
    private func openPreview(_ script: ProjectScript, source: ProjectActionCommands.Source) {
        guard source.isCurrent(in: store), let value = script.previewURL else { return }
        do { try store.projectScripts().preview.open(value, sourceIsCurrent: { source.isCurrent(in: store) }) }
        catch { store.errorMessage = error.localizedDescription }
    }
    private func importScript(_ script: ProjectScript, project: WorkspaceProject, capture: ProjectSettingsCapture?) {
        guard let capture else { return }
        let scope = ProjectSettingsPresentationScope(project: project)
        Task {
            do {
                try await settings.update(project, expectedCapture: capture,
                    sourceIsCurrent: { scope.matches(store.snapshot.projects.first(where: { $0.id == project.id })) }) { document in
                    document.actions = try ProjectActions.adding(.init(script: script), to: document.actions ?? [])
                }
            } catch { store.errorMessage = error.localizedDescription }
        }
    }
}
