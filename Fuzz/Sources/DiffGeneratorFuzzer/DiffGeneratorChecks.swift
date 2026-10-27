import Foundation
import FuzzSupport

/// Input: a flags byte, then the old text, a 0xFF byte and the new text.
///
/// Flags: bit 0 old is nil (a new file), bit 1 new is nil (a deleted file, CursorDiff only), bit 2
/// build each text from one line per byte out of a small vocabulary (so edits repeat and move lines)
/// instead of decoding it as UTF-8, bit 3 and bit 4 end the old and new vocabulary texts with a
/// newline, bits 5-7 the number of context lines.
enum DiffGeneratorChecks {
    /// Lines that collide with diff syntax or are easy to confuse with one another.
    private static let vocabulary = [
        "a", "b", "c", "", " ", "{", "}", "\treturn x", "+", "-", "@@ -1 +1 @@", "\\ No newline at end of file", "é",
        "e\u{301}", "x\ry", "diff --git a/f b/f",
    ]

    static func run(_ bytes: [UInt8]) {
        guard let flags = bytes.first else { return }
        let parts = bytes.dropFirst().split(separator: 0xFF, maxSplits: 1, omittingEmptySubsequences: false)
        let oldBytes = Array(parts.first ?? [])
        let newBytes = parts.count > 1 ? Array(parts[1]) : []
        let vocabularyMode = flags & 0b100 != 0
        let old = vocabularyMode ? text(oldBytes, trailingNewline: flags & 0b1000 != 0) : decode(oldBytes)
        let new = vocabularyMode ? text(newBytes, trailingNewline: flags & 0b1_0000 != 0) : decode(newBytes)
        let context = Int(flags >> 5)

        checkUnifiedDiff(old: flags & 1 != 0 ? nil : old, new: new, context: context)
        checkCursorDiff(old: flags & 1 != 0 ? nil : old, new: flags & 0b10 != 0 ? nil : new, context: context)
    }

    private static func decode(_ bytes: [UInt8]) -> String { String(decoding: bytes, as: UTF8.self) }

    private static func text(_ bytes: [UInt8], trailingNewline: Bool) -> String {
        let lines = bytes.map { vocabulary[Int($0) % vocabulary.count] }
        guard !lines.isEmpty else { return "" }
        return lines.joined(separator: "\n") + (trailingNewline ? "\n" : "")
    }

    static func checkUnifiedDiff(old: String?, new: String, context: Int) {
        let diff = UnifiedDiff.make(path: "f.txt", old: old, new: new, context: context)
        if let old, lines(old, stripCR: false) == lines(new, stripCR: false) {
            expectEqual(diff, "", "no diff for unchanged lines")
            return
        }
        let header = old == nil ? "--- /dev/null\n+++ b/f.txt" : "--- a/f.txt\n+++ b/f.txt"
        expect(diff.hasPrefix(header), "UnifiedDiff header: \(diff.debugDescription)")
        apply(diff, to: old, expecting: new, context: "UnifiedDiff")
    }

    static func checkCursorDiff(old: String?, new: String?, context: Int) {
        let diff = CursorDiff.unified(old: old, new: new, path: "f.txt", context: context)
        let header = (old == nil ? "--- /dev/null\n" : "--- a/f.txt\n") + (new == nil ? "+++ /dev/null" : "+++ b/f.txt")
        expect(diff.hasPrefix(header), "CursorDiff header: \(diff.debugDescription)")
        apply(diff, to: old, expecting: new, context: "CursorDiff")
    }

    /// Parses `diff` as git's would be and applies its hunks to `old`, which must give `new`.
    private static func apply(_ diff: String, to old: String?, expecting new: String?, context name: String) {
        let files = DiffParser.parse("diff --git a/f.txt b/f.txt\n" + diff)
        guard files.count == 1 else { fail("\(name): \(files.count) files in \(diff.debugDescription)") }
        let file = files[0]
        let oldLines = lines(old ?? "")
        let newLines = lines(new ?? "")
        let describe = "\(name) of \((old ?? "nil").debugDescription) → \((new ?? "nil").debugDescription):\n\(diff)"

        var result: [String] = []
        var cursor = 0
        for hunk in file.hunks {
            var counts = (context: 0, deletions: 0, additions: 0)
            for line in hunk.lines {
                switch line.kind {
                case .context: counts.context += 1
                case .deletion: counts.deletions += 1
                case .addition: counts.additions += 1
                case .noNewline: break
                }
            }
            expect(
                hunk.oldCount == counts.context + counts.deletions && hunk.newCount == counts.context + counts.additions,
                "\(hunk.header) does not match its lines in \(describe)")

            // A side with no lines names the line before the hunk.
            let start = hunk.oldCount == 0 ? hunk.oldStart : hunk.oldStart - 1
            expect(start >= cursor && start <= oldLines.count, "\(hunk.header) is out of order in \(describe)")
            result += oldLines[cursor..<start]
            cursor = start
            expectEqual(hunk.newStart, hunk.newCount == 0 ? result.count : result.count + 1, "new start of \(hunk.header) in \(describe)")
            for line in hunk.lines {
                switch line.kind {
                case .context, .deletion:
                    expect(cursor < oldLines.count && oldLines[cursor] == line.text, "\(line.text.debugDescription) is not the old line \(cursor + 1) in \(describe)")
                    if line.kind == .context { result.append(line.text) }
                    cursor += 1
                case .addition:
                    result.append(line.text)
                case .noNewline:
                    break
                }
            }
        }
        result += oldLines[cursor...]
        expectEqual(result, newLines, "applying \(describe)")
        expectEqual(file.additions - file.deletions, newLines.count - oldLines.count, "line count change in \(describe)")
    }

    /// Lines as git sees them: split at each "\n", the last one ending the text. DiffParser shows them
    /// without a carriage return at the end (`stripCR`).
    private static func lines(_ text: String, stripCR: Bool = true) -> [String] {
        guard !text.isEmpty else { return [] }
        var lines = text.utf8.split(separator: 0x0A, omittingEmptySubsequences: false).map { raw in
            let line = Substring(raw)
            return String(stripCR && line.hasSuffix("\r") ? line.dropLast() : line)
        }
        if text.utf8.last == 0x0A { lines.removeLast() }
        return lines
    }
}
