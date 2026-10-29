import CoincideRemoteKit
import SwiftUI

/// The Mac's sidebar on the phone: Bots, Pinned, each project, then Chats, with the Mac's order and status.
struct SidebarView: View {
    @Environment(RemoteClient.self) private var client
    @Environment(Navigator.self) private var navigator
    @Environment(\.theme) private var theme
    @AppStorage("sidebar.showsHidden") private var showsHidden = false
    @State private var collapsed: Set<UUID> = []

    var body: some View {
        @Bindable var navigator = navigator
        List(selection: $navigator.selection) {
            ConnectionStatusRow()
                .listRowBackground(Color.clear)
            if let bots = client.workspace.bots, !bots.isEmpty, !isSearching {
                Section("Bots") {
                    ForEach(bots) { bot in
                        ForEach(threads(bot.threadIDs)) { ThreadRow(thread: $0).tag($0.id) }
                    }
                }
            }
            // The Mac's sections in its order.
            ForEach(client.workspace.sections, id: \.self) { section in
                switch section {
                case "pinned":
                    let pinned = pinnedThreads
                    if !pinned.isEmpty {
                        Section("Pinned") {
                            ForEach(pinned) { ThreadRow(thread: $0, showsProject: true).tag($0.id) }
                        }
                    }
                case "projects":
                    ForEach(client.workspace.projects.filter { !$0.isChats }) { projectSection($0) }
                case "chats":
                    ForEach(client.workspace.projects.filter(\.isChats)) { projectSection($0) }
                default:
                    EmptyView()
                }
            }
        }
        .listStyle(.sidebar)
        .scrollContentBackground(.hidden)
        .background(theme.sidebar)
        .searchable(text: $navigator.searchText, isPresented: $navigator.isSearching, placement: .sidebar, prompt: "Search threads")
        .refreshable { await client.refreshWorkspace() }
        .navigationTitle(client.mac?.name ?? "Coincide")
        .toolbar {
            ToolbarItem(placement: .topBarLeading) {
                Button { navigator.showsSettings = true } label: {
                    Label("Settings", systemImage: "gearshape")
                }
            }
            ToolbarItemGroup(placement: .topBarTrailing) {
                Menu {
                    Toggle("Show Snoozed and Settled", isOn: $showsHidden)
                    Toggle("Show Archived", isOn: Bindable(client).includesArchived)
                } label: {
                    Label("Filter", systemImage: "line.3.horizontal.decrease")
                }
                Button { Task { await newChat() } } label: {
                    Label("New Chat", systemImage: "square.and.pencil")
                }
                .disabled(!client.isConnected)
            }
        }
        .onChange(of: navigator.newThreadRequests) { Task { await newThreadForShortcut() } }
    }

    private var isSearching: Bool { !navigator.searchText.trimmingCharacters(in: .whitespaces).isEmpty }

    /// Threads the list shows, in the Mac's order: what the Mac's list shows, narrowed by the search.
    private var visible: [RemoteThreadSummary] {
        let query = navigator.searchText.trimmingCharacters(in: .whitespaces)
        return client.workspace.threads.filter { thread in
            (showsHidden || isSearching || !thread.isHidden || thread.id == navigator.selection)
                && (query.isEmpty || thread.title.localizedStandardContains(query))
        }
    }

    private var pinnedThreads: [RemoteThreadSummary] {
        let pinned = visible.filter(\.isPinned)
        let order = client.workspace.pinnedOrder
        return pinned.sorted { lhs, rhs in
            (order.firstIndex(of: lhs.id) ?? .max) < (order.firstIndex(of: rhs.id) ?? .max)
        }
    }

    @ViewBuilder
    private func projectSection(_ project: RemoteProject) -> some View {
        let threads = visible.filter { $0.projectID == project.id && !$0.isPinned }
        if !isSearching || !threads.isEmpty {
            Section(isExpanded: expansion(project.id)) {
                ForEach(threads) { ThreadRow(thread: $0).tag($0.id) }
                if threads.isEmpty {
                    Text(project.isChats ? "No chats yet" : "No threads yet")
                        .font(.callout)
                        .foregroundStyle(theme.secondaryInk)
                }
            } header: {
                ProjectHeader(project: project)
            }
        }
    }

    private func threads(_ ids: [UUID]) -> [RemoteThreadSummary] {
        ids.compactMap { id in visible.first { $0.id == id } }
    }

    private func expansion(_ id: UUID) -> Binding<Bool> {
        Binding(
            get: { isSearching || !collapsed.contains(id) },
            set: { expanded in
                if expanded { collapsed.remove(id) } else { collapsed.insert(id) }
            })
    }

    private func newChat() async {
        if let id = await client.newThread(in: nil) { navigator.selection = id }
    }

    /// ⌘N: a thread in the open thread's project, or a chat.
    private func newThreadForShortcut() async {
        let projectID = navigator.selection.flatMap { client.summary($0)?.projectID }
        let project = projectID.flatMap { client.project($0) }
        if let id = await client.newThread(in: project?.isChats == false ? project?.id : nil) { navigator.selection = id }
    }
}

struct ProjectHeader: View {
    let project: RemoteProject
    @Environment(RemoteClient.self) private var client
    @Environment(Navigator.self) private var navigator
    @Environment(\.theme) private var theme

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: project.isChats ? "bubble.left.and.bubble.right" : "folder")
                .foregroundStyle(theme.secondaryInk)
                .accessibilityHidden(true)
            Text(project.name)
                .lineLimit(1)
            Spacer()
            Button {
                Task {
                    if let id = await client.newThread(in: project.isChats ? nil : project.id) { navigator.selection = id }
                }
            } label: {
                Image(systemName: "plus")
            }
            .buttonStyle(.borderless)
            .disabled(!client.isConnected)
            .accessibilityLabel(project.isChats ? Text("New Chat") : Text("New Thread in \(project.name)"))
            .hoverEffect()
        }
    }
}

struct ThreadRow: View {
    let thread: RemoteThreadSummary
    var showsProject = false
    @Environment(RemoteClient.self) private var client
    @Environment(\.theme) private var theme

    var body: some View {
        HStack(spacing: 10) {
            StatusMark(thread: thread)
                .frame(width: 20)
            VStack(alignment: .leading, spacing: 2) {
                Text(thread.title)
                    .font(.body.weight(thread.unseen != nil ? .semibold : .regular))
                    .foregroundStyle(theme.ink)
                    .lineLimit(1)
                Text(subtitle)
                    .font(.caption)
                    .foregroundStyle(theme.secondaryInk)
                    .lineLimit(1)
            }
            Spacer(minLength: 4)
            if thread.isPinned && !showsProject {
                Image(systemName: "pin.fill").font(.caption2).foregroundStyle(theme.secondaryInk)
                    .accessibilityHidden(true)
            }
        }
        .padding(.vertical, 2)
        .contentShape(Rectangle())
        .contextMenu { ThreadActionsMenu(thread: thread) }
        .swipeActions(edge: .leading) {
            Button { Task { await client.act(.pin(!thread.isPinned), on: thread.id) } } label: {
                Label(thread.isPinned ? "Unpin" : "Pin", systemImage: thread.isPinned ? "pin.slash" : "pin")
            }
            .tint(.orange)
        }
        .swipeActions(edge: .trailing) {
            Button { Task { await client.act(.archive(!thread.isArchived), on: thread.id) } } label: {
                Label(thread.isArchived ? "Unarchive" : "Archive", systemImage: "archivebox")
            }
            .tint(.indigo)
            .disabled(thread.isRunning && !thread.isArchived)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(accessibilityLabel)
        .hoverEffect(.highlight)
    }

    private var subtitle: String {
        var parts: [String] = []
        if showsProject, let project = client.project(thread.projectID) { parts.append(project.name) }
        parts.append(thread.selection.modelName)
        if let until = thread.snoozedUntil, until > Date() {
            parts.append(String(localized: "Snoozed until \(until.formatted(date: .omitted, time: .shortened))"))
        } else {
            parts.append(thread.updatedAt.formatted(.relative(presentation: .named, unitsStyle: .abbreviated)))
        }
        return parts.joined(separator: " · ")
    }

    private var accessibilityLabel: Text {
        var parts = [thread.title]
        if thread.isRunning { parts.append(String(localized: "Working")) }
        if thread.pendingApprovals > 0 { parts.append(String(localized: "Waiting for approval")) }
        if thread.pendingQuestions > 0 { parts.append(String(localized: "Has a question")) }
        if thread.unseen == "failed" { parts.append(String(localized: "Failed")) } else if thread.unseen != nil {
            parts.append(String(localized: "Unread"))
        }
        if thread.isPinned { parts.append(String(localized: "Pinned")) }
        parts.append(subtitle)
        return Text(parts.joined(separator: ", "))
    }
}

/// A thread's state at a glance: working, waiting for the user, unread or failed, or its agent.
struct StatusMark: View {
    let thread: RemoteThreadSummary
    @Environment(\.theme) private var theme

    var body: some View {
        if thread.needsUser {
            Image(systemName: thread.pendingApprovals > 0 ? "hand.raised.fill" : "questionmark.bubble.fill")
                .foregroundStyle(.orange)
                .symbolEffect(.pulse)
        } else if thread.isRunning {
            ProgressView().controlSize(.small)
        } else if thread.unseen == "failed" {
            Circle().fill(.red).frame(width: 8, height: 8)
        } else if thread.unseen != nil {
            Circle().fill(theme.accent).frame(width: 8, height: 8)
        } else {
            AgentLogo(provider: thread.selection.provider, size: 15)
        }
    }
}

/// The connection's state, with what to do about it.
struct ConnectionStatusRow: View {
    @Environment(RemoteClient.self) private var client
    @Environment(Navigator.self) private var navigator
    @Environment(\.theme) private var theme

    var body: some View {
        switch client.phase {
        case .connected:
            EmptyView()
        case .connecting(let name):
            Label {
                Text("Connecting to \(name)…")
            } icon: {
                ProgressView().controlSize(.small)
            }
            .font(.callout)
            .foregroundStyle(theme.secondaryInk)
        case .offline(let message):
            VStack(alignment: .leading, spacing: 6) {
                Label("Offline", systemImage: "wifi.exclamationmark").font(.headline).foregroundStyle(.orange)
                Text(message).font(.caption).foregroundStyle(theme.secondaryInk)
                Button("Try Again") { client.reconnectIfNeeded() }
                    .buttonStyle(.glass)
            }
            .padding(.vertical, 4)
        case .needsPairing(let message):
            VStack(alignment: .leading, spacing: 6) {
                Label("Pair Again", systemImage: "qrcode.viewfinder").font(.headline).foregroundStyle(.orange)
                Text(message).font(.caption).foregroundStyle(theme.secondaryInk)
                Button("Scan Pairing Code") { navigator.showsConnect = true }
                    .buttonStyle(.glassProminent)
            }
            .padding(.vertical, 4)
        case .idle:
            Button("Connect") { client.reconnectIfNeeded() }
        }
    }
}
