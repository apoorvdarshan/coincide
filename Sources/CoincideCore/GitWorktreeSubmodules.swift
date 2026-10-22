import Foundation

/// Git's recursive children are not direct user-provided URLs. Standard protocols
/// must be allowed both by effective Git configuration and any inherited allowlist.
/// Local file transport therefore requires an explicit `always` configuration.
enum GitWorktreeSubmodulePolicy {
    static let protocols = ["http", "https", "ssh", "git", "file"]
    static func allowlist(configuration: Data, inherited: String?) throws -> String {
        guard let text = String(data: configuration, encoding: .utf8) else { throw GitWorktreeError(.commandFailed, "Git transport policy could not be read safely.") }
        var values: [String: String] = [:]
        for record in text.split(separator: "\0", omittingEmptySubsequences: true) {
            guard let newline = record.firstIndex(of: "\n") else { throw GitWorktreeError(.commandFailed, "Git transport policy could not be read safely.") }
            let key = record[..<newline].lowercased(), value = String(record[record.index(after: newline)...]).trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            guard key == "protocol.allow" || protocols.contains(where: { key == "protocol." + $0 + ".allow" }) else { continue }
            guard ["always", "never", "user"].contains(value) else { throw GitWorktreeError(.commandFailed, "Git transport policy is unsupported.") }
            values[key] = value
        }
        let inheritedSet = inherited.map { Set($0.split(separator: ":").map(String.init)) }
        return protocols.filter { name in
            let policy = values["protocol." + name + ".allow"] ?? values["protocol.allow"] ?? (name == "file" ? "user" : "always")
            return policy == "always" && (inheritedSet?.contains(name) ?? true)
        }.joined(separator: ":")
    }
}
