import CoincideCore
import SwiftUI

private enum RemotePullRequestSheetMode: Equatable { case list, detail, create, checkout(GitHubPullRequestReference) }

struct RemotePullRequestsSheet: View {
    let store: RemotePullRequestStore
    let requestPush: () -> Void
    @State private var captured: RemotePullRequestWorkspace?
    @State private var mode = RemotePullRequestSheetMode.list
    @Environment(\.dismiss) private var dismiss
    init(store: RemotePullRequestStore, requestPush: @escaping () -> Void) {
        self.store = store; self.requestPush = requestPush; _captured = State(initialValue: store.current)
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Remote Pull Requests").font(.title2)
                    if let context = captured?.context { Text(context.repository.nameWithOwner).font(.caption.monospaced()).textSelection(.enabled) }
                    Text("Git and GitHub actions run on the remote Mac.").font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Button("Refresh", systemImage: "arrow.clockwise") { Task { await captured?.refresh() } }
                    .disabled(captured?.canRead != true || captured?.isLoading == true || captured?.isBusy == true)
            }.padding(20)
            Divider()
            if let error = store.errorMessage { Text(error).font(.caption).foregroundStyle(.red).textSelection(.enabled).padding(12) }
            if let model = captured {
                if mode != .list { Button("Back to Pull Requests") { mode = .list }.disabled(model.isActing).padding(12) }
                if model.operation != nil || !model.checkoutOperations.isEmpty {
                    ScrollView { RemotePullRequestOperations(model: model, viewResult: { mode = .detail }).padding(12) }.frame(maxHeight: 200)
                }
                content(model).frame(maxWidth: .infinity, minHeight: 220, maxHeight: .infinity)
            } else { ContentUnavailableView("Choose a Remote Conversation", systemImage: "arrow.triangle.branch") }
            Divider()
            HStack { Spacer(); Button("Done") { dismiss() }.keyboardShortcut(.cancelAction).disabled(captured?.isActing == true) }.padding(16)
        }.frame(minWidth: 480, idealWidth: 650, maxWidth: 800, minHeight: 420, idealHeight: 640, maxHeight: 760)
            .interactiveDismissDisabled(captured?.isActing == true)
            .task { await captured?.refresh() }
    }
    @ViewBuilder private func content(_ model: RemotePullRequestWorkspace) -> some View {
        if let contextError = model.contextError { ScrollView { Text(contextError).foregroundStyle(.secondary).textSelection(.enabled).padding(20) } }
        else if model.context == nil {
            if model.isLoading { ProgressView("Reading remote GitHub repository…") }
            else { Text(model.unavailableMessage ?? "Refresh to read the remote repository.").foregroundStyle(.secondary).padding(20) }
        } else {
            switch mode {
            case .list: RemotePullRequestList(model: model, detail: { mode = .detail }, create: { mode = .create })
            case .detail:
                if model.isLoadingDetail { ProgressView("Loading remote pull request…") }
                else if let detail = model.detail {
                    PullRequestDetailContent(detail: detail, canCheckout: model.canCheckout(.worktree) || model.canCheckout(.local),
                        checkout: { mode = .checkout(detail.summary.reference) })
                } else { Text(model.detailError ?? "Choose a pull request from the list.").foregroundStyle(.secondary).padding(20) }
            case .create: RemotePullRequestCreatePane(model: model, requestPush: requestPush)
            case .checkout(let reference): RemotePullRequestCheckoutPane(model: model, reference: reference).id(reference)
            }
        }
    }
}

private struct RemotePullRequestList: View {
    @Bindable var model: RemotePullRequestWorkspace
    let detail: () -> Void
    let create: () -> Void
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Picker("State", selection: $model.listState) {
                    Text("Open").tag(GitHubPullRequestListState.open); Text("Closed").tag(GitHubPullRequestListState.closed)
                    Text("Merged").tag(GitHubPullRequestListState.merged); Text("All").tag(GitHubPullRequestListState.all)
                }.onChange(of: model.listState) { Task { await model.loadList() } }
                Spacer(); Button("New Pull Request…", action: create).disabled(!model.canCreate)
            }
            HStack { TextField("Search remote pull requests", text: $model.query).onSubmit { Task { await model.loadList() } }; Button("Search") { Task { await model.loadList() } }.disabled(model.isLoadingList) }
            HStack {
                TextField("Pull request URL or #number", text: $model.referenceText).onSubmit(resolve)
                Button("Open", action: resolve).disabled(model.referenceText.isEmpty || model.isLoadingDetail)
            }
            if let message = model.unavailableMessage { Text(message).font(.caption).foregroundStyle(.secondary) }
            if let error = model.listError { Text(error).font(.caption).foregroundStyle(.red).textSelection(.enabled) }
            if model.isLoadingList { ProgressView("Loading remote pull requests…").controlSize(.small) }
            if let page = model.page {
                if page.items.isEmpty { ContentUnavailableView("No Matching Pull Requests", systemImage: "magnifyingglass") }
                else {
                    List(page.items) { summary in
                        Button { detail(); Task { await model.select(summary.reference) } } label: { PullRequestSummaryRow(summary: summary) }.buttonStyle(.plain)
                    }
                }
                if page.truncated { Text("Results are limited. Narrow the search or open an exact pull request.").font(.caption).foregroundStyle(.secondary) }
            }
        }.textFieldStyle(.roundedBorder).padding(16)
    }
    private func resolve() { detail(); Task { await model.resolve() } }
}

private struct RemotePullRequestCreatePane: View {
    var model: RemotePullRequestWorkspace
    let requestPush: () -> Void
    var body: some View {
        @Bindable var draft = model.draft
        PullRequestCreateContent(context: model.context, review: model.creationReview, title: $draft.title, description: $draft.body,
            baseBranch: $draft.baseBranch, isDraft: $draft.isDraft, busy: model.isBusy, canPrepare: model.canCreate,
            error: model.actionError, edit: model.clearCreation, prepare: { Task { await model.prepareCreation() } },
            create: { Task { await model.create() } }, requestPush: requestPush)
            .disabled(!draft.acceptingEdits)
    }
}
