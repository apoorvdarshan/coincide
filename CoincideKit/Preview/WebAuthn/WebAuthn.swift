import CryptoKit
import Foundation

/// base64url (RFC 4648 §5), as WebAuthn and Bitwarden write binary values. Encoding never pads. Decoding also takes
/// padding and the standard alphabet, as Bitwarden's own decoder does, so imported vault values read the same.
public nonisolated enum Base64URL {
    public static func encode(_ data: Data) -> String {
        var text = data.base64EncodedString()
        text = text.replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_")
        while text.hasSuffix("=") { text.removeLast() }
        return text
    }

    public static func decode(_ text: String) -> Data? {
        var body = Substring(text)
        var padding = 0
        while body.hasSuffix("="), padding < 2 {
            body.removeLast()
            padding += 1
        }
        guard body.utf8.allSatisfy(isAlphabet) else { return nil }
        let remainder = body.utf8.count % 4
        guard remainder != 1, padding == 0 || (remainder + padding) % 4 == 0 else { return nil }
        var base64 = body.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        if remainder > 0 { base64 += String(repeating: "=", count: 4 - remainder) }
        return Data(base64Encoded: base64)
    }

    private static func isAlphabet(_ byte: UInt8) -> Bool {
        switch byte {
        case UInt8(ascii: "A")...UInt8(ascii: "Z"), UInt8(ascii: "a")...UInt8(ascii: "z"), UInt8(ascii: "0")...UInt8(ascii: "9"),
            UInt8(ascii: "-"), UInt8(ascii: "_"), UInt8(ascii: "+"), UInt8(ascii: "/"):
            true
        default: false
        }
    }
}

/// The origin of the frame that asked for a passkey, from WebKit's own record of it (never from the page). Only
/// origins where WebAuthn may run exist: https, and plain http on `localhost` for local development, as browsers allow.
/// IP addresses aren't domains, so they can't be relying parties.
public nonisolated struct WebAuthnOrigin: Sendable, Hashable {
    public let scheme: String
    public let host: String
    /// Nil for the scheme's default port.
    public let port: Int?

    /// From a `WKSecurityOrigin`'s parts (`port` 0 meaning the default).
    public init?(scheme: String, host: String, port: Int) {
        let scheme = scheme.lowercased(), host = host.lowercased()
        guard WebAuthnRelyingParty.isDomain(host), (0...65_535).contains(port) else { return nil }
        switch scheme {
        case "https": guard host == "localhost" || host.contains(".") else { return nil }
        case "http": guard host == "localhost" else { return nil }
        default: return nil
        }
        self.scheme = scheme
        self.host = host
        self.port = port == 0 || port == (scheme == "https" ? 443 : 80) ? nil : port
    }

    /// From an address, for checking a frame's document address against its security origin.
    public init?(url: URL) {
        guard let scheme = url.scheme, let host = url.host(percentEncoded: false) else { return nil }
        self.init(scheme: scheme, host: host, port: url.port ?? 0)
    }

    /// As `clientDataJSON` names it: `https://example.com`, `http://localhost:3000`.
    public var serialized: String { "\(scheme)://\(host)" + (port.map { ":\($0)" } ?? "") }
}

/// Which relying party ID a page may use, by WebAuthn's rule (the RP ID must equal the origin's host or be a
/// registrable domain suffix of it, HTML's "is a registrable domain suffix of or is equal to"), with the Public Suffix
/// List deciding what is registrable.
public nonisolated enum WebAuthnRelyingParty {
    /// The RP ID for a request from `origin` that named `requested` (nil: the origin's host), or nil when the request
    /// must fail with a SecurityError. A public suffix is never allowed, even as the host itself, and neither is an
    /// RP ID above the host's registrable domain.
    public static func validate(_ requested: String?, origin: WebAuthnOrigin, suffixes: PublicSuffixList) -> String? {
        let host = origin.host
        let rpID = requested ?? host
        // RP IDs are compared and hashed exactly as written, so only the lowercase form the host has can match.
        guard rpID == rpID.lowercased(), isDomain(rpID) else { return nil }
        if host == "localhost" || rpID == "localhost" { return host == rpID ? rpID : nil }
        guard rpID.contains("."), !suffixes.isPublicSuffix(rpID) else { return nil }
        if rpID == host { return rpID }
        guard host.hasSuffix("." + rpID), let registrable = suffixes.registrableDomain(of: host),
            rpID == registrable || rpID.hasSuffix("." + registrable)
        else { return nil }
        return rpID
    }

    /// A lowercase ASCII domain name: labels of letters, digits, `-` and `_`, not an IP address (no last label that is
    /// a number, as the URL standard reads `1.2.3.4` and `0x7f.1`).
    static func isDomain(_ text: String) -> Bool {
        guard let labels = PublicSuffixList.labels(text), text == text.lowercased() else { return false }
        let allowed = Set("abcdefghijklmnopqrstuvwxyz0123456789-_".unicodeScalars)
        guard labels.allSatisfy({ $0.unicodeScalars.allSatisfy(allowed.contains) }), let last = labels.last else { return false }
        let numeric = last.allSatisfy(\.isNumber) || (last.hasPrefix("0x") && last.dropFirst(2).allSatisfy(\.isHexDigit))
        return !numeric
    }
}

/// A page's `navigator.credentials.get({publicKey})`, as Coincide's page script forwards it. Everything here comes from
/// the page and is checked and bounded before use; the origin is never part of it.
public nonisolated struct WebAuthnGetRequest: Sendable, Equatable {
    public enum UserVerification: String, Sendable { case required, preferred, discouraged }
    public enum Mediation: String, Sendable { case optional, required, silent, conditional }

    public struct AllowedCredential: Sendable, Equatable {
        public let id: Data
        public let transports: [String]

        public init(id: Data, transports: [String] = []) {
            self.id = id
            self.transports = transports
        }
    }

    /// Generous bounds on what a page may send: Google's sign-in challenges and the credential lists of accounts with
    /// many passkeys must fit.
    public static let maxChallenge = 65_536
    public static let maxAllowedCredentials = 256
    /// WebAuthn's limit for a credential ID.
    public static let maxCredentialID = 1_023
    public static let maxRPID = 253
    private static let idCharacters = Set("abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789".unicodeScalars)

    /// The script's id for the request, so an abort can name it.
    public let id: String
    public let challenge: Data
    public let rpID: String?
    public let allowCredentials: [AllowedCredential]
    public let userVerification: UserVerification
    /// The page's timeout in milliseconds, if it gave one.
    public let timeout: Double?
    public let mediation: Mediation

    public init(id: String, challenge: Data, rpID: String? = nil, allowCredentials: [AllowedCredential] = [],
        userVerification: UserVerification = .preferred, timeout: Double? = nil, mediation: Mediation = .optional) {
        self.id = id
        self.challenge = challenge
        self.rpID = rpID
        self.allowCredentials = allowCredentials
        self.userVerification = userVerification
        self.timeout = timeout
        self.mediation = mediation
    }

    /// The script's message: `{kind: "get", id, mediation?, publicKey: {challenge, rpId?, allowCredentials?,
    /// userVerification?, timeout?}}` with binary values in base64url. Nil when anything is missing, malformed or over
    /// its limit; the page then gets the browser's own behavior.
    public init?(message body: Any) {
        guard let body = body as? [String: Any], body["kind"] as? String == "get", let id = body["id"] as? String,
            (1...64).contains(id.utf8.count), id.unicodeScalars.allSatisfy(Self.idCharacters.contains),
            let options = body["publicKey"] as? [String: Any],
            let challengeText = options["challenge"] as? String, challengeText.utf8.count <= Self.maxChallenge * 2,
            let challenge = Base64URL.decode(challengeText), (1...Self.maxChallenge).contains(challenge.count)
        else { return nil }
        var rpID: String?
        if let value = options["rpId"], !(value is NSNull) {
            guard let text = value as? String, text.utf8.count <= Self.maxRPID else { return nil }
            rpID = text
        }
        var allowed: [AllowedCredential] = []
        if let value = options["allowCredentials"], !(value is NSNull) {
            guard let list = value as? [Any], list.count <= Self.maxAllowedCredentials else { return nil }
            for entry in list {
                guard let entry = entry as? [String: Any], let idText = entry["id"] as? String,
                    idText.utf8.count <= Self.maxCredentialID * 2, let credentialID = Base64URL.decode(idText),
                    (1...Self.maxCredentialID).contains(credentialID.count)
                else { return nil }
                // Only public-key descriptors name credentials; browsers skip other types.
                guard (entry["type"] as? String ?? "public-key") == "public-key" else { continue }
                var transports: [String] = []
                if let value = entry["transports"], !(value is NSNull) {
                    guard let list = value as? [Any], list.count <= 16 else { return nil }
                    transports = list.compactMap { ($0 as? String).flatMap { $0.utf8.count <= 32 ? $0 : nil } }
                }
                allowed.append(AllowedCredential(id: credentialID, transports: transports))
            }
        }
        // Unknown values mean the default, as in the specification.
        let userVerification = (options["userVerification"] as? String).flatMap(UserVerification.init(rawValue:)) ?? .preferred
        var timeout: Double?
        if let number = options["timeout"] as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID() {
            let value = number.doubleValue
            if value.isFinite, value >= 0 { timeout = value }
        }
        var mediation = Mediation.optional
        if let value = body["mediation"], !(value is NSNull) {
            guard let text = value as? String, let known = Mediation(rawValue: text) else { return nil }
            mediation = known
        }
        self.init(id: id, challenge: challenge, rpID: rpID, allowCredentials: allowed, userVerification: userVerification,
            timeout: timeout, mediation: mediation)
    }

    /// The shape of a message, for the log when it can't be read: sizes and the mediation only, never the values.
    public static func summary(of body: Any) -> String {
        let body = body as? [String: Any]
        let options = body?["publicKey"] as? [String: Any]
        let challenge = (options?["challenge"] as? String).map { "\($0.utf8.count) chars" } ?? "missing"
        let allowed = options?["allowCredentials"].map { ($0 as? [Any]).map { "\($0.count)" } ?? "not a list" } ?? "none"
        let mediation = (body?["mediation"] as? String).map { String($0.prefix(16)) } ?? "none"
        return "challenge \(challenge), allowCredentials \(allowed), mediation \(mediation)"
    }

    /// How long Coincide waits for the user, from the page's timeout clamped as Bitwarden clamps it: 30 seconds to 10
    /// minutes (5 by default) when user verification is wanted, 30 seconds to 3 minutes (2 by default) when discouraged.
    public var waitLimit: TimeInterval {
        let (lower, fallback, upper): (Double, Double, Double) = userVerification == .discouraged ? (30, 120, 180) : (30, 300, 600)
        guard let timeout else { return fallback }
        return min(max(timeout / 1_000, lower), upper)
    }
}

/// The bytes of a WebAuthn assertion (WebAuthn Level 3, §6.1 and §6.3.3).
public nonisolated enum WebAuthnAssertion {
    public struct Flags: OptionSet, Sendable {
        public let rawValue: UInt8
        public init(rawValue: UInt8) { self.rawValue = rawValue }
        public static let userPresent = Flags(rawValue: 0x01)
        public static let userVerified = Flags(rawValue: 0x04)
        public static let backupEligible = Flags(rawValue: 0x08)
        public static let backedUp = Flags(rawValue: 0x10)
    }

    /// The client data of a sign-in, in WebAuthn's JSON-compatible serialization (§5.8.1.1): exactly these fields, in
    /// this order. `origin` is the frame's, from WebKit.
    public static func clientDataJSON(challenge: Data, origin: String) -> Data {
        let json = #"{"type":"webauthn.get","challenge":"# + quoted(Base64URL.encode(challenge))
            + #","origin":"# + quoted(origin) + #","crossOrigin":false}"#
        return Data(json.utf8)
    }

    /// The specification's CCDToString: a JSON string with `"`, `\` and control characters escaped.
    static func quoted(_ text: String) -> String {
        var out = "\""
        for scalar in text.unicodeScalars {
            switch scalar.value {
            case 0x22: out += "\\\""
            case 0x5C: out += "\\\\"
            case 0..<0x20: out += "\\u" + String(format: "%04x", scalar.value)
            default: out.unicodeScalars.append(scalar)
            }
        }
        return out + "\""
    }

    /// SHA-256 of the RP ID, the flags and the big-endian signature counter; no attested credential data or extensions.
    public static func authenticatorData(rpID: String, flags: Flags, signCount: UInt32) -> Data {
        var data = Data(SHA256.hash(data: Data(rpID.utf8)))
        data.append(flags.rawValue)
        withUnsafeBytes(of: signCount.bigEndian) { data.append(contentsOf: $0) }
        return data
    }

    /// ES256 over `authenticatorData` followed by SHA-256 of `clientDataJSON`, DER-encoded as WebAuthn expects. `pkcs8`
    /// is the private key as Bitwarden stores it; CryptoKit keeps its copy in memory it erases.
    public static func signature(authenticatorData: Data, clientDataJSON: Data, pkcs8: Data) throws -> Data {
        let key = try P256.Signing.PrivateKey(derRepresentation: pkcs8)
        var signed = authenticatorData
        signed.append(Data(SHA256.hash(data: clientDataJSON)))
        return try key.signature(for: signed).derRepresentation
    }
}
