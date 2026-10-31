import CoincideKit
import CoincideRemoteKit
import Foundation
import Security

/// The remote server's TLS identity: a P-256 key and a self-signed certificate made once and kept in the login
/// Keychain. Phones pin the certificate's SHA-256 when they pair, so it must stay the same across launches and
/// updates; forgetting it (Settings › Remote › Reset) makes every paired phone pair again.
nonisolated struct RemoteIdentity: @unchecked Sendable {
    let identity: SecIdentity
    let certificateDER: Data

    /// Lowercase hex SHA-256 of the certificate, which the pairing code carries.
    var fingerprint: String { RemoteCrypto.sha256Hex(certificateDER) }

    /// "Coincide Remote", or "Coincide Debug Remote": the certificate is found by its label, so a Debug build makes and
    /// resets its own, never the installed app's (`CoincideIdentity`).
    static let label = "\(CoincideIdentity.displayName) Remote"
    private static let keyTag = Data(CoincideIdentity.scoped("remote.tls-key").utf8)

    /// The saved identity, or a new one made and saved now.
    static func loadOrCreate() throws -> RemoteIdentity {
        if let existing = load() { return existing }
        return try create()
    }

    static func load() -> RemoteIdentity? {
        let query: [CFString: Any] = [
            kSecClass: kSecClassCertificate, kSecAttrLabel: label, kSecReturnRef: true, kSecMatchLimit: kSecMatchLimitOne,
        ]
        var result: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess, let result,
            CFGetTypeID(result) == SecCertificateGetTypeID()
        else { return nil }
        let certificate = result as! SecCertificate
        var identity: SecIdentity?
        guard SecIdentityCreateWithCertificate(nil, certificate, &identity) == errSecSuccess, let identity else { return nil }
        return RemoteIdentity(identity: identity, certificateDER: SecCertificateCopyData(certificate) as Data)
    }

    /// Removes the key and certificate, so the next start makes new ones.
    static func reset() {
        SecItemDelete([kSecClass: kSecClassCertificate, kSecAttrLabel: label] as CFDictionary)
        SecItemDelete([kSecClass: kSecClassKey, kSecAttrApplicationTag: keyTag] as CFDictionary)
    }

    private static func create() throws -> RemoteIdentity {
        reset()
        var error: Unmanaged<CFError>?
        let attributes: [CFString: Any] = [
            kSecAttrKeyType: kSecAttrKeyTypeECSECPrimeRandom,
            kSecAttrKeySizeInBits: 256,
            kSecPrivateKeyAttrs: [
                kSecAttrIsPermanent: true, kSecAttrApplicationTag: keyTag, kSecAttrLabel: label,
            ] as [CFString: Any],
        ]
        guard let privateKey = SecKeyCreateRandomKey(attributes as CFDictionary, &error) else {
            throw error!.takeRetainedValue() as Error
        }
        guard let publicKey = SecKeyCopyPublicKey(privateKey),
            let publicBytes = SecKeyCopyExternalRepresentation(publicKey, &error) as Data?
        else { throw error.map { $0.takeRetainedValue() as Error } ?? RemoteIdentityError.keyUnavailable }
        let serial = Data((0..<12).map { _ in UInt8.random(in: 1...0x7F) })
        let der = try SelfSignedCertificate.make(commonName: label, publicKey: publicBytes, serial: serial) { tbs in
            guard let signature = SecKeyCreateSignature(privateKey, .ecdsaSignatureMessageX962SHA256, tbs as CFData, &error)
            else { throw error!.takeRetainedValue() as Error }
            return signature as Data
        }
        guard let certificate = SecCertificateCreateWithData(nil, der as CFData) else {
            throw RemoteIdentityError.invalidCertificate
        }
        let added = SecItemAdd(
            [kSecClass: kSecClassCertificate, kSecValueRef: certificate, kSecAttrLabel: label] as CFDictionary, nil)
        guard added == errSecSuccess || added == errSecDuplicateItem else { throw RemoteIdentityError.keychain(added) }
        var identity: SecIdentity?
        let status = SecIdentityCreateWithCertificate(nil, certificate, &identity)
        guard status == errSecSuccess, let identity else { throw RemoteIdentityError.keychain(status) }
        return RemoteIdentity(identity: identity, certificateDER: der)
    }
}

nonisolated enum RemoteIdentityError: LocalizedError {
    case keyUnavailable
    case invalidCertificate
    case keychain(OSStatus)

    var errorDescription: String? {
        switch self {
        case .keyUnavailable: String(localized: "Coincide couldn’t make a key for the remote server.")
        case .invalidCertificate: String(localized: "Coincide couldn’t make a certificate for the remote server.")
        case .keychain(let status):
            String(localized: "The Keychain refused the remote server’s certificate: \(SecCopyErrorMessageString(status, nil) as String? ?? "\(status)")")
        }
    }
}

/// A minimal X.509 v3 certificate for a P-256 key, signed with ECDSA-SHA256, in DER. Self-signed: issuer and subject
/// are the same name. Phones trust it by its fingerprint, not by its contents.
nonisolated enum SelfSignedCertificate {
    static func make(
        commonName: String, publicKey: Data, serial: Data, notBefore: Date = Date().addingTimeInterval(-86_400),
        notAfter: Date = Date().addingTimeInterval(20 * 365 * 86_400), sign: (Data) throws -> Data
    ) throws -> Data {
        let algorithm = DER.sequence([DER.oid([1, 2, 840, 10045, 4, 3, 2])])  // ecdsa-with-SHA256
        let name = DER.sequence([DER.set([DER.sequence([DER.oid([2, 5, 4, 3]), DER.utf8(commonName)])])])
        let keyInfo = DER.sequence([
            DER.sequence([DER.oid([1, 2, 840, 10045, 2, 1]), DER.oid([1, 2, 840, 10045, 3, 1, 7])]),  // id-ecPublicKey, P-256
            DER.bitString(publicKey),
        ])
        let extensions = DER.explicit(3, DER.sequence([
            // Basic constraints: not a certificate authority. Critical.
            DER.sequence([DER.oid([2, 5, 29, 19]), DER.boolean(true), DER.octetString(DER.sequence([]))]),
            // Key usage: digital signature. Critical.
            DER.sequence([DER.oid([2, 5, 29, 15]), DER.boolean(true), DER.octetString(DER.bitString(Data([0x80]), unusedBits: 7))]),
            // Extended key usage: TLS server.
            DER.sequence([DER.oid([2, 5, 29, 37]), DER.octetString(DER.sequence([DER.oid([1, 3, 6, 1, 5, 5, 7, 3, 1])]))]),
        ]))
        let tbs = DER.sequence([
            DER.explicit(0, DER.integer(Data([2]))),  // v3
            DER.integer(serial),
            algorithm,
            name,
            DER.sequence([DER.time(notBefore), DER.time(notAfter)]),
            name,
            keyInfo,
            extensions,
        ])
        let signature = try sign(tbs)
        return DER.sequence([tbs, algorithm, DER.bitString(signature)])
    }
}

/// The few DER encodings the certificate needs.
nonisolated enum DER {
    static func element(_ tag: UInt8, _ content: Data) -> Data {
        var data = Data([tag])
        let count = content.count
        if count < 0x80 {
            data.append(UInt8(count))
        } else {
            var bytes: [UInt8] = []
            var remaining = count
            while remaining > 0 {
                bytes.insert(UInt8(remaining & 0xFF), at: 0)
                remaining >>= 8
            }
            data.append(0x80 | UInt8(bytes.count))
            data.append(contentsOf: bytes)
        }
        data.append(content)
        return data
    }

    static func sequence(_ elements: [Data]) -> Data { element(0x30, elements.reduce(Data(), +)) }
    static func set(_ elements: [Data]) -> Data { element(0x31, elements.reduce(Data(), +)) }
    static func explicit(_ number: UInt8, _ content: Data) -> Data { element(0xA0 | number, content) }
    static func boolean(_ value: Bool) -> Data { element(0x01, Data([value ? 0xFF : 0x00])) }
    static func octetString(_ content: Data) -> Data { element(0x04, content) }
    static func utf8(_ string: String) -> Data { element(0x0C, Data(string.utf8)) }
    static func bitString(_ content: Data, unusedBits: UInt8 = 0) -> Data { element(0x03, Data([unusedBits]) + content) }

    /// A positive INTEGER from big-endian bytes.
    static func integer(_ bytes: Data) -> Data {
        var trimmed = Data(bytes.drop { $0 == 0 })
        if trimmed.isEmpty { trimmed = Data([0]) }
        if trimmed.first! & 0x80 != 0 { trimmed.insert(0, at: 0) }
        return element(0x02, trimmed)
    }

    static func oid(_ arcs: [UInt]) -> Data {
        var content = Data([UInt8(arcs[0] * 40 + arcs[1])])
        for arc in arcs.dropFirst(2) {
            var chunk: [UInt8] = [UInt8(arc & 0x7F)]
            var value = arc >> 7
            while value > 0 {
                chunk.insert(UInt8(value & 0x7F) | 0x80, at: 0)
                value >>= 7
            }
            content.append(contentsOf: chunk)
        }
        return element(0x06, content)
    }

    /// UTCTime before 2050, GeneralizedTime from then on, as RFC 5280 asks.
    static func time(_ date: Date) -> Data {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "UTC")
        let year = Calendar(identifier: .gregorian).dateComponents(in: TimeZone(identifier: "UTC")!, from: date).year ?? 2000
        if year < 2050 {
            formatter.dateFormat = "yyMMddHHmmss'Z'"
            return element(0x17, Data(formatter.string(from: date).utf8))
        }
        formatter.dateFormat = "yyyyMMddHHmmss'Z'"
        return element(0x18, Data(formatter.string(from: date).utf8))
    }
}
