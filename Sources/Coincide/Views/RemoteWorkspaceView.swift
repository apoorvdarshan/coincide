import AppKit
import CoincideCore
import CoincideMarkdown
import SwiftUI
import UniformTypeIdentifiers

struct RemoteWorkspacePresentation {
    var newThread: Binding<Bool>
    var addProject: Binding<Bool>
    var inspectorVisible: Binding<Bool>
}
private struct RemoteWorkspacePresentationKey: FocusedValueKey {
    typealias Value = RemoteWorkspacePresentation
}
extension FocusedValues {
    var remoteWorkspacePresentation: RemoteWorkspacePresentation? {
        get { self[RemoteWorkspacePresentationKey.self] }
        set { self[RemoteWorkspacePresentationKey.self] = newValue }
    }
}

struct RemoteWorkspaceCommands: Commands {
    @Environment(\.openWindow) private var openWindow
    /// Configured as `remote.open` in keybindings.json.
    var shortcut: KeyboardShortcut? = KeyboardShortcut("r", modifiers: [.command, .option])
    var allowsInvocation: @MainActor () -> Bool = { true }
    var body: some Commands {
        CommandMenu("Remote") {
            Button("Remote Workspaces…") { if allowsInvocation() { openWindow(id: RemoteWorkspaceStore.sceneID) } }
                .keyboardShortcut(shortcut)
        }
    }
}

struct RemoteWorkspaceView: View {
    @Bindable var store: RemoteWorkspaceStore
    var keybindings: KeybindingsStore? = nil
    @AppStorage("appearance") private var appearance = "system"
    @State private var addingConnection = false
    @State private var addingProject = false
    @State private var addingThread = false
    @State private var choosingWorktree = false
    @State private var dismissingRequest = false
    @State private var showingPullRequests = false
    @State private var showingCheckpoints = false
    @State private var contextModel: RemoteContextTransferWorkspace?
    @State private var showingContext = false
    @State private var lifecycleSettings: RemoteLifecycleSettingsPresentation?

    var body: some View {
        NavigationSplitView {
            List {
                Section("Connections") {
                    ForEach(store.connections) { connection in
                        Button {
                            Task { await store.connect(connection) }
                        } label: {
                            HStack {
                                Image(systemName: store.connection?.id == connection.id && store.isConnected ? "network" : "desktopcomputer")
                                Text(connection.name)
                                Spacer()
                                if store.connection?.id == connection.id && store.isConnected { Image(systemName: "checkmark") }
                            }
                        }
                        .disabled(store.isWorking)
                        .contextMenu {
                            Button("Forget Connection") { Task { await store.forget(connection) } }
                                .disabled(store.isWorking || (store.connection?.id == connection.id && store.isConnected))
                        }
                    }
                    Button("Add SSH Connection…", systemImage: "plus") { addingConnection = true }
                        .accessibilityIdentifier("remote-add-connection").disabled(store.isWorking)
                }
                Section {
                    Toggle("Include Archived Conversations", isOn: Binding(get: { store.includeArchived }, set: { value in Task { await store.setIncludeArchived(value) } }))
                        .disabled(!store.isConnected)
                }
                if store.usesProjection {
                    Section("Remote Projects") {
                        if store.projection.catalogOutdated { Text("Updated catalog available · Refresh to return to the first page").font(.caption).foregroundStyle(.secondary) }
                        HStack {
                            Text("Projects \(store.projection.projectWindowStart + (store.projection.projects.isEmpty ? 0 : 1))–\(store.projection.projectWindowStart + store.projection.projects.count) of \(store.projection.projectCount)").font(.caption).foregroundStyle(.secondary)
                            Spacer()
                            Button("Refresh", systemImage: "arrow.clockwise") { Task { await store.projection.refreshLatest() } }.labelStyle(.iconOnly).disabled(!store.isConnected || store.projection.isLoading)
                        }
                        ForEach(store.projection.projects) { project in
                            VStack(alignment: .leading, spacing: 5) {
                                RemoteProjectionPreview(text: project.name).font(.headline)
                                Button("New Conversation…", systemImage: "square.and.pencil") { store.selectedProjectID = project.id; addingThread = true }.disabled(!store.canWrite)
                            }
                        }
                        if store.projection.canLoadProjects { Button("Load More Projects") { Task { await store.projection.loadProjects() } } }
                    }
                    Section("Remote Conversations") {
                        Text("Conversations \(store.projection.threadWindowStart + (store.projection.threads.isEmpty ? 0 : 1))–\(store.projection.threadWindowStart + store.projection.threads.count) of \(store.projection.threadCount)").font(.caption).foregroundStyle(.secondary)
                        ForEach(store.projection.threads) { thread in
                            Button { store.selectThread(thread.id) } label: {
                                HStack { if thread.isPinned { Image(systemName: "pin.fill").font(.caption) }; if thread.isArchived { Image(systemName: "archivebox").font(.caption) }; Text(thread.title.preview).lineLimit(2); Spacer(); if store.selectedThreadID == thread.id { Image(systemName: "checkmark") } }
                            }.accessibilityIdentifier("remote-thread-\(thread.id.uuidString)")
                        }
                        if store.projection.canLoadThreads { Button("Load More Conversations") { Task { await store.projection.loadThreads() } } }
                    }
                } else {
                ForEach(store.projects) { project in
                    Section(project.name) {
                        ForEach(store.threads.filter { $0.projectID == project.id }) { thread in
                            Button { store.selectThread(thread.id) } label: {
                                HStack {
                                    if thread.isPinned { Image(systemName: "pin.fill").font(.caption) }
                                    if thread.isArchived { Image(systemName: "archivebox").font(.caption) }
                                    Text(thread.title).lineLimit(2)
                                    Spacer()
                                    if thread.isBusy { ProgressView().controlSize(.mini) }
                                    if store.selectedThreadID == thread.id { Image(systemName: "checkmark") }
                                }
                            }
                            .accessibilityIdentifier("remote-thread-\(thread.id.uuidString)")
                        }
                        Button("New Conversation…", systemImage: "square.and.pencil") {
                            store.selectedProjectID = project.id; addingThread = true
                        }.disabled(!store.canWrite)
                    }
                }
                }
            }
            .navigationSplitViewColumnWidth(min: 220, ideal: 260)
        } detail: {
            VStack(spacing: 0) {
                connectionStatus
                RemoteThreadActionsView(store: store).padding(.horizontal, 12)
                if let error = store.errorMessage ?? (store.usesProjection ? store.projection.errorMessage : nil) {
                    HStack {
                        Label(error, systemImage: "exclamationmark.triangle").textSelection(.enabled)
                        Spacer(); Button("Dismiss") { store.errorMessage = nil }
                    }.font(.callout).padding(12).background(.red.opacity(0.08))
                }
                if store.needsTrust { trustPanel }
                else {
                    HSplitView {
                        VSplitView {
                            Group {
                                if store.usesProjection, store.selectedThreadID != nil {
                                    RemoteProjectedConversationView(store: store, chooseWorktree: {
                                        store.updateWorktrees(); if store.worktrees.beginSetup() { choosingWorktree = true }
                                    }, mergeContextBack: { showContext(.mergeBack) })
                                } else if let thread = store.selectedThread { conversation(thread) }
                                else {
                                    ContentUnavailableView {
                                        Label(store.isConnected ? "Choose a remote project" : "Connect to another Mac", systemImage: "network")
                                    } description: {
                                        Text(store.isConnected ? "Add an existing folder on the remote Mac, then start a conversation." :
                                            "Use an SSH connection and the Coincide environment helper installed on that Mac. Provider sign-in stays on the remote machine.")
                                    } actions: {
                                        if store.isConnected { Button("Add Remote Project…") { addingProject = true }.disabled(!store.canWrite) }
                                        else { Button("Add SSH Connection…") { addingConnection = true }.disabled(store.isWorking) }
                                    }
                                }
                            }.frame(minHeight: 240)
                            if store.terminalsVisible {
                                VStack(spacing: 0) {
                                    if store.isConnected && store.descriptor?.capabilities.supportsRemoteTerminal != true {
                                        Text("This remote helper does not support terminals. Update CoincideEnvironment on that Mac to enable them.")
                                            .font(.caption).foregroundStyle(.secondary).padding(8)
                                    }
                                    RemoteTerminalPanel(store: store.terminals, hide: { store.terminalsVisible = false })
                                }.frame(minHeight: 160, idealHeight: 260)
                            }
                        }.frame(minWidth: 380)
                        if store.inspectorVisible {
                            RemoteWorkspaceInspectorView(store: store.inspector)
                                .frame(minWidth: 320, idealWidth: 390, maxWidth: 600)
                        }
                    }
                }
            }
        }
        .navigationTitle("Remote Workspaces")
        .background(RemoteThreadUndoWindowRegistration(store: store.threadActions, dispatcher: keybindings?.dispatcher).frame(width: 0, height: 0))
        .focusedSceneValue(\.remoteWorkspacePresentation, .init(newThread: $addingThread, addProject: $addingProject, inspectorVisible: $store.inspectorVisible))
        .toolbar {
            ToolbarItem {
                Button("Remote Automatic Settlement…", systemImage: "moon.zzz") {
                    let environmentID = store.connection?.environmentID
                    Task {
                        await store.updateLifecycle()
                        guard let environmentID, store.connection?.environmentID == environmentID,
                              let policy = store.lifecycle.policy else { return }
                        lifecycleSettings = .init(environmentID: environmentID, policy: policy)
                    }
                }.disabled(!store.isConnected || store.descriptor?.capabilities.supportsWorkspaceLifecycleControls != true)
                    .accessibilityIdentifier("remote-lifecycle-settings")
            }
            ToolbarItem {
                Menu("Transfer Context", systemImage: "arrow.triangle.branch") {
                    Button("Fork Context…") { showContext(.fork) }
                    Button("Switch Provider with Context…") { showContext(.providerHandoff) }
                }.disabled(store.contextTransfers.current?.canRead != true || !store.canWrite)
            }
            ToolbarItem {
                Button("Remote Checkpoints…", systemImage: "clock.arrow.circlepath") {
                    Task { await store.updateCheckpoints(); showingCheckpoints = true }
                }.disabled(!store.isConnected || !store.selectedThreadExists || store.descriptor?.capabilities.supportsRemoteCheckpoints != true)
                    .accessibilityIdentifier("remote-checkpoints")
            }

            ToolbarItem {
                Button("Remote Pull Requests…", systemImage: "arrow.triangle.pull") {
                    Task { await store.updatePullRequests(); showingPullRequests = true }
                }.disabled(!store.isConnected || !store.selectedThreadExists || store.descriptor?.capabilities.supportsRemotePullRequests != true)
                    .accessibilityIdentifier("remote-pull-requests")
            }
            ToolbarItem {
                Button("Toggle Remote Terminal", systemImage: "terminal") { store.terminalsVisible.toggle() }
                    .accessibilityIdentifier("remote-toggle-terminal")
            }
            ToolbarItem {
                Button("Toggle Files and Git", systemImage: "sidebar.trailing") { store.inspectorVisible.toggle() }
                    .accessibilityIdentifier("remote-toggle-inspector")
            }
            ToolbarItem { Button("Add Remote Project", systemImage: "folder.badge.plus") { addingProject = true }.disabled(!store.canWrite) }
            ToolbarItem {
                if store.isConnected {
                    Button("Disconnect", systemImage: "network.slash") { Task { await store.disconnect() } }.disabled(store.isWorking)
                } else if store.connection != nil {
                    Button("Reconnect", systemImage: "arrow.clockwise") { Task { await store.reconnect() } }.disabled(store.isWorking)
                }
            }
        }
        .task { await store.load() }
        .task(id: store.threadActionsSelection) { await store.updateThreadActions() }
        .task(id: store.inspectorSelection) { await store.updateInspector() }
        .task(id: store.lifecycleSelection) { await store.updateLifecycle() }
        .task(id: store.attachmentSelection) { await store.updateAttachments() }
        .task(id: store.checkpointSelection) { await store.updateCheckpoints() }
        .task(id: store.historySelection) { await store.updateHistory() }
        .task(id: store.contextTransferSelection) { await store.updateContextTransfers() }
        .task(id: store.pullRequestSelection) { await store.updatePullRequests() }
        .task(id: store.terminalSelection) { await store.updateTerminals() }
        .task(id: store.worktreeSelection) { store.updateWorktrees() }
        .onDisappear { Task { await store.disconnect() } }
        .preferredColorScheme(appearance == "dark" ? .dark : appearance == "light" ? .light : nil)
        .sheet(isPresented: $addingConnection) { RemoteConnectionSheet(store: store) }
        .sheet(isPresented: $addingProject) { RemoteProjectSheet(store: store) }
        .sheet(isPresented: $addingThread) { RemoteThreadSheet(store: store) }
        .sheet(item: $lifecycleSettings) { value in
            RemoteLifecycleSettingsSheet(store: store.lifecycle, environmentID: value.environmentID,
                policy: value.policy, close: { lifecycleSettings = nil })
        }
        .sheet(isPresented: $choosingWorktree) {
            RemoteWorktreeSheet(store: store.worktrees, onPrepared: { choosingWorktree = false })
        }
        .sheet(isPresented: $showingContext) { if let contextModel { RemoteContextTransferSheet(model: contextModel, close: { showingContext = false }) } }
        .sheet(isPresented: $showingCheckpoints) { RemoteRunCheckpointsSheet(store: store.checkpoints, history: store.history, contextTransfers: store.contextTransfers,
            attachmentAccess: store.attachmentTarget.map { store.attachments.access(target: $0) }) }
        .sheet(isPresented: $showingPullRequests) {
            RemotePullRequestsSheet(store: store.pullRequests, requestPush: {
                showingPullRequests = false; Task { await store.showPullRequestChanges() }
            })
        }
        .confirmationDialog("Dismiss the unconfirmed request?", isPresented: $dismissingRequest) {
            Button("Keep Draft and Dismiss") { Task { await store.dismissPending() } }
        } message: {
            Text("Inspect the remote conversation first: the request may already have run. Its local record will be retained, and nothing will be sent again automatically.")
        }
    }

    private func showContext(_ kind: ContextTransferFormKind) {
        guard let model = store.contextTransfers.current else { return }
        model.kind = kind; model.sourceID = "latest"; contextModel = model; showingContext = true
    }

    private var connectionStatus: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Label(store.connection?.name ?? "No connection", systemImage: "desktopcomputer")
                Text(store.isConnected ? "Connected" : store.needsTrust ? "Confirm environment" : "Disconnected").foregroundStyle(.secondary)
                Spacer()
                if store.isWorking { ProgressView().controlSize(.small) }
            }
            Text("Closing this window disconnects the owned host and stops its active work. Saved conversations and local drafts remain available.")
                .font(.caption).foregroundStyle(.secondary)
            if let notice = store.notice { Text(notice).font(.callout).textSelection(.enabled) }
            if store.pending != nil {
                HStack {
                    Button("Check Result") { Task { await store.checkPendingResult() } }.disabled(!store.isConnected || store.isWorking)
                    Button("Dismiss Unconfirmed Request…") { dismissingRequest = true }.disabled(store.isWorking)
                }
            }
        }.padding(12).coincideSurface(cornerRadius: 0)
    }

    private var trustPanel: some View {
        VStack(alignment: .leading, spacing: 18) {
            Label("Confirm this remote environment", systemImage: "checkmark.shield").font(.title2)
            Text("SSH has verified the host. Check this environment identity before saving the connection. Future connections must return the same identity.")
            if let descriptor = store.descriptor {
                LabeledContent("Environment", value: descriptor.label)
                LabeledContent("Identity") { Text(descriptor.environmentID.uuidString).font(.system(.callout, design: .monospaced)).textSelection(.enabled) }
            }
            HStack {
                Button("Cancel") { Task { await store.disconnect() } }
                Button("Trust and Connect") { Task { await store.trustDiscoveredEnvironment() } }.buttonStyle(.borderedProminent)
            }.disabled(store.isWorking)
        }.padding(30).frame(maxWidth: 680, maxHeight: .infinity, alignment: .topLeading)
    }

    private func conversation(_ thread: CodingThread) -> some View {
        VStack(spacing: 0) {
            RemoteConversationHeader(store: store, thread: thread)
            if store.descriptor?.capabilities.supportsWorkspaceLifecycleControls == true {
                RemoteLifecycleControls(store: store.lifecycle, supportsScriptReview: store.descriptor?.capabilities.supportsReviewedSettleScripts == true).padding(.horizontal, 14).padding(.bottom, 8)
            }
            if store.descriptor?.capabilities.supportsReviewedSettleScripts == true, thread.settlement != nil {
                RemoteProjectScriptPanel(store: store.projectScripts).padding(.horizontal, 14).padding(.bottom, 8)
            }
            if let usage = thread.liveProviderUsage {
                DisclosureGroup("Latest Provider Status") {
                    ProviderUsageView(usage: usage, showMainAgent: thread.activeRun != nil)
                }.padding(.horizontal, 14).padding(.bottom, 8)
            }
            HStack {
                Button("Choose Worktree…", systemImage: "arrow.triangle.branch") {
                    store.updateWorktrees()
                    if store.worktrees.beginSetup() { choosingWorktree = true }
                }
                .disabled(!store.worktrees.canChoose)
                .accessibilityIdentifier("remote-choose-worktree")
                if store.isConnected && store.descriptor?.capabilities.supportsRemoteWorktrees != true {
                    Text("Update the remote helper to enable worktrees.").font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
            }.padding(.horizontal, 14).padding(.bottom, 8)
            RemoteWorktreeBanner(store: store.worktrees)
            RemotePullRequestBanner(store: store.pullRequests)
            RemoteRunCheckpointBanner(store: store.checkpoints)
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 24) {
                        ForEach(thread.visibleMessages) { message in
                            RemoteMessageView(message: message, source: store.attachmentTarget.map { store.attachments.access(target: $0) })
                        }
                        if thread.isBusy { Label("\(thread.providerName) is working on the remote Mac…", systemImage: "ellipsis").font(.caption).foregroundStyle(.secondary) }
                        Color.clear.frame(height: 1).id("remote-latest")
                    }.frame(maxWidth: 760, alignment: .leading).padding(24).frame(maxWidth: .infinity)
                }
                .defaultScrollAnchor(.bottom)
                .onChange(of: thread.visibleMessages.count) { proxy.scrollTo("remote-latest", anchor: .bottom) }
            }
            if let request = thread.runtimeRequests.first {
                ApprovalView(request: request.request, isResponding: request.responding || !store.canWrite,
                    onDecision: { response(thread, request.request, .decision($0)) },
                    onAnswer: { response(thread, request.request, .answers($0)) },
                    onOption: { response(thread, request.request, .option($0)) },
                    onSelections: { response(thread, request.request, .selections($0)) },
                    onSelectionsWithNotes: { response(thread, request.request, .selectionsWithNotes(selections: $0, notes: $1)) })
                    .id(request.id).padding(.horizontal, 20)
            }
            if !thread.queuedTurns.isEmpty {
                HStack {
                    Text("\(thread.queuedTurns.count) queued").font(.caption)
                    if thread.queuePaused {
                        Button("Resume Queue") {
                            Task { await store.perform(.resumeQueue(threadID: thread.id, expectedConfiguration: .init(thread: thread))) }
                        }.disabled(!store.canWrite)
                    }
                    Spacer()
                }.padding(.horizontal, 24)
            }
            VStack(alignment: .leading, spacing: 8) {
                RemoteComposerView(store: store, threadID: thread.id, provider: thread.provider, providerName: thread.providerName,
                    permission: thread.permission, busy: thread.isBusy, canStop: store.canWrite && thread.runtimeID != nil,
                    stop: { Task { await store.stop(thread) } })
            }.padding(14).coincideSurface(cornerRadius: 20).padding(18)
                .onDrop(of: [UTType.fileURL.identifier, UTType.image.identifier], isTargeted: nil) { providers in
                    if store.composerSupported, let scope = store.remoteComposerScope {
                        guard store.composer.canOperate else { return false }
                        store.composer.tools?.importProviders(providers, threadID: scope.threadID); return true
                    }
                    guard store.attachments.canImport else { return false }
                    store.attachments.importAttachments(providers: providers); return true
                }
        }
    }

    private func response(_ thread: CodingThread, _ request: ApprovalRequest, _ value: ProviderApprovalResponse) {
        Task { await store.respond(request, thread: thread, response: value) }
    }
}

private struct RemoteConversationHeader: View {
    @Bindable var store: RemoteWorkspaceStore
    let thread: CodingThread
    @State private var model = ""
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(thread.title).font(.headline)
                Text(thread.providerName).font(.caption).foregroundStyle(.secondary)
                Spacer()
                Picker("Permissions", selection: Binding(get: { thread.permission }, set: { edit(.permission($0)) })) {
                    ForEach(PermissionMode.allCases) { Text($0.title).tag($0) }
                }.fixedSize().disabled(!store.canWrite)
            }
            if store.descriptor?.capabilities.supportsRemoteCheckpoints == true {
                Picker("Run checkpoints", selection: Binding(get: { thread.effectiveCheckpointPolicy }, set: { edit(.checkpointPolicy($0, expected: thread.effectiveCheckpointPolicy)) })) {
                    Text("Automatic").tag(RunCheckpointPolicy.automatic)
                    Text("Disabled").tag(RunCheckpointPolicy.disabled)
                }.fixedSize().disabled(!store.canWrite)
            }
            Text(thread.workspacePath).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
            HStack {
                TextField("Model identifier (empty uses CLI default)", text: $model).onSubmit { edit(.model(model)) }
                Button("Use Model") { edit(.model(model)) }.disabled(!store.canWrite || model == thread.model)
            }.disabled(!store.canWrite)
        }.padding(14)
        .onAppear { model = thread.model }
        .onChange(of: thread.id) { model = thread.model }
        .onChange(of: thread.model) { model = thread.model }
    }
    private func edit(_ value: RemoteEnvironmentThreadEdit) {
        Task { await store.perform(.editThread(threadID: thread.id, edit: value, expectedConfiguration: .init(thread: thread))) }
    }
}

private struct RemoteMessageView: View {
    @AppStorage("renderMathInMarkdown") private var renderMathInMarkdown = false
    let message: ChatMessage
    let source: AttachmentAccess?
    @State private var expanded = false
    @State private var hovered = false
    @AppStorage(TranscriptPreferences.timestampFormatKey) private var timestampFormat = TranscriptTimestampFormat.system.rawValue
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let attachments = message.attachments, !attachments.isEmpty, let source { AttachmentShelf(source: source, attachments: attachments) }
            // Remote paths never resolve against this Mac: no workspace and no file opening.
            if message.role == .tool {
                let card = TranscriptToolPresentation.card(for: message)
                if card.kind == .plan, let plan = card.plan { PlanCardView(plan: plan, expanded: $expanded) }
                else { ToolCardView(card: card, entity: message.providerEntity, expanded: $expanded) }
            } else if message.role == .reasoning {
                ReasoningRowView(text: message.text, live: false, duration: nil, expanded: $expanded)
            } else if message.role == .user {
                HStack { Spacer(minLength: 60); UserMessageBody(text: message.text, expanded: $expanded).padding(14).background(.quaternary, in: RoundedRectangle(cornerRadius: 18)) }
            } else {
                // No local workspace URL: a remote file link must never resolve
                // against files on this Mac.
                MarkdownView(message.text, mathEnabled: renderMathInMarkdown)
            }
            if message.role == .user || message.role == .assistant {
                MessageActionsBar(message: message, role: message.role,
                    actions: .init(timestamps: .init(format: .init(rawValue: timestampFormat) ?? .system)),
                    steered: message.promptSteeringID != nil, visible: hovered)
            }
        }.frame(maxWidth: .infinity, alignment: .leading)
        .onHover { hovered = $0 }
    }
}

private struct RemoteConnectionSheet: View {
    @Bindable var store: RemoteWorkspaceStore
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var target = ""
    @State private var port = ""
    @State private var helper = "/usr/local/bin/CoincideEnvironment"
    @State private var directory = ""
    @State private var error: String?
    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("Add SSH Connection").font(.title2)
            Form {
                TextField("Name", text: $name).accessibilityIdentifier("remote-connection-name")
                TextField("SSH host or user@host", text: $target).accessibilityIdentifier("remote-connection-target")
                TextField("Port (optional)", text: $port).accessibilityIdentifier("remote-connection-port")
                TextField("Helper path on remote Mac", text: $helper).accessibilityIdentifier("remote-connection-helper")
                TextField("Data directory on remote Mac", text: $directory).accessibilityIdentifier("remote-connection-directory")
            }
            Text("Install the CoincideEnvironment helper on the remote Mac first. Use absolute remote paths. SSH uses your configured keys and known hosts; first-time host verification and password sign-in must be completed in Terminal.")
                .font(.callout).foregroundStyle(.secondary)
            if let error { Text(error).foregroundStyle(.red).accessibilityIdentifier("remote-connection-error") }
            HStack {
                Spacer(); Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction).accessibilityIdentifier("remote-connection-cancel")
                Button("Inspect Connection") { connect() }.keyboardShortcut(.defaultAction)
                    .accessibilityIdentifier("remote-connection-inspect")
                    .disabled(target.isEmpty || directory.isEmpty || store.isWorking)
            }
        }.padding(24).frame(width: 570)
    }
    private func connect() {
        let number = port.isEmpty ? nil : Int(port)
        guard port.isEmpty || number.map({ (1...65_535).contains($0) }) == true else { error = "Enter a port between 1 and 65535."; return }
        let configuration = SSHRemoteEnvironmentConfiguration(target: target, port: number, helperPath: helper, dataDirectory: directory)
        do { try configuration.validate() }
        catch { self.error = error.localizedDescription; return }
        let selected = RemoteWorkspaceConnection(name: name.isEmpty ? target : name, configuration: configuration)
        dismiss(); Task { await store.connect(selected) }
    }
}

private struct RemoteProjectSheet: View {
    @Bindable var store: RemoteWorkspaceStore
    @Environment(\.dismiss) private var dismiss
    @State private var path = ""
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Add Remote Project").font(.title2)
            TextField("Absolute folder path on the remote Mac", text: $path)
            Text("Choose an existing folder on \(store.connection?.name ?? "the remote Mac").").foregroundStyle(.secondary)
            HStack {
                Spacer(); Button("Cancel") { dismiss() }
                Button("Add Project") {
                    Task { if await store.perform(.addProject(id: UUID(), path: path, title: nil)) { dismiss() } }
                }.disabled(!store.canWrite || !path.hasPrefix("/"))
            }
        }.padding(24).frame(width: 500)
    }
}

private struct RemoteThreadSheet: View {
    @Bindable var store: RemoteWorkspaceStore
    @Environment(\.dismiss) private var dismiss
    @State private var provider: ProviderKind = .codex
    @State private var title = "New thread"
    @State private var checkpointPolicy: RunCheckpointPolicy = .automatic
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("New Remote Conversation").font(.title2)
            TextField("Title", text: $title)
            Picker("Provider", selection: $provider) {
                ForEach(store.descriptor?.capabilities.providers ?? []) { Text($0.name).tag($0) }
            }
            if store.descriptor?.capabilities.supportsRemoteCheckpoints == true {
                Picker("Run checkpoints", selection: $checkpointPolicy) {
                    Text("Automatic").tag(RunCheckpointPolicy.automatic)
                    Text("Disabled").tag(RunCheckpointPolicy.disabled)
                }
            }
            Text("The provider uses its existing sign-in on the remote Mac. New conversations start with supervised permissions.").font(.callout).foregroundStyle(.secondary)
            HStack {
                Spacer(); Button("Cancel") { dismiss() }
                Button("Create") {
                    guard let projectID = store.selectedProjectID else { return }
                    let id = UUID()
                    Task {
                        if await store.perform(.createThread(id: id, projectID: projectID, provider: provider, title: title, model: "", permission: .supervised, checkpointPolicy: store.descriptor?.capabilities.supportsRemoteCheckpoints == true ? checkpointPolicy : nil)) {
                            store.selectThread(id); dismiss()
                        }
                    }
                }.disabled(!store.canWrite || store.selectedProjectID == nil)
            }
        }.padding(24).frame(width: 490)
    }
}
