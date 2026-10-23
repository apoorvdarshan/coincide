import Foundation

public struct GitWorktreeService: WorkspaceWorktreeSession, Sendable {
    public let source: URL
    private let request: GitWorktreeRequest?
    private let command: GitWorktreeCommand
    private let timeout: Duration
    public init(request: GitWorktreeRequest, timeout: Duration = .seconds(120)) {
        self.request = request; source = URL(fileURLWithPath: request.sourcePath)
        command = .init(environment: nil, executable: nil); self.timeout = timeout
    }
    public init(source: URL, timeout: Duration = .seconds(120)) {
        self.source = source; request = nil; command = .init(environment: nil, executable: nil); self.timeout = timeout
    }
    init(request: GitWorktreeRequest, environment: [String: String], gitExecutable: URL? = nil, timeout: Duration = .seconds(120)) {
        self.request = request; source = URL(fileURLWithPath: request.sourcePath)
        command = .init(environment: environment, executable: gitExecutable); self.timeout = timeout
    }
    init(source: URL, environment: [String: String], gitExecutable: URL? = nil, timeout: Duration = .seconds(120)) {
        self.source = source; request = nil; command = .init(environment: environment, executable: gitExecutable); self.timeout = timeout
    }
    public func inventory() async throws -> GitWorktreeInventory {
        try validateSourceURL()
        let context = try await context(source.path)
        return try await inventory(context)
    }
    public func prepare() async throws -> GitWorktreePlan {
        guard let request else { throw WorktreeValidation.invalid("A worktree request is required for planning.") }
        return try await prepare(request)
    }
    public func prepare(_ request: GitWorktreeRequest) async throws -> GitWorktreePlan {
        try validateSourceURL()
        try request.validate(); try Task.checkCancellation()
        guard canonical(source.path) == canonical(request.sourcePath) else { throw WorktreeValidation.invalid("The worktree request belongs to a different source folder.") }
        let context = try await context(request.sourcePath, expectedSourceIdentity: request.expectedSourceIdentity), inventory = try await inventory(context)
        switch request.selection {
        case .reuse:
            let checkout = try await verifyCheckout(path: request.destinationPath, context: context, inventory: inventory, branch: nil)
            let parent = try GitWorktreeDirectory(path: URL(fileURLWithPath: request.destinationPath).deletingLastPathComponent().path)
            return try .init(request: request, sourcePath: context.source.path, commonDirectoryPath: context.common.path,
                             sourceIdentity: context.source.identity, commonDirectoryIdentity: context.common.identity,
                             destinationParentIdentity: parent.identity, branch: checkout.result.branch!, baseCommit: checkout.result.headCommit,
                             destinationIdentity: checkout.directory.identity, worktreeGitDirectoryPath: checkout.gitDirectory.path,
                             worktreeGitDirectoryIdentity: checkout.gitDirectory.identity,
                             sourceGitDirectoryPath: context.admin.path, sourceGitDirectoryIdentity: context.admin.identity)
        case .createBranch(let name, let baseRef):
            try await checkBranch(name, context: context)
            try await requireAvailableBranch(name, creating: true, context: context, inventory: inventory)
            let commit: String
            if let base = request.automaticBase { commit = try await automaticCommit(base, context: context) }
            else { commit = try await self.commit(baseRef, context: context) }
            return try plan(request, context: context, branch: name, commit: commit)
        case .existingBranch(let name):
            try await checkBranch(name, context: context)
            try await requireAvailableBranch(name, creating: false, context: context, inventory: inventory)
            let commit = try await commit("refs/heads/" + name, context: context)
            return try plan(request, context: context, branch: name, commit: commit)
        }
    }
    public func run(_ plan: GitWorktreePlan) async throws -> GitWorktreeResult {
        try validateSession(plan)
        let context = try await context(plan.sourcePath, expectedSourceIdentity: plan.sourceIdentity)
        try validate(context, plan: plan)
        return try await GitOperationGate.shared.perform(key: plan.commonDirectoryPath) {
            try await execute(plan, context: context)
        }
    }
    /// Internal coordinator seam. The caller must hold GitOperationGate for this
    /// exact common-directory path; all normal plan and ownership checks remain.
    func runHoldingOperationGate(_ plan: GitWorktreePlan) async throws -> GitWorktreeResult {
        try validateSession(plan)
        let context = try await context(plan.sourcePath, expectedSourceIdentity: plan.sourceIdentity)
        try validate(context, plan: plan)
        return try await execute(plan, context: context)
    }
    public func inspectCompletion(_ plan: GitWorktreePlan) async throws -> GitWorktreeResult? {
        try validateSession(plan)
        let context = try await context(plan.sourcePath, expectedSourceIdentity: plan.sourceIdentity)
        try validate(context, plan: plan)
        return try await inspect(plan, context: context)
    }
    public func isCompleted(_ plan: GitWorktreePlan) async throws -> Bool { try await inspectCompletion(plan) != nil }

    private struct Context: Sendable { let source: GitWorktreeDirectory; let common: GitWorktreeDirectory; let admin: GitWorktreeDirectory }
    private struct Checkout: Sendable { let directory: GitWorktreeDirectory; let gitDirectory: GitWorktreeDirectory; let result: GitWorktreeResult }
    private func canonical(_ path: String) -> String { URL(fileURLWithPath: path).standardizedFileURL.resolvingSymlinksInPath().path }
    private func validateSourceURL() throws {
        guard source.isFileURL, let components = URLComponents(url: source, resolvingAgainstBaseURL: false),
              components.user == nil, components.password == nil, components.query == nil, components.fragment == nil,
              components.host == nil || components.host == "" || components.host?.lowercased() == "localhost" else {
            throw WorktreeValidation.invalid("Choose a local file URL for this source repository.")
        }
    }
    private func validateSession(_ plan: GitWorktreePlan) throws {
        try validateSourceURL()
        try plan.validate(); try Task.checkCancellation()
        guard request == nil || request == plan.request, canonical(source.path) == plan.sourcePath,
              canonical(plan.request.sourcePath) == plan.sourcePath else { throw worktreeFileFailure("The source folder no longer matches this worktree plan.") }
    }
    private func validate(_ context: Context, plan: GitWorktreePlan) throws {
        try context.source.validate(expected: plan.sourceIdentity); try context.common.validate(expected: plan.commonDirectoryIdentity)
        try context.admin.validate(expected: plan.sourceGitDirectoryIdentity)
        guard context.source.path == plan.sourcePath, context.common.path == plan.commonDirectoryPath,
              context.admin.path == plan.sourceGitDirectoryPath else { throw worktreeFileFailure("The source repository identity changed after worktree planning.") }
    }
    private func context(_ sourcePath: String, expectedSourceIdentity: GitWorktreeNodeIdentity? = nil) async throws -> Context {
        let directory = try GitWorktreeDirectory(path: canonical(sourcePath))
        try directory.validate(expected: expectedSourceIdentity)
        let result = try await command.run(["rev-parse", "--path-format=absolute", "--git-common-dir"], cwdFD: directory.fd)
        guard result.status == 0 else { throw GitWorktreeError(.notRepository, "This source folder is not an available local Git repository.") }
        try directory.validate()
        let commonPath = canonical(try line(result.output))
        let common = try GitWorktreeDirectory(path: commonPath)
        let adminResult = try await command.run(["rev-parse", "--absolute-git-dir"], cwdFD: directory.fd)
        guard adminResult.status == 0 else { throw GitWorktreeError(.notRepository, "This source folder has no available Git administration directory.") }
        let admin = try GitWorktreeDirectory(path: canonical(try line(adminResult.output)))
        let context = Context(source: directory, common: common, admin: admin)
        try await validateMapping(context); return context
    }
    private func validateMapping(_ context: Context) async throws {
        for (argument, expected) in [("--git-common-dir", context.common), ("--absolute-git-dir", context.admin)] {
            let result = try await command.run(["rev-parse", "--path-format=absolute", argument], cwdFD: context.source.fd)
            guard result.status == 0, canonical(try line(result.output)) == expected.path else { throw worktreeFileFailure("The source checkout's Git pointer changed. No branch or worktree was changed.") }
            try expected.validate()
        }
        if context.admin.path != context.common.path {
            let top = try await command.run(["rev-parse", "--show-toplevel"], cwdFD: context.source.fd)
            guard top.status == 0, context.admin.path.hasPrefix(context.common.path + "/worktrees/"),
                  let backlink = try context.admin.read("gitdir", maximum: 16_384),
                  canonical(try line(backlink)) == canonical(try line(top.output)) + "/.git",
                  let relativeCommon = try context.admin.read("commondir", maximum: 16_384) else {
                throw worktreeFileFailure("The source worktree administration backlink changed. No repository was retargeted.")
            }
            let commonValue = try line(relativeCommon)
            let referenced = canonical(commonValue.hasPrefix("/") ? commonValue : context.admin.path + "/" + commonValue)
            guard referenced == context.common.path else { throw worktreeFileFailure("The source worktree common-directory pointer changed.") }
        }
        try context.source.validate()
    }
    private func output(_ arguments: [String], at directory: GitWorktreeDirectory, context: Context? = nil, timeout: Duration = .seconds(30), maximumOutput: Int = 1_048_576) async throws -> Data {
        try directory.validate()
        let result = try await command.run(arguments, cwdFD: directory.fd, timeout: timeout, maximumOutput: maximumOutput,
                                           gitDirectory: context?.admin.path, commonDirectory: context?.common.path, workTree: context?.source.path)
        try directory.validate()
        guard result.status == 0 else { throw GitWorktreeError(.commandFailed, "A local worktree Git command failed. Existing branches and files were preserved.") }
        return result.output
    }
    private func line(_ data: Data) throws -> String {
        guard var value = String(data: data, encoding: .utf8), !value.contains("\0"), value.utf16.count <= 8_192 else { throw GitWorktreeError(.commandFailed, "Git returned an unsupported local path or ref encoding.") }
        if value.hasSuffix("\n") { value.removeLast() }
        guard !value.isEmpty else { throw GitWorktreeError(.commandFailed, "Git returned an empty local path or ref.") }; return value
    }
    private func inventory(_ context: Context) async throws -> GitWorktreeInventory {
        let data = try await output(["worktree", "list", "--porcelain", "-z"], at: context.source, context: context, maximumOutput: 8_388_608)
        try context.common.validate()
        let parsed = try Self.parseInventory(data, sourcePath: context.source.path, commonDirectoryPath: context.common.path)
        var paths = Set<String>()
        let worktrees = try parsed.worktrees.map { entry in
            let path = canonical(entry.path)
            try WorktreeValidation.path(path)
            guard paths.insert(path).inserted else { throw GitWorktreeError(.commandFailed, "Git returned duplicate checkout paths after local path resolution.") }
            return GitWorktree(path: path, headCommit: entry.headCommit, branch: entry.branch, isBare: entry.isBare,
                               isDetached: entry.isDetached, lockedReason: entry.lockedReason, prunableReason: entry.prunableReason)
        }
        return .init(sourcePath: context.source.path, commonDirectoryPath: context.common.path, worktrees: worktrees)
    }
    private func checkBranch(_ branch: String, context: Context) async throws {
        try WorktreeValidation.branch(branch)
        let value = try line(await output(["check-ref-format", "--branch", branch], at: context.source, context: context))
        guard value == branch else { throw WorktreeValidation.invalid("Choose a literal local branch name.") }
    }
    private func commit(_ ref: String, context: Context) async throws -> String {
        let result = try await command.run(["rev-parse", "--verify", "--end-of-options", ref + "^{commit}"], cwdFD: context.source.fd,
                                           gitDirectory: context.admin.path, commonDirectory: context.common.path, workTree: context.source.path)
        try context.source.validate(); try context.common.validate()
        guard result.status == 0 else { throw GitWorktreeError(.branchMissing, "The selected commit is not available locally. Choose an existing local ref; no fetch was performed.") }
        let value = try line(result.output); try WorktreeValidation.commit(value); return value
    }
    /// Uses a real captured branch and configured upstream. A failed fetch never
    /// falls back to a stale tracking ref or the source checkout.
    private func automaticCommit(_ base: GitWorktreeAutomaticBase, context: Context) async throws -> String {
        let capture: TaskIsolationCapture
        if let environment = command.environment { capture = .init(environment: environment, gitExecutable: command.executable) }
        else { capture = .init() }
        try await capture.validate(base.sourceProof)
        guard context.source.path.utf8.elementsEqual(base.sourceProof.sourcePath.utf8),
              context.common.path.utf8.elementsEqual(base.sourceProof.commonDirectoryPath.utf8),
              context.common.identity == base.sourceProof.commonDirectoryIdentity,
              context.admin.path.utf8.elementsEqual(base.sourceProof.sourceGitDirectoryPath.utf8),
              context.admin.identity == base.sourceProof.sourceGitDirectoryIdentity else { throw TaskIsolationError.changedRepository }
        try await checkBranch(base.branch, context: context)
        guard base.startFromOrigin else { return try await commit("refs/heads/" + base.branch, context: context) }
        let remoteData = try await output(["remote"], at: context.source, context: context)
        guard let remoteText = String(data: remoteData, encoding: .utf8) else { throw TaskIsolationError.changedRepository }
        let remotes = remoteText.split(separator: "\n").map(String.init)
        func config(_ key: String) async throws -> String? {
            let result = try await command.run(["config", "--get", key], cwdFD: context.source.fd,
                gitDirectory: context.admin.path, commonDirectory: context.common.path, workTree: context.source.path)
            try await validateMapping(context)
            if result.status == 1 { return nil }
            guard result.status == 0 else { throw TaskIsolationError.changedRepository }
            return try line(result.output)
        }
        let upstream = try await config("branch." + base.branch + ".remote")
        let merge = try await config("branch." + base.branch + ".merge")
        let remote: String, branch: String
        if let upstream, remotes.contains(upstream), let merge, merge.hasPrefix("refs/heads/") {
            remote = upstream; branch = String(merge.dropFirst("refs/heads/".count))
        } else if remotes.contains("origin") { remote = "origin"; branch = base.branch }
        else { return try await commit("refs/heads/" + base.branch, context: context) }
        guard !remote.isEmpty, !remote.hasPrefix("-"), remote.utf8.count <= 1_024,
              !remote.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) else { throw TaskIsolationError.changedRepository }
        try WorktreeValidation.branch(branch)
        return try await GitOperationGate.shared.perform(key: context.common.path) {
            try await validateMapping(context)
            let result = try await command.run(["fetch", "--no-recurse-submodules", "--no-prune", "--no-tags", "--", remote,
                "+refs/heads/" + branch + ":refs/remotes/" + remote + "/" + branch], cwdFD: context.source.fd,
                timeout: timeout, gitDirectory: context.admin.path, commonDirectory: context.common.path,
                workTree: context.source.path, allowedProtocols: command.inheritedProtocolAllowlist ?? "https:http:ssh:git:file")
            try await validateMapping(context)
            guard result.status == 0 else { throw GitWorktreeError(.commandFailed, "Fetching the configured worktree base failed. The input remains queued; no base-checkout turn was sent.") }
            return try await commit("refs/remotes/" + remote + "/" + branch, context: context)
        }
    }

    private func optionalBranchCommit(_ branch: String, context: Context) async throws -> String? {
        let result = try await command.run(["rev-parse", "--verify", "--quiet", "--end-of-options", "refs/heads/" + branch + "^{commit}"], cwdFD: context.source.fd,
                                           gitDirectory: context.admin.path, commonDirectory: context.common.path, workTree: context.source.path)
        try context.source.validate(); try context.common.validate()
        if result.status == 1 { return nil }
        guard result.status == 0 else { throw GitWorktreeError(.commandFailed, "The local branch could not be inspected safely.") }
        let value = try line(result.output); try WorktreeValidation.commit(value); return value
    }
    private func requireAvailableBranch(_ branch: String, creating: Bool, context: Context, inventory: GitWorktreeInventory) async throws {
        if let existing = inventory.worktrees.first(where: { $0.branch == branch && !$0.isBare }) {
            throw GitWorktreeError(.branchInUse, "This branch is already registered in a worktree. Choose explicit registered-worktree reuse instead of creating another checkout.", existingWorktree: existing)
        }
        let existing = try await optionalBranchCommit(branch, context: context)
        if creating, existing != nil { throw GitWorktreeError(.branchExists, "This local branch already exists. Choose the existing branch or an explicitly verified registered worktree; no branch was reset.") }
        if !creating, existing == nil { throw GitWorktreeError(.branchMissing, "The selected local branch no longer exists.") }
    }
    private func plan(_ request: GitWorktreeRequest, context: Context, branch: String, commit: String) throws -> GitWorktreePlan {
        let parent = try GitWorktreeDirectory(path: request.destinationRoot)
        guard try !parent.exists(request.id.uuidString), try !parent.exists(GitWorktreeOwnership.filename(request.id)),
              try !parent.exists(GitWorktreeCompletion.filename(request.id)) else {
            throw GitWorktreeError(.destinationExists, "This worktree attempt already has a destination or ownership record. Preserve it and choose a new attempt.")
        }
        return try .init(request: request, sourcePath: context.source.path, commonDirectoryPath: context.common.path,
                         sourceIdentity: context.source.identity, commonDirectoryIdentity: context.common.identity,
                         destinationParentIdentity: parent.identity, branch: branch, baseCommit: commit,
                         sourceGitDirectoryPath: context.admin.path, sourceGitDirectoryIdentity: context.admin.identity)
    }
    private func execute(_ plan: GitWorktreePlan, context: Context) async throws -> GitWorktreeResult {
        try validate(context, plan: plan)
        try await validateMapping(context)
        if case .reuse = plan.request.selection {
            guard let result = try await inspect(plan, context: context) else { throw GitWorktreeError(.incomplete, "The registered worktree changed after it was selected. Choose it again to capture its current ownership.") }
            return result
        }
        let parent = try GitWorktreeDirectory(path: plan.request.destinationRoot)
        try parent.validate(expected: plan.destinationParentIdentity)
        let lock = try parent.lock(GitWorktreeOwnership.lockname(plan.id)); defer { withExtendedLifetime(lock) {} }
        if let completed = try await inspect(plan, context: context) { return completed }
        guard try !parent.exists(plan.id.uuidString), try !parent.exists(GitWorktreeOwnership.filename(plan.id)) else {
            throw GitWorktreeError(.incomplete, "This attempt has unfinished worktree data. Its files were preserved; inspect the destination and create a new attempt instead of retrying over it.")
        }
        let inventory = try await inventory(context)
        let creating: Bool
        if case .createBranch = plan.request.selection { creating = true } else { creating = false }
        try await requireAvailableBranch(plan.branch, creating: creating, context: context, inventory: inventory)
        if !creating, try await optionalBranchCommit(plan.branch, context: context) != plan.baseCommit { throw worktreeFileFailure("The selected local branch moved after planning. No checkout or branch was changed.") }
        guard try await commit(plan.baseCommit, context: context) == plan.baseCommit else { throw worktreeFileFailure() }
        try await validateMapping(context)
        try validate(context, plan: plan); try parent.validate(expected: plan.destinationParentIdentity)
        let checkout = try parent.claimDirectory(plan.id.uuidString)
        let owner = GitWorktreeOwnership(plan: plan, destinationIdentity: checkout.identity)
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        try parent.writeExclusive(encoder.encode(owner), name: GitWorktreeOwnership.filename(plan.id))
        try checkout.validate(); try parent.validate(expected: plan.destinationParentIdentity); try validate(context, plan: plan)
        var args = ["worktree", "add", "--quiet", "--no-guess-remote"]
        if creating { args += ["--no-track", "-b", plan.branch] }
        args += ["--", plan.destinationPath, creating ? plan.baseCommit : plan.branch]
        let result = try await command.run(args, cwdFD: context.source.fd, timeout: timeout,
                                           gitDirectory: context.admin.path, commonDirectory: context.common.path, workTree: context.source.path)
        try await validateMapping(context)
        try checkout.validate(); try parent.validate(expected: plan.destinationParentIdentity); try validate(context, plan: plan)
        guard result.status == 0 else { throw GitWorktreeError(.commandFailed, "Git did not finish creating this worktree. Existing branches and checkout data were preserved; inspect the attempt before choosing a new one.") }
        // Only this owned successful-exit path may turn a claimed destination into a durable
        // completion. A process lost before this receipt could still have an orphaned Git hook.
        guard let checkoutResult = try await inspect(plan, context: context, requireReceipt: false) else { throw GitWorktreeError(.incomplete, "Git returned without verifiable registered-worktree ownership. Existing files were preserved.") }
        let initialInventory = try await self.inventory(context)
        let initial = try await verifyCheckout(path: plan.destinationPath, context: context, inventory: initialInventory, branch: plan.branch)
        let warning = try await initializeSubmodules(plan, checkout: initial, source: context)
        let finalInventory = try await self.inventory(context)
        let checked = try await verifyCheckout(path: plan.destinationPath, context: context, inventory: finalInventory, branch: plan.branch)
        guard checked.result == checkoutResult else { throw worktreeFileFailure("The completed checkout changed before it could be recorded.") }
        let completed = GitWorktreeResult(destinationPath: checkoutResult.destinationPath, headCommit: checkoutResult.headCommit,
                                          branch: checkoutResult.branch, submoduleWarning: warning)
        try completed.validate(); try Task.checkCancellation()
        try checkout.validate(expected: owner.destinationIdentity); try validate(context, plan: plan); try parent.validate(expected: plan.destinationParentIdentity)
        let receipt = GitWorktreeCompletion(ownership: owner, result: completed, gitDirectoryPath: checked.gitDirectory.path, gitDirectoryIdentity: checked.gitDirectory.identity)
        try parent.writeExclusive(encoder.encode(receipt), name: GitWorktreeCompletion.filename(plan.id))
        guard let recorded = try await inspect(plan, context: context) else { throw GitWorktreeError(.incomplete, "The completed worktree no longer matches its recorded receipt. Existing files were preserved.") }
        return recorded
    }
    private func inspect(_ plan: GitWorktreePlan, context: Context, requireReceipt: Bool = true) async throws -> GitWorktreeResult? {
        try validate(context, plan: plan)
        let destination: GitWorktreeNodeIdentity
        let parentPath = URL(fileURLWithPath: plan.destinationPath).deletingLastPathComponent().path
        let parent = try GitWorktreeDirectory(path: parentPath)
        try parent.validate(expected: plan.destinationParentIdentity)
        var completion: GitWorktreeCompletion?
        if case .reuse = plan.request.selection { destination = plan.destinationIdentity! }
        else {
            guard let bytes = try parent.read(GitWorktreeOwnership.filename(plan.id)) else { return nil }
            guard let owner = try? JSONDecoder().decode(GitWorktreeOwnership.self, from: bytes), owner.plan == plan else { throw GitWorktreeError(.metadataCorrupt, "The worktree ownership record does not match this attempt. No files were changed.") }
            destination = owner.destinationIdentity
            if requireReceipt {
                guard let receiptBytes = try parent.read(GitWorktreeCompletion.filename(plan.id)) else { return nil }
                guard let receipt = try? JSONDecoder().decode(GitWorktreeCompletion.self, from: receiptBytes),
                      receipt.ownership.plan == plan, receipt.ownership.destinationIdentity == destination,
                      receipt.result.submoduleWarning == nil || plan.request.submodules != .none else {
                    throw GitWorktreeError(.metadataCorrupt, "The worktree completion receipt does not match this attempt. Existing files were preserved.")
                }
                completion = receipt
            }
        }
        guard try parent.exists(URL(fileURLWithPath: plan.destinationPath).lastPathComponent) else { return nil }
        let directory = try GitWorktreeDirectory(path: plan.destinationPath)
        try directory.validate(expected: destination)
        let inventory = try await inventory(context)
        guard inventory.worktrees.contains(where: { canonical($0.path) == canonical(plan.destinationPath) && $0.branch == plan.branch && !$0.isBare && !$0.isDetached && $0.prunableReason == nil }) else { return nil }
        let checked = try await verifyCheckout(path: plan.destinationPath, context: context, inventory: inventory, branch: plan.branch)
        guard checked.result.headCommit == plan.baseCommit else { return nil }
        if let completion {
            guard completion.result.hasSameCheckout(as: checked.result), completion.gitDirectoryPath == checked.gitDirectory.path,
                  completion.gitDirectoryIdentity == checked.gitDirectory.identity else { return nil }
        }
        try checked.directory.validate(expected: destination)
        if case .reuse = plan.request.selection {
            guard checked.gitDirectory.path == plan.worktreeGitDirectoryPath,
                  checked.gitDirectory.identity == plan.worktreeGitDirectoryIdentity else { throw worktreeFileFailure("The registered worktree administration directory changed after selection.") }
        }
        try await validateMapping(context)
        try parent.validate(expected: plan.destinationParentIdentity); try validate(context, plan: plan)
        return completion?.result ?? checked.result
    }
    private func initializeSubmodules(_ plan: GitWorktreePlan, checkout: Checkout, source: Context) async throws -> String? {
        guard plan.request.submodules != .none else { return nil }
        let context = Context(source: checkout.directory, common: source.common, admin: checkout.gitDirectory)
        try await validateMapping(context); try validate(source, plan: plan)
        let entry = try await output(["ls-tree", "-z", plan.baseCommit, "--", ".gitmodules"], at: checkout.directory, context: context)
        let expected: Data?
        if entry.isEmpty { expected = nil }
        else {
            guard entry.starts(with: Data("100644 blob ".utf8)) || entry.starts(with: Data("100755 blob ".utf8)) else {
                throw worktreeFileFailure("The selected checkout has unsupported submodule configuration metadata.")
            }
            expected = try await output(["show", plan.baseCommit + ":.gitmodules"], at: checkout.directory, context: context, maximumOutput: 262_144)
        }
        let actual: Data?
        do { actual = try checkout.directory.read(".gitmodules", maximum: 262_144, allowEmpty: true) }
        catch is CancellationError { throw CancellationError() }
        catch { throw worktreeFileFailure("The checkout's submodule configuration is missing, replaced, or inaccessible.") }
        guard actual == expected else { throw worktreeFileFailure("Submodule configuration changed after checkout. Its files were preserved without fetching.") }
        let index = try await command.run(["diff", "--cached", "--quiet", "--no-ext-diff", plan.baseCommit, "--"], cwdFD: checkout.directory.fd,
                                           gitDirectory: context.admin.path, commonDirectory: context.common.path, workTree: context.source.path)
        guard index.status == 0 else { throw worktreeFileFailure("The checkout index changed before submodule initialization. Its files were preserved.") }
        var warning: String?
        do {
            let policy = try await command.run(["config", "--null", "--get-regexp", "^protocol\\.(allow|(http|https|ssh|git|file)\\.allow)$"], cwdFD: checkout.directory.fd,
                                                gitDirectory: context.admin.path, commonDirectory: context.common.path, workTree: context.source.path)
            guard policy.status == 0 || policy.status == 1 else { throw GitWorktreeError(.commandFailed, "Git transport policy could not be read safely.") }
            let protocols = try GitWorktreeSubmodulePolicy.allowlist(configuration: policy.output, inherited: command.inheritedProtocolAllowlist)
            let finalIndex = try await command.run(["diff", "--cached", "--quiet", "--no-ext-diff", plan.baseCommit, "--"], cwdFD: checkout.directory.fd,
                                                    gitDirectory: context.admin.path, commonDirectory: context.common.path, workTree: context.source.path)
            guard finalIndex.status == 0 else { throw worktreeFileFailure("The checkout index changed before submodule initialization. Its files were preserved.") }
            try await validateMapping(context); try validate(source, plan: plan); try checkout.directory.validate()
            // Policy/index discovery suspends. Re-read the anchored configuration
            // after those waits and immediately before spawning Git. External
            // processes can still race a later write; this is not a filesystem CAS.
            let finalConfiguration: Data?
            do { finalConfiguration = try checkout.directory.read(".gitmodules", maximum: 262_144, allowEmpty: true) }
            catch is CancellationError { throw CancellationError() }
            catch { throw worktreeFileFailure("The checkout's submodule configuration changed during validation.") }
            guard finalConfiguration == expected else { throw worktreeFileFailure("Submodule configuration changed during validation. No submodule was fetched.") }
            var arguments = ["submodule", "update", "--init", "--checkout"]
            if plan.request.submodules == .recursive { arguments.append("--recursive") }
            arguments.append("--")
            let initialized = try await command.run(arguments, cwdFD: checkout.directory.fd, timeout: timeout,
                                                    gitDirectory: context.admin.path, commonDirectory: context.common.path, workTree: context.source.path,
                                                    allowedProtocols: protocols)
            if initialized.status != 0 { warning = GitWorktreeResult.submoduleFailureWarning }
        } catch is CancellationError { throw CancellationError() }
        catch let error as GitWorktreeError where [.commandFailed, .outputLimit, .timedOut].contains(error.failure) {
            warning = GitWorktreeResult.submoduleFailureWarning
        }
        try Task.checkCancellation(); try await validateMapping(context); try validate(source, plan: plan)
        try checkout.directory.validate(); try checkout.gitDirectory.validate()
        return warning
    }
    private func verifyCheckout(path: String, context: Context, inventory: GitWorktreeInventory, branch: String?) async throws -> Checkout {
        guard let entry = inventory.worktrees.first(where: { canonical($0.path) == canonical(path) }),
              !entry.isBare, !entry.isDetached, entry.prunableReason == nil, let registeredBranch = entry.branch,
              branch == nil || branch == registeredBranch else { throw GitWorktreeError(.incomplete, "Choose an existing registered local-branch worktree from this repository.") }
        let directory = try GitWorktreeDirectory(path: path)
        let commonPath = canonical(try line(await output(["rev-parse", "--path-format=absolute", "--git-common-dir"], at: directory)))
        let common = try GitWorktreeDirectory(path: commonPath)
        guard common.path == context.common.path, common.identity == context.common.identity else { throw worktreeFileFailure("The selected checkout belongs to a different Git repository.") }
        let gitPath = canonical(try line(await output(["rev-parse", "--absolute-git-dir"], at: directory)))
        let gitDirectory = try GitWorktreeDirectory(path: gitPath)
        let checkoutContext = Context(source: directory, common: common, admin: gitDirectory)
        try await validateMapping(checkoutContext)
        let top = canonical(try line(await output(["rev-parse", "--show-toplevel"], at: directory, context: checkoutContext)))
        guard top == canonical(path) else { throw worktreeFileFailure("Select the worktree root rather than a subfolder.") }
        let ref = try line(await output(["symbolic-ref", "--quiet", "HEAD"], at: directory, context: checkoutContext))
        guard ref == "refs/heads/" + registeredBranch else { throw worktreeFileFailure("The selected worktree branch changed while it was inspected.") }
        let head = try line(await output(["rev-parse", "--verify", "HEAD^{commit}"], at: directory, context: checkoutContext)); try WorktreeValidation.commit(head)
        if gitDirectory.path != common.path {
            guard gitDirectory.path.hasPrefix(common.path + "/worktrees/"), let backlink = try gitDirectory.read("gitdir", maximum: 16_384),
                  canonical(try line(backlink)) == canonical(path) + "/.git" else { throw worktreeFileFailure("The registered worktree backlink does not match this checkout.") }
        }
        try await validateMapping(checkoutContext)
        try directory.validate(); try gitDirectory.validate(); try context.common.validate()
        return .init(directory: directory, gitDirectory: gitDirectory, result: .init(destinationPath: path, headCommit: head, branch: registeredBranch))
    }
}
