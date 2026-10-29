import CryptoKit
import Foundation

/// Where to reach a Mac, as the pairing code and saved connections list it.
public struct RemoteHostCandidate: Codable, Hashable, Sendable, Identifiable {
    public enum Kind: String, Codable, Sendable, Comparable {
        /// An IP address on the local network.
        case lan
        /// The Mac's `.local` name.
        case localName
        /// A Tailscale address (100.x.y.z or fd7a:115c:a1e0::/48).
        case tailscale
        /// A Tailscale MagicDNS name (`mac.tailnet.ts.net`).
        case tailscaleName
        /// Typed in by the user.
        case manual
        case unknown

        public init(from decoder: Decoder) throws {
            self = Kind(rawValue: try decoder.singleValueContainer().decode(String.self)) ?? .unknown
        }

        /// The order the phone tries them in: the local network first, then Tailscale, which also works away from home.
        var rank: Int {
            switch self {
            case .lan: 0
            case .localName: 1
            case .manual: 2
            case .tailscale: 3
            case .tailscaleName: 4
            case .unknown: 5
            }
        }

        public static func < (lhs: Kind, rhs: Kind) -> Bool { lhs.rank < rhs.rank }
    }

    public var host: String
    public var kind: Kind

    public var id: String { "\(kind.rawValue):\(host)" }

    public init(host: String, kind: Kind) {
        self.host = host
        self.kind = kind
    }

    public var isTailscale: Bool { kind == .tailscale || kind == .tailscaleName }
}

/// What the Mac's pairing QR code holds: how to reach it, its certificate's fingerprint to pin, and a one-time secret.
///
/// Encoded as `coincide-remote:pair#<base64url JSON>`. The secret is in the fragment of a custom URI that never goes on
/// the network as a URL: the phone reads it from the code and sends it inside the pinned TLS connection.
public struct RemotePairingPayload: Codable, Hashable, Sendable {
    public static let scheme = "coincide-remote"

    public var version: Int
    public var serverID: String
    public var name: String
    public var hosts: [RemoteHostCandidate]
    public var port: UInt16
    /// SHA-256 of the Mac's TLS certificate (DER), lowercase hex.
    public var fingerprint: String
    public var secret: String
    public var expiresAt: Date

    public init(
        serverID: String, name: String, hosts: [RemoteHostCandidate], port: UInt16, fingerprint: String, secret: String,
        expiresAt: Date, version: Int = RemoteProtocol.version
    ) {
        self.version = version
        self.serverID = serverID
        self.name = name
        self.hosts = hosts
        self.port = port
        self.fingerprint = fingerprint
        self.secret = secret
        self.expiresAt = expiresAt
    }

    private enum CodingKeys: String, CodingKey {
        case version = "v", serverID = "id", name = "n", hosts = "h", port = "p", fingerprint = "f", secret = "s"
        case expiresAt = "e"
    }

    public func encoded() -> String {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .secondsSince1970
        encoder.outputFormatting = .sortedKeys
        let data = (try? encoder.encode(self)) ?? Data()
        return "\(Self.scheme):pair#\(RemoteCrypto.base64URL(data))"
    }

    /// Reads a scanned code. Nil for anything that isn't a Coincide pairing code.
    public static func decode(_ string: String) -> RemotePairingPayload? {
        let trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines)
        let prefix = "\(scheme):pair#"
        guard trimmed.hasPrefix(prefix), let data = RemoteCrypto.data(base64URL: String(trimmed.dropFirst(prefix.count)))
        else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .secondsSince1970
        guard let payload = try? decoder.decode(RemotePairingPayload.self, from: data), payload.version >= 1,
            !payload.secret.isEmpty, payload.fingerprint.count == 64
        else { return nil }
        return payload
    }
}

public enum RemoteCrypto {
    /// `count` random bytes, base64url without padding.
    public static func randomToken(bytes count: Int = 32) -> String {
        var generator = SystemRandomNumberGenerator()
        let bytes = (0..<count).map { _ in UInt8.random(in: .min ... .max, using: &generator) }
        return base64URL(Data(bytes))
    }

    public static func sha256Hex(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    public static func sha256Hex(_ string: String) -> String { sha256Hex(Data(string.utf8)) }

    /// Compares without returning early, so timing doesn't tell how much of a secret matched.
    public static func constantTimeEquals(_ lhs: String, _ rhs: String) -> Bool {
        let a = Array(lhs.utf8)
        let b = Array(rhs.utf8)
        var difference = UInt8(a.count == b.count ? 0 : 1)
        for index in 0..<max(a.count, b.count) {
            difference |= (index < a.count ? a[index] : 0) ^ (index < b.count ? b[index] : 0)
        }
        return difference == 0
    }

    public static func base64URL(_ data: Data) -> String {
        data.base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    public static func data(base64URL string: String) -> Data? {
        var base64 = string.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        base64 += String(repeating: "=", count: (4 - base64.count % 4) % 4)
        return Data(base64Encoded: base64)
    }

    /// A fingerprint grouped for reading aloud, such as `AB12 CD34 …`.
    public static func displayFingerprint(_ hex: String, groups: Int = 4) -> String {
        let upper = Array(hex.uppercased())
        return stride(from: 0, to: min(upper.count, groups * 4), by: 4).map { String(upper[$0..<min($0 + 4, upper.count)]) }
            .joined(separator: " ")
    }
}
