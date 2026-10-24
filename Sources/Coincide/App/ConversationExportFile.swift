import Foundation
import CoincideCore
import Darwin

enum ConversationExportFile {
    /// CLI exports create a private new file and never replace an existing path.
    static func writeNew(_ data: Data, to url: URL) throws {
        let fd = open(url.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard fd >= 0 else { throw CoincideError("Cannot create the export. Choose a new file in an existing writable folder.") }
        var complete = false
        defer {
            Darwin.close(fd)
            if !complete { unlink(url.path) }
        }
        try data.withUnsafeBytes { bytes in
            var offset = 0
            while offset < bytes.count {
                let count = Darwin.write(fd, bytes.baseAddress!.advanced(by: offset), bytes.count - offset)
                if count < 0 && errno == EINTR { continue }
                guard count > 0 else { throw CoincideError("The export could not be written.") }
                offset += count
            }
        }
        guard fsync(fd) == 0 else { throw CoincideError("The export could not be saved.") }
        complete = true
    }
}
