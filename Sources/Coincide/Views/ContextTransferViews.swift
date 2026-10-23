import CoincideCore
import SwiftUI

struct ContextTransferReviewFacts {
    let id: UUID
    let kind: ContextTransferKind
    let strategy: ContextTransferStrategy
    let sourcePoint: ContextTransferResolvedPoint
    let basePoint: ContextTransferResolvedPoint?
    let sourceProvider: String
    let destinationProvider: String
    let sourcePath: String
    let destinationPath: String
    let archiveCount: Int
    let archiveBytes: Int
    var strategyTitle: String { switch strategy { case .nativeFork: "Native Provider Fork"; case .portableContext: "Portable Context"; case .forkDeltaContext: "Portable Child Delta"; case .deltaContext: "Context Added to Saved Provider Session" } }
    var coverage: String {
        switch strategy {
        case .nativeFork: "An exact native boundary was verified. The native fork is prepared when you next explicitly send; this review does not send input."
        case .portableContext: "Archived app-visible messages and textual outcomes provide context. Native sessions, tool state, approvals, reasoning, and attachment bytes are not replayed."
        case .forkDeltaContext: "Eligible child context is added to the actual parent conversation. This is textual context, with no Git merge or workspace file copying."
        case .deltaContext: "The host verified a saved session for this provider profile. Only eligible context that session has not received is added to the next explicit input."
        }
    }
}

struct ContextTransferFactsView: View {
    let value: ContextTransferReviewFacts
    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            Label(value.strategyTitle, systemImage: value.strategy == .nativeFork ? "arrow.triangle.branch" : "text.bubble").font(.headline)
            Text(value.coverage).font(.callout).foregroundStyle(.secondary)
            LabeledContent("Source provider", value: value.sourceProvider)
            LabeledContent("Destination provider", value: value.destinationProvider)
            LabeledContent("Source run", value: value.sourcePoint.runID.uuidString).font(.caption.monospaced())
            if let checkpoint = value.sourcePoint.checkpointAttemptID { LabeledContent("After-run observation", value: checkpoint.uuidString).font(.caption.monospaced()) }
            if let base = value.basePoint { LabeledContent("Fork base run", value: base.runID.uuidString).font(.caption.monospaced()) }
            VStack(alignment: .leading, spacing: 3) {
                Text("Source workspace").font(.caption.weight(.medium)); Text(value.sourcePath).font(.caption.monospaced())
                Text("Destination workspace").font(.caption.weight(.medium)); Text(value.destinationPath).font(.caption.monospaced())
            }
            Text("Archive: \(value.archiveCount) items · \(value.archiveBytes) bytes").font(.caption).foregroundStyle(.secondary)
            if value.strategy != .nativeFork {
                Text("The final intact-item selection and omissions depend on the actual next message's conservative provider budget. Oversized items can be omitted; the authored message and attachments are never truncated to make context fit.").font(.caption).foregroundStyle(.secondary)
            }
            Text("Creating this transfer does not submit a message or replace any current draft or attachments.").font(.caption.weight(.medium))
        }.textSelection(.enabled)
    }
}

struct ContextTransferSheet: View {
    @Bindable var model: ContextTransferStore
    let close: () -> Void
    @State private var preparing: Task<Void, Never>?
    @State private var ownedID: UUID?
    @State private var submitted = false
    var body: some View {
        ContextTransferSheetContent(model: model, submitted: submitted, prepare: prepare,
            accept: { Task { submitted = await model.accept() } }, close: close)
            .interactiveDismissDisabled(model.isAccepting)
            .onDisappear { preparing?.cancel(); model.clear(id: ownedID) }
    }
    private func prepare() {
        preparing?.cancel()
        preparing = Task {
            let id = await model.prepare()
            guard !Task.isCancelled else { model.clear(id: id); return }
            ownedID = id
        }
    }
}
struct ContextTransferSheetContent: View {
    @Bindable var model: ContextTransferStore
    var submitted = false
    let prepare: () -> Void
    let accept: () -> Void
    let close: () -> Void
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 6) {
                Text("Transfer Conversation Context").font(.title2)
                Text("Review the source point and destination before creating a context choice for the next explicit input.").font(.callout).foregroundStyle(.secondary)
            }.padding(20)
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    if submitted { Label("Context transfer created. No message was submitted.", systemImage: "checkmark.circle").font(.headline) }
                    else {
                        form.disabled(model.isAccepting)
                        Button("Review Context", action: prepare).disabled(!model.canPrepare)
                        if model.isReviewing { ProgressView("Reviewing the exact source and destination…").controlSize(.small) }
                    }
                    if let review = model.review {
                        ContextTransferFactsView(value: .init(id: review.id, kind: review.kind, strategy: review.strategy,
                            sourcePoint: review.sourcePoint, basePoint: review.basePoint,
                            sourceProvider: review.sourceConfiguration.provider.name, destinationProvider: review.targetConfiguration.provider.name,
                            sourcePath: review.sourceConfiguration.workspacePath, destinationPath: review.targetConfiguration.workspacePath,
                            archiveCount: review.messages.count, archiveBytes: (try? ContextTransferProtocol.payload(review.messages).count) ?? 0))
                        ContextTransferArchiveView(messages: review.messages)
                    }
                    if let error = model.errorMessage { Text(error).font(.callout).foregroundStyle(.red).textSelection(.enabled) }
                }.padding(20)
            }.frame(minHeight: 220, idealHeight: 420, maxHeight: 520)
            Divider()
            HStack {
                Spacer()
                Button(submitted ? "Done" : "Cancel", action: close).keyboardShortcut(.cancelAction).disabled(model.isAccepting)
                if !submitted { Button("Create Reviewed Transfer", action: accept).disabled(!model.canConfirm) }
            }.padding(16)
        }.frame(minWidth: 400, idealWidth: 620, maxWidth: 800)
    }
    private var form: some View {
        VStack(alignment: .leading, spacing: 10) {
            Picker("Action", selection: $model.kind) {
                ForEach(ContextTransferFormKind.allCases) { kind in Text(kind.title).tag(kind).disabled(kind == .mergeBack && model.parent == nil) }
            }
            Picker("Source point", selection: $model.sourceID) {
                ForEach(model.sourceOptions) { Text($0.title).tag($0.id) }
            }
            if model.kind == .mergeBack {
                if let parent = model.parent {
                    LabeledContent("Parent conversation", value: parent.title)
                    Text("\(parent.providerName) · \(parent.workspacePath)").font(.caption).foregroundStyle(.secondary)
                } else { Text("This conversation has no available context-transfer parent.").font(.caption).foregroundStyle(.secondary) }
            } else {
                Picker("Destination provider", selection: providerBinding) {
                    ForEach(ProviderKind.builtIn) { Text($0.name).tag("provider:" + $0.rawValue) }
                }
                if model.kind == .fork {
                    Picker("Destination workspace", selection: $model.workspaceID) { ForEach(model.workspaceOptions) { Text("\($0.title) · \($0.path)").tag($0.id) } }
                } else { Text("Provider handoff keeps this app conversation and its current workspace.").font(.caption).foregroundStyle(.secondary) }
                TextField("Model (empty uses the configured CLI default)", text: $model.model)
                Picker("Permissions", selection: $model.permission) { ForEach(PermissionMode.allCases) { Text($0.title).tag($0) } }
                if model.kind == .fork { TextField("New conversation title", text: $model.title) }
            }
        }
    }
    private var providerBinding: Binding<String> {
        .init(get: { model.provider == .acp ? "agent:" + (model.agentID?.uuidString ?? "") : "provider:" + model.provider.rawValue }, set: { value in
            if value.hasPrefix("agent:"), let id = UUID(uuidString: String(value.dropFirst(6))) { model.provider = .acp; model.agentID = id }
            else if value.hasPrefix("provider:"), let kind = ProviderKind(rawValue: String(value.dropFirst(9))) { model.provider = kind; model.agentID = nil }
        })
    }
}

struct ContextTransferArchiveView: View {
    let messages: [ContextHandoffMessage]
    @State private var start = 0
    private let pageSize = 32
    var body: some View {
        DisclosureGroup("Archived Eligible Context") {
            VStack(alignment: .leading, spacing: 8) {
                Text("Items \(messages.isEmpty ? 0 : start + 1)–\(min(messages.count, start + pageSize)) of \(messages.count)").font(.caption).foregroundStyle(.secondary)
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 12) {
                        ForEach(Array(messages.dropFirst(start).prefix(pageSize))) { message in
                            VStack(alignment: .leading, spacing: 4) {
                                Text("\(message.role.capitalized) · \(message.kind)").font(.caption.weight(.semibold))
                                ContextTransferTextPreview(text: message.text)
                            }.padding(8).coincideSurface()
                        }
                    }
                }.frame(maxHeight: 240)
                HStack {
                    Button("Previous Items") { start = max(0, start - pageSize) }.disabled(start == 0)
                    Button("Next Items") { start += pageSize }.disabled(start + pageSize >= messages.count)
                }
            }
        }.font(.caption)
    }
}
struct ContextTransferTextPreview: View {
    let text: String
    @State private var end = 4_096
    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(String(text.prefix(end))).font(.caption).textSelection(.enabled)
            if text.count > end { Button("Show More Text") { end = min(text.count, end + 32_768) }.disabled(end >= 1_048_576) }
            if text.count > end { Text("Preview: \(end) of \(text.count) characters").font(.caption2).foregroundStyle(.secondary) }
        }
    }
}

struct ContextTransferDeliveryView: View {
    let strategy: ContextTransferStrategy
    let status: ContextTransferStatus
    let delivery: ContextTransferDelivery?
    let abandoned: Bool
    let error: String?
    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            Text(statusText).font(.caption.weight(.semibold))
            if let error { Text(error).font(.caption).foregroundStyle(.secondary).textSelection(.enabled) }
            if let delivery, strategy != .nativeFork {
                ContextTransferSelectionView(selection: delivery.selection, advisory: false)
            }
            if status == .uncertain {
                Text(abandoned ? "The earlier native history and uncertain outcome are retained. A future explicit message uses fresh context; the earlier input and context are not replayed." : "Input or context may have reached the provider. Nothing is replayed automatically. Inspect the recorded run before choosing fresh context.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
    }
    private var statusText: String {
        if abandoned { return "Earlier context outcome retained as uncertain" }
        switch status {
        case .pending: return strategy == .nativeFork ? "Native fork prepared for the next explicit Send" : "Portable context selected for the next explicit Send"
        case .resolvedNative, .resolvedPortable: return delivery?.status == .reserved ? "Context reserved for an explicit input" : "Delivering reviewed context…"
        case .consumed: return strategy == .nativeFork ? "Native context used by the recorded input" : "Portable context delivered to the recorded input"
        case .failed: return "Context transfer could not complete"
        case .superseded: return "Context choice superseded by a later reviewed transfer"
        case .uncertain: return "Context delivery outcome is uncertain"
        }
    }
}
struct ContextTransferSelectionView: View {
    let selection: ContextHandoffSelection
    var advisory = false
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if advisory { Text("Advisory selection · recalculated for the next actual input").font(.caption.weight(.medium)) }
            Text(selection.coverage).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
            Text("\(selection.includedIDs.count) intact items selected · \(selection.omittedIDs.count) omitted").font(.caption)
            if !selection.omittedIDs.isEmpty {
                DisclosureGroup("Omitted Item References") {
                    ScrollView { LazyVStack(alignment: .leading) {
                        ForEach(Array(selection.omittedIDs.prefix(512).enumerated()), id: \.offset) { _, id in Text(id).font(.caption.monospaced()).textSelection(.enabled) }
                        if selection.omittedIDs.count > 512 { Text("Showing the first 512 references of \(selection.omittedIDs.count).").font(.caption).foregroundStyle(.secondary) }
                    } }.frame(maxHeight: 160)
                }
            }
        }
    }
}

struct ContextTransferBanner: View {
    let store: WorkspaceStore
    let thread: CodingThread
    let mergeBack: () -> Void
    @State private var freshDelivery: ContextTransferDelivery?
    private var records: [ContextTransfer] { Array((store.snapshot.contextTransfers ?? []).filter { $0.targetThreadID == thread.id && $0.status != .superseded }.suffix(4).reversed()) }
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let lineage = thread.contextTransferLineage {
                HStack {
                    Text("Context fork").font(.caption).foregroundStyle(.secondary)
                    Button("Open Parent") { open(lineage.parentThreadID) }.disabled(store.thread(lineage.parentThreadID) == nil)
                    Button("Merge Context Back…", action: mergeBack).disabled(store.thread(lineage.parentThreadID) == nil)
                }.controlSize(.small)
            }
            ForEach(records) { transfer in
                VStack(alignment: .leading, spacing: 6) {
                    ContextTransferDeliveryView(strategy: transfer.review.strategy, status: transfer.status,
                        delivery: transfer.delivery, abandoned: transfer.abandonedAt != nil, error: transfer.error)
                    HStack {
                        Button("Open Source") { open(transfer.sourceThreadID) }.disabled(store.thread(transfer.sourceThreadID) == nil)
                        if transfer.status == .uncertain, transfer.abandonedAt == nil, let delivery = transfer.delivery,
                           records.first(where: { $0.delivery?.id == delivery.id })?.id == transfer.id {
                            Button("Use Fresh Context…") { freshDelivery = delivery }
                        }
                    }.controlSize(.small)
                }.padding(10).coincideSurface()
            }
        }
        .confirmationDialog("Use fresh context for a future explicit input?", isPresented: Binding(get: { freshDelivery != nil }, set: { if !$0 { freshDelivery = nil } })) {
            if let captured = freshDelivery {
                Button("Use Fresh Context") { freshDelivery = nil; Task { await store.useFreshContext(threadID: thread.id, deliveryID: captured.id, transferIDs: captured.transferIDs) } }
            }
            Button("Cancel", role: .cancel) { freshDelivery = nil }
        } message: { Text("The previous input and context may already have reached the provider. Its native history and uncertain audit are retained without claiming they were inspected. This retires that context choice and permits only a fresh future input. Nothing is resent, and the current draft and attachments stay unchanged.") }
    }
    private func open(_ id: UUID) { guard let target = store.thread(id) else { return }; store.selectedProjectID = target.projectID; store.showArchived = target.isArchived; store.selectedThreadID = id }
}


struct ContextTransferRunSheet: View {
    let store: WorkspaceStore
    let threadID: UUID
    let runID: UUID
    let close: () -> Void
    @State private var model: ContextTransferStore?
    var body: some View {
        Group {
            if let model { ContextTransferSheet(model: model, close: close) }
            else { ProgressView("Preparing context choices…").padding(30) }
        }.task {
            let value = store.contextTransferStore(threadID: threadID)
            value.kind = .fork; value.sourceID = "run-" + runID.uuidString; model = value
        }
    }
}
