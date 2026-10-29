import Foundation
import SQLite3

/// A read of another app's SQLite database through a private copy: browsers keep theirs open and locked, and
/// journal recent writes in a `-wal` file beside it. The database and its journal are copied into a folder only the
/// user can read, queried there, and deleted when the snapshot closes. The browser's own files are never opened
/// for writing.
nonisolated final class SQLiteSnapshot {
    enum Failure: Error, Equatable {
        case missing
        case permissionDenied
        case unreadable
    }

    /// A column value, read out before the statement moves on.
    enum Value: Equatable {
        case null
        case integer(Int64)
        case real(Double)
        case text(String)
        case blob(Data)

        var int: Int64? {
            switch self {
            case .integer(let value): value
            case .real(let value): Int64(value)
            case .text(let value): Int64(value)
            default: nil
            }
        }
        var double: Double? {
            switch self {
            case .integer(let value): Double(value)
            case .real(let value): value
            case .text(let value): Double(value)
            default: nil
            }
        }
        var string: String? {
            switch self {
            case .text(let value): value
            case .blob(let value): String(data: value, encoding: .utf8)
            case .integer(let value): String(value)
            default: nil
            }
        }
        var data: Data? {
            switch self {
            case .blob(let value): value
            case .text(let value): Data(value.utf8)
            default: nil
            }
        }
    }

    private var database: OpaquePointer?
    let folder: URL

    init(copying source: URL) throws {
        let manager = FileManager.default
        var info = stat()
        if stat(source.path, &info) != 0 {
            throw errno == EPERM || errno == EACCES ? Failure.permissionDenied : Failure.missing
        }
        folder = manager.temporaryDirectory.appendingPathComponent("CoincideImport-" + UUID().uuidString, isDirectory: true)
        try manager.createDirectory(at: folder, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let copy = folder.appendingPathComponent("snapshot.sqlite")
        do {
            try Self.copy(source, to: copy)
            for suffix in ["-wal", "-shm"] {
                let sidecar = URL(fileURLWithPath: source.path + suffix)
                if manager.fileExists(atPath: sidecar.path) { try? Self.copy(sidecar, to: URL(fileURLWithPath: copy.path + suffix)) }
            }
        } catch let failure as Failure {
            try? manager.removeItem(at: folder)
            throw failure
        }
        // Read-write on the copy, so SQLite can fold the copied journal in; the original is untouched.
        guard sqlite3_open_v2(copy.path, &database, SQLITE_OPEN_READWRITE | SQLITE_OPEN_NOMUTEX, nil) == SQLITE_OK else {
            sqlite3_close(database)
            database = nil
            try? manager.removeItem(at: folder)
            throw Failure.unreadable
        }
        sqlite3_busy_timeout(database, 1000)
    }

    deinit { close() }

    func close() {
        if database != nil {
            sqlite3_close(database)
            database = nil
        }
        try? FileManager.default.removeItem(at: folder)
    }

    /// Copies with plain reads, so a file macOS protects (Full Disk Access) reports as such instead of failing vaguely.
    private static func copy(_ source: URL, to destination: URL) throws {
        let input = open(source.path, O_RDONLY)
        if input < 0 { throw errno == EPERM || errno == EACCES ? Failure.permissionDenied : Failure.unreadable }
        defer { Darwin.close(input) }
        let output = open(destination.path, O_WRONLY | O_CREAT | O_EXCL, 0o600)
        guard output >= 0 else { throw Failure.unreadable }
        defer { Darwin.close(output) }
        var buffer = [UInt8](repeating: 0, count: 1 << 16)
        while true {
            let count = read(input, &buffer, buffer.count)
            if count == 0 { break }
            if count < 0 { throw errno == EPERM || errno == EACCES ? Failure.permissionDenied : Failure.unreadable }
            guard write(output, buffer, count) == count else { throw Failure.unreadable }
        }
    }

    func hasTable(_ name: String) -> Bool {
        (try? rows("SELECT name FROM sqlite_master WHERE type = 'table' AND name = ?", [name]).isEmpty == false) ?? false
    }

    func columns(of table: String) -> Set<String> {
        guard table.allSatisfy({ $0.isLetter || $0.isNumber || $0 == "_" }) else { return [] }
        return Set(((try? rows("PRAGMA table_info(\(table))")) ?? []).compactMap { $0["name"]?.string })
    }

    /// Runs `query` and returns every row by column name, up to `limit` rows.
    func rows(_ query: String, _ bindings: [String] = [], limit: Int = 200_000) throws -> [[String: Value]] {
        guard let database else { throw Failure.unreadable }
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, query, -1, &statement, nil) == SQLITE_OK else { throw Failure.unreadable }
        defer { sqlite3_finalize(statement) }
        let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
        for (position, binding) in bindings.enumerated() {
            sqlite3_bind_text(statement, Int32(position + 1), binding, -1, transient)
        }
        var result: [[String: Value]] = []
        let count = sqlite3_column_count(statement)
        while result.count < limit {
            let step = sqlite3_step(statement)
            if step == SQLITE_DONE { break }
            guard step == SQLITE_ROW else { throw Failure.unreadable }
            var row: [String: Value] = [:]
            for column in 0..<count {
                let name = String(cString: sqlite3_column_name(statement, column))
                switch sqlite3_column_type(statement, column) {
                case SQLITE_INTEGER: row[name] = .integer(sqlite3_column_int64(statement, column))
                case SQLITE_FLOAT: row[name] = .real(sqlite3_column_double(statement, column))
                case SQLITE_TEXT: row[name] = .text(String(cString: sqlite3_column_text(statement, column)))
                case SQLITE_BLOB:
                    let length = Int(sqlite3_column_bytes(statement, column))
                    if let bytes = sqlite3_column_blob(statement, column), length > 0 {
                        row[name] = .blob(Data(bytes: bytes, count: length))
                    } else {
                        row[name] = .blob(Data())
                    }
                default: row[name] = .null
                }
            }
            result.append(row)
        }
        return result
    }
}
