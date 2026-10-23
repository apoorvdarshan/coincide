import AppKit
import Foundation
import SwiftUI
import Testing
@testable import Coincide
@testable import CoincideCore

private actor RemotePRBoundary {
    private var waiting = false
    private var released = false
    private var continuation: CheckedContinuation<Void, Never>?
    private var observers: [CheckedContinuation<Void, Never>] = []
    func pause() async { waiting = true; observers.forEach { $0.resume() }; observers = []; if !released { await withCheckedContinuation { continuation = $0 } } }
    func entered() async { if !waiting { await withCheckedContinuation { observers.append($0) } } }
    func release() { released = true; continuation?.resume(); continuation = nil }
}

private actor RemotePRPeer {
    let rootID = UUID()
    let repository: GitHubRepository
    private var reads: [RemotePullRequestReadRequest] = []
    private var reviews: [RemotePullRequestReviewRequest] = []
    private var discarded: [RemotePullRequestDiscardRequest] = []
    private var boundary: RemotePRBoundary?
    private var inspectOnly = false
    private var bindCount = 0
    private var failBind = false
    init() throws { repository = try .init(owner: "fixture", name: "remote-pr") }
    nonisolated var transport: RemotePullRequestTransport {
        .init(bind: { try await self.bind($0) }, read: { try await self.read($0) }, review: { try await self.review($0) },
            discard: { await self.discard($0) })
    }
    func setBoundary(_ value: RemotePRBoundary) { boundary = value }
    func setInspectOnly() { inspectOnly = true }
    func counts() -> [Int] { [reads.count, reviews.count, discarded.count] }
    func requests() -> [RemotePullRequestReadRequest] { reads }
    func setBindFailure(_ value: Bool) { failBind = value }
    func bindAttempts() -> Int { bindCount }
    func makeReview(_ request: RemotePullRequestReviewRequest) async throws -> RemotePullRequestReview { try await review(request) }
    func bind(_ target: RemoteWorkspaceTarget) throws -> RemoteWorkspaceTarget {
        bindCount += 1
        guard !failBind, target.rootID == nil || target.rootID == rootID else { throw RemotePullRequestFailure(.invalidTarget) }
        return .init(environmentID: target.environmentID, projectID: target.projectID, threadID: target.threadID, configuration: target.configuration, rootID: rootID)
    }
    func context(_ target: RemoteWorkspaceTarget) throws -> GitHubPullRequestContext {
        try .init(workspacePath: target.workspacePath, repository: repository, headRepository: repository, branch: "topic",
            headCommit: String(repeating: "a", count: 40), upstream: .init(remoteName: "origin", branch: "topic", commit: String(repeating: "a", count: 40)),
            defaultBranch: "main", baseBranches: ["main", "release"], readiness: .ready, sourceFingerprint: String(repeating: "c", count: 64))
    }
    func summary(_ number: Int = 7) throws -> GitHubPullRequestSummary {
        try .init(reference: .init(repository: repository, number: number), title: "Reviewed remote pull request",
            url: "https://github.com/fixture/remote-pr/pull/\(number)", state: .open, headBranch: "topic", baseBranch: "main",
            headCommit: String(repeating: "a", count: 40), baseCommit: String(repeating: "b", count: 40), headRepository: repository)
    }
    private func read(_ request: RemotePullRequestReadRequest) throws -> RemotePullRequestReadResult {
        reads.append(request)
        let value: RemotePullRequestValue
        switch request.query {
        case .context: value = .context(try context(request.target))
        case .list: value = .page(.init(items: [try summary()], truncated: false))
        case .detail(let reference): value = .detail(try .init(summary: summary(reference.number), body: "Remote Markdown\n\n[relative](../private.txt)", createdAt: Date()))
        case .resolve: value = .detail(try .init(summary: summary(), body: "Resolved exact PR", createdAt: Date()))
        }
        return .init(target: request.target, value: value)
    }
    private func review(_ request: RemotePullRequestReviewRequest) async throws -> RemotePullRequestReview {
        reviews.append(request)
        let value: RemotePullRequestReviewValue
        switch request.intent {
        case .create(let title, let body, let base, let draft):
            value = .creation(try .init(context: context(request.target), title: title, body: body,
                baseBranch: base ?? "main", baseCommit: String(repeating: "b", count: 40), isDraft: draft))
        case .checkout(let reference, let mode, let submodules, let title):
            let identity = GitWorktreeNodeIdentity(device: 1, inode: 2), path = request.target.workspacePath
            let query = GitHubPullRequestCheckoutRequest(sourcePath: path, destinationRoot: "/remote-only/managed", reference: reference,
                mode: mode, submodules: submodules, policy: inspectOnly ? .inspectOnly : .refresh)
            let destination = mode == .local ? path : inspectOnly ? "/remote-only/retained" : query.destinationRoot + "/" + query.id.uuidString
            let proof = GitHubPullRequestCheckoutProof(sourceIdentity: identity, repositoryIdentity: identity,
                gitDirectoryPath: path + "/.git", gitDirectoryIdentity: identity, commonDirectoryIdentity: identity,
                sourceFingerprint: String(repeating: "c", count: 64), statusDigest: String(repeating: "d", count: 64),
                destinationIdentity: inspectOnly ? identity : nil, destinationGitDirectoryPath: inspectOnly ? path + "/.git/worktrees/retained" : nil,
                destinationGitDirectoryIdentity: inspectOnly ? identity : nil, destinationStatusDigest: inspectOnly ? String(repeating: "e", count: 64) : nil,
                destinationHeadCommit: inspectOnly ? String(repeating: "a", count: 40) : nil, destinationBranch: inspectOnly ? "topic" : nil,
                destinationFingerprint: inspectOnly ? String(repeating: "f", count: 64) : nil,
                destinationConfigurationDigest: inspectOnly ? String(repeating: "a", count: 64) : nil)
            let plan = try GitHubPullRequestCheckoutPlan(request: query, sourcePath: path, repositoryPath: path, commonDirectoryPath: path + "/.git",
                destinationPath: destination, pullRequest: summary(reference.number), requestedBranch: "topic", requestedHeadCommit: String(repeating: "a", count: 40),
                disposition: mode == .local ? .local : inspectOnly ? .reuseWorktree : .createWorktree, proof: proof,
                baseRemote: .init(name: "origin", url: "https://github.com/fixture/remote-pr.git", repository: repository, needsCreation: false), destinationParentIdentity: identity)
            var configuration = request.target.configuration; configuration.workspacePath = destination; configuration.nativeThreadID = nil
            value = .checkout(try .init(projectID: request.target.projectID, projectPath: path, registeredWorkspacePath: path,
                sourceIncarnation: UUID(), targetConfiguration: configuration, checkpointPolicy: .disabled,
                title: title ?? "Remote PR #\(reference.number)", reviewSetup: false, plan: plan))
        }
        if let boundary { self.boundary = nil; await boundary.pause() }
        return try .init(target: request.target, value: value)
    }
    private func discard(_ request: RemotePullRequestDiscardRequest) -> RemotePullRequestDiscardResult {
        discarded.append(request); return .init(request: request, discarded: true)
    }
}

@Test(.timeLimit(.minutes(1))) @MainActor
func remotePullRequestReconnectRebindsTheNewHostAndRetainsItsPrivateDraft() async throws {
    let f = try RemotePRFixture()
    do {
        await f.update(); let model = try f.model()
        await model.refresh()
        let oldRoot = try #require(model.target.rootID)
        model.draft.title = "Retain this newer local PR title"
        f.store.disconnect()
        let replacement = try RemotePRPeer()
        await f.store.select(target: f.target, transport: replacement.transport, snapshot: f.snapshot,
            supported: true, canWrite: true, canMutate: true, perform: { _ in false }, openConversation: { _ in })
        await model.refresh()
        #expect(model.target.rootID != oldRoot && model.target.rootID == replacement.rootID)
        let binds = await replacement.bindAttempts()
        #expect(model.page?.items.count == 1 && binds == 1)
        #expect(model.draft.title == "Retain this newer local PR title")
        #expect(f.commands.isEmpty)
        await f.remove()
    } catch { await f.remove(); throw error }
}

@MainActor private final class RemotePRFixture {
    let root: URL
    let store: RemotePullRequestStore
    let peer: RemotePRPeer
    let environmentID = UUID()
    var thread = CodingThread(project: WorkspaceProject(path: "/remote-only/source"))
    var snapshot = WorkspaceSnapshot()
    var commands: [RemoteEnvironmentCommand] = []
    var opened: [UUID] = []
    var accepted = false
    init() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("coincide-remote-pr-ui-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        store = .init(root: root); peer = try .init()
    }
    var target: RemoteWorkspaceTarget { .init(environmentID: environmentID, projectID: thread.projectID, threadID: thread.id, configuration: .init(thread: thread)) }
    func update(canWrite: Bool = true, canMutate: Bool = true, supported: Bool = true) async {
        await store.select(target: target, transport: peer.transport, snapshot: snapshot, supported: supported, canWrite: canWrite, canMutate: canMutate,
            perform: { [self] value in commands.append(value); return accepted }, openConversation: { [self] in opened.append($0) })
    }
    func model() throws -> RemotePullRequestWorkspace { try #require(store.current) }
    func remove() async { await store.shutdown(); try? FileManager.default.removeItem(at: root) }
}

@Test(.timeLimit(.minutes(1))) @MainActor
func remotePullRequestSelectionIsReadFreeAndSameCaptureUpdatesPreserveBoundRootAndNativeInventory() async throws {
    let f = try RemotePRFixture()
    do {
        await f.update(); let model = try f.model()
        #expect(await f.peer.counts() == [0, 0, 0])
        await model.refresh()
        let rootID = try #require(model.target.rootID)
        #expect(model.context?.workspacePath == "/remote-only/source" && model.page?.items.count == 1)
        await f.update()
        #expect(try f.model() === model && model.target.rootID == rootID)
        let summary = try #require(model.page?.items.first); await model.select(summary.reference)
        #expect(model.detail?.body.contains("../private.txt") == true)
        model.referenceText = "#7"; await model.resolve()
        #expect(model.detail?.body == "Resolved exact PR" && f.commands.isEmpty)
        let requests = await f.peer.requests(); #expect(requests.allSatisfy { $0.target.rootID == rootID })
        await f.remove()
    } catch { await f.remove(); throw error }
}

@Test(.timeLimit(.minutes(1))) @MainActor
func remotePullRequestLateReviewCannotOverwriteNewerDraftAndDraftSurvivesDisconnectRestartAndQuitCancellation() async throws {
    let f = try RemotePRFixture(), boundary = RemotePRBoundary()
    do {
        await f.update(); let model = try f.model(); await model.refresh()
        model.draft.title = "Captured title"; model.draft.body = "Original exact body\n"; model.draft.isDraft = true
        await f.peer.setBoundary(boundary)
        let preparing = Task { await model.prepareCreation() }; await boundary.entered()
        model.draft.title = "Newer Caf\u{00e9} title"; model.draft.body = "Newer body\n\n- Kept exactly\n"
        await boundary.release(); await preparing.value
        #expect(model.creation == nil && f.commands.isEmpty)
        #expect(await f.peer.counts() == [2, 1, 1])
        await f.store.shutdown(); #expect(!f.store.hasUnsavedDrafts)
        let fields = model.draft.fields
        model.draft.title = "Late shutdown callback"; #expect(model.draft.fields.matches(fields))
        f.store.cancelShutdown(); model.draft.title = "Editable after cancelled Quit"; await f.store.shutdown()
        let reopened = RemotePullRequestStore(root: f.root)
        await reopened.select(target: f.target, transport: nil, snapshot: .init(), supported: true, canWrite: false, canMutate: false,
            perform: { _ in Issue.record("Disk restore must not send a native command"); return false }, openConversation: { _ in })
        let restored = try #require(reopened.current)
        #expect(restored.draft.title == "Editable after cancelled Quit" && restored.draft.body == fields.body && restored.draft.isDraft)
        #expect(restored.context == nil && !reopened.hasUnsavedDrafts)
        await reopened.shutdown(); await f.remove()
    } catch { await boundary.release(); await f.remove(); throw error }
}

@Test(.timeLimit(.minutes(1))) @MainActor
func remotePullRequestChangedProviderConfigurationInvalidatesHeldReviewAndCannotSubmitItsOpaqueIdentity() async throws {
    let f = try RemotePRFixture(), boundary = RemotePRBoundary()
    do {
        await f.update(); let model = try f.model(); await model.refresh(); model.draft.title = "Guard captured configuration"
        await f.peer.setBoundary(boundary)
        let preparing = Task { await model.prepareCreation() }; await boundary.entered()
        f.thread.model += "-replacement"; await f.update()
        await boundary.release(); await preparing.value; await model.create()
        #expect(model.creation == nil && model.context == nil && f.commands.isEmpty)
        #expect(model.draft.title == "Guard captured configuration")
        await f.remove()
    } catch { await boundary.release(); await f.remove(); throw error }
}

@Test(.timeLimit(.minutes(1))) @MainActor
func remotePullRequestCreationUsesExactOpaqueReviewOnceUntilRootReceiptRecoveryUnlocksActions() async throws {
    let f = try RemotePRFixture()
    do {
        await f.update(); let model = try f.model(); await model.refresh()
        model.draft.title = "Exact native review"; model.draft.body = "Markdown body\n"; await model.prepareCreation()
        let review = try #require(model.creation)
        await model.create()
        #expect(f.commands == [.pullRequest(target: review.target, action: .begin(reviewID: review.id, digest: review.digest))])
        await f.update(canWrite: false); await model.create()
        #expect(f.commands.count == 1 && model.draft.title == "Exact native review")
        let native = try #require(model.creationReview)
        let operation = PullRequestCreationOperation(projectID: f.thread.projectID, projectPath: f.target.workspacePath, sourceIncarnation: UUID(),
            review: native, phase: .unconfirmed, error: PullRequestCreationOperation.unconfirmedMessage)
        f.snapshot.pullRequestCreations = [operation]; await f.update()
        await model.recoverCreation(id: operation.id)
        #expect(f.commands.last == .pullRequest(target: model.target, action: .inspectCreation(operationID: operation.id)))
        await model.recoverCreation(id: UUID(), acknowledge: true)
        #expect(f.commands.count == 2)
        f.store.disconnect(); await model.recoverCreation(id: operation.id, acknowledge: true)
        #expect(f.commands.count == 2)
        await f.remove()
    } catch { await f.remove(); throw error }
}

@Test(.timeLimit(.minutes(1))) @MainActor
func remotePullRequestWorktreeReviewAllowsBusySourceReadOnlyReuseAndBothReviewKindsRemainAddressable() async throws {
    let f = try RemotePRFixture()
    do {
        await f.update(); let model = try f.model(); await model.refresh()
        model.draft.title = "Retained creation review"; await model.prepareCreation()
        let creation = try #require(model.creation)
        await f.update(canMutate: false); await f.peer.setInspectOnly()
        #expect(model.canCheckout(.worktree) && !model.canCheckout(.local) && !model.canCreate)
        let reference = try #require(model.page?.items.first?.reference)
        await model.prepareCheckout(reference: reference, mode: .worktree, submodules: .none)
        let checkout = try #require(model.checkout), native = try #require(model.checkoutReview)
        #expect(native.plan.isReadOnly && !native.reviewSetup && model.canAcceptCheckout)
        #expect(f.store.review(id: creation.id) == creation && f.store.review(id: checkout.id) == checkout)
        await model.beginCheckout()
        #expect(f.commands == [.pullRequest(target: checkout.target, action: .begin(reviewID: checkout.id, digest: checkout.digest))])
        await f.remove()
    } catch { await f.remove(); throw error }
}

@Test(.timeLimit(.minutes(1))) @MainActor
func remotePullRequestByteDistinctWorkspaceDraftsRemainSeparateAndManifestConflictsPreserveOriginal() async throws {
    let f = try RemotePRFixture()
    do {
        f.thread.workspacePath = "/remote-only/Caf\u{00e9}"; await f.update(); let first = try f.model(); first.draft.title = "Composed path draft"
        f.thread.workspacePath = "/remote-only/Cafe\u{0301}"; await f.update(); let second = try f.model(); second.draft.title = "Decomposed path draft"
        #expect(first !== second && f.store.retainedDrafts.count == 2)
        await f.store.shutdown()
        let persistence = RemotePullRequestDraftPersistence(root: f.root)
        var target = f.target
        #expect(try await persistence.load(target: target).title == "Decomposed path draft")
        var configuration = target.configuration; configuration.workspacePath = "/remote-only/Caf\u{00e9}"
        target = .init(environmentID: target.environmentID, projectID: target.projectID, threadID: target.threadID, configuration: configuration)
        #expect(try await persistence.load(target: target).title == "Composed path draft")
        let docs = try FileManager.default.contentsOfDirectory(at: f.root, includingPropertiesForKeys: nil).filter { $0.pathExtension == "json" }
        #expect(docs.count == 2)
        var matching: URL?
        for file in docs {
            let value = try JSONDecoder().decode(JSONValue.self, from: Data(contentsOf: file))
            if value["workspacePath"].string?.utf8.elementsEqual(target.workspacePath.utf8) == true { matching = file }
        }
        let corruptedFile = try #require(matching)
        let before = try Data(contentsOf: corruptedFile); try Data("owned-corrupt-draft".utf8).write(to: corruptedFile)
        await #expect(throws: (any Error).self) { try await persistence.save(target: target, fields: .init(title: "Must not overwrite concurrent data")) }
        #expect(try Data(contentsOf: corruptedFile) == Data("owned-corrupt-draft".utf8))
        #expect(!before.isEmpty)
        await f.remove()
    } catch { await f.remove(); throw error }
}

@Test(.timeLimit(.minutes(1))) @MainActor
func remotePullRequestAnotherDraftSaveCannotHideRetainedFailureAndShutdownDrainsObservedWriteCounts() async throws {
    let f = try RemotePRFixture()
    do {
        await f.update(); let first = try f.model(); first.draft.title = "First saved draft"
        await f.store.shutdown(); #expect(!f.store.hasUnsavedDrafts && f.store.pendingWrites == 0)
        f.store.cancelShutdown(); await f.update()
        let file = try #require(FileManager.default.contentsOfDirectory(at: f.root, includingPropertiesForKeys: nil).first { $0.pathExtension == "json" })
        let corrupt = Data("owned retained draft conflict".utf8); try corrupt.write(to: file)
        first.draft.title = "Keep this failed retained edit"
        f.thread = CodingThread(project: WorkspaceProject(path: "/remote-only/another-source")); await f.update()
        let second = try f.model(); second.draft.title = "Second scope saves successfully"
        await f.store.shutdown()
        #expect(f.store.pendingWrites == 0 && f.store.persistenceFailed && f.store.hasUnsavedDrafts)
        let preserved = try Data(contentsOf: file)
        #expect(first.draft.title == "Keep this failed retained edit" && preserved == corrupt)
        let saved = try await RemotePullRequestDraftPersistence(root: f.root).load(target: f.target)
        #expect(saved.title == "Second scope saves successfully")
        await f.remove()
    } catch { await f.remove(); throw error }
}

@Test(.timeLimit(.minutes(1))) @MainActor
func remotePullRequestAcceptedBeginConsumesOnlyReviewedIdentityAndKeepsCreateDraft() async throws {
    let f = try RemotePRFixture()
    do {
        await f.update(); let model = try f.model(); await model.refresh()
        model.draft.title = "Retain accepted form"; model.draft.body = "Exact original description\n"; await model.prepareCreation()
        let review = try #require(model.creation)
        f.accepted = true; await model.create(); await model.create()
        #expect(model.creation == nil && f.store.review(id: review.id) == nil && f.commands.count == 1)
        #expect(model.draft.title == "Retain accepted form" && model.draft.body == "Exact original description\n")
        await f.remove()
    } catch { await f.remove(); throw error }
}

@Test(.timeLimit(.minutes(1))) @MainActor
func remotePullRequestColdRecoveryBindsInspectionOnlyAndMetadataAcknowledgementCancellationSurviveMissingFolder() async throws {
    let f = try RemotePRFixture()
    do {
        let context = try await f.peer.context(f.target)
        let creation = try GitHubPullRequestCreateReview(context: context, title: "Retained creation", body: "Exact retained body", baseBranch: "main", baseCommit: String(repeating: "b", count: 40))
        let operation = PullRequestCreationOperation(projectID: f.thread.projectID, projectPath: f.target.workspacePath,
            sourceIncarnation: UUID(), review: creation, phase: .unconfirmed, error: PullRequestCreationOperation.unconfirmedMessage)
        f.snapshot.pullRequestCreations = [operation]; await f.peer.setBindFailure(true); await f.update()
        let model = try f.model(); #expect(model.target.rootID == nil)
        await model.recoverCreation(id: operation.id, acknowledge: true)
        #expect(f.commands.last == .pullRequest(target: f.target, action: .acknowledgeCreation(operationID: operation.id)))
        let reference = try await f.peer.summary().reference
        let wrapped = try await f.peer.makeReview(.init(target: f.target, intent: .checkout(reference: reference, mode: .worktree, submodules: .none, title: nil)))
        guard case .checkout(let checkout) = wrapped.value else { Issue.record("Expected native checkout review"); await f.remove(); return }
        f.snapshot.pullRequestCreations = []
        var checkoutOperation = PullRequestCheckoutOperation(review: checkout, phase: .unconfirmed, error: PullRequestCheckoutOperation.unconfirmedMessage)
        f.snapshot.pullRequestCheckouts = [checkoutOperation]; await f.update()
        await model.recoverCheckout(checkout.id, acknowledge: true)
        #expect(f.commands.last == .pullRequest(target: f.target, action: .acknowledgeCheckout(operationID: checkout.id)))
        checkoutOperation.phase = .accepted; checkoutOperation.error = nil; f.snapshot.pullRequestCheckouts = [checkoutOperation]; await f.update()
        await model.cancelCheckout(checkout.id)
        #expect(f.commands.last == .pullRequest(target: f.target, action: .cancelCheckout(operationID: checkout.id)))
        let beforeInspection = await f.peer.bindAttempts()
        #expect(beforeInspection == 0 && f.commands.count == 3)
        f.snapshot.pullRequestCreations = [operation]; f.snapshot.pullRequestCheckouts = []; await f.update()
        await model.recoverCreation(id: operation.id)
        let refusedInspection = await f.peer.bindAttempts()
        #expect(refusedInspection == 1 && f.commands.count == 3)
        await f.peer.setBindFailure(false); await model.recoverCreation(id: operation.id)
        guard case .pullRequest(let bound, .inspectCreation(let id)) = try #require(f.commands.last) else { Issue.record("Inspection must capture a bound root"); await f.remove(); return }
        #expect(bound.rootID != nil && id == operation.id && f.commands.count == 4)
        let counts = await f.peer.counts(); #expect(counts[0] == 0)
        model.draft.title = "Keep all fields"; model.draft.body = "Keep body"; model.draft.baseBranch = "main"; model.draft.isDraft = true
        await f.store.shutdown(); let fields = model.draft.fields
        model.draft.title = "Late title"; model.draft.body = "Late body"; model.draft.baseBranch = "release"; model.draft.isDraft = false
        #expect(model.draft.fields.matches(fields))
        await f.remove()
    } catch { await f.remove(); throw error }
}

@Test(.timeLimit(.minutes(1))) @MainActor
func remotePullRequestOffscreenSheetCheckoutAndRecoveryFitSmallBoundsInBothAppearancesWithoutNativeActions() async throws {
    _ = NSApplication.shared
    let f = try RemotePRFixture()
    do {
        await f.update(); let model = try f.model(); await model.refresh()
        let reference = try #require(model.page?.items.first?.reference)
        await f.peer.setInspectOnly(); await model.prepareCheckout(reference: reference, mode: .worktree, submodules: .none)
        let review = try #require(model.checkoutReview)
        #expect(review.plan.isReadOnly && review.plan.requestedBranch == "topic" && !review.reviewSetup)
        #expect(PullRequestPresentation.head(try #require(model.context)) == "fixture/remote-pr:topic")
        for scheme in [ColorScheme.light, .dark] {
            for bounds in [CGSize(width: 480, height: 560), CGSize(width: 640, height: 680)] {
                let views: [AnyView] = [
                    AnyView(RemotePullRequestsSheet(store: f.store, requestPush: { Issue.record("Rendering must not request a push") })),
                    AnyView(RemotePullRequestCheckoutPane(model: model, reference: reference))
                ]
                for view in views { try remotePRLayoutWithoutWindow(view.environment(\.colorScheme, scheme), bounds: bounds) }
            }
        }
        let uncertain = PullRequestCheckoutOperation(review: review, phase: .unconfirmed, error: PullRequestCheckoutOperation.unconfirmedMessage)
        f.snapshot.pullRequestCheckouts = [uncertain]; await f.update()
        for scheme in [ColorScheme.light, .dark] {
            let view = ScrollView { RemotePullRequestOperations(model: model).padding(12) }.environment(\.colorScheme, scheme)
            try remotePRLayoutWithoutWindow(view, bounds: CGSize(width: 480, height: 560))
        }
        #expect(f.commands.isEmpty && f.opened.isEmpty)
        #expect(model.checkoutReview?.id == review.id && model.checkoutOperations.first?.id == uncertain.id)
        await f.remove()
    } catch { await f.remove(); throw error }
}

@MainActor private func remotePRLayoutWithoutWindow<Content: View>(_ content: Content, bounds: CGSize) throws {
    let hosting = NSHostingController(rootView: content)
    let measured = hosting.sizeThatFits(in: bounds)
    #expect(measured.width.isFinite && measured.height.isFinite && measured.width > 0 && measured.height > 0)
    #expect(measured.width <= bounds.width + 1 && measured.height <= bounds.height + 1)
    hosting.view.frame = CGRect(origin: .zero, size: measured)
    hosting.view.layoutSubtreeIfNeeded()
    #expect(hosting.view.window == nil, "Offscreen layout must never create or present a native window.")
    #expect(hosting.view.bounds.width > 0 && hosting.view.bounds.height > 0)
}
