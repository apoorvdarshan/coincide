import Foundation

/// Where dictated text goes in the composer: at the caret, replacing the selection, with a space before it when it
/// follows a word and after it when a word follows. Each partial transcript replaces the last one, so the text streams
/// in place; the final transcript replaces the last partial. Ranges are UTF-16, as `NSTextView` counts them.
public struct DictationInsertion: Equatable, Sendable {
    /// What the composer holds once dictation started, with the selection removed.
    public private(set) var range: NSRange
    /// The text inserted so far, spacing included.
    public private(set) var inserted = ""
    private let before: unichar?
    private let after: unichar?

    /// Starts at `selection` in `text`. The selection is replaced by the first update.
    public nonisolated init(text: String, selection: NSRange) {
        let string = text as NSString
        let location = min(max(0, selection.location), string.length)
        let length = min(max(0, selection.length), string.length - location)
        range = NSRange(location: location, length: length)
        before = location > 0 ? string.character(at: location - 1) : nil
        after = location + length < string.length ? string.character(at: location + length) : nil
    }

    /// The edit that shows `transcript` in place of what was inserted before: replace `range` with `replacement`.
    /// Nil when nothing changes.
    public nonisolated mutating func update(_ transcript: String) -> (range: NSRange, replacement: String)? {
        let replacement = spaced(transcript)
        // Until there are words, a selection stays selected.
        guard replacement != inserted else { return nil }
        let edit = (range: range, replacement: replacement)
        inserted = replacement
        range = NSRange(location: range.location, length: (replacement as NSString).length)
        return edit
    }

    /// Where the caret goes after the dictated text.
    public nonisolated var caret: NSRange { NSRange(location: range.location + range.length, length: 0) }

    /// `transcript` trimmed, with a space before it after a word and after it before a word.
    public nonisolated func spaced(_ transcript: String) -> String {
        let text = transcript.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return "" }
        var result = text
        if let before, !Self.isSpace(before) { result = " " + result }
        if let after, !Self.isSpace(after), !Self.isClosingPunctuation(after) { result += " " }
        return result
    }

    private nonisolated static func isSpace(_ character: unichar) -> Bool {
        guard let scalar = Unicode.Scalar(character) else { return false }
        return CharacterSet.whitespacesAndNewlines.contains(scalar)
    }

    private nonisolated static func isClosingPunctuation(_ character: unichar) -> Bool {
        guard let scalar = Unicode.Scalar(character) else { return false }
        return CharacterSet(charactersIn: ".,;:!?)]}”’'\"…").contains(scalar)
    }
}
