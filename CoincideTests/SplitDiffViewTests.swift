import AppKit
import CoincideKit
import Testing
@testable import Coincide

@MainActor
struct SplitDiffViewTests {
    private var diff: GitDiff {
        let lines: [DiffLine] = [
            .init(kind: .context, text: "start", oldLine: 1, newLine: 1),
            .init(kind: .deletion, text: "old first", oldLine: 2),
            .init(kind: .deletion, text: "old second", oldLine: 3),
            .init(kind: .addition, text: "new first", newLine: 2),
            .init(kind: .context, text: "end", oldLine: 4, newLine: 3),
        ]
        return GitDiff(files: [FileDiff(path: "Code.swift", status: .modified, additions: 1, deletions: 2, hunks: [
            DiffHunk(oldStart: 1, oldCount: 4, newStart: 1, newCount: 3, lines: lines),
        ])])
    }

    @Test func switchingLayoutsKeepsFileHeadersAndCollapseActions() throws {
        let document = makeDocument(diff)
        let table = try table(in: document)
        #expect(table.numberOfRows == 7)
        document.setLayout(.sideBySide)
        #expect(table.numberOfRows == 6)
        #expect(document.tableView(table, isGroupRow: 0))
        #expect(document.tableView(table, shouldSelectRow: 3))
        #expect(!document.tableView(table, shouldSelectRow: 0))
        document.setCollapsed(true, path: "Code.swift")
        #expect(table.numberOfRows == 1 && document.allCollapsed)
        document.setLayout(.unified)
        #expect(table.numberOfRows == 1)
        document.setAllCollapsed(false)
        #expect(table.numberOfRows == 7)
    }

    @Test func copyAndCommentsUseTheSelectedSideAndSkipSpacers() throws {
        let document = makeDocument(diff)
        document.setLayout(.sideBySide)
        let table = try table(in: document)
        table.selectRowIndexes(IndexSet(integersIn: 3...4), byExtendingSelection: false)
        table.onSelectPosition?(NSPoint(x: 1, y: 0))
        #expect(document.selectedText() == "old first\nold second")
        let before = try #require(document.commentTarget())
        let oldComment = try #require(MessageContext.DiffComment(file: diff.files[0], lines: before.lines, comment: "why?"))
        #expect(oldComment.isBeforeChange && oldComment.lineStart == 2 && oldComment.lineEnd == 3)
        #expect(oldComment.diff.contains("-old first\n-old second"))

        #expect(table.onMoveSide?(.after) == true)
        #expect(document.selectedText() == "new first")
        let after = try #require(document.commentTarget())
        let newComment = try #require(MessageContext.DiffComment(file: diff.files[0], lines: after.lines, comment: "why?"))
        #expect(!newComment.isBeforeChange && newComment.lineStart == 2 && newComment.lineEnd == 2)
        #expect(newComment.diff.contains("+new first") && !newComment.diff.contains("-old"))
        table.selectRowIndexes(IndexSet(integer: 4), byExtendingSelection: false)
        #expect(document.selectedText().isEmpty && document.commentTarget() == nil)
    }

    @Test func bothPanesStayVisibleAndShareTheHorizontalOffset() throws {
        var long = diff
        long.files[0].hunks[0].lines[3].text = String(repeating: "long line ", count: 80)
        let document = makeDocument(long)
        document.setLayout(.sideBySide)
        let table = try table(in: document)
        let scroll = try #require(table.enclosingScrollView)
        scroll.contentView.scroll(to: NSPoint(x: 120, y: 0))
        scroll.reflectScrolledClipView(scroll.contentView)
        let pair = try #require(document.tableView(table, viewFor: table.tableColumns[0], row: 3) as? DiffSplitLineView)
        pair.frame = NSRect(x: 0, y: 0, width: table.tableColumns[0].width, height: 22)
        pair.layoutSubtreeIfNeeded()
        let viewport = scroll.contentView.bounds
        #expect(pair.before.frame.minX == viewport.minX)
        #expect(pair.after.frame.minX == viewport.midX)
        #expect(pair.before.frame.width == pair.after.frame.width)
        // AppKit permits views to draw outside their bounds by default. Each column and the
        // fixed heading must clip, otherwise a later cell's background covers its neighbor.
        #expect(pair.clipsToBounds && pair.before.clipsToBounds && pair.after.clipsToBounds)
        #expect(document.subviews.compactMap { $0 as? DiffSideLabels }.first?.clipsToBounds == true)
        #expect(pair.after.frame.maxX == viewport.maxX)
        #expect(pair.before.horizontalOffset == viewport.minX && pair.after.horizontalOffset == viewport.minX)
        #expect(pair.before.accessibilityLabel() == "Removed line 2: old first")
    }

    @Test func binaryRenamedAndEmptyFilesRemainReadableInBothLayouts() throws {
        let files = [
            FileDiff(path: "image.png", status: .modified, isBinary: true),
            FileDiff(path: "new.swift", oldPath: "old.swift", status: .renamed),
            FileDiff(path: "empty.txt", status: .added),
        ]
        let document = makeDocument(GitDiff(files: files))
        let table = try table(in: document)
        for layout in DiffLayout.allCases {
            document.setLayout(layout)
            #expect(table.numberOfRows == 6)
            for row in [0, 2, 4] { #expect(document.tableView(table, isGroupRow: row)) }
            let note = document.tableView(table, viewFor: table.tableColumns[0], row: 1)
            #expect(note?.accessibilityLabel() == "Binary file not shown.")
        }
    }

    @Test func switchingLayoutsKeepsTheSameSourceLineAtTheTop() throws {
        let removed = (1...100).map { (number: Int) in DiffLine(kind: .deletion, text: "old \(number)", oldLine: number) }
        let added = (1...100).map { (number: Int) in DiffLine(kind: .addition, text: "new \(number)", newLine: number) }
        let context = (101...300).map { (number: Int) in DiffLine(kind: .context, text: "same \(number)", oldLine: number, newLine: number) }
        let diff = GitDiff(files: [FileDiff(path: "large.swift", status: .modified, hunks: [
            DiffHunk(oldStart: 1, oldCount: 300, newStart: 1, newCount: 300, lines: removed + added + context),
        ])])
        let document = makeDocument(diff)
        let window = NSWindow(contentRect: document.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = document
        defer { window.close() }
        document.layoutSubtreeIfNeeded()
        let table = try table(in: document)
        table.layoutSubtreeIfNeeded()
        #expect(table.frame.height > 1_000)
        let scroll = try #require(table.enclosingScrollView)
        let oldRow = 252 // file header + hunk header + 200 changed lines + 50 context lines
        scroll.contentView.scroll(to: NSPoint(x: 0, y: table.rect(ofRow: oldRow).minY))
        scroll.reflectScrolledClipView(scroll.contentView)
        #expect(scroll.contentView.bounds.minY > 1_000)
        let belowHeader = table.rect(ofRow: 0).height + 1
        let visibleRow = table.row(at: NSPoint(x: 0, y: scroll.contentView.bounds.minY + belowHeader))
        #expect(visibleRow > 200)
        document.setLayout(.sideBySide)
        let splitRow = table.row(at: NSPoint(x: 0, y: scroll.contentView.bounds.minY + belowHeader))
        #expect(splitRow == visibleRow - 100)
        document.setLayout(.unified)
        #expect(table.row(at: NSPoint(x: 0, y: scroll.contentView.bounds.minY + belowHeader)) == visibleRow)
    }

    @Test func layoutPreferenceSurvivesRelaunchAndUnknownValuesFallBack() throws {
        let folder = TemporaryDirectory("split-diff-preferences")
        let state = UIState(directory: folder.url)
        #expect(state.values.diffLayout == .unified)
        state.update { $0.diffLayout = .sideBySide }
        state.flush()
        #expect(UIState(directory: folder.url).values.diffLayout == .sideBySide)
        let future = Data(#"{"diffLayout":"future-layout"}"#.utf8)
        let decoded = try JSONDecoder().decode(UIState.Values.self, from: future)
        #expect(decoded.diffLayout == .unified)
    }

    private func makeDocument(_ diff: GitDiff) -> DiffDocumentView {
        let document = DiffDocumentView(frame: NSRect(x: 0, y: 0, width: 700, height: 360))
        document.layoutSubtreeIfNeeded()
        document.show(diff, presentation: DiffPresentation.make(diff), keepPosition: false)
        document.layoutSubtreeIfNeeded()
        return document
    }

    private func table(in document: DiffDocumentView) throws -> DiffTableView {
        let scroll = try #require(document.subviews.compactMap { $0 as? NSScrollView }.first)
        return try #require(scroll.documentView as? DiffTableView)
    }
}
