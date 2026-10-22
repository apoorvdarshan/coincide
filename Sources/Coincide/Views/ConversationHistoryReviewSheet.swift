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
                Text(kind == .forkAfterRun
                     ? String(localized: "Create a separate conversation through the end of this run. The source conversation and its draft stay unchanged.")
                     : review?.recallPromptOnSuccess == true
                     ? String(localized: "Rewind before this run and keep its audit. After the rewind fully completes, the original prompt and attachments return to your latest draft. Current provider settings stay unchanged.")
                     : String(localized: "Remove this run and later messages from the current conversation. Its run audit is retained; your current draft and settings stay unchanged."))
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
        .accessibilityIdentifier("conversation-history-review")
    }
    private var closeButton: some View {
        Button(operation == nil ? "Cancel" : "Done", action: close).keyboardShortcut(.defaultAction)
            .disabled(accepting).accessibilityIdentifier("conversation-history-close")
    }
    @ViewBuilder private var actionButtons: some View {
        if operation == nil {
            if kind == .rewindBeforeRun {
                Button(review?.files == nil ? "Revert Files Too…" : "Revert Files Too", role: .destructive) {
                    if review?.files != nil { confirmFiles?() } else { reviewFiles?() }
                }.disabled(review == nil || accepting || filesLoading || reviewFiles == nil)
                    .accessibilityIdentifier("conversation-history-revert-files")
                Button("Revert and Keep Changes", action: confirm)
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
    static func title(_ kind: ConversationHistoryKind) -> String {
        kind == .forkAfterRun ? String(localized: "Fork After This Run") : String(localized: "Rewind Before This Run")
    }
    static func isPending(_ operation: ConversationHistoryOperation) -> Bool {
        operation.isWorking
    }
    static func status(_ operation: ConversationHistoryOperation) -> String {
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
