import Foundation
import Testing
@testable import CoincideCore

@Test(arguments: [
    "printf '%s\\n' 'first\nsecond'",
    "printf \"%s\" \"$(printf 'first\nsecond')\"",
    "printf '%s' `printf 'first\nsecond'`",
    "printf one \\\n two",
    "printf one |\n sed 's/one/two/'",
    "(printf one\nprintf two)",
    "cat <<'EOF'\nExact café e\u{301} 🌍\nEOF",
    "cat <<-EOF\n\tkeep\n\tEOF",
    "cat <<A <<A\nfirst body\nA\nsecond body\nA",
    "cat <<< 'literal\nhere string'",
    "echo foo#bar 'quoted\nvalue'",
])
func transcriptCommandParserKeepsSupportedMultilineCommandBytesSeparateFromOutput(command: String) {
    let output = "Exact output e\u{301} 🌍\n\n"
    let value = TranscriptCommandParser.parse("$ " + command + "\n" + output)
    #expect(value.command?.utf8.elementsEqual(command.utf8) == true && value.output?.utf8.elementsEqual(output.utf8) == true)
    let message = ChatMessage(id: "command", role: .tool, text: "$ " + command + "\n" + output)
    let card = TranscriptToolPresentation.card(for: message)
    #expect(card.subject?.utf8.elementsEqual(command.utf8) == true && card.output?.utf8.elementsEqual(output.utf8) == true)
}

@Test(arguments: ["printf 'unterminated\noutput", "cat <<EOF\nmissing delimiter", "echo $(unterminated\noutput", "if true; then\nbody\nfi\noutput", "echo trailing\\"])
func transcriptCommandParserPreservesUnprovenSourceLiterallyInsteadOfInventingBoundary(body: String) {
    let source = "$ " + body, value = TranscriptCommandParser.parse(source)
    #expect(value.command == nil && value.output?.utf8.elementsEqual(source.utf8) == true)
}

@Test func transcriptCommandParserBoundsNestedAndOversizedInputsWithoutNormalizingTheirBytes() {
    for source in ["$ " + String(repeating: "$(", count: 65) + "x" + String(repeating: ")", count: 65),
                   "$ " + String(repeating: "🌍", count: TranscriptCommandParser.maximumBytes / 4 + 1)] {
        let value = TranscriptCommandParser.parse(source)
        #expect(value.command == nil && value.output?.utf8.elementsEqual(source.utf8) == true)
    }
    let empty = TranscriptCommandParser.parse("$ ls\n")
    #expect(empty.command == "ls" && empty.output == nil)
}
