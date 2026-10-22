import Foundation

enum ComposerUTF16Selection {
    static func isValid(_ range: NSRange, in text: String) -> Bool {
        let value = text as NSString
        guard range.location != NSNotFound, range.location >= 0, range.length >= 0,
              range.location <= value.length, range.length <= value.length - range.location else { return false }
        func boundary(_ offset: Int) -> Bool {
            guard offset > 0 && offset < value.length else { return true }
            return !((0xD800...0xDBFF).contains(value.character(at: offset - 1)) &&
                     (0xDC00...0xDFFF).contains(value.character(at: offset)))
        }
        return boundary(range.location) && boundary(range.location + range.length)
    }
}

/// AppKit selections use UTF-16. Validate every range against the latest draft
/// before replacing, including when a picker outlives a concurrent draft edit.
struct ComposerSkillMention: Equatable {
    let range: NSRange
    let selection: NSRange
    let expectedText: String
    let query: String
    static func trigger(in text: String, selection: NSRange, showSlash: Bool) -> Self? {
        guard selection.length == 0, ComposerUTF16Selection.isValid(selection, in: text),
              let caret = Range(selection, in: text)?.lowerBound else { return nil }
        var start = caret
        while start > text.startIndex {
            let previous = text.index(before: start)
            if text[previous].isWhitespace { break }
            start = previous
        }
        let token = String(text[start..<caret])
        let query: String
        if token.hasPrefix("$") { query = String(token.dropFirst()) }
        else if showSlash && token.lowercased().hasPrefix("/skill:") { query = String(token.dropFirst(7)) }
        else { return nil }
        guard query.unicodeScalars.allSatisfy({ scalar in
            scalar.isASCII && (CharacterSet.alphanumerics.contains(scalar) || ":_-".unicodeScalars.contains(scalar))
        }), query.isEmpty || query.unicodeScalars.contains(where: { CharacterSet.letters.contains($0) }) else { return nil }
        var end = caret
        while end < text.endIndex {
            let character = text[end]
            guard character.unicodeScalars.allSatisfy({ $0.isASCII && (CharacterSet.alphanumerics.contains($0) || ":_-".unicodeScalars.contains($0)) }) else { break }
            end = text.index(after: end)
        }
        return .init(range: NSRange(start..<end, in: text), selection: selection, expectedText: String(text[start..<end]), query: query)
    }
    static func selection(in text: String, range: NSRange) -> Self? {
        guard ComposerUTF16Selection.isValid(range, in: text), let selected = Range(range, in: text) else { return nil }
        return .init(range: range, selection: range, expectedText: String(text[selected]), query: "")
    }
    func inserting(token: String, into latest: String, selection: NSRange) -> (text: String, selection: NSRange)? {
        guard token.hasPrefix("$"), token.count > 1, !token.contains(where: { $0.isWhitespace }),
              selection == self.selection,
              ComposerUTF16Selection.isValid(selection, in: latest), ComposerUTF16Selection.isValid(range, in: latest),
              let target = Range(range, in: latest), String(latest[target]) == expectedText else { return nil }
        var end = target.upperBound
        if end < latest.endIndex && latest[end] == " " { end = latest.index(after: end) }
        let replacement = token + " "
        let result = latest.replacingCharacters(in: target.lowerBound..<end, with: replacement)
        return (result, .init(location: range.location + replacement.utf16.count, length: 0))
    }
}
