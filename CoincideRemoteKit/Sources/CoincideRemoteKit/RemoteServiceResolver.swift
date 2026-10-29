import Foundation
import Network

/// Turns a Bonjour service into the address and port it runs on, by opening a plain TCP connection to it and reading
/// where it went. The WebSocket then connects to that address, since its handshake needs a URL.
public enum RemoteServiceResolver {
    public static func resolve(_ endpoint: NWEndpoint, timeout: Duration = .seconds(4)) async -> (host: String, port: UInt16)? {
        let parameters = NWParameters.tcp
        // IPv4, since an IPv6 link-local address loses the interface scope a URL can't carry.
        (parameters.defaultProtocolStack.internetProtocol as? NWProtocolIP.Options)?.version = .v4
        let connection = NWConnection(to: endpoint, using: parameters)
        let queue = DispatchQueue(label: "coincide.remote.resolve")
        let result = await withCheckedContinuation { (continuation: CheckedContinuation<(String, UInt16)?, Never>) in
            let once = Once(continuation)
            connection.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    if case .hostPort(let host, let port)? = connection.currentPath?.remoteEndpoint {
                        once.resume((Self.string(host), port.rawValue))
                    } else {
                        once.resume(nil)
                    }
                case .failed, .cancelled, .waiting:
                    once.resume(nil)
                default:
                    break
                }
            }
            connection.start(queue: queue)
            queue.asyncAfter(deadline: .now() + timeout.timeInterval) { once.resume(nil) }
        }
        connection.cancel()
        return result
    }

    static func string(_ host: NWEndpoint.Host) -> String {
        switch host {
        case .ipv4(let address): "\(address)"
        case .ipv6(let address):
            // Drop the interface scope (`%en0`), which a URL can't carry; link-local addresses then won't work, but
            // routable ones do.
            "\(address)".split(separator: "%").first.map(String.init) ?? "\(address)"
        case .name(let name, _): name
        @unknown default: "\(host)"
        }
    }

    private final class Once: @unchecked Sendable {
        private var continuation: CheckedContinuation<(String, UInt16)?, Never>?
        private let lock = NSLock()

        init(_ continuation: CheckedContinuation<(String, UInt16)?, Never>) {
            self.continuation = continuation
        }

        func resume(_ value: (String, UInt16)?) {
            lock.lock()
            let continuation = self.continuation
            self.continuation = nil
            lock.unlock()
            continuation?.resume(returning: value)
        }
    }
}

extension Duration {
    var timeInterval: TimeInterval {
        let parts = components
        return TimeInterval(parts.seconds) + TimeInterval(parts.attoseconds) / 1e18
    }
}
