import CoincideRemoteKit
import SwiftUI

/// The app's tabs along the bottom, in Liquid Glass: Bots, Projects and Chats from the Mac's sidebar, Settings, and a
/// search tab that finds any thread or bot. On iPad the same tabs become a sidebar.
struct MainTabView: View {
    @Environment(RemoteClient.self) private var client
    @Environment(Navigator.self) private var navigator

    var body: some View {
        @Bindable var navigator = navigator
        TabView(selection: $navigator.tab) {
            Tab("Bots", systemImage: "face.smiling", value: AppTab.bots) {
                stack(.bots) { BotsView() }
            }
            Tab("Projects", systemImage: "folder", value: AppTab.projects) {
                stack(.projects) { ProjectsView() }
            }
            Tab("Chats", systemImage: "bubble.left.and.bubble.right", value: AppTab.chats) {
                stack(.chats) { ChatsView() }
            }
            Tab("Settings", systemImage: "gearshape", value: AppTab.settings) {
                NavigationStack { SettingsView() }
            }
            Tab(value: AppTab.search, role: .search) {
                stack(.search) { SearchView() }
            }
        }
        .tabViewStyle(.sidebarAdaptable)
        .tabBarMinimizeBehavior(.onScrollDown)
        .onAppear(perform: wire)
        .onChange(of: client.workspace) { wire() }
        .onChange(of: navigator.recent) { _, recent in
            // Keep the last few threads following the Mac; stop the rest.
            for id in client.threads.keys where !recent.prefix(4).contains(id) { client.close(id) }
        }
        .onChange(of: navigator.newThreadRequests) { Task { await newThreadForShortcut() } }
        .modifier(ThreadActionDialogs())
        #if DEBUG
        // Testing in the simulator without taps: open the first thread once the workspace arrives.
        .onChange(of: client.workspace.threads.first?.id) { _, id in
            if ProcessInfo.processInfo.arguments.contains("-CoincideRemoteOpenFirstThread"), navigator.selection == nil, let id {
                navigator.open(id)
            }
        }
        #endif
    }

    private func stack<Content: View>(_ tab: AppTab, @ViewBuilder root: () -> Content) -> some View {
        NavigationStack(path: navigator.path(tab)) {
            root()
                .navigationDestination(for: Route.self) { route in
                    switch route {
                    case .thread(let id): ThreadContainer(threadID: id)
                    case .project(let id): ProjectThreadsView(projectID: id)
                    case .bot(let id): BotConversationsView(botID: id)
                    }
                }
        }
    }

    /// Teaches the navigator where each thread lives, so an alert or a shortcut opens it under the right tab.
    private func wire() {
        navigator.locate = { [client] id in
            if let bot = client.workspace.bots?.first(where: { $0.threadIDs.contains(id) }) {
                return (.bots, bot.threadIDs.first == id ? nil : .bot(bot.id))
            }
            guard let thread = client.summary(id), let project = client.project(thread.projectID), !project.isChats else {
                return (.chats, nil)
            }
            return (.projects, .project(project.id))
        }
    }

    /// ⌘N: a thread in the project on screen, a new conversation with the bot on screen, or a chat.
    private func newThreadForShortcut() async {
        let routes = navigator.paths[navigator.tab] ?? []
        for route in routes.reversed() {
            switch route {
            case .project(let id):
                if let thread = await client.newThread(in: id) { navigator.push(.thread(thread)) }
                return
            case .bot(let id):
                if let thread = await client.newBotConversation(id) { navigator.push(.thread(thread)) }
                return
            case .thread(let id):
                if let bot = client.workspace.bots?.first(where: { $0.threadIDs.contains(id) }) {
                    if let thread = await client.newBotConversation(bot.id) { navigator.push(.thread(thread)) }
                    return
                }
                if let project = client.summary(id).flatMap({ client.project($0.projectID) }), !project.isChats {
                    if let thread = await client.newThread(in: project.id) { navigator.push(.thread(thread)) }
                    return
                }
            }
        }
        if let thread = await client.newThread(in: nil) {
            navigator.tab = .chats
            navigator.paths[.chats] = [.thread(thread)]
        }
    }
}

// MARK: Projects

/// The Mac's projects, with its Pinned threads first.
struct ProjectsView: View {
    @Environment(RemoteClient.self) private var client
    @Environment(Navigator.self) private var navigator
    @Environment(\.theme) private var theme
    @AppStorage("sidebar.showsHidden") private var showsHidden = false

    var body: some View {
        let filter = ThreadFilter(showsHidden: showsHidden, keeping: navigator.selection)
        let projects = client.workspace.projects.filter { !$0.isChats }
        let pinned = pinnedThreads(filter)
        List {
            ConnectionStatusRow()
                .listRowBackground(Color.clear)
            if !pinned.isEmpty {
                Section("Pinned") {
                    ForEach(pinned) { thread in
                        NavigationLink(value: Route.thread(thread.id)) { ThreadRow(thread: thread, showsProject: true) }
                    }
                }
            }
            Section {
                ForEach(projects) { project in
                    NavigationLink(value: Route.project(project.id)) {
                        ProjectRow(project: project, threads: filter.visible(threads(in: project)))
                    }
                    .contextMenu {
                        Button {
                            Task { if let id = await client.newThread(in: project.id) { navigator.open(id) } }
                        } label: {
                            Label("New Thread", systemImage: "square.and.pencil")
                        }
                        .disabled(!client.isConnected)
                    }
                }
            } header: {
                if !pinned.isEmpty { Text("Projects") }
            }
        }
        .overlay {
            if projects.isEmpty, client.isConnected {
                ContentUnavailableView(
                    "No Projects", systemImage: "folder",
                    description: Text("Add a project on your Mac and it shows up here."))
            }
        }
        .themedList(theme)
        .refreshable { await client.refreshWorkspace() }
        .navigationTitle("Projects")
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) { ThreadFilterMenu() }
        }
    }

    private func threads(in project: RemoteProject) -> [RemoteThreadSummary] {
        client.workspace.threads.filter { $0.projectID == project.id }
    }

    private func pinnedThreads(_ filter: ThreadFilter) -> [RemoteThreadSummary] {
        let order = client.workspace.pinnedOrder
        guard client.workspace.sections.contains("pinned") else { return [] }
        return filter.visible(client.workspace.threads.filter(\.isPinned)).sorted { lhs, rhs in
            (order.firstIndex(of: lhs.id) ?? .max) < (order.firstIndex(of: rhs.id) ?? .max)
        }
    }
}

/// A project at a glance: its name and folder, how many threads, and whether any is working, waiting or unread.
struct ProjectRow: View {
    let project: RemoteProject
    let threads: [RemoteThreadSummary]
    @Environment(\.theme) private var theme

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "folder.fill")
                .font(.title3)
                .foregroundStyle(theme.secondaryInk)
                .frame(width: 28)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(project.name)
                    .font(.body.weight(.medium))
                    .foregroundStyle(theme.ink)
                    .lineLimit(1)
                Text(project.path)
                    .font(.caption)
                    .foregroundStyle(theme.secondaryInk)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            Spacer(minLength: 8)
            ProjectActivity(threads: threads)
        }
        .padding(.vertical, 4)
        .accessibilityElement(children: .combine)
    }
}

/// The busiest state among some threads, and how many there are.
struct ProjectActivity: View {
    let threads: [RemoteThreadSummary]
    @Environment(\.theme) private var theme

    var body: some View {
        HStack(spacing: 8) {
            if threads.contains(where: \.needsUser) {
                Image(systemName: "hand.raised.fill").foregroundStyle(.orange).accessibilityLabel(Text("Waiting for you"))
            } else if threads.contains(where: \.isRunning) {
                ProgressView().controlSize(.small).accessibilityLabel(Text("Working"))
            } else if threads.contains(where: { $0.unseen != nil }) {
                Circle().fill(.green).frame(width: 8, height: 8).accessibilityLabel(Text("Unread"))
            }
            if !threads.isEmpty {
                Text(threads.count, format: .number)
                    .font(.callout.monospacedDigit())
                    .foregroundStyle(theme.secondaryInk)
            }
        }
    }
}

/// One project's threads, in the Mac's order.
struct ProjectThreadsView: View {
    let projectID: UUID
    @Environment(RemoteClient.self) private var client
    @Environment(Navigator.self) private var navigator
    @Environment(\.theme) private var theme
    @AppStorage("sidebar.showsHidden") private var showsHidden = false

    var body: some View {
        let project = client.project(projectID)
        let threads = ThreadFilter(showsHidden: showsHidden, keeping: navigator.selection)
            .visible(client.workspace.threads.filter { $0.projectID == projectID && !$0.isPinned })
        List {
            ConnectionStatusRow()
                .listRowBackground(Color.clear)
            ForEach(threads) { thread in
                NavigationLink(value: Route.thread(thread.id)) { ThreadRow(thread: thread) }
            }
        }
        .overlay {
            if threads.isEmpty {
                ContentUnavailableView {
                    Label("No Threads", systemImage: "text.bubble")
                } description: {
                    Text("Start one here or on your Mac.")
                } actions: {
                    Button("New Thread") { Task { await newThread() } }
                        .buttonStyle(.glassProminent)
                        .disabled(!client.isConnected)
                }
            }
        }
        .themedList(theme)
        .refreshable { await client.refreshWorkspace() }
        .navigationTitle(project?.name ?? String(localized: "Project"))
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) { ThreadFilterMenu() }
            ToolbarItem(placement: .topBarTrailing) {
                Button { Task { await newThread() } } label: {
                    Label("New Thread", systemImage: "square.and.pencil")
                }
                .disabled(!client.isConnected)
            }
        }
    }

    private func newThread() async {
        if let id = await client.newThread(in: projectID) { navigator.push(.thread(id)) }
    }
}

// MARK: Chats

/// Chats: threads that belong to no project.
struct ChatsView: View {
    @Environment(RemoteClient.self) private var client
    @Environment(Navigator.self) private var navigator
    @Environment(\.theme) private var theme
    @AppStorage("sidebar.showsHidden") private var showsHidden = false

    var body: some View {
        let chatsIDs = Set(client.workspace.projects.filter(\.isChats).map(\.id))
        let threads = ThreadFilter(showsHidden: showsHidden, keeping: navigator.selection)
            .visible(client.workspace.threads.filter { chatsIDs.contains($0.projectID) })
        List {
            ConnectionStatusRow()
                .listRowBackground(Color.clear)
            ForEach(threads) { thread in
                NavigationLink(value: Route.thread(thread.id)) { ThreadRow(thread: thread) }
            }
        }
        .overlay {
            if threads.isEmpty, client.isConnected {
                ContentUnavailableView {
                    Label("No Chats", systemImage: "bubble.left.and.bubble.right")
                } description: {
                    Text("Chats are threads outside any project.")
                } actions: {
                    Button("New Chat") { Task { await newChat() } }
                        .buttonStyle(.glassProminent)
                }
            }
        }
        .themedList(theme)
        .refreshable { await client.refreshWorkspace() }
        .navigationTitle("Chats")
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) { ThreadFilterMenu() }
            ToolbarItem(placement: .topBarTrailing) {
                Button { Task { await newChat() } } label: {
                    Label("New Chat", systemImage: "square.and.pencil")
                }
                .disabled(!client.isConnected)
            }
        }
    }

    private func newChat() async {
        if let id = await client.newThread(in: nil) { navigator.push(.thread(id)) }
    }
}

// MARK: Search

/// Finds any thread or bot by name. With nothing typed, the latest threads.
struct SearchView: View {
    @Environment(RemoteClient.self) private var client
    @Environment(Navigator.self) private var navigator
    @Environment(\.theme) private var theme

    var body: some View {
        @Bindable var navigator = navigator
        let query = navigator.searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        let bots = (client.workspace.bots ?? []).filter { !query.isEmpty && $0.name.localizedStandardContains(query) }
        let threads = matches(query)
        List {
            if !bots.isEmpty {
                Section("Bots") {
                    ForEach(bots) { bot in
                        Button { Task { await BotOpening.open(bot, client: client, navigator: navigator) } } label: {
                            BotRow(bot: bot)
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
            Section(query.isEmpty ? "Recent" : "Threads") {
                ForEach(threads) { thread in
                    NavigationLink(value: Route.thread(thread.id)) { ThreadRow(thread: thread, showsProject: true) }
                }
            }
        }
        .overlay {
            if !query.isEmpty, bots.isEmpty, threads.isEmpty {
                ContentUnavailableView.search(text: query)
            }
        }
        .themedList(theme)
        .navigationTitle("Search")
        .searchable(text: $navigator.searchText, prompt: "Threads and bots")
    }

    private func matches(_ query: String) -> [RemoteThreadSummary] {
        let all = client.workspace.threads
        guard !query.isEmpty else {
            return Array(all.filter { !$0.isHidden }.sorted { $0.updatedAt > $1.updatedAt }.prefix(15))
        }
        return all.filter { $0.title.localizedStandardContains(query) }.sorted { $0.updatedAt > $1.updatedAt }
    }
}

extension View {
    /// A list on the theme's own background: its content color in dark themes and its sidebar's quieter tone in light
    /// ones, so the cards stand out as the Mac's grouped settings do.
    func themedList(_ theme: Theme) -> some View {
        listStyle(.insetGrouped)
            .scrollContentBackground(.hidden)
            .background(theme.isDark ? theme.content : theme.sidebar)
    }
}
