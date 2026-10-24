import Foundation

/// Foundation accepts repeated JSON object keys, then silently loses all but
/// one value on rewrite. Refuse those files, including unknown nested sections.
enum ProviderConfigurationJSON {
    static func validateUniqueKeys(_ data: Data) throws {
        var parser = Parser(bytes: Array(data))
        try parser.value(depth: 0)
    }
    private struct Parser {
        let bytes: [UInt8]
        var offset = 0
        mutating func whitespace() { while offset < bytes.count && [9, 10, 13, 32].contains(bytes[offset]) { offset += 1 } }
        mutating func string() throws -> String {
            whitespace()
            let start = offset
            guard offset < bytes.count, bytes[offset] == 34 else { throw invalid() }
            offset += 1
            while offset < bytes.count {
                if bytes[offset] == 92 { offset += 2; continue }
                if bytes[offset] == 34 {
                    offset += 1
                    guard let value = try? JSONDecoder().decode(String.self, from: Data(bytes[start..<offset])) else { throw invalid() }
                    return value
                }
                offset += 1
            }
            throw invalid()
        }
        mutating func value(depth: Int) throws {
            whitespace()
            guard depth < 100, offset < bytes.count else { throw invalid() }
            switch bytes[offset] {
            case 123:
                offset += 1; whitespace()
                var keys = Set<String>()
                if offset < bytes.count, bytes[offset] == 125 { offset += 1; return }
                while offset < bytes.count {
                    guard keys.insert(try string()).inserted else { throw invalid() }
                    whitespace()
                    guard offset < bytes.count, bytes[offset] == 58 else { throw invalid() }
                    offset += 1; try value(depth: depth + 1); whitespace()
                    guard offset < bytes.count else { throw invalid() }
                    if bytes[offset] == 125 { offset += 1; return }
                    guard bytes[offset] == 44 else { throw invalid() }
                    offset += 1
                }
                throw invalid()
            case 91:
                offset += 1; whitespace()
                if offset < bytes.count, bytes[offset] == 93 { offset += 1; return }
                while offset < bytes.count {
                    try value(depth: depth + 1); whitespace()
                    guard offset < bytes.count else { throw invalid() }
                    if bytes[offset] == 93 { offset += 1; return }
                    guard bytes[offset] == 44 else { throw invalid() }
                    offset += 1
                }
                throw invalid()
            case 34: _ = try string()
            default:
                let start = offset
                while offset < bytes.count, ![9, 10, 13, 32, 44, 93, 125].contains(bytes[offset]) { offset += 1 }
                guard offset > start else { throw invalid() }
            }
        }
        func invalid() -> CoincideError { .init("The provider settings have duplicate keys or a structure that cannot be rewritten safely.") }
    }
}
