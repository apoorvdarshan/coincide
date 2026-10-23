import AppKit
import SwiftUI
import Testing
@testable import CoincideMarkdown

@Test func markdownDetailsUsesFirstSummaryBooleanOpenAndKeepsMarkdownBodyWithNativeAlertsAndMath() {
    let source = "<details open=\"false\" onclick=\"neverExecute()\">\n<summary>A <strong>safe</strong> &amp; readable title</summary>\n\nParagraph **body** and $x$.\n\n> [!NOTE]\n> Kept inside.\n\n</details>"
    let document = MarkdownDocument(parsing: source)
    guard case .some(.details(let summary, let open, let blocks)) = document.blocks.first else { Issue.record("Missing native details"); return }
    #expect(open && summary.map(\.text).joined() == "A safe & readable title")
    #expect(summary.contains { $0.text == "safe" && $0.style.contains(.strong) })
    #expect(blocks.contains { if case .paragraph(let spans) = $0 { spans.contains { $0.text == "body" && $0.style.contains(.strong) } } else { false } })
    #expect(blocks.contains { if case .alert(.note, _) = $0 { true } else { false } })
    #expect(!summary.contains { $0.text.contains("onclick") })
}

@Test func markdownDetailsDefaultsClosedRetainsNestedBodiesAndTreatsRawIntroductionAsHTMLText() {
    let source = "<details>\n<summary>Outer</summary>\n\n<details open>\n<summary>Inner</summary>\n\n- Retained child\n\n</details>\n\n</details>"
    let document = MarkdownDocument(parsing: source)
    guard case .some(.details(_, let open, let blocks)) = document.blocks.first,
          case .some(.details(let title, let childOpen, let child)) = blocks.first else { Issue.record("Nested details were flattened"); return }
    #expect(!open && childOpen && title.map(\.text).joined() == "Inner")
    #expect(child.contains { if case .list = $0 { true } else { false } })
    let raw = MarkdownDocument(parsing: "<details><summary>**literal summary**</summary>**literal body**</details>")
    guard case .some(.details(let rawTitle, _, let rawBody)) = raw.blocks.first,
          case .some(.paragraph(let spans)) = rawBody.first else { Issue.record("Raw HTML text was lost"); return }
    #expect(rawTitle.map(\.text).joined() == "**literal summary**" && spans.map(\.text).joined() == "**literal body**")
    #expect(rawTitle.allSatisfy { $0.style.isEmpty } && spans.allSatisfy { $0.style.isEmpty })
}

@Test func markdownDetailsPreservesIncompleteUnsupportedAndProtectedHTMLWithoutInterpretingControls() {
    for source in ["<details>\n<summary>Still streaming", "```html\n<details><summary>Code</summary></details>\n```", "<script>\n<details>not a control</details>\n</script>", "<details><summary><a href='file:///outside'>unsupported</a></summary>Body</details>"] {
        #expect(!MarkdownDocument(parsing: source).blocks.contains { if case .details = $0 { true } else { false } })
    }
    let fenced = MarkdownDocument(parsing: "<details>\n<summary>Code sample</summary>\n\n```html\n</details>\n```\n\nRetained after code.\n\n</details>")
    guard case .some(.details(_, _, let blocks)) = fenced.blocks.first else { Issue.record("A code sample closed its owning details"); return }
    #expect(blocks.contains { if case .code(_, let code, _, _) = $0 { code.contains("</details>") } else { false } })
    #expect(blocks.contains { if case .paragraph(let spans) = $0 { spans.map(\.text).joined().contains("Retained after code.") } else { false } })
}

@MainActor @Test func nativeMarkdownDetailsAndMathRenderBothAppearancesWithOpenAndClosedNativeState() throws {
    let source = "Before $x_1$.\n\n<details open>\n<summary>Native details</summary>\n\n**Content** with \\(y^2\\).\n\n</details>\n\n<details>\n<summary>Closed details</summary>\n\nHidden body.\n\n</details>"
    let document = MarkdownDocument(parsing: source)
    for scheme in [ColorScheme.light, .dark] {
        let view = MarkdownBlocksView(blocks: document.blocks, workspace: nil, openFile: { _, _ in }).font(.system(size: 15))
            .padding(16).frame(width: 460).background(Color(nsColor: .textBackgroundColor)).environment(\.colorScheme, scheme)
        let renderer = ImageRenderer(content: view); renderer.scale = 1
        let image = try #require(renderer.cgImage)
        #expect(image.width == 460 && image.height > 80 && image.height < 1_000)
    }
}
