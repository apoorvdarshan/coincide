import CryptoKit
import Darwin
import Foundation
import zlib

/// Strict two-member ZIP reader. Layout follows PKWARE APPNOTE6.3.10 sections
///4.3/4.5.3; ZIP64 sizes and streamed data descriptors are validated, not guessed.
public enum AntigravityArchiveExtractor {
    public static func extract(release: AntigravityManagedRelease, archive: URL, to destination: URL) async throws {
        do { try release.validate() } catch { throw AntigravityArchiveError.invalidRelease }
        guard !Task.isCancelled else { throw AntigravityArchiveError.cancelled }
        let work = Task.detached(priority: .utility) { try extractOwned(release: release, archive: archive, destination: destination) }
        try await withTaskCancellationHandler {
            do { try await work.value } catch {
                if let error = error as? PinnedArchiveError, let mapped = AntigravityArchiveError(rawValue: error.rawValue) { throw mapped }
                throw error is CancellationError ? AntigravityArchiveError.cancelled : error as? AntigravityArchiveError ?? .archiveInvalid
            }
        } onCancel: { work.cancel() }
    }
    private static func extractOwned(release: AntigravityManagedRelease, archive: URL, destination: URL) throws {
        let source = try AntigravityZIPSource(archive, expected: release.archiveBytes)
        try source.verify(sha256: release.sha256)
        let entries = try source.entries(release: release)
        let directory = try PinnedArchiveDirectory(destination)
        try requireEmpty(directory)
        var outputs: [PinnedArchiveOutput] = []
        do {
            for entry in entries {
                try Task.checkCancellation()
                let output = try PinnedArchiveOutput(directory: directory, name: entry.name, mode: 0o700)
                outputs.append(output)
                try source.extract(entry, output: output)
                try output.finish(mode: release.platform == "win32" ? 0o700 : 0o755)
            }
            try source.validate(); try directory.validate(); try Task.checkCancellation()
        } catch {
            for output in outputs { output.removeIfOwned() }
            throw error
        }
    }
    private static func requireEmpty(_ directory: PinnedArchiveDirectory) throws {
        try directory.validate()
        let copy = dup(directory.fd)
        guard copy >= 0 else { throw AntigravityArchiveError.io }
        guard let stream = fdopendir(copy) else { Darwin.close(copy); throw AntigravityArchiveError.io }
        defer { closedir(stream) }
        while let entry = readdir(stream) {
            let name = withUnsafePointer(to: &entry.pointee.d_name) { pointer in
                pointer.withMemoryRebound(to: CChar.self, capacity: MemoryLayout.size(ofValue: entry.pointee.d_name)) { String(cString: $0) }
            }
            guard name == "." || name == ".." else { throw AntigravityArchiveError.invalidDestination }
        }
    }
}

private struct AntigravityZIPEntry {
    let name: String
    let flags: UInt16
    let method: UInt16
    let crc: UInt32
    let compressed: Int64
    let uncompressed: Int64
    let localOffset: Int64
    let time: UInt32
    let zip64: Bool
    var dataOffset: Int64 = 0
}
private final class AntigravityZIPSource {
    let fd: Int32
    let url: URL
    let size: Int64
    private let original: stat
    init(_ url: URL, expected: Int64) throws {
        guard url.isFileURL, !url.path.contains("\0") else { throw AntigravityArchiveError.archiveInvalid }
        self.url = url; size = expected
        let opened = Darwin.open(url.path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        guard opened >= 0 else { throw AntigravityArchiveError.archiveInvalid }
        var node = stat()
        guard fstat(opened, &node) == 0, node.st_mode & S_IFMT == S_IFREG, node.st_size == expected, node.st_nlink == 1 else { Darwin.close(opened); throw AntigravityArchiveError.archiveInvalid }
        fd = opened; original = node
    }
    deinit { Darwin.close(fd) }
    func validate() throws {
        var opened = stat(), named = stat()
        guard fstat(fd, &opened) == 0, lstat(url.path, &named) == 0,
              opened.st_dev == original.st_dev, opened.st_ino == original.st_ino, opened.st_size == size,
              opened.st_mtimespec.tv_sec == original.st_mtimespec.tv_sec, opened.st_mtimespec.tv_nsec == original.st_mtimespec.tv_nsec,
              named.st_dev == opened.st_dev, named.st_ino == opened.st_ino, named.st_mode & S_IFMT == S_IFREG else { throw AntigravityArchiveError.archiveInvalid }
    }
    func read(_ offset: Int64, _ count: Int) throws -> Data {
        guard offset >= 0, offset <= size, count >= 0, Int64(count) <= size - offset else { throw AntigravityArchiveError.archiveInvalid }
        var data = Data(count: count)
        try data.withUnsafeMutableBytes { bytes in
            var cursor = 0
            while cursor < count {
                try Task.checkCancellation()
                let amount = pread(fd, bytes.baseAddress!.advanced(by: cursor), count - cursor, off_t(offset + Int64(cursor)))
                if amount < 0, errno == EINTR { continue }
                guard amount > 0 else { throw AntigravityArchiveError.archiveInvalid }; cursor += amount
            }
        }; return data
    }
    func verify(sha256: String) throws {
        var hash = SHA256(), cursor: Int64 = 0
        while cursor < size {
            let chunk = try read(cursor, Int(min(65_536, size - cursor))); cursor += Int64(chunk.count); hash.update(data: chunk)
        }
        guard hash.finalize().map({ String(format: "%02x", $0) }).joined() == sha256 else { throw AntigravityArchiveError.checksumMismatch }
        try validate()
    }
    func entries(release: AntigravityManagedRelease) throws -> [AntigravityZIPEntry] {
        guard size >= 22 else { throw AntigravityArchiveError.archiveInvalid }
        let tailOffset = max(0, size - 65_557), tail = try read(tailOffset, Int(size - tailOffset))
        var end: Int?
        for index in stride(from: tail.count - 22, through: 0, by: -1) {
            if try tail.u32(index) == 0x06054b50, index + 22 + Int(try tail.u16(index + 20)) == tail.count { end = index; break }
        }
        guard let end else { throw AntigravityArchiveError.archiveInvalid }
        let endOffset = tailOffset + Int64(end)
        guard try tail.u16(end + 4) == 0, try tail.u16(end + 6) == 0 else { throw AntigravityArchiveError.archiveInvalid }
        let diskEntries = try tail.u16(end + 8), totalEntries = try tail.u16(end + 10)
        let rawSize = try tail.u32(end + 12), rawOffset = try tail.u32(end + 16)
        var centralSize = Int64(rawSize), centralOffset = Int64(rawOffset), centralEnd = endOffset
        let locator = endOffset >= 20 ? try read(endOffset - 20, 20) : Data()
        if locator.count == 20, try locator.u32(0) == 0x07064b50 {
            guard try locator.u32(4) == 0, try locator.u32(16) == 1 else { throw AntigravityArchiveError.archiveInvalid }
            let recordOffset = try locator.i64(8), fixed = try read(recordOffset, 56)
            let recordSize = try fixed.i64(4)
            guard try fixed.u32(0) == 0x06064b50, (44...4_096).contains(recordSize), recordOffset <= endOffset - 20,
                  recordSize + 12 == endOffset - 20 - recordOffset, try fixed.u16(14) <= 45,
                  try fixed.u32(16) == 0, try fixed.u32(20) == 0, try fixed.i64(24) == 2, try fixed.i64(32) == 2 else { throw AntigravityArchiveError.archiveInvalid }
            if recordSize > 44 { try validateExtensible(try read(recordOffset + 56, Int(recordSize - 44))) }
            centralSize = try fixed.i64(40); centralOffset = try fixed.i64(48); centralEnd = recordOffset
            guard (diskEntries == 0xffff || diskEntries == 2), (totalEntries == 0xffff || totalEntries == 2),
                  (rawSize == 0xffffffff || Int64(rawSize) == centralSize), (rawOffset == 0xffffffff || Int64(rawOffset) == centralOffset) else { throw AntigravityArchiveError.archiveInvalid }
        } else {
            guard diskEntries == 2, totalEntries == 2, rawSize != 0xffffffff, rawOffset != 0xffffffff else { throw AntigravityArchiveError.archiveInvalid }
        }
        guard centralSize > 0, centralSize <= 524_288, centralOffset >= 0, centralOffset <= centralEnd,
              centralSize == centralEnd - centralOffset else { throw AntigravityArchiveError.archiveInvalid }
        let central = try read(centralOffset, Int(centralSize)), expected = [release.serverName: release.serverBytes, release.harnessName: release.harnessBytes]
        var result: [AntigravityZIPEntry] = [], names = Set<String>(), cursor = 0
        for _ in 0..<2 {
            guard try central.u32(cursor) == 0x02014b50, try central.u16(cursor + 6) <= 45 else { throw AntigravityArchiveError.archiveInvalid }
            let flags = try central.u16(cursor + 8), method = try central.u16(cursor + 10)
            try validateFlags(flags, method: method)
            let nameCount = Int(try central.u16(cursor + 28)), extraCount = Int(try central.u16(cursor + 30)), commentCount = Int(try central.u16(cursor + 32))
            let length = 46 + nameCount + extraCount + commentCount
            guard nameCount > 0, nameCount <= 255, length <= central.count - cursor else { throw AntigravityArchiveError.archiveInvalid }
            let nameData = central.subdata(in: cursor + 46..<cursor + 46 + nameCount)
            guard let name = String(data: nameData, encoding: .utf8), let expectedSize = expected[name], names.insert(name).inserted,
                  nameData == Data(name.utf8), !name.contains("/"), !name.contains("\\") else { throw AntigravityArchiveError.archiveInvalid }
            let attributes = try central.u32(cursor + 38), kind = (attributes >> 16) & 0o170000
            guard (kind == 0 || kind == 0o100000), attributes & 0x10 == 0 else { throw AntigravityArchiveError.archiveInvalid }
            let rawCompressed = try central.u32(cursor + 20), rawUncompressed = try central.u32(cursor + 24), rawLocal = try central.u32(cursor + 42), rawDisk = try central.u16(cursor + 34)
            let extra = try extras(central.subdata(in: cursor + 46 + nameCount..<cursor + 46 + nameCount + extraCount))
            let resolved = try zip64(extra[1], uncompressed: rawUncompressed, compressed: rawCompressed, offset: rawLocal, disk: rawDisk)
            guard resolved.uncompressed == expectedSize, resolved.compressed >= 0, resolved.compressed <= size,
                  resolved.offset >= 0, resolved.offset < centralOffset, resolved.disk == 0,
                  method != 0 || resolved.compressed == resolved.uncompressed else { throw AntigravityArchiveError.archiveInvalid }
            result.append(.init(name: name, flags: flags, method: method, crc: try central.u32(cursor + 16), compressed: resolved.compressed,
                                uncompressed: resolved.uncompressed, localOffset: resolved.offset, time: try central.u32(cursor + 12), zip64: extra[1] != nil))
            cursor += length
        }
        guard cursor == central.count else { throw AntigravityArchiveError.archiveInvalid }
        result.sort { $0.localOffset < $1.localOffset }
        guard result[0].localOffset == 0 else { throw AntigravityArchiveError.archiveInvalid }
        for index in result.indices {
            let entry = result[index], local = try read(entry.localOffset, 30)
            guard try local.u32(0) == 0x04034b50, try local.u16(4) <= 45, try local.u16(6) == entry.flags,
                  try local.u16(8) == entry.method, try local.u32(10) == entry.time else { throw AntigravityArchiveError.archiveInvalid }
            let nameCount = Int(try local.u16(26)), extraCount = Int(try local.u16(28))
            guard nameCount == entry.name.utf8.count else { throw AntigravityArchiveError.archiveInvalid }
            let fields = try read(entry.localOffset + 30, nameCount + extraCount)
            guard fields.prefix(nameCount) == Data(entry.name.utf8) else { throw AntigravityArchiveError.archiveInvalid }
            let extra = try extras(fields.subdata(in: nameCount..<fields.count))
            let resolved = try zip64(extra[1], uncompressed: local.u32(22), compressed: local.u32(18), offset: 0, disk: 0)
            let hasDescriptor = entry.flags & 8 != 0, localCRC = try local.u32(14)
            guard hasDescriptor ? (localCRC == 0 || localCRC == entry.crc) : localCRC == entry.crc,
                  hasDescriptor ? (resolved.compressed == 0 || resolved.compressed == entry.compressed) : resolved.compressed == entry.compressed,
                  hasDescriptor ? (resolved.uncompressed == 0 || resolved.uncompressed == entry.uncompressed) : resolved.uncompressed == entry.uncompressed else { throw AntigravityArchiveError.archiveInvalid }
            let dataOffset = entry.localOffset + 30 + Int64(nameCount + extraCount)
            let limit = index + 1 < result.count ? result[index + 1].localOffset : centralOffset
            guard dataOffset <= limit, entry.compressed <= limit - dataOffset else { throw AntigravityArchiveError.archiveInvalid }
            let end = dataOffset + entry.compressed
            if hasDescriptor {
                guard limit - end <= 24 else { throw AntigravityArchiveError.archiveInvalid }
                try descriptor(try read(end, Int(limit - end)), entry: entry, zip64: entry.zip64 || extra[1] != nil)
            }
            else { guard end == limit else { throw AntigravityArchiveError.archiveInvalid } }
            result[index].dataOffset = dataOffset
        }
        return result
    }
    func extract(_ entry: AntigravityZIPEntry, output: PinnedArchiveOutput) throws {
        var consumed: Int64 = 0, written: Int64 = 0, checksum = crc32(0, nil, 0)
        func emit(_ bytes: UnsafeRawBufferPointer, count: Int) throws {
            try Task.checkCancellation()
            guard Int64(count) <= entry.uncompressed - written else { throw AntigravityArchiveError.archiveInvalid }
            if count > 0 {
                checksum = crc32(checksum, bytes.bindMemory(to: Bytef.self).baseAddress, uInt(count))
                try output.write(Data(bytes: bytes.baseAddress!, count: count)); written += Int64(count)
            }
        }
        if entry.method == 0 {
            while consumed < entry.compressed {
                let bytes = try read(entry.dataOffset + consumed, Int(min(65_536, entry.compressed - consumed)))
                try bytes.withUnsafeBytes { try emit($0, count: $0.count) }; consumed += Int64(bytes.count)
            }
        } else {
            var stream = z_stream()
            guard inflateInit2_(&stream, -MAX_WBITS, ZLIB_VERSION, Int32(MemoryLayout<z_stream>.size)) == Z_OK else { throw AntigravityArchiveError.archiveInvalid }
            defer { inflateEnd(&stream) }
            var ended = false, buffer = [UInt8](repeating: 0, count: 65_536)
            func pump(_ flush: Int32) throws -> Int32 {
                try buffer.withUnsafeMutableBytes { bytes in
                    stream.next_out = bytes.bindMemory(to: Bytef.self).baseAddress; stream.avail_out = uInt(bytes.count)
                    let status = inflate(&stream, flush)
                    try emit(UnsafeRawBufferPointer(bytes), count: bytes.count - Int(stream.avail_out))
                    return status
                }
            }
            while consumed < entry.compressed, !ended {
                let chunk = try read(entry.dataOffset + consumed, Int(min(65_536, entry.compressed - consumed))); consumed += Int64(chunk.count)
                try chunk.withUnsafeBytes { bytes in
                    stream.next_in = UnsafeMutablePointer(mutating: bytes.bindMemory(to: Bytef.self).baseAddress); stream.avail_in = uInt(bytes.count)
                    repeat {
                        let before = stream.avail_in, beforeWritten = written, status = try pump(Z_NO_FLUSH)
                        if status == Z_STREAM_END { guard stream.avail_in == 0, consumed == entry.compressed else { throw AntigravityArchiveError.archiveInvalid }; ended = true; break }
                        // Raw inflate can drain buffered output after consuming
                        // this input chunk. An empty-input/no-output Z_BUF_ERROR
                        // requests the next chunk; final truncation still fails
                        // below when Z_FINISH cannot reach Z_STREAM_END.
                        if status == Z_BUF_ERROR, stream.avail_in == 0, written == beforeWritten { break }
                        guard status == Z_OK, before != stream.avail_in || written > beforeWritten else { throw AntigravityArchiveError.archiveInvalid }
                    } while stream.avail_in > 0 || stream.avail_out == 0
                    stream.next_in = nil
                }
            }
            while !ended {
                stream.next_in = nil; stream.avail_in = 0
                let before = written, status = try pump(Z_FINISH)
                if status == Z_STREAM_END { ended = true }
                else { guard status == Z_OK, written > before else { throw AntigravityArchiveError.archiveInvalid } }
            }
        }
        guard consumed == entry.compressed, written == entry.uncompressed, UInt32(truncatingIfNeeded: checksum) == entry.crc else { throw AntigravityArchiveError.archiveInvalid }
    }
    private func validateFlags(_ flags: UInt16, method: UInt16) throws {
        guard method == 0 || method == 8, flags & ~(method == 8 ? 0x080e : 0x0808) == 0 else { throw AntigravityArchiveError.archiveInvalid }
    }
    private func extras(_ data: Data) throws -> [UInt16: Data] {
        var result: [UInt16: Data] = [:], cursor = 0
        while cursor < data.count {
            let id = try data.u16(cursor), length = Int(try data.u16(cursor + 2)); cursor += 4
            guard length <= data.count - cursor, result[id] == nil, ![UInt16(0x0017), 0x9901].contains(id) else { throw AntigravityArchiveError.archiveInvalid }
            result[id] = data.subdata(in: cursor..<cursor + length); cursor += length
        }; return result
    }
    private func zip64(_ extra: Data?, uncompressed: UInt32, compressed: UInt32, offset: UInt32, disk: UInt16) throws -> (uncompressed: Int64, compressed: Int64, offset: Int64, disk: Int64) {
        let extra = extra ?? Data(); var cursor = 0
        func size(_ raw: UInt32) throws -> Int64 {
            if raw != 0xffffffff { return Int64(raw) }; defer { cursor += 8 }; return try extra.i64(cursor)
        }
        let size1 = try size(uncompressed), size2 = try size(compressed), start = try size(offset)
        let diskNumber: Int64
        if disk == 0xffff { diskNumber = Int64(try extra.u32(cursor)); cursor += 4 } else { diskNumber = Int64(disk) }
        guard cursor == extra.count else { throw AntigravityArchiveError.archiveInvalid }
        return (size1, size2, start, diskNumber)
    }
    private func descriptor(_ data: Data, entry: AntigravityZIPEntry, zip64: Bool) throws {
        let base = zip64 ? 20 : 12
        guard data.count == base || data.count == base + 4 else { throw AntigravityArchiveError.archiveInvalid }
        let start = data.count == base + 4 ? 4 : 0
        if start == 4 { guard try data.u32(0) == 0x08074b50 else { throw AntigravityArchiveError.archiveInvalid } }
        let compressed = zip64 ? try data.i64(start + 4) : Int64(try data.u32(start + 4))
        let uncompressed = zip64 ? try data.i64(start + 12) : Int64(try data.u32(start + 8))
        guard try data.u32(start) == entry.crc, compressed == entry.compressed, uncompressed == entry.uncompressed else { throw AntigravityArchiveError.archiveInvalid }
    }
    private func validateExtensible(_ data: Data) throws {
        var cursor = 0
        while cursor < data.count {
            _ = try data.u16(cursor); let length = Int(try data.u32(cursor + 2)); cursor += 6
            guard length <= data.count - cursor else { throw AntigravityArchiveError.archiveInvalid }; cursor += length
        }
    }
}
private extension Data {
    func u16(_ offset: Int) throws -> UInt16 {
        guard offset >= 0, offset <= count - 2 else { throw AntigravityArchiveError.archiveInvalid }
        return UInt16(self[offset]) | UInt16(self[offset + 1]) << 8
    }
    func u32(_ offset: Int) throws -> UInt32 { UInt32(try u16(offset)) | UInt32(try u16(offset + 2)) << 16 }
    func i64(_ offset: Int) throws -> Int64 {
        let value = UInt64(try u32(offset)) | UInt64(try u32(offset + 4)) << 32
        guard value <= UInt64(Int64.max) else { throw AntigravityArchiveError.archiveInvalid }; return Int64(value)
    }
}
