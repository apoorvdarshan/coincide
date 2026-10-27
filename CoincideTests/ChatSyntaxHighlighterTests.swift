import AppKit
import Testing

@testable import Coincide

/// Token colors in the light appearance, as Xcode's default theme has them.
private enum Light {
    static let keyword: UInt32 = 0x9B2393
    static let string: UInt32 = 0xC41A16
    static let comment: UInt32 = 0x5D6C79
    static let number: UInt32 = 0x1C00CF
    static let type: UInt32 = 0x0B4F79
    static let call: UInt32 = 0x326D74
    static let attribute: UInt32 = 0x815F03
    static let property: UInt32 = 0x6C36A9
    /// The text's own color, which plain words keep.
    static let plain: UInt32 = 0x111111
}

/// Code highlighted for a language, with each token's color readable as a light-appearance hex value.
@MainActor
private struct Highlighted {
    let text: NSMutableAttributedString

    init(_ code: String, _ language: String?) {
        text = NSMutableAttributedString(
            string: code, attributes: [.foregroundColor: NSColor(srgbRed: 17 / 255, green: 17 / 255, blue: 17 / 255, alpha: 1)])
        ChatSyntaxHighlighter.highlight(text, range: NSRange(location: 0, length: text.length), language: language)
    }

    /// The color of every character of `token` (its `occurrence`th appearance), or nil when they differ.
    func color(_ token: String, occurrence: Int = 1, sourceLocation: SourceLocation = #_sourceLocation) -> UInt32? {
        let string = text.string as NSString
        var range = NSRange(location: NSNotFound, length: 0)
        var start = 0
        for _ in 0..<occurrence {
            range = string.range(of: token, range: NSRange(location: start, length: string.length - start))
            guard range.location != NSNotFound else {
                Issue.record("\(token) not found", sourceLocation: sourceLocation)
                return nil
            }
            start = NSMaxRange(range)
        }
        let colors = Set((range.location..<NSMaxRange(range)).map { hex(at: $0) })
        return colors.count == 1 ? colors.first ?? nil : nil
    }

    func hex(at index: Int) -> UInt32? {
        guard let color = text.attribute(.foregroundColor, at: index, effectiveRange: nil) as? NSColor else { return nil }
        var resolved: NSColor?
        NSAppearance(named: .aqua)?.performAsCurrentDrawingAppearance { resolved = color.usingColorSpace(.sRGB) }
        guard let resolved else { return nil }
        let red = UInt32((resolved.redComponent * 255).rounded())
        let green = UInt32((resolved.greenComponent * 255).rounded())
        let blue = UInt32((resolved.blueComponent * 255).rounded())
        return red << 16 | green << 8 | blue
    }
}

struct ChatSyntaxHighlighterTests {
    @Test func swiftKeywordsTypesCallsAttributesNumbersStringsAndComments() {
        let code = Highlighted(
            """
            @MainActor
            func greet(name: String) -> Int {
                // say hi
                let count = 42
                return print("hi \\(name)", count)
            }
            """, "swift")
        #expect(code.color("@MainActor") == Light.attribute)
        #expect(code.color("func") == Light.keyword)
        #expect(code.color("greet") == Light.call)
        #expect(code.color("name") == Light.plain)
        #expect(code.color("String") == Light.type)
        #expect(code.color("// say hi") == Light.comment)
        #expect(code.color("let") == Light.keyword)
        #expect(code.color("42") == Light.number)
        #expect(code.color("return") == Light.keyword)
        #expect(code.color("print") == Light.call)
        #expect(code.color("\"hi \\(name)\"") == Light.string)
        #expect(code.color("count", occurrence: 2) == Light.plain)
    }

    @Test func swiftMultilineStringsAndLiterals() {
        let code = Highlighted("let s = \"\"\"\nline \"x\"\n\"\"\"\nlet ok = true && nil == x", "swift")
        #expect(code.color("line \"x\"") == Light.string)
        #expect(code.color("let", occurrence: 2) == Light.keyword)
        #expect(code.color("true") == Light.keyword)
        #expect(code.color("nil") == Light.keyword)
        #expect(code.color("ok") == Light.plain)
    }

    @Test func languageNamesAreCaseInsensitiveAndUnknownOnesStayPlain() {
        #expect(Highlighted("let x = 1", "SWIFT").color("let") == Light.keyword)
        let unknown = Highlighted("let x = 1 // no", "brainfuck")
        #expect(unknown.color("let x = 1 // no") == Light.plain)
        #expect(Highlighted("let x = 1", nil).color("let x = 1") == Light.plain)
    }

    @Test func pythonCommentsDecoratorsAndTripleQuotedStrings() {
        let code = Highlighted("# setup\n@cache\ndef f(x):\n    return None  # done\n'''doc\nstring'''\nprint(True)", "python")
        #expect(code.color("# setup") == Light.comment)
        #expect(code.color("@cache") == Light.attribute)
        #expect(code.color("def") == Light.keyword)
        #expect(code.color("f", occurrence: 2) == Light.call)
        #expect(code.color("None") == Light.keyword)
        #expect(code.color("# done") == Light.comment)
        #expect(code.color("'''doc\nstring'''") == Light.string)
        #expect(code.color("True") == Light.keyword)
    }

    @Test func javaScriptTemplateLiteralsSpanLinesButOtherStringsDoNot() {
        let code = Highlighted("const s = `a\nb`;\nconst t = 'open\nconst $el = 0x1F;", "ts")
        #expect(code.color("`a\nb`") == Light.string)
        #expect(code.color("'open") == Light.string)
        // The unterminated quote ends at the line end, so the next line is code again.
        #expect(code.color("const", occurrence: 3) == Light.keyword)
        #expect(code.color("$el") == Light.plain)
        #expect(code.color("0x1F") == Light.number)
    }

    @Test func blockCommentsRunToTheirCloseOrTheEnd() {
        let closed = Highlighted("a /* note */ b", "c")
        #expect(closed.color("/* note */") == Light.comment)
        #expect(closed.color(" b") == Light.plain)
        let open = Highlighted("int x; /* open\nstill", "cpp")
        #expect(open.color("/* open\nstill") == Light.comment)
        #expect(open.color("int") == Light.keyword)
    }

    @Test func rustAndGoKeywordsAndLiterals() {
        let rust = Highlighted("fn main() { let mut v = Some(1); }", "rust")
        #expect(rust.color("fn") == Light.keyword)
        #expect(rust.color("main") == Light.call)
        #expect(rust.color("mut") == Light.keyword)
        #expect(rust.color("Some") == Light.keyword)
        #expect(rust.color("1") == Light.number)
        let go = Highlighted("package main\nvar raw = `multi\nline`", "go")
        #expect(go.color("package") == Light.keyword)
        #expect(go.color("`multi\nline`") == Light.string)
    }

    @Test func shellCommandsVariablesAndComments() {
        let code = Highlighted(
            "$ npm install --save\nexport PATH=$HOME/bin\necho ${USER} | grep x && ls # list\necho a#b", "bash")
        #expect(code.color("npm") == Light.call)
        #expect(code.color("install") == Light.plain)
        #expect(code.color("export") == Light.keyword)
        #expect(code.color("$HOME") == Light.type)
        #expect(code.color("${USER}") == Light.type)
        #expect(code.color("echo") == Light.call)
        #expect(code.color("grep") == Light.call)
        #expect(code.color("ls") == Light.call)
        #expect(code.color("# list") == Light.comment)
        // A hash inside a word is not a comment.
        #expect(code.color("a#b") == Light.plain)
    }

    @Test func sqlKeywordsIgnoreCase() {
        let code = Highlighted("SELECT name FROM Users WHERE id = 1 -- note\nselect 'x'", "sql")
        #expect(code.color("SELECT") == Light.keyword)
        #expect(code.color("FROM") == Light.keyword)
        #expect(code.color("Users") == Light.plain)
        #expect(code.color("1") == Light.number)
        #expect(code.color("-- note") == Light.comment)
        #expect(code.color("select") == Light.keyword)
        #expect(code.color("'x'") == Light.string)
    }

    @Test func jsonKeysAreProperties() {
        let code = Highlighted("{\"key\": \"value\", \"n\" : 1.5, \"ok\": true, \"none\": null}", "json")
        #expect(code.color("\"key\"") == Light.property)
        #expect(code.color("\"value\"") == Light.string)
        #expect(code.color("\"n\"") == Light.property)
        #expect(code.color("1.5") == Light.number)
        #expect(code.color("true") == Light.keyword)
        #expect(code.color("null") == Light.keyword)
    }

    @Test func yamlKeysCommentsAndLiterals() {
        let code = Highlighted("name: app\nversion: 2\nenabled: yes # on\n- item: x", "yaml")
        #expect(code.color("name") == Light.property)
        #expect(code.color("2") == Light.number)
        #expect(code.color("yes") == Light.keyword)
        #expect(code.color("# on") == Light.comment)
        #expect(code.color("item") == Light.property)
        #expect(code.color("app") == Light.plain)
    }

    @Test func markupTagsAttributesEntitiesAndComments() {
        let code = Highlighted("<div class=\"a\">Hi &amp; bye</div>\n<!-- note -->", "html")
        #expect(code.color("<") == Light.keyword)
        #expect(code.color("div") == Light.keyword)
        #expect(code.color("class") == Light.attribute)
        #expect(code.color("\"a\"") == Light.string)
        #expect(code.color("Hi") == Light.plain)
        #expect(code.color("&amp;") == Light.number)
        #expect(code.color("</") == Light.keyword)
        #expect(code.color("<!-- note -->") == Light.comment)
    }

    @Test func cssPropertiesColorsAndAtRules() {
        let code = Highlighted(".card {\n  color: #fff;\n  margin: 0 !important;\n}\n@media screen {}", "css")
        #expect(code.color("color") == Light.property)
        #expect(code.color("#fff") == Light.number)
        #expect(code.color("margin") == Light.property)
        #expect(code.color("important") == Light.keyword)
        #expect(code.color("@media") == Light.keyword)
        #expect(code.color("card") == Light.plain)
    }

    @Test func veryLongCodeStaysPlain() {
        let long = String(repeating: "let x = 1\n", count: ChatSyntaxHighlighter.maximumLength / 10 + 1)
        let code = Highlighted(long, "swift")
        #expect(code.hex(at: 0) == Light.plain)
    }

    // MARK: Diffs

    @Test func diffLinesAreFilledOrColored() {
        let diff = "diff --git a/x b/x\n--- a/x\n+++ b/x\n@@ -1,2 +1,2 @@\n-old\n+new\n context"
        let text = NSMutableAttributedString(string: diff)
        ChatSyntaxHighlighter.highlight(text, range: NSRange(location: 0, length: text.length), language: "diff")
        let string = diff as NSString
        func background(_ line: String) -> NSColor? {
            text.attribute(.chatLineBackground, at: string.range(of: line).location, effectiveRange: nil) as? NSColor
        }
        func foreground(_ line: String) -> NSColor? {
            text.attribute(.foregroundColor, at: string.range(of: line).location, effectiveRange: nil) as? NSColor
        }
        #expect(background("+new") === Theme.addition)
        #expect(background("-old") === Theme.deletion)
        #expect(foreground("@@ -1,2") == .systemBlue)
        #expect(foreground("+++ b/x") == .secondaryLabelColor)
        #expect(foreground("--- a/x") == .secondaryLabelColor)
        #expect(foreground("diff --git") == .secondaryLabelColor)
        #expect(background("+++ b/x") == nil)
        #expect(background(" context") == nil && foreground(" context") == nil)
        // The fill covers the line's newline too, so it spans the full width.
        let added = string.range(of: "+new\n")
        #expect(text.attribute(.chatLineBackground, at: NSMaxRange(added) - 1, effectiveRange: nil) != nil)
    }

    @Test func patchAndUdiffAreDiffsToo() {
        for language in ["patch", "udiff", "DIFF"] {
            let text = NSMutableAttributedString(string: "+a")
            ChatSyntaxHighlighter.highlight(text, range: NSRange(location: 0, length: 2), language: language)
            #expect(text.attribute(.chatLineBackground, at: 0, effectiveRange: nil) != nil, "\(language)")
        }
    }

    @Test func looksLikeDiffNeedsAHeaderAndAChange() {
        #expect(ChatSyntaxHighlighter.looksLikeDiff("@@ -1 +1 @@\n-a\n+b"))
        #expect(ChatSyntaxHighlighter.looksLikeDiff("diff --git a/x b/x\n+added"))
        #expect(!ChatSyntaxHighlighter.looksLikeDiff("- item\n- another"))
        #expect(!ChatSyntaxHighlighter.looksLikeDiff("--- a/x\n+++ b/x\n"))
        #expect(!ChatSyntaxHighlighter.looksLikeDiff("plain text"))
    }
}
