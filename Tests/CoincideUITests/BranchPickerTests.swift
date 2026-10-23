import AppKit
import CoincideCore
import SwiftUI
import Testing
@testable import Coincide

@MainActor private func pickerCatalog() -> GitBranchCatalog {
    let now = Date()
    return .init(repositoryRoot: "/tmp/repository", entries: [
        .init(ref: "refs/heads/main", upstream: "origin/main", committedAt: now.addingTimeInterval(-500)),
        .init(ref: "refs/heads/feature/search", committedAt: now, isHead: true),
        .init(ref: "refs/heads/feature/older", committedAt: now.addingTimeInterval(-1_000)),
        .init(ref: "refs/heads/elsewhere", worktreePath: "/tmp/other-checkout", committedAt: now.addingTimeInterval(-50)),
        .init(ref: "refs/remotes/origin/main", committedAt: now.addingTimeInterval(-400), remote: "origin"),
        .init(ref: "refs/remotes/origin/release/2.0", committedAt: now.addingTimeInterval(-10), remote: "origin")
    ], defaultBranch: .init(name: "main", remoteRef: "refs/remotes/origin/main"))
}

@MainActor @Test func branchPickerRowsSearchCreateFromQueryAndDetectPullRequests() {
    let catalog = pickerCatalog()
    let all = BranchPickerRows.make(catalog: catalog, query: "")
    #expect(all.local.map(\.name) == ["feature/search", "main", "feature/older"])
    #expect(all.otherWorktrees.map(\.name) == ["elsewhere"] && all.remote.map(\.name) == ["origin/release/2.0", "origin/main"])
    #expect(all.create == nil && all.pullRequest == nil)
    let search = BranchPickerRows.make(catalog: catalog, query: "old")
    #expect(search.local.map(\.name) == ["feature/older"] && search.create == "old")
    #expect(BranchPickerRows.make(catalog: catalog, query: "MAIN").create == nil)
    #expect(BranchPickerRows.make(catalog: catalog, query: "release").remote.map(\.name) == ["origin/release/2.0"])
    #expect(BranchPickerRows.make(catalog: catalog, query: "#123").pullRequest == "#123" && BranchPickerRows.make(catalog: catalog, query: "#123").create == nil)
    #expect(BranchPickerRows.make(catalog: catalog, query: "45").pullRequest == "#45")
    #expect(BranchPickerRows.pullRequestReference("https://github.com/o/r/pull/9") == "https://github.com/o/r/pull/9")
    #expect(BranchPickerRows.pullRequestReference("https://github.com/o/r/issues/9") == nil && BranchPickerRows.pullRequestReference("#0") == nil)
    #expect(BranchPickerRows.make(catalog: catalog, query: "#1", allowsPullRequest: false).pullRequest == nil)
    for invalid in ["has space", "-flag", "a..b", "trailing/", "x.lock", "a~b", "bad:name", ".hidden/x"] { #expect(!BranchPickerRows.isCreatable(invalid, existing: [])) }
    #expect(BranchPickerRows.isCreatable("feature/new-thing", existing: ["main"]))
    #expect(catalog.otherWorktree(for: catalog.entries[3]) == "/tmp/other-checkout")
    #expect(WorktreeBaseResolution.remote(for: "main", in: catalog)?.ref == "refs/remotes/origin/main")
    #expect(WorktreeBaseResolution.remote(for: "origin/release/2.0", in: catalog)?.localName == "release/2.0")
    #expect(WorktreeBaseResolution.remote(for: "feature/older", in: catalog) == nil && WorktreeBaseResolution.remote(for: "main", in: nil) == nil)
}

@MainActor @Test func branchPickerFitsItsPopoverInBothAppearances() {
    _ = NSApplication.shared
    for scheme in [ColorScheme.light, .dark] {
        for base in [false, true] {
            let controller = NSHostingController(rootView: BranchPickerView(catalog: pickerCatalog(), loading: false, error: nil, baseMode: base) { _ in }
                .environment(\.colorScheme, scheme))
            let size = controller.sizeThatFits(in: CGSize(width: 400, height: 600))
            #expect(size.width <= 341 && size.height <= 600)
        }
    }
}
