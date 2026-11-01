import Foundation

/// A passkey saved in the user's Bitwarden vault, without its private key: what Coincide matches against a page's
/// request and shows the user before they confirm. The key itself is read from `bw` again only after they do
/// (`BitwardenProvider.assertion`).
///
/// Field encodings follow Bitwarden's own clients (bitwarden/clients, `fido2-authenticator.service.ts`,
/// `credential-id-utils.ts`, `fido2-credential.export.ts`): `bw` writes `counter` and `discoverable` as strings, a
/// credential ID is either a GUID or `b64.` and base64url, and only an item's first passkey is used.
public nonisolated struct BitwardenPasskey: Sendable, Hashable, Identifiable {
    public var id: String { itemID }
    public let itemID: String
    public let itemName: String
    /// The account's name on the site (the passkey's user name, else the login's username).
    public let userName: String
    public let userDisplayName: String
    public let rpID: String
    /// As Bitwarden stores it, compared when the item is read again.
    public let storedCredentialID: String
    public let credentialID: Data
    public let userHandle: Data?
    public let counter: UInt32
    public let discoverable: Bool
    /// Bitwarden's master password re-prompt is on for the item; Coincide then signs only after Touch ID or the Mac's
    /// password succeeds.
    public let requiresReprompt: Bool

    public init(itemID: String, itemName: String, userName: String, userDisplayName: String = "", rpID: String,
        storedCredentialID: String, credentialID: Data, userHandle: Data?, counter: UInt32, discoverable: Bool,
        requiresReprompt: Bool = false) {
        self.itemID = itemID
        self.itemName = itemName
        self.userName = userName
        self.userDisplayName = userDisplayName
        self.rpID = rpID
        self.storedCredentialID = storedCredentialID
        self.credentialID = credentialID
        self.userHandle = userHandle
        self.counter = counter
        self.discoverable = discoverable
        self.requiresReprompt = requiresReprompt
    }

    /// How the prompt names the account.
    public var accountName: String {
        [userName, userDisplayName, itemName].first { !$0.isEmpty } ?? rpID
    }

    /// `bw list items`: every login's passkey Coincide can sign with.
    public static func parseList(_ json: String) -> [BitwardenPasskey] {
        (JSONValue.parse(Data(json.utf8))?.array ?? []).compactMap(parse(item:))
    }

    /// One item from `bw list items` or `bw get item`: a login (`type` 1), not in the trash, whose first passkey is an
    /// ES256 key (ECDSA on P-256, the only kind Bitwarden creates) with a readable credential ID and counter.
    static func parse(item: JSONValue) -> BitwardenPasskey? {
        guard item["type"]?.int == 1, item["deletedDate"]?.string == nil, let itemID = item["id"]?.string, !itemID.isEmpty,
            let login = item["login"], let credential = login["fido2Credentials"]?[0],
            credential["keyType"]?.string == "public-key", credential["keyAlgorithm"]?.string == "ECDSA",
            credential["keyCurve"]?.string == "P-256",
            let rpID = credential["rpId"]?.string, !rpID.isEmpty,
            let stored = credential["credentialId"]?.string, let credentialID = PasskeyCredentialID.raw(stored),
            let counter = counter(credential["counter"])
        else { return nil }
        let discoverable = credential["discoverable"]?.string == "true" || credential["discoverable"]?.bool == true
        let userHandle = credential["userHandle"]?.string.flatMap { $0.isEmpty ? nil : Base64URL.decode($0) }
        return BitwardenPasskey(itemID: itemID, itemName: item["name"]?.string ?? "",
            userName: credential["userName"]?.string.flatMap { $0.isEmpty ? nil : $0 } ?? login["username"]?.string ?? "",
            userDisplayName: credential["userDisplayName"]?.string ?? "", rpID: rpID, storedCredentialID: stored,
            credentialID: credentialID, userHandle: userHandle, counter: counter, discoverable: discoverable,
            requiresReprompt: (item["reprompt"]?.int ?? 0) != 0)
    }

    /// `counter` as `bw` writes it, a decimal string; empty counts as 0 like Bitwarden. A value that isn't a 32-bit
    /// count makes the passkey unusable rather than guessed.
    static func counter(_ value: JSONValue?) -> UInt32? {
        switch value {
        case nil, .null?: return 0
        case .string(let text)?:
            let text = text.trimmingCharacters(in: .whitespaces)
            return text.isEmpty ? 0 : UInt32(text)
        case .number(let number)?:
            return number >= 0 && number <= Double(UInt32.max) && number.rounded() == number ? UInt32(number) : nil
        default: return nil
        }
    }

    /// The passkeys that may answer a request for `rpID`: with `allowCredentials`, those whose credential ID it names;
    /// without, the discoverable ones. The RP ID must match exactly, as Bitwarden compares it. Sorted by account.
    public static func matching(_ passkeys: [BitwardenPasskey], rpID: String, allowCredentials: [Data]) -> [BitwardenPasskey] {
        let allowed = Set(allowCredentials)
        return passkeys.filter { passkey in
            guard passkey.rpID == rpID else { return false }
            return allowed.isEmpty ? passkey.discoverable : allowed.contains(passkey.credentialID)
        }
        .sorted { lhs, rhs in
            let order = lhs.accountName.localizedStandardCompare(rhs.accountName)
            return order == .orderedSame ? lhs.itemName.localizedStandardCompare(rhs.itemName) == .orderedAscending : order == .orderedAscending
        }
    }
}

/// Bitwarden's stored credential IDs: `b64.` followed by base64url of the raw ID (passkeys Bitwarden imported), or a
/// GUID whose 16 bytes are the raw ID (passkeys Bitwarden created).
public nonisolated enum PasskeyCredentialID {
    public static func raw(_ stored: String) -> Data? {
        if stored.hasPrefix("b64.") {
            guard let data = Base64URL.decode(String(stored.dropFirst(4))), !data.isEmpty,
                data.count <= WebAuthnGetRequest.maxCredentialID
            else { return nil }
            return data
        }
        guard stored.utf8.count == 36, let uuid = UUID(uuidString: stored) else { return nil }
        return withUnsafeBytes(of: uuid.uuid) { Data($0) }
    }
}

/// A signed sign-in, ready for the page. Holds no key material.
public nonisolated struct PasskeyAssertion: Sendable, Equatable {
    public let credentialID: Data
    public let authenticatorData: Data
    public let signature: Data
    public let userHandle: Data?

    public init(credentialID: Data, authenticatorData: Data, signature: Data, userHandle: Data?) {
        self.credentialID = credentialID
        self.authenticatorData = authenticatorData
        self.signature = signature
        self.userHandle = userHandle
    }
}

/// Where passkeys come from: Bitwarden in the app, a fake in tests.
public protocol PasskeyVault: Sendable {
    /// Every usable passkey, without private keys.
    func passkeys() async throws -> [BitwardenPasskey]
    /// Signs in with `passkey` for `rpID`, reading its private key only now.
    func assertion(for passkey: BitwardenPasskey, rpID: String, clientDataJSON: Data, userVerified: Bool) async throws -> PasskeyAssertion
}

extension BitwardenProvider: PasskeyVault {
    /// Whether Coincide holds an unlocked Bitwarden session, checked without starting `bw`.
    public var hasSession: Bool { sessions.read(Self.sessionAccount).map { !$0.isEmpty } ?? false }

    /// `bw` can't list only passkeys or leave out fields, so this reads the vault's item list and keeps only the
    /// passkeys' public details; the output is dropped when it returns.
    public func passkeys() async throws -> [BitwardenPasskey] {
        BitwardenPasskey.parseList(try await run(["list", "items"]))
    }

    /// Reads the passkey's item again, checks it is still the passkey the user chose for `rpID`, signs, and counts the
    /// use the way Bitwarden does: a counter above 0 is synced first, incremented, and saved back before the assertion
    /// is returned (none is returned if saving fails); a counter of 0 stays 0. The private key is decoded only here and
    /// erased after signing.
    public func assertion(for passkey: BitwardenPasskey, rpID: String, clientDataJSON: Data, userVerified: Bool) async throws -> PasskeyAssertion {
        // Another device may have advanced the counter since this Mac's copy of the vault was synced.
        if passkey.counter > 0 { _ = try await run(["sync"]) }
        guard let item = JSONValue.parse(Data(try await run(["get", "item", passkey.itemID]).utf8)),
            let current = BitwardenPasskey.parse(item: item), current.itemID == passkey.itemID,
            current.storedCredentialID == passkey.storedCredentialID, current.rpID == rpID,
            userVerified || !current.requiresReprompt
        else { throw PasswordProviderError.notFound }
        let counter = try BitwardenPasskeyCounter.next(after: current.counter)
        var flags: WebAuthnAssertion.Flags = [.userPresent, .backupEligible, .backedUp]
        if userVerified { flags.insert(.userVerified) }
        let authenticatorData = WebAuthnAssertion.authenticatorData(rpID: rpID, flags: flags, signCount: counter)
        guard let keyText = item["login"]?["fido2Credentials"]?[0]?["keyValue"]?.string, var key = Base64URL.decode(keyText) else {
            throw PasswordProviderError.notFound
        }
        defer { key.resetBytes(in: 0..<key.count) }
        let signature = try WebAuthnAssertion.signature(authenticatorData: authenticatorData, clientDataJSON: clientDataJSON, pkcs8: key)
        if counter != current.counter {
            guard let edited = BitwardenPasskeyCounter.item(item, settingCounter: counter) else { throw PasswordProviderError.notFound }
            let saved = try await run(["edit", "item", passkey.itemID], input: Data(edited.compactJSON.utf8).base64EncodedString())
            guard let savedItem = JSONValue.parse(Data(saved.utf8)), BitwardenPasskey.parse(item: savedItem)?.counter == counter else {
                throw PasswordProviderError.failed(String(localized: "Bitwarden didn’t save the passkey’s sign-in count."))
            }
        }
        return PasskeyAssertion(credentialID: current.credentialID, authenticatorData: authenticatorData, signature: signature,
            userHandle: current.userHandle)
    }
}

/// Bitwarden's signature counter rule, and the item edit that saves a new count.
public nonisolated enum BitwardenPasskeyCounter {
    /// The count for the next sign-in: 0 stays 0 (Bitwarden's synced passkeys don't count), anything else goes up by
    /// one. Throws when the count can't go higher.
    public static func next(after counter: UInt32) throws -> UInt32 {
        guard counter > 0 else { return 0 }
        guard counter < UInt32.max else { throw PasswordProviderError.failed(String(localized: "The passkey’s sign-in count can’t go higher.")) }
        return counter + 1
    }

    /// `item` (from `bw get item`) with its first passkey's counter set, for `bw edit item`.
    static func item(_ item: JSONValue, settingCounter counter: UInt32) -> JSONValue? {
        guard case .object(var root) = item, case .object(var login)? = root["login"],
            case .array(var credentials)? = login["fido2Credentials"], case .object(var first)? = credentials.first
        else { return nil }
        first["counter"] = .string(String(counter))
        credentials[0] = .object(first)
        login["fido2Credentials"] = .array(credentials)
        root["login"] = .object(login)
        return .object(root)
    }
}

extension PasswordVault {
    /// Bitwarden, when the user lets the browser sign in with its passkeys (`BrowserSettings.usesBitwardenPasskeys`)
    /// and Bitwarden is turned on and unlocked in Coincide; otherwise nil.
    public var bitwardenPasskeys: BitwardenProvider? {
        guard settings.settings.usesBitwardenPasskeys, enabledKinds.contains(.bitwarden),
            let bitwarden = providers[.bitwarden] as? BitwardenProvider, bitwarden.hasSession
        else { return nil }
        return bitwarden
    }
}
