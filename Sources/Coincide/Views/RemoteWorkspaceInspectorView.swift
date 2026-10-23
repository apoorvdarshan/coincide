import CoincideCore
import SwiftUI

struct RemoteWorkspaceInspectorView: View {
    @Bindable var store: RemoteWorkspaceInspectorStore
    var body: some View {
        VStack(spacing: 0) {
            EditorRecoveryShelf(records: store.recoveredDrafts.filter { record in
                guard let target = store.selected?.session.target else { return true }
                return !record.scope.matchesRemote(target, includingOtherRoots: true)
            }, active: nil, error: store.recoveryError, canRestore: { _ in false }, restore: { _ in },
                discard: { await store.discardRecoveredDraft($0) }, refresh: { await store.refreshRecoveredDrafts() })
            if !store.retainedEditors.isEmpty {
                HStack {
                Menu("Retained Editors") {
                    ForEach(store.retainedEditors, id: \.id) { model in
                        Button(model.session.target.workspacePath + " · " + String(model.session.target.threadID.uuidString.prefix(8))) {
                            store.showRetained(model)
                        }
                    }
                }.accessibilityIdentifier("remote-retained-editors")
                if store.canReturnToCurrent { Button("Current Workspace") { Task { await store.returnToCurrent() } }.controlSize(.small) }
                }.padding(8)
            }
            if let model = store.selected { RemoteWorkspaceInspectorContent(model: model) }
            else { ContentUnavailableView("Remote Workspace", systemImage: "network", description: Text(store.errorMessage ?? "Choose a remote conversation or a retained editor.")) }
        }
        .task { await store.refreshRecoveredDrafts() }
    }
}

private struct RemoteWorkspaceInspectorContent: View {
    @Bindable var model: RemoteWorkspaceInspectorModel
    @State private var dismissingOperation = false
    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Label("Remote Workspace", systemImage: "network")
                Spacer()
                if model.session.isBinding { ProgressView().controlSize(.mini) }
                else if !model.session.isConnected { Text("Disconnected").foregroundStyle(.secondary) }
            }.font(.caption).padding(.horizontal).padding(.top, 12)
            Picker("Remote workspace inspector", selection: $model.tab) {
                Text("Files").tag("Files"); Text("Changes").tag("Changes")
            }.pickerStyle(.segmented).padding()
            if model.session.pending != nil { operationStatus }
            if let error = model.session.errorMessage {
                Text(error).font(.caption).foregroundStyle(.red).textSelection(.enabled).padding(.horizontal).padding(.bottom, 8)
            }
            if model.tab == "Files" { RemoteFileBrowserView(model: model.files) }
            else { RemoteGitInspectorView(model: model.git) }
        }
        .accessibilityIdentifier("remote-workspace-inspector")
        .confirmationDialog("Dismiss this unconfirmed workspace operation?", isPresented: $dismissingOperation) {
            Button("Keep Drafts and Dismiss") { Task { await model.session.dismissOperation() } }
        } message: {
            Text("Inspect the remote files and Git status first. The change may already have happened. Its exact local record will be retained, and nothing will be repeated.")
        }
    }

    private var operationStatus: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label(operationTitle, systemImage: "clock.arrow.circlepath").font(.callout)
            if let pending = model.session.pending, !pending.target.workspacePath.utf8.elementsEqual(model.session.target.workspacePath.utf8) {
                Text("Previous workspace: \(pending.target.workspacePath)").font(.caption).textSelection(.enabled)
            }
            if let notice = model.session.notice { Text(notice).font(.caption).textSelection(.enabled) }
            HStack {
                if model.session.operation?.state == .accepted || model.session.operation?.state == .running {
                    ProgressView().controlSize(.mini)
                    Button("Cancel Operation") { Task { await model.session.cancelOperation() } }.disabled(!model.session.canCheckResult)
                }
                Button("Check Result") { Task { await model.session.checkResult() } }.disabled(!model.session.canCheckResult)
                Button("Dismiss…") { dismissingOperation = true }.disabled(!model.session.canDismissOperation)
            }.controlSize(.small)
        }.frame(maxWidth: .infinity, alignment: .leading).padding(12).background(.quaternary.opacity(0.5))
    }

    private var operationTitle: String {
        guard let pending = model.session.pending else { return "Remote Operation" }
        switch pending.mutation {
        case .saveFile: return "Saving remote file"
        case .createFile: return "Creating remote file"
        case .gitInitialize: return "Initializing remote repository"
        case .gitStage: return "Staging remote changes"
        case .gitUnstage: return "Unstaging remote changes"
        case .gitCommit: return "Committing remote changes"
        case .gitCheckout: return "Switching remote branch"
        case .gitCreateBranch: return "Creating remote branch"
        case .gitFetch: return "Fetching on remote Mac"
        case .gitPull: return "Pulling on remote Mac"
        case .gitPush: return "Pushing from remote Mac"
        }
    }
}
