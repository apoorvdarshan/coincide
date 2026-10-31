import CoincideRemoteKit
import SwiftUI

/// Opens a thread's model and shows it.
struct ThreadContainer: View {
    let threadID: UUID
    @Environment(RemoteClient.self) private var client
    @Environment(Navigator.self) private var navigator
    @Environment(\.theme) private var theme

    var body: some View {
        Group {
            if let model = client.threads[threadID] {
                ThreadView(model: model)
            } else {
                ProgressView()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(theme.content)
            }
        }
        .task(id: threadID) { _ = client.thread(threadID) }
        .onAppear { navigator.noteOpened(threadID) }
        // The composer sits where the tab bar would, as in Messages. Side by side, the tabs stay for the list.
        .toolbarVisibility(navigator.isSplit ? .automatic : .hidden, for: .tabBar)
    }
}

/// The detail column before a thread is picked, side by side with the list.
struct NoThreadSelected: View {
    @Environment(\.theme) private var theme

    var body: some View {
        ContentUnavailableView {
            Label("No Thread Selected", systemImage: "bubble.left.and.text.bubble.right")
        } description: {
            Text("Pick a thread from the list, or start a new one.")
        }
        .foregroundStyle(theme.secondaryInk)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(theme.content)
    }
}

/// One entry of the transcript as drawn: an item, a group of tool calls, or what a turn changed.
enum TranscriptBlock: Identifiable {
    case item(RemoteItem)
    case work([RemoteItem])
    case changes(turnID: UUID, files: [RemoteChangedFile])
    /// Under a finished turn's last reply, as on the Mac: the agent, its model and the time.
    case footer(RemoteItem)

    var id: String {
        switch self {
        case .item(let item): item.id.uuidString
        case .work(let items): "work-" + (items.first?.id.uuidString ?? "")
        case .changes(let turnID, _): "changes-" + turnID.uuidString
        case .footer(let item): "footer-" + item.id.uuidString
        }
    }

    /// Groups consecutive tool calls and reasoning, as the Mac's work rows do, and puts each finished turn's changed
    /// files at its end.
    static func build(_ items: [RemoteItem], showsReasoning: Bool, changes: (UUID) -> [RemoteChangedFile], isRunning: Bool)
        -> [TranscriptBlock]
    {
        var blocks: [TranscriptBlock] = []
        var work: [RemoteItem] = []
        var turnID: UUID?
        var lastReply: RemoteItem?

        func flushWork() {
            if !work.isEmpty { blocks.append(.work(work)) }
            work = []
        }
        func closeTurn() {
            if let reply = lastReply { blocks.append(.footer(reply)) }
            lastReply = nil
            guard let id = turnID else { return }
            let files = changes(id)
            if !files.isEmpty { blocks.append(.changes(turnID: id, files: files)) }
        }

        for item in items {
            switch item.kind {
            case .tool:
                work.append(item)
            case .reasoning:
                if showsReasoning { work.append(item) }
            case .user where !item.steered:
                flushWork()
                closeTurn()
                turnID = item.id
                blocks.append(.item(item))
            default:
                flushWork()
                if item.kind == .assistant { lastReply = item }
                blocks.append(.item(item))
            }
        }
        flushWork()
        if !isRunning { closeTurn() }
        return blocks
    }
}

struct ThreadView: View {
    @Bindable var model: ThreadModel
    @Environment(RemoteClient.self) private var client
    @Environment(Navigator.self) private var navigator
    @Environment(\.theme) private var theme

    var body: some View {
        let blocks = TranscriptBlock.build(
            model.items, showsReasoning: client.server?.showsReasoning ?? true, changes: model.changes(forTurnOpenedBy:),
            isRunning: model.turn.isRunning)
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 14) {
                if model.hasEarlier {
                    Button {
                        Task { await client.loadEarlier(model.id) }
                    } label: {
                        if model.isLoadingEarlier { ProgressView() } else { Text("Show Earlier Messages") }
                    }
                    .buttonStyle(.glass)
                    .frame(maxWidth: .infinity)
                }
                ForEach(blocks) { block in
                    TranscriptBlockView(block: block, model: model)
                        .id(block.id)
                }
                if model.turn.isRunning {
                    WorkingIndicator(turn: model.turn)
                        .id("working")
                } else if let tasks = model.turn.backgroundTasks, !tasks.isEmpty {
                    BackgroundWork(tasks: tasks)
                        .id("background")
                }
                if model.items.isEmpty, !model.isLoading {
                    ContentUnavailableView("New Thread", systemImage: "bubble.left", description: Text("Send a message to start."))
                        .padding(.top, 60)
                }
            }
            .frame(maxWidth: 820, alignment: .leading)
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
            .frame(maxWidth: .infinity)
            .scrollTargetLayout()
        }
        .scrollPosition(id: scrollAnchor, anchor: .top)
        .defaultScrollAnchor(.bottom, for: .initialOffset)
        .defaultScrollAnchor(.bottom, for: .sizeChanges)
        .scrollDismissesKeyboard(.interactively)
        .background(theme.content)
        .overlay {
            if model.isLoading, model.items.isEmpty { ProgressView() }
            if model.isRemoved {
                ContentUnavailableView("Thread Deleted", systemImage: "trash", description: Text("This thread was deleted on the Mac."))
                    .background(theme.content)
            }
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            VStack(spacing: 8) {
                WaitingBanner(model: model)
                QueueStrip(model: model)
                ComposerView(model: model)
            }
            .frame(maxWidth: 860)
            .padding(.horizontal, 10)
            .padding(.bottom, 6)
        }
        .navigationTitle(model.summary?.title ?? "")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .principal) {
                ThreadTitle(model: model)
            }
            ToolbarItem(placement: .topBarTrailing) {
                if let summary = model.summary {
                    Menu {
                        ThreadActionsMenu(thread: summary)
                    } label: {
                        Label("Thread Actions", systemImage: "ellipsis")
                    }
                }
            }
        }
        .toolbarBackgroundVisibility(.automatic, for: .navigationBar)
        .onAppear { client.markSeen(model.id) }
        .onChange(of: model.items.count) { client.markSeen(model.id) }
    }

    private var scrollAnchor: Binding<String?> {
        Binding(
            get: { model.scrollAnchor.map { $0.uuidString } },
            set: { value in model.scrollAnchor = value.flatMap(UUID.init(uuidString:)) })
    }
}

struct ThreadTitle: View {
    let model: ThreadModel
    @Environment(RemoteClient.self) private var client
    @Environment(\.theme) private var theme

    var body: some View {
        VStack(spacing: 0) {
            Text(model.summary?.title ?? "")
                .font(.headline)
                .lineLimit(1)
            if let summary = model.summary {
                Text(subtitle(summary))
                    .font(.caption2)
                    .foregroundStyle(theme.secondaryInk)
                    .lineLimit(1)
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isHeader)
    }

    private func subtitle(_ summary: RemoteThreadSummary) -> String {
        var parts = [client.project(summary.projectID)?.name ?? ""]
        if let branch = summary.branch { parts.append(branch) }
        return parts.filter { !$0.isEmpty }.joined(separator: " · ")
    }
}

/// The bottom line while a turn runs, as on the Mac: "Thinking…" (or "Starting Claude Code…") beside a breathing dot in
/// the agent's color, and how long the turn has run.
struct WorkingIndicator: View {
    let turn: RemoteTurnState
    @Environment(\.theme) private var theme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        let provider = turn.provider ?? ""
        HStack(spacing: 10) {
            Circle()
                .fill(theme.agent(provider))
                .frame(width: 7, height: 7)
                .phaseAnimator(reduceMotion ? [1.0] : [1.0, 0.35]) { dot, opacity in dot.opacity(opacity) } animation: { _ in
                    .easeInOut(duration: 0.9)
                }
                .frame(width: 15)
            Text(turn.isStarting ? String(localized: "Starting \(AgentLogo.name(provider))…") : String(localized: "Thinking…"))
                .foregroundStyle(theme.secondaryInk)
            if let started = turn.startedAt, !turn.isStarting {
                Text(started, style: .timer)
                    .monospacedDigit()
                    .foregroundStyle(theme.tertiaryInk)
            }
        }
        .font(.subheadline)
        .accessibilityElement(children: .combine)
    }
}

/// What the thread's agents still run between turns, as the Mac lists it under the transcript: "Claude Code is running
/// 2 tasks in the background", then a line per subagent or command with what it does now and for how long it has run.
/// Updated live from the Mac's turn events.
struct BackgroundWork: View {
    let tasks: [RemoteBackgroundTask]
    @Environment(\.theme) private var theme

    var body: some View {
        let name = AgentLogo.name(tasks.first?.provider ?? "")
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 10) {
                Circle().fill(theme.agent(tasks.first?.provider)).frame(width: 7, height: 7).frame(width: 15)
                Text(tasks.count == 1
                    ? String(localized: "\(name) is working in the background")
                    : String(localized: "\(name) is running \(tasks.count) tasks in the background"))
                    .font(.subheadline)
                    .foregroundStyle(theme.secondaryInk)
            }
            .accessibilityElement(children: .combine)
            .accessibilityAddTraits(.isHeader)
            VStack(spacing: 2) {
                ForEach(tasks) { task in BackgroundTaskLine(task: task) }
            }
            .padding(4)
            .background(theme.card, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        }
    }
}

/// One background task: its kind's symbol, its title, "Subagent · fork · Running the tests", and its elapsed time.
struct BackgroundTaskLine: View {
    let task: RemoteBackgroundTask
    @Environment(\.theme) private var theme

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Image(systemName: Self.symbol(task.kind))
                .font(.caption.weight(.medium))
                .foregroundStyle(theme.tertiaryInk)
                .frame(width: 18)
            VStack(alignment: .leading, spacing: 1) {
                Text(Self.oneLine(task.title))
                    .font(.footnote)
                    .foregroundStyle(theme.ink)
                    .lineLimit(1)
                let detail = Self.detail(task)
                if !detail.isEmpty {
                    Text(detail)
                        .font(.caption)
                        .foregroundStyle(theme.secondaryInk)
                        .lineLimit(2)
                }
            }
            Spacer(minLength: 6)
            if let started = task.startedAt {
                TimelineView(.periodic(from: started, by: 1)) { context in
                    Text(Self.elapsed(context.date.timeIntervalSince(started)))
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(theme.tertiaryInk)
                }
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 7)
        .frame(minHeight: 44)
        .accessibilityElement(children: .combine)
    }

    /// "Subagent · fork · Running the tests", "Command", "Task", as the Mac words it.
    static func detail(_ task: RemoteBackgroundTask) -> String {
        let kind =
            switch task.kind {
            case .agent: String(localized: "Subagent")
            case .command: String(localized: "Command")
            case .other: String(localized: "Task")
            }
        return [kind, task.agentType, task.progress.map(oneLine)].compactMap { $0 }.filter { !$0.isEmpty }
            .joined(separator: " · ")
    }

    /// A background command's title is often a whole script; one line reads in the list.
    static func oneLine(_ text: String) -> String { text.split(whereSeparator: \.isWhitespace).joined(separator: " ") }

    static func symbol(_ kind: RemoteBackgroundTask.Kind) -> String {
        switch kind {
        case .agent: "person.2"
        case .command: "terminal"
        case .other: "circle.dashed"
        }
    }

    /// "42s", "1m 08s", "2h 05m", as the Mac's transcript counts.
    static func elapsed(_ interval: TimeInterval) -> String {
        let seconds = max(0, Int(interval))
        let minutes = seconds / 60
        if minutes == 0 { return "\(seconds)s" }
        let hours = minutes / 60
        if hours == 0 { return String(format: "%dm %02ds", minutes, seconds % 60) }
        return String(format: "%dh %02dm", hours, minutes % 60)
    }
}

/// Messages waiting for the running turn to finish.
struct QueueStrip: View {
    let model: ThreadModel
    @Environment(RemoteClient.self) private var client
    @Environment(\.theme) private var theme

    var body: some View {
        if !model.turn.queued.isEmpty {
            VStack(alignment: .leading, spacing: 6) {
                ForEach(model.turn.queued) { message in
                    HStack(spacing: 8) {
                        Image(systemName: "clock").foregroundStyle(theme.secondaryInk).accessibilityHidden(true)
                        Text(message.text.isEmpty ? String(localized: "\(message.imageCount) images") : message.text)
                            .lineLimit(2)
                            .font(.callout)
                        Spacer()
                        if model.turn.canSteer {
                            Button("Send Now") {
                                Task { await client.perform(.steerQueued(threadID: model.id, messageID: message.id)) }
                            }
                            .font(.callout)
                        }
                        Button {
                            Task { await client.perform(.removeQueued(threadID: model.id, messageID: message.id)) }
                        } label: {
                            Image(systemName: "xmark")
                        }
                        .accessibilityLabel(Text("Remove queued message"))
                    }
                    .buttonStyle(.borderless)
                    .accessibilityElement(children: .contain)
                    .accessibilityLabel(Text("Queued: \(message.text)"))
                }
            }
            .padding(12)
            .glassEffect(.regular, in: .rect(cornerRadius: 18))
        }
    }
}
