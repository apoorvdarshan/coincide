import Foundation
import CryptoKit
import CSQLite
import Darwin

private final class DatabaseHandle: @unchecked Sendable {
    let value: OpaquePointer
    init(_ value: OpaquePointer) { self.value = value }
    deinit { sqlite3_close(value) }
}

/// Commits the replayable journal, projection, receipt, and audit marker atomically.
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
        guard versionStatus == SQLITE_ROW, (0...1).contains(storageVersion) else { throw CoincideError("This workspace needs a newer version of Coincide.") }
        let setup = """
        PRAGMA journal_mode=WAL;
        PRAGMA synchronous=FULL;
        CREATE TABLE IF NOT EXISTS workspace (id INTEGER PRIMARY KEY CHECK(id=1), payload BLOB NOT NULL);
        CREATE TABLE IF NOT EXISTS events (sequence INTEGER PRIMARY KEY AUTOINCREMENT, kind TEXT NOT NULL, created_at REAL NOT NULL);
        CREATE TABLE IF NOT EXISTS workspace_journal (sequence INTEGER PRIMARY KEY, payload BLOB NOT NULL);
        CREATE TABLE IF NOT EXISTS workspace_projection (id INTEGER PRIMARY KEY CHECK(id=1), sequence INTEGER NOT NULL);
        CREATE TABLE IF NOT EXISTS workspace_receipts (id TEXT PRIMARY KEY, fingerprint BLOB NOT NULL, payload BLOB NOT NULL);
        PRAGMA user_version=1;
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
                       expectedSequence: Int64? = nil) throws -> WorkspaceCommandReceipt {
        try WorkspaceJournal.validate(snapshot)
        struct FingerprintInput: Encodable { let snapshot: WorkspaceSnapshot; let event: String }
        let fingerprint = Data(SHA256.hash(data: try encoder.encode(FingerprintInput(snapshot: snapshot, event: event))))
        try bootstrap(); try execute("BEGIN IMMEDIATE")
        do {
            if let stored = try existingReceipt(commandID) {
                guard stored.fingerprint == fingerprint else { throw CoincideError("This command ID was already used for different workspace changes.") }
                try execute("COMMIT"); return stored.receipt
            }
            let before = try currentRevision()
            if let expectedSequence, expectedSequence != before.sequence { throw CoincideError("The workspace changed. Reload it before retrying this command.") }
            let changes = try WorkspaceJournal.changes(from: before.snapshot, to: snapshot)
            var sequence = before.sequence
            for change in changes {
                sequence += 1
                try insert(.init(sequence: sequence, commandID: commandID, event: change))
            }
            let receipt = WorkspaceCommandReceipt(commandID: commandID, sequence: sequence, eventCount: changes.count, acceptedAt: Date())
            try writeProjection(snapshot, through: sequence)
            try insertReceipt(receipt, fingerprint: fingerprint)
            try audit(event)
            try execute("COMMIT")
            cached = WorkspaceRevision(snapshot: snapshot, sequence: sequence)
            return receipt
        } catch { try? execute("ROLLBACK"); throw error }
    }

    public func receipt(_ id: UUID) throws -> WorkspaceCommandReceipt? { try existingReceipt(id)?.receipt }

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
