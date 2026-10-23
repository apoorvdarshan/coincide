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

extension ProjectActionShortcut {
    var keyEquivalent: KeyEquivalent { KeyEquivalent(Character(key)) }
    var eventModifiers: EventModifiers {
        var value: EventModifiers = []
        if command { value.insert(.command) }; if shift { value.insert(.shift) }
        if option { value.insert(.option) }; if control { value.insert(.control) }
        return value
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
    let requests: ProjectActionsRequests
    @State private var loaded: (key: String, configuration: ProjectConfiguration?, warning: String?)?
    @State private var running = false
    private var thread: CodingThread? { store.selectedThread }
    private var project: WorkspaceProject? { thread.flatMap { thread in store.snapshot.projects.first { $0.id == thread.projectID } } }
    private var settings: ProjectSettingsStore { store.projectSettings }
    private var available: Bool { thread.map { store.canOpenTerminal(for: $0) } ?? false }
    private var loadKey: String { thread.map { "\($0.id)\u{0}\($0.workspacePath)\u{0}\(available)" } ?? "" }
    private var catalog: ProjectScriptCatalog {
        let configuration = loaded?.key == loadKey ? loaded?.configuration : nil
        return .init(actions: project.map { settings.document(for: $0).actions } ?? nil, configuration: configuration)
    }
    var body: some View {
        let catalog = catalog
        let primary = project.flatMap { catalog.primary(preferredID: settings.lastInvokedScriptID(for: $0)) }
        Group {
            if let primary, available {
                Menu { menuItems(catalog) } label: {
                    Label(String(localized: "Run \(primary.script.name)"), systemImage: primary.script.icon.systemImage)
                } primaryAction: { run(primary) }
                .help(primary.action == nil ? String(localized: "Review and run \(primary.script.name) from t3.json") : String(localized: "Run \(primary.script.name)"))
                .accessibilityLabel(Text("Run \(primary.script.name)"))
                .accessibilityIdentifier("project-actions-run")
            } else {
                Menu { menuItems(catalog) } label: { Label("Actions", systemImage: "wrench.and.screwdriver") }
                    .help("Project actions").accessibilityLabel("Project actions")
                    .accessibilityIdentifier("project-actions-menu")
            }
        }
        .disabled(thread == nil || running)
        .background { shortcutButtons(catalog) }
        .task(id: loadKey) { await loadConfiguration() }
        .task(id: project?.id) { if let project { await settings.load(project) } }
    }

    @ViewBuilder private func menuItems(_ catalog: ProjectScriptCatalog) -> some View {
        if !catalog.scripts.isEmpty {
            Section(catalog.origin == .projectActions ? String(localized: "Project Actions") : String(localized: "t3.json Scripts")) {
                ForEach(catalog.scripts) { entry in
                    let button = Button { run(entry) } label: { Label(entry.menuLabel, systemImage: entry.script.icon.systemImage) }.disabled(!available)
                    if let shortcut = entry.shortcut { button.keyboardShortcut(shortcut.keyEquivalent, modifiers: shortcut.eventModifiers) }
                    else { button }
                }
            }
        }
        let previews = catalog.scripts.filter { $0.script.previewURL != nil }
        if !previews.isEmpty {
            Section("Preview") {
                ForEach(previews) { entry in
                    Button { openPreview(entry.script) } label: { Label("Open Preview for \(entry.script.name)", systemImage: "safari") }
                }
            }
        }
        if catalog.origin == .projectActions, !catalog.importable.isEmpty, let project {
            Section("Import from t3.json") {
                ForEach(Array(catalog.importable.enumerated()), id: \.offset) { _, script in
                    Button { importScript(script, project: project) } label: { Label(script.name, systemImage: "square.and.arrow.down") }
                }
            }
        }
        Divider()
        if let project {
            Button("Add Action…") { requests.addAction(project) }
        }
        if let thread { Button("Run Script…") { requests.review(thread, nil) }.disabled(!available).accessibilityIdentifier("project-scripts") }
        if let project { Button("Project Settings…") { requests.settings(project) } }
        if let warning = loaded?.warning, loaded?.key == loadKey { Text(warning) }
    }

    /// Zero-size buttons register each action's shortcut while this window shows the control.
    private func shortcutButtons(_ catalog: ProjectScriptCatalog) -> some View {
        ZStack {
            ForEach(catalog.scripts.filter { $0.shortcut != nil }) { entry in
                if let shortcut = entry.shortcut {
                    Button("") { run(entry) }.keyboardShortcut(shortcut.keyEquivalent, modifiers: shortcut.eventModifiers)
                        .disabled(!available || running).opacity(0).frame(width: 0, height: 0).accessibilityHidden(true)
                }
            }
        }.frame(width: 0, height: 0).allowsHitTesting(false)
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
    private func run(_ entry: ResolvedProjectScript) {
        guard let thread, let project, available, !running else { return }
        guard let action = entry.action else { requests.review(thread, entry.id); return }
        running = true
        Task {
            defer { running = false }
            do {
                try await store.projectScripts().run(action, thread: thread, in: terminals)
                settings.rememberInvokedScript(action.id, for: project)
                terminals.panelVisible = true
            } catch is CancellationError { }
            catch { store.errorMessage = error.localizedDescription }
        }
    }
    private func openPreview(_ script: ProjectScript) {
        guard let value = script.previewURL else { return }
        do { try store.projectScripts().preview.open(value) } catch { store.errorMessage = error.localizedDescription }
    }
    private func importScript(_ script: ProjectScript, project: WorkspaceProject) {
        Task {
            do { try await settings.update(project) { document in document.actions = try ProjectActions.adding(.init(script: script), to: document.actions ?? []) } }
            catch { store.errorMessage = error.localizedDescription }
        }
    }
}
