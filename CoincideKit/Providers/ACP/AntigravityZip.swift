import Compression
import Foundation
import zlib

/// Reads a ZIP archive's central directory and streams out stored or deflated members: just enough
/// for Google's Antigravity release archives, and strict about it. Every offset and size is checked
/// against the file before it is used, names are never used as paths, and a member must inflate to
/// exactly its recorded size and CRC-32. Which members are acceptable is the caller's decision.
struct AntigravityZip {
    struct Entry: Sendable, Hashable {
        var name: String
        var versionMadeBy: UInt16
        var flags: UInt16
        var method: UInt16
        var crc32: UInt32
        var compressedSize: UInt64
        var uncompressedSize: UInt64
        var externalAttributes: UInt32
        var localHeaderOffset: UInt64

        nonisolated var isEncrypted: Bool { flags & 1 != 0 }
        /// The Unix file type bits (`S_IFMT`), or 0 when the archiver recorded none.
        nonisolated var unixFileType: UInt32 { (externalAttributes >> 16) & 0o170000 }
        nonisolated var isDOSDirectory: Bool { externalAttributes & 0x10 != 0 }
    }

    struct Failure: Error, Equatable {
        var reason: String
    }

    nonisolated static let maxEntries = 64
    private nonisolated static let maxCentralDirectoryBytes: UInt64 = 1 << 20
    private nonisolated static let chunkBytes = 1 << 20

    let url: URL
    let entries: [Entry]
    private let fileSize: UInt64
    /// Where the central directory starts; member data must end before it.
    private let centralDirectoryOffset: UInt64

    nonisolated init(url: URL) throws {
        self.url = url
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        let size = try handle.seekToEnd()
        fileSize = size
        guard size >= 22 else { throw Failure(reason: "too small for a zip archive") }

        // The end of central directory record, which may be followed by a comment of up to 64 KiB.
        let tailLength = min(size, 22 + 0xFFFF)
        let tail = try Self.read(handle, at: size - tailLength, count: Int(tailLength))
        var eocd: Int?
        var index = tail.count - 22
        while index >= 0 {
            if Self.uint32(tail, index) == 0x0605_4B50, Int(Self.uint16(tail, index + 20)) == tail.count - index - 22 {
                eocd = index
                break
            }
            index -= 1
        }
        guard let eocd else { throw Failure(reason: "no end of central directory record") }
        let eocdOffset = size - tailLength + UInt64(eocd)
        guard Self.uint16(tail, eocd + 4) == 0, Self.uint16(tail, eocd + 6) == 0 else {
            throw Failure(reason: "multi-disk archives are not supported")
        }
        var entriesOnDisk = UInt64(Self.uint16(tail, eocd + 8))
        var totalEntries = UInt64(Self.uint16(tail, eocd + 10))
        var directorySize = UInt64(Self.uint32(tail, eocd + 12))
        var directoryOffset = UInt64(Self.uint32(tail, eocd + 16))
        var directoryEnd = eocdOffset

        if totalEntries == 0xFFFF || entriesOnDisk == 0xFFFF || directorySize == 0xFFFF_FFFF || directoryOffset == 0xFFFF_FFFF {
            // ZIP64: a locator right before the record points at the 64-bit record.
            guard eocdOffset >= 20 else { throw Failure(reason: "missing ZIP64 locator") }
            let locator = try Self.read(handle, at: eocdOffset - 20, count: 20)
            guard Self.uint32(locator, 0) == 0x0706_4B50, Self.uint32(locator, 4) == 0, Self.uint32(locator, 16) == 1 else {
                throw Failure(reason: "invalid ZIP64 locator")
            }
            let recordOffset = Self.uint64(locator, 8)
            guard recordOffset <= eocdOffset - 20 - 56 else { throw Failure(reason: "ZIP64 record out of range") }
            let record = try Self.read(handle, at: recordOffset, count: 56)
            guard Self.uint32(record, 0) == 0x0606_4B50, Self.uint32(record, 16) == 0, Self.uint32(record, 20) == 0 else {
                throw Failure(reason: "invalid ZIP64 record")
            }
            entriesOnDisk = Self.uint64(record, 24)
            totalEntries = Self.uint64(record, 32)
            directorySize = Self.uint64(record, 40)
            directoryOffset = Self.uint64(record, 48)
            directoryEnd = recordOffset
        }
        guard entriesOnDisk == totalEntries, totalEntries <= UInt64(Self.maxEntries) else {
            throw Failure(reason: "unexpected number of entries")
        }
        guard directorySize <= Self.maxCentralDirectoryBytes, directoryOffset <= directoryEnd,
            directorySize <= directoryEnd - directoryOffset
        else { throw Failure(reason: "central directory out of range") }
        centralDirectoryOffset = directoryOffset

        let directory = try Self.read(handle, at: directoryOffset, count: Int(directorySize))
        var entries: [Entry] = []
        var cursor = 0
        for _ in 0..<totalEntries {
            guard cursor + 46 <= directory.count, Self.uint32(directory, cursor) == 0x0201_4B50 else {
                throw Failure(reason: "invalid central directory entry")
            }
            let nameLength = Int(Self.uint16(directory, cursor + 28))
            let extraLength = Int(Self.uint16(directory, cursor + 30))
            let commentLength = Int(Self.uint16(directory, cursor + 32))
            let end = cursor + 46 + nameLength + extraLength + commentLength
            guard end <= directory.count, nameLength > 0 else { throw Failure(reason: "truncated central directory entry") }
            let nameBytes = directory[directory.startIndex + cursor + 46..<directory.startIndex + cursor + 46 + nameLength]
            guard let name = String(validating: nameBytes, as: UTF8.self), !name.contains("\0") else {
                throw Failure(reason: "member name is not valid UTF-8")
            }
            var entry = Entry(
                name: name, versionMadeBy: Self.uint16(directory, cursor + 4), flags: Self.uint16(directory, cursor + 8),
                method: Self.uint16(directory, cursor + 10), crc32: Self.uint32(directory, cursor + 16),
                compressedSize: UInt64(Self.uint32(directory, cursor + 20)),
                uncompressedSize: UInt64(Self.uint32(directory, cursor + 24)),
                externalAttributes: Self.uint32(directory, cursor + 38),
                localHeaderOffset: UInt64(Self.uint32(directory, cursor + 42)))
            let diskStart = Self.uint16(directory, cursor + 34)
            try Self.applyZIP64Extra(
                &entry, diskStart: diskStart,
                extra: directory[directory.startIndex + cursor + 46 + nameLength..<directory.startIndex + cursor + 46 + nameLength + extraLength])
            entries.append(entry)
            cursor = end
        }
        self.entries = entries
    }

    /// Streams `entry`'s contents to `consume` in chunks. Fails, without writing more, when the member
    /// would exceed its recorded size or its data, CRC-32 or compression is not what the archive says,
    /// and stops with `CancellationError` once `isCancelled` returns true.
    nonisolated func extract(_ entry: Entry, isCancelled: () -> Bool = { false }, consume: (Data) throws -> Void) throws {
        guard entry.method == 0 || entry.method == 8 else { throw Failure(reason: "unsupported compression method") }
        guard !entry.isEncrypted else { throw Failure(reason: "encrypted member") }
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        guard entry.localHeaderOffset <= centralDirectoryOffset, centralDirectoryOffset - entry.localHeaderOffset >= 30 else {
            throw Failure(reason: "local header out of range")
        }
        let header = try Self.read(handle, at: entry.localHeaderOffset, count: 30)
        guard Self.uint32(header, 0) == 0x0403_4B50, Self.uint16(header, 8) == entry.method else {
            throw Failure(reason: "local header does not match the central directory")
        }
        let nameLength = UInt64(Self.uint16(header, 26))
        let extraLength = UInt64(Self.uint16(header, 28))
        let dataStart = entry.localHeaderOffset + 30 + nameLength + extraLength
        guard dataStart <= centralDirectoryOffset, entry.compressedSize <= centralDirectoryOffset - dataStart else {
            throw Failure(reason: "member data out of range")
        }
        let localName = try Self.read(handle, at: entry.localHeaderOffset + 30, count: Int(nameLength))
        guard String(validating: localName, as: UTF8.self) == entry.name else {
            throw Failure(reason: "local name does not match the central directory")
        }
        if entry.method == 0, entry.compressedSize != entry.uncompressedSize {
            throw Failure(reason: "stored member sizes differ")
        }

        try handle.seek(toOffset: dataStart)
        var produced: UInt64 = 0
        var crc = zlib.crc32(0, nil, 0)
        try withoutActuallyEscaping(consume) { consume in
            let emit = { (data: Data) throws in
                produced += UInt64(data.count)
                guard produced <= entry.uncompressedSize else { throw Failure(reason: "member is larger than recorded") }
                crc = data.withUnsafeBytes { raw in
                    zlib.crc32(crc, raw.bindMemory(to: Bytef.self).baseAddress, uInt(raw.count))
                }
                try consume(data)
            }
            // The filter lives only for this call, so its writer never outlives `consume`.
            let filter: OutputFilter? =
                entry.method == 8
                ? try OutputFilter(.decompress, using: .zlib, bufferCapacity: Self.chunkBytes) { data in
                    if let data, !data.isEmpty { try emit(data) }
                } : nil
            var remaining = entry.compressedSize
            while remaining > 0 {
                if isCancelled() { throw CancellationError() }
                let count = Int(min(UInt64(Self.chunkBytes), remaining))
                guard let chunk = try handle.read(upToCount: count), chunk.count == count else {
                    throw Failure(reason: "member data is truncated")
                }
                remaining -= UInt64(count)
                if let filter { try filter.write(chunk) } else { try emit(chunk) }
            }
            try filter?.finalize()
        }
        guard produced == entry.uncompressedSize else { throw Failure(reason: "member is smaller than recorded") }
        guard UInt32(truncatingIfNeeded: crc) == entry.crc32 else { throw Failure(reason: "member failed its CRC-32 check") }
    }

    // MARK: Parsing

    private nonisolated static func applyZIP64Extra(_ entry: inout Entry, diskStart: UInt16, extra: Data) throws {
        let needsSize = entry.uncompressedSize == 0xFFFF_FFFF
        let needsCompressed = entry.compressedSize == 0xFFFF_FFFF
        let needsOffset = entry.localHeaderOffset == 0xFFFF_FFFF
        var found = false
        var cursor = 0
        while cursor + 4 <= extra.count {
            let id = uint16(extra, cursor)
            let length = Int(uint16(extra, cursor + 2))
            guard cursor + 4 + length <= extra.count else { throw Failure(reason: "truncated extra field") }
            if id == 0x0001 {
                found = true
                var field = cursor + 4
                let end = field + length
                func next() throws -> UInt64 {
                    guard field + 8 <= end else { throw Failure(reason: "truncated ZIP64 extra field") }
                    defer { field += 8 }
                    return uint64(extra, field)
                }
                if needsSize { entry.uncompressedSize = try next() }
                if needsCompressed { entry.compressedSize = try next() }
                if needsOffset { entry.localHeaderOffset = try next() }
            }
            cursor += 4 + length
        }
        guard diskStart == 0 || diskStart == 0xFFFF else { throw Failure(reason: "member on another disk") }
        if (needsSize || needsCompressed || needsOffset) && !found { throw Failure(reason: "missing ZIP64 extra field") }
    }

    private nonisolated static func read(_ handle: FileHandle, at offset: UInt64, count: Int) throws -> Data {
        try handle.seek(toOffset: offset)
        guard count > 0 else { return Data() }
        guard let data = try handle.read(upToCount: count), data.count == count else {
            throw Failure(reason: "unexpected end of archive")
        }
        return data
    }

    private nonisolated static func uint16(_ data: Data, _ offset: Int) -> UInt16 {
        let base = data.startIndex + offset
        return UInt16(data[base]) | UInt16(data[base + 1]) << 8
    }

    private nonisolated static func uint32(_ data: Data, _ offset: Int) -> UInt32 {
        UInt32(uint16(data, offset)) | UInt32(uint16(data, offset + 2)) << 16
    }

    private nonisolated static func uint64(_ data: Data, _ offset: Int) -> UInt64 {
        UInt64(uint32(data, offset)) | UInt64(uint32(data, offset + 4)) << 32
    }
}
