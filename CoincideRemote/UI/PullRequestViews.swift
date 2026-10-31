import CoincideRemoteKit
import SwiftUI

/// A project's pull requests, as the Mac's pull request workspace lists them from GitHub: open ones, the user's, or
/// those waiting for their review, each with its checks and review state. Tap one for its description, checks and
/// reviews, and to merge, review, mark it ready or check it out in a new thread.
struct PullRequestsView: View {
    let project: RemoteProject
    @Environment(RemoteClient.self) private var client
    @Environment(\.dismiss) private var dismiss
    @Environment(\.theme) private var theme
    @State private var filter = "open"
    @State private var list: RemotePullRequestList?
    @State private var error: String?

    var body: some View {
        NavigationStack {
            List {
                Picker("Show", selection: $filter) {
                    ForEach(RemotePullRequestQuery.filters, id: \.self) { filter in Text(Self.title(of: filter)).tag(filter) }
                }
                .pickerStyle(.segmented)
                .listRowBackground(Color.clear)
                .listRowSeparator(.hidden)
                if let list {
                    ForEach(list.items) { pullRequest in
                        NavigationLink {
                            PullRequestDetailView(project: project, number: pullRequest.number, summary: pullRequest)
                        } label: {
                            PullRequestRow(pullRequest: pullRequest)
                        }
                        .listRowBackground(Color.clear)
                    }
                }
            }
            .listStyle(.plain)
            .scrollContentBackground(.hidden)
            .background(theme.content)
            .overlay { placeholder }
            .refreshable { await load() }
            .navigationTitle("Pull Requests")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } }
            }
            .task(id: filter) { await load() }
        }
    }

    @ViewBuilder private var placeholder: some View {
        if let unavailable = list?.unavailable {
            ContentUnavailableView("No Pull Requests", systemImage: "arrow.triangle.pull", description: Text(unavailable))
                .foregroundStyle(theme.secondaryInk)
        } else if let error {
            ContentUnavailableView("Can’t Show Pull Requests", systemImage: "exclamationmark.triangle", description: Text(error))
                .foregroundStyle(theme.secondaryInk)
        } else if list?.items.isEmpty == true {
            ContentUnavailableView("No Pull Requests", systemImage: "arrow.triangle.pull")
                .foregroundStyle(theme.secondaryInk)
        } else if list == nil {
            ProgressView()
        }
    }

    private func load() async {
        do {
            list = try await client.pullRequests(RemotePullRequestQuery(projectID: project.id, filter: filter))
            error = nil
        } catch let failure as RemoteError where failure.code == .unsupported {
            error = String(localized: "Update Coincide on your Mac to do this from here.")
        } catch {
            self.error = (error as? RemoteError)?.message ?? error.localizedDescription
        }
    }

    static func title(of filter: String) -> String {
        switch filter {
        case "mine": String(localized: "Mine")
        case "reviewRequested": String(localized: "Review Requested")
        default: String(localized: "Open")
        }
    }
}

/// How a pull request's state, checks and review show, as on the Mac (`PullRequestGlyph`).
enum PullRequestGlyph {
    static func state(_ pullRequest: RemotePullRequest) -> (symbol: String, color: Color, label: String) {
        switch pullRequest.state {
        case .open where pullRequest.isDraft: ("arrow.triangle.pull", .secondary, String(localized: "Draft"))
        case .open: ("arrow.triangle.pull", .green, String(localized: "Open"))
        case .merged: ("arrow.triangle.merge", .purple, String(localized: "Merged"))
        case .closed, .unknown: ("xmark.circle", .secondary, String(localized: "Closed"))
        }
    }

    static func checks(_ checks: RemotePullRequest.Checks) -> (symbol: String, color: Color, label: String) {
        switch checks {
        case .passing: ("checkmark.circle", .green, String(localized: "All checks have passed"))
        case .failing: ("xmark.circle", .red, String(localized: "Some checks were not successful"))
        case .pending, .unknown: ("smallcircle.filled.circle", .orange, String(localized: "Some checks haven’t completed yet"))
        }
    }

    static func review(_ review: RemotePullRequest.Review) -> (symbol: String, color: Color, label: String) {
        switch review {
        case .approved: ("person.crop.circle.badge.checkmark", .green, String(localized: "Approved"))
        case .changesRequested: ("person.crop.circle.badge.xmark", .orange, String(localized: "Changes requested"))
        case .reviewRequired, .unknown: ("person.crop.circle", .secondary, String(localized: "Awaiting review"))
        }
    }

    static func check(_ status: String) -> (symbol: String, color: Color, label: String) {
        switch status {
        case "success": ("checkmark.circle", .green, String(localized: "Passed"))
        case "failure": ("xmark.circle", .red, String(localized: "Failed"))
        case "cancelled": ("xmark.circle", .red, String(localized: "Cancelled"))
        case "actionRequired": ("exclamationmark.circle", .orange, String(localized: "Awaiting approval"))
        case "skipped": ("slash.circle", .secondary, String(localized: "Skipped"))
        case "neutral": ("circle.dashed", .secondary, String(localized: "Neutral"))
        default: ("smallcircle.filled.circle", .orange, String(localized: "In progress"))
        }
    }
}

struct PullRequestRow: View {
    let pullRequest: RemotePullRequest
    @Environment(\.theme) private var theme

    var body: some View {
        let state = PullRequestGlyph.state(pullRequest)
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: state.symbol).foregroundStyle(state.color).font(.subheadline).padding(.top, 2)
                .accessibilityLabel(Text(state.label))
            VStack(alignment: .leading, spacing: 3) {
                Text(pullRequest.title).font(.callout.weight(.medium)).foregroundStyle(theme.ink).lineLimit(2)
                Text(subtitle).font(.footnote).foregroundStyle(theme.secondaryInk).lineLimit(1)
            }
            Spacer(minLength: 4)
            HStack(spacing: 6) {
                if let checks = pullRequest.checks {
                    let glyph = PullRequestGlyph.checks(checks)
                    Image(systemName: glyph.symbol).foregroundStyle(glyph.color).accessibilityLabel(Text(glyph.label))
                }
                if let review = pullRequest.review {
                    let glyph = PullRequestGlyph.review(review)
                    Image(systemName: glyph.symbol).foregroundStyle(glyph.color).accessibilityLabel(Text(glyph.label))
                }
            }
            .font(.footnote)
            .padding(.top, 2)
        }
        .padding(.vertical, 4)
        .accessibilityElement(children: .combine)
    }

    private var subtitle: String {
        var parts = ["#\(pullRequest.number)"]
        if let author = pullRequest.author { parts.append(author) }
        if !pullRequest.headBranch.isEmpty { parts.append(pullRequest.headBranch) }
        if let updated = pullRequest.updatedAt { parts.append(updated.formatted(.relative(presentation: .named))) }
        return parts.joined(separator: " · ")
    }
}

/// One pull request: its description, checks and reviews, with the Mac workspace's actions.
struct PullRequestDetailView: View {
    let project: RemoteProject
    let number: Int
    let summary: RemotePullRequest
    @Environment(RemoteClient.self) private var client
    @Environment(Navigator.self) private var navigator
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openURL) private var openURL
    @Environment(\.theme) private var theme
    @State private var detail: RemotePullRequestDetail?
    @State private var error: String?
    @State private var busy = false
    @State private var merging: String?
    @State private var reviewing: String?

    var body: some View {
        List {
            header.listRowBackground(Color.clear)
            if let detail {
                if !detail.body.isEmpty {
                    Section("Description") {
                        MarkdownText(text: detail.body).listRowBackground(theme.card)
                    }
                }
                if !detail.checks.isEmpty {
                    Section("Checks") {
                        ForEach(detail.checks, id: \.name) { check in
                            let glyph = PullRequestGlyph.check(check.status)
                            HStack {
                                Image(systemName: glyph.symbol).foregroundStyle(glyph.color)
                                Text(check.name).foregroundStyle(theme.ink).lineLimit(1)
                                Spacer()
                                Text(glyph.label).font(.footnote).foregroundStyle(theme.secondaryInk)
                            }
                            .accessibilityElement(children: .combine)
                            .listRowBackground(theme.card)
                        }
                    }
                }
                if !detail.reviews.isEmpty {
                    Section("Reviews") {
                        ForEach(Array(detail.reviews.enumerated()), id: \.offset) { _, review in
                            VStack(alignment: .leading, spacing: 4) {
                                Text("\(review.author) · \(Self.reviewState(review.state))")
                                    .font(.footnote.weight(.medium)).foregroundStyle(theme.ink)
                                if !review.body.isEmpty {
                                    Text(review.body).font(.footnote).foregroundStyle(theme.secondaryInk).lineLimit(6)
                                }
                            }
                            .listRowBackground(theme.card)
                        }
                    }
                }
            } else if let error {
                Text(error).font(.footnote).foregroundStyle(theme.secondaryInk).listRowBackground(Color.clear)
            } else {
                ProgressView().frame(maxWidth: .infinity).listRowBackground(Color.clear)
            }
        }
        .scrollContentBackground(.hidden)
        .background(theme.content)
        .refreshable { await load() }
        .navigationTitle(Text(verbatim: "#\(number)"))
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .primaryAction) { actions }
        }
        .task { await load() }
        .confirmationDialog(
            mergeQuestion, isPresented: Binding(get: { merging != nil }, set: { if !$0 { merging = nil } }), titleVisibility: .visible
        ) {
            if let method = merging {
                Button(Self.mergeTitle(method)) { perform(.merge, method: method) }
            }
            Button("Cancel", role: .cancel) { merging = nil }
        }
        .sheet(item: Binding(get: { reviewing.map(ReviewEvent.init) }, set: { reviewing = $0?.id })) { event in
            ReviewSheet(event: event.id, number: number) { body in perform(.review, event: event.id, body: body) }
        }
    }

    private var current: RemotePullRequest { detail?.pullRequest ?? summary }

    private var header: some View {
        let state = PullRequestGlyph.state(current)
        return VStack(alignment: .leading, spacing: 6) {
            Text(current.title).font(.title3.weight(.semibold)).foregroundStyle(theme.ink)
            HStack(spacing: 6) {
                Label(state.label, systemImage: state.symbol).foregroundStyle(state.color)
                Text("\(current.baseBranch) ← \(current.headBranch)").foregroundStyle(theme.secondaryInk).lineLimit(1)
                    .truncationMode(.middle)
            }
            .font(.footnote)
            if let detail, let additions = detail.additions, let deletions = detail.deletions {
                HStack(spacing: 8) {
                    DiffCounts(additions: additions, deletions: deletions)
                    if let files = detail.changedFiles {
                        Text("\(files) files").font(.footnote).foregroundStyle(theme.secondaryInk)
                    }
                    if detail.mergeability == "conflicting" {
                        Text("Has conflicts").font(.footnote).foregroundStyle(.orange)
                    }
                }
            }
        }
        .padding(.vertical, 4)
    }

    private var actions: some View {
        Menu {
            if let detail, detail.canMerge, !detail.mergeMethods.isEmpty {
                Menu {
                    ForEach(detail.mergeMethods, id: \.self) { method in
                        Button(Self.mergeTitle(method)) { merging = method }
                    }
                } label: {
                    Label("Merge", systemImage: "arrow.triangle.merge")
                }
            }
            if current.state == .open {
                Button { reviewing = "APPROVE" } label: { Label("Approve…", systemImage: "checkmark.circle") }
                Button { reviewing = "COMMENT" } label: { Label("Comment…", systemImage: "text.bubble") }
                Button { reviewing = "REQUEST_CHANGES" } label: { Label("Request Changes…", systemImage: "exclamationmark.bubble") }
                if current.isDraft {
                    Button { perform(.markReady) } label: { Label("Mark as Ready for Review", systemImage: "eye") }
                }
                Divider()
                Button { perform(.checkOut) } label: { Label("Check Out in New Thread", systemImage: "arrow.down.to.line") }
            }
            if let url = URL(string: current.url) {
                Button { openURL(url) } label: { Label("Open on GitHub", systemImage: "safari") }
            }
        } label: {
            if busy { ProgressView() } else { Label("Actions", systemImage: "ellipsis") }
        }
        .disabled(busy || !client.isConnected)
    }

    private var mergeQuestion: String {
        switch merging {
        case "squash": String(localized: "Squash and merge pull request #\(number)?")
        case "rebase": String(localized: "Rebase and merge pull request #\(number)?")
        default: String(localized: "Merge pull request #\(number) with a merge commit?")
        }
    }

    static func mergeTitle(_ method: String) -> String {
        switch method {
        case "squash": String(localized: "Squash and Merge")
        case "rebase": String(localized: "Rebase and Merge")
        default: String(localized: "Create a Merge Commit")
        }
    }

    static func reviewState(_ state: String) -> String {
        switch state {
        case "APPROVED": String(localized: "Approved")
        case "CHANGES_REQUESTED": String(localized: "Changes requested")
        case "COMMENTED": String(localized: "Commented")
        default: state.capitalized
        }
    }

    private func load() async {
        do {
            detail = try await client.pullRequest(RemotePullRequestReference(projectID: project.id, number: number))
            error = nil
        } catch {
            self.error = (error as? RemoteError)?.message ?? error.localizedDescription
        }
    }

    private func perform(_ action: RemotePullRequestCommand.Action, method: String? = nil, event: String? = nil, body: String? = nil) {
        merging = nil
        busy = true
        Task {
            let result = await client.pullRequestAction(
                RemotePullRequestCommand(projectID: project.id, number: number, action: action, method: method, event: event, body: body))
            busy = false
            switch result {
            case .pullRequest(let updated)?: detail = updated
            case .thread(let id)?:
                dismiss()
                navigator.push(.thread(id))
            default: break
            }
        }
    }
}

private struct ReviewEvent: Identifiable {
    let id: String
}

/// A review's comment: optional when approving, needed to comment or request changes.
private struct ReviewSheet: View {
    let event: String
    let number: Int
    let send: (String) -> Void
    @Environment(\.dismiss) private var dismiss
    @Environment(\.theme) private var theme
    @State private var text = ""

    var body: some View {
        NavigationStack {
            Form {
                TextField(event == "APPROVE" ? "Comment (optional)" : "Comment", text: $text, axis: .vertical)
                    .lineLimit(4...14)
                    .themedCards(theme)
            }
            .scrollContentBackground(.hidden)
            .background(theme.isDark ? theme.content : theme.sidebar)
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Send") {
                        dismiss()
                        send(text)
                    }
                    .disabled(event != "APPROVE" && text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
        }
        .presentationDetents([.medium, .large])
    }

    private var title: String {
        switch event {
        case "APPROVE": String(localized: "Approve #\(number)")
        case "REQUEST_CHANGES": String(localized: "Request Changes on #\(number)")
        default: String(localized: "Comment on #\(number)")
        }
    }
}
