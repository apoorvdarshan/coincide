import Foundation

/// Finds lexical boundaries for supported quoted/heredoc Codex command displays.
/// Unsupported or malformed source stays literal; parsed text is never executed.
enum TranscriptCommandParser {
    struct Value { let command: String?; let output: String? }
    private enum Frame: Equatable { case single, double, backtick, paren, parameter, brace }
    private struct Here { let delimiter: [UInt8]; let stripTabs: Bool }
    static let maximumBytes = 2 * 1_048_576
    static func parse(_ text: String) -> Value {
        func literal() -> Value { .init(command: nil, output: text.isEmpty ? nil : text) }
        guard text.hasPrefix("$ "), text.utf8.count <= maximumBytes else { return literal() }
        let bytes = Array(text.utf8), end = bytes.count
        var index = 2, frames: [Frame] = [], pending: [Here] = [], continued = false, lines = 0
        func result(_ boundary: Int, after: Int) -> Value {
            .init(command: String(decoding: bytes[2..<boundary], as: UTF8.self),
                  output: after < end ? String(decoding: bytes[after..<end], as: UTF8.self) : nil)
        }
        // Compound shell keywords need a real shell grammar. Keep their full
        // source literal rather than treating the first body line as output.
        let first = bytes[2...].prefix { $0 != 32 && $0 != 9 && $0 != 10 && $0 != 59 }
        let word = String(decoding: first, as: UTF8.self)
        if ["if", "for", "while", "until", "case", "select", "function"].contains(word) { return literal() }
        func hereWord(_ start: Int) -> (Here, Int)? {
            var cursor = start, strip = false
            if cursor < end, bytes[cursor] == 45 { strip = true; cursor += 1 }
            while cursor < end, bytes[cursor] == 32 || bytes[cursor] == 9 { cursor += 1 }
            var token: [UInt8] = [], quote: UInt8?
            while cursor < end {
                let byte = bytes[cursor]
                if byte == 10 || byte == 13 { break }
                if quote == nil, [UInt8(32), 9, 59, 124, 38, 60, 62, 40, 41].contains(byte) { break }
                if byte == 92, quote != 39 {
                    cursor += 1; guard cursor < end, bytes[cursor] != 10 else { return nil }
                    token.append(bytes[cursor]); cursor += 1; continue
                }
                if byte == 39 || byte == 34 {
                    if quote == byte { quote = nil }
                    else if quote == nil { quote = byte }
                    else { token.append(byte) }
                } else { token.append(byte) }
                guard token.count <= 256 else { return nil }; cursor += 1
            }
            guard quote == nil, !token.isEmpty else { return nil }
            return (.init(delimiter: token, stripTabs: strip), cursor)
        }
        while index < end {
            guard frames.count <= 64 else { return literal() }
            let byte = bytes[index]
            if byte == 10 {
                lines += 1; guard lines <= 20_000 else { return literal() }
                if !pending.isEmpty {
                    var cursor = index + 1
                    for (hereIndex, here) in pending.enumerated() {
                        var found = false
                        while cursor <= end {
                            let start = cursor
                            while cursor < end, bytes[cursor] != 10 { cursor += 1 }
                            var contentStart = start
                            if here.stripTabs { while contentStart < cursor, bytes[contentStart] == 9 { contentStart += 1 } }
                            lines += 1; guard lines <= 20_000 else { return literal() }
                            let delimiter = bytes[contentStart..<cursor].elementsEqual(here.delimiter)
                            let after = cursor < end ? cursor + 1 : cursor
                            if delimiter {
                                found = true
                                if hereIndex == pending.count - 1, frames.isEmpty, !continued { return result(cursor, after: after) }
                                cursor = after; break
                            }
                            guard cursor < end else { break }; cursor = after
                        }
                        guard found else { return literal() }
                    }
                    pending.removeAll(); index = cursor; continue
                }
                if frames.isEmpty, !continued { return result(index, after: index + 1) }
                index += 1; continue
            }
            if frames.last == .single {
                if byte == 39 { frames.removeLast() }; index += 1; continue
            }
            if byte == 92 {
                guard index + 1 < end else { return literal() }
                index += 2; continue
            }
            if byte == 39, frames.last != .double, frames.last != .backtick {
                frames.append(.single); index += 1; continue
            }
            if byte == 34, frames.last != .backtick {
                if frames.last == .double { frames.removeLast() } else { frames.append(.double) }
                index += 1; continue
            }
            if byte == 96 {
                if frames.last == .backtick { frames.removeLast() } else { frames.append(.backtick) }
                index += 1; continue
            }
            if byte == 36, index + 1 < end, bytes[index + 1] == 40 || bytes[index + 1] == 123 {
                frames.append(bytes[index + 1] == 40 ? .paren : .parameter); index += 2; continue
            }
            if frames.last == .double || frames.last == .backtick { index += 1; continue }
            if byte == 60, index + 2 < end, bytes[index + 1] == 60, bytes[index + 2] == 60 {
                index += 3; continued = false; continue
            }
            if byte == 60, index + 1 < end, bytes[index + 1] == 60 {
                guard pending.count < 16, let (here, after) = hereWord(index + 2) else { return literal() }
                pending.append(here); index = after; continue
            }
            if byte == 35, index == 2 || [UInt8(32), 9, 10, 59, 124, 38, 40, 41].contains(bytes[index - 1]) {
                while index < end, bytes[index] != 10 { index += 1 }; continue
            }
            switch byte {
            case 40: frames.append(.paren)
            case 41: guard frames.last == .paren else { return literal() }; frames.removeLast()
            case 123: frames.append(.brace)
            case 125: guard frames.last == .parameter || frames.last == .brace else { return literal() }; frames.removeLast()
            case 124: continued = true
            case 38:
                if index + 1 < end, bytes[index + 1] == 38 { continued = true; index += 1 }
                else { continued = false }
            case 32, 9, 13: break
            default: continued = false
            }
            guard frames.count <= 64 else { return literal() }
            index += 1
        }
        guard frames.isEmpty, pending.isEmpty, !continued else { return literal() }
        return result(end, after: end)
    }
}
