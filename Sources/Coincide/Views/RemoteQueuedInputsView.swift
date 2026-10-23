import CoincideCore
import SwiftUI

struct RemoteQueuedInputsView: View {
    let store: RemoteWorkspaceStore
    @State private var acknowledge: RemoteSteeringOperationSummary?
    var body: some View {
        let model = store.steering
        let queueCapture = model.state?.page.capture
        VStack(alignment: .leading, spacing: 8) {
            if model.state != nil {
                HStack {
                    Text("\(model.state?.page.totalCount ?? 0) queued").font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    Button("Refresh Queue") { Task { await model.refresh() } }.font(.caption).disabled(model.isLoading || model.editor != nil)
                }
                if !model.queue.isEmpty { ScrollView { LazyVStack(alignment: .leading, spacing: 8) {
                ForEach(model.queue) { row in
                    HStack(alignment: .top) {
                        VStack(alignment: .leading) {
                            Text(row.preview).font(.caption).lineLimit(3)
                            Text("\(row.provider.name) · \(row.model) · \(row.permission.rawValue) · \(row.attachmentCount) attachment(s)").font(.caption2).foregroundStyle(.secondary)
                        }.frame(maxWidth: .infinity, alignment: .leading)
                        Button("Steer") { Task { await model.steerQueued(row) } }.disabled(!row.canSteer || !store.canWrite || model.isWorking)
                            .help(row.reason ?? "Send this exact queued input into the running turn")
                        if store.descriptor?.capabilities.supportsRemoteQueueManagement == true {
                            Menu {
                                if let position = model.queue.firstIndex(where: { $0.id == row.id }) {
                                    if position > 0 { Button("Move Up") { let before = model.queue[position - 1].id; Task { await model.moveQueued(row, beforeID: before, expected: queueCapture) } } }
                                    if position + 1 < model.queue.count {
                                        Button("Move Down") { let before = position + 2 < model.queue.count ? model.queue[position + 2].id : nil; Task { await model.moveQueued(row, beforeID: before, expected: queueCapture) } }
                                            .disabled(position + 2 == model.queue.count && model.queueCursor != nil)
                                    }
                                }
                                Button("Remove Queued Message", role: .destructive) { Task { await model.removeQueued(row, expected: queueCapture) } }
                            } label: { Image(systemName: "ellipsis") }.disabled(!store.canWrite || model.isWorking)
                        }
                        Button("Edit") { Task { await model.edit(row, attachments: store.attachments) } }.disabled(!row.canEdit || !store.canWrite || model.isLoading)
                    }.buttonStyle(.borderless)
                }
                } }.frame(maxHeight: 220) }
                if model.queueCursor != nil { Button("Load More Queued Inputs") { Task { await model.page(.queue) } }.disabled(model.isLoading) }
                if !model.operations.isEmpty {
                    DisclosureGroup("Steering Delivery History") {
                        ScrollView { LazyVStack(alignment: .leading, spacing: 8) {
                        ForEach(model.operations) { operation in
                            HStack(alignment: .top) {
                                VStack(alignment: .leading) {
                                    Text(operation.phase.rawValue.capitalized + (operation.acknowledged ? " · acknowledged" : "")).font(.caption)
                                    Text(operation.preview).font(.caption2).lineLimit(2)
                                    if let error = operation.error { Text(error).font(.caption2).foregroundStyle(.secondary).lineLimit(3) }
                                }.frame(maxWidth: .infinity, alignment: .leading)
                                Button("Read Input") { Task { await model.inspect(operation) } }.disabled(model.isLoading)
                                if operation.phase == .unconfirmed && !operation.acknowledged { Button("Acknowledge…") { acknowledge = operation }.disabled(!store.canWrite || model.isWorking) }
                            }.buttonStyle(.borderless)
                        }
                        } }.frame(maxHeight: 250)
                        if model.operationCursor != nil { Button("Load More Delivery History") { Task { await model.page(.operations) } }.disabled(model.isLoading) }
                    }
                }
            }
            if let error = model.errorMessage { Text(error).font(.caption).foregroundStyle(.secondary) }
        }
        .sheet(item: Binding(get: { model.editor }, set: { if $0 == nil { model.closeEditor() } })) { editor in RemoteQueuedInputEditorView(store: store, model: editor) }
        .sheet(isPresented: Binding(get: { model.inspectedText != nil }, set: { if !$0 { model.inspectedText = nil } })) {
            VStack(alignment: .leading) { Text("Original Steering Input").font(.headline); TranscriptPlainTextViewport(text: model.inspectedText ?? ""); Button("Done") { model.inspectedText = nil } }.padding().frame(width: 640, height: 420)
        }
        .confirmationDialog("Acknowledge unknown steering delivery?", isPresented: Binding(get: { acknowledge != nil }, set: { if !$0 { acknowledge = nil } })) {
            Button("Acknowledge Without Repeating") {
                guard let operation = acknowledge, let state = model.state else { return }; acknowledge = nil
                Task { _ = await model.send(.acknowledge(capture: state.page.capture, operationID: operation.id, digest: operation.digest)) }
            }
        } message: { Text("The provider may already have received this input. This records your acknowledgment and never resends it. The queue remains paused until you explicitly resume it.") }
    }
}
private struct RemoteQueuedInputEditorView: View {
    let store: RemoteWorkspaceStore
    let model: RemoteSteeringEditor
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Edit Queued Message").font(.headline)
            Text("This replaces only the reviewed queued input. Its captured provider settings and your separate unsent composer draft stay intact.").font(.caption).foregroundStyle(.secondary)
            if !model.composer.selected.isEmpty { AttachmentShelf(source: model.composer.access, attachments: model.composer.selected, remove: { model.composer.remove($0) }) }
            if model.uploads.entries.contains(where: { $0.upload != nil }) { RemoteDraftAttachmentShelf(store: model.uploads, includeHostReferences: false) }
            ComposerView(text: Binding(get: { model.text }, set: { model.text = $0; model.composer.setText($0) }), provider: model.source.provider, permission: model.source.permission,
                busy: false, submitting: model.isSaving, hasAttachments: model.composer.hasAttachments, historyLocked: !store.canWrite || !model.composer.canOperate,
                attach: { model.composer.chooseAttachments() }, importProviders: { model.composer.tools?.importProviders($0, threadID: model.state.target.threadID) },
                setPermission: { _ in }, send: { Task { await store.saveQueuedEdit(model) } }, stop: {}, draftTools: model.composer.tools, draftThreadID: model.state.target.threadID,
                inputAccessibilityLabel: "Edit remote queued message", sendAccessibilityLabel: "Save Queued Message", sendAvailable: !model.requiresRefresh && !model.composer.blocksSubmission, stopAvailable: false, permissionEditable: false).disabled(model.isSaving)
            if let error = model.errorMessage ?? model.composer.errorMessage ?? model.uploads.errorMessage { Text(error).font(.caption).foregroundStyle(.secondary) }
            Button("Cancel") { store.steering.closeEditor() }.disabled(model.isSaving).keyboardShortcut(.cancelAction)
        }.padding(18).frame(width: 680).interactiveDismissDisabled(model.isSaving)
    }
}
