import AppKit
import SwiftUI

public struct CodeToken: Sendable, Equatable {
    /// UTF-16 offsets, matching `NSString` and `NSTextView` ranges.
    public var range: Range<Int>
    public var kind: CodeTokenKind
    public var nsRange: NSRange { NSRange(location: range.lowerBound, length: range.count) }
}

/// Native single-pass lexical highlighter over ~45 languages. Unknown languages, inputs
/// over 64 KB and inputs over 4,000 lines keep their original, uncolored text.
public enum CodeHighlight {
    static let maximumBytes = 65_536, maximumLines = 4_000

    /// A display name such as "Swift" or "C++" for a fence language or alias.
    public static func label(for language: String) -> String? { CodeLanguages.language(language)?.label }

    public static func tokens(_ source: String, language: String) -> [CodeToken] {
        guard source.utf8.count <= maximumBytes, let resolved = CodeLanguages.language(language) else { return [] }
        let units = Array(source.utf16)
        var lines = 1
        for unit in units where unit == 10 { lines += 1; if lines > maximumLines { return [] } }
        var scanner = CodeScanner(u: units)
        scanner.scan(resolved, 0..<units.count)
        return scanner.tokens
    }

    /// AppKit text with appearance-resolving token colors.
    public static func attributed(_ source: String, language: String) -> NSAttributedString {
        let result = NSMutableAttributedString(string: source, attributes: [.font: NSFont.monospacedSystemFont(ofSize: 13, weight: .regular), .foregroundColor: NSColor.labelColor])
        for token in tokens(source, language: language) { result.addAttribute(.foregroundColor, value: CodeTheme.dynamicColor(token.kind), range: token.nsRange) }
        return result
    }

    /// SwiftUI text colored for an explicit appearance, so offscreen and per-view color
    /// schemes resolve the same palette. Colors are applied over ranges of one string
    /// instead of concatenating a piece per token.
    public static func attributedString(_ source: String, language: String, dark: Bool, increasedContrast: Bool = false) -> AttributedString {
        let found = tokens(source, language: language)
        var result = AttributedString(source)
        guard !found.isEmpty else { return result }
        let utf16 = source.utf16
        var colors: [CodeTokenKind: Color] = [:], cursor = utf16.startIndex, offset = 0
        for token in found {
            guard let lower = utf16.index(cursor, offsetBy: token.range.lowerBound - offset, limitedBy: utf16.endIndex),
                  let upper = utf16.index(lower, offsetBy: token.range.count, limitedBy: utf16.endIndex) else { break }
            cursor = upper; offset = token.range.upperBound
            guard let start = AttributedString.Index(lower, within: result), let end = AttributedString.Index(upper, within: result), start < end else { continue }
            let color = colors[token.kind] ?? Color(nsColor: CodeTheme.color(token.kind, dark: dark, increasedContrast: increasedContrast))
            colors[token.kind] = color
            result[start..<end].foregroundColor = color
        }
        return result
    }
}

struct CodeScanner {
    let u: [UInt16]
    var tokens: [CodeToken] = []

    private static let valueLanguage = CodeLanguage(id: "value", label: "Value", multilineStrings: ["\"\"\"", "'''"], constants: ["true", "false", "yes", "no", "on", "off", "null"])

    mutating func scan(_ language: CodeLanguage, _ range: Range<Int>) {
        switch language.mode {
        case .code: code(language, range)
        case .markup: markup(range)
        case .css: css(language, range)
        case .diff: diff(range)
        case .ini: ini(range)
        case .markdown: markdown(range)
        }
    }

    // MARK: Helpers

    private mutating func add(_ kind: CodeTokenKind, _ range: Range<Int>) {
        guard !range.isEmpty else { return }
        if let last = tokens.last, last.range.upperBound > range.lowerBound { return }
        tokens.append(.init(range: range, kind: kind))
    }
    private func matches(_ pattern: [UInt16], at index: Int, end: Int) -> Bool {
        guard index + pattern.count <= end, !pattern.isEmpty else { return false }
        for offset in pattern.indices where u[index + offset] != pattern[offset] { return false }
        return true
    }
    private func find(_ pattern: [UInt16], from start: Int, end: Int) -> Int? {
        var index = start
        while index + pattern.count <= end { if matches(pattern, at: index, end: end) { return index }; index += 1 }
        return nil
    }
    private func lineEnd(_ start: Int, _ end: Int) -> Int {
        var index = start
        while index < end, u[index] != 10 { index += 1 }
        return index
    }
    /// The index after `closer`, skipping backslash escapes.
    private func closing(_ closer: [UInt16], from start: Int, end: Int) -> Int? {
        var index = start
        while index < end {
            if u[index] == 92 { index += 2; continue }
            if matches(closer, at: index, end: end) { return index + closer.count }
            index += 1
        }
        return nil
    }
    static func isIdentStart(_ c: UInt16) -> Bool { (c >= 65 && c <= 90) || (c >= 97 && c <= 122) || c == 95 || c >= 0x80 }
    static func isDigit(_ c: UInt16) -> Bool { c >= 48 && c <= 57 }
    static func isSpace(_ c: UInt16) -> Bool { c == 32 || c == 9 || c == 13 || c == 10 }
    private static func isHex(_ c: UInt16) -> Bool { isDigit(c) || (c >= 65 && c <= 70) || (c >= 97 && c <= 102) }

    private func numberEnd(_ start: Int, _ end: Int, percent: Bool = false) -> Int {
        var index = start
        if u[index] == 48, index + 1 < end, [120, 88, 98, 66, 111, 79].contains(u[index + 1]) {
            index += 2
            while index < end, Self.isHex(u[index]) || u[index] == 95 { index += 1 }
            return index
        }
        while index < end, Self.isDigit(u[index]) || u[index] == 95 { index += 1 }
        if index + 1 < end, u[index] == 46, Self.isDigit(u[index + 1]) {
            index += 1
            while index < end, Self.isDigit(u[index]) || u[index] == 95 { index += 1 }
        }
        if index + 1 < end, u[index] == 101 || u[index] == 69,
           Self.isDigit(u[index + 1]) || ((u[index + 1] == 43 || u[index + 1] == 45) && index + 2 < end && Self.isDigit(u[index + 2])) {
            index += 2
            while index < end, Self.isDigit(u[index]) { index += 1 }
        }
        while index < end, (u[index] < 0x80 && Self.isIdentStart(u[index])) || Self.isDigit(u[index]) || (percent && u[index] == 37) { index += 1 }
        return index
    }
    private func charLiteralEnd(_ quote: Int, _ end: Int) -> Int? {
        var index = quote + 1
        guard index < end, u[index] != 39, u[index] != 10 else { return nil }
        if u[index] == 92 {
            index += 2
            while index < end, index - quote < 14, u[index] != 39, u[index] != 10 { index += 1 }
        } else {
            index += (0xD800...0xDBFF).contains(u[index]) ? 2 : 1
        }
        return index < end && u[index] == 39 ? index + 1 : nil
    }

    // MARK: Code

    private mutating func code(_ l: CodeLanguage, _ range: Range<Int>) {
        let end = range.upperBound
        let blocks = l.blockComments.map { (Array($0[0].utf16), Array($0[1].utf16)) }
        let lines = l.lineComments.map { Array($0.utf16) }
        let multis = l.multilineStrings.map { Array($0.utf16) }
        let singles = Set(l.strings.compactMap { $0.utf16.first })
        let metas = l.metaMarkers.map { Array($0.utf16) }
        func isIdent(_ c: UInt16) -> Bool { Self.isIdentStart(c) || Self.isDigit(c) || l.identifierExtras.contains(c) }
        var index = range.lowerBound, lineStart = true
        while index < end {
            let c = u[index]
            if c == 10 { lineStart = true; index += 1; continue }
            if c == 32 || c == 9 || c == 13 { index += 1; continue }
            let wasLineStart = lineStart
            lineStart = false
            let previous: UInt16? = index > range.lowerBound ? u[index - 1] : nil
            if let marker = metas.first(where: { matches($0, at: index, end: end) }) { add(.meta, index..<(index + marker.count)); index += marker.count; continue }
            if let (open, close) = blocks.first(where: { matches($0.0, at: index, end: end) }) {
                let stop = find(close, from: index + open.count, end: end).map { $0 + close.count } ?? end
                add(.comment, index..<stop); index = stop; continue
            }
            if lines.contains(where: { matches($0, at: index, end: end) }), !(l.hashNeedsBoundary && c == 35 && previous.map({ !Self.isSpace($0) }) == true) {
                let stop = lineEnd(index, end); add(.comment, index..<stop); index = stop; continue
            }
            if l.preprocessor, wasLineStart, c == 35 { let stop = lineEnd(index, end); add(.meta, index..<stop); index = stop; continue }
            if l.hashAttributes, c == 35, index + 1 < end, u[index + 1] == 91 || (u[index + 1] == 33 && index + 2 < end && u[index + 2] == 91) {
                let lineStop = lineEnd(index, end)
                let stop = find([93], from: index, end: lineStop).map { $0 + 1 } ?? lineStop
                add(.attribute, index..<stop); index = stop; continue
            }
            if l.keys, wasLineStart, c == 45 {
                if matches(Array("---".utf16), at: index, end: end) { let stop = lineEnd(index, end); add(.meta, index..<stop); index = stop; continue }
                if index + 1 < end, u[index + 1] == 32 { lineStart = true; index += 1; continue }
            }
            // Strings, including Rust raw strings and Python prefixes.
            if l.rawStrings, c == 114, index + 1 < end, u[index + 1] == 34 || u[index + 1] == 35, previous.map(isIdent) != true {
                var hashes = 0, quote = index + 1
                while quote < end, u[quote] == 35 { hashes += 1; quote += 1 }
                if quote < end, u[quote] == 34 {
                    let closer = [UInt16(34)] + Array(repeating: 35, count: hashes)
                    let stop = find(closer, from: quote + 1, end: end).map { $0 + closer.count } ?? end
                    add(.string, index..<stop); index = stop; continue
                }
            }
            var quote = index
            if l.stringPrefixes.contains(c), previous.map(isIdent) != true {
                var probe = index
                while probe < end, probe - index < 2, l.stringPrefixes.contains(u[probe]) { probe += 1 }
                if probe < end, u[probe] == 34 || u[probe] == 39 { quote = probe }
            }
            if let delimiter = multis.first(where: { matches($0, at: quote, end: end) }) {
                let stop = closing(delimiter, from: quote + delimiter.count, end: end) ?? end
                add(.string, index..<stop); index = stop; continue
            }
            let q = u[quote]
            if q == 39, l.charLiterals, quote == index {
                if let stop = charLiteralEnd(quote, end) { add(.string, index..<stop); index = stop } else { index += 1 }
                continue
            }
            if singles.contains(q) || (quote > index && (q == 34 || q == 39)) {
                let lineStop = lineEnd(quote, end)
                let stop = closing([q], from: quote + 1, end: lineStop) ?? lineStop
                var after = stop
                while after < end, u[after] == 32 || u[after] == 9 { after += 1 }
                add(l.keys && after < end && u[after] == 58 ? .attribute : .string, index..<stop); index = stop; continue
            }
            if Self.isDigit(c) || (c == 46 && index + 1 < end && Self.isDigit(u[index + 1]) && previous.map(isIdent) != true) {
                let stop = numberEnd(index, end); add(.number, index..<stop); index = stop; continue
            }
            if l.variables.contains(c), index + 1 < end {
                let next = u[index + 1]
                if c == 36, next == 123 || (next == 40 && l.targets) {
                    let lineStop = lineEnd(index, end)
                    let stop = find([next == 123 ? 125 : 41], from: index + 2, end: lineStop).map { $0 + 1 } ?? lineStop
                    add(.variable, index..<stop); index = stop; continue
                }
                if Self.isIdentStart(next) {
                    var stop = index + 1
                    while stop < end, isIdent(u[stop]) { stop += 1 }
                    let word = String(decoding: u[index..<stop], as: UTF16.self)
                    add(l.constants.contains(l.caseInsensitive ? word.lowercased() : word) ? .constant : .variable, index..<stop); index = stop; continue
                }
                if c == 36, Array("@?#*!$-0123456789<^".utf16).contains(next) { add(.variable, index..<(index + 2)); index += 2; continue }
            }
            if l.attributes.contains(c), index + 1 < end, Self.isIdentStart(u[index + 1]) {
                var stop = index + 1
                while stop < end, isIdent(u[stop]) || u[stop] == 46 { stop += 1 }
                add(.attribute, index..<stop); index = stop; continue
            }
            if l.symbols, c == 58, index + 1 < end, Self.isIdentStart(u[index + 1]), previous.map({ $0 == 58 || isIdent($0) }) != true {
                var stop = index + 1
                while stop < end, isIdent(u[stop]) { stop += 1 }
                add(.constant, index..<stop); index = stop; continue
            }
            if l.jsxTags, c == 60, index + 1 < end, Self.isIdentStart(u[index + 1]) || (u[index + 1] == 47 && index + 2 < end && Self.isIdentStart(u[index + 2])) {
                var back = index - 1
                while back >= range.lowerBound, u[back] == 32 || u[back] == 9 { back -= 1 }
                if back < range.lowerBound || !(isIdent(u[back]) || u[back] == 41 || u[back] == 93) {
                    var stop = index + (u[index + 1] == 47 ? 2 : 1)
                    while stop < end, isIdent(u[stop]) || u[stop] == 46 || u[stop] == 45 { stop += 1 }
                    add(.tag, index..<stop); index = stop; continue
                }
            }
            if Self.isIdentStart(c) || (c == 36 && l.identifierExtras.contains(36)) {
                var stop = index + 1
                while stop < end, isIdent(u[stop]) { stop += 1 }
                let word = String(decoding: u[index..<stop], as: UTF16.self)
                let key = l.caseInsensitive ? word.lowercased() : word
                var next = stop
                while next < end, u[next] == 32 || u[next] == 9 { next += 1 }
                let following: UInt16 = next < end ? u[next] : 0
                var kind: CodeTokenKind?
                if l.keywords.contains(key), !l.lineKeywords || wasLineStart { kind = .keyword }
                else if l.constants.contains(word) || l.constants.contains(key) { kind = .constant }
                else if l.keys, wasLineStart, following == 58, next + 1 >= end || Self.isSpace(u[next + 1]) { kind = .attribute }
                else if l.targets, wasLineStart, following == 58, !(next + 1 < end && u[next + 1] == 61) { kind = .function }
                else if l.types.contains(key) { kind = .type }
                else if l.macros, stop < end, u[stop] == 33 { kind = .function; stop += 1 }
                else if following == 40 || l.builtins.contains(key) { kind = .function }
                else if l.capitalizedTypes, c >= 65, c <= 90 { kind = .type }
                else if l.id == "powershell", word.contains("-") { kind = .function }
                if let kind { add(kind, index..<stop) }
                index = stop; continue
            }
            index += 1
        }
    }

    // MARK: Markup

    private mutating func markup(_ range: Range<Int>) {
        let end = range.upperBound
        func isName(_ c: UInt16) -> Bool { Self.isIdentStart(c) || Self.isDigit(c) || c == 45 || c == 58 || c == 46 }
        var index = range.lowerBound
        while index < end {
            let c = u[index]
            if c == 38 {
                var stop = index + 1
                while stop < end, stop - index < 12, isName(u[stop]) || u[stop] == 35 { stop += 1 }
                if stop < end, u[stop] == 59, stop > index + 1 { add(.constant, index..<(stop + 1)); index = stop + 1; continue }
                index += 1; continue
            }
            guard c == 60 else { index += 1; continue }
            if matches(Array("<!--".utf16), at: index, end: end) {
                let stop = find(Array("-->".utf16), from: index + 4, end: end).map { $0 + 3 } ?? end
                add(.comment, index..<stop); index = stop; continue
            }
            if matches(Array("<![CDATA[".utf16), at: index, end: end) {
                let stop = find(Array("]]>".utf16), from: index + 9, end: end).map { $0 + 3 } ?? end
                add(.string, index..<stop); index = stop; continue
            }
            if index + 1 < end, u[index + 1] == 33 || u[index + 1] == 63 {
                let stop = find([62], from: index, end: end).map { $0 + 1 } ?? end
                add(.meta, index..<stop); index = stop; continue
            }
            let closingTag = index + 1 < end && u[index + 1] == 47
            var stop = index + (closingTag ? 2 : 1)
            guard stop < end, Self.isIdentStart(u[stop]) else { index += 1; continue }
            let nameStart = stop
            while stop < end, isName(u[stop]) { stop += 1 }
            let name = String(decoding: u[nameStart..<stop], as: UTF16.self).lowercased()
            add(.tag, index..<stop); index = stop
            var selfClosing = false, afterEquals = false
            while index < end, u[index] != 62 {
                let a = u[index]
                if a == 47, index + 1 < end, u[index + 1] == 62 { add(.tag, index..<(index + 2)); index += 2; selfClosing = true; break }
                if a == 60 { break }
                if Self.isSpace(a) { index += 1; continue }
                if a == 61 { afterEquals = true; index += 1; continue }
                if a == 34 || a == 39 {
                    let close = closing([a], from: index + 1, end: end) ?? end
                    add(.string, index..<close); index = close; afterEquals = false; continue
                }
                if a == 123 {
                    var depth = 0, close = index
                    while close < end { if u[close] == 123 { depth += 1 } else if u[close] == 125 { depth -= 1; if depth == 0 { close += 1; break } }; close += 1 }
                    index = close; afterEquals = false; continue
                }
                var close = index
                while close < end, !Self.isSpace(u[close]), ![61, 62, 34, 39, 60].contains(u[close]), !(u[close] == 47 && close + 1 < end && u[close + 1] == 62) { close += 1 }
                guard close > index else { index += 1; continue }
                add(afterEquals ? .string : .attribute, index..<close); index = close; afterEquals = false
            }
            if !selfClosing, index < end, u[index] == 62 {
                add(.tag, index..<(index + 1)); index += 1
                if !closingTag, name == "script" || name == "style", let embedded = CodeLanguages.language(name == "script" ? "javascript" : "css") {
                    var close = index
                    while close < end, !(u[close] == 60 && close + 1 < end && u[close + 1] == 47 && String(decoding: u[(close + 2)..<min(end, close + 2 + name.count)], as: UTF16.self).lowercased() == name) { close += 1 }
                    scan(embedded, index..<close); index = close
                }
            }
        }
    }

    // MARK: CSS

    private mutating func css(_ l: CodeLanguage, _ range: Range<Int>) {
        let end = range.upperBound
        let blocks = l.blockComments.map { (Array($0[0].utf16), Array($0[1].utf16)) }
        let lines = l.lineComments.map { Array($0.utf16) }
        func isName(_ c: UInt16) -> Bool { Self.isIdentStart(c) || Self.isDigit(c) || c == 45 }
        var index = range.lowerBound, depth = 0
        while index < end {
            let c = u[index]
            if Self.isSpace(c) { index += 1; continue }
            if let (open, close) = blocks.first(where: { matches($0.0, at: index, end: end) }) {
                let stop = find(close, from: index + open.count, end: end).map { $0 + close.count } ?? end
                add(.comment, index..<stop); index = stop; continue
            }
            if lines.contains(where: { matches($0, at: index, end: end) }), !(index > range.lowerBound && u[index - 1] == 58) {
                let stop = lineEnd(index, end); add(.comment, index..<stop); index = stop; continue
            }
            if c == 34 || c == 39 {
                let lineStop = lineEnd(index, end)
                let stop = closing([c], from: index + 1, end: lineStop) ?? lineStop
                add(.string, index..<stop); index = stop; continue
            }
            if c == 123 { depth += 1; index += 1; continue }
            if c == 125 { depth = max(0, depth - 1); index += 1; continue }
            var stop = index + 1
            if c == 64 || c == 36 || c == 35 || c == 46 || c == 33 || c == 58 || (c == 45 && index + 1 < end && u[index + 1] == 45) {
                while stop < end, isName(u[stop]) { stop += 1 }
                if stop > index + 1 {
                    let kind: CodeTokenKind? = switch c {
                    case 64, 33: .keyword
                    case 36, 45: .variable
                    case 35: depth > 0 ? .number : .constant
                    case 46: depth == 0 ? .type : nil
                    case 58: depth == 0 || (index > range.lowerBound && u[index - 1] == 38) ? .keyword : nil
                    default: nil
                    }
                    if let kind { add(kind, index..<stop); index = stop; continue }
                    if c != 46 && c != 58 { index = stop; continue }
                }
            }
            if Self.isDigit(c) || (c == 46 && index + 1 < end && Self.isDigit(u[index + 1])) {
                let numberStop = numberEnd(index, end, percent: true); add(.number, index..<numberStop); index = numberStop; continue
            }
            if Self.isIdentStart(c) || (c == 45 && index + 1 < end && Self.isIdentStart(u[index + 1])) {
                stop = index + 1
                while stop < end, isName(u[stop]) { stop += 1 }
                var next = stop
                while next < end, u[next] == 32 || u[next] == 9 { next += 1 }
                let following: UInt16 = next < end ? u[next] : 0
                if following == 40 { add(.function, index..<stop) }
                else if depth == 0 { add(.tag, index..<stop) }
                else if following == 58 { add(.attribute, index..<stop) }
                index = stop; continue
            }
            index += 1
        }
    }

    // MARK: Line formats

    private mutating func diff(_ range: Range<Int>) {
        var index = range.lowerBound
        let headers = ["diff ", "index ", "new file", "deleted file", "similarity", "rename ", "old mode", "new mode", "Binary files", "commit ", "Author:", "Date:"]
        while index < range.upperBound {
            let stop = lineEnd(index, range.upperBound)
            if stop > index {
                let line = String(decoding: u[index..<min(stop, index + 16)], as: UTF16.self)
                let kind: CodeTokenKind? =
                    line.hasPrefix("+++ ") || line.hasPrefix("--- ") || line.hasPrefix("@@") || headers.contains(where: line.hasPrefix) ? .meta
                    : u[index] == 43 ? .inserted : u[index] == 45 ? .deleted : u[index] == 92 ? .comment : nil
                if let kind { add(kind, index..<stop) }
            }
            index = stop + 1
        }
    }

    private mutating func ini(_ range: Range<Int>) {
        var index = range.lowerBound
        while index < range.upperBound {
            let stop = lineEnd(index, range.upperBound)
            var start = index
            while start < stop, u[start] == 32 || u[start] == 9 { start += 1 }
            if start < stop {
                let c = u[start]
                if c == 35 || c == 59 { add(.comment, start..<stop) }
                else if c == 91 { add(.type, start..<(find([93], from: start, end: stop).map { $0 + 1 } ?? stop)) }
                else if let separator = (start..<stop).first(where: { u[$0] == 61 || (u[$0] == 58 && $0 + 1 < stop && u[$0 + 1] == 32) }) {
                    var keyEnd = separator
                    while keyEnd > start, u[keyEnd - 1] == 32 || u[keyEnd - 1] == 9 { keyEnd -= 1 }
                    add(.attribute, start..<keyEnd)
                    code(Self.valueLanguage, (separator + 1)..<stop)
                } else if c == 33 { add(.keyword, start..<(start + 1)) }
            }
            index = stop + 1
        }
    }

    private mutating func markdown(_ range: Range<Int>) {
        var index = range.lowerBound, fence = false
        while index < range.upperBound {
            let stop = lineEnd(index, range.upperBound)
            var start = index
            while start < stop, start - index < 4, u[start] == 32 { start += 1 }
            if matches(Array("```".utf16), at: start, end: stop) || matches(Array("~~~".utf16), at: start, end: stop) {
                add(.meta, start..<stop); fence.toggle()
            } else if !fence, start < stop {
                var hashes = start
                while hashes < stop, u[hashes] == 35 { hashes += 1 }
                if hashes > start, hashes - start <= 6, hashes == stop || u[hashes] == 32 { add(.heading, start..<stop) }
                else if u[start] == 62 { add(.comment, start..<stop) }
                else {
                    var cursor = start
                    if [45, 42, 43].contains(u[start]), start + 1 < stop, u[start + 1] == 32 { add(.keyword, start..<(start + 1)); cursor = start + 2 }
                    else {
                        var digits = start
                        while digits < stop, Self.isDigit(u[digits]) { digits += 1 }
                        if digits > start, digits + 1 < stop, u[digits] == 46 || u[digits] == 41, u[digits + 1] == 32 { add(.keyword, start..<(digits + 1)); cursor = digits + 2 }
                    }
                    while cursor < stop {
                        if u[cursor] == 96, let close = find([96], from: cursor + 1, end: stop) { add(.string, cursor..<(close + 1)); cursor = close + 1; continue }
                        if u[cursor] == 93, cursor + 1 < stop, u[cursor + 1] == 40, let close = find([41], from: cursor + 2, end: stop) {
                            add(.function, (cursor + 1)..<(close + 1)); cursor = close + 1; continue
                        }
                        cursor += 1
                    }
                }
            }
            index = stop + 1
        }
    }
}
