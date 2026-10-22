import Darwin
import Foundation

/// Anchored native-file proof and explicit recovery. This service never starts
/// Pi, sends a prompt, repairs a transcript, or searches the user's sessions.
public struct PiHistoryService: Sendable {
    public let configuration: PiRuntimeConfiguration
    public let workerRootURL: URL
    private let reader: PiHistoryFileReader

    public init(configuration: PiRuntimeConfiguration, workerRootURL: URL? = nil) throws {
        try configuration.validate(); self.configuration = configuration
        let proposed = workerRootURL ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Coincide/history/pi", isDirectory: true)
        self.workerRootURL = URL(fileURLWithPath: try PiRuntimeConfiguration.physical(proposed.path, allowMissing: true))
        reader = .init()
    }

    /// The actor supplies the real live leaf. Reading a file cannot supply it.
    public func snapshot(observation: PiRuntimeEntryObservation, observedVersion: String,
                         freshIntent: PiFreshSessionIntent? = nil) throws -> PiHistorySnapshot {
        try observation.validate()
        let revision: PiHistoryFileRevision?
        if let freshIntent, try Self.isAbsent(freshIntent.nativeSessionFile) {
            try freshIntent.validate()
            guard freshIntent.runtimeIdentity == identity, freshIntent.nativeSessionFile == observation.nativeSessionFile,
                  observation.entries.isEmpty, observation.leafID == nil else { throw PiHistoryGraphError(.invalidWindow) }
            revision = nil
        } else {
            let file = try reader.read(filePath: observation.nativeSessionFile, expectedWorkspacePath: configuration.workspacePath,
                                       expectedSessionID: observation.nativeSessionID)
            guard file.graph.entries.map(PiHistoryEntryDescriptor.init) == observation.entries else { throw PiHistoryGraphError(.changed) }
            revision = try .init(file)
        }
        return try .init(reference: .init(provider: .pi, nativeThreadID: observation.nativeSessionFile), runtimeIdentity: identity,
                         observedVersion: observedVersion, fileRevision: revision, observation: observation, freshIntent: freshIntent)
    }

    /// Only the exact previously observed source is inspected. There is no
    /// switch_session, native migration, inferred leaf or directory discovery.
    public func inspectOriginal(expected: PiHistorySnapshot) throws -> PiHistorySnapshot {
        try expected.validate(); guard expected.runtimeIdentity == identity else { throw PiHistoryGraphError(.invalidWindow) }
        if expected.fileRevision == nil {
            guard let intent = expected.freshIntent, try Self.isAbsent(intent.nativeSessionFile) else { throw PiHistoryGraphError(.changed) }
        } else {
            let retained = try graph(expected: expected)
            guard retained.entries.last?.id == expected.leafID else { throw PiHistoryGraphError(.invalidWindow) }
        }
        return expected
    }

    /// A cold read can reuse an explicitly observed terminal leaf only while
    /// every native byte and entry still matches that prospective proof.
    public func readSnapshot(nativeSessionFile: String, latestRun: PiRunHistoryEvidence,
                             freshIntent: PiFreshSessionIntent? = nil) throws -> PiHistorySnapshot {
        try latestRun.validate()
        guard latestRun.runtimeIdentity == identity, latestRun.nativeSessionFile == nativeSessionFile,
              latestRun.captureStatus == .proven || latestRun.captureStatus == .noNativeChange,
              let final = latestRun.finalObservation else { throw PiHistoryGraphError(.invalidWindow) }
        let result = try snapshot(observation: final, observedVersion: latestRun.preparation.observedVersion, freshIntent: freshIntent)
        guard result.fileRevision == nil || result.entries.last?.id == final.leafID else { throw PiHistoryGraphError(.invalidWindow) }
        return result
    }

    /// Called only after the exact process is drained. Absence is explicit
    /// uncertainty acknowledgement, never proof that a prompt was not seen.
    public func inspectFresh(intent: PiFreshSessionIntent, consumer: PiRunHistoryEvidence?) throws -> PiFreshSessionInspection {
        try intent.validate()
        guard intent.runtimeIdentity == identity else { return .unavailable }
        if try Self.isAbsent(intent.nativeSessionFile) { return .unwritten }
        guard let consumer else { return .unavailable }
        do {
            try consumer.validate()
            let preparation = consumer.preparation
            guard preparation.freshIntentID == intent.id, preparation.freshEmptyObservation != nil,
                  consumer.runtimeIdentity == identity, consumer.nativeSessionFile == intent.nativeSessionFile else { return .unavailable }
            let file = try reader.read(filePath: intent.nativeSessionFile, expectedWorkspacePath: configuration.workspacePath,
                                       expectedSessionID: preparation.nativeSessionID)
            let observation = try PiRuntimeEntryObservation(nativeSessionFile: file.filePath, nativeSessionID: file.graph.header.sessionID,
                leafID: file.graph.leafID, entries: file.graph.entries.map(PiHistoryEntryDescriptor.init))
            let window = try observation.appendedWindow(since: preparation.baseline)
            let users = window.filter(\.isUser).map(\.id)
            let owners = consumer.inputs.filter { $0.kind != .compact }
            guard !users.isEmpty, users.count == owners.count else { return .unavailable }
            let entries = Dictionary(uniqueKeysWithValues: file.graph.entries.map { ($0.id, $0) })
            for (id, owner) in zip(users, owners) {
                guard owner.nativeUserEntryID == nil || owner.nativeUserEntryID == id,
                      let entry = entries[id], try PiProtocol.inputDigest(entry) == owner.inputDigest else { return .unavailable }
            }
            let revision = try PiHistoryFileRevision(file)
            guard consumer.persistedFileRevision == nil || consumer.persistedFileRevision == revision else { return .unavailable }
            return .persisted(revision)
        } catch { return .unavailable }
    }

    var identity: PiRuntimeIdentity { .init(instanceID: configuration.instanceID, executable: configuration.requestedExecutable, runtime: configuration) }

    func graph(expected: PiHistorySnapshot) throws -> PiHistoryGraph {
        try expected.validate()
        guard expected.runtimeIdentity == identity else { throw PiHistoryGraphError(.unavailable) }
        return try Self.sourceGraph(expected: expected)
    }

    static func sourceGraph(expected: PiHistorySnapshot, allowAppended: Bool = false) throws -> PiHistoryGraph {
        try expected.validate()
        guard let runtime = expected.runtimeIdentity.runtime, let revision = expected.fileRevision else { throw PiHistoryGraphError(.unavailable) }
        let file = try PiHistoryFileReader().read(filePath: expected.reference.nativeThreadID, expectedWorkspacePath: runtime.workspacePath,
                                   expectedSessionID: expected.observation.nativeSessionID)
        if allowAppended {
            guard file.device == revision.device, file.inode == revision.inode, file.byteCount >= revision.byteCount,
                  try PiHistoryValidation.digest(file.graph.header.raw) == revision.headerDigest,
                  file.graph.entries.count >= expected.entries.count,
                  Array(file.graph.entries.prefix(expected.entries.count)).map(PiHistoryEntryDescriptor.init) == expected.entries else { throw PiHistoryGraphError(.changed) }
        } else {
            guard try PiHistoryFileRevision(file) == revision,
                  file.graph.entries.map(PiHistoryEntryDescriptor.init) == expected.entries else { throw PiHistoryGraphError(.changed) }
        }
        return try .init(header: file.graph.header.raw, entries: Array(file.graph.entries.prefix(expected.entries.count)).map(\.raw), leafID: expected.leafID)
    }

    func candidateGraph(_ candidate: PiHistoryCandidate) throws -> PiHistoryGraph {
        try candidate.validate()
        guard candidate.runtimeIdentity == identity, let path = candidate.nativeSessionFile, let sessionID = candidate.nativeSessionID else {
            throw PiHistoryGraphError(.invalidWindow)
        }
        return try reader.read(filePath: path, expectedWorkspacePath: configuration.workspacePath, expectedSessionID: sessionID).graph
    }

    public func inspectCandidate(review: PiHistoryReviewEvidence, candidate: PiHistoryCandidate,
                                 configuration target: ProviderConfiguration) throws -> PiHistoryResult {
        try review.validate(); try candidate.validate()
        guard target.provider == .pi, target.piConfiguration?.runtimeIdentity == identity,
              candidate.runtimeIdentity == identity, target.workspacePath == configuration.registeredWorkspacePath,
              candidate.stage != .reserved, review.source.observedVersion == "0.80.5" else { throw PiHistoryGraphError(.invalidWindow) }
        let source = try Self.sourceGraph(expected: review.source, allowAppended: review.kind == .forkAfterRun)
        var candidates: [PiHistoryCandidate] = []
        if review.kind == .forkAfterRun {
            guard let directory = candidate.operationDirectory else { throw PiHistoryGraphError(.invalidWindow) }
            let reservation = try PiHistoryCandidate(operationID: review.operationID, stage: .reserved, runtimeIdentity: identity,
                operationDirectory: directory, expectedParentSessionPath: review.source.reference.nativeThreadID,
                sourceInventoryDigest: review.source.inventoryDigest, semanticDigest: review.semanticDigest)
            try verifyReservation(reservation); candidates.append(reservation)
            if candidate.stage == .finalBranch {
                let initialFile = try reader.read(filePath: candidate.expectedParentSessionPath, expectedWorkspacePath: configuration.workspacePath)
                let initial = try PiHistoryCandidate(operationID: review.operationID, stage: .initialClone, runtimeIdentity: identity,
                    operationDirectory: directory, nativeSessionFile: initialFile.filePath, nativeSessionID: initialFile.graph.header.sessionID,
                    expectedParentSessionPath: review.source.reference.nativeThreadID,
                    sourceInventoryDigest: review.source.inventoryDigest, semanticDigest: review.semanticDigest)
                try validateInitialClone(source: source, candidate: initial, graph: initialFile.graph); candidates.append(initial)
            }
        }
        try review.validateCandidate(candidate, previous: candidates); candidates.append(candidate)
        // A missing candidate is not proof of its old in-memory context. In
        // particular, extension custom state may never have reached disk.
        let graph = try candidateGraph(candidate)
        guard let path = candidate.nativeSessionFile else { throw PiHistoryGraphError(.invalidWindow) }
        let observation = try PiRuntimeEntryObservation(nativeSessionFile: path, nativeSessionID: graph.header.sessionID,
            leafID: graph.leafID, entries: graph.entries.map(PiHistoryEntryDescriptor.init))
        return try makeResult(review: review, candidates: candidates, observation: observation, sourceGraph: source)
    }

    func validateInitialClone(source: PiHistoryGraph, candidate: PiHistoryCandidate, graph: PiHistoryGraph) throws {
        // This staged copy proves the complete append inventory. A historical
        // cut is still selected from the reviewed LIVE branch, not this reload.
        let reloaded = try PiHistoryGraph(header: source.header.raw, entries: source.entries.map(\.raw), leafID: source.entries.last?.id)
        let transform = try PiHistoryForkTransform(source: reloaded, mode: .cliFork, retainedLeafID: reloaded.leafID)
        try transform.validate(candidate: graph, expectedWorkspacePath: configuration.workspacePath,
            expectedParentSessionPath: candidate.expectedParentSessionPath)
    }

    func makeResult(review: PiHistoryReviewEvidence, candidates: [PiHistoryCandidate], observation: PiRuntimeEntryObservation,
                    sourceGraph source: PiHistoryGraph) throws -> PiHistoryResult {
        guard let candidate = candidates.last, candidate.nativeSessionFile == observation.nativeSessionFile,
              candidate.nativeSessionID == observation.nativeSessionID,
              candidate.runtimeIdentity == identity, let selected = review.inputs.firstIndex(where: { $0.runID == review.runID }) else {
            throw PiHistoryGraphError(.invalidWindow)
        }
        let fresh: PiFreshSessionIntent?
        let mode: PiHistoryForkTransform.Mode = review.cutUserEntryID == nil ? .cliFork : (review.retainedLeafID == nil ? .fresh : .branched)
        let transform = try PiHistoryForkTransform(source: source, mode: mode, retainedLeafID: review.retainedLeafID)
        guard transform.semanticDigest == review.semanticDigest, transform.retainedEntries == review.retainedEntries else { throw PiHistoryGraphError(.invalidWindow) }
        if case .freshSession(let id) = review.boundary {
            guard observation.entries.isEmpty, observation.leafID == nil, candidate.stage == .finalBranch else { throw PiHistoryGraphError(.invalidWindow) }
            fresh = try .init(id: id, operationID: review.operationID, runtimeIdentity: identity, nativeSessionFile: observation.nativeSessionFile,
                sourceNativeSessionFile: review.source.reference.nativeThreadID, originalNativeSessionID: observation.nativeSessionID,
                sourceInventoryDigest: review.source.inventoryDigest, semanticDigest: review.semanticDigest)
        } else { fresh = nil }
        let observed = try snapshot(observation: observation, observedVersion: review.source.observedVersion, freshIntent: fresh)
        if observed.fileRevision != nil {
            let actual = try candidateGraph(candidate)
            try transform.validate(candidate: actual, expectedWorkspacePath: configuration.workspacePath,
                expectedParentSessionPath: candidate.expectedParentSessionPath)
        } else {
            guard !transform.requiresPersistedFile, transform.retainedEntries.isEmpty, fresh != nil else { throw PiHistoryGraphError(.unavailable) }
        }
        let retainedCount = review.kind == .forkAfterRun ? selected + 1 : selected
        let result = try PiHistoryResult(operationID: review.operationID, source: review.source, snapshot: observed,
            inputs: Array(review.inputs.prefix(retainedCount)), candidates: candidates, semanticDigest: review.semanticDigest)
        try review.validateResult(result); return result
    }

    func reserveFork(operationID: UUID, review: PiHistoryReviewEvidence) throws -> PiHistoryCandidate {
        try review.validate()
        guard review.operationID == operationID, review.kind == .forkAfterRun else { throw PiHistoryGraphError(.invalidWindow) }
        let root = try Self.openDirectory(workerRootURL.path, create: true, requirePrivate: true)
        defer { Darwin.close(root) }
        let name = operationID.uuidString.lowercased()
        guard mkdirat(root, name, 0o700) == 0 else { throw PiHistoryGraphError(.unavailable) }
        let directory = workerRootURL.appendingPathComponent(name, isDirectory: true).path
        let operation = openat(root, name, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard operation >= 0 else { throw PiHistoryGraphError(.unavailable) }
        defer { Darwin.close(operation) }
        let candidate = try PiHistoryCandidate(operationID: operationID, stage: .reserved, runtimeIdentity: identity,
            operationDirectory: directory, expectedParentSessionPath: review.source.reference.nativeThreadID,
            sourceInventoryDigest: review.source.inventoryDigest, semanticDigest: review.semanticDigest)
        let data = try JSONEncoder().encode(candidate)
        guard data.count <= 65_536 else { throw PiHistoryGraphError(.oversized) }
        let descriptor = openat(operation, "owner.json", O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard descriptor >= 0 else { throw PiHistoryGraphError(.unavailable) }
        defer { Darwin.close(descriptor) }
        try data.withUnsafeBytes { bytes in
            var offset = 0
            while offset < bytes.count {
                let count = Darwin.write(descriptor, bytes.baseAddress!.advanced(by: offset), bytes.count - offset)
                if count < 0, errno == EINTR { continue }
                guard count > 0 else { throw PiHistoryGraphError(.unavailable) }; offset += count
            }
        }
        guard fsync(descriptor) == 0, fsync(operation) == 0 else { throw PiHistoryGraphError(.unavailable) }
        return candidate
    }

    func verifyReservation(_ reservation: PiHistoryCandidate) throws {
        try reservation.validate()
        guard reservation.stage == .reserved, reservation.runtimeIdentity == identity,
              let directory = reservation.operationDirectory,
              directory == workerRootURL.appendingPathComponent(reservation.operationID.uuidString.lowercased(), isDirectory: true).path else {
            throw PiHistoryGraphError(.invalidWindow)
        }
        let parent = try Self.openDirectory(directory, create: false, requirePrivate: true)
        defer { Darwin.close(parent) }
        let descriptor = openat(parent, "owner.json", O_RDONLY | O_NONBLOCK | O_NOFOLLOW | O_CLOEXEC)
        guard descriptor >= 0 else { throw PiHistoryGraphError(.unavailable) }
        defer { Darwin.close(descriptor) }
        var info = stat()
        guard fstat(descriptor, &info) == 0, info.st_mode & S_IFMT == S_IFREG, info.st_uid == geteuid(), info.st_nlink == 1,
              info.st_size > 0, info.st_size <= 65_536 else { throw PiHistoryGraphError(.unavailable) }
        var data = Data(), block = [UInt8](repeating: 0, count: 4_096)
        while true {
            let count = Darwin.read(descriptor, &block, block.count)
            if count < 0, errno == EINTR { continue }
            guard count >= 0 else { throw PiHistoryGraphError(.unavailable) }
            if count == 0 { break }; data.append(contentsOf: block.prefix(count))
            guard data.count <= 65_536 else { throw PiHistoryGraphError(.oversized) }
        }
        var after = stat(), named = stat()
        guard fstat(descriptor, &after) == 0, fstatat(parent, "owner.json", &named, AT_SYMLINK_NOFOLLOW) == 0,
              PiHistoryValidation.sameFile(info, after), PiHistoryValidation.sameFile(after, named),
              try JSONDecoder().decode(PiHistoryCandidate.self, from: data) == reservation else { throw PiHistoryGraphError(.changed) }
    }

    static func isAbsent(_ path: String) throws -> Bool {
        try PiHistoryValidation.absolutePath(path)
        let parent = try openDirectory((path as NSString).deletingLastPathComponent, create: false, requirePrivate: false)
        defer { Darwin.close(parent) }
        var info = stat()
        if fstatat(parent, (path as NSString).lastPathComponent, &info, AT_SYMLINK_NOFOLLOW) == 0 { return false }
        guard errno == ENOENT else { throw PiHistoryGraphError(.unavailable) }; return true
    }

    private static func openDirectory(_ path: String, create: Bool, requirePrivate: Bool) throws -> Int32 {
        try PiHistoryValidation.absolutePath(path)
        var parent = open("/", O_RDONLY | O_DIRECTORY | O_CLOEXEC)
        guard parent >= 0 else { throw PiHistoryGraphError(.unavailable) }
        do {
            for part in path.split(separator: "/").map(String.init) {
                var next = openat(parent, part, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
                if next < 0, create, errno == ENOENT {
                    guard mkdirat(parent, part, 0o700) == 0 || errno == EEXIST else { throw PiHistoryGraphError(.unavailable) }
                    next = openat(parent, part, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
                }
                guard next >= 0 else { throw PiHistoryGraphError(.unavailable) }
                Darwin.close(parent); parent = next
            }
            var info = stat()
            guard fstat(parent, &info) == 0, info.st_mode & S_IFMT == S_IFDIR,
                  !requirePrivate || (info.st_uid == geteuid() && info.st_mode & 0o077 == 0) else { throw PiHistoryGraphError(.unavailable) }
            return parent
        } catch { Darwin.close(parent); throw error }
    }
}
