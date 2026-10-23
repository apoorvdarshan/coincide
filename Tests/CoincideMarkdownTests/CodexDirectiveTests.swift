import Foundation
import Testing
@testable import CoincideMarkdown

private let citation = #":codex-file-citation{path="outputs/report.xlsx" purpose="output"}"#
private let followUp = #":codex-followup[Prepare print version]{prompt="Prepare the document for printing."}"#
private let artifact = #"::artifact-template{skill_name="artifact-template-hello-world" skill_directory="/Users/test/.codex/skills/artifact-template-hello-world" display_name="Hello World" artifact_kind="document"}"#

private func spans(_ source: String) -> [MarkdownSpan] {
    guard case .paragraph(let spans)? = MarkdownDocument(parsing: source).blocks.first else { return [] }
    return spans
}

@Test func codexFileCitationsBecomeContainedFileLinksWithLines() throws {
    let rendered = spans("Created \(citation).")
    #expect(rendered.map(\.text).joined() == "Created report.xlsx.")
    #expect(rendered.first { $0.text == "report.xlsx" }?.destination == "outputs/report.xlsx")
    let lined = spans(#"See :codex-file-citation{path="src/a#b?c%.swift" line_range_start="7"}"#)
    let destination = try #require(lined.first { $0.text == "a#b?c%.swift" }?.destination)
    #expect(destination == "src/a%23b%3Fc%25.swift#L7")
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("coincide-citation-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let resolvedRoot = root.standardizedFileURL.resolvingSymlinksInPath()
    #expect(MarkdownLinkTarget.resolve(destination, workspace: root) == .file(resolvedRoot.appendingPathComponent("src").appendingPathComponent("a#b?c%.swift"), line: 7))
}

@Test func codexFollowUpsRenderTheirLabelAndMalformedDirectivesStayLiteral() {
    let document = MarkdownDocument(parsing: "- \(followUp)\n- :codex-followup[Review **document**]{prompt=\"Review it.\"}")
    guard case .list(_, let items)? = document.blocks.first, case .paragraph(let first)? = items.first?.blocks.first,
          case .paragraph(let second)? = items.last?.blocks.first else { Issue.record("Missing follow-up list"); return }
    #expect(first.map(\.text).joined() == "Prepare print version")
    #expect(second.first { $0.text == "document" }?.style == .strong)
    for literal in [#":codex-file-citation{purpose="output"}"#, ":codex-followup[Prepare print version]", #":codex-followup[ ]{prompt="x"}"#,
                    #":codex-file-citation-extra{path="a.txt"}"#, "Meeting at 10:30", "`\(citation)`", "\\\(citation)", "[See \(citation)](https://example.com)"] {
        let text = spans(literal).map(\.text).joined()
        #expect(!spans(literal).contains { $0.destination == "outputs/report.xlsx" }, "\(literal)")
        #expect(text.contains("codex") || text == "Meeting at 10:30", "\(literal) rendered as \(text)")
    }
}

@Test func artifactTemplatesBecomeCardsAndCopyTextMatchesT3() {
    let document = MarkdownDocument(parsing: "Before\n\n\(artifact)\n\nAfter")
    guard document.blocks.count == 3, case .artifactTemplate(let template) = document.blocks[1] else { Issue.record("Missing artifact card: \(document.blocks)"); return }
    #expect(template.displayName == "Hello World" && template.artifactKind == .document && template.skillName == "artifact-template-hello-world")
    let malformed = #"::artifact-template{display_name="Hello World"}"#
    #expect(MarkdownDocument(parsing: malformed).blocks == [.paragraph([.init(text: malformed)])])
    let fenced = MarkdownDocument(parsing: "```\n\(artifact)\n```")
    guard case .code(_, let code, _, _)? = fenced.blocks.first else { Issue.record("Fenced directive must stay code"); return }
    #expect(code == artifact + "\n")
    #expect(CodexDirectives.renderForCopy("Created \(citation).\n\n\(artifact)\n\n- \(followUp)")
        == "Created [report.xlsx](<outputs/report.xlsx>).\n\nHello World (Document template)\n\n- Prepare print version")
    #expect(CodexDirectives.renderForCopy("plain text") == "plain text")
}
