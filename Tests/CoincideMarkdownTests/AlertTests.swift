import AppKit
import SwiftUI
import Testing
@testable import CoincideMarkdown

@Test(arguments: ["NOTE", "tIp", "IMPORTANT", "warning", "CaUtIoN"])
func markdownGithubAlertsRecognizeAllPinnedKindsAndKeepTheNextStyledLine(marker: String) {
    let source = "> [!\(marker)]\n> **Keep this bold** and exact Unicode e\u{301} 🪁."
    let document = MarkdownDocument(parsing: source)
    guard document.blocks.count == 1, case .alert(let kind, let blocks) = document.blocks[0],
          blocks.count == 1, case .paragraph(let spans) = blocks[0] else { Issue.record("Expected one complete native alert"); return }
    #expect(kind.rawValue == marker.lowercased())
    #expect(spans.map(\.text).joined().utf8.elementsEqual("Keep this bold and exact Unicode e\u{301} 🪁.".utf8))
    #expect(spans.contains { $0.text == "Keep this bold" && $0.style.contains(.strong) })
}

@Test func markdownGithubAlertMarkerOnlyParagraphKeepsFollowingHeadingParagraphAndTaskList() {
    let document = MarkdownDocument(parsing: "> [!WARNING]\n>\n> ### Review changes\n>\n> A [source](https://example.com) and **bold** text.\n>\n> - [x] Preserve the body")
    guard case .some(.alert(let kind, let blocks)) = document.blocks.first,
          blocks.count == 3, case .heading(let level, let heading) = blocks[0],
          case .paragraph(let spans) = blocks[1], case .list(let start, let items) = blocks[2] else { Issue.record("Alert content was dropped or flattened"); return }
    #expect(kind == .warning && level == 3 && heading.map(\.text).joined() == "Review changes")
    #expect(spans.contains { $0.text == "source" && $0.destination == "https://example.com" })
    #expect(spans.contains { $0.text == "bold" && $0.style.contains(.strong) })
    #expect(start == nil && items.count == 1 && items[0].checked == true)
    #expect(items[0].blocks == [.paragraph([.init(text: "Preserve the body")])])
}

@Test func markdownNestedTasksKeepStyledBodiesAndNeverPromoteEscapedCodeOrEntityMarkers() {
    let source = "> [!TIP]\n>\n> - [x] **Checked** and [source](https://example.com).\n> - [ ] Unchecked\n> - [X] Uppercase\n> - \\[x] Escaped\n> - `[x]` Code\n> - &#91;x] Entity"
    let document = MarkdownDocument(parsing: source)
    guard case .some(.alert(_, let blocks)) = document.blocks.first,
          blocks.count == 1, case .list(start: nil, let items) = blocks[0], items.count == 6 else {
        Issue.record("Nested tasks lost their alert or list ownership"); return
    }
    #expect(items.map(\.checked) == [true, false, true, nil, nil, nil])
    guard case .some(.paragraph(let styled)) = items[0].blocks.first else { Issue.record("Task body was dropped"); return }
    #expect(styled.map(\.text).joined() == "Checked and source.")
    #expect(styled.contains { $0.text == "Checked" && $0.style.contains(.strong) })
    #expect(styled.contains { $0.text == "source" && $0.destination == "https://example.com" })
    for index in 3...5 {
        guard case .some(.paragraph(let spans)) = items[index].blocks.first else { Issue.record("Literal marker was dropped"); continue }
        #expect(spans.map(\.text).joined().hasPrefix("[x]"))
        if index == 4 { #expect(spans.contains { $0.text == "[x]" && $0.style.contains(.code) }) }
    }
    let ordered = MarkdownDocument(parsing: "> 3. [ ] **Review**\n> 4. [x] Complete")
    guard case .some(.quote(let quoted)) = ordered.blocks.first, case .some(.list(start: 3, let orderedItems)) = quoted.first else {
        Issue.record("Quoted ordered task ownership changed"); return
    }
    #expect(orderedItems.map(\.checked) == [false, true])
}

@Test(arguments: [
    "> [!NOTE] an ordinary quote", "> [!NOTE]*aside*", "> prefix [!NOTE]\n> Body",
    "> [!UNKNOWN]\n> Body", "> **[!NOTE]**\n> Body", "> `[!NOTE]`\n> Body",
    "> [!NOTE]  \n> Body", "> [!NOTE]\\\n> Body"
])
func markdownGithubAlertsRequireTheFirstPlainTextMarkerToOwnItsLine(source: String) {
    let document = MarkdownDocument(parsing: source)
    guard case .some(.quote(let blocks)) = document.blocks.first else { Issue.record("An ordinary quote became an alert"); return }
    #expect(!blocks.isEmpty)
}

@Test func markdownGithubAlertsRemainNestedInOrdinaryQuotesAndLists() {
    let source = "> An ordinary outer quote.\n>\n> > [!TIP]\n> > A nested tip.\n\n- List entry\n\n  > [!CAUTION]\n  > A nested caution."
    let document = MarkdownDocument(parsing: source)
    guard document.blocks.count == 2, case .quote(let outer) = document.blocks[0], outer.count == 2,
          case .alert(let tip, let tipBody) = outer[1], case .list(_, let items) = document.blocks[1],
          items.count == 1, items[0].blocks.count == 2, case .alert(let caution, let cautionBody) = items[0].blocks[1] else {
        Issue.record("Nested alert ownership changed"); return
    }
    #expect(tip == .tip && caution == .caution && tipBody.count == 1 && cautionBody.count == 1)
}

@Test func markdownGithubAlertsKeepStreamingPrefixesCodeAndHTMLInertAndUseDecodedMarkdownText() {
    let partial = MarkdownDocument(parsing: "> [!NOT")
    #expect(partial.blocks == [.quote([.paragraph([.init(text: "[!NOT")])])])
    #expect(MarkdownDocument(parsing: "> [!NOTE]").blocks == [.alert(kind: .note, blocks: [])])
    #expect(MarkdownDocument(parsing: "> [!NOTE]\r\n> Body").blocks == [.alert(kind: .note, blocks: [.paragraph([.init(text: "Body")])])])
    // The pinned remark plugin inspects decoded text, not raw source spelling.
    #expect(MarkdownDocument(parsing: "> \\[!NOTE]\n> Body").blocks == [.alert(kind: .note, blocks: [.paragraph([.init(text: "Body")])])])
    let protected = MarkdownDocument(parsing: "```text\n> [!NOTE]\n> Code only\n```\n\n<blockquote>\n[!WARNING]\nHTML only\n</blockquote>")
    guard protected.blocks.count == 2, case .code(_, let code, _, _) = protected.blocks[0], case .quote(let htmlBody) = protected.blocks[1],
          case .some(.paragraph(let htmlSpans)) = htmlBody.first else {
        Issue.record("Code or HTML was interpreted as an alert"); return
    }
    #expect(code.contains("[!NOTE]"))
    #expect(htmlSpans.map(\.text).joined() == "[!WARNING] HTML only")
    #expect(!htmlBody.contains { if case .alert = $0 { true } else { false } })
}

@MainActor @Test(arguments: [240.0, 700.0])
func nativeMarkdownGithubAlertsRenderAllKindsInBothAppearancesWithoutAWindow(width: Double) throws {
    let source = MarkdownAlertKind.allCases.map { "> [!\($0.rawValue.uppercased())]\n> **Readable content** with Unicode 世界 and an ordinary link [source](https://example.com)." }.joined(separator: "\n\n")
    let document = MarkdownDocument(parsing: source)
    #expect(document.blocks.count == 5)
    for scheme in [ColorScheme.light, .dark] {
        let view = MarkdownBlocksView(blocks: document.blocks, workspace: nil, openFile: { _, _ in })
            .font(.system(size: 15)).padding(16).frame(width: width)
            .background(Color(nsColor: .textBackgroundColor)).environment(\.colorScheme, scheme)
        let renderer = ImageRenderer(content: view); renderer.scale = 1
        let image = try #require(renderer.cgImage)
        #expect(image.width == Int(width) && image.height > 150 && image.height < 4_000)
    }
}
