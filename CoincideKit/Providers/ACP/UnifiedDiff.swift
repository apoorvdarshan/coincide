import Foundation

/// Unified diffs for the file edits ACP agents report as before and after text.
enum UnifiedDiff {
    private enum Line {
        case same(String)
        case removed(String)
        case added(String)

        var isChange: Bool {
            if case .same = self { return false }
            return true
        }
    }

    /// Above this many line pairs, the diff shows a full replacement instead of searching for a
    /// minimal edit script, so a huge rewrite cannot stall the main thread.
    private nonisolated static let maxComparisons = 16_000_000

    /// A `---`/`+++` diff for one file, or an empty string when nothing changed.
    /// `old` is nil for a new file.
    nonisolated static func make(path: String, old: String?, new: String, context: Int = 3) -> String {
        let oldLines = lines(old ?? "")
        let newLines = lines(new)
        guard oldLines != newLines || old == nil else { return "" }
        let script = editScript(from: oldLines, to: newLines)

        var output = [old == nil ? "--- /dev/null" : "--- a/\(path)", "+++ b/\(path)"]
        let changes = script.indices.filter { script[$0].isChange }
        var hunkStart = 0
        while hunkStart < changes.count {
            var hunkEnd = hunkStart
            while hunkEnd + 1 < changes.count, changes[hunkEnd + 1] - changes[hunkEnd] <= context * 2 + 1 {
                hunkEnd += 1
            }
            let lower = max(0, changes[hunkStart] - context)
            let upper = min(script.count, changes[hunkEnd] + context + 1)
            output.append(contentsOf: hunk(script, lower..<upper))
            hunkStart = hunkEnd + 1
        }
        return output.joined(separator: "\n")
    }

    private nonisolated static func hunk(_ script: [Line], _ range: Range<Int>) -> [String] {
        var oldBefore = 0
        var newBefore = 0
        for line in script[..<range.lowerBound] {
            switch line {
            case .same: oldBefore += 1; newBefore += 1
            case .removed: oldBefore += 1
            case .added: newBefore += 1
            }
        }
        var oldCount = 0
        var newCount = 0
        var body: [String] = []
        for line in script[range] {
            switch line {
            case .same(let text):
                oldCount += 1
                newCount += 1
                body.append(" " + text)
            case .removed(let text):
                oldCount += 1
                body.append("-" + text)
            case .added(let text):
                newCount += 1
                body.append("+" + text)
            }
        }
        let oldStart = oldCount > 0 ? oldBefore + 1 : oldBefore
        let newStart = newCount > 0 ? newBefore + 1 : newBefore
        return ["@@ -\(oldStart),\(oldCount) +\(newStart),\(newCount) @@"] + body
    }

    private nonisolated static func editScript(from old: [String], to new: [String]) -> [Line] {
        guard old.count * new.count <= maxComparisons else {
            return old.map(Line.removed) + new.map(Line.added)
        }
        var removed = Set<Int>()
        var inserted = Set<Int>()
        for change in new.difference(from: old) {
            switch change {
            case .remove(let offset, _, _): removed.insert(offset)
            case .insert(let offset, _, _): inserted.insert(offset)
            }
        }
        var script: [Line] = []
        var oldIndex = 0
        var newIndex = 0
        while oldIndex < old.count || newIndex < new.count {
            if oldIndex < old.count, removed.contains(oldIndex) {
                script.append(.removed(old[oldIndex]))
                oldIndex += 1
            } else if newIndex < new.count, inserted.contains(newIndex) {
                script.append(.added(new[newIndex]))
                newIndex += 1
            } else if oldIndex < old.count, newIndex < new.count {
                script.append(.same(old[oldIndex]))
                oldIndex += 1
                newIndex += 1
            } else {
                break
            }
        }
        return script
    }

    /// Lines as git sees them, split at each "\n" scalar with any "\r" kept on its line. ("\r\n" is one
    /// Character, so splitting Characters would leave a CRLF file as one line.)
    private nonisolated static func lines(_ text: String) -> [String] {
        guard !text.isEmpty else { return [] }
        var lines = text.unicodeScalars.split(separator: "\n", omittingEmptySubsequences: false).map {
            String(Substring($0))
        }
        if lines.last == "" { lines.removeLast() }
        return lines
    }
}
