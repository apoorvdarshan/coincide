import CryptoKit
import Darwin
import Foundation
import zlib

/// Gzip + POSIX TAR/PAX, matching the canonical Codex package writer. The
/// complete inventory is validated before creating any destination members.
public enum CodexArchiveExtractor {
    // Policy limits, not independently pinned member-size metadata. The probed
    // macOS arm64 release expands to326,471,680 TAR bytes including padding.
    public static let maximumExpandedBytes: Int64 = 8 * 1_024 * 1_024 * 1_024
    static let maximumMemberBytes: Int64 = 4 * 1_024 * 1_024 * 1_024
    static let maximumEntries = 10_000

    public static func extract(release: CodexManagedRelease, archive: URL, to destination: URL) async throws {
        do { try release.validate() } catch { throw CodexArchiveError.invalidRelease }
        guard !Task.isCancelled else { throw CodexArchiveError.cancelled }
        let work = Task.detached(priority: .utility) {
            let source = try CodexArchiveInput(archive, release: release)
            try source.verify()
            let inventory = try CodexTarReader(source: source).walk()
            try source.validate(); try Task.checkCancellation()
            let tree = try CodexArchiveTree(destination)
            do {
                _ = try CodexTarReader(source: source).walk(expected: inventory) { try tree.begin($0) }
                try source.validate(); try tree.finish(); try Task.checkCancellation()
            } catch { tree.removeOwned(); throw error }
        }
        try await withTaskCancellationHandler {
            do { try await work.value } catch { throw CodexArchiveError.sanitized(error, fallback: .archiveInvalid) }
        } onCancel: { work.cancel() }
    }
}

private final class CodexArchiveInput {
    let fd: Int32
    let size: Int64
    let digest: String
    private let url: URL
    private let identity: stat
    init(_ url: URL, release: CodexManagedRelease) throws {
        guard url.isFileURL, !url.path.contains("\0") else { throw CodexArchiveError.archiveInvalid }
        self.url = url; size = release.archiveBytes; digest = release.sha256
        let opened = Darwin.open(url.path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        guard opened >= 0 else { throw CodexArchiveError.archiveInvalid }
        var node = stat()
        guard fstat(opened, &node) == 0, node.st_mode & S_IFMT == S_IFREG, node.st_size == size, node.st_nlink == 1 else {
            Darwin.close(opened); throw CodexArchiveError.archiveInvalid
        }
        fd = opened; identity = node
    }
    deinit { Darwin.close(fd) }
    func validate() throws {
        var current = stat(), named = stat()
        guard fstat(fd, &current) == 0, lstat(url.path, &named) == 0, current.st_nlink == 1,
              current.st_dev == identity.st_dev, current.st_ino == identity.st_ino, current.st_size == size,
              current.st_mtimespec.tv_sec == identity.st_mtimespec.tv_sec, current.st_mtimespec.tv_nsec == identity.st_mtimespec.tv_nsec,
              current.st_ctimespec.tv_sec == identity.st_ctimespec.tv_sec, current.st_ctimespec.tv_nsec == identity.st_ctimespec.tv_nsec,
              named.st_dev == current.st_dev, named.st_ino == current.st_ino, named.st_mode & S_IFMT == S_IFREG else { throw CodexArchiveError.archiveInvalid }
    }
    func read(_ offset: Int64, count: Int) throws -> Data {
        guard offset >= 0, offset <= size, count >= 0, count <= 65_536, Int64(count) <= size - offset else { throw CodexArchiveError.archiveInvalid }
        var result = Data(count: count)
        try result.withUnsafeMutableBytes { bytes in
            var cursor = 0
            while cursor < count {
                try Task.checkCancellation()
                let amount = pread(fd, bytes.baseAddress!.advanced(by: cursor), count - cursor, off_t(offset + Int64(cursor)))
                if amount < 0, errno == EINTR { continue }
                guard amount > 0 else { throw CodexArchiveError.archiveInvalid }; cursor += amount
            }
        }; return result
    }
    func verify() throws {
        var cursor: Int64 = 0, hash = SHA256()
        while cursor < size { let bytes = try read(cursor, count: Int(min(65_536, size - cursor))); hash.update(data: bytes); cursor += Int64(bytes.count) }
        guard hash.finalize().map({ String(format: "%02x", $0) }).joined() == digest else { throw CodexArchiveError.checksumMismatch }
        try validate()
    }
}

private final class CodexGzipReader {
    private let source: CodexArchiveInput
    private var stream = z_stream()
    private var input = Data()
    private var inputCursor = 0
    private var compressedCursor: Int64 = 0
    private var hash = SHA256()
    private var ended = false
    private(set) var decoded: Int64 = 0
    init(source: CodexArchiveInput) throws {
        self.source = source
        guard inflateInit2_(&stream, MAX_WBITS + 16, ZLIB_VERSION, Int32(MemoryLayout<z_stream>.size)) == Z_OK else { throw CodexArchiveError.archiveInvalid }
    }
    deinit { inflateEnd(&stream) }
    func read(_ maximum: Int) throws -> Data {
        guard maximum > 0, maximum <= 65_536 else { throw CodexArchiveError.archiveInvalid }
        if ended { return Data() }
        var output = Data(count: maximum), produced = 0
        try output.withUnsafeMutableBytes { target in
            while produced < maximum, !ended {
                try Task.checkCancellation()
                if inputCursor == input.count, compressedCursor < source.size {
                    input = try source.read(compressedCursor, count: Int(min(65_536, source.size - compressedCursor)))
                    compressedCursor += Int64(input.count); inputCursor = 0; hash.update(data: input)
                }
                let available = input.count - inputCursor, beforeProduced = produced
                let status: Int32 = input.withUnsafeBytes { bytes in
                    stream.next_in = available == 0 ? nil : UnsafeMutablePointer(mutating: bytes.bindMemory(to: Bytef.self).baseAddress!.advanced(by: inputCursor))
                    stream.avail_in = uInt(available)
                    stream.next_out = target.bindMemory(to: Bytef.self).baseAddress!.advanced(by: produced); stream.avail_out = uInt(maximum - produced)
                    let status = inflate(&stream, Z_NO_FLUSH)
                    inputCursor += available - Int(stream.avail_in); produced = maximum - Int(stream.avail_out)
                    stream.next_in = nil; stream.next_out = nil
                    return status
                }
                guard Int64(produced) <= CodexArchiveExtractor.maximumExpandedBytes - decoded else { throw CodexArchiveError.archiveInvalid }
                if status == Z_STREAM_END {
                    guard inputCursor == input.count, compressedCursor == source.size,
                          hash.finalize().map({ String(format: "%02x", $0) }).joined() == source.digest else { throw CodexArchiveError.archiveInvalid }
                    // Gzip header/FNAME, CRC32 and ISIZE are validated by zlib.
                    // A second gzip member or any trailing compressed bytes is
                    // outside the canonical package format and is rejected.
                    ended = true; try source.validate()
                } else {
                    guard status == Z_OK, available != input.count - inputCursor || produced > beforeProduced else { throw CodexArchiveError.archiveInvalid }
                }
            }
        }
        decoded += Int64(produced); output.count = produced; return output
    }
    func exact(_ count: Int) throws -> Data {
        guard count >= 0, count <= 65_536 else { throw CodexArchiveError.archiveInvalid }
        var result = Data(); result.reserveCapacity(count)
        while result.count < count {
            let bytes = try read(count - result.count)
            guard !bytes.isEmpty else { throw CodexArchiveError.archiveInvalid }; result.append(bytes)
        }; return result
    }
}

private struct CodexTarEntry: Equatable {
    let path: String
    let directory: Bool
    let size: Int64
    let mode: mode_t
}
private final class CodexTarReader {
    private let reader: CodexGzipReader
    init(source: CodexArchiveInput) throws { reader = try CodexGzipReader(source: source) }
    func walk(expected: [CodexTarEntry]? = nil, output: ((CodexTarEntry) throws -> PinnedArchiveOutput?)? = nil) throws -> [CodexTarEntry] {
        var result: [CodexTarEntry] = [], pending: [String: String]?, seen: [String: Bool] = [:], parents = Set<String>(), spellings: [String: String] = [:], headers = 0, total: Int64 = 0
        while true {
            let header = try reader.exact(512)
            if header.allSatisfy({ $0 == 0 }) {
                guard pending == nil, try reader.exact(512).allSatisfy({ $0 == 0 }) else { throw CodexArchiveError.archiveInvalid }
                while true { let bytes = try reader.read(65_536); if bytes.isEmpty { break }; guard bytes.allSatisfy({ $0 == 0 }) else { throw CodexArchiveError.archiveInvalid } }
                guard reader.decoded % 512 == 0, !result.isEmpty, expected == nil || result == expected else { throw CodexArchiveError.archiveInvalid }
                return result
            }
            headers += 1
            guard headers <= 2 * CodexArchiveExtractor.maximumEntries,
                  header.subdata(in: 257..<265) == Data([0x75, 0x73, 0x74, 0x61, 0x72, 0, 0x30, 0x30]) else { throw CodexArchiveError.archiveInvalid }
            let checksum = header.enumerated().reduce(0) { $0 + (148..<156 ~= $1.offset ? 32 : Int($1.element)) }
            guard try octal(header, 148..<156) == Int64(checksum), try string(header, 157..<257).isEmpty else { throw CodexArchiveError.archiveInvalid }
            let rawSize = try octal(header, 124..<136), rawMode = try octal(header, 100..<108)
            guard rawSize <= CodexArchiveExtractor.maximumMemberBytes, rawMode <= 0o777, rawMode >= 0 else { throw CodexArchiveError.archiveInvalid }
            let kind = header[156]
            if kind == 120 { // POSIX per-entry PAX, not a filesystem member.
                guard pending == nil, rawSize > 0, rawSize <= 65_536 else { throw CodexArchiveError.archiveInvalid }
                pending = try pax(reader.exact(Int(rawSize))); try padding(rawSize)
                continue
            }
            guard kind == 0 || kind == 48 || kind == 53 else { throw CodexArchiveError.archiveInvalid }
            let directory = kind == 53, prefix = try string(header, 345..<500), name = try string(header, 0..<100)
            var path = prefix.isEmpty ? name : prefix + "/" + name
            if let overridden = pending?["path"] { path = overridden }
            let size: Int64
            if let text = pending?["size"] { guard let value = Int64(text), value >= 0 else { throw CodexArchiveError.archiveInvalid }; size = value }
            else { size = rawSize }
            pending = nil
            if directory, path.hasSuffix("/") { path.removeLast() }
            try validatePath(path)
            let canonical = path.precomposedStringWithCanonicalMapping.lowercased()
            guard size >= 0, size <= CodexArchiveExtractor.maximumMemberBytes, !directory || size == 0,
                  size <= CodexArchiveExtractor.maximumExpandedBytes - total, seen[canonical] == nil,
                  spellings[canonical] == nil || spellings[canonical] == path,
                  result.count < CodexArchiveExtractor.maximumEntries else { throw CodexArchiveError.archiveInvalid }
            let components = path.split(separator: "/")
            for length in 1..<components.count {
                let parent = components.prefix(length).joined(separator: "/")
                let key = parent.precomposedStringWithCanonicalMapping.lowercased()
                guard seen[key] != false, spellings[key] == nil || spellings[key] == parent else { throw CodexArchiveError.archiveInvalid }
                parents.insert(key); spellings[key] = parent
            }
            if !directory { guard !parents.contains(canonical) else { throw CodexArchiveError.archiveInvalid } }
            seen[canonical] = directory; spellings[canonical] = path; total += size
            let entry = CodexTarEntry(path: path, directory: directory, size: size, mode: rawMode & 0o111 == 0 ? 0o644 : 0o755)
            if let expected { guard result.count < expected.count, expected[result.count] == entry else { throw CodexArchiveError.archiveInvalid } }
            result.append(entry)
            let sink = try output?(entry)
            var remaining = size
            while remaining > 0 {
                let bytes = try reader.exact(Int(min(65_536, remaining))); try sink?.write(bytes); remaining -= Int64(bytes.count)
            }
            try padding(size); try sink?.finish(mode: entry.mode)
        }
    }
    private func padding(_ size: Int64) throws {
        let count = Int((512 - size % 512) % 512)
        guard try reader.exact(count).allSatisfy({ $0 == 0 }) else { throw CodexArchiveError.archiveInvalid }
    }
    private func validatePath(_ path: String) throws {
        let parts = path.split(separator: "/", omittingEmptySubsequences: false)
        guard !path.isEmpty, path.utf8.count <= 4_096, !path.hasPrefix("/"), !path.contains("\\"), !path.contains(":"),
              !path.unicodeScalars.contains(where: { $0.value < 32 || $0.value == 127 }), parts.count <= 32,
              parts.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." && $0.utf8.count <= 255 }) else { throw CodexArchiveError.archiveInvalid }
    }
    private func string(_ data: Data, _ range: Range<Int>) throws -> String {
        let field = data.subdata(in: range), bytes = field.prefix { $0 != 0 }
        guard field.dropFirst(bytes.count).allSatisfy({ $0 == 0 }), let text = String(data: Data(bytes), encoding: .utf8) else { throw CodexArchiveError.archiveInvalid }
        return text
    }
    private func octal(_ data: Data, _ range: Range<Int>) throws -> Int64 {
        let bytes = data.subdata(in: range)
        guard bytes.allSatisfy({ $0 == 0 || $0 == 32 || (48...55).contains($0) }) else { throw CodexArchiveError.archiveInvalid }
        let text = String(decoding: bytes, as: UTF8.self).trimmingCharacters(in: CharacterSet(charactersIn: "\0 "))
        guard text.isEmpty || text.utf8.allSatisfy({ (48...55).contains($0) }), let value = Int64(text.isEmpty ? "0" : text, radix: 8) else { throw CodexArchiveError.archiveInvalid }
        return value
    }
    private func pax(_ data: Data) throws -> [String: String] {
        var result: [String: String] = [:], cursor = 0
        let supported: Set<String> = ["path", "size", "mtime", "atime", "ctime", "uid", "gid", "uname", "gname"]
        while cursor < data.count {
            guard let space = data[cursor...].firstIndex(of: 32), space - cursor <= 8, space > cursor,
                  data[cursor..<space].allSatisfy({ (48...57).contains($0) }),
                  let length = Int(String(decoding: data[cursor..<space], as: UTF8.self)), length > space - cursor + 2, length <= data.count - cursor else { throw CodexArchiveError.archiveInvalid }
            let record = data.subdata(in: space + 1..<cursor + length)
            guard record.last == 10, let equal = record.firstIndex(of: 61), equal > 0,
                  let key = String(data: record.prefix(equal), encoding: .utf8), supported.contains(key), result[key] == nil,
                  let value = String(data: record.subdata(in: equal + 1..<record.count - 1), encoding: .utf8), value.utf8.count <= 4_096,
                  !value.contains("\0") else { throw CodexArchiveError.archiveInvalid }
            if ["size", "uid", "gid"].contains(key) {
                guard !value.isEmpty, value.utf8.allSatisfy({ (48...57).contains($0) }), let number = Int64(value), number >= 0,
                      key != "size" || number <= CodexArchiveExtractor.maximumMemberBytes else { throw CodexArchiveError.archiveInvalid }
            } else if ["mtime", "atime", "ctime"].contains(key) {
                guard value.count <= 128, let number = Double(value), number.isFinite else { throw CodexArchiveError.archiveInvalid }
            }
            result[key] = value; cursor += length
        }
        guard !result.isEmpty else { throw CodexArchiveError.archiveInvalid }; return result
    }
}

private final class CodexArchiveTree {
    private let root: PinnedArchiveDirectory
    private var directories: [String: PinnedArchiveDirectory] = [:]
    private var createdDirectories: [PinnedArchiveDirectory] = []
    private var files: [PinnedArchiveOutput] = []
    init(_ destination: URL) throws {
        root = try PinnedArchiveDirectory(destination)
        let copy = openat(root.fd, ".", O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard copy >= 0 else { throw CodexArchiveError.invalidDestination }
        guard let stream = fdopendir(copy) else { Darwin.close(copy); throw CodexArchiveError.invalidDestination }
        defer { closedir(stream) }
        while let entry = readdir(stream) {
            let name = withUnsafePointer(to: entry.pointee.d_name) { $0.withMemoryRebound(to: CChar.self, capacity: Int(MAXNAMLEN) + 1) { String(cString: $0) } }
            guard name == "." || name == ".." else { throw CodexArchiveError.invalidDestination }
        }
        directories[""] = root
    }
    func begin(_ entry: CodexTarEntry) throws -> PinnedArchiveOutput? {
        try Task.checkCancellation(); try root.validate()
        let parts = entry.path.split(separator: "/").map(String.init)
        var parent = root, path = ""
        for (index, part) in parts.enumerated() {
            if !entry.directory, index == parts.count - 1 {
                let output = try PinnedArchiveOutput(directory: parent, name: part, mode: 0o600); files.append(output); return output
            }
            path = path.isEmpty ? part : path + "/" + part
            if let existing = directories[path] { try existing.validate(); parent = existing }
            else { let child = try parent.create(part); directories[path] = child; createdDirectories.append(child); parent = child }
        }
        return nil
    }
    func finish() throws {
        for directory in createdDirectories.reversed() { try Task.checkCancellation(); try directory.finish() }
        try root.validate(); guard fsync(root.fd) == 0 else { throw CodexArchiveError.io }
    }
    func removeOwned() {
        for file in files { file.removeIfOwned() }
        for directory in createdDirectories.reversed() { directory.removeIfOwned() }
    }
}
