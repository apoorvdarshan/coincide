import Foundation

/// Answers an agent's `fs/read_text_file` and `fs/write_text_file` requests, confined to the
/// session's folders. Symlinks are resolved before the containment check, so a link cannot
/// lead outside the workspace.
public struct ACPFileSystem: Sendable {
    public nonisolated static let maxFileBytes = 8 * 1024 * 1024

    /// Canonical paths of the folders the agent may read and write.
    public let roots: [String]

    public nonisolated init(roots: [URL]) {
        self.roots = roots.map { Self.realPath($0.path) ?? $0.standardizedFileURL.path }
    }

    public nonisolated func readTextFile(_ params: JSONValue) throws -> JSONValue {
        guard let requested = params["path"]?.string else { throw ACPError.invalidParams("Missing path.") }
        let path = try resolve(requested)
        let attributes = try? FileManager.default.attributesOfItem(atPath: path)
        guard let attributes else {
            throw ACPError(code: ACPError.resourceNotFound, message: "File '\(requested)' not found.")
        }
        let size = (attributes[.size] as? NSNumber)?.intValue ?? 0
        guard attributes[.type] as? FileAttributeType == .typeRegular, size <= Self.maxFileBytes,
            let data = FileManager.default.contents(atPath: path), let text = String(data: data, encoding: .utf8)
        else {
            throw ACPError.invalidParams("'\(requested)' is not a readable text file under \(Self.maxFileBytes) bytes.")
        }
        let line = params["line"]?.acpInt
        let limit = params["limit"]?.acpInt
        guard line != nil || limit != nil else { return ["content": .string(text)] }
        // ACP lines are 1-based and `limit` counts lines.
        // Split on the newline scalar: "\r\n" is a single Character, so CRLF files would read as one line.
        let lines = text.unicodeScalars.split(separator: "\n", omittingEmptySubsequences: false).map { String(Substring($0)) }
        // The numbers come from the agent; clamp so extreme values can't overflow.
        let start = min(lines.count, max(0, (line ?? 1).saturatingSubtracting(1)))
        let end = limit.map { min(lines.count, start.saturatingAdding(max(0, $0))) } ?? lines.count
        return ["content": .string(lines[start..<end].joined(separator: "\n"))]
    }

    public nonisolated func writeTextFile(_ params: JSONValue) throws -> JSONValue {
        guard let requested = params["path"]?.string, let content = params["content"]?.string else {
            throw ACPError.invalidParams("Missing path or content.")
        }
        let path = try resolve(requested)
        do {
            try FileManager.default.createDirectory(
                atPath: (path as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
            try content.write(toFile: path, atomically: true, encoding: .utf8)
        } catch {
            throw ACPError.internalError("Could not write '\(requested)'.")
        }
        return [:]
    }

    /// The canonical path for `requested`, or an error when it lies outside every root.
    nonisolated func resolve(_ requested: String) throws -> String {
        let outside = ACPError.invalidParams("Path '\(requested)' is outside the session workspace.")
        guard (requested as NSString).isAbsolutePath else {
            throw ACPError.invalidParams("Path '\(requested)' must be absolute.")
        }
        let candidate: String
        if let real = Self.realPath(requested) {
            candidate = real
        } else {
            // A missing file: canonicalize its nearest existing ancestor, never a dangling link.
            if (try? FileManager.default.destinationOfSymbolicLink(atPath: requested)) != nil { throw outside }
            var ancestor = requested
            var missing: [String] = []
            while true {
                let parent = (ancestor as NSString).deletingLastPathComponent
                missing.insert((ancestor as NSString).lastPathComponent, at: 0)
                guard parent != ancestor else { throw outside }
                ancestor = parent
                if let real = Self.realPath(ancestor) {
                    guard !missing.contains("..") else { throw outside }
                    candidate = missing.reduce(real) { ($0 as NSString).appendingPathComponent($1) }
                    break
                }
            }
        }
        let inside = roots.contains { root in
            candidate == root || candidate.hasPrefix(root.hasSuffix("/") ? root : root + "/")
        }
        guard inside else { throw outside }
        return candidate
    }

    nonisolated static func realPath(_ path: String) -> String? {
        guard let resolved = realpath(path, nil) else { return nil }
        defer { free(resolved) }
        return String(cString: resolved)
    }
}
