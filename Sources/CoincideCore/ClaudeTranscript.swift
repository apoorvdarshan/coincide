import Foundation

public struct ClaudeTranscriptError: LocalizedError, Sendable, Equatable {
    public enum Kind: String, Sendable { case malformed, ambiguous, limitExceeded, invalidBoundary }
    public let kind: Kind
    public init(_ kind: Kind) { self.kind = kind }
    public var errorDescription: String? {
        switch kind {
        case .malformed: "The Claude transcript contains invalid native records."
        case .ambiguous: "The Claude transcript has ambiguous native message ownership."
        case .limitExceeded: "The Claude transcript exceeds the supported history limits."
        case .invalidBoundary: "The selected Claude transcript boundary is unavailable."
        }
    }
}

public struct ClaudeTranscriptFork: Sendable, Equatable {
    public let records: [JSONValue]
    /// SDK allocation map, including omitted progress UUIDs. Map membership does
    /// not assert that a native record was published under the mapped UUID.
    public let sourceToForkMessageIDs: [String: String]
    /// SDK getSessionMessages' last projected message, not necessarily the raw tail.
    public let headMessageID: String?
    public init(records: [JSONValue], sourceToForkMessageIDs: [String: String], headMessageID: String?) {
        self.records = records; self.sourceToForkMessageIDs = sourceToForkMessageIDs; self.headMessageID = headMessageID
    }
}

/// Pure native JSONL algorithms from Agent SDK 0.3.276 (sdk.mjs fI/LGe/UGe/x9).
/// Unlike its tolerant display reader, mutation evidence rejects malformed lines,
/// duplicate UUID updates, mixed sessions and cycles instead of guessing a head.
/// This type performs no filesystem access, CLI invocation or implicit file rewind.
public struct ClaudeTranscript: Sendable, Equatable {
    public static let maximumBytes = 16 * 1_024 * 1_024
    public static let maximumRecords = 20_000
    public static let maximumLineBytes = 4 * 1_024 * 1_024
    public static let precompactThresholdBytes = 5_242_880
    public let records: [JSONValue]
    /// SDK default reader projection. Queued inputs may have a synthesized UUID.
    public let selectedMessages: [JSONValue]
    /// SDK's normalized native chain before its reader projection. Its chosen
    /// conversational head can precede later raw attachments; this is NOT proof
    /// of the kept turn's final native entry for resumeDropsTurn.
    public let selectedChainRecords: [JSONValue]
    private static let transcriptTypes: Set<String> = ["user", "assistant", "system", "attachment", "progress"]

    public static func parse(_ data: Data) throws -> Self {
        guard data.count <= maximumBytes else { throw ClaudeTranscriptError(.limitExceeded) }
        var records: [JSONValue] = []
        for line in data.split(separator: 10, omittingEmptySubsequences: false) {
            guard line.count <= maximumLineBytes else { throw ClaudeTranscriptError(.limitExceeded) }
            if line.allSatisfy({ $0 == 9 || $0 == 13 || $0 == 32 }) { continue }
            guard String(data: Data(line), encoding: .utf8) != nil else { throw ClaudeTranscriptError(.malformed) }
            let value: JSONValue
            do { value = try JSONDecoder().decode(JSONValue.self, from: Data(line)) }
            catch { throw ClaudeTranscriptError(.malformed) }
            records.append(value)
            guard records.count <= maximumRecords else { throw ClaudeTranscriptError(.limitExceeded) }
        }
        return try Self(validating: records, byteCount: data.count)
    }

    private init(validating records: [JSONValue], byteCount: Int) throws {
        var uuids = Set<String>(), sessions = Set<String>()
        for record in records {
            guard let object = record.object, let type = object["type"]?.string,
                  !type.isEmpty, type.utf8.count <= 256, !type.contains("\0") else { throw ClaudeTranscriptError(.malformed) }
            for key in ["uuid", "sessionId", "parentUuid", "logicalParentUuid", "sourceToolAssistantUUID"] {
                if let value = object[key], value != .null {
                    guard let id = value.string, Self.validUUID(id) else { throw ClaudeTranscriptError(.malformed) }
                    if key == "uuid", !uuids.insert(id.lowercased()).inserted { throw ClaudeTranscriptError(.ambiguous) }
                    if key == "sessionId" { sessions.insert(id.lowercased()) }
                }
            }
            guard sessions.count <= 1 else { throw ClaudeTranscriptError(.ambiguous) }
            for key in ["isSidechain", "isMeta", "isCompactSummary", "isVisibleInTranscriptOnly"] {
                if let value = object[key], value != .null {
                    guard case .bool = value else { throw ClaudeTranscriptError(.malformed) }
                }
            }
            if Self.transcriptTypes.contains(type) {
                guard object["uuid"]?.string != nil, object["sessionId"]?.string != nil else { throw ClaudeTranscriptError(.malformed) }
                if type == "user" || type == "assistant" {
                    guard record["message"].object != nil else { throw ClaudeTranscriptError(.malformed) }
                }
                if type == "attachment", record["attachment"].object == nil { throw ClaudeTranscriptError(.malformed) }
            }
            try Self.validateCompaction(record)
            if type == "attachment", record["attachment"]["type"].string == "queued_command",
               let source = record["attachment"].object?["source_uuid"], source != .null {
                guard let id = source.string, Self.validUUID(id) else { throw ClaudeTranscriptError(.malformed) }
            }
        }
        let native = records.filter { Self.transcriptTypes.contains($0["type"].string ?? "") }
        try Self.rejectCycles(native)
        self.records = records
        // Exact SDK IGe/E4 default reader lane. There are deliberately no ambient
        // environment reads: a runtime with DISABLE_PRECOMPACT_SKIP must not claim
        // this default profile without its separate compatibility gate.
        var readerRecords = native
        if byteCount > Self.precompactThresholdBytes,
           let boundary = native.lastIndex(where: { record in
               record["type"].string == "system" && record["subtype"].string == "compact_boundary" &&
                   !Self.truthy(record["compactMetadata"]["preservedMessages"]) &&
                   !Self.truthy(record["compactMetadata"]["preservedSegment"])
           }) {
            // E4 resets its output at the boundary's START, retaining that line.
            // Its retained file-history snapshot is not a reader chain entry.
            readerRecords = Array(native[boundary...])
        }
        selectedChainRecords = try Self.chain(readerRecords)
        selectedMessages = Self.project(try Self.promoteQueued(selectedChainRecords))
    }

    /// Pure Data cannot read the SDK's optional source-title sidecar. A caller
    /// with verified title metadata may supply it; otherwise native record title
    /// and prompt fallback are used, without filesystem scanning.
    public func fork(upToMessageID: String?, targetSessionID: String, sourceSessionID: String,
                     title: String? = nil) throws -> ClaudeTranscriptFork {
        guard Self.validUUID(targetSessionID), Self.validUUID(sourceSessionID), targetSessionID.lowercased() != sourceSessionID.lowercased(),
              records.allSatisfy({ $0.object?["sessionId"] == nil || $0["sessionId"].string?.lowercased() == sourceSessionID.lowercased() }) else {
            throw ClaudeTranscriptError(.invalidBoundary)
        }
        var retained = records.filter { Self.transcriptTypes.contains($0["type"].string ?? "") && $0["isSidechain"] != .bool(true) }
        guard !retained.isEmpty else { throw ClaudeTranscriptError(.invalidBoundary) }
        if let cutoff = upToMessageID {
            guard Self.validUUID(cutoff) else { throw ClaudeTranscriptError(.invalidBoundary) }
            let selected = try Self.chain(retained)
            let positions = Dictionary(uniqueKeysWithValues: retained.enumerated().map { ($0.element["uuid"].string!, $0.offset) })
            let last = selected.compactMap { positions[$0["uuid"].string ?? ""] }.max() ?? -1
            let candidates = selected + retained.dropFirst(last + 1)
            let chosen = candidates.first(where: { $0["uuid"].string == cutoff }) ?? candidates.first(where: { Self.queuedSource($0) == cutoff })
            let index = chosen.flatMap { positions[$0["uuid"].string ?? ""] }
                ?? retained.firstIndex(where: { $0["uuid"].string == cutoff || Self.queuedSource($0) == cutoff })
            guard let index else { throw ClaudeTranscriptError(.invalidBoundary) }
            retained = try Self.prune(Array(retained.prefix(index + 1)), selected: selected, positions: positions)
        }
        var allIDs = Set(records.compactMap { $0["uuid"].string?.lowercased() })
        allIDs.insert(targetSessionID.lowercased())
        var mapping: [String: String] = [:]
        for record in retained {
            let sourceID = record["uuid"].string!
            var id = UUID().uuidString.lowercased()
            while allIDs.contains(id) { id = UUID().uuidString.lowercased() }
            allIDs.insert(id); mapping[sourceID] = id
        }
        let byID = Dictionary(uniqueKeysWithValues: retained.map { ($0["uuid"].string!, $0) })
        let published = retained.filter { $0["type"].string != "progress" }
        guard !published.isEmpty else { throw ClaudeTranscriptError(.invalidBoundary) }
        let formatter = ISO8601DateFormatter(); formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let now = formatter.string(from: Date())
        var output: [JSONValue] = []
        if records.contains(where: { $0["type"].string == "history-suppression" }) {
            output.append(.object(["type": .string("history-suppression"), "sessionId": .string(targetSessionID),
                                   "cause": .string("fork_inherit"), "ts": .string(now)]))
        }
        // Many published siblings can share the same long progress ancestry.
        // Cache the nearest mapped non-progress parent (including a proven null)
        // so this transform walks each shared progress segment only once.
        var parentCache: [String: JSONValue] = [:], parentWork = 0
        for (index, record) in published.enumerated() {
            var object = record.object!, parent = record["parentUuid"].string, visited = Set<String>()
            var mappedParent: String?, trail: [String] = []
            while let id = parent, let ancestor = byID[id] {
                if let cached = parentCache[id] { mappedParent = cached.string; break }
                parentWork += 1
                guard parentWork <= 2_000_000 else { throw ClaudeTranscriptError(.limitExceeded) }
                guard visited.insert(id).inserted else { throw ClaudeTranscriptError(.ambiguous) }
                if ancestor["type"].string != "progress" {
                    mappedParent = mapping[id]; parentCache[id] = mappedParent.map(JSONValue.string) ?? .null; break
                }
                trail.append(id)
                parent = ancestor["parentUuid"].string
            }
            for id in trail { parentCache[id] = mappedParent.map(JSONValue.string) ?? .null }
            let sourceID = record["uuid"].string!, newID = mapping[sourceID]!
            object["uuid"] = .string(newID); object["sessionId"] = .string(targetSessionID)
            object["parentUuid"] = mappedParent.map(JSONValue.string) ?? .null
            if let logical = record.object?["logicalParentUuid"], logical != .null {
                object["logicalParentUuid"] = logical.string.flatMap { mapping[$0] }.map(JSONValue.string) ?? .null
            }
            object["isSidechain"] = .bool(false)
            object["forkedFrom"] = .object(["sessionId": .string(sourceSessionID), "messageUuid": .string(sourceID)])
            for key in ["teamName", "agentName", "sessionKind", "slug", "sourceToolAssistantUUID"] { object.removeValue(forKey: key) }
            if index == published.count - 1 { object["timestamp"] = .string(now) }
            if record["type"].string == "system", record["subtype"].string == "model_refusal_fallback" { object["neutralizedByFork"] = .bool(true) }
            if record["type"].string == "attachment", var attachment = record["attachment"].object {
                if attachment["type"]?.string == "deferred_tools_record", let names = attachment["nameOnlyAnnouncements"]?.array {
                    attachment["nameOnlyAnnouncements"] = .array(names.compactMap { $0.string.flatMap { mapping[$0] }.map(JSONValue.string) })
                }
                if let source = Self.queuedSource(record), let mapped = mapping[source] { attachment["source_uuid"] = .string(mapped) }
                object["attachment"] = .object(attachment)
            }
            output.append(.object(object))
        }
        let replacements = records.filter { $0["type"].string == "content-replacement" && $0["sessionId"].string == sourceSessionID }
            .flatMap { $0["replacements"].array ?? [] }
        if !replacements.isEmpty {
            output.append(.object(["type": .string("content-replacement"), "sessionId": .string(targetSessionID),
                "replacements": .array(replacements), "uuid": .string(UUID().uuidString.lowercased()), "timestamp": .string(now)]))
        }
        if let atis = records.last(where: { record in
            record["type"].string == "atis-latch" && record["sessionId"].string == sourceSessionID &&
                record["atis"].string.map { $0.utf8.allSatisfy { (33...126).contains($0) } } == true
        }) {
            output.append(.object(["type": .string("atis-latch"), "sessionId": .string(targetSessionID), "atis": atis["atis"]]))
        }
        if let relocated = records.last(where: { $0["type"].string == "relocated" && $0["sessionId"].string == sourceSessionID && $0["relocatedCwd"].string?.isEmpty == false }) {
            output.append(.object(["type": .string("relocated"), "sessionId": .string(targetSessionID), "relocatedCwd": relocated["relocatedCwd"]]))
        }
        let sourceTitle = records.last(where: { $0["customTitle"].string?.isEmpty == false })?["customTitle"].string
            ?? records.last(where: { $0["aiTitle"].string?.isEmpty == false })?["aiTitle"].string
            ?? Self.firstPromptTitle(records)
        let trimmedTitle = title?.trimmingCharacters(in: .whitespacesAndNewlines)
        let forkTitle = trimmedTitle.flatMap { $0.isEmpty ? nil : $0 } ?? ((sourceTitle ?? "Forked session") + " (fork)")
        output.append(.object(["type": .string("custom-title"), "sessionId": .string(targetSessionID),
            "customTitle": .string(forkTitle),
            "uuid": .string(UUID().uuidString.lowercased()), "timestamp": .string(now)]))
        guard output.count <= Self.maximumRecords else { throw ClaudeTranscriptError(.limitExceeded) }
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        var bytes = 0
        for value in output {
            let count = try encoder.encode(value).count
            guard count <= Self.maximumLineBytes else { throw ClaudeTranscriptError(.limitExceeded) }
            bytes += count + 1
            guard bytes <= Self.maximumBytes else { throw ClaudeTranscriptError(.limitExceeded) }
        }
        let forked = try Self(validating: output, byteCount: bytes)
        return .init(records: output, sourceToForkMessageIDs: mapping, headMessageID: forked.selectedMessages.last?["uuid"].string)
    }

    /// Rebuild the exact pinned content transform, substituting only the supplied
    /// native UUID allocation and publication time. A digest or record count alone
    /// never establishes that an arbitrary target is this source's fork.
    public func validateFork(_ fork: ClaudeTranscriptFork, upToMessageID: String?, targetSessionID: String,
                             sourceSessionID: String, title: String? = nil) throws {
        guard fork.records.count <= Self.maximumRecords else { throw ClaudeTranscriptError(.limitExceeded) }
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        var count = 0
        for record in fork.records {
            let size = try encoder.encode(record).count; count += size + 1
            guard size <= Self.maximumLineBytes, count <= Self.maximumBytes else { throw ClaudeTranscriptError(.limitExceeded) }
        }
        _ = try Self(validating: fork.records, byteCount: count)
        let expected = try self.fork(upToMessageID: upToMessageID, targetSessionID: targetSessionID,
                                     sourceSessionID: sourceSessionID, title: title)
        let mapping = fork.sourceToForkMessageIDs, sourceIDs = Set(records.compactMap { $0["uuid"].string?.lowercased() })
        guard mapping.keys.sorted() == expected.sourceToForkMessageIDs.keys.sorted(),
              Set(mapping.values.map { $0.lowercased() }).count == mapping.count,
              mapping.values.allSatisfy({ Self.validUUID($0) && !sourceIDs.contains($0.lowercased()) && $0.lowercased() != targetSessionID.lowercased() }),
              fork.records.count == expected.records.count,
              let publicationTime = fork.records.last?["timestamp"].string else { throw ClaudeTranscriptError(.ambiguous) }
        let formatter = ISO8601DateFormatter(); formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        guard formatter.date(from: publicationTime) != nil else { throw ClaudeTranscriptError(.malformed) }
        let substitutions = Dictionary(uniqueKeysWithValues: expected.sourceToForkMessageIDs.map { ($0.value, mapping[$0.key]!) })
        let lastNative = expected.records.lastIndex(where: { Self.transcriptTypes.contains($0["type"].string ?? "") })
        var expectedRecords: [JSONValue] = [], metadataIDs = Set<String>()
        for (index, record) in expected.records.enumerated() {
            var object = record.object!
            for key in ["uuid", "parentUuid", "logicalParentUuid"] {
                if let id = object[key]?.string, let replacement = substitutions[id] { object[key] = .string(replacement) }
            }
            if let id = record["uuid"].string, substitutions[id] == nil {
                guard let actualID = fork.records[index]["uuid"].string, Self.validUUID(actualID),
                      !sourceIDs.contains(actualID.lowercased()), !mapping.values.contains(where: { $0.lowercased() == actualID.lowercased() }), actualID.lowercased() != targetSessionID.lowercased(),
                      metadataIDs.insert(actualID.lowercased()).inserted else { throw ClaudeTranscriptError(.ambiguous) }
                object["uuid"] = .string(actualID)
            }
            if index == lastNative || record["type"].string == "custom-title" || record["type"].string == "content-replacement" {
                object["timestamp"] = .string(publicationTime)
            }
            if record["type"].string == "history-suppression" { object["ts"] = .string(publicationTime) }
            if var attachment = record["attachment"].object {
                if let source = attachment["source_uuid"]?.string, let replacement = substitutions[source] { attachment["source_uuid"] = .string(replacement) }
                if attachment["type"]?.string == "deferred_tools_record", let names = attachment["nameOnlyAnnouncements"]?.array {
                    attachment["nameOnlyAnnouncements"] = .array(names.map { value in value.string.flatMap { substitutions[$0] }.map(JSONValue.string) ?? value })
                }
                object["attachment"] = .object(attachment)
            }
            expectedRecords.append(.object(object))
        }
        let expectedHead = expected.headMessageID.flatMap { substitutions[$0] }
        guard fork.records == expectedRecords, fork.headMessageID == expectedHead else { throw ClaudeTranscriptError(.ambiguous) }
    }

    private static func validUUID(_ value: String) -> Bool {
        let pieces = value.split(separator: "-", omittingEmptySubsequences: false)
        return pieces.map(\.count) == [8, 4, 4, 4, 12] && pieces.allSatisfy { $0.utf8.allSatisfy { (48...57).contains($0) || (65...70).contains($0) || (97...102).contains($0) } }
    }
    private static func validateCompaction(_ record: JSONValue) throws {
        guard record["type"].string == "system", record["subtype"].string == "compact_boundary" else { return }
        for name in ["preservedMessages", "preservedSegment"] {
            guard let value = record["compactMetadata"].object?[name], value != .null else { continue }
            guard value.object != nil else { throw ClaudeTranscriptError(.malformed) }
            let keys = name == "preservedMessages" ? ["anchorUuid"] : ["anchorUuid", "headUuid", "tailUuid"]
            guard keys.allSatisfy({ value[$0].string.map(validUUID) == true }) else { throw ClaudeTranscriptError(.malformed) }
            if name == "preservedMessages" {
                guard let ids = value["uuids"].array, ids.allSatisfy({ $0.string.map(validUUID) == true }),
                      Set(ids.compactMap(\.string)).count == ids.count else { throw ClaudeTranscriptError(.malformed) }
            }
        }
    }
    private static func rejectCycles(_ records: [JSONValue]) throws {
        let parents = Dictionary(uniqueKeysWithValues: records.map { ($0["uuid"].string!, $0["parentUuid"].string) })
        var done = Set<String>()
        for record in records {
            var cursor: String? = record["uuid"].string, path = Set<String>()
            while let id = cursor, !done.contains(id), parents.keys.contains(id) {
                guard path.insert(id).inserted else { throw ClaudeTranscriptError(.ambiguous) }
                cursor = parents[id] ?? nil
            }
            done.formUnion(path)
        }
    }

    private static func chain(_ records: [JSONValue]) throws -> [JSONValue] {
        var byID = Dictionary(uniqueKeysWithValues: records.map { ($0["uuid"].string!, $0) })
        let order = records.compactMap { $0["uuid"].string }
        let positions = Dictionary(uniqueKeysWithValues: order.enumerated().map { ($0.element, $0.offset) })
        var operations = 0
        func charge(_ count: Int = 1) throws {
            operations += count
            guard operations <= 2_000_000 else { throw ClaudeTranscriptError(.limitExceeded) }
        }
        func reparent(_ id: String, _ parent: String) {
            guard var object = byID[id]?.object else { return }
            object["parentUuid"] = .string(parent); byID[id] = .object(object)
        }
        for id in order {
            guard let boundary = byID[id], boundary["type"].string == "system", boundary["subtype"].string == "compact_boundary" else { continue }
            let compact = boundary["compactMetadata"]
            if let kept = compact["preservedMessages"].object {
                let ids = kept["uuids"]?.array?.compactMap(\.string) ?? []
                guard !ids.isEmpty, ids.allSatisfy({ byID[$0] != nil }), let anchor = kept["anchorUuid"]?.string else { continue }
                var parent = anchor
                for keptID in ids { reparent(keptID, parent); parent = keptID }
                for other in order {
                    try charge()
                    if byID[other]?["parentUuid"].string == anchor, other != ids.first { reparent(other, parent) }
                }
            } else if let segment = compact["preservedSegment"].object,
                      let head = segment["headUuid"]?.string, let tail = segment["tailUuid"]?.string, let anchor = segment["anchorUuid"]?.string {
                reparent(head, anchor)
                for other in order {
                    try charge()
                    if byID[other]?["parentUuid"].string == anchor, other != head { reparent(other, tail) }
                }
            }
        }
        let parents = Set(byID.values.compactMap { $0["parentUuid"].string })
        var candidates: [JSONValue] = []
        for id in order where !parents.contains(id) {
            var cursor = byID[id], visited = Set<String>()
            while let record = cursor, let uuid = record["uuid"].string {
                try charge()
                guard visited.insert(uuid).inserted else { throw ClaudeTranscriptError(.ambiguous) }
                if conversational(record) { candidates.append(record); break }
                cursor = record["parentUuid"].string.flatMap { byID[$0] }
            }
        }
        let rootCandidates = candidates.filter { $0["isSidechain"] != .bool(true) && $0["isMeta"] != .bool(true) && !truthy($0["teamName"]) }
        let available = rootCandidates.isEmpty ? candidates : rootCandidates
        guard let head = available.max(by: { (positions[$0["uuid"].string!] ?? -1) < (positions[$1["uuid"].string!] ?? -1) }) else { return [] }
        var selected: [JSONValue] = [], visited = Set<String>(), cursor: JSONValue? = head
        while let record = cursor, let id = record["uuid"].string {
            try charge()
            guard visited.insert(id).inserted else { throw ClaudeTranscriptError(.ambiguous) }
            selected.append(record); cursor = record["parentUuid"].string.flatMap { byID[$0] }
        }
        selected.reverse()
        var groups: [String: [JSONValue]] = [:], results: [String: [JSONValue]] = [:], last: [String: String] = [:]
        for record in selected where record["type"].string == "assistant" {
            if let apiID = apiMessageID(record) { last[apiID] = record["uuid"].string }
        }
        for id in order {
            let record = byID[id]!
            if let apiID = apiMessageID(record) { groups[apiID, default: []].append(record) }
            else if toolResult(record), let parent = record["parentUuid"].string { results[parent, default: []].append(record) }
        }
        var seen = Set<String>(), appendAfter: [String: [JSONValue]] = [:]
        func stableTime(_ left: JSONValue, _ right: JSONValue) -> Bool {
            let a = left["timestamp"].string ?? "", b = right["timestamp"].string ?? ""
            return a == b ? positions[left["uuid"].string!]! < positions[right["uuid"].string!]! : a < b
        }
        for record in selected where record["type"].string == "assistant" {
            guard let apiID = apiMessageID(record), seen.insert(apiID).inserted, let anchor = last[apiID] else { continue }
            let siblings = groups[apiID] ?? [record]
            let missing = siblings.filter { !visited.contains($0["uuid"].string!) }.sorted(by: stableTime)
            let missingResults = siblings.flatMap { results[$0["uuid"].string!] ?? [] }
                .filter { !visited.contains($0["uuid"].string!) }.sorted(by: stableTime)
            try charge(siblings.count + missingResults.count)
            let extras = missing + missingResults
            extras.forEach { visited.insert($0["uuid"].string!) }
            appendAfter[anchor] = extras
        }
        return selected.flatMap { [$0] + (appendAfter[$0["uuid"].string!] ?? []) }
    }

    private static func promoteQueued(_ records: [JSONValue]) throws -> [JSONValue] {
        var completed = Set<Int>(), work = 0
        for (index, record) in records.enumerated() where record["type"].string == "user" && record["isMeta"] == .bool(true) && sourceTag(record) == "caveat" {
            var sawRecord = false
            for next in records.indices.dropFirst(index + 1) {
                work += 1
                guard work <= 2_000_000 else { throw ClaudeTranscriptError(.limitExceeded) }
                let value = records[next]
                if value["type"].string == "assistant" { break }
                if value["type"].string != "user" || value["isMeta"] == .bool(true) { continue }
                let tag = sourceTag(value)
                if tag == "record", !sawRecord { sawRecord = true }
                else if tag != "output" || !sawRecord { break }
                completed.insert(next)
            }
        }
        var replied = Array(repeating: false, count: records.count), state = false
        for index in records.indices.reversed() {
            let record = records[index]; replied[index] = state
            if record["type"].string == "assistant" || toolResult(record) || interruptedMarker(record) { state = true }
            else if record["type"].string == "user", record["isMeta"] != .bool(true), record["isCompactSummary"] != .bool(true), !completed.contains(index) { state = false }
        }
        var used = Set(records.compactMap { $0["uuid"].string })
        return records.enumerated().map { index, record in
            if completed.contains(index), var object = record.object { object["isCompletedLocalCommand"] = .bool(true); return .object(object) }
            guard replied[index], record["type"].string == "attachment", let attachment = record["attachment"].object,
                  attachment["type"]?.string == "queued_command", attachment["isMeta"] != .bool(true),
                  attachment["prompt"]?.string != nil || attachment["prompt"]?.array != nil else { return record }
            let forwarded = attachment["forwardedIntent"]
            if let lineage = forwarded?["lineage"].string, !lineage.isEmpty,
               forwarded?.object?["source"] == nil || forwarded?["source"].string != nil { return record }
            let native = record["uuid"].string!, id = attachment["source_uuid"]?.string ?? native
            if id != native, used.contains(id) { return record }
            used.insert(id)
            var object: [String: JSONValue] = ["type": .string("user"), "uuid": .string(id),
                "message": .object(["role": .string("user"), "content": attachment["prompt"]!]), "isMeta": .bool(false), "isQueuedCommand": .bool(true)]
            for key in ["parentUuid", "sessionId", "timestamp", "isSidechain", "teamName"] { object[key] = record.object?[key] }
            if let origin = attachment["origin"], origin["kind"].string != nil { object["origin"] = normalizedOrigin(origin) }
            else if attachment["commandMode"]?.string == "task-notification" { object["origin"] = .object(["kind": .string("task-notification")]) }
            return .object(object)
        }
    }
    private static func project(_ records: [JSONValue]) -> [JSONValue] {
        records.compactMap { record in
            guard conversational(record), record["isMeta"] != .bool(true), record["isSidechain"] != .bool(true), !truthy(record["teamName"]) else { return nil }
            var result: [String: JSONValue] = ["type": record["type"], "uuid": record["uuid"], "session_id": record["sessionId"],
                "message": record["message"], "parent_tool_use_id": .null, "parent_agent_id": .null]
            result["timestamp"] = record.object?["timestamp"]
            for key in ["interruptedByShutdown", "isCompactSummary", "isQueuedCommand", "isCompletedLocalCommand"] where record[key] == .bool(true) { result[key] = .bool(true) }
            if record["isCompactSummary"] == .bool(true) || record["isVisibleInTranscriptOnly"] == .bool(true) { result["is_meta"] = .bool(true) }
            if let origin = record.object?["origin"], origin != .null { result["origin"] = normalizedOrigin(origin) }
            return .object(result)
        }
    }
    private static func normalizedOrigin(_ origin: JSONValue) -> JSONValue {
        guard origin["kind"].string == "task-notification" else { return origin }
        var result: [String: JSONValue] = ["kind": .string("task-notification")]
        for key in ["subkind", "fireReason"] { result[key] = origin.object?[key] }
        return .object(result)
    }
    private static func prune(_ records: [JSONValue], selected: [JSONValue], positions: [String: Int]) throws -> [JSONValue] {
        guard let tail = records.last, !eligibleConversation(tail), let first = selected.first?["uuid"].string,
              let start = positions[first] else { return records }
        let byID = Dictionary(uniqueKeysWithValues: records.map { ($0["uuid"].string!, $0) })
        var selectedIDs = Set(selected.compactMap { $0["uuid"].string }), cursor: JSONValue? = tail
        while let record = cursor, let id = record["uuid"].string, !selectedIDs.contains(id) {
            selectedIDs.insert(id); cursor = record["parentUuid"].string.flatMap { byID[$0] }
        }
        let last = records.lastIndex(where: { eligibleConversation($0) && selectedIDs.contains($0["uuid"].string!) }) ?? -1
        var removed = Set<String>(), work = 0
        for record in records.dropFirst(last + 1) where eligibleConversation(record) && !selectedIDs.contains(record["uuid"].string!) {
            cursor = record
            while let value = cursor, let id = value["uuid"].string, !selectedIDs.contains(id), !removed.contains(id), (positions[id] ?? start) >= start {
                work += 1
                guard work <= 2_000_000 else { throw ClaudeTranscriptError(.limitExceeded) }
                removed.insert(id); cursor = value["parentUuid"].string.flatMap { byID[$0] }
            }
        }
        for record in records where record["parentUuid"].string.map({ removed.contains($0) }) == true { removed.insert(record["uuid"].string!) }
        return records.filter { !removed.contains($0["uuid"].string!) }
    }
    private static func conversational(_ value: JSONValue) -> Bool { ["user", "assistant"].contains(value["type"].string ?? "") }
    private static func eligibleConversation(_ value: JSONValue) -> Bool { conversational(value) && value["isMeta"] != .bool(true) && !truthy(value["teamName"]) }
    private static func apiMessageID(_ value: JSONValue) -> String? {
        guard value["type"].string == "assistant", let id = value["message"]["id"].string, !id.isEmpty else { return nil }; return id
    }
    private static func toolResult(_ value: JSONValue) -> Bool {
        value["type"].string == "user" && value["parentUuid"].string != nil && value["message"]["content"].array?.contains(where: { $0["type"].string == "tool_result" }) == true
    }
    private static func truthy(_ value: JSONValue) -> Bool {
        switch value { case .null: false; case .bool(let flag): flag; case .string(let text): !text.isEmpty; case .number(let n): n != 0; default: true }
    }
    private static func queuedSource(_ value: JSONValue) -> String? {
        guard value["type"].string == "attachment", value["attachment"]["type"].string == "queued_command" else { return nil }
        return value["attachment"]["source_uuid"].string
    }
    private static func sourceTag(_ value: JSONValue) -> String? {
        guard value.object?["promptSource"] == nil else { return nil }
        let content = value["message"]["content"]
        let text = content.string ?? content.array?.last(where: { $0["type"].string == "text" })?["text"].string
        guard let text else { return nil }
        for (prefix, name) in [("<command-name>", "record"), ("<local-command-stdout>", "output"), ("<local-command-stderr>", "output"), ("<local-command-caveat>", "caveat")] where text.hasPrefix(prefix) { return name }
        return nil
    }
    private static func interruptedMarker(_ value: JSONValue) -> Bool {
        guard value["type"].string == "user" else { return false }
        let prefixes = ["[Request interrupted by user]", "[Request interrupted by user for tool use]",
            "[Tool call did not complete: the turn was ended to deliver the message that follows. Nothing refused it; re-run it if still needed.]",
            "The user doesn't want to take this action right now. STOP what you are doing and wait for the user to tell you how to proceed.",
            "[Tool call skipped: the turn ended to deliver the message that follows before this call ran. Nothing refused it; re-run it if still needed.]"]
        func marker(_ text: String) -> Bool { prefixes.contains(where: { text.hasPrefix($0) }) }
        let content = value["message"]["content"]
        if let text = content.string { return marker(text) }
        guard let blocks = content.array, !blocks.isEmpty else { return false }
        return blocks.allSatisfy { block in
            let text = block["type"].string == "text" ? block["text"].string : (block["type"].string == "tool_result" && block["is_error"] == .bool(true) ? block["content"].string : nil)
            return text.map(marker) == true
        }
    }
    private static func firstPromptTitle(_ records: [JSONValue]) -> String? {
        guard let input = records.first(where: { $0["type"].string == "user" && $0["isMeta"] != .bool(true) }) else { return nil }
        let content = input["message"]["content"]
        return content.string ?? content.array?.first(where: { $0["type"].string == "text" })?["text"].string
    }
}
