import Foundation

/// A bounded, immutable preview. The original bytes are archived only after the user chooses Import.
public struct CLISessionPreview: Sendable {
    public let sourceURL: URL
    public let sourceData: Data
    public let provider: ProviderKind
    public let sessionID: String
    public let directory: URL
    public let title: String
    public let modelID: String
    public let branch: String?
    public let items: [TranscriptItem]
    public let createdAt: Date
    public let updatedAt: Date
    public let omittedRecords: Int
    public let shortenedText: Bool
}

public enum CLISessionImportError: Error, LocalizedError {
    case tooLarge, invalid, identity, noMessages, changed

    public var errorDescription: String? {
        switch self {
        case .tooLarge: String(localized: "This session exceeds the import limits (32 MB per file, 4 MB per record, or 100,000 records).")
        case .invalid: String(localized: "Choose a Claude Code session or Codex rollout JSONL file.")
        case .identity: String(localized: "The session must have one valid session ID and an absolute working directory.")
        case .noMessages: String(localized: "This session has no supported conversation messages to import.")
        case .changed: String(localized: "The session changed after the preview. Select it again to refresh before importing.")
        }
    }
}

public enum CLISessionImport {
    public static let maximumBytes = 32 * 1_024 * 1_024
    static let maximumRecordBytes = 4 * 1_024 * 1_024
    static let maximumRecords = 100_000
    static let maximumText = 100_000

    /// Streaming reads enforce the limit even if a running CLI keeps growing the file.
    public static func read(_ url: URL) throws -> Data {
        let values = try url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey])
        guard values.isRegularFile == true, values.isSymbolicLink != true else { throw CLISessionImportError.invalid }
        guard (values.fileSize ?? 0) <= maximumBytes else { throw CLISessionImportError.tooLarge }
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var data = Data()
        while let chunk = try handle.read(upToCount: 64 * 1_024), !chunk.isEmpty {
            try Task.checkCancellation()
            guard data.count + chunk.count <= maximumBytes else { throw CLISessionImportError.tooLarge }
            data.append(chunk)
        }
        return data
    }

    public static func preview(_ url: URL) throws -> CLISessionPreview {
        try parse(read(url), sourceURL: url)
    }

    public static func parse(_ data: Data, sourceURL: URL) throws -> CLISessionPreview {
        guard data.count <= maximumBytes else { throw CLISessionImportError.tooLarge }
        var records: [[String: Any]] = []
        var omitted = 0
        var count = 0
        var start = data.startIndex
        while start < data.endIndex {
            try Task.checkCancellation()
            count += 1
            guard count <= maximumRecords else { throw CLISessionImportError.tooLarge }
            let end = data[start...].firstIndex(of: 10) ?? data.endIndex
            let line = data[start..<end]
            start = end == data.endIndex ? end : data.index(after: end)
            guard line.count <= maximumRecordBytes else { throw CLISessionImportError.tooLarge }
            if line.allSatisfy({ $0 == 13 || $0 == 32 || $0 == 9 }) { continue }
            guard let record = try? JSONSerialization.jsonObject(with: Data(line)) as? [String: Any] else {
                omitted += 1
                continue
            }
            records.append(record)
        }
        let codex = records.contains { $0["type"] as? String == "session_meta" }
        let claude = records.contains { $0["sessionId"] is String && $0["cwd"] is String }
        guard codex != claude else { throw CLISessionImportError.invalid }
        var parser = Parser(provider: codex ? .codex : .claude, omitted: omitted)
        try parser.consume(records)
        guard parser.sessionIDs.count == 1, let sessionID = parser.sessionIDs.first,
            UUID(uuidString: sessionID) != nil, let cwd = parser.cwd, cwd.hasPrefix("/"), !cwd.contains("\0")
        else { throw CLISessionImportError.identity }
        guard parser.items.contains(where: { $0.kind == .user || $0.kind == .assistant }) else {
            throw CLISessionImportError.noMessages
        }
        let firstPrompt = parser.items.first { $0.kind == .user }?.text
        let title = (parser.title ?? firstPrompt ?? parser.provider.displayName).trimmingCharacters(in: .whitespacesAndNewlines)
        return CLISessionPreview(
            sourceURL: sourceURL, sourceData: data, provider: parser.provider, sessionID: sessionID,
            directory: URL(fileURLWithPath: cwd).standardizedFileURL,
            title: String(title.prefix(100)), modelID: parser.model ?? "default", branch: parser.branch,
            items: parser.items, createdAt: parser.firstDate ?? .distantPast,
            updatedAt: parser.lastDate ?? parser.firstDate ?? .distantPast,
            omittedRecords: parser.omitted, shortenedText: parser.shortened)
    }

    private struct Parser {
        let provider: ProviderKind
        var omitted: Int
        var shortened = false
        var sessionIDs: Set<String> = []
        var cwd: String?
        var title: String?
        var model: String?
        var branch: String?
        var firstDate: Date?
        var lastDate: Date?
        var items: [TranscriptItem] = []
        var tools: [String: Int] = [:]
        let dates = ISO8601DateFormatter()
        let fractions: ISO8601DateFormatter = {
            let value = ISO8601DateFormatter()
            value.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            return value
        }()

        mutating func consume(_ records: [[String: Any]]) throws {
            if provider == .claude { try claude(records) } else { try codex(records) }
        }

        mutating func time(_ value: Any?) -> Date {
            let parsed = (value as? String).flatMap { fractions.date(from: $0) ?? dates.date(from: $0) }
            let date = parsed ?? lastDate ?? .distantPast
            if let parsed {
                firstDate = min(firstDate ?? parsed, parsed)
                lastDate = max(lastDate ?? parsed, parsed)
            }
            return date
        }

        mutating func text(_ value: String) -> String {
            guard value.count > maximumText else { return value }
            shortened = true
            return String(value.prefix(maximumText)) + "\n…"
        }

        mutating func append(_ kind: TranscriptItem.Kind, _ value: String, at date: Date, externalID: String? = nil) {
            guard !value.isEmpty else { return }
            items.append(TranscriptItem(kind: kind, text: text(value), provider: provider, modelID: model,
                externalID: externalID, createdAt: date, completedAt: date))
        }

        mutating func call(_ id: String?, name: String?, input: Any?, at date: Date) {
            guard let id, tools[id] == nil else { return }
            let detail = text(render(input))
            tools[id] = items.count
            items.append(TranscriptItem(kind: .tool, text: String(localized: "No result was recorded in this session."), title: name ?? "tool", detail: detail,
                status: .failed, provider: provider, modelID: model, externalID: id, createdAt: date, completedAt: date))
        }

        mutating func result(_ id: String?, output: Any?, failed: Bool, at date: Date) {
            let value = text(render(output))
            if let id, let index = tools[id], items.indices.contains(index) {
                items[index].text = value
                items[index].status = failed ? .failed : .completed
                items[index].completedAt = date
            } else {
                append(.notice, value, at: date, externalID: id)
            }
        }

        func render(_ value: Any?) -> String {
            if let text = value as? String { return text }
            if let blocks = value as? [[String: Any]] {
                return blocks.compactMap { $0["text"] as? String }.joined(separator: "\n")
            }
            guard let value, JSONSerialization.isValidJSONObject(value),
                let data = try? JSONSerialization.data(withJSONObject: value, options: [.sortedKeys]),
                let string = String(data: data, encoding: .utf8) else { return "" }
            return string
        }

        mutating func claude(_ records: [[String: Any]]) throws {
            let main = records.filter { $0["isSidechain"] as? Bool != true }
            var parents: [String: String] = [:]
            var positions: [String: Int] = [:]
            var leaf: String?
            for (index, record) in main.enumerated() {
                if let id = record["sessionId"] as? String { sessionIDs.insert(id.lowercased()) }
                if let value = record["cwd"] as? String { cwd = value }
                if let value = record["gitBranch"] as? String, !value.isEmpty { branch = value }
                if let value = record["aiTitle"] as? String { title = value }
                if let id = record["uuid"] as? String {
                    positions[id] = index
                    if record["message"] != nil { leaf = id }
                    if let parent = record["parentUuid"] as? String { parents[id] = parent }
                }
            }
            // Claude appends forks to one file. Import the latest main conversation's ancestry.
            var ancestry: Set<String> = []
            if let leaf, !parents.isEmpty {
                var next: String? = leaf
                while let id = next, positions[id] != nil {
                    guard ancestry.insert(id).inserted else { throw CLISessionImportError.invalid }
                    next = parents[id]
                }
            }
            for (index, record) in main.enumerated() {
                try Task.checkCancellation()
                let date = time(record["timestamp"])
                guard let message = record["message"] as? [String: Any] else { continue }
                if let id = record["uuid"] as? String {
                    guard positions[id] == index, ancestry.isEmpty || ancestry.contains(id) else { omitted += 1; continue }
                }
                guard record["isMeta"] as? Bool != true else { omitted += 1; continue }
                let role = message["role"] as? String ?? record["type"] as? String
                guard role == "user" || role == "assistant" else { omitted += 1; continue }
                if let value = message["model"] as? String, value != "<synthetic>" { model = value }
                if let value = message["content"] as? String {
                    append(role == "user" ? .user : .assistant, value, at: date, externalID: record["uuid"] as? String)
                    continue
                }
                guard let blocks = message["content"] as? [[String: Any]] else { omitted += 1; continue }
                var prose: [String] = []
                func flush(_ parser: inout Parser) {
                    parser.append(role == "user" ? .user : .assistant, prose.joined(separator: "\n"), at: date)
                    prose.removeAll()
                }
                for block in blocks {
                    switch block["type"] as? String {
                    case "text": if let value = block["text"] as? String { prose.append(value) }
                    case "thinking":
                        flush(&self)
                        append(.reasoning, block["thinking"] as? String ?? "", at: date)
                    case "tool_use":
                        flush(&self)
                        call(block["id"] as? String, name: block["name"] as? String, input: block["input"], at: date)
                    case "tool_result":
                        flush(&self)
                        result(block["tool_use_id"] as? String, output: block["content"], failed: block["is_error"] as? Bool == true, at: date)
                    default: omitted += 1
                    }
                }
                flush(&self)
            }
        }

        mutating func codex(_ records: [[String: Any]]) throws {
            let hasMessages = records.contains {
                guard $0["type"] as? String == "response_item", let payload = $0["payload"] as? [String: Any],
                    payload["type"] as? String == "message" else { return false }
                return payload["role"] as? String == "user" || payload["role"] as? String == "assistant"
            }
            var seen: Set<String> = []
            for record in records {
                try Task.checkCancellation()
                let date = time(record["timestamp"])
                guard let payload = record["payload"] as? [String: Any] else { omitted += 1; continue }
                switch record["type"] as? String {
                case "session_meta":
                    if let id = payload["id"] as? String ?? payload["session_id"] as? String { sessionIDs.insert(id.lowercased()) }
                    cwd = payload["cwd"] as? String ?? cwd
                    branch = (payload["git"] as? [String: Any])?["branch"] as? String ?? branch
                case "turn_context":
                    cwd = payload["cwd"] as? String ?? cwd
                    model = payload["model"] as? String ?? model
                case "response_item":
                    if let id = payload["id"] as? String, !seen.insert(id).inserted { continue }
                    switch payload["type"] as? String {
                    case "message":
                        let role = payload["role"] as? String
                        guard role == "user" || role == "assistant" else { continue }
                        append(role == "user" ? .user : .assistant, render(payload["content"]), at: date,
                            externalID: payload["id"] as? String)
                        if let blocks = payload["content"] as? [[String: Any]], blocks.contains(where: { $0["text"] == nil }) { omitted += 1 }
                    case "reasoning": append(.reasoning, render(payload["summary"]), at: date)
                    case "function_call", "custom_tool_call":
                        call(payload["call_id"] as? String, name: payload["name"] as? String,
                            input: payload["arguments"] ?? payload["input"], at: date)
                    case "function_call_output", "custom_tool_call_output":
                        result(payload["call_id"] as? String, output: payload["output"], failed: false, at: date)
                    default: omitted += 1
                    }
                case "event_msg":
                    switch payload["type"] as? String {
                    case "user_message" where !hasMessages: append(.user, render(payload["message"]), at: date)
                    case "agent_message" where !hasMessages: append(.assistant, render(payload["message"]), at: date)
                    case "thread_rolled_back":
                        if let count = payload["num_turns"] as? Int, count > 0 {
                            let starts = items.indices.filter { items[$0].kind == .user }
                            if !starts.isEmpty { items.removeSubrange(starts[max(0, starts.count - count)]...) }
                            tools = Dictionary(uniqueKeysWithValues: items.enumerated().compactMap { index, item in
                                item.kind == .tool ? item.externalID.map { ($0, index) } : nil
                            })
                        }
                    default: break
                    }
                case "compacted": omitted += 1 // Keep the readable pre-compaction history; never replace it with hidden instructions.
                default: omitted += 1
                }
            }
        }
    }
}
