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

/// A thread in a sidebar list: tap to open it, long-press for its menu, swipe to pin or archive.
struct ThreadLink: View {
    let thread: RemoteThreadSummary
    /// Where it lives, shown quietly after the title where its list doesn't say (Pinned, Search).
    var place: String?
    /// Indented under its project, as on the Mac.
    var isNested = false
    @Environment(RemoteClient.self) private var client
    @Environment(Navigator.self) private var navigator

    var body: some View {
        Button { navigator.push(.thread(thread.id)) } label: {
            ThreadRow(thread: thread, place: place)
                .padding(.leading, isNested ? ProjectRow.nestedIndent : 0)
        }
        .buttonStyle(SidebarRowButtonStyle(isSelected: navigator.isSplit && navigator.selection == thread.id))
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
        .sidebarRow()
    }
}

/// One line per thread, as the Mac's sidebar draws it (`ThreadCell`): the agent's mark (a spinner while it works, a
/// shield while it waits), the title, then a badge, an unread dot, or how long ago it changed (how long it has been
/// working, in the agent's color, while it runs).
struct ThreadRow: View {
    let thread: RemoteThreadSummary
    var place: String?
    @Environment(\.theme) private var theme

    var body: some View {
        let status = SidebarStatus(thread)
        HStack(spacing: 8) {
            ThreadIcon(thread: thread, status: status)
            Text(thread.title)
                .font(.callout.weight(status == .completed || status == .failed ? .semibold : .regular))
                .foregroundStyle(thread.isArchived ? theme.secondaryInk : theme.ink)
                .lineLimit(1)
                .layoutPriority(1)
            if let place, !place.isEmpty {
                Text(place)
                    .font(.caption)
                    .foregroundStyle(theme.tertiaryInk)
                    .lineLimit(1)
            }
            Spacer(minLength: 4)
            accessories(status)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityLabel(status))
    }

    @ViewBuilder
    private func accessories(_ status: SidebarStatus) -> some View {
        HStack(spacing: 6) {
            if thread.isPinned {
                Image(systemName: "pin.fill").font(.caption2).foregroundStyle(theme.tertiaryInk)
            }
            if let snoozed = thread.snoozedUntil, snoozed > Date() {
                Image(systemName: "moon.zzz.fill").font(.caption2).foregroundStyle(theme.tertiaryInk)
            }
            switch status {
            case .approval(let count):
                StatusBadge(text: count > 1 ? String(localized: "Approval \(count)") : String(localized: "Approval"), color: .orange)
            case .question:
                StatusBadge(text: String(localized: "Question"), color: .orange)
            case .failed:
                StatusBadge(text: String(localized: "Failed"), color: .red)
            case .completed:
                StatusDot(color: .green)
                age
            case .running(let since?):
                TimelineView(.periodic(from: since, by: 1)) { context in
                    Text(Formatting.elapsed(since: since, now: context.date))
                        .font(.footnote.monospacedDigit())
                        .foregroundStyle(theme.agent(thread.selection.provider))
                }
            case .idle, .starting, .running(nil):
                age
            }
        }
        .fixedSize()
    }

    private var age: some View {
        TimelineView(.everyMinute) { context in
            Text(Formatting.compactAge(of: thread.updatedAt, now: context.date))
                .font(.footnote.monospacedDigit())
                .foregroundStyle(theme.secondaryInk)
        }
    }

    private func accessibilityLabel(_ status: SidebarStatus) -> Text {
        var parts = [thread.title]
        if let place, !place.isEmpty { parts.append(place) }
        if let label = status.label { parts.append(label) }
        if thread.isPinned { parts.append(String(localized: "Pinned")) }
        if let until = thread.snoozedUntil, until > Date() {
            parts.append(String(localized: "Snoozed until \(until.formatted(date: .omitted, time: .shortened))"))
        }
        parts.append(AgentLogo.name(thread.selection.provider) + ", " + thread.selection.modelName)
        if case .running(let since?) = status {
            parts.append(Formatting.elapsed(since: since))
        } else {
            parts.append(thread.updatedAt.formatted(.relative(presentation: .named)))
        }
        return Text(parts.joined(separator: ", "))
    }
}

/// The mark before a thread's title: its agent's logo, a spinner while it works (or works in the background), a shield
/// while it waits for an approval, a box once archived.
struct ThreadIcon: View {
    let thread: RemoteThreadSummary
    let status: SidebarStatus
    @Environment(\.theme) private var theme
    @ScaledMetric(relativeTo: .callout) private var size: CGFloat = 16

    var body: some View {
        Group {
            switch status {
            case .approval:
                Image(systemName: "exclamationmark.shield.fill").foregroundStyle(.orange)
            case .question:
                Image(systemName: "questionmark.bubble.fill").foregroundStyle(.orange)
            default:
                if status.isRunning || thread.hasBackgroundWork == true {
                    ProgressView().controlSize(.mini).tint(theme.secondaryInk)
                } else if thread.isArchived {
                    Image(systemName: "archivebox").foregroundStyle(theme.tertiaryInk)
                } else {
                    AgentLogo(provider: thread.selection.provider, size: size * 0.9)
                }
            }
        }
        .font(.footnote.weight(.medium))
        .frame(width: size + 2, height: size + 2)
        .accessibilityHidden(true)
    }
}

/// The connection's state, with what to do about it.
struct ConnectionStatusRow: View {
    @Environment(RemoteClient.self) private var client
    @Environment(Navigator.self) private var navigator
    @Environment(\.theme) private var theme

    var body: some View {
        Group {
            switch client.phase {
            case .connected:
                EmptyView()
            case .connecting(let name):
                Label {
                    Text("Connecting to \(name)…")
                } icon: {
                    ProgressView().controlSize(.small)
                }
                .font(.footnote)
                .foregroundStyle(theme.secondaryInk)
                .padding(.horizontal, 10)
                .frame(minHeight: 44)
            case .offline(let message):
                notice(title: Text("Offline"), symbol: "wifi.exclamationmark", message: message) {
                    Button("Try Again") { client.reconnectIfNeeded() }
                        .buttonStyle(.glass)
                }
            case .needsPairing(let message):
                notice(title: Text("Pair Again"), symbol: "qrcode.viewfinder", message: message) {
                    Button("Scan Pairing Code") { navigator.showsConnect = true }
                        .prominentButton()
                }
            case .idle:
                Button("Connect") { client.reconnectIfNeeded() }
                    .buttonStyle(.glass)
                    .padding(.horizontal, 10)
                    .frame(minHeight: 44)
            }
        }
        .sidebarRow()
    }

    private func notice<Action: View>(title: Text, symbol: String, message: String, @ViewBuilder action: () -> Action)
        -> some View
    {
        VStack(alignment: .leading, spacing: 8) {
            Label { title } icon: { Image(systemName: symbol) }
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(theme.ink)
            Text(message).font(.footnote).foregroundStyle(theme.secondaryInk)
            action()
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(theme.card, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .padding(.vertical, 6)
    }
}
