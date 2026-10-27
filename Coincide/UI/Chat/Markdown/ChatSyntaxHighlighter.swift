import AppKit

/// Lightweight syntax coloring for code blocks and tool output: one forward scan per block,
/// covering comments, strings, numbers, keywords, types, calls and attributes for common
/// languages, plus line-level coloring for diffs. Colors follow Xcode's default themes.
@MainActor
enum ChatSyntaxHighlighter {
    /// Above this size code is shown plain to keep long outputs responsive.
    static let maximumLength = 120_000

    static func highlight(_ text: NSMutableAttributedString, range: NSRange, language: String?) {
        guard range.length > 0, range.length <= maximumLength, let language = language?.lowercased() else { return }
        if ["diff", "patch", "udiff"].contains(language) {
            highlightDiff(text, range: range)
            return
        }
        guard let grammar = Grammar.named(language) else { return }
        let units = Array((text.string as NSString).substring(with: range).utf16)
        text.beginEditing()
        var scanner = Scanner(units: units, grammar: grammar)
        scanner.scan { token, tokenRange in
            text.addAttribute(
                .foregroundColor, value: token.color,
                range: NSRange(location: range.location + tokenRange.location, length: tokenRange.length))
        }
        text.endEditing()
    }

    /// Whether text looks like a unified diff.
    static func looksLikeDiff(_ text: String) -> Bool {
        var hunks = 0
        var changes = 0
        for line in text.split(separator: "\n", omittingEmptySubsequences: false).prefix(400) {
            if line.hasPrefix("@@") || line.hasPrefix("+++ ") || line.hasPrefix("--- ") || line.hasPrefix("diff --git") {
                hunks += 1
            } else if line.hasPrefix("+") || line.hasPrefix("-") {
                changes += 1
            }
        }
        return hunks > 0 && changes > 0
    }

    /// Colors diff lines and fills each changed line across the full width.
    static func highlightDiff(_ text: NSMutableAttributedString, range: NSRange) {
        let string = text.string as NSString
        text.beginEditing()
        string.enumerateSubstrings(in: range, options: [.byLines, .substringNotRequired]) { _, lineRange, enclosingRange, _ in
            guard lineRange.length > 0 else { return }
            let first = string.character(at: lineRange.location)
            let line = string.substring(with: NSRange(location: lineRange.location, length: min(4, lineRange.length)))
            if line.hasPrefix("+++") || line.hasPrefix("---") || line.hasPrefix("diff") || line.hasPrefix("inde") {
                text.addAttribute(.foregroundColor, value: NSColor.secondaryLabelColor, range: lineRange)
            } else if line.hasPrefix("@@") {
                text.addAttribute(.foregroundColor, value: NSColor.systemBlue, range: lineRange)
            } else if first == UInt16(UInt8(ascii: "+")) {
                text.addAttribute(.chatLineBackground, value: Theme.addition, range: enclosingRange)
            } else if first == UInt16(UInt8(ascii: "-")) {
                text.addAttribute(.chatLineBackground, value: Theme.deletion, range: enclosingRange)
            }
        }
        text.endEditing()
    }

    // MARK: Tokens

    fileprivate enum Token {
        case keyword, string, comment, number, type, call, attribute, property, variable

        var color: NSColor {
            switch self {
            case .keyword: Palette.keyword
            case .string: Palette.string
            case .comment: Palette.comment
            case .number: Palette.number
            case .type: Palette.type
            case .call: Palette.call
            case .attribute: Palette.attribute
            case .property: Palette.property
            case .variable: Palette.type
            }
        }
    }

    private enum Palette {
        static let keyword = dynamic(light: 0x9B2393, dark: 0xFC5FA3)
        static let string = dynamic(light: 0xC41A16, dark: 0xFC6A5D)
        static let comment = dynamic(light: 0x5D6C79, dark: 0x7F8C98)
        static let number = dynamic(light: 0x1C00CF, dark: 0xD0BF69)
        static let type = dynamic(light: 0x0B4F79, dark: 0x5DD8FF)
        static let call = dynamic(light: 0x326D74, dark: 0x67B7A4)
        static let attribute = dynamic(light: 0x815F03, dark: 0xBF8555)
        static let property = dynamic(light: 0x6C36A9, dark: 0xA167E6)

        private static func dynamic(light: UInt32, dark: UInt32) -> NSColor {
            NSColor(name: nil) { appearance in
                let isDark = appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
                let hex = isDark ? dark : light
                return NSColor(
                    srgbRed: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255,
                    blue: CGFloat(hex & 0xFF) / 255, alpha: 1)
            }
        }
    }
}

// MARK: - Grammars

nonisolated private struct Grammar {
    enum Kind {
        case code, json, yaml, markup, css, shell
    }

    var kind: Kind = .code
    var keywords: Set<String> = []
    var literals: Set<String> = []
    var lineComments: [String] = ["//"]
    var blockComment: (open: String, close: String)? = ("/*", "*/")
    var quotes: Set<UInt16> = [.doubleQuote, .singleQuote]
    /// Quotes whose strings may span lines, like JavaScript template literals.
    var multilineQuotes: Set<UInt16> = []
    var tripleQuotes = false
    var attributePrefixes: Set<UInt16> = []
    var capitalizedTypes = true
    var caseInsensitive = false
    var identifierExtras: Set<UInt16> = [.underscore]

    static func named(_ name: String) -> Grammar? {
        switch name {
        case "swift":
            return Grammar(
                keywords: [
                    "actor", "any", "as", "associatedtype", "async", "await", "break", "case", "catch", "class", "continue",
                    "default", "defer", "deinit", "do", "else", "enum", "extension", "fallthrough", "fileprivate", "final",
                    "for", "func", "guard", "if", "import", "in", "indirect", "init", "inout", "internal", "is", "isolated",
                    "lazy", "let", "macro", "mutating", "nonisolated", "open", "operator", "override", "private",
                    "protocol", "public", "repeat", "required", "rethrows", "return", "self", "Self", "some", "static",
                    "struct", "subscript", "super", "switch", "throw", "throws", "try", "typealias", "var", "weak", "where",
                    "while", "unowned", "convenience", "dynamic", "get", "set", "willSet", "didSet", "consuming", "borrowing",
                ],
                literals: ["true", "false", "nil"], tripleQuotes: true, attributePrefixes: [.at, .hash])
        case "js", "javascript", "jsx", "mjs", "cjs", "ts", "typescript", "tsx", "mts", "cts":
            return Grammar(
                keywords: [
                    "abstract", "as", "async", "await", "break", "case", "catch", "class", "const", "continue", "debugger",
                    "declare", "default", "delete", "do", "else", "enum", "export", "extends", "finally", "for", "from",
                    "function", "get", "if", "implements", "import", "in", "instanceof", "interface", "keyof", "let",
                    "namespace", "new", "of", "private", "protected", "public", "readonly", "return", "satisfies", "set",
                    "static", "super", "switch", "this", "throw", "try", "type", "typeof", "var", "void", "while", "with",
                    "yield",
                ],
                literals: ["true", "false", "null", "undefined", "NaN", "Infinity"], quotes: [.doubleQuote, .singleQuote, .backtick],
                multilineQuotes: [.backtick], attributePrefixes: [.at], identifierExtras: [.underscore, .dollar])
        case "py", "python", "python3":
            return Grammar(
                keywords: [
                    "and", "as", "assert", "async", "await", "break", "class", "continue", "def", "del", "elif", "else",
                    "except", "finally", "for", "from", "global", "if", "import", "in", "is", "lambda", "match", "case",
                    "nonlocal", "not", "or", "pass", "raise", "return", "try", "while", "with", "yield", "self",
                ],
                literals: ["True", "False", "None"], lineComments: ["#"], blockComment: nil, tripleQuotes: true,
                attributePrefixes: [.at])
        case "rb", "ruby":
            return Grammar(
                keywords: [
                    "alias", "and", "begin", "break", "case", "class", "def", "defined?", "do", "else", "elsif", "end",
                    "ensure", "for", "if", "in", "module", "next", "not", "or", "redo", "require", "rescue", "retry",
                    "return", "self", "super", "then", "unless", "until", "when", "while", "yield", "attr_reader",
                    "attr_accessor",
                ],
                literals: ["true", "false", "nil"], lineComments: ["#"], blockComment: nil)
        case "go", "golang":
            return Grammar(
                keywords: [
                    "break", "case", "chan", "const", "continue", "default", "defer", "else", "fallthrough", "for", "func",
                    "go", "goto", "if", "import", "interface", "map", "package", "range", "return", "select", "struct",
                    "switch", "type", "var",
                ],
                literals: ["true", "false", "nil", "iota"], quotes: [.doubleQuote, .singleQuote, .backtick], multilineQuotes: [.backtick])
        case "rs", "rust":
            return Grammar(
                keywords: [
                    "as", "async", "await", "break", "const", "continue", "crate", "dyn", "else", "enum", "extern", "fn",
                    "for", "if", "impl", "in", "let", "loop", "match", "mod", "move", "mut", "pub", "ref", "return", "self",
                    "Self", "static", "struct", "super", "trait", "type", "unsafe", "use", "where", "while",
                ],
                literals: ["true", "false", "None", "Some", "Ok", "Err"], quotes: [.doubleQuote], attributePrefixes: [.hash])
        case "java", "kotlin", "kt", "kts", "scala", "groovy", "dart", "cs", "csharp", "c#":
            return Grammar(
                keywords: [
                    "abstract", "as", "async", "await", "break", "case", "catch", "class", "companion", "const", "continue",
                    "data", "default", "do", "else", "enum", "extends", "final", "finally", "for", "fun", "if", "implements",
                    "import", "in", "interface", "internal", "is", "lateinit", "namespace", "new", "object", "open",
                    "override", "package", "private", "protected", "public", "return", "sealed", "static", "super", "switch",
                    "this", "throw", "throws", "try", "using", "val", "var", "void", "when", "while", "yield", "record",
                    "struct", "readonly", "get", "set", "init", "suspend", "def", "trait", "with", "match",
                ],
                literals: ["true", "false", "null"], tripleQuotes: true, attributePrefixes: [.at])
        case "c", "h", "cpp", "c++", "cc", "cxx", "hpp", "hh", "objc", "objective-c", "objectivec", "m", "mm", "metal", "cuda":
            return Grammar(
                keywords: [
                    "auto", "break", "case", "catch", "char", "class", "const", "constexpr", "continue", "default", "delete",
                    "do", "double", "else", "enum", "explicit", "extern", "float", "for", "friend", "goto", "if", "inline",
                    "int", "long", "namespace", "new", "noexcept", "operator", "private", "protected", "public", "register",
                    "return", "short", "signed", "sizeof", "static", "struct", "switch", "template", "this", "throw", "try",
                    "typedef", "typename", "union", "unsigned", "using", "virtual", "void", "volatile", "while", "bool",
                    "self", "id", "instancetype", "nonatomic", "strong", "weak", "readonly", "property", "interface",
                    "implementation", "end", "import", "nullable", "nonnull",
                ],
                literals: ["true", "false", "NULL", "nullptr", "nil", "YES", "NO"], attributePrefixes: [.hash, .at])
        case "php":
            return Grammar(
                keywords: [
                    "abstract", "array", "as", "break", "case", "catch", "class", "const", "continue", "default", "do",
                    "echo", "else", "elseif", "extends", "final", "finally", "fn", "for", "foreach", "function", "if",
                    "implements", "include", "interface", "match", "namespace", "new", "private", "protected", "public",
                    "require", "return", "static", "switch", "throw", "trait", "try", "use", "while",
                ],
                literals: ["true", "false", "null"], lineComments: ["//", "#"], identifierExtras: [.underscore, .dollar])
        case "sh", "bash", "zsh", "shell", "console", "fish", "ksh", "shellscript", "terminal", "dockerfile", "docker", "makefile", "make":
            var grammar = Grammar(
                kind: .shell,
                keywords: [
                    "if", "then", "else", "elif", "fi", "for", "while", "until", "do", "done", "case", "esac", "in",
                    "function", "return", "export", "local", "readonly", "set", "unset", "source", "alias", "exit", "FROM",
                    "RUN", "CMD", "COPY", "ADD", "WORKDIR", "ENV", "ARG", "EXPOSE", "ENTRYPOINT", "USER", "VOLUME", "LABEL",
                ],
                literals: ["true", "false"], lineComments: ["#"], blockComment: nil)
            grammar.capitalizedTypes = false
            return grammar
        case "sql", "postgres", "postgresql", "mysql", "sqlite", "psql", "plsql":
            var grammar = Grammar(
                keywords: [
                    "select", "from", "where", "and", "or", "not", "insert", "into", "values", "update", "set", "delete",
                    "create", "table", "index", "view", "drop", "alter", "add", "column", "primary", "key", "foreign",
                    "references", "join", "left", "right", "inner", "outer", "on", "as", "group", "by", "order", "having",
                    "limit", "offset", "distinct", "union", "all", "case", "when", "then", "else", "end", "is", "in",
                    "exists", "between", "like", "default", "unique", "constraint", "begin", "commit", "rollback", "with",
                    "returning", "if", "integer", "int", "text", "varchar", "boolean", "timestamp", "serial", "bigint",
                ],
                literals: ["null", "true", "false"], lineComments: ["--"], quotes: [.singleQuote, .doubleQuote])
            grammar.caseInsensitive = true
            grammar.capitalizedTypes = false
            return grammar
        case "json", "jsonc", "json5", "geojson":
            return Grammar(kind: .json, literals: ["true", "false", "null"], quotes: [.doubleQuote], capitalizedTypes: false)
        case "yaml", "yml", "toml", "ini", "conf", "properties", "env":
            return Grammar(
                kind: .yaml, literals: ["true", "false", "null", "yes", "no", "on", "off", "~"], lineComments: ["#", ";"],
                blockComment: nil, capitalizedTypes: false)
        case "html", "xml", "svg", "xhtml", "plist", "vue", "svelte", "astro", "jsx-html":
            return Grammar(kind: .markup, lineComments: [], blockComment: ("<!--", "-->"), capitalizedTypes: false)
        case "css", "scss", "sass", "less":
            return Grammar(kind: .css, keywords: ["important"], quotes: [.doubleQuote, .singleQuote], attributePrefixes: [.at], capitalizedTypes: false)
        default:
            return nil
        }
    }
}

// MARK: - Scanner

nonisolated private struct Scanner {
    let units: [UInt16]
    let grammar: Grammar
    var index = 0

    init(units: [UInt16], grammar: Grammar) {
        self.units = units
        self.grammar = grammar
    }

    private func matches(_ text: String, at position: Int) -> Bool {
        var cursor = position
        for unit in text.utf16 {
            guard cursor < units.count, units[cursor] == unit else { return false }
            cursor += 1
        }
        return true
    }

    private func isIdentifierStart(_ unit: UInt16) -> Bool {
        (unit >= 0x41 && unit <= 0x5A) || (unit >= 0x61 && unit <= 0x7A) || grammar.identifierExtras.contains(unit) || unit > 0x7F
    }

    private func isIdentifierPart(_ unit: UInt16) -> Bool {
        isIdentifierStart(unit) || unit.isDigit
    }

    private func isLineStart(_ position: Int) -> Bool {
        var cursor = position - 1
        while cursor >= 0 {
            let unit = units[cursor]
            if unit == .newline { return true }
            if unit != .space && unit != .tab && unit != .hyphen { return false }
            cursor -= 1
        }
        return true
    }

    private func skipSpaces(from position: Int) -> Int {
        var cursor = position
        while cursor < units.count, units[cursor] == .space || units[cursor] == .tab { cursor += 1 }
        return cursor
    }

    mutating func scan(_ emit: (ChatSyntaxHighlighter.Token, NSRange) -> Void) {
        func token(_ kind: ChatSyntaxHighlighter.Token, _ start: Int, _ end: Int) {
            if end > start { emit(kind, NSRange(location: start, length: end - start)) }
        }
        var insideTag = false
        var expectsTagName = false
        while index < units.count {
            let start = index
            let unit = units[index]

            if let comment = grammar.blockComment, matches(comment.open, at: index) {
                index += comment.open.utf16.count
                while index < units.count, !matches(comment.close, at: index) { index += 1 }
                index = min(units.count, index + comment.close.utf16.count)
                token(.comment, start, index)
                continue
            }
            if grammar.lineComments.contains(where: { matches($0, at: index) }), index == 0 || !isIdentifierPart(units[index - 1]) {
                while index < units.count, units[index] != .newline { index += 1 }
                token(.comment, start, index)
                continue
            }

            switch grammar.kind {
            case .markup:
                if unit == .lessThan {
                    index += 1
                    if index < units.count, units[index] == .slash || units[index] == .question || units[index] == .exclamation { index += 1 }
                    token(.keyword, start, index)
                    insideTag = true
                    expectsTagName = true
                    continue
                }
                if insideTag, unit == .greaterThan || (unit == .slash && index + 1 < units.count && units[index + 1] == .greaterThan) {
                    index += unit == .slash ? 2 : 1
                    token(.keyword, start, index)
                    insideTag = false
                    continue
                }
                if unit == .ampersand {
                    while index < units.count, units[index] != .semicolon, !units[index].isWhitespace { index += 1 }
                    if index < units.count, units[index] == .semicolon { index += 1 }
                    token(.number, start, index)
                    continue
                }
                if !insideTag {
                    index += 1
                    continue
                }
            case .css:
                if unit == .hash, index + 1 < units.count, units[index + 1].isHexDigit {
                    index += 1
                    while index < units.count, isIdentifierPart(units[index]) { index += 1 }
                    token(.number, start, index)
                    continue
                }
            case .shell:
                if unit == .dollar {
                    index += 1
                    if index < units.count, units[index] == .openBrace {
                        while index < units.count, units[index] != .closeBrace, units[index] != .newline { index += 1 }
                        if index < units.count, units[index] == .closeBrace { index += 1 }
                    } else {
                        while index < units.count, isIdentifierPart(units[index]) { index += 1 }
                    }
                    token(.variable, start, index)
                    continue
                }
            case .code, .json, .yaml:
                break
            }

            if grammar.quotes.contains(unit) {
                index = endOfString(from: index, quote: unit)
                let next = skipSpaces(from: index)
                let isKey = (grammar.kind == .json || grammar.kind == .yaml) && next < units.count && units[next] == .colon
                token(isKey ? .property : .string, start, index)
                continue
            }

            if unit.isDigit || (unit == .period && index + 1 < units.count && units[index + 1].isDigit) {
                index += 1
                while index < units.count, isIdentifierPart(units[index]) || units[index] == .period {
                    if units[index] == .period, index + 1 < units.count, !units[index + 1].isDigit { break }
                    index += 1
                }
                token(.number, start, index)
                continue
            }

            if grammar.attributePrefixes.contains(unit), index + 1 < units.count, isIdentifierStart(units[index + 1]) {
                index += 1
                while index < units.count, isIdentifierPart(units[index]) { index += 1 }
                token(grammar.kind == .css ? .keyword : .attribute, start, index)
                continue
            }

            if isIdentifierStart(unit) {
                let allowsHyphen = grammar.kind == .markup || grammar.kind == .css || grammar.kind == .yaml
                while index < units.count, isIdentifierPart(units[index]) || (allowsHyphen && units[index] == .hyphen) {
                    index += 1
                }
                classifyWord(from: start, to: index, expectsTagName: &expectsTagName, emit: token)
                continue
            }
            index += 1
        }
    }

    private func endOfString(from start: Int, quote: UInt16) -> Int {
        let tripleQuote = String(repeating: Unicode.Scalar(quote).map(Character.init) ?? " ", count: 3)
        let triple = grammar.tripleQuotes && matches(tripleQuote, at: start)
        let multiline = triple || grammar.multilineQuotes.contains(quote)
        var cursor = start + (triple ? 3 : 1)
        while cursor < units.count {
            let current = units[cursor]
            if current == .backslash, grammar.kind != .shell || quote != .singleQuote {
                cursor += 2
                continue
            }
            if current == .newline, !multiline { return cursor }
            if current == quote {
                if !triple { return cursor + 1 }
                if matches(tripleQuote, at: cursor) { return cursor + 3 }
            }
            cursor += 1
        }
        return units.count
    }

    private func classifyWord(
        from start: Int, to end: Int, expectsTagName: inout Bool, emit token: (ChatSyntaxHighlighter.Token, Int, Int) -> Void
    ) {
        let word = String(utf16CodeUnits: Array(units[start..<end]), count: end - start)
        let lookup = grammar.caseInsensitive ? word.lowercased() : word
        let next = skipSpaces(from: end)
        let nextUnit = next < units.count ? units[next] : 0
        switch grammar.kind {
        case .markup:
            if expectsTagName {
                token(.keyword, start, end)
                expectsTagName = false
            } else if nextUnit == .equals {
                token(.attribute, start, end)
            }
        case .css:
            if grammar.keywords.contains(lookup) {
                token(.keyword, start, end)
            } else if nextUnit == .colon, isLineStart(start), !restOfLine(from: end).contains(.openBrace) {
                token(.property, start, end)
            }
        case .json, .yaml:
            if grammar.literals.contains(lookup) {
                token(.keyword, start, end)
            } else if grammar.kind == .yaml, nextUnit == .colon, isLineStart(start) {
                token(.property, start, end)
            }
        case .shell:
            if grammar.keywords.contains(lookup) {
                token(.keyword, start, end)
            } else if isCommandPosition(start) {
                token(.call, start, end)
            }
        case .code:
            if grammar.keywords.contains(lookup) || grammar.literals.contains(lookup) {
                token(.keyword, start, end)
            } else if nextUnit == .openParen {
                token(.call, start, end)
            } else if grammar.capitalizedTypes, units[start] >= 0x41, units[start] <= 0x5A {
                token(.type, start, end)
            }
        }
    }

    private func restOfLine(from position: Int) -> ArraySlice<UInt16> {
        units[position...].prefix { $0 != .newline }
    }

    /// The first word of a shell line (after an optional `$ ` prompt, a pipe or `&&`) is the command.
    private func isCommandPosition(_ position: Int) -> Bool {
        var cursor = position - 1
        while cursor >= 0, units[cursor] == .space || units[cursor] == .tab { cursor -= 1 }
        guard cursor >= 0 else { return true }
        let previous = units[cursor]
        if previous == .newline || previous == .pipe || previous == .semicolon || previous == .openParen { return true }
        if previous == .ampersand { return true }
        if previous == .dollar || previous == .percent {
            return cursor == 0 || units[cursor - 1] == .newline
        }
        return false
    }
}

nonisolated private extension UInt16 {
    static let tab: UInt16 = 0x09
    static let newline: UInt16 = 0x0A
    static let space: UInt16 = 0x20
    static let exclamation: UInt16 = 0x21
    static let doubleQuote: UInt16 = 0x22
    static let hash: UInt16 = 0x23
    static let dollar: UInt16 = 0x24
    static let ampersand: UInt16 = 0x26
    static let singleQuote: UInt16 = 0x27
    static let openParen: UInt16 = 0x28
    static let hyphen: UInt16 = 0x2D
    static let period: UInt16 = 0x2E
    static let slash: UInt16 = 0x2F
    static let colon: UInt16 = 0x3A
    static let semicolon: UInt16 = 0x3B
    static let lessThan: UInt16 = 0x3C
    static let equals: UInt16 = 0x3D
    static let greaterThan: UInt16 = 0x3E
    static let percent: UInt16 = 0x25
    static let question: UInt16 = 0x3F
    static let at: UInt16 = 0x40
    static let backslash: UInt16 = 0x5C
    static let underscore: UInt16 = 0x5F
    static let backtick: UInt16 = 0x60
    static let openBrace: UInt16 = 0x7B
    static let pipe: UInt16 = 0x7C
    static let closeBrace: UInt16 = 0x7D

    var isDigit: Bool { self >= 0x30 && self <= 0x39 }
    var isHexDigit: Bool { isDigit || (self >= 0x41 && self <= 0x46) || (self >= 0x61 && self <= 0x66) }
    var isWhitespace: Bool { self == .space || self == .tab || self == .newline || self == 0x0D }
}
