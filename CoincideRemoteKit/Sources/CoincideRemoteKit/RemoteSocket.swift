import Foundation
import Network
import Security

/// The phone's WebSocket to a Mac, over TLS that trusts exactly one certificate: the one whose SHA-256 the pairing code
/// carried. The Mac's certificate is self-signed, so no certificate authority is involved; a different certificate,
/// such as a machine in the middle presenting its own, fails the handshake.
public final class RemoteSocket: @unchecked Sendable {
    public enum Event: Sendable {
        case ready
        case message(Data)
        case closed(RemoteSocketError?)
    }

    /// Where to connect. A Bonjour service is resolved to a host and port first (`RemoteServiceResolver`).
    public enum Target: Sendable, Hashable {
        case host(String, port: UInt16)

        func endpoint(tls: Bool) -> NWEndpoint {
            switch self {
            case .host(let host, let port):
                // The WebSocket handshake needs a URL for its Host header and path; IPv6 literals go in brackets.
                if let url = Self.url(host: host, port: port, tls: tls) { .url(url) }
                else { .hostPort(host: NWEndpoint.Host(host), port: NWEndpoint.Port(rawValue: port) ?? 1) }
            }
        }

        static func url(host: String, port: UInt16, tls: Bool) -> URL? {
            let bracketed = host.contains(":") && !host.hasPrefix("[") ? "[\(host)]" : host
            return URL(string: "\(tls ? "wss" : "ws")://\(bracketed):\(port)/coincide")
        }
    }

    public let events: AsyncStream<Event>
    private let continuation: AsyncStream<Event>.Continuation
    private let connection: NWConnection
    private let queue = DispatchQueue(label: "coincide.remote.socket")
    private var finished = false

    /// `fingerprint` is the lowercase hex SHA-256 of the certificate to trust. `tls: false` is for tests on loopback.
    public init(target: Target, fingerprint: String, tls: Bool = true) {
        (events, continuation) = AsyncStream.makeStream(of: Event.self, bufferingPolicy: .unbounded)
        let tcp = NWProtocolTCP.Options()
        tcp.connectionTimeout = 6
        tcp.enableKeepalive = true
        tcp.keepaliveIdle = 15
        let parameters: NWParameters
        if tls {
            let tlsOptions = NWProtocolTLS.Options()
            parameters = NWParameters(tls: tlsOptions, tcp: tcp)
            let expected = fingerprint.lowercased()
            let verifyQueue = DispatchQueue(label: "coincide.remote.verify")
            sec_protocol_options_set_min_tls_protocol_version(tlsOptions.securityProtocolOptions, .TLSv13)
            sec_protocol_options_set_verify_block(
                tlsOptions.securityProtocolOptions,
                { _, trust, complete in
                    let trustRef = sec_trust_copy_ref(trust).takeRetainedValue()
                    let leaf = (SecTrustCopyCertificateChain(trustRef) as? [SecCertificate])?.first
                    let der = leaf.map { SecCertificateCopyData($0) as Data }
                    let matches = der.map { RemoteCrypto.constantTimeEquals(RemoteCrypto.sha256Hex($0), expected) } ?? false
                    complete(matches)
                }, verifyQueue)
        } else {
            parameters = NWParameters(tls: nil, tcp: tcp)
        }
        let websocket = NWProtocolWebSocket.Options()
        websocket.autoReplyPing = true
        websocket.maximumMessageSize = RemoteProtocol.maxMessageBytes
        parameters.defaultProtocolStack.applicationProtocols.insert(websocket, at: 0)
        connection = NWConnection(to: target.endpoint(tls: tls), using: parameters)
    }

    public func start() {
        connection.stateUpdateHandler = { [weak self] state in self?.handle(state) }
        connection.start(queue: queue)
    }

    public func send(_ data: Data) {
        let metadata = NWProtocolWebSocket.Metadata(opcode: .text)
        let context = NWConnection.ContentContext(identifier: "message", metadata: [metadata])
        connection.send(content: data, contentContext: context, isComplete: true, completion: .contentProcessed { [weak self] error in
            if let error { self?.finish(.transport(error.localizedDescription)) }
        })
    }

    public func cancel() {
        queue.async { [weak self] in
            guard let self else { return }
            self.connection.cancel()
            self.finish(nil)
        }
    }

    private func handle(_ state: NWConnection.State) {
        switch state {
        case .ready:
            continuation.yield(.ready)
            receive()
        case .failed(let error):
            finish(Self.describe(error))
            connection.cancel()
        case .waiting(let error):
            // Unreachable for now (no route, refused): give up so the caller can try the next address.
            finish(Self.describe(error))
            connection.cancel()
        case .cancelled:
            finish(nil)
        default:
            break
        }
    }

    private func receive() {
        connection.receiveMessage { [weak self] content, context, _, error in
            guard let self else { return }
            if let error {
                self.finish(Self.describe(error))
                return
            }
            let metadata = context?.protocolMetadata(definition: NWProtocolWebSocket.definition) as? NWProtocolWebSocket.Metadata
            if metadata?.opcode == .close {
                self.finish(.closedByMac)
                self.connection.cancel()
                return
            }
            if let content, metadata?.opcode == .text || metadata?.opcode == .binary {
                self.continuation.yield(.message(content))
            }
            self.receive()
        }
    }

    private func finish(_ error: RemoteSocketError?) {
        guard !finished else { return }
        finished = true
        continuation.yield(.closed(error))
        continuation.finish()
    }

    private static func describe(_ error: NWError) -> RemoteSocketError {
        // The pin is the only certificate check, so a TLS failure means the Mac presented another certificate.
        if case .tls = error { return .certificateMismatch }
        return .transport(error.localizedDescription)
    }
}

public enum RemoteSocketError: Error, Hashable, Sendable {
    /// The Mac presented a certificate other than the paired one.
    case certificateMismatch
    case closedByMac
    case transport(String)

    public var message: String {
        switch self {
        case .certificateMismatch:
            String(localized: "The Mac's security certificate doesn't match the one you paired with. Pair again from the Mac's Settings.")
        case .closedByMac: String(localized: "The Mac closed the connection.")
        case .transport(let message): message
        }
    }
}
