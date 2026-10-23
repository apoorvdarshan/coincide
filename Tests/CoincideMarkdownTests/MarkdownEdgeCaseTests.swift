import AppKit
import Foundation
import SwiftUI
import Testing
@testable import CoincideMarkdown

private func blocks(_ source: String) -> [MarkdownBlock] { MarkdownDocument(parsing: source).blocks }
private func paragraph(_ source: String) -> [MarkdownSpan] {
    guard case .paragraph(let spans)? = blocks(source).first else { return [] }
    return spans
}
private func formulas(_ spans: [MarkdownSpan]) -> [String] { spans.filter { !$0.style.isDisjoint(with: .math) }.map(\.text) }
private func privateUse(_ blocks: [MarkdownBlock]) -> Bool { "\(blocks)".unicodeScalars.contains { (0xE000...0xE002).contains($0.value) } }

// MARK: Sentinels

@Test func adjacentFootnotesFormulasAndCodeSpansStaySeparate() {
    let notes = "\n\n[^1]: One.\n[^2]: Two."
    let claim = paragraph("Claim[^1][^2]." + notes)
    #expect(claim.filter { $0.style.contains(.footnoteReference) }.map(\.text) == ["1", "2"])
    #expect(!claim.contains { $0.style.contains(.code) })
    for (source, expected) in [(#"\(a\)\(b\)"#, ["a", "b"]), (#"\(a\)$b$"#, ["a", "b"]), ("See[^1]$x$" + notes, ["x"]), ("Value $x$[^1]" + notes, ["x"]),
                               ("`code`$x$ and $y$`more`", ["x", "y"]), ("A ` stray tick then $x$", ["x"])] {
        let spans = paragraph(source)
        #expect(formulas(spans) == expected, "\(source)")
        #expect(!privateUse(blocks(source)), "\(source)")
    }
    let mixed = paragraph("`code`$x$ and $y$`more`")
    #expect(mixed.filter { $0.style.contains(.code) }.map(\.text) == ["code", "more"])
    #expect(paragraph("A ` stray tick then $x$").map(\.text).joined() == "A ` stray tick then x")
    #expect(paragraph("See[^1]$x$" + notes).filter { $0.style.contains(.footnoteReference) }.count == 1)
    #expect(CodexDirectives.renderForCopy("a ` b :codex-followup[Next]{prompt=go}") == "a ` b Next")
}

@Test func imageAltTextKeepsFormulaAndFootnoteSource() {
    let spans = paragraph("![alt $x$ here](img.png)")
    #expect(spans.first?.text == "Image: alt $x$ here" && spans.first?.destination == "img.png")
}

@Test func footnoteReferencesInsideDefinitionsShareNumbering() {
    let document = MarkdownDocument(parsing: "A[^a].\n\n[^a]: See [^b] and $x$.\n[^b]: Deep note.\n[^c]: Unused.")
    #expect(document.footnotes.map(\.label) == ["a", "b"])
    guard case .paragraph(let note)? = document.footnotes.first?.blocks.first else { Issue.record("Missing first note"); return }
    #expect(note.filter { $0.style.contains(.footnoteReference) }.map(\.text) == ["2"])
    #expect(formulas(note) == ["x"])
}

// MARK: Details

@Test func consecutiveDetailsInOneHTMLBlockEachBecomeDisclosures() {
    let stacked = blocks("<details>\n<summary>A</summary>\n\nContent A\n\n</details>\n<details>\n<summary>B</summary>\n\nContent B\n\n</details>\n\nAfter")
    #expect(stacked == [.details(summary: [.init(text: "A")], open: false, [.paragraph([.init(text: "Content A")])]),
                        .details(summary: [.init(text: "B")], open: false, [.paragraph([.init(text: "Content B")])]),
                        .paragraph([.init(text: "After")])])
    let sameLine = blocks("<details><summary>A</summary>x</details>\n<details><summary>B</summary>y</details>")
    #expect(sameLine == [.details(summary: [.init(text: "A")], open: false, [.paragraph([.init(text: "x")])]),
                         .details(summary: [.init(text: "B")], open: false, [.paragraph([.init(text: "y")])])])
    let introduced = blocks("<p>Intro</p>\n<details>\n<summary>Log</summary>\n\nBody\n\n</details>")
    #expect(introduced == [.paragraph([.init(text: "Intro")]), .details(summary: [.init(text: "Log")], open: false, [.paragraph([.init(text: "Body")])])])
}

@Test func displayMathStaysInsideDetailsListsAndQuotes() {
    let proof = blocks("<details>\n<summary>Proof</summary>\n\n$$\nx^2\n$$\n\nDone.\n\n</details>\n\nAfter")
    #expect(proof == [.details(summary: [.init(text: "Proof")], open: false, [.math("x^2"), .paragraph([.init(text: "Done.")])]), .paragraph([.init(text: "After")])])
    #expect(blocks("> $$\n> x\n> $$") == [.quote([.math("x")])])
    #expect(blocks("> [!NOTE]\n> $$\n> x^2\n> $$") == [.alert(.note, [.math("x^2")])])
    guard case .list(_, let items)? = blocks("- a\n  $$\n  x\n  $$\n  after\n- b").first else { Issue.record("Missing list"); return }
    #expect(items.count == 2 && items[0].blocks == [.paragraph([.init(text: "a")]), .math("x"), .paragraph([.init(text: "after")])])
    guard case .list(_, let nested)? = blocks("- a\n    - b\n\n      $$\n      y\n      $$").first, case .list(_, let inner)? = nested.first?.blocks.last else { Issue.record("Missing nested list"); return }
    #expect(inner.first?.blocks.last == .math("y"))
    #expect(blocks("- $$\n  z\n  $$") == [.list(start: nil, items: [.init(checked: nil, blocks: [.math("z")])])])
}

// MARK: Math parity with T3's patched llm-math

@Test func mathFormsMatchT3Delimiters() {
    #expect(formulas(paragraph(#"Inline $x^2$ and \(y_1\), display $$a+b$$ and \[c\]."#)) == ["x^2", "y_1", "a+b", "c"])
    #expect(blocks("$$ x^2 + 1 $$") == [.math("x^2 + 1")])
    #expect(formulas(paragraph("Text $$ x $$ more")) == ["x"])
    #expect(blocks("$$x^2\n+y^2$$") == [.math("x^2\n+y^2")])
    #expect(formulas(paragraph("Energy \\(x\n+y\\) here")) == ["x\n+y"])
    guard case .quote(let quoted)? = blocks("> Energy \\(x\n> +y\\) here").first, case .paragraph(let spans)? = quoted.first else { Issue.record("Quoted formula"); return }
    #expect(formulas(spans) == ["x\n+y"])
    #expect(formulas(paragraph("the $n$th term")) == ["n"])
    #expect(blocks("Where\n\\[\na\n=\nb\n\\]\nholds.") == [.paragraph([.init(text: "Where")]), .math("a\n=\nb"), .paragraph([.init(text: "holds.")])])
    #expect(blocks("$$a$$ is first.\nSome prose.\n$$\nb\n$$").last == .math("b"))
    #expect(formulas(paragraph("$$a$$ is first.\nSome prose.")) == ["a"])
    #expect(formulas(paragraph(#"Pay \$$x$ now."#)) == ["x"])
    #expect(formulas(paragraph(#"Cost $a\$b$ and \(\left(x\right)\)."#)) == [#"a\$b"#, #"\left(x\right)"#])
    // One backslash escapes the closing fence; two do not.
    #expect(blocks("$$a+\\$$\nb\n$$") == [.math("a+\\$$\nb")])
    #expect(blocks("$$a+\\\\$$\nb\n$$").first == .math("a+\\\\"))
}

@Test func mathKeepsPricesCitationsURLsAndUnfinishedFormulasAsText() {
    for prose in ["It costs $5 and $10.", "Budget $5-$10 per seat, or $20,000-$30,000 a year.", "Plans are $5/$10 monthly.", "Run $browser then $deploy on it.",
                  "Set $HOME before running.", "Shell $PATH:$HOME and $HOME/$USER stay.", "Energy \\(E = mc"] {
        #expect(formulas(paragraph(prose)).isEmpty, "\(prose)")
    }
    #expect(formulas(paragraph("Price $5-$10 stays literal. The formula is $x_i$ and $5$.")) == ["x_i", "5"])
    let citations = paragraph(#"As shown in \[1\] and \[2, 3\]."#)
    #expect(formulas(citations).isEmpty && citations.map(\.text).joined() == "As shown in [1] and [2, 3].")
    let link = paragraph("Set $TOKEN, then open [users](https://graph.microsoft.com/v1.0/users?$select=id).")
    #expect(formulas(link).isEmpty && link.first { $0.text == "users" }?.destination == "https://graph.microsoft.com/v1.0/users?$select=id")
    #expect(formulas(paragraph("Query www.example.com/?$select=id and $x$.")) == ["x"])
    #expect(!blocks("$$\nx^2").contains { if case .math = $0 { true } else { false } })
    #expect(!blocks("\\[\nx^2\n- y").contains { if case .math = $0 { true } else { false } })
    #expect(blocks("$$E=mc^2") == [.paragraph([.init(text: "$$E=mc^2")])])
    let table = blocks("| Name | Value |\n| --- | --- |\n| first | \\(x |\n| second | y\\) |\n| valid | $|z|$ |")
    guard case .table(_, let rows, _)? = table.first else { Issue.record("Missing table"); return }
    #expect(rows.map(\.count) == [2, 2, 2] && formulas(rows[2][1]) == ["|z|"] && formulas(rows.flatMap { $0 }.flatMap { $0 }) == ["|z|"])
}

@Test func repeatedUnclosedOpenersStayLinear() {
    let started = Date()
    _ = MarkdownDocument(parsing: String(repeating: "\\( ", count: 20_000))
    _ = MarkdownDocument(parsing: String(repeating: "](a(", count: 20_000) + " $x$")
    _ = MarkdownDocument(parsing: String(repeating: "` $", count: 20_000))
    _ = MarkdownDocument(parsing: String(repeating: "\\[\n", count: 5_000) + String(repeating: "> $$\n", count: 5_000))
    #expect(Date().timeIntervalSince(started) < 20)
}

// MARK: Fences in list items

@Test func fencesOpeningOnAListMarkerLineTrackTheirClosingMarker() {
    #expect(blocks("1. ```math\n   x^2") == [.list(start: 1, items: [.init(checked: nil, blocks: [.code(language: "math", text: "x^2\n", meta: "", closed: false)])])])
    #expect(blocks("1. ```math\n   x^2\n   ```") == [.list(start: 1, items: [.init(checked: nil, blocks: [.math("x^2\n")])])])
    guard case .list(_, let open)? = blocks("- ```mermaid\n  graph TD\n  A-->B").first, case .code(_, _, _, let streaming)? = open.first?.blocks.first else { Issue.record("Open fence"); return }
    #expect(!streaming)
    guard case .list(_, let done)? = blocks("- ```mermaid\n  graph TD\n  A-->B\n  ```").first, case .code(_, _, _, let closed)? = done.first?.blocks.first else { Issue.record("Closed fence"); return }
    #expect(closed)
    #expect(blocks("    ```\n    not a fence") == [.code(language: "", text: "```\nnot a fence\n", meta: "", closed: true)])
}

// MARK: HTML structure

@Test func htmlListsTablesAndDefinitionListsBecomeNativeBlocks() {
    #expect(blocks("<ul><li>one</li><li><b>two</b></li></ul>") == [.list(start: nil, items: [.init(checked: nil, blocks: [.paragraph([.init(text: "one")])]),
                                                                                           .init(checked: nil, blocks: [.paragraph([.init(text: "two", style: .strong)])])])])
    guard case .list(let start, let items)? = blocks("<ol start=\"3\"><li>a<li>b</ol>").first else { Issue.record("Ordered list"); return }
    #expect(start == 3 && items.count == 2)
    let table = blocks("<table><thead><tr><th>A</th><th align=\"right\">B</th></tr></thead><tbody><tr><td>x</td><td><i>y</i></td></tr><tr><td>z<td>w</tr></tbody></table>")
    #expect(table == [.table(headers: [[.init(text: "A")], [.init(text: "B")]], rows: [[[.init(text: "x")], [.init(text: "y", style: .emphasis)]], [[.init(text: "z")], [.init(text: "w")]]],
                             alignments: [.left, .right])])
    #expect(blocks("<dl><dt>Term</dt><dd>Meaning</dd></dl>") == [.paragraph([.init(text: "Term", style: .strong)]), .paragraph([.init(text: "Meaning")])])
    #expect(blocks("<ul><li><details><summary>More</summary>Hidden</details></li></ul>")
            == [.list(start: nil, items: [.init(checked: nil, blocks: [.details(summary: [.init(text: "More")], open: false, [.paragraph([.init(text: "Hidden")])])])])])
    guard case .literal? = blocks("<table><tr><td><script>x()</script></td></tr></table>").first else { Issue.record("Script must keep the block literal"); return }
}

// MARK: Highlighting

@Test func highlightedTextColorsTokenRangesWithoutRebuildingTheString() {
    let source = "let 👩‍👩‍👧 = \"🪁\" // note\nfunc f() {}\n"
    let text = CodeHighlight.attributedString(source, language: "swift", dark: false)
    #expect(String(text.characters) == source)
    let keyword = Color(nsColor: CodeTheme.color(.keyword, dark: false))
    let colored = text.runs.compactMap { run -> String? in run.foregroundColor == keyword ? String(text[run.range].characters) : nil }
    #expect(colored == ["let", "func"])
    #expect(text.runs.contains { String(text[$0.range].characters) == "// note" && $0.foregroundColor == Color(nsColor: CodeTheme.color(.comment, dark: false)) })
    let large = String(repeating: "let value = \"text\" // comment\n", count: 1_500)
    let started = Date()
    #expect(String(CodeHighlight.attributedString(large, language: "swift", dark: true).characters) == large)
    #expect(Date().timeIntervalSince(started) < 10)
}

@MainActor @Test func largeStreamingCodeBlocksRenderBeforeBackgroundHighlighting() throws {
    let source = String(repeating: "let value = 1 // streaming\n", count: 1_000)
    for closed in [false, true] {
        let view = MarkdownCodeView(language: "swift", meta: "", source: source, closed: closed, context: .init(workspace: nil, openFile: { _, _ in }))
            .frame(width: 600).environment(\.colorScheme, .dark)
        let size = NSHostingController(rootView: view).sizeThatFits(in: CGSize(width: 600, height: 100_000))
        #expect(size.height > 1_000)
    }
}

// MARK: Robustness

@Test func t3AdjacentCodeSpansAndEscapesStayLiteral() {
    for (source, code) in [("$a`$HOME`", "$HOME"), (#"\(a`\)`"#, #"\)"#), (#"\(a\alpha`\)`"#, #"\)"#), (#"text \[a`\]`"#, #"\]"#)] {
        let spans = paragraph(source)
        #expect(formulas(spans).isEmpty && spans.first { $0.style.contains(.code) }?.text == code, "\(source)")
    }
    #expect(paragraph(#"Escaped \$x\$ stays."#).map(\.text).joined() == "Escaped $x$ stays.")
    #expect(paragraph(#"Escaped \\(x\\) stays."#).map(\.text).joined() == #"Escaped \(x\) stays."#)
    guard case .list(_, let items)? = blocks("- a \\(x\n  +y\\) b\n- c").first, case .paragraph(let item)? = items.first?.blocks.first else { Issue.record("List formula"); return }
    #expect(formulas(item) == ["x\n+y"] && items.count == 2)
}

/// Every streamed prefix and a deterministic set of token soups parse without leaking
/// sentinel scalars into the rendered model.
@Test func streamedPrefixesAndTokenSoupsNeverLeakSentinels() {
    let message = """
    Intro with $x$, \\(y\\) and [^n] plus `code`$z$[^n].

    > [!NOTE]
    > $$
    > \\frac{a}{b}
    > $$

    - item \\(p\\n+q\\) and $$r$$
      $$
      s
      $$
    1. ```math
       t
       ```

    <details><summary>A</summary>
    \\[u\\]
    </details>
    <details>
    <summary>B</summary>

    $$v$$

    </details>

    | a | $|w|$ |
    | --- | --- |
    | :codex-followup[Next]{prompt=go} | ![alt $k$](i.png) |

    [^n]: Note with [^m] and $m$.
    [^m]: Second.
    """
    for end in message.indices where message[end] == " " || message[end] == "\n" || message[end] == "$" {
        let document = MarkdownDocument(parsing: String(message[..<end]))
        #expect(!privateUse(document.blocks), "Prefix ending at \(message.distance(from: message.startIndex, to: end))")
    }
    let tokens = ["$", "$$", "\\(", "\\)", "\\[", "\\]", "`", "``", "[^1]", "\n[^1]: n\n", "\n", "\n\n", "> ", "- ", "1. ", "  ", "    ", "<details>", "</details>",
                  "<summary>s</summary>", "<ul><li>", "</li>", "<table><tr><td>", "x", "y", "|", "| --- |", "```", "~~~", "math", "*", "_", ":codex-followup[a]{prompt=b}",
                  "](", "(", ")", "![", "[", "]", "\\", "5", ",", " "]
    var seed: UInt64 = 0x9E37_79B9_7F4A_7C15
    for _ in 0..<1_500 {
        var source = ""
        for _ in 0..<32 {
            seed = seed &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
            source += tokens[Int((seed >> 33) % UInt64(tokens.count))]
        }
        let document = MarkdownDocument(parsing: source)
        #expect(!privateUse(document.blocks), "\(source.debugDescription)")
    }
}
