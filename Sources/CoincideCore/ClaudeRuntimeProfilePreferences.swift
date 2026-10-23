import Foundation

/// Private application preferences only. A failed decode or compare-and-swap
/// preserves the original file; callers must explicitly reload before retrying.
public actor ClaudeRuntimeProfilePreferences {
    private struct Document: Codable { let version: Int; let profile: ClaudeRuntimeProfile }
    private let documents: RemotePrivateDocumentStore
    private var loaded = false
    private var previous: Data?
    public init(root: URL) { documents = .init(root: root) }
    public func load() async throws -> ClaudeRuntimeProfile {
        let data = try await documents.load(name: "profile.json", maximum: 65_536)
        if let data {
            guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                  Set(object.keys) == ["version", "profile"],
                  let profile = object["profile"] as? [String: Any],
                  Set(profile.keys).isSubset(of: ["instanceID", "executable", "configurationDirectory", "autoCompactWindow"]),
                  Set(profile.keys).isSuperset(of: ["instanceID", "executable"]) else { throw ClaudeRuntimeProfile.invalid() }
            let decoded = try JSONDecoder().decode(Document.self, from: data)
            guard decoded.version == 1 else { throw ClaudeRuntimeProfile.invalid() }
            try decoded.profile.validate()
            previous = data; loaded = true; return decoded.profile
        }
        previous = nil; loaded = true; return .init()
    }
    public func save(_ profile: ClaudeRuntimeProfile) async throws {
        guard loaded else { throw ClaudeRuntimeProfile.invalid() }
        try profile.validate()
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(Document(version: 1, profile: profile))
        try await documents.save(data: data, name: "profile.json", maximum: 65_536, expected: previous)
        previous = data
    }
}
