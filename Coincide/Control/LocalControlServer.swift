import CoincideKit
import CoincideRemoteKit
import Darwin
import Foundation

/// The `coincide` command-line tool's way in: a Unix socket in Coincide's data folder, readable and writable only by
/// its owner, where each connection is a Coincide Remote session that starts trusted (`RemoteSession(localTransport:)`)
/// instead of pairing. Messages are the Remote protocol's JSON, one per line. Connections from another user are
/// refused, and nothing listens on the network.
@MainActor
final class LocalControlServer {
    /// The longest line one message may take; a longer one ends the connection.
    nonisolated static let maxLineBytes = 8 * 1024 * 1024

    let path: String
    private let adapter: RemoteStoreAdapter
    private let serverInfo: () -> RemoteServerInfo
    /// Opens a thread in the window, for `showThread`.
    var onShowThread: ((UUID) -> Void)?
    private var listener: Int32 = -1
    private var acceptSource: DispatchSourceRead?
    private var connections: [ObjectIdentifier: LocalControlConnection] = [:]

    init(path: String, adapter: RemoteStoreAdapter, serverInfo: @escaping () -> RemoteServerInfo) {
        self.path = path
        self.adapter = adapter
        self.serverInfo = serverInfo
    }

    var isRunning: Bool { listener >= 0 }

    enum StartError: LocalizedError {
        case pathTooLong(String)
        case failed(String, Int32)

        var errorDescription: String? {
            switch self {
            case .pathTooLong(let path): "The command-line socket path is too long: \(path)"
            case .failed(let step, let code): "The command-line socket couldn't \(step): \(String(cString: strerror(code)))"
            }
        }
    }

    /// Listens at `path`, replacing a socket left by an earlier run.
    func start() throws {
        guard listener < 0 else { return }
        var address = sockaddr_un()
        let bytes = Array(path.utf8)
        guard bytes.count < MemoryLayout.size(ofValue: address.sun_path) else { throw StartError.pathTooLong(path) }
        try? FileManager.default.createDirectory(
            atPath: (path as NSString).deletingLastPathComponent, withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700])
        var info = stat()
        if lstat(path, &info) == 0, (info.st_mode & S_IFMT) == S_IFSOCK { unlink(path) }
        let socket = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
        guard socket >= 0 else { throw StartError.failed("be created", errno) }
        address.sun_family = sa_family_t(AF_UNIX)
        withUnsafeMutableBytes(of: &address.sun_path) { buffer in
            for (index, byte) in bytes.enumerated() { buffer[index] = byte }
        }
        address.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
        // Owner-only from the moment it exists.
        let previous = umask(0o077)
        let bound = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(socket, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
        }
        umask(previous)
        guard bound == 0 else {
            let code = errno
            close(socket)
            throw StartError.failed("open at \(path)", code)
        }
        chmod(path, 0o600)
        guard listen(socket, 16) == 0 else {
            let code = errno
            close(socket)
            unlink(path)
            throw StartError.failed("listen", code)
        }
        listener = socket
        let source = DispatchSource.makeReadSource(fileDescriptor: socket, queue: .main)
        source.setEventHandler { [weak self] in MainActor.assumeIsolated { self?.accept() } }
        source.resume()
        acceptSource = source
    }

    func stop() {
        acceptSource?.cancel()
        acceptSource = nil
        if listener >= 0 {
            close(listener)
            unlink(path)
        }
        listener = -1
        for connection in connections.values { connection.close() }
        connections.removeAll()
    }

    private func accept() {
        let client = Darwin.accept(listener, nil, nil)
        guard client >= 0 else { return }
        // Only this user's own processes.
        var uid: uid_t = 0
        var gid: gid_t = 0
        guard getpeereid(client, &uid, &gid) == 0, uid == getuid() else {
            close(client)
            return
        }
        var noSignal: Int32 = 1
        setsockopt(client, SOL_SOCKET, SO_NOSIGPIPE, &noSignal, socklen_t(MemoryLayout<Int32>.size))
        let connection = LocalControlConnection(socket: client)
        let session = RemoteSession(
            localTransport: connection, adapter: adapter, deviceID: "local-command-line", serverInfo: serverInfo)
        session.onShowThread = { [weak self] in self?.onShowThread?($0) }
        connection.onMessage = { [weak session] in session?.receive($0) }
        let key = ObjectIdentifier(connection)
        connection.onClose = { [weak self, weak session] in
            session?.close()
            self?.connections[key] = nil
        }
        connections[key] = connection
        connection.retain(session)
        connection.start()
    }
}

/// One command-line connection: newline-separated messages in and out. Reads are handled on the main queue; writes go
/// through a serial queue of their own, so a slow reader never blocks Coincide.
@MainActor
final class LocalControlConnection: RemoteTransport {
    let peer = "local"
    var onMessage: ((Data) -> Void)?
    var onClose: (() -> Void)?
    private let socket: Int32
    private var source: DispatchSourceRead?
    private var buffer = Data()
    private var closed = false
    private var session: RemoteSession?
    private let writes = DispatchQueue(label: "com.apoorvdarshan.coincide.control-write")

    init(socket: Int32) {
        self.socket = socket
    }

    /// Keeps the session alive as long as the connection.
    func retain(_ session: RemoteSession) { self.session = session }

    func start() {
        let source = DispatchSource.makeReadSource(fileDescriptor: socket, queue: .main)
        source.setEventHandler { [weak self] in MainActor.assumeIsolated { self?.readAvailable() } }
        source.resume()
        self.source = source
    }

    private func readAvailable() {
        var chunk = [UInt8](repeating: 0, count: 65_536)
        let count = read(socket, &chunk, chunk.count)
        guard count > 0 else {
            close()
            return
        }
        buffer.append(contentsOf: chunk[0..<count])
        while let newline = buffer.firstIndex(of: 0x0A) {
            let line = buffer[buffer.startIndex..<newline]
            buffer.removeSubrange(buffer.startIndex...newline)
            if !line.isEmpty { onMessage?(Data(line)) }
            if closed { return }
        }
        if buffer.count > LocalControlServer.maxLineBytes { close() }
    }

    func send(_ data: Data) {
        guard !closed else { return }
        var line = data
        line.append(0x0A)
        let socket = socket
        writes.async {
            line.withUnsafeBytes { raw in
                var offset = 0
                while offset < raw.count {
                    let written = write(socket, raw.baseAddress!.advanced(by: offset), raw.count - offset)
                    if written <= 0 { return }
                    offset += written
                }
            }
        }
    }

    func close() {
        guard !closed else { return }
        closed = true
        source?.cancel()
        source = nil
        let socket = socket
        // After any writes already queued.
        writes.async { Darwin.close(socket) }
        let onClose = onClose
        self.onClose = nil
        session = nil
        onClose?()
    }
}
