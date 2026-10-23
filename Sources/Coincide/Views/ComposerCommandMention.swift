import Foundation

/// A native command expands only at the beginning of the whole prompt. Keep
/// the original UTF-16 selection and token so a late picker cannot edit a
/// different draft or move the user's cursor implicitly.
struct ComposerCommandMention: Equatable {
    let anchor: ComposerSkillMention
    var query: String { anchor.query }
    static func trigger(in text: String, selection: NSRange) -> Self? {
        guard selection.length == 0, ComposerUTF16Selection.isValid(selection, in: text),
              let caret = Range(selection, in: text)?.lowerBound,
              text.hasPrefix("/"), caret > text.startIndex else { return nil }
        let prefix = text[..<caret]
        guard !prefix.dropFirst().contains(where: { $0.isWhitespace || $0 == "/" }) else { return nil }
        var end = caret
        while end < text.endIndex, !text[end].isWhitespace, text[end] != "/" { end = text.index(after: end) }
        return .init(anchor: .init(range: NSRange(text.startIndex..<end, in: text), selection: selection,
                                  expectedText: String(text[..<end]), query: String(prefix.dropFirst())))
    }
    static func selection(in text: String, range: NSRange) -> Self? {
        guard range.location == 0, let anchor = ComposerSkillMention.selection(in: text, range: range) else { return nil }
        return .init(anchor: anchor)
    }
    func inserting(command: String, into latest: String, selection: NSRange) -> (text: String, selection: NSRange)? {
        guard !command.isEmpty, !command.contains(where: { $0.isWhitespace || $0 == "/" }),
              !command.unicodeScalars.contains(where: { $0.value < 32 || $0.value == 127 }),
              anchor.range.location == 0 else { return nil }
        return anchor.replacing(with: "/" + command + " ", into: latest, selection: selection)
    }
}
