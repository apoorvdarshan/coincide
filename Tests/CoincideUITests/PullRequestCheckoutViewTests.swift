import AppKit
import SwiftUI
import Testing
@testable import Coincide
@testable import CoincideCore

@MainActor @Test(.timeLimit(.minutes(1)))
func nativePullRequestCheckoutReviewsAndRecoveryFitSmallWindowsInBothAppearances() async throws {
    _ = NSApplication.shared
    let f = try await PullRequestNativeFixture.make()
    do {
        let context = try #require(f.model.context)
        let summary = try GitHubPullRequestSummary(reference: .init(repository: context.repository, number: 42),
            title: "Review the exact pull request checkout while retaining every existing conversation draft",
            url: "https://github.com/fixture/native-pr/pull/42", state: .open, isDraft: false,
            headBranch: "feature/native-review", baseBranch: "main", headCommit: String(repeating: "a", count: 40),
            baseCommit: String(repeating: "b", count: 40), headRepository: context.repository)
        let worktree = try nativePullRequestCheckoutReview(f, summary: summary, disposition: .createWorktree)
        let local = try nativePullRequestCheckoutReview(f, summary: summary, disposition: .local)
        let reused = try nativePullRequestCheckoutReview(f, summary: summary, disposition: .reuseUnrelatedWorktree)
        let childRequest = GitWorktreeRequest(id: reused.plan.id, sourcePath: reused.plan.repositoryPath,
            destinationRoot: reused.plan.request.destinationRoot, selection: .reuse(path: reused.plan.destinationPath))
        let childPlan = try GitWorktreePlan(request: childRequest, sourcePath: reused.plan.repositoryPath,
            commonDirectoryPath: reused.plan.commonDirectoryPath, sourceIdentity: reused.plan.proof.repositoryIdentity,
            commonDirectoryIdentity: reused.plan.proof.commonDirectoryIdentity,
            destinationParentIdentity: reused.plan.destinationParentIdentity, branch: "kept-local-commits",
            baseCommit: String(repeating: "f", count: 40), destinationIdentity: reused.plan.proof.destinationIdentity,
            worktreeGitDirectoryPath: reused.plan.proof.destinationGitDirectoryPath,
            worktreeGitDirectoryIdentity: reused.plan.proof.destinationGitDirectoryIdentity)
        let childResult = GitWorktreeResult(destinationPath: reused.plan.destinationPath,
            headCommit: childPlan.baseCommit, branch: childPlan.branch)
        let result = GitHubPullRequestCheckoutResult(destinationPath: reused.plan.destinationPath,
            branch: "kept-local-commits", headCommit: String(repeating: "f", count: 40), isOnPullRequestHead: false,
            created: false, reused: true, moved: false, warnings: [GitHubPullRequestCheckoutResult.offHeadWarning],
            worktreePlan: childPlan, worktreeResult: childResult)
        let pending = PullRequestCheckoutOperation(review: worktree, phase: .accepted)
        let stopping = PullRequestCheckoutOperation(review: worktree, phase: .dispatching, cancelRequested: true)
        let uncertain = PullRequestCheckoutOperation(review: worktree, phase: .unconfirmed, error: PullRequestCheckoutOperation.unconfirmedMessage)
        let completed = PullRequestCheckoutOperation(review: reused, phase: .completed, result: result)
        try pending.validate(); try stopping.validate(); try uncertain.validate(); try completed.validate()
        for scheme in [ColorScheme.light, .dark] {
            for width in [CGFloat(320), 680] {
                for (name, review, mode) in [("choose-worktree", Optional<PullRequestCheckoutReview>.none, GitHubPullRequestCheckoutMode.worktree),
                                           ("review-worktree", worktree, .worktree), ("review-local", local, .local),
                                           ("review-reused-off-head", reused, .worktree)] {
                    let geometry = NativePullRequestCheckoutGeometry()
                    let content = PullRequestCheckoutContent(reference: summary.reference, summary: summary, review: review,
                        mode: .constant(mode), submodules: .constant(.recursive), reviewSetup: .constant(true),
                        busy: false, canPrepare: true, error: nil, edit: { }, prepare: { }, checkout: { },
                        reportGeometry: { geometry.frames[$0] = $1 }).environment(\.colorScheme, scheme)
                    let hosting = NSHostingController(rootView: content)
                    let size = hosting.sizeThatFits(in: CGSize(width: width, height: 650))
                    #expect(size.width <= width + 1 && size.height <= 650)
                    try await captureNativePullRequestCheckout(content, name: name, width: width, height: size.height,
                                                              scheme: scheme, geometry: geometry)
                }
                for (name, operation) in [("queued", pending), ("stopping", stopping), ("unconfirmed", uncertain), ("completed-off-head", completed)] {
                    let content = ScrollView {
                        PullRequestCheckoutOperationContent(operation: operation, acting: false,
                            stop: { }, inspect: { }, acknowledge: { }, openConversation: { }).padding(16)
                    }.environment(\.colorScheme, scheme)
                    let hosting = NSHostingController(rootView: content)
                    let size = hosting.sizeThatFits(in: CGSize(width: width, height: 650))
                    #expect(size.width <= width + 1 && size.height <= 650)
                    try await captureNativePullRequestCheckout(content, name: name, width: width, height: size.height, scheme: scheme)
                }
            }
        }
        #expect(f.workspace.thread(f.threadID)?.draft == "Retain this unsent draft")
        #expect(await f.peer.creates == 0)
    } catch { await f.finish(); throw error }
    await f.finish()
}

@MainActor private func nativePullRequestCheckoutReview(_ f: PullRequestNativeFixture, summary: GitHubPullRequestSummary,
                                                       disposition: GitHubPullRequestCheckoutDisposition) throws -> PullRequestCheckoutReview {
    let mode: GitHubPullRequestCheckoutMode = disposition == .local ? .local : .worktree
    let destinationRoot = f.root.appendingPathComponent("Worktrees").path
    let request = GitHubPullRequestCheckoutRequest(sourcePath: f.root.path, destinationRoot: destinationRoot,
        reference: summary.reference, mode: mode, submodules: mode == .local ? .none : .recursive)
    let reused = disposition == .reuseWorktree || disposition == .reuseUnrelatedWorktree
    let destination = disposition == .local ? f.root.path : destinationRoot + "/" + (reused ? "registered-checkout" : request.id.uuidString)
    let identity = GitWorktreeNodeIdentity(device: 1, inode: 2)
    let proof = GitHubPullRequestCheckoutProof(sourceIdentity: identity, repositoryIdentity: identity,
        gitDirectoryPath: f.root.appendingPathComponent(".git").path, gitDirectoryIdentity: identity,
        commonDirectoryIdentity: identity, sourceFingerprint: String(repeating: "a", count: 64),
        statusDigest: String(repeating: "b", count: 64), headCommit: summary.baseCommit, branch: "main",
        destinationIdentity: reused ? identity : nil,
        destinationGitDirectoryPath: reused ? f.root.appendingPathComponent(".git/worktrees/registered-checkout").path : nil,
        destinationGitDirectoryIdentity: reused ? identity : nil, destinationStatusDigest: reused ? String(repeating: "c", count: 64) : nil,
        destinationHeadCommit: reused ? String(repeating: "f", count: 40) : nil, destinationBranch: reused ? "kept-local-commits" : nil,
        destinationFingerprint: reused ? String(repeating: "d", count: 64) : nil,
        destinationConfigurationDigest: reused ? String(repeating: "e", count: 64) : nil)
    let remote = try GitHubPullRequestCheckoutRemote(name: "origin", url: "https://github.com/fixture/native-pr.git", repository: summary.reference.repository, needsCreation: false)
    let plan = try GitHubPullRequestCheckoutPlan(request: request, sourcePath: f.root.path, repositoryPath: f.root.path,
        commonDirectoryPath: f.root.appendingPathComponent(".git").path, destinationPath: destination,
        pullRequest: summary, requestedBranch: "feature/native-review", requestedHeadCommit: summary.headCommit,
        disposition: disposition, proof: proof, baseRemote: remote, destinationParentIdentity: identity)
    var configuration = ProviderConfiguration(thread: try #require(f.workspace.thread(f.threadID)))
    configuration.workspacePath = destination; configuration.nativeThreadID = nil
    return try PullRequestCheckoutReview(projectID: f.projectID, projectPath: f.root.path,
        registeredWorkspacePath: f.root.path, sourceIncarnation: UUID(), targetConfiguration: configuration,
        checkpointPolicy: .automatic, title: "PR #42: Native review", reviewSetup: mode == .worktree, plan: plan)
}

@MainActor private final class NativePullRequestCheckoutGeometry {
    var frames: [String: CGRect] = [:]
}

@MainActor private func captureNativePullRequestCheckout<Content: View>(_ content: Content, name: String, width: CGFloat,
                                                                      height: CGFloat, scheme: ColorScheme,
                                                                      geometry: NativePullRequestCheckoutGeometry? = nil) async throws {
    let capture = ProcessInfo.processInfo.environment["COINCIDE_RENDER_PULL_REQUEST_CHECKOUTS"] == "1"
    guard capture || geometry != nil else { return }
    let appearance = try #require(NSAppearance(named: scheme == .light ? .aqua : .darkAqua))
    let hosting = NSHostingView(rootView: content.background(Color(nsColor: .windowBackgroundColor)).frame(width: width, height: height))
    let window = NSWindow(contentRect: NSRect(x: -10_000, y: -10_000, width: width, height: height), styleMask: .borderless, backing: .buffered, defer: false)
    window.appearance = appearance; hosting.appearance = appearance; window.isReleasedWhenClosed = false; window.contentView = hosting
    defer { window.close() }
    hosting.layoutSubtreeIfNeeded(); try await Task.sleep(for: .milliseconds(100)); hosting.layoutSubtreeIfNeeded()
    if let geometry {
        let bounds = try #require(geometry.frames["bounds"]), confirm = try #require(geometry.frames["confirm"])
        #expect(bounds.width <= width + 1 && bounds.height <= height + 1)
        #expect(confirm.width > 0 && confirm.height > 0 && bounds.insetBy(dx: -1, dy: -1).contains(confirm),
                "The explicit checkout action must remain visible below its scrolling review.")
    }
    guard capture else { return }
    let bitmap = try #require(hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds))
    appearance.performAsCurrentDrawingAppearance { hosting.cacheDisplay(in: hosting.bounds, to: bitmap) }
    let data = try #require(bitmap.representation(using: .png, properties: [:]))
    let path = FileManager.default.temporaryDirectory.appendingPathComponent("coincide-pull-request-checkout-\(name)-\(Int(width))-\(scheme == .light ? "light" : "dark").png")
    try data.write(to: path); print("Native pull request checkout preview: \(path.path)")
}
