import CoincideCore
import SwiftUI

struct PullRequestsSheet: View {
    let model: PullRequestStore
    var initialSelection: GitHubPullRequestReference?
    let requestPush: () -> Void
    var reportGeometry: ((String, CGRect) -> Void)? = nil
    @Environment(\.dismiss) private var dismiss
    @State private var mode = PullRequestSheetMode.list
    @State private var listState = GitHubPullRequestListState.open
    @State private var query = ""
    @State private var reference = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 5) {
                    Text("Pull Requests").font(.title2).accessibilityIdentifier("pull-requests-heading")
                        .background { geometry("heading") }
                    if let context = model.context {
                        Text(context.repository.nameWithOwner).font(.caption.monospaced()).textSelection(.enabled)
                    }
                }
                Spacer(minLength: 8)
                Button { Task { await model.refresh() } } label: { Image(systemName: "arrow.clockwise") }
                    .accessibilityLabel("Refresh pull requests").help("Refresh pull requests").disabled(model.isBusy || model.isLoading)
            }.padding(20)
            Divider()
            if mode != .list {
                Button("Back to Pull Requests") { mode = .list }.disabled(model.isBusy).padding(.horizontal, 20).padding(.top, 12)
                    .accessibilityIdentifier("pull-requests-back")
            }
            if mode != .create && model.operation?.locksSource == true {
                ScrollView { operationContent.padding(20) }.frame(minHeight: 0, maxHeight: .infinity)
                    .accessibilityIdentifier("pull-request-operation-scroll")
            } else {
                if !mode.isForm, model.operation != nil || !model.checkoutOperations.isEmpty {
                    ScrollView { operationContent.padding(.horizontal, 20).padding(.vertical, 12) }.frame(minHeight: 0, maxHeight: 180)
                        .accessibilityIdentifier("pull-request-operation-scroll")
                }
                browserContent.frame(minHeight: 0, maxHeight: .infinity)
            }
            Divider()
            HStack {
                Spacer(minLength: 0)
                Button(mode.isForm && !model.isMutating ? "Cancel" : "Done") { dismiss() }
                    .keyboardShortcut(.defaultAction).disabled(model.isAccepting)
                    .accessibilityIdentifier("pull-requests-close")
                    .background { geometry("close") }
            }.padding(16)
        }.frame(minWidth: 320, idealWidth: 620, maxWidth: 760, minHeight: 380, idealHeight: 560, maxHeight: 680)
            .background { geometry("bounds") }
            .coordinateSpace(name: "pull-requests-layout")
            .interactiveDismissDisabled(model.isAccepting)
            .onExitCommand { if !model.isAccepting { dismiss() } }
            .task {
                await model.refresh()
                if let initialSelection { mode = .detail; await model.select(initialSelection) }
            }
    }
    private func geometry(_ region: String) -> some View {
        GeometryReader { proxy in
            let frame = proxy.frame(in: .named("pull-requests-layout"))
            Color.clear
                .onAppear { reportGeometry?(region, frame) }
                .onChange(of: frame) { _, value in reportGeometry?(region, value) }
        }
    }
    @ViewBuilder private var browserContent: some View {
        if let message = model.contextError {
            ScrollView { Text(message).font(.callout).foregroundStyle(.secondary).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading).padding(20) }
        } else if model.context == nil {
            VStack { Spacer(); ProgressView("Reading GitHub repository…"); Spacer() }.frame(maxWidth: .infinity)
        } else {
            switch mode {
            case .list: listContent
            case .detail: detailContent
            case .create: PullRequestCreateView(model: model, back: { mode = .detail }, requestPush: requestPush)
            case .checkout(let reference): PullRequestCheckoutView(model: model, reference: reference).id(reference)
            }
        }
    }
    @ViewBuilder private var operationContent: some View {
        LazyVStack(alignment: .leading, spacing: 12) {
            ForEach(model.checkoutOperations.reversed()) { operation in
                PullRequestCheckoutOperationView(model: model, operationID: operation.id)
            }
            if model.operation != nil { PullRequestOperationView(model: model, viewResult: { mode = .detail }) }
        }.coincideGlassGroup()
    }
    private var listContent: some View {
        VStack(alignment: .leading, spacing: 12) {
            ViewThatFits(in: .horizontal) {
                HStack { filter; Spacer(minLength: 8); createButton }.fixedSize(horizontal: true, vertical: false)
                VStack(alignment: .leading, spacing: 8) { filter; createButton }
            }.frame(maxWidth: .infinity, alignment: .leading)
            HStack {
                TextField("Search pull requests", text: $query).onSubmit(search)
                    .accessibilityIdentifier("pull-request-search")
                Button("Search", action: search).disabled(model.isLoadingList).accessibilityIdentifier("pull-request-search-submit")
            }.textFieldStyle(.roundedBorder)
            HStack {
                TextField("Pull request URL or #number", text: $reference).onSubmit(resolve)
                    .accessibilityIdentifier("pull-request-reference")
                Button("Open", action: resolve).disabled(reference.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || model.isLoadingDetail)
                    .accessibilityIdentifier("pull-request-resolve")
            }.textFieldStyle(.roundedBorder)
            if model.isLoadingList { ProgressView("Loading pull requests…").font(.caption) }
            if let error = model.listError { Text(error).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true) }
            if let page = model.page {
                if page.items.isEmpty {
                    ContentUnavailableView("No Matching Pull Requests", systemImage: "magnifyingglass", description: Text("Change the state or search query, then refresh."))
                } else {
                    List(page.items) { summary in
                        Button { mode = .detail; Task { await model.select(summary.reference) } } label: { PullRequestSummaryRow(summary: summary) }
                            .buttonStyle(.plain)
                            .accessibilityIdentifier("pull-request-select-\(summary.reference.number)")
                    }.listStyle(.inset).accessibilityIdentifier("pull-request-list")
                }
                if page.truncated { Text("This list is limited. Narrow the search to find more pull requests.").font(.caption).foregroundStyle(.secondary) }
            } else { Spacer(minLength: 0) }
        }.padding(20)
    }
    private var filter: some View {
        Picker("State", selection: $listState) {
            Text("Open").tag(GitHubPullRequestListState.open)
            Text("Closed").tag(GitHubPullRequestListState.closed)
            Text("Merged").tag(GitHubPullRequestListState.merged)
            Text("All").tag(GitHubPullRequestListState.all)
        }.fixedSize().accessibilityIdentifier("pull-request-state")
            .onChange(of: listState) { search() }
    }
    private var createButton: some View {
        Button("New Pull Request…") { mode = .create }
            .disabled(model.isBusy || model.operation?.locksSource == true || model.context?.existingPullRequest != nil)
            .accessibilityIdentifier("pull-request-new")
    }
    @ViewBuilder private var detailContent: some View {
        if model.isLoadingDetail { VStack { Spacer(); ProgressView("Reading pull request…"); Spacer() }.frame(maxWidth: .infinity) }
        else if let detail = model.detail {
            PullRequestDetailContent(detail: detail, canCheckout: model.canCheckout && !model.isBusy,
                                     checkout: { mode = .checkout(detail.summary.reference) })
        }
        else if let error = model.detailError { ScrollView { Text(error).font(.callout).foregroundStyle(.secondary).textSelection(.enabled).padding(20) }.frame(maxWidth: .infinity, alignment: .leading) }
        else { ContentUnavailableView("Choose a Pull Request", systemImage: "arrow.triangle.branch", description: Text("Return to the list or enter an exact URL or number.")) }
    }
    private func search() { Task { await model.loadList(state: listState, query: query) } }
    private func resolve() {
        guard !reference.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        mode = .detail
        Task { await model.resolve(reference) }
    }
}

private enum PullRequestSheetMode: Equatable {
    case list, detail, create, checkout(GitHubPullRequestReference)
    var isCheckout: Bool { if case .checkout = self { true } else { false } }
    var isForm: Bool { self == .create || isCheckout }
}

struct PullRequestBranchCard: View {
    let model: PullRequestStore
    let open: (GitHubPullRequestReference?) -> Void
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("Pull Request").font(.caption.weight(.medium))
                Spacer(minLength: 4)
                if model.isLoading { ProgressView().controlSize(.mini) }
                Button("Pull Requests…") { open(nil) }.controlSize(.small).accessibilityIdentifier("pull-requests-open")
            }
            if let operation = model.checkoutOperations.last(where: \.retainsProject) {
                Text(operation.isWorking
                     ? operation.review.plan.isReadOnly ? "Inspecting existing checkout…" : "Preparing pull request checkout…"
                     : "Checkout unconfirmed; inspect before continuing")
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                Button("View Checkout State") { open(nil) }.controlSize(.small).accessibilityIdentifier("pull-request-open-checkout")
            } else if let operation = model.operation, operation.locksSource {
                Text(operation.isWorking ? "Creating pull request…" : "Creation unconfirmed; inspect before continuing")
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                Button("View Creation State") { open(nil) }.controlSize(.small).accessibilityIdentifier("pull-request-open-creation")
            } else if let summary = model.context?.existingPullRequest {
                Button { open(summary.reference) } label: {
                    Text("#\(summary.reference.number) · \(summary.title)").font(.caption).lineLimit(2).frame(maxWidth: .infinity, alignment: .leading)
                }.buttonStyle(.plain).accessibilityIdentifier("pull-request-current")
                Text(PullRequestPresentation.state(summary)).font(.caption).foregroundStyle(.secondary)
            } else if let error = model.contextError {
                Text(error).font(.caption).foregroundStyle(.secondary).lineLimit(3).help(error)
            } else if let context = model.context {
                Text(context.readiness.message ?? String(localized: "No open pull request for this published branch."))
                    .font(.caption).foregroundStyle(.secondary).lineLimit(3)
            }
        }.frame(minWidth: 0, maxWidth: .infinity, alignment: .leading)
            .task { await model.refresh() }
    }
}
