import Foundation

public struct ChangedFile: Sendable, Identifiable, Equatable {
    public var path: String
    public var previousPath: String?
    public var indexStatus: Character
    public var worktreeStatus: Character
    public var id: String { path }
    public var isUntracked: Bool { indexStatus == "?" && worktreeStatus == "?" }
    public var isStaged: Bool { indexStatus != " " && indexStatus != "?" }
    public var status: String { String([indexStatus, worktreeStatus]) }
}
public struct GitSnapshot: Sendable {
    public var branch: String
    public var changes: [ChangedFile]
}

public struct GitService: Sendable {
    public let root: URL
    public init(root: URL) { self.root = root }
    public func status() async throws -> GitSnapshot {
        let data = try await command(["status", "--porcelain=v1", "-z", "--untracked-files=all"])
        let branch = try await command(["rev-parse", "--abbrev-ref", "HEAD"])
        return GitSnapshot(branch: String(decoding: branch, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines),
                           changes: try Self.parseStatus(data))
    }
    public static func parseStatus(_ data: Data) throws -> [ChangedFile] {
        let fields = data.split(separator: 0, omittingEmptySubsequences: false)
        var files: [ChangedFile] = [], i = 0
        while i < fields.count, !fields[i].isEmpty {
            let field = fields[i]; i += 1
            guard field.count >= 4, field[field.startIndex + 2] == 32 else { throw CoincideError("Malformed Git status.") }
            let x = Character(UnicodeScalar(field[field.startIndex])), y = Character(UnicodeScalar(field[field.startIndex + 1]))
            let path = String(decoding: field.dropFirst(3), as: UTF8.self)
            var previous: String?
            if x == "R" || x == "C" || y == "R" || y == "C" {
                guard i < fields.count, !fields[i].isEmpty else { throw CoincideError("Missing rename source in Git status.") }
                previous = String(decoding: fields[i], as: UTF8.self); i += 1
            }
            files.append(ChangedFile(path: path, previousPath: previous, indexStatus: x, worktreeStatus: y))
        }
        return files
    }
    public func diff(file: ChangedFile? = nil, staged: Bool = false) async throws -> String {
        if let file, file.isUntracked {
            let url = try WorkspaceFiles(root: root).resolve(file.path)
            let data = try Data(contentsOf: url, options: [.mappedIfSafe])
            guard data.count <= 2_000_000, let text = String(data: data, encoding: .utf8) else { return "Binary or large untracked file: \(file.path)" }
            return "+++ \(file.path) (untracked)\n" + text.split(separator: "\n", omittingEmptySubsequences: false).map { "+" + $0 }.joined(separator: "\n")
        }
        var args = ["diff", "--no-ext-diff", "--no-textconv"]
        if staged { args.append("--cached") }
        args.append("--")
        if let file { args.append(file.path); if let previous = file.previousPath { args.append(previous) } }
        return String(decoding: try await command(args), as: UTF8.self)
    }
    public func stage(_ paths: [String]) async throws { guard !paths.isEmpty else { return }; _ = try await command(["add", "--"] + paths) }
    public func unstage(_ paths: [String]) async throws { guard !paths.isEmpty else { return }; _ = try await command(["restore", "--staged", "--"] + paths) }
    public func commit(message: String) async throws {
        guard !message.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw CoincideError("Enter a commit message.") }
        _ = try await command(["commit", "-F", "-"], input: Data(message.utf8))
    }
    public func branches() async throws -> [String] {
        String(decoding: try await command(["for-each-ref", "--format=%(refname:short)", "refs/heads/"]), as: UTF8.self).split(separator: "\n").map(String.init)
    }
    public func createWorktree(at path: URL, branch: String, base: String = "HEAD") async throws {
        _ = try await command(["check-ref-format", "--branch", branch])
        guard !base.hasPrefix("-") else { throw CoincideError("Invalid base ref.") }
        _ = try await command(["worktree", "add", "-b", branch, "--", path.path, base])
    }
    @discardableResult private func command(_ args: [String], input: Data? = nil) async throws -> Data {
        let result = try await CommandRunner.run("git", ["-C", root.path] + args, input: input)
        guard result.status == 0 else { throw CoincideError(String(decoding: result.error, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)) }
        return result.output
    }
}
