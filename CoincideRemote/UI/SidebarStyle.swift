import CoincideRemoteKit
import SwiftUI

// The Mac sidebar's look, for the phone's lists: flat rows on the theme's sidebar color, no cards or separators, a
// rounded highlight while pressed, quiet section headings with their buttons, and compact times. Sized for touch: every
// row is at least 44 points tall and the type follows Dynamic Type.

/// Short time labels, as the Mac's sidebar shows them (`Formatting` on the Mac).
enum Formatting {
    private static let compact: DateComponentsFormatter = {
        let formatter = DateComponentsFormatter()
        formatter.unitsStyle = .abbreviated
        formatter.maximumUnitCount = 1
        formatter.allowedUnits = [.year, .month, .weekOfMonth, .day, .hour, .minute]
        return formatter
    }()

    /// "now", "5m", "3h", "2d", "1w": how long ago.
    static func compactAge(of date: Date, now: Date = Date()) -> String {
        let elapsed = now.timeIntervalSince(date)
        guard elapsed >= 60 else { return String(localized: "now", comment: "Age of a thread updated less than a minute ago") }
        return compact.string(from: elapsed) ?? ""
    }

    /// "0:42", "12:05", "1:02:09": how long a turn has been running.
    static func elapsed(since start: Date, now: Date = Date()) -> String {
        let seconds = max(0, Int(now.timeIntervalSince(start)))
        let duration = Duration.seconds(seconds)
        return seconds >= 3600
            ? duration.formatted(.time(pattern: .hourMinuteSecond))
            : duration.formatted(.time(pattern: .minuteSecond))
    }
}

/// A thread's state as the Mac's sidebar ranks it (`ThreadRowModel.Status`), plus the questions the phone also answers.
enum SidebarStatus: Equatable {
    case idle
    case starting
    case running(since: Date?)
    case approval(count: Int)
    case question
    case failed
    case completed

    init(_ thread: RemoteThreadSummary) {
        if thread.pendingApprovals > 0 {
            self = .approval(count: thread.pendingApprovals)
        } else if thread.pendingQuestions > 0 {
            self = .question
        } else if thread.isStarting {
            self = .starting
        } else if thread.isRunning {
            self = .running(since: thread.runningSince)
        } else if thread.unseen == "failed" {
            self = .failed
        } else if thread.unseen != nil {
            self = .completed
        } else {
            self = .idle
        }
    }

    var isRunning: Bool {
        switch self {
        case .starting, .running: true
        default: false
        }
    }

    /// Which status a collapsed project or a "Show more" row shows for the threads it hides.
    var priority: Int {
        switch self {
        case .approval, .question: 5
        case .running: 4
        case .starting: 3
        case .failed: 2
        case .completed: 1
        case .idle: 0
        }
    }

    func color(_ theme: Theme) -> Color? {
        switch self {
        case .approval, .question: .orange
        case .starting, .running: theme.ink
        case .failed: .red
        case .completed: .green
        case .idle: nil
        }
    }

    var label: String? {
        switch self {
        case .idle: nil
        case .starting: String(localized: "Connecting")
        case .running: String(localized: "Working")
        case .approval: String(localized: "Waiting for approval")
        case .question: String(localized: "Has a question")
        case .failed: String(localized: "Failed")
        case .completed: String(localized: "Completed")
        }
    }

    /// The most urgent status among some threads, or nil when none needs a mark.
    static func strongest(_ threads: [RemoteThreadSummary]) -> SidebarStatus? {
        let strongest = threads.map(SidebarStatus.init).max { $0.priority < $1.priority }
        return strongest == .idle ? nil : strongest
    }
}

/// A row that highlights while pressed, as the Mac's sidebar rows do on hover and click: a rounded tint inset from the
/// edges, never the system's gray band.
struct SidebarRowButtonStyle: ButtonStyle {
    /// The row's thread is the one on screen beside the list.
    var isSelected = false
    @Environment(\.theme) private var theme

    func makeBody(configuration: Configuration) -> some View {
        let shape = RoundedRectangle(cornerRadius: 10, style: .continuous)
        configuration.label
            .padding(.horizontal, 10)
            // Room between rows once larger text outgrows the minimum height.
            .padding(.vertical, 3)
            .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
            .background {
                shape.fill(configuration.isPressed || isSelected ? theme.selection : .clear)
            }
            .contentShape(.rect)
            .contentShape(.hoverEffect, shape)
            .hoverEffect(.highlight)
    }
}

extension View {
    /// A list in the Mac sidebar's look: flat on the theme's sidebar color.
    func sidebarList(_ theme: Theme) -> some View {
        listStyle(.plain)
            .scrollContentBackground(.hidden)
            .background(theme.sidebar)
            .environment(\.defaultMinListRowHeight, 0)
    }

    /// One row of a sidebar list: no separator, no background of its own, and the sidebar's margins.
    func sidebarRow() -> some View {
        listRowInsets(EdgeInsets(top: 0, leading: 8, bottom: 0, trailing: 8))
            .listRowSeparator(.hidden)
            .listRowBackground(Color.clear)
    }

    /// A grouped settings list on the theme's colors: its sidebar tone behind, and cards in its surface color.
    func themedList(_ theme: Theme) -> some View {
        listStyle(.insetGrouped)
            .scrollContentBackground(.hidden)
            .background(theme.isDark ? theme.content : theme.sidebar)
    }

    /// Cards of a grouped list in the theme's raised color, for a `Section`, with switches that read on them.
    func themedCards(_ theme: Theme) -> some View {
        listRowBackground(theme.isDark ? theme.surface : theme.content)
            .toggleStyle(ThemedSwitchStyle())
    }
}

/// A section heading as the Mac's sidebar draws it: small, quiet and bold, with the section's buttons at the end.
struct SidebarHeader<Actions: View>: View {
    let title: Text
    @ViewBuilder var actions: Actions
    @Environment(\.theme) private var theme

    init(_ title: Text, @ViewBuilder actions: () -> Actions) {
        self.title = title
        self.actions = actions()
    }

    var body: some View {
        HStack(spacing: 2) {
            title
                .font(.footnote.weight(.semibold))
                .foregroundStyle(theme.secondaryInk)
                .accessibilityAddTraits(.isHeader)
            Spacer(minLength: 8)
            actions
                .labelStyle(.iconOnly)
                .font(.body.weight(.medium))
                .foregroundStyle(theme.secondaryInk)
                .buttonStyle(SidebarAccessoryButtonStyle())
        }
        .padding(.leading, 10)
        .padding(.top, 14)
        .frame(minHeight: 44, alignment: .bottom)
    }
}

extension SidebarHeader where Actions == EmptyView {
    init(_ title: Text) {
        self.init(title) { EmptyView() }
    }
}

/// A header's or row's borderless symbol button, with a full touch target.
struct SidebarAccessoryButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .frame(minWidth: 44, minHeight: 44)
            .contentShape(.rect)
            .opacity(configuration.isPressed ? 0.5 : 1)
    }
}

/// A small capsule such as "Approval" or "Failed", as on the Mac.
struct StatusBadge: View {
    let text: String
    let color: Color

    var body: some View {
        Text(text)
            .font(.caption2.weight(.semibold))
            .foregroundStyle(color)
            .padding(.horizontal, 7)
            .padding(.vertical, 2)
            .background(color.opacity(0.16), in: .capsule)
            .fixedSize()
    }
}

/// A filled dot for unseen results and the status a collapsed row hides.
struct StatusDot: View {
    let color: Color
    @ScaledMetric(relativeTo: .footnote) private var size: CGFloat = 7

    var body: some View {
        Circle().fill(color).frame(width: size, height: size)
    }
}

/// "Show 3 more", "Show less" and "No threads yet" under a project, quieter than a thread.
struct SidebarNote: View {
    let text: String
    var symbol: String?
    var status: SidebarStatus?
    @Environment(\.theme) private var theme

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: symbol ?? "circle")
                .font(.caption2.weight(.semibold))
                .foregroundStyle(theme.tertiaryInk)
                .frame(width: 18)
                .opacity(symbol == nil ? 0 : 1)
                .accessibilityHidden(true)
            Text(text)
                .font(.footnote)
                .foregroundStyle(theme.secondaryInk)
                .lineLimit(1)
            if let color = status?.color(theme) { StatusDot(color: color) }
            Spacer(minLength: 0)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(Text([text, status?.label].compactMap(\.self).joined(separator: ", ")))
    }
}
