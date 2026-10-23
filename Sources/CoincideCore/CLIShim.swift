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
        usage() { printf '%s\\n' 'Usage: coincide [folder]' '' 'Opens the folder in Coincide, adding it as a project if needed, and starts a new conversation there.'; }
        case "${1:-}" in -h|--help) usage; exit 0 ;; esac
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

    /// Only a small regular file carrying the marker is ours; a large binary is never read.
    public static func isShim(at url: URL) -> Bool {
        guard let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey, .isSymbolicLinkKey]),
              values.isSymbolicLink != true, values.isRegularFile == true, (values.fileSize ?? .max) <= maximumShimBytes,
              let text = try? String(contentsOf: url, encoding: .utf8) else { return false }
        return text.split(separator: "\n").prefix(3).contains { $0 == "# " + marker }
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
    private func exists(_ url: URL) -> Bool { (try? FileManager.default.attributesOfItem(atPath: url.path)) != nil }
    private func standardized(_ path: String) -> String { URL(fileURLWithPath: path).standardizedFileURL.path }
    private func isOnPath(_ directory: URL) -> Bool { pathEntries.map(standardized).contains(directory.standardizedFileURL.path) }

    public func state() -> State {
        for directory in directories where CLIShim.isShim(at: command(in: directory)) { return .installed(command(in: directory)) }
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
        let fileManager = FileManager.default
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
        let temporary = directory.appendingPathComponent(".coincide-\(UUID().uuidString).tmp")
        do {
            try Data(script.utf8).write(to: temporary, options: [.withoutOverwriting])
            try fileManager.setAttributes([.posixPermissions: 0o755], ofItemAtPath: temporary.path)
            guard rename(temporary.path, destination.path) == 0 else { throw CoincideError("The command could not be installed at \(destination.path).") }
        } catch {
            try? fileManager.removeItem(at: temporary); throw error
        }
        return .init(url: destination, onPath: isOnPath(directory), shadowedBy: foreignCommandOnPath())
    }

    /// Removes only commands this app wrote. Returns what was removed.
    @discardableResult
    public func remove() throws -> [URL] {
        var removed: [URL] = []
        for directory in directories {
            let url = command(in: directory)
            guard CLIShim.isShim(at: url) else { continue }
            try FileManager.default.removeItem(at: url); removed.append(url)
        }
        return removed
    }
}
