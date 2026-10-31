import CoincideRemoteKit
import Darwin
import Foundation

/// Asks Coincide something and returns its answer; the socket client in the tool, an in-process one in tests.
nonisolated protocol ControlConnection: Sendable {
    func request(_ request: RemoteRequest) throws -> RemoteResult
}

nonisolated struct ControlError: Error, CustomStringConvertible, Equatable {
    var message: String
    /// The Remote protocol's error code, when Coincide answered with one.
    var code: RemoteError.Code?
    var description: String { message }
}

nonisolated enum ControlPaths {
    /// The data folder of the Coincide this tool was built with: a Debug build's tool talks to the Debug app
    /// (`CoincideIdentity.dataDirectory`, which the tool doesn't link).
    #if DEBUG
    static let dataFolderName = "Coincide Debug"
    #else
    static let dataFolderName = "Coincide"
    #endif

    /// Where Coincide listens unless `COINCIDE_CONTROL_SOCKET` says otherwise.
    static var defaultSocket: String {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/\(dataFolderName)/control.sock").path
    }

    static func socket(explicit: String?, environment: [String: String]) -> String {
        explicit ?? environment["COINCIDE_CONTROL_SOCKET"].flatMap { $0.isEmpty ? nil : $0 } ?? defaultSocket
    }
}

/// A blocking connection to Coincide's control socket: one Remote protocol message per line each way. Events Coincide
/// pushes in between are skipped; each request waits for the response with its id.
nonisolated final class ControlClient: ControlConnection, @unchecked Sendable {
    private let socket: Int32
    private var buffer = Data()
    private let lock = NSLock()

    init(path: String, timeout: TimeInterval = 120) throws {
        var address = sockaddr_un()
        let bytes = Array(path.utf8)
        guard bytes.count < MemoryLayout.size(ofValue: address.sun_path) else {
            throw ControlError(message: "The socket path is too long: \(path)")
        }
        let socket = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
        guard socket >= 0 else { throw ControlError(message: "Couldn't create a socket.") }
        address.sun_family = sa_family_t(AF_UNIX)
        withUnsafeMutableBytes(of: &address.sun_path) { buffer in
            for (index, byte) in bytes.enumerated() { buffer[index] = byte }
        }
        address.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
        let connected = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(socket, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
        }
        guard connected == 0 else {
            close(socket)
            throw ControlError(
                message: "Couldn't reach Coincide at \(path). Is Coincide running, with Settings › General › Command-line control on?")
        }
        var noSignal: Int32 = 1
        setsockopt(socket, SOL_SOCKET, SO_NOSIGPIPE, &noSignal, socklen_t(MemoryLayout<Int32>.size))
        var limit = timeval(tv_sec: Int(timeout), tv_usec: 0)
        setsockopt(socket, SOL_SOCKET, SO_RCVTIMEO, &limit, socklen_t(MemoryLayout<timeval>.size))
        self.socket = socket
    }

    deinit { close(socket) }

    func request(_ request: RemoteRequest) throws -> RemoteResult {
        lock.lock()
        defer { lock.unlock() }
        let message = RemoteClientMessage(request: request)
        var line = try RemoteProtocol.makeEncoder().encode(message)
        line.append(0x0A)
        try line.withUnsafeBytes { raw in
            var offset = 0
            while offset < raw.count {
                let written = write(socket, raw.baseAddress!.advanced(by: offset), raw.count - offset)
                guard written > 0 else { throw ControlError(message: "Coincide closed the connection.") }
                offset += written
            }
        }
        let decoder = RemoteProtocol.makeDecoder()
        while true {
            let line = try readLine()
            guard let reply = try? decoder.decode(RemoteServerMessage.self, from: line) else { continue }
            switch reply {
            case .response(let id, let result) where id == message.id:
                return result
            case .failure(let id, let error) where id == message.id || id == nil:
                throw ControlError(message: error.message, code: error.code)
            default:
                continue
            }
        }
    }

    private func readLine() throws -> Data {
        while true {
            if let newline = buffer.firstIndex(of: 0x0A) {
                let line = buffer[buffer.startIndex..<newline]
                buffer.removeSubrange(buffer.startIndex...newline)
                return Data(line)
            }
            var chunk = [UInt8](repeating: 0, count: 65_536)
            let count = read(socket, &chunk, chunk.count)
            if count < 0, errno == EAGAIN || errno == EWOULDBLOCK {
                throw ControlError(message: "Coincide didn't answer in time.")
            }
            guard count > 0 else { throw ControlError(message: "Coincide closed the connection.") }
            buffer.append(contentsOf: chunk[0..<count])
        }
    }
}
