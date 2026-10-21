import Foundation

extension GitWorktreeService {
    /// NUL fields and empty NUL records are the only separators. Quoted/newline path parsing
    /// would corrupt valid worktree names, so the human-readable porcelain form is not used.
    public static func parseInventory(_ data: Data, sourcePath: String, commonDirectoryPath: String) throws -> GitWorktreeInventory {
        func malformed() -> GitWorktreeError { .init(.commandFailed, "Git returned incomplete or unsupported worktree inventory.") }
        guard data.count >= 2, data.suffix(2).allSatisfy({ $0 == 0 }), String(data: data, encoding: .utf8) != nil else { throw malformed() }
        var path: String?, head: String?, branch: String?, bare = false, detached = false
        var locked: String?, prunable: String?, saw = Set<String>(), worktrees: [GitWorktree] = [], paths = Set<String>()
        func finish() throws {
            guard let current = path, !saw.isEmpty, paths.insert(current).inserted,
                  bare ? (head == nil && branch == nil && !detached) : (detached ? (branch == nil && head != nil) : branch != nil) else { throw malformed() }
            worktrees.append(.init(path: current, headCommit: head, branch: branch, isBare: bare, isDetached: detached, lockedReason: locked, prunableReason: prunable))
            guard worktrees.count <= 25_000 else { throw GitWorktreeError(.outputLimit, "This repository has too many registered worktrees to list safely.") }
            path = nil; head = nil; branch = nil; bare = false; detached = false; locked = nil; prunable = nil; saw = []
        }
        for bytes in data.split(separator: 0, omittingEmptySubsequences: false).dropLast() {
            if bytes.isEmpty { try finish(); continue }
            let text = String(decoding: bytes, as: UTF8.self)
            let parts = text.split(separator: " ", maxSplits: 1, omittingEmptySubsequences: false)
            let field = String(parts[0]), value = parts.count == 2 ? String(parts[1]) : nil
            if field == "worktree" {
                guard path == nil, saw.isEmpty, let value else { throw malformed() }
                try WorktreeValidation.path(value); path = value; saw.insert(field); continue
            }
            guard path != nil else { throw malformed() }
            switch field {
            case "HEAD", "branch", "bare", "detached", "locked", "prunable":
                guard saw.insert(field).inserted else { throw malformed() }
            default: continue // Git's porcelain fields are extensible.
            }
            switch field {
            case "HEAD":
                guard let value else { throw malformed() }; try WorktreeValidation.commit(value)
                head = value.allSatisfy({ $0 == "0" }) ? nil : value
            case "branch":
                guard let value, value.hasPrefix("refs/heads/") else { throw malformed() }
                let name = String(value.dropFirst("refs/heads/".count)); try WorktreeValidation.branch(name); branch = name
            case "bare": guard value == nil else { throw malformed() }; bare = true
            case "detached": guard value == nil else { throw malformed() }; detached = true
            case "locked": locked = value ?? ""
            case "prunable": prunable = value ?? ""
            default: break
            }
        }
        guard path == nil, !worktrees.isEmpty else { throw malformed() }
        return .init(sourcePath: sourcePath, commonDirectoryPath: commonDirectoryPath, worktrees: worktrees)
    }
}
