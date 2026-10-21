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
        guard !relativePath.hasPrefix("/"), !relativePath.contains("\0"), relativePath.utf16.count <= 4_096 else { throw CoincideError("Use a path relative to this workspace.") }
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
        let folder = try WorkspaceFileRoot(root: root); defer { folder.close() }
        return try folder.list(relativePath).entries.map { WorkspaceFile(path: $0.path, isDirectory: $0.isDirectory) }
    }
    public func read(_ path: String) throws -> String {
        let folder = try WorkspaceFileRoot(root: root); defer { folder.close() }
        let document = try folder.read(path, allowMissing: false, maxBytes: 2_000_000)
        guard !document.truncated else { throw CoincideError("This file is too large for the editor (2 MB limit).") }
        return document.contents
    }
    public func write(_ path: String, text: String, expectedContents: String) throws {
        let folder = try WorkspaceFileRoot(root: root); defer { folder.close() }
        let document = try folder.read(path, allowMissing: false, maxBytes: 2_000_000)
        guard !document.truncated, document.contents == expectedContents, let revision = document.revision else {
            throw CoincideError("The file changed on disk. Reload before saving to preserve those changes.")
        }
        _ = try folder.write(path, contents: text, expected: .matching(revision))
    }
}
