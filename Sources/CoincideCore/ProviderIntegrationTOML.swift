import Foundation

/// A bounded structural reader for table metadata, not a general TOML decoder.
/// Values remain opaque except for explicit Boolean fields. Quoted/multiline
/// strings and nested arrays are consumed as one statement so their contents
/// cannot masquerade as integration table headers.
enum ProviderIntegrationTOML {
    struct Table { var path: [String]; var values: [String: String] = [:] }

    static func tables(_ text: String) throws -> [Table] {
        guard text.utf8.count <= 1_048_576 else { throw malformed() }
        let input = Array(text)
        var statements: [String] = [], statement = "", index = 0, depth = 0
        var quote: Character?, triple = false, escaped = false, comment = false
        while index < input.count {
            let c = input[index]
            if comment {
                if c == "\n" { comment = false; if depth == 0 { flush(&statement, into: &statements) } else { statement.append(c) } }
                index += 1; continue
            }
            if let q = quote {
                statement.append(c)
                if escaped { escaped = false; index += 1; continue }
                if q == "\"", c == "\\" { escaped = true; index += 1; continue }
                if c == q {
                    if !triple { quote = nil }
                    else if index + 2 < input.count, input[index + 1] == q, input[index + 2] == q {
                        statement.append(q); statement.append(q); index += 2; quote = nil; triple = false
                    }
                } else if !triple, c == "\n" { throw malformed() }
                index += 1; continue
            }
            switch c {
            case "#": comment = true
            case "\"", "'":
                quote = c; statement.append(c)
                if index + 2 < input.count, input[index + 1] == c, input[index + 2] == c {
                    statement.append(c); statement.append(c); index += 2; triple = true
                }
            case "[", "{": depth += 1; statement.append(c)
            case "]", "}": depth -= 1; guard depth >= 0 else { throw malformed() }; statement.append(c)
            case "\n": if depth == 0 { flush(&statement, into: &statements) } else { statement.append(c) }
            default: statement.append(c)
            }
            guard depth <= 64, statements.count <= 20_000 else { throw malformed() }
            index += 1
        }
        guard quote == nil, depth == 0 else { throw malformed() }
        flush(&statement, into: &statements)
        var tables = [Table(path: [])], current: [String] = []
        for statement in statements {
            if statement.hasPrefix("[") {
                let count = statement.hasPrefix("[[") ? 2 : 1
                guard statement.hasSuffix(String(repeating: "]", count: count)) else { throw malformed() }
                current = try keys(String(statement.dropFirst(count).dropLast(count)))
                if !tables.contains(where: { $0.path == current }) { tables.append(Table(path: current)) }
                continue
            }
            guard let separator = assignment(statement) else { throw malformed() }
            let path = current + (try keys(String(statement[..<separator])))
            guard let key = path.last else { throw malformed() }
            let tablePath = Array(path.dropLast())
            let value = String(statement[statement.index(after: separator)...]).trimmingCharacters(in: .whitespacesAndNewlines)
            guard !value.isEmpty else { throw malformed() }
            if let i = tables.firstIndex(where: { $0.path == tablePath }) { tables[i].values[key] = value }
            else { tables.append(Table(path: tablePath, values: [key: value])) }
        }
        return tables
    }

    static func string(_ raw: String?) -> String? {
        guard let raw else { return nil }
        if raw.hasPrefix("'"), raw.hasSuffix("'"), !raw.hasPrefix("'''") { return String(raw.dropFirst().dropLast()) }
        guard raw.hasPrefix("\""), !raw.hasPrefix("\"\"\"") else { return nil }
        return try? JSONDecoder().decode(String.self, from: Data(raw.utf8))
    }

    private static func flush(_ text: inout String, into statements: inout [String]) {
        let value = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if !value.isEmpty { statements.append(value) }; text = ""
    }
    private static func assignment(_ text: String) -> String.Index? {
        var quote: Character?, escaped = false
        for index in text.indices {
            let c = text[index]
            if let q = quote {
                if escaped { escaped = false } else if q == "\"", c == "\\" { escaped = true } else if c == q { quote = nil }
            } else if c == "\"" || c == "'" { quote = c }
            else if c == "=" { return index }
        }
        return nil
    }
    private static func keys(_ text: String) throws -> [String] {
        var components: [String] = [], current = "", quote: Character?, escaped = false
        for c in text {
            if let q = quote {
                current.append(c)
                if escaped { escaped = false } else if q == "\"", c == "\\" { escaped = true } else if c == q { quote = nil }
            } else if c == "\"" || c == "'" { quote = c; current.append(c) }
            else if c == "." { components.append(current); current = "" }
            else { current.append(c) }
        }
        guard quote == nil else { throw malformed() }; components.append(current)
        return try components.map {
            let raw = $0.trimmingCharacters(in: .whitespacesAndNewlines)
            if let decoded = string(raw), !decoded.isEmpty { return decoded }
            guard !raw.isEmpty, raw.range(of: "^[A-Za-z0-9_-]+$", options: .regularExpression) != nil else { throw malformed() }
            return raw
        }
    }
    private static func malformed() -> CoincideError { .init("The provider configuration could not be inspected. Review it in the provider CLI.") }
}
