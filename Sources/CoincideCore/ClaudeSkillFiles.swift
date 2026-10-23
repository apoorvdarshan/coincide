import Darwin
import Foundation

/// Read-only anchored metadata access. Symlinked skills are supported by Claude;
/// the resolved regular file and the lexical source must still name the same
/// inode after the bounded read. No skill body is retained in an inventory.
enum ClaudeSkillFiles {
    struct Identity: Equatable { let device: dev_t, inode: ino_t }
    static func identity(_ path: String, directory: Bool = false) throws -> Identity {
        var info = stat()
        guard stat(path, &info) == 0, !directory || info.st_mode & S_IFMT == S_IFDIR,
              info.st_uid == getuid() || info.st_uid == 0 else { throw ProviderSkillError(.unavailable) }
        return .init(device: info.st_dev, inode: info.st_ino)
    }
    static func read(_ path: String, maximum: Int, prefix: Bool = false) throws -> Data? {
        try SkillValidation.text(path, maximum: 4_096, empty: false)
        let physical = URL(fileURLWithPath: path).resolvingSymlinksInPath().path
        let fd = open(physical, O_RDONLY | O_CLOEXEC | O_NOFOLLOW | O_NONBLOCK)
        if fd < 0, errno == ENOENT || errno == ENOTDIR { return nil }
        guard fd >= 0 else { throw ProviderSkillError(.unavailable) }; defer { close(fd) }
        var before = stat(), after = stat()
        guard fstat(fd, &before) == 0, before.st_mode & S_IFMT == S_IFREG,
              before.st_uid == getuid() || before.st_uid == 0,
              before.st_size >= 0, prefix || before.st_size <= maximum else { throw ProviderSkillError(.invalidResponse) }
        let capacity = min(8_192, maximum + 1)
        var result = Data(), buffer = [UInt8](repeating: 0, count: capacity)
        while result.count <= maximum {
            try Task.checkCancellation()
            let count = buffer.withUnsafeMutableBytes { Darwin.read(fd, $0.baseAddress, min(capacity, maximum + 1 - result.count)) }
            if count == 0 { break }; if count < 0, errno == EINTR { continue }
            guard count > 0 else { throw ProviderSkillError(.unavailable) }; result.append(contentsOf: buffer.prefix(count))
        }
        guard fstat(fd, &after) == 0, before.st_dev == after.st_dev, before.st_ino == after.st_ino,
              before.st_size == after.st_size, before.st_mtimespec.tv_sec == after.st_mtimespec.tv_sec,
              before.st_mtimespec.tv_nsec == after.st_mtimespec.tv_nsec,
              try identity(path) == Identity(device: before.st_dev, inode: before.st_ino),
              prefix || result.count <= maximum else { throw ProviderSkillError(.invalidResponse) }
        return result
    }
    static func text(_ path: String, maximum: Int = 1_048_576) throws -> String? {
        guard let data = try read(path, maximum: maximum) else { return nil }
        guard let value = String(data: data, encoding: .utf8) else { throw ProviderSkillError(.invalidResponse) }; return value
    }
    static func directory(_ path: String) throws -> [String] {
        let before = try identity(path, directory: true)
        guard let directory = opendir(path) else { throw ProviderSkillError(.unavailable) }; defer { closedir(directory) }
        var opened = stat(); guard fstat(dirfd(directory), &opened) == 0,
            before == Identity(device: opened.st_dev, inode: opened.st_ino) else { throw ProviderSkillError(.unavailable) }
        var values: [String] = []
        while let entry = readdir(directory) {
            try Task.checkCancellation()
            let name = withUnsafePointer(to: &entry.pointee.d_name) { pointer in
                pointer.withMemoryRebound(to: CChar.self, capacity: Int(NAME_MAX) + 1) { String(cString: $0) }
            }
            if name == "." || name == ".." { continue }; values.append(name)
            guard values.count <= 5_000 else { throw ProviderSkillError(.invalidResponse) }
        }
        guard try identity(path, directory: true) == before else { throw ProviderSkillError(.invalidResponse) }
        return values.sorted { $0.utf8.lexicographicallyPrecedes($1.utf8) }
    }
    static func exists(_ path: String) -> Bool { FileManager.default.fileExists(atPath: path) }
    static func path(_ raw: String, relativeTo base: String) -> String {
        URL(fileURLWithPath: raw.hasPrefix("/") ? raw : base + "/" + raw).standardizedFileURL.path
    }
    static func inside(_ candidate: String, root: String) -> Bool {
        candidate.utf8.elementsEqual(root.utf8) || Data(candidate.utf8).starts(with: Data((root.hasSuffix("/") ? root : root + "/").utf8))
    }
    /// JSONC settings: remove comments and trailing commas outside strings only.
    /// No evaluation, interpolation, shell, or permissive JSON5 key coercion.
    static func json(_ text: String) throws -> [String: Any] {
        let input = Array(text.utf8); var output: [UInt8] = []; var index = 0, quoted = false, escaped = false
        while index < input.count {
            let byte = input[index]
            if quoted {
                output.append(byte)
                if escaped { escaped = false } else if byte == 92 { escaped = true } else if byte == 34 { quoted = false }
                index += 1; continue
            }
            if byte == 34 { quoted = true; output.append(byte); index += 1; continue }
            if byte == 47, index + 1 < input.count, input[index + 1] == 47 {
                index += 2; while index < input.count, ![10, 13].contains(input[index]) { index += 1 }; output.append(32); continue
            }
            if byte == 47, index + 1 < input.count, input[index + 1] == 42 {
                index += 2; var closed = false
                while index + 1 < input.count { if input[index] == 42 && input[index + 1] == 47 { index += 2; closed = true; break }; output.append(input[index] == 10 ? 10 : 32); index += 1 }
                guard closed else { throw ProviderSkillError(.invalidResponse) }; output.append(32); continue
            }
            output.append(byte); index += 1
        }
        guard !quoted else { throw ProviderSkillError(.invalidResponse) }
        var stripped: [UInt8] = []; quoted = false; escaped = false
        for index in output.indices {
            let byte = output[index]
            if quoted { stripped.append(byte); if escaped { escaped = false } else if byte == 92 { escaped = true } else if byte == 34 { quoted = false }; continue }
            if byte == 34 { quoted = true }
            if byte == 44 {
                var next = index + 1; while next < output.count, [9, 10, 13, 32].contains(output[next]) { next += 1 }
                if next < output.count, [93, 125].contains(output[next]) { continue }
            }
            stripped.append(byte)
        }
        guard let value = try JSONSerialization.jsonObject(with: Data(stripped)) as? [String: Any] else { throw ProviderSkillError(.invalidResponse) }; return value
    }
}
