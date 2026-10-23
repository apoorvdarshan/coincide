import CoincideCore
import CryptoKit
import Foundation
import Observation

struct RemotePullRequestDraftFields: Codable, Sendable {
    var title = ""
    var body = ""
    var baseBranch = ""
    var isDraft = false
    var hasText: Bool { !title.isEmpty || !body.isEmpty || !baseBranch.isEmpty || isDraft }
    func matches(_ other: Self) -> Bool {
        title.utf8.elementsEqual(other.title.utf8) && body.utf8.elementsEqual(other.body.utf8) &&
            baseBranch.utf8.elementsEqual(other.baseBranch.utf8) && isDraft == other.isDraft
    }
    func validate() throws {
        guard title.utf8.count <= 4_096, body.utf8.count <= 1_048_576, baseBranch.utf8.count <= 1_024,
              !title.contains("\0"), !body.contains("\0"), !baseBranch.contains("\0") else { throw GitHubPullRequestError(.invalidRequest) }
    }
}

@MainActor @Observable
final class RemotePullRequestCreateDraft {
    private var value: RemotePullRequestDraftFields
    var title: String { get { value.title } set { guard acceptingEdits else { return }; value.title = newValue; edited?() } }
    var body: String { get { value.body } set { guard acceptingEdits else { return }; value.body = newValue; edited?() } }
    var baseBranch: String { get { value.baseBranch } set { guard acceptingEdits else { return }; value.baseBranch = newValue; edited?() } }
    var isDraft: Bool { get { value.isDraft } set { guard acceptingEdits else { return }; value.isDraft = newValue; edited?() } }
    var acceptingEdits = true
    @ObservationIgnored var edited: (@MainActor () -> Void)?
    init(_ fields: RemotePullRequestDraftFields = .init()) {
        value = fields
    }
    var fields: RemotePullRequestDraftFields { value }
}

/// Draft scopes use exact remote path bytes solely as an identity. All files
/// this actor opens belong to the application's private local document store.
actor RemotePullRequestDraftPersistence {
    private struct Document: Codable {
        let version: Int
        let environmentID: UUID, projectID: UUID, threadID: UUID
        let workspacePath: String
        let fields: RemotePullRequestDraftFields
    }
    private struct Raw { let bytes: Data? }
    private let documents: RemotePrivateDocumentStore
    private var cached: [String: Raw] = [:]
    private let maximum = 8 * 1_024 * 1_024
    init(root: URL) { documents = .init(root: root) }
    func load(target: RemoteWorkspaceTarget) async throws -> RemotePullRequestDraftFields {
        let name = Self.name(target), bytes = try await documents.load(name: Self.name(target), maximum: maximum)
        let fields: RemotePullRequestDraftFields
        if let bytes {
            let value = try JSONDecoder().decode(Document.self, from: bytes)
            guard value.version == 1, value.environmentID == target.environmentID, value.projectID == target.projectID,
                  value.threadID == target.threadID, value.workspacePath.utf8.elementsEqual(target.workspacePath.utf8) else { throw RemoteEnvironmentStorageError(.corruptFile) }
            try value.fields.validate(); fields = value.fields
        } else { fields = .init() }
        cached[name] = .init(bytes: bytes); return fields
    }
    func save(target: RemoteWorkspaceTarget, fields: RemotePullRequestDraftFields) async throws {
        let name = Self.name(target)
        if cached[name] == nil { _ = try await load(target: target) }
        try fields.validate()
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(Document(version: 1, environmentID: target.environmentID, projectID: target.projectID,
            threadID: target.threadID, workspacePath: target.workspacePath, fields: fields))
        try await documents.save(data: data, name: name, maximum: maximum, expected: cached[name]?.bytes)
        cached[name] = .init(bytes: data)
    }
    private static func name(_ target: RemoteWorkspaceTarget) -> String {
        let digest = SHA256.hash(data: Data(target.workspacePath.utf8)).map { String(format: "%02x", $0) }.joined()
        return "pr-" + target.environmentID.uuidString.lowercased() + "-" + target.threadID.uuidString.lowercased() + "-" + digest + ".json"
    }
}
