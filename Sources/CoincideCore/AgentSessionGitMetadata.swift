import Foundation

/// Readonly candidate enrichment, not a repository mutation or execution grant.
/// The pinned scanner hides linked worktrees whose non-bare main checkout is
/// discoverable separately, while linked worktrees of bare repositories remain.
enum AgentSessionGitMetadata {
    struct Result { let excludedWorktree: Bool; let git: AgentSessionProjectGit? }
    static func read(_ workspace: AgentSessionDirectory) throws -> Result {
        try workspace.validate()
        let admin: AgentSessionDirectory
        var linked = false
        if let directory = try? workspace.directory(".git") { admin = directory }
        else if let marker = try? workspace.file(".git"), let pointer = try? marker.readMetadata(maximumBytes: 16_384),
                let path = capture(#"(?m)^gitdir:\s*(.+)$"#, pointer)?.trimmingCharacters(in: .whitespacesAndNewlines), !path.isEmpty {
            let resolved = URL(fileURLWithPath: path, relativeTo: URL(fileURLWithPath: workspace.path, isDirectory: true)).standardizedFileURL.resolvingSymlinksInPath().path
            linked = resolved.range(of: #"/worktrees/[^/]+/?$"#, options: .regularExpression) != nil
            guard let directory = try? AgentSessionDirectory(path: resolved) else { return .init(excludedWorktree: linked, git: nil) }
            admin = directory
        } else { return .init(excludedWorktree: false, git: nil) }
        let common: AgentSessionDirectory
        if linked {
            guard let file = try? admin.file("commondir"), let value = try? file.readMetadata(maximumBytes: 16_384),
                  !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return .init(excludedWorktree: true, git: nil) }
            let path = URL(fileURLWithPath: value.trimmingCharacters(in: .whitespacesAndNewlines), relativeTo: URL(fileURLWithPath: admin.path, isDirectory: true)).standardizedFileURL.resolvingSymlinksInPath().path
            guard let directory = try? AgentSessionDirectory(path: path) else { return .init(excludedWorktree: true, git: nil) }; common = directory
        } else { common = admin }
        let config = (try? common.file("config").readMetadata()) ?? ""
        try workspace.validate(); try admin.validate(); try common.validate()
        if linked && !isBare(config) { return .init(excludedWorktree: true, git: nil) }
        let raw = origin(config), remote = raw.flatMap(safeRemote)
        return .init(excludedWorktree: false, git: .init(remoteKey: remote?.canonicalKey,
            repository: remote?.canonicalKey.hasPrefix("github.com/") == true ? remote?.displayName : nil))
    }
    private static func safeRemote(_ raw: String) -> RepositoryIdentity.Remote? {
        if raw.contains("://") {
            guard let components = URLComponents(string: raw), components.password == nil,
                  components.query == nil, components.fragment == nil,
                  components.user == nil || components.scheme?.lowercased() == "ssh" && components.user == "git" else { return nil }
        }
        return RepositoryIdentity.normalizedRemote(raw)
    }
    private static func origin(_ text: String) -> String? {
        let joined = text.replacingOccurrences(of: #"\\\r?\n[ \t]*"#, with: "", options: .regularExpression)
        var section: String?, origin: String?, first: String?
        for raw in joined.components(separatedBy: .newlines) {
            let line = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            if let name = capture(#"(?i)^\[\s*remote\s+\"([^\"]+)\"\s*\](?:\s*[#;].*)?$"#, line) { section = name; continue }
            if let name = capture(#"(?i)^\[\s*remote\.([^\]\s]+)\s*\](?:\s*[#;].*)?$"#, line) { section = name.lowercased(); continue }
            if line.hasPrefix("[") { section = nil; continue }
            guard let section, let rawValue = capture(#"(?i)^url\s*=\s*(.*)$"#, line) else { continue }
            let value = configValue(rawValue); guard !value.isEmpty else { continue }
            if section == "origin" { origin = origin ?? value } else { first = first ?? value }
        }
        return origin ?? first
    }
    private static func isBare(_ text: String) -> Bool {
        var core = false, bare = false
        for raw in text.components(separatedBy: .newlines) {
            var line = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            if let expression = try? NSRegularExpression(pattern: #"^\[\s*([^\]]*?)\s*\](.*)$"#),
               let match = expression.firstMatch(in: line, range: NSRange(line.startIndex..., in: line)),
               let name = Range(match.range(at: 1), in: line), let rest = Range(match.range(at: 2), in: line) {
                core = line[name].lowercased() == "core"; line = String(line[rest]).trimmingCharacters(in: .whitespacesAndNewlines)
            }
            guard core else { continue }
            if line.range(of: #"(?i)^bare\s*(?:[#;].*)?$"#, options: .regularExpression) != nil { bare = true }
            else if let value = capture(#"(?i)^bare\s*=(.*)$"#, line) { bare = ["true", "yes", "on", "1"].contains(configValue(value).lowercased()) }
        }
        return bare
    }
    private static func configValue(_ raw: String) -> String {
        var result = "", quoted = false, escaped = false
        for character in raw {
            if escaped { result.append(character); escaped = false }
            else if character == "\\" { escaped = true }
            else if character == "\"" { quoted.toggle() }
            else if !quoted && (character == "#" || character == ";") { break }
            else { result.append(character) }
        }
        return result.trimmingCharacters(in: .whitespacesAndNewlines)
    }
    private static func capture(_ pattern: String, _ value: String) -> String? {
        guard let expression = try? NSRegularExpression(pattern: pattern),
              let match = expression.firstMatch(in: value, range: NSRange(value.startIndex..., in: value)),
              let range = Range(match.range(at: 1), in: value) else { return nil }; return String(value[range])
    }
}
