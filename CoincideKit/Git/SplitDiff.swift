import Foundation

/// Source-line indexes for one aligned row in a side-by-side diff. A nil side is a spacer,
/// never a fabricated empty line. Context lines occur on both sides.
public struct SplitDiffLine: Hashable, Sendable {
    public let before: Int?
    public let after: Int?

    public init(before: Int?, after: Int?) {
        self.before = before
        self.after = after
    }

    /// Align each contiguous replacement block in source order. End-of-file markers stay with
    /// their preceding line, including when a marker separates deletions from additions.
    public static func align(_ lines: [DiffLine]) -> [SplitDiffLine] {
        struct Entry {
            var line: Int
            var markers: [Int] = []
        }
        var result: [SplitDiffLine] = []
        var index = 0
        while index < lines.count {
            switch lines[index].kind {
            case .context, .noNewline:
                result.append(SplitDiffLine(before: index, after: index))
                index += 1
            case .deletion, .addition:
                var old: [Entry] = []
                var new: [Entry] = []
                var previousWasDeletion = false
                while index < lines.count, lines[index].kind != .context {
                    switch lines[index].kind {
                    case .deletion:
                        old.append(Entry(line: index))
                        previousWasDeletion = true
                    case .addition:
                        new.append(Entry(line: index))
                        previousWasDeletion = false
                    case .noNewline:
                        if previousWasDeletion, !old.isEmpty {
                            old[old.count - 1].markers.append(index)
                        } else if !new.isEmpty {
                            new[new.count - 1].markers.append(index)
                        }
                    case .context: break
                    }
                    index += 1
                }
                for offset in 0..<max(old.count, new.count) {
                    let left = old.indices.contains(offset) ? old[offset] : nil
                    let right = new.indices.contains(offset) ? new[offset] : nil
                    result.append(SplitDiffLine(before: left?.line, after: right?.line))
                    let oldMarkers = left?.markers ?? []
                    let newMarkers = right?.markers ?? []
                    for marker in 0..<max(oldMarkers.count, newMarkers.count) {
                        result.append(SplitDiffLine(
                            before: oldMarkers.indices.contains(marker) ? oldMarkers[marker] : nil,
                            after: newMarkers.indices.contains(marker) ? newMarkers[marker] : nil))
                    }
                }
            }
        }
        return result
    }
}
