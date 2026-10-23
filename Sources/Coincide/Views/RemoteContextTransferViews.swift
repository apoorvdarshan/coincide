import CoincideCore
import CryptoKit
import SwiftUI

struct RemoteContextTransferSheet: View {
    @Bindable var model: RemoteContextTransferWorkspace
    let close: () -> Void
    @State private var preparing: Task<Void, Never>?
    @State private var ownedID: UUID?
    @State private var accepted = false
    var body: some View {
        RemoteContextTransferSheetContent(model: model, accepted: accepted, prepare: prepare,
            accept: { Task { accepted = await model.accept() } }, close: close)
            .interactiveDismissDisabled(model.isAccepting)
            .onDisappear { preparing?.cancel(); model.clear(id: ownedID) }
    }
    private func prepare() {
        preparing?.cancel()
        preparing = Task {
            let owned = await model.prepare()
            guard !Task.isCancelled else { model.clear(id: owned); return }
            ownedID = owned
        }
    }
}

/// Display only. Explicit buttons own review and command execution.
struct RemoteContextTransferSheetContent: View {
    @Bindable var model: RemoteContextTransferWorkspace
    var accepted = false
    let prepare: () -> Void
    let accept: () -> Void
    let close: () -> Void
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 5) {
                Text("Transfer Remote Conversation Context").font(.title2)
                Text("The remote host reviews provider context. Paths remain on that host; no message is submitted by creating a transfer.").font(.callout).foregroundStyle(.secondary)
            }.padding(20)
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    if accepted { Label("Context transfer created. Your draft and attachments remain unchanged.", systemImage: "checkmark.circle").font(.headline) }
                    else {
                        form.disabled(model.isAccepting)
                        Button("Review Context", action: prepare).disabled(!model.canPrepare)
                        if model.isReviewing { ProgressView("Reviewing remote source and destination…").controlSize(.small) }
                    }
                    if let review = model.review, let source = model.sourceConfiguration, let destination = model.destinationConfiguration {
                        ContextTransferFactsView(value: .init(id: review.id, kind: review.value.kind, strategy: review.value.strategy,
                            sourcePoint: review.value.sourcePoint, basePoint: review.value.basePoint, sourceProvider: source.provider.name,
                            destinationProvider: destination.provider.name, sourcePath: source.workspacePath, destinationPath: destination.workspacePath,
                            archiveCount: review.value.archiveItemCount, archiveBytes: review.value.archiveByteCount))
                        ForEach(Array(review.value.warnings.enumerated()), id: \.offset) { _, warning in
                            RemoteContextTextBlock(model: model, binding: review.binding, value: warning)
                        }
                        if let selection = model.previewSelection { ContextTransferSelectionView(selection: selection, advisory: true) }
                        RemoteContextArchiveBrowser(model: model, review: review).id(review.binding.leaseID)
                    }
                    if let error = model.errorMessage { Text(error).font(.callout).foregroundStyle(.red).textSelection(.enabled) }
                }.padding(20)
            }.frame(minHeight: 200, idealHeight: 420, maxHeight: 520)
            Divider()
            HStack {
                Spacer()
                Button(accepted ? "Done" : "Cancel", action: close).keyboardShortcut(.cancelAction).disabled(model.isAccepting)
                if !accepted { Button("Create Reviewed Transfer", action: accept).disabled(!model.canConfirm) }
            }.padding(16)
        }.frame(minWidth: 400, idealWidth: 640, maxWidth: 800)
    }
    private var form: some View {
        VStack(alignment: .leading, spacing: 10) {
            Picker("Action", selection: $model.kind) {
                ForEach(ContextTransferFormKind.allCases) { item in Text(item.title).tag(item).disabled(item == .mergeBack && model.inventory?.lineage == nil) }
            }
            Picker("Source point", selection: $model.sourceID) { ForEach(model.sourceOptions) { Text($0.title).tag($0.id) } }
            if !model.unloadedSourceRuns.isEmpty {
                DisclosureGroup("Load Source Checkpoints") {
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 6) {
                            ForEach(model.unloadedSourceRuns) { run in
                                Button("Load \(run.checkpointAttemptCount) observations · \(run.startedAt.formatted(date: .abbreviated, time: .shortened))") {
                                    Task { await model.loadSourceCheckpoints(runID: run.id) }
                                }.disabled(!model.canRead || model.sourceCheckpoints.isLoading)
                            }
                        }
                    }.frame(maxHeight: 160)
                }.font(.caption)
            }
            if model.kind == .mergeBack {
                if let parent = model.inventory?.lineage { LabeledContent("Actual parent", value: parent.parentThreadID.uuidString).font(.caption.monospaced()) }
                Text("Review resolves the actual parent and its current configured provider on the remote host.").font(.caption).foregroundStyle(.secondary)
            } else {
                Picker("Destination provider", selection: $model.provider) { ForEach(model.providers) { Text($0.name).tag($0) } }
                if model.kind == .fork {
                    Picker("Destination workspace", selection: $model.workspaceID) { ForEach(model.workspaceOptions) { Text("\($0.title) · \($0.path)").tag($0.id) } }
                } else { Text("Provider handoff keeps this app conversation and its current workspace.").font(.caption).foregroundStyle(.secondary) }
                TextField("Model (empty uses the host's configured default)", text: $model.model)
                Picker("Permissions", selection: $model.permission) { ForEach(PermissionMode.allCases) { Text($0.title).tag($0) } }
                if model.kind == .fork { TextField("New conversation title", text: $model.title) }
            }
            if let projection = model.projection, !projection.runsComplete {
                Text("Source choices show loaded runs. Open Remote Checkpoints and load more runs to choose an earlier source.").font(.caption).foregroundStyle(.secondary)
            }
        }
    }
}

struct RemoteContextArchiveBrowser: View {
    var model: RemoteContextTransferWorkspace
    let review: RemoteContextReview
    @State private var messages: [RemoteContextMessage] = []
    @State private var cursor: UUID?
    @State private var offset = 0
    @State private var complete = false
    @State private var loading = false
    @State private var error: String?
    var body: some View {
        DisclosureGroup("Archived Eligible Context") {
            VStack(alignment: .leading, spacing: 8) {
                Text("Items \(max(0, offset - messages.count))–\(offset) of \(review.value.archiveItemCount) · immutable reviewed archive").font(.caption).foregroundStyle(.secondary)
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 10) {
                        ForEach(messages) { message in
                            VStack(alignment: .leading, spacing: 4) {
                                Text("\(message.role.capitalized) · \(message.kind)").font(.caption.weight(.semibold))
                                RemoteContextTextBlock(model: model, binding: review.binding, value: message.text)
                            }.padding(8).coincideSurface()
                        }
                    }
                }.frame(maxHeight: 240)
                Button(offset == 0 ? "Load Context Items" : "Load More Items") { Task { await load() } }.disabled(loading || complete || !model.canRead)
                if messages.count < offset { Text("Earlier loaded rows are outside this bounded 512-item window.").font(.caption2).foregroundStyle(.secondary) }
                if let error { Text(error).font(.caption).foregroundStyle(.secondary) }
            }
        }.font(.caption)
    }
    private func load() async {
        guard !loading, !complete else { return }; loading = true; defer { loading = false }
        do {
            let result = try await model.leasedRead(.messages(binding: review.binding, cursor: cursor))
            guard case .messages(let page) = result, page.binding == review.binding, page.offset == offset,
                  page.totalCount == review.value.archiveItemCount, page.offset + page.items.count <= page.totalCount,
                  page.complete == (page.nextCursor == nil), page.complete == (page.offset + page.items.count == page.totalCount),
                  page.complete || !page.items.isEmpty, Set(page.items.map(\.id)).count == page.items.count,
                  Set(page.items.map(\.id)).isDisjoint(with: messages.map(\.id)), !Task.isCancelled else { throw RemoteContextFailure(.staleCursor) }
            messages = Array((messages + page.items).suffix(512)); offset += page.items.count; cursor = page.nextCursor; complete = page.complete; error = nil
        } catch is CancellationError { }
        catch { self.error = error.localizedDescription }
    }
}

@MainActor @Observable
final class RemoteContextTextReader {
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
    func load(model: RemoteContextTransferWorkspace, binding: RemoteHistoryBinding, reference: RemoteProjectionContentReference) async {
        guard !loading, !complete else { return }; loading = true; defer { loading = false }
        do {
            let result = try await model.leasedRead(.content(binding: binding, reference: reference, offset: offset, cursor: cursor))
            guard case .content(let page) = result, page.binding == binding, page.reference == reference, page.offset == offset,
                  page.data.count <= RemoteHistoryProtocol.maximumContentChunkBytes, offset + page.data.count <= reference.totalBytes,
                  page.complete == (page.nextCursor == nil), page.complete == (offset + page.data.count == reference.totalBytes),
                  page.complete || !page.data.isEmpty, !Task.isCancelled else { throw RemoteContextFailure(.staleCursor) }
            hasher.update(data: page.data); data.append(page.data); offset += page.data.count; cursor = page.nextCursor; complete = page.complete
            if data.count > 1_048_576 {
                var remove = data.count - 1_048_576
                while remove < data.count, data[data.startIndex + remove] & 0xc0 == 0x80 { remove += 1 }
                data.removeFirst(remove); windowStart += remove
            }
            text = try RemoteProjectionTextReader.decodeWindow(data, complete: complete)
            if complete {
                let digest = hasher.finalize().map { String(format: "%02x", $0) }.joined()
                guard digest == reference.digest else { throw RemoteContextFailure(.invalidRequest) }; verified = true
            }
            error = nil
        } catch is CancellationError { }
        catch { self.error = error.localizedDescription }
    }
}
struct RemoteContextTextBlock: View {
    var model: RemoteContextTransferWorkspace
    let binding: RemoteHistoryBinding
    let value: RemoteProjectionText
    var body: some View {
        RemoteContextTextBlockContent(model: model, binding: binding, value: value)
            .id(binding.leaseID.uuidString + ":" + (value.content?.id.uuidString ?? RemoteProjectionProtocol.digest(Data(value.preview.utf8))))
    }
}
private struct RemoteContextTextBlockContent: View {
    var model: RemoteContextTransferWorkspace
    let binding: RemoteHistoryBinding
    let value: RemoteProjectionText
    @State private var reader = RemoteContextTextReader()
    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            ScrollView([.horizontal, .vertical]) { Text(reader.offset > 0 ? reader.text : value.preview).font(.caption).textSelection(.enabled) }.frame(maxHeight: 140)
            if !value.complete, let reference = value.content {
                Button(reader.offset == 0 ? "Load Text" : "Load More Text") { Task { await reader.load(model: model, binding: binding, reference: reference) } }
                    .disabled(reader.loading || reader.complete || !model.canRead)
                if reader.offset > 0 { Text("Bytes \(reader.windowStart)–\(reader.offset) of \(reference.totalBytes) · \(reader.verified ? "verified" : "incomplete")").font(.caption2).foregroundStyle(.secondary) }
                if let error = reader.error { Text(error).font(.caption).foregroundStyle(.secondary) }
            }
        }
    }
}

struct RemoteContextTransferBanner: View {
    let store: RemoteContextTransferStore
    let mergeBack: () -> Void
    @State private var fresh: RemoteContextDeliveryControl?
    var body: some View {
        if let model = store.current {
            VStack(alignment: .leading, spacing: 8) {
                if let lineage = model.inventory?.lineage {
                    HStack {
                        Text("Context fork").font(.caption).foregroundStyle(.secondary)
                        Button("Open Parent") { model.openThread(lineage.parentThreadID) }
                        Button("Merge Context Back…", action: mergeBack).disabled(!model.canRead || !model.writesAllowed)
                    }.controlSize(.small)
                }
                if let inventory = model.inventory, inventory.pendingCount > 0 { Text("\(inventory.pendingCount) context choices pending for the next explicit input").font(.caption).foregroundStyle(.secondary) }
                ForEach(Array(model.transfers.prefix(4))) { transfer in
                    RemoteContextTransferRecordView(model: model, transfer: transfer)
                }
                if model.transfers.count > 4 || model.canLoadTransfers {
                    DisclosureGroup("Transfer History") {
                        VStack(alignment: .leading, spacing: 8) {
                            Text("Showing \(model.transfers.count) retained records from the host inventory").font(.caption).foregroundStyle(.secondary)
                            ScrollView {
                                LazyVStack(alignment: .leading, spacing: 10) {
                                    ForEach(model.transfers) { transfer in RemoteContextTransferRecordView(model: model, transfer: transfer) }
                                }
                            }.frame(maxHeight: 260)
                            if model.canLoadTransfers { Button("Load More Transfer Records") { Task { await model.loadMoreTransfers() } } }
                        }
                    }.font(.caption)
                }
                if let control = model.inventory?.uncertain, control.canUseFreshContext {
                    Button("Use Fresh Context…") { fresh = control }.disabled(!model.canRead || !model.writesAllowed || model.isAccepting)
                }
                if let error = model.errorMessage { Text(error).font(.caption).foregroundStyle(.secondary) }
            }.padding(.horizontal, 14)
            .confirmationDialog("Use fresh context for future input?", isPresented: Binding(get: { fresh != nil }, set: { if !$0 { fresh = nil } })) {
                if let fresh { Button("Use Fresh Context", role: .destructive) { self.fresh = nil; Task { await model.useFreshContext(fresh) } } }
                Button("Cancel", role: .cancel) { fresh = nil }
            } message: {
                Text("The earlier input and context may already have arrived. Their native history has not been inspected and is retained as uncertain. This retires that session choice, keeps your current draft, and permits a fresh future explicit input. It never resends the earlier input or context.")
            }
        }
    }
}

struct RemoteContextTransferRunSheet: View {
    let model: RemoteContextTransferWorkspace
    let runID: UUID
    let close: () -> Void
    var body: some View {
        RemoteContextTransferSheet(model: model, close: close)
            .task { model.kind = .fork; model.sourceID = "run-" + runID.uuidString }
    }
}


struct RemoteContextTransferRecordView: View {
    var model: RemoteContextTransferWorkspace
    let transfer: RemoteContextTransferSummary
    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text("\(strategyTitle) · \(transfer.status.rawValue)").font(.caption.weight(.semibold))
            if let delivery = transfer.deliveryStatus { Text("Recorded input context: \(delivery.rawValue)").font(.caption).foregroundStyle(.secondary) }
            if transfer.status == .uncertain { Text("Input or context may have reached the provider. Nothing is replayed automatically.").font(.caption).foregroundStyle(.secondary) }
            if let error = transfer.error, let binding = model.inventory?.binding { RemoteContextTextBlock(model: model, binding: binding, value: error) }
            if let selection = model.deliverySelections[transfer.id] { ContextTransferSelectionView(selection: selection) }
            else if transfer.selection != nil { Button("Inspect Delivered Selection") { Task { await model.loadSelection(transfer) } }.disabled(!model.canRead) }
            Button("Open Source") { model.openThread(transfer.sourceThreadID) }.controlSize(.small)
        }.padding(8).coincideSurface()
    }
    private var strategyTitle: String {
        switch transfer.strategy {
        case .nativeFork: "Native Provider Fork"
        case .portableContext: "Portable Context"
        case .deltaContext: "Context Added to Saved Provider Session"
        case .forkDeltaContext: "Portable Child Delta"
        }
    }
}
