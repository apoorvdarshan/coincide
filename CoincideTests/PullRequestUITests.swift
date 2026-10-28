import AppKit
import Testing

@testable import Coincide
@testable import CoincideKit

@MainActor
@Suite(.serialized)
struct PullRequestUITests {
    @Test func reviewFailureKeepsTheMessageAndAllowsCorrection() async throws {
        let sheet = PullRequestReviewSheet(number: 42)
        let message = try #require(first(NSTextView.self, in: sheet.view))
        let submit = try #require(button("Submit Review", in: sheet.view))
        #expect(!submit.isEnabled)
        message.string = "Please keep the validation for empty input."
        sheet.textDidChange(Notification(name: NSText.didChangeNotification, object: message))
        #expect(submit.isEnabled)
        var attempted = false
        sheet.onSubmit = { event, body in
            #expect(event == .comment)
            #expect(body == message.string)
            attempted = true
            throw GitError("Review failed", detail: "The server rejected the request.")
        }
        submit.performClick(nil)
        for _ in 0..<50 where !attempted { try await Task.sleep(for: .milliseconds(10)) }
        #expect(attempted)
        #expect(message.string == "Please keep the validation for empty input.")
        #expect(message.isEditable)
        #expect(submit.isEnabled)
        #expect(labels(in: sheet.view).contains { $0.stringValue.contains("The server rejected the request.") })
    }

    @Test func pendingChecksDisableMergeAndReviewsAreVisible() throws {
        let view = PullRequestDetailView(frame: NSRect(x: 0, y: 0, width: 400, height: 800))
        var detail = PullRequestDetail(
            summary: PullRequestSummary(number: 42, title: "Preserve validation when a request is retried",
                url: "https://github.com/example/project/pull/42", author: "contributor", headBranch: "validation", baseBranch: "main",
                checksState: .pending),
            body: "## Summary\nKeep the existing validation when retrying a request.",
            checks: [PullRequestCheck(name: "Build and test", status: .pending)], mergeability: .mergeable,
            headCommit: String(repeating: "a", count: 40),
            reviews: [PullRequestReview(author: "reviewer", state: "COMMENTED", body: "Please cover the empty-input case.")])
        view.show(detail.summary, detail: detail, isBusy: false)
        let merge = try #require(button("Merge…", in: view))
        #expect(!merge.isEnabled)
        #expect(button("Review…", in: view)?.isEnabled == true)
        #expect(labels(in: view).contains { $0.stringValue == "reviewer · Commented" })
        detail.summary.checksState = .passing
        view.show(detail.summary, detail: detail, isBusy: false)
        #expect(merge.isEnabled)
        view.show(detail.summary, detail: detail, isBusy: true)
        #expect(!merge.isEnabled)
        #expect(button("Review…", in: view)?.isEnabled == false)
    }

    private func first<T: NSView>(_ type: T.Type, in view: NSView) -> T? {
        if let match = view as? T { return match }
        return view.subviews.lazy.compactMap { first(type, in: $0) }.first
    }

    private func button(_ title: String, in view: NSView) -> NSButton? {
        if let button = view as? NSButton, button.title == title { return button }
        return view.subviews.lazy.compactMap { button(title, in: $0) }.first
    }

    private func labels(in view: NSView) -> [NSTextField] {
        (view as? NSTextField).map { [$0] } ?? view.subviews.flatMap { labels(in: $0) }
    }
}
