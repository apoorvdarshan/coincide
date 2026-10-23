import Foundation

/// Incremental field selection for JSONL. Unselected strings (tool output,
/// images, credentials and private reasoning) never enter an allocated value.
/// The grammar is validated even when a value is skipped; duplicate keys retain
/// their final value just as JSON.parse does in the pinned importer.
final class AgentSessionJSONSelector {
    private enum Kind { case object, array }
    private enum Expect { case keyOrEnd, key, colon, valueOrEnd, value, commaOrEnd }
    private struct Frame {
        let kind: Kind; let path: [String]; let selected: Bool
        var expect: Expect; var key: String?
        var fields: [String: JSONValue] = [:]; var values: [JSONValue] = []
    }
    private enum Mode { case normal, string, number, literal }
    private var mode = Mode.normal, frames: [Frame] = []
    private var raw = Data(), literal: [UInt8] = [], literalIndex = 0
    private var isKey = false, capturing = false, ignoredKey = false, escaped = false, unicode = 0
    private var root: JSONValue?, completed = false, malformed = false, selectedBytes = 0
    private let maximum: Int
    private let metadataOnly: Bool
    init(maximumSelectedBytes: Int, metadataOnly: Bool = false) { maximum = maximumSelectedBytes; self.metadataOnly = metadataOnly }

    func feed(_ byte: UInt8) throws {
        guard !malformed else { return }
        switch mode {
        case .string:
            if unicode > 0 {
                guard (48...57).contains(byte) || (65...70).contains(byte) || (97...102).contains(byte) else { malformed = true; return }
                unicode -= 1; try append(byte); return
            }
            if escaped {
                escaped = false
                guard [34, 47, 92, 98, 102, 110, 114, 116, 117].contains(byte) else { malformed = true; return }
                if byte == 117 { unicode = 4 }; try append(byte); return
            }
            if byte == 92 { escaped = true; try append(byte); return }
            if byte == 34 {
                try append(byte); mode = .normal
                if isKey {
                    guard !frames.isEmpty else { malformed = true; return }
                    if ignoredKey { frames[frames.count - 1].key = nil }
                    else {
                        guard let value = try? JSONDecoder().decode(JSONValue.self, from: raw), let key = value.string else { malformed = true; return }
                        frames[frames.count - 1].key = key
                    }
                    frames[frames.count - 1].expect = .colon
                } else {
                    let value = capturing ? try? JSONDecoder().decode(JSONValue.self, from: raw) : nil
                    if capturing && value == nil { malformed = true; return }; emit(value)
                }
                raw.removeAll(keepingCapacity: true); return
            }
            guard byte >= 32 else { malformed = true; return }; try append(byte)
        case .number:
            if [44, 93, 125, 9, 13, 32].contains(byte) {
                finishNumber(); try feed(byte)
            } else {
                guard [45, 43, 46, 69, 101].contains(byte) || (48...57).contains(byte), raw.count < 256 else { malformed = true; return }
                raw.append(byte)
            }
        case .literal:
            guard literalIndex < literal.count, byte == literal[literalIndex] else { malformed = true; return }
            literalIndex += 1
            if literalIndex == literal.count {
                mode = .normal
                emit(capturing ? (literal == Array("true".utf8) ? .bool(true) : literal == Array("false".utf8) ? .bool(false) : .null) : nil)
            }
        case .normal:
            if [9, 13, 32].contains(byte) { return }
            if completed { malformed = true; return }
            if let last = frames.last {
                switch last.expect {
                case .colon:
                    guard byte == 58 else { malformed = true; return }; frames[frames.count - 1].expect = .value; return
                case .commaOrEnd:
                    if byte == 44 { frames[frames.count - 1].expect = last.kind == .object ? .key : .value; return }
                    guard byte == (last.kind == .object ? 125 : 93) else { malformed = true; return }; endContainer(); return
                case .keyOrEnd, .key:
                    if byte == 125 && last.expect == .keyOrEnd { endContainer(); return }
                    guard byte == 34 else { malformed = true; return }
                    beginString(key: true, selected: last.selected); return
                case .valueOrEnd:
                    if byte == 93 { endContainer(); return }
                case .value: break
                }
            }
            let path = valuePath(), selected = (frames.last?.selected ?? true) && select(path)
            switch byte {
            case 123, 91:
                guard frames.count < 128 else { throw AgentSessionImportError.limit }
                if selected { selectedBytes += 64; guard selectedBytes <= maximum else { throw AgentSessionImportError.limit } }
                frames.append(.init(kind: byte == 123 ? .object : .array, path: path, selected: selected, expect: byte == 123 ? .keyOrEnd : .valueOrEnd))
            case 34: beginString(key: false, selected: selected)
            case 116, 102, 110:
                literal = Array((byte == 116 ? "true" : byte == 102 ? "false" : "null").utf8); literalIndex = 1; capturing = selected; mode = .literal
            case 45, 48...57:
                raw = Data([byte]); capturing = selected; mode = .number
            default: malformed = true
            }
        }
    }
    func finishLine() throws -> JSONValue? {
        if mode == .number { finishNumber() }
        let value = !malformed && completed && mode == .normal && frames.isEmpty ? root : nil
        mode = .normal; frames = []; raw = Data(); literal = []; root = nil; completed = false; malformed = false
        selectedBytes = 0; escaped = false; unicode = 0; ignoredKey = false
        return value
    }
    private func beginString(key: Bool, selected: Bool) {
        mode = .string; isKey = key; capturing = selected; ignoredKey = key && !selected
        raw = selected ? Data([34]) : Data(); escaped = false; unicode = 0
    }
    private func append(_ byte: UInt8) throws {
        guard capturing else { return }
        if isKey && raw.count >= 4_096 { ignoredKey = true; capturing = false; raw.removeAll(keepingCapacity: false); return }
        selectedBytes += 1; guard selectedBytes <= maximum else { throw AgentSessionImportError.limit }
        raw.append(byte)
    }
    private func finishNumber() {
        guard let value = try? JSONDecoder().decode(JSONValue.self, from: raw), case .number(let number) = value, number.isFinite else { malformed = true; return }
        mode = .normal; emit(capturing ? value : nil); raw.removeAll(keepingCapacity: true)
    }
    private func valuePath() -> [String] {
        guard let last = frames.last else { return [] }
        return last.path + [last.kind == .array ? "*" : last.key ?? "<ignored>"]
    }
    private func endContainer() {
        guard let frame = frames.popLast() else { malformed = true; return }
        emit(frame.selected ? (frame.kind == .object ? .object(frame.fields) : .array(frame.values)) : nil)
    }
    private func emit(_ value: JSONValue?) {
        guard !frames.isEmpty else { root = value; completed = true; return }
        let i = frames.count - 1
        if frames[i].selected, let value {
            if frames[i].kind == .object, let key = frames[i].key { frames[i].fields[key] = value }
            else if frames[i].kind == .array { frames[i].values.append(value) }
        }
        frames[i].expect = .commaOrEnd
    }
    private func select(_ path: [String]) -> Bool {
        guard let first = path.first else { return true }
        if metadataOnly {
            if path.count == 1 { return ["type", "cwd", "payload"].contains(first) }
            return first == "payload" && (path.count == 2 && ["cwd", "source"].contains(path[1]) || path.count == 3 && path[1] == "source" && ["subagent", "subAgent"].contains(path[2]))
        }
        if path.count == 1 { return ["type", "timestamp", "cwd", "sessionId", "aiTitle", "customTitle", "isSidechain", "isMeta", "isCompactSummary", "message", "payload"].contains(first) }
        if first == "message" {
            if path.count == 2 { return ["role", "content", "model"].contains(path[1]) }
            return path[1] == "content" && (path.count == 3 || (path.count == 4 && ["type", "text"].contains(path[3])))
        }
        if first == "payload" {
            if path.count == 2 { return ["id", "session_id", "type", "role", "message", "model", "cwd", "content", "source", "internal_chat_message_metadata_passthrough"].contains(path[1]) }
            if path[1] == "content" { return path.count == 3 || (path.count == 4 && ["type", "text"].contains(path[3])) }
            if path[1] == "internal_chat_message_metadata_passthrough" { return path.count == 3 && path[2] == "turn_id" }
            if path[1] == "source" { return path.count == 3 && ["subagent", "subAgent"].contains(path[2]) }
        }
        return false
    }
}
