import CoincideTerminal
import Foundation
import Testing

@Test func terminalGroupsSplitAfterTheActivePaneUpToFourAndAdoptTheLatestAxis() {
    let a = UUID(), b = UUID(), c = UUID(), d = UUID(), e = UUID()
    var layout = TerminalThreadLayout()
    layout.addGroup(a)
    let first = layout.split(b, after: a, axis: .horizontal), second = layout.split(c, after: a, axis: .vertical)
    #expect(first && second)
    #expect(layout.groups.count == 1 && layout.groups[0].sessionIDs == [a, c, b] && layout.groups[0].axis == .vertical)
    let third = layout.split(d, after: b, axis: .horizontal)
    #expect(third && layout.groups[0].sessionIDs == [a, c, b, d])
    #expect(!layout.canSplit(a))
    let overLimit = layout.split(e, after: a, axis: .horizontal)
    #expect(!overLimit, "A group holds at most four terminals.")
    let duplicate = layout.split(b, after: a, axis: .horizontal), orphan = layout.split(e, after: UUID(), axis: .horizontal)
    #expect(!duplicate && !orphan, "A session cannot join a second group or follow an unknown pane.")
    layout.addGroup(e)
    #expect(layout.groups.map(\.sessionIDs) == [[a, c, b, d], [e]])
}

@Test func closingTerminalPanesSelectsANeighbourAndCollapsesEmptyGroups() {
    let a = UUID(), b = UUID(), c = UUID(), d = UUID()
    var layout = TerminalThreadLayout()
    layout.addGroup(a); layout.split(b, after: a, axis: .horizontal); layout.split(c, after: b, axis: .horizontal)
    layout.addGroup(d)
    let afterB = layout.remove(b), afterC = layout.remove(c), afterD = layout.remove(d)
    #expect(afterB == c && afterC == a)
    #expect(afterD == a, "Removing the last pane of a tab selects the previous tab.")
    #expect(layout.groups.map(\.sessionIDs) == [[a]])
    let afterA = layout.remove(a), unknown = layout.remove(UUID())
    #expect(afterA == nil && layout.groups.isEmpty && unknown == nil)
}

@Test func terminalLayoutNormalizationReconcilesSessionsWithStableIdentities() {
    let a = UUID(), b = UUID(), c = UUID(), missing = UUID(), group = UUID()
    let saved = TerminalThreadLayout(groups: [
        .init(id: group, sessionIDs: [a, missing, b], axis: .vertical),
        .init(id: group, sessionIDs: [b, c], axis: .horizontal)
    ])
    let normalized = saved.normalized(sessionIDs: [a, b, c])
    #expect(normalized.groups.map(\.sessionIDs) == [[a, b], [c]])
    #expect(normalized.groups[0].id == group && normalized.groups[0].axis == .vertical)
    #expect(normalized.groups[1].id != group, "Duplicate group identities are replaced.")
    #expect(normalized == normalized.normalized(sessionIDs: [a, b, c]), "Normalization is idempotent.")
    let fresh = TerminalThreadLayout().normalized(sessionIDs: [a, b])
    #expect(fresh.groups.map(\.sessionIDs) == [[a], [b]] && fresh.groups.map(\.id) == [a, b])
    let oversized = TerminalThreadLayout(groups: [.init(sessionIDs: (0..<6).map { _ in UUID() })])
    let ids = oversized.groups[0].sessionIDs
    #expect(oversized.normalized(sessionIDs: ids).groups.map(\.sessionIDs.count) == [4, 2])
}

@Test func terminalWindowArchiveValidatesGroupsVisibilityAndHeights() throws {
    let thread = UUID(), other = UUID(), a = UUID(), b = UUID()
    func tab(_ id: UUID, _ thread: UUID) -> TerminalTabArchive {
        .init(id: id, threadID: thread, workspacePath: "/tmp", directory: "/tmp", title: "T", text: "x", isCommand: false, exitCode: nil)
    }
    var archive = TerminalWindowArchive(tabs: [tab(a, thread), tab(b, thread)], visibleThreadIDs: [thread], panelHeights: [thread: 320],
        groups: [.init(id: UUID(), threadID: thread, sessionIDs: [a, b], axis: .horizontal)])
    try archive.validate()
    archive.groups = [.init(id: UUID(), threadID: other, sessionIDs: [a], axis: .horizontal)]
    #expect(throws: (any Error).self, "A group may only contain its own conversation's tabs.") { try archive.validate() }
    archive.groups = [.init(id: UUID(), threadID: thread, sessionIDs: [a], axis: .horizontal),
                      .init(id: UUID(), threadID: thread, sessionIDs: [a], axis: .vertical)]
    #expect(throws: (any Error).self) { try archive.validate() }
    archive.groups = [.init(id: UUID(), threadID: thread, sessionIDs: [], axis: .horizontal)]
    #expect(throws: (any Error).self) { try archive.validate() }
    archive.groups = nil; archive.panelHeights = [thread: .infinity]
    #expect(throws: (any Error).self) { try archive.validate() }
    archive.panelHeights = [thread: 10]
    #expect(throws: (any Error).self) { try archive.validate() }
    archive.panelHeights = nil; archive.visibleThreadIDs = [thread, thread]
    #expect(throws: (any Error).self) { try archive.validate() }
}
