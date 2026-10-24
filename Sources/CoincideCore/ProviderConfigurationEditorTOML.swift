import Foundation

/// A conservative, source-preserving editor, not a replacement TOML parser.
/// Only standalone scalar and string-array assignments are editable. Unknown
/// syntax is retained; ambiguous table/key layouts fail closed before writing.
struct ProviderConfigurationTOML {
    struct Entry {
        let path: [String]
        let range: Range<String.Index>
        let value: String
    }
    struct Table {
        let path: [String]
        let range: Range<String.Index>
    }
    private(set) var source: String
    private var entries: [Entry] = []
    private var tables: [Table] = []
    var paths: [[String]] { entries.map(\.path) }

    init(data: Data) throws {
        guard let text = String(data: data, encoding: .utf8) else { throw Self.invalid() }
        source = text
        try scan()
    }

    func value(at path: [String]) -> Any? {
        guard let entry = entries.first(where: { $0.path == path }) else {
            // Inline-table parents cannot be modified by creating a competing
            // standalone table. Surface this as an advanced value instead.
            return entries.contains(where: { path.starts(with: $0.path) || $0.path.starts(with: path) }) || tables.contains(where: { $0.path.starts(with: path) }) ? NSNull() : nil
        }
        let value = entry.value.trimmingCharacters(in: .whitespacesAndNewlines)
        if value == "true" { return true }
        if value == "false" { return false }
        if let integer = Int(value) { return integer }
        if value.hasPrefix("\""), !value.hasPrefix("\"\"\""), let data = value.data(using: .utf8),
           let string = try? JSONDecoder().decode(String.self, from: data) { return string }
        if value.hasPrefix("'"), value.hasSuffix("'"), !value.hasPrefix("'''"), !value.dropFirst().dropLast().contains("'") {
            return String(value.dropFirst().dropLast())
        }
        if value.hasPrefix("["), let data = value.data(using: .utf8), let array = try? JSONDecoder().decode([String].self, from: data) { return array }
        return NSNull()
    }

    mutating func set(_ path: [String], value: Any?) throws {
        guard !path.isEmpty else { throw Self.invalid() }
        if let entry = entries.first(where: { $0.path == path }) {
            // Existing dotted assignments retain their complete path rather
            // than accidentally moving a child key to the current table.
            let table = tables.last(where: { $0.range.upperBound <= entry.range.lowerBound })?.path ?? []
            guard path.starts(with: table) else { throw Self.invalid() }
            let replacement = value == nil ? "" : try path.dropFirst(table.count).map(Self.key).joined(separator: ".") + " = " + Self.encode(value!) + "\n"
            source.replaceSubrange(entry.range, with: replacement)
        } else if let value {
            guard !entries.contains(where: { path.starts(with: $0.path) || $0.path.starts(with: path) }),
                  !tables.contains(where: { $0.path.starts(with: path) }) else { throw Self.invalid() }
            let parent = Array(path.dropLast())
            let assignment = try Self.key(path.last!) + " = " + Self.encode(value) + "\n"
            if parent.isEmpty {
                source.insert(contentsOf: assignment, at: source.startIndex)
            } else if let table = tables.first(where: { $0.path == parent }) {
                source.insert(contentsOf: (source[table.range].last == "\n" ? "" : "\n") + assignment, at: table.range.upperBound)
            } else {
                let prefix = source.isEmpty || source.hasSuffix("\n") ? "" : "\n"
                source += prefix + "\n[" + (try parent.map(Self.key).joined(separator: ".")) + "]\n" + assignment
            }
        }
        try scan()
    }

    private mutating func scan() throws {
        entries = []; tables = []
        var table: [String] = []
        var inArrayTable = false
        var structure = Structure()
        for range in try Self.statements(source) {
            let code = try Self.withoutComments(String(source[range])).trimmingCharacters(in: .whitespacesAndNewlines)
            if code.isEmpty { continue }
            if code.hasPrefix("[") {
                let array = code.hasPrefix("[[")
                guard code.hasSuffix(array ? "]]" : "]") else { throw Self.invalid() }
                let path = try Self.keyPath(String(code.dropFirst(array ? 2 : 1).dropLast(array ? 2 : 1)))
                inArrayTable = try structure.selectTable(path, array: array)
                if !inArrayTable {
                    guard !tables.contains(where: { $0.path == path }) else { throw Self.invalid() }
                    tables.append(.init(path: path, range: range))
                }
                table = path
                continue
            }
            guard let separator = try Self.assignmentSeparator(code) else { throw Self.invalid() }
            let key = try Self.keyPath(String(code[..<separator]))
            let path = table + key
            let value = String(code[code.index(after: separator)...]).trimmingCharacters(in: .whitespacesAndNewlines)
            try Self.validateValue(value)
            try structure.assign(key)
            if inArrayTable { continue }
            entries.append(.init(path: path, range: range, value: value))
        }
    }

    /// Track declaration identity separately from the source editor. Each array
    /// element has its own table namespace; ordinary and inline values cannot
    /// later become tables or be overwritten by dotted assignments.
    private struct Structure {
        enum Component: Hashable { case key(String), element(Int) }
        enum Kind { case value, implicitTable, table, array(Int) }
        var nodes: [[Component]: Kind] = [:]
        var context: [Component] = []

        mutating func selectTable(_ path: [String], array: Bool) throws -> Bool {
            guard !path.isEmpty, path.count <= 64 else { throw ProviderConfigurationTOML.invalid() }
            var target: [Component] = []
            for key in path.dropLast() {
                target.append(.key(key))
                switch nodes[target] {
                case nil: nodes[target] = .implicitTable
                case .value: throw ProviderConfigurationTOML.invalid()
                case .array(let index): target.append(.element(index))
                case .implicitTable, .table: break
                }
            }
            target.append(.key(path.last!))
            if array {
                let index: Int
                switch nodes[target] {
                case nil: index = 0
                case .array(let previous): index = previous + 1
                default: throw ProviderConfigurationTOML.invalid()
                }
                nodes[target] = .array(index); context = target + [.element(index)]
            } else {
                switch nodes[target] {
                case nil, .implicitTable: nodes[target] = .table
                default: throw ProviderConfigurationTOML.invalid()
                }
                context = target
            }
            return context.contains { if case .element = $0 { return true }; return false }
        }

        mutating func assign(_ path: [String]) throws {
            guard !path.isEmpty, path.count <= 64 else { throw ProviderConfigurationTOML.invalid() }
            var target = context
            for key in path.dropLast() {
                target.append(.key(key))
                switch nodes[target] {
                case nil: nodes[target] = .table
                case .implicitTable, .table: break
                default: throw ProviderConfigurationTOML.invalid()
                }
            }
            target.append(.key(path.last!))
            guard nodes[target] == nil else { throw ProviderConfigurationTOML.invalid() }
            nodes[target] = .value
        }
    }

    private static func validateValue(_ raw: String, depth: Int = 0) throws {
        let value = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty, depth < 64 else { throw invalid() }
        if value.hasPrefix("\"") || value.hasPrefix("'") { try validateString(value); return }
        if value.hasPrefix("[") || value.hasPrefix("{") {
            let array = value.hasPrefix("[")
            guard value.hasSuffix(array ? "]" : "}") else { throw invalid() }
            let inner = String(value.dropFirst().dropLast())
            if inner.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                guard array || !inner.contains("\n") else { throw invalid() }; return
            }
            var pieces: [String] = [], start = inner.startIndex, invalidInlineLine = false
            try walk(inner) { range, _, state in
                if !array, inner[range].contains("\n"), state.quote == nil { invalidInlineLine = true }
                if inner[range] == ",", state.quote == nil, state.brackets == 0, state.braces == 0 {
                    pieces.append(String(inner[start..<range.lowerBound])); start = range.upperBound
                }
            }
            guard !invalidInlineLine else { throw invalid() }
            pieces.append(String(inner[start...]))
            if array, pieces.last?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == true { pieces.removeLast() }
            var structure = Structure()
            for piece in pieces {
                if array { try validateValue(piece, depth: depth + 1) }
                else {
                    guard let separator = try assignmentSeparator(piece) else { throw invalid() }
                    try structure.assign(keyPath(String(piece[..<separator])))
                    try validateValue(String(piece[piece.index(after: separator)...]), depth: depth + 1)
                }
            }
            return
        }
        if ["true", "false", "inf", "+inf", "-inf", "nan", "+nan", "-nan"].contains(value) { return }
        let patterns = [
            #"^[+-]?(?:0|[1-9](?:_?[0-9])*)$"#,
            #"^0x[0-9a-fA-F](?:_?[0-9a-fA-F])*$"#,
            #"^0o[0-7](?:_?[0-7])*$"#,
            #"^0b[01](?:_?[01])*$"#,
            #"^[+-]?(?:0|[1-9](?:_?[0-9])*)(?:\.[0-9](?:_?[0-9])*(?:[eE][+-]?[0-9](?:_?[0-9])*)?|[eE][+-]?[0-9](?:_?[0-9])*)$"#,
            #"^[0-9]{4}-(?:0[1-9]|1[0-2])-(?:0[1-9]|[12][0-9]|3[01])(?:[Tt ](?:[01][0-9]|2[0-3]):[0-5][0-9]:[0-5][0-9](?:\.[0-9]+)?(?:[Zz]|[+-](?:[01][0-9]|2[0-3]):[0-5][0-9])?)?$"#,
            #"^(?:[01][0-9]|2[0-3]):[0-5][0-9]:[0-5][0-9](?:\.[0-9]+)?$"#
        ]
        guard patterns.contains(where: { value.range(of: $0, options: .regularExpression) != nil }) else { throw invalid() }
        if value.count >= 10, value[value.index(value.startIndex, offsetBy: 4)] == "-" {
            let date = String(value.prefix(10)).split(separator: "-").compactMap { Int($0) }
            guard date.count == 3 else { throw invalid() }
            let leapYear = date[0] % 4 == 0 && (date[0] % 100 != 0 || date[0] % 400 == 0)
            let lengths = [31, leapYear ? 29 : 28, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31]
            guard (1...12).contains(date[1]), (1...lengths[date[1] - 1]).contains(date[2]) else { throw invalid() }
        }
    }

    private static func validateString(_ value: String) throws {
        let scalars = Array(value.unicodeScalars)
        let quote = scalars[0].value
        let multiline = scalars.count >= 3 && scalars.prefix(3).allSatisfy { $0.value == quote }
        var index = multiline ? 3 : 1
        while index < scalars.count {
            let scalar = scalars[index].value
            if scalar == quote {
                var end = index + 1
                while end < scalars.count, scalars[end].value == quote { end += 1 }
                let count = end - index
                if !multiline || count >= 3 {
                    guard end == scalars.count, multiline ? count <= 5 : count == 1 else { throw invalid() }
                    return
                }
                index = end; continue
            }
            if scalar == 92, quote == 34 {
                index += 1
                guard index < scalars.count else { throw invalid() }
                let escape = scalars[index].value
                if [34, 92, 98, 116, 110, 102, 114].contains(escape) { index += 1; continue }
                if escape == 117 || escape == 85 {
                    let length = escape == 117 ? 4 : 8
                    guard index + length < scalars.count else { throw invalid() }
                    let digits = String(String.UnicodeScalarView(scalars[(index + 1)...(index + length)]))
                    guard digits.range(of: "^[0-9a-fA-F]+$", options: .regularExpression) != nil,
                          let number = UInt32(digits, radix: 16), Unicode.Scalar(number) != nil else { throw invalid() }
                    index += length + 1; continue
                }
                if multiline, [9, 10, 13, 32].contains(escape) {
                    var sawNewline = false
                    while index < scalars.count, [9, 10, 13, 32].contains(scalars[index].value) {
                        sawNewline = sawNewline || scalars[index].value == 10; index += 1
                    }
                    guard sawNewline else { throw invalid() }; continue
                }
                throw invalid()
            }
            guard scalar != 127, scalar >= 32 || scalar == 9 || (multiline && (scalar == 10 || scalar == 13)) else { throw invalid() }
            index += 1
        }
        throw invalid()
    }

    private static func encode(_ value: Any) throws -> String {
        if let number = value as? NSNumber { return CFGetTypeID(number) == CFBooleanGetTypeID() ? (number.boolValue ? "true" : "false") : number.stringValue }
        if let string = value as? String { return String(decoding: try JSONEncoder().encode(string), as: UTF8.self).replacingOccurrences(of: "\\/", with: "/") }
        if let strings = value as? [String] { return "[" + (try strings.map { try encode($0) }.joined(separator: ", ")) + "]" }
        throw invalid()
    }
    private static func key(_ value: String) throws -> String {
        if !value.isEmpty, value.utf8.allSatisfy({ (48...57).contains($0) || (65...90).contains($0) || (97...122).contains($0) || $0 == 95 || $0 == 45 }) { return value }
        return try encode(value)
    }
    private static func keyPath(_ raw: String) throws -> [String] {
        var result: [String] = []; var piece = ""; var quote: Character?; var escaped = false
        func decode(_ piece: String) throws -> String {
            let value = piece.trimmingCharacters(in: .whitespacesAndNewlines)
            if value.hasPrefix("\""), let data = value.data(using: .utf8), let decoded = try? JSONDecoder().decode(String.self, from: data) { return decoded }
            if value.hasPrefix("'"), value.hasSuffix("'"), value.count >= 2, !value.hasPrefix("'''") {
                try validateString(value)
                return String(value.dropFirst().dropLast())
            }
            guard !value.isEmpty, value.utf8.allSatisfy({ (48...57).contains($0) || (65...90).contains($0) || (97...122).contains($0) || $0 == 95 || $0 == 45 }) else { throw invalid() }
            return value
        }
        for character in raw {
            if let current = quote {
                piece.append(character)
                if escaped { escaped = false }
                else if current == "\"", character == "\\" { escaped = true }
                else if character == current { quote = nil }
            } else if character == "\"" || character == "'" { quote = character; piece.append(character) }
            else if character == "." { result.append(try decode(piece)); piece = "" }
            else { piece.append(character) }
        }
        guard quote == nil else { throw invalid() }
        result.append(try decode(piece)); return result
    }

    private static func assignmentSeparator(_ text: String) throws -> String.Index? {
        var quote: Character?; var escaped = false
        for index in text.indices {
            let character = text[index]
            if let current = quote {
                if escaped { escaped = false }
                else if current == "\"", character == "\\" { escaped = true }
                else if character == current { quote = nil }
            } else if character == "\"" || character == "'" { quote = character }
            else if character == "=" { return index }
        }
        return nil
    }

    private struct Lexer {
        var quote: Character?
        var multiline = false
        var escaped = false
        var comment = false
        var brackets = 0
        var braces = 0
    }
    private static func walk(_ text: String, visit: (Range<String.Index>, Bool, Lexer) -> Void) throws {
        var state = Lexer(); var index = text.startIndex
        while index < text.endIndex {
            let start = index; let c = text[index]
            guard !c.unicodeScalars.contains(where: { $0.value < 32 && ![9, 10, 13].contains($0.value) || $0.value == 127 }) else { throw invalid() }
            let isComment = state.comment || (state.quote == nil && c == "#")
            if state.comment {
                if c == "\n" { state.comment = false }
            } else if let quote = state.quote {
                if state.escaped { state.escaped = false }
                else if quote == "\"", c == "\\" { state.escaped = true }
                else if c == quote {
                    let count = state.multiline ? 3 : 1
                    if text[index...].hasPrefix(String(repeating: String(quote), count: count)) {
                        index = text.index(index, offsetBy: count - 1); state.quote = nil; state.multiline = false
                    }
                } else if c == "\n", !state.multiline { throw invalid() }
            } else if c == "#" { state.comment = true }
            else if c == "\"" || c == "'" {
                state.quote = c; state.multiline = text[index...].hasPrefix(String(repeating: String(c), count: 3))
                if state.multiline { index = text.index(index, offsetBy: 2) }
            } else if c == "[" { state.brackets += 1 }
            else if c == "]" { state.brackets -= 1 }
            else if c == "{" { state.braces += 1 }
            else if c == "}" { state.braces -= 1 }
            guard (0...64).contains(state.brackets), (0...64).contains(state.braces) else { throw invalid() }
            index = text.index(after: index)
            visit(start..<index, isComment && c != "\n", state)
        }
        guard state.quote == nil, state.brackets == 0, state.braces == 0 else { throw invalid() }
    }
    private static func statements(_ source: String) throws -> [Range<String.Index>] {
        var ranges: [Range<String.Index>] = []; var start = source.startIndex
        try walk(source) { range, _, state in
            if source[range].last == "\n", state.quote == nil, state.brackets == 0, state.braces == 0 {
                ranges.append(start..<range.upperBound); start = range.upperBound
            }
        }
        if start < source.endIndex { ranges.append(start..<source.endIndex) }
        return ranges
    }
    private static func withoutComments(_ source: String) throws -> String {
        var result = ""
        try walk(source) { range, comment, _ in if !comment { result.append(contentsOf: source[range]) } }
        return result
    }
    private static func invalid() -> CoincideError { .init("This TOML source has syntax or an advanced table layout that the structured editor cannot safely change. Edit it in the provider's source file.") }
}
