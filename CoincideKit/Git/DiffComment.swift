import Foundation

extension MessageContext.DiffComment {
    /// A comment on lines of `file`'s diff, given as hunk and line indexes, as T3 Code builds a review comment from a
    /// selected range. Each hunk contributes the lines from the first to the last one picked in it, under a hunk header
    /// that counts only those lines. Nil when no index names a line of the file.
    public nonisolated init?(file: FileDiff, lines positions: [(hunk: Int, line: Int)], comment: String) {
        var spans: [(hunk: DiffHunk, range: ClosedRange<Int>)] = []
        for (index, hunk) in file.hunks.enumerated() {
            let picked = positions.filter { $0.hunk == index && hunk.lines.indices.contains($0.line) }.map(\.line)
            guard let first = picked.min(), let last = picked.max() else { continue }
            spans.append((hunk, first...last))
        }
        guard !spans.isEmpty else { return nil }

        var fragments: [String] = []
        var newNumbers: [Int] = []
        var oldNumbers: [Int] = []
        for (hunk, range) in spans {
            let lines = hunk.lines[range]
            let old = lines.compactMap(\.oldLine)
            let new = lines.compactMap(\.newLine)
            oldNumbers += old
            newNumbers += new
            // A side with no lines here starts, as git writes it, at the line before the span.
            let before = hunk.lines[..<range.lowerBound]
            let oldStart = old.first ?? before.compactMap(\.oldLine).last ?? max(hunk.oldStart - 1, 0)
            let newStart = new.first ?? before.compactMap(\.newLine).last ?? max(hunk.newStart - 1, 0)
            var fragment = ["@@ -\(oldStart),\(old.count) +\(newStart),\(new.count) @@"]
            for line in lines {
                switch line.kind {
                case .context: fragment.append(" " + line.text)
                case .addition: fragment.append("+" + line.text)
                case .deletion: fragment.append("-" + line.text)
                case .noNewline: fragment.append("\\ No newline at end of file")
                }
            }
            fragments.append(fragment.joined(separator: "\n"))
        }
        // Lines of the changed file when there are any; only removed lines are numbered as before the change.
        let numbers = newNumbers.isEmpty ? oldNumbers : newNumbers
        guard let start = numbers.min(), let end = numbers.max() else { return nil }
        self.init(
            path: file.path, lineStart: start, lineEnd: end, isBeforeChange: newNumbers.isEmpty,
            diff: fragments.joined(separator: "\n"), comment: comment)
    }
}
