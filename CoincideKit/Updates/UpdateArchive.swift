import Foundation
import zlib

/// A deliberately small ZIP reader for app releases. Extraction never follows an archive-created link:
/// regular files are written first, and validated relative links are created last.
public enum UpdateArchive {
    private struct Entry {
        var path: String
        var bytes: Data
        var mode: UInt32
        var isDirectory: Bool
        var isLink: Bool { mode & 0o170000 == 0o120000 }
    }

    public static func extract(_ archive: URL, to destination: URL) throws {
        let data = try Data(contentsOf: archive, options: .mappedIfSafe)
        guard data.count <= 512 * 1024 * 1024, data.count >= 22,
              let end = stride(from: data.count - 22, through: max(0, data.count - 65_557), by: -1)
                .first(where: { data.u32($0) == 0x06054b50 }),
              data.u16(end + 4) == 0, data.u16(end + 6) == 0,
              data.u16(end + 8) == data.u16(end + 10),
              end + 22 + Int(data.u16(end + 20)) == data.count else { throw AppUpdateError.archive }
        let count = Int(data.u16(end + 10))
        var cursor = Int(data.u32(end + 16))
        let centralEnd = cursor + Int(data.u32(end + 12))
        guard count > 0, count < 50_000, centralEnd == end else { throw AppUpdateError.archive }
        var entries: [Entry] = []
        var paths = Set<String>()
        var expanded = 0
        for _ in 0..<count {
            guard cursor >= 0, cursor + 46 <= end, data.u32(cursor) == 0x02014b50 else { throw AppUpdateError.archive }
            let flags = data.u16(cursor + 8), method = data.u16(cursor + 10)
            let crc = data.u32(cursor + 16)
            let compressed = Int(data.u32(cursor + 20)), size = Int(data.u32(cursor + 24))
            let nameLength = Int(data.u16(cursor + 28)), extra = Int(data.u16(cursor + 30)), comment = Int(data.u16(cursor + 32))
            let offset = Int(data.u32(cursor + 42))
            guard flags & 1 == 0, method == 0 || method == 8, data.u16(cursor + 34) == 0,
                  size <= 256 * 1024 * 1024, compressed <= data.count,
                  cursor + 46 + nameLength + extra + comment <= end,
                  offset + 30 <= Int(data.u32(end + 16)), data.u32(offset) == 0x04034b50,
                  data.u16(offset + 6) == flags, data.u16(offset + 8) == method else { throw AppUpdateError.archive }
            let rawName = data.subdata(in: cursor + 46..<cursor + 46 + nameLength)
            let localNameLength = Int(data.u16(offset + 26)), localExtra = Int(data.u16(offset + 28))
            let body = offset + 30 + localNameLength + localExtra
            guard body + compressed <= Int(data.u32(end + 16)), localNameLength == nameLength,
                  data.subdata(in: offset + 30..<offset + 30 + localNameLength) == rawName,
                  let name = String(data: rawName, encoding: .utf8) else { throw AppUpdateError.archive }
            let isDirectory = name.hasSuffix("/")
            let path = isDirectory ? String(name.dropLast()) : name
            guard safe(path), paths.insert(key(path)).inserted else { throw AppUpdateError.archive }
            let mode = data.u32(cursor + 38) >> 16
            let kind = mode & 0o170000
            guard [0, 0o040000, 0o100000, 0o120000].contains(kind),
                  !isDirectory || size == 0, isDirectory || kind != 0o040000 else { throw AppUpdateError.archive }
            expanded += size
            guard expanded <= 1024 * 1024 * 1024 else { throw AppUpdateError.archive }
            let payload = data.subdata(in: body..<body + compressed)
            let bytes = try inflate(payload, method: method, size: size)
            let checksum = bytes.withUnsafeBytes { crc32(0, $0.bindMemory(to: Bytef.self).baseAddress, uInt(bytes.count)) }
            guard checksum == crc else { throw AppUpdateError.archive }
            // Finder ZIP metadata is not needed for executable validation and is never restored.
            if !path.hasPrefix("__MACOSX/") && path != "__MACOSX" {
                guard path == "Coincide.app" || path.hasPrefix("Coincide.app/") else { throw AppUpdateError.archive }
                entries.append(Entry(path: path, bytes: bytes, mode: mode, isDirectory: isDirectory))
            }
            cursor += 46 + nameLength + extra + comment
        }
        guard cursor == centralEnd, !entries.isEmpty else { throw AppUpdateError.archive }
        let byPath = Dictionary(uniqueKeysWithValues: entries.map { (key($0.path), $0) })
        for entry in entries {
            var parent = (entry.path as NSString).deletingLastPathComponent
            while !parent.isEmpty {
                if let existing = byPath[key(parent)], !existing.isDirectory { throw AppUpdateError.archive }
                parent = (parent as NSString).deletingLastPathComponent
            }
            if entry.isLink {
                guard let target = String(data: entry.bytes, encoding: .utf8), !target.isEmpty, target.utf8.count <= 4096,
                      !target.hasPrefix("/"), !target.contains("\\"), !target.contains("\0") else { throw AppUpdateError.archive }
                _ = try resolvedLink(entry.path, target: target, entries: byPath, visited: [])
            }
        }
        let fm = FileManager.default
        guard !fm.fileExists(atPath: destination.path) else { throw AppUpdateError.archive }
        try fm.createDirectory(at: destination, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        do {
            for entry in entries where !entry.isLink {
                let url = destination.appendingPathComponent(entry.path)
                if entry.isDirectory {
                    try fm.createDirectory(at: url, withIntermediateDirectories: true)
                } else {
                    try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
                    try entry.bytes.write(to: url, options: .withoutOverwriting)
                    try fm.setAttributes([.posixPermissions: entry.mode & 0o111 == 0 ? 0o644 : 0o755], ofItemAtPath: url.path)
                }
            }
            for entry in entries where entry.isLink {
                let url = destination.appendingPathComponent(entry.path)
                try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
                try fm.createSymbolicLink(atPath: url.path, withDestinationPath: String(decoding: entry.bytes, as: UTF8.self))
            }
        } catch { try? fm.removeItem(at: destination); throw error }
    }

    private static func safe(_ path: String) -> Bool {
        !path.isEmpty && path.utf8.count <= 4096 && !path.contains("\\") && !path.contains(":") && !path.contains("\0")
            && path.split(separator: "/", omittingEmptySubsequences: false).allSatisfy { !$0.isEmpty && $0 != "." && $0 != ".." }
    }

    private static func key(_ path: String) -> String { path.precomposedStringWithCanonicalMapping.lowercased() }

    private static func resolvedLink(_ path: String, target: String, entries: [String: Entry], visited: Set<String>) throws -> String {
        guard visited.count < 40, !visited.contains(key(path)) else { throw AppUpdateError.archive }
        var components = path.split(separator: "/").dropLast().map(String.init)
        for part in target.split(separator: "/") {
            if part == "." { continue }
            if part == ".." { guard components.count > 1 else { throw AppUpdateError.archive }; components.removeLast() }
            else {
                components.append(String(part))
                let candidate = components.joined(separator: "/")
                if let entry = entries[key(candidate)], entry.isLink {
                    guard let next = String(data: entry.bytes, encoding: .utf8) else { throw AppUpdateError.archive }
                    components = try resolvedLink(candidate, target: next, entries: entries, visited: visited.union([key(path)])).split(separator: "/").map(String.init)
                }
            }
        }
        guard components.first == "Coincide.app" else { throw AppUpdateError.archive }
        return components.joined(separator: "/")
    }

    private static func inflate(_ input: Data, method: UInt16, size: Int) throws -> Data {
        if method == 0 { guard input.count == size else { throw AppUpdateError.archive }; return input }
        var output = Data(count: max(1, size))
        var stream = z_stream()
        guard inflateInit2_(&stream, -MAX_WBITS, ZLIB_VERSION, Int32(MemoryLayout<z_stream>.size)) == Z_OK else { throw AppUpdateError.archive }
        defer { inflateEnd(&stream) }
        let result = input.withUnsafeBytes { source in
            output.withUnsafeMutableBytes { destination in
                stream.next_in = UnsafeMutablePointer(mutating: source.bindMemory(to: Bytef.self).baseAddress)
                stream.avail_in = uInt(input.count)
                stream.next_out = destination.bindMemory(to: Bytef.self).baseAddress
                stream.avail_out = uInt(max(1, size))
                return zlib.inflate(&stream, Z_FINISH)
            }
        }
        guard result == Z_STREAM_END, stream.total_out == size, stream.total_in == input.count else { throw AppUpdateError.archive }
        return output.prefix(size)
    }
}

private extension Data {
    func u16(_ offset: Int) -> UInt16 { UInt16(self[offset]) | UInt16(self[offset + 1]) << 8 }
    func u32(_ offset: Int) -> UInt32 { UInt32(u16(offset)) | UInt32(u16(offset + 2)) << 16 }
}
