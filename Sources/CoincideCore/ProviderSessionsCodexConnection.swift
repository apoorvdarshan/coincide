import CryptoKit
import Darwin
import Foundation

/// The existing Codex control socket speaks RFC 6455, not newline-delimited
/// stdio JSON-RPC. Keep this small, local-only client separate from chat runtimes.
/// It never creates a daemon, resumes a thread, or subscribes to approvals.
final class ProviderSessionsCodexConnection {
    private let descriptor: Int32
    private let lifetime: SocketLifetime
    private var buffered = Data()
    private var sequence = 0
    private var deadline: TimeInterval = 0
    private static let maximumMessage = 8 * 1_024 * 1_024

    static func perform<T: Sendable>(socketPath: String, operation: @escaping @Sendable (ProviderSessionsCodexConnection) throws -> T) async throws -> T {
        let lifetime = SocketLifetime()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                // Blocking Unix I/O stays off Swift's cooperative executor. poll
                // has a deadline, and task cancellation shuts down this socket only.
                DispatchQueue.global(qos: .userInitiated).async {
                    defer { lifetime.finish() }
                    do {
                        let connection = try ProviderSessionsCodexConnection(socketPath: socketPath, lifetime: lifetime)
                        try lifetime.checkCancellation()
                        _ = try connection.request("initialize", params: .object([
                            "clientInfo": .object(["name": .string("coincide_sessions"), "title": .string("Coincide Sessions"), "version": .string("0.1.0")]),
                            "capabilities": .object(["experimentalApi": .bool(true)])
                        ]))
                        try connection.send(.object(["method": .string("initialized")]))
                        try lifetime.checkCancellation()
                        let result = try operation(connection)
                        try lifetime.checkCancellation()
                        continuation.resume(returning: result)
                    } catch {
                        if lifetime.isCancelled { continuation.resume(throwing: CancellationError()) }
                        else { continuation.resume(throwing: error) }
                    }
                }
            }
        } onCancel: { lifetime.cancel() }
    }

    private init(socketPath: String, lifetime: SocketLifetime) throws {
        self.lifetime = lifetime
        try lifetime.checkCancellation()
        let target = URL(fileURLWithPath: socketPath).resolvingSymlinksInPath().path
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: target), attributes[.type] as? FileAttributeType == .typeSocket else {
            throw CoincideError("No running Codex daemon is available for this configuration. Open Codex first, then refresh. Coincide does not start a background daemon here.")
        }
        var address = sockaddr_un()
        guard target.utf8.count < MemoryLayout.size(ofValue: address.sun_path) else {
            throw CoincideError("The Codex daemon socket path is too long.")
        }
        descriptor = socket(AF_UNIX, SOCK_STREAM, 0)
        guard descriptor >= 0 else { throw Self.unavailable() }
        try lifetime.own(descriptor)
        _ = fcntl(descriptor, F_SETFD, FD_CLOEXEC)
        _ = fcntl(descriptor, F_SETFL, O_NONBLOCK)
        var noSIGPIPE: Int32 = 1
        _ = setsockopt(descriptor, SOL_SOCKET, SO_NOSIGPIPE, &noSIGPIPE, socklen_t(MemoryLayout<Int32>.size))
        address.sun_family = sa_family_t(AF_UNIX)
        address.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
        withUnsafeMutableBytes(of: &address.sun_path) { bytes in
            bytes.copyBytes(from: Array(target.utf8) + [0])
        }
        deadline = ProcessInfo.processInfo.systemUptime + 10
        let result = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.connect(descriptor, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
        }
        if result != 0 {
            guard errno == EINPROGRESS else { throw Self.unavailable() }
            try wait(POLLOUT)
            var error: Int32 = 0, length = socklen_t(MemoryLayout<Int32>.size)
            guard getsockopt(descriptor, SOL_SOCKET, SO_ERROR, &error, &length) == 0, error == 0 else { throw Self.unavailable() }
        }
        try handshake()
    }

    func request(_ method: String, params: JSONValue) throws -> JSONValue {
        try lifetime.checkCancellation()
        deadline = ProcessInfo.processInfo.systemUptime + 15
        sequence += 1
        let id = JSONValue.number(Double(sequence))
        try send(.object(["id": id, "method": .string(method), "params": params]))
        for _ in 0..<512 {
            let frame = try JSONDecoder().decode(JSONValue.self, from: message())
            if frame["id"] == id, frame["method"].string == nil {
                guard frame["error"] == .null else {
                    throw CoincideError("The running Codex daemon could not complete this session action. It may require a newer CLI, or the session may have changed. Refresh and try again.")
                }
                return frame["result"]
            }
            // Neither approve nor reject requests owned by another client. The
            // inspection client did not start work and has no approval authority.
            if frame["method"].string != nil, frame["id"] != .null {
                throw CoincideError("Codex requested an interactive action. Handle it in the original Codex session, then refresh.")
            }
        }
        throw CoincideError("Codex sent too many events while reading session metadata.")
    }

    private func handshake() throws {
        let key = Data((0..<16).map { _ in UInt8.random(in: .min ... .max) }).base64EncodedString()
        let request = "GET / HTTP/1.1\r\nHost: localhost\r\nUpgrade: websocket\r\nConnection: Upgrade\r\nSec-WebSocket-Key: \(key)\r\nSec-WebSocket-Version: 13\r\n\r\n"
        try write(Data(request.utf8))
        let delimiter = Data("\r\n\r\n".utf8)
        while buffered.range(of: delimiter) == nil {
            guard buffered.count < 16_384 else { throw Self.unavailable() }
            try receive()
        }
        guard let range = buffered.range(of: delimiter), range.upperBound <= 16_384 else { throw Self.unavailable() }
        let header = String(decoding: buffered[..<range.lowerBound], as: UTF8.self)
        buffered.removeSubrange(..<range.upperBound)
        let lines = header.components(separatedBy: "\r\n")
        guard lines.first?.split(separator: " ").dropFirst().first == "101" else { throw Self.unavailable() }
        var fields: [String: String] = [:]
        for line in lines.dropFirst() {
            guard let colon = line.firstIndex(of: ":") else { continue }
            fields[String(line[..<colon]).lowercased()] = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
        }
        let expected = Data(Insecure.SHA1.hash(data: Data((key + "258EAFA5-E914-47DA-95CA-C5AB0DC85B11").utf8))).base64EncodedString()
        guard fields["sec-websocket-accept"] == expected,
              fields["upgrade"]?.lowercased() == "websocket",
              fields["connection"]?.lowercased().components(separatedBy: ",").map({ $0.trimmingCharacters(in: .whitespaces) }).contains("upgrade") == true else {
            throw Self.unavailable()
        }
    }

    private func send(_ value: JSONValue) throws { try write(Self.clientFrame(try JSONEncoder().encode(value))) }

    static func clientFrame(_ payload: Data, opcode: UInt8 = 1) -> Data {
        let mask = (0..<4).map { _ in UInt8.random(in: .min ... .max) }
        var frame = Data([0x80 | opcode])
        if payload.count < 126 { frame.append(0x80 | UInt8(payload.count)) }
        else if payload.count <= 65_535 {
            frame.append(0x80 | 126)
            frame.append(UInt8(payload.count >> 8)); frame.append(UInt8(payload.count & 0xff))
        } else {
            frame.append(0x80 | 127)
            for shift in stride(from: 56, through: 0, by: -8) { frame.append(UInt8((UInt64(payload.count) >> shift) & 0xff)) }
        }
        frame.append(contentsOf: mask)
        frame.append(contentsOf: payload.enumerated().map { $0.element ^ mask[$0.offset % 4] })
        return frame
    }

    private func message() throws -> Data {
        var contents = Data(), started = false
        for _ in 0..<512 {
            let prefix = try take(2), first = prefix[prefix.startIndex], second = prefix[prefix.index(after: prefix.startIndex)]
            let final = first & 0x80 != 0, opcode = first & 0x0f
            guard first & 0x70 == 0, second & 0x80 == 0 else { throw Self.unavailable() }
            var length = UInt64(second & 0x7f)
            if length == 126 { length = try take(2).reduce(0) { ($0 << 8) | UInt64($1) } }
            else if length == 127 { length = try take(8).reduce(0) { ($0 << 8) | UInt64($1) } }
            guard length <= Self.maximumMessage, contents.count <= Self.maximumMessage - Int(length) else {
                throw CoincideError("The Codex session response exceeded the inspection limit.")
            }
            let payload = try take(Int(length))
            if opcode >= 8 {
                guard final, payload.count <= 125 else { throw Self.unavailable() }
                if opcode == 8 { throw Self.unavailable() }
                if opcode == 9 { try write(Self.clientFrame(payload, opcode: 10)) }
                else if opcode != 10 { throw Self.unavailable() }
                continue
            }
            guard (opcode == 1 && !started) || (opcode == 0 && started) else { throw Self.unavailable() }
            started = true; contents.append(payload)
            if final { return contents }
        }
        throw Self.unavailable()
    }

    private func take(_ count: Int) throws -> Data {
        while buffered.count < count { try receive() }
        let bytes = Data(buffered.prefix(count)); buffered.removeFirst(count)
        return bytes
    }
    private func receive() throws {
        while true {
            try lifetime.checkCancellation()
            try wait(POLLIN)
            var bytes = [UInt8](repeating: 0, count: 8_192)
            let count = recv(descriptor, &bytes, bytes.count, 0)
            if count < 0, errno == EINTR || errno == EAGAIN { continue }
            guard count > 0 else { throw Self.unavailable() }
            buffered.append(contentsOf: bytes.prefix(count))
            return
        }
    }
    private func write(_ data: Data) throws {
        var offset = 0
        while offset < data.count {
            try lifetime.checkCancellation()
            try wait(POLLOUT)
            let written = data.withUnsafeBytes { bytes in Darwin.send(descriptor, bytes.baseAddress!.advanced(by: offset), data.count - offset, 0) }
            if written < 0, errno == EINTR || errno == EAGAIN { continue }
            guard written > 0 else { throw Self.unavailable() }
            offset += written
        }
    }
    private func wait(_ events: Int32) throws {
        while true {
            try lifetime.checkCancellation()
            let remaining = deadline - ProcessInfo.processInfo.systemUptime
            guard remaining > 0 else { throw CoincideError("The existing Codex daemon did not respond in time. Refresh when Codex is ready.") }
            var descriptor = pollfd(fd: descriptor, events: Int16(events), revents: 0)
            let result = poll(&descriptor, 1, Int32(min(remaining * 1_000, 15_000)))
            if result < 0, errno == EINTR { continue }
            guard result > 0, descriptor.revents & Int16(events) != 0 else { throw Self.unavailable() }
            return
        }
    }
    private static func unavailable() -> CoincideError {
        CoincideError("Could not read the existing Codex daemon. Open Codex with this configuration, then refresh. No daemon or conversation was started.")
    }
}

private final class SocketLifetime: @unchecked Sendable {
    private let lock = NSLock()
    private var descriptor: Int32 = -1
    private var cancelled = false
    var isCancelled: Bool { lock.withLock { cancelled } }
    func checkCancellation() throws { if isCancelled { throw CancellationError() } }
    func own(_ descriptor: Int32) throws {
        try lock.withLock {
            if cancelled { Darwin.close(descriptor); throw CancellationError() }
            self.descriptor = descriptor
        }
    }
    func cancel() {
        lock.withLock { cancelled = true; if descriptor >= 0 { shutdown(descriptor, SHUT_RDWR) } }
    }
    func finish() {
        lock.withLock { if descriptor >= 0 { Darwin.close(descriptor); descriptor = -1 } }
    }
}
