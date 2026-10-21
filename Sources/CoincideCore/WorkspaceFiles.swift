import Foundation

public struct WorkspaceFile: Identifiable, Sendable {
    public var path: String
    public var isDirectory: Bool
    public var id: String { path }
    public var name: String { URL(fileURLWithPath: path).lastPathComponent }
    public init(path: String, isDirectory: Bool) { self.path = path; self.isDirectory = isDirectory }
}

public struct WorkspaceFiles: Sendable {
    public let root: URL
    public init(root: URL) { self.root = root.standardizedFileURL.resolvingSymlinksInPath() }
    public func resolve(_ relativePath: String) throws -> URL {
        guard !relativePath.hasPrefix("/") else { throw CoincideError("Use a path relative to this workspace.") }
        let components = relativePath.split(separator: "/")
        guard !components.contains("..") else { throw CoincideError("This file is outside the workspace.") }
        var url = root
        // Resolve each existing parent, even when the final file does not exist yet.
        // resolvingSymlinksInPath on an entire nonexistent path can retain symlink parents.
        for component in components where component != "." {
            url = url.appendingPathComponent(String(component)).resolvingSymlinksInPath()
            guard url.path == root.path || url.path.hasPrefix(root.path + "/") else { throw CoincideError("This file is outside the workspace.") }
        }
        return url
    }
    public func list(_ relativePath: String = "") throws -> [WorkspaceFile] {
        let directory = try resolve(relativePath)
        return try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles]).map {
            WorkspaceFile(path: String($0.path.dropFirst(root.path.count + 1)), isDirectory: (try $0.resourceValues(forKeys: [.isDirectoryKey])).isDirectory == true)
        }.sorted { $0.isDirectory != $1.isDirectory ? $0.isDirectory : $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }
    public func read(_ path: String) throws -> String {
        let url = try resolve(path)
        let size = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
        guard size <= 2_000_000 else { throw CoincideError("This file is too large for the editor (2 MB limit).") }
        guard let text = String(data: try Data(contentsOf: url), encoding: .utf8) else { throw CoincideError("This file is not UTF-8 text.") }
        return text
    }
    public func write(_ path: String, text: String, expectedContents: String) throws {
        let url = try resolve(path)
        guard try read(path) == expectedContents else { throw CoincideError("The file changed on disk. Reload before saving to preserve those changes.") }
        try text.write(to: url, atomically: true, encoding: .utf8)
    }
}
