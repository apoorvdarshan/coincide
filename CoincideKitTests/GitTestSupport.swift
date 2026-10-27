import Foundation

@testable import CoincideKit

/// A throwaway git repository in the temporary folder.
struct TestRepository {
    let url: URL

    /// A repository on `main` with one commit containing `README.md`, unless `commit` is false.
    /// Local settings shield it from the user's global git configuration: no hooks, signing,
    /// filesystem monitor daemons or global ignore rules.
    static func make(commit: Bool = true) async throws -> TestRepository {
        let url = try makeDirectory("repo")
        let repository = TestRepository(url: url)
        let hooks = try makeDirectory("hooks")
        let excludes = hooks.appendingPathComponent("excludes")
        try Data().write(to: excludes)
        try await repository.git("init", "-q", "--template=", "-b", "main")
        let settings = [
            ("user.email", "test@example.com"), ("user.name", "Test"), ("commit.gpgsign", "false"),
            ("tag.gpgsign", "false"), ("core.hooksPath", hooks.path), ("core.fsmonitor", "false"),
            ("core.autocrlf", "false"), ("core.excludesFile", excludes.path), ("status.showUntrackedFiles", "normal"),
        ]
        for (key, value) in settings { try await repository.git("config", key, value) }
        if commit {
            try repository.write("README.md", "hello\n")
            try await repository.git("add", ".")
            try await repository.git("commit", "-q", "-m", "initial")
        }
        return repository
    }

    /// An empty folder under the temporary directory, with symlinks resolved as git reports them.
    static func makeDirectory(_ name: String) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("coincide-git-tests-\(UUID().uuidString)", isDirectory: true)
            .appendingPathComponent(name, isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url.resolvingSymlinksInPath()
    }

    @discardableResult
    func git(_ arguments: String..., environment: [String: String] = [:]) async throws -> String {
        try await git(arguments, in: url, environment: environment)
    }

    @discardableResult
    func git(_ arguments: [String], in directory: URL, environment: [String: String] = [:]) async throws -> String {
        let result = await GitCLI.git(arguments, in: directory, environment: environment)
        guard result.succeeded else {
            throw GitError.failed("git \(arguments.joined(separator: " "))", result)
        }
        return result.stdout
    }

    func write(_ path: String, _ contents: String) throws {
        let file = url.appendingPathComponent(path)
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try contents.write(to: file, atomically: true, encoding: .utf8)
    }

    func read(_ path: String) -> String? {
        try? String(contentsOf: url.appendingPathComponent(path), encoding: .utf8)
    }

    func exists(_ path: String) -> Bool {
        FileManager.default.fileExists(atPath: url.appendingPathComponent(path).path)
    }

    func delete(_ path: String) throws {
        try FileManager.default.removeItem(at: url.appendingPathComponent(path))
    }
}
