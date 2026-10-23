import AppKit
import CoincideCore
import Observation
import SwiftUI
import UniformTypeIdentifiers

/// Window-level requests for project settings and action editors, shared by the toolbar and sidebar.
@MainActor @Observable
final class ProjectActionsPresenter {
    struct SettingsTarget: Identifiable, Equatable { let projectID: UUID; var id: UUID { projectID } }
    struct EditorTarget: Identifiable { let id = UUID(); let project: WorkspaceProject; let actionID: String?; let initial: ProjectActionInput }
    var settings: SettingsTarget?
    var editor: EditorTarget?
    func showSettings(_ project: WorkspaceProject) { settings = .init(projectID: project.id) }
    func addAction(_ project: WorkspaceProject, initial: ProjectActionInput = .init()) { editor = .init(project: project, actionID: nil, initial: initial) }
    func editAction(_ id: String, project: WorkspaceProject) { editor = .init(project: project, actionID: id, initial: .init()) }
}

extension View {
    /// Installs project settings and action editor sheets for one window and shares the presenter with its sidebar.
    func projectActionsPresentation(store: WorkspaceStore, presenter: ProjectActionsPresenter) -> some View {
        self.environment(presenter)
            .sheet(item: Binding(get: { presenter.settings }, set: { presenter.settings = $0 })) { target in
                ProjectSettingsSheet(store: store, projectID: target.projectID, close: { presenter.settings = nil })
            }
            .sheet(item: Binding(get: { presenter.editor }, set: { presenter.editor = $0 })) { target in
                ProjectActionEditorSheet(settings: store.projectSettings, project: target.project, actionID: target.actionID,
                                         initial: target.initial, close: { presenter.editor = nil })
            }
    }
}

/// T3's Project settings category: name, icon, actions, repository-backed defaults, checkouts and removal.
struct ProjectSettingsSheet: View {
    let store: WorkspaceStore
    let projectID: UUID
    let close: () -> Void
    @State private var name = ""
    @State private var file: ProjectConfigurationDocument?
    @State private var error: String?
    @State private var saving = false
    @State private var editor: ProjectActionsPresenter.EditorTarget?
    @State private var confirmReset = false
    @State private var removal: ProjectRemovalRequest?
    @State private var groupRemoval: ProjectGroupRemovalRequest?
    private var project: WorkspaceProject? { store.snapshot.projects.first { $0.id == projectID } }
    private var group: ProjectGroup? { store.projectGroup(containing: projectID) }
    private var settings: ProjectSettingsStore { store.projectSettings }
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if let project {
                header(project)
                Form {
                    projectSection(project)
                    actionsSection(project)
                    defaultsSection(project)
                    checkoutsSection(project)
                    dangerSection(project)
                }.formStyle(.grouped)
            } else {
                ContentUnavailableView("Project Removed", systemImage: "folder.badge.minus", description: Text("This project is no longer in the workspace."))
            }
            HStack {
                if let error { Text(error).font(.caption).foregroundStyle(.red).lineLimit(3).accessibilityIdentifier("project-settings-error") }
                Spacer()
                Button("Done", action: close).keyboardShortcut(.defaultAction).accessibilityIdentifier("project-settings-done")
            }.padding(16)
        }
        .frame(width: 600, height: 640)
        .task(id: projectID) { await load() }
        .sheet(item: $editor) { target in
            ProjectActionEditorSheet(settings: settings, project: target.project, actionID: target.actionID, initial: target.initial, close: { editor = nil })
        }
        .confirmationDialog("Use the checkout’s t3.json scripts?", isPresented: $confirmReset) {
            Button("Use t3.json", role: .destructive) { change { $0.actions = nil } }
            Button("Cancel", role: .cancel) { }
        } message: { Text("This removes this project’s own action list and its shortcuts. t3.json is not changed.") }
        .confirmationDialog(removal.map { "Remove “\($0.name)” from Coincide?" } ?? "", isPresented: Binding(get: { removal != nil }, set: { if !$0 { removal = nil } }), presenting: removal) { request in
            Button("Remove Project", role: .destructive) {
                removal = nil; close()
                Task {
                    do { try await store.removeProject(request) } catch is CancellationError { } catch { store.errorMessage = error.localizedDescription }
                }
            }
            Button("Cancel", role: .cancel) { removal = nil }
        } message: { request in
            Text(request.path + "\n\n" + String(localized: "This removes this checkout’s conversations from the workspace and stops their agents and terminals. Coincide does not delete checkout files."))
        }
        .sheet(item: $groupRemoval) { request in
            ProjectGroupRemovalSheet(request: request, cancel: { groupRemoval = nil }, remove: {
                groupRemoval = nil; close()
                Task {
                    do { try await store.removeProjectGroup(request) } catch is CancellationError { } catch { store.errorMessage = error.localizedDescription }
                }
            })
        }
    }

    private func header(_ project: WorkspaceProject) -> some View {
        HStack(spacing: 12) {
            ProjectIconView(settings: settings, project: project, name: group?.displayName ?? project.name, size: 32)
            VStack(alignment: .leading, spacing: 2) {
                Text(group?.displayName ?? project.name).font(.title2).lineLimit(1)
                Text(project.path).font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle).textSelection(.enabled)
            }
        }.padding([.horizontal, .top], 20).padding(.bottom, 4)
    }

    // MARK: Project

    @ViewBuilder private func projectSection(_ project: WorkspaceProject) -> some View {
        Section("Project") {
            HStack {
                TextField("Name", text: $name).accessibilityIdentifier("project-settings-name")
                Button("Rename") { rename(project) }
                    .disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || name == (group?.displayName ?? project.name))
            }
            LabeledContent("Icon") {
                Menu {
                    Button("Automatic") { change { $0.icon = nil } }
                    Menu("Monogram") {
                        let text = ProjectMonogram(name: group?.displayName ?? project.name).text
                        ForEach(ProjectIconColor.allCases) { color in
                            Button(color.title) { change { $0.icon = .monogram(text: text, color: color) } }
                        }
                    }
                    Menu("Symbol") {
                        ForEach(Self.symbols, id: \.self) { symbol in
                            Button { change { $0.icon = .symbol(name: symbol, color: .blue) } } label: { Label(symbol, systemImage: symbol) }
                        }
                    }
                    Menu("Emoji") {
                        ForEach(Self.emoji, id: \.self) { value in Button(value) { change { $0.icon = .emoji(value) } } }
                    }
                    Button("Image from Checkout…") { chooseImage(project) }
                } label: {
                    HStack(spacing: 6) {
                        ProjectIconView(settings: settings, project: project, name: group?.displayName ?? project.name)
                        Text(iconTitle(project))
                    }
                }.fixedSize().accessibilityIdentifier("project-settings-icon")
            }
            Text("Automatic uses t3.json `iconPath`, then a favicon or app icon in the checkout, then the project’s monogram.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }
    static let symbols = ["folder", "hammer", "globe", "server.rack", "iphone", "desktopcomputer", "terminal", "shippingbox", "cube", "leaf", "flame", "bolt", "book", "gamecontroller", "paintbrush", "chart.bar"]
    static let emoji = ["🚀", "🧪", "🛠️", "📦", "🌐", "📱", "🎮", "🎨", "📚", "⚡️", "🔥", "🌱"]
    private func iconTitle(_ project: WorkspaceProject) -> String {
        switch settings.document(for: project).icon {
        case nil: String(localized: "Automatic")
        case .symbol: String(localized: "Symbol")
        case .emoji: String(localized: "Emoji")
        case .monogram: String(localized: "Monogram")
        case .image(let path): path
        }
    }

    // MARK: Actions

    @ViewBuilder private func actionsSection(_ project: WorkspaceProject) -> some View {
        let actions = settings.document(for: project).actions
        let fileScripts = file?.configuration?.scripts ?? []
        let importable = ProjectActions.importable(fileScripts, existing: actions ?? [])
        Section {
            if let actions {
                if actions.isEmpty { Text("No actions. This project ignores t3.json scripts until you use them again.").foregroundStyle(.secondary) }
                ForEach(Array(actions.enumerated()), id: \.element.id) { index, action in
                    actionRow(action, index: index, count: actions.count, project: project)
                }
            } else if fileScripts.isEmpty {
                Text("No actions yet. Add one to run it from the toolbar.").foregroundStyle(.secondary)
            } else {
                Text("Using \(fileScripts.count) scripts from t3.json. Adding, importing or editing creates this project’s own list.")
                    .foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                ForEach(Array(fileScripts.enumerated()), id: \.offset) { _, script in
                    Label(ProjectActions.menuLabel(name: script.name, setup: script.runOnWorktreeCreate, settle: script.runOnSettle), systemImage: script.icon.systemImage)
                }
            }
            if let warning = file?.warning {
                Label("t3.json is invalid, so its scripts and icon are ignored. \(warning)", systemImage: "exclamationmark.triangle")
                    .font(.caption).foregroundStyle(.orange)
            }
            if let loadError = settings.loadErrors[settings.key(for: project)] {
                Label(loadError, systemImage: "exclamationmark.triangle").font(.caption).foregroundStyle(.red)
            }
        } header: {
            HStack {
                Text("Actions")
                Spacer()
                if !importable.isEmpty {
                    Menu("Import from t3.json") {
                        if importable.count > 1 { Button("Import All") { importScripts(importable) } ; Divider() }
                        ForEach(Array(importable.enumerated()), id: \.offset) { _, script in
                            Button { importScripts([script]) } label: { Label(script.name, systemImage: script.icon.systemImage) }
                        }
                    }.fixedSize().accessibilityIdentifier("project-settings-import")
                }
                Button("Add Action…") { editor = .init(project: project, actionID: nil, initial: .init()) }
                    .accessibilityIdentifier("project-settings-add-action")
                if actions != nil { Button("Use t3.json…") { confirmReset = true }.accessibilityIdentifier("project-settings-reset-actions") }
            }.controlSize(.small)
        }
    }
    private func actionRow(_ action: ProjectAction, index: Int, count: Int, project: WorkspaceProject) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Image(systemName: action.icon.systemImage).frame(width: 18).foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 2) {
                Text(action.menuLabel).lineLimit(1)
                Text(action.command).font(.caption.monospaced()).foregroundStyle(.secondary).lineLimit(1).truncationMode(.tail)
            }
            Spacer(minLength: 8)
            if let shortcut = action.shortcut { Text(shortcut.displayLabel).font(.caption.monospaced()).foregroundStyle(.secondary) }
            Menu {
                Button("Edit…") { editor = .init(project: project, actionID: action.id, initial: .init()) }
                Button("Move Up") { move(index, by: -1) }.disabled(index == 0)
                Button("Move Down") { move(index, by: 1) }.disabled(index == count - 1)
            } label: { Image(systemName: "ellipsis.circle") }
                .menuStyle(.borderlessButton).fixedSize().accessibilityLabel("Options for \(action.name)")
        }.accessibilityElement(children: .combine).accessibilityIdentifier("project-action-\(action.id)")
    }

    // MARK: Defaults

    @ViewBuilder private func defaultsSection(_ project: WorkspaceProject) -> some View {
        let document = settings.document(for: project)
        let environment = ProjectDefaultsResolver.threadEnvironmentMode(project: document.defaultThreadEnvMode, app: settings.appThreadEnvironmentMode, repository: file?.configuration)
        let submodules = ProjectDefaultsResolver.worktreeSubmodules(project: document.worktreeSubmodules, app: settings.appWorktreeSubmodules, repository: file?.configuration)
        Section {
            Picker("New thread workspace", selection: Binding(get: { document.defaultThreadEnvMode }, set: { value in change { $0.defaultThreadEnvMode = value } })) {
                Text("Inherit").tag(ProjectThreadEnvironmentMode?.none)
                ForEach(ProjectThreadEnvironmentMode.allCases, id: \.self) { Text(Self.title($0)).tag(Optional($0)) }
            }.accessibilityIdentifier("project-settings-thread-mode")
            Picker("All projects", selection: Binding(get: { settings.appThreadEnvironmentMode }, set: { settings.appThreadEnvironmentMode = $0 })) {
                Text("Inherit").tag(ProjectThreadEnvironmentMode?.none)
                ForEach(ProjectThreadEnvironmentMode.allCases, id: \.self) { Text(Self.title($0)).tag(Optional($0)) }
            }.font(.caption).accessibilityLabel("New thread workspace for all projects").accessibilityIdentifier("project-settings-app-thread-mode")
            resolved(Self.title(environment.value), source: environment.source).accessibilityIdentifier("project-settings-thread-mode-resolved")
            Picker("Worktree submodules", selection: Binding(get: { document.worktreeSubmodules }, set: { value in change { $0.worktreeSubmodules = value } })) {
                Text("Inherit").tag(ProjectWorktreeSubmoduleMode?.none)
                ForEach(ProjectWorktreeSubmoduleMode.allCases, id: \.self) { Text(Self.title($0)).tag(Optional($0)) }
            }.accessibilityIdentifier("project-settings-submodules")
            Picker("All projects", selection: Binding(get: { settings.appWorktreeSubmodules }, set: { settings.appWorktreeSubmodules = $0 })) {
                Text("Inherit").tag(ProjectWorktreeSubmoduleMode?.none)
                ForEach(ProjectWorktreeSubmoduleMode.allCases, id: \.self) { Text(Self.title($0)).tag(Optional($0)) }
            }.font(.caption).accessibilityLabel("Worktree submodules for all projects").accessibilityIdentifier("project-settings-app-submodules")
            resolved(Self.title(submodules.value), source: submodules.source).accessibilityIdentifier("project-settings-submodules-resolved")
        } header: { Text("Defaults") } footer: {
            Text("Resolution order: this project, all projects, the checkout’s t3.json, then the built-in default (Local and Recursive).")
                .font(.caption).foregroundStyle(.secondary)
        }
    }
    private func resolved(_ value: String, source: ProjectSettingSource) -> some View {
        HStack(spacing: 6) {
            Text("Uses \(value)").font(.caption)
            Text(source.title).font(.caption2.weight(.medium)).padding(.horizontal, 6).padding(.vertical, 2)
                .background(Color.accentColor.opacity(0.14), in: Capsule())
        }.foregroundStyle(.secondary)
    }
    static func title(_ mode: ProjectThreadEnvironmentMode) -> String {
        switch mode { case .local: String(localized: "Local"); case .worktree: String(localized: "New worktree") }
    }
    static func title(_ mode: ProjectWorktreeSubmoduleMode) -> String {
        switch mode { case .recursive: String(localized: "Recursive"); case .topLevel: String(localized: "Top level only"); case .none: String(localized: "Skip") }
    }

    // MARK: Checkouts and removal

    @ViewBuilder private func checkoutsSection(_ project: WorkspaceProject) -> some View {
        Section("Checkouts") {
            ForEach(group?.members ?? [project]) { member in
                HStack {
                    Text(member.path).font(.caption.monospaced()).lineLimit(1).truncationMode(.middle).textSelection(.enabled)
                    Spacer()
                    Button("Reveal") { NSWorkspace.shared.selectFile(nil, inFileViewerRootedAtPath: member.path) }
                        .disabled(member.clone.map { !$0.isReady } ?? false)
                    if (group?.members.count ?? 1) > 1 {
                        Button("Remove…", role: .destructive) { removal = store.projectRemovalRequest(member.id) }
                    }
                }.controlSize(.small)
            }
        }
    }
    @ViewBuilder private func dangerSection(_ project: WorkspaceProject) -> some View {
        Section {
            if let group, group.memberProjectIDs.count > 1 {
                Button("Remove Group…", role: .destructive) { groupRemoval = store.projectGroupRemovalRequest(group.key) }
            } else {
                Button("Remove Project…", role: .destructive) { removal = store.projectRemovalRequest(project.id) }
                    .accessibilityIdentifier("project-settings-remove")
            }
        } footer: { Text("Removing a project keeps its files on disk.").font(.caption).foregroundStyle(.secondary) }
    }

    // MARK: Operations

    private func load() async {
        guard let project else { return }
        name = group?.displayName ?? project.name
        await settings.load(project, force: true)
        guard project.clone.map({ !$0.isReady }) != true else { file = nil; return }
        let path = project.path
        let document = await Task.detached { () -> ProjectConfigurationDocument? in
            let files = WorkspaceFileService(root: URL(fileURLWithPath: path))
            let value = try? await ProjectConfigurationService.load(using: files)
            await files.close(); return value
        }.value
        if !Task.isCancelled { file = document }
    }
    private func change(_ update: @escaping @Sendable (inout ProjectSettingsDocument) throws -> Void) {
        guard let project, !saving else { return }
        saving = true; error = nil
        Task {
            defer { saving = false }
            do { try await settings.update(project, update) } catch { self.error = error.localizedDescription }
        }
    }
    private func importScripts(_ scripts: [ProjectScript]) {
        change { document in
            var actions = document.actions ?? []
            for script in ProjectActions.importable(scripts, existing: actions) { actions = try ProjectActions.adding(.init(script: script), to: actions) }
            document.actions = actions
        }
    }
    private func move(_ index: Int, by offset: Int) {
        change { document in
            guard let actions = document.actions, actions.indices.contains(index), actions.indices.contains(index + offset) else { return }
            document.actions = ProjectActions.moving(actions, fromOffsets: [index], toOffset: offset > 0 ? index + offset + 1 : index + offset)
        }
    }
    private func rename(_ project: WorkspaceProject) {
        let title = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty else { return }
        if let group, group.memberProjectIDs.count > 1 { store.renameProjectGroup(group, title: title) }
        else { store.renameProject(project.id, title: title) }
        settings.invalidateIcons(for: project)
    }
    private func chooseImage(_ project: WorkspaceProject) {
        let panel = NSOpenPanel()
        panel.directoryURL = URL(fileURLWithPath: project.path); panel.canChooseDirectories = false; panel.allowsMultipleSelection = false
        panel.allowedContentTypes = [.image]; panel.message = String(localized: "Choose an image inside this checkout.")
        guard panel.runModal() == .OK, let url = panel.url?.standardizedFileURL.resolvingSymlinksInPath() else { return }
        let root = URL(fileURLWithPath: project.path).standardizedFileURL.resolvingSymlinksInPath().path
        guard url.path.hasPrefix(root + "/") else { error = String(localized: "Choose an image inside this project’s checkout."); return }
        let relative = String(url.path.dropFirst(root.count + 1))
        change { $0.icon = .image(path: relative) }
    }
}
