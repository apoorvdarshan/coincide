import CryptoKit
import Foundation

/// RFC 6238 one-time codes, for Coincide's own saved logins that keep a TOTP secret (base32, or an `otpauth://` URI).
public nonisolated struct TOTP: Sendable, Equatable {
    public enum Algorithm: String, Sendable { case sha1 = "SHA1", sha256 = "SHA256", sha512 = "SHA512" }

    let secret: Data
    let digits: Int
    let period: TimeInterval
    let algorithm: Algorithm

    public init?(_ text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        var secretText = trimmed
        var digits = 6, period: TimeInterval = 30, algorithm = Algorithm.sha1
        if trimmed.lowercased().hasPrefix("otpauth://") {
            guard let components = URLComponents(string: trimmed), components.host?.lowercased() == "totp",
                let secret = components.queryItems?.first(where: { $0.name.lowercased() == "secret" })?.value
            else { return nil }
            secretText = secret
            for item in components.queryItems ?? [] {
                switch item.name.lowercased() {
                case "digits": digits = item.value.flatMap(Int.init) ?? digits
                case "period": period = item.value.flatMap(TimeInterval.init) ?? period
                case "algorithm": algorithm = item.value.flatMap { Algorithm(rawValue: $0.uppercased()) } ?? algorithm
                default: break
                }
            }
        }
        guard let secret = Self.base32(secretText), !secret.isEmpty, (6...8).contains(digits), period >= 1 else { return nil }
        self.secret = secret
        self.digits = digits
        self.period = period
        self.algorithm = algorithm
    }

    init(secret: Data, digits: Int = 6, period: TimeInterval = 30, algorithm: Algorithm = .sha1) {
        self.secret = secret
        self.digits = digits
        self.period = period
        self.algorithm = algorithm
    }

    public func code(at date: Date = Date()) -> String {
        var counter = UInt64(floor(date.timeIntervalSince1970 / period)).bigEndian
        let message = Data(bytes: &counter, count: 8)
        let key = SymmetricKey(data: secret)
        let mac: [UInt8] =
            switch algorithm {
            case .sha1: Array(HMAC<Insecure.SHA1>.authenticationCode(for: message, using: key))
            case .sha256: Array(HMAC<SHA256>.authenticationCode(for: message, using: key))
            case .sha512: Array(HMAC<SHA512>.authenticationCode(for: message, using: key))
            }
        let offset = Int(mac[mac.count - 1] & 0x0f)
        let value = (UInt32(mac[offset] & 0x7f) << 24) | (UInt32(mac[offset + 1]) << 16) | (UInt32(mac[offset + 2]) << 8) | UInt32(mac[offset + 3])
        let modulo = UInt32(pow(10, Double(digits)))
        let code = String(value % modulo)
        return String(repeating: "0", count: digits - code.count) + code
    }

    static func base32(_ text: String) -> Data? {
        let alphabet = Array("ABCDEFGHIJKLMNOPQRSTUVWXYZ234567")
        var bits = 0, value = 0
        var bytes: [UInt8] = []
        for character in text.uppercased() where character != "=" && character != " " && character != "-" {
            guard let index = alphabet.firstIndex(of: character) else { return nil }
            value = (value << 5) | index
            bits += 5
            if bits >= 8 {
                bytes.append(UInt8((value >> (bits - 8)) & 0xff))
                bits -= 8
            }
        }
        return Data(bytes)
    }
}
