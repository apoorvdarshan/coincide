import CryptoKit
import Darwin
import Foundation

/// Generation 1 stores {info,parts} rows. Only native copy changes are
/// normalized; raw provider text, tool data and session settings stay transient.
enum OpenCodeV1HistoryWire {
    static let maximumMessages = 10_000
    static let maximumPages = 100
    static let maximumPageBytes = 4 * 1_024 * 1_024
    static let maximumBytes = 16 * 1_024 * 1_024
    static let maximumParts = 40_000

    struct Session: Sendable, Equatable {
        let id: String
        let projectID: String
        let workspaceID: String?
        let digest: String
        let hasRevert: Bool
        let permissions: [OpenCodeV1PermissionRule]?
    }
    struct Page: Sendable {
        let values: [JSONValue]
        let before: String?
    }

    static func json(_ response: OpenCodeHTTPResponse) throws -> JSONValue {
        let mime = response.headers["content-type"]?.split(separator: ";").first?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard response.status == 200, response.body.count <= maximumPageBytes,
              mime == "application/json" || (mime?.hasPrefix("application/") == true && mime?.hasSuffix("+json") == true),
              let value = try? JSONDecoder().decode(JSONValue.self, from: response.body) else { throw ProviderHistoryError(.invalidResponse) }
        var pending: [(JSONValue, Int)] = [(value, 0)], count = 0
        while let (item, depth) = pending.popLast() {
            count += 1
            guard depth <= 48, count <= 200_000 else { throw ProviderHistoryError(.limitExceeded) }
            if let fields = item.object { pending += fields.values.map { ($0, depth + 1) } }
            else if let items = item.array { pending += items.map { ($0, depth + 1) } }
            else if case .number(let number) = item, !number.isFinite { throw ProviderHistoryError(.invalidResponse) }
        }
        return value
    }

    static func page(_ response: OpenCodeHTTPResponse) throws -> Page {
        guard let values = try json(response).array, values.count <= 200 else { throw ProviderHistoryError(.invalidResponse) }
        let cursor = response.headers["x-next-cursor"]
        if let cursor {
            try ProviderHistoryValidation.cursor(cursor)
            guard !values.isEmpty else { throw ProviderHistoryError(.invalidResponse) }
        }
        // Link is deliberately not followed: it is not an owned URL authority.
        return .init(values: values, before: cursor)
    }

    static func session(_ response: OpenCodeHTTPResponse, id expected: String? = nil, directory: String) throws -> Session {
        let value = try json(response)
        guard let native = value["directory"].string, sameDirectory(native, directory) else { throw ProviderHistoryError(.invalidResponse) }
        let info: OpenCodeV1SessionInfo
        do { info = try OpenCodeV1Protocol.session(response, expectedID: expected, directory: native) }
        catch { throw ProviderHistoryError(.invalidResponse) }
        try identifier(info.id, prefix: "ses_")
        guard info.parentID == nil else { throw ProviderHistoryError(.invalidResponse) }
        let project = try identifier(value["projectID"])
        let workspace = try value["workspaceID"] == .null ? nil : identifier(value["workspaceID"])
        return .init(id: info.id, projectID: project, workspaceID: workspace, digest: try digest(value),
                     hasRevert: info.hasRevert, permissions: info.permissions)
    }

    static func records(_ values: [JSONValue], sessionID: String) throws -> [OpenCodeV1HistoryMessage] {
        guard values.count <= maximumMessages else { throw ProviderHistoryError(.limitExceeded) }
        var positions: [String: Int] = [:], roles: [String: MessageRole] = [:]
        var seenParts = Set<String>(), output: [OpenCodeV1HistoryMessage] = [], bytes = 0
        let known = Set(["text", "reasoning", "file", "agent", "subtask", "retry", "step-start", "step-finish", "snapshot", "patch", "compaction", "tool"])
        for (index, value) in values.enumerated() {
            guard var info = value["info"].object, let rawParts = value["parts"].array, rawParts.count <= 4_096 else {
                throw ProviderHistoryError(.invalidResponse)
            }
            bytes += try encoded(value).count
            guard bytes <= maximumBytes else { throw ProviderHistoryError(.limitExceeded) }
            let native: OpenCodeV1Message
            do { native = try OpenCodeV1Protocol.message(.object(info)) }
            catch { throw ProviderHistoryError(.invalidResponse) }
            try identifier(native.id, prefix: "msg_")
            guard native.sessionID == sessionID, positions[native.id] == nil else { throw ProviderHistoryError(.invalidResponse) }
            let role: MessageRole = native.role == "user" ? .user : .assistant
            let agent = try scalar(value["info"]["agent"])
            guard !agent.isEmpty else { throw ProviderHistoryError(.invalidResponse) }
            if role == .user {
                _ = try scalar(value["info"]["model"]["providerID"])
                _ = try scalar(value["info"]["model"]["modelID"])
                guard native.parentID == nil else { throw ProviderHistoryError(.invalidResponse) }
            } else {
                _ = try scalar(value["info"]["providerID"]); _ = try scalar(value["info"]["modelID"])
                guard let parent = native.parentID, let position = positions[parent], roles[parent] == .user, position < index else {
                    throw ProviderHistoryError(.invalidResponse)
                }
                info["parentID"] = .string("coincide-v1-history-position:\(position)")
            }
            var parts: [JSONValue] = [], partIDs: [String] = []
            var settled = role == .user || native.completed
            for part in rawParts {
                let parsed: OpenCodeV1Part
                do { parsed = try OpenCodeV1Protocol.part(part) }
                catch { throw ProviderHistoryError(.invalidResponse) }
                try identifier(parsed.id, prefix: "prt_")
                guard known.contains(parsed.type), parsed.sessionID == sessionID, parsed.messageID == native.id,
                      seenParts.insert(parsed.id).inserted, seenParts.count <= maximumParts,
                      var fields = part.object else { throw ProviderHistoryError(.invalidResponse) }
                if let tool = parsed.tool, ["pending", "running"].contains(tool.status) { settled = false }
                if parsed.type == "compaction" {
                    guard case .bool = part["auto"] else { throw ProviderHistoryError(.invalidResponse) }
                    if part["overflow"] != .null { guard case .bool = part["overflow"] else { throw ProviderHistoryError(.invalidResponse) } }
                    if part["tail_start_id"] != .null { _ = try identifier(part["tail_start_id"], prefix: "msg_") }
                }
                fields.removeValue(forKey: "id"); fields.removeValue(forKey: "messageID"); fields.removeValue(forKey: "sessionID")
                // In particular, preserve compaction.tail_start_id and nested
                // tool/attachment identities: native v1 does not rewrite them.
                parts.append(.object(fields)); partIDs.append(parsed.id)
            }
            let internalInput: Bool
            if role == .user, rawParts.count == 1, let part = rawParts.first {
                internalInput = part["type"] == .string("compaction") ||
                    (part["type"] == .string("text") && part["synthetic"] == .bool(true) && part["metadata"]["compaction_continue"] == .bool(true))
            } else { internalInput = false }
            info.removeValue(forKey: "id"); info.removeValue(forKey: "sessionID")
            output.append(try .init(id: native.id, role: role, parentID: native.parentID, partIDs: partIDs,
                contentDigest: digest(.object(["info": .object(info), "parts": .array(parts)])),
                isSettled: settled, isInternalUserInput: internalInput))
            positions[native.id] = index; roles[native.id] = role
        }
        return output
    }

    private static func scalar(_ value: JSONValue) throws -> String {
        guard let text = value.string, !text.isEmpty, text.utf8.count <= 4_096,
              !text.unicodeScalars.contains(where: { $0.value < 32 || $0.value == 127 }) else { throw ProviderHistoryError(.invalidResponse) }
        return text
    }
    static func identifier(_ value: JSONValue, prefix: String? = nil) throws -> String {
        guard let text = value.string else { throw ProviderHistoryError(.invalidResponse) }
        try identifier(text, prefix: prefix); return text
    }
    static func identifier(_ value: String, prefix: String? = nil) throws {
        try ProviderHistoryValidation.id(value)
        guard !value.contains("/"), !value.contains("\\"), prefix.map({ value.hasPrefix($0) }) ?? true else {
            throw ProviderHistoryError(.invalidResponse)
        }
    }
    static func digest(_ value: JSONValue) throws -> String {
        SHA256.hash(data: try encoded(value)).map { String(format: "%02x", $0) }.joined()
    }
    private static func encoded(_ value: JSONValue) throws -> Data {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(value)
    }
    static func sameDirectory(_ native: String, _ expected: String) -> Bool {
        guard (try? ProviderHistoryValidation.path(native)) != nil, (try? ProviderHistoryValidation.path(expected)) != nil else { return false }
        if native == expected { return true }
        var a = stat(), b = stat()
        guard native.withCString({ stat($0, &a) }) == 0, expected.withCString({ stat($0, &b) }) == 0,
              a.st_mode & S_IFMT == S_IFDIR, b.st_mode & S_IFMT == S_IFDIR else { return false }
        return a.st_dev == b.st_dev && a.st_ino == b.st_ino
    }
}
