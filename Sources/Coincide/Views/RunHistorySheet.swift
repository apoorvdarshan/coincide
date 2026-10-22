import CoincideCore
import SwiftUI

struct RunHistorySheet: View {
    let store: WorkspaceStore
    let threadID: UUID

    var body: some View {
        RunHistoryContent(thread: store.thread(threadID))
    }
}

struct RunHistoryContent: View {
    let thread: CodingThread?
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 5) {
                Text("Run History").font(.title2)
                if let thread {
                    Text(thread.title).foregroundStyle(.secondary).lineLimit(2)
                }
            }.padding(20)
            Divider()
            ScrollView {
                if let thread {
                    history(thread)
                } else {
                    ContentUnavailableView("Conversation unavailable", systemImage: "bubble.left",
                                           description: Text("This conversation is no longer in the workspace."))
                        .padding(20)
                }
            }.frame(minHeight: 180, idealHeight: 360, maxHeight: 420)
                .accessibilityIdentifier("run-history-records")
            Divider()
            HStack {
                Spacer()
                Button("Done") { dismiss() }.keyboardShortcut(.defaultAction)
                    .accessibilityIdentifier("run-history-done")
            }.padding(16)
        }
        .frame(minWidth: 320, idealWidth: 560, maxWidth: 680)
        .onExitCommand { dismiss() }
        .accessibilityIdentifier("run-history")
    }

    @ViewBuilder private func history(_ thread: CodingThread) -> some View {
        let records = RunHistoryPresentation.records(in: thread)
        if records.isEmpty {
            ContentUnavailableView("No recorded runs", systemImage: "clock",
                                   description: Text(RunHistoryPresentation.emptyDescription(thread)))
                .padding(20)
        } else {
            LazyVStack(alignment: .leading, spacing: 0) {
                if RunHistoryPresentation.hasUnrecordedMessages(in: thread) {
                    Text("Some messages do not include recorded run details.")
                        .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                        .padding(.top, 14).padding(.bottom, 4)
                        .accessibilityIdentifier("run-history-incomplete")
                }
                ForEach(records) { record in
                    RunHistoryRow(record: record, thread: thread).padding(.vertical, 14)
                    Divider()
                }
            }.padding(.horizontal, 20)
        }
    }
}

private struct RunHistoryRow: View {
    let record: ThreadRunRecord
    let thread: CodingThread

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(alignment: .firstTextBaseline) {
                Label(RunHistoryPresentation.status(record.status), systemImage: RunHistoryPresentation.symbol(record.status))
                    .font(.callout.weight(.medium))
                    .accessibilityIdentifier("run-history-status-\(record.id)")
                Spacer(minLength: 8)
                Text(record.startedAt, format: .dateTime.month(.abbreviated).day().hour().minute())
                    .font(.caption).foregroundStyle(.secondary)
            }
            Text(RunHistoryPresentation.prompt(record, in: thread))
                .font(.callout).lineLimit(3).textSelection(.enabled)
            Text("\(RunHistoryPresentation.provider(record.configuration)) · \(RunHistoryPresentation.model(record.configuration))")
                .font(.caption).foregroundStyle(.secondary).lineLimit(2).textSelection(.enabled)
            if RunHistoryPresentation.hasSavedAgentOptions(record.configuration) {
                Text("Saved agent options").font(.caption).foregroundStyle(.secondary)
            }
            Text(record.configuration.workspacePath).font(.caption.monospaced()).foregroundStyle(.secondary)
                .lineLimit(2).truncationMode(.middle).textSelection(.enabled)
                .accessibilityIdentifier("run-history-workspace-\(record.id)")
            if record.stopRequested {
                Text("Stop requested").font(.caption).foregroundStyle(.secondary)
            }
            DisclosureGroup("Details") {
                VStack(alignment: .leading, spacing: 8) {
                    LabeledContent("Origin", value: RunHistoryPresentation.origin(record.origin))
                    LabeledContent("Provider", value: RunHistoryPresentation.provider(record.configuration))
                    LabeledContent("Model", value: RunHistoryPresentation.model(record.configuration))
                    LabeledContent("Permissions") { Text(LocalizedStringKey(record.configuration.permission.title)) }
                    if let mode = record.configuration.agentModeID, !mode.isEmpty {
                        LabeledContent("Agent mode", value: mode)
                    }
                    LabeledContent("Started") {
                        Text(record.startedAt, format: .dateTime.year().month(.abbreviated).day().hour().minute().second())
                    }
                    if let endedAt = record.endedAt {
                        LabeledContent("Ended") {
                            Text(endedAt, format: .dateTime.year().month(.abbreviated).day().hour().minute().second())
                        }
                    }
                    if let reason = record.endReason {
                        LabeledContent("Outcome", value: RunHistoryPresentation.reason(reason))
                    }
                    if let reason = record.providerStopReason, !reason.isEmpty {
                        VStack(alignment: .leading, spacing: 3) {
                            Text("Provider stop reason").foregroundStyle(.secondary)
                            Text(reason).textSelection(.enabled)
                        }
                    }
                    Text(record.configuration.workspacePath).font(.caption.monospaced())
                        .fixedSize(horizontal: false, vertical: true).textSelection(.enabled)
                        .accessibilityLabel("Captured workspace")
                    if record.origin == .user {
                        Text(RunHistoryPresentation.prompt(record, in: thread))
                            .fixedSize(horizontal: false, vertical: true).textSelection(.enabled)
                    }
                    references
                }.font(.caption).padding(.top, 8)
            }.font(.caption)
        }.frame(minWidth: 0, maxWidth: .infinity, alignment: .leading)
            .accessibilityElement(children: .contain).accessibilityIdentifier("run-history-record-\(record.id)")
    }

    private var references: some View {
        DisclosureGroup("Recorded references") {
            VStack(alignment: .leading, spacing: 5) {
                Text("Session and turn references may be supplied by an adapter.")
                    .foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                LabeledContent("Run", value: record.id.uuidString)
                if let session = record.providerThreadID, !session.isEmpty {
                    LabeledContent("Session", value: session)
                }
                ForEach(record.turnIDs, id: \.self) { reference in
                    LabeledContent("Turn", value: reference)
                }
            }.textSelection(.enabled).padding(.top, 5)
        }
    }
}

enum RunHistoryPresentation {
    static func records(in thread: CodingThread) -> [ThreadRunRecord] {
        Array((thread.runHistory ?? []).reversed())
    }

    static func hasUnrecordedMessages(in thread: CodingThread) -> Bool {
        let recorded = Set((thread.runHistory ?? []).compactMap(\.userMessageID))
        return thread.messages.contains { $0.role == .user && !recorded.contains($0.id) }
    }

    static func emptyDescription(_ thread: CodingThread) -> String {
        thread.messages.isEmpty
            ? String(localized: "Runs will appear here after a message starts a coding agent.")
            : String(localized: "Earlier messages do not include recorded run details.")
    }

    static func prompt(_ record: ThreadRunRecord, in thread: CodingThread) -> String {
        switch record.origin {
        case .agent: return String(localized: "Agent-initiated run")
        case .legacy: return String(localized: "Earlier run — original prompt not recorded")
        case .user:
            guard let id = record.userMessageID,
                  let message = thread.messages.first(where: { $0.id == id && $0.role == .user }) else {
                return String(localized: "User message unavailable")
            }
            if message.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                return message.attachments?.isEmpty == false
                    ? String(localized: "Message with attachments") : String(localized: "Empty user message")
            }
            return message.text
        }
    }

    static func provider(_ configuration: ProviderConfiguration) -> String {
        configuration.provider == .acp ? configuration.acpAgent?.name ?? configuration.provider.name : configuration.provider.name
    }
    static func model(_ configuration: ProviderConfiguration) -> String {
        guard configuration.model.isEmpty else { return configuration.model }
        return hasSavedAgentOptions(configuration)
            ? String(localized: "Agent-managed model") : String(localized: "Default model")
    }
    static func hasSavedAgentOptions(_ configuration: ProviderConfiguration) -> Bool {
        configuration.provider == .acp &&
            (configuration.agentConfiguration?.isEmpty == false || configuration.agentConfigValues?.isEmpty == false)
    }
    static func origin(_ origin: ThreadRunOrigin) -> String {
        switch origin {
        case .user: String(localized: "User message")
        case .agent: String(localized: "Agent initiated")
        case .legacy: String(localized: "Earlier session")
        }
    }
    static func status(_ status: ThreadRunStatus) -> String {
        switch status {
        case .running: String(localized: "Running")
        case .awaitingApproval: String(localized: "Waiting for approval")
        case .completed: String(localized: "Completed")
        case .interrupted: String(localized: "Interrupted")
        case .failed: String(localized: "Failed")
        case .unknown: String(localized: "Outcome unknown")
        }
    }
    static func symbol(_ status: ThreadRunStatus) -> String {
        switch status {
        case .running: "play.circle"
        case .awaitingApproval: "hand.raised"
        case .completed: "checkmark.circle"
        case .interrupted: "pause.circle"
        case .failed: "exclamationmark.circle"
        case .unknown: "questionmark.circle"
        }
    }
    static func reason(_ reason: ThreadRunEndReason) -> String {
        switch reason {
        case .providerCompleted: String(localized: "Provider reported turn completion")
        case .providerActivity: String(localized: "Provider activity ended")
        case .providerFailure: String(localized: "Provider reported a failure")
        case .connectionLost: String(localized: "Provider connection closed")
        case .startFailed: String(localized: "Provider could not start")
        case .forcedStop: String(localized: "Forced stop")
        case .applicationClosed: String(localized: "App closed during the run")
        }
    }
}
