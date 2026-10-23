import Foundation
import Testing
@testable import CoincideMarkdown

private func containedHTMLSpans(_ blocks: [MarkdownBlock]) -> [MarkdownSpan] {
    blocks.flatMap { block in
        switch block {
        case .paragraph(let spans), .heading(_, let spans): return spans
        case .quote(let children), .alert(_, let children), .details(_, _, let children): return containedHTMLSpans(children)
        case .list(_, let items): return items.flatMap { containedHTMLSpans($0.blocks) }
        case .table(let headers, let rows, _): return headers.flatMap { $0 } + rows.flatMap { $0.flatMap { $0 } }
        case .footnotes(let notes): return notes.flatMap { containedHTMLSpans($0.blocks) }
        default: return []
        }
    }
}

@Test(.timeLimit(.minutes(1)), arguments: ["deep", "wide", "unfinished"])
func markdownHTMLConstructionRefusesTheWholeOverBudgetBlockAndRetainsFollowingContent(kind: String) {
    let raw: String
    switch kind {
    case "deep": raw = String(repeating: "<div>", count: 4_096) + "Exact Unicode e\u{301} 😀" + String(repeating: "</div>", count: 4_096) + "\n"
    case "wide": raw = "<div>" + String(repeating: "<span>retained</span>", count: 9_000) + "</div>\n"
    default: raw = "<div>" + String(repeating: "<span>streaming</span>", count: 9_000) + "<span data-open='unfinished\n"
    }
    #expect(MarkdownHTML.blocks(raw) == nil)
    let document = MarkdownDocument(parsing: raw + "\nAfter the bounded HTML block.\n")
    guard case .some(.literal(let literal)) = document.blocks.first else { Issue.record("An over-budget HTML block was partially interpreted."); return }
    #expect(literal.utf8.elementsEqual(raw.utf8))
    #expect(document.blocks.last == .paragraph([.init(text: "After the bounded HTML block.")]))
}

@Test(.timeLimit(.minutes(1)))
func markdownHTMLImpliedClosingTagsDoNotConsumeTheNestingBudgetOrDropSiblingRows() {
    let labels = (0..<1_000).map { "row-\($0)-😀" }
    let raw = "<ul>" + labels.map { "<li>" + $0 }.joined() + "</ul>\n"
    let document = MarkdownDocument(parsing: raw)
    guard case .some(.list(start: nil, let rows)) = document.blocks.first else { Issue.record("Implied closing tags became excessive nesting."); return }
    #expect(rows.count == labels.count)
    #expect(rows.map { containedHTMLSpans($0.blocks).map(\.text).joined() } == labels)
    #expect(!document.blocks.contains { if case .literal = $0 { true } else { false } })
}

@Test
func markdownHTMLAssetsRemainAlternativesAndActivationStillRequiresContainedSafeLinks() throws {
    let scratch = FileManager.default.temporaryDirectory.appendingPathComponent("coincide-markdown-assets-" + UUID().uuidString)
    let workspace = scratch.appendingPathComponent("Workspace"), outside = scratch.appendingPathComponent("Outside")
    try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
    try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
    defer { try? FileManager.default.removeItem(at: scratch) }
    let file = outside.appendingPathComponent("image.svg"), privateContents = "ASSET CONTENT MUST NEVER ENTER THE TRANSCRIPT"
    try privateContents.write(to: file, atomically: false, encoding: .utf8)
    try FileManager.default.createSymbolicLink(at: workspace.appendingPathComponent("escape"), withDestinationURL: outside)
    let source = "<p><img src='\(file.absoluteString)' alt='Local image' onerror='neverExecute()'> <img src='https://example.invalid/image.svg' alt='Remote image'> <a href='javascript:neverExecute()'>bad link</a> <a href='escape/image.svg'>outside link</a> <a href='safe.swift#L7'>source</a></p>\n"
    let document = MarkdownDocument(parsing: source), spans = containedHTMLSpans(document.blocks)
    let text = spans.map(\.text).joined()
    #expect(text.contains("Image: Local image") && text.contains("Image: Remote image"))
    #expect(!text.contains(privateContents) && !text.contains("onerror") && !text.contains("neverExecute"))
    for span in spans where ["Image: Local image", "bad link", "outside link"].contains(span.text) {
        let destination = try #require(span.destination)
        #expect(MarkdownLinkTarget.resolve(destination, workspace: workspace) == nil)
    }
    let sourceLink = try #require(spans.first { $0.text == "source" }?.destination)
    #expect(MarkdownLinkTarget.resolve(sourceLink, workspace: workspace) == .file(workspace.appendingPathComponent("safe.swift"), line: 7))
    #expect(try String(contentsOf: file, encoding: .utf8) == privateContents)
}

@Test
func markdownPrivateUseTextCoexistsWithMathFootnotesAndFileCitationsWithoutSentinelSubstitution() throws {
    let authored = "\u{e000}\u{e001}\u{e002}e\u{301}🪁"
    let source = "$x$ " + authored + " claim[^n] :codex-file-citation{path=src/main.swift line_range_start=9}\n\n[^n]: Exact note " + authored
    let document = MarkdownDocument(parsing: source), spans = containedHTMLSpans(document.blocks)
    #expect(spans.compactMap(\.formula).map(\.latex) == ["x"])
    let note = try #require(document.footnotes.first)
    #expect(document.footnotes.count == 1 && note.label == "n")
    #expect(spans.filter { $0.formula == nil }.map(\.text).joined().contains(authored))
    #expect(containedHTMLSpans(note.blocks).map(\.text).joined().utf8.elementsEqual(("Exact note " + authored).utf8))
    #expect(spans.contains { $0.text == "main.swift" && $0.destination == "src/main.swift#L9" })
}
