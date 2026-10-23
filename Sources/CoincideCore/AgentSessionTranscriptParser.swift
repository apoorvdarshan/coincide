import Foundation

enum AgentSessionTranscriptParser {
    struct Parsed: Sendable { let transcript: AgentSessionTranscript; let recordCount: Int }
    private struct Message {
        let message: AgentSessionMessage; let response: Bool; let position: Int
    }
    static func workspace(_ records: [JSONValue], source: AgentSessionSource) -> String? {
        for row in records {
            if source == .codex, row["type"].string == "session_meta", let origin = row["payload"]["source"].object,
               origin["subagent"] != nil || origin["subAgent"] != nil { return nil }
            if let cwd = row["cwd"].string?.trimmingCharacters(in: .whitespacesAndNewlines), !cwd.isEmpty { return cwd }
            if let cwd = row["payload"]["cwd"].string?.trimmingCharacters(in: .whitespacesAndNewlines), !cwd.isEmpty { return cwd }
        }
        return nil
    }
    static func parse(_ records: [JSONValue], profile: AgentSessionProfile, fallbackSessionID: String, lastActive: Date) throws -> AgentSessionTranscript? {
        guard records.count <= AgentSessionImportProtocol.maximumRecords,
              let workspace = workspace(records, source: profile.source), workspace.hasPrefix("/"), !workspace.contains("\0"), workspace.utf8.count <= 4_096 else { return nil }
        var native = profile.source == .codex ? "" : fallbackSessionID, title: String?, customTitle: String?, model: String?
        if profile.source == .claudeAgent {
            for row in records where !hidden(row) {
                if let value = nonempty(row["sessionId"].string) { native = value }
                if let value = nonempty(row["aiTitle"].string) { title = value }
                if row.object?["customTitle"] != nil { customTitle = nonempty(row["customTitle"].string) }
                if let value = nonempty(row["message"]["model"].string), value != "<synthetic>" { model = value }
            }
            guard native.range(of: #"^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[1-8][0-9a-fA-F]{3}-[89aAbB][0-9a-fA-F]{3}-[0-9a-fA-F]{12}$"#, options: .regularExpression) != nil else { return nil }
        }
        // Canonical Codex event prompts can follow their response-item copies.
        // A turn_id scopes matching duplicates; distinct text is never dropped.
        var canonical: Set<Int> = [], eventTexts: Set<Data> = [], responseUsers: [(Int, String, Data)] = []
        func finishTurn() {
            let turns = Set(responseUsers.filter { eventTexts.contains($0.2) }.map { $0.1 })
            canonical.formUnion(responseUsers.filter { turns.contains($0.1) }.map { $0.0 })
            eventTexts = []; responseUsers = []
        }
        if profile.source == .codex {
            for (index, row) in records.enumerated() {
                if index % 128 == 0 { try Task.checkCancellation() }
                if row["type"].string == "response_item", row["payload"]["type"].string == "message", row["payload"]["role"].string == "assistant" { finishTurn(); continue }
                if row["type"].string == "event_msg", row["payload"]["type"].string == "user_message", let value = nonempty(row["payload"]["message"].string) { eventTexts.insert(Data(value.utf8)); continue }
                if row["type"].string == "response_item", row["payload"]["type"].string == "message", row["payload"]["role"].string == "user",
                   let turn = nonempty(row["payload"]["internal_chat_message_metadata_passthrough"]["turn_id"].string) {
                    let value = text(row["payload"]["content"]); if !value.isEmpty { responseUsers.append((index, turn, Data(value.utf8))) }
                }
            }
            finishTurn()
        }
        var messages: [Message] = [], firstUser: Message?, firstTitle: String?, visibleCount = 0, hasNative = false
        func retain(role: MessageRole, value: String, timestamp: JSONValue, response: Bool, position: Int) {
            let message = Message(message: .init(role: role, text: value, createdAt: date(timestamp.string) ?? lastActive), response: response, position: position)
            if firstUser == nil && role == .user { firstUser = message }
            if firstTitle == nil && role == .user { firstTitle = deriveTitle(value, source: profile.source) }
            messages.append(message); visibleCount += 1
            if messages.count > AgentSessionImportProtocol.maximumMessages { messages.removeFirst() }
        }
        for (index, row) in records.enumerated() {
            if index % 128 == 0 { try Task.checkCancellation() }
            if profile.source == .claudeAgent {
                guard !hidden(row), ["user", "assistant"].contains(row["type"].string ?? "") else { continue }
                let value = text(row["message"]["content"]); guard !value.isEmpty else { continue }
                retain(role: row["type"].string == "user" ? .user : .assistant, value: value, timestamp: row["timestamp"], response: false, position: index); continue
            }
            if row["type"].string == "session_meta" {
                if !hasNative, let value = nonempty(row["payload"]["id"].string) ?? nonempty(row["payload"]["session_id"].string) { native = value; hasNative = true }
                continue
            }
            if row["type"].string == "turn_context", let value = nonempty(row["payload"]["model"].string) { model = value; continue }
            if row["type"].string == "event_msg", row["payload"]["type"].string == "user_message", let value = row["payload"]["message"].string, !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                for i in messages.indices.reversed() {
                    if messages[i].message.role == .assistant { break }
                    if messages[i].response, equalTrimmed(messages[i].message.text, value) {
                        if firstUser?.position == messages[i].position { firstUser = nil }
                        messages.remove(at: i); visibleCount -= 1; break
                    }
                }
                retain(role: .user, value: value, timestamp: row["timestamp"], response: false, position: index); continue
            }
            guard row["type"].string == "response_item", row["payload"]["type"].string == "message", let role = row["payload"]["role"].string, ["user", "assistant"].contains(role) else { continue }
            let value = text(row["payload"]["content"]); guard !value.isEmpty else { continue }
            if role == "user" {
                if canonical.contains(index) { continue }
                var duplicate = false
                for message in messages.reversed() {
                    if message.message.role == .assistant { break }
                    if message.message.role == .user && !message.response && equalTrimmed(message.message.text, value) { duplicate = true; break }
                }
                if duplicate { continue }
            }
            retain(role: role == "user" ? .user : .assistant, value: value, timestamp: row["timestamp"], response: role == "user", position: index)
        }
        guard !native.isEmpty, native.utf8.count <= 4_096, !native.contains("\0"), let firstUser else { return nil }
        if !messages.contains(where: { $0.position == firstUser.position }) { messages = [firstUser] + Array(messages.suffix(AgentSessionImportProtocol.maximumMessages - 1)) }
        return .init(source: profile.source, providerInstanceID: profile.id, providerSessionID: native, workspacePath: workspace,
            title: customTitle ?? title ?? firstTitle ?? "Imported thread", model: model,
            createdAt: messages.first?.message.createdAt ?? lastActive, updatedAt: lastActive,
            messages: messages.map(\.message), omittedMessageCount: max(0, visibleCount - messages.count))
    }
    private static func hidden(_ row: JSONValue) -> Bool { row["isSidechain"] == .bool(true) || row["isMeta"] == .bool(true) || row["isCompactSummary"] == .bool(true) }
    private static func nonempty(_ value: String?) -> String? { value?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty }
    private static func text(_ value: JSONValue) -> String {
        if let string = value.string { return string.trimmingCharacters(in: .whitespacesAndNewlines) }
        return (value.array ?? []).filter { ["text", "input_text", "output_text"].contains($0["type"].string ?? "") }
            .compactMap { nonempty($0["text"].string) }.joined(separator: "\n")
    }
    private static func equalTrimmed(_ left: String, _ right: String) -> Bool { Data(left.trimmingCharacters(in: .whitespacesAndNewlines).utf8) == Data(right.trimmingCharacters(in: .whitespacesAndNewlines).utf8) }
    private static func date(_ value: String?) -> Date? {
        guard let value else { return nil }; let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.date(from: value) ?? ISO8601DateFormatter().date(from: value)
    }
    private static func deriveTitle(_ value: String, source: AgentSessionSource) -> String? {
        var value = value
        if source == .codex {
            let pattern = #"^(?:\s*(?:<(recommended_plugins|environment_context|user_instructions|INSTRUCTIONS|in-app-browser-context)(?:\s[^>]*)?>[\s\S]*?</\1>|# AGENTS\.md instructions\b[^\n]*|## My request for Codex:))+"#
            if let expression = try? NSRegularExpression(pattern: pattern), let match = expression.firstMatch(in: value, range: NSRange(value.startIndex..., in: value)), let range = Range(match.range, in: value) { value.removeSubrange(range) }
        }
        return nonempty(value)?.split(separator: "\n", omittingEmptySubsequences: false).first.map { String(String($0).prefix(100)).trimmingCharacters(in: .whitespacesAndNewlines) }
    }
}
private extension String { var nilIfEmpty: String? { isEmpty ? nil : self } }
