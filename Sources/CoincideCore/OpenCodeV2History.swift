import CryptoKit
import Darwin
import Foundation

/// The native 2.1.2 history wire is an ordered message log, not a list of turns.
/// Raw message/error/native payloads are hashed transiently and never retained
/// in the durable evidence returned to the workspace.
enum OpenCodeV2HistoryWire {
    static let maximumMessages = 10_000
    static let maximumPages = 100
    static let maximumPageBytes = 4 * 1_024 * 1_024
    static let maximumBytes = 16 * 1_024 * 1_024

    struct Session: Sendable, Equatable {
        let stage: OpenCodeV2HistoryStage?
        let fork: OpenCodeV2HistoryFork?
    }
    struct Page: Sendable {
        let values: [JSONValue]
        let next: String?
    }

    static func json(_ response: OpenCodeHTTPResponse) throws -> JSONValue {
        guard response.status == 200, response.body.count <= maximumPageBytes else {
            throw ProviderHistoryError(.invalidResponse)
        }
        do { return try OpenCodeV2Protocol.json(response) }
        catch { throw ProviderHistoryError(.invalidResponse) }
    }

    static func page(_ response: OpenCodeHTTPResponse) throws -> Page {
        let value = try json(response)
        guard let values = value["data"].array, values.count <= 200,
              let cursor = value["cursor"].object else { throw ProviderHistoryError(.invalidResponse) }
        // Current 2.1.2 omits empty cursor fields. Recorded 2.0.18 replies
        // sometimes contain null: accepting null as absent is intentional.
        for key in ["next", "previous"] {
            if let supplied = cursor[key], supplied != .null {
                guard let text = supplied.string else { throw ProviderHistoryError(.invalidResponse) }
                try ProviderHistoryValidation.cursor(text)
            }
        }
        return .init(values: values, next: cursor["next"]?.string)
    }

    static func session(_ response: OpenCodeHTTPResponse, id: String, directory: String) throws -> Session {
        let value = try json(response)["data"]
        do {
            let native = try OpenCodeV2Bounds.directory(value["location"]["directory"])
            guard sameDirectory(native, directory) else { throw ProviderHistoryError(.invalidResponse) }
            let info = try OpenCodeV2Protocol.session(response, expectedID: id, directory: native)
            guard info.parentID == nil else { throw ProviderHistoryError(.invalidResponse) }
        } catch { throw ProviderHistoryError(.invalidResponse) }
        let stagedRevert = try value["revert"] == .null ? nil : Self.stage(value["revert"])
        let fork: OpenCodeV2HistoryFork?
        if value["fork"] == .null { fork = nil }
        else {
            let source = try messageOwner(value["fork"]["sessionID"], session: true)
            let boundaryID = try messageOwner(value["fork"]["boundary"]["messageID"])
            let boundary: ProviderHistoryBoundary
            switch value["fork"]["boundary"]["type"].string {
            case "before": boundary = .beforeMessage(boundaryID)
            case "through": boundary = .throughMessage(boundaryID)
            default: throw ProviderHistoryError(.invalidResponse)
            }
            fork = try .init(sourceSessionID: source, boundary: boundary)
        }
        return .init(stage: stagedRevert, fork: fork)
    }

    static func stage(_ value: JSONValue) throws -> OpenCodeV2HistoryStage {
        guard value.object != nil else { throw ProviderHistoryError(.invalidResponse) }
        let state: OpenCodeV2HistoryStage.FilesState
        if value["files"] == .null { state = .absent }
        else {
            guard let files = value["files"].array, files.count <= 4_096 else { throw ProviderHistoryError(.invalidResponse) }
            state = files.isEmpty ? .empty : .nonempty
        }
        return try .init(messageID: messageOwner(value["messageID"]),
            snapshot: optionalText(value["snapshot"]), partID: optionalText(value["partID"]), files: state)
    }

    static func stageResponse(_ response: OpenCodeHTTPResponse) throws -> OpenCodeV2HistoryStage {
        try stage(json(response)["data"])
    }

    static func records(_ values: [JSONValue]) throws -> [OpenCodeV2HistoryMessage] {
        guard values.count <= maximumMessages else { throw ProviderHistoryError(.limitExceeded) }
        var positions: [String: Int] = [:]
        var result: [OpenCodeV2HistoryMessage] = []
        var bytes = 0
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        for (index, value) in values.enumerated() {
            guard var normalized = value.object,
                  let rawKind = value["type"].string,
                  let kind = OpenCodeV2HistoryMessageKind(rawValue: rawKind),
                  case .number(let created) = value["time"]["created"], created.isFinite else {
                throw ProviderHistoryError(.invalidResponse)
            }
            let id = try messageOwner(value["id"])
            guard positions[id] == nil else { throw ProviderHistoryError(.invalidResponse) }
            if value["metadata"] != .null, value["metadata"].object == nil { throw ProviderHistoryError(.invalidResponse) }
            bytes += try encoder.encode(value).count
            guard bytes <= maximumBytes else { throw ProviderHistoryError(.limitExceeded) }
            let settled: Bool
            let outcome: String?
            switch rawKind {
            case "assistant":
                try text(value["agent"]); try model(value["model"])
                guard let content = value["content"].array, content.count <= 4_096 else { throw ProviderHistoryError(.invalidResponse) }
                if value["time"]["completed"] == .null { settled = false }
                else {
                    guard case .number(let completed) = value["time"]["completed"], completed.isFinite else { throw ProviderHistoryError(.invalidResponse) }
                    settled = true
                }
                outcome = nil
            case "shell":
                try text(value["shellID"]); try text(value["command"], empty: true)
                guard let status = value["status"].string, ["running", "exited", "timeout", "killed"].contains(status) else {
                    throw ProviderHistoryError(.invalidResponse)
                }
                settled = status != "running"; outcome = nil
            case "compaction":
                guard let status = value["status"].string, ["running", "completed", "failed"].contains(status) else {
                    throw ProviderHistoryError(.invalidResponse)
                }
                settled = status != "running"; outcome = nil
                guard ["auto", "manual"].contains(value["reason"].string ?? "") else { throw ProviderHistoryError(.invalidResponse) }
                if status != "failed" { try text(value["summary"], empty: true) }
                if let keepID = value["metadata"]["keepID"].string {
                    // Native forks regenerate IDs and rewrite only this one
                    // message reference. Resolve it against the same ordered
                    // inventory; never erase arbitrary metadata or native data.
                    guard let position = positions[keepID], position < index,
                          var metadata = value["metadata"].object else { throw ProviderHistoryError(.invalidResponse) }
                    metadata["keepID"] = .string("coincide-history-position:\(position)")
                    normalized["metadata"] = .object(metadata)
                }
            case "idle":
                guard let idle = value["outcome"].string, ["succeeded", "failed", "interrupted"].contains(idle) else {
                    throw ProviderHistoryError(.invalidResponse)
                }
                settled = true; outcome = idle
            case "user", "synthetic", "system":
                try text(value["text"], empty: true); settled = true; outcome = nil
            case "skill":
                try text(value["text"], empty: true); try text(value["skill"]); try text(value["name"])
                settled = true; outcome = nil
            case "agent-switched":
                try text(value["agent"]); settled = true; outcome = nil
            case "model-switched":
                try model(value["model"]); settled = true; outcome = nil
            case "location-switched":
                guard let directory = value["location"]["directory"].string else { throw ProviderHistoryError(.invalidResponse) }
                try ProviderHistoryValidation.path(directory); settled = true; outcome = nil
            default: throw ProviderHistoryError(.invalidResponse)
            }
            normalized.removeValue(forKey: "id")
            let digest = SHA256.hash(data: try encoder.encode(JSONValue.object(normalized))).map { String(format: "%02x", $0) }.joined()
            result.append(try .init(id: id, kind: kind, contentDigest: digest, isSettled: settled, idleOutcome: outcome))
            positions[id] = index
        }
        return result
    }

    static func messageOwner(_ value: JSONValue, session: Bool = false) throws -> String {
        do {
            let id = try (session ? OpenCodeV2Bounds.sessionID(value) : OpenCodeV2Bounds.messageID(value))
            try ProviderHistoryValidation.id(id)
            return id
        } catch { throw ProviderHistoryError(.invalidResponse) }
    }
    private static func optionalText(_ value: JSONValue) throws -> String? {
        guard value != .null else { return nil }
        guard let text = value.string else { throw ProviderHistoryError(.invalidResponse) }
        try ProviderHistoryValidation.id(text); return text
    }
    private static func text(_ value: JSONValue, empty: Bool = false) throws {
        guard let text = value.string, empty || !text.isEmpty, text.utf8.count <= maximumPageBytes else {
            throw ProviderHistoryError(.invalidResponse)
        }
    }
    private static func model(_ value: JSONValue) throws {
        try text(value["providerID"]); try text(value["id"])
    }
    private static func sameDirectory(_ native: String, _ expected: String) -> Bool {
        guard (try? ProviderHistoryValidation.path(native)) != nil, (try? ProviderHistoryValidation.path(expected)) != nil else { return false }
        if native == expected { return true }
        // A different spelling is accepted only when both existing directory
        // identities agree. Text suffixes and unresolved aliases prove nothing.
        var source = stat(), target = stat()
        guard native.withCString({ stat($0, &source) }) == 0, expected.withCString({ stat($0, &target) }) == 0,
              source.st_mode & S_IFMT == S_IFDIR, target.st_mode & S_IFMT == S_IFDIR else { return false }
        return source.st_dev == target.st_dev && source.st_ino == target.st_ino
    }
}
