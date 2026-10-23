import Darwin
import Foundation

/// The optional `coincide [folder]` command (T3's `t3 app [path]`). The script only asks
/// the app to open a `coincide://open` link: Coincide adds the folder as a project when
/// needed and starts an empty conversation there. Nothing is sent to an agent.
public enum CLIShim {
    public static let commandName = "coincide"
    public static let marker = "Written by Coincide: opens a folder in the Coincide app."
    static let maximumShimBytes = 16_384

    static func shellWord(_ value: String) -> String { "'" + value.replacingOccurrences(of: "'", with: "'\"'\"'") + "'" }

    public static func script(appPath: String, bundleIdentifier: String) -> String {
        """
        #!/bin/sh
        # \(marker)
        # Remove it from Coincide Settings > General > Command-line tool.
        COINCIDE_APP=\(shellWord(appPath))
        COINCIDE_BUNDLE_ID=\(shellWord(bundleIdentifier))
        usage() { printf '%s\\n' 'Usage: coincide [folder]' '       coincide status|projects|threads|thread|providers|models|select|new|screenshot [arguments]' '' 'Open a folder or control the running Coincide app. Commands return JSON; no command sends a model prompt.'; }
        case "${1:-}" in -h|--help) usage; exit 0 ;; esac
        case "${1:-}" in status|projects|threads|thread|providers|models|select|new|screenshot)
            if [ -f "$COINCIDE_APP/Contents/Resources/coincide" ]; then exec /usr/bin/python3 "$COINCIDE_APP/Contents/Resources/coincide" "$@"; fi
            printf '%s\\n' 'Update Coincide and reinstall the command from Settings.' >&2; exit 127 ;;
        esac
        if [ "$#" -gt 1 ]; then usage >&2; exit 2; fi
        unset CDPATH
        target=${1:-.}
        if [ ! -d "$target" ]; then printf 'coincide: %s is not a folder.\\n' "$target" >&2; exit 1; fi
        folder=$(cd -- "$target" 2>/dev/null && pwd -P) || { printf 'coincide: cannot open %s.\\n' "$target" >&2; exit 1; }
        encoded=$(printf '%s' "$folder" | /usr/bin/od -An -v -tx1 | /usr/bin/tr -d ' \\n' | /usr/bin/sed 's/../%&/g')
        link="coincide://open?path=$encoded"
        if [ "${COINCIDE_PRINT_LINK:-}" = 1 ]; then printf '%s\\n' "$link"; exit 0; fi
        if [ -d "$COINCIDE_APP" ]; then exec /usr/bin/open -a "$COINCIDE_APP" "$link"; fi
        /usr/bin/open -b "$COINCIDE_BUNDLE_ID" "$link" 2>/dev/null && exit 0
        printf '%s\\n' 'Coincide has moved or been removed. Open the app and install the command again from Settings.' >&2
        exit 127

        """
    }

    /// The command must be our bounded, single-link regular file. Never follow a
    /// symbolic link, including a dangling link, to classify another file as ours.
    public static func isShim(at url: URL) -> Bool {
        let fd = open(url.path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        guard fd >= 0 else { return false }
        defer { Darwin.close(fd) }
        return ownedBytes(fd) != nil
    }

    static func hasMarker(_ data: Data) -> Bool {
        guard !data.isEmpty, data.count <= maximumShimBytes, let text = String(data: data, encoding: .utf8) else { return false }
        return text.split(separator: "\n").prefix(3).contains { $0 == "# " + marker }
    }
    static func ownedBytes(_ fd: Int32) -> Data? {
        var before = stat()
        guard fstat(fd, &before) == 0, before.st_mode & S_IFMT == S_IFREG,
              before.st_uid == getuid(), before.st_nlink == 1, before.st_mode & 0o022 == 0,
              before.st_size > 0, before.st_size <= maximumShimBytes else { return nil }
        var data = Data(count: Int(before.st_size)), offset = 0
        while offset < data.count {
            let count = data.withUnsafeMutableBytes { pread(fd, $0.baseAddress!.advanced(by: offset), $0.count - offset, off_t(offset)) }
            if count < 0 && errno == EINTR { continue }
            guard count > 0 else { return nil }; offset += count
        }
        var after = stat()
        guard fstat(fd, &after) == 0, before.st_dev == after.st_dev, before.st_ino == after.st_ino,
              before.st_size == after.st_size, before.st_mtimespec.tv_sec == after.st_mtimespec.tv_sec,
              before.st_mtimespec.tv_nsec == after.st_mtimespec.tv_nsec, hasMarker(data) else { return nil }
        return data
    }

    public static func defaultDirectories(home: URL = FileManager.default.homeDirectoryForCurrentUser) -> [URL] {
        [URL(fileURLWithPath: "/opt/homebrew/bin"), URL(fileURLWithPath: "/usr/local/bin"),
         home.appendingPathComponent(".local/bin"), home.appendingPathComponent("bin")]
    }
}

public struct CLIShimInstaller: Sendable {
    public enum State: Sendable, Equatable {
        case notInstalled
        case installed(URL)
    }
    public struct Installation: Sendable, Equatable {
        public let url: URL
        /// The directory is not on the login-shell PATH; the command needs its full path.
        public let onPath: Bool
        /// Another `coincide` earlier on PATH runs instead of this one.
        public let shadowedBy: URL?
    }
    public let directories: [URL]
    public let pathEntries: [String]
    /// Created only when no existing candidate directory can hold the command.
    public let creatableDirectory: URL?

    public init(directories: [URL] = CLIShim.defaultDirectories(), pathEntries: [String],
                creatableDirectory: URL? = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".local/bin")) {
        self.directories = directories; self.pathEntries = pathEntries; self.creatableDirectory = creatableDirectory
    }

    private func command(in directory: URL) -> URL { directory.appendingPathComponent(CLIShim.commandName) }
    private func exists(_ url: URL) -> Bool {
        var info = stat()
        return lstat(url.path, &info) == 0
    }
    private func openDirectory(_ directory: URL) -> Int32 {
        let fd = open(directory.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard fd >= 0 else { return -1 }
        var info = stat()
        guard fstat(fd, &info) == 0, info.st_mode & S_IFMT == S_IFDIR,
              (info.st_uid == getuid() || info.st_uid == 0), info.st_mode & 0o002 == 0 else { Darwin.close(fd); return -1 }
        return fd
    }
    private func stillNames(_ fd: Int32, directory: Int32) -> Bool {
        var opened = stat(), named = stat()
        return fstat(fd, &opened) == 0 && fstatat(directory, CLIShim.commandName, &named, AT_SYMLINK_NOFOLLOW) == 0
            && opened.st_dev == named.st_dev && opened.st_ino == named.st_ino && opened.st_nlink == 1
            && named.st_mode & S_IFMT == S_IFREG
    }
    private func write(_ data: Data, to fd: Int32) throws {
        var offset = 0
        while offset < data.count {
            let count = data.withUnsafeBytes { pwrite(fd, $0.baseAddress!.advanced(by: offset), $0.count - offset, off_t(offset)) }
            if count < 0 && errno == EINTR { continue }
            guard count > 0 else { throw CoincideError("The command could not be written.") }; offset += count
        }
        guard ftruncate(fd, off_t(data.count)) == 0, fchmod(fd, 0o755) == 0, fsync(fd) == 0 else {
            throw CoincideError("The command could not be saved.")
        }
    }
    private func standardized(_ path: String) -> String { URL(fileURLWithPath: path).standardizedFileURL.path }
    private func isOnPath(_ directory: URL) -> Bool { pathEntries.map(standardized).contains(directory.standardizedFileURL.path) }

    public func state() -> State {
        for directory in directories {
            let parent = openDirectory(directory)
            guard parent >= 0 else { continue }
            defer { Darwin.close(parent) }
            let fd = openat(parent, CLIShim.commandName, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
            guard fd >= 0 else { continue }
            defer { Darwin.close(fd) }
            if CLIShim.ownedBytes(fd) != nil { return .installed(command(in: directory)) }
        }
        return .notInstalled
    }

    /// The first `coincide` on PATH that is not this app's command.
    public func foreignCommandOnPath() -> URL? {
        for entry in pathEntries where !entry.isEmpty {
            let candidate = command(in: URL(fileURLWithPath: entry))
            guard exists(candidate) else { continue }
            return CLIShim.isShim(at: candidate) ? nil : candidate
        }
        return nil
    }

    /// Prefers candidate directories on PATH. Never replaces a file it did not write.
    public func install(script: String) throws -> Installation {
        let fileManager = FileManager.default, bytes = Data(script.utf8)
        guard CLIShim.hasMarker(bytes) else { throw CoincideError("The generated command is invalid.") }
        let ordered = directories.filter(isOnPath) + directories.filter { !isOnPath($0) }
        var refused: [URL] = []
        var target: URL?
        for directory in ordered {
            var isDirectory: ObjCBool = false
            guard fileManager.fileExists(atPath: directory.path, isDirectory: &isDirectory), isDirectory.boolValue,
                  fileManager.isWritableFile(atPath: directory.path) else { continue }
            let destination = command(in: directory)
            if exists(destination) && !CLIShim.isShim(at: destination) { refused.append(destination); continue }
            target = directory; break
        }
        if target == nil, let creatable = creatableDirectory, !exists(creatable) {
            try fileManager.createDirectory(at: creatable, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o755])
            target = creatable
        }
        guard let directory = target else {
            if let first = refused.first { throw CoincideError("A different coincide command already exists at \(first.path). Coincide does not replace it.") }
            throw CoincideError("No writable folder is available for the command. Create ~/.local/bin and add it to PATH, then try again.")
        }
        let destination = command(in: directory)
        let parent = openDirectory(directory)
        guard parent >= 0 else { throw CoincideError("The command folder changed or is unavailable.") }
        defer { Darwin.close(parent) }
        var named = stat()
        if fstatat(parent, CLIShim.commandName, &named, AT_SYMLINK_NOFOLLOW) == 0 {
            let fd = openat(parent, CLIShim.commandName, O_RDWR | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
            guard fd >= 0 else { throw CoincideError("A different coincide command already exists. It was kept.") }
            defer { Darwin.close(fd) }
            guard flock(fd, LOCK_EX | LOCK_NB) == 0, let original = CLIShim.ownedBytes(fd), stillNames(fd, directory: parent) else {
                throw CoincideError("The existing command changed. It was kept.")
            }
            // Write only the verified owned inode. Replacing the pathname after this
            // check cannot cause an unrelated replacement file or symlink to be overwritten.
            if original != bytes {
                do { try write(bytes, to: fd) }
                catch { try? write(original, to: fd); throw error }
            }
            guard stillNames(fd, directory: parent) else { throw CoincideError("The command changed while it was installed.") }
        } else {
            guard errno == ENOENT else { throw CoincideError("The command location could not be inspected.") }
            let temporary = ".coincide-" + UUID().uuidString + ".tmp"
            let fd = openat(parent, temporary, O_RDWR | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o755)
            guard fd >= 0 else { throw CoincideError("The command could not be installed.") }
            defer { Darwin.close(fd); _ = unlinkat(parent, temporary, 0) }
            try write(bytes, to: fd)
            // linkat is an exclusive publication: an unrelated file or dangling link
            // appearing after discovery is preserved rather than renamed over.
            guard linkat(parent, temporary, parent, CLIShim.commandName, 0) == 0 else {
                throw CoincideError("The command location changed. The existing file was kept.")
            }
            guard unlinkat(parent, temporary, 0) == 0, fsync(parent) == 0 else {
                throw CoincideError("The command was installed but its directory could not be synchronized.")
            }
        }
        return .init(url: destination, onPath: isOnPath(directory), shadowedBy: foreignCommandOnPath())
    }

    /// Removes only commands this app wrote. Returns what was removed.
    @discardableResult
    public func remove() throws -> [URL] {
        var removed: [URL] = []
        for directory in directories {
            let parent = openDirectory(directory)
            guard parent >= 0 else { continue }
            defer { Darwin.close(parent) }
            let fd = openat(parent, CLIShim.commandName, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
            guard fd >= 0 else { continue }
            defer { Darwin.close(fd) }
            guard flock(fd, LOCK_EX | LOCK_NB) == 0, CLIShim.ownedBytes(fd) != nil, stillNames(fd, directory: parent) else { continue }
            guard unlinkat(parent, CLIShim.commandName, 0) == 0 else { throw CoincideError("The command could not be removed.") }
            removed.append(command(in: directory))
        }
        return removed
    }
}
