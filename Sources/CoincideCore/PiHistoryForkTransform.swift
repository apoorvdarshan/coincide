import Foundation

/// Exact v0.80.5 SessionManager fork semantics. This is a pure comparison of
/// observed graphs; the native owner supplies quietness, paths and durable
/// candidate admission. No file is created, opened or repaired here.
public struct PiHistoryForkTransform: Sendable, Equatable {
    public enum Mode: String, Codable, Sendable, Equatable { case cliFork, branched, fresh }
    public let mode: Mode
    public let retainedEntries: [PiHistoryEntryDescriptor]
    public let retainedUserEntryIDs: [String]
    public let semanticDigest: String
    /// Branched/fresh sessions without an assistant can have an observed native
    /// path while no file exists yet. A missing file never proves this graph.
    public let requiresPersistedFile: Bool
    private let sourceSessionID: String
    private let labels: [Label]
    private struct Label: Sendable, Equatable {
        let targetID: String
        let payloadDigest: String
    }

    public init(source: PiHistoryGraph, mode: Mode, retainedLeafID: String?) throws {
        self.mode = mode
        sourceSessionID = source.header.sessionID
        let retained: [PiHistoryEntry]
        var expectedLabels: [Label] = []
        switch mode {
        case .cliFork:
            // forkFrom copies every non-header row, then reopens its new file.
            // It cannot preserve a different, unpersisted live branch pointer.
            guard retainedLeafID == source.leafID, source.leafID == source.entries.last?.id else {
                throw PiHistoryGraphError(.invalidWindow)
            }
            retained = source.entries
            requiresPersistedFile = true
        case .fresh:
            guard retainedLeafID == nil else { throw PiHistoryGraphError(.invalidWindow) }
            retained = []
            requiresPersistedFile = false
        case .branched:
            guard let retainedLeafID else { throw PiHistoryGraphError(.invalidWindow) }
            let path = try source.branch(through: retainedLeafID)
            var rows: [PiHistoryEntry] = [], parent: String?
            for entry in path where entry.kind != .label {
                guard var object = entry.raw.object else { throw PiHistoryGraphError(.invalidEntry) }
                object["parentId"] = parent.map(JSONValue.string) ?? .null
                rows.append(try PiHistoryEntry(raw: .object(object)))
                parent = entry.id
            }
            retained = rows
            requiresPersistedFile = rows.contains { $0.kind == .message && $0.raw["message"]["role"] == .string("assistant") }

            // _buildIndex processes the complete append inventory. Map.set on
            // replacement retains order; clear deletes it, and re-add appends.
            // Labels on another branch can therefore affect a retained target.
            var values: [String: (insertion: Int, entry: PiHistoryEntry)] = [:]
            for (position, entry) in source.entries.enumerated() where entry.kind == .label {
                guard let target = entry.raw["targetId"].string else { throw PiHistoryGraphError(.invalidEntry) }
                if let text = entry.raw["label"].string, !text.isEmpty {
                    values[target] = (values[target]?.insertion ?? position, entry)
                } else {
                    values.removeValue(forKey: target)
                }
            }
            let retainedIDs = Set(rows.map(\.id))
            for (target, value) in values.sorted(by: { $0.value.insertion < $1.value.insertion }) where retainedIDs.contains(target) {
                expectedLabels.append(.init(targetID: target, payloadDigest: try Self.labelDigest(value.entry.raw)))
            }
        }
        retainedEntries = retained.map(PiHistoryEntryDescriptor.init)
        retainedUserEntryIDs = retained.filter(\.isUserMessage).map(\.id)
        labels = expectedLabels
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        let descriptors = try JSONDecoder().decode(JSONValue.self, from: encoder.encode(retainedEntries))
        semanticDigest = try PiHistoryValidation.digest(.object([
            "mode": .string(mode.rawValue), "entries": descriptors,
            "labels": .array(expectedLabels.map { .object(["targetId": .string($0.targetID), "payloadDigest": .string($0.payloadDigest)]) })
        ]))
    }

    /// New header identity/timestamp and generated label IDs are the only
    /// nondeterministic values. Every other native payload field remains exact.
    public func validate(candidate: PiHistoryGraph, expectedWorkspacePath: String, expectedParentSessionPath: String) throws {
        try PiHistoryValidation.absolutePath(expectedWorkspacePath)
        try PiHistoryValidation.absolutePath(expectedParentSessionPath)
        let header = candidate.header
        guard header.sessionID != sourceSessionID,
              header.workspacePath == expectedWorkspacePath,
              header.parentSessionPath == expectedParentSessionPath,
              Set(header.raw.object?.keys.map { $0 } ?? []) == Set(["type", "version", "id", "timestamp", "cwd", "parentSession"]),
              candidate.entries.count == retainedEntries.count + labels.count,
              Array(candidate.entries.prefix(retainedEntries.count)).map(PiHistoryEntryDescriptor.init) == retainedEntries,
              candidate.leafID == candidate.entries.last?.id else { throw PiHistoryGraphError(.invalidWindow) }
        var parent = retainedEntries.last?.id
        for (entry, label) in zip(candidate.entries.dropFirst(retainedEntries.count), labels) {
            guard entry.kind == .label, entry.parentID == parent, entry.raw["targetId"] == .string(label.targetID),
                  Set(entry.raw.object?.keys.map { $0 } ?? []) == Set(["type", "id", "parentId", "timestamp", "targetId", "label"]),
                  try Self.labelDigest(entry.raw) == label.payloadDigest else { throw PiHistoryGraphError(.invalidWindow) }
            parent = entry.id
        }
    }

    private static func labelDigest(_ raw: JSONValue) throws -> String {
        try PiHistoryValidation.digest(.object(["type": .string("label"), "targetId": raw["targetId"],
            "timestamp": raw["timestamp"], "label": raw["label"]]))
    }
}
