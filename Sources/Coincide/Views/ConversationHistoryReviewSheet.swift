import CoincideCore
import SwiftUI

struct ConversationHistoryReviewSheet: View {
    let store: WorkspaceStore
    let threadID: UUID
    let runID: UUID
    let kind: ConversationHistoryKind
    let close: () -> Void
    @State private var review: ConversationHistoryReview?
    @State private var filesReview: ConversationHistoryReview?
    @State private var acceptedReviewID: UUID?
    @State private var filesLoading = false
    @State private var filesError: String?
    @State private var filesTask: Task<Void, Never>?
    @State private var title = ""
    @State private var loading = true
    @State private var accepting = false
    @State private var error: String?
    private var operation: ConversationHistoryOperation? { acceptedReviewID.flatMap { store.conversationHistoryOperation($0) } }
    private var busy: Bool { accepting || operation.map(ConversationHistoryPresentation.isPending) == true }
    private var openingPrompt: String? {
        guard let thread = store.thread(threadID), let run = thread.runHistory?.first(where: { $0.id == runID }),
              let message = thread.messages.first(where: { $0.id == run.userMessageID }) else { return nil }
        return message.text.isEmpty ? String(localized: "Input with attachments") : message.text
    }

    var body: some View {
        ConversationHistoryReviewContent(review: operation?.review ?? filesReview ?? review, kind: kind, title: $title, loading: loading,
                                         accepting: busy, error: error, operation: operation,
                                         openingPrompt: openingPrompt, filesLoading: filesLoading, filesError: filesError,
                                         reviewFiles: prepareFiles, confirmFiles: { confirm(restoringFiles: true) },
                                         confirm: { confirm(restoringFiles: false) }, close: close) {
            if let operation { ConversationHistoryOperationView(store: store, operation: operation) }
        }
        .interactiveDismissDisabled(busy)
        .task {
            do {
                let value = try await store.reviewConversationHistory(threadID: threadID, runID: runID, kind: kind, recallPromptOnSuccess: kind == .rewindBeforeRun)
                guard !Task.isCancelled else { store.discardConversationHistoryReview(value.id); return }
                review = value; title = value.suggestedTitle; loading = false
            } catch {
                guard !Task.isCancelled else { return }
                self.error = ConversationHistoryPresentation.error(error); loading = false
            }
        }
        .onDisappear {
            filesTask?.cancel()
            if let review { store.discardConversationHistoryReview(review.id) }
            if let filesReview { store.discardConversationHistoryReview(filesReview.id) }
        }
    }

    private func prepareFiles() {
        guard let review, kind == .rewindBeforeRun, !busy, operation == nil, !filesLoading else { return }
        filesLoading = true; filesError = nil
        filesTask = Task {
            defer { filesLoading = false; filesTask = nil }
            do {
                let value = try await store.reviewConversationHistoryRestoringFiles(review)
                guard !Task.isCancelled else { store.discardConversationHistoryReview(value.id); return }
                filesReview = value
            } catch {
                guard !Task.isCancelled else { return }
                filesError = String(localized: "Files cannot be restored from this boundary in the current workspace. Keep current files, or close this review and finish unsaved edits, terminals and other workspace work before reviewing again.")
            }
        }
    }
    private func confirm(restoringFiles: Bool) {
        guard let selected = restoringFiles ? filesReview : review, !busy, operation == nil else { return }
        if !restoringFiles { filesTask?.cancel() }
        accepting = true; error = nil
        acceptedReviewID = selected.id
        Task {
            defer { accepting = false }
            do { try await store.beginConversationHistory(selected, title: kind == .forkAfterRun ? title : nil) }
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
    var filesLoading = false
    var filesError: String? = nil
    var reviewFiles: (() -> Void)? = nil
    var confirmFiles: (() -> Void)? = nil
    let confirm: () -> Void
    let close: () -> Void
    @ViewBuilder let status: () -> Status

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 6) {
                Text(ConversationHistoryPresentation.title(kind)).font(.title2)
                Text(ConversationHistoryPresentation.reviewSummary(review, kind: kind))
                    .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                if kind == .forkAfterRun || (operation != nil && review?.files == nil) {
                    Text("Workspace files and staging stay as they are.").font(.caption).foregroundStyle(.secondary)
                } else {
                    Text("Keep current files, or review restoring a saved workspace observation. Restoring files also undoes your own edits.")
                        .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
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
                        if let files = review.files { ConversationHistoryFilesReviewSection(files: files) }
                        if review.claude != nil, kind == .rewindBeforeRun {
                            Text(ConversationHistoryPresentation.claudeContextDetail(review))
                                .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                                .accessibilityIdentifier("conversation-history-claude-context-selection")
                        } else if review.openCodeV1 != nil, kind == .rewindBeforeRun {
                            Text("OpenCode v1 creates and verifies a separate native conversation, then switches this conversation to it. The original native conversation is kept. Your current settings and latest draft stay unchanged until the optional prompt recall.")
                                .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                                .accessibilityIdentifier("conversation-history-v1-adoption")
                        }
                        if kind == .forkAfterRun, operation == nil {
                            TextField("New conversation name", text: $title)
                                .accessibilityIdentifier("conversation-history-title").disabled(accepting)
                        }
                        LabeledContent("Provider", value: RunHistoryPresentation.provider(configuration))
                        LabeledContent("Model", value: RunHistoryPresentation.model(configuration))
                        if configuration.provider == .codex, let effort = configuration.reasoningEffort {
                            LabeledContent("Reasoning", value: ReasoningEffortPresentation.title(effort))
                        }
                        LabeledContent("Permissions") { Text(LocalizedStringKey(configuration.permission.title)) }
                        Text(configuration.workspacePath).font(.caption.monospaced()).textSelection(.enabled)
                            .fixedSize(horizontal: false, vertical: true).accessibilityIdentifier("conversation-history-workspace")
                        LabeledContent("Messages kept", value: review.prefix.count.formatted())
                        if kind == .rewindBeforeRun {
                            LabeledContent(review.claude == nil ? "Messages removed" : "Local messages hidden", value: review.removedMessageIDs.count.formatted())
                        }
                        DisclosureGroup("Verified boundary") {
                            VStack(alignment: .leading, spacing: 6) {
                                LabeledContent("Run", value: review.runID.uuidString)
                                LabeledContent("Provider conversation", value: review.sourceReference.nativeThreadID)
                                if let head = review.reviewedHeadTurnID {
                                    LabeledContent("Reviewed head", value: head)
                                }
                                if let evidence = review.claude {
                                    if let head = evidence.source.headMessageID { LabeledContent("Reviewed native message head", value: head) }
                                    if let opening = evidence.inputs.first(where: { $0.runID == review.runID })?.openingInputID {
                                        LabeledContent("Selected native opening input", value: opening)
                                    }
                                    if let inherited = evidence.inheritedHead {
                                        LabeledContent("Inherited fork head", value: inherited.cursor)
                                    }
                                    if kind == .forkAfterRun {
                                        Text("Claude copies the native transcript through the inclusive selected entry and verifies the fork’s remapped message identities before it can be opened. The source is retained.")
                                            .foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                                    }
                                } else if let evidence = review.openCodeV1 {
                                    if let head = evidence.source.messages.last?.id { LabeledContent("Reviewed message head", value: head) }
                                    LabeledContent("Selected opening message", value: evidence.selectedOpeningMessageID)
                                    Text("OpenCode v1 copies native messages at the exact reviewed cut. Copied message IDs change; historical run IDs and their audit are retained.")
                                        .foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                                } else if let evidence = review.openCodeV2 {
                                    if let head = evidence.source.headMessageID { LabeledContent("Reviewed message head", value: head) }
                                    LabeledContent("Selected opening message", value: evidence.selectedOpeningMessageID)
                                    Text("OpenCode message references identify the exact reviewed inputs; they are not native provider turn IDs.")
                                        .foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                                }
                                switch review.boundary {
                                case .throughTurn(let id), .beforeTurn(let id):
                                    LabeledContent("Selected provider turn", value: id)
                                case .beforeMessage(let id):
                                    LabeledContent("First excluded message", value: id)
                                case .throughMessage(let id):
                                    LabeledContent("Last retained message", value: id)
                                case .throughClaudeMessage(let id):
                                    LabeledContent("Inclusive Claude transcript cursor", value: id)
                                    Text("This is a native transcript-entry reference, separate from API message IDs and adapter input references.")
                                        .foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                                case .freshClaudeSession(let id):
                                    LabeledContent("Reserved next conversation", value: id)
                                    Text("The new native transcript starts only when you explicitly send a message.")
                                        .foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                                case .head:
                                    Text("Current provider head")
                                }
                                Text(kind == .forkAfterRun ? "Through the end of the selected run" : "Before the selected run’s opening message")
                            }.font(.caption).textSelection(.enabled).padding(.top, 6)
                        }
                    }
                    if filesLoading { ProgressView("Reviewing files before rewind…").font(.caption) }
                    if let filesError { Text(filesError).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true) }
                    if let operation { status().id(operation.id) }
                    if let error { Text(error).font(.callout).foregroundStyle(.red).fixedSize(horizontal: false, vertical: true) }
                }.padding(20)
            }.frame(minHeight: 160, idealHeight: 300, maxHeight: 420)
            Divider()
            ViewThatFits(in: .horizontal) {
                HStack { closeButton; actionButtons }.fixedSize(horizontal: true, vertical: false)
                VStack(alignment: .trailing, spacing: 8) { closeButton; actionButtons }.frame(maxWidth: .infinity, alignment: .trailing)
            }.frame(maxWidth: .infinity, alignment: .trailing).padding(16)
        }
        .frame(minWidth: 320, idealWidth: 560, maxWidth: 680)
        .onExitCommand { if !accepting { close() } }
    }
    private var closeButton: some View {
        Button(operation == nil ? "Cancel" : "Done", action: close).keyboardShortcut(.defaultAction)
            .disabled(accepting).accessibilityIdentifier("conversation-history-close")
    }
    @ViewBuilder private var actionButtons: some View {
        if operation == nil {
            if kind == .rewindBeforeRun {
                Button(review?.claude != nil
                       ? review?.files == nil ? "Restore Files Too…" : "Save Point and Restore Files"
                       : review?.files == nil ? "Revert Files Too…" : "Revert Files Too", role: .destructive) {
                    if review?.files != nil { confirmFiles?() } else { reviewFiles?() }
                }.disabled(review == nil || accepting || filesLoading || reviewFiles == nil)
                    .accessibilityIdentifier("conversation-history-revert-files")
                Button(review?.claude == nil ? "Revert and Keep Changes" : "Save Resume Point", action: confirm)
                    .disabled(review == nil || accepting).accessibilityIdentifier("conversation-history-confirm")
            } else {
                Button("Fork Conversation", action: confirm)
                    .disabled(review == nil || accepting || title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    .accessibilityIdentifier("conversation-history-confirm")
            }
        }
    }
}

struct ConversationHistoryFilesReviewSection: View {
    let files: ConversationHistoryFilesReview
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Divider()
            Text(files.target.stage == .baseline ? "Original Workspace Before First Provider Turn" : "After Previous Visible Run").font(.headline)
                .accessibilityIdentifier("conversation-history-file-target")
            LabeledContent("Saved observation") { Text(files.target.receipt.capturedAt, format: .dateTime.year().month(.abbreviated).day().hour().minute().second()) }
            Text(files.gitReview.currentPlan.workspacePath).font(.caption.monospaced()).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
                .accessibilityIdentifier("conversation-history-file-workspace")
            Text("Working edits and staging will be lost. New files that are not ignored may be deleted. Ignored files are kept; the current branch and HEAD stay unchanged.")
                .font(.callout).fixedSize(horizontal: false, vertical: true).accessibilityIdentifier("conversation-history-file-warning")
            LabeledContent("Affected paths", value: files.gitReview.affectedPaths.count.formatted())
            DisclosureGroup("Paths in this restore") {
                ScrollView { LazyVStack(alignment: .leading, spacing: 4) {
                    ForEach(files.gitReview.affectedPaths, id: \.self) { Text($0).font(.caption.monospaced()).textSelection(.enabled) }
                }.frame(maxWidth: .infinity, alignment: .leading) }.frame(maxHeight: 140)
            }
            if !files.gitReview.previewPatch.isEmpty {
                DisclosureGroup("Preview changes to current files") {
                    ScrollView([.horizontal, .vertical]) { Text(files.gitReview.previewPatch).font(.caption.monospaced()).textSelection(.enabled) }.frame(maxHeight: 180)
                }
            }
            if files.gitReview.previewTruncated {
                Text("The preview is limited. Restoration applies to the complete reviewed manifest.").font(.caption).foregroundStyle(.secondary)
            }
        }.font(.caption)
    }
}

enum ConversationHistoryPresentation {
    static func isClaudeContextSelection(_ review: ConversationHistoryReview) -> Bool {
        review.claude != nil && review.kind == .rewindBeforeRun
    }
    static func reviewSummary(_ review: ConversationHistoryReview?, kind: ConversationHistoryKind) -> String {
        if let review, isClaudeContextSelection(review) {
            return review.recallPromptOnSuccess == true
                ? String(localized: "Save the context before this run for your next explicit Claude message. The original prompt and attachments return to your latest draft after this action and any selected file restoration finish. Current settings stay unchanged; no message is sent.")
                : String(localized: "Save the context before this run for your next explicit Claude message. The local run audit and native transcript are retained. Your current draft and settings stay unchanged; no message is sent.")
        }
        return kind == .forkAfterRun
            ? String(localized: "Create a separate conversation through the end of this run. The source conversation and its draft stay unchanged.")
            : review?.recallPromptOnSuccess == true
            ? String(localized: "Rewind before this run and keep its audit. After the rewind fully completes, the original prompt and attachments return to your latest draft. Current provider settings stay unchanged.")
            : String(localized: "Remove this run and later messages from the current conversation. Its run audit is retained; your current draft and settings stay unchanged.")
    }
    static func claudeContextDetail(_ review: ConversationHistoryReview) -> String {
        if let evidence = review.claude, evidence.inputs.first?.runID == review.runID, evidence.inheritedHead != nil {
            return String(localized: "Your next Claude message resumes from this conversation’s inherited fork head. The inherited context is kept; this does not start an empty conversation or delete native history.")
        }
        switch review.boundary {
        case .freshClaudeSession:
            return String(localized: "Your next message starts a new, empty Claude conversation. Its identity is reserved now; no native transcript is created until you send. Existing native conversations are kept.")
        default:
            return String(localized: "Claude will resume through the selected native transcript entry when you next send a message. The original transcript is not deleted or truncated. This action does not run Claude or restore files by itself.")
        }
    }
    static func recallFailure(_ operation: ConversationHistoryOperation) -> String {
        isClaudeContextSelection(operation.review)
            ? String(localized: "The Claude resume point was saved, but the original input could not be recalled. Review the latest draft and attachments, then recall it or keep your current draft. No message was sent.")
            : String(localized: "Rewind completed. The original input could not be recalled. Review the latest draft and attachments, then recall it or keep your current draft.")
    }
    static func title(_ kind: ConversationHistoryKind) -> String {
        kind == .forkAfterRun ? String(localized: "Fork After This Run") : String(localized: "Rewind Before This Run")
    }
    static func isPending(_ operation: ConversationHistoryOperation) -> Bool {
        operation.isWorking
    }
    static func status(_ operation: ConversationHistoryOperation) -> String {
        if isClaudeContextSelection(operation.review) {
            if operation.phase == .applied, let files = operation.files {
                switch files.phase {
                case .waitingForProvider: return String(localized: "Claude resume point saved; files not restored")
                case .accepted, .dispatching: return String(localized: "Claude resume point saved; restoring files…")
                case .applied: return String(localized: "Claude resume point saved; workspace files restored")
                case .failed: return files.acknowledgedAt == nil ? String(localized: "Claude resume point saved; files were not restored") : String(localized: "Claude resume point saved; current files kept")
                case .unconfirmed: return files.acknowledgedAt == nil ? String(localized: "Claude resume point saved; file restoration unconfirmed") : String(localized: "Claude resume point saved; current files kept")
                }
            }
            return switch operation.phase {
            case .accepted: String(localized: "Claude context selection accepted")
            case .dispatching: String(localized: "Saving Claude resume point…")
            case .applied: String(localized: "Claude resume point saved")
            case .failed: String(localized: "Claude context selection could not complete")
            case .unconfirmed: String(localized: "Claude context selection unconfirmed")
            }
        }
        if operation.error == ConversationHistoryOperation.openCodeV1NotAdoptedMessage { return String(localized: "Original conversation kept") }
        if operation.phase == .unconfirmed, let maintenance = operation.maintenance {
            switch maintenance.phase {
            case .accepted, .dispatching: return String(localized: "Clearing pending provider revert…")
            case .applied: return String(localized: "Pending revert cleared; inspect provider state")
            case .unconfirmed: return String(localized: "Provider revert cleanup unconfirmed")
            case .failed: break
            }
        }
        if operation.phase == .applied, let files = operation.files {
            switch files.phase {
            case .waitingForProvider: return String(localized: "Conversation rewound; files not restored")
            case .accepted, .dispatching: return String(localized: "Conversation rewound; restoring files…")
            case .applied: return String(localized: "Conversation and workspace files rewound")
            case .failed: return files.acknowledgedAt == nil ? String(localized: "Conversation rewound; files were not restored") : String(localized: "Conversation rewound; current files kept")
            case .unconfirmed: return files.acknowledgedAt == nil ? String(localized: "Conversation rewound; file restoration unconfirmed") : String(localized: "Conversation rewound; current files kept")
            }
        }
        return switch operation.phase {
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
