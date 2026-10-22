import Foundation

/// One lossless transport consumer produces bounded complete text replacements for every window.
actor ProjectScriptRunLog {
    let id: UUID
    private var text = "", pending = Data(), sequence: UInt64 = 0
    private var truncated = false, closed = false, lineLength = 0, previousCR = false
    private enum Escape { case none, escape, csi, osc, oscEscape }
    private var escape = Escape.none
    private var listeners: [UUID: AsyncStream<ProjectScriptOutputSnapshot>.Continuation] = [:]
    private var publishTask: Task<Void, Never>?
    init(id: UUID) { self.id = id }
    func stream() -> AsyncStream<ProjectScriptOutputSnapshot> {
        let pair = AsyncStream<ProjectScriptOutputSnapshot>.makeStream(bufferingPolicy: .bufferingNewest(1))
        pair.continuation.yield(snapshot())
        if closed { pair.continuation.finish(); return pair.stream }
        let token = UUID(); listeners[token] = pair.continuation
        pair.continuation.onTermination = { [weak self] _ in Task { await self?.remove(token) } }
        return pair.stream
    }
    private func remove(_ id: UUID) { listeners.removeValue(forKey: id) }
    func append(_ data: Data) {
        guard !closed else { return }
        pending.append(data)
        var bytes = Array(pending), tail = 0
        // Retain only an incomplete trailing UTF8 scalar. Invalid complete sequences render as U+FFFD.
        if let last = bytes.last {
            var start = bytes.count - 1
            while start > 0 && bytes[start] & 0xc0 == 0x80 { start -= 1 }
            let lead = bytes[start], length = (0xc2...0xdf).contains(lead) ? 2 : (0xe0...0xef).contains(lead) ? 3 : (0xf0...0xf4).contains(lead) ? 4 : 0
            if last >= 0x80, length > bytes.count - start { tail = bytes.count - start }
        }
        pending = Data(bytes.suffix(tail)); if tail > 0 { bytes.removeLast(tail) }
        for scalar in String(decoding: bytes, as: UTF8.self).unicodeScalars {
            switch escape {
            case .escape: escape = scalar == "[" ? .csi : scalar == "]" ? .osc : .none; continue
            case .csi: if (0x40...0x7e).contains(scalar.value) { escape = .none }; continue
            case .osc: if scalar.value == 7 { escape = .none } else if scalar.value == 27 { escape = .oscEscape }; continue
            case .oscEscape: escape = scalar == "\\" ? .none : .osc; continue
            case .none: break
            }
            if scalar.value == 27 { escape = .escape; continue }
            if scalar == "\r" { text.append("\n"); previousCR = true; lineLength = 0; continue }
            if scalar == "\n" { if !previousCR { text.append("\n") }; previousCR = false; lineLength = 0; continue }
            previousCR = false
            guard scalar.value == 9 || scalar.value >= 32 && scalar.value != 127 else { continue }
            if lineLength < 400 { text.unicodeScalars.append(scalar); lineLength += 1 }
            else { truncated = true }
        }
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false)
        if lines.count > 500 { text = lines.suffix(500).joined(separator: "\n"); truncated = true }
        if text.utf8.count > 65_536 {
            var suffix = Array(text.utf8.suffix(65_536))
            while suffix.first.map({ $0 & 0xc0 == 0x80 }) == true { suffix.removeFirst() }
            text = String(decoding: suffix, as: UTF8.self); truncated = true
        }
        sequence &+= 1
        if publishTask == nil {
            publishTask = Task { [weak self] in try? await Task.sleep(for: .milliseconds(30)); await self?.publish() }
        }
    }
    private func snapshot() -> ProjectScriptOutputSnapshot { .init(runID: id, sequence: sequence, text: text, truncated: truncated, isClosed: closed) }
    private func publish() { publishTask = nil; let value = snapshot(); for listener in listeners.values { listener.yield(value) } }
    func close() {
        guard !closed else { return }; closed = true; sequence &+= 1; publishTask?.cancel(); publishTask = nil
        let value = snapshot(); for listener in listeners.values { listener.yield(value); listener.finish() }; listeners = [:]
    }
}
