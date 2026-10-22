import Darwin
import Foundation

enum ScriptWire {
    static let version = 1
    static let controlFD: Int32 = 3, statusFD: Int32 = 4, outputFD: Int32 = 5
    static let maximumFrame = 1_048_576
    static let maximumStatus = 16_384
    static let maximumInput = 16_384
    struct Message: Codable, Sendable {
        let version: Int
        let runID: UUID
        let kind: String
        var plan: ProjectScriptExecutionPlan?
        var input: Data?
        var columns: Int?
        var rows: Int?
        var code: Int32?
        var failure: String?
        init(_ kind: String, id: UUID) { self.version = ScriptWire.version; runID = id; self.kind = kind }
        func validate() throws {
            guard version == ScriptWire.version else { throw ProjectScriptExecutionError(.protocolViolation) }
            let valid: Bool
            switch kind {
            case "prepare": valid = plan != nil && input == nil && columns == nil && rows == nil && code == nil && failure == nil
            case "input": valid = plan == nil && input != nil && columns == nil && rows == nil && code == nil && failure == nil
            case "resize": valid = plan == nil && input == nil && columns != nil && rows != nil && code == nil && failure == nil
            case "exited", "signaled": valid = plan == nil && input == nil && columns == nil && rows == nil && code != nil && failure == nil
            case "error": valid = plan == nil && input == nil && columns == nil && rows == nil && code == nil && ["configurationChanged", "protocolViolation", "launchFailed"].contains(failure)
            case "ready", "prepared", "start", "started", "stop", "helperClosed":
                valid = plan == nil && input == nil && columns == nil && rows == nil && code == nil && failure == nil
            default: valid = false
            }
            guard valid else { throw ProjectScriptExecutionError(.protocolViolation) }
        }
    }
    static func frame(_ message: Message, maximum: Int = maximumFrame) throws -> Data {
        try message.validate()
        let payload = try JSONEncoder().encode(message)
        guard !payload.isEmpty, payload.count <= maximum else { throw ProjectScriptExecutionError(.protocolViolation) }
        var result = Data()
        var length = UInt32(payload.count).bigEndian
        withUnsafeBytes(of: &length) { result.append(contentsOf: $0) }; result.append(payload)
        return result
    }
    struct Decoder {
        var bytes = Data()
        let maximum: Int
        mutating func append(_ data: Data) throws -> [Message] {
            // One read is bounded; one partial frame plus the next read is the maximum allocation.
            guard bytes.count + data.count <= maximum + 65_540 else { throw ProjectScriptExecutionError(.protocolViolation) }
            bytes.append(data); var messages: [Message] = []
            while bytes.count >= 4 {
                let length = bytes.prefix(4).reduce(UInt32(0)) { ($0 << 8) | UInt32($1) }
                guard length > 0, length <= maximum else { throw ProjectScriptExecutionError(.protocolViolation) }
                guard bytes.count >= 4 + Int(length) else { break }
                let payload = Data(bytes.dropFirst(4).prefix(Int(length)))
                let allowed: Set<String> = ["version", "runID", "kind", "plan", "input", "columns", "rows", "code", "failure"]
                guard let object = try? JSONSerialization.jsonObject(with: payload) as? [String: Any], Set(object.keys).isSubset(of: allowed) else {
                    throw ProjectScriptExecutionError(.protocolViolation)
                }
                let value: Message
                do { value = try JSONDecoder().decode(Message.self, from: payload) }
                catch { throw ProjectScriptExecutionError(.protocolViolation) }
                try value.validate()
                messages.append(value); bytes.removeFirst(4 + Int(length))
            }
            return messages
        }
    }
    static func setNonblocking(_ fd: Int32) throws {
        let flags = fcntl(fd, F_GETFL)
        guard flags >= 0, fcntl(fd, F_SETFL, flags | O_NONBLOCK) == 0,
              fcntl(fd, F_SETFD, fcntl(fd, F_GETFD) | FD_CLOEXEC) == 0 else { throw ProjectScriptExecutionError(.launchFailed) }
        _ = fcntl(fd, F_SETNOSIGPIPE, 1)
    }
    static func elevated(_ fd: Int32, minimum: Int32 = 10) throws -> Int32 {
        guard fd >= 0 else { throw ProjectScriptExecutionError(.launchFailed) }
        if fd >= minimum {
            guard fcntl(fd, F_SETFD, fcntl(fd, F_GETFD) | FD_CLOEXEC) == 0 else { throw ProjectScriptExecutionError(.launchFailed) }
            return fd
        }
        let copy = fcntl(fd, F_DUPFD_CLOEXEC, minimum)
        guard copy >= 0 else { throw ProjectScriptExecutionError(.launchFailed) }
        Darwin.close(fd); return copy
    }
    /// A census failure is not evidence of an empty process group.
    static func groupMembers(_ group: pid_t, excluding: pid_t) throws -> [pid_t] {
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PGRP, group]
        for _ in 0..<4 {
            var size = 0
            guard sysctl(&mib, 4, nil, &size, nil, 0) == 0 else { throw ProjectScriptExecutionError(.launchFailed) }
            let count = max(1, size / MemoryLayout<kinfo_proc>.stride + 16)
            var values = [kinfo_proc](repeating: kinfo_proc(), count: count)
            size = values.count * MemoryLayout<kinfo_proc>.stride
            if sysctl(&mib, 4, &values, &size, nil, 0) == 0 {
                return values.prefix(size / MemoryLayout<kinfo_proc>.stride).compactMap {
                    let process = $0.kp_proc
                    return process.p_pid != excluding && process.p_stat != SZOMB ? process.p_pid : nil
                }
            }
            if errno != ENOMEM && errno != EINTR { break }
        }
        throw ProjectScriptExecutionError(.launchFailed)
    }
}

/// Cancellation detaches one waiter without cancelling a shared process or another waiter.
final class ScriptPromise<Value: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var result: Result<Value, any Error>?
    private var waiters: [UUID: CheckedContinuation<Value, any Error>] = [:]
    private var cancelled: Set<UUID> = []
    func finish(_ value: Result<Value, any Error>) {
        let pending = lock.withLock { () -> [CheckedContinuation<Value, any Error>] in
            guard result == nil else { return [] }; result = value
            let values = Array(waiters.values); waiters.removeAll(); return values
        }
        for waiter in pending { waiter.resume(with: value) }
    }
    func value() async throws -> Value {
        let id = UUID()
        defer { lock.withLock { _ = cancelled.remove(id) } }
        return try await withTaskCancellationHandler {
            try Task.checkCancellation()
            let value = try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Value, any Error>) in
                let value = lock.withLock { () -> Result<Value, any Error>? in
                    if cancelled.remove(id) != nil { return .failure(CancellationError()) }
                    if let result { return result }
                    waiters[id] = continuation; return nil
                }
                if let value { continuation.resume(with: value) }
            }
            try Task.checkCancellation(); return value
        } onCancel: {
            let waiter = self.lock.withLock { () -> CheckedContinuation<Value, any Error>? in
                if let waiter = self.waiters.removeValue(forKey: id) { return waiter }
                self.cancelled.insert(id); return nil
            }
            waiter?.resume(throwing: CancellationError())
        }
    }
}

/// Lossless raw-byte queue. At most eight 16KiB chunks can await the sole consumer.
final class ScriptOutputQueue: @unchecked Sendable {
    private let condition = NSCondition()
    private var chunks: [ProjectScriptOutputChunk] = []
    private var waiter: CheckedContinuation<ProjectScriptOutputChunk?, Never>?
    private var ended = false, discard = false
    private var sequence: UInt64 = 0
    func push(_ data: Data) {
        condition.lock()
        while chunks.count >= 8 && !discard { condition.wait() }
        guard !discard else { condition.unlock(); return }
        let chunk = ProjectScriptOutputChunk(sequence: sequence, data: data); sequence &+= 1
        if let waiter { self.waiter = nil; condition.unlock(); waiter.resume(returning: chunk) }
        else { chunks.append(chunk); condition.unlock() }
    }
    func next() async -> ProjectScriptOutputChunk? {
        await withCheckedContinuation { continuation in
            condition.lock()
            if !chunks.isEmpty {
                let chunk = chunks.removeFirst(); condition.broadcast(); condition.unlock(); continuation.resume(returning: chunk)
            } else if ended { condition.unlock(); continuation.resume(returning: nil) }
            else { waiter = continuation; condition.unlock() }
        }
    }
    func finish(discard: Bool = false) {
        condition.lock(); ended = true
        if discard { self.discard = true; chunks.removeAll() }
        let waiter = self.waiter; self.waiter = nil; condition.broadcast(); condition.unlock()
        waiter?.resume(returning: nil)
    }
}
