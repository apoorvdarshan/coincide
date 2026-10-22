import Foundation
import CryptoKit
import CSQLite
import Darwin

private final class DatabaseHandle: @unchecked Sendable {
    let value: OpaquePointer
    init(_ value: OpaquePointer) { self.value = value }
    deinit { sqlite3_close(value) }
}

struct WorkspaceCommitOutcome: Sendable {
    var receipt: WorkspaceCommandReceipt
    /// Original rows before pending actions were cancelled. Running rows keep their leases.
    var removedEffects: [WorkspaceEffect]
}

/// Commits the journal, projection, receipt, pending effects, and audit marker atomically.
public actor WorkspaceDatabase {
    private let handle: DatabaseHandle
    private var db: OpaquePointer { handle.value }
    private var bootstrapped = false
    private var cached: WorkspaceRevision?
    private let encoder: JSONEncoder = { let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]; return encoder }()
    public init(url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true,
                                               attributes: [.posixPermissions: 0o700])
        let created = Darwin.open(url.path, O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC, mode_t(0o600))
        if created >= 0 { Darwin.close(created) }
        else if errno != EEXIST { throw CoincideError("Could not create the private workspace database.") }
        // Apply this before SQLite creates WAL/SHM files, whose modes inherit the database's.
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        var connection: OpaquePointer?
        guard sqlite3_open_v2(url.path, &connection, SQLITE_OPEN_CREATE | SQLITE_OPEN_READWRITE | SQLITE_OPEN_FULLMUTEX, nil) == SQLITE_OK else {
            if let connection { sqlite3_close(connection) }
            throw CoincideError("Could not open the workspace database.")
        }
        handle = DatabaseHandle(connection!)
        sqlite3_busy_timeout(connection, 5_000)
        var version: OpaquePointer?
        guard sqlite3_prepare_v2(connection, "PRAGMA user_version", -1, &version, nil) == SQLITE_OK else {
            throw CoincideError("Could not read the workspace storage version.")
        }
        let versionStatus = sqlite3_step(version)
        let storageVersion = sqlite3_column_int(version, 0)
        sqlite3_finalize(version)
        guard versionStatus == SQLITE_ROW, (0...30).contains(storageVersion) else { throw CoincideError("This workspace needs a newer version of Coincide.") }
        let setup = """
        PRAGMA journal_mode=WAL;
        PRAGMA synchronous=FULL;
        CREATE TABLE IF NOT EXISTS workspace (id INTEGER PRIMARY KEY CHECK(id=1), payload BLOB NOT NULL);
        CREATE TABLE IF NOT EXISTS events (sequence INTEGER PRIMARY KEY AUTOINCREMENT, kind TEXT NOT NULL, created_at REAL NOT NULL);
        CREATE TABLE IF NOT EXISTS workspace_journal (sequence INTEGER PRIMARY KEY, payload BLOB NOT NULL);
        CREATE TABLE IF NOT EXISTS workspace_projection (id INTEGER PRIMARY KEY CHECK(id=1), sequence INTEGER NOT NULL);
        CREATE TABLE IF NOT EXISTS workspace_receipts (id TEXT PRIMARY KEY, fingerprint BLOB NOT NULL, payload BLOB NOT NULL);
        CREATE TABLE IF NOT EXISTS workspace_effects (sequence INTEGER PRIMARY KEY AUTOINCREMENT, id TEXT NOT NULL UNIQUE, command_id TEXT NOT NULL, thread_id TEXT NOT NULL, status TEXT NOT NULL, payload BLOB NOT NULL);
        CREATE INDEX IF NOT EXISTS workspace_effects_pending ON workspace_effects(status,sequence);
        PRAGMA user_version=30;
        """
        guard sqlite3_exec(connection, setup, nil, nil, nil) == SQLITE_OK else { throw CoincideError("Could not initialize the workspace database.") }
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        for suffix in ["-wal", "-shm"] where FileManager.default.fileExists(atPath: url.path + suffix) {
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path + suffix)
        }
    }

    public func load() throws -> WorkspaceSnapshot { try revision().snapshot }
    public func revision() throws -> WorkspaceRevision {
        try bootstrap()
        try execute("BEGIN")
        do {
            let value = try currentRevision(); try execute("COMMIT"); return value
        } catch { try? execute("ROLLBACK"); throw error }
    }
    public func save(_ snapshot: WorkspaceSnapshot, event: String) throws {
        _ = try commit(snapshot, event: event, commandID: UUID())
    }

    /// Retries of one command ID return the original receipt. Reusing it for a
    /// different payload or committing a stale explicit revision fails closed.
    public func commit(_ snapshot: WorkspaceSnapshot, event: String, commandID: UUID,
                       expectedSequence: Int64? = nil, effects: [PendingWorkspaceEffect] = [],
                       deduplicationPayload: Data? = nil) throws -> WorkspaceCommandReceipt {
        try commitWithRemovedEffects(snapshot, event: event, commandID: commandID, expectedSequence: expectedSequence,
                                     effects: effects, deduplicationPayload: deduplicationPayload).receipt
    }
    func commitWithRemovedEffects(_ snapshot: WorkspaceSnapshot, event: String, commandID: UUID,
                                  expectedSequence: Int64? = nil, effects: [PendingWorkspaceEffect] = [],
                                  deduplicationPayload: Data? = nil) throws -> WorkspaceCommitOutcome {
        try WorkspaceJournal.validate(snapshot)
        struct FingerprintInput: Encodable { let snapshot: WorkspaceSnapshot; let event: String }
        struct EffectFingerprintInput: Encodable { let snapshot: WorkspaceSnapshot; let event: String; let effects: [PendingWorkspaceEffect] }
        let fingerprint: Data
        if let deduplicationPayload { fingerprint = commandFingerprint(deduplicationPayload) }
        else if effects.isEmpty { fingerprint = Data(SHA256.hash(data: try encoder.encode(FingerprintInput(snapshot: snapshot, event: event)))) }
        else { fingerprint = Data(SHA256.hash(data: try encoder.encode(EffectFingerprintInput(snapshot: snapshot, event: event, effects: effects)))) }
        guard Set(effects.map(\.id)).count == effects.count,
              effects.allSatisfy({ effect in
                  if case .promptSteering(let threadID, let operationID) = effect.request {
                      return snapshot.promptSteering(operationID).map { $0.phase == .accepted && $0.threadID == threadID && effect.id == $0.effectID } ?? false
                  }
                  if case .pullRequestCheckout(let id, let operationID, let effectID) = effect.request {
                      return snapshot.pullRequestCheckout(operationID).map { $0.phase == .accepted && $0.review.projectID == id && $0.effectID == effectID && effect.id == effectID } ?? false
                  }
                  if case .pullRequestCreation(let id, let operationID, let effectID) = effect.request {
                      return snapshot.pullRequestCreation(operationID).map { $0.phase == .accepted && $0.projectID == id && $0.effectID == effectID && effect.id == effectID } ?? false
                  }
                  if case .conversationHistory(let id, let operationID) = effect.request {
                      return snapshot.conversationHistoryOperation(operationID).map { $0.phase == .accepted && $0.review.sourceThreadID == id && effect.id == operationID } ?? false
                  }
                  if case .conversationHistoryFiles(let id, let operationID, let fileAttemptID) = effect.request {
                      return snapshot.conversationHistoryOperation(operationID).map {
                          $0.phase == .applied && $0.review.sourceThreadID == id && $0.files?.phase == .accepted &&
                          $0.files?.review.id == fileAttemptID && effect.id == fileAttemptID
                      } ?? false
                  }
                  if case .checkpointRestore(let id, let operationID) = effect.request {
                      return snapshot.checkpointRestoreOperation(operationID).map { $0.phase == .accepted && $0.review.threadID == id && effect.id == operationID } ?? false
                  }
                  if let owner = effect.request.checkpointOwner {
                      guard let id = effect.request.threadID, let thread = snapshot.threads.first(where: { $0.id == id }),
                            let attempt = thread.runCheckpoint(runID: owner.runID, stage: owner.stage), attempt.id == owner.attemptID else { return false }
                      switch effect.request {
                      case .resolveRunCheckpoint: return attempt.phase == .resolving && attempt.plan == nil
                      case .captureRunCheckpoint(_, _, _, let plan): return attempt.phase == .capturing && attempt.plan == plan
                      default: return false
                      }
                  }
                  if let owner = effect.request.projectScriptOwner, let runID = effect.request.projectScriptRunID {
                      guard let id = effect.request.threadID, let thread = snapshot.threads.first(where: { $0.id == id }),
                            let run = thread.projectScript(owner: owner), run.id == runID else { return false }
                      switch effect.request {
                      case .resolveProjectScript, .resolveThreadScript: return run.phase == .discovering
                      case .startProjectScript(_, _, let plan), .startThreadScript(_, _, let plan): return run.plan == plan && run.phase == .starting
                      default: return false
                      }
                  }
                  if case .resolveWorktree(let id, let request) = effect.request {
                      return snapshot.threads.contains { $0.id == id && $0.workspacePreparation?.request == request && $0.workspacePreparation?.isRunning == true && $0.workspacePreparation?.plan == nil }
                  }
                  if case .prepareWorktree(let id, let plan) = effect.request {
                      return snapshot.threads.contains { $0.id == id && $0.workspacePreparation?.plan == plan && $0.workspacePreparation?.phase == .preparing }
                  }
                  if let id = effect.request.threadID { return snapshot.threads.contains { $0.id == id } }
                  if case .projectClone(let id, let plan) = effect.request {
                      return snapshot.projects.contains { $0.id == id && $0.clone?.plan == plan && $0.clone?.isRunning == true } && effect.id == plan.id
                  }
                  return false
              }) else {
            throw CoincideError("Workspace effects must have unique identities and belong to an existing thread or project.")
        }
        try bootstrap(); try execute("BEGIN IMMEDIATE")
        do {
            if let stored = try existingReceipt(commandID) {
                guard stored.fingerprint == fingerprint else { throw WorkspaceCommitError.commandIDCollision }
                try execute("COMMIT"); return .init(receipt: stored.receipt, removedEffects: [])
            }
            let before = try currentRevision()
            if let expectedSequence, expectedSequence != before.sequence { throw WorkspaceCommitError.revisionChanged }
            for pending in effects {
                let check = try prepare("SELECT 1 FROM workspace_effects WHERE id=?")
                defer { sqlite3_finalize(check) }
                try bind(pending.id.uuidString, to: check, index: 1)
                let status = sqlite3_step(check)
                if status == SQLITE_ROW { throw WorkspaceCommitError.effectIDCollision }
                guard status == SQLITE_DONE else { throw CoincideError("Could not verify this operation identity.") }
            }
            let changes = try WorkspaceJournal.changes(from: before.snapshot, to: snapshot)
            var sequence = before.sequence
            for change in changes {
                sequence += 1
                try insert(.init(sequence: sequence, commandID: commandID, event: change))
            }
            let receipt = WorkspaceCommandReceipt(commandID: commandID, sequence: sequence, eventCount: changes.count, acceptedAt: Date())
            try writeProjection(snapshot, through: sequence)
            try insertReceipt(receipt, fingerprint: fingerprint)
            for pending in effects {
                try insertEffect(.init(id: pending.id, commandID: commandID, request: pending.request, status: .pending,
                                       attemptCount: 0, createdAt: receipt.acceptedAt, updatedAt: receipt.acceptedAt))
            }
            let removedEffects = try cancelPendingEffectsOfRemovedEntities(from: before.snapshot, to: snapshot, now: receipt.acceptedAt)
            try audit(event)
            try execute("COMMIT")
            cached = WorkspaceRevision(snapshot: snapshot, sequence: sequence)
            return .init(receipt: receipt, removedEffects: removedEffects)
        } catch { try? execute("ROLLBACK"); throw error }
    }

    public func receipt(_ id: UUID) throws -> WorkspaceCommandReceipt? { try existingReceipt(id)?.receipt }
    public func receipt(_ id: UUID, matching commandPayload: Data) throws -> WorkspaceCommandReceipt? {
        guard let stored = try existingReceipt(id) else { return nil }
        guard stored.fingerprint == commandFingerprint(commandPayload) else { throw WorkspaceCommitError.commandIDCollision }
        return stored.receipt
    }
    private func commandFingerprint(_ payload: Data) -> Data {
        Data(SHA256.hash(data: Data("coincide-command-v1\n".utf8) + payload))
    }
    public func rejectCommand(_ id: UUID, matching payload: Data, reason: String, expectedSequence: Int64) throws -> WorkspaceCommandReceipt {
        try bootstrap(); try execute("BEGIN IMMEDIATE")
        do {
            if let existing = try existingReceipt(id) {
                guard existing.fingerprint == commandFingerprint(payload) else { throw WorkspaceCommitError.commandIDCollision }
                try execute("COMMIT"); return existing.receipt
            }
            let current = try currentRevision()
            guard current.sequence == expectedSequence else { throw WorkspaceCommitError.revisionChanged }
            let receipt = WorkspaceCommandReceipt(commandID: id, sequence: current.sequence, eventCount: 0, acceptedAt: Date(), rejection: reason)
            try insertReceipt(receipt, fingerprint: commandFingerprint(payload)); try audit("command.rejected")
            try execute("COMMIT"); return receipt
        } catch { try? execute("ROLLBACK"); throw error }
    }

    public func journal(after sequence: Int64 = 0, limit: Int = 500) throws -> [WorkspaceJournalRecord] {
        try bootstrap()
        let statement = try prepare("SELECT sequence,payload FROM workspace_journal WHERE sequence>? ORDER BY sequence LIMIT ?")
        defer { sqlite3_finalize(statement) }
        try check(sqlite3_bind_int64(statement, 1, sequence))
        try check(sqlite3_bind_int(statement, 2, Int32(min(1_000, max(1, limit)))))
        return try readRecords(statement)
    }

    /// Rebuilds the replaceable projection solely from committed journal records.
    @discardableResult public func rebuildProjection() throws -> WorkspaceRevision {
        try bootstrap(); try execute("BEGIN IMMEDIATE")
        do {
            let value = try replay()
            try writeProjection(value.snapshot, through: value.sequence)
            try execute("COMMIT"); cached = value; return value
        } catch { try? execute("ROLLBACK"); throw error }
    }

    public func eventCount() throws -> Int { Int(try scalar("SELECT count(*) FROM events")) }
    public func journalEventCount() throws -> Int { try bootstrap(); return Int(try scalar("SELECT count(*) FROM workspace_journal")) }

    private func bootstrap() throws {
        guard !bootstrapped else { return }
        try execute("BEGIN IMMEDIATE")
        do {
            if try scalar("SELECT coalesce(max(sequence),0) FROM workspace_journal") == 0,
               try scalar("SELECT count(*) FROM workspace_projection") == 0,
               let legacy = try projectionSnapshot() {
                try WorkspaceJournal.validate(legacy)
                try insert(.init(sequence: 1, commandID: UUID(), event: .imported(legacy)))
                try writeProjection(legacy, through: 1)
            }
            try execute("COMMIT"); bootstrapped = true
        } catch { try? execute("ROLLBACK"); throw error }
    }
    private func currentRevision() throws -> WorkspaceRevision {
        let sequence = try scalar("SELECT coalesce(max(sequence),0) FROM workspace_journal")
        if let cached, cached.sequence == sequence { return cached }
        let projectedSequence = try scalar("SELECT coalesce((SELECT sequence FROM workspace_projection WHERE id=1),-1)")
        guard projectedSequence <= sequence else { throw CoincideError("The workspace journal is incomplete. Restore its complete history before opening it.") }
        if projectedSequence == sequence, let snapshot = try? projectionSnapshot() {
            let value = WorkspaceRevision(snapshot: snapshot, sequence: sequence); cached = value; return value
        }
        let value = try replay(); cached = value; return value
    }
    private func replay() throws -> WorkspaceRevision {
        let statement = try prepare("SELECT sequence,payload FROM workspace_journal ORDER BY sequence")
        defer { sqlite3_finalize(statement) }
        var value = WorkspaceRevision(snapshot: WorkspaceSnapshot(), sequence: 0)
        while true {
            let status = sqlite3_step(statement)
            if status == SQLITE_DONE { break }; try checkRow(status)
            let record = try readRecord(statement)
            guard record.sequence == value.sequence + 1 else { throw CoincideError("The workspace journal has a missing sequence.") }
            try record.event.apply(to: &value.snapshot); value.sequence = record.sequence
        }
        try WorkspaceJournal.validate(value.snapshot)
        return value
    }
    private func readRecords(_ statement: OpaquePointer) throws -> [WorkspaceJournalRecord] {
        var records: [WorkspaceJournalRecord] = []
        while true {
            let status = sqlite3_step(statement)
            if status == SQLITE_DONE { return records }; try checkRow(status)
            records.append(try readRecord(statement))
        }
    }
    private func readRecord(_ statement: OpaquePointer) throws -> WorkspaceJournalRecord {
        let record = try JSONDecoder().decode(WorkspaceJournalRecord.self, from: blob(statement, column: 1))
        guard record.version == 1, record.sequence == sqlite3_column_int64(statement, 0) else { throw CoincideError("This journal needs a newer version of Coincide or is damaged.") }
        return record
    }
    private func insert(_ record: WorkspaceJournalRecord) throws {
        let statement = try prepare("INSERT INTO workspace_journal(sequence,payload) VALUES(?,?)")
        defer { sqlite3_finalize(statement) }
        try check(sqlite3_bind_int64(statement, 1, record.sequence))
        try bind(try encoder.encode(record), to: statement, index: 2)
        try check(sqlite3_step(statement))
    }
    private func projectionSnapshot() throws -> WorkspaceSnapshot? {
        let statement = try prepare("SELECT payload FROM workspace WHERE id=1")
        defer { sqlite3_finalize(statement) }
        let status = sqlite3_step(statement)
        if status == SQLITE_DONE { return nil }; try checkRow(status)
        let value = try JSONDecoder().decode(WorkspaceSnapshot.self, from: blob(statement, column: 0))
        try WorkspaceJournal.validate(value); return value
    }
    private func writeProjection(_ snapshot: WorkspaceSnapshot, through sequence: Int64) throws {
        let statement = try prepare("INSERT INTO workspace(id,payload) VALUES(1,?) ON CONFLICT(id) DO UPDATE SET payload=excluded.payload")
        defer { sqlite3_finalize(statement) }
        try bind(try encoder.encode(snapshot), to: statement, index: 1); try check(sqlite3_step(statement))
        let checkpoint = try prepare("INSERT INTO workspace_projection(id,sequence) VALUES(1,?) ON CONFLICT(id) DO UPDATE SET sequence=excluded.sequence")
        defer { sqlite3_finalize(checkpoint) }
        try check(sqlite3_bind_int64(checkpoint, 1, sequence)); try check(sqlite3_step(checkpoint))
    }
    private func insertReceipt(_ receipt: WorkspaceCommandReceipt, fingerprint: Data) throws {
        let statement = try prepare("INSERT INTO workspace_receipts(id,fingerprint,payload) VALUES(?,?,?)")
        defer { sqlite3_finalize(statement) }
        try bind(receipt.commandID.uuidString, to: statement, index: 1)
        try bind(fingerprint, to: statement, index: 2)
        try bind(try encoder.encode(receipt), to: statement, index: 3); try check(sqlite3_step(statement))
    }
    private func existingReceipt(_ id: UUID) throws -> (fingerprint: Data, receipt: WorkspaceCommandReceipt)? {
        let statement = try prepare("SELECT fingerprint,payload FROM workspace_receipts WHERE id=?")
        defer { sqlite3_finalize(statement) }
        try bind(id.uuidString, to: statement, index: 1)
        let status = sqlite3_step(statement)
        if status == SQLITE_DONE { return nil }; try checkRow(status)
        return (try blob(statement, column: 0), try JSONDecoder().decode(WorkspaceCommandReceipt.self, from: blob(statement, column: 1)))
    }
    private func audit(_ kind: String) throws {
        let statement = try prepare("INSERT INTO events(kind,created_at) VALUES(?,?)")
        defer { sqlite3_finalize(statement) }
        try bind(kind, to: statement, index: 1)
        try check(sqlite3_bind_double(statement, 2, Date().timeIntervalSince1970)); try check(sqlite3_step(statement))
    }
    private func prepare(_ sql: String) throws -> OpaquePointer {
        var statement: OpaquePointer?
        try check(sqlite3_prepare_v2(db, sql, -1, &statement, nil)); return statement!
    }
    private func scalar(_ sql: String) throws -> Int64 {
        let statement = try prepare(sql); defer { sqlite3_finalize(statement) }
        try checkRow(sqlite3_step(statement)); return sqlite3_column_int64(statement, 0)
    }
    private func blob(_ statement: OpaquePointer, column: Int32) throws -> Data {
        guard let bytes = sqlite3_column_blob(statement, column) else { throw CoincideError("Workspace data is missing.") }
        return Data(bytes: bytes, count: Int(sqlite3_column_bytes(statement, column)))
    }
    private func bind(_ data: Data, to statement: OpaquePointer, index: Int32) throws {
        guard data.count <= Int32.max else { throw CoincideError("Workspace data exceeded the storage limit.") }
        try data.withUnsafeBytes { bytes in try check(sqlite3_bind_blob(statement, index, bytes.baseAddress, Int32(bytes.count), unsafeBitCast(-1, to: sqlite3_destructor_type.self))) }
    }
    private func bind(_ text: String, to statement: OpaquePointer, index: Int32) throws {
        try check(sqlite3_bind_text(statement, index, text, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self)))
    }
    private func execute(_ sql: String) throws { try check(sqlite3_exec(db, sql, nil, nil, nil)) }
    private func checkRow(_ code: Int32) throws {
        guard code == SQLITE_ROW else { throw CoincideError("Could not read workspace data (\(code)).") }
    }
    private func check(_ code: Int32) throws {
        guard code == SQLITE_OK || code == SQLITE_DONE else { throw CoincideError(String(cString: sqlite3_errmsg(db))) }
    }
}

extension WorkspaceDatabase {
    /// Runs inside the metadata transaction. Never revoke running leases: their owned executors
    /// must stop and settle them, including a claim that has not yet registered in memory.
    private func cancelPendingEffectsOfRemovedEntities(from previous: WorkspaceSnapshot, to next: WorkspaceSnapshot, now: Date) throws -> [WorkspaceEffect] {
        let threads = Set(previous.threads.map(\.id)).subtracting(next.threads.map(\.id))
        let projects = Set(previous.projects.map(\.id)).subtracting(next.projects.map(\.id))
        let scripts = Set(previous.threads.flatMap { old in
            let current = next.threads.first(where: { $0.id == old.id })
            return old.projectScripts.compactMap { owner, run -> UUID? in
                let updated = current?.projectScript(owner: owner)
                if updated?.id != run.id || current?.isArchived == true || (owner.role == .settle && current?.settlement?.phase == .resuming) ||
                    [.stopping, .cancelled, .interrupted, .skipped].contains(updated?.phase) { return run.id }
                return nil
            }
        })
        guard !threads.isEmpty || !projects.isEmpty || !scripts.isEmpty else { return [] }
        let statement = try prepare("SELECT payload,id,command_id,thread_id,status FROM workspace_effects WHERE status IN ('pending','running') ORDER BY sequence")
        defer { sqlite3_finalize(statement) }
        let removed = try readEffects(statement).filter { effect in
            effect.request.threadID.map { threads.contains($0) } == true || effect.request.projectID.map { projects.contains($0) } == true || effect.request.projectScriptRunID.map { scripts.contains($0) } == true
        }
        for var effect in removed where effect.status == .pending {
            effect.status = .cancelled; effect.leaseOwner = nil; effect.leaseExpiresAt = nil
            effect.updatedAt = now; effect.lastError = "The owning conversation or project was removed."
            try writeEffect(effect)
        }
        return removed
    }
    public func cancelEffect(_ id: UUID, workerID: UUID, reason: String, now: Date = Date()) throws -> Bool {
        try effectTransaction {
            guard var effect = try ownedEffect(id, workerID: workerID, now: now) else { return false }
            effect.status = .cancelled; effect.leaseOwner = nil; effect.leaseExpiresAt = nil
            effect.updatedAt = now; effect.lastError = reason; try writeEffect(effect); return true
        }
    }
    public func effects(commandID: UUID? = nil) throws -> [WorkspaceEffect] {
        let statement = try prepare("SELECT payload,id,command_id,thread_id,status FROM workspace_effects" + (commandID == nil ? "" : " WHERE command_id=?") + " ORDER BY sequence")
        defer { sqlite3_finalize(statement) }
        if let commandID { try bind(commandID.uuidString, to: statement, index: 1) }
        return try readEffects(statement)
    }

    /// A pending action can be claimed once. Expired process-bound actions are
    /// deliberately not reclaimed: their external execution may already have begun.
    public func claimNextEffect(workerID: UUID, leaseDuration: TimeInterval = 120, now: Date = Date(), includeProviderStarts: Bool = true) throws -> WorkspaceEffect? {
        try validateLease(leaseDuration, now: now)
        return try effectTransaction {
            let statement = try prepare("SELECT payload,id,command_id,thread_id,status FROM workspace_effects WHERE status='pending' ORDER BY sequence")
            defer { sqlite3_finalize(statement) }
            while true {
                let status = sqlite3_step(statement)
                if status == SQLITE_DONE { return nil }; try checkRow(status)
                var effect = try readEffect(statement)
                if !includeProviderStarts, case .providerStart = effect.request { continue }
                effect.status = .running; effect.attemptCount += 1; effect.leaseOwner = workerID
                effect.leaseExpiresAt = now.addingTimeInterval(leaseDuration); effect.updatedAt = now
                try writeEffect(effect)
                return effect
            }
        }
    }

    public func renewEffectLease(_ id: UUID, workerID: UUID, leaseDuration: TimeInterval = 120, now: Date = Date()) throws -> Bool {
        try validateLease(leaseDuration, now: now)
        return try effectTransaction {
            guard var effect = try ownedEffect(id, workerID: workerID, now: now) else { return false }
            effect.leaseExpiresAt = now.addingTimeInterval(leaseDuration); effect.updatedAt = now
            try writeEffect(effect); return true
        }
    }

    public func settleEffect(_ id: UUID, workerID: UUID, error: String? = nil, now: Date = Date()) throws -> Bool {
        try effectTransaction {
            guard var effect = try ownedEffect(id, workerID: workerID, now: now) else { return false }
            let snapshot = try currentRevision().snapshot
            let ownerExists = effect.request.threadID.map { id in snapshot.threads.contains { $0.id == id } }
                ?? effect.request.projectID.map { id in snapshot.projects.contains { $0.id == id } } ?? false
            effect.status = ownerExists ? (error == nil ? .succeeded : .failed) : .cancelled
            effect.leaseOwner = nil; effect.leaseExpiresAt = nil; effect.updatedAt = now
            effect.lastError = ownerExists ? error : "The owning conversation or project was removed."
            try writeEffect(effect); return true
        }
    }

    /// Called only after runtime loss, before admitting new provider work.
    /// Queued user messages are separate domain state and are not deleted here.
    public func cancelEffectsAfterProcessLoss(reason: String = "The provider runtime was lost.", now: Date = Date()) throws -> [UUID] {
        try effectTransaction {
            let statement = try prepare("SELECT payload,id,command_id,thread_id,status FROM workspace_effects WHERE status IN ('pending','running') ORDER BY sequence")
            defer { sqlite3_finalize(statement) }
            let effects = try readEffects(statement)
            for var effect in effects {
                effect.status = .cancelled; effect.leaseOwner = nil; effect.leaseExpiresAt = nil
                effect.updatedAt = now; effect.lastError = reason
                try writeEffect(effect)
            }
            return effects.map(\.id)
        }
    }

    private func insertEffect(_ effect: WorkspaceEffect) throws {
        let statement = try prepare("INSERT INTO workspace_effects(id,command_id,thread_id,status,payload) VALUES(?,?,?,?,?)")
        defer { sqlite3_finalize(statement) }
        try bind(effect.id.uuidString, to: statement, index: 1)
        try bind(effect.commandID.uuidString, to: statement, index: 2)
        // Legacy column name; storage version 7 also indexes project-owned actions here.
        try bind(effect.request.targetID.uuidString, to: statement, index: 3)
        try bind(effect.status.rawValue, to: statement, index: 4)
        try bind(try encoder.encode(effect), to: statement, index: 5)
        try check(sqlite3_step(statement))
    }
    private func writeEffect(_ effect: WorkspaceEffect) throws {
        let statement = try prepare("UPDATE workspace_effects SET status=?,payload=? WHERE id=?")
        defer { sqlite3_finalize(statement) }
        try bind(effect.status.rawValue, to: statement, index: 1)
        try bind(try encoder.encode(effect), to: statement, index: 2)
        try bind(effect.id.uuidString, to: statement, index: 3)
        try check(sqlite3_step(statement))
        guard sqlite3_changes(db) == 1 else { throw CoincideError("The workspace effect no longer exists.") }
    }
    private func ownedEffect(_ id: UUID, workerID: UUID, now: Date) throws -> WorkspaceEffect? {
        let statement = try prepare("SELECT payload,id,command_id,thread_id,status FROM workspace_effects WHERE id=?")
        defer { sqlite3_finalize(statement) }
        try bind(id.uuidString, to: statement, index: 1)
        let status = sqlite3_step(statement)
        if status == SQLITE_DONE { return nil }; try checkRow(status)
        let effect = try readEffect(statement)
        guard effect.status == .running, effect.leaseOwner == workerID, let expires = effect.leaseExpiresAt, expires > now else { return nil }
        return effect
    }
    private func readEffects(_ statement: OpaquePointer) throws -> [WorkspaceEffect] {
        var values: [WorkspaceEffect] = []
        while true {
            let status = sqlite3_step(statement)
            if status == SQLITE_DONE { return values }; try checkRow(status)
            values.append(try readEffect(statement))
        }
    }
    private func readEffect(_ statement: OpaquePointer) throws -> WorkspaceEffect {
        let effect = try JSONDecoder().decode(WorkspaceEffect.self, from: blob(statement, column: 0))
        let expected = [effect.id.uuidString, effect.commandID.uuidString, effect.request.targetID.uuidString, effect.status.rawValue]
        for (offset, value) in expected.enumerated() {
            guard let bytes = sqlite3_column_text(statement, Int32(offset + 1)), String(cString: bytes) == value else {
                throw CoincideError("The workspace outbox contains inconsistent data.")
            }
        }
        return effect
    }
    private func validateLease(_ duration: TimeInterval, now: Date) throws {
        guard duration.isFinite, duration > 0, now.addingTimeInterval(duration).timeIntervalSince1970.isFinite else {
            throw CoincideError("An effect lease must have a positive, finite duration.")
        }
    }
    private func effectTransaction<T>(_ operation: () throws -> T) throws -> T {
        try execute("BEGIN IMMEDIATE")
        do { let result = try operation(); try execute("COMMIT"); return result }
        catch { try? execute("ROLLBACK"); throw error }
    }
}
