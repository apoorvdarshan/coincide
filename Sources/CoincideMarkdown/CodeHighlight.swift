import AppKit

/// Small native lexical highlighter. Unknown languages retain their original text.
public enum CodeHighlight {
    public static func attributed(_ source: String, language: String) -> NSAttributedString {
        let result = NSMutableAttributedString(string: source, attributes: [.font: NSFont.monospacedSystemFont(ofSize: 13, weight: .regular), .foregroundColor: NSColor.labelColor])
        guard source.utf8.count <= 65_536 else { return result }
        let language = language.lowercased().split(whereSeparator: \.isWhitespace).first.map(String.init) ?? ""
        let hashComments = ["python", "py", "bash", "sh", "shell", "zsh", "ruby", "rb", "yaml", "yml", "toml"].contains(language)
        let slashComments = ["swift", "rust", "rs", "javascript", "js", "typescript", "ts", "tsx", "jsx", "c", "cpp", "c++", "objc", "java", "kotlin", "kt", "go", "css", "jsonc"].contains(language)
        let json = ["json", "jsonc"].contains(language)
        guard hashComments || slashComments || json else { return result }
        let keywords = #"\b(?:actor|as|async|await|break|case|catch|class|const|continue|def|defer|do|else|enum|export|extends|false|final|fn|for|from|func|function|guard|if|impl|import|in|init|interface|is|let|match|mut|nil|None|null|override|private|protocol|pub|public|raise|return|self|static|struct|super|switch|throw|throws|trait|true|try|type|var|void|where|while|with|yield)\b"#
        let comment = hashComments ? #"#[^\n]*"# : #"//[^\n]*|/\*[\s\S]*?\*/"#
        let string = #""(?:\\.|[^"\\])*"|'(?:\\.|[^'\\])*'|`(?:\\.|[^`\\])*`"#
        // One scan keeps strings from being recolored as comments or keywords.
        let pattern = "(?<comment>\(comment))|(?<string>\(string))|(?<keyword>\(keywords))|(?<number>\\b(?:0[xX][0-9a-fA-F]+|[0-9]+(?:\\.[0-9]+)?)\\b)"
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return result }
        regex.enumerateMatches(in: source, range: NSRange(source.startIndex..., in: source)) { match, _, _ in
            guard let match else { return }
            for (name, color) in [("comment", NSColor.secondaryLabelColor), ("string", .systemRed), ("keyword", .systemPurple), ("number", .systemBlue)] {
                let range = match.range(withName: name)
                if range.location != NSNotFound { result.addAttribute(.foregroundColor, value: color, range: range); break }
            }
        }
        return result
    }
}
