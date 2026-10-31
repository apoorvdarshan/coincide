import CoincideRemoteKit
import SwiftUI

/// The Mac sidebar's sort and limit menus ("Sort Projects By", "Sort Threads By", "Threads per Project", "Sort Chats
/// By", "Sort Bots By"), for a list's options menu. They change the Mac's sidebar too, and the phone follows its order.
/// An older Mac sends no options, and the menus don't show.
struct SidebarSortMenus: View {
    enum Kind {
        case projects, chats, bots
    }

    let kind: Kind
    @Environment(RemoteClient.self) private var client

    var body: some View {
        if let options = client.workspace.sidebar {
            switch kind {
            case .projects:
                sortMenu(String(localized: "Sort Projects By"), RemoteSidebarOptions.projectSorts, options.projectSort) {
                    $0.projectSort = $1
                }
                sortMenu(String(localized: "Sort Threads By"), RemoteSidebarOptions.threadSorts, options.threadSort) {
                    $0.threadSort = $1
                }
                limitMenu(options)
            case .chats:
                sortMenu(String(localized: "Sort Chats By"), RemoteSidebarOptions.threadSorts, options.chatSort) { $0.chatSort = $1 }
            case .bots:
                sortMenu(String(localized: "Sort Bots By"), RemoteSidebarOptions.botSorts, options.botSort) { $0.botSort = $1 }
            }
        }
    }

    private func sortMenu(
        _ title: String, _ sorts: [String], _ current: String, apply: @escaping (inout RemoteSidebarOptions, String) -> Void
    ) -> some View {
        Menu {
            Picker(title, selection: Binding(get: { current }, set: { sort in change { apply(&$0, sort) } })) {
                ForEach(sorts, id: \.self) { sort in Text(Self.title(of: sort)).tag(sort) }
            }
            .pickerStyle(.inline)
        } label: {
            Label(title, systemImage: "arrow.up.arrow.down")
        }
    }

    /// Fit (nil, sent as -1 here), the Mac's fixed counts, a count chosen on the Mac, and All (0).
    private func limitMenu(_ options: RemoteSidebarOptions) -> some View {
        let current = options.threadsPerProject ?? -1
        let counts = Set(RemoteSidebarOptions.threadLimits + [current].filter { $0 > 0 }).sorted()
        return Menu {
            Picker(
                String(localized: "Threads per Project"),
                selection: Binding(get: { current }, set: { count in change { $0.threadsPerProject = count < 0 ? nil : count } })
            ) {
                Text("Fit to Sidebar").tag(-1)
                ForEach(counts, id: \.self) { count in Text(count.formatted()).tag(count) }
                Text("All").tag(0)
            }
            .pickerStyle(.inline)
        } label: {
            Label("Threads per Project", systemImage: "list.number")
        }
    }

    private func change(_ edit: (inout RemoteSidebarOptions) -> Void) {
        guard var options = client.workspace.sidebar else { return }
        edit(&options)
        Task { await client.setSidebarOptions(options) }
    }

    /// A sort's name, as the Mac's menus give it.
    static func title(of sort: String) -> String {
        switch sort {
        case "manual": String(localized: "Manual")
        case "recentActivity": String(localized: "Recent Activity")
        case "created": String(localized: "Date Created")
        case "name": String(localized: "Name")
        default: sort
        }
    }

    /// How many threads a project lists before "Show more", nil for all: the Mac's choice, or the phone's own when it
    /// fits the list to the window (or the Mac doesn't say).
    static func threadLimit(_ options: RemoteSidebarOptions?) -> Int? {
        RemoteLayout.threadLimit(threadsPerProject: options?.threadsPerProject, fitting: ProjectsView.threadLimit)
    }
}

/// What a project's menu opens: its defaults, its pull requests, or the question before removing it.
enum ProjectSheet: Identifiable {
    case defaults
    case pullRequests

    var id: String {
        switch self {
        case .defaults: "defaults"
        case .pullRequests: "pullRequests"
        }
    }
}

/// "Project Defaults…": what the project's new threads start with, as the Mac's sheet sets it. Existing threads keep
/// their settings.
struct ProjectDefaultsView: View {
    let project: RemoteProject
    @Environment(RemoteClient.self) private var client
    @Environment(\.dismiss) private var dismiss
    @Environment(\.theme) private var theme
    @State private var defaults: RemoteProjectDefaults?
    @State private var saving = false

    var body: some View {
        NavigationStack {
            Form {
                if let defaults = Binding($defaults) {
                    Group { fields(defaults) }.themedCards(theme)
                } else {
                    ProgressView().frame(maxWidth: .infinity).listRowBackground(Color.clear)
                }
            }
            .scrollContentBackground(.hidden)
            .background(theme.isDark ? theme.content : theme.sidebar)
            .navigationTitle("Project Defaults")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") { Task { await save() } }
                        .disabled(defaults == nil || saving || !client.isConnected)
                }
            }
            .task {
                if defaults == nil { defaults = await client.projectDefaults(project.id) }
                if defaults == nil { dismiss() }
            }
        }
    }

    @ViewBuilder
    private func fields(_ defaults: Binding<RemoteProjectDefaults>) -> some View {
        Section {
            Toggle("Use Global Defaults", isOn: defaults.usesGlobalDefaults)
                .toggleStyle(ThemedSwitchStyle())
        } footer: {
            Text("Applies to new threads in \(project.name). Existing threads keep their settings.")
        }
        if !defaults.wrappedValue.usesGlobalDefaults {
            Section("Model") {
                Picker("Agent", selection: defaults.provider) {
                    ForEach(client.workspace.providers) { option in Text(option.name).tag(option.id) }
                }
                .onChange(of: defaults.wrappedValue.provider) { _, provider in
                    let models = client.provider(provider)?.models ?? []
                    if !models.contains(where: { $0.id == defaults.wrappedValue.modelID }) {
                        defaults.wrappedValue.modelID = models.first?.id ?? ""
                        defaults.wrappedValue.effort = nil
                    }
                }
                let models = client.provider(defaults.wrappedValue.provider)?.models ?? []
                if !models.isEmpty {
                    Picker("Model", selection: defaults.modelID) {
                        ForEach(models) { model in Text(model.name).tag(model.id) }
                    }
                }
                if let model = models.first(where: { $0.id == defaults.wrappedValue.modelID }), !model.efforts.isEmpty {
                    Picker("Effort", selection: Binding(
                        get: { defaults.wrappedValue.effort ?? model.defaultEffort ?? model.efforts[0] },
                        set: { defaults.wrappedValue.effort = $0 })
                    ) {
                        ForEach(model.efforts, id: \.self) { effort in Text(ComposerControls.effortTitle(effort)).tag(effort) }
                    }
                }
            }
            Section("Permissions") {
                Picker("Permissions", selection: defaults.accessMode) {
                    Label("Ask for approval", systemImage: "lock").tag("approval")
                    Label("Full access", systemImage: "lock.open").tag("fullAccess")
                }
                .pickerStyle(.inline)
                .labelsHidden()
            }
            Section("Mode") {
                Picker("Mode", selection: defaults.interactionMode) {
                    Label("Build", systemImage: "hammer").tag("build")
                    Label("Plan", systemImage: "list.bullet.clipboard").tag("plan")
                }
                .pickerStyle(.inline)
                .labelsHidden()
            }
        }
    }

    private func save() async {
        guard let defaults else { return }
        saving = true
        defer { saving = false }
        if await client.saveProjectDefaults(defaults) != nil { dismiss() }
    }
}

/// Asks before removing a project, as the Mac's "Remove from Coincide…" does.
struct ProjectRemoval: ViewModifier {
    @Binding var project: RemoteProject?
    @Environment(RemoteClient.self) private var client

    func body(content: Content) -> some View {
        content.confirmationDialog(
            "Remove “\(project?.name ?? "")”?", isPresented: Binding(get: { project != nil }, set: { if !$0 { project = nil } }),
            titleVisibility: .visible
        ) {
            if let project {
                Button("Remove", role: .destructive) {
                    self.project = nil
                    Task { await client.removeProject(project.id) }
                }
            }
            Button("Cancel", role: .cancel) { project = nil }
        } message: {
            if let project {
                let count = client.workspace.threads.filter { $0.projectID == project.id }.count
                Text(
                    count == 0
                        ? String(localized: "The folder and its files are not changed.")
                        : String(localized: "Its \(count) threads will be deleted. The folder and its files are not changed."))
            }
        }
    }
}
