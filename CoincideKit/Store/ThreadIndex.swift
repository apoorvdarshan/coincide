import Foundation

/// The size, modification time and file number of a file, which tell whether it changed since it was
/// indexed. Every save replaces a thread file atomically, so a saved file always gets a new file number.
struct FileStamp: Codable, Hashable, Sendable {
    var size: Int64
    var seconds: Int64
    var nanoseconds: Int64
    var fileNumber: UInt64

    /// The file's stamp, or nil when it does not exist.
    nonisolated init?(of url: URL) {
        var info = stat()
        guard url.withUnsafeFileSystemRepresentation({ path in path.map { stat($0, &info) == 0 } ?? false }) else {
            return nil
        }
        size = Int64(info.st_size)
        seconds = Int64(info.st_mtimespec.tv_sec)
        nanoseconds = Int64(info.st_mtimespec.tv_nsec)
        fileNumber = UInt64(info.st_ino)
    }
}

/// One thread file as indexed: its name in `threads/`, its stamp then, and the summary of what it held.
struct ThreadIndexEntry: Codable, Hashable, Sendable {
    var file: String
    var stamp: FileStamp
    var summary: ThreadSummary
}

/// `thread-index.json`: the summaries of the thread files, so launch lists every thread without decoding them.
///
/// It only caches what the thread files hold; they stay the record. An entry counts only while its file
/// still has the stamp it had when indexed, so a file changed since (a save the index missed because the app
/// quit unexpectedly, or another version writing it) is read again, and an index that is missing, unreadable
/// or of another version is rebuilt from the files. Versions that do not know the index ignore it.
struct ThreadIndexFile: Codable {
    nonisolated static let currentVersion = 3

    var version: Int
    var entries: [ThreadIndexEntry]

    nonisolated init(entries: [ThreadIndexEntry]) {
        version = Self.currentVersion
        self.entries = entries
    }

    /// Entries this version cannot read are skipped; their files are read again.
    nonisolated init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        version = try container.decode(Int.self, forKey: .version)
        entries = version == Self.currentVersion ? try container.decode(LenientList<ThreadIndexEntry>.self, forKey: .entries).elements : []
    }
}
