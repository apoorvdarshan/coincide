import CoincideCore
import SwiftUI

struct ChatView: View {
    @Bindable var store: WorkspaceStore
    let threadID: UUID
    @State private var sending = false
    @State private var worktreeSheet = false
    @State private var branch = ""
    private var thread: CodingThread? { store.thread(threadID) }
    private var draft: Binding<String> {
        Binding(get: { thread?.draft ?? "" }, set: { store.setDraft($0, id: threadID) })
    }
    var body: some View {
        if let thread {
            VStack(spacing: 0) {
                HStack(spacing: 12) {
                    ProviderMenu(store: store, thread: thread)
                    Spacer()
                    Menu {
                        Text(thread.workspacePath)
                        Button("Reveal Workspace") { NSWorkspace.shared.selectFile(nil, inFileViewerRootedAtPath: thread.workspacePath) }
                        if thread.messages.isEmpty { Button("Create Worktree…") { worktreeSheet = true } }
                    } label: { Label(store.selectedProject?.name ?? "Workspace", systemImage: "folder").font(.caption).foregroundStyle(.secondary) }
                    .menuStyle(.borderlessButton).fixedSize()
                }.padding(.horizontal, 24).padding(.vertical, 12)
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 28) {
                            if thread.messages.isEmpty {
                                VStack(spacing: 12) {
                                    Text("What are we building?").font(.system(size: 29, weight: .medium))
                                    Text("Start a conversation in \(store.selectedProject?.name ?? "your project").")
                                        .font(.subheadline).foregroundStyle(.secondary)
                                }.frame(maxWidth: .infinity).padding(.top, 100).padding(.bottom, 60)
                            }
                            ForEach(thread.messages) { message in
                                MessageView(store: store, message: message, providerName: thread.provider.name, workspacePath: thread.workspacePath,
                                            openFile: { url, line in store.openFile(url, line: line, workspacePath: thread.workspacePath) })
                            }
                            if thread.state == .running {
                                HStack(spacing: 8) { ProgressView().controlSize(.small); Text("\(thread.provider.name) is working…").font(.caption).foregroundStyle(.secondary) }
                            }
                            Color.clear.frame(height: 1).id("latest")
                        }
                        .frame(maxWidth: 760).padding(.horizontal, 28).padding(.top, 24).padding(.bottom, 18)
                        .frame(maxWidth: .infinity)
                    }
                    .defaultScrollAnchor(.bottom)
                    .onChange(of: thread.messages.count) { proxy.scrollTo("latest", anchor: .bottom) }
                }
                VStack(spacing: 10) {
                    ForEach(store.approvals[threadID, default: []]) { request in
                        ApprovalView(request: request, isResponding: store.isResponding(request, threadID: threadID), onDecision: { allow in Task { await store.respond(request, threadID: threadID, allow: allow) } },
                                     onAnswer: { answers in Task { await store.answer(request, threadID: threadID, answers: answers) } })
                    }
                    if !thread.queuedTurns.isEmpty { QueuedTurnsView(store: store, thread: thread) }
                    if !thread.draftAttachments.isEmpty { AttachmentShelf(store: store, attachments: thread.draftAttachments, remove: { store.removeAttachment($0, threadID: threadID) }) }
                    if store.isImportingAttachments(threadID) { HStack { ProgressView().controlSize(.small); Text("Adding attachments…").font(.caption).foregroundStyle(.secondary); Spacer() } }
                    ComposerView(text: draft, provider: thread.provider, permission: thread.permission,
                                 busy: store.isBusy(threadID), submitting: sending || store.isPreparingWorkspace(threadID) || store.isImportingAttachments(threadID),
                                 hasAttachments: !thread.draftAttachments.isEmpty, attach: { store.chooseAttachments(threadID: threadID) },
                                 importProviders: { store.importAttachments(providers: $0, threadID: threadID) },
                                 setPermission: { store.setPermission($0, id: threadID) },
                                 send: {
                                     guard !sending else { return }; sending = true
                                     let prompt = thread.draft
                                     let submitted = store.submit(prompt, threadID: threadID)
                                     Task {
                                         _ = await submitted.value
                                         sending = false
                                     }
                                 }, stop: { Task { await store.interrupt(threadID) } })
                }
                .frame(maxWidth: 760).padding(.horizontal, 28).padding(.bottom, 16).frame(maxWidth: .infinity)
            }
            .navigationTitle("Coincide")
            .sheet(isPresented: $worktreeSheet) {
                VStack(alignment: .leading, spacing: 16) {
                    Text("Create a Worktree").font(.title2)
                    Text("Give this thread its own branch and working directory.").foregroundStyle(.secondary)
                    TextField("Branch name", text: $branch)
                    HStack { Spacer(); Button("Cancel") { worktreeSheet = false }; Button("Create") { worktreeSheet = false; Task { await store.createWorktree(for: threadID, branch: branch) } }.disabled(branch.isEmpty) }
                }.padding(24).frame(width: 430)
            }
        }
    }
}

private struct ProviderMenu: View {
    var store: WorkspaceStore
    let thread: CodingThread
    var body: some View {
        Menu {
            if thread.messages.isEmpty {
                ForEach(ProviderKind.allCases) { provider in
                    Button { store.setProvider(provider, id: thread.id) } label: {
                        if provider == thread.provider { Label(provider.name, systemImage: "checkmark") } else { Text(provider.name) }
                    }
                }
                Divider()
            }
            Button("Default Model") { store.setModel("", id: thread.id) }
            ForEach(store.models(for: thread.provider)) { model in Button(model.name) { store.setModel(model.id, id: thread.id) } }
            Divider()
            Button("Refresh Models") { Task { await store.refreshModels(provider: thread.provider) } }
        } label: {
            HStack(spacing: 6) {
                Text(thread.provider.name).font(.system(size: 17, weight: .semibold))
                if !thread.model.isEmpty { Text(thread.model).font(.caption).foregroundStyle(.secondary).lineLimit(1) }
            }
        }
        .menuStyle(.borderlessButton).fixedSize().disabled(store.isBusy(thread.id))
        .accessibilityLabel("Provider and model")
    }
}
