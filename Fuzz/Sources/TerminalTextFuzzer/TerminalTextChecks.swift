import Foundation
import FuzzSupport

/// `R` treats the rest of the input as terminal output, `E` builds text with escape sequences of every
/// kind between plain segments and checks exactly the segments remain, `C` clips text with TextClip.
enum TerminalTextChecks {
    static func run(_ bytes: [UInt8]) {
        guard let first = bytes.first else { return }
        let rest = Array(bytes.dropFirst())
        switch first {
        case UInt8(ascii: "R"): raw(rest)
        case UInt8(ascii: "E"): embedded(FuzzInput(rest))
        case UInt8(ascii: "C"): clip(rest)
        default:
            switch first % 3 {
            case 0: raw(rest)
            case 1: embedded(FuzzInput(rest))
            default: clip(rest)
            }
        }
    }

    // MARK: Any output

    /// The first two bytes set `tail`'s line count and length; the rest is the output.
    static func raw(_ bytes: [UInt8]) {
        var input = FuzzInput(bytes.prefix(2))
        let lineCount = input.int(in: 1...12)
        let maxLength = input.int(in: 1...256)
        let text = String(decoding: bytes.dropFirst(2), as: UTF8.self)

        let stripped = TerminalText.stripANSI(text)
        if !text.unicodeScalars.contains(where: { $0 == "\u{1B}" || $0 == "\u{9B}" }) {
            expectEqual(stripped, text, "text without escapes is unchanged")
        }
        // Stripping only removes, so what is left appears in the same order in the original.
        expect(isSubsequence(stripped.unicodeScalars, of: text.unicodeScalars), "stripANSI added or reordered text")

        if let tail = TerminalText.tail(text, lines: lineCount, maxLength: maxLength) {
            expect(!tail.isEmpty && tail.count <= maxLength, "tail is \(tail.count) characters, limit \(maxLength)")
            let lines = tail.split(separator: "\n", omittingEmptySubsequences: false)
            expect(lines.count <= lineCount, "tail has \(lines.count) lines, limit \(lineCount)")
            // Lines are rejoined with "\n", whatever ended them in the output.
            expect(isSubsequence(tail.unicodeScalars.filter { $0 != "\n" }, of: stripped.unicodeScalars), "tail is not from the output")
        } else {
            let blank = stripped.split(whereSeparator: \.isNewline).allSatisfy {
                $0.trimmingCharacters(in: .whitespaces).isEmpty
            }
            expect(blank, "tail is nil although the output has text")
        }

        if let nonEmpty = TerminalText.nonEmpty(text) {
            expectEqual(nonEmpty, text.trimmingCharacters(in: .whitespacesAndNewlines), "nonEmpty trims")
            expect(!nonEmpty.isEmpty, "nonEmpty is empty")
        } else {
            expect(text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, "nonEmpty dropped text")
        }
    }

    // MARK: Known sequences

    /// Plain text that cannot start an escape sequence.
    private static let plain = [
        "a", "Error:", " ", "\n", "\r", "\t", "[", "]", "(", "0", "m", "\\", "\u{07}", "é", "🙂", "e\u{301}", "✔ Done",
        "~", "@", "P", "\u{90}",
    ]

    static func embedded(_ input: FuzzInput) {
        var input = input
        var text = ""
        var expected = ""
        for index in 0..<input.int(in: 1...6) {
            if index > 0 { text += sequence(&input) }
            let segment = input.text(plain, maxPieces: 5)
            text += segment
            expected += segment
        }
        expectEqual(TerminalText.stripANSI(text), expected, "stripANSI(\(text.debugDescription))")
    }

    /// One escape sequence of a kind TerminalText documents removing.
    private static func sequence(_ input: inout FuzzInput) -> String {
        switch input.int(in: 0...5) {
        case 0, 1:
            // CSI: ESC [ (or the one-byte 0x9B), parameter bytes, intermediate bytes, one final byte.
            var sequence = input.bool() ? "\u{1B}[" : "\u{9B}"
            for _ in 0..<input.int(in: 0...6) { sequence.unicodeScalars.append(scalar(&input, 0x30...0x3F)) }
            for _ in 0..<input.int(in: 0...2) { sequence.unicodeScalars.append(scalar(&input, 0x20...0x2F)) }
            sequence.unicodeScalars.append(scalar(&input, 0x40...0x7E))
            return sequence
        case 2:
            // OSC, such as a title or a hyperlink, ended by BEL or ESC \.
            let payload = input.text(["8;;https://example.com/a?b=c", "0;title", ";", " ", "é", "\n", "\u{9B}"], maxPieces: 4)
            return "\u{1B}]" + payload + (input.bool() ? "\u{07}" : "\u{1B}\\")
        case 3:
            // Character set selection.
            return "\u{1B}" + input.pick(["(", ")", "*", "+"]) + input.pick(["B", "0", "A", "z", "9"])
        default:
            // Two-character escapes: keypad modes, cursor save and restore, index, string terminators.
            return "\u{1B}" + input.pick(["7", "8", "=", ">", "<", "M", "D", "E", "\\", "^", "_", "@", "Z"])
        }
    }

    private static func scalar(_ input: inout FuzzInput, _ range: ClosedRange<Int>) -> Unicode.Scalar {
        Unicode.Scalar(UInt8(input.int(in: range)))
    }

    // MARK: TextClip

    /// The first four bytes set the limit and the clip length; the rest is the text.
    static func clip(_ bytes: [UInt8]) {
        var input = FuzzInput(bytes.prefix(4))
        let text = String(decoding: bytes.dropFirst(4), as: UTF8.self)
        let size = text.utf8.count
        let limit = input.int(in: -2...(size + 300))
        let clipTo = input.int(in: -2...(size + 300))
        let clipped = TextClip.keepingTail(text, limit: limit, clipTo: clipTo)
        guard size > limit else {
            expect(clipped.utf8.elementsEqual(text.utf8), "text within the limit is unchanged")
            return
        }
        let target = max(0, min(clipTo, limit))
        let kept = clipped.utf8.count
        expect(kept >= target && kept <= size, "kept \(kept) bytes for a target of \(target) out of \(size)")
        expect(text.utf8.suffix(kept).elementsEqual(clipped.utf8), "the result is not the end of the text")
        // The cut is at the last character boundary at or before the target, never inside a character.
        let cut = text.utf8.index(text.utf8.endIndex, offsetBy: -kept)
        guard kept > 0 else { return }
        expect(cut.samePosition(in: text) != nil, "the cut splits a character")
        let next = text.index(after: cut)
        expect(text.utf8.distance(from: next, to: text.utf8.endIndex) < target, "kept more than needed")
    }

    private static func isSubsequence(_ part: some Sequence<Unicode.Scalar>, of whole: String.UnicodeScalarView) -> Bool {
        var iterator = whole.makeIterator()
        return part.allSatisfy { scalar in
            while let next = iterator.next() { if next == scalar { return true } }
            return false
        }
    }
}
