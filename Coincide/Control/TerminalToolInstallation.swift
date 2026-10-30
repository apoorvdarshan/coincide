import Foundation

/// Resolves the command a Terminal shell will find, then reuses or repairs Coincide's own link. Never runs the
/// discovered executable or replaces another tool. The app's Helpers directory is deliberately excluded.
nonisolated enum TerminalToolInstallation {
    struct Location: Equatable, Sendable {
        let url: URL
        let isOnPath: Bool
    }

    static func ensure(tool: URL, home: URL = FileManager.default.homeDirectoryForCurrentUser, searchPath: String,
        installDirectories: [URL]? = nil) throws -> Location {
        let files = FileManager.default
        guard files.isExecutableFile(atPath: tool.path) else { throw CommandLineControl.InstallError.missingTool }
        let helperDirectory = tool.deletingLastPathComponent().resolvingSymlinksInPath()
        var seen = Set<URL>()
        let directories = searchPath.split(separator: ":").compactMap { part -> URL? in
            guard part.hasPrefix("/") else { return nil }
            let directory = URL(fileURLWithPath: String(part), isDirectory: true).standardizedFileURL
            guard directory.resolvingSymlinksInPath() != helperDirectory, seen.insert(directory).inserted else { return nil }
            return directory
        }
        let preferred = installDirectories ?? [URL(fileURLWithPath: "/opt/homebrew/bin", isDirectory: true),
            URL(fileURLWithPath: "/usr/local/bin", isDirectory: true), home.appendingPathComponent(".local/bin", isDirectory: true)]

        // Respect PATH precedence: an unrelated command earlier on PATH must not silently shadow our installation.
        for directory in directories {
            let command = directory.appendingPathComponent("coincide")
            if ownsLink(command, tool: tool) {
                try link(tool, at: command)
                return Location(url: command, isOnPath: true)
            }
            if files.isExecutableFile(atPath: command.path) { throw CommandLineControl.InstallError.occupied(command.path) }
        }
        let writable = preferred.filter { files.isWritableFile(atPath: $0.path) }
        let directory = writable.first(where: { directories.contains($0.standardizedFileURL) })
            ?? writable.first ?? home.appendingPathComponent(".local/bin", isDirectory: true)
        let command = directory.appendingPathComponent("coincide")
        try files.createDirectory(at: directory, withIntermediateDirectories: true)
        try link(tool, at: command)
        return Location(url: command, isOnPath: directories.contains(directory.standardizedFileURL))
    }

    private static func ownsLink(_ command: URL, tool: URL) -> Bool {
        guard let target = try? FileManager.default.destinationOfSymbolicLink(atPath: command.path) else { return false }
        return command.resolvingSymlinksInPath() == tool.resolvingSymlinksInPath() || target.hasSuffix("/Contents/Helpers/coincide")
    }

    private static func link(_ tool: URL, at command: URL) throws {
        let files = FileManager.default
        if let _ = try? files.destinationOfSymbolicLink(atPath: command.path) {
            guard ownsLink(command, tool: tool) else { throw CommandLineControl.InstallError.occupied(command.path) }
            if command.resolvingSymlinksInPath() == tool.resolvingSymlinksInPath() { return }
            try files.removeItem(at: command)
        } else if files.fileExists(atPath: command.path) {
            throw CommandLineControl.InstallError.occupied(command.path)
        }
        try files.createSymbolicLink(at: command, withDestinationURL: tool)
    }
}
