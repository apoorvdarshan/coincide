import CoincideCore
import SwiftUI

struct ConversationHistoryReviewSheet: View {
    let store: WorkspaceStore
    let threadID: UUID
    let runID: UUID
    let kind: ConversationHistoryKind
    let close: () -> Void
    @State private var review: ConversationHistoryReview?
    @State private var title = ""
    @State private var loading = true
    @State private var accepting = false
    @State private var error: String?
    private var operation: ConversationHistoryOperation? { review.flatMap { store.conversationHistoryOperation($0.id) } }
    private var busy: Bool { accepting || operation.map(ConversationHistoryPresentation.isPending) == true }
    private var openingPrompt: String? {
        guard let thread = store.thread(threadID), let run = thread.runHistory?.first(where: { $0.id == runID }),
              let message = thread.messages.first(where: { $0.id == run.userMessageID }) else { return nil }
        return message.text.isEmpty ? String(localized: "Input with attachments") : message.text
    }

    var body: some View {
        ConversationHistoryReviewContent(review: review, kind: kind, title: $title, loading: loading,
                                         accepting: busy, error: error, operation: operation,
                                         openingPrompt: openingPrompt, confirm: confirm, close: close) {
            if let operation { ConversationHistoryOperationView(store: store, operation: operation) }
        }
        .interactiveDismissDisabled(busy)
        .task {
            do {
                let value = try await store.reviewConversationHistory(threadID: threadID, runID: runID, kind: kind)
                guard !Task.isCancelled else { store.discardConversationHistoryReview(value.id); return }
                review = value; title = value.suggestedTitle; loading = false
            } catch {
                guard !Task.isCancelled else { return }
                self.error = ConversationHistoryPresentation.error(error); loading = false
            }
        }
        .onDisappear { if let review { store.discardConversationHistoryReview(review.id) } }
    }

    private func confirm() {
        guard let review, !busy, operation == nil else { return }
        accepting = true; error = nil
        Task {
            defer { accepting = false }
            do { try await store.beginConversationHistory(review, title: kind == .forkAfterRun ? title : nil) }
            catch is CancellationError { error = String(localized: "The conversation changed. Close this review and choose the action again.") }
            catch { self.error = ConversationHistoryPresentation.error(error) }
        }
    }
}

struct ConversationHistoryReviewContent<Status: View>: View {
    let review: ConversationHistoryReview?
    let kind: ConversationHistoryKind
    @Binding var title: String
    let loading: Bool
    let accepting: Bool
    let error: String?
    let operation: ConversationHistoryOperation?
    var openingPrompt: String? = nil
    let confirm: () -> Void
    let close: () -> Void
    @ViewBuilder let status: () -> Status

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 6) {
                Text(ConversationHistoryPresentation.title(kind)).font(.title2)
                Text(kind == .forkAfterRun
                     ? String(localized: "Create a separate conversation through the end of this run. The source conversation and its draft stay unchanged.")
                     : String(localized: "Remove this run and later messages from the current conversation. Its run audit is retained; your current draft and settings stay unchanged."))
                    .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                Text("Workspace files and staging stay as they are.").font(.caption).foregroundStyle(.secondary)
            }.padding(20)
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    if loading { ProgressView("Checking conversation history…").frame(maxWidth: .infinity).padding() }
                    if let review {
                        let configuration = kind == .forkAfterRun ? review.targetConfiguration : review.sourceConfiguration
                        if let openingPrompt {
                            VStack(alignment: .leading, spacing: 5) {
                                Text("Selected run’s opening input").font(.caption).foregroundStyle(.secondary)
                                Text(openingPrompt).font(.callout).lineLimit(5).textSelection(.enabled)
                            }.frame(maxWidth: .infinity, alignment: .leading)
                        }
                        if kind == .forkAfterRun, operation == nil {
                            TextField("New conversation name", text: $title)
                                .accessibilityIdentifier("conversation-history-title").disabled(accepting)
                        }
                        LabeledContent("Provider", value: RunHistoryPresentation.provider(configuration))
                        LabeledContent("Model", value: RunHistoryPresentation.model(configuration))
                        LabeledContent("Permissions") { Text(LocalizedStringKey(configuration.permission.title)) }
                        Text(configuration.workspacePath).font(.caption.monospaced()).textSelection(.enabled)
                            .fixedSize(horizontal: false, vertical: true).accessibilityIdentifier("conversation-history-workspace")
                        LabeledContent("Messages kept", value: review.prefix.count.formatted())
                        if kind == .rewindBeforeRun { LabeledContent("Messages removed", value: review.removedMessageIDs.count.formatted()) }
                        DisclosureGroup("Verified boundary") {
                            VStack(alignment: .leading, spacing: 6) {
                                LabeledContent("Run", value: review.runID.uuidString)
                                LabeledContent("Provider conversation", value: review.sourceReference.nativeThreadID)
                                LabeledContent("Reviewed head", value: review.reviewedHeadTurnID)
                                switch review.boundary {
                                case .throughTurn(let id), .beforeTurn(let id):
                                    LabeledContent("Selected provider turn", value: id)
                                case .head:
                                    Text("Current provider head")
                                }
                                Text(kind == .forkAfterRun ? "Through the end of the selected run" : "Before the selected run’s opening message")
                            }.font(.caption).textSelection(.enabled).padding(.top, 6)
                        }
                    }
                    if let operation { status().id(operation.id) }
                    if let error { Text(error).font(.callout).foregroundStyle(.red).fixedSize(horizontal: false, vertical: true) }
                }.padding(20)
            }.frame(minHeight: 160, idealHeight: 300, maxHeight: 420)
            Divider()
            HStack {
                Spacer()
                Button(operation == nil ? "Cancel" : "Done", action: close).keyboardShortcut(.defaultAction)
                    .disabled(accepting).accessibilityIdentifier("conversation-history-close")
                if operation == nil {
                    Button(kind == .forkAfterRun ? "Fork Conversation" : "Rewind Conversation", role: kind == .rewindBeforeRun ? .destructive : nil, action: confirm)
                        .disabled(review == nil || accepting || (kind == .forkAfterRun && title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty))
                        .accessibilityIdentifier("conversation-history-confirm")
                }
            }.padding(16)
        }
        .frame(minWidth: 320, idealWidth: 560, maxWidth: 680)
        .onExitCommand { if !accepting { close() } }
        .accessibilityIdentifier("conversation-history-review")
    }
}

enum ConversationHistoryPresentation {
    static func title(_ kind: ConversationHistoryKind) -> String {
        kind == .forkAfterRun ? String(localized: "Fork After This Run") : String(localized: "Rewind Before This Run")
    }
    static func isPending(_ operation: ConversationHistoryOperation) -> Bool {
        operation.phase == .accepted || operation.phase == .dispatching
    }
    static func status(_ operation: ConversationHistoryOperation) -> String {
        switch operation.phase {
        case .accepted: String(localized: "History action accepted")
        case .dispatching: operation.review.kind == .forkAfterRun ? String(localized: "Forking conversation…") : String(localized: "Rewinding conversation…")
        case .applied: operation.review.kind == .forkAfterRun ? String(localized: "Conversation fork created") : String(localized: "Conversation rewound")
        case .failed: String(localized: "History action could not complete")
        case .unconfirmed: String(localized: "Provider history change unconfirmed")
        }
    }
    static func error(_ error: any Error) -> String {
        if let error = error as? ProviderHistoryError { return error.localizedDescription }
        return String(localized: "This conversation history action is unavailable or the conversation changed. Close the review and check its current status.")
    }
}
