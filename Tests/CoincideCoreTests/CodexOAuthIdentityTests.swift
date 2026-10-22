import CryptoKit
import Foundation
import Security
import Testing
@testable import CoincideCore

/// Private signing keys and signed tokens exist only in this process. No key or
/// token is loaded from disk, exported as a private fixture, logged, or persisted.
final class CodexOAuthTestKey: @unchecked Sendable {
    enum Algorithm: String, Sendable, CaseIterable { case rsa = "RS256", ec = "ES256" }
    let algorithm: Algorithm
    let jwk: JSONValue
    private let rsa: SecKey?
    private let ec: P256.Signing.PrivateKey?
    init(_ algorithm: Algorithm) throws {
        self.algorithm = algorithm
        if algorithm == .ec {
            let key = P256.Signing.PrivateKey(); ec = key; rsa = nil
            let bytes = key.publicKey.x963Representation
            jwk = .object(["kty": .string("EC"), "kid": .string("fixture-key"), "alg": .string(algorithm.rawValue),
                "use": .string("sig"), "crv": .string("P-256"), "x": .string(CodexOAuthParsing.base64url(bytes[1..<33])),
                "y": .string(CodexOAuthParsing.base64url(bytes[33..<65]))])
        } else {
            let attributes: [CFString: Any] = [kSecAttrKeyType: kSecAttrKeyTypeRSA, kSecAttrKeySizeInBits: 2_048]
            guard let key = SecKeyCreateRandomKey(attributes as CFDictionary, nil), let publicKey = SecKeyCopyPublicKey(key),
                  let bytes = SecKeyCopyExternalRepresentation(publicKey, nil) as Data? else { throw CoincideError("Test signing key unavailable") }
            rsa = key; ec = nil
            var cursor = 0
            func length() throws -> Int {
                guard cursor < bytes.count else { throw CoincideError("Invalid test public key") }
                let first = Int(bytes[cursor]); cursor += 1
                if first < 128 { return first }
                let count = first & 127
                guard count > 0, count <= 4, cursor + count <= bytes.count else { throw CoincideError("Invalid test public key") }
                var result = 0
                for _ in 0..<count { result = result * 256 + Int(bytes[cursor]); cursor += 1 }
                return result
            }
            func integer() throws -> Data {
                guard cursor < bytes.count, bytes[cursor] == 2 else { throw CoincideError("Invalid test public key") }
                cursor += 1; let size = try length()
                guard cursor + size <= bytes.count else { throw CoincideError("Invalid test public key") }
                var result = Data(bytes[cursor..<cursor + size]); cursor += size
                if result.first == 0 { result.removeFirst() }; return result
            }
            guard bytes.first == 48 else { throw CoincideError("Invalid test public key") }
            cursor += 1; _ = try length()
            let modulus = try integer(), exponent = try integer()
            jwk = .object(["kty": .string("RSA"), "kid": .string("fixture-key"), "alg": .string(algorithm.rawValue),
                "use": .string("sig"), "n": .string(CodexOAuthParsing.base64url(modulus)),
                "e": .string(CodexOAuthParsing.base64url(exponent))])
        }
    }
    var jwks: Data { get throws { try JSONEncoder().encode(JSONValue.object(["keys": .array([jwk])])) } }
    func token(claims: [String: JSONValue], header: [String: JSONValue]? = nil) throws -> String {
        let h = try JSONEncoder().encode(JSONValue.object(header ?? ["alg": .string(algorithm.rawValue), "kid": .string("fixture-key")]))
        let p = try JSONEncoder().encode(JSONValue.object(claims))
        let input = CodexOAuthParsing.base64url(h) + "." + CodexOAuthParsing.base64url(p)
        let signature: Data
        if let ec { signature = try ec.signature(for: Data(input.utf8)).rawRepresentation }
        else {
            guard let rsa, let value = SecKeyCreateSignature(rsa, .rsaSignatureMessagePKCS1v15SHA256, Data(input.utf8) as CFData, nil) as Data? else {
                throw CoincideError("Test signature unavailable")
            }
            signature = value
        }
        return input + "." + CodexOAuthParsing.base64url(signature)
    }
}

func codexOAuthTestClaims(now: Date, nonce: String? = "fixture-nonce") -> [String: JSONValue] {
    var claims: [String: JSONValue] = ["iss": .string("https://auth.openai.com"), "aud": .string("oaiapp_fixture"),
        "sub": .string("synthetic-subject"), "email": .string("synthetic@example.invalid"),
        "exp": .number(now.timeIntervalSince1970 + 600), "iat": .number(now.timeIntervalSince1970)]
    if let nonce { claims["nonce"] = .string(nonce) }; return claims
}

@Test(arguments: CodexOAuthTestKey.Algorithm.allCases)
func codexOAuthIdentityVerifiesGeneratedPublicKeysAndRedactsMetadata(algorithm: CodexOAuthTestKey.Algorithm) throws {
    let key = try CodexOAuthTestKey(algorithm), now = Date(timeIntervalSince1970: 1_800_000_000)
    let token = try key.token(claims: codexOAuthTestClaims(now: now)), jwks = try key.jwks
    let identity = try CodexOAuthIdentityVerifier.verify(idToken: token, jwks: jwks,
        issuer: URL(string: "https://auth.openai.com")!, audience: "oaiapp_fixture", nonce: "fixture-nonce", now: now)
    #expect(identity.subject == "synthetic-subject" && identity.email == "synthetic@example.invalid")
    #expect(!String(reflecting: identity).contains(identity.subject))
    #expect(Mirror(reflecting: identity).children.isEmpty)
}

@Test(arguments: ["issuer", "audience", "nonce", "expired", "missingExpiry", "future", "signature", "duplicateKey", "algorithm", "privateKey", "keyOperation", "subject"])
func codexOAuthIdentityRejectsForeignOrUnprovenIdentity(fault: String) throws {
    let key = try CodexOAuthTestKey(.ec), now = Date(timeIntervalSince1970: 1_800_000_000)
    var claims = codexOAuthTestClaims(now: now), publicKey = key.jwk.object!
    var header: [String: JSONValue]?, expectedSubject: String?, jwks: Data
    switch fault {
    case "issuer": claims["iss"] = .string("https://foreign.invalid")
    case "audience": claims["aud"] = .array([.string("oaiapp_foreign")])
    case "nonce": claims["nonce"] = .string("another-nonce")
    case "expired": claims["exp"] = .number(now.timeIntervalSince1970 - 6)
    case "missingExpiry": claims.removeValue(forKey: "exp")
    case "future": claims["nbf"] = .number(now.timeIntervalSince1970 + 6)
    case "algorithm": header = ["alg": .string("HS256"), "kid": .string("fixture-key")]
    case "privateKey": publicKey["d"] = .string("untrusted-private-member")
    case "keyOperation": publicKey["key_ops"] = .array([.string("sign")])
    case "subject": expectedSubject = "other-subject"
    default: break
    }
    jwks = try JSONEncoder().encode(JSONValue.object(["keys": .array(fault == "duplicateKey" ? [key.jwk, key.jwk] : [.object(publicKey)])]))
    var token = try key.token(claims: claims, header: header)
    if fault == "signature" { token = String(token.dropLast()) + (token.last == "A" ? "B" : "A") }
    do {
        _ = try CodexOAuthIdentityVerifier.verify(idToken: token, jwks: jwks, issuer: URL(string: "https://auth.openai.com")!,
            audience: "oaiapp_fixture", nonce: "fixture-nonce", expectedSubject: expectedSubject, now: now)
        Issue.record("An unproven synthetic identity was accepted")
    } catch let error as CodexOAuthError { #expect(error.kind == (fault == "subject" ? .accountMismatch : .identityInvalid)) }
}

@Test func codexOAuthIdentityBoundsAndDecodedDuplicateClaimsAreRejected() throws {
    let key = try CodexOAuthTestKey(.ec), now = Date(timeIntervalSince1970: 1_800_000_000), jwks = try key.jwks
    let invalid = ["", "a.b", String(repeating: "x", count: 65_537), "a.b.c.d"]
    for token in invalid {
        #expect(throws: CodexOAuthError.self) {
            _ = try CodexOAuthIdentityVerifier.verify(idToken: token, jwks: jwks,
                issuer: URL(string: "https://auth.openai.com")!, audience: "oaiapp_fixture", nonce: nil, now: now)
        }
    }
    let duplicate = Data(#"{"iss":"first","\u0069ss":"second"}"#.utf8)
    #expect(throws: (any Error).self) { _ = try CodexOAuthParsing.object(duplicate) }
    let deep = Data((String(repeating: "[", count: 34) + "0" + String(repeating: "]", count: 34)).utf8)
    #expect(throws: (any Error).self) { _ = try CodexOAuthParsing.object(deep) }
}
