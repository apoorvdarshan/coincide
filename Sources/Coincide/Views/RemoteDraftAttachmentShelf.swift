import CoincideCore
import SwiftUI

struct RemoteDraftAttachmentShelf: View {
    @Bindable var store: RemoteAttachmentsStore
    @State private var showingRetained = false
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if store.isLoading { ProgressView("Loading attachment drafts…").controlSize(.small) }
            if let error = store.errorMessage {
                HStack(alignment: .top) {
                    Text(error).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                    Spacer(); Button("Dismiss") { store.dismissError() }.controlSize(.mini)
                }
            }
            if let draft = store.current {
                if !draft.hostDraftAttachments.isEmpty {
                    Text("Already in the remote composer").font(.caption).foregroundStyle(.secondary)
                    AttachmentShelf(source: store.access(target: draft.target), attachments: draft.hostDraftAttachments)
                    Text("These remote files will be included with this message.").font(.caption2).foregroundStyle(.secondary)
                }
                if !draft.entries.isEmpty {
                    AttachmentShelf(source: store.localAccess(target: draft.target), attachments: draft.entries.map(\.local), remove: store.remove)
                    ForEach(draft.entries) { entry in RemoteAttachmentTransferRow(store: store, entry: entry) }
                }
            }
            if store.isImporting { ProgressView("Importing private attachment copies…").controlSize(.small) }
            if !store.retainedDrafts.isEmpty {
                Button("Retained Attachment Drafts…") { showingRetained = true }.font(.caption)
            }
        }
        .sheet(isPresented: $showingRetained) { RemoteRetainedAttachmentDrafts(store: store) }
    }
}

private struct RemoteAttachmentTransferRow: View {
    var store: RemoteAttachmentsStore
    var entry: RemoteDraftAttachment
    var body: some View {
        HStack(spacing: 8) {
            VStack(alignment: .leading, spacing: 2) {
                Text(entry.local.name).font(.caption).lineLimit(1)
                Text(entry.errorMessage ?? entry.status).font(.caption2).foregroundStyle(.secondary)
            }
            if entry.isUploading, let request = entry.upload {
                ProgressView(value: Double(entry.completedBytes), total: Double(max(1, request.byteCount))).frame(width: 100)
                Button("Cancel Upload") { Task { await store.cancelUpload(entry.id) } }
            } else if entry.isChecking { ProgressView().controlSize(.small) }
            else if entry.requiresCheck {
                Button("Check Upload") { Task { await store.checkUpload(entry.id) } }.disabled(!store.canUpload)
            } else if !entry.isReady, entry.remote?.state != .claimed {
                Button(entry.remote == nil ? "Upload" : "Resume Upload") { Task { await store.upload(entry.id) } }.disabled(!store.canUpload)
            }
        }.controlSize(.small).accessibilityElement(children: .contain)
            .accessibilityIdentifier("remote-attachment-transfer-" + entry.id.uuidString)
    }
}

private struct RemoteRetainedAttachmentDrafts: View {
    var store: RemoteAttachmentsStore
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack { Text("Retained Attachment Drafts").font(.title2); Spacer(); Button("Done") { dismiss() }.keyboardShortcut(.cancelAction) }
            Text("Private copies stay on this Mac when you switch conversations or disconnect. Select the original conversation to upload and send them.")
                .font(.callout).foregroundStyle(.secondary)
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    ForEach(store.retainedDrafts) { draft in
                        VStack(alignment: .leading, spacing: 6) {
                            Text(draft === store.current ? "Current conversation" : "Saved conversation draft").font(.headline)
                            Text("Environment \(draft.target.environmentID.uuidString.prefix(8)) · Conversation \(draft.target.threadID.uuidString.prefix(8))")
                                .font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                            AttachmentShelf(source: store.localAccess(target: draft.target), attachments: draft.entries.map(\.local),
                                remove: { store.remove($0, target: draft.target) })
                        }
                    }
                }
            }.frame(maxHeight: 420)
        }.padding(24).frame(width: 640)
    }
}
