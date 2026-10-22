import Foundation

extension GitCheckpointService {
    /// A bounded display patch over owned copies. Never used as a write manifest.
    func restorePreview(before: [CheckpointRestoreNode], desired: [CheckpointRestoreNode], context: Context,
                        shadow: GitWorktreeDirectory, data: GitWorktreeDirectory, staging: Staging,
                        deadline: ContinuousClock.Instant, scope: String) async throws -> GitCheckpointDiff {
        let old = Dictionary(uniqueKeysWithValues: before.map { ($0.path, $0) }), new = Dictionary(uniqueKeysWithValues: desired.map { ($0.path, $0) })
        let paths = Set(old.keys).union(new.keys).sorted().filter { path in
            if let a = old[path], let b = new[path] { return !a.sameContents(b) }; return true
        }
        guard !paths.isEmpty else { return .init(patch: "", truncated: false) }
        let preview = try data.claimDirectory("preview")
        let limit = 1_048_576
        var patch = Data(), truncated = false, pairs = 0
        let encoder = JSONEncoder(); encoder.outputFormatting = [.withoutEscapingSlashes]
        func quoted(_ value: String) throws -> String { String(decoding: try encoder.encode(value), as: UTF8.self) }
        for path in paths {
            let a = old[path], b = new[path]
            if a?.kind == .directory || b?.kind == .directory { truncated = true; continue }
            if (a?.length ?? 0) > limit || (b?.length ?? 0) > limit { truncated = true; continue }
            guard pairs < 128, patch.count < limit else { truncated = true; break }
            let pair = try preview.claimDirectory(String(pairs)); pairs += 1
            if let a { try CheckpointRestoreFiles.copyNode(a, from: context.repository, to: pair, name: "before") }
            if let b { try CheckpointRestoreFiles.copyNode(b, from: shadow, to: pair, name: "after") }
            let args = ["diff", "--no-index", "--no-color", "--no-ext-diff", "--no-textconv", "--no-renames", "--",
                        a == nil ? "/dev/null" : "before.file", b == nil ? "/dev/null" : "after.file"]
            let result = try await command.run(Self.safeOptions + args, cwdFD: pair.fd, timeout: remaining(deadline), maximumOutput: limit - patch.count,
                gitDirectory: staging.admin.path, commonDirectory: staging.admin.path, workTree: shadow.path,
                checkpointIndexPath: staging.admin.path + "/index", allowTruncatedOutput: true, checkpointObjectDirectory: context.objects.path)
            guard result.status == 0 || result.status == 1 || result.stdoutOverflow else { throw GitCheckpointRestoreError(.commandFailed) }
            try pair.validate(); try shadow.validate(); try context.objects.validate()
            let relative = scope.isEmpty ? path : String(path.dropFirst(scope.count + 1))
            let left = try quoted("a/" + relative), right = try quoted("b/" + relative)
            let text = String(decoding: result.output, as: UTF8.self)
            var published = ""
            for line in text.split(separator: "\n", omittingEmptySubsequences: false).dropLast(text.hasSuffix("\n") ? 1 : 0) {
                if line.hasPrefix("diff --git ") { published += "diff --git " + left + " " + right }
                else if line.hasPrefix("--- ") { published += "--- " + (a == nil ? "/dev/null" : left) }
                else if line.hasPrefix("+++ ") { published += "+++ " + (b == nil ? "/dev/null" : right) }
                else if line.hasPrefix("Binary files ") { published += "Binary files " + (a == nil ? "/dev/null" : left) + " and " + (b == nil ? "/dev/null" : right) + " differ" }
                else { published += line }
                published += "\n"
            }
            let redacted = Data(GitService.redactURLs(published).utf8)
            if redacted.count > limit - patch.count { truncated = true }
            patch.append(redacted.prefix(limit - patch.count))
            if result.stdoutOverflow { truncated = true; break }
        }
        while !patch.isEmpty, String(data: patch, encoding: .utf8) == nil { patch.removeLast(); truncated = true }
        return .init(patch: String(decoding: patch, as: UTF8.self), truncated: truncated)
    }
}
