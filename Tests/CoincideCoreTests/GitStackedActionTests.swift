import Foundation
import Testing
@testable import CoincideCore

// Ported from T3's GitActionsControl.logic.test.ts.
private func status(_ edit: (inout GitQuickActionStatus) -> Void = { _ in }) -> GitQuickActionStatus {
    var value = GitQuickActionStatus(hasBranch: true, hasChanges: false, hasOpenPullRequest: false, aheadCount: 0, behindCount: 0, hasUpstream: true)
    edit(&value); return value
}

@Test func quickActionPrefersPushWhenCleanAheadWithAnOpenPullRequest() {
    let quick = GitActionResolver.quickAction(status { $0.aheadCount = 3; $0.hasOpenPullRequest = true }, isBusy: false)
    #expect(quick.kind == .run(.push) && quick.label == "Push" && !quick.disabled)
}

@Test func quickActionCreatesPullRequestWhenSyncedButAheadOfDefaultEvenWithChangesInMenu() {
    let synced = status { $0.aheadOfDefaultCount = 1 }
    let quick = GitActionResolver.quickAction(synced, isBusy: false)
    #expect(quick.kind == .run(.createPullRequest) && quick.label == "Create PR" && !quick.disabled)
    #expect(GitActionResolver.menuItems(synced, isBusy: false).first { $0.id == .pullRequest }?.disabled == false)
    var dirty = synced; dirty.hasChanges = true
    #expect(GitActionResolver.menuItems(dirty, isBusy: false).first { $0.id == .pullRequest }?.disabled == false)
    #expect(GitActionResolver.quickAction(dirty, isBusy: false).kind == .run(.commitPushPullRequest))
}

@Test func quickActionOnTheDefaultBranchCommitsAndPushesAndRequiresConfirmation() {
    let quick = GitActionResolver.quickAction(status { $0.hasChanges = true }, isBusy: false, isDefaultBranch: true)
    #expect(quick.kind == .run(.commitPush) && quick.label == "Commit & Push" && !quick.disabled)
    #expect(!GitActionResolver.requiresDefaultBranchConfirmation(.commit, isDefaultBranch: true))
    for action in [GitStackedAction.push, .createPullRequest, .commitPush, .commitPushPullRequest] {
        #expect(GitActionResolver.requiresDefaultBranchConfirmation(action, isDefaultBranch: true))
        #expect(!GitActionResolver.requiresDefaultBranchConfirmation(action, isDefaultBranch: false))
    }
    let ahead = GitActionResolver.quickAction(status { $0.aheadCount = 1 }, isBusy: false, isDefaultBranch: true)
    #expect(ahead.kind == .run(.push) && ahead.label == "Push" && !ahead.disabled)
    #expect(ahead.action?.includesCommit == false && GitActionResolver.requiresDefaultBranchConfirmation(.push, isDefaultBranch: true))
    let firstPush = GitActionResolver.quickAction(status { $0.aheadCount = 1; $0.hasUpstream = false }, isBusy: false, isDefaultBranch: true)
    #expect(firstPush.kind == .run(.push) && !firstPush.disabled)
}

@Test func quickActionWithoutUpstreamPushesAndCreatesOrPublishes() {
    let ahead = status { $0.hasUpstream = false; $0.aheadCount = 2 }
    #expect(GitActionResolver.quickAction(ahead, isBusy: false).kind == .run(.createPullRequest))
    #expect(GitActionResolver.quickAction(ahead, isBusy: false).label == "Push & Create PR")
    #expect(GitActionResolver.quickAction(ahead, isBusy: false, isDefaultBranch: false, hasPrimaryRemote: false) == .init(label: "Publish Repository", disabled: false, kind: .publish))
    let noRemoteChanges = GitActionResolver.quickAction(status { $0.hasUpstream = false; $0.hasChanges = true }, isBusy: false, hasPrimaryRemote: false)
    #expect(noRemoteChanges.kind == .run(.commit))
    #expect(GitActionResolver.menuItems(status { $0.hasChanges = true }, isBusy: false, hasPrimaryRemote: false).map(\.id) == [.commit])
    let nothing = GitActionResolver.quickAction(status { $0.hasUpstream = false }, isBusy: false)
    #expect(nothing.disabled && nothing.hint == "No local commits to push.")
}

@Test func quickActionPullsWhenBehindAndHintsWhenDivergedDetachedBusyOrUpToDate() {
    #expect(GitActionResolver.quickAction(status { $0.behindCount = 2 }, isBusy: false).kind == .pull)
    let diverged = GitActionResolver.quickAction(status { $0.behindCount = 1; $0.aheadCount = 1 }, isBusy: false)
    #expect(diverged.disabled && diverged.label == "Sync Branch" && diverged.hint != nil)
    #expect(GitActionResolver.quickAction(status { $0.hasBranch = false; $0.hasChanges = true }, isBusy: false).disabled)
    #expect(GitActionResolver.quickAction(status(), isBusy: true).hint == "Git action in progress.")
    #expect(GitActionResolver.quickAction(nil, isBusy: false).hint == "Git status is unavailable.")
    #expect(GitActionResolver.quickAction(status(), isBusy: false).hint == "Branch is up to date. No action needed.")
    #expect(GitActionResolver.quickAction(status { $0.hasOpenPullRequest = true }, isBusy: false).disabled)
    #expect(GitActionResolver.menuItems(status { $0.hasOpenPullRequest = true }, isBusy: false).map(\.id) == [.commit, .push])
    let behindMenu = GitActionResolver.menuItems(status { $0.behindCount = 1; $0.aheadCount = 1 }, isBusy: false)
    #expect(behindMenu.first { $0.id == .push }?.disabled == true)
}

@Test func defaultBranchDialogCopyAndFeatureBranchNamingFollowT3() {
    let copy = GitActionResolver.defaultBranchDialogCopy(.commitPushPullRequest, branch: "main", includesCommit: true)
    #expect(copy.title == "Commit, push & create PR from the default branch?" && copy.continueLabel == "Commit, Push & Create PR")
    #expect(GitActionResolver.defaultBranchDialogCopy(.push, branch: "main", includesCommit: false).continueLabel == "Push to main")
    #expect(GitActionResolver.featureBranchUnavailableReason(branch: "main", hasChanges: true) == nil)
    #expect(GitActionResolver.featureBranchUnavailableReason(branch: "main", hasChanges: false)?.contains("main") == true)
    #expect(GitActionResolver.autoFeatureBranchName(existing: ["main", "feature/fix-toast-copy", "feature/fix-toast-copy-2"], preferred: "fix toast copy") == "feature/fix-toast-copy-3")
    #expect(GitActionResolver.autoFeatureBranchName(existing: ["Feature/Ticket-1"], preferred: "feature/ticket-1") == "feature/ticket-1-2")
    #expect(GitActionResolver.autoFeatureBranchName(existing: []) == "feature/update")
    #expect(GitActionResolver.autoFeatureBranchName(existing: ["feature/a/b"], preferred: "feature/a") == "feature/a-2")
    #expect(GitActionResolver.sanitizeBranchFragment("  Fix: \"Quoted\" Thing!! ") == "fix-quoted-thing")
    #expect(GitActionResolver.sanitizeBranchFragment("...") == "update")
    #expect(GitActionResolver.featureBranchSeed(commitMessage: "feat(ui): add native diff\n\nBody") == "add native diff")
    #expect(GitActionResolver.formatElapsed(59) == "59s" && GitActionResolver.formatElapsed(133) == "2m 13s")
}
