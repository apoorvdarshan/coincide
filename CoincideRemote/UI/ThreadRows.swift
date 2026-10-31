import CoincideRemoteKit
import SwiftUI

/// Which threads the lists show: what the Mac's sidebar shows, plus snoozed and settled ones when asked.
struct ThreadFilter {
    var showsHidden: Bool
    var keeping: UUID?

    func visible(_ threads: [RemoteThreadSummary]) -> [RemoteThreadSummary] {
        threads.filter { showsHidden || !$0.isHidden || $0.id == keeping }
    }
}

/// The lists' filter menu: snoozed and settled threads, and archived ones.
struct ThreadFilterMenu: View {
    @Environment(RemoteClient.self) private var client
    @AppStorage("sidebar.showsHidden") private var showsHidden = false

    var body: some View {
        Menu {
            Toggle("Show Snoozed and Settled", isOn: $showsHidden)
            Toggle("Show Archived", isOn: Bindable(client).includesArchived)
        } label: {
            Label("Filter", systemImage: showsHidden || client.includesArchived
                ? "line.3.horizontal.decrease.circle.fill" : "line.3.horizontal.decrease")
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
            .tint(.gray)
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
            // Green, as the Mac's sidebar marks a finished result.
            Circle().fill(.green).frame(width: 8, height: 8)
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
                Label("Offline", systemImage: "wifi.exclamationmark").font(.headline).foregroundStyle(theme.ink)
                Text(message).font(.caption).foregroundStyle(theme.secondaryInk)
                Button("Try Again") { client.reconnectIfNeeded() }
                    .buttonStyle(.glass)
            }
            .padding(.vertical, 4)
        case .needsPairing(let message):
            VStack(alignment: .leading, spacing: 6) {
                Label("Pair Again", systemImage: "qrcode.viewfinder").font(.headline).foregroundStyle(theme.ink)
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
