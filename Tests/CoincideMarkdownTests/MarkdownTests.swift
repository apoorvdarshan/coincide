import AppKit
import Foundation
import Testing
@testable import CoincideMarkdown

@Test func markdownPreservesBlockAndInlineStructure() throws {
    let document = MarkdownDocument(parsing: "# Heading\n\nHello **bold and *italic***, ~~old~~ and `a_b`.\nnext\n\n> quote\n\n---")
    #expect(document.blocks.count == 4)
    guard case .heading(level: 1, let heading) = document.blocks[0],
          case .paragraph(let spans) = document.blocks[1], case .quote(let quote) = document.blocks[2],
          case .rule = document.blocks[3] else { Issue.record("Expected heading, paragraph, quote and rule"); return }
    #expect(heading.map(\.text).joined() == "Heading")
    #expect(spans.map(\.text).joined() == "Hello bold and italic, old and a_b.\nnext")
    #expect(spans.first { $0.text == "italic" }?.style == [.strong, .emphasis])
    #expect(spans.first { $0.text == "old" }?.style.contains(.strike) == true)
    #expect(spans.first { $0.text == "a_b" }?.style.contains(.code) == true)
    #expect(quote.count == 1)
}

@Test func markdownHandlesIncompleteStreamedFencesWithoutLosingCode() throws {
    for suffix in ["", "\n```"] {
        let document = MarkdownDocument(parsing: "Before\n\n```swift\nlet emoji = \"🪁\"\nprint(emoji)" + suffix)
        guard case .code(language: "swift", let code, _, let closed) = document.blocks.last else { Issue.record("Missing code block"); continue }
        #expect(code == "let emoji = \"🪁\"\nprint(emoji)\n")
        #expect(closed == !suffix.isEmpty)
    }
    let after = MarkdownDocument(parsing: "```\nx\n```\n\nAfter")
    #expect(after.blocks.count == 2)
}

@Test func markdownSupportsTablesTasksAndNestedLists() throws {
    let document = MarkdownDocument(parsing: "| Name | Count |\n| :--- | ---: |\n| **A** | 2 |\n\n- [x] done\n- [ ] todo\n  - nested\n\n3. third\n4. fourth")
    guard case .table(let headers, let rows, let alignments) = document.blocks[0],
          case .list(start: nil, let items) = document.blocks[1],
          case .list(start: 3, let ordered) = document.blocks[2] else { Issue.record("Missing GFM structures"); return }
    #expect(headers.count == 2 && rows.count == 1)
    #expect(rows[0][0][0].style == .strong)
    #expect(alignments == [.left, .right])
    #expect(items.map(\.checked) == [true, false])
    #expect(items[1].blocks.count == 2 && ordered.count == 2)
}

@Test func markdownKeepsHTMLAndImageAlternativesInert() {
    let source = "<script>alert('x')</script>\n\n![a diagram](https://example.com/image.png) [bad](javascript:alert) <b>raw</b> <span onclick=\"x()\">tap</span>"
    let document = MarkdownDocument(parsing: source)
    guard case .literal(let html) = document.blocks[0], case .paragraph(let spans) = document.blocks[1] else { Issue.record("Missing inert content"); return }
    #expect(html.contains("<script>"))
    #expect(spans.map(\.text).joined().contains("Image: a diagram"))
    #expect(spans.first { $0.text == "raw" }?.style == .strong)
    #expect(spans.map(\.text).joined().contains("tap") && !spans.map(\.text).joined().contains("onclick"))
    let literal = MarkdownDocument(parsing: source, options: .init(rawHTML: false))
    guard case .paragraph(let userSpans) = literal.blocks[1] else { Issue.record("Missing user paragraph"); return }
    #expect(userSpans.map(\.text).joined().contains("<b>raw</b>"))
    #expect(MarkdownLinkTarget.resolve("javascript:alert", workspace: nil) == nil)
    #expect(MarkdownLinkTarget.resolve("data:text/html,test", workspace: nil) == nil)
    #expect(MarkdownLinkTarget.resolve("https://user:secret@example.com", workspace: nil) == nil)
    #expect(MarkdownLinkTarget.resolve("https://example.com/docs", workspace: nil) == .external(URL(string: "https://example.com/docs")!))
}

@Test func markdownFileLinksStayWithinWorkspaceAndRetainLine() throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    let root = directory.appendingPathComponent("workspace"), outside = directory.appendingPathComponent("outside")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    try FileManager.default.createSymbolicLink(at: root.appendingPathComponent("escape"), withDestinationURL: outside)
    let file = root.appendingPathComponent("file with spaces.swift")
    #expect(MarkdownLinkTarget.resolve("file%20with%20spaces.swift#L12-L15", workspace: root) == .file(file, line: 12))
    #expect(MarkdownLinkTarget.resolve("file%20with%20spaces.swift:7:2", workspace: root) == .file(file, line: 7))
    #expect(MarkdownLinkTarget.resolve(file.absoluteString + "#L9", workspace: root) == .file(file, line: 9))
    for target in ["../outside/file", "escape/missing.swift", outside.path + "/file", "file://remote/tmp/file", "#heading", "vscode://file/private"] {
        #expect(MarkdownLinkTarget.resolve(target, workspace: root) == nil)
    }
}

@Test func syntaxHighlightPreservesUnicodeAndStringCommentBoundaries() {
    let source = "let 🪁 = \"// not a comment\" // comment\nprint(🪁)\n"
    let highlighted = CodeHighlight.attributed(source, language: "swift")
    #expect(highlighted.string == source)
    let ns = source as NSString
    let tokens = CodeHighlight.tokens(source, language: "swift")
    func kind(at text: String) -> CodeTokenKind? { tokens.first { $0.range.contains(ns.range(of: text).location) }?.kind }
    #expect(kind(at: "let") == .keyword)
    #expect(kind(at: "not a comment") == .string)
    #expect(kind(at: "// comment") == .comment)
    #expect(kind(at: "print") == .function)
    #expect(String(CodeHighlight.attributedString(source, language: "swift", dark: true).characters) == source)
    #expect(CodeHighlight.attributed(source, language: "unknown").string == source)
    let large = String(repeating: "x", count: 70_000)
    #expect(CodeHighlight.attributed(large, language: "swift").string == large)
    #expect(CodeHighlight.tokens(large, language: "swift").isEmpty)
}

@Test func markdownLargeInputHasLosslessFallbackAndCacheDoesNotMixStreams() async {
    let source = String(repeating: "字", count: 350_000)
    #expect(MarkdownDocument(parsing: source).blocks == [.literal(source)])
    let parser = MarkdownParser()
    let a = await parser.parse("# A"), b = await parser.parse("# B"), again = await parser.parse("# A")
    #expect(a != b && a == again)
}

@Test func sourceLineNavigationUsesUTF16AndClampsAtEOF() {
    let source = "🪁 first\r\n第二行\nlast"
    let ns = source as NSString
    #expect(ns.substring(with: SourceTextLocation.range(in: source, line: 2)) == "第二行\n")
    #expect(ns.substring(with: SourceTextLocation.range(in: source, line: 3)) == "last")
    #expect(SourceTextLocation.range(in: source, line: 500) == NSRange(location: ns.length, length: 0))
    #expect(SourceTextLocation.range(in: "", line: 2) == NSRange(location: 0, length: 0))
    #expect(ns.substring(with: SourceTextLocation.range(in: source, line: -1)) == "🪁 first\r\n")
}
