import CoincideCore
import CoincideMarkdown
import SwiftUI

struct PullRequestSummaryRow: View {
    let summary: GitHubPullRequestSummary
    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(summary.title).font(.body.weight(.medium)).lineLimit(2)
            HStack(spacing: 6) {
                Text("#\(summary.reference.number)")
                Text(PullRequestPresentation.state(summary))
                if let author = summary.author { Text(author).lineLimit(1) }
                Spacer(minLength: 0)
            }.font(.caption).foregroundStyle(.secondary)
            Text(summary.headBranch + " → " + summary.baseBranch).font(.caption.monospaced()).lineLimit(1).truncationMode(.middle)
        }.frame(maxWidth: .infinity, alignment: .leading)
            .padding(.vertical, 5).contentShape(Rectangle())
            .accessibilityElement(children: .combine)
            .accessibilityIdentifier("pull-request-row-\(summary.reference.number)")
    }
}

struct PullRequestDetailContent: View {
    @AppStorage("renderMathInMarkdown") private var renderMathInMarkdown = false
    let detail: GitHubPullRequestDetail
    var canCheckout = false
    var checkout: (() -> Void)? = nil
    private var summary: GitHubPullRequestSummary { detail.summary }
    private let bodyPreviewLimit = 100_000
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                VStack(alignment: .leading, spacing: 6) {
                    Text(summary.title).font(.title2).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
                    Text("#\(summary.reference.number) · \(PullRequestPresentation.state(summary))").font(.callout).foregroundStyle(.secondary)
                    Text(summary.reference.repository.nameWithOwner).font(.caption.monospaced()).textSelection(.enabled)
                    if let url = PullRequestPresentation.url(summary) {
                        Link("Open on GitHub", destination: url).accessibilityIdentifier("pull-request-open")
                    }
                    if let checkout {
                        Button("Open in Conversation…", action: checkout).disabled(!canCheckout)
                            .accessibilityIdentifier("pull-request-checkout")
                    }
                }
                VStack(alignment: .leading, spacing: 7) {
                    LabeledContent("Head") { Text((summary.headRepository?.nameWithOwner ?? summary.reference.repository.nameWithOwner) + ":" + summary.headBranch).textSelection(.enabled) }
                    LabeledContent("Base", value: summary.baseBranch)
                    LabeledContent("Head commit") { Text(summary.headCommit).font(.caption.monospaced()).textSelection(.enabled) }
                    if let author = summary.author { LabeledContent("Author", value: author) }
                    LabeledContent("Updated") { Text(summary.updatedAt, format: .dateTime.year().month(.abbreviated).day().hour().minute()) }
                    if let checks = summary.checksState { LabeledContent("Checks", value: PullRequestPresentation.checks(checks)) }
                    if let review = summary.reviewDecision { LabeledContent("Reviews", value: PullRequestPresentation.review(review)) }
                }.font(.callout)
                Divider()
                VStack(alignment: .leading, spacing: 8) {
                    Text("Description").font(.headline)
                    if detail.body.isEmpty { Text("No description provided.").foregroundStyle(.secondary) }
                    else { MarkdownView(String(detail.body.prefix(bodyPreviewLimit)), workspace: nil, mathEnabled: renderMathInMarkdown) }
                    if detail.body.count > bodyPreviewLimit {
                        Text("This description preview is limited. Open on GitHub to read the complete description.").font(.caption).foregroundStyle(.secondary)
                    }
                }.accessibilityIdentifier("pull-request-description")
                Text("\(detail.changedFiles) changed files · +\(detail.additions) additions · −\(detail.deletions) deletions")
                    .font(.caption).foregroundStyle(.secondary)
                if !detail.checks.isEmpty {
                    DisclosureGroup("Checks (\(detail.checks.count))") {
                        ScrollView { LazyVStack(alignment: .leading, spacing: 8) {
                            ForEach(Array(detail.checks.enumerated()), id: \.offset) { _, check in
                                HStack(alignment: .firstTextBaseline) {
                                    Text(check.name).fixedSize(horizontal: false, vertical: true)
                                    Spacer(minLength: 8)
                                    Text(PullRequestPresentation.checks(check.state)).foregroundStyle(.secondary)
                                }.font(.caption)
                            }
                        }.padding(.top, 8) }.frame(maxHeight: 180)
                    }
                }
                if !detail.reviewers.isEmpty { LabeledContent("Reviewers", value: detail.reviewers.joined(separator: ", ")).font(.caption) }
                if !detail.labels.isEmpty { LabeledContent("Labels", value: detail.labels.joined(separator: ", ")).font(.caption) }
            }.padding(20).frame(minWidth: 0, maxWidth: .infinity, alignment: .leading)
        }.accessibilityIdentifier("pull-request-detail")
    }
}
