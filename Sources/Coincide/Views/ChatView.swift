import CoincideCore
import SwiftUI

struct ChatView: View {
    @Bindable var store: WorkspaceStore
    let threadID: UUID
    var onSettle: ((CodingThread) -> Void)? = nil
    @State private var sending = false
    @AppStorage("followUpBehavior") private var followUpBehavior = ComposerFollowUpBehavior.queue.rawValue
    @State private var worktreeSheet = false
    @State private var referenceFileSheet = false
    @State private var runHistorySheet = false
    @State private var delegatedTasksSheet = false
    @State private var contextTransferSheet = false
    @State private var contextTransferModel: ContextTransferStore?
    @State private var skillsModel: ProviderSkillsStore?
    @State private var pendingWorktree: (threadID: UUID, selection: GitWorktreeSelection, submodules: ProjectWorktreeSubmoduleMode, reviewSetup: Bool)?
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
    func submitCurrentDraft() -> Task<Bool, Never> {
        store.submit(store.thread(threadID)?.draft ?? "", threadID: threadID)
    }
    func steerCurrentDraft() -> Task<Bool, Never> {
        store.steer(store.thread(threadID)?.draft ?? "", threadID: threadID)
    }
    var body: some View {
        if let thread {
            VStack(spacing: 0) {
                HStack(spacing: 12) {
                    ProviderMenu(store: store, thread: thread)
                        .disabled(actionsLocked)
                    Spacer()
                    Menu {
                        Text(thread.workspacePath)
                        Button("Reveal Workspace") { NSWorkspace.shared.selectFile(nil, inFileViewerRootedAtPath: thread.workspacePath) }
                            .disabled(!store.workspaceReady(for: thread))
                        ExternalEditorMenu(store: store, workspacePath: thread.workspacePath, title: "Open Workspace in…")
                        Button("Run History…") { runHistorySheet = true }
                            .accessibilityIdentifier("conversation-run-history")
                        Button("Delegated Tasks…") { delegatedTasksSheet = true }
                            .accessibilityIdentifier("conversation-delegated-tasks")
                        Button("Fork Context…") { showContextTransfer(.fork) }
                        Button("Switch Provider with Context…") { showContextTransfer(.providerHandoff) }
                        Toggle("Save Run Checkpoints", isOn: Binding(
                            get: { thread.effectiveCheckpointPolicy == .automatic },
                            set: { store.setCheckpointPolicy($0 ? .automatic : .disabled, id: threadID) }))
                            .accessibilityIdentifier("conversation-run-checkpoints")
                            .disabled(actionsLocked)
                            .help("Save workspace observations before and after future messages. Already accepted messages keep their captured setting.")
                        if let settlement = thread.settlement {
                            Button("Resume Conversation") { store.requestResume(threadID, generationID: settlement.id) }
                                .disabled(settlement.phase == .resuming || actionsLocked)
                        } else if let onSettle {
                            Button("Settle Conversation…") { onSettle(thread) }.disabled(!store.canSettle(thread))
                        }
                        if thread.messages.isEmpty {
                            Button("Choose Worktree…") { worktreeSheet = true }
                                .disabled(thread.isSettled || thread.isBusy || !thread.queuedTurns.isEmpty || thread.workspacePreparation?.isRunning == true ||
                                          actionsLocked ||
                                          (store.snapshot.projects.first { $0.id == thread.projectID }?.clone.map { !$0.isReady } ?? false))
                        }
                    } label: { Label(store.selectedProject?.name ?? "Workspace", systemImage: "folder").font(.caption).foregroundStyle(.secondary) }
                    .menuStyle(.borderlessButton).fixedSize()
                    .accessibilityIdentifier("conversation-workspace")
                    .accessibilityLabel("Conversation workspace")
                    .accessibilityValue(thread.workspacePath)
                }.padding(.horizontal, 24).padding(.vertical, 12)
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 28) {
                            if thread.visibleMessages.isEmpty {
                                VStack(spacing: 12) {
                                    Text("What are we building?").font(.system(size: 29, weight: .medium))
                                    Text("Start a conversation in \(store.selectedProject?.name ?? "your project").")
                                        .font(.subheadline).foregroundStyle(.secondary)
                                }.frame(maxWidth: .infinity).padding(.top, 100).padding(.bottom, 60)
                            }
                            ForEach(thread.visibleMessages) { message in
                                MessageView(store: store, message: message, providerName: thread.providerName, workspacePath: thread.workspacePath,
                                            openFile: { url, line in store.openFile(url, line: line, workspacePath: thread.workspacePath) })
                            }
                            if thread.state == .running || thread.state == .awaitingApproval {
                                HStack(spacing: 8) {
                                    ProgressView().controlSize(.small)
                                    Text(RunCheckpointPresentation.preparingBaseline(in: thread)
                                         ? String(localized: "Preparing workspace snapshot…")
                                         : thread.state == .awaitingApproval ? String(localized: "Waiting for input…")
                                         : thread.providerActivity?.state == .idle ? String(localized: "Waiting for agent confirmation…")
                                         : String(localized: "\(thread.providerName) is working…"))
                                        .font(.caption).foregroundStyle(.secondary)
                                }
                            }
                            Color.clear.frame(height: 1).id("latest")
                        }
                        .frame(minWidth: 0, maxWidth: 760).padding(.horizontal, 28).padding(.top, 24).padding(.bottom, 18)
                        .frame(minWidth: 0, maxWidth: .infinity)
                    }
                    .defaultScrollAnchor(.bottom)
                    .onChange(of: thread.visibleMessages.count) { proxy.scrollTo("latest", anchor: .bottom) }
                }
                VStack(spacing: 10) {
                    if let group = store.projectGroup(containing: thread.projectID), group.members.count > 1 {
                        Picker("New conversations", selection: Binding(
                            get: { store.preferredProject(in: group)?.id ?? group.representative.id },
                            set: { store.setProjectGroupCheckout(group, projectID: $0) })) {
                            ForEach(group.members) { project in
                                Text(project.path).lineLimit(1).truncationMode(.middle).tag(project.id)
                                    .disabled(project.clone.map { !$0.isReady } ?? false)
                            }
                        }
                        .pickerStyle(.menu).font(.caption).foregroundStyle(.secondary)
                        .accessibilityIdentifier("new-conversation-checkout")
                        .help("Choose the checkout for a new conversation. This conversation keeps its current workspace.")
                    }
                    if let project = store.snapshot.projects.first(where: { $0.id == thread.projectID }) {
                        ProjectCloneBanner(project: project, cancel: { store.cancelProjectClone(project.id) }, retry: { store.retryProjectClone(project.id) },
                                           retrying: store.isRetryingProjectClone(project.id))
                    }
                    if let preparation = thread.workspacePreparation {
                        WorktreePreparationBanner(preparation: preparation, cancel: { store.cancelWorktreePreparation(threadID) },
                                                  retry: { store.retryWorktreePreparation(threadID) },
                                                  retrying: store.isPreparingWorkspace(threadID))
                        if thread.settlement == nil, preparation.isReady, let setup = preparation.setup {
                            WorkspaceSetupBanner(store: store, threadID: threadID, run: setup)
                        }
                    }
                    if let settlement = thread.settlement {
                        ThreadSettlementBanner(store: store, threadID: threadID, settlement: settlement)
                    }
                    RunCheckpointRestoreBanner(store: store, threadID: threadID)
                    RunCheckpointBanner(store: store, threadID: threadID)
                    ConversationHistoryBanner(store: store, threadID: threadID)
                    ContextTransferBanner(store: store, thread: thread, mergeBack: { showContextTransfer(.mergeBack) })
                    if store.isPullRequestCreationLocked(threadID: threadID) {
                        Label("Pull request creation is pending or unconfirmed. Open Changes → Pull Requests to inspect its state.", systemImage: "arrow.triangle.branch")
                            .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                            .accessibilityIdentifier("conversation-pull-request-hold")
                    }
                    PullRequestCheckoutBanner(store: store, thread: thread)
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
                                 grokRuntimeMode: ProviderConfiguration(thread: thread).effectiveGrokRuntimeMode,
                                 setGrokRuntimeMode: { store.setGrokRuntimeMode($0, threadID: threadID) },
                                 skills: skillsModel, draftTools: store.composerDraftTools, draftThreadID: threadID)
                }
                .coincideGlassGroup()
                .frame(minWidth: 0, maxWidth: 760).padding(.horizontal, 28).padding(.bottom, 16).frame(minWidth: 0, maxWidth: .infinity)
            }
            .frame(minWidth: 0, maxWidth: .infinity)
            .navigationTitle("Coincide")
            .task(id: store.promptSteeringKey(threadID: threadID)) {
                await store.refreshPromptSteeringAvailability(threadID: threadID)
            }
            .task(id: store.skillsScope(threadID: threadID)) { skillsModel = store.skillsStore(threadID: threadID) }
            .sheet(isPresented: $runHistorySheet) { RunHistorySheet(store: store, threadID: threadID) }
            .sheet(isPresented: $delegatedTasksSheet) { DelegatedTasksPanel(workspace: store, conversationID: threadID) }
            .sheet(isPresented: $contextTransferSheet) {
                if let contextTransferModel { ContextTransferSheet(model: contextTransferModel, close: { contextTransferSheet = false }) }
            }
            .sheet(isPresented: $referenceFileSheet) {
                WorkspaceFilePicker(workspace: store, path: thread.workspacePath) { path in
                    referenceFileSheet = false
                    Task { await store.insertWorkspaceReference(path: path, workspacePath: thread.workspacePath, threadID: threadID) }
                } cancel: { referenceFileSheet = false }
            }
            .sheet(isPresented: $worktreeSheet, onDismiss: {
                guard let pending = pendingWorktree else { return }
                pendingWorktree = nil
                Task { await store.prepareWorktree(for: pending.threadID, selection: pending.selection, submodules: pending.submodules, reviewSetup: pending.reviewSetup) }
            }) {
                WorktreeSetupSheet(store: store, threadID: threadID, cancel: { worktreeSheet = false }) { selection, submodules, reviewSetup in
                    pendingWorktree = (threadID, selection, submodules, reviewSetup); worktreeSheet = false
                }
            }
        }
    }
    private func showContextTransfer(_ kind: ContextTransferFormKind) {
        let model = store.contextTransferStore(threadID: threadID)
        model.kind = kind; model.sourceID = "latest"; contextTransferModel = model; contextTransferSheet = true
    }

}
