import Foundation

/// Byte ranges from an already validated, bounded JSONC array. Editing a known
/// rule must not rewrite entries a newer app understands, normalize strings, or
/// discard hand-written comments. All untouched bytes remain verbatim.
struct KeybindingsJSONCDocument {
    struct Entry {
        let value: Range<Int>
        let comma: Int?
    }
    private let bytes: [UInt8]
    private let open: Int
    private let close: Int
    let entries: [Entry]

    init(validated data: Data) throws {
        let bytes = Array(data)
        var cursor = bytes.starts(with: [0xef, 0xbb, 0xbf]) ? 3 : 0
        try Self.skipTrivia(bytes, cursor: &cursor, end: bytes.count)
        guard cursor < bytes.count, bytes[cursor] == 91 else { throw Self.failure() }
        let open = cursor
        cursor += 1
        var depth = 1, start: Int?, lastEnd = cursor, entries: [Entry] = []
        var close: Int?
        while cursor < bytes.count {
            try Self.skipTrivia(bytes, cursor: &cursor, end: bytes.count)
            guard cursor < bytes.count else { throw Self.failure() }
            let tokenStart = cursor, byte = bytes[cursor]
            try Self.skipToken(bytes, cursor: &cursor, end: bytes.count)
            if depth == 1, byte == 93 {
                if let start { entries.append(.init(value: start..<lastEnd, comma: nil)) }
                close = tokenStart
                break
            }
            if depth == 1, byte == 44 {
                guard let valueStart = start else { throw Self.failure() }
                entries.append(.init(value: valueStart..<lastEnd, comma: tokenStart))
                start = nil
                continue
            }
            if start == nil { start = tokenStart }
            lastEnd = cursor
            if byte == 91 || byte == 123 { depth += 1 }
            else if byte == 93 || byte == 125 { depth -= 1 }
            guard depth >= 1, depth <= 32 else { throw Self.failure() }
        }
        guard let close, entries.count <= 4_096 else { throw Self.failure() }
        try Self.skipTrivia(bytes, cursor: &cursor, end: bytes.count)
        guard cursor == bytes.count else { throw Self.failure() }
        self.bytes = bytes; self.open = open; self.close = close; self.entries = entries
    }

    /// Deleting syntax retains even comments inside the edited/removed object.
    /// Existing separators after retained values stay valid JSONC trailing commas.
    func editing(removing: Set<Int>, appending value: Data? = nil) throws -> Data {
        guard removing.allSatisfy({ entries.indices.contains($0) }),
              entries.count - removing.count + (value == nil ? 0 : 1) <= 4_096 else { throw Self.failure() }
        var edits: [(Range<Int>, [UInt8])] = []
        for index in removing.sorted() {
            let entry = entries[index]
            edits.append((entry.value, try trivia(in: entry.value)))
            if let comma = entry.comma { edits.append((comma..<(comma + 1), [])) }
        }
        if let value {
            if let last = entries.indices.last(where: { !removing.contains($0) }), entries[last].comma == nil {
                let end = entries[last].value.upperBound
                edits.append((end..<end, [44]))
            }
            edits.append((close..<close, [10] + Array(value) + [10]))
        }
        return try applying(edits)
    }

    func prepending(_ values: Data) throws -> Data {
        guard !values.isEmpty else { return Data(bytes) }
        let insertion = open + 1
        return try applying([(insertion..<insertion, [10] + Array(values) + (entries.isEmpty ? [10] : [44, 10]))])
    }

    private func trivia(in range: Range<Int>) throws -> [UInt8] {
        var cursor = range.lowerBound, result: [UInt8] = []
        while cursor < range.upperBound {
            let start = cursor
            try Self.skipTrivia(bytes, cursor: &cursor, end: range.upperBound)
            result.append(contentsOf: bytes[start..<cursor])
            if cursor < range.upperBound { try Self.skipToken(bytes, cursor: &cursor, end: range.upperBound) }
        }
        return result
    }

    private func applying(_ edits: [(Range<Int>, [UInt8])]) throws -> Data {
        var result = Data(), cursor = 0
        for (range, replacement) in edits.sorted(by: { $0.0.lowerBound < $1.0.lowerBound }) {
            guard range.lowerBound >= cursor, range.upperBound <= bytes.count else { throw Self.failure() }
            result.append(contentsOf: bytes[cursor..<range.lowerBound])
            result.append(contentsOf: replacement)
            cursor = range.upperBound
        }
        result.append(contentsOf: bytes[cursor...])
        guard result.count <= KeybindingsConfigStore.maximumFileBytes else { throw Self.failure() }
        return result
    }

    private static func skipTrivia(_ bytes: [UInt8], cursor: inout Int, end: Int) throws {
        while cursor < end {
            if [9, 10, 13, 32].contains(bytes[cursor]) { cursor += 1; continue }
            guard bytes[cursor] == 47, cursor + 1 < end else { return }
            if bytes[cursor + 1] == 47 {
                cursor += 2
                while cursor < end, bytes[cursor] != 10 { cursor += 1 }
            } else if bytes[cursor + 1] == 42 {
                cursor += 2
                while cursor + 1 < end, !(bytes[cursor] == 42 && bytes[cursor + 1] == 47) { cursor += 1 }
                guard cursor + 1 < end else { throw failure() }
                cursor += 2
            } else { return }
        }
    }

    private static func skipToken(_ bytes: [UInt8], cursor: inout Int, end: Int) throws {
        guard cursor < end else { throw failure() }
        if bytes[cursor] == 34 {
            cursor += 1
            while cursor < end {
                if bytes[cursor] == 34 { cursor += 1; return }
                if bytes[cursor] == 92 { cursor += 2 } else { cursor += 1 }
            }
            throw failure()
        }
        if [91, 93, 123, 125, 44, 58].contains(bytes[cursor]) { cursor += 1; return }
        let start = cursor
        while cursor < end, ![9, 10, 13, 32, 91, 93, 123, 125, 44, 58, 34].contains(bytes[cursor]) {
            if bytes[cursor] == 47, cursor + 1 < end, (bytes[cursor + 1] == 47 || bytes[cursor + 1] == 42) { break }
            cursor += 1
        }
        guard cursor > start else { throw failure() }
    }

    private static func failure() -> CoincideError {
        .init("The shortcuts file could not be edited without changing its other contents. The file was preserved; edit it directly or reload it.")
    }
}
