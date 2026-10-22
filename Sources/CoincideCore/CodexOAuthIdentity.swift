import Foundation
import Security

public struct CodexOAuthIdentity: Sendable, Equatable, CustomStringConvertible, CustomDebugStringConvertible, CustomReflectable {
    public let subject: String
    public let email: String?
    public init(subject: String, email: String?) { self.subject = subject; self.email = email }
    public var description: String { "CodexOAuthIdentity(redacted)" }
    public var debugDescription: String { description }
    public var customMirror: Mirror { Mirror(self, children: [:]) }
}

/// Verifies only the discovered issuer's supplied JWKS. JWT key URLs, algorithms,
/// or claims cannot choose a network destination or change the expected account.
public enum CodexOAuthIdentityVerifier {
    public static func verify(idToken: String, jwks: Data, issuer: URL, audience: String, nonce: String?,
                              expectedSubject: String? = nil, now: Date = Date()) throws -> CodexOAuthIdentity {
        do {
            guard idToken.utf8.count <= 65_536, issuer.absoluteString == "https://auth.openai.com",
                  CodexOAuthParsing.clientID(audience), now.timeIntervalSince1970.isFinite else { throw invalid() }
            let pieces = idToken.split(separator: ".", omittingEmptySubsequences: false)
            guard pieces.count == 3 else { throw invalid() }
            let header = try CodexOAuthParsing.object(decode(String(pieces[0]), maximum: 16_384))
            let claims = try CodexOAuthParsing.object(decode(String(pieces[1]), maximum: 49_152))
            let signature = try decode(String(pieces[2]), maximum: 1_024)
            guard let alg = header["alg"]?.string, alg == "RS256" || alg == "ES256",
                  let kid = header["kid"]?.string, CodexOAuthParsing.text(kid, maximum: 256),
                  header["crit"] == nil, header["jku"] == nil, header["x5u"] == nil, header["jwk"] == nil,
                  header["b64"] == nil else { throw invalid() }
            let root = try CodexOAuthParsing.object(jwks)
            guard let rawKeys = root["keys"], case .array(let keys) = rawKeys, !keys.isEmpty, keys.count <= 64 else { throw invalid() }
            let matches = keys.filter { $0["kid"].string == kid }
            guard matches.count == 1, case .object(let jwk) = matches[0] else { throw invalid() }
            if let use = jwk["use"], use.string != "sig" { throw invalid() }
            if let nativeAlg = jwk["alg"], nativeAlg.string != alg { throw invalid() }
            if let operations = jwk["key_ops"] {
                guard case .array(let values) = operations, !values.isEmpty, values.count <= 8,
                      values.allSatisfy({ $0.string != nil }), values.contains(.string("verify")) else { throw invalid() }
            }
            guard jwk["d"] == nil, jwk["p"] == nil, jwk["q"] == nil, jwk["oth"] == nil else { throw invalid() }
            let key: SecKey
            let algorithm: SecKeyAlgorithm
            let signatureBytes: Data
            if alg == "RS256" {
                guard jwk["kty"]?.string == "RSA", let n = jwk["n"]?.string, let e = jwk["e"]?.string else { throw invalid() }
                let modulus = try decode(n, maximum: 512), exponent = try decode(e, maximum: 8)
                guard modulus.count >= 256, modulus.count <= 512, modulus.first != 0,
                      !exponent.isEmpty, exponent.first != 0, exponent.count <= 4,
                      exponent.last.map({ $0 & 1 == 1 }) == true,
                      !(exponent.count == 1 && exponent[0] < 3), signature.count == modulus.count else { throw invalid() }
                let bytes = derSequence(derInteger(modulus) + derInteger(exponent))
                key = try makeKey(bytes, type: kSecAttrKeyTypeRSA, bits: modulus.count * 8)
                algorithm = .rsaSignatureMessagePKCS1v15SHA256; signatureBytes = signature
            } else {
                guard jwk["kty"]?.string == "EC", jwk["crv"]?.string == "P-256",
                      let x = jwk["x"]?.string, let y = jwk["y"]?.string else { throw invalid() }
                let xBytes = try decode(x, maximum: 32), yBytes = try decode(y, maximum: 32)
                guard xBytes.count == 32, yBytes.count == 32, signature.count == 64 else { throw invalid() }
                key = try makeKey(Data([4]) + xBytes + yBytes, type: kSecAttrKeyTypeECSECPrimeRandom, bits: 256)
                algorithm = .ecdsaSignatureMessageX962SHA256
                signatureBytes = derSequence(derInteger(signature.prefix(32)) + derInteger(signature.suffix(32)))
            }
            guard SecKeyIsAlgorithmSupported(key, .verify, algorithm),
                  SecKeyVerifySignature(key, algorithm, Data("\(pieces[0]).\(pieces[1])".utf8) as CFData,
                                        signatureBytes as CFData, nil) else { throw invalid() }
            guard claims["iss"]?.string == issuer.absoluteString, let subject = claims["sub"]?.string,
                  CodexOAuthParsing.text(subject, maximum: 4_096),
                  let expires = number(claims["exp"]), expires > now.timeIntervalSince1970 - 5 else { throw invalid() }
            if let aud = claims["aud"] {
                switch aud {
                case .string(let value): guard value == audience else { throw invalid() }
                case .array(let values):
                    guard !values.isEmpty, values.count <= 32, values.allSatisfy({ $0.string != nil }),
                          values.contains(.string(audience)) else { throw invalid() }
                    if values.count > 1 { guard claims["azp"]?.string == audience else { throw invalid() } }
                default: throw invalid()
                }
            } else { throw invalid() }
            if let raw = claims["nbf"] { guard let value = number(raw), value <= now.timeIntervalSince1970 + 5 else { throw invalid() } }
            if let raw = claims["iat"] { guard let value = number(raw), value <= now.timeIntervalSince1970 + 5 else { throw invalid() } }
            if let nonce { guard CodexOAuthParsing.text(nonce, maximum: 512), claims["nonce"]?.string == nonce else { throw invalid() } }
            if let expectedSubject, subject != expectedSubject { throw CodexOAuthError(.accountMismatch) }
            let email: String?
            if let raw = claims["email"], raw != .null {
                guard let value = raw.string, CodexOAuthParsing.text(value, maximum: 4_096) else { throw invalid() }
                email = value
            } else { email = nil }
            return .init(subject: subject, email: email)
        } catch let error as CodexOAuthError where error.kind == .accountMismatch { throw error }
        catch { throw invalid() }
    }
    private static func number(_ value: JSONValue?) -> Double? {
        guard let value, case .number(let number) = value, number.isFinite else { return nil }; return number
    }
    private static func invalid() -> CodexOAuthError { .init(.identityInvalid) }
    private static func makeKey(_ data: Data, type: CFString, bits: Int) throws -> SecKey {
        let options: [CFString: Any] = [kSecAttrKeyType: type, kSecAttrKeyClass: kSecAttrKeyClassPublic, kSecAttrKeySizeInBits: bits]
        guard let key = SecKeyCreateWithData(data as CFData, options as CFDictionary, nil) else { throw invalid() }
        return key
    }
    private static func decode(_ value: String, maximum: Int) throws -> Data {
        guard !value.isEmpty, value.utf8.count <= maximum * 2,
              value.utf8.allSatisfy({ (65...90).contains($0) || (97...122).contains($0) || (48...57).contains($0) || $0 == 45 || $0 == 95 }) else { throw invalid() }
        var encoded = value.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        encoded += String(repeating: "=", count: (4 - encoded.count % 4) % 4)
        guard let data = Data(base64Encoded: encoded), data.count <= maximum, CodexOAuthParsing.base64url(data) == value else { throw invalid() }
        return data
    }
    private static func derInteger(_ bytes: some DataProtocol) -> Data {
        var value = Array(bytes)
        while value.count > 1 && value.first == 0 { value.removeFirst() }
        if value.first.map({ $0 & 128 != 0 }) == true { value.insert(0, at: 0) }
        return Data([2]) + derLength(value.count) + Data(value)
    }
    private static func derSequence(_ data: Data) -> Data { Data([48]) + derLength(data.count) + data }
    private static func derLength(_ count: Int) -> Data {
        if count < 128 { return Data([UInt8(count)]) }
        var value = count, bytes: [UInt8] = []
        while value > 0 { bytes.insert(UInt8(value & 255), at: 0); value >>= 8 }
        return Data([128 | UInt8(bytes.count)]) + Data(bytes)
    }
}
