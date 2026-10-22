import Foundation

/// A bounded lexer keeps comment markers, escaped quotes and trailing-comma text inside
/// strings intact. Replacing removed bytes with whitespace also keeps tokens separated.
enum ProjectConfigurationJSON {
    static func normalized(_ contents: String) throws -> Data {
        var bytes = Array(contents.utf8), index = 0, inString = false, escaped = false, depth = 0
        while index < bytes.count {
            if index & 4_095 == 0 { try Task.checkCancellation() }
            let byte = bytes[index]
            if inString {
                if escaped { escaped = false }
                else if byte == 0x5c { escaped = true }
                else if byte == 0x22 { inString = false }
                index += 1; continue
            }
            if byte == 0x22 { inString = true; index += 1; continue }
            if byte == 0x2f, index + 1 < bytes.count {
                if bytes[index + 1] == 0x2f {
                    bytes[index] = 0x20; bytes[index + 1] = 0x20; index += 2
                    while index < bytes.count, bytes[index] != 0x0a, bytes[index] != 0x0d { bytes[index] = 0x20; index += 1 }
                    continue
                }
                if bytes[index + 1] == 0x2a {
                    bytes[index] = 0x20; bytes[index + 1] = 0x20; index += 2
                    var closed = false
                    while index < bytes.count {
                        if bytes[index] == 0x2a, index + 1 < bytes.count, bytes[index + 1] == 0x2f {
                            bytes[index] = 0x20; bytes[index + 1] = 0x20; index += 2; closed = true; break
                        }
                        if bytes[index] != 0x0a, bytes[index] != 0x0d { bytes[index] = 0x20 }; index += 1
                    }
                    guard closed else { throw ProjectConfigurationError(.invalidConfiguration) }; continue
                }
            }
            if byte == 0x7b || byte == 0x5b { depth += 1; guard depth <= 64 else { throw ProjectConfigurationError(.invalidConfiguration) } }
            if byte == 0x7d || byte == 0x5d { depth -= 1; guard depth >= 0 else { throw ProjectConfigurationError(.invalidConfiguration) } }
            index += 1
        }
        guard !inString, depth == 0 else { throw ProjectConfigurationError(.invalidConfiguration) }
        // Foundation's JSON decoder accepts some malformed trailing/repeated comma
        // forms. Validate JSONC grammar ourselves before removing one trailing
        // comma; otherwise [value,,] can become an accepted [value,].
        var syntax = Syntax(bytes: bytes)
        try syntax.document()
        index = 0; inString = false; escaped = false
        while index < bytes.count {
            let byte = bytes[index]
            if inString {
                if escaped { escaped = false }
                else if byte == 0x5c { escaped = true }
                else if byte == 0x22 { inString = false }
            } else if byte == 0x22 { inString = true }
            else if byte == 0x2c {
                var next = index + 1
                while next < bytes.count, [0x20, 0x09, 0x0a, 0x0d].contains(bytes[next]) { next += 1 }
                if next < bytes.count, bytes[next] == 0x7d || bytes[next] == 0x5d { bytes[index] = 0x20 }
            }
            index += 1
        }
        return Data(bytes)
    }

    private struct Syntax {
        let bytes: [UInt8]
        var index = 0
        mutating func document() throws {
            try value(depth: 0); whitespace()
            guard index == bytes.count else { throw ProjectConfigurationError(.invalidConfiguration) }
        }
        mutating func value(depth: Int) throws {
            try Task.checkCancellation(); whitespace()
            guard index < bytes.count, depth <= 64 else { throw ProjectConfigurationError(.invalidConfiguration) }
            switch bytes[index] {
            case 0x7b: try object(depth: depth + 1)
            case 0x5b: try array(depth: depth + 1)
            case 0x22: try string()
            case 0x74: try literal([0x74, 0x72, 0x75, 0x65])
            case 0x66: try literal([0x66, 0x61, 0x6c, 0x73, 0x65])
            case 0x6e: try literal([0x6e, 0x75, 0x6c, 0x6c])
            case 0x2d, 0x30...0x39: try number()
            default: throw ProjectConfigurationError(.invalidConfiguration)
            }
        }
        mutating func object(depth: Int) throws {
            index += 1; whitespace()
            if take(0x7d) { return }
            while true {
                try string(); whitespace()
                guard take(0x3a) else { throw ProjectConfigurationError(.invalidConfiguration) }
                try value(depth: depth); whitespace()
                if take(0x7d) { return }
                guard take(0x2c) else { throw ProjectConfigurationError(.invalidConfiguration) }
                whitespace()
                if take(0x7d) { return } // One trailing comma is permitted by T3 JSONC.
            }
        }
        mutating func array(depth: Int) throws {
            index += 1; whitespace()
            if take(0x5d) { return }
            while true {
                try value(depth: depth); whitespace()
                if take(0x5d) { return }
                guard take(0x2c) else { throw ProjectConfigurationError(.invalidConfiguration) }
                whitespace()
                if take(0x5d) { return }
            }
        }
        mutating func string() throws {
            guard take(0x22) else { throw ProjectConfigurationError(.invalidConfiguration) }
            while index < bytes.count {
                if index & 4_095 == 0 { try Task.checkCancellation() }
                let byte = bytes[index]; index += 1
                if byte == 0x22 { return }
                guard byte >= 0x20 else { throw ProjectConfigurationError(.invalidConfiguration) }
                if byte == 0x5c {
                    guard index < bytes.count else { throw ProjectConfigurationError(.invalidConfiguration) }
                    let escaped = bytes[index]; index += 1
                    if escaped == 0x75 {
                        guard bytes.count - index >= 4, bytes[index..<(index + 4)].allSatisfy({ (0x30...0x39).contains($0) || (0x41...0x46).contains($0) || (0x61...0x66).contains($0) }) else {
                            throw ProjectConfigurationError(.invalidConfiguration)
                        }
                        index += 4
                    } else if ![0x22, 0x5c, 0x2f, 0x62, 0x66, 0x6e, 0x72, 0x74].contains(escaped) {
                        throw ProjectConfigurationError(.invalidConfiguration)
                    }
                }
            }
            throw ProjectConfigurationError(.invalidConfiguration)
        }
        mutating func number() throws {
            _ = take(0x2d)
            if !take(0x30) {
                guard index < bytes.count, (0x31...0x39).contains(bytes[index]) else { throw ProjectConfigurationError(.invalidConfiguration) }
                digits()
            }
            if take(0x2e) {
                guard index < bytes.count, (0x30...0x39).contains(bytes[index]) else { throw ProjectConfigurationError(.invalidConfiguration) }
                digits()
            }
            if take(0x65) || take(0x45) {
                if !take(0x2b) { _ = take(0x2d) }
                guard index < bytes.count, (0x30...0x39).contains(bytes[index]) else { throw ProjectConfigurationError(.invalidConfiguration) }
                digits()
            }
        }
        mutating func digits() { while index < bytes.count, (0x30...0x39).contains(bytes[index]) { index += 1 } }
        mutating func literal(_ value: [UInt8]) throws {
            guard bytes.count - index >= value.count, bytes[index..<(index + value.count)].elementsEqual(value) else { throw ProjectConfigurationError(.invalidConfiguration) }
            index += value.count
        }
        mutating func whitespace() { while index < bytes.count, [0x20, 0x09, 0x0a, 0x0d].contains(bytes[index]) { index += 1 } }
        mutating func take(_ byte: UInt8) -> Bool {
            guard index < bytes.count, bytes[index] == byte else { return false }; index += 1; return true
        }
    }
}
