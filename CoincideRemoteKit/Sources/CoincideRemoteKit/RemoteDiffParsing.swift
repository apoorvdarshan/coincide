import Foundation

/// Splits git's unified diff into files, and reads a file's patch into lines for display.
public enum RemoteDiffParsing {
    /// The files of `git diff` output, each with its hunks. Files past `maxFiles`, and patch text past `maxPatchBytes`
    /// in total, are left out and the result marked truncated.
    public static func split(_ patch: String, title: String, maxFiles: Int = 300, maxPatchBytes: Int = 2_000_000) -> RemoteDiff {
        var files: [RemoteDiff.File] = []
        var current: RemoteDiff.File?
        var hunkLines: [Substring] = []
        var truncated = false
        var bytes = 0

        func finish() {
            guard var file = current else { return }
            let text = hunkLines.joined(separator: "\n")
            if bytes + text.utf8.count > maxPatchBytes {
                truncated = true
                file.patch = ""
            } else {
                file.patch = text
                bytes += text.utf8.count
            }
            if files.count < maxFiles { files.append(file) } else { truncated = true }
            current = nil
            hunkLines = []
        }

        for line in patch.split(separator: "\n", omittingEmptySubsequences: false) {
            if line.hasPrefix("diff --git ") {
                finish()
                let paths = Self.paths(fromHeader: line)
                current = RemoteDiff.File(path: paths.new, oldPath: paths.old == paths.new ? nil : paths.old, status: "modified")
                continue
            }
            guard current != nil else { continue }
            if hunkLines.isEmpty, !line.hasPrefix("@@") {
                // The file header between `diff --git` and the first hunk.
                if line.hasPrefix("new file mode") { current?.status = "added" }
                else if line.hasPrefix("deleted file mode") { current?.status = "deleted" }
                else if line.hasPrefix("rename from ") {
                    current?.status = "renamed"
                    current?.oldPath = String(line.dropFirst("rename from ".count))
                } else if line.hasPrefix("rename to ") {
                    current?.path = String(line.dropFirst("rename to ".count))
                } else if line.hasPrefix("Binary files ") || line.hasPrefix("GIT binary patch") {
                    current?.isBinary = true
                } else if line.hasPrefix("+++ "), line.dropFirst(4) != "/dev/null" {
                    let path = line.dropFirst(4)
                    current?.path = String(path.hasPrefix("b/") ? path.dropFirst(2) : path)
                }
                continue
            }
            if line.hasPrefix("+"), !line.hasPrefix("+++") || !hunkLines.isEmpty { current?.additions += 1 }
            if line.hasPrefix("-"), !line.hasPrefix("---") || !hunkLines.isEmpty { current?.deletions += 1 }
            hunkLines.append(line)
        }
        finish()
        return RemoteDiff(title: title, files: files, isTruncated: truncated)
    }

    /// `diff --git a/x b/y` → (x, y). Paths with spaces are split at the middle ` b/`.
    static func paths(fromHeader line: Substring) -> (old: String, new: String) {
        let rest = line.dropFirst("diff --git ".count)
        if let range = rest.range(of: " b/") {
            var old = rest[rest.startIndex..<range.lowerBound]
            if old.hasPrefix("a/") { old = old.dropFirst(2) }
            let new = rest[range.upperBound...]
            return (String(old), String(new))
        }
        return (String(rest), String(rest))
    }

    /// One line of a patch as the diff view draws it.
    public struct Line: Hashable, Sendable, Identifiable {
        public enum Kind: Sendable { case hunk, context, addition, deletion, note }
        public var id: Int
        public var kind: Kind
        public var text: String
        public var oldLine: Int?
        public var newLine: Int?
    }

    /// The lines of a file's patch, numbered from its hunk headers.
    public static func lines(of patch: String) -> [Line] {
        var result: [Line] = []
        var old = 0
        var new = 0
        for (index, raw) in patch.split(separator: "\n", omittingEmptySubsequences: false).enumerated() {
            let text = String(raw)
            if text.hasPrefix("@@") {
                let numbers = hunkStarts(text)
                old = numbers.old
                new = numbers.new
                result.append(Line(id: index, kind: .hunk, text: text))
            } else if text.hasPrefix("+") {
                result.append(Line(id: index, kind: .addition, text: String(text.dropFirst()), newLine: new))
                new += 1
            } else if text.hasPrefix("-") {
                result.append(Line(id: index, kind: .deletion, text: String(text.dropFirst()), oldLine: old))
                old += 1
            } else if text.hasPrefix("\\") {
                result.append(Line(id: index, kind: .note, text: text))
            } else if !(text.isEmpty && index > 0 && result.isEmpty) {
                result.append(Line(id: index, kind: .context, text: String(text.dropFirst()), oldLine: old, newLine: new))
                old += 1
                new += 1
            }
        }
        // A trailing newline in the patch leaves an empty context line at the end.
        if let last = result.last, last.kind == .context, last.text.isEmpty, patch.hasSuffix("\n") { result.removeLast() }
        return result
    }

    private static func hunkStarts(_ header: String) -> (old: Int, new: Int) {
        // @@ -12,7 +12,9 @@ section
        let parts = header.split(separator: " ")
        func start(_ prefix: Character) -> Int {
            guard let part = parts.first(where: { $0.first == prefix }) else { return 0 }
            return Int(part.dropFirst().split(separator: ",").first ?? "0") ?? 0
        }
        return (start("-"), start("+"))
    }
}
