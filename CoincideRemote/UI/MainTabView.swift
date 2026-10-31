import CoincideRemoteKit
import SwiftUI

/// The app's tabs along the bottom, in Liquid Glass: Bots, Projects and Chats from the Mac's sidebar, Settings, and a
/// search tab that finds any thread or bot. On iPad the same tabs become a sidebar.
struct MainTabView: View {
    @Environment(RemoteClient.self) private var client
    @Environment(Navigator.self) private var navigator
    @Environment(\.horizontalSizeClass) private var sizeClass

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
        .onAppear {
            navigator.isSplit = sizeClass == .regular
            wire()
        }
        .onChange(of: sizeClass) { _, size in navigator.isSplit = size == .regular }
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

    /// A tab's screens: pushed one over another on a phone, or side by side (the list, then the open thread) where the
    /// window is wide, as on an iPad or an unfolded Duo. Both read the same path, so folding keeps the place.
    @ViewBuilder
    private func stack<Content: View>(_ tab: AppTab, @ViewBuilder root: () -> Content) -> some View {
        if sizeClass == .regular {
            NavigationSplitView {
                NavigationStack(path: navigator.listPath(tab)) {
                    root()
                        .navigationDestination(for: Route.self) { route in destination(route) }
                }
                .navigationSplitViewColumnWidth(min: 300, ideal: 360, max: 440)
            } detail: {
                NavigationStack {
                    if let id = navigator.detailThread(tab) {
                        ThreadContainer(threadID: id).id(id)
                    } else {
                        NoThreadSelected()
                    }
                }
            }
            .navigationSplitViewStyle(.balanced)
        } else {
            NavigationStack(path: navigator.path(tab)) {
                root()
                    .navigationDestination(for: Route.self) { route in destination(route) }
            }
        }
    }

    @ViewBuilder
    private func destination(_ route: Route) -> some View {
        switch route {
        case .thread(let id): ThreadContainer(threadID: id)
        case .bot(let id): BotConversationsView(botID: id)
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
            return (.projects, nil)
        }
    }

    /// ⌘N: a thread in the project of the thread on screen, a new conversation with the bot on screen, or a chat.
    private func newThreadForShortcut() async {
        let routes = navigator.paths[navigator.tab] ?? []
        for route in routes.reversed() {
            switch route {
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

/// The Mac sidebar's Pinned and Projects sections: each project expands in place to show its threads, and remembers
/// whether it's open, together with the Mac.
struct ProjectsView: View {
    @Environment(RemoteClient.self) private var client
    @Environment(Navigator.self) private var navigator
    @Environment(\.theme) private var theme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @AppStorage("sidebar.showsHidden") private var showsHidden = false
    /// Projects whose whole list shows, past "Show more".
    @State private var showsAll: Set<UUID> = []

    /// Threads a project lists before "Show more".
    static let threadLimit = 6

    var body: some View {
        let filter = ThreadFilter(showsHidden: showsHidden, keeping: navigator.selection)
        let projects = client.workspace.projects.filter { !$0.isChats }
        let pinned = pinnedThreads(filter)
        List {
            ConnectionStatusRow()
            if !pinned.isEmpty {
                SidebarHeader(Text("Pinned")).sidebarRow()
                ForEach(pinned) { thread in
                    ThreadLink(thread: thread, place: client.project(thread.projectID)?.name)
                }
            }
            // Under Pinned, a heading tells the projects apart; on their own, the title says it.
            if !pinned.isEmpty, !projects.isEmpty {
                SidebarHeader(Text("Projects")).sidebarRow()
            }
            ForEach(projects) { project in
                let threads = filter.visible(client.workspace.threads.filter { $0.projectID == project.id && !$0.isPinned })
                let isExpanded = client.isExpanded(project)
                ProjectRow(project: project, isExpanded: isExpanded, hiddenStatus: isExpanded ? nil : SidebarStatus.strongest(threads)) {
                    toggle(project)
                }
                if isExpanded { children(of: project, threads: threads) }
            }
        }
        .sidebarList(theme)
        .overlay {
            if projects.isEmpty, pinned.isEmpty, client.isConnected {
                ContentUnavailableView {
                    Label("No Projects", systemImage: "folder")
                } description: {
                    Text("Add a project on your Mac and it shows up here.")
                }
                .foregroundStyle(theme.secondaryInk)
            }
        }
        .refreshable { await client.refreshWorkspace() }
        .navigationTitle("Projects")
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) { ThreadFilterMenu() }
        }
    }

    /// A project's threads under it, cut at the limit with "Show more", as on the Mac.
    @ViewBuilder
    private func children(of project: RemoteProject, threads: [RemoteThreadSummary]) -> some View {
        if threads.isEmpty {
            SidebarNote(text: String(localized: "No threads yet"))
                .padding(.leading, ProjectRow.nestedIndent + 10)
                .frame(minHeight: 36)
                .sidebarRow()
        } else {
            let all = showsAll.contains(project.id) || threads.count <= Self.threadLimit + 1
            let visible = all ? threads : Array(threads.prefix(Self.threadLimit))
            ForEach(visible) { thread in ThreadLink(thread: thread, isNested: true) }
            if !all {
                let hidden = Array(threads.dropFirst(Self.threadLimit))
                Button { withAnimation(motion) { _ = showsAll.insert(project.id) } } label: {
                    SidebarNote(
                        text: String(localized: "Show \(hidden.count) more"), symbol: "chevron.down",
                        status: SidebarStatus.strongest(hidden)
                    )
                    .padding(.leading, ProjectRow.nestedIndent)
                }
                .buttonStyle(SidebarRowButtonStyle())
                .sidebarRow()
            } else if showsAll.contains(project.id), threads.count > Self.threadLimit + 1 {
                Button { withAnimation(motion) { _ = showsAll.remove(project.id) } } label: {
                    SidebarNote(text: String(localized: "Show less"), symbol: "chevron.up")
                        .padding(.leading, ProjectRow.nestedIndent)
                }
                .buttonStyle(SidebarRowButtonStyle())
                .sidebarRow()
            }
        }
    }

    private var motion: Animation? { reduceMotion ? nil : .snappy(duration: 0.25) }

    private func toggle(_ project: RemoteProject) {
        let expanded = !client.isExpanded(project)
        withAnimation(motion) { client.setExpanded(project, expanded) }
    }

    private func pinnedThreads(_ filter: ThreadFilter) -> [RemoteThreadSummary] {
        let order = client.workspace.pinnedOrder
        guard client.workspace.sections.contains("pinned") else { return [] }
        return filter.visible(client.workspace.threads.filter(\.isPinned)).sorted { lhs, rhs in
            (order.firstIndex(of: lhs.id) ?? .max) < (order.firstIndex(of: rhs.id) ?? .max)
        }
    }
}

/// A project as the Mac's sidebar shows it: a disclosure triangle, its folder and name, and while collapsed, a dot for
/// the most pressing thing its threads are doing. Tap to expand or collapse; long-press or swipe to start a thread.
struct ProjectRow: View {
    let project: RemoteProject
    let isExpanded: Bool
    let hiddenStatus: SidebarStatus?
    let toggle: () -> Void
    @Environment(RemoteClient.self) private var client
    @Environment(Navigator.self) private var navigator
    @Environment(\.theme) private var theme
    @ScaledMetric(relativeTo: .callout) private var chevronWidth: CGFloat = 14

    /// How far a project's threads sit in, so their marks line up under its folder.
    static let nestedIndent: CGFloat = 22

    var body: some View {
        Button(action: toggle) {
            HStack(spacing: 8) {
                Image(systemName: "chevron.right")
                    .font(.caption2.weight(.bold))
                    .foregroundStyle(theme.tertiaryInk)
                    .rotationEffect(.degrees(isExpanded ? 90 : 0))
                    .frame(width: chevronWidth)
                Image(systemName: "folder")
                    .font(.subheadline)
                    .foregroundStyle(theme.secondaryInk)
                Text(project.name)
                    .font(.callout.weight(.semibold))
                    .foregroundStyle(theme.ink)
                    .lineLimit(1)
                Spacer(minLength: 4)
                if let color = hiddenStatus?.color(theme) { StatusDot(color: color) }
            }
        }
        .buttonStyle(SidebarRowButtonStyle())
        .contextMenu {
            Button { Task { await newThread() } } label: {
                Label("New Thread", systemImage: "square.and.pencil")
            }
            .disabled(!client.isConnected)
            Button(action: toggle) {
                Label(
                    isExpanded ? String(localized: "Collapse \(project.name)") : String(localized: "Expand \(project.name)"),
                    systemImage: isExpanded ? "chevron.up" : "chevron.down")
            }
        }
        .swipeActions(edge: .trailing) {
            Button { Task { await newThread() } } label: {
                Label("New Thread", systemImage: "square.and.pencil")
            }
            .tint(.indigo)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text([project.name, project.path, hiddenStatus?.label].compactMap(\.self).joined(separator: ", ")))
        .accessibilityValue(isExpanded ? Text("Expanded") : Text("Collapsed"))
        .accessibilityAddTraits(.isButton)
        .accessibilityAction(named: Text("New Thread in \(project.name)")) { Task { await newThread() } }
        .sidebarRow()
    }

    private func newThread() async {
        if let id = await client.newThread(in: project.id) { navigator.push(.thread(id)) }
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
            ForEach(threads) { thread in ThreadLink(thread: thread) }
        }
        .sidebarList(theme)
        .overlay {
            if threads.isEmpty, client.isConnected {
                ContentUnavailableView {
                    Label("No Chats", systemImage: "bubble.left.and.bubble.right")
                } description: {
                    Text("Chats are threads outside any project.")
                } actions: {
                    Button("New Chat") { Task { await newChat() } }
                        .prominentButton()
                }
                .foregroundStyle(theme.secondaryInk)
            }
        }
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
                SidebarHeader(Text("Bots")).sidebarRow()
                ForEach(bots) { bot in BotLink(bot: bot) }
            }
            if !threads.isEmpty {
                SidebarHeader(query.isEmpty ? Text("Recent") : Text("Threads")).sidebarRow()
                ForEach(threads) { thread in ThreadLink(thread: thread, place: place(of: thread)) }
            }
        }
        .sidebarList(theme)
        .overlay {
            if !query.isEmpty, bots.isEmpty, threads.isEmpty {
                ContentUnavailableView.search(text: query)
            }
        }
        .navigationTitle("Search")
        .searchable(text: $navigator.searchText, prompt: "Threads and bots")
    }

    private func place(of thread: RemoteThreadSummary) -> String? {
        guard let project = client.project(thread.projectID), !project.isChats else { return nil }
        return project.name
    }

    private func matches(_ query: String) -> [RemoteThreadSummary] {
        let all = client.workspace.threads
        guard !query.isEmpty else {
            return Array(all.filter { !$0.isHidden }.sorted { $0.updatedAt > $1.updatedAt }.prefix(15))
        }
        return all.filter { $0.title.localizedStandardContains(query) }.sorted { $0.updatedAt > $1.updatedAt }
    }
}
