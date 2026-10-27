import Foundation

/// Streams a running command's output. Claude Code reports a Bash call's output only when it
/// finishes, but writes it to a task file as it runs; T3 tails that file the same way. The layout
/// is private to Claude Code, so any failure only means no live output.
@MainActor
final class ClaudeTaskOutputTail {
    private static let pollInterval: Duration = .milliseconds(250)
    private static let locateAttempts = 40
    /// Only the tail is shown, so fast writers are skipped ahead.
    private static let maxReadBytes: UInt64 = 256 * 1024

    private let root: URL
    private let sessionID: String
    private let taskID: String
    private let onChunk: (String) -> Void
    private var task: Task<Void, Never>?
    private var decoder = UTF8Stream()

    init(root: URL, sessionID: String, taskID: String, onChunk: @escaping (String) -> Void) {
        self.root = root
        self.sessionID = sessionID
        self.taskID = taskID
        self.onChunk = onChunk
    }

    /// Claude Code's per-user temporary folder: `$CLAUDE_CODE_TMPDIR/claude-<uid>` or `/tmp/claude-<uid>`.
    nonisolated static func root(environment: [String: String]) -> URL {
        let base = environment["CLAUDE_CODE_TMPDIR"].flatMap { $0.isEmpty ? nil : $0 } ?? "/tmp"
        return URL(fileURLWithPath: base, isDirectory: true).appendingPathComponent("claude-\(getuid())", isDirectory: true)
    }

    func start() {
        task = Task { [weak self] in await self?.run() }
    }

    /// Stops reading; the tool's final output replaces whatever was streamed.
    func cancel() {
        task?.cancel()
        task = nil
    }

    private func run() async {
        var file: URL?
        for _ in 0..<Self.locateAttempts {
            file = locate()
            if file != nil || Task.isCancelled { break }
            try? await Task.sleep(for: Self.pollInterval)
        }
        guard let file else { return }
        var offset: UInt64 = 0
        while !Task.isCancelled {
            offset = read(file, from: offset)
            try? await Task.sleep(for: Self.pollInterval)
        }
    }

    private func locate() -> URL? {
        let projects = (try? FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)) ?? []
        for project in projects {
            let candidate = project.appendingPathComponent(sessionID).appendingPathComponent("tasks")
                .appendingPathComponent("\(taskID).output")
            if FileManager.default.fileExists(atPath: candidate.path) { return candidate }
        }
        return nil
    }

    private func read(_ file: URL, from offset: UInt64) -> UInt64 {
        guard let handle = try? FileHandle(forReadingFrom: file) else { return offset }
        defer { try? handle.close() }
        guard let size = try? handle.seekToEnd() else { return offset }
        var start = size < offset ? 0 : offset
        guard size > start else { return size }
        let skipped = size - start > Self.maxReadBytes
        if skipped {
            start = size - Self.maxReadBytes
            decoder = UTF8Stream()
        }
        guard (try? handle.seek(toOffset: start)) != nil, let data = try? handle.read(upToCount: Int(size - start)) else {
            return offset
        }
        // Skipped output must not splice two unrelated lines together.
        let text = (skipped ? "\n" : "") + decoder.decode(data)
        let visible = text.replacingOccurrences(of: "\u{1B}\\[[0-9;?]*[ -/]*[@-~]", with: "", options: .regularExpression)
        if !visible.isEmpty { onChunk(visible) }
        return start + UInt64(data.count)
    }
}

/// Decodes UTF-8 that arrives in pieces, holding back a character split across reads.
struct UTF8Stream {
    private var pending = Data()

    mutating func decode(_ data: Data) -> String {
        let bytes = [UInt8](pending + data)
        var cut = bytes.count
        // Find the last lead byte; if its sequence is incomplete, keep it for the next read.
        var index = bytes.count - 1
        while index >= 0, bytes.count - index <= 4 {
            let byte = bytes[index]
            if byte & 0xC0 != 0x80 {
                let length = byte < 0x80 ? 1 : byte >= 0xF0 ? 4 : byte >= 0xE0 ? 3 : byte >= 0xC0 ? 2 : 1
                if bytes.count - index < length { cut = index }
                break
            }
            index -= 1
        }
        pending = Data(bytes[cut...])
        return String(decoding: bytes[..<cut], as: UTF8.self)
    }
}
