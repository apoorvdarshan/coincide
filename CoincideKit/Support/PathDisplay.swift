import Foundation

/// Shows paths under a working directory relative to it, as the transcript's tool titles do. Agents
/// report the folder as given or with symlinks resolved (`/tmp` spelled `/private/tmp`), so all of
/// those spellings count.
public struct PathDisplay: Sendable, Hashable {
    /// The working directory as given and as agents may report it.
    public let roots: [String]

    public nonisolated init(workingDirectory: String) {
        let base =
            workingDirectory.count > 1 && workingDirectory.hasSuffix("/")
            ? String(workingDirectory.dropLast()) : workingDirectory
        var roots = [base]
        if let resolved = realpath(base, nil) {
            roots.append(String(cString: resolved))
            free(resolved)
        }
        for alias in ["/tmp", "/var", "/etc"] {
            if base == alias || base.hasPrefix(alias + "/") {
                roots.append("/private" + base)
            } else if base == "/private" + alias || base.hasPrefix("/private" + alias + "/") {
                roots.append(String(base.dropFirst("/private".count)))
            }
        }
        self.roots = roots.reduce(into: []) { unique, root in
            if !unique.contains(root) { unique.append(root) }
        }
    }

    /// The path relative to the working directory (`.` for the directory itself), or unchanged when it
    /// lies elsewhere.
    public nonisolated func relative(_ path: String) -> String {
        for root in roots where !root.isEmpty {
            if path == root { return "." }
            let prefix = root.hasSuffix("/") ? root : root + "/"
            if path.hasPrefix(prefix) { return String(path.dropFirst(prefix.count)) }
        }
        return path
    }
}
