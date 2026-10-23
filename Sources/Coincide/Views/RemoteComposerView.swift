import CoincideCore
import SwiftUI

/// Both remote renderers mount this same native composer. Its references and
/// content source remain remote/local-copy scoped; no CodingThread is forged.
struct RemoteComposerView: View {
    let store: RemoteWorkspaceStore
    let threadID: UUID
    let provider: ProviderKind
    let providerName: String
    let permission: PermissionMode
    let busy: Bool
    let canStop: Bool
    let stop: () -> Void
    @State private var showingRetained = false
    @AppStorage("composerFollowUpBehavior") private var followUpBehavior = ComposerFollowUpBehavior.queue.rawValue
    var body: some View {
        let owner = store.remoteComposerScope
        VStack(alignment: .leading, spacing: 8) {
            RemoteQueuedInputsView(store: store)
            if store.composerSupported {
                if !store.composer.selected.isEmpty {
                    AttachmentShelf(source: store.composer.access, attachments: store.composer.selected, remove: { store.composer.remove($0) })
                    ScrollView(.horizontal) { HStack {
                        ForEach(store.composer.selected.filter { !$0.isImage && $0.byteCount <= 8 * 1_024 * 1_024 }) { reference in
                            Button("Expand \(reference.name)") { store.composer.expand(reference) }
                                .font(.caption).disabled(store.composer.blocksSubmission)
                        }
                    } }
                }
                if store.attachments.entries.contains(where: { $0.upload != nil }) { RemoteDraftAttachmentShelf(store: store.attachments, includeHostReferences: false) }
            } else { RemoteDraftAttachmentShelf(store: store.attachments) }
            ComposerView(text: Binding(get: { store.draft }, set: { store.setDraft($0, threadID: threadID) }),
                provider: provider, providerName: providerName, permission: permission, busy: busy,
                submitting: store.isPreparingSubmission || store.isWorking || store.composer.tools?.isWorking(threadID) == true,
                hasAttachments: store.composerSupported ? store.composer.hasAttachments : store.attachments.hasAttachments,
                historyLocked: store.selectedIsArchived || !store.canWrite || (store.composerSupported && !store.composer.canOperate),
                followUpBehavior: ComposerFollowUpBehavior(rawValue: followUpBehavior) ?? .queue,
                steeringAvailable: store.steering.canSteer && store.composerSupported,
                steeringExplanation: busy ? store.steering.explanation : nil,
                steer: { Task { guard store.selectedThreadID == threadID, owner.map({ store.remoteComposerScope?.matches($0) == true }) ?? false else { return }; await store.submit(steer: true) } },
                attach: { if store.composerSupported { store.composer.chooseAttachments() } else { store.attachments.chooseAttachments() } },
                importProviders: { providers in
                    if store.composerSupported { store.composer.tools?.importProviders(providers, threadID: threadID) }
                    else { store.attachments.importAttachments(providers: providers) }
                }, setPermission: { mode in
                    guard store.selectedThreadID == threadID, owner.map({ store.remoteComposerScope?.matches($0) == true }) ?? true, let configuration = store.selectedConfiguration else { return }
                    Task { await store.perform(.editThread(threadID: threadID, edit: .permission(mode), expectedConfiguration: configuration)) }
                }, send: { Task { guard store.selectedThreadID == threadID, owner.map({ store.remoteComposerScope?.matches($0) == true }) ?? true else { return }; await store.submit() } }, stop: { if canStop { stop() } },
                draftTools: store.composerSupported ? store.composer.tools : nil, draftThreadID: threadID, inputAccessibilityLabel: "Remote message", attachAccessibilityIdentifier: "remote-attach-files", sendAccessibilityLabel: nil, stopAccessibilityLabel: "Stop", sendAvailable: store.canSubmit, stopAvailable: canStop)
            HStack {
                if store.composer.isSaving || store.draftsSaving { ProgressView().controlSize(.small) }
                Text(store.composer.errorMessage ?? (store.draftPersistenceFailed ? "Draft could not be saved" : "Drafts and saved prompts stay on this Mac"))
                    .font(.caption).foregroundStyle(.secondary)
                Spacer()
            }
            if !store.composer.retainedDrafts.isEmpty {
                Button("Saved Drafts from Other Helper Sessions…") { showingRetained = true }.font(.caption)
                    .popover(isPresented: $showingRetained) {
                        VStack(alignment: .leading, spacing: 10) {
                            Text("Saved Local Drafts").font(.headline)
                            Text("Copy verified local text and references into the current draft. The source copy is kept; nothing is sent.").font(.caption)
                            ScrollView {
                                LazyVStack(alignment: .leading, spacing: 8) {
                                    ForEach(store.composer.retainedDrafts, id: \.scope.key) { record in
                                        Button { guard let owner else { return }; Task { await store.composer.copyRetainedDraft(record, expectedScope: owner) }; showingRetained = false } label: {
                                            VStack(alignment: .leading) {
                                                Text(String(record.draft.text.prefix(120))).lineLimit(2)
                                                Text("\(record.draft.attachments.count) attachment(s) · \(record.scope.workspacePath)").font(.caption2).lineLimit(1)
                                            }
                                        }.buttonStyle(.plain).disabled(!store.composer.canOperate)
                                    }
                                }
                            }.frame(maxHeight: 280)
                        }.padding(14).frame(width: 360)
                    }
            }
            if !store.composerSupported { Text("Update the helper to enable scoped saved prompts and selected attachment sends.").font(.caption).foregroundStyle(.secondary) }
        }
        .accessibilityIdentifier("remote-composer")
        .task(id: store.steeringSelection) { await store.updateSteering() }
    }
}
