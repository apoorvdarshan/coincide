import Foundation

/// Parsers for git's machine-readable output.
enum GitParse {
    struct StatusEntry: Sendable, Hashable {
        /// `1` ordinary, `2` renamed or copied, `u` unmerged, `?` untracked.
        var kind: Character
        /// Index and work tree status letters, `.` when unchanged.
        var xy: String
        var path: String
        var originalPath: String?

        var status: ChangedFile.Status {
            switch kind {
            case "?": return .untracked
            case "2": return xy.contains("C") ? .added : .renamed
            case "u": return .modified
            default:
                if xy.contains("A") { return .added }
                if xy.contains("D") { return .deleted }
                return .modified
            }
        }

        var isConflicted: Bool { kind == "u" }
    }

    struct Status: Sendable, Hashable {
        var oid: String?
        var head: String?
        var upstream: String?
        var ahead = 0
        var behind = 0
        var entries: [StatusEntry] = []
    }

    /// Parses `git status --porcelain=2 --branch -z`.
    static func porcelainV2(_ output: String) -> Status {
        var status = Status()
        let records = output.split(separator: "\0", omittingEmptySubsequences: false)
        var index = 0
        while index < records.count {
            let record = records[index]
            index += 1
            guard let first = record.first else { continue }
            if record.hasPrefix("# ") {
                let parts = record.dropFirst(2).split(separator: " ", maxSplits: 1)
                guard parts.count == 2 else { continue }
                let value = String(parts[1])
                switch parts[0] {
                case "branch.oid": status.oid = value == "(initial)" ? nil : value
                case "branch.head": status.head = value == "(detached)" ? nil : value
                case "branch.upstream": status.upstream = value
                case "branch.ab":
                    let numbers = value.split(separator: " ").map { Int($0.dropFirst()) ?? 0 }
                    if numbers.count == 2 {
                        status.ahead = numbers[0]
                        status.behind = numbers[1]
                    }
                default: break
                }
                continue
            }
            let fieldsBeforePath: Int
            switch first {
            case "1": fieldsBeforePath = 8
            case "2": fieldsBeforePath = 9
            case "u": fieldsBeforePath = 10
            case "?", "!": fieldsBeforePath = 1
            default: continue
            }
            if first == "!" { continue }
            let fields = record.split(separator: " ", maxSplits: fieldsBeforePath, omittingEmptySubsequences: false)
            guard fields.count == fieldsBeforePath + 1 else { continue }
            let xy = fieldsBeforePath > 1 ? String(fields[1]) : "??"
            var entry = StatusEntry(kind: first, xy: xy, path: String(fields[fieldsBeforePath]))
            // A rename record is followed by its original path as a separate record.
            if first == "2", index < records.count {
                entry.originalPath = String(records[index])
                index += 1
            }
            status.entries.append(entry)
        }
        return status
    }

    struct Numstat: Sendable, Hashable {
        var path: String
        var oldPath: String?
        var additions: Int
        var deletions: Int
        var isBinary: Bool
    }

    /// Parses `git diff --numstat -z`, including rename records (`adds\tdels\t\0old\0new\0`).
    static func numstat(_ output: String) -> [Numstat] {
        let fields = output.split(separator: "\0", omittingEmptySubsequences: false)
        var result: [Numstat] = []
        var index = 0
        while index < fields.count {
            let field = fields[index]
            index += 1
            let parts = field.split(separator: "\t", maxSplits: 2, omittingEmptySubsequences: false)
            guard parts.count == 3 else { continue }
            let isBinary = parts[0] == "-" && parts[1] == "-"
            let additions = Int(parts[0]) ?? 0
            let deletions = Int(parts[1]) ?? 0
            var path = String(parts[2])
            var oldPath: String?
            if path.isEmpty {
                guard index + 1 < fields.count else { break }
                oldPath = String(fields[index])
                path = String(fields[index + 1])
                index += 2
            }
            guard !path.isEmpty else { continue }
            result.append(
                Numstat(path: path, oldPath: oldPath, additions: additions, deletions: deletions, isBinary: isBinary))
        }
        return result
    }

    /// Parses `git worktree list --porcelain -z`.
    static func worktrees(_ output: String) -> [GitWorktree] {
        var result: [GitWorktree] = []
        var current: GitWorktree?
        for field in output.split(separator: "\0", omittingEmptySubsequences: false) {
            if field.isEmpty {
                if let worktree = current { result.append(worktree) }
                current = nil
            } else if field.hasPrefix("worktree ") {
                if let worktree = current { result.append(worktree) }
                current = GitWorktree(path: String(field.dropFirst("worktree ".count)), isMain: result.isEmpty)
            } else if field.hasPrefix("HEAD ") {
                current?.head = String(field.dropFirst("HEAD ".count))
            } else if field.hasPrefix("branch ") {
                let ref = field.dropFirst("branch ".count)
                current?.branch = ref.hasPrefix("refs/heads/") ? String(ref.dropFirst("refs/heads/".count)) : String(ref)
            } else if field == "prunable" || field.hasPrefix("prunable ") {
                current?.isPrunable = true
            } else if field == "locked" || field.hasPrefix("locked ") {
                current?.isLocked = true
            }
        }
        if let worktree = current { result.append(worktree) }
        return result
    }

    /// Non-empty NUL-separated fields.
    static func nulFields(_ output: String) -> [String] {
        output.split(separator: "\0").map(String.init)
    }

    /// Non-empty trimmed lines.
    static func lines(_ output: String) -> [String] {
        output.split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
    }

    /// Undoes git's C-style quoting of a path (`"a\tb"`, octal escapes for raw bytes).
    static func unquote<S: StringProtocol>(_ value: S) -> String {
        guard value.count >= 2, value.first == "\"", value.last == "\"" else { return String(value) }
        var bytes: [UInt8] = []
        var iterator = Array(value.utf8.dropFirst().dropLast())[...]
        while let byte = iterator.popFirst() {
            guard byte == UInt8(ascii: "\\"), let next = iterator.popFirst() else {
                bytes.append(byte)
                continue
            }
            switch next {
            case UInt8(ascii: "n"): bytes.append(0x0A)
            case UInt8(ascii: "t"): bytes.append(0x09)
            case UInt8(ascii: "r"): bytes.append(0x0D)
            case UInt8(ascii: "a"): bytes.append(0x07)
            case UInt8(ascii: "b"): bytes.append(0x08)
            case UInt8(ascii: "f"): bytes.append(0x0C)
            case UInt8(ascii: "v"): bytes.append(0x0B)
            case UInt8(ascii: "0")...UInt8(ascii: "7"):
                var octal = Int(next - UInt8(ascii: "0"))
                for _ in 0..<2 {
                    guard let digit = iterator.first, (UInt8(ascii: "0")...UInt8(ascii: "7")).contains(digit) else { break }
                    octal = octal * 8 + Int(digit - UInt8(ascii: "0"))
                    iterator.removeFirst()
                }
                bytes.append(UInt8(truncatingIfNeeded: octal))
            default: bytes.append(next)
            }
        }
        return String(decoding: bytes, as: UTF8.self)
    }
}

/// Splits a unified diff (as produced with `--src-prefix=a/ --dst-prefix=b/`) into files and hunks.
enum DiffParser {
    static func parse(_ patch: String) -> [FileDiff] {
        var files: [FileDiff] = []
        var file: FileDiff?
        var hunk: DiffHunk?
        var oldRemaining = 0
        var newRemaining = 0
        var oldLine = 0
        var newLine = 0
        var inBinaryPatch = false

        func finishHunk() {
            if let finished = hunk { file?.hunks.append(finished) }
            hunk = nil
        }
        func finishFile() {
            finishHunk()
            if let finished = file { files.append(finished) }
            file = nil
            inBinaryPatch = false
        }

        for rawLine in patch.utf8.split(separator: 0x0A, omittingEmptySubsequences: false) {
            var line = Substring(rawLine)
            if line.hasSuffix("\r") { line = line.dropLast() }

            if line.hasPrefix("diff --git ") {
                finishFile()
                let paths = headerPaths(line.dropFirst("diff --git ".count))
                file = FileDiff(path: paths.new, oldPath: nil, status: .modified)
                continue
            }
            guard file != nil else { continue }

            if hunk != nil, oldRemaining > 0 || newRemaining > 0 {
                let marker = line.first
                let text = String(line.dropFirst())
                switch marker {
                case "+":
                    hunk?.lines.append(DiffLine(kind: .addition, text: text, newLine: newLine))
                    newLine += 1
                    newRemaining -= 1
                    file?.additions += 1
                case "-":
                    hunk?.lines.append(DiffLine(kind: .deletion, text: text, oldLine: oldLine))
                    oldLine += 1
                    oldRemaining -= 1
                    file?.deletions += 1
                case "\\":
                    hunk?.lines.append(DiffLine(kind: .noNewline, text: String(line)))
                default:
                    // A context line; an empty line is context whose leading space was stripped.
                    hunk?.lines.append(DiffLine(kind: .context, text: text, oldLine: oldLine, newLine: newLine))
                    oldLine += 1
                    newLine += 1
                    oldRemaining -= 1
                    newRemaining -= 1
                }
                continue
            }

            if line.hasPrefix("@@") {
                finishHunk()
                guard let parsed = hunkHeader(line) else { continue }
                hunk = parsed
                oldLine = parsed.oldStart
                newLine = parsed.newStart
                oldRemaining = parsed.oldCount
                newRemaining = parsed.newCount
                continue
            }
            if line.hasPrefix("\\") {
                hunk?.lines.append(DiffLine(kind: .noNewline, text: String(line)))
                continue
            }
            if inBinaryPatch { continue }

            if line.hasPrefix("new file mode") {
                file?.status = .added
            } else if line.hasPrefix("deleted file mode") {
                file?.status = .deleted
            } else if line.hasPrefix("old mode ") {
                file?.modeChange = String(line.dropFirst("old mode ".count))
            } else if line.hasPrefix("new mode ") {
                let old = file?.modeChange ?? ""
                file?.modeChange = "\(old) → \(line.dropFirst("new mode ".count))"
            } else if line.hasPrefix("rename from ") {
                file?.oldPath = GitParse.unquote(line.dropFirst("rename from ".count))
                file?.status = .renamed
            } else if line.hasPrefix("rename to ") {
                file?.path = GitParse.unquote(line.dropFirst("rename to ".count))
            } else if line.hasPrefix("copy to ") {
                file?.path = GitParse.unquote(line.dropFirst("copy to ".count))
                file?.status = .added
            } else if line.hasPrefix("Binary files ") {
                file?.isBinary = true
            } else if line.hasPrefix("GIT binary patch") {
                file?.isBinary = true
                inBinaryPatch = true
            } else if line.hasPrefix("--- ") {
                if let path = markerPath(line.dropFirst(4), prefix: "a/"), file?.status != .renamed {
                    let newPath = file?.path
                    file?.oldPath = path == newPath ? nil : path
                }
            } else if line.hasPrefix("+++ ") {
                if let path = markerPath(line.dropFirst(4), prefix: "b/") {
                    file?.path = path
                }
            }
        }
        finishFile()
        return files
    }

    /// Paths from `a/<old> b/<new>`, which are ambiguous when names contain " b/".
    private static func headerPaths(_ value: Substring) -> (old: String, new: String) {
        if value.hasPrefix("\"") {
            var index = value.index(after: value.startIndex)
            var escaped = false
            while index < value.endIndex {
                let character = value[index]
                if escaped {
                    escaped = false
                } else if character == "\\" {
                    escaped = true
                } else if character == "\"" {
                    break
                }
                index = value.index(after: index)
            }
            let end = index < value.endIndex ? value.index(after: index) : value.endIndex
            let old = stripPrefix(GitParse.unquote(value[..<end]), "a/")
            let rest = value[end...].drop { $0 == " " }
            return (old, stripPrefix(GitParse.unquote(rest), "b/"))
        }
        // Without a rename both halves are the same path, so split where they match.
        let characters = Array(value)
        if characters.count >= 5, (characters.count - 5) % 2 == 0 {
            let length = (characters.count - 5) / 2
            let left = String(characters[2..<(2 + length)])
            let right = String(characters[(5 + length)...])
            if left == right, value.hasPrefix("a/") { return (left, right) }
        }
        if let range = value.range(of: " b/", options: .backwards) {
            return (stripPrefix(String(value[..<range.lowerBound]), "a/"), String(value[range.upperBound...]))
        }
        return (String(value), String(value))
    }

    private static func markerPath(_ value: Substring, prefix: String) -> String? {
        var trimmed = value
        // git appends a tab after names that contain spaces.
        if trimmed.hasSuffix("\t") { trimmed = trimmed.dropLast() }
        if trimmed == "/dev/null" { return nil }
        return stripPrefix(GitParse.unquote(trimmed), prefix)
    }

    private static func stripPrefix(_ value: String, _ prefix: String) -> String {
        value.hasPrefix(prefix) ? String(value.dropFirst(prefix.count)) : value
    }

    /// No file in a diff has this many lines. Capping hunk numbers here keeps the line numbers and counts
    /// `parse` steps from them, once per line of the patch, from overflowing.
    private static let maxLineNumber = Int(Int32.max)

    /// Parses `@@ -a,b +c,d @@ section`; a missing count means 1. A negative or absurdly large number,
    /// which git never writes, makes the line not a hunk header.
    static func hunkHeader(_ line: Substring) -> DiffHunk? {
        let parts = line.split(separator: " ", maxSplits: 4, omittingEmptySubsequences: true)
        guard parts.count >= 4, parts[0] == "@@", parts[3] == "@@" || parts[3].hasPrefix("@@") else { return nil }
        func range(_ value: Substring) -> (Int, Int)? {
            let pieces = value.dropFirst().split(separator: ",", omittingEmptySubsequences: false)
            guard let start = Int(pieces[0]) else { return nil }
            let count = pieces.count > 1 ? Int(pieces[1]) ?? 1 : 1
            guard (0...maxLineNumber).contains(start), (0...maxLineNumber).contains(count) else { return nil }
            return (start, count)
        }
        guard let old = range(parts[1]), let new = range(parts[2]) else { return nil }
        let section = parts.count > 4 ? String(parts[4]) : ""
        return DiffHunk(oldStart: old.0, oldCount: old.1, newStart: new.0, newCount: new.1, section: section)
    }
}

/// Branch naming rules shared by worktrees, feature branches and the branch picker.
public enum BranchNames {
    /// Lowercase, hyphenated and ref-safe, at most 64 characters.
    public nonisolated static func sanitizeFragment(_ raw: String) -> String {
        var value = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        value = value.replacingOccurrences(of: "['\"`]", with: "", options: .regularExpression)
        value = value.replacingOccurrences(of: "[^a-z0-9/_-]+", with: "-", options: .regularExpression)
        value = value.replacingOccurrences(of: "/+", with: "/", options: .regularExpression)
        value = value.replacingOccurrences(of: "-+", with: "-", options: .regularExpression)
        value = value.replacingOccurrences(of: "^[./_-]+|[./_-]+$", with: "", options: .regularExpression)
        value = String(value.prefix(64)).replacingOccurrences(of: "[./_-]+$", with: "", options: .regularExpression)
        return value.isEmpty ? "update" : value
    }

    /// `feature/<fragment>` unless the fragment already has a namespace.
    public nonisolated static func featureBranchName(_ raw: String) -> String {
        let fragment = sanitizeFragment(raw)
        return fragment.contains("/") ? fragment : "feature/\(fragment)"
    }

    /// Whitespace becomes hyphens; anything else is left to `git check-ref-format`.
    public nonisolated static func sanitizeNewRefName(_ raw: String) -> String {
        raw.trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "[ \t\n\r\u{0B}\u{0C}]+", with: "-", options: .regularExpression)
    }

    /// `origin/feature/x` → `feature/x`.
    public nonisolated static func localName(fromRemoteRef name: String) -> String {
        guard let slash = name.firstIndex(of: "/"), slash != name.startIndex, name.index(after: slash) != name.endIndex
        else { return name }
        return String(name[name.index(after: slash)...])
    }

    /// Picks `preferred` or the first `-2`, `-3`… variant no existing branch (or branch namespace) uses.
    public nonisolated static func availableFeatureBranchName(_ preferred: String, existing: [String]) -> String {
        let names = existing.map { $0.lowercased() }
        let taken = Set(names)
        let parts = featureBranchName(preferred).split(separator: "/").map(String.init)
        var resolved = ""
        for (index, part) in parts.enumerated() {
            let base = resolved.isEmpty ? part : "\(resolved)/\(part)"
            var candidate = base
            var suffix = 2
            while taken.contains(candidate)
                || (index == parts.count - 1 && names.contains(where: { $0.hasPrefix(candidate + "/") }))
            {
                candidate = "\(base)-\(suffix)"
                suffix += 1
            }
            resolved = candidate
        }
        return resolved
    }

    /// A throwaway name for a new worktree, renamed once the thread's first message arrives.
    public nonisolated static func temporaryWorktreeBranch(prefix: String) -> String {
        let token = UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased().prefix(8)
        return "\(prefix)\(token)"
    }

    /// `prefix/<token>` becomes `prefix-<token>` when a branch named `prefix` blocks nested refs.
    public nonisolated static func flattenedTemporaryBranch(_ branch: String, prefix: String) -> String {
        let base = prefix.hasSuffix("/") ? String(prefix.dropLast()) : prefix
        return "\(base)-\(branch.suffix(8))"
    }

    public nonisolated static func isTemporaryWorktreeBranch(_ branch: String, prefix: String) -> Bool {
        let base = prefix.hasSuffix("/") ? String(prefix.dropLast()) : prefix
        let escaped = NSRegularExpression.escapedPattern(for: base)
        let pattern =
            base.isEmpty
            ? "^[0-9a-f]{8}$"
            : "^\(NSRegularExpression.escapedPattern(for: prefix))[0-9a-f]{8}$|^\(escaped)-[0-9a-f]{8}$"
        return branch.range(of: pattern, options: .regularExpression) != nil
    }

    private nonisolated static let fillerWords: Set<String> = [
        "a", "an", "the", "please", "pls", "can", "could", "would", "you", "i", "we", "me", "us", "lets", "let's",
        "kindly", "just", "hey", "hi",
    ]

    /// A short branch name describing a request, such as `coincide/fix-login-redirect`.
    public nonisolated static func descriptiveBranch(for message: String, prefix: String) -> String {
        let firstLine = message.split(whereSeparator: \.isNewline).first.map(String.init) ?? message
        let words = firstLine.lowercased()
            .split(whereSeparator: { !$0.isLetter && !$0.isNumber && $0 != "'" })
            .map(String.init)
            .filter { !fillerWords.contains($0) }
        var fragment = ""
        for word in words.prefix(5) {
            let candidate = fragment.isEmpty ? word : "\(fragment)-\(word)"
            if candidate.count > 40 { break }
            fragment = candidate
        }
        let sanitized = sanitizeFragment(fragment.isEmpty ? "update" : fragment).replacingOccurrences(of: "/", with: "-")
        return prefix + sanitized
    }
}
