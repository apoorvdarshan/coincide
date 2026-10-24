import CoincideCore
import SwiftUI

struct ChatView: View {
    @Bindable var store: WorkspaceStore
    let threadID: UUID
    @State private var sending = false
    @AppStorage("followUpBehavior") private var followUpBehavior = ComposerFollowUpBehavior.queue.rawValue
    @State private var referenceFileSheet = false
    @State private var skillsModel: ProviderSkillsStore?
    @State private var transcriptState = TranscriptViewState()
    @State private var transcriptSheet: TranscriptSheetRequest?
    private var thread: CodingThread? { store.thread(threadID) }
    private var actionsLocked: Bool {
        store.snapshot.isConversationHistoryLocked(threadID: threadID) ||
            store.isCheckpointRestoreLocked(threadID: threadID) || store.isPullRequestCreationLocked(threadID: threadID) ||
            store.isPullRequestCheckoutLocked(threadID: threadID)
    }
    var composerHistoryLocked: Bool {
        actionsLocked || store.claudeResumeSelectionNeedsInspection(threadID: threadID)
    }
    private var draft: Binding<String> {
        Binding(get: { thread?.draft ?? "" }, set: { store.setDraft($0, id: threadID) })
    }
    private func workspaceMenu(_ thread: CodingThread) -> some View {
        Menu {
            if thread.visibleMessages.isEmpty {
                ForEach(store.orderedProjects.filter { $0.scratch == nil }) { project in
                    Button(project.name) { store.newThread(projectID: project.id) }
                }
                Divider()
                Button("Open folder…") { store.addProject() }
                Divider()
            }
            Button("Show in Finder") {
                NSWorkspace.shared.selectFile(nil, inFileViewerRootedAtPath: thread.workspacePath)
            }.disabled(!store.workspaceReady(for: thread))
        } label: {
            Label(store.snapshot.projects.first { $0.id == thread.projectID }?.name ?? "Choose project", systemImage: "folder")
                .font(.system(size: 12)).foregroundStyle(.secondary)
        }
        .menuStyle(.borderlessButton).fixedSize()
        .accessibilityIdentifier("conversation-workspace")
        .accessibilityLabel("Conversation project").accessibilityValue(thread.workspacePath)
    }
    func submitCurrentDraft() -> Task<Bool, Never> {
        store.submit(store.thread(threadID)?.draft ?? "", threadID: threadID)
    }
    func steerCurrentDraft() -> Task<Bool, Never> {
        store.steer(store.thread(threadID)?.draft ?? "", threadID: threadID)
    }
    var body: some View {
        if let thread {
            VStack(spacing: 0) {
                if !thread.visibleMessages.isEmpty {
                HStack(spacing: 12) {
                    Text(thread.title).font(.system(size: 14, weight: .medium)).lineLimit(1)
                    Spacer()
                    workspaceMenu(thread)
                }.padding(.horizontal, 24).frame(height: 52)
                }
                if thread.visibleMessages.isEmpty {
                    Spacer(minLength: 32)
                    Text("What should we work on?").font(.system(size: 25, weight: .regular))
                        .padding(.bottom, 24)
                } else {
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 28) {
                            TranscriptRowsView(store: store, thread: thread, state: transcriptState, present: { transcriptSheet = $0 })
                                .id(TranscriptCardScope(thread: thread))
                            TranscriptWorkingIndicator(thread: thread)
                            Color.clear.frame(height: 1).id("latest")
                        }
                        .frame(minWidth: 0, maxWidth: 740).padding(.horizontal, 28).padding(.top, 24).padding(.bottom, 18)
                        .frame(minWidth: 0, maxWidth: .infinity)
                    }
                    .defaultScrollAnchor(.bottom)
                    .onChange(of: thread.visibleMessages.count) { proxy.scrollTo("latest", anchor: .bottom) }
                    .threadFind(threadID: threadID, messages: thread.visibleMessages, proxy: proxy)
                }
                }
                VStack(spacing: 10) {
                    // Keep recovery reachable for an existing interrupted history operation.
                    if composerHistoryLocked {
                        ConversationHistoryBanner(store: store, threadID: threadID)
                    }
                    PromptSteeringBanner(store: store, threadID: threadID)
                    ForEach(store.approvals[threadID, default: []]) { request in
                        ApprovalView(request: request, isResponding: store.isResponding(request, threadID: threadID), onDecision: { allow in Task { await store.respond(request, threadID: threadID, allow: allow) } },
                                     onAnswer: { answers in Task { await store.answer(request, threadID: threadID, answers: answers) } },
                                     onOption: { option in Task { await store.choose(request, threadID: threadID, optionID: option) } },
                                     onSelections: { selections in Task { await store.selectAnswers(request, threadID: threadID, selections: selections) } },
                                     onSelectionsWithNotes: { selections, notes in Task { await store.selectAnswers(request, threadID: threadID, selections: selections, notes: notes) } })
                    }
                    if !thread.queuedTurns.isEmpty { QueuedTurnsView(store: store, thread: thread) }
                    if !thread.draftAttachments.isEmpty { AttachmentShelf(store: store, attachments: thread.draftAttachments, remove: { store.removeAttachment($0, threadID: threadID) }) }
                    if store.composerDraftTools.isWorking(threadID) { HStack { ProgressView().controlSize(.small); Text("Updating draft…").font(.caption).foregroundStyle(.secondary); Spacer() } }
                    ComposerView(text: draft, provider: thread.provider, providerName: thread.providerName, permission: thread.permission,
                                 busy: store.isBusy(threadID), submitting: sending || store.isAcceptingPromptSteering(threadID) || store.isPreparingWorkspace(threadID) || store.isImportingAttachments(threadID),
                                 hasAttachments: !thread.draftAttachments.isEmpty,
                                 historyLocked: composerHistoryLocked,
                                 followUpBehavior: .init(rawValue: followUpBehavior) ?? .queue,
                                 steeringAvailable: store.steeringAvailability(threadID: threadID)?.canSteer == true,
                                 steeringExplanation: store.steeringExplanation(threadID: threadID),
                                 steer: {
                                     guard !sending else { return }; sending = true
                                     let submitted = steerCurrentDraft()
                                     Task { _ = await submitted.value; sending = false }
                                 },
                                 attach: { store.chooseAttachments(threadID: threadID) },
                                 referenceFile: store.canAccessWorkspaceFiles(thread.workspacePath) ? { referenceFileSheet = true } : nil,
                                 importProviders: { store.importAttachments(providers: $0, threadID: threadID) },
                                 setPermission: { store.setPermission($0, id: threadID) },
                                 send: {
                                     guard !sending else { return }; sending = true
                                     let submitted = submitCurrentDraft()
                                     Task {
                                         _ = await submitted.value
                                         sending = false
                                     }
                                 }, stop: { Task { await store.interrupt(threadID) } },
                                 skills: skillsModel, draftTools: store.composerDraftTools, draftThreadID: threadID, discardDraft: { store.discardComposerDraft(threadID) },
                                 modelControl: AnyView(ProviderMenu(store: store, thread: thread).disabled(actionsLocked)))
                        .disabled(store.choosingModelThreads.contains(threadID))
                    if thread.visibleMessages.isEmpty {
                        HStack(spacing: 22) {
                            workspaceMenu(thread)
                            Button { store.chooseAttachments(threadID: threadID) } label: { Label("Add files", systemImage: "paperclip") }
                            Spacer()
                        }
                        .buttonStyle(.plain).font(.system(size: 12)).foregroundStyle(.secondary)
                        .padding(.horizontal, 14).padding(.vertical, 10)
                        .background(ChatChrome.footer, in: RoundedRectangle(cornerRadius: 16))
                        .padding(.horizontal, 10).padding(.top, -10)
                    }
                }
                .frame(minWidth: 0, maxWidth: thread.visibleMessages.isEmpty ? 640 : 740).padding(.horizontal, 28).padding(.bottom, 16).frame(minWidth: 0, maxWidth: .infinity)
                if thread.visibleMessages.isEmpty { Spacer(minLength: 64) }
            }
            .frame(minWidth: 0, maxWidth: .infinity)
            .background(ChatChrome.canvas)
            .navigationTitle("Coincide")
            .task(id: store.promptSteeringKey(threadID: threadID)) {
                await store.refreshPromptSteeringAvailability(threadID: threadID)
            }
            .task(id: store.skillsScope(threadID: threadID)) { skillsModel = store.skillsStore(threadID: threadID) }
            .sheet(item: $transcriptSheet) { TranscriptSheet(store: store, threadID: threadID, request: $0, close: { transcriptSheet = nil }) }
            .sheet(isPresented: $referenceFileSheet) {
                WorkspaceFilePicker(workspace: store, path: thread.workspacePath) { path in
                    referenceFileSheet = false
                    Task { await store.insertWorkspaceReference(path: path, workspacePath: thread.workspacePath, threadID: threadID) }
                } cancel: { referenceFileSheet = false }
            }
        }
    }
}
