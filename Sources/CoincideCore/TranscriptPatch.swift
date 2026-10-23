import Foundation

/// One changed file shown in a transcript card or turn summary. Line numbers are
/// nil for snippet diffs (for example a provider's old/new edit strings), whose
/// position in the real file is unknown.
public struct TranscriptFileChange: Sendable, Equatable, Identifiable {
    public enum Kind: String, Sendable { case added, deleted, modified, renamed }
    public var path: String
    public var previousPath: String?
    public var kind: Kind
    public var hunks: [TranscriptDiffHunk]
    public var additions: Int
    public var deletions: Int
    public var isBinary: Bool
    public var isTruncated: Bool
    /// False when bounded input prevented an exact preview/count calculation.
    public var countsComplete: Bool
    public var id: String { (previousPath.map { $0 + "\u{0}" } ?? "") + path }
    public init(path: String, previousPath: String? = nil, kind: Kind = .modified, hunks: [TranscriptDiffHunk] = [], additions: Int = 0, deletions: Int = 0, isBinary: Bool = false, isTruncated: Bool = false, countsComplete: Bool = true) {
        self.path = path; self.previousPath = previousPath; self.kind = kind; self.hunks = hunks
        self.additions = additions; self.deletions = deletions; self.isBinary = isBinary
        self.isTruncated = isTruncated; self.countsComplete = countsComplete
    }
    public var lineCount: Int { hunks.reduce(0) { $0 + $1.lines.count + 1 } }
}

public struct TranscriptDiffHunk: Sendable, Equatable {
    public var header: String
    public var lines: [TranscriptDiffLine]
    public init(header: String, lines: [TranscriptDiffLine]) { self.header = header; self.lines = lines }
}

public struct TranscriptDiffLine: Sendable, Equatable {
    public enum Kind: Sendable, Equatable { case context, addition, deletion, note }
    public var kind: Kind
    public var text: String
    public var oldLine: Int?
    public var newLine: Int?
    public init(_ kind: Kind, _ text: String, old: Int? = nil, new: Int? = nil) { self.kind = kind; self.text = text; oldLine = old; newLine = new }
}

public struct TranscriptDiffStat: Sendable, Equatable {
    public var files: Int
    public var additions: Int
    public var deletions: Int
    public init(files: Int, additions: Int, deletions: Int) { self.files = files; self.additions = additions; self.deletions = deletions }
    public init(_ changes: [TranscriptFileChange]) {
        files = Set(changes.map { Data($0.path.utf8) }).count
        additions = changes.reduce(0) { $0 + $1.additions }; deletions = changes.reduce(0) { $0 + $1.deletions }
    }
}

/// Parses git and plain unified patches into display models. The parser is
/// bounded and never throws: text that is not a recognizable patch returns nil
/// so callers can fall back to literal output.
public enum TranscriptPatch {
    public static let maximumLines = 50_000

    public static func parse(_ text: String, fallbackPath: String? = nil) -> [TranscriptFileChange]? {
        guard !text.isEmpty, text.utf8.count <= 16 * 1_048_576 else { return nil }
        var files: [TranscriptFileChange] = []
        var current: TranscriptFileChange?
        var hunk: TranscriptDiffHunk?
        var oldLine = 0, newLine = 0, oldRemaining = 0, newRemaining = 0
        var recognized = false, malformed = false, oldHeader: String?, sawOldHeader = false
        var transportCRLF: Bool?
        func closeHunk() {
            if let value = hunk {
                if oldRemaining != 0 || newRemaining != 0 { malformed = true }
                current?.hunks.append(value)
            }
            hunk = nil
        }
        func closeFile() {
            closeHunk()
            if let value = current { files.append(value); if files.count > 512 { malformed = true } }
            current = nil
        }
        func ensureFile() {
            if current == nil { current = .init(path: fallbackPath ?? "", kind: .modified) }
        }
        var count = 0
        // Iterate without first materializing every source line. Oversized or
        // incomplete patches fall back to their literal provider output.
        let bytes = text.utf8
        var cursor = bytes.startIndex
        while cursor < bytes.endIndex {
            let end = bytes[cursor...].firstIndex(of: 10) ?? bytes.endIndex
            let raw = String(decoding: bytes[cursor..<end], as: UTF8.self)
            cursor = end < bytes.endIndex ? bytes.index(after: end) : end
            count += 1
            guard count <= maximumLines, !malformed else { return nil }
            var line = raw[...]
            if transportCRLF == nil, line.hasPrefix("diff --git ") || line.hasPrefix("--- ") || line.hasPrefix("@@") {
                transportCRLF = line.hasSuffix("\r")
            }
            // Git's LF-framed patch can contain literal CR file bytes. Only
            // remove CR framing when the patch's own header established CRLF.
            if transportCRLF == true, line.hasSuffix("\r") { line = line.dropLast() }
            let inHunk = hunk != nil && (oldRemaining > 0 || newRemaining > 0)
            if inHunk, let first = line.first, first == " " || first == "+" || first == "-" {
                let body = String(line.dropFirst())
                switch first {
                case "+":
                    guard newRemaining > 0 else { return nil }
                    hunk?.lines.append(.init(.addition, body, new: newLine)); newLine += 1; newRemaining -= 1; current?.additions += 1
                case "-":
                    guard oldRemaining > 0 else { return nil }
                    hunk?.lines.append(.init(.deletion, body, old: oldLine)); oldLine += 1; oldRemaining -= 1; current?.deletions += 1
                default:
                    guard oldRemaining > 0, newRemaining > 0 else { return nil }
                    hunk?.lines.append(.init(.context, body, old: oldLine, new: newLine)); oldLine += 1; newLine += 1; oldRemaining -= 1; newRemaining -= 1
                }
                continue
            }
            if inHunk, line.isEmpty { return nil }
            if line.hasPrefix("\\") {
                if hunk != nil { hunk?.lines.append(.init(.note, String(line.dropFirst()).trimmingCharacters(in: .whitespaces))) }
                continue
            }
            if line.hasPrefix("diff --git ") {
                closeFile(); recognized = true; oldHeader = nil; sawOldHeader = false
                let (a, b) = gitHeaderPaths(String(line.dropFirst("diff --git ".count)))
                current = .init(path: b ?? a ?? fallbackPath ?? "", previousPath: nil, kind: .modified)
                if let a, let b, !a.utf8.elementsEqual(b.utf8) { current?.previousPath = a; current?.kind = .renamed }
                continue
            }
            if line.hasPrefix("@@") {
                guard let header = hunkHeader(String(line)) else { return nil }
                recognized = true
                ensureFile(); closeHunk()
                oldLine = header.oldStart; newLine = header.newStart; oldRemaining = header.oldCount; newRemaining = header.newCount
                hunk = .init(header: String(line), lines: [])
                continue
            }
            if hunk != nil { closeHunk() }
            if line.hasPrefix("--- ") {
                recognized = true
                if current == nil || current?.hunks.isEmpty == false { closeFile(); current = .init(path: fallbackPath ?? "") }
                oldHeader = headerPath(String(line.dropFirst(4))); sawOldHeader = true
                if oldHeader == nil { current?.kind = .added; current?.previousPath = nil }
                else if current?.path.isEmpty == true { current?.path = oldHeader! }
                continue
            }
            if line.hasPrefix("+++ ") {
                recognized = true; ensureFile()
                if let path = headerPath(String(line.dropFirst(4))) {
                    if sawOldHeader, let old = oldHeader, !old.utf8.elementsEqual(path.utf8), current?.kind != .added { current?.previousPath = old; current?.kind = .renamed }
                    current?.path = path
                } else {
                    current?.kind = .deleted; current?.previousPath = nil
                    if let old = oldHeader { current?.path = old }
                }
                oldHeader = nil; sawOldHeader = false
                continue
            }
            guard current != nil else { continue }
            if line.hasPrefix("new file mode") { current?.kind = .added; current?.previousPath = nil }
            else if line.hasPrefix("deleted file mode") { current?.kind = .deleted; current?.previousPath = nil }
            else if line.hasPrefix("rename from ") { current?.previousPath = String(line.dropFirst("rename from ".count)); current?.kind = .renamed }
            else if line.hasPrefix("rename to ") { current?.path = String(line.dropFirst("rename to ".count)); current?.kind = .renamed }
            else if line.hasPrefix("Binary files ") || line.hasPrefix("GIT binary patch") { current?.isBinary = true }
        }
        closeFile()
        guard recognized, !malformed else { return nil }
        let valid = files.filter { !$0.path.isEmpty || !$0.hunks.isEmpty }
        return valid.isEmpty ? nil : valid
    }

    /// Codex `fileChange` items carry one entry per path with a native kind and
    /// either a unified diff (update) or the whole content (add/delete).
    public static func codexChanges(_ value: JSONValue) -> [TranscriptFileChange] {
        let entries: [(String, JSONValue)]
        if let array = value.array { entries = array.prefix(512).compactMap { item in item["path"].string.map { ($0, item) } } }
        else if let object = value.object { entries = object.keys.sorted().prefix(512).map { ($0, object[$0]!) } }
        else { return [] }
        var result: [TranscriptFileChange] = [], lineCount = 0
        for (path, item) in entries.prefix(512) {
            if lineCount >= maximumLines {
                if !result.isEmpty { result[result.count - 1].isTruncated = true; result[result.count - 1].countsComplete = false }
                break
            }
            let change: TranscriptFileChange = {
            let type = item["kind"]["type"].string ?? item["type"].string ?? "update"
            let diff = item["diff"].string ?? item["unified_diff"].string ?? item["content"].string ?? ""
            let move = item["kind"]["move_path"].string ?? item["move_path"].string
            switch type {
            case "add": return TranscriptLineDiff.change(path: path, old: nil, new: diff, kind: .added, numbered: true)
            case "delete": return TranscriptLineDiff.change(path: path, old: diff, new: nil, kind: .deleted, numbered: true)
            default:
                var change = parse(diff, fallbackPath: path)?.first ?? .init(path: path, isTruncated: true, countsComplete: false)
                change.path = move ?? path
                if let move, !move.utf8.elementsEqual(path.utf8) { change.previousPath = path; change.kind = .renamed } else { change.kind = .modified; change.previousPath = nil }
                return change
            }
            }()
            lineCount += change.lineCount
            result.append(change)
        }
        let originalCount = value.array?.count ?? value.object?.count ?? 0
        if originalCount > result.count, !result.isEmpty {
            result[result.count - 1].isTruncated = true; result[result.count - 1].countsComplete = false
        }
        return result
    }

    private static func gitHeaderPaths(_ value: String) -> (String?, String?) {
        // `a/x b/x`; paths with spaces are ambiguous, so split on the last " b/".
        guard let range = value.range(of: " b/", options: .backwards) else { return (nil, nil) }
        let a = String(value[..<range.lowerBound]), b = String(value[range.upperBound...])
        return (a.hasPrefix("a/") ? String(a.dropFirst(2)) : a, b)
    }
    private static func headerPath(_ value: String) -> String? {
        var path = value
        if let tab = path.firstIndex(of: "\t") { path = String(path[..<tab]) }
        path = path.trimmingCharacters(in: .whitespaces)
        if path == "/dev/null" { return nil }
        if path.hasPrefix("a/") || path.hasPrefix("b/") { path = String(path.dropFirst(2)) }
        return path.isEmpty ? nil : path
    }
    struct HunkHeader: Equatable { var oldStart: Int; var oldCount: Int; var newStart: Int; var newCount: Int }
    static func hunkHeader(_ line: String) -> HunkHeader? {
        guard line.hasPrefix("@@ -"), let end = line.range(of: " @@", range: line.index(line.startIndex, offsetBy: 3)..<line.endIndex) else { return nil }
        let body = line[line.index(line.startIndex, offsetBy: 4)..<end.lowerBound]
        let parts = body.split(separator: " ")
        guard parts.count == 2, parts[1].hasPrefix("+") else { return nil }
        func range(_ value: Substring) -> (Int, Int)? {
            let pieces = value.split(separator: ",", omittingEmptySubsequences: false)
            guard let start = Int(pieces[0]), start >= 0 else { return nil }
            if pieces.count == 1 { return (start, 1) }
            guard pieces.count == 2, let count = Int(pieces[1]), count >= 0 else { return nil }
            return (start, count)
        }
        guard let old = range(parts[0]), let new = range(parts[1].dropFirst()),
              old.0 <= Int.max - old.1, new.0 <= Int.max - new.1 else { return nil }
        return .init(oldStart: old.0, oldCount: old.1, newStart: new.0, newCount: new.1)
    }
}

/// Line diff for provider edits that carry old/new text instead of a patch.
public enum TranscriptLineDiff {
    public static let contextLines = 3
    public static let maximumLines = 20_000
    public static let maximumBytes = 2 * 1_048_576
    private static let maximumDiffWork = 1_000_000

    public static func change(path: String, old: String?, new: String?, kind: TranscriptFileChange.Kind? = nil, numbered: Bool = false) -> TranscriptFileChange {
        let resolved = kind ?? (old == nil ? .added : new == nil ? .deleted : .modified)
        guard let oldLines = boundedLines(old), let newLines = boundedLines(new), oldLines.count + newLines.count <= maximumLines else {
            return .init(path: path, kind: resolved, isTruncated: true, countsComplete: false)
        }
        // Trim equal edges before computing a difference. A completely changed
        // large body gets a valid replacement diff instead of quadratic Myers
        // work. Unicode canonical equivalence never hides literal byte edits.
        func same(_ a: SourceLine, _ b: SourceLine) -> Bool {
            a.terminated == b.terminated && a.text.utf8.elementsEqual(b.text.utf8)
        }
        var prefix = 0, suffix = 0
        while prefix < min(oldLines.count, newLines.count), same(oldLines[prefix], newLines[prefix]) { prefix += 1 }
        while suffix < min(oldLines.count, newLines.count) - prefix,
              same(oldLines[oldLines.count - 1 - suffix], newLines[newLines.count - 1 - suffix]) { suffix += 1 }
        let oldRange = prefix..<(oldLines.count - suffix), newRange = prefix..<(newLines.count - suffix)
        var removed = Set<Int>(), inserted = Set<Int>()
        if oldRange.count * newRange.count > maximumDiffWork {
            removed.formUnion(oldRange); inserted.formUnion(newRange)
        } else {
            let difference = Array(newLines[newRange]).difference(from: Array(oldLines[oldRange]), by: same)
            for change in difference {
                switch change {
                case .remove(let offset, _, _): removed.insert(prefix + offset)
                case .insert(let offset, _, _): inserted.insert(prefix + offset)
                }
            }
        }
        var script: [TranscriptDiffLine] = []
        var i = 0, j = 0
        while i < oldLines.count || j < newLines.count {
            if i < oldLines.count, removed.contains(i) {
                script.append(.init(.deletion, oldLines[i].text, old: numbered ? i + 1 : nil))
                if !oldLines[i].terminated { script.append(.init(.note, "No newline at end of file")) }
                i += 1
            } else if j < newLines.count, inserted.contains(j) {
                script.append(.init(.addition, newLines[j].text, new: numbered ? j + 1 : nil))
                if !newLines[j].terminated { script.append(.init(.note, "No newline at end of file")) }
                j += 1
            } else if i < oldLines.count, j < newLines.count {
                script.append(.init(.context, oldLines[i].text, old: numbered ? i + 1 : nil, new: numbered ? j + 1 : nil))
                if !oldLines[i].terminated { script.append(.init(.note, "No newline at end of file")) }
                i += 1; j += 1
            }
            else { break }
        }
        return .init(path: path, kind: resolved, hunks: hunks(script, oldTotal: oldLines.count, newTotal: newLines.count),
                     additions: inserted.count, deletions: removed.count)
    }

    private struct SourceLine {
        let text: String
        let terminated: Bool
    }
    private static func boundedLines(_ text: String?) -> [SourceLine]? {
        guard let text, !text.isEmpty else { return [] }
        guard text.utf8.count <= maximumBytes else { return nil }
        let bytes = text.utf8
        var values: [SourceLine] = [], cursor = bytes.startIndex
        while cursor < bytes.endIndex {
            guard values.count < maximumLines else { return nil }
            let end = bytes[cursor...].firstIndex(of: 10) ?? bytes.endIndex
            let terminated = end < bytes.endIndex
            // A CR belongs to the file content. Only LF is the patch's line
            // separator; retaining CR distinguishes CRLF from LF edits.
            values.append(.init(text: String(decoding: bytes[cursor..<end], as: UTF8.self), terminated: terminated))
            cursor = terminated ? bytes.index(after: end) : end
        }
        return values
    }

    private static func hunks(_ script: [TranscriptDiffLine], oldTotal: Int, newTotal: Int) -> [TranscriptDiffHunk] {
        let changed = script.indices.filter { script[$0].kind == .addition || script[$0].kind == .deletion }
        guard !changed.isEmpty else { return [] }
        var ranges: [ClosedRange<Int>] = []
        for index in changed {
            let lower = max(0, index - contextLines)
            var upper = min(script.count - 1, index + contextLines)
            while upper + 1 < script.count, script[upper + 1].kind == .note { upper += 1 }
            if let last = ranges.last, lower <= last.upperBound + 1 { ranges[ranges.count - 1] = last.lowerBound...max(last.upperBound, upper) }
            else { ranges.append(lower...upper) }
        }
        // Old/new starting positions are counted from the script itself so
        // snippet diffs stay consistent without real file line numbers.
        var oldPositions: [Int] = [], newPositions: [Int] = []
        var o = 1, n = 1
        for line in script {
            oldPositions.append(o); newPositions.append(n)
            if line.kind == .context || line.kind == .deletion { o += 1 }
            if line.kind == .context || line.kind == .addition { n += 1 }
        }
        return ranges.map { range in
            let slice = Array(script[range])
            let oldCount = slice.filter { $0.kind == .context || $0.kind == .deletion }.count
            let newCount = slice.filter { $0.kind == .context || $0.kind == .addition }.count
            let oldStart = oldCount == 0 ? oldPositions[range.lowerBound] - 1 : oldPositions[range.lowerBound]
            let newStart = newCount == 0 ? newPositions[range.lowerBound] - 1 : newPositions[range.lowerBound]
            return .init(header: "@@ -\(oldStart),\(oldCount) +\(newStart),\(newCount) @@", lines: slice)
        }
    }
}
