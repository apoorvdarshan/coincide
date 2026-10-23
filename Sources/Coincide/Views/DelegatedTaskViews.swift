import CoincideCore
import SwiftUI

struct DelegatedTasksPanel: View {
    @Bindable var workspace: WorkspaceStore
    let conversationID: UUID
    @State private var model = DelegatedTasksStore()
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        DelegatedTasksPanelContent(model: model, close: { dismiss() })
            .onChange(of: workspace.snapshot, initial: true) { update() }
            .onChange(of: conversationID) { update() }
            .task {
                await withTaskCancellationHandler {
                    await model.waitForClose(); await model.shutdown()
                } onCancel: { Task { @MainActor in model.stop() } }
            }
            .onDisappear { model.stop() }
    }
    private func update() {
        model.update(conversationID: conversationID, snapshot: workspace.snapshot,
            transport: .init(inspect: { [weak workspace] parent, task in
                guard let workspace else { throw CancellationError() }
                return try await workspace.inspectDelegatedTask(parentThreadID: parent, taskID: task)
            }, cancel: { [weak workspace] parent, task, command in
                guard let workspace else { throw CancellationError() }
                return try await workspace.cancelDelegatedTask(parentThreadID: parent, taskID: task, commandID: command)
            }), open: { [weak workspace] id in
                guard let workspace, let target = workspace.thread(id) else { return }
                workspace.selectedProjectID = target.projectID; workspace.showArchived = target.isArchived
                workspace.selectedThreadID = id; dismiss()
            })
    }
}

struct DelegatedTasksPanelContent: View {
    @Bindable var model: DelegatedTasksStore
    let close: () -> Void
    @State private var confirmingCancel = false
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("Delegated Tasks").font(.title2)
                Spacer()
                if let parent = model.parentConversationID { Button("Parent Conversation") { model.open(parent) } }
                Button("Done", action: close).keyboardShortcut(.cancelAction)
            }.padding(20)
            Divider()
            if model.tasks.isEmpty {
                ContentUnavailableView("No Delegated Tasks", systemImage: "person.2", description: Text("Tasks created by this conversation appear here. Provider-native tool activity remains in the transcript."))
                    .frame(minHeight: 250)
            } else {
                HSplitView {
                    List(model.tasks) { task in
                        Button { model.inspect(task.id) } label: {
                            VStack(alignment: .leading, spacing: 4) {
                                Text(task.request.title ?? String(task.request.task.prefix(120))).lineLimit(2)
                                Text("\(task.request.role.rawValue.capitalized) · \(task.request.configuration.provider.name) · \(task.status.rawValue.capitalized)")
                                    .font(.caption).foregroundStyle(.secondary)
                            }.frame(maxWidth: .infinity, alignment: .leading).padding(.vertical, 3)
                        }.buttonStyle(.plain).accessibilityIdentifier("delegated-task-\(task.id)")
                    }.frame(minWidth: 180, idealWidth: 250, maxWidth: 320)
                    ScrollView {
                        if let task = model.selectedTask { details(task).padding(18) }
                        else { ContentUnavailableView("Select a Task", systemImage: "list.bullet", description: Text("View its result or open the child conversation.")) }
                    }.frame(minWidth: 230, idealWidth: 410, maxWidth: .infinity)
                }.frame(minHeight: 280, idealHeight: 400, maxHeight: 580)
            }
            if let error = model.errorMessage { Text(error).font(.caption).foregroundStyle(.red).textSelection(.enabled).padding(12) }
            if let notice = model.notice { Text(notice).font(.caption).foregroundStyle(.secondary).padding(12) }
        }.frame(minWidth: 460, idealWidth: 720, maxWidth: 1000)
        .accessibilityIdentifier("delegated-tasks-panel")
        .confirmationDialog("Cancel this delegated task and its owned child work?", isPresented: $confirmingCancel) {
            Button("Cancel Task", role: .destructive) { model.cancelSelected() }
        } message: { Text("Cancellation is explicit. Inspect the child conversation afterward; completed work and its saved result are retained.") }
    }
    private func details(_ task: DelegatedTask) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(task.request.title ?? "Delegated Task").font(.headline)
            LabeledContent("Role", value: task.request.role.rawValue.capitalized)
            LabeledContent("Provider", value: task.request.configuration.provider.name)
            LabeledContent("Status", value: task.status.rawValue.capitalized)
            LabeledContent("Workspace", value: task.request.isolation == .worktree ? "Isolated worktree" : "Shared parent workspace")
            if model.isInspecting { ProgressView("Inspecting task…").controlSize(.small) }
            Text("Child requests: \(model.pendingQuestionCount) questions · \(model.pendingApprovalCount) approvals").font(.caption)
            if model.pendingQuestionCount + model.pendingApprovalCount > 0 {
                Text("Open the child conversation to review and answer its requests.").font(.caption).foregroundStyle(.secondary)
            }
            HStack {
                Button("Parent") { model.open(task.parentThreadID) }
                Button("Open Child") { model.open(task.childThreadID) }.disabled(model.child == nil)
                Button("Refresh") { model.inspect(task.id) }.disabled(model.isInspecting)
            }.controlSize(.small)
            if let result = task.result { resultView(result, title: "Original Task Result") }
            else { Text("The original task has no confirmed terminal result yet.").font(.caption).foregroundStyle(.secondary) }
            if let later = model.latestChildResult { resultView(later, title: "Latest Child Follow-up") }
            if model.hasPendingChildRuns { Text("The child has additional work pending.").font(.caption).foregroundStyle(.secondary) }
            Button(model.cancellingTaskIDs.contains(task.id) ? "Cancelling…" : "Cancel Task…", role: .destructive) { confirmingCancel = true }
                .disabled(!model.canCancelSelected)
        }.textSelection(.enabled)
    }
    private func resultView(_ result: DelegatedTaskResult, title: String) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(title).font(.subheadline.weight(.medium))
            Text(result.status.rawValue.capitalized).font(.caption).foregroundStyle(.secondary)
            Text(String(result.summary.prefix(16_000))).font(.callout)
            if result.truncated == true || result.summary.count > 16_000 { Text("Result preview. Open the child conversation for the retained transcript.").font(.caption).foregroundStyle(.secondary) }
        }
    }
}
