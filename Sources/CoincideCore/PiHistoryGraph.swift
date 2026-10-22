import CryptoKit
import Darwin
import Foundation

public struct PiHistoryGraphError: Error, LocalizedError, Sendable, Equatable {
    public enum Kind: String, Sendable { case unsupportedVersion, invalidHeader, invalidEntry, invalidGraph, invalidWindow, oversized, unavailable, changed }
    public let kind: Kind
    public init(_ kind: Kind) { self.kind = kind }
    public var errorDescription: String? {
        switch kind {
        case .unsupportedVersion: "This Pi session uses an unsupported history format. It was not migrated or changed."
        case .invalidWindow: "The Pi history read does not prove an unchanged ancestor window. No input ownership was inferred."
        case .oversized: "The Pi history exceeds its bounded read limits."
        case .unavailable: "The exact Pi history file could not be read safely."
        case .changed: "The Pi history file changed during its read. Read it again before reviewing history."
        default: "The Pi history contains invalid or ambiguous native records. It was not changed."
        }
    }
}

/// The file format and projections below follow Pi v0.80.5 session-manager.ts.
/// Raw records are transient and deliberately do not conform to Codable: future
/// durable proofs should retain digests/identities, not another prompt archive.
public struct PiHistoryHeader: Sendable, Equatable {
    public let raw: JSONValue
    public let sessionID: String
    public let workspacePath: String
    public let parentSessionPath: String?
    public init(raw: JSONValue) throws {
        _ = try PiHistoryValidation.bytes(raw)
        guard raw.object != nil, raw["type"] == .string("session") else { throw PiHistoryGraphError(.invalidHeader) }
        guard raw["version"] == .number(3) else { throw PiHistoryGraphError(.unsupportedVersion) }
        let session = try PiHistoryValidation.identifier(raw["id"], kind: .invalidHeader)
        let bytes = Array(session.utf8)
        func alphanumeric(_ byte: UInt8) -> Bool { (48...57).contains(byte) || (65...90).contains(byte) || (97...122).contains(byte) }
        guard let first = bytes.first, let last = bytes.last, alphanumeric(first), alphanumeric(last),
              bytes.allSatisfy({ alphanumeric($0) || $0 == 45 || $0 == 46 || $0 == 95 }) else { throw PiHistoryGraphError(.invalidHeader) }
        let workspace = try PiHistoryValidation.path(raw["cwd"], kind: .invalidHeader)
        try PiHistoryValidation.timestamp(raw["timestamp"], kind: .invalidHeader)
        let parent = raw["parentSession"] == .null ? nil : try PiHistoryValidation.path(raw["parentSession"], kind: .invalidHeader)
        self.raw = raw; sessionID = session; workspacePath = workspace; parentSessionPath = parent
    }
}

public struct PiHistoryEntry: Sendable, Equatable, Identifiable {
    public enum Kind: String, Sendable {
        case message, thinkingLevelChange = "thinking_level_change", modelChange = "model_change"
        case compaction, branchSummary = "branch_summary", custom, customMessage = "custom_message", label, sessionInfo = "session_info"
    }
    public let raw: JSONValue
    public let id: String
    public let parentID: String?
    public let kind: Kind
    public let digest: String
    public var isUserMessage: Bool { kind == .message && raw["message"]["role"] == .string("user") }
    /// This is the SDK's entry-to-context classification, not a claim that custom
    /// extension state, a summary, or a bash result is an original user input.
    public var contributesContextMessage: Bool {
        switch kind {
        case .message, .customMessage, .compaction: true
        case .branchSummary: raw["summary"].string?.isEmpty == false
        default: false
        }
    }
    public init(raw: JSONValue) throws {
        let encoded = try PiHistoryValidation.bytes(raw)
        guard let object = raw.object, let kind = Kind(rawValue: raw["type"].string ?? ""), object["parentId"] != nil else {
            throw PiHistoryGraphError(.invalidEntry)
        }
        id = try PiHistoryValidation.identifier(raw["id"])
        parentID = raw["parentId"] == .null ? nil : try PiHistoryValidation.identifier(raw["parentId"])
        try PiHistoryValidation.timestamp(raw["timestamp"])
        switch kind {
        case .message:
            guard raw["message"].object != nil else { throw PiHistoryGraphError(.invalidEntry) }
            _ = try PiHistoryValidation.identifier(raw["message"]["role"])
            // The native reader normalizes absent/null content to [] for these
            // roles; retain the original envelope rather than invent payloads.
            if ["user", "assistant", "toolResult"].contains(raw["message"]["role"].string ?? ""), raw["message"]["content"] != .null {
                try PiHistoryValidation.content(raw["message"]["content"])
            }
        case .thinkingLevelChange: _ = try PiHistoryValidation.identifier(raw["thinkingLevel"])
        case .modelChange:
            _ = try PiHistoryValidation.identifier(raw["provider"]); _ = try PiHistoryValidation.identifier(raw["modelId"])
        case .compaction:
            guard raw["summary"].string != nil, let tokens = raw["tokensBefore"].numberValue, tokens.isFinite, tokens >= 0 else { throw PiHistoryGraphError(.invalidEntry) }
            _ = try PiHistoryValidation.identifier(raw["firstKeptEntryId"])
        case .branchSummary:
            guard raw["summary"].string != nil else { throw PiHistoryGraphError(.invalidEntry) }
            _ = try PiHistoryValidation.identifier(raw["fromId"])
        case .custom: _ = try PiHistoryValidation.identifier(raw["customType"])
        case .customMessage:
            _ = try PiHistoryValidation.identifier(raw["customType"])
            guard case .bool = raw["display"] else { throw PiHistoryGraphError(.invalidEntry) }
            if raw["content"] != .null { try PiHistoryValidation.content(raw["content"]) }
        case .label:
            _ = try PiHistoryValidation.identifier(raw["targetId"])
            guard raw["label"] == .null || raw["label"].string != nil else { throw PiHistoryGraphError(.invalidEntry) }
        case .sessionInfo:
            guard raw["name"] == .null || raw["name"].string != nil else { throw PiHistoryGraphError(.invalidEntry) }
        }
        self.raw = raw; self.kind = kind; digest = PiHistoryValidation.sha(encoded)
    }
}

public enum PiHistoryLeafOrigin: Sendable, Equatable {
    /// Exact leafId from a complete get_entries response; quietness still belongs
    /// to the owning provider operation, not this pure graph parser.
    case runtime
    /// Pi reloads the last appended entry as its leaf. A file cannot prove an
    /// unpersisted live branch()/resetLeaf() pointer.
    case reloadedFile
}

public struct PiHistoryReadWindow: Sendable, Equatable {
    public let baselineLeafID: String?
    public let leafID: String?
    public let entryIDs: [String]
    public let userEntryIDs: [String]
    public let beforeInventoryDigest: String
    public let afterInventoryDigest: String
    public var openingUserEntryID: String? { userEntryIDs.first }
}

public struct PiHistoryGraph: Sendable, Equatable {
    public static let maximumBytes = 16 * 1_024 * 1_024
    public static let maximumLineBytes = 4 * 1_024 * 1_024
    public static let maximumEntries = 20_000
    public static let maximumDepth = 64
    public let header: PiHistoryHeader
    public let entries: [PiHistoryEntry]
    public let leafID: String?
    public let leafOrigin: PiHistoryLeafOrigin
    public let inventoryDigest: String
    private let index: [String: Int]

    /// A COMPLETE RPC inventory and its explicit native leaf. Incremental `since`
    /// lists must be joined and verified by their owner before constructing this.
    public init(header: JSONValue, entries: [JSONValue], leafID: String?) throws {
        try self.init(header: header, entries: entries, leafID: leafID, origin: .runtime)
    }
    private init(header rawHeader: JSONValue, entries rawEntries: [JSONValue], leafID: String?, origin: PiHistoryLeafOrigin) throws {
        guard rawEntries.count <= Self.maximumEntries else { throw PiHistoryGraphError(.oversized) }
        header = try .init(raw: rawHeader)
        var parsed: [PiHistoryEntry] = [], index: [String: Int] = [:]
        var byteCount = try PiHistoryValidation.bytes(rawHeader).count + 1
        for raw in rawEntries {
            byteCount += try PiHistoryValidation.bytes(raw).count + 1
            guard byteCount <= Self.maximumBytes else { throw PiHistoryGraphError(.oversized) }
            let entry = try PiHistoryEntry(raw: raw)
            guard index[entry.id] == nil else { throw PiHistoryGraphError(.invalidGraph) }
            index[entry.id] = parsed.count; parsed.append(entry)
        }
        // All native parents already exist when an append is made. This also
        // rejects cycles/forward references on abandoned branches in O(n).
        for (position, entry) in parsed.enumerated() {
            if let parent = entry.parentID {
                guard let parentPosition = index[parent], parentPosition < position else { throw PiHistoryGraphError(.invalidGraph) }
            }
            if entry.kind == .label {
                guard let target = index[entry.raw["targetId"].string ?? ""], target < position else { throw PiHistoryGraphError(.invalidGraph) }
            }
        }
        if let leafID { _ = try PiHistoryValidation.identifier(.string(leafID)); guard index[leafID] != nil else { throw PiHistoryGraphError(.invalidGraph) } }
        self.entries = parsed; self.index = index; self.leafID = leafID; leafOrigin = origin
        inventoryDigest = try PiHistoryValidation.digest(.object(["header": rawHeader, "entries": .array(rawEntries)]))
    }

    /// Strict, read-only v3 decoding. Unlike Pi's permissive loader this refuses
    /// malformed/legacy records instead of skipping or migrating private data.
    public static func parse(_ data: Data) throws -> Self {
        guard !data.isEmpty else { throw PiHistoryGraphError(.invalidHeader) }
        guard data.count <= maximumBytes else { throw PiHistoryGraphError(.oversized) }
        guard String(data: data, encoding: .utf8) != nil else { throw PiHistoryGraphError(.invalidEntry) }
        var values: [JSONValue] = []
        for line in data.split(separator: 10, omittingEmptySubsequences: false) {
            guard line.count <= maximumLineBytes else { throw PiHistoryGraphError(.oversized) }
            let trimmed = line.drop(while: { $0 == 32 || $0 == 9 || $0 == 13 })
            if trimmed.isEmpty { continue }
            guard values.count <= maximumEntries else { throw PiHistoryGraphError(.oversized) }
            try PiHistoryValidation.jsonDepth(trimmed)
            do { values.append(try JSONDecoder().decode(JSONValue.self, from: Data(trimmed))) }
            catch let error as PiHistoryGraphError { throw error }
            catch { throw PiHistoryGraphError(.invalidEntry) }
        }
        guard let header = values.first else { throw PiHistoryGraphError(.invalidHeader) }
        let entries = Array(values.dropFirst())
        return try .init(header: header, entries: entries, leafID: entries.last?["id"].string, origin: .reloadedFile)
    }

    public func entry(id: String) -> PiHistoryEntry? { index[id].map { entries[$0] } }
    public var activeBranch: [PiHistoryEntry] { branchUnchecked(through: leafID) }
    public func branch(through entryID: String) throws -> [PiHistoryEntry] {
        guard index[entryID] != nil else { throw PiHistoryGraphError(.invalidGraph) }
        return branchUnchecked(through: entryID)
    }
    private func branchUnchecked(through entryID: String?) -> [PiHistoryEntry] {
        var reverse: [PiHistoryEntry] = [], cursor = entryID
        while let id = cursor, let position = index[id] { let entry = entries[position]; reverse.append(entry); cursor = entry.parentID }
        return Array(reverse.reversed())
    }
    /// Exact SDK buildContextEntries order. A missing/off-branch firstKeptEntryId
    /// retains the summary and post-compaction suffix only, as the pinned reader
    /// does; it must not resurrect another branch or fabricate a user boundary.
    public var contextEntries: [PiHistoryEntry] {
        let path = activeBranch
        guard let compactIndex = path.lastIndex(where: { $0.kind == .compaction }) else { return path }
        let compaction = path[compactIndex], firstKept = compaction.raw["firstKeptEntryId"].string
        let firstIndex = path[..<compactIndex].firstIndex(where: { $0.id == firstKept })
        let kept = firstIndex.map { Array(path[$0..<compactIndex]) } ?? []
        return [compaction] + kept + Array(path.dropFirst(compactIndex + 1))
    }
    /// Entries which SDK sessionEntryToContextMessages projects into messages.
    /// This does not perform the later LLM conversion or copy summary text.
    public var contextMessageEntries: [PiHistoryEntry] { contextEntries.filter(\.contributesContextMessage) }
    public var activeBranchDigest: String { get throws { try PiHistoryValidation.digest(.array(activeBranch.map(\.raw))) } }
    public var contextDigest: String { get throws { try PiHistoryValidation.digest(.array(contextMessageEntries.map(\.raw))) } }

    /// The native RPC fork boundary is BEFORE this actual USER entry. IDs and
    /// payloads are unchanged; native label filtering/rechaining belongs to the
    /// eventual fork-result validator, not this source-prefix observation.
    public func retainedPrefix(beforeUserEntryID id: String) throws -> [PiHistoryEntry] {
        let path = activeBranch
        guard let position = path.firstIndex(where: { $0.id == id && $0.isUserMessage }) else { throw PiHistoryGraphError(.invalidGraph) }
        return Array(path[..<position])
    }
    /// A bounded prospective observation, NEVER temporal/run attribution. Both
    /// observations must have explicit runtime leaves, an unchanged full prior
    /// inventory, and a newly appended path that reaches the exact prior leaf.
    public func appendedActiveWindow(since previous: Self) throws -> PiHistoryReadWindow {
        guard leafOrigin == .runtime, previous.leafOrigin == .runtime, header == previous.header,
              entries.count >= previous.entries.count,
              Array(entries.prefix(previous.entries.count)) == previous.entries else { throw PiHistoryGraphError(.invalidWindow) }
        var reverse: [PiHistoryEntry] = [], cursor = leafID
        while cursor != previous.leafID {
            guard let id = cursor, let position = index[id], position >= previous.entries.count else { throw PiHistoryGraphError(.invalidWindow) }
            let entry = entries[position]; reverse.append(entry); cursor = entry.parentID
        }
        let path = Array(reverse.reversed())
        return .init(baselineLeafID: previous.leafID, leafID: leafID, entryIDs: path.map(\.id),
            userEntryIDs: path.filter(\.isUserMessage).map(\.id), beforeInventoryDigest: previous.inventoryDigest, afterInventoryDigest: inventoryDigest)
    }
}

public struct PiHistoryFileSnapshot: Sendable, Equatable {
    public let filePath: String
    public let graph: PiHistoryGraph
    public let byteDigest: String
    public let byteCount: Int
    public let device: UInt64
    public let inode: UInt64
}
public enum PiHistoryReadPhase: Sendable { case opened, read }

/// Only an explicitly named, fully anchored native file is read. No discovery,
/// migration, replacement runtime, credential read or native write occurs.
public struct PiHistoryFileReader: Sendable {
    private let observer: (@Sendable (PiHistoryReadPhase) throws -> Void)?
    public init(observer: (@Sendable (PiHistoryReadPhase) throws -> Void)? = nil) { self.observer = observer }
    public func read(filePath: String, expectedWorkspacePath: String, expectedSessionID: String? = nil) throws -> PiHistoryFileSnapshot {
        try PiHistoryValidation.absolutePath(filePath); try PiHistoryValidation.absolutePath(expectedWorkspacePath)
        let expectedPhysical = try PiHistoryValidation.physicalDirectory(expectedWorkspacePath)
        guard expectedPhysical == expectedWorkspacePath else { throw PiHistoryGraphError(.unavailable) }
        let parts = filePath.split(separator: "/").map(String.init)
        guard let name = parts.last else { throw PiHistoryGraphError(.unavailable) }
        var descriptors: [Int32] = [], links: [(Int32, String, stat)] = []
        defer { for descriptor in descriptors.reversed() { _ = Darwin.close(descriptor) } }
        let root = open("/", O_RDONLY | O_DIRECTORY | O_CLOEXEC)
        guard root >= 0 else { throw PiHistoryGraphError(.unavailable) }
        descriptors.append(root); var parent = root
        for component in parts.dropLast() {
            let child = openat(parent, component, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
            guard child >= 0 else { throw PiHistoryGraphError(.unavailable) }
            descriptors.append(child); var info = stat()
            guard fstat(child, &info) == 0, info.st_mode & S_IFMT == S_IFDIR else { throw PiHistoryGraphError(.unavailable) }
            links.append((parent, component, info)); parent = child
        }
        let descriptor = openat(parent, name, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        guard descriptor >= 0 else { throw PiHistoryGraphError(.unavailable) }
        descriptors.append(descriptor)
        var before = stat()
        guard fstat(descriptor, &before) == 0, PiHistoryValidation.regularOwned(before) else { throw PiHistoryGraphError(.unavailable) }
        guard before.st_size > 0 else { throw PiHistoryGraphError(.invalidHeader) }
        guard before.st_size <= PiHistoryGraph.maximumBytes else { throw PiHistoryGraphError(.oversized) }
        try observer?(.opened)
        var bytes = Data(), buffer = [UInt8](repeating: 0, count: 65_536)
        while true {
            let count = Darwin.read(descriptor, &buffer, buffer.count)
            if count < 0, errno == EINTR { continue }
            guard count >= 0 else { throw PiHistoryGraphError(.unavailable) }
            if count == 0 { break }
            guard bytes.count + count <= PiHistoryGraph.maximumBytes else { throw PiHistoryGraphError(.oversized) }
            bytes.append(contentsOf: buffer.prefix(count))
        }
        try observer?(.read)
        var after = stat(), named = stat()
        guard fstat(descriptor, &after) == 0, fstatat(parent, name, &named, AT_SYMLINK_NOFOLLOW) == 0,
              PiHistoryValidation.sameFile(before, after), PiHistoryValidation.sameFile(after, named),
              bytes.count == Int(before.st_size) else { throw PiHistoryGraphError(.changed) }
        for (anchor, component, expected) in links {
            var namedDirectory = stat()
            guard fstatat(anchor, component, &namedDirectory, AT_SYMLINK_NOFOLLOW) == 0,
                  namedDirectory.st_mode & S_IFMT == S_IFDIR, namedDirectory.st_dev == expected.st_dev,
                  namedDirectory.st_ino == expected.st_ino else { throw PiHistoryGraphError(.changed) }
        }
        let graph = try PiHistoryGraph.parse(bytes)
        guard try PiHistoryValidation.physicalDirectory(graph.header.workspacePath) == expectedPhysical,
              expectedSessionID == nil || expectedSessionID == graph.header.sessionID else { throw PiHistoryGraphError(.invalidHeader) }
        return .init(filePath: filePath, graph: graph, byteDigest: PiHistoryValidation.sha(bytes), byteCount: bytes.count,
            device: UInt64(before.st_dev), inode: UInt64(before.st_ino))
    }
}

/// Shared only by native file and live-RPC validation within CoincideCore.
enum PiHistoryValidation {
    static func identifier(_ raw: JSONValue, kind: PiHistoryGraphError.Kind = .invalidEntry) throws -> String {
        guard let string = raw.string, !string.isEmpty, string.utf8.count <= 4_096,
              !string.unicodeScalars.contains(where: { $0.value < 32 || $0.value == 127 }) else { throw PiHistoryGraphError(kind) }
        return string
    }
    static func path(_ raw: JSONValue, kind: PiHistoryGraphError.Kind) throws -> String {
        guard let path = raw.string else { throw PiHistoryGraphError(kind) }
        do { try absolutePath(path) } catch { throw PiHistoryGraphError(kind) }
        return path
    }
    static func absolutePath(_ path: String) throws {
        guard path.hasPrefix("/"), path != "/", path.utf8.count <= 16_384,
              !path.unicodeScalars.contains(where: { $0.value < 32 || $0.value == 127 }),
              !path.split(separator: "/", omittingEmptySubsequences: false).dropFirst().contains(where: { $0.isEmpty || $0 == "." || $0 == ".." }) else { throw PiHistoryGraphError(.unavailable) }
    }
    static func timestamp(_ raw: JSONValue, kind: PiHistoryGraphError.Kind = .invalidEntry) throws {
        guard let text = raw.string, !text.isEmpty, text.utf8.count <= 128 else { throw PiHistoryGraphError(kind) }
        if (try? Date.ISO8601FormatStyle(includingFractionalSeconds: true).parse(text)) == nil,
           (try? Date.ISO8601FormatStyle().parse(text)) == nil { throw PiHistoryGraphError(kind) }
    }
    static func content(_ raw: JSONValue) throws {
        guard raw.string != nil || raw.array != nil else { throw PiHistoryGraphError(.invalidEntry) }
    }
    static func value(_ root: JSONValue) throws {
        var pending: [(JSONValue, Int)] = [(root, 0)], nodes = 0
        while let (value, depth) = pending.popLast() {
            nodes += 1
            guard depth <= PiHistoryGraph.maximumDepth, nodes <= 500_000 else { throw PiHistoryGraphError(.oversized) }
            switch value {
            case .object(let object): for (key, child) in object { guard !key.contains("\0") else { throw PiHistoryGraphError(.invalidEntry) }; pending.append((child, depth + 1)) }
            case .array(let array): for child in array { pending.append((child, depth + 1)) }
            case .number(let number): guard number.isFinite else { throw PiHistoryGraphError(.invalidEntry) }
            default: break
            }
        }
    }
    static func bytes(_ raw: JSONValue) throws -> Data {
        try value(raw)
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        let bytes = try encoder.encode(raw)
        guard bytes.count <= PiHistoryGraph.maximumLineBytes else { throw PiHistoryGraphError(.oversized) }
        return bytes
    }
    static func digest(_ value: JSONValue) throws -> String { sha(try bytesForDigest(value)) }
    private static func bytesForDigest(_ value: JSONValue) throws -> Data {
        // Whole inventories exceed a single-line budget, but remain file-bounded.
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        let bytes = try encoder.encode(value)
        guard bytes.count <= PiHistoryGraph.maximumBytes + 1_048_576 else { throw PiHistoryGraphError(.oversized) }
        return bytes
    }
    static func sha(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }
    static func jsonDepth(_ bytes: Data.SubSequence) throws {
        var frames: [(object: Bool, expectsKey: Bool, keys: Set<String>)] = []
        var inString = false, escaped = false, stringStart = bytes.startIndex, keysSeen = 0
        for position in bytes.indices {
            let byte = bytes[position]
            if inString {
                if escaped { escaped = false }
                else if byte == 92 { escaped = true }
                else if byte == 34 {
                    inString = false
                    if let last = frames.indices.last, frames[last].object, frames[last].expectsKey {
                        let key: String
                        do { key = try JSONDecoder().decode(String.self, from: Data(bytes[stringStart...position])) }
                        catch { throw PiHistoryGraphError(.invalidEntry) }
                        keysSeen += 1
                        guard keysSeen <= 500_000 else { throw PiHistoryGraphError(.oversized) }
                        guard frames[last].keys.insert(key).inserted else { throw PiHistoryGraphError(.invalidEntry) }
                        frames[last].expectsKey = false
                    }
                }
            } else if byte == 34 { inString = true; stringStart = position }
            else if byte == 123 || byte == 91 {
                frames.append((byte == 123, byte == 123, []))
                guard frames.count <= PiHistoryGraph.maximumDepth else { throw PiHistoryGraphError(.oversized) }
            } else if byte == 125 || byte == 93 {
                guard let last = frames.popLast(), last.object == (byte == 125) else { throw PiHistoryGraphError(.invalidEntry) }
            } else if byte == 44, let last = frames.indices.last, frames[last].object { frames[last].expectsKey = true }
        }
        guard !inString, frames.isEmpty else { throw PiHistoryGraphError(.invalidEntry) }
    }
    static func physicalDirectory(_ path: String) throws -> String {
        try absolutePath(path)
        guard let pointer = path.withCString({ realpath($0, nil) }) else { throw PiHistoryGraphError(.unavailable) }
        let physical = String(cString: pointer); free(pointer)
        var info = stat()
        guard physical.withCString({ stat($0, &info) }) == 0, info.st_mode & S_IFMT == S_IFDIR else { throw PiHistoryGraphError(.unavailable) }
        return physical
    }
    static func regularOwned(_ info: stat) -> Bool { info.st_mode & S_IFMT == S_IFREG && info.st_uid == geteuid() && info.st_nlink == 1 }
    static func sameFile(_ first: stat, _ second: stat) -> Bool {
        regularOwned(first) && regularOwned(second) && first.st_dev == second.st_dev && first.st_ino == second.st_ino && first.st_size == second.st_size &&
        first.st_mtimespec.tv_sec == second.st_mtimespec.tv_sec && first.st_mtimespec.tv_nsec == second.st_mtimespec.tv_nsec &&
        first.st_ctimespec.tv_sec == second.st_ctimespec.tv_sec && first.st_ctimespec.tv_nsec == second.st_ctimespec.tv_nsec
    }
}

private extension JSONValue {
    var numberValue: Double? { if case .number(let value) = self { value } else { nil } }
}
