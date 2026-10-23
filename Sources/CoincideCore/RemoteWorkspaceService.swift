import CryptoKit
import Darwin
import Foundation

/// Owns native workspace anchors and durable, never-replayed mutation attempts.
/// Its async jobs do not occupy the environment's conversation command lane.
actor RemoteWorkspaceService {
    private final class Root: @unchecked Sendable {
        let id: UUID, path: String, anchor: WorkspaceFileRoot, files: WorkspaceFileService
        var gitDirectories: [GitWorktreeDirectory]?
        init(id: UUID, path: String, anchor: WorkspaceFileRoot) {
            self.id = id; self.path = path; self.anchor = anchor; files = .init(root: URL(fileURLWithPath: path))
        }
    }
    private struct Revision { let rootID: UUID; let path: String; let value: WorkspaceFileRevision }
    private let environmentID: UUID
    private let engine: WorkspaceEngine
    private let journal: RemoteWorkspaceJournal
    private var roots: [UUID: Root] = [:]
    private var revisions: [UUID: Revision] = [:]
    private var jobs: [UUID: Task<Void, Never>] = [:]
    private var busyRoots: [UUID: UUID] = [:]
    private var busyGitRoots: Set<UUID> = []
    private var terminalRoots: [UUID: UUID] = [:]
    private var closing = false
    private var journalFailed = false
    private var closeTask: Task<Void, Never>?

    init(environmentID: UUID, engine: WorkspaceEngine, dataDirectory: URL) throws {
        self.environmentID = environmentID; self.engine = engine
        journal = try .init(directory: dataDirectory)
    }
    private func samePath(_ lhs: String, _ rhs: String) -> Bool { lhs.utf8.elementsEqual(rhs.utf8) }
    private func authorize(_ target: RemoteWorkspaceTarget, mutating: Bool = false) async throws {
        guard !closing, !journalFailed else { throw RemoteWorkspaceFailure(.unavailable) }
        guard target.environmentID == environmentID else { throw RemoteWorkspaceFailure(.invalidTarget) }
        let update = await engine.current(), snapshot = update.snapshot
        guard !closing, !journalFailed else { throw RemoteWorkspaceFailure(.unavailable) }
        guard update.error == nil, let thread = snapshot.threads.first(where: { $0.id == target.threadID }),
              thread.projectID == target.projectID, !thread.isArchived,
              snapshot.projects.contains(where: { $0.id == target.projectID }),
              samePath(thread.workspacePath, target.workspacePath), snapshot.workspaceReady(for: thread),
              !snapshot.isCheckpointRestoreLocked(path: target.workspacePath),
              !snapshot.isPullRequestCheckoutLocked(path: target.workspacePath),
              !snapshot.isPullRequestCreationLocked(path: target.workspacePath),
              !snapshot.isConversationHistoryLocked(threadID: thread.id) else { throw RemoteWorkspaceFailure(.invalidTarget) }
        if thread.scratchWorkspace != nil { try await engine.validateScratchWorkspace(threadID: thread.id, workspacePath: target.workspacePath) }
        if mutating {
            try await admitManagedScriptScope([target.workspacePath])
            guard !hasRunningWorktree(at: target.workspacePath, snapshot: snapshot) else { throw RemoteWorkspaceFailure(.busy) }
            let owners = snapshot.threads.filter { samePath($0.workspacePath, target.workspacePath) }
            guard owners.allSatisfy({ !$0.isBusy && $0.activeRun == nil && $0.queuedTurns.isEmpty && $0.runtimeRequests.isEmpty
                && $0.heldPostRunCheckpoint == nil && snapshot.workspaceReady(for: $0) }) else { throw RemoteWorkspaceFailure(.busy) }
        }
    }
    func bind(_ target: RemoteWorkspaceTarget) async throws -> RemoteWorkspaceTarget {
        do { return try await bindRoot(target) }
        catch { throw safe(error) }
    }
    /// PR recovery may inspect a checkout held by its own durable operation.
    /// It still requires the same registered thread, configuration and inode.
    func validatePullRequestTarget(_ target: RemoteWorkspaceTarget, allowLocked: Bool, requireRoot: Bool = true) async throws {
        guard !closing, !journalFailed, target.environmentID == environmentID else {
            throw RemoteWorkspaceFailure(.invalidTarget)
        }
        let update = await engine.current()
        guard !closing, !journalFailed, update.error == nil,
              let thread = update.snapshot.threads.first(where: { $0.id == target.threadID && $0.projectID == target.projectID }),
              !thread.isArchived, update.snapshot.projects.contains(where: { $0.id == target.projectID }),
              try RemotePullRequestProtocol.payload(ProviderConfiguration(thread: thread)) == RemotePullRequestProtocol.payload(target.configuration),
              samePath(thread.workspacePath, target.workspacePath), update.snapshot.workspaceReady(for: thread),
              !hasRunningWorktree(at: target.workspacePath, snapshot: update.snapshot),
              !update.snapshot.isCheckpointRestoreLocked(path: target.workspacePath),
              !update.snapshot.isConversationHistoryLocked(threadID: thread.id),
              allowLocked || (!update.snapshot.isPullRequestCreationLocked(path: target.workspacePath) && !update.snapshot.isPullRequestCheckoutLocked(path: target.workspacePath)) else {
            throw RemoteWorkspaceFailure(.invalidTarget)
        }
        if requireRoot {
            guard let id = target.rootID, let root = roots[id], samePath(root.path, target.workspacePath) else { throw RemoteWorkspaceFailure(.staleRoot) }
            do { try root.anchor.validate() } catch { throw RemoteWorkspaceFailure(.staleRoot) }
        }
    }
    func bindPullRequestTarget(_ target: RemoteWorkspaceTarget) async throws -> RemoteWorkspaceTarget {
        try await validatePullRequestTarget(target, allowLocked: true, requireRoot: false)
        let id = try bindPhysicalRoot(path: target.workspacePath, expectedID: target.rootID)
        let bound = RemoteWorkspaceTarget(environmentID: target.environmentID, projectID: target.projectID, threadID: target.threadID,
            configuration: target.configuration, rootID: id)
        try await validatePullRequestTarget(bound, allowLocked: true)
        return bound
    }
    /// Checkpoint recovery can inspect its own durable restoration lock.
    /// Files and Git retain their stricter general authorization.
    func validateCheckpointTarget(_ target: RemoteWorkspaceTarget, allowLocked: Bool, requireRoot: Bool = true) async throws {
        guard !closing, !journalFailed, target.environmentID == environmentID else { throw RemoteWorkspaceFailure(.invalidTarget) }
        let update = await engine.current(), snapshot = update.snapshot
        guard !closing, !journalFailed, update.error == nil,
              let thread = snapshot.threads.first(where: { $0.id == target.threadID && $0.projectID == target.projectID }),
              !thread.isArchived, snapshot.projects.contains(where: { $0.id == target.projectID }),
              try RemoteCheckpointProtocol.payload(ProviderConfiguration(thread: thread)) == RemoteCheckpointProtocol.payload(target.configuration),
              samePath(thread.workspacePath, target.workspacePath), snapshot.workspaceReady(for: thread),
              !hasRunningWorktree(at: target.workspacePath, snapshot: snapshot),
              !snapshot.isPullRequestCreationLocked(path: target.workspacePath),
              !snapshot.isPullRequestCheckoutLocked(path: target.workspacePath),
              !snapshot.isConversationHistoryLocked(threadID: thread.id),
              allowLocked || !snapshot.isCheckpointRestoreLocked(path: target.workspacePath) else { throw RemoteWorkspaceFailure(.invalidTarget) }
        if requireRoot {
            guard let id = target.rootID, let root = roots[id], samePath(root.path, target.workspacePath) else { throw RemoteWorkspaceFailure(.staleRoot) }
            do { try root.anchor.validate() } catch { throw RemoteWorkspaceFailure(.staleRoot) }
        }
    }
    func bindCheckpointTarget(_ target: RemoteWorkspaceTarget) async throws -> RemoteWorkspaceTarget {
        try await validateCheckpointTarget(target, allowLocked: true, requireRoot: false)
        let id = try bindPhysicalRoot(path: target.workspacePath, expectedID: target.rootID)
        let bound = RemoteWorkspaceTarget(environmentID: target.environmentID, projectID: target.projectID,
            threadID: target.threadID, configuration: target.configuration, rootID: id)
        try await validateCheckpointTarget(bound, allowLocked: true)
        return bound
    }
    func admitCheckpointScope(_ scope: RemoteCheckpointScope) async throws {
        try await admitPullRequestScope(.init(mutatingPaths: scope.mutatingPaths, coordinationPaths: scope.coordinationPaths))
    }
    /// History recovery may inspect its own durable hold. Other workflow holds
    /// still exclude it, and native inspections require the same physical root.
    func validateHistoryTarget(_ target: RemoteWorkspaceTarget, allowLocked: Bool, requireRoot: Bool = true) async throws {
        guard !closing, !journalFailed, target.environmentID == environmentID else { throw RemoteWorkspaceFailure(.invalidTarget) }
        let update = await engine.current(), snapshot = update.snapshot
        let standaloneRestore = (snapshot.checkpointRestoreOperations ?? []).contains {
            $0.locksSource && WorkspaceSnapshot.checkpointRestorePathsOverlap(target.workspacePath, $0.review.gitReview.currentPlan.repositoryPath)
        }
        let foreignHistoryRestore = (snapshot.conversationHistoryOperations ?? []).contains { operation in
            guard operation.locksFiles, let files = operation.files,
                  WorkspaceSnapshot.checkpointRestorePathsOverlap(target.workspacePath, files.review.gitReview.currentPlan.repositoryPath) else { return false }
            let owned = operation.review.sourceThreadID == target.threadID && operation.review.projectID == target.projectID &&
                operation.review.sourceConfiguration.workspacePath.utf8.elementsEqual(target.workspacePath.utf8)
            return !allowLocked || !owned
        }
        guard !closing, !journalFailed, update.error == nil,
              let thread = snapshot.threads.first(where: { $0.id == target.threadID && $0.projectID == target.projectID }),
              !thread.isArchived, snapshot.projects.contains(where: { $0.id == target.projectID }),
              try RemoteEnvironmentProtocol.encode(ProviderConfiguration(thread: thread)) == RemoteEnvironmentProtocol.encode(target.configuration),
              samePath(thread.workspacePath, target.workspacePath), snapshot.workspaceReady(for: thread),
              !hasRunningWorktree(at: target.workspacePath, snapshot: snapshot),
              !snapshot.isPullRequestCreationLocked(path: target.workspacePath),
              !snapshot.isPullRequestCheckoutLocked(path: target.workspacePath),
              !standaloneRestore, !foreignHistoryRestore,
              allowLocked || !snapshot.isConversationHistoryLocked(threadID: thread.id) else { throw RemoteWorkspaceFailure(.invalidTarget) }
        if requireRoot {
            guard let id = target.rootID, let root = roots[id], samePath(root.path, target.workspacePath) else { throw RemoteWorkspaceFailure(.staleRoot) }
            do { try root.anchor.validate() } catch { throw RemoteWorkspaceFailure(.staleRoot) }
        }
    }
    func bindHistoryTarget(_ target: RemoteWorkspaceTarget) async throws -> RemoteWorkspaceTarget {
        try await validateHistoryTarget(target, allowLocked: true, requireRoot: false)
        let id = try bindPhysicalRoot(path: target.workspacePath, expectedID: target.rootID)
        let bound = RemoteWorkspaceTarget(environmentID: target.environmentID, projectID: target.projectID,
            threadID: target.threadID, configuration: target.configuration, rootID: id)
        try await validateHistoryTarget(bound, allowLocked: true)
        return bound
    }
    func admitHistoryScope(_ scope: RemoteHistoryScope) async throws {
        try await admitPullRequestScope(.init(mutatingPaths: scope.mutatingPaths, coordinationPaths: scope.coordinationPaths))
    }
    func busyPullRequestPaths() async -> [String] {
        let managed = await engine.remoteProjectScriptBusyPaths()
        return Set(busyRoots.keys).union(terminalRoots.values).compactMap { roots[$0]?.path } + managed
    }
    /// Called under the same host admission gate as file jobs and PTY opens.
    /// The paths come from native prepared operations, never from the client.
    func admitPullRequestScope(_ scope: RemotePullRequestScope, excludingManagedScriptThreadID: UUID? = nil) async throws {
        guard !closing, !journalFailed else { throw RemoteWorkspaceFailure(.unavailable) }
        try await admitManagedScriptScope(scope.mutatingPaths + scope.coordinationPaths, excludingThreadID: excludingManagedScriptThreadID)
        func overlap(_ a: String, _ b: String) -> Bool { WorkspaceSnapshot.checkpointRestorePathsOverlap(a, b) }
        let mutations = scope.mutatingPaths, coordination = scope.coordinationPaths
        for id in Set(busyRoots.keys).union(terminalRoots.values) {
            guard let root = roots[id] else { continue }
            try root.anchor.validate()
            guard !mutations.contains(where: { overlap(root.path, $0) }) else { throw RemoteWorkspaceFailure(.busy) }
            if busyGitRoots.contains(id) {
                let paths = [root.path] + (root.gitDirectories?.map(\.path) ?? [])
                guard !paths.contains(where: { path in (coordination + mutations).contains { overlap(path, $0) } }) else { throw RemoteWorkspaceFailure(.busy) }
            }
        }
    }
    func admitProjectScriptScope(target: RemoteWorkspaceTarget, scope: RemotePullRequestScope, excludingManagedScriptThreadID: UUID?) async throws {
        try await validateCheckpointTarget(target, allowLocked: false)
        guard let id = target.rootID, let root = roots[id] else { throw RemoteWorkspaceFailure(.staleRoot) }
        _ = try await git(root)
        try root.anchor.validate()
        let directories = root.gitDirectories?.map(\.path) ?? []
        try await admitPullRequestScope(.init(mutatingPaths: scope.mutatingPaths + directories,
            coordinationPaths: scope.coordinationPaths + directories), excludingManagedScriptThreadID: excludingManagedScriptThreadID)
    }
    private func bindRoot(_ target: RemoteWorkspaceTarget) async throws -> RemoteWorkspaceTarget {
        try await authorize(target)
        let id = try bindPhysicalRoot(path: target.workspacePath, expectedID: target.rootID)
        return .init(environmentID: target.environmentID, projectID: target.projectID, threadID: target.threadID,
                     configuration: target.configuration, rootID: id)
    }
    private func bindPhysicalRoot(path: String, expectedID: UUID?) throws -> UUID {
        guard samePath(URL(fileURLWithPath: path).standardizedFileURL.resolvingSymlinksInPath().path, path) else { throw RemoteWorkspaceFailure(.invalidTarget) }
        let anchor = try WorkspaceFileRoot(root: URL(fileURLWithPath: path))
        let id: UUID
        do { id = try rootIdentity(anchor) } catch { anchor.close(); throw error }
        guard expectedID == nil || expectedID == id else { anchor.close(); throw RemoteWorkspaceFailure(.staleRoot) }
        if let existing = roots[id] { anchor.close(); try existing.anchor.validate() }
        else {
            guard roots.count < 128 else { anchor.close(); throw RemoteWorkspaceFailure(.limitExceeded) }
            roots[id] = Root(id: id, path: path, anchor: anchor)
        }
        return id
    }
    /// Failed preparation may point at a destination that does not exist. Bind
    /// its saved source separately, without granting file access to that path.
    func bindWorktreeSource(_ target: RemoteWorkspaceTarget) async throws -> (sourcePath: String, sourceRootID: UUID, attemptID: UUID?) {
        let thread = try await worktreeThread(target)
        let source = thread.workspacePreparation.flatMap { $0.canRetry ? $0.request.sourcePath : nil } ?? thread.workspacePath
        let id = try bindPhysicalRoot(path: source, expectedID: samePath(source, target.workspacePath) ? target.rootID : nil)
        return (source, id, thread.workspacePreparation?.id)
    }
    @discardableResult
    func validateWorktreeSource(_ target: RemoteWorkspaceTarget, sourceRootID: UUID, expectedAttemptID: UUID?) async throws -> GitWorktreeNodeIdentity {
        let thread = try await worktreeThread(target)
        let source = thread.workspacePreparation.flatMap { $0.canRetry ? $0.request.sourcePath : nil } ?? thread.workspacePath
        guard thread.workspacePreparation?.id == expectedAttemptID,
              let root = roots[sourceRootID], samePath(root.path, source) else { throw RemoteWorkspaceFailure(.staleRoot) }
        do { try root.anchor.validate() } catch { throw RemoteWorkspaceFailure(.staleRoot) }
        return .init(device: root.anchor.device, inode: root.anchor.inode)
    }
    private func worktreeThread(_ target: RemoteWorkspaceTarget) async throws -> CodingThread {
        guard !closing, !journalFailed, target.environmentID == environmentID else { throw RemoteWorkspaceFailure(.invalidTarget) }
        let update = await engine.current()
        guard !closing, !journalFailed, update.error == nil,
              let thread = update.snapshot.threads.first(where: { $0.id == target.threadID }),
              !thread.isArchived, thread.projectID == target.projectID,
              update.snapshot.projects.contains(where: { $0.id == target.projectID }),
              ProviderConfiguration(thread: thread) == target.configuration,
              samePath(thread.workspacePath, target.workspacePath),
              thread.workspacePreparation?.isRunning != true else { throw RemoteWorkspaceFailure(.invalidTarget) }
        return thread
    }
    private func hasRunningWorktree(at path: String, snapshot: WorkspaceSnapshot) -> Bool {
        snapshot.threads.contains { thread in
            guard let state = thread.workspacePreparation, state.isRunning else { return false }
            return samePath(state.request.sourcePath, path) || samePath(state.destinationPath, path)
        }
    }
    private func rootIdentity(_ root: WorkspaceFileRoot) throws -> UUID {
        var value = stat()
        guard fstat(root.fd, &value) == 0 else { throw RemoteWorkspaceFailure(.staleRoot) }
        let text = "\(environmentID.uuidString)|\(root.path)|\(root.device)|\(root.inode)|\(value.st_birthtimespec.tv_sec)|\(value.st_birthtimespec.tv_nsec)"
        let bytes = Array(SHA256.hash(data: Data(text.utf8)))
        return UUID(uuid: (bytes[0],bytes[1],bytes[2],bytes[3],bytes[4],bytes[5],bytes[6],bytes[7],bytes[8],bytes[9],bytes[10],bytes[11],bytes[12],bytes[13],bytes[14],bytes[15]))
    }
    private func root(_ target: RemoteWorkspaceTarget) async throws -> Root {
        try await authorize(target)
        guard let id = target.rootID, let value = roots[id], samePath(value.path, target.workspacePath) else { throw RemoteWorkspaceFailure(.staleRoot) }
        do { try value.anchor.validate() } catch { throw RemoteWorkspaceFailure(.staleRoot) }
        return value
    }
    func read(_ request: RemoteWorkspaceReadRequest) async throws -> RemoteWorkspaceReadResult {
        do {
            let root = try await root(request.target), value: RemoteWorkspaceValue
            switch request.query {
            case .list(let path): value = .entries(try await root.files.listEntries(directoryPath: path))
            case .searchPaths(let query, let limit): value = .entries(try await root.files.searchEntries(query: query, limit: limit))
            case .searchContents(let query, let limit, let sensitive, let word, let regex):
                value = .contents(try await root.files.searchContents(query: query, limit: limit, caseSensitive: sensitive, wholeWord: word, useRegex: regex))
            case .readFile(let path, let missing, let maximum):
                try await validateFile(path, root: root, allowMissing: missing)
                value = .document(document(try await root.files.readFile(relativePath: path, allowMissing: missing, maxBytes: maximum), root: root))
            case .gitStatus: value = .git(try normalizedGitSnapshot(try await git(root).status(), root: root))
            case .gitDiff(let file, let staged):
                if let file {
                    try await validateFile(file.path, root: root, allowMissing: true)
                    if let previous = file.previousPath { try await validateFile(previous, root: root, allowMissing: true) }
                }
                value = .diff(try await git(root).diff(file: file, staged: staged))
            case .gitBranches: value = .branches(try await git(root).branchDetails())
            case .gitRemotes: value = .remotes(try await git(root).remotes())
            }
            try await authorize(request.target); try root.anchor.validate()
            _ = try RemoteEnvironmentProtocol.encode(value)
            return .init(target: request.target, value: value)
        } catch { throw safe(error) }
    }
    private func validateFile(_ path: String, root: Root, allowMissing: Bool) async throws {
        guard !path.isEmpty else { throw RemoteWorkspaceFailure(.invalidRequest) }
        do { _ = try await root.files.metadata(relativePath: path) }
        catch let error as WorkspaceFileError where allowMissing && error.failure == .missing { }
    }
    private func document(_ value: WorkspaceTextDocument, root: Root) -> RemoteWorkspaceDocument {
        var token: UUID?
        if let revision = value.revision {
            while revisions.count >= 1_024, let first = revisions.keys.first { revisions.removeValue(forKey: first) }
            let id = UUID(); revisions[id] = .init(rootID: root.id, path: value.relativePath, value: revision); token = id
        }
        return .init(relativePath: value.relativePath, contents: value.contents, byteLength: value.byteLength,
                     truncated: value.truncated, exists: value.exists, revision: token)
    }
    private func git(_ root: Root) async throws -> GitService {
        try root.anchor.validate()
        let git = GitService(root: URL(fileURLWithPath: root.path))
        let paths = try await git.remoteWorkspaceDirectories()
        guard paths.first.map({ samePath($0, root.path) }) == true else { throw RemoteWorkspaceFailure(.invalidTarget) }
        if let pinned = root.gitDirectories {
            guard pinned.count == paths.count, zip(pinned, paths).allSatisfy({ samePath($0.path, $1) }) else { throw RemoteWorkspaceFailure(.staleRoot) }
            for value in pinned { try value.validate() }
        } else { root.gitDirectories = try paths.map { try .init(path: $0) } }
        try root.anchor.validate(); return git
    }
    private func normalizedGitSnapshot(_ snapshot: GitSnapshot, root: Root) throws -> GitSnapshot {
        try root.anchor.validate()
        for directory in root.gitDirectories ?? [] { try directory.validate() }
        let resolved = snapshot.repositoryRoot.standardizedFileURL.resolvingSymlinksInPath().path
        guard samePath(resolved, root.path) else { throw RemoteWorkspaceFailure(.invalidTarget) }
        var value = snapshot
        // Git may spell Darwin's /var alias as /private/var. Export only the
        // already-validated bound spelling; remote clients never resolve it.
        value.repositoryRoot = URL(fileURLWithPath: root.path)
        return value
    }
    func operation(_ request: RemoteWorkspaceMutationRequest) throws -> RemoteWorkspaceOperation? {
        guard request.target.environmentID == environmentID else { throw RemoteWorkspaceFailure(.invalidTarget) }
        guard !journalFailed else { throw RemoteWorkspaceFailure(.unavailable) }
        return try journal.lookup(request)
    }
    func begin(_ request: RemoteWorkspaceMutationRequest) async throws -> RemoteWorkspaceOperation {
        if let existing = try operation(request) { return existing }
        let root: Root
        do {
            root = try await self.root(request.target)
            try await authorize(request.target, mutating: true)
            try validate(request.mutation)
            switch request.mutation {
            case .createFile, .saveFile, .gitInitialize: break
            default:
                _ = try await git(root)
                let snapshot = await engine.current().snapshot
                let paths = [root.path] + (root.gitDirectories?.map(\.path) ?? [])
                try await admitManagedScriptScope(paths)
                guard !paths.contains(where: { snapshot.isPullRequestCheckoutCoordinating(path: $0) }) else { throw RemoteWorkspaceFailure(.busy) }
            }
            guard busyRoots[root.id] == nil, !terminalRoots.values.contains(root.id), jobs.count < 8 else { throw RemoteWorkspaceFailure(.busy) }
        } catch { return try journal.insert(request, failure: safe(error)) }
        let accepted = try journal.insert(request)
        busyRoots[root.id] = request.id
        switch request.mutation { case .createFile, .saveFile: break; default: busyGitRoots.insert(root.id) }
        jobs[request.id] = Task { await self.execute(request, root: root) }
        return accepted
    }
    private func validate(_ mutation: RemoteWorkspaceMutation) throws {
        func text(_ value: String, maximum: Int, empty: Bool = false) throws {
            guard value.utf8.count <= maximum, !value.contains("\0"), empty || !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw RemoteWorkspaceFailure(.invalidRequest) }
        }
        func paths(_ values: [String]) throws {
            guard !values.isEmpty, values.count <= 2_000 else { throw RemoteWorkspaceFailure(.invalidRequest) }
            for path in values { try text(path, maximum: 4_096); guard !path.hasPrefix("/"), !path.split(separator: "/").contains("..") else { throw RemoteWorkspaceFailure(.invalidRequest) } }
        }
        switch mutation {
        case .createFile(let path, let contents), .saveFile(let path, let contents, _): try paths([path]); try text(contents, maximum: 2_000_000, empty: true)
        case .gitStage(let values), .gitUnstage(let values): try paths(values)
        case .gitCommit(let message): try text(message, maximum: 120_000)
        case .gitInitialize(let branch), .gitCheckout(let branch), .gitPull(let branch): try text(branch, maximum: 512)
        case .gitCreateBranch(let branch, let tracking): try text(branch, maximum: 512); if let tracking { try text(tracking, maximum: 1_024) }
        case .gitFetch(let remote): try text(remote, maximum: 512)
        case .gitPush(let branch, let remote, let remoteBranch, _): try text(branch, maximum: 512); try text(remote, maximum: 512); try text(remoteBranch, maximum: 512)
        }
    }
    private func execute(_ request: RemoteWorkspaceMutationRequest, root: Root) async {
        defer { jobs.removeValue(forKey: request.id); if busyRoots[root.id] == request.id { busyRoots.removeValue(forKey: root.id); busyGitRoots.remove(root.id) } }
        var entered = false
        do {
            try Task.checkCancellation(); try await authorize(request.target, mutating: true); try root.anchor.validate()
            guard var state = try journal.lookup(request), state.state == .accepted else { return }
            // Resolve and validate all native preconditions before marking running.
            let expected: WorkspaceFileWriteCondition?
            let gitService: GitService?
            switch request.mutation {
            case .saveFile(let path, _, let token):
                guard let revision = revisions[token], revision.rootID == root.id, samePath(revision.path, path) else { throw RemoteWorkspaceFailure(.conflict) }
                try await validateFile(path, root: root, allowMissing: false)
                let current = try await root.files.readFile(relativePath: path, maxBytes: 2_000_000)
                guard current.revision == revision.value else { throw RemoteWorkspaceFailure(.conflict) }
                expected = .matching(revision.value); gitService = nil
            case .createFile(let path, _):
                do { _ = try await root.files.metadata(relativePath: path); throw RemoteWorkspaceFailure(.conflict) }
                catch let error as WorkspaceFileError where error.failure == .missing { }
                expected = .missing; gitService = nil
            case .gitInitialize: expected = nil; gitService = .init(root: URL(fileURLWithPath: root.path))
            default:
                expected = nil; gitService = try await git(root)
                if case .gitStage(let paths) = request.mutation { for path in paths { try await validateFile(path, root: root, allowMissing: true) } }
                if case .gitUnstage(let paths) = request.mutation { for path in paths { try await validateFile(path, root: root, allowMissing: true) } }
            }
            try Task.checkCancellation(); try await authorize(request.target, mutating: true); try root.anchor.validate()
            state.state = .running; state.updatedAt = .now; try journal.store(state); entered = true
            let result: RemoteWorkspaceValue
            switch request.mutation {
            case .createFile(let path, let contents), .saveFile(let path, let contents, _):
                guard let expected else { throw RemoteWorkspaceFailure(.invalidRequest) }
                result = .document(document(try await root.files.writeFile(relativePath: path, contents: contents, expected: expected), root: root))
            default:
                guard let gitService else { throw RemoteWorkspaceFailure(.invalidRequest) }
                try await performGit(request.mutation, git: gitService)
                _ = try await git(root); result = .git(try normalizedGitSnapshot(try await gitService.status(), root: root))
            }
            try Task.checkCancellation(); try root.anchor.validate(); try await authorize(request.target)
            state.state = .finished; state.result = result; state.failure = nil; state.updatedAt = .now; try journal.store(state)
        } catch {
            do {
                guard var state = try journal.lookup(request) else { return }
                state.state = entered ? .uncertain : .finished; state.failure = safe(error); state.updatedAt = .now
                try journal.store(state)
            } catch { journalFailed = true }
        }
    }
    private func performGit(_ mutation: RemoteWorkspaceMutation, git: GitService) async throws {
        switch mutation {
        case .gitInitialize(let branch): try await git.initialize(branch: branch)
        case .gitStage(let paths): try await git.stage(paths)
        case .gitUnstage(let paths): try await git.unstage(paths)
        case .gitCommit(let message): try await git.commit(message: message)
        case .gitCheckout(let branch): try await git.checkout(branch: branch)
        case .gitCreateBranch(let branch, let tracking): try await git.createBranch(branch, tracking: tracking)
        case .gitFetch(let remote): try await git.fetch(remote: remote)
        case .gitPull(let branch): try await git.pull(branch: branch)
        case .gitPush(let branch, let remote, let destination, let upstream): try await git.push(branch: branch, remote: remote, remoteBranch: destination, setUpstream: upstream)
        default: throw RemoteWorkspaceFailure(.invalidRequest)
        }
    }
    func cancel(_ request: RemoteWorkspaceMutationRequest) async throws -> RemoteWorkspaceOperation? {
        guard var value = try operation(request) else { return nil }
        if let job = jobs[request.id] {
            value.state = .uncertain; value.failure = .init(.interrupted); value.updatedAt = .now
            try journal.store(value); job.cancel(); await job.value
            return try operation(request)
        }
        return value
    }
    /// Called under the environment service's admission gate, before its Engine
    /// command commits. Mutations reserve busyRoots under that same gate.
    func admitConversationCommand(_ command: RemoteEnvironmentCommand) async throws {
        let snapshot = await engine.current().snapshot
        var paths: [String] = []
        var excludesTerminals = false
        var inputOwnerID: UUID?
        switch command {
        case .submit(let id, _, _), .resumeQueue(let id, _):
            guard let thread = snapshot.threads.first(where: { $0.id == id }) else { return }
            paths = [thread.workspacePath]
            inputOwnerID = id
        case .promptSteering(let target, let action):
            switch action { case .acknowledge, .removeQueued, .moveQueued: return; default: break }
            try await validateCheckpointTarget(target, allowLocked: false)
            paths = [target.workspacePath]; inputOwnerID = target.threadID
        case .submitComposerDraft(let input):
            guard let thread = snapshot.threads.first(where: { $0.id == input.target.threadID }) else { return }
            paths = [thread.workspacePath]; inputOwnerID = thread.id
        case .submitWithAttachments(let target, _, _, _, _):
            guard let thread = snapshot.threads.first(where: { $0.id == target.threadID }) else { return }
            paths = [thread.workspacePath]
            inputOwnerID = thread.id
        case .implementTranscriptPlan(let target, _, _, _):
            paths = [target.workspacePath]; inputOwnerID = target.threadID
        case .implementTranscriptPlanInNewConversation(let target, _, _, _, _):
            // A fresh conversation does not inherit the source conversation's
            // permission to coexist with its own managed setup/script job.
            paths = [target.workspacePath]; inputOwnerID = nil
        case .prepareWorktree(let target, let sourceRootID, let attemptID, let selection, _):
            try await validateWorktreeSource(target, sourceRootID: sourceRootID, expectedAttemptID: attemptID)
            guard let source = roots[sourceRootID] else { throw RemoteWorkspaceFailure(.staleRoot) }
            paths = [source.path, target.workspacePath]
            if case .reuse(let destination) = selection { paths.append(destination) }
            excludesTerminals = true
        case .retryWorktree(let target, let attemptID):
            guard let thread = snapshot.threads.first(where: { $0.id == target.threadID }),
                  let state = thread.workspacePreparation, state.id == attemptID else { throw RemoteWorkspaceFailure(.invalidTarget) }
            paths = [state.request.sourcePath, state.destinationPath]
            excludesTerminals = true
        default: return
        }
        // Native readiness gates this conversation's own blocking setup, while
        // asynchronous setup may release it and settlement Resume first drains
        // cleanup. Foreign conversations cannot bypass the managed job lease.
        try await admitManagedScriptScope(paths, excludingThreadID: inputOwnerID)
        let held = Set(busyRoots.keys).union(excludesTerminals ? Set(terminalRoots.values) : [])
        guard !held.contains(where: { id in roots[id].map { root in paths.contains { samePath(root.path, $0) } } == true }),
              !excludesTerminals || !paths.contains(where: { hasRunningWorktree(at: $0, snapshot: snapshot) }) else { throw RemoteWorkspaceFailure(.busy) }
    }
    func acquireTerminalRoot(_ target: RemoteWorkspaceTarget, owner: UUID) async throws {
        let root = try await self.root(target)
        _ = try? await git(root)
        try root.anchor.validate()
        try await admitManagedScriptScope([root.path])
        let snapshot = await engine.current().snapshot
        guard !closing, busyRoots[root.id] == nil, !hasRunningWorktree(at: root.path, snapshot: snapshot) else { throw RemoteWorkspaceFailure(.busy) }
        terminalRoots[owner] = root.id
    }
    func validateTerminalRoot(_ target: RemoteWorkspaceTarget, owner: UUID) async throws {
        let root = try await self.root(target)
        guard terminalRoots[owner] == root.id else { throw RemoteWorkspaceFailure(.invalidTarget) }
    }
    func releaseTerminalRoot(owner: UUID) { terminalRoots.removeValue(forKey: owner) }
    private func admitManagedScriptScope(_ paths: [String], excludingThreadID: UUID? = nil) async throws {
        let held = await engine.remoteProjectScriptBusyPaths(excludingThreadID: excludingThreadID)
        guard !closing, !journalFailed else { throw RemoteWorkspaceFailure(.unavailable) }
        let heldDirectories = roots.values.filter { root in held.contains { samePath($0, root.path) } }.flatMap { $0.gitDirectories?.map(\.path) ?? [] }
        let requestedDirectories = roots.values.filter { root in paths.contains { samePath($0, root.path) } }.flatMap { $0.gitDirectories?.map(\.path) ?? [] }
        guard !(paths + requestedDirectories).contains(where: { path in (held + heldDirectories).contains { WorkspaceSnapshot.checkpointRestorePathsOverlap(path, $0) } }) else {
            throw RemoteWorkspaceFailure(.busy)
        }
    }
    private func safe(_ error: any Error) -> RemoteWorkspaceFailure {
        if let error = error as? RemoteWorkspaceFailure { return error }
        if error is CancellationError { return .init(.interrupted) }
        if let error = error as? WorkspaceFileError {
            switch error.failure { case .conflict: return .init(.conflict)
            case .rootReplaced, .rootMissing, .rootNotDirectory: return .init(.staleRoot)
            case .invalidPath, .pathOutsideRoot, .gitMetadata, .invalidQuery, .binary, .invalidUTF8, .notFile: return .init(.invalidRequest)
            default: break }
        }
        return .init(.operationFailed)
    }
    func close() async {
        if let closeTask { await closeTask.value; return }
        closing = true
        let jobs = Array(jobs.values), roots = Array(roots.values)
        for job in jobs { job.cancel() }
        let task = Task {
            for job in jobs { await job.value }
            for root in roots { await root.files.close(); root.anchor.close() }
        }
        closeTask = task; await task.value
        self.roots = [:]; revisions = [:]
    }
}
