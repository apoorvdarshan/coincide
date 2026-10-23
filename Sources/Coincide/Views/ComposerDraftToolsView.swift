import SwiftUI

struct ComposerStashMenu: View {
    let store: ComposerDraftToolsStore
    let threadID: UUID
    @Binding var showing: Bool
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack { Text("Stashed Prompts").font(.headline); Spacer(); Button("Done") { showing = false } }
            Text("Saved on this Mac. Restoring adds to the current thread's draft without sending.")
                .font(.caption).foregroundStyle(.secondary)
            if store.stashes(threadID).isEmpty {
                ContentUnavailableView("No Stashed Prompts", systemImage: "bookmark", description: Text("Use Stash Prompt or ⌘S while writing a message."))
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 8) {
                        ForEach(store.stashes(threadID)) { entry in
                            HStack(alignment: .top) {
                                Button {
                                    store.restore(entry.id, threadID: threadID); showing = false
                                } label: {
                                    VStack(alignment: .leading, spacing: 4) {
                                        Text(entry.snippet).lineLimit(2).multilineTextAlignment(.leading)
                                        HStack {
                                            Text(entry.createdAt, style: .relative)
                                            if !entry.draft.attachments.isEmpty { Label("\(entry.draft.attachments.count)", systemImage: "paperclip") }
                                        }.font(.caption2).foregroundStyle(.secondary)
                                        if entry.draft.threadID != threadID { Text("Saved from another thread").font(.caption2).foregroundStyle(.secondary) }
                                    }.frame(maxWidth: .infinity, alignment: .leading)
                                }.buttonStyle(.plain).accessibilityLabel("Restore stashed prompt: \(entry.snippet)")
                                Button { store.delete(entry.id) } label: { Image(systemName: "trash") }
                                    .buttonStyle(.plain).accessibilityLabel("Delete stashed prompt")
                            }.padding(8).coincideSurface(cornerRadius: 8)
                                .disabled(store.isWorking(threadID) || store.hasUnresolved(threadID) || store.stopping
                                    || store.pending.contains { $0.purpose == .restore(entry.id) || $0.purpose == .stash(entry.id) })
                        }
                    }
                }.frame(maxHeight: 280)
            }
            if !store.pending.isEmpty {
                Divider()
                Text("Unconfirmed Draft Changes").font(.caption.weight(.medium))
                Text("Check the original result, including saved prompts from closed or removed threads. Changes are never repeated.")
                    .font(.caption2).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                ScrollView {
                    VStack(spacing: 8) {
                        ForEach(store.pending) { operation in
                            HStack {
                                Text("Draft change unconfirmed").font(.caption)
                                Spacer(minLength: 6)
                                Button("Check Result") { store.checkResult(operation.id) }.font(.caption)
                                    .disabled(store.isWorking(operation.replacement.expected.threadID) || store.stopping)
                                    .accessibilityIdentifier("composer-stash-check-result")
                            }
                        }
                    }
                }.frame(maxHeight: 120)
            }
        }.padding(14).frame(width: 360)
    }
}

struct ComposerDraftToolsFeedback: View {
    let store: ComposerDraftToolsStore
    let threadID: UUID
    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            if let error = store.errorMessage {
                HStack(alignment: .top) {
                    Text(error).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 4)
                    Button { store.clearError() } label: { Image(systemName: "xmark") }.buttonStyle(.plain).accessibilityLabel("Dismiss draft notice")
                }
            } else if let notice = store.notice { Text(notice).font(.caption).foregroundStyle(.secondary) }
            ForEach(store.unresolved(threadID)) { operation in
                HStack {
                    Label("Draft change unconfirmed", systemImage: "questionmark.circle").font(.caption)
                    Spacer()
                    Button("Check Result") { store.checkResult(operation.id) }.font(.caption)
                        .disabled(store.isWorking(threadID) || store.stopping)
                }.accessibilityIdentifier("composer-draft-check-result")
            }
            if !store.importItems(threadID).isEmpty {
                ScrollView {
                    VStack(alignment: .leading, spacing: 6) {
                        ForEach(store.importItems(threadID)) { item in
                            HStack(alignment: .top, spacing: 8) {
                                if item.state == .importing { ProgressView().controlSize(.small) }
                                else { Image(systemName: item.state == .unconfirmed ? "questionmark.circle" : "exclamationmark.triangle").foregroundStyle(.secondary) }
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(item.name).font(.caption).lineLimit(1)
                                    if let message = item.message { Text(message).font(.caption2).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true) }
                                    else if item.state == .importing { Text("Adding attachment…").font(.caption2).foregroundStyle(.secondary) }
                                    if item.state == .needsReattach { Text("Choose the file again; no complete original copy was captured.").font(.caption2).foregroundStyle(.secondary) }
                                }
                                Spacer(minLength: 2)
                                if item.state == .failed {
                                    Button("Retry") { store.retryImport(item.id) }.font(.caption)
                                        .accessibilityLabel("Retry \(item.name)").disabled(store.stopping || store.isWorking(threadID) || store.hasUnresolved(threadID))
                                }
                                if item.state != .importing && item.state != .unconfirmed {
                                    Button { store.removeImport(item.id) } label: { Image(systemName: "xmark.circle") }
                                        .buttonStyle(.plain).accessibilityLabel("Remove failed attachment \(item.name)")
                                }
                            }
                        }
                    }
                }.frame(maxHeight: 115)
            }
        }
    }
}
