import Darwin
import Foundation

struct CheckpointRestoreManifest: Codable, Sendable, Equatable {
    let id: UUID
    let target: GitCheckpointReceipt
    let current: GitCheckpointPlan
    let parentPath: String
    let parentIdentity: GitWorktreeNodeIdentity
    let dataIdentity: GitWorktreeNodeIdentity
    let shadowIdentity: GitWorktreeNodeIdentity
    let recoveryIdentity: GitWorktreeNodeIdentity
    let before: [CheckpointRestoreNode]
    let desired: [CheckpointRestoreNode]
    let candidateIndexDigest: String
    let publishesIndex: Bool
    let headRevision: GitCheckpointIndexRevision
    let executionLockIdentity: GitWorktreeNodeIdentity
    let metadataScratch: [CheckpointRestoreNode]
    let dataScratch: [CheckpointRestoreNode]
    let roots: [String]
}
struct CheckpointRestoreCompletion: Codable, Sendable {
    let receipt: GitCheckpointRestoreReceipt
    let nodes: [CheckpointRestoreNode]
}

extension GitCheckpointService {
    public func reviewRestore(target: GitCheckpointReceipt, id: UUID = UUID()) async throws -> GitCheckpointRestoreReview {
        try await restoreTranslated {
            try target.validate(); try validateSession(target.plan)
            let deadline = ContinuousClock.now.advanced(by: timeout)
            let context = try await discover(deadline: deadline)
            try validate(target.plan, context)
            return try await GitOperationGate.shared.perform(key: target.plan.commonDirectoryPath) {
                guard try await inspect(target.plan, context, deadline: deadline) == .ready(target) else { throw GitCheckpointRestoreError(.invalidReview) }
                let current = try await prepare(id: id)
                try validate(current, context)
                let configuration = try await configuration(context, deadline: deadline)
                let metadata = try context.common.claimDirectory(CheckpointRestoreFiles.name(id))
                let executionLock = try metadata.lock("execution.lock")
                defer { withExtendedLifetime(executionLock) {} }
                var lockNode = stat()
                guard fstat(executionLock.fd, &lockNode) == 0,
                      let headRevision = try CheckpointFiles.index(context.admin, name: "HEAD", maximum: 16_384) else { throw GitCheckpointRestoreError(.metadataInvalid) }
                let parent = try GitWorktreeDirectory(path: URL(fileURLWithPath: current.repositoryPath).deletingLastPathComponent().path)
                guard parent.identity.device == context.repository.identity.device else { throw GitCheckpointRestoreError(.unsupportedConfiguration) }
                let data = try parent.claimDirectory(CheckpointRestoreFiles.name(id))
                let shadow = try data.claimDirectory("shadow"), recovery = try data.claimDirectory("recovery")
                let before = try CheckpointRestoreFiles.scan(context.repository, copyingTo: shadow)
                guard try CheckpointRestoreFiles.scan(context.repository) == before else { throw GitCheckpointRestoreError(.staleReview) }
                let staging = try makeStaging(current, configuration: configuration, metadata: metadata)
                let originalIndex = try context.admin.read("index", maximum: CheckpointFiles.maximumIndexBytes, allowEmpty: true)
                guard originalIndex.map(CheckpointFiles.digest) == current.indexRevision?.digest else { throw GitCheckpointRestoreError(.staleReview) }
                try CheckpointFiles.claimIndex(originalIndex ?? CheckpointFiles.emptyIndex(format: current.objectFormat), name: "index", admin: staging.admin)
                // Copy only the exact referenced split-index base, not historical bases.
                let shared = try await command.run(Self.safeOptions + ["rev-parse", "--path-format=absolute", "--shared-index-path"],
                    cwdFD: context.workspace.fd, timeout: remaining(deadline), maximumOutput: 16_385,
                    gitDirectory: context.admin.path, commonDirectory: context.common.path, workTree: context.repository.path)
                guard shared.status == 0 else { throw GitCheckpointRestoreError(.commandFailed) }
                if !shared.output.isEmpty, shared.output != Data([10]) {
                    let path = CheckpointFiles.canonical(try CheckpointFiles.line(shared.output))
                    let name = URL(fileURLWithPath: path).lastPathComponent
                    guard path == context.admin.path + "/" + name, name.hasPrefix("sharedindex."),
                          CheckpointValidation.object(String(name.dropFirst("sharedindex.".count)), format: current.objectFormat),
                          let bytes = try context.admin.read(name, maximum: CheckpointFiles.maximumIndexBytes, allowEmpty: true) else { throw GitCheckpointRestoreError(.metadataInvalid) }
                    try CheckpointFiles.claimIndex(bytes, name: name, admin: staging.admin)
                }
                let scope = current.workspacePath == current.repositoryPath ? "" : String(current.workspacePath.dropFirst(current.repositoryPath.count + 1))
                try await restoreValidateFilters(target, configuration: configuration, context, shadow: shadow, staging: staging, deadline: deadline)
                var cwd = try CheckpointRestoreFiles.directory(shadow, scope)
                let inventory = try await restoreOutput(["ls-files", "--cached", "--with-tree=" + target.commit, "-z", "--", "."], context, shadow: shadow, cwd: cwd, staging: staging, deadline: deadline)
                if !inventory.isEmpty {
                    _ = try await restoreOutput(["restore", "--source=" + target.commit, "--worktree", "--staged", "--", "."], context, shadow: shadow, cwd: cwd, staging: staging, deadline: deadline)
                }
                // Git may remove an empty scope; recreate only our private shadow path.
                cwd = try CheckpointRestoreFiles.directory(shadow, scope, create: true)
                let cleaned = try await restoreCommand(["clean", "-fd", "--", "."], context, shadow: shadow, cwd: cwd, staging: staging, deadline: deadline)
                if cleaned.status != 0 {
                    // The one upstream exception is an empty cwd Git tried to remove.
                    let remaining = try CheckpointRestoreFiles.directory(shadow, scope, create: true)
                    let warning = String(data: cleaned.errorOutput, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                    let prefix = "warning: failed to remove ./: "
                    guard cleaned.status == 1, warning.hasPrefix(prefix), warning.count > prefix.count,
                          !warning.contains("\n"), !warning.contains("\r"),
                          try CheckpointRestoreFiles.names(remaining).isEmpty else { throw GitCheckpointRestoreError(.commandFailed) }
                }
                cwd = try CheckpointRestoreFiles.directory(shadow, scope, create: true)
                if current.headCommit != nil { _ = try await restoreOutput(["reset", "--quiet", "--", "."], context, shadow: shadow, cwd: cwd, staging: staging, deadline: deadline) }
                if !scope.isEmpty, let originalScope = before.first(where: { $0.path == scope }) {
                    let scopeDirectory = try CheckpointRestoreFiles.directory(shadow, scope, create: true)
                    guard fchmod(scopeDirectory.fd, mode_t(originalScope.mode)) == 0 else { throw GitCheckpointRestoreError(.ownershipLost) }
                }
                let desired = try CheckpointRestoreFiles.scan(shadow)
                let roots = try restoreRoots(before: before, desired: desired, scope: scope)
                guard let index = try staging.admin.read("index", maximum: CheckpointFiles.maximumIndexBytes, allowEmpty: true) else { throw GitCheckpointRestoreError(.metadataInvalid) }
                try CheckpointFiles.claimIndex(index, name: "candidate.index", admin: metadata)
                let preview = try await restorePreview(before: before, desired: desired, context: context, shadow: shadow,
                    data: data, staging: staging, deadline: deadline, scope: scope)
                let metadataScratch = try CheckpointRestoreFiles.scan(metadata, protectRepositories: false)
                let dataScratch = try CheckpointRestoreFiles.scan(data, protectRepositories: false)
                let manifest = CheckpointRestoreManifest(id: id, target: target, current: current, parentPath: parent.path,
                    parentIdentity: parent.identity, dataIdentity: data.identity, shadowIdentity: shadow.identity, recoveryIdentity: recovery.identity,
                    before: before, desired: desired, candidateIndexDigest: CheckpointFiles.digest(index),
                    publishesIndex: originalIndex != nil || !inventory.isEmpty || current.headCommit != nil,
                    headRevision: headRevision, executionLockIdentity: worktreeIdentity(lockNode),
                    metadataScratch: metadataScratch, dataScratch: dataScratch, roots: roots)
                let manifestBytes = try CheckpointRestoreFiles.encoded(manifest)
                let beforeByPath = Dictionary(uniqueKeysWithValues: before.map { ($0.path, $0) })
                let afterByPath = Dictionary(uniqueKeysWithValues: desired.map { ($0.path, $0) })
                let paths = Set(beforeByPath.keys).union(afterByPath.keys).filter { path in
                    guard let a = beforeByPath[path], let b = afterByPath[path] else { return true }; return !a.sameContents(b)
                }.sorted().map { scope.isEmpty ? $0 : String($0.dropFirst(scope.count + 1)) }
                let review = try GitCheckpointRestoreReview(id: id, targetReceipt: target, currentPlan: current,
                    manifestDigest: CheckpointFiles.digest(manifestBytes), affectedPaths: paths, previewPatch: preview.patch, previewTruncated: preview.truncated)
                try await validateCurrent(current, context, deadline: deadline)
                guard try CheckpointFiles.index(context.admin, name: "HEAD", maximum: 16_384) == headRevision,
                      try CheckpointRestoreFiles.scan(context.repository) == before,
                      try await inspect(target.plan, context, deadline: deadline) == .ready(target) else { throw GitCheckpointRestoreError(.staleReview) }
                try CheckpointRestoreFiles.write(manifestBytes, to: metadata, name: "manifest.json")
                try CheckpointRestoreFiles.write(try CheckpointRestoreFiles.encoded(review), to: metadata, name: "review.json")
                return review
            }
        }
    }

    public func restore(review: GitCheckpointRestoreReview) async throws -> GitCheckpointRestoreReceipt {
        try await restoreTranslated {
            try review.validate(); try validateSession(review.currentPlan)
            let priorWrite = restorePriorWriteEvidence(review)
            do {
                let deadline = ContinuousClock.now.advanced(by: timeout), context = try await discover(deadline: deadline)
                try validate(review.currentPlan, context)
                return try await GitOperationGate.shared.perform(key: review.currentPlan.commonDirectoryPath) {
                    let owned = try restoreOwned(review, context)
                    guard let lock = try restoreExecutionLock(owned) else { throw GitCheckpointRestoreError(.interrupted, mayHaveMutated: true) }
                    defer { withExtendedLifetime(lock) {} }
                    if let completion = try restoreCompletion(review, owned: owned) {
                        try await verifyRestoreCompletion(completion, context, owned: owned, deadline: deadline)
                        return completion.receipt
                    }
                    guard try !owned.metadata.exists("started.json") else { throw GitCheckpointRestoreError(.interrupted, mayHaveMutated: true) }
                    try await validateCurrent(review.currentPlan, context, deadline: deadline)
                    guard try await inspect(review.targetReceipt.plan, context, deadline: deadline) == .ready(review.targetReceipt),
                          try CheckpointRestoreFiles.scan(context.repository) == owned.manifest.before else { throw GitCheckpointRestoreError(.staleReview) }
                    guard let candidate = try owned.metadata.read("candidate.index", maximum: CheckpointFiles.maximumIndexBytes, allowEmpty: true),
                          CheckpointFiles.digest(candidate) == owned.manifest.candidateIndexDigest,
                          CheckpointRestoreFiles.sameContents(try CheckpointRestoreFiles.scan(owned.shadow), owned.manifest.desired) else { throw GitCheckpointRestoreError(.metadataInvalid) }
                    // Repeat mutable Git proof after all target/object subprocesses have drained.
                    try await validateCurrent(review.currentPlan, context, deadline: deadline)
                    guard try CheckpointRestoreFiles.scan(context.repository) == owned.manifest.before,
                          try CheckpointFiles.index(context.admin, name: "HEAD", maximum: 16_384) == owned.manifest.headRevision,
                          try !context.admin.exists("index.lock") else { throw GitCheckpointRestoreError(.staleReview) }
                    // No async work occurs between the final proof and recording first-write intent.
                    try validate(review.currentPlan, context); try owned.data.validate(); try Task.checkCancellation()
                    try owned.metadata.writeExclusive(Data((review.manifestDigest + "\n").utf8), name: "started.json")
                    var indexLock: RestoreIndexLock?
                    do {
                        indexLock = try RestoreIndexLock(admin: context.admin, bytes: candidate)
                        for path in owned.manifest.roots {
                            try Task.checkCancellation(); try validate(review.currentPlan, context)
                            try restoreApply(path, context, owned: owned)
                        }
                        try await validateMapping(context, deadline: deadline)
                        guard try await head(context, deadline: deadline) == review.currentPlan.headCommit,
                              try CheckpointFiles.index(context.admin, name: "HEAD", maximum: 16_384) == owned.manifest.headRevision,
                              try CheckpointFiles.index(context.admin) == review.currentPlan.indexRevision else { throw GitCheckpointRestoreError(.staleReview) }
                        let final = try CheckpointRestoreFiles.scan(context.repository)
                        guard CheckpointRestoreFiles.sameContents(final, owned.manifest.desired) else { throw GitCheckpointRestoreError(.staleReview) }
                        try indexLock!.publish(expected: review.currentPlan.indexRevision, metadata: owned.metadata, publishesIndex: owned.manifest.publishesIndex)
                        let index = try CheckpointFiles.index(context.admin)
                        guard owned.manifest.publishesIndex ? index?.digest == owned.manifest.candidateIndexDigest : index == nil else { throw GitCheckpointRestoreError(.metadataInvalid) }
                        let receipt = try GitCheckpointRestoreReceipt(review: review, finalIndexRevision: index,
                            stateDigest: CheckpointRestoreFiles.digest(final))
                        try Task.checkCancellation(); try validate(review.currentPlan, context)
                        let complete = CheckpointRestoreCompletion(receipt: receipt, nodes: final)
                        try CheckpointRestoreFiles.write(try CheckpointRestoreFiles.encoded(complete), to: owned.metadata, name: "complete.json")
                        try await verifyRestoreCompletion(complete, context, owned: owned, deadline: deadline)
                        return receipt
                    } catch {
                        // All original displaced bytes remain in recovery. No automatic rollback,
                        // retry, branch reset, clean, prune or deletion is attempted here.
                        indexLock = nil
                        if let failure = error as? GitCheckpointRestoreError { throw GitCheckpointRestoreError(failure.kind, mayHaveMutated: true) }
                        throw GitCheckpointRestoreError(.interrupted, mayHaveMutated: true)
                    }
                }
            } catch {
                // A prior owned first-write marker
                // must never be downgraded by a later metadata read failure.
                if priorWrite || restorePriorWriteEvidence(review) {
                    throw GitCheckpointRestoreError((error as? GitCheckpointRestoreError)?.kind ?? .interrupted, mayHaveMutated: true)
                }
                throw error
            }
        }
    }

    public func inspectRestore(review: GitCheckpointRestoreReview) async throws -> GitCheckpointRestoreInspection {
        try await restoreTranslated {
            try review.validate(); try validateSession(review.currentPlan)
            let deadline = ContinuousClock.now.advanced(by: timeout), context = try await discover(deadline: deadline)
            try validate(review.currentPlan, context)
            return try await GitOperationGate.shared.perform(key: review.currentPlan.commonDirectoryPath) {
                // Missing/tampered metadata never proves that no writes happened.
                let owned = try restoreOwned(review, context)
                guard let lock = try restoreExecutionLock(owned) else { return .interrupted }
                defer { withExtendedLifetime(lock) {} }
                if let completion = try restoreCompletion(review, owned: owned) {
                    try await verifyRestoreCompletion(completion, context, owned: owned, deadline: deadline)
                    return .ready(completion.receipt)
                }
                if try owned.metadata.exists("started.json") { return .interrupted }
                try await validateCurrent(review.currentPlan, context, deadline: deadline)
                guard try await inspect(review.targetReceipt.plan, context, deadline: deadline) == .ready(review.targetReceipt),
                      try CheckpointRestoreFiles.scan(context.repository) == owned.manifest.before,
                      try CheckpointFiles.index(context.admin, name: "HEAD", maximum: 16_384) == owned.manifest.headRevision else { return .interrupted }
                return .notStarted
            }
        }
    }
}

struct CheckpointRestoreOwned: Sendable {
    let metadata: GitWorktreeDirectory
    let parent: GitWorktreeDirectory
    let data: GitWorktreeDirectory
    let shadow: GitWorktreeDirectory
    let recovery: GitWorktreeDirectory
    let manifest: CheckpointRestoreManifest
}
extension GitCheckpointService {
    private func restorePriorWriteEvidence(_ review: GitCheckpointRestoreReview) -> Bool {
        do {
            let common = try GitWorktreeDirectory(path: review.currentPlan.commonDirectoryPath)
            try common.validate(expected: review.currentPlan.commonDirectoryIdentity)
            let metadata = try GitWorktreeDirectory(child: CheckpointRestoreFiles.name(review.id), parent: common)
            guard let bytes = try metadata.read("manifest.json", maximum: CheckpointRestoreFiles.maximumManifest),
                  CheckpointFiles.digest(bytes) == review.manifestDigest,
                  let recorded = try metadata.read("review.json", maximum: CheckpointRestoreFiles.maximumManifest),
                  try JSONDecoder().decode(GitCheckpointRestoreReview.self, from: recorded) == review else { return false }
            return try metadata.exists("started.json")
        } catch { return false }
    }
    func restoreOwned(_ review: GitCheckpointRestoreReview, _ c: Context) throws -> CheckpointRestoreOwned {
        let metadata = try GitWorktreeDirectory(child: CheckpointRestoreFiles.name(review.id), parent: c.common)
        guard try !metadata.exists("discard-started.json"),
              let reviewBytes = try metadata.read("review.json", maximum: CheckpointRestoreFiles.maximumManifest),
              let recorded = try? JSONDecoder().decode(GitCheckpointRestoreReview.self, from: reviewBytes), recorded == review,
              let bytes = try metadata.read("manifest.json", maximum: CheckpointRestoreFiles.maximumManifest),
              CheckpointFiles.digest(bytes) == review.manifestDigest,
              let manifest = try? JSONDecoder().decode(CheckpointRestoreManifest.self, from: bytes),
              manifest.id == review.id, manifest.current == review.currentPlan, manifest.target == review.targetReceipt,
              manifest.parentPath == URL(fileURLWithPath: review.currentPlan.repositoryPath).deletingLastPathComponent().path,
              manifest.before.count <= 100_000, manifest.desired.count <= 100_000 else { throw GitCheckpointRestoreError(.metadataInvalid) }
        for node in manifest.before + manifest.desired { try CheckpointFiles.relative(node.path) }
        guard Set(manifest.before.map(\.path)).count == manifest.before.count,
              Set(manifest.desired.map(\.path)).count == manifest.desired.count else { throw GitCheckpointRestoreError(.metadataInvalid) }
        let scope = restoreScope(review.currentPlan)
        guard try restoreRoots(before: manifest.before, desired: manifest.desired, scope: scope) == manifest.roots else { throw GitCheckpointRestoreError(.metadataInvalid) }
        let parent = try GitWorktreeDirectory(path: manifest.parentPath)
        try parent.validate(expected: manifest.parentIdentity)
        let data = try GitWorktreeDirectory(child: CheckpointRestoreFiles.name(review.id), parent: parent)
        try data.validate(expected: manifest.dataIdentity)
        let shadow = try GitWorktreeDirectory(child: "shadow", parent: data), recovery = try GitWorktreeDirectory(child: "recovery", parent: data)
        try shadow.validate(expected: manifest.shadowIdentity); try recovery.validate(expected: manifest.recoveryIdentity)
        return .init(metadata: metadata, parent: parent, data: data, shadow: shadow, recovery: recovery, manifest: manifest)
    }
    func restoreExecutionLock(_ owned: CheckpointRestoreOwned) throws -> GitWorktreeLock? {
        let fd = openat(owned.metadata.fd, "execution.lock", O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        guard fd >= 0 else { throw GitCheckpointRestoreError(.metadataInvalid) }
        var opened = stat(), named = stat()
        guard fstat(fd, &opened) == 0, opened.st_mode & S_IFMT == S_IFREG, opened.st_size == 0,
              worktreeIdentity(opened) == owned.manifest.executionLockIdentity,
              fstatat(owned.metadata.fd, "execution.lock", &named, AT_SYMLINK_NOFOLLOW) == 0,
              worktreeIdentity(named) == owned.manifest.executionLockIdentity else { close(fd); throw GitCheckpointRestoreError(.metadataInvalid) }
        if flock(fd, LOCK_EX | LOCK_NB) != 0 {
            let failure = errno; close(fd)
            if failure == EWOULDBLOCK || failure == EAGAIN { return nil }
            throw GitCheckpointRestoreError(.metadataInvalid)
        }
        return .init(fd: fd)
    }
    private func restoreCompletion(_ review: GitCheckpointRestoreReview, owned: CheckpointRestoreOwned) throws -> CheckpointRestoreCompletion? {
        guard let bytes = try owned.metadata.read("complete.json", maximum: CheckpointRestoreFiles.maximumManifest) else { return nil }
        guard let complete = try? JSONDecoder().decode(CheckpointRestoreCompletion.self, from: bytes), complete.receipt.review == review,
              try owned.metadata.read("started.json") == Data((review.manifestDigest + "\n").utf8),
              try CheckpointRestoreFiles.digest(complete.nodes) == complete.receipt.stateDigest,
              CheckpointRestoreFiles.sameContents(complete.nodes, owned.manifest.desired),
              owned.manifest.publishesIndex ? complete.receipt.finalIndexRevision?.digest == owned.manifest.candidateIndexDigest : complete.receipt.finalIndexRevision == nil else { throw GitCheckpointRestoreError(.metadataInvalid, mayHaveMutated: true) }
        return complete
    }
    private func verifyRestoreCompletion(_ completion: CheckpointRestoreCompletion, _ c: Context,
                                         owned: CheckpointRestoreOwned, deadline: ContinuousClock.Instant) async throws {
        let review = completion.receipt.review
        try validate(review.currentPlan, c); try await validateMapping(c, deadline: deadline)
        guard try await inspect(review.targetReceipt.plan, c, deadline: deadline) == .ready(review.targetReceipt),
              try await head(c, deadline: deadline) == review.currentPlan.headCommit,
              try CheckpointFiles.index(c.admin, name: "HEAD", maximum: 16_384) == owned.manifest.headRevision,
              try CheckpointFiles.index(c.admin) == completion.receipt.finalIndexRevision,
              try CheckpointRestoreFiles.scan(c.repository) == completion.nodes else {
            throw GitCheckpointRestoreError(.interrupted, mayHaveMutated: true)
        }
        try owned.metadata.validate(); try owned.data.validate(); try validate(review.currentPlan, c)
    }
    private func restoreScope(_ plan: GitCheckpointPlan) -> String {
        plan.workspacePath == plan.repositoryPath ? "" : String(plan.workspacePath.dropFirst(plan.repositoryPath.count + 1))
    }
    private func restoreRoots(before: [CheckpointRestoreNode], desired: [CheckpointRestoreNode], scope: String) throws -> [String] {
        let old = Dictionary(uniqueKeysWithValues: before.map { ($0.path, $0) }), new = Dictionary(uniqueKeysWithValues: desired.map { ($0.path, $0) })
        let all = Set(old.keys).union(new.keys).sorted()
        var roots = [String]()
        for path in all {
            let a = old[path], b = new[path]
            if let a, let b, a.sameContents(b) { continue }
            // Shadow Git must never alter outside the selected cwd scope.
            guard scope.isEmpty || path.hasPrefix(scope + "/") else { throw GitCheckpointRestoreError(.unsupportedConfiguration) }
            guard !roots.contains(where: { path.hasPrefix($0 + "/") }) else { continue }
            guard a?.opaque != true, b?.opaque != true,
                  !before.contains(where: { $0.opaque && path.hasPrefix($0.path + "/") }),
                  !desired.contains(where: { $0.opaque && path.hasPrefix($0.path + "/") }),
                  !before.contains(where: { $0.opaque && $0.path.hasPrefix(path + "/") }),
                  !desired.contains(where: { $0.opaque && $0.path.hasPrefix(path + "/") }) else { throw GitCheckpointRestoreError(.unsupportedConfiguration) }
            // Existing directories keep their inode. Their changed descendants get
            // their own moves; a type-change/removal/new directory is one subtree.
            if a?.kind == .directory && b?.kind == .directory {
                guard a?.mode == b?.mode else { throw GitCheckpointRestoreError(.unsupportedConfiguration) }
                continue
            }
            roots.append(path)
        }
        return roots
    }
    private func restoreApply(_ path: String, _ c: Context, owned: CheckpointRestoreOwned) throws {
        let previous = owned.manifest.before.filter { $0.path == path || $0.path.hasPrefix(path + "/") }
        let desired = owned.manifest.desired.filter { $0.path == path || $0.path.hasPrefix(path + "/") }
        let (liveParent, leaf) = try CheckpointRestoreFiles.parent(c.repository, path)
        if !previous.isEmpty {
            let (backupParent, backupLeaf) = try CheckpointRestoreFiles.parent(owned.recovery, path, create: true)
            guard renameatx_np(liveParent.fd, leaf, backupParent.fd, backupLeaf, UInt32(RENAME_EXCL)) == 0 else { throw GitCheckpointRestoreError(.staleReview) }
            guard fsync(liveParent.fd) == 0, fsync(backupParent.fd) == 0 else { throw GitCheckpointRestoreError(.ownershipLost) }
            // Verify what was actually moved. A last-moment external replacement is
            // preserved here and never silently overwritten by the desired bytes.
            let moved = try CheckpointRestoreFiles.scan(owned.recovery).filter { $0.path == path || $0.path.hasPrefix(path + "/") }
            guard moved == previous else { throw GitCheckpointRestoreError(.staleReview) }
        } else {
            guard try !liveParent.exists(leaf) else { throw GitCheckpointRestoreError(.staleReview) }
        }
        if !desired.isEmpty {
            let (sourceParent, sourceLeaf) = try CheckpointRestoreFiles.parent(owned.shadow, path)
            guard renameatx_np(sourceParent.fd, sourceLeaf, liveParent.fd, leaf, UInt32(RENAME_EXCL)) == 0 else { throw GitCheckpointRestoreError(.staleReview) }
            guard fsync(sourceParent.fd) == 0, fsync(liveParent.fd) == 0 else { throw GitCheckpointRestoreError(.ownershipLost) }
        }
        try liveParent.validate(); try owned.data.validate(); try c.repository.validate()
    }
    private func restoreCommand(_ args: [String], _ c: Context, shadow: GitWorktreeDirectory, cwd: GitWorktreeDirectory,
                                staging: Staging, deadline: ContinuousClock.Instant, maximum: Int = 4_194_304) async throws -> GitWorktreeCommandResult {
        try c.objects.validate(); try c.common.validate(); try shadow.validate(); try cwd.validate(); try staging.admin.validate()
        let result = try await command.run(Self.safeOptions + args, cwdFD: cwd.fd, timeout: remaining(deadline), maximumOutput: maximum,
            gitDirectory: staging.admin.path, commonDirectory: staging.admin.path, workTree: shadow.path,
            checkpointIndexPath: staging.admin.path + "/index", checkpointObjectDirectory: c.objects.path)
        try c.objects.validate(); try c.common.validate(); try shadow.validate(); try staging.admin.validate()
        return result
    }
    private func restoreOutput(_ args: [String], _ c: Context, shadow: GitWorktreeDirectory, cwd: GitWorktreeDirectory,
                               staging: Staging, deadline: ContinuousClock.Instant, maximum: Int = 4_194_304) async throws -> Data {
        let result = try await restoreCommand(args, c, shadow: shadow, cwd: cwd, staging: staging, deadline: deadline, maximum: maximum)
        guard result.status == 0 else { throw GitCheckpointRestoreError(.commandFailed) }; return result.output
    }
    private func restoreValidateFilters(_ target: GitCheckpointReceipt, configuration: Configuration, _ c: Context,
                                        shadow: GitWorktreeDirectory, staging: Staging, deadline: ContinuousClock.Instant) async throws {
        var drivers = configuration.executableFilters
        for (key, value) in configuration.values where key.hasPrefix("filter.") && key.hasSuffix(".smudge") && !value.isEmpty {
            drivers.insert(String(key.dropFirst("filter.".count).dropLast(".smudge".count)))
        }
        guard !drivers.isEmpty else { return }
        let names = try CheckpointFiles.names(await restoreOutput(["ls-tree", "-r", "--name-only", "-z", target.commit], c,
            shadow: shadow, cwd: shadow, staging: staging, deadline: deadline))
        var chunk = [String](), count = 0
        func check(_ paths: [String]) async throws {
            guard !paths.isEmpty else { return }
            let bytes = try await restoreOutput(["check-attr", "--source=" + target.commit, "-z", "filter", "--"] + paths, c,
                shadow: shadow, cwd: shadow, staging: staging, deadline: deadline)
            let fields = bytes.split(separator: 0, omittingEmptySubsequences: false)
            guard bytes.last == 0, fields.count == paths.count * 3 + 1 else { throw GitCheckpointRestoreError(.unsupportedConfiguration) }
            for i in paths.indices {
                guard String(data: fields[i * 3], encoding: .utf8) == paths[i], String(data: fields[i * 3 + 1], encoding: .utf8) == "filter",
                      let driver = String(data: fields[i * 3 + 2], encoding: .utf8), !drivers.contains(driver.lowercased()) else { throw GitCheckpointRestoreError(.unsupportedConfiguration) }
            }
        }
        let scope = restoreScope(target.plan)
        for path in names where scope.isEmpty || path.hasPrefix(scope + "/") {
            try CheckpointFiles.relative(path)
            if chunk.count == 512 || count + path.utf8.count > 65_536 { try await check(chunk); chunk = []; count = 0 }
            chunk.append(path); count += path.utf8.count
        }
        try await check(chunk)
    }
    private func restoreTranslated<T: Sendable>(_ operation: @Sendable () async throws -> T) async throws -> T {
        do { return try await operation() }
        catch is CancellationError { throw CancellationError() }
        catch let error as GitCheckpointRestoreError { throw error }
        catch let error as GitCheckpointError {
            let kind: GitCheckpointRestoreError.Kind
            switch error.kind {
            case .ownershipLost: kind = .ownershipLost
            case .configurationChanged: kind = .staleReview
            case .unsupportedConfiguration: kind = .unsupportedConfiguration
            case .timedOut: kind = .timedOut
            case .outputLimit: kind = .outputLimit
            case .metadataInvalid, .refCollision, .incomplete: kind = .metadataInvalid
            default: kind = .commandFailed
            }
            throw GitCheckpointRestoreError(kind)
        }
        catch let error as GitWorktreeError {
            let kind: GitCheckpointRestoreError.Kind
            switch error.failure {
            case .timedOut: kind = .timedOut
            case .outputLimit: kind = .outputLimit
            case .ownershipLost: kind = .ownershipLost
            case .metadataCorrupt, .destinationExists: kind = .metadataInvalid
            default: kind = .commandFailed
            }
            throw GitCheckpointRestoreError(kind)
        }
        catch { try Task.checkCancellation(); throw GitCheckpointRestoreError(.commandFailed) }
    }
}

// The real index is never passed to Git. Only this owned lock may be promoted,
// after all working changes and final HEAD/index/identity proofs succeed.
private final class RestoreIndexLock {
    let admin: GitWorktreeDirectory
    let identity: GitWorktreeNodeIdentity
    var published = false
    init(admin: GitWorktreeDirectory, bytes: Data) throws {
        self.admin = admin
        try CheckpointFiles.claimIndex(bytes, name: "index.lock", admin: admin)
        guard let proof = try CheckpointFiles.index(admin, name: "index.lock") else { throw GitCheckpointRestoreError(.ownershipLost) }
        identity = proof.identity
    }
    func publish(expected: GitCheckpointIndexRevision?, metadata: GitWorktreeDirectory, publishesIndex: Bool) throws {
        try admin.validate(); try metadata.validate()
        guard let proof = try CheckpointFiles.index(admin, name: "index.lock"), proof.identity == identity else { throw GitCheckpointRestoreError(.ownershipLost) }
        if !publishesIndex {
            guard expected == nil, try !admin.exists("index"), unlinkat(admin.fd, "index.lock", 0) == 0 else { throw GitCheckpointRestoreError(.staleReview) }
            published = true
            guard fsync(admin.fd) == 0 else { throw GitCheckpointRestoreError(.ownershipLost) }
            return
        }
        if let expected {
            // Preserve even an external index replacement that races the final read.
            guard renameatx_np(admin.fd, "index", metadata.fd, "original.index", UInt32(RENAME_EXCL)) == 0,
                  try CheckpointFiles.index(metadata, name: "original.index") == expected else { throw GitCheckpointRestoreError(.staleReview) }
            guard fsync(admin.fd) == 0, fsync(metadata.fd) == 0 else { throw GitCheckpointRestoreError(.ownershipLost) }
        }
        guard renameatx_np(admin.fd, "index.lock", admin.fd, "index", UInt32(RENAME_EXCL)) == 0 else { throw GitCheckpointRestoreError(.ownershipLost) }
        published = true
        guard fsync(admin.fd) == 0 else { throw GitCheckpointRestoreError(.ownershipLost) }
    }
    deinit {
        guard !published else { return }
        var node = stat()
        if fstatat(admin.fd, "index.lock", &node, AT_SYMLINK_NOFOLLOW) == 0, worktreeIdentity(node) == identity { _ = unlinkat(admin.fd, "index.lock", 0) }
    }
}
