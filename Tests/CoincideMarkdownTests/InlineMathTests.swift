import AppKit
import Foundation
import SwiftUI
import Testing
@testable import CoincideMarkdown

private func spans(_ source: String) -> [MarkdownSpan] {
    guard case .paragraph(let spans)? = MarkdownDocument(parsing: source).blocks.first else { return [] }
    return spans
}
private func formulas(_ spans: [MarkdownSpan]) -> [String] { spans.filter { !$0.style.isDisjoint(with: .math) }.map(\.text) }

@Test func inlineMathFollowsDollarRulesAndKeepsTeXIntact() {
    #expect(formulas(spans(#"Energy $E=mc^2$ and $a_1 * b_2$ with \(\frac{a}{b}\) and $$\sum_i x_i$$."#)) == ["E=mc^2", "a_1 * b_2", #"\frac{a}{b}"#, #"\sum_i x_i"#])
    let money = spans(#"It costs $5 and $10, or \$20 and $ x $ and $y$5."#)
    #expect(formulas(money).isEmpty)
    #expect(money.map(\.text).joined() == "It costs $5 and $10, or $20 and $ x $ and $y$5.")
    let code = spans("Shell `echo $HOME $PATH` and $x$")
    #expect(code.first { $0.style.contains(.code) }?.text == "echo $HOME $PATH")
    #expect(formulas(code) == ["x"])
    let source = spans(#"Inline \(a\) keeps $b$ source"#).filter { !$0.style.isDisjoint(with: .math) }
    #expect(source.map(\.source) == [#"\(a\)"#, "$b$"] && source.allSatisfy { $0.style.contains(.inlineMath) })
    #expect(source.compactMap(\.formula).map(\.latex) == ["a", "b"])
    #expect(source.compactMap(\.formula).map(\.source) == [#"\(a\)"#, "$b$"])
    #expect(source.compactMap(\.formula).map(\.copySource) == [#"\(a\)"#, #"\(b\)"#])
    #expect(source.compactMap(\.formula).allSatisfy { !$0.display })
    #expect(formulas(spans("Unclosed $x and \\(y")).isEmpty)
    #expect(formulas(spans("Shell vars $PATH:$HOME and US$5 or a$b$c stay text, but ($x$) and $y$, work.")) == ["x", "y"])
}

@Test func mathWorksInTablesListsAndAsLoneDisplayParagraphs() {
    let document = MarkdownDocument(parsing: "| Value | Formula |\n| --- | --- |\n| abs | $|x|$ |\n| frac | \\(\\tfrac12\\) |\n\n- item with $x^2$\n\n$$x+y$$\n\n\\[z\\]")
    guard case .table(_, let rows, _) = document.blocks[0], case .list(_, let items) = document.blocks[1] else { Issue.record("Missing table or list"); return }
    #expect(rows.count == 2 && rows[0].count == 2)
    #expect(formulas(rows[0][1]) == ["|x|"] && formulas(rows[1][1]) == [#"\tfrac12"#])
    guard case .paragraph(let item)? = items.first?.blocks.first else { Issue.record("Missing list paragraph"); return }
    #expect(formulas(item) == ["x^2"])
    #expect(Array(document.blocks[2...]) == [.math("x+y"), .math("z")])
}

@MainActor @Test func inlineFormulasRenderOnTheBaselineInBothAppearancesAndRespectTheSetting() throws {
    let spans = spans(#"Area $\pi r^2$ grows, and $x$ too."#)
    for render in [true, false] {
        for scheme in [ColorScheme.light, .dark] {
            let view = MarkdownInlineText(spans: spans, context: .init(workspace: nil, openFile: { _, _ in }, mathEnabled: render))
                .font(.system(size: 15)).frame(width: 420, alignment: .leading).environment(\.colorScheme, scheme)
            let size = NSHostingController(rootView: view).sizeThatFits(in: CGSize(width: 420, height: 400))
            #expect(size.height > 10 && size.height < 40, "An inline formula must not inflate the line height.")
            let renderer = ImageRenderer(content: view); renderer.scale = 1
            #expect(renderer.cgImage != nil)
        }
    }
    #expect(NativeMath.rendered(#"\pi r^2"#, dark: false, display: false, fontSize: 15).map { $0.descent >= 0 && $0.image.size.height < 30 } == true)
}
