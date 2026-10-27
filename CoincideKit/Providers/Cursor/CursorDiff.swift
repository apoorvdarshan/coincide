import Foundation

/// Builds unified diffs from the before/after text Cursor reports for file edits.
enum CursorDiff {
    private enum Line: Equatable {
        case same(String)
        case removed(String)
        case added(String)

        nonisolated var isChange: Bool {
            if case .same = self { return false }
            return true
        }

        nonisolated var inOld: Bool {
            if case .added = self { return false }
            return true
        }

        nonisolated var inNew: Bool {
            if case .removed = self { return false }
            return true
        }
    }

    /// Beyond these sizes the changed middle of a file is shown as one replacement instead of a minimal diff.
    private nonisolated static let maxDiffedLines = 4_000
    private nonisolated static let maxEditDistance = 1_000

    /// `old` is nil for a new file and `new` is nil for a deleted one.
    nonisolated static func unified(old: String?, new: String?, path: String, context: Int = 3) -> String {
        let header = [
            "--- " + (old == nil ? "/dev/null" : "a/\(path)"),
            "+++ " + (new == nil ? "/dev/null" : "b/\(path)"),
        ]
        return (header + hunks(diff(lines(old), lines(new)), context: context)).joined(separator: "\n")
    }

    private nonisolated static func lines(_ text: String?) -> [String] {
        guard let text, !text.isEmpty else { return [] }
        var lines = text.components(separatedBy: "\n")
        if lines.last == "" { lines.removeLast() }
        return lines
    }

    private nonisolated static func diff(_ old: [String], _ new: [String]) -> [Line] {
        var prefix = 0
        while prefix < old.count, prefix < new.count, old[prefix] == new[prefix] { prefix += 1 }
        var suffix = 0
        while suffix < old.count - prefix, suffix < new.count - prefix,
            old[old.count - 1 - suffix] == new[new.count - 1 - suffix]
        {
            suffix += 1
        }
        let oldMiddle = Array(old[prefix..<(old.count - suffix)])
        let newMiddle = Array(new[prefix..<(new.count - suffix)])
        let middle =
            (oldMiddle.count + newMiddle.count <= maxDiffedLines ? myers(oldMiddle, newMiddle) : nil)
            ?? oldMiddle.map(Line.removed) + newMiddle.map(Line.added)
        return old[..<prefix].map(Line.same) + middle + old[(old.count - suffix)...].map(Line.same)
    }

    /// Myers' shortest edit script, or nil when the files differ too much to be worth it.
    private nonisolated static func myers(_ a: [String], _ b: [String]) -> [Line]? {
        let n = a.count
        let m = b.count
        guard n > 0 || m > 0 else { return [] }
        let offset = n + m + 1
        var v = [Int](repeating: 0, count: 2 * offset + 1)
        // trace[d] keeps v for k in -(d+1)...(d+1) as it was when round d began.
        var trace: [[Int]] = []
        var found = false
        search: for d in 0...min(n + m, maxEditDistance) {
            trace.append(Array(v[(offset - d - 1)...(offset + d + 1)]))
            for k in stride(from: -d, through: d, by: 2) {
                var x =
                    (k == -d || (k != d && v[offset + k - 1] < v[offset + k + 1]))
                    ? v[offset + k + 1] : v[offset + k - 1] + 1
                var y = x - k
                while x < n, y < m, a[x] == b[y] {
                    x += 1
                    y += 1
                }
                v[offset + k] = x
                if x >= n, y >= m {
                    found = true
                    break search
                }
            }
        }
        guard found else { return nil }

        var result: [Line] = []
        var x = n
        var y = m
        for d in stride(from: trace.count - 1, through: 0, by: -1) {
            let snapshot = trace[d]
            func value(_ k: Int) -> Int { snapshot[k + d + 1] }
            let k = x - y
            let previousK = (k == -d || (k != d && value(k - 1) < value(k + 1))) ? k + 1 : k - 1
            let previousX = value(previousK)
            let previousY = previousX - previousK
            while x > previousX, y > previousY {
                result.append(.same(a[x - 1]))
                x -= 1
                y -= 1
            }
            if d > 0 {
                result.append(x == previousX ? .added(b[y - 1]) : .removed(a[x - 1]))
            }
            x = previousX
            y = previousY
        }
        return result.reversed()
    }

    private nonisolated static func hunks(_ lines: [Line], context: Int) -> [String] {
        let changes = lines.indices.filter { lines[$0].isChange }
        guard let first = changes.first else { return [] }

        // Changes whose context would touch or overlap share a hunk.
        var groups: [ClosedRange<Int>] = []
        var start = first
        var end = first
        for index in changes.dropFirst() {
            if index - end > 2 * context {
                groups.append(start...end)
                start = index
            }
            end = index
        }
        groups.append(start...end)

        // Old and new line counts before each entry, for the hunk headers.
        var oldBefore: [Int] = []
        var newBefore: [Int] = []
        var oldCount = 0
        var newCount = 0
        for line in lines {
            oldBefore.append(oldCount)
            newBefore.append(newCount)
            if line.inOld { oldCount += 1 }
            if line.inNew { newCount += 1 }
        }

        var output: [String] = []
        for group in groups {
            let lower = max(0, group.lowerBound - context)
            let upper = min(lines.count - 1, group.upperBound + context)
            let slice = lines[lower...upper]
            let oldLength = slice.count(where: \.inOld)
            let newLength = slice.count(where: \.inNew)
            let oldStart = oldBefore[lower] + (oldLength == 0 ? 0 : 1)
            let newStart = newBefore[lower] + (newLength == 0 ? 0 : 1)
            output.append("@@ -\(range(oldStart, oldLength)) +\(range(newStart, newLength)) @@")
            for line in slice {
                switch line {
                case .same(let text): output.append(" " + text)
                case .removed(let text): output.append("-" + text)
                case .added(let text): output.append("+" + text)
                }
            }
        }
        return output
    }

    private nonisolated static func range(_ start: Int, _ length: Int) -> String {
        length == 1 ? "\(start)" : "\(start),\(length)"
    }
}
