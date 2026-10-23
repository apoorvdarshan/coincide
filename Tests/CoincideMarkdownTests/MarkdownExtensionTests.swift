import Foundation
import Testing
@testable import CoincideMarkdown

private func paragraph(_ source: String, options: MarkdownParseOptions = .init()) -> [MarkdownSpan] {
    guard case .paragraph(let spans)? = MarkdownDocument(parsing: source, options: options).blocks.first else { return [] }
    return spans
}
private func links(_ spans: [MarkdownSpan]) -> [String: String] {
    Dictionary(spans.compactMap { span in span.destination.map { (span.text, $0) } }, uniquingKeysWith: { first, _ in first })
}

// MARK: GFM literals

@Test func markdownKeepsLiteralPunctuationWithoutSmartQuotes() {
    let text = paragraph(#"Run `git push` with --force -- "quoted" and 'single' --- done..."#).map(\.text).joined()
    #expect(text == #"Run git push with --force -- "quoted" and 'single' --- done..."#)
}

@Test func gfmAutolinkLiteralsFollowTrailingPunctuationAndParenthesisRules() {
    let spans = paragraph("See https://example.com/a_(b). Or www.example.com/docs, mail me@example.org! (https://x.dev/p) 🪁 http://localhost:8080/x?y=1.")
    let found = links(spans)
    #expect(found["https://example.com/a_(b)"] == "https://example.com/a_(b)")
    #expect(found["www.example.com/docs"] == "https://www.example.com/docs")
    #expect(found["me@example.org"] == "mailto:me@example.org")
    #expect(found["https://x.dev/p"] == "https://x.dev/p")
    #expect(found["http://localhost:8080/x?y=1"] == "http://localhost:8080/x?y=1")
    #expect(spans.map(\.text).joined() == "See https://example.com/a_(b). Or www.example.com/docs, mail me@example.org! (https://x.dev/p) 🪁 http://localhost:8080/x?y=1.")
    for destination in found.values { #expect(MarkdownLinkTarget.resolve(destination, workspace: nil) != nil) }
}

@Test func autolinksSkipCodeExistingLinksAndUnsafeTargets() {
    let spans = paragraph("`https://code.example` [label](https://real.example) javascript:alert(1) https://user:pass@example.com wwwexample.com a.b@c")
    #expect(spans.first { $0.text == "https://code.example" }?.destination == nil)
    #expect(spans.first { $0.text == "label" }?.destination == "https://real.example")
    #expect(!spans.contains { $0.destination?.hasPrefix("javascript") == true })
    #expect(!spans.contains { $0.text.hasPrefix("wwwexample") && $0.destination != nil })
    let credential = spans.first { $0.destination?.contains("user:pass") == true }?.destination
    #expect(credential.map { MarkdownLinkTarget.resolve($0, workspace: nil) } == .some(nil))
    let fenced = MarkdownDocument(parsing: "```\nhttps://fenced.example\n```")
    #expect(fenced.blocks == [.code(language: "", text: "https://fenced.example\n", meta: "", closed: true)])
}

// MARK: Footnotes

@Test func footnotesNumberByFirstReferenceAndCollectMultiParagraphDefinitions() throws {
    let source = """
    First claim[^b] and second[^a], again[^b]. Unknown[^missing] stays.

    [^a]: Alpha note.
    [^b]: Beta note with `code`.

        Second paragraph of beta.

    ```text
    [^a]: not a definition
    ```
    """
    let document = MarkdownDocument(parsing: source)
    guard case .paragraph(let spans) = document.blocks[0] else { Issue.record("Missing paragraph"); return }
    let references = spans.filter { $0.style.contains(.footnoteReference) }
    #expect(references.map(\.text) == ["1", "2", "1"])
    #expect(references.map(\.source) == ["[^b]", "[^a]", "[^b]"])
    #expect(spans.map(\.text).joined().contains("Unknown[^missing] stays."))
    let notes = document.footnotes
    #expect(notes.map(\.number) == [1, 2] && notes.map(\.label) == ["b", "a"])
    #expect(notes[0].blocks.count == 2)
    guard case .code(_, let fenced, _, _) = try #require(document.blocks.dropLast().last) else { Issue.record("Fence was consumed"); return }
    #expect(fenced == "[^a]: not a definition\n")
}

@Test func footnoteDefinitionsWithoutReferencesAreOmittedAndInlineCodeStaysLiteral() {
    let document = MarkdownDocument(parsing: "Use `[^x]` here.\n\n[^x]: Never referenced.")
    #expect(document.footnotes.isEmpty)
    guard case .paragraph(let spans)? = document.blocks.first else { Issue.record("Missing paragraph"); return }
    #expect(spans.first { $0.style.contains(.code) }?.text == "[^x]")
}

// MARK: GitHub alerts

@Test func githubAlertsFollowT3MarkerRules() {
    let alone = MarkdownDocument(parsing: "> [!NOTE]\n> Useful information.")
    #expect(alone.blocks == [.alert(.note, [.paragraph([.init(text: "Useful information.")])])])
    let separate = MarkdownDocument(parsing: "> [!warning]\n>\n> **Careful** now.")
    guard case .alert(.warning, let blocks)? = separate.blocks.first else { Issue.record("Lowercase marker"); return }
    #expect(blocks.count == 1)
    let nextLineInline = MarkdownDocument(parsing: "> [!TIP]\n> *Optional* tweak")
    guard case .alert(.tip, let tip)? = nextLineInline.blocks.first, case .paragraph(let spans)? = tip.first else { Issue.record("Inline next line"); return }
    #expect(spans.first?.style == .emphasis)
    for plain in ["> [!NOTE] Same line", "> [!NOTE]*aside*", "> [!UNKNOWN]\n> text", "> text\n> [!NOTE]"] {
        guard case .quote? = MarkdownDocument(parsing: plain).blocks.first else { Issue.record("Expected a plain quote for \(plain)"); continue }
    }
    let nested = MarkdownDocument(parsing: "> Outer\n>\n> > [!CAUTION]\n> > Inner")
    guard case .quote(let outer)? = nested.blocks.first, case .alert(.caution, _)? = outer.last else { Issue.record("Nested alert"); return }
}

// MARK: Safe HTML

@Test func detailsPairAcrossMarkdownChildrenAndNest() {
    let source = """
    <details open>
    <summary>Build <b>log</b></summary>

    Output with **bold** and `code`.

    <details>
    <summary>Inner</summary>

    Deep

    </details>

    </details>

    After
    """
    let document = MarkdownDocument(parsing: source)
    guard case .details(let summary, let open, let content)? = document.blocks.first else { Issue.record("Missing details"); return }
    #expect(open && summary.map(\.text).joined() == "Build log" && summary.last?.style == .strong)
    #expect(content.count == 2)
    guard case .details(let inner, false, let deep)? = content.last else { Issue.record("Missing nested details"); return }
    #expect(inner.map(\.text).joined() == "Inner" && deep == [.paragraph([.init(text: "Deep")])])
    #expect(document.blocks.last == .paragraph([.init(text: "After")]))
}

@Test func detailsInOneBlockUnclosedDetailsAndUserTextStayInert() {
    let single = MarkdownDocument(parsing: "<details><summary>Logs</summary>\nline one\nline two\n</details>")
    guard case .details(let summary, false, let body)? = single.blocks.first else { Issue.record("Single-block details"); return }
    #expect(summary.map(\.text).joined() == "Logs")
    #expect(body == [.paragraph([.init(text: "line one"), .init(text: "\n"), .init(text: "line two")])])
    let unclosed = MarkdownDocument(parsing: "<details>\n<summary>Streaming</summary>\n\nPartial text")
    #expect(!unclosed.blocks.contains { if case .details = $0 { true } else { false } })
    #expect(unclosed.blocks.contains { if case .literal(let raw) = $0 { raw.contains("<summary>Streaming</summary>") } else { false } })
    #expect(unclosed.blocks.contains { if case .paragraph(let spans) = $0 { spans.map(\.text).joined() == "Partial text" } else { false } })
    let user = MarkdownDocument(parsing: "<details><summary>Logs</summary>\nx\n</details>", options: .init(rawHTML: false))
    guard case .literal(let raw)? = user.blocks.first else { Issue.record("User HTML must stay literal"); return }
    #expect(raw.contains("<summary>"))
}

@Test func safeHTMLSubsetMapsInlineTagsAndKeepsEverythingElseLiteral() {
    let spans = paragraph(#"Press <kbd>⌘</kbd>+<kbd>K</kbd>, H<sub>2</sub>O, x<sup>2</sup>, <a href="https://example.com">site</a>, <a href="javascript:alert(1)">bad</a>, <img src="x.png" alt="Logo"><br>next <!-- hidden --> <iframe src="x"></iframe>"#)
    #expect(spans.first { $0.text == "⌘" }?.style == .keyboard)
    #expect(spans.first { $0.text == "2" && $0.style == .subscript } != nil)
    #expect(spans.first { $0.text == "2" && $0.style == .superscript } != nil)
    #expect(spans.first { $0.text == "site" }?.destination == "https://example.com")
    let bad = spans.first { $0.text == "bad" }?.destination
    #expect(bad.map { MarkdownLinkTarget.resolve($0, workspace: nil) } == .some(nil))
    #expect(spans.contains { $0.text == "Image: Logo" && $0.destination == "x.png" })
    let joined = spans.map(\.text).joined()
    #expect(joined.contains("\nnext") && !joined.contains("hidden") && joined.contains("<iframe src=\"x\">"))
    let block = MarkdownDocument(parsing: "<p align=\"center\">\n  <img src=\"logo.png\" alt=\"Coincide\">\n</p>\n\n<!-- note -->\n\n<div onclick=\"x()\"><script>alert(1)</script></div>")
    #expect(block.blocks.first == .paragraph([.init(text: "Image: Coincide", destination: "logo.png")]))
    guard case .literal(let script)? = block.blocks.last else { Issue.record("Script must stay literal"); return }
    #expect(script.contains("<script>") && block.blocks.count == 2)
}
