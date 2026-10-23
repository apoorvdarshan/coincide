import Foundation

/// A lossless-enough model of `git diff` text for native review. Parsing never fails: unknown
/// headers are ignored, incomplete tails are marked truncated, and hunk bodies are bounded by
/// their declared counts so deleted lines beginning with `-- ` are never mistaken for headers.
public struct UnifiedDiffLine: Sendable, Equatable, Hashable {
    public enum Kind: String, Sendable { case context, addition, deletion, noNewline }
    public let kind: Kind
    public let text: String
    public let oldLine: Int?
    public let newLine: Int?
    public init(kind: Kind, text: String, oldLine: Int?, newLine: Int?) { self.kind = kind; self.text = text; self.oldLine = oldLine; self.newLine = newLine }
}

public struct UnifiedDiffSplitRow: Sendable, Equatable {
    public let left: UnifiedDiffLine?
    public let right: UnifiedDiffLine?
    public init(left: UnifiedDiffLine?, right: UnifiedDiffLine?) { self.left = left; self.right = right }
}

public struct UnifiedDiffHunk: Sendable, Equatable, Identifiable {
    public let id: Int
    public let header: String
    public let section: String?
    public let oldStart: Int
    public let oldCount: Int
    public let newStart: Int
    public let newCount: Int
    public var lines: [UnifiedDiffLine]
    public var isComplete: Bool

    /// Pairs each deletion run with the following addition run, as side-by-side reviewers expect.
    public var splitRows: [UnifiedDiffSplitRow] {
        var rows: [UnifiedDiffSplitRow] = [], deletions: [UnifiedDiffLine] = [], additions: [UnifiedDiffLine] = []
        func flush() {
            for index in 0..<max(deletions.count, additions.count) {
                rows.append(.init(left: index < deletions.count ? deletions[index] : nil, right: index < additions.count ? additions[index] : nil))
            }
            deletions.removeAll(); additions.removeAll()
        }
        for line in lines {
            switch line.kind {
            case .deletion: if !additions.isEmpty { flush() }; deletions.append(line)
            case .addition: additions.append(line)
            case .context: flush(); rows.append(.init(left: line, right: line))
            case .noNewline:
                // The marker belongs to the side of the line it follows.
                if let last = additions.last ?? deletions.last {
                    flush(); rows.append(last.kind == .addition ? .init(left: nil, right: line) : .init(left: line, right: nil))
                } else if let previous = rows.last {
                    rows.append(previous.left != nil && previous.right == nil ? .init(left: line, right: nil) : previous.right != nil && previous.left == nil ? .init(left: nil, right: line) : .init(left: line, right: line))
                } else { rows.append(.init(left: line, right: line)) }
            }
        }
        flush(); return rows
    }
}

public struct UnifiedDiffFile: Sendable, Equatable, Identifiable {
    public enum Status: String, Sendable { case modified, added, deleted, renamed, copied, untracked, modeChanged }
    public var oldPath: String?
    public var newPath: String?
    public var status: Status
    public var isBinary: Bool
    public var oldMode: String?
    public var newMode: String?
    public var similarity: Int?
    public var hunks: [UnifiedDiffHunk]
    public var isTruncated: Bool
    /// A preview note such as an unreadable untracked file.
    public var note: String?
    public var path: String { newPath ?? oldPath ?? "" }
    public var id: String { (oldPath ?? "") + "\u{0}" + (newPath ?? "") }
    public var additions: Int { hunks.reduce(0) { $0 + $1.lines.filter { $0.kind == .addition }.count } }
    public var deletions: Int { hunks.reduce(0) { $0 + $1.lines.filter { $0.kind == .deletion }.count } }
    public var lineCount: Int { hunks.reduce(0) { $0 + $1.lines.count } }
    /// First new-side line of the first change, for opening an editor near the edit.
    public var firstChangedLine: Int? {
        for hunk in hunks {
            var next = hunk.newStart
            for line in hunk.lines {
                switch line.kind {
                case .context: next = (line.newLine ?? next) + 1
                case .addition: return line.newLine
                case .deletion: return max(next, 1)
                case .noNewline: continue
                }
            }
        }
        return nil
    }
    public var fileExtension: String { (path.split(separator: "/").last.map(String.init) ?? "").split(separator: ".").dropFirst().last.map { String($0).lowercased() } ?? "" }
}

public struct UnifiedDiff: Sendable, Equatable {
    public var files: [UnifiedDiffFile]
    public var truncated: Bool
    public var additions: Int { files.reduce(0) { $0 + $1.additions } }
    public var deletions: Int { files.reduce(0) { $0 + $1.deletions } }
    public var isEmpty: Bool { files.isEmpty }
    public init(files: [UnifiedDiffFile] = [], truncated: Bool = false) { self.files = files; self.truncated = truncated }

    public static func parse(_ text: String, truncated: Bool = false) -> UnifiedDiff {
        var parser = Parser(lines: text.split(separator: "\n", omittingEmptySubsequences: false).map { $0.hasSuffix("\r") ? String($0.dropLast()) : String($0) })
        parser.run()
        if truncated, let last = parser.files.indices.last { parser.files[last].isTruncated = true }
        return .init(files: parser.files, truncated: truncated || parser.files.contains(where: \.isTruncated))
    }

    private struct Parser {
        let lines: [String]
        var index = 0
        var files: [UnifiedDiffFile] = []

        mutating func run() {
            while index < lines.count {
                let line = lines[index]
                if line.hasPrefix("diff --git ") || line.hasPrefix("diff --cc ") || line.hasPrefix("diff --combined ") { parseGitFile() }
                else if line.hasPrefix("+++ "), line.hasSuffix(" (untracked)") { parseSynthesizedUntracked() }
                else if line.hasPrefix("Binary or large untracked file: ") {
                    let path = String(line.dropFirst("Binary or large untracked file: ".count))
                    files.append(.init(oldPath: nil, newPath: path, status: .untracked, isBinary: true, hunks: [], isTruncated: false, note: line)); index += 1
                } else if line.hasPrefix("--- "), index + 1 < lines.count, lines[index + 1].hasPrefix("+++ ") { parsePlainFile() }
                else { index += 1 }
            }
        }

        private mutating func parseGitFile() {
            let header = lines[index]; index += 1
            var file = UnifiedDiffFile(oldPath: nil, newPath: nil, status: .modified, isBinary: false, hunks: [], isTruncated: false)
            let paths = Self.headerPaths(String(header.drop(while: { $0 != " " }).dropFirst().drop(while: { $0 != " " }).dropFirst()))
            var sawOldNull = false, sawNewNull = false
            while index < lines.count {
                let line = lines[index]
                if line.hasPrefix("diff --git ") || line.hasPrefix("diff --cc ") || line.hasPrefix("diff --combined ") || line.hasPrefix("@@") { break }
                if line.hasPrefix("+++ "), line.hasSuffix(" (untracked)") { break }
                index += 1
                if line.hasPrefix("old mode ") { file.oldMode = String(line.dropFirst(9)) }
                else if line.hasPrefix("new mode ") { file.newMode = String(line.dropFirst(9)) }
                else if line.hasPrefix("deleted file mode ") { file.status = .deleted; file.oldMode = String(line.dropFirst(18)) }
                else if line.hasPrefix("new file mode ") { file.status = .added; file.newMode = String(line.dropFirst(14)) }
                else if line.hasPrefix("rename from ") { file.status = .renamed; file.oldPath = Self.unquote(String(line.dropFirst(12))) }
                else if line.hasPrefix("rename to ") { file.status = .renamed; file.newPath = Self.unquote(String(line.dropFirst(10))) }
                else if line.hasPrefix("copy from ") { file.status = .copied; file.oldPath = Self.unquote(String(line.dropFirst(10))) }
                else if line.hasPrefix("copy to ") { file.status = .copied; file.newPath = Self.unquote(String(line.dropFirst(8))) }
                else if line.hasPrefix("similarity index ") { file.similarity = Int(line.dropFirst(17).dropLast()) }
                else if line.hasPrefix("Binary files ") || line == "GIT binary patch" { file.isBinary = true }
                else if line.hasPrefix("--- ") {
                    let value = String(line.dropFirst(4))
                    if value == "/dev/null" { sawOldNull = true } else if file.oldPath == nil { file.oldPath = Self.stripPrefix(Self.unquote(value), "a/") }
                } else if line.hasPrefix("+++ ") {
                    let value = String(line.dropFirst(4))
                    if value == "/dev/null" { sawNewNull = true } else if file.newPath == nil { file.newPath = Self.stripPrefix(Self.unquote(value), "b/") }
                }
            }
            if sawOldNull { file.status = file.status == .modified ? .added : file.status; file.oldPath = nil }
            if sawNewNull { file.status = .deleted; file.newPath = nil }
            if file.oldPath == nil, file.newPath == nil, let paths {
                if file.status != .added { file.oldPath = paths.old }
                if file.status != .deleted { file.newPath = paths.new }
            } else if file.status == .added, file.newPath == nil { file.newPath = paths?.new }
            else if file.status == .deleted, file.oldPath == nil { file.oldPath = paths?.old }
            else if file.status != .added, file.status != .deleted {
                if file.oldPath == nil { file.oldPath = paths?.old ?? file.newPath }
                if file.newPath == nil { file.newPath = paths?.new ?? file.oldPath }
            }
            if file.status == .modified, file.oldMode != nil, file.newMode != nil, file.oldMode != file.newMode { file.status = .modeChanged }
            parseHunks(into: &file)
            if file.status == .modeChanged, !file.hunks.isEmpty { file.status = .modified }
            files.append(file)
        }

        private mutating func parsePlainFile() {
            let old = String(lines[index].dropFirst(4)), new = String(lines[index + 1].dropFirst(4)); index += 2
            var file = UnifiedDiffFile(oldPath: old == "/dev/null" ? nil : Self.stripPrefix(Self.unquote(old), "a/"),
                                       newPath: new == "/dev/null" ? nil : Self.stripPrefix(Self.unquote(new), "b/"),
                                       status: old == "/dev/null" ? .added : new == "/dev/null" ? .deleted : .modified, isBinary: false, hunks: [], isTruncated: false)
            parseHunks(into: &file); files.append(file)
        }

        /// Coincide's preview format for readable untracked files: a `+++ path (untracked)` header
        /// followed by every line prefixed with `+`.
        private mutating func parseSynthesizedUntracked() {
            let header = lines[index]; index += 1
            let path = String(header.dropFirst(4).dropLast(" (untracked)".count))
            var body: [UnifiedDiffLine] = [], number = 0
            while index < lines.count, lines[index].hasPrefix("+"), !(lines[index].hasPrefix("+++ ") && lines[index].hasSuffix(" (untracked)")) {
                number += 1; body.append(.init(kind: .addition, text: String(lines[index].dropFirst()), oldLine: nil, newLine: number)); index += 1
            }
            // A trailing newline in the file produces one final empty "+" record.
            if body.count > 1, body.last?.text.isEmpty == true { body.removeLast() }
            else if body.count == 1, body[0].text.isEmpty { body.removeAll() }
            let hunk = UnifiedDiffHunk(id: 0, header: "@@ -0,0 +1,\(body.count) @@", section: nil, oldStart: 0, oldCount: 0, newStart: body.isEmpty ? 0 : 1, newCount: body.count, lines: body, isComplete: true)
            files.append(.init(oldPath: nil, newPath: path, status: .untracked, isBinary: false, hunks: body.isEmpty ? [] : [hunk], isTruncated: false))
        }

        private mutating func parseHunks(into file: inout UnifiedDiffFile) {
            while index < lines.count, lines[index].hasPrefix("@@") {
                guard let range = Self.hunkRange(lines[index]) else { index += 1; continue }
                let header = lines[index]; index += 1
                var oldRemaining = range.oldCount, newRemaining = range.newCount, oldLine = range.oldStart, newLine = range.newStart
                var body: [UnifiedDiffLine] = []
                while index < lines.count, oldRemaining > 0 || newRemaining > 0 || lines[index].hasPrefix("\\") {
                    let line = lines[index]
                    guard let marker = line.first else {
                        // Git always prefixes context; an empty record means the text ended early
                        // unless it is the final newline of the whole patch.
                        if index == lines.count - 1 { break }
                        body.append(.init(kind: .context, text: "", oldLine: oldLine, newLine: newLine)); oldLine += 1; newLine += 1
                        oldRemaining -= 1; newRemaining -= 1; index += 1; continue
                    }
                    let text = String(line.dropFirst())
                    switch marker {
                    case " " where oldRemaining > 0 && newRemaining > 0:
                        body.append(.init(kind: .context, text: text, oldLine: oldLine, newLine: newLine)); oldLine += 1; newLine += 1; oldRemaining -= 1; newRemaining -= 1
                    case "-" where oldRemaining > 0:
                        body.append(.init(kind: .deletion, text: text, oldLine: oldLine, newLine: nil)); oldLine += 1; oldRemaining -= 1
                    case "+" where newRemaining > 0:
                        body.append(.init(kind: .addition, text: text, oldLine: nil, newLine: newLine)); newLine += 1; newRemaining -= 1
                    case "\\":
                        body.append(.init(kind: .noNewline, text: text.trimmingCharacters(in: .whitespaces), oldLine: nil, newLine: nil))
                    default:
                        oldRemaining = -1 // inconsistent counts: treat as truncated
                    }
                    if oldRemaining < 0 { break }
                    index += 1
                }
                let complete = oldRemaining == 0 && newRemaining == 0
                file.hunks.append(.init(id: file.hunks.count, header: header, section: range.section, oldStart: range.oldStart, oldCount: range.oldCount,
                                        newStart: range.newStart, newCount: range.newCount, lines: body, isComplete: complete))
                if !complete { file.isTruncated = true; return }
            }
        }

        static func hunkRange(_ header: String) -> (oldStart: Int, oldCount: Int, newStart: Int, newCount: Int, section: String?)? {
            guard header.hasPrefix("@@ -") else { return nil }
            let rest = header.dropFirst(4)
            guard let close = rest.range(of: " @@") else { return nil }
            let ranges = rest[..<close.lowerBound].split(separator: " ")
            guard ranges.count == 2, ranges[1].hasPrefix("+") else { return nil }
            func parse(_ value: Substring) -> (Int, Int)? {
                let parts = value.split(separator: ",", omittingEmptySubsequences: false)
                guard let start = Int(parts[0]), start >= 0 else { return nil }
                if parts.count == 1 { return (start, 1) }
                guard parts.count == 2, let count = Int(parts[1]), count >= 0 else { return nil }
                return (start, count)
            }
            guard let old = parse(ranges[0]), let new = parse(ranges[1].dropFirst()) else { return nil }
            let section = rest[close.upperBound...].trimmingCharacters(in: .whitespaces)
            return (old.0, old.1, new.0, new.1, section.isEmpty ? nil : section)
        }

        /// `a/<path> b/<path>` with C-quoting when Git needed it. Unquoted paths containing
        /// spaces are only resolved when both sides are identical.
        static func headerPaths(_ value: String) -> (old: String, new: String)? {
            if value.hasPrefix("\"") {
                guard let (first, rest) = quotedPrefix(value) else { return nil }
                let second = rest.trimmingCharacters(in: .init(charactersIn: " "))
                let other = second.hasPrefix("\"") ? quotedPrefix(second)?.0 : second
                guard let other else { return nil }
                return (stripPrefix(first, "a/"), stripPrefix(other, "b/"))
            }
            if let space = value.range(of: " \"b/") {
                guard let other = quotedPrefix(String(value[value.index(after: space.lowerBound)...]))?.0 else { return nil }
                return (stripPrefix(String(value[..<space.lowerBound]), "a/"), stripPrefix(other, "b/"))
            }
            let count = value.count
            if count % 2 == 1 {
                let half = count / 2, start = value.prefix(half), end = value.suffix(half)
                if start.hasPrefix("a/"), end.hasPrefix("b/"), start.dropFirst(2) == end.dropFirst(2), value[value.index(value.startIndex, offsetBy: half)] == " " {
                    return (String(start.dropFirst(2)), String(end.dropFirst(2)))
                }
            }
            guard let split = value.range(of: " b/") else { return nil }
            return (stripPrefix(String(value[..<split.lowerBound]), "a/"), String(value[split.upperBound...]))
        }
        static func stripPrefix(_ value: String, _ prefix: String) -> String { value.hasPrefix(prefix) ? String(value.dropFirst(prefix.count)) : value }
        static func unquote(_ value: String) -> String {
            guard value.hasPrefix("\"") else { return value.hasSuffix("\t") ? String(value.dropLast()) : value }
            return quotedPrefix(value)?.0 ?? value
        }
        /// Decodes Git's C-style quoting, including octal UTF-8 bytes, lossily.
        static func quotedPrefix(_ value: String) -> (String, String)? {
            let all = Array(value.utf8)
            var bytes: [UInt8] = [], position = 1
            func next() -> UInt8? { guard position < all.count else { return nil }; defer { position += 1 }; return all[position] }
            while let byte = next() {
                if byte == 34 { return (String(decoding: bytes, as: UTF8.self), String(decoding: all[position...], as: UTF8.self)) }
                guard byte == 92 else { bytes.append(byte); continue }
                guard let escaped = next() else { return nil }
                switch escaped {
                case 110: bytes.append(10)
                case 116: bytes.append(9)
                case 114: bytes.append(13)
                case 97: bytes.append(7)
                case 98: bytes.append(8)
                case 102: bytes.append(12)
                case 118: bytes.append(11)
                case 48...55:
                    var code = Int(escaped - 48)
                    for _ in 0..<2 { guard let digit = next(), (48...55).contains(digit) else { return nil }; code = code * 8 + Int(digit - 48) }
                    guard code <= 255 else { return nil }; bytes.append(UInt8(code))
                default: bytes.append(escaped)
                }
            }
            return nil
        }
    }
}
