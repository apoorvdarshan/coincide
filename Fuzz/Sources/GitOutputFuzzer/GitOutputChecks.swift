import Foundation
import FuzzSupport

/// Upper-case modes feed the rest of the input to a parser as raw git output and check what must hold
/// for any input. Lower-case modes build git output from the input the way git writes it and check
/// that the parser reads back exactly what was written.
enum GitOutputChecks {
    private static let modes: [UInt8: @Sendable ([UInt8]) -> Void] = [
        UInt8(ascii: "S"): { rawStatus(text($0)) },
        UInt8(ascii: "N"): { rawNumstat(text($0)) },
        UInt8(ascii: "W"): { rawWorktrees(text($0)) },
        UInt8(ascii: "Q"): { rawUnquote(text($0)) },
        UInt8(ascii: "B"): branchNames,
        UInt8(ascii: "s"): { statusRoundTrip(FuzzInput($0)) },
        UInt8(ascii: "n"): { numstatRoundTrip(FuzzInput($0)) },
        UInt8(ascii: "w"): { worktreesRoundTrip(FuzzInput($0)) },
        UInt8(ascii: "q"): { unquoteRoundTrip($0) },
    ]
    private static let modeKeys = modes.keys.sorted()

    static func run(_ bytes: [UInt8]) {
        guard let first = bytes.first else { return }
        let mode = modes[first] ?? modes[modeKeys[Int(first) % modeKeys.count]]!
        mode(Array(bytes.dropFirst()))
    }

    private static func text(_ bytes: [UInt8]) -> String { String(decoding: bytes, as: UTF8.self) }

    // MARK: Any input

    static func rawStatus(_ output: String) {
        let status = GitParse.porcelainV2(output)
        let records = output.split(separator: "\0", omittingEmptySubsequences: false).count
        expect(status.entries.count <= records, "more entries than records")
        for entry in status.entries {
            expect(["1", "2", "u", "?"].contains(entry.kind), "unexpected entry kind \(entry.kind)")
            expectEqual(entry.isConflicted, entry.kind == "u", "only unmerged entries conflict")
            if entry.kind == "?" { expectEqual(entry.status, .untracked, "untracked status") }
        }
    }

    static func rawNumstat(_ output: String) {
        let stats = GitParse.numstat(output)
        expect(stats.count <= output.split(separator: "\0", omittingEmptySubsequences: false).count, "too many records")
        for stat in stats {
            expect(!stat.path.isEmpty, "numstat path is empty")
            if stat.isBinary { expect(stat.additions == 0 && stat.deletions == 0, "binary file with line counts") }
        }
    }

    static func rawWorktrees(_ output: String) {
        let worktrees = GitParse.worktrees(output)
        for (index, worktree) in worktrees.enumerated() {
            expectEqual(worktree.isMain, index == 0, "only the first worktree is the main one")
        }
    }

    static func rawUnquote(_ value: String) {
        let result = GitParse.unquote(value)
        // By bytes, as git quotes: a combining mark after the opening quote does not hide it.
        let utf8 = Array(value.utf8)
        if !(utf8.count >= 2 && utf8.first == UInt8(ascii: "\"") && utf8.last == UInt8(ascii: "\"")) {
            expectEqual(result, value, "an unquoted path is returned as is")
        }
    }

    // MARK: Round trips

    /// `git status --porcelain=2 --branch -z`.
    static func statusRoundTrip(_ input: FuzzInput) {
        var input = input
        var records: [String] = []
        let oid = input.bool() ? nil : input.hex(40)
        records.append("# branch.oid \(oid ?? "(initial)")")
        let head = input.bool() ? nil : input.refName()
        records.append("# branch.head \(head ?? "(detached)")")
        let upstream = input.bool() ? input.refName() : nil
        var ahead = 0
        var behind = 0
        if let upstream {
            ahead = input.int(in: 0...70_000)
            behind = input.int(in: 0...70_000)
            records.append("# branch.upstream \(upstream)")
            records.append("# branch.ab +\(ahead) -\(behind)")
        }
        if input.bool() { records.append("# stash \(input.int(in: 0...9))") }

        let codes = [".", "M", "T", "A", "D", "R", "C", "U"]
        var expected: [GitParse.StatusEntry] = []
        for _ in 0..<input.int(in: 0...6) {
            let xy = input.pick(codes) + input.pick(codes)
            let path = input.gitPath()
            let modes = "100644 100644 100644"
            switch input.int(in: 0...4) {
            case 0:
                records.append("1 \(xy) N... \(modes) \(input.hex(40)) \(input.hex(40)) \(path)")
                expected.append(.init(kind: "1", xy: xy, path: path))
            case 1:
                let original = input.gitPath()
                let score = "\(input.pick(["R", "C"]))\(input.int(in: 0...100))"
                records.append("2 \(xy) N... \(modes) \(input.hex(40)) \(input.hex(40)) \(score) \(path)")
                records.append(original)
                expected.append(.init(kind: "2", xy: xy, path: path, originalPath: original))
            case 2:
                records.append("u \(xy) N... 100644 \(modes) \(input.hex(40)) \(input.hex(40)) \(input.hex(40)) \(path)")
                expected.append(.init(kind: "u", xy: xy, path: path))
            case 3:
                records.append("? \(path)")
                expected.append(.init(kind: "?", xy: "??", path: path))
            default:
                records.append("! \(path)")
            }
        }
        let output = records.map { $0 + "\0" }.joined()
        let status = GitParse.porcelainV2(output)
        expectEqual(status.oid, oid, "branch.oid of \(output.debugDescription)")
        expectEqual(status.head, head, "branch.head")
        expectEqual(status.upstream, upstream, "branch.upstream")
        expect(status.ahead == ahead && status.behind == behind, "branch.ab")
        expectEqual(status.entries, expected, "entries of \(output.debugDescription)")
    }

    /// `git diff --numstat -z`, with rename records split over three fields.
    static func numstatRoundTrip(_ input: FuzzInput) {
        var input = input
        var output = ""
        var expected: [GitParse.Numstat] = []
        for _ in 0..<input.int(in: 0...6) {
            let isBinary = input.int(in: 0...3) == 0
            let additions = isBinary ? 0 : input.int(in: 0...70_000)
            let deletions = isBinary ? 0 : input.int(in: 0...70_000)
            let counts = isBinary ? "-\t-\t" : "\(additions)\t\(deletions)\t"
            let path = input.gitPath()
            if input.bool() {
                let oldPath = input.gitPath()
                output += "\(counts)\0\(oldPath)\0\(path)\0"
                expected.append(.init(path: path, oldPath: oldPath, additions: additions, deletions: deletions, isBinary: isBinary))
            } else {
                output += "\(counts)\(path)\0"
                expected.append(.init(path: path, additions: additions, deletions: deletions, isBinary: isBinary))
            }
        }
        expectEqual(GitParse.numstat(output), expected, "numstat of \(output.debugDescription)")
    }

    /// `git worktree list --porcelain -z`: NUL after each attribute and an empty field after each worktree.
    static func worktreesRoundTrip(_ input: FuzzInput) {
        var input = input
        var output = ""
        var expected: [GitWorktree] = []
        for index in 0..<input.int(in: 0...4) {
            var worktree = GitWorktree(path: input.gitPath(), head: input.hex(40), isMain: index == 0)
            var fields = ["worktree \(worktree.path)", "HEAD \(worktree.head!)"]
            if input.bool() {
                let branch = input.refName()
                worktree.branch = branch
                fields.append("branch refs/heads/\(branch)")
            } else {
                fields.append("detached")
            }
            if input.bool() {
                worktree.isLocked = true
                fields.append(input.bool() ? "locked" : "locked \(input.lineText())")
            }
            if input.bool() {
                worktree.isPrunable = true
                fields.append(input.bool() ? "prunable" : "prunable \(input.lineText())")
            }
            output += fields.map { $0 + "\0" }.joined() + "\0"
            expected.append(worktree)
        }
        expectEqual(GitParse.worktrees(output), expected, "worktrees of \(output.debugDescription)")
    }

    /// Quoting any bytes as git does and unquoting them gives the bytes back.
    static func unquoteRoundTrip(_ bytes: [UInt8]) {
        let quoted = GitQuote.quoted(bytes, quotePath: true)
        expectEqual(GitParse.unquote(quoted), String(decoding: bytes, as: UTF8.self), "unquote(\(quoted))")
        // With core.quotePath=false the UTF-8 stays as is inside the quotes.
        let text = String(decoding: bytes, as: UTF8.self)
        let loose = GitQuote.quoted(Array(text.utf8), quotePath: false)
        expectEqual(GitParse.unquote(loose), text, "unquote(\(loose))")
    }

    // MARK: Branch names

    /// Lines: a request or fragment, a branch prefix, then existing branch names.
    static func branchNames(_ bytes: [UInt8]) {
        let lines = text(bytes).split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        let raw = lines.first ?? ""
        let existing = Array(lines.dropFirst(2).prefix(64))

        let fragment = BranchNames.sanitizeFragment(raw)
        checkRefFragment(fragment, allowSlash: true, context: "sanitizeFragment(\(raw.debugDescription))")
        expectEqual(BranchNames.sanitizeFragment(fragment), fragment, "sanitizeFragment is idempotent")

        let feature = BranchNames.featureBranchName(raw)
        expectEqual(feature, fragment.contains("/") ? fragment : "feature/\(fragment)", "featureBranchName")

        let available = BranchNames.availableFeatureBranchName(raw, existing: existing)
        let taken = Set(existing.map { $0.lowercased() })
        let parts = available.split(separator: "/")
        for end in parts.indices {
            let namespace = parts[...end].joined(separator: "/")
            expect(!taken.contains(namespace), "\(available) collides with existing \(namespace)")
        }
        expect(!taken.contains { $0.hasPrefix(available + "/") }, "\(available) is an existing namespace")

        let newRef = BranchNames.sanitizeNewRefName(raw)
        expect(!newRef.unicodeScalars.contains { " \t\n\r\u{0B}\u{0C}".unicodeScalars.contains($0) }, "whitespace left in \(newRef.debugDescription)")

        let remote = BranchNames.localName(fromRemoteRef: raw)
        expect(raw.hasSuffix(remote), "localName is a suffix of the remote ref")

        // Temporary worktree branches are recognized in both spellings.
        let prefix = BranchNames.sanitizeFragment(lines.count > 1 ? lines[1] : "") + "/"
        var input = FuzzInput(bytes)
        let branch = prefix + input.hex(8)
        expect(BranchNames.isTemporaryWorktreeBranch(branch, prefix: prefix), "\(branch) is temporary for \(prefix)")
        let flattened = BranchNames.flattenedTemporaryBranch(branch, prefix: prefix)
        expect(BranchNames.isTemporaryWorktreeBranch(flattened, prefix: prefix), "\(flattened) is temporary for \(prefix)")

        let descriptive = BranchNames.descriptiveBranch(for: raw, prefix: prefix)
        expect(descriptive.hasPrefix(prefix), "descriptiveBranch keeps the prefix")
        checkRefFragment(String(descriptive.dropFirst(prefix.count)), allowSlash: false, context: "descriptiveBranch")
    }

    /// Non-empty, at most 64 characters of `[a-z0-9/_-]`, no doubled `/` or `-`, no separator at either end.
    private static func checkRefFragment(_ value: String, allowSlash: Bool, context: String) {
        let allowed = Set("abcdefghijklmnopqrstuvwxyz0123456789_-" + (allowSlash ? "/" : ""))
        expect(!value.isEmpty && value.count <= 64, "\(context): length of \(value.debugDescription)")
        expect(value.allSatisfy(allowed.contains), "\(context): \(value.debugDescription) has other characters")
        expect(!value.contains("//") && !value.contains("--"), "\(context): \(value.debugDescription) repeats a separator")
        expect(!"./_-".contains(value.first!) && !"./_-".contains(value.last!), "\(context): \(value.debugDescription) starts or ends with a separator")
    }
}
