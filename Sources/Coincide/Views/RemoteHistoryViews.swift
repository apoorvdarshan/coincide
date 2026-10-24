import CoincideCore
import CryptoKit
import Foundation
import SwiftUI

struct RemoteHistoryRunActions: View {
    var model: RemoteHistoryWorkspace
    let runID: UUID
    let review: (ConversationHistoryKind) -> Void
    var body: some View {
        Menu("Conversation") {
            Button("Fork After This Run…") { review(.forkAfterRun) }
                .disabled(!model.availability(runID: runID, kind: .forkAfterRun).allowed)
                .help(model.availability(runID: runID, kind: .forkAfterRun).reason ?? "Create a separate conversation through this run.")
            Button("Rewind Before This Run…") { review(.rewindBeforeRun) }
                .disabled(!model.availability(runID: runID, kind: .rewindBeforeRun).allowed)
                .help(model.availability(runID: runID, kind: .rewindBeforeRun).reason ?? "Review the exact native context before this run. Files are kept unless separately reviewed.")
        }.menuStyle(.borderlessButton).fixedSize().font(.caption)
    }
}

struct RemoteHistoryReviewPane: View {
    var model: RemoteHistoryWorkspace
    let runID: UUID
    let kind: ConversationHistoryKind
    var attachmentAccess: AttachmentAccess?
    let close: () -> Void
    @State private var ownedKeep: UUID?
    @State private var ownedFiles: UUID?
    @State private var filesTask: Task<Void, Never>?
    @State private var submitted: RemoteHistoryReview?
    var body: some View {
        RemoteHistoryReviewContent(model: model, runID: runID, kind: kind, submitted: submitted,
            attachmentAccess: attachmentAccess, reviewFiles: prepareFiles, accept: accept, close: close)
            .interactiveDismissDisabled(model.isActing)
            .task {
                let owned = await model.prepare(runID: runID, kind: kind)
                guard !Task.isCancelled else { model.clearReview(id: owned); return }
                ownedKeep = owned
            }
            .onDisappear {
                filesTask?.cancel()
                model.clearReview(id: ownedKeep); model.clearReview(id: ownedFiles)
            }
    }
    private func prepareFiles() {
        filesTask?.cancel()
        filesTask = Task {
            let owned = await model.prepare(runID: runID, kind: kind, files: .restore)
            guard !Task.isCancelled else { model.clearReview(id: owned); return }
            ownedFiles = owned
        }
    }
    private func accept(_ review: RemoteHistoryReview) {
        Task {
            if await model.accept(review) { submitted = review }
        }
    }
}

/// Pure display. The pane wrapper owns reads and the exact review lifetime.
struct RemoteHistoryReviewContent: View {
    @Bindable var model: RemoteHistoryWorkspace
    let runID: UUID
    let kind: ConversationHistoryKind
    var submitted: RemoteHistoryReview?
    var attachmentAccess: AttachmentAccess?
    let reviewFiles: () -> Void
    let accept: (RemoteHistoryReview) -> Void
    let close: () -> Void
    private var keep: RemoteHistoryReview? { model.keepReview.flatMap { $0.value.runID == runID && $0.value.kind == kind ? $0 : nil } }
    private var files: RemoteHistoryReview? { model.filesReview.flatMap { $0.value.runID == runID && $0.value.kind == kind ? $0 : nil } }
    private var shown: RemoteHistoryReview? { submitted ?? files ?? keep }
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 6) {
                Text(kind == .forkAfterRun ? "Fork After This Remote Run" : "Rewind Before This Remote Run").font(.title2)
                Text(summary).font(.callout).foregroundStyle(.secondary)
            }.padding(20)
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    if model.isReviewing { ProgressView("Reviewing the exact native history boundary…").controlSize(.small) }
                    if let value = shown {
                        LabeledContent("Provider", value: value.value.provider.name)
                        LabeledContent("Run", value: value.value.runID.uuidString).font(.caption.monospaced())
                        Text(value.value.workspacePath).font(.caption.monospaced()).textSelection(.enabled)
                        HStack {
                            Text("\(value.value.retainedMessageCount) retained messages")
                            if kind == .rewindBeforeRun { Text("\(value.value.removedMessageCount) messages / \(value.value.removedRunCount) runs removed from the current view") }
                        }.font(.caption).foregroundStyle(.secondary)
                        if kind == .forkAfterRun { TextField("Fork title", text: $model.title).disabled(submitted != nil || model.isActing) }
                        ForEach(Array(value.value.details.enumerated()), id: \.offset) { _, detail in
                            VStack(alignment: .leading, spacing: 3) {
                                Text(detail.label).font(.caption.weight(.semibold))
                                RemoteHistoryTextBlock(model: model, binding: value.binding, value: detail.value)
                            }
                        }
                        ForEach(Array(value.value.warnings.enumerated()), id: \.offset) { _, warning in RemoteHistoryTextBlock(model: model, binding: value.binding, value: warning).foregroundStyle(.secondary) }
                        if let file = value.value.files {
                            VStack(alignment: .leading, spacing: 8) {
                                Divider()
                                Text(file.stage == .baseline ? "Original Workspace Before This Run" : "Workspace After Previous Visible Run").font(.headline)
                                Text("Working edits and staging will be lost. New files that are not ignored may be deleted. Ignored files are kept; the branch and HEAD stay unchanged.").font(.callout)
                                Text("\(file.affectedPathCount) affected paths").font(.caption)
                                RemoteHistoryTextBlock(model: model, binding: value.binding, value: file.patch, monospaced: true)
                                if file.patchTruncated { Text("The patch preview is limited. Restoration uses the complete host-reviewed manifest.").font(.caption).foregroundStyle(.secondary) }
                            }
                        }
                        RemoteHistoryPreviewBrowser(model: model, review: value, attachmentAccess: attachmentAccess).id(value.binding.leaseID)
                        if submitted != nil {
                            Text("The original action was submitted. Its saved state below determines whether provider work and any file restoration finished. It will not be sent again automatically.").font(.caption).foregroundStyle(.secondary)
                            if let operation = model.operationViews[value.id] { RemoteHistoryOperationContent(model: model, value: operation) }
                        }
                    }
                    if model.isReviewingFiles { ProgressView("Reviewing current remote files…").controlSize(.small) }
                    if let error = model.filesError ?? model.errorMessage { Text(error).font(.callout).foregroundStyle(.red).textSelection(.enabled) }
                }.padding(20)
            }.frame(minHeight: 160, idealHeight: 360, maxHeight: 440)
            Divider()
            ViewThatFits(in: .horizontal) {
                HStack { buttons }
                VStack(alignment: .trailing, spacing: 8) { buttons }
            }.frame(maxWidth: .infinity, alignment: .trailing).padding(16)
        }.frame(minWidth: 360, idealWidth: 600, maxWidth: 760)
    }
    @ViewBuilder private var buttons: some View {
        Button(submitted == nil ? "Cancel" : "Done", action: close).keyboardShortcut(.cancelAction).disabled(model.isActing)
        if submitted == nil {
            if kind == .forkAfterRun {
                Button("Fork Conversation") { if let keep { accept(keep) } }.disabled(keep.map { !model.canAccept($0) } ?? true)
            } else {
                if let files {
                    Button(files.value.provider == .claude ? "Save Point and Restore Files" : "Rewind and Restore Files", role: .destructive) { accept(files) }.disabled(!model.canAccept(files))
                } else {
                    Button("Restore Files Too…", role: .destructive, action: reviewFiles)
                        .disabled(keep?.value.restoreFiles.allowed != true || model.isReviewingFiles || model.isActing)
                        .help(keep?.value.restoreFiles.reason ?? "Review the exact saved observation and current files before restoring.")
                }
                Button(keep?.value.provider == .claude ? "Save Resume Point" : "Rewind and Keep Changes") { if let keep { accept(keep) } }
                    .disabled(keep.map { !model.canAccept($0) } ?? true)
            }
        }
    }
    private var summary: String {
        if kind == .forkAfterRun { return "Create a separate conversation through this run. The source conversation and its draft stay unchanged." }
        if shown?.value.provider == .claude { return "Save the context before this run for the next explicit Claude message. Native transcripts and current settings are retained. No message is sent." }
        return "Rewind before this run while retaining its audit. Keep current files, or separately review restoring them. Original input returns to the latest local draft only after the saved action completes."
    }
}

struct RemoteHistoryPreviewBrowser: View {
    var model: RemoteHistoryWorkspace
    let review: RemoteHistoryReview
    var attachmentAccess: AttachmentAccess?
    @State private var messages: [RemoteMessageSummary] = []
    @State private var paths: [String] = []
    @State private var messageOffset = 0
    @State private var pathOffset = 0
    @State private var messageCursor: UUID?
    @State private var pathCursor: UUID?
    @State private var messageDone = false
    @State private var pathsDone = false
    @State private var loading = false
    @State private var error: String?
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            DisclosureGroup("Reviewed Retained Transcript") {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Rows \(max(0, messageOffset - messages.count))–\(messageOffset) of \(review.value.retainedMessageCount) · immutable reviewed prefix").font(.caption).foregroundStyle(.secondary)
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 10) {
                            ForEach(messages.reversed()) { message in
                                VStack(alignment: .leading, spacing: 5) {
                                    Text(message.role.rawValue.capitalized).font(.caption.weight(.semibold))
                                    RemoteHistoryTextBlock(model: model, binding: review.binding, value: message.text)
                                    if message.attachmentCount > 0 {
                                        RemoteHistoryMessageAttachments(model: model, binding: review.binding, message: message, source: attachmentAccess)
                                    }
                                }.padding(8).coincideSurface()
                            }
                        }
                    }.frame(maxHeight: 220)
                    Button(messages.isEmpty ? "Load Reviewed Messages" : "Load Earlier Reviewed Messages") { Task { await loadMessages() } }
                        .disabled(loading || messageDone || !model.canRead)
                }.padding(.top, 6)
            }
            if let file = review.value.files {
                DisclosureGroup("Paths in This Restore") {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Rows \(max(0, pathOffset - paths.count))–\(pathOffset) of \(file.affectedPathCount)").font(.caption).foregroundStyle(.secondary)
                        ScrollView { LazyVStack(alignment: .leading) {
                            ForEach(Array(paths.enumerated()), id: \.offset) { _, path in Text(path).font(.caption.monospaced()).textSelection(.enabled) }
                        }.frame(maxWidth: .infinity, alignment: .leading) }.frame(maxHeight: 140)
                        Button(paths.isEmpty ? "Load Restore Paths" : "Load More Restore Paths") { Task { await loadPaths() } }.disabled(loading || pathsDone || !model.canRead)
                    }
                }
            }
            if let error { Text(error).font(.caption).foregroundStyle(.red) }
        }.font(.caption)
    }
    private func loadMessages() async {
        guard !loading, !messageDone else { return }; loading = true; defer { loading = false }
        do {
            let result = try await model.leasedRead(.prefix(binding: review.binding, newestFirst: true, cursor: messageCursor))
            guard case .messages(let page) = result, !Task.isCancelled else { throw RemoteHistoryFailure(.staleCursor) }
            try RemoteHistoryPageValidation.messages(page, binding: review.binding, offset: messageOffset,
                total: review.value.retainedMessageCount, retained: messages)
            messages = Array((messages + page.items).suffix(512)); messageOffset += page.items.count; messageCursor = page.nextCursor; messageDone = page.complete
        } catch { self.error = error.localizedDescription }
    }
    private func loadPaths() async {
        guard !loading, !pathsDone else { return }; loading = true; defer { loading = false }
        do {
            let result = try await model.leasedRead(.paths(binding: review.binding, cursor: pathCursor))
            guard case .paths(let page) = result, let total = review.value.files?.affectedPathCount,
                  !Task.isCancelled else { throw RemoteHistoryFailure(.staleCursor) }
            try RemoteHistoryPageValidation.paths(page, binding: review.binding, offset: pathOffset, total: total, retained: paths)
            paths = Array((paths + page.items).suffix(512)); pathOffset += page.items.count; pathCursor = page.nextCursor; pathsDone = page.complete
        } catch { self.error = error.localizedDescription }
    }
}

private struct RemoteHistoryMessageAttachments: View {
    var model: RemoteHistoryWorkspace
    let binding: RemoteHistoryBinding
    let message: RemoteMessageSummary
    let source: AttachmentAccess?
    @State private var attachments: [ChatAttachment]?
    @State private var error: String?
    var body: some View {
        if let attachments, let source { AttachmentShelf(source: source, attachments: attachments) }
        else {
            VStack(alignment: .leading) {
                Button("Load \(message.attachmentCount) Attachments") { Task { await load() } }.disabled(!model.canRead)
                if let error { Text(error).font(.caption).foregroundStyle(.secondary) }
            }
        }
    }
    private func load() async {
        guard let reference = message.attachments, reference.kind == .attachmentReferences else { return }
        do {
            let values = try JSONDecoder().decode([ChatAttachment].self, from: await model.document(reference, binding: binding))
            guard values.count == message.attachmentCount, !Task.isCancelled else { throw RemoteHistoryFailure(.invalidRequest) }
            attachments = values
        } catch { self.error = error.localizedDescription }
    }
}

@MainActor @Observable
final class RemoteHistoryTextReader {
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
    func load(model: RemoteHistoryWorkspace, binding: RemoteHistoryBinding, reference: RemoteProjectionContentReference) async {
        guard !loading, !complete else { return }; loading = true; defer { loading = false }
        do {
            let result = try await model.leasedRead(.content(binding: binding, reference: reference, offset: offset, cursor: cursor))
            guard case .content(let page) = result, page.binding == binding, page.reference == reference, page.offset == offset,
                  page.data.count <= RemoteHistoryProtocol.maximumContentChunkBytes, offset + page.data.count <= reference.totalBytes,
                  page.complete == (page.nextCursor == nil), page.complete == (offset + page.data.count == reference.totalBytes),
                  page.complete || !page.data.isEmpty, !Task.isCancelled else { throw RemoteHistoryFailure(.staleCursor) }
            hasher.update(data: page.data); data.append(page.data); offset += page.data.count; cursor = page.nextCursor; complete = page.complete
            if data.count > 1_048_576 {
                var remove = data.count - 1_048_576
                while remove < data.count, data[data.startIndex + remove] & 0xc0 == 0x80 { remove += 1 }
                data.removeFirst(remove); windowStart += remove
            }
            text = try RemoteProjectionTextReader.decodeWindow(data, complete: complete)
            if complete {
                let digest = hasher.finalize().map { String(format: "%02x", $0) }.joined()
                guard digest == reference.digest else { throw RemoteHistoryFailure(.invalidRequest) }; verified = true
            }
        } catch { self.error = error.localizedDescription }
    }
}
struct RemoteHistoryTextBlock: View {
    var model: RemoteHistoryWorkspace
    let binding: RemoteHistoryBinding
    let value: RemoteProjectionText
    var monospaced = false
    var body: some View {
        RemoteHistoryTextBlockContent(model: model, binding: binding, value: value, monospaced: monospaced)
            .id(binding.leaseID.uuidString + ":" + (value.content?.id.uuidString ?? RemoteProjectionProtocol.digest(Data(value.preview.utf8))))
    }
}
private struct RemoteHistoryTextBlockContent: View {
    var model: RemoteHistoryWorkspace
    let binding: RemoteHistoryBinding
    let value: RemoteProjectionText
    var monospaced = false
    @State private var reader = RemoteHistoryTextReader()
    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            ScrollView([.horizontal, .vertical]) {
                Text(reader.offset > 0 ? reader.text : value.preview).font(monospaced ? .system(.caption, design: .monospaced) : .caption).textSelection(.enabled)
            }.frame(maxHeight: monospaced ? 180 : 140)
            if !value.complete, let reference = value.content {
                HStack {
                    Button(reader.offset == 0 ? "Load Text" : "Load More Text") { Task { await reader.load(model: model, binding: binding, reference: reference) } }
                        .disabled(reader.loading || reader.complete || !model.canRead)
                    if reader.offset > 0 { Text("Bytes \(reader.windowStart)–\(reader.offset) of \(reference.totalBytes)\(reader.verified ? " · verified" : " · incomplete")").font(.caption2).foregroundStyle(.secondary) }
                }
                if let error = reader.error { Text(error).font(.caption).foregroundStyle(.secondary) }
            }
        }
    }
}

private enum RemoteHistoryConfirmation: String, Identifiable {
    case files
    var id: Self { self }
}
struct RemoteHistoryOperationContent: View {
    var model: RemoteHistoryWorkspace
    let value: RemoteHistoryOperationView
    @State private var confirmation: RemoteHistoryConfirmation?
    private var operation: RemoteOperationSummary { value.operation }
    private var enabled: Bool { model.canRead && model.writesAllowed && !model.isActing }
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack { Text(operation.title.preview).font(.caption.weight(.semibold)); Spacer(); Text(operation.phase).font(.caption).foregroundStyle(.secondary) }
            if operation.phase == "unconfirmed" {
                Text(value.kind == .forkAfterRun ? "The provider may have created a separate native conversation. Inspect its recorded candidate; the fork is never automatically repeated." : "The native history outcome is unconfirmed. Provider work stays paused until its exact state is inspected; the rewind is never automatically repeated.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            ForEach(Array(operation.details.enumerated()), id: \.offset) { _, detail in
                VStack(alignment: .leading, spacing: 3) {
                    Text(detail.label).font(.caption.weight(.medium))
                    RemoteHistoryTextBlock(model: model, binding: value.binding, value: detail.value)
                }
            }
            if let error = operation.error { RemoteHistoryTextBlock(model: model, binding: value.binding, value: error).foregroundStyle(.secondary) }
            ForEach(Array(operation.warnings.enumerated()), id: \.offset) { _, warning in RemoteHistoryTextBlock(model: model, binding: value.binding, value: warning).foregroundStyle(.secondary) }
            if let files = value.filesPhase {
                Text("Remote file restoration: \(files.rawValue)\(value.filesAcknowledged ? " · current files explicitly kept" : "")").font(.caption).foregroundStyle(.secondary)
                if [.failed, .unconfirmed].contains(files), !value.filesAcknowledged {
                    Text("Files or staging may be partially changed. Inspection reads saved evidence. Keeping current files releases this hold without repeating restoration or recalling the original input.").font(.caption).foregroundStyle(.secondary)
                }
            }
            ViewThatFits(in: .horizontal) { HStack { actions }; VStack(alignment: .leading, spacing: 6) { actions } }.controlSize(.small)
            if value.needsPromptRecall { Text("The original input is waiting to be appended to your latest private local draft. Recall never submits a message.").font(.caption).foregroundStyle(.secondary) }
            if value.recalled { Text("The host recorded recall. The saved local request receipt completes its merge into the latest draft; inspect any unconfirmed request before continuing.").font(.caption).foregroundStyle(.secondary) }
            if value.recallDismissed { Text("The latest draft was kept; the original input was not recalled.").font(.caption).foregroundStyle(.secondary) }
        }.textSelection(.enabled).padding(12).coincideSurface()
        .confirmationDialog(confirmationTitle, isPresented: Binding(get: { confirmation != nil }, set: { if !$0 { confirmation = nil } })) {
            if let confirmation {
                Button(confirmLabel(confirmation)) {
                    self.confirmation = nil
                    switch confirmation {
                    case .files: act(.acknowledgeFiles)
                    }
                }
            }
            Button("Cancel", role: .cancel) { confirmation = nil }
        } message: { Text(confirmationMessage) }
    }
    @ViewBuilder private var actions: some View {
        if present(.inspectProvider) { Button(value.provider == .claude && value.kind == .forkAfterRun ? "Inspect Reserved Fork" : "Inspect Provider State") { act(.inspectProvider) }.disabled(!allowed(.inspectProvider)) }
        if present(.inspectFiles) { Button("Inspect Restoration Evidence") { act(.inspectFiles) }.disabled(!allowed(.inspectFiles)) }
        if present(.acknowledgeFiles) { Button("Keep Current Files…") { confirmation = .files }.disabled(!allowed(.acknowledgeFiles)) }
        if present(.recallPrompt) { Button("Recall Prompt") { act(.recallPrompt) }.disabled(!allowed(.recallPrompt)) }
        if present(.dismissRecall) { Button("Keep Current Draft") { act(.dismissRecall) }.disabled(!allowed(.dismissRecall)) }
        if present(.openConversation) { Button("Open Fork") { act(.openConversation) }.disabled(!allowed(.openConversation)) }
    }
    private func present(_ action: RemoteOperationAction) -> Bool { operation.actions[action.rawValue]?.allowed == true }
    private func allowed(_ action: RemoteOperationAction) -> Bool {
        enabled && operation.actions[action.rawValue]?.allowed == true
    }
    private func act(_ action: RemoteOperationAction) { Task { await model.act(action, operationID: operation.id) } }
    private var confirmationTitle: String {
        switch confirmation { case .files: "Keep the current remote files?"; default: "Confirm remote recovery" }
    }
    private func confirmLabel(_ value: RemoteHistoryConfirmation) -> String {
        switch value { case .files: "Keep Current Files" }
    }
    private var confirmationMessage: String {
        switch confirmation {
        case .files: "The conversation change remains applied. Current files and staging may contain a partial restore. This keeps those bytes, releases the file hold, and leaves the latest draft unchanged. Restoration is not repeated."
        default: "Inspect the exact saved state before continuing. No earlier action is repeated."
        }
    }
}

struct RemoteHistoryBanner: View {
    var store: RemoteHistoryStore
    var body: some View {
        if let model = store.current {
            VStack(alignment: .leading, spacing: 8) {
                RemoteHistoryThreadControlsContent(model: model)
                if !model.summaries.isEmpty {
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 8) {
                            ForEach(model.summaries) { summary in
                                if let value = model.operationViews[summary.id] { RemoteHistoryOperationContent(model: model, value: value) }
                                else {
                                    VStack(alignment: .leading, spacing: 5) {
                                        Text(summary.title.preview).font(.caption.weight(.semibold))
                                        Text(summary.phase).font(.caption).foregroundStyle(.secondary)
                                        Button("Load Saved History State") { Task { await model.loadOperation(summary.id) } }.disabled(!model.canRead)
                                    }.padding(12).coincideSurface()
                                }
                            }
                        }
                    }.frame(maxHeight: 240)
                }
                if let error = model.errorMessage { Text(error).font(.caption).foregroundStyle(.secondary).textSelection(.enabled) }
            }.frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}
struct RemoteHistoryThreadControlsContent: View {
    var model: RemoteHistoryWorkspace
    var body: some View {
        if let controls = model.controls {
            VStack(alignment: .leading, spacing: 7) {
                if controls.claudeSelectionID != nil {
                    Text(controls.claudeConsumerRunID == nil ? "Saved Claude context is selected for your next explicit message. Native transcripts are retained; this history action did not send a message." : "This Claude turn is using the saved context. The matching native use must be confirmed before the selection is released.").font(.caption).foregroundStyle(.secondary)
                    if controls.canInspectClaudeResume {
                        Button("Inspect Claude Context") { Task { await model.inspectClaude() } }.disabled(!model.canRead || !model.writesAllowed || model.isActing)
                    }
                }
            }.padding(controls.claudeSelectionID == nil ? 0 : 12)
        }
    }
}
