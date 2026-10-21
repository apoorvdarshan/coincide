import Foundation
import CSQLite

/// The actor is the only accessor; this owner closes its connection on final release.
private final class DatabaseHandle: @unchecked Sendable {
    let value: OpaquePointer
    init(_ value: OpaquePointer) { self.value = value }
    deinit { sqlite3_close(value) }
}

/// Saves the projection and its event in a single SQLite transaction.
public actor WorkspaceDatabase {
    private let handle: DatabaseHandle
    private var db: OpaquePointer { handle.value }
    public init(url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        var connection: OpaquePointer?
        guard sqlite3_open_v2(url.path, &connection, SQLITE_OPEN_CREATE | SQLITE_OPEN_READWRITE | SQLITE_OPEN_FULLMUTEX, nil) == SQLITE_OK else {
            if let connection { sqlite3_close(connection) }
            throw CoincideError("Could not open the workspace database.")
        }
        handle = DatabaseHandle(connection!)
        sqlite3_busy_timeout(connection, 5_000)
        let setup = """
        PRAGMA journal_mode=WAL;
        PRAGMA synchronous=FULL;
        CREATE TABLE IF NOT EXISTS workspace (id INTEGER PRIMARY KEY CHECK(id=1), payload BLOB NOT NULL);
        CREATE TABLE IF NOT EXISTS events (sequence INTEGER PRIMARY KEY AUTOINCREMENT, kind TEXT NOT NULL, created_at REAL NOT NULL);
        """
        guard sqlite3_exec(connection, setup, nil, nil, nil) == SQLITE_OK else {
            throw CoincideError("Could not initialize the workspace database.")
        }
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }

    public func load() throws -> WorkspaceSnapshot {
        var statement: OpaquePointer?
        try check(sqlite3_prepare_v2(db, "SELECT payload FROM workspace WHERE id=1", -1, &statement, nil))
        defer { sqlite3_finalize(statement) }
        let status = sqlite3_step(statement)
        if status == SQLITE_DONE { return WorkspaceSnapshot() }
        guard status == SQLITE_ROW, let data = sqlite3_column_blob(statement, 0) else {
            throw CoincideError("Could not read workspace data.")
        }
        let value = try JSONDecoder().decode(WorkspaceSnapshot.self,
            from: Data(bytes: data, count: Int(sqlite3_column_bytes(statement, 0))))
        guard value.schemaVersion == 1 else { throw CoincideError("This workspace needs a newer version of Coincide.") }
        return value
    }

    public func save(_ snapshot: WorkspaceSnapshot, event: String) throws {
        let data = try JSONEncoder().encode(snapshot)
        try execute("BEGIN IMMEDIATE")
        do {
            var statement: OpaquePointer?
            try check(sqlite3_prepare_v2(db, "INSERT INTO workspace(id,payload) VALUES(1,?) ON CONFLICT(id) DO UPDATE SET payload=excluded.payload", -1, &statement, nil))
            defer { sqlite3_finalize(statement) }
            try data.withUnsafeBytes { bytes in
                try check(sqlite3_bind_blob(statement, 1, bytes.baseAddress, Int32(bytes.count), unsafeBitCast(-1, to: sqlite3_destructor_type.self)))
            }
            try check(sqlite3_step(statement))
            var log: OpaquePointer?
            try check(sqlite3_prepare_v2(db, "INSERT INTO events(kind,created_at) VALUES(?,?)", -1, &log, nil))
            defer { sqlite3_finalize(log) }
            try check(sqlite3_bind_text(log, 1, event, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self)))
            try check(sqlite3_bind_double(log, 2, Date().timeIntervalSince1970))
            try check(sqlite3_step(log)); try execute("COMMIT")
        } catch { try? execute("ROLLBACK"); throw error }
    }

    public func eventCount() throws -> Int {
        var statement: OpaquePointer?
        try check(sqlite3_prepare_v2(db, "SELECT count(*) FROM events", -1, &statement, nil))
        defer { sqlite3_finalize(statement) }
        guard sqlite3_step(statement) == SQLITE_ROW else { throw CoincideError("Could not read event count.") }
        return Int(sqlite3_column_int64(statement, 0))
    }
    private func execute(_ sql: String) throws { try check(sqlite3_exec(db, sql, nil, nil, nil)) }
    private func check(_ code: Int32) throws {
        guard code == SQLITE_OK || code == SQLITE_DONE else {
            throw CoincideError(String(cString: sqlite3_errmsg(db)))
        }
    }
}
