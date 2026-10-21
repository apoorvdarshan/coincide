import CoincideCore
import SwiftUI

struct ChatView: View {
    @Bindable var store: WorkspaceStore
    let threadID: UUID
    @State private var sending = false
    @State private var worktreeSheet = false
    @State private var referenceFileSheet = false
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
                            .disabled(store.snapshot.projects.first { $0.id == thread.projectID }?.clone.map { !$0.isReady } ?? false)
                        if thread.messages.isEmpty {
                            Button("Create Worktree…") { worktreeSheet = true }
                                .disabled(store.snapshot.projects.first { $0.id == thread.projectID }?.clone.map { !$0.isReady } ?? false)
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
                            if thread.messages.isEmpty {
                                VStack(spacing: 12) {
                                    Text("What are we building?").font(.system(size: 29, weight: .medium))
                                    Text("Start a conversation in \(store.selectedProject?.name ?? "your project").")
                                        .font(.subheadline).foregroundStyle(.secondary)
                                }.frame(maxWidth: .infinity).padding(.top, 100).padding(.bottom, 60)
                            }
                            ForEach(thread.messages) { message in
                                MessageView(store: store, message: message, providerName: thread.providerName, workspacePath: thread.workspacePath,
                                            openFile: { url, line in store.openFile(url, line: line, workspacePath: thread.workspacePath) })
                            }
                            if thread.state == .running || thread.state == .awaitingApproval {
                                HStack(spacing: 8) {
                                    ProgressView().controlSize(.small)
                                    Text(thread.state == .awaitingApproval ? "Waiting for input…" : thread.providerActivity?.state == .idle ? "Waiting for agent confirmation…" : "\(thread.providerName) is working…").font(.caption).foregroundStyle(.secondary)
                                }
                            }
                            Color.clear.frame(height: 1).id("latest")
                        }
                        .frame(minWidth: 0, maxWidth: 760).padding(.horizontal, 28).padding(.top, 24).padding(.bottom, 18)
                        .frame(minWidth: 0, maxWidth: .infinity)
                    }
                    .defaultScrollAnchor(.bottom)
                    .onChange(of: thread.messages.count) { proxy.scrollTo("latest", anchor: .bottom) }
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
                    ForEach(store.approvals[threadID, default: []]) { request in
                        ApprovalView(request: request, isResponding: store.isResponding(request, threadID: threadID), onDecision: { allow in Task { await store.respond(request, threadID: threadID, allow: allow) } },
                                     onAnswer: { answers in Task { await store.answer(request, threadID: threadID, answers: answers) } },
                                     onOption: { option in Task { await store.choose(request, threadID: threadID, optionID: option) } })
                    }
                    if !thread.queuedTurns.isEmpty { QueuedTurnsView(store: store, thread: thread) }
                    if !thread.draftAttachments.isEmpty { AttachmentShelf(store: store, attachments: thread.draftAttachments, remove: { store.removeAttachment($0, threadID: threadID) }) }
                    if store.isImportingAttachments(threadID) { HStack { ProgressView().controlSize(.small); Text("Adding attachments…").font(.caption).foregroundStyle(.secondary); Spacer() } }
                    ComposerView(text: draft, provider: thread.provider, providerName: thread.providerName, permission: thread.permission,
                                 busy: store.isBusy(threadID), submitting: sending || store.isPreparingWorkspace(threadID) || store.isImportingAttachments(threadID),
                                 hasAttachments: !thread.draftAttachments.isEmpty, attach: { store.chooseAttachments(threadID: threadID) },
                                 referenceFile: store.canAccessWorkspaceFiles(thread.workspacePath) ? { referenceFileSheet = true } : nil,
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
                .frame(minWidth: 0, maxWidth: 760).padding(.horizontal, 28).padding(.bottom, 16).frame(minWidth: 0, maxWidth: .infinity)
            }
            .frame(minWidth: 0, maxWidth: .infinity)
            .navigationTitle("Coincide")
            .sheet(isPresented: $referenceFileSheet) {
                WorkspaceFilePicker(workspace: store, path: thread.workspacePath) { path in
                    referenceFileSheet = false
                    Task { await store.insertWorkspaceReference(path: path, workspacePath: thread.workspacePath, threadID: threadID) }
                } cancel: { referenceFileSheet = false }
            }
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
                ForEach(ProviderKind.builtIn) { provider in
                    Button { store.setProvider(provider, id: thread.id) } label: {
                        if provider == thread.provider { Label(provider.name, systemImage: "checkmark") } else { Text(provider.name) }
                    }
                }
                ForEach(store.snapshot.acpAgents) { agent in
                    Button { store.setACPAgent(agent, id: thread.id) } label: {
                        if thread.acpAgent == agent { Label(agent.name, systemImage: "checkmark") } else { Text(agent.name) }
                    }
                }
                Divider()
            }
            Button("Default Model") { store.setModel("", id: thread.id) }
            ForEach(store.models(for: thread)) { model in Button(model.name) { store.setModel(model.id, id: thread.id) } }
            if thread.provider == .acp {
                Divider()
                Button("Reset Agent Options") { store.resetAgentOptions(thread.id) }
                if let options = thread.providerMetadata?["configOptions"].array {
                    ForEach(options, id: \.self) { option in
                        if option["type"].string == "select", option["category"].string != "model", let id = ACPConfigurationOptions.id(option) {
                            Menu(option["name"].string ?? id) {
                                Button("Agent Default") {
                                    if option["configId"].string != nil { store.setAgentConfiguration(id, value: nil, id: thread.id) }
                                    else { store.setAgentConfig(id, value: nil, id: thread.id) }
                                }
                                ForEach(ACPConfigurationOptions.values(option), id: \.self) { value in
                                    if let selected = value["value"].string {
                                        Button(value["name"].string ?? selected) {
                                            if option["configId"].string != nil { store.setAgentConfiguration(id, value: .string(selected), id: thread.id) }
                                            else { store.setAgentConfig(id, value: selected, id: thread.id) }
                                        }
                                    }
                                }
                            }
                        } else if option["type"].string == "boolean", let id = ACPConfigurationOptions.id(option) {
                            Toggle(option["name"].string ?? id, isOn: Binding(
                                get: { (thread.agentConfiguration?[id] ?? option["currentValue"]) == .bool(true) },
                                set: { store.setAgentConfiguration(id, value: .bool($0), id: thread.id) }))
                        }
                    }
                } else {
                    Button("Agent Default Mode") { store.setAgentMode(nil, id: thread.id) }
                    ForEach(thread.providerMetadata?["modes"]["availableModes"].array ?? [], id: \.self) { mode in
                        if let id = mode["id"].string { Button(mode["name"].string ?? id) { store.setAgentMode(id, id: thread.id) } }
                    }
                }
            }
            Divider()
            Button("Refresh Models") { Task { await store.refreshModels(provider: thread.provider) } }
                .disabled(thread.provider == .acp && !store.workspaceReady(for: thread))
        } label: {
            HStack(spacing: 6) {
                Text(thread.providerName).font(.system(size: 17, weight: .semibold))
                if !thread.model.isEmpty { Text(thread.model).font(.caption).foregroundStyle(.secondary).lineLimit(1) }
            }
        }
        .menuStyle(.borderlessButton).fixedSize()
        .accessibilityLabel("Provider and model")
    }
}
