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
        // The composer sits where the tab bar would, as in Messages.
        .toolbarVisibility(.hidden, for: .tabBar)
    }
}

/// One entry of the transcript as drawn: an item, a group of tool calls, or what a turn changed.
enum TranscriptBlock: Identifiable {
    case item(RemoteItem)
    case work([RemoteItem])
    case changes(turnID: UUID, files: [RemoteChangedFile])

    var id: String {
        switch self {
        case .item(let item): item.id.uuidString
        case .work(let items): "work-" + (items.first?.id.uuidString ?? "")
        case .changes(let turnID, _): "changes-" + turnID.uuidString
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

        func flushWork() {
            if !work.isEmpty { blocks.append(.work(work)) }
            work = []
        }
        func closeTurn() {
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

struct WorkingIndicator: View {
    let turn: RemoteTurnState
    @Environment(\.theme) private var theme

    var body: some View {
        HStack(spacing: 8) {
            ProgressView().controlSize(.small)
            if let started = turn.startedAt {
                Text(turn.isStarting ? "Starting…" : "Working")
                    .foregroundStyle(theme.secondaryInk)
                Text(started, style: .timer)
                    .monospacedDigit()
                    .foregroundStyle(theme.secondaryInk)
            } else {
                Text("Working").foregroundStyle(theme.secondaryInk)
            }
        }
        .font(.callout)
        .accessibilityElement(children: .combine)
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
