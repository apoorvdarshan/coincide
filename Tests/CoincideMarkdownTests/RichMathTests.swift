import AppKit
import Foundation
import SwiftUI
import Testing
@testable import CoincideMarkdown

private func richMathSpans(_ blocks: [MarkdownBlock]) -> [MarkdownSpan] {
    blocks.flatMap { block in
        switch block {
        case .paragraph(let spans), .heading(_, let spans): return spans
        case .quote(let children), .alert(_, let children), .details(_, _, let children): return richMathSpans(children)
        case .list(_, let items): return items.flatMap { richMathSpans($0.blocks) }
        case .table(let headers, let rows, _): return headers.flatMap { $0 } + rows.flatMap { $0.flatMap { $0 } }
        default: return []
        }
    }
}
private func richMathFormulas(_ blocks: [MarkdownBlock]) -> [String] {
    blocks.flatMap { block in
        switch block {
        case .math(let latex): return ["display:" + latex]
        case .paragraph(let spans), .heading(_, let spans): return spans.compactMap { $0.formula.map { ($0.display ? "display:" : "inline:") + $0.latex } }
        case .quote(let children), .alert(_, let children), .details(_, _, let children): return richMathFormulas(children)
        case .list(_, let items): return items.flatMap { richMathFormulas($0.blocks) }
        case .table(let headers, let rows, _): return (headers.flatMap { $0 } + rows.flatMap { $0.flatMap { $0 } }).compactMap { $0.formula.map { ($0.display ? "display:" : "inline:") + $0.latex } }
        default: return []
        }
    }
}

@Test func markdownMathReadsFourPinnedDelimitersAndClosedFlowWithoutEatingAdjacentProse() {
    let cases: [(String, [String])] = [
        (#"Inline $x^2$ and \(y_1\), display $$a+b$$ and \[c\]."#, ["inline:x^2", "inline:y_1", "display:a+b", "display:c"]),
        ("$$\n\\frac{a}{b}\n$$", [#"display:\frac{a}{b}"#]),
        ("Where\n\\[\na\n=\nb\n\\]\nholds.", ["display:a\n=\nb"]),
        ("$$a$$ is the first formula.\nSome prose.\n$$\nb\n$$", ["display:a", "display:b"]),
        ("$$x^2\n+y^2$$", ["display:x^2\n+y^2"]),
        ("> $$\n> x\n> $$", ["display:x"]),
        ("\\[\n1\n\\]", ["display:1"]),
        (#"Cost $a\$b$ and \(\left(x\right)\)."#, [#"inline:a\$b"#, #"inline:\left(x\right)"#]),
        (#"Pay \$$x$ now."#, ["inline:x"])
    ]
    for (source, expected) in cases {
        let document = MarkdownDocument(parsing: source)
        #expect(richMathFormulas(document.blocks) == expected, Comment(rawValue: source))
        #expect(!richMathSpans(document.blocks).contains { $0.text.contains("coincide-math-") })
    }
}

@Test func markdownMathLeavesPinnedPricesVariablesEscapesCodeLinksAndCitationNumbersAsProse() {
    let cases = [
        "It costs $5 and $10.", "Budget $5-$10 per seat, or $20,000-$30,000 a year.", "Plans are $5/$10 monthly.",
        "Run $browser then $deploy on it.", "Set $HOME before running.", #"Escaped \$x\$ stays."#, #"Escaped \\(x\\) stays."#,
        #"As shown in \[1\] and \[2, 3\]."#, #"Use `$x$` in code."#, "```text\n$x$ \\(y\\)\n```", "    \\(x\\)",
        #"See [docs](https://example.com/\(a\)) here."#, #"Set $TOKEN, then open <https://graph.example.com/users?$select=id>."#,
        #"$a`$HOME`"#, #"\(a`\)`"#, #"\(a\alpha`\)`"#, #"text \[a`\]`"#
    ]
    for source in cases { #expect(richMathFormulas(MarkdownDocument(parsing: source).blocks).isEmpty, Comment(rawValue: source)) }
    let formula = MarkdownDocument(parsing: "Price $5-$10 stays literal. The formula is $x_i$ and $5$.")
    #expect(richMathFormulas(formula.blocks) == ["inline:x_i", "inline:5"])
    let plain = richMathSpans(formula.blocks).filter { $0.formula == nil }.map(\.text).joined()
    #expect(plain == "Price $5-$10 stays literal. The formula is  and .")
}

@Test func markdownMathPreservesLinksPrivateUseUnicodeAndTableCellBoundaries() {
    let pua = (0..<6_400).compactMap { UnicodeScalar(0xe000 + $0) }.map(String.init).joined()
    let source = "$x$ " + pua + " [norm $|x|$](https://example.com/$path)"
    let document = MarkdownDocument(parsing: source)
    #expect(richMathFormulas(document.blocks) == ["inline:x", "inline:|x|"])
    let spans = richMathSpans(document.blocks)
    #expect(spans.filter { $0.formula == nil }.map(\.text).joined().contains(pua))
    #expect(spans.contains { $0.formula?.latex == "|x|" && $0.destination == "https://example.com/$path" })
    for formula in [#"\(\frac{1}{|x|}\)"#, "$$|x|$$", "$|x|$"] {
        let table = MarkdownDocument(parsing: "| Name | Value |\n| --- | --- |\n| x | \(formula) |")
        guard case .some(.table(let headers, let rows, _)) = table.blocks.first else { Issue.record("Math pipe split the table"); continue }
        #expect(headers.count == 2 && rows.count == 1 && rows[0].count == 2)
        #expect(richMathFormulas(table.blocks).count == 1)
    }
    for opener in [#"\("#, #"\["#] {
        let closer = opener == #"\("# ? #"\)"# : #"\]"#
        let table = MarkdownDocument(parsing: "| Name | Value |\n| --- | --- |\n| first | \(opener)x |\n| second | y\(closer) |\n| valid | $|z|$ |")
        guard case .some(.table(let headers, let rows, _)) = table.blocks.first else { Issue.record("Unclosed math consumed table rows"); continue }
        #expect(headers.count == 2 && rows.count == 3 && rows.allSatisfy { $0.count == 2 })
        #expect(richMathFormulas(table.blocks) == ["inline:|z|"])
    }
}

@Test func markdownMathStreamingAndDisabledModeNeverLeakTokensOrMixCachedDocuments() async {
    let source = #"Energy \(E = mc^2\) and $$\sum_i x_i$$ done."#
    for end in source.indices {
        let document = MarkdownDocument(parsing: String(source[..<end]))
        #expect(!richMathSpans(document.blocks).contains { $0.text.contains("coincide-math-") })
    }
    #expect(richMathFormulas(MarkdownDocument(parsing: "$$\nx^2").blocks).isEmpty)
    #expect(richMathFormulas(MarkdownDocument(parsing: "\\[\nx^2\n- y").blocks).isEmpty)
    let combined = source + "\n\n```math\nx^2\n```", parser = MarkdownParser()
    let enabled = await parser.parse(combined), disabled = await parser.parse(combined, mathEnabled: false)
    #expect(!richMathFormulas(enabled.blocks).isEmpty && richMathFormulas(disabled.blocks).isEmpty)
    #expect(disabled.blocks.contains { if case .code(let language, _, _, _) = $0 { language == "math" } else { false } })
    #expect(await parser.parse(combined) == enabled)
}

@MainActor @Test func nativeMathInlineMetricsFallbackAndSourceCopyAreBoundedWithoutAWindow() throws {
    let rendered = try #require(NativeMath.render(#"x_1+\frac{1}{2}"#, dark: false, display: false))
    #expect(rendered.descent >= 0 && rendered.image.size.width > 0 && rendered.image.size.height > 0)
    #expect(NativeMath.render(#"\unsupportedCommand{x}"#, dark: true, display: false) == nil)
    #expect(NativeMath.render(String(repeating: "x", count: 4_097), dark: false, display: false) == nil)
    let formula = MarkdownFormula(source: "$x_1$", latex: "x_1", display: false)
    #expect(formula.copySource == #"\(x_1\)"#)
    let display = MarkdownFormula(source: "$$x_1$$", latex: "x_1", display: true)
    #expect(display.copySource == "\\[\nx_1\n\\]")
}
