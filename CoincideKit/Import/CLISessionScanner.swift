import Foundation

public struct CLISessionCandidate: Identifiable, Hashable, Sendable {
    public var id: URL { url }
    public let url: URL
    public let provider: ProviderKind
    public let title: String
    public let directory: String
    public let modifiedAt: Date
}

public struct CLISessionScan: Sendable {
    public let candidates: [CLISessionCandidate]
    public let incomplete: Bool
}

/// Discovers files only in the CLI history roots. It never imports, writes, or follows directory symlinks.
public enum CLISessionScanner {
    public static func defaultRoots(environment: [String: String] = ProcessInfo.processInfo.environment,
        home: URL = FileManager.default.homeDirectoryForCurrentUser) -> [ProviderKind: [URL]] {
        let claude = environment["CLAUDE_CONFIG_DIR"].map { URL(fileURLWithPath: $0) } ?? home.appendingPathComponent(".claude")
        let codex = environment["CODEX_HOME"].map { URL(fileURLWithPath: $0) } ?? home.appendingPathComponent(".codex")
        return [.claude: [claude.appendingPathComponent("projects")],
            .codex: [codex.appendingPathComponent("sessions"), codex.appendingPathComponent("archived_sessions")]]
    }

    public static func scan(roots: [ProviderKind: [URL]], limit: Int = 2_000) throws -> CLISessionScan {
        let manager = FileManager.default
        let keys: [URLResourceKey] = [.isDirectoryKey, .isSymbolicLinkKey, .isRegularFileKey, .contentModificationDateKey]
        var found: [(URL, ProviderKind, Date)] = []
        var incomplete = false
        var visited = 0
        // A bounded walk also protects against unexpectedly large/custom CLI roots.
        for provider in [ProviderKind.claude, .codex] {
            for root in roots[provider] ?? [] {
                guard manager.fileExists(atPath: root.path) else { continue }
                guard (try? root.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) != true else { incomplete = true; continue }
                guard let enumerator = manager.enumerator(at: root, includingPropertiesForKeys: keys,
                    options: [.skipsHiddenFiles], errorHandler: { _, _ in incomplete = true; return true }) else { incomplete = true; continue }
                for case let url as URL in enumerator {
                    try Task.checkCancellation()
                    visited += 1
                    if visited > 20_000 { incomplete = true; break }
                    guard let value = try? url.resourceValues(forKeys: Set(keys)) else { incomplete = true; continue }
                    if value.isSymbolicLink == true || url.lastPathComponent == "subagents" {
                        enumerator.skipDescendants()
                        continue
                    }
                    guard value.isRegularFile == true, url.pathExtension == "jsonl" else { continue }
                    found.append((url, provider, value.contentModificationDate ?? .distantPast))
                }
                if visited > 20_000 { break }
            }
        }
        found.sort { $0.2 > $1.2 }
        if found.count > max(limit, 0) { incomplete = true }
        var candidates: [CLISessionCandidate] = []
        for (url, provider, modified) in found.prefix(max(limit, 0)) {
            try Task.checkCancellation()
            do {
                let handle = try FileHandle(forReadingFrom: url)
                defer { try? handle.close() }
                let data = try handle.read(upToCount: 128 * 1_024) ?? Data()
                var title: String?
                var directory = ""
                for line in data.split(separator: 10).prefix(100) {
                    guard let record = try? JSONSerialization.jsonObject(with: Data(line)) as? [String: Any] else { continue }
                    if provider == .claude {
                        directory = record["cwd"] as? String ?? directory
                        title = record["aiTitle"] as? String ?? title
                        if title == nil, record["type"] as? String == "user", record["isMeta"] as? Bool != true,
                            let message = record["message"] as? [String: Any] {
                            title = prompt(message["content"])
                        }
                    } else if let payload = record["payload"] as? [String: Any] {
                        if record["type"] as? String == "session_meta" { directory = payload["cwd"] as? String ?? directory }
                        if title == nil, record["type"] as? String == "response_item", payload["role"] as? String == "user" {
                            title = prompt(payload["content"])
                        }
                    }
                }
                candidates.append(CLISessionCandidate(url: url, provider: provider,
                    title: String((title ?? url.deletingPathExtension().lastPathComponent).prefix(100)),
                    directory: directory, modifiedAt: modified))
            } catch { incomplete = true }
        }
        return CLISessionScan(candidates: candidates, incomplete: incomplete)
    }

    private static func prompt(_ content: Any?) -> String? {
        let value = content as? String ?? (content as? [[String: Any]])?.compactMap { $0["text"] as? String }.joined(separator: "\n")
        guard let value, !value.isEmpty else { return nil }
        return value.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
