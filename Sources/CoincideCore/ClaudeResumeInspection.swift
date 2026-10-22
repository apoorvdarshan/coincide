import Foundation

/// Read-only recovery, used only after the exact owning process and metadata
/// jobs have drained. It neither launches Claude nor retries a native input.
public enum ClaudeResumeInspection: String, Codable, Sendable, Equatable {
    case consumed, notConsumed

    public static func inspect(configuration: ClaudeRuntimeConfiguration, selection: ClaudeResumeSelection,
                               run: ThreadRunRecord) throws -> Self {
        try configuration.validate(); try selection.validate(runtime: configuration)
        guard run.origin == .user, run.configuration.provider == .claude,
              run.configuration.claudeRuntimeConfiguration == configuration,
              run.configuration.claudeLaunchSelection == selection,
              let evidence = run.claude, evidence.runID == run.id,
              evidence.runtimeIdentity == configuration.runtimeIdentity,
              evidence.openingInputID == ClaudeInputIdentity.opening(runID: run.id),
              evidence.nativeSessionID == nil || evidence.nativeSessionID == selection.nativeSessionID else { throw uncertain() }
        try evidence.validate()
        let store = try ClaudeTranscriptStore(configurationDirectory: URL(fileURLWithPath: configuration.configurationDirectory),
            workspace: URL(fileURLWithPath: configuration.workspacePath), projectDirectoryName: configuration.projectDirectoryName)
        let source: ClaudeTranscriptSnapshot
        do { source = try store.read(sessionID: selection.nativeSessionID) }
        catch let error as ClaudeTranscriptStoreError where error.kind == .notFound && selection.kind == .freshSession {
            return .notConsumed
        }
        switch selection.kind {
        case .resumeAt:
            guard source.location == selection.reviewedLocation else { throw uncertain() }
            if source.revision == selection.reviewedRevision { return .notConsumed }
        case .freshSession: break
        }
        // Reader-synthesized queued UUIDs are deliberately insufficient. The
        // prospective owner must be an actual root user record on this chain.
        let chain = source.transcript.selectedChainRecords
        guard let opening = chain.first(where: { $0["uuid"].string == evidence.openingInputID }),
              let original = source.transcript.records.first(where: { $0["uuid"].string == evidence.openingInputID }),
              original["type"].string == "user", opening["type"].string == "user",
              original["sessionId"].string == selection.nativeSessionID, root(original), root(opening),
              original["isCompactSummary"] == .null || original["isCompactSummary"] == .bool(false),
              original["is_meta"] == .null || original["is_meta"] == .bool(false),
              original["isCompletedLocalCommand"] == .null || original["isCompletedLocalCommand"] == .bool(false),
              original["message"]["role"].string == "user",
              original["message"]["content"].array?.contains(where: { $0["type"].string == "tool_result" }) != true else { throw uncertain() }
        switch selection.kind {
        case .freshSession:
            guard original.object?["parentUuid"] == .null, opening.object?["parentUuid"] == .null else { throw uncertain() }
        case .resumeAt:
            guard let cursor = selection.cursor,
                  let boundary = chain.first(where: { $0["uuid"].string == cursor }),
                  boundary["type"].string == "assistant", root(boundary) else { throw uncertain() }
            // Require the literal native parent graph as well as selected-chain
            // membership. Compaction repairs cannot manufacture consumption.
            let byID = Dictionary(uniqueKeysWithValues: source.transcript.records.compactMap { value -> (String, JSONValue)? in
                value["uuid"].string.map { ($0, value) }
            })
            var next = original["parentUuid"].string, visited = Set<String>()
            while let id = next, id != cursor {
                guard visited.insert(id).inserted, visited.count <= ClaudeTranscript.maximumRecords,
                      let ancestor = byID[id], ancestor["type"].string != "user", ancestor["type"].string != "assistant",
                      ancestor["isSidechain"] != .bool(true) else { throw uncertain() }
                next = ancestor["parentUuid"].string
            }
            guard next == cursor else { throw uncertain() }
        }
        return .consumed
    }

    private static func root(_ record: JSONValue) -> Bool {
        (record["isSidechain"] == .null || record["isSidechain"] == .bool(false)) &&
            (record["isMeta"] == .null || record["isMeta"] == .bool(false)) &&
            (record["teamName"] == .null || record["teamName"].string == "") &&
            record["parent_tool_use_id"] == .null && record["parent_agent_id"] == .null
    }

    private static func uncertain() -> CoincideError {
        .init("The deferred Claude input could not be confirmed from its exact native transcript. It was not sent again.")
    }
}
