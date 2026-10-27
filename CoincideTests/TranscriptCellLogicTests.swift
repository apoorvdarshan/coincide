import AppKit
import CoincideKit
import Testing

@testable import Coincide

/// What a tool call shows when expanded, and the one-line labels of transcript rows.
struct TranscriptToolDetailTests {
    private func tool(
        _ category: ToolCategory?, title: String? = nil, detail: String? = nil, output: String = "", status: ItemStatus? = nil,
        duration: TimeInterval? = nil
    ) -> TranscriptItem {
        let start = Date(timeIntervalSinceReferenceDate: 800_000_000)
        return TranscriptItem(
            kind: .tool, text: output, title: title, detail: detail, category: category, status: status, createdAt: start,
            completedAt: duration.map { start.addingTimeInterval($0) })
    }

    private func color(at index: Int, in text: NSAttributedString) -> NSColor? {
        text.attribute(.foregroundColor, at: index, effectiveRange: nil) as? NSColor
    }

    @Test func aCommandShowsAPromptThenItsOutputWithoutTerminalEscapes() {
        let item = tool(.command, title: "Run tests", detail: "swift test", output: "\u{1B}[32mok\u{1B}[0m\n\n")
        let text = TranscriptToolDetail.render(item).string
        #expect(text.string == "$ swift test\n\nok")
        #expect(color(at: 0, in: text) == .secondaryLabelColor)
        // The command is highlighted as shell.
        #expect(color(at: 2, in: text) != .labelColor)
        #expect(color(at: text.length - 1, in: text) == .labelColor)
    }

    @Test func aCommandWithoutInputFallsBackToItsTitleWithoutBackticks() {
        #expect(TranscriptToolDetail.render(tool(.command, title: "Ran `ls -la`")).string.string == "$ ls -la")
        #expect(TranscriptToolDetail.render(tool(.command, title: "`")).string.string == "$ `")
        #expect(TranscriptToolDetail.render(tool(.command)).string.string == "")
        #expect(TranscriptToolDetail.render(tool(.command, output: "only output")).string.string == "only output")
    }

    @Test func longOutputKeepsItsEnd() {
        let output = "first line\n" + String(repeating: "x", count: TranscriptToolDetail.outputLimit) + "END"
        let text = TranscriptToolDetail.render(tool(.command, detail: "make", output: output)).string.string
        #expect(text.hasPrefix("$ make\n\n… earlier output trimmed …\n"))
        #expect(text.hasSuffix("xEND"))
        #expect(!text.contains("first line"))
        #expect(text.utf16.count < TranscriptToolDetail.outputLimit + 100)
    }

    @Test func fileChangesShowTheirDiffAndDimTheirOutput() throws {
        let diff = "@@ -1 +1 @@\n-old\n+new"
        let text = TranscriptToolDetail.render(tool(.fileChange, title: "Edit a.swift", detail: diff, output: "Applied")).string
        #expect(text.string == diff + "\n\nApplied")
        let added = (text.string as NSString).range(of: "+new").location
        #expect(text.attribute(.chatLineBackground, at: added, effectiveRange: nil) != nil)
        #expect(color(at: text.length - 1, in: text) == .secondaryLabelColor)
        // Input that repeats the title is not shown twice.
        #expect(TranscriptToolDetail.render(tool(.fileChange, title: "a.swift", detail: "a.swift")).string.string == "")
    }

    @Test func jsonInputIsPrettyPrintedAndHighlighted() {
        let text = TranscriptToolDetail.render(tool(.mcp, title: "query", detail: "{\"b\":1,\"a\":[1,2]}")).string
        #expect(text.string == "{\n  \"a\" : [\n    1,\n    2\n  ],\n  \"b\" : 1\n}")
        #expect(color(at: (text.string as NSString).range(of: "\"a\"").location, in: text) != .labelColor)
        // Text that only looks like JSON stays as it is.
        #expect(TranscriptToolDetail.render(tool(.read, detail: "{not json")).string.string == "{not json")
    }

    @Test func aCallHasDetailWhenItHasInputBeyondItsTitleOrOutput() {
        #expect(!TranscriptToolDetail.hasDetail(tool(.read)))
        #expect(!TranscriptToolDetail.hasDetail(tool(.read, title: "a.swift", detail: " a.swift ", output: " \n")))
        #expect(TranscriptToolDetail.hasDetail(tool(.read, title: "a.swift", detail: "b.swift")))
        #expect(TranscriptToolDetail.hasDetail(tool(.read, output: "contents")))
    }

    @Test func onlyFinishedCallsOfASecondOrMoreShowTheirDuration() {
        #expect(TranscriptToolDetail.durationText(tool(.command, status: .running, duration: 30)) == nil)
        #expect(TranscriptToolDetail.durationText(tool(.command, status: .completed, duration: 0.5)) == nil)
        #expect(TranscriptToolDetail.durationText(tool(.command, status: .completed)) == nil)
        #expect(TranscriptToolDetail.durationText(tool(.command, status: .failed, duration: 75)) == "1m 15s")
        #expect(TranscriptToolDetail.durationText(tool(.command, duration: 2.25)) == "2.3s")
    }

    @Test func everyStatusHasAHeaderState() {
        let pairs: [(ItemStatus?, TranscriptDisclosureHeader.Status)] = [
            (.running, .running), (.completed, .completed), (.failed, .failed), (.declined, .declined), (.waiting, .waiting), (nil, .none),
        ]
        for (status, expected) in pairs {
            #expect(TranscriptToolDetail.status(tool(.other, status: status)) == expected)
        }
    }

    @Test func titlesFallBackToTheCategoryName() {
        #expect(TranscriptToolCell.title(tool(.search)).string == "Search")
        #expect(TranscriptToolCell.title(tool(nil)).string == "Tool")
        #expect(TranscriptToolCell.title(tool(.web, title: "Fetch `https://x.dev`")).string == "Fetch https://x.dev")
    }
}

struct TranscriptInlineLabelTests {
    private let font = NSFont.systemFont(ofSize: 12)

    @Test func labelsKeepTheFirstLineWithCodeInMonospaceAndStrongInBold() throws {
        let label = TranscriptText.inlineLabel("Run `make test` **now**\nsecond line", font: font, color: .labelColor)
        #expect(label.string == "Run make test now")
        let code = try #require(label.attribute(.font, at: 4, effectiveRange: nil) as? NSFont)
        #expect(code.isFixedPitch && code.pointSize == 11)
        let strong = try #require(label.attribute(.font, at: label.length - 1, effectiveRange: nil) as? NSFont)
        #expect(strong.fontDescriptor.symbolicTraits.contains(.bold))
        let paragraph = try #require(label.attribute(.paragraphStyle, at: 0, effectiveRange: nil) as? NSParagraphStyle)
        #expect(paragraph.lineBreakMode == .byTruncatingTail)
    }

    @Test func blocksOtherThanParagraphsShowTheirLineAsWritten() {
        #expect(TranscriptText.inlineLabel("# Plan [link](x)", font: font, color: .labelColor).string == "Plan link")
        #expect(TranscriptText.inlineLabel("- item", font: font, color: .labelColor).string == "- item")
        #expect(TranscriptText.inlineLabel("", font: font, color: .labelColor).string == "")
    }

    @Test func questionAndNoticeLabelsUseTheirFirstLines() {
        let request = UserInputRequest(id: "r", questions: [UserQuestion(id: "q", prompt: "Which *database*?")])
        #expect(TranscriptQuestionCell.titleSource(request) == "Which *database*?")
        #expect(TranscriptQuestionCell.title(request).string == "Which database?")
        #expect(TranscriptQuestionCell.titleSource(UserInputRequest(id: "r", title: "Setup", questions: [])) == "Setup")
        #expect(TranscriptQuestionCell.titleSource(UserInputRequest(id: "r", title: "  ", questions: [])) == "Question")
        #expect(TranscriptNoticeCell.label(TranscriptItem(kind: .notice, text: "First\nSecond")) == "First")
    }

    @Test func approvalsShowOnlyInputBeyondTheirTitle() {
        #expect(TranscriptApprovalCell.kindLabel(.fileChange) == "File change approval")
        #expect(TranscriptApprovalCell.kindLabel(nil) == "Approval needed")
        #expect(TranscriptApprovalCell.detail(TranscriptItem(kind: .approval, title: "rm -rf build", detail: "rm -rf build")) == nil)
        #expect(TranscriptApprovalCell.detail(TranscriptItem(kind: .approval, title: "Run", detail: " rm -rf build\n")) == "rm -rf build")
    }
}

/// The sidebar keeps one node per project and thread, so the outline view tracks the same objects.
struct SidebarNodeCacheTests {
    @Test func nodesKeepTheirIdentityAcrossRebuilds() {
        var cache = SidebarNodeCache()
        let project = UUID()
        let thread = UUID()
        let first = cache.node(.thread(thread))
        #expect(cache.node(.thread(thread)) === first)
        #expect(cache.node(.project(project)) !== first)
        #expect(first.threadID == thread && first.projectID == nil && first.isSelectable)
        let more = cache.node(.showMore(project))
        #expect(more.projectID == project && more.threadID == nil && !more.isSelectable)
        #expect(cache.header.kind == .header && cache.header.projectID == nil)
    }

    @Test func pruningDropsNodesOfDeletedProjectsAndThreads() {
        var cache = SidebarNodeCache()
        let kept = UUID()
        let gone = UUID()
        let thread = UUID()
        for kind: SidebarNode.Kind in [.project(kept), .empty(kept), .project(gone), .showLess(gone), .thread(thread)] {
            _ = cache.node(kind)
        }
        let header = cache.header
        cache.prune(keeping: [kept], threadIDs: [])
        #expect(cache.existing(.project(kept)) != nil)
        #expect(cache.existing(.empty(kept)) != nil)
        #expect(cache.existing(.project(gone)) == nil)
        #expect(cache.existing(.showLess(gone)) == nil)
        #expect(cache.existing(.thread(thread)) == nil)
        #expect(cache.header === header)
    }
}
