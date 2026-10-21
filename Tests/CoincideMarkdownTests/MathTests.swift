import AppKit
import Foundation
import Testing
@testable import CoincideMarkdown

@Test func displayMathKeepsMarkdownCharactersInsideTheFormula() {
    let document = MarkdownDocument(parsing: "Before\n\n$$\na\n=\nb_1\n- x\n# y\n$$\n\nAfter\n\n\\[\n\\frac{x}{y}\n\\]")
    #expect(document.blocks.count == 4)
    #expect(document.blocks[1] == .math("a\n=\nb_1\n- x\n# y"))
    #expect(document.blocks[3] == .math(#"\frac{x}{y}"#))
}

@Test func explicitMathFencesRequireAClosingMarkerAndWorkInsideQuotes() {
    #expect(MarkdownDocument(parsing: "```math\nx^2\n```").blocks == [.math("x^2\n")])
    #expect(MarkdownDocument(parsing: "```math\nx^2").blocks == [.code(language: "math", text: "x^2\n")])
    let quoted = MarkdownDocument(parsing: "> ~~~math\n> \\sqrt{x}\n> ~~~")
    #expect(quoted.blocks == [.quote([.math("\\sqrt{x}\n")])])
}

@Test func displayMathDoesNotConsumeCodeHTMLPricesOrIncompleteFormulas() {
    let source = "```text\n$$\nx\n$$\n```\n\n    $$\n    y\n    $$\n\n<pre>\n$$\nz\n$$\n</pre>\n\nIt costs $5 and $10.\n\n\\[\nunclosed"
    let document = MarkdownDocument(parsing: source)
    #expect(!document.blocks.contains { if case .math = $0 { true } else { false } })
    let protectedCloser = MarkdownDocument(parsing: "$$\nunclosed\n\n```text\n$$\n```")
    #expect(!protectedCloser.blocks.contains { if case .math = $0 { true } else { false } })
    let many = String(repeating: "\\[\n", count: 5_000)
    #expect(!MarkdownDocument(parsing: many).blocks.isEmpty)
}

@MainActor @Test func nativeMathLoadsFontsAndRendersOrFallsBackWithoutAWebview() throws {
    for latex in [#"x=\frac{-b\pm\sqrt{b^2-4ac}}{2a}"#, #"\int_0^1 x^2\,dx=\frac13"#, #"\begin{pmatrix}1&2\\3&4\end{pmatrix}"#] {
        for dark in [false, true] {
            let image = try #require(NativeMath.image(latex, dark: dark))
            #expect(image.size.width > 10 && image.size.height > 10)
            #expect(image.cgImage(forProposedRect: nil, context: nil, hints: nil) != nil)
        }
    }
    #expect(NativeMath.image(#"\unknownCommand{x}"#, dark: false) == nil)
    #expect(NativeMath.image(String(repeating: "{", count: 100) + "x", dark: false) == nil)
    #expect(NativeMath.image(String(repeating: "x", count: 5_000), dark: false) == nil)
}
