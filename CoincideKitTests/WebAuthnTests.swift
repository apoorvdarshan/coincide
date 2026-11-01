import CryptoKit
import Foundation
import Testing
@testable import CoincideKit

/// The Public Suffix List as Coincide ships it. Vectors are from the list's own test file (tests/test_psl.txt).
@Suite struct PublicSuffixListTests {
    static let list = PublicSuffixList.bundled

    @Test func theBundledListLoadsCompletely() throws {
        let list = try #require(Self.list)
        #expect(list.isComplete)
        // A truncated copy isn't trusted.
        #expect(!PublicSuffixList("com\nco.uk\ngithub.io\n").isComplete)
    }

    @Test func registrableDomainsMatchTheListsOwnTests() throws {
        let list = try #require(Self.list)
        let vectors: [(String, String?)] = [
            ("com", nil), ("example.com", "example.com"), ("b.example.com", "example.com"), ("a.b.example.com", "example.com"),
            ("uk.com", nil), ("example.uk.com", "example.uk.com"), ("b.example.uk.com", "example.uk.com"), ("test.ac", "test.ac"),
            // Wildcards.
            ("mm", nil), ("c.mm", nil), ("b.c.mm", "b.c.mm"), ("a.b.c.mm", "b.c.mm"),
            ("jp", nil), ("test.jp", "test.jp"), ("www.test.jp", "test.jp"), ("ac.jp", nil), ("test.ac.jp", "test.ac.jp"),
            ("kyoto.jp", nil), ("test.kyoto.jp", "test.kyoto.jp"), ("ide.kyoto.jp", nil), ("b.ide.kyoto.jp", "b.ide.kyoto.jp"),
            ("a.b.ide.kyoto.jp", "b.ide.kyoto.jp"),
            // Wildcards with exceptions.
            ("c.kobe.jp", nil), ("b.c.kobe.jp", "b.c.kobe.jp"), ("a.b.c.kobe.jp", "b.c.kobe.jp"), ("city.kobe.jp", "city.kobe.jp"),
            ("www.city.kobe.jp", "city.kobe.jp"),
            ("ck", nil), ("test.ck", nil), ("b.test.ck", "b.test.ck"), ("a.b.test.ck", "b.test.ck"), ("www.ck", "www.ck"), ("www.www.ck", "www.ck"),
            ("us", nil), ("test.us", "test.us"), ("ak.us", nil), ("test.ak.us", "test.ak.us"), ("k12.ak.us", nil),
            ("test.k12.ak.us", "test.k12.ak.us"), ("www.test.k12.ak.us", "test.k12.ak.us"),
            // Internationalized rules, which the list writes in Unicode, against hosts in their ASCII form.
            ("xn--85x722f.com.cn", "xn--85x722f.com.cn"), ("xn--85x722f.xn--55qx5d.cn", "xn--85x722f.xn--55qx5d.cn"),
            ("www.xn--85x722f.xn--55qx5d.cn", "xn--85x722f.xn--55qx5d.cn"), ("shishi.xn--55qx5d.cn", "shishi.xn--55qx5d.cn"),
            ("xn--55qx5d.cn", nil), ("xn--85x722f.xn--fiqs8s", "xn--85x722f.xn--fiqs8s"), ("shishi.xn--fiqs8s", "shishi.xn--fiqs8s"),
            ("xn--fiqs8s", nil),
            // Unlisted top-level domains fall under the implicit "*".
            ("example", nil), ("example.example", "example.example"), ("b.example.example", "example.example"),
            // The private section counts.
            ("github.io", nil), ("alice.github.io", "alice.github.io"), ("www.alice.github.io", "alice.github.io"),
            ("s3.amazonaws.com", nil), ("bucket.s3.amazonaws.com", "bucket.s3.amazonaws.com"),
        ]
        for (host, expected) in vectors {
            #expect(list.registrableDomain(of: host) == expected, "\(host)")
        }
        #expect(list.isPublicSuffix("co.uk") && list.isPublicSuffix("github.io") && list.isPublicSuffix("com"))
        #expect(!list.isPublicSuffix("example.co.uk") && !list.isPublicSuffix("www.ck"))
        // Not domains.
        for host in ["", ".", "example.com.", ".example.com", "a..b", "bücher.de"] {
            #expect(list.publicSuffix(of: host) == nil, "\(host)")
        }
    }

    @Test func rulesAreReadLikeTheListSays() {
        let list = PublicSuffixList("""
            // A comment, then rules; text after whitespace is ignored.
            test
            *.wild.test extra words
            !keep.wild.test

            公司.test
            """)
        #expect(list.registrableDomain(of: "a.b.test") == "b.test")
        #expect(list.registrableDomain(of: "x.y.wild.test") == "x.y.wild.test")
        #expect(list.publicSuffix(of: "y.wild.test") == "y.wild.test")
        #expect(list.registrableDomain(of: "a.keep.wild.test") == "keep.wild.test")
        #expect(list.publicSuffix(of: "xn--55qx5d.test") == "xn--55qx5d.test")
        #expect(list.registrableDomain(of: "shop.xn--55qx5d.test") == "shop.xn--55qx5d.test")
    }

    @Test func punycodeMatchesRFC3492() {
        let vectors = [
            ("bücher", "bcher-kva"), ("münchen", "mnchen-3ya"), ("公司", "55qx5d"), ("网络", "io0a7i"), ("ελ", "qxam"), ("рф", "p1ai"),
            ("中国", "fiqs8s"), ("食狮", "85x722f"),
            // RFC 3492 §7.1 (A), Arabic (Egyptian).
            ("ليهمابتكلموشعربي؟", "egbpdaj6bu4bxfgehfvwxn"),
        ]
        for (unicode, ascii) in vectors { #expect(Punycode.encode(unicode) == ascii, "\(unicode)") }
    }
}

@Suite struct WebAuthnRelyingPartyTests {
    /// The bundled list (`theBundledListLoadsCompletely` fails without it; an empty list then fails these instead of crashing).
    static let suffixes = PublicSuffixList.bundled ?? PublicSuffixList("")

    func origin(_ host: String, scheme: String = "https", port: Int = 0) -> WebAuthnOrigin {
        WebAuthnOrigin(scheme: scheme, host: host, port: port)!
    }

    func validate(_ rpID: String?, from host: String, scheme: String = "https", port: Int = 0) -> String? {
        WebAuthnRelyingParty.validate(rpID, origin: origin(host, scheme: scheme, port: port), suffixes: Self.suffixes)
    }

    @Test func theRPIDDefaultsToTheHostAndMayBeAParentDomain() {
        #expect(validate(nil, from: "github.com") == "github.com")
        #expect(validate("github.com", from: "github.com") == "github.com")
        #expect(validate("google.com", from: "accounts.google.com") == "google.com")
        #expect(validate("example.co.uk", from: "a.b.example.co.uk") == "example.co.uk")
        #expect(validate("b.example.co.uk", from: "a.b.example.co.uk") == "b.example.co.uk")
        #expect(validate("alice.github.io", from: "www.alice.github.io") == "alice.github.io")
        #expect(validate("city.kobe.jp", from: "www.city.kobe.jp") == "city.kobe.jp")
    }

    @Test func pagesCantClaimAnotherSitesRPID() {
        // A different site, a lookalike that only contains the name, and a child of the page's own host.
        #expect(validate("github.com", from: "evil.com") == nil)
        #expect(validate("github.com", from: "github.com.evil.com") == nil)
        #expect(validate("github.com", from: "evilgithub.com") == nil)
        #expect(validate("sub.example.com", from: "example.com") == nil)
        #expect(validate("alice.github.io", from: "bob.github.io") == nil)
        #expect(validate("localhost", from: "example.com") == nil)
        #expect(validate("example.com", from: "localhost", scheme: "http", port: 3000) == nil)
    }

    @Test func publicSuffixesAreNeverRPIDs() {
        #expect(validate("com", from: "example.com") == nil)
        #expect(validate("co.uk", from: "a.b.example.co.uk") == nil)
        #expect(validate("uk", from: "a.b.example.co.uk") == nil)
        // A hosting platform's customers can't sign in as the whole platform, and the platform's host itself isn't one.
        #expect(validate("github.io", from: "alice.github.io") == nil)
        #expect(validate(nil, from: "github.io") == nil)
        #expect(validate("c.kobe.jp", from: "b.c.kobe.jp") == nil)
        // amazonaws.com isn't itself a suffix, but it is above the host's registrable domain (bucket.s3.amazonaws.com).
        #expect(validate("amazonaws.com", from: "bucket.s3.amazonaws.com") == nil)
        #expect(validate("s3.amazonaws.com", from: "bucket.s3.amazonaws.com") == nil)
    }

    @Test func malformedRPIDsFail() {
        for rpID in ["", "Example.com", "example.com.", ".example.com", "exa mple.com", "example..com", "xn--bcher-kva.example.com\u{0}",
            "bücher.example.com", "1.2.3.4", String(repeating: "a.", count: 130) + "com"] {
            #expect(validate(rpID, from: "example.com") == nil, "\(rpID)")
        }
    }

    @Test func onlySecureOriginsAndLocalhostCanUseWebAuthn() {
        #expect(validate(nil, from: "localhost", scheme: "http", port: 3000) == "localhost")
        #expect(validate("localhost", from: "localhost", scheme: "https") == "localhost")
        #expect(WebAuthnOrigin(scheme: "http", host: "example.com", port: 0) == nil)
        #expect(WebAuthnOrigin(scheme: "http", host: "127.0.0.1", port: 8080) == nil)
        #expect(WebAuthnOrigin(scheme: "https", host: "192.168.1.1", port: 0) == nil)
        #expect(WebAuthnOrigin(scheme: "https", host: "::1", port: 0) == nil)
        #expect(WebAuthnOrigin(scheme: "https", host: "[::1]", port: 0) == nil)
        #expect(WebAuthnOrigin(scheme: "https", host: "intranet", port: 0) == nil)
        #expect(WebAuthnOrigin(scheme: "ftp", host: "example.com", port: 0) == nil)
        #expect(WebAuthnOrigin(scheme: "file", host: "", port: 0) == nil)
        #expect(WebAuthnOrigin(scheme: "", host: "", port: 0) == nil)
        #expect(WebAuthnOrigin(scheme: "https", host: "example.com", port: 70_000) == nil)
    }

    @Test func originsSerializeAsClientDataNamesThem() throws {
        #expect(origin("example.com").serialized == "https://example.com")
        #expect(origin("example.com", port: 443).serialized == "https://example.com")
        #expect(origin("Example.COM", port: 8443).serialized == "https://example.com:8443")
        #expect(origin("localhost", scheme: "http", port: 80).serialized == "http://localhost")
        #expect(origin("localhost", scheme: "http", port: 3000).serialized == "http://localhost:3000")
        #expect(WebAuthnOrigin(url: try #require(URL(string: "https://github.com/login?x=1"))) == origin("github.com"))
        #expect(WebAuthnOrigin(url: try #require(URL(string: "https://github.com:8443/"))) == origin("github.com", port: 8443))
        #expect(WebAuthnOrigin(url: try #require(URL(string: "about:blank"))) == nil)
    }
}

@Suite struct WebAuthnAssertionTests {
    @Test func clientDataIsTheSpecificationsSerialization() {
        let data = WebAuthnAssertion.clientDataJSON(challenge: Data([0xfb, 0xff, 0x01]), origin: "https://example.com")
        #expect(String(decoding: data, as: UTF8.self)
            == #"{"type":"webauthn.get","challenge":"-_8B","origin":"https://example.com","crossOrigin":false}"#)
        let parsed = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        #expect(parsed?["crossOrigin"] as? Bool == false)
        #expect(WebAuthnAssertion.quoted("a\"b\\c\u{1}d") == #""a\"b\\c\u0001d""#)
        #expect(WebAuthnAssertion.quoted("é") == "\"é\"")
    }

    @Test func authenticatorDataIsRPIDHashFlagsAndCounter() {
        let data = WebAuthnAssertion.authenticatorData(rpID: "example.com", flags: [.userPresent, .userVerified, .backupEligible, .backedUp],
            signCount: 0x0102_0304)
        #expect(data.count == 37)
        #expect(data.map { String(format: "%02x", $0) }.joined()
            == "a379a6f6eeafb9a55e378c118034e2751e682fab9f2d30ab13d2125586ce1947" + "1d" + "01020304")
        // User presence alone, as Bitwarden's synced passkeys report it without verification.
        let present = WebAuthnAssertion.authenticatorData(rpID: "example.com", flags: [.userPresent, .backupEligible, .backedUp], signCount: 0)
        #expect(present[32] == 0x19 && present.suffix(4) == Data([0, 0, 0, 0]))
    }

    @Test func theSignatureVerifiesAgainstTheDerivedPublicKey() throws {
        let key = P256.Signing.PrivateKey()
        let authenticatorData = WebAuthnAssertion.authenticatorData(rpID: "github.com", flags: [.userPresent], signCount: 0)
        let clientData = WebAuthnAssertion.clientDataJSON(challenge: Data(repeating: 7, count: 32), origin: "https://github.com")
        let signature = try WebAuthnAssertion.signature(authenticatorData: authenticatorData, clientDataJSON: clientData,
            pkcs8: key.derRepresentation)
        let parsed = try P256.Signing.ECDSASignature(derRepresentation: signature)
        var signed = authenticatorData
        signed.append(Data(SHA256.hash(data: clientData)))
        #expect(key.publicKey.isValidSignature(parsed, for: signed))
        // Bound to these exact bytes.
        var other = authenticatorData
        other.append(Data(SHA256.hash(data: WebAuthnAssertion.clientDataJSON(challenge: Data(repeating: 8, count: 32), origin: "https://github.com"))))
        #expect(!key.publicKey.isValidSignature(parsed, for: other))
        // A key that isn't PKCS#8 or SEC1 is refused.
        #expect(throws: (any Error).self) {
            _ = try WebAuthnAssertion.signature(authenticatorData: authenticatorData, clientDataJSON: clientData, pkcs8: Data([1, 2, 3]))
        }
    }

    @Test func base64URLRoundTripsAndReadsWhatBitwardenWrites() {
        for length in 0..<40 {
            let data = Data((0..<length).map { UInt8(($0 * 37 + 11) & 0xff) })
            let text = Base64URL.encode(data)
            #expect(!text.contains("=") && !text.contains("+") && !text.contains("/"))
            #expect(Base64URL.decode(text) == data)
        }
        #expect(Base64URL.decode("-_8B") == Data([0xfb, 0xff, 0x01]))
        #expect(Base64URL.decode("+/8B") == Data([0xfb, 0xff, 0x01]))
        #expect(Base64URL.decode("AQ==") == Data([1]))
        #expect(Base64URL.decode("AQI=") == Data([1, 2]))
        for invalid in ["A", "AQ=", "AQI==", "A Q", "AQ*", "AQ\n", "====="] { #expect(Base64URL.decode(invalid) == nil, "\(invalid)") }
    }
}

@Suite struct WebAuthnGetRequestTests {
    static func message(_ publicKey: [String: Any], id: String = "abc123", extra: [String: Any] = [:]) -> [String: Any] {
        (["kind": "get", "id": id, "publicKey": publicKey] as [String: Any]).merging(extra) { $1 }
    }

    static let challenge = Base64URL.encode(Data(repeating: 1, count: 32))

    @Test func readsTheScriptsMessage() throws {
        let request = try #require(WebAuthnGetRequest(message: Self.message([
            "challenge": Self.challenge, "rpId": "github.com", "userVerification": "required", "timeout": NSNumber(value: 60_000),
            "allowCredentials": [
                ["id": Base64URL.encode(Data([1, 2, 3])), "type": "public-key", "transports": ["internal", "hybrid"]] as [String: Any],
                ["id": Base64URL.encode(Data([4])), "type": "other"],
            ] as [Any],
        ], extra: ["mediation": "required"])))
        #expect(request.id == "abc123" && request.challenge == Data(repeating: 1, count: 32) && request.rpID == "github.com")
        #expect(request.userVerification == .required && request.timeout == 60_000 && request.mediation == .required)
        // Descriptors of other types don't name passkeys.
        #expect(request.allowCredentials == [.init(id: Data([1, 2, 3]), transports: ["internal", "hybrid"])])

        let plain = try #require(WebAuthnGetRequest(message: Self.message(["challenge": Self.challenge, "userVerification": "sometimes",
            "timeout": NSNumber(value: true)])))
        #expect(plain.rpID == nil && plain.allowCredentials.isEmpty && plain.userVerification == .preferred && plain.timeout == nil)
        #expect(plain.mediation == .optional)
    }

    @Test func refusesMalformedOrOversizedMessages() {
        let big = Base64URL.encode(Data(repeating: 2, count: WebAuthnGetRequest.maxChallenge + 1))
        let longID = Base64URL.encode(Data(repeating: 3, count: WebAuthnGetRequest.maxCredentialID + 1))
        let many = (0...WebAuthnGetRequest.maxAllowedCredentials).map { _ in ["id": "AQ", "type": "public-key"] }
        let invalid: [Any] = [
            "not a dictionary", ["kind": "get"],
            ["kind": "create", "id": "a", "publicKey": ["challenge": Self.challenge]] as [String: Any],
            Self.message(["challenge": Self.challenge], id: ""), Self.message(["challenge": Self.challenge], id: "has space"),
            Self.message(["challenge": Self.challenge], id: String(repeating: "a", count: 65)),
            Self.message([:]), Self.message(["challenge": ""]), Self.message(["challenge": "*"]), Self.message(["challenge": big]),
            Self.message(["challenge": NSNumber(value: 1)]),
            Self.message(["challenge": Self.challenge, "rpId": NSNumber(value: 1)]),
            Self.message(["challenge": Self.challenge, "rpId": String(repeating: "a", count: 254)]),
            Self.message(["challenge": Self.challenge, "allowCredentials": "AQ"]),
            Self.message(["challenge": Self.challenge, "allowCredentials": many]),
            Self.message(["challenge": Self.challenge, "allowCredentials": [["id": longID, "type": "public-key"]]]),
            Self.message(["challenge": Self.challenge, "allowCredentials": [["type": "public-key"]]]),
            Self.message(["challenge": Self.challenge], extra: ["mediation": "sometimes"]),
        ]
        for body in invalid { #expect(WebAuthnGetRequest(message: body) == nil, "\(body)") }
    }

    @Test func waitsWithinBitwardensClamps() {
        func limit(_ timeout: Double?, _ verification: WebAuthnGetRequest.UserVerification = .preferred) -> TimeInterval {
            WebAuthnGetRequest(id: "a", challenge: Data([1]), userVerification: verification, timeout: timeout).waitLimit
        }
        #expect(limit(nil) == 300 && limit(1_000) == 30 && limit(120_000) == 120 && limit(3_600_000) == 600)
        #expect(limit(nil, .discouraged) == 120 && limit(3_600_000, .discouraged) == 180 && limit(0, .discouraged) == 30)
    }
}
