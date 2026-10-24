import AppKit
import CoincideCore
import CoincideMarkdown
import CryptoKit
import Foundation
import SwiftUI
import UniformTypeIdentifiers

struct RemoteProjectedOperationCard: View {
    let operation: RemoteOperationSummary
    var enabled = true
    var actionsVisible = true
    let act: (RemoteOperationAction) -> Void
    @State private var confirming: RemoteOperationAction?
    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack { Text(operation.title.preview).font(.caption.weight(.semibold)); Spacer(); Text(operation.phase).font(.caption).foregroundStyle(.secondary) }
            ForEach(Array(operation.details.enumerated()), id: \.offset) { _, detail in
                LabeledContent(detail.label) { RemoteProjectionPreview(text: detail.value) }.font(.caption)
            }
            if let error = operation.error { RemoteProjectionPreview(text: error).foregroundStyle(.secondary) }
            ForEach(Array(operation.warnings.enumerated()), id: \.offset) { _, warning in RemoteProjectionPreview(text: warning).foregroundStyle(.secondary) }
            if actionsVisible { ViewThatFits(in: .horizontal) { buttons; VStack(alignment: .leading) { buttons } } }
        }.textSelection(.enabled).padding(12).coincideSurface()
        .confirmationDialog("Keep the current remote outcome?", isPresented: Binding(get: { confirming != nil }, set: { if !$0 { confirming = nil } })) {
            if let action = confirming { Button("Keep Current Outcome") { confirming = nil; act(action) } }
            Button("Cancel", role: .cancel) { confirming = nil }
        } message: { Text("The earlier action may already have changed the remote files or service. This releases its hold without repeating that action.") }
    }
    @ViewBuilder private var buttons: some View {
        ForEach(RemoteOperationAction.allCases, id: \.rawValue) { action in
            if let availability = operation.actions[action.rawValue] {
                if action == .openPullRequest, let raw = operation.url, let url = URL(string: raw), ["http", "https"].contains(url.scheme?.lowercased() ?? "") {
                    Link("Open Pull Request", destination: url).font(.caption)
                } else if supported(action) {
                    Button(label(action)) {
                        if [.acknowledgeCreation, .acknowledgeCheckout, .acknowledgeRestore].contains(action) { confirming = action }
                        else { act(action) }
                    }.disabled(!enabled || !availability.allowed).help(availability.reason ?? "")
                }
            }
        }
    }
    private func supported(_ action: RemoteOperationAction) -> Bool {
        [.inspectCreation, .acknowledgeCreation, .inspectCheckout, .acknowledgeCheckout, .cancelCheckout, .openConversation,
         .inspectRestore, .acknowledgeRestore].contains(action)
    }
    private func label(_ action: RemoteOperationAction) -> String {
        switch action {
        case .inspectCreation, .inspectCheckout, .inspectRestore: "Inspect Result"
        case .acknowledgeCreation, .acknowledgeCheckout, .acknowledgeRestore: "Keep Current Outcome…"
        case .cancelCheckout: "Cancel Checkout"
        case .openConversation: "Open Conversation"
        default: action.rawValue
        }
    }
}
struct RemoteProjectionPreview: View {
    let text: RemoteProjectionText
    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(text.preview).textSelection(.enabled)
            if !text.complete { Text("Preview · full text has not been loaded").font(.caption2).foregroundStyle(.secondary) }
        }
    }
}

/// Keeps a bounded window of UTF-8 content. Historical bytes never become
/// provider input; full SHA verification is reported only after the final page.
@MainActor @Observable
final class RemoteProjectionTextReader {
    private(set) var text = ""
    private(set) var offset = 0
    private(set) var windowStart = 0
    private(set) var complete = false
    private(set) var verified = false
    private(set) var loading = false
    private(set) var error: String?
    @ObservationIgnored private var data = Data()
    @ObservationIgnored private var cursor: UUID?
    @ObservationIgnored private var hasher = SHA256()
    @ObservationIgnored private var generation = UUID()
    func load(reference: RemoteProjectionContentReference, binding: RemoteProjectionBinding, store: RemoteProjectionStore) async {
        guard !loading, !complete else { return }
        loading = true; let owner = generation
        defer { if generation == owner { loading = false } }
        do {
            let page = try await store.content(.init(binding: binding, reference: reference, offset: offset, cursor: cursor))
            guard owner == generation, !Task.isCancelled else { return }
            guard page.binding == binding, page.reference == reference, page.offset == offset,
                  page.data.count <= RemoteProjectionProtocol.maximumContentChunkBytes,
                  offset + page.data.count <= reference.totalBytes,
                  page.complete == (page.nextCursor == nil), page.complete == (offset + page.data.count == reference.totalBytes),
                  page.complete || !page.data.isEmpty else { throw RemoteProjectionFailure(.invalidRequest) }
            hasher.update(data: page.data); data.append(page.data); offset += page.data.count; cursor = page.nextCursor; complete = page.complete
            if data.count > 1_048_576 {
                var remove = data.count - 1_048_576
                while remove < data.count, data[data.startIndex + remove] & 0xc0 == 0x80 { remove += 1 }
                data.removeFirst(remove); windowStart += remove
            }
            text = try Self.decodeWindow(data, complete: complete)
            if complete {
                let digest = hasher.finalize().map { String(format: "%02x", $0) }.joined()
                guard digest == reference.digest else { throw RemoteProjectionFailure(.invalidRequest) }
                verified = true
            }
            error = nil
        } catch { if owner == generation { self.error = error.localizedDescription } }
    }
    static func decodeWindow(_ bytes: Data, complete: Bool) throws -> String {
        var end = bytes.count
        if !complete, end > 0 {
            var leading = end - 1
            while leading > 0, bytes[bytes.startIndex + leading] & 0xc0 == 0x80 { leading -= 1 }
            let byte = bytes[bytes.startIndex + leading]
            let count = byte & 0x80 == 0 ? 1 : byte & 0xe0 == 0xc0 ? 2 : byte & 0xf0 == 0xe0 ? 3 : byte & 0xf8 == 0xf0 ? 4 : 0
            guard count > 0 else { throw RemoteProjectionFailure(.invalidRequest) }
            if end - leading < count { end = leading }
        }
        guard let text = String(data: bytes.prefix(end), encoding: .utf8) else { throw RemoteProjectionFailure(.invalidRequest) }
        return text
    }
    func reset() { generation = UUID(); text = ""; data = Data(); offset = 0; windowStart = 0; cursor = nil; complete = false; verified = false; loading = false; error = nil; hasher = SHA256() }
}

struct RemoteProjectedMessageView: View {
    @AppStorage("renderMathInMarkdown") private var renderMathInMarkdown = false
    let message: RemoteMessageSummary
    let binding: RemoteProjectionBinding
    let store: RemoteProjectionStore
    let source: AttachmentAccess?
    let transcript: RemoteTranscriptState
    var workspace: RemoteWorkspaceStore? = nil
    var result: RemoteMessageSummary? = nil
    var historyAction: ((UUID, ConversationHistoryKind) -> Void)? = nil
    var changesAction: ((UUID) -> Void)? = nil
    @State private var reader = RemoteProjectionTextReader()
    @State private var attachments: [ChatAttachment]?
    @State private var attachmentError: String?
    @State private var expanded = false
    @State private var hovered = false
    @AppStorage(TranscriptPreferences.timestampFormatKey) private var timestampFormat = TranscriptTimestampFormat.system.rawValue
    private var entry: RemoteTranscriptEntry? { transcript.entry(message, binding) }
    private var displayText: String { reader.offset > 0 ? reader.text : message.text.preview }
    var copySource: String? {
        if let entry { return entry.sourceText }
        return message.presentation == nil && message.text.complete ? message.text.preview : nil
    }
    private var current: Bool {
        guard let workspace, let presentation = entry?.presentation else { return false }
        return workspace.transcriptActionIsCurrent(message: message, binding: binding, presentation: presentation)
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let attachments, let source { AttachmentShelf(source: source, attachments: attachments) }
            if message.attachmentCount > 0, attachments == nil {
                Button("Load \(message.attachmentCount) Attachments") { Task { await loadAttachments() } }.disabled(!store.connected)
            }
            if let attachmentError { Text(attachmentError).font(.caption).foregroundStyle(.secondary) }
            if let title = message.title { RemoteProjectionPreview(text: title).font(.caption.weight(.semibold)) }
            if let status = message.status { RemoteProjectionPreview(text: status).font(.caption).foregroundStyle(.secondary) }
            if message.role == .tool, let card = transcript.card(message, result: result, binding: binding) {
                if card.kind == .plan, let plan = card.plan {
                    PlanCardView(plan: plan, expanded: $expanded,
                        canImplement: card.status == .completed && (entry.map { workspace?.canImplementTranscriptPlan(message: message, binding: binding, presentation: $0.presentation) == true } ?? false),
                        canImplementInNewConversation: card.status == .completed && (entry.map { workspace?.canImplementTranscriptPlan(message: message, binding: binding, presentation: $0.presentation, inNewConversation: true) == true } ?? false),
                        implement: { plan in
                            guard let workspace, let entry, current else { return false }
                            return await workspace.implementTranscriptPlan(plan: plan, message: message, binding: binding, presentation: entry.presentation)
                        }, implementInNewConversation: { plan in
                            guard let workspace, let entry, current else { return false }
                            return await workspace.implementTranscriptPlanInNewConversation(plan: plan, message: message, binding: binding, presentation: entry.presentation)
                        }, save: { path, contents in
                            guard let workspace, let entry, current else { throw CancellationError() }
                            try await workspace.saveTranscriptPlan(path: path, contents: contents, message: message, binding: binding, presentation: entry.presentation)
                        }, saveAvailable: current && workspace?.canWrite == true)
                } else {
                    ToolCardView(card: card, entity: entry?.presentation.providerEntity, expanded: $expanded)
                }
            } else if message.role == .tool {
                DisclosureGroup(message.title?.preview ?? "Tool activity") { Text(displayText).font(.system(.caption, design: .monospaced)) }
            } else if message.role == .reasoning {
                ReasoningRowView(text: displayText, live: entry?.presentation.runActive == true && entry?.presentation.trailing == true,
                                 duration: nil, expanded: $expanded)
            } else if message.role == .user {
                HStack { Spacer(minLength: 60); UserMessageBody(text: displayText, expanded: $expanded).padding(14).background(.quaternary, in: RoundedRectangle(cornerRadius: 18)) }
            } else { MarkdownView(displayText, mathEnabled: renderMathInMarkdown) }
            if message.role == .user || message.role == .assistant {
                MessageActionsBar(message: displayMessage, role: message.role, actions: actions,
                    steered: entry?.presentation.promptSteeringID != nil, streaming: entry?.presentation.streaming == true,
                    providerName: entry?.presentation.provider?.name ?? "Provider", visible: hovered,
                    copyAvailable: copySource != nil,
                    copyUnavailableReason: "Load the complete verified source before copying this message.")
            }
            if message.presentation != nil, entry == nil {
                Button("Load Activity Details") { requestDetails() }.disabled(transcript.loading.contains(.init(message, binding)) || !store.connected)
                    .help("Load the immutable remote presentation document.")
            }
            if entry?.sourceText == nil, entry != nil {
                Button("Load Complete Source for Actions") { requestDetails(includeSource: true) }
                    .disabled(transcript.loading.contains(.init(message, binding)) || !store.connected)
                    .help("Complete source is bounded to 32 MiB; longer content remains available through paged text.")
            }
            if let error = transcript.errors[.init(message, binding)] { Text(error).font(.caption).foregroundStyle(.secondary) }
            if !message.text.complete, let reference = message.text.content {
                HStack {
                    Button(reader.offset == 0 ? "Load Text" : "Load More Text") { Task { await reader.load(reference: reference, binding: binding, store: store) } }
                        .disabled(reader.loading || reader.complete || !store.connected)
                    if reader.loading { ProgressView().controlSize(.small) }
                    if reader.offset > 0 { Text("Bytes \(reader.windowStart)–\(reader.offset) of \(reference.totalBytes)\(reader.verified ? " · verified" : " · incomplete")").font(.caption2).foregroundStyle(.secondary) }
                    if reader.windowStart > 0 { Button("Restart Text") { reader.reset() } }
                }
                if let error = reader.error { Text(error).font(.caption).foregroundStyle(.secondary) }
            }
            if let error = message.submissionError { RemoteProjectionPreview(text: error).font(.caption).foregroundStyle(.red) }
        }.textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
        .onHover { hovered = $0 }
        .task(id: RemoteTranscriptMessageKey(message, binding)) { requestDetails() }
        .onChange(of: transcript.binding) {
            if transcript.binding == binding { requestDetails() }
        }
    }
    private var displayMessage: ChatMessage {
        if let entry { return entry.message }
        var value = ChatMessage(id: message.id, role: message.role, text: copySource ?? "")
        value.createdAt = message.createdAt; return value
    }
    private var actions: TranscriptMessageActions {
        var value = TranscriptMessageActions(timestamps: .init(format: .init(rawValue: timestampFormat) ?? .system))
        guard let entry, let runID = entry.presentation.runReference?.runID else { return value }
        if entry.presentation.opensRun {
            value.editUnavailableReason = !current ? "Select the original remote conversation before reviewing history." : workspace?.history.current?.availability(runID: runID, kind: .rewindBeforeRun).reason
            value.editFromHere = { if current { historyAction?(runID, .rewindBeforeRun) } }
            if historyAction == nil || workspace?.history.current?.availability(runID: runID, kind: .rewindBeforeRun).allowed != true { value.editUnavailableReason = value.editUnavailableReason ?? "Load this exact run in remote history first." }
        }
        if entry.presentation.terminalResponse {
            value.forkUnavailableReason = !current ? "Select the original remote conversation before reviewing history." : workspace?.history.current?.availability(runID: runID, kind: .forkAfterRun).reason
            value.forkFromHere = { if current { historyAction?(runID, .forkAfterRun) } }
            if historyAction == nil || workspace?.history.current?.availability(runID: runID, kind: .forkAfterRun).allowed != true { value.forkUnavailableReason = value.forkUnavailableReason ?? "Load this exact run in remote history first." }
            if store.runs.first(where: { $0.id == runID })?.checkpointDiff.allowed == true {
                value.viewChanges = { if current { changesAction?(runID) } }
            }
        }
        return value
    }
    private func requestDetails(includeSource: Bool = false) {
        guard store.connected else { return }
        transcript.request(message, binding: binding, includeSource: includeSource) { try await store.document($0, binding: $1) }
    }
    private func loadAttachments() async {
        guard let reference = message.attachments, reference.kind == .attachmentReferences else { return }
        do {
            let values = try JSONDecoder().decode([ChatAttachment].self, from: await store.document(reference, binding: binding))
            guard values.count == message.attachmentCount, !Task.isCancelled, transcript.binding == binding else { throw RemoteProjectionFailure(.invalidRequest) }
            attachments = values; attachmentError = nil
        } catch { attachmentError = error.localizedDescription }
    }
}

struct RemoteProjectedConversationView: View {
    @Bindable var store: RemoteWorkspaceStore
    let chooseWorktree: () -> Void
    var mergeContextBack: () -> Void = { }
    @State private var model = ""
    private var control: RemoteProjectionControl? { store.projection.control }
    var body: some View {
        if let control, control.detail.summary.id == store.selectedThreadID {
            VStack(spacing: 0) {
                header(control)
                if store.descriptor?.capabilities.supportsWorkspaceLifecycleControls == true {
                    RemoteLifecycleControls(store: store.lifecycle, supportsScriptReview: store.descriptor?.capabilities.supportsReviewedSettleScripts == true).padding(.horizontal, 14).padding(.bottom, 8)
                }
                if store.descriptor?.capabilities.supportsReviewedSettleScripts == true, control.detail.settlementID != nil {
                    RemoteProjectScriptPanel(store: store.projectScripts).padding(.horizontal, 14).padding(.bottom, 8)
                }
                if control.detail.liveProviderUsage != nil || control.detail.liveProviderUsageContent != nil {
                    DisclosureGroup("Latest Provider Status") {
                        RemoteProviderUsageView(binding: control.binding, contentAccess: .init(store: store.projection),
                            provider: control.detail.summary.provider, runID: control.detail.activeRun?.id,
                            inline: control.detail.liveProviderUsage, reference: control.detail.liveProviderUsageContent, live: true)
                    }.padding(.horizontal, 14).padding(.bottom, 8)
                }
                HStack {
                    Button("Choose Worktree…", systemImage: "arrow.triangle.branch", action: chooseWorktree).disabled(!store.worktrees.canChoose)
                    Spacer()
                }.padding(.horizontal, 14).padding(.bottom, 8)
                RemoteWorktreeBanner(store: store.worktrees)
                RemotePullRequestBanner(store: store.pullRequests)
                RemoteRunCheckpointBanner(store: store.checkpoints)
                RemoteHistoryBanner(store: store.history)
                RemoteContextTransferBanner(store: store.contextTransfers, mergeBack: mergeContextBack)
                transcript
                if let request = control.requests.first {
                    ApprovalView(request: request.request, isResponding: request.responding || !store.canWrite,
                        onDecision: { respond(request.request, .decision($0)) }, onAnswer: { respond(request.request, .answers($0)) },
                        onSelectionsWithNotes: { respond(request.request, .selectionsWithNotes(selections: $0, notes: $1)) })
                        .id(request.id).padding(.horizontal, 20)
                }
                if control.detail.summary.queueCount > 0 {
                    HStack {
                        Text("\(control.detail.summary.queueCount) queued").font(.caption)
                        if control.detail.queuePaused {
                            Button("Resume Queue") { Task { await store.perform(.resumeQueue(threadID: control.detail.summary.id, expectedConfiguration: control.configuration)) } }
                                .disabled(!store.canWrite || !control.detail.resumeQueue.allowed)
                        }
                        Spacer()
                    }.padding(.horizontal, 24)
                }
                composer(control)
            }
            .onAppear { model = control.configuration.model }
            .onChange(of: control.configuration.model) { model = control.configuration.model }
            .onChange(of: control.detail.summary.id) { model = control.configuration.model }
        } else if store.projection.isLoading { ProgressView("Reading remote conversation…").frame(maxWidth: .infinity, maxHeight: .infinity) }
        else { ContentUnavailableView("Choose a Remote Conversation", systemImage: "bubble.left.and.bubble.right") }
    }
    private func header(_ value: RemoteProjectionControl) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                RemoteProjectionPreview(text: value.detail.summary.title).font(.headline)
                Text(value.detail.summary.providerName).font(.caption).foregroundStyle(.secondary)
                Spacer()
                Picker("Permissions", selection: Binding(get: { value.configuration.permission }, set: { edit(value, .permission($0)) })) {
                    ForEach(PermissionMode.allCases) { Text($0.title).tag($0) }
                }.fixedSize().disabled(!store.canWrite)
            }
            if store.descriptor?.capabilities.supportsRemoteCheckpoints == true {
                Picker("Run checkpoints", selection: Binding(get: { value.detail.checkpointPolicy }, set: { edit(value, .checkpointPolicy($0, expected: value.detail.checkpointPolicy)) })) {
                    Text("Automatic").tag(RunCheckpointPolicy.automatic); Text("Disabled").tag(RunCheckpointPolicy.disabled)
                }.fixedSize().disabled(!store.canWrite)
            }
            Text(value.configuration.workspacePath).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
            HStack {
                TextField("Model identifier (empty uses CLI default)", text: $model).onSubmit { edit(value, .model(model)) }
                Button("Use Model") { edit(value, .model(model)) }.disabled(model == value.configuration.model)
            }.disabled(!store.canWrite)
        }.padding(14)
    }
    private var transcript: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Message rows \(store.projection.messageWindowStart + (store.projection.messages.isEmpty ? 0 : 1))–\(store.projection.messageWindowStart + store.projection.messages.count) of \(store.projection.messageCount)").font(.caption).foregroundStyle(.secondary)
                if !store.projection.messagesComplete || store.projection.messageWindowStart > 0 { Text("History is incomplete").font(.caption).foregroundStyle(.secondary) }
                Spacer()
                if store.projection.hasNewerContent || !store.projection.followsLatest {
                    Button("Follow Latest") { Task { await store.projection.followLatest() } }.disabled(!store.isConnected)
                } else { Button("Pause Following") { store.projection.pauseFollowing() }.disabled(!store.isConnected) }
            }.padding(.horizontal, 18).padding(.vertical, 6)
            DisclosureGroup("Saved Operation History") {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Operation rows \(store.projection.operationWindowStart + (store.projection.operations.isEmpty ? 0 : 1))–\(store.projection.operationWindowStart + store.projection.operations.count) of \(store.projection.operationCount) · read-only pinned history").font(.caption).foregroundStyle(.secondary)
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 8) {
                            ForEach(store.projection.operations) { operation in
                                RemoteProjectedOperationCard(operation: operation, enabled: false, actionsVisible: false) { _ in }
                            }
                            if store.projection.canLoadOperations { Button("Load More Operations") { Task { await store.projection.loadMore(.operations) } } }
                        }
                    }.frame(maxHeight: 200)
                }
            }.font(.caption).padding(.horizontal, 18)
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 24) {
                    if store.projection.canLoadEarlier { Button("Load Earlier Messages") { Task { await store.projection.loadMore(.messages) } } }
                    if let binding = store.projection.browseBinding {
                        RemoteTranscriptRowsView(store: store, binding: binding)
                    }
                    if control?.detail.isBusy == true { Text("\(control?.detail.summary.providerName ?? "Provider") is working on the remote Mac…").font(.caption).foregroundStyle(.secondary) }
                }.frame(maxWidth: 760, alignment: .leading).padding(24).frame(maxWidth: .infinity)
            }.defaultScrollAnchor(.bottom)
        }
    }
    private func composer(_ value: RemoteProjectionControl) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            if store.draftExceedsLocalLimit {
                VStack(alignment: .leading, spacing: 6) {
                    Text("This host draft exceeds the local limit of 120,000 UTF-16 characters. Copy it, then replace it with a shorter local draft before sending. The host draft stays unchanged.").font(.caption).foregroundStyle(.secondary)
                    Text(String(store.draft.prefix(2_048))).font(.caption).lineLimit(5).textSelection(.enabled)
                    HStack {
                        Button("Copy Full Host Draft") { NSPasteboard.general.clearContents(); NSPasteboard.general.setString(store.draft, forType: .string) }
                        Button("Replace with Empty Local Draft") { store.replaceOversizedDraft() }
                    }
                }
            } else {
                RemoteComposerView(store: store, threadID: value.detail.summary.id, provider: value.detail.summary.provider,
                    providerName: value.detail.summary.providerName, permission: value.detail.summary.permission,
                    busy: value.detail.isBusy, canStop: store.canWrite && value.detail.runtimeID != nil,
                    stop: { Task { await store.stopProjected() } })
            }
            if !value.detail.submit.allowed, let reason = value.detail.submit.reason { Text(reason).font(.caption).foregroundStyle(.secondary) }
        }.padding(14).coincideSurface(cornerRadius: 20).padding(18)
        .onDrop(of: [UTType.fileURL.identifier, UTType.image.identifier], isTargeted: nil) { providers in
            if store.composerSupported, let scope = store.remoteComposerScope {
                        guard store.composer.canOperate else { return false }
                        store.composer.tools?.importProviders(providers, threadID: scope.threadID); return true
                    }
                    guard store.attachments.canImport else { return false }; store.attachments.importAttachments(providers: providers); return true
        }
    }
    private func respond(_ request: ApprovalRequest, _ response: ProviderApprovalResponse) { Task { await store.respondProjected(request, response: response) } }
    private func edit(_ value: RemoteProjectionControl, _ edit: RemoteEnvironmentThreadEdit) {
        Task { await store.perform(.editThread(threadID: value.detail.summary.id, edit: edit, expectedConfiguration: value.configuration)) }
    }
}
