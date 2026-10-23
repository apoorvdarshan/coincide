import Foundation

/// A local commit and its actual repository ownership. This captures HEAD rather
/// than creating a checkpoint: dirty and untracked parent files are not copied.
public struct TaskIsolationProof: Codable, Sendable, Equatable {
    public let sourcePath: String
    public let sourceIdentity: GitWorktreeNodeIdentity
    public let projectPath: String
    public let projectIdentity: GitWorktreeNodeIdentity
    public let baseCommit: String
    public let commonDirectoryPath: String
    public let commonDirectoryIdentity: GitWorktreeNodeIdentity
    public let sourceRepositoryPath: String
    public let sourceRepositoryIdentity: GitWorktreeNodeIdentity
    public let sourceGitDirectoryPath: String
    public let sourceGitDirectoryIdentity: GitWorktreeNodeIdentity
    public let projectRepositoryPath: String
    public let projectRepositoryIdentity: GitWorktreeNodeIdentity
    public let projectGitDirectoryPath: String
    public let projectGitDirectoryIdentity: GitWorktreeNodeIdentity

    public func validate() throws {
        for path in [sourcePath, projectPath, commonDirectoryPath, sourceRepositoryPath,
                     sourceGitDirectoryPath, projectRepositoryPath, projectGitDirectoryPath] {
            try WorktreeValidation.path(path)
        }
        try WorktreeValidation.commit(baseCommit)
        guard [sourceIdentity, projectIdentity, commonDirectoryIdentity,
               sourceRepositoryIdentity, sourceGitDirectoryIdentity,
               projectRepositoryIdentity, projectGitDirectoryIdentity].allSatisfy({ $0.inode != 0 }) else {
            throw TaskIsolationError.changedRepository
        }
    }
}

public enum TaskIsolationError: Error, Sendable, Equatable, LocalizedError {
    case unavailableRepository, differentRepository, changedRepository, noLocalCommit
    public var errorDescription: String? {
        switch self {
        case .unavailableRepository: "The task workspace is not an available local Git checkout."
        case .differentRepository: "An isolated task must use the parent project's local repository."
        case .changedRepository: "The task's source repository changed. Review the task again."
        case .noLocalCommit: "The task needs a local parent HEAD commit. No files or branches were changed."
        }
    }
}

/// Uses the same descriptor-bound, local-only Git process implementation as
/// managed worktrees. No fetch, snapshot, setup, branch or index mutation occurs.
public struct TaskIsolationCapture: Sendable {
    private let command: GitWorktreeCommand
    private let environment: [String: String]?
    private let executable: URL?
    public init() { command = .init(environment: nil, executable: nil); environment = nil; executable = nil }
    init(environment: [String: String], gitExecutable: URL? = nil) {
        self.environment = environment; executable = gitExecutable
        command = .init(environment: environment, executable: gitExecutable)
    }
    private struct Repository: Sendable {
        let workspace: GitWorktreeDirectory
        let root: GitWorktreeDirectory
        let admin: GitWorktreeDirectory
        let common: GitWorktreeDirectory
    }

    public func capture(parentWorkspacePath: String, projectPath: String) async throws -> TaskIsolationProof {
        try Task.checkCancellation()
        let source = try await repository(parentWorkspacePath), project = try await repository(projectPath)
        guard source.common.path.utf8.elementsEqual(project.common.path.utf8),
              source.common.identity == project.common.identity else { throw TaskIsolationError.differentRepository }
        return try await GitOperationGate.shared.perform(key: source.common.path) {
            try await validateMapping(source); try await validateMapping(project)
            let head = try await localHead(source)
            try await requireLocalCommit(head, in: project)
            try await validateMapping(source); try await validateMapping(project)
            guard try await localHead(source) == head else { throw TaskIsolationError.changedRepository }
            let proof = TaskIsolationProof(sourcePath: source.workspace.path, sourceIdentity: source.workspace.identity,
                projectPath: project.workspace.path, projectIdentity: project.workspace.identity, baseCommit: head,
                commonDirectoryPath: source.common.path, commonDirectoryIdentity: source.common.identity,
                sourceRepositoryPath: source.root.path, sourceRepositoryIdentity: source.root.identity,
                sourceGitDirectoryPath: source.admin.path, sourceGitDirectoryIdentity: source.admin.identity,
                projectRepositoryPath: project.root.path, projectRepositoryIdentity: project.root.identity,
                projectGitDirectoryPath: project.admin.path, projectGitDirectoryIdentity: project.admin.identity)
            try proof.validate(); return proof
        }
    }

    /// The accepted base stays pinned when the parent later commits. Admission
    /// may explicitly require an unchanged HEAD before accepting a new intent.
    public func validate(_ proof: TaskIsolationProof, requireCurrentHead: Bool = false) async throws {
        try proof.validate(); try Task.checkCancellation()
        let source = try await repository(proof.sourcePath), project = try await repository(proof.projectPath)
        guard matches(source, workspace: proof.sourcePath, identity: proof.sourceIdentity,
                      root: proof.sourceRepositoryPath, rootIdentity: proof.sourceRepositoryIdentity,
                      admin: proof.sourceGitDirectoryPath, adminIdentity: proof.sourceGitDirectoryIdentity, proof: proof),
              matches(project, workspace: proof.projectPath, identity: proof.projectIdentity,
                      root: proof.projectRepositoryPath, rootIdentity: proof.projectRepositoryIdentity,
                      admin: proof.projectGitDirectoryPath, adminIdentity: proof.projectGitDirectoryIdentity, proof: proof) else {
            throw TaskIsolationError.changedRepository
        }
        try await GitOperationGate.shared.perform(key: proof.commonDirectoryPath) {
            try await validateMapping(source); try await validateMapping(project)
            try await requireLocalCommit(proof.baseCommit, in: source)
            try await requireLocalCommit(proof.baseCommit, in: project)
            if requireCurrentHead, try await localHead(source) != proof.baseCommit { throw TaskIsolationError.changedRepository }
            try await validateMapping(source); try await validateMapping(project)
        }
    }

    private func matches(_ repository: Repository, workspace: String, identity: GitWorktreeNodeIdentity,
                         root: String, rootIdentity: GitWorktreeNodeIdentity,
                         admin: String, adminIdentity: GitWorktreeNodeIdentity, proof: TaskIsolationProof) -> Bool {
        repository.workspace.path.utf8.elementsEqual(workspace.utf8) && repository.workspace.identity == identity &&
        repository.root.path.utf8.elementsEqual(root.utf8) && repository.root.identity == rootIdentity &&
        repository.admin.path.utf8.elementsEqual(admin.utf8) && repository.admin.identity == adminIdentity &&
        repository.common.path.utf8.elementsEqual(proof.commonDirectoryPath.utf8) && repository.common.identity == proof.commonDirectoryIdentity
    }
    private func repository(_ path: String) async throws -> Repository {
        try WorktreeValidation.path(path)
        let workspace = try GitWorktreeDirectory(path: canonical(path))
        // This existing inventory verifies registered linked-worktree backlinks,
        // the .git pointer and common-directory mapping before returning metadata.
        let service: GitWorktreeService
        if let environment { service = .init(source: URL(fileURLWithPath: workspace.path), environment: environment, gitExecutable: executable) }
        else { service = .init(source: URL(fileURLWithPath: workspace.path)) }
        let inventory = try await service.inventory()
        let root = try GitWorktreeDirectory(path: canonical(try await line(["rev-parse", "--show-toplevel"], at: workspace)))
        let admin = try GitWorktreeDirectory(path: canonical(try await line(["rev-parse", "--absolute-git-dir"], at: workspace)))
        let common = try GitWorktreeDirectory(path: canonical(try await line(["rev-parse", "--path-format=absolute", "--git-common-dir"], at: workspace)))
        guard inventory.sourcePath.utf8.elementsEqual(workspace.path.utf8),
              inventory.commonDirectoryPath.utf8.elementsEqual(common.path.utf8),
              workspace.path == root.path || workspace.path.hasPrefix(root.path + "/"),
              inventory.worktrees.contains(where: { $0.path.utf8.elementsEqual(root.path.utf8) && !$0.isBare }) else {
            throw TaskIsolationError.unavailableRepository
        }
        let repository = Repository(workspace: workspace, root: root, admin: admin, common: common)
        try await validateMapping(repository); return repository
    }
    private func validateMapping(_ repository: Repository) async throws {
        try repository.workspace.validate(); try repository.root.validate()
        try repository.admin.validate(); try repository.common.validate()
        for (arguments, expected) in [(["rev-parse", "--show-toplevel"], repository.root.path),
                                      (["rev-parse", "--absolute-git-dir"], repository.admin.path),
                                      (["rev-parse", "--path-format=absolute", "--git-common-dir"], repository.common.path)] {
            guard canonical(try await line(arguments, at: repository.workspace)).utf8.elementsEqual(expected.utf8) else {
                throw TaskIsolationError.changedRepository
            }
        }
        try repository.workspace.validate(); try repository.root.validate()
        try repository.admin.validate(); try repository.common.validate()
    }
    private func localHead(_ repository: Repository) async throws -> String {
        let value = try await line(["rev-parse", "--verify", "--end-of-options", "HEAD^{commit}"], at: repository.workspace, repository: repository)
        do { try WorktreeValidation.commit(value) } catch { throw TaskIsolationError.noLocalCommit }
        return value
    }
    private func requireLocalCommit(_ commit: String, in repository: Repository) async throws {
        try WorktreeValidation.commit(commit)
        let result = try await run(["cat-file", "-e", commit + "^{commit}"], at: repository.workspace, repository: repository)
        guard result.status == 0 else { throw TaskIsolationError.noLocalCommit }
    }
    private func line(_ arguments: [String], at directory: GitWorktreeDirectory, repository: Repository? = nil) async throws -> String {
        let result = try await run(arguments, at: directory, repository: repository)
        guard result.status == 0, var text = String(data: result.output, encoding: .utf8),
              text.utf8.count <= 16_384, !text.contains("\0") else { throw TaskIsolationError.unavailableRepository }
        if text.hasSuffix("\n") { text.removeLast() }
        guard !text.isEmpty else { throw TaskIsolationError.unavailableRepository }; return text
    }
    private func run(_ arguments: [String], at directory: GitWorktreeDirectory, repository: Repository?) async throws -> GitWorktreeCommandResult {
        try directory.validate()
        let result = try await command.run(["--no-lazy-fetch", "--no-replace-objects"] + arguments,
            cwdFD: directory.fd, maximumOutput: 16_384,
            gitDirectory: repository?.admin.path, commonDirectory: repository?.common.path, workTree: repository?.root.path)
        try directory.validate(); return result
    }
    private func canonical(_ path: String) -> String { URL(fileURLWithPath: path).standardizedFileURL.resolvingSymlinksInPath().path }
}
