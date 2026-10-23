import AppKit
import Foundation
import Testing
@testable import CoincideMarkdown

private func kinds(_ source: String, _ language: String) -> [(String, CodeTokenKind)] {
    let units = Array(source.utf16)
    return CodeHighlight.tokens(source, language: language).map { (String(decoding: units[$0.range], as: UTF16.self), $0.kind) }
}
private func kind(_ source: String, _ language: String, _ text: String) -> CodeTokenKind? { kinds(source, language).first { $0.0 == text }?.1 }

@Test func highlighterResolvesT3LanguagesAndAliases() {
    for alias in ["py", "sh", "zsh", "yml", "c++", "cs", "rs", "ts", "tsx", "jsx", "md", "gitignore", "dockerfile", "makefile", "objc", "console", "kt", "golang",
                  "graphql", "haskell", "lua", "php", "powershell", "r", "ruby", "scala", "scss", "sql", "svelte", "swift", "toml", "vue", "xml", "zig", "dart", "elixir", "diff", "ini"] {
        #expect(CodeHighlight.label(for: alias) != nil, "Missing \(alias)")
    }
    #expect(CodeHighlight.label(for: "C++") == "C++" && CodeHighlight.label(for: "language-python") == "Python" && CodeHighlight.label(for: "text") == nil)
}

@Test func highlighterTokenizesRepresentativeLanguages() {
    let python = "@cache\ndef f(x):\n    s = f\"{x} # not comment\"  # comment\n    return None\n"
    #expect(kind(python, "py", "@cache") == .attribute && kind(python, "py", "def") == .keyword && kind(python, "py", "f") == .function)
    #expect(kind(python, "py", "f\"{x} # not comment\"") == .string && kind(python, "py", "# comment") == .comment && kind(python, "py", "None") == .constant)
    let shell = "echo \"$HOME\" ${PATH} $1 a#b # note\n"
    #expect(kind(shell, "bash", "echo") == .function && kind(shell, "bash", "${PATH}") == .variable && kind(shell, "bash", "$1") == .variable && kind(shell, "bash", "# note") == .comment)
    #expect(!kinds(shell, "bash").contains { $0.0.hasPrefix("#b") })
    let sql = "SELECT name FROM users WHERE id = 1 -- first\nselect count(*) from t;"
    #expect(kind(sql, "sql", "SELECT") == .keyword && kind(sql, "sql", "select") == .keyword && kind(sql, "sql", "-- first") == .comment && kind(sql, "sql", "count") == .function)
    let yaml = "name: CI\non:\n  - push: true\nruns-on: ubuntu # os\n"
    #expect(kind(yaml, "yml", "name") == .attribute && kind(yaml, "yml", "push") == .attribute && kind(yaml, "yml", "runs-on") == .attribute && kind(yaml, "yml", "true") == .constant)
    let json = #"{"key": "value", "n": 1.5e3, "ok": true}"#
    #expect(kind(json, "json", #""key""#) == .attribute && kind(json, "json", #""value""#) == .string && kind(json, "json", "1.5e3") == .number)
    let diff = "diff --git a/x b/x\n@@ -1 +1 @@\n-old\n+new\n context\n"
    #expect(kinds(diff, "diff").map(\.1) == [.meta, .meta, .deleted, .inserted])
    let html = "<div class=\"a\" hidden><!-- c --><script>let x = 1</script>&amp;</div>"
    #expect(kind(html, "html", "<div") == .tag && kind(html, "html", "class") == .attribute && kind(html, "html", "\"a\"") == .string)
    #expect(kind(html, "html", "<!-- c -->") == .comment && kind(html, "html", "let") == .keyword && kind(html, "html", "&amp;") == .constant)
    let css = ".card:hover { color: #fff; margin: 4px !important; }"
    #expect(kind(css, "css", ".card") == .type && kind(css, "css", "color") == .attribute && kind(css, "css", "#fff") == .number && kind(css, "css", "4px") == .number && kind(css, "css", "!important") == .keyword)
    let rust = "fn f<'a>(c: char) -> &'a str { let x = 'x'; println!(\"hi\"); r#\"raw\"# }"
    #expect(kind(rust, "rust", "'x'") == .string && kind(rust, "rust", "println!") == .function && kind(rust, "rust", "r#\"raw\"#") == .string && kind(rust, "rust", "str") == .type)
    #expect(!kinds(rust, "rust").contains { $0.0.hasPrefix("'a") })
}

@Test func highlighterHandlesUnterminatedInputUnicodeAndLimits() {
    for (source, language) in [("let s = \"open\nlet t = 1", "swift"), ("/* open comment\nx", "c"), ("x = '''open", "python"), ("<div class=\"x", "html")] {
        let tokens = CodeHighlight.tokens(source, language: language)
        #expect(tokens.allSatisfy { $0.range.upperBound <= source.utf16.count })
        #expect(zip(tokens, tokens.dropFirst()).allSatisfy { $0.range.upperBound <= $1.range.lowerBound })
        #expect(String(CodeHighlight.attributedString(source, language: language, dark: false).characters) == source)
    }
    #expect(kind("let s = \"open\nlet t = 1", "swift", "let") == .keyword)
    let emoji = "let 👩‍👩‍👧 = \"🪁\" // 世界\n"
    #expect(String(CodeHighlight.attributedString(emoji, language: "swift", dark: true).characters) == emoji)
    let lines = String(repeating: "let x = 1\n", count: 4_100)
    #expect(CodeHighlight.tokens(lines, language: "swift").isEmpty)
    #expect(CodeTheme.color(.keyword, dark: false) != CodeTheme.color(.keyword, dark: true))
    #expect(CodeTheme.color(.string, dark: true) != CodeTheme.color(.string, dark: true, increasedContrast: true))
}

@Test func fenceTitlesAndLanguageAreSplitFromTheInfoString() {
    #expect(CodeFence.title(#"title="src/app.swift""#) == "src/app.swift")
    #expect(CodeFence.title("filename=Package.swift {1,3}") == "Package.swift")
    #expect(CodeFence.title("file='a b.ts'") == "a b.ts")
    #expect(CodeFence.title("showLineNumbers main.rs") == "main.rs")
    #expect(CodeFence.title("{1,3} highlight") == nil && CodeFence.title("") == nil)
    let document = MarkdownDocument(parsing: "```swift title=\"a.swift\"\nlet a = 1\n```")
    #expect(document.blocks == [.code(language: "swift", text: "let a = 1\n", meta: #"title="a.swift""#, closed: true)])
}

@Test func runPredicateAllowsOnlyClosedSingleLineShellCommands() {
    #expect(CodeFence.runnableCommand(language: "bash", code: "  npm test  \n", closed: true, streaming: false) == "npm test")
    #expect(CodeFence.runnableCommand(language: "PowerShell", code: "Get-ChildItem\n", closed: true, streaming: false) == "Get-ChildItem")
    for (language, code, closed, streaming) in [("bash", "a\nb\n", true, false), ("bash", "make \\\n", true, false), ("bash", "ls\u{202E}x\n", true, false),
                                                ("zsh", "echo\u{200B}hi\n", true, false), ("bash", "ls\n", false, false), ("bash", "ls\n", true, true),
                                                ("python", "print(1)\n", true, false), ("sh", "   \n", true, false), ("bash", "a\tb\n", true, false)] {
        #expect(CodeFence.runnableCommand(language: language, code: code, closed: closed, streaming: streaming) == nil, "\(language) \(code.debugDescription)")
    }
}

@Test func tableExportEscapesMarkdownAndQuotesCSV() {
    let headers: [[MarkdownSpan]] = [[.init(text: "Name")], [.init(text: "Value")], [.init(text: "Note")]]
    let rows: [[[MarkdownSpan]]] = [
        [[.init(text: "a|b", style: .strong)], [.init(text: "x", style: .inlineMath, source: "$|x|$")], [.init(text: "say \"hi\", ok")]],
        [[.init(text: "code`tick", style: .code)], [.init(text: "site", destination: "https://example.com")], [.init(text: "line\nbreak")]]
    ]
    let markdown = MarkdownTableExport.markdown(headers: headers, rows: rows, alignments: [.left, .center, .right])
    #expect(markdown == """
    | Name | Value | Note |
    | --- | :---: | ---: |
    | **a\\|b** | $\\|x\\|$ | say "hi", ok |
    | ``code`tick`` | [site](<https://example.com>) | line break |
    """)
    let csv = MarkdownTableExport.csv(headers: headers, rows: rows)
    #expect(csv == "Name,Value,Note\na|b,$|x|$,\"say \"\"hi\"\", ok\"\ncode`tick,site,line break")
    let reparsed = MarkdownDocument(parsing: markdown)
    guard case .table(let parsedHeaders, let parsedRows, let alignments)? = reparsed.blocks.first else { Issue.record("Markdown export must reparse"); return }
    #expect(parsedHeaders.count == 3 && parsedRows.count == 2 && alignments == [.left, .center, .right])
    let captured = parsedRows[0][1].compactMap(\.formula)
    #expect(captured.map(\.source) == ["$\\|x\\|$"] && captured.map(\.latex) == ["|x|"])
    #expect(captured.map(\.copySource) == [#"\(|x|\)"#] && captured.allSatisfy { !$0.display })
    #expect(MarkdownTableExport.plainText(parsedRows[0][1]) == "$|x|$")
}
