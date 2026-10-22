import AppKit
import SwiftUI
import Testing
@testable import Coincide
@testable import CoincideCore

@MainActor @Test(.timeLimit(.minutes(1)))
func nativePullRequestViewsKeepPublishedHeadAndReviewReadableAtSmallWidthsInBothAppearances() async throws {
    _ = NSApplication.shared
    let f = try await PullRequestNativeFixture.make()
    do {
        let original = try #require(f.model.context)
        let context = try GitHubPullRequestContext(workspacePath: original.workspacePath,
            repositoryPath: original.repositoryPath, commonDirectoryPath: original.commonDirectoryPath,
            repository: original.repository, headRepository: original.headRepository, branch: "local-feature",
            headCommit: original.headCommit, upstream: .init(remoteName: "origin", branch: "published-review", commit: original.headCommit),
            defaultBranch: "main", baseBranches: ["main", "release/long-supported-base"], readiness: .ready,
            sourceFingerprint: original.sourceFingerprint)
        let title = "Preserve the reviewed branch and every existing conversation draft"
        let body = "Review the published commit without changing local files.\n\n- Preserve Markdown spacing\n- Keep existing drafts and provider settings\n"
        let review = try GitHubPullRequestCreateReview(context: context, title: title, body: body,
            baseBranch: "main", baseCommit: String(repeating: "d", count: 40), isDraft: true)
        #expect(PullRequestPresentation.head(context) == "fixture/native-pr:published-review")
        #expect(context.branch == "local-feature" && review.baseBranch == "main")
        let reference = try GitHubPullRequestReference(repository: context.repository, number: 42)
        let summary = try GitHubPullRequestSummary(reference: reference, title: title,
            url: "https://github.com/fixture/native-pr/pull/42", state: .open, isDraft: true,
            headBranch: "published-review", baseBranch: "main", headCommit: original.headCommit!,
            baseCommit: review.baseCommit, headRepository: original.headRepository, author: "fixture",
            reviewDecision: .reviewRequired, checksState: .pending)
        let detail = try GitHubPullRequestDetail(summary: summary, body: body, createdAt: Date(), additions: 13,
            deletions: 2, changedFiles: 3,
            checks: [.init(name: "Build and test the native macOS application", state: .success),
                     .init(name: "Hosted native interface workflows", state: .pending)],
            reviewers: ["fixture-reviewer"], labels: ["native", "macOS"])
        let uncertain = PullRequestCreationOperation(projectID: f.projectID, projectPath: f.root.path,
            sourceIncarnation: UUID(), review: review, phase: .unconfirmed, error: PullRequestCreationOperation.unconfirmedMessage)
        for scheme in [ColorScheme.light, .dark] {
            for width in [CGFloat(320), 680] {
                let views: [(String, AnyView)] = [
                    ("edit", AnyView(PullRequestCreateContent(context: context, review: nil,
                        title: .constant(title), description: .constant(body), baseBranch: .constant("main"), isDraft: .constant(true),
                        busy: false, canPrepare: true, error: nil, edit: { }, prepare: { }, create: { }, requestPush: { }))),
                    ("review", AnyView(PullRequestCreateContent(context: context, review: review,
                        title: .constant(title), description: .constant(body), baseBranch: .constant("main"), isDraft: .constant(true),
                        busy: false, canPrepare: true, error: nil, edit: { }, prepare: { }, create: { }, requestPush: { }))),
                    ("detail", AnyView(PullRequestDetailContent(detail: detail))),
                    ("uncertain", AnyView(PullRequestOperationContent(operation: uncertain, inspecting: false, inspect: { }, acknowledge: { }, viewResult: { }).padding(12)))
                ]
                for (name, view) in views {
                    let content = view.environment(\.colorScheme, scheme)
                    let hosting = NSHostingController(rootView: content)
                    let size = hosting.sizeThatFits(in: CGSize(width: width, height: 650))
                    #expect(size.width <= width + 1 && size.height <= 650)
                    try await captureNativePullRequest(content, name: name, width: width, height: size.height, scheme: scheme)
                }
            }
        }
        #expect(f.workspace.thread(f.threadID)?.draft == "Retain this unsent draft")
        #expect(await f.peer.creates == 0, "Layout and read-only detail rendering cannot publish a pull request.")
        #expect(PullRequestPresentation.url(summary)?.absoluteString == summary.url)
    } catch { await f.finish(); throw error }
    await f.finish()
}

@MainActor @Test(.timeLimit(.minutes(1)))
func nativePullRequestBrowserAndPushPrerequisiteFitSmallSheetsWithoutCreatingAnything() async throws {
    _ = NSApplication.shared
    let f = try await PullRequestNativeFixture.make()
    do {
        let context = try #require(f.model.context)
        let unpublished = try GitHubPullRequestContext(workspacePath: context.workspacePath,
            repositoryPath: context.repositoryPath, commonDirectoryPath: context.commonDirectoryPath,
            repository: context.repository, headRepository: context.headRepository, branch: "local-only",
            headCommit: context.headCommit, upstream: nil, defaultBranch: "main", baseBranches: ["main"],
            readiness: .unpublished, sourceFingerprint: context.sourceFingerprint)
        for scheme in [ColorScheme.light, .dark] {
            for width in [CGFloat(320), 680] {
                let views: [(String, AnyView)] = [
                    ("browser", AnyView(PullRequestsSheet(model: f.model, initialSelection: nil, requestPush: { }))),
                    ("push-required", AnyView(PullRequestCreateContent(context: unpublished, review: nil,
                        title: .constant("Retain this entered title"), description: .constant("Retain this entered description"),
                        baseBranch: .constant("main"), isDraft: .constant(false), busy: false, canPrepare: false,
                        error: nil, edit: { }, prepare: { }, create: { }, requestPush: { })))
                ]
                for (name, view) in views {
                    let content = view.environment(\.colorScheme, scheme)
                    let hosting = NSHostingController(rootView: content)
                    let size = hosting.sizeThatFits(in: CGSize(width: width, height: 650))
                    #expect(size.width <= width + 1 && size.height <= 650)
                    try await captureNativePullRequest(content, name: name, width: width, height: size.height, scheme: scheme)
                }
            }
        }
        #expect(await f.peer.creates == 0)
        #expect(f.workspace.thread(f.threadID)?.draft == "Retain this unsent draft")
    } catch { await f.finish(); throw error }
    await f.finish()
}

@MainActor private final class NativePullRequestSheetGeometry {
    var frames: [String: CGRect] = [:]
}

@MainActor private func captureNativePullRequest<Content: View>(_ content: Content, name: String, width: CGFloat,
                                                              height: CGFloat, scheme: ColorScheme, sheetGeometry: NativePullRequestSheetGeometry? = nil) async throws {
    let capture = ProcessInfo.processInfo.environment["COINCIDE_RENDER_PULL_REQUESTS"] == "1"
    guard capture || sheetGeometry != nil else { return }
    let appearance = try #require(NSAppearance(named: scheme == .light ? .aqua : .darkAqua))
    let hosting = NSHostingView(rootView: content.background(Color(nsColor: .windowBackgroundColor)).frame(width: width, height: height))
    let window = NSWindow(contentRect: NSRect(x: -10_000, y: -10_000, width: width, height: height), styleMask: .borderless, backing: .buffered, defer: false)
    window.appearance = appearance; hosting.appearance = appearance; window.isReleasedWhenClosed = false; window.contentView = hosting
    defer { window.close() }
    hosting.layoutSubtreeIfNeeded(); try await Task.sleep(for: .milliseconds(100)); hosting.layoutSubtreeIfNeeded()
    if let sheetGeometry {
        let bounds = try #require(sheetGeometry.frames["bounds"])
        #expect(bounds.width <= width + 1 && bounds.height <= height + 1)
        for region in ["heading", "close"] {
            let frame = try #require(sheetGeometry.frames[region])
            #expect(frame.width > 0 && frame.height > 0 && bounds.insetBy(dx: -1, dy: -1).contains(frame), "The sheet heading and close action must remain visible around the scrollable operation.")
        }
    }
    guard capture else { return }
    let bitmap = try #require(hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds))
    appearance.performAsCurrentDrawingAppearance { hosting.cacheDisplay(in: hosting.bounds, to: bitmap) }
    let data = try #require(bitmap.representation(using: .png, properties: [:]))
    let path = FileManager.default.temporaryDirectory.appendingPathComponent("coincide-pull-request-\(name)-\(Int(width))-\(scheme == .light ? "light" : "dark").png")
    try data.write(to: path); print("Native pull request preview: \(path.path)")
}

@MainActor @Test(.timeLimit(.minutes(1)), arguments: [false, true])
func nativePullRequestUnconfirmedWholeSheetFitsSmallWindowsAcrossRestartStylePresentation(longTitle: Bool) async throws {
    _ = NSApplication.shared
    let f = try await PullRequestNativeFixture.make()
    do {
        await f.peer.configureCreate(lostReply: true, hidden: true)
        let review: GitHubPullRequestCreateReview
        if longTitle {
            let title = String(String(repeating: "Preserve the full reviewed pull request title and recover its exact outcome. ", count: 60).prefix(4_096))
            #expect(title.utf8.count == 4_096)
            review = try await f.model.prepareCreation(title: title, body: "Retain this reviewed description.", baseBranch: "main", isDraft: true)
        } else {
            review = try await f.review()
        }
        try await f.model.create(review)
        try await waitForNativePullRequest { await f.peer.enteredCreate }
        await f.peer.releaseCreate()
        try await waitForNativePullRequest { f.model.operation?.phase == .unconfirmed }
        for scheme in [ColorScheme.light, .dark] {
            for width in [CGFloat(320), 680] {
                let geometry = NativePullRequestSheetGeometry()
                let content = PullRequestsSheet(model: f.model, initialSelection: nil, requestPush: { },
                    reportGeometry: { geometry.frames[$0] = $1 }).environment(\.colorScheme, scheme)
                let hosting = NSHostingController(rootView: content)
                let size = hosting.sizeThatFits(in: CGSize(width: width, height: 650))
                #expect(size.width <= width + 1 && size.height <= 650)
                try await captureNativePullRequest(content, name: longTitle ? "uncertain-long-title-sheet" : "uncertain-sheet", width: width, height: size.height, scheme: scheme, sheetGeometry: geometry)
            }
        }
        #expect(f.model.operation?.phase == .unconfirmed && f.model.operation?.acknowledgedAt == nil)
        #expect(f.model.operation?.review.title == review.title)
        #expect(!f.model.canCreate && !f.workspace.canEditWorkspace(f.root.path))
        #expect(await f.peer.creates == 1)
        #expect(f.workspace.thread(f.threadID)?.draft == "Retain this unsent draft")
        if longTitle {
            await f.peer.configureCreate(lostReply: true, hidden: false)
            try await f.model.reconcileCreation()
            try await waitForNativePullRequest { f.model.operation?.phase == .openedExisting }
            for scheme in [ColorScheme.light, .dark] {
                for width in [CGFloat(320), 680] {
                    let geometry = NativePullRequestSheetGeometry()
                    let content = PullRequestsSheet(model: f.model, initialSelection: nil, requestPush: { },
                        reportGeometry: { geometry.frames[$0] = $1 }).environment(\.colorScheme, scheme)
                    let hosting = NSHostingController(rootView: content)
                    let size = hosting.sizeThatFits(in: CGSize(width: width, height: 650))
                    #expect(size.width <= width + 1 && size.height <= 650)
                    try await captureNativePullRequest(content, name: "completed-long-title-sheet", width: width, height: size.height, scheme: scheme, sheetGeometry: geometry)
                }
            }
            #expect(await f.peer.creates == 1)
            #expect(f.model.operation?.review.title == review.title)
        }
    } catch { await f.finish(); throw error }
    await f.finish()
}
