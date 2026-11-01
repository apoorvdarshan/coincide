import CryptoKit
import Foundation
import Testing
@testable import CoincideKit

/// Synthetic `bw` output with keys generated for each test. No real vault, passkey or Keychain item is used.
enum PasskeyFixture {
    static func item(id: String = "item-1", name: String = "GitHub", rpID: String = "github.com", credentialID: String = "b64.AQIDBA",
        key: P256.Signing.PrivateKey = P256.Signing.PrivateKey(), counter: Any = "0", discoverable: Any = "true",
        userName: String = "octocat", loginUsername: String = "octocat@example.test", userHandle: Data = Data([0xa1, 0xb2]),
        reprompt: Int = 0, curve: String = "P-256", type: Int = 1, deletedDate: Any = NSNull()) -> [String: Any] {
        [
            "object": "item", "id": id, "type": type, "name": name, "reprompt": reprompt, "deletedDate": deletedDate,
            "notes": NSNull(), "favorite": false, "fields": [] as [Any], "collectionIds": [] as [Any],
            "login": [
                "username": loginUsername, "password": "fixture-password", "totp": NSNull(),
                "uris": [["match": NSNull(), "uri": "https://\(rpID)"]] as [[String: Any]],
                "fido2Credentials": [[
                    "credentialId": credentialID, "keyType": "public-key", "keyAlgorithm": "ECDSA", "keyCurve": curve,
                    "keyValue": Base64URL.encode(key.derRepresentation), "rpId": rpID, "userHandle": Base64URL.encode(userHandle),
                    "userName": userName, "counter": counter, "rpName": name, "userDisplayName": "The Octocat",
                    "discoverable": discoverable, "creationDate": "2026-01-01T00:00:00.000Z",
                ] as [String: Any]],
            ] as [String: Any],
        ]
    }

    static func json(_ value: Any) -> String {
        String(decoding: try! JSONSerialization.data(withJSONObject: value, options: [.sortedKeys]), as: UTF8.self)
    }

    static func passkey(_ item: [String: Any]) -> BitwardenPasskey? {
        JSONValue.parse(Data(json(item).utf8)).flatMap(BitwardenPasskey.parse(item:))
    }

    static func keyValue(_ item: [String: Any]) -> String {
        (((item["login"] as? [String: Any])?["fido2Credentials"] as? [[String: Any]])?.first?["keyValue"] as? String) ?? ""
    }

    static func provider(_ runner: FakeRunner) throws -> BitwardenProvider {
        let sessions = MemorySecretStore()
        try sessions.write("fixture-session", for: BitwardenProvider.sessionAccount)
        return BitwardenProvider(runner: runner, sessions: sessions)
    }
}

@Suite struct BitwardenPasskeyTests {
    @Test func credentialIDsConvertLikeBitwardens() {
        #expect(PasskeyCredentialID.raw("b64.AQIDBA") == Data([1, 2, 3, 4]))
        #expect(PasskeyCredentialID.raw("b64.-_8B") == Data([0xfb, 0xff, 0x01]))
        // A GUID is its 16 bytes in order: Bitwarden's own AAGUID, as its source writes both forms.
        let aaguid = Data([0xd5, 0x48, 0x82, 0x6e, 0x79, 0xb4, 0xdb, 0x40, 0xa3, 0xd8, 0x11, 0x11, 0x6f, 0x7e, 0x83, 0x49])
        #expect(PasskeyCredentialID.raw("d548826e-79b4-db40-a3d8-11116f7e8349") == aaguid)
        #expect(PasskeyCredentialID.raw("D548826E-79B4-DB40-A3D8-11116F7E8349") == aaguid)
        for invalid in ["", "b64.", "b64.***", "d548826e79b4db40a3d811116f7e8349", "{d548826e-79b4-db40-a3d8-11116f7e8349}", "AQIDBA",
            "b64." + Base64URL.encode(Data(repeating: 1, count: 1_024))] {
            #expect(PasskeyCredentialID.raw(invalid) == nil, "\(invalid)")
        }
    }

    @Test func readsOnlyUsablePasskeysWithoutTheirKeys() throws {
        let good = PasskeyFixture.item()
        let items: [Any] = [
            good,
            PasskeyFixture.item(id: "guid", credentialID: "d548826e-79b4-db40-a3d8-11116f7e8349", counter: "7", discoverable: "false",
                userName: "", reprompt: 1),
            PasskeyFixture.item(id: "p384", curve: "P-384"),
            PasskeyFixture.item(id: "note", type: 2),
            PasskeyFixture.item(id: "trash", deletedDate: "2026-02-01T00:00:00.000Z"),
            PasskeyFixture.item(id: "bad-counter", counter: "lots"),
            PasskeyFixture.item(id: "big-counter", counter: "4294967296"),
            PasskeyFixture.item(id: "bad-id", credentialID: "nope"),
            ["object": "item", "id": "plain", "type": 1, "name": "Plain", "login": ["username": "me", "password": "pw"]] as [String: Any],
        ]
        let passkeys = BitwardenPasskey.parseList(PasskeyFixture.json(items))
        #expect(passkeys.map(\.itemID) == ["item-1", "guid"])
        let first = try #require(passkeys.first)
        #expect(first.rpID == "github.com" && first.credentialID == Data([1, 2, 3, 4]) && first.storedCredentialID == "b64.AQIDBA")
        #expect(first.userName == "octocat" && first.userHandle == Data([0xa1, 0xb2]) && first.counter == 0 && first.discoverable)
        #expect(!first.requiresReprompt && first.accountName == "octocat")
        let second = passkeys[1]
        // Without the passkey's user name, the login's username names the account.
        #expect(second.userName == "octocat@example.test" && second.counter == 7 && !second.discoverable && second.requiresReprompt)
        // The private key isn't part of what's kept.
        var dumped = ""
        dump(passkeys, to: &dumped)
        #expect(!dumped.contains(PasskeyFixture.keyValue(good)) && !dumped.contains("fixture-password"))
        // Counters as bw writes them; numbers and missing ones too.
        #expect(BitwardenPasskey.counter(.string("")) == 0 && BitwardenPasskey.counter(nil) == 0 && BitwardenPasskey.counter(.number(3)) == 3)
        #expect(BitwardenPasskey.counter(.string("-1")) == nil && BitwardenPasskey.counter(.number(1.5)) == nil)
    }

    @Test func matchesTheRPIDAndAllowCredentialsLikeBitwarden() throws {
        func passkey(_ id: String, rpID: String = "github.com", credential: Data, discoverable: Bool = true, user: String) -> BitwardenPasskey {
            BitwardenPasskey(itemID: id, itemName: "Item " + id, userName: user, rpID: rpID, storedCredentialID: "b64." + Base64URL.encode(credential),
                credentialID: credential, userHandle: nil, counter: 0, discoverable: discoverable)
        }
        let work = passkey("w", credential: Data([1]), user: "work")
        let home = passkey("h", credential: Data([2]), user: "home")
        let hidden = passkey("n", credential: Data([3]), discoverable: false, user: "hidden")
        let other = passkey("o", rpID: "gitlab.com", credential: Data([4]), user: "other")
        let parent = passkey("p", rpID: "github.com.evil.test", credential: Data([5]), user: "evil")
        let all = [work, home, hidden, other, parent]
        // No allowCredentials: the site's discoverable passkeys, sorted by account.
        #expect(BitwardenPasskey.matching(all, rpID: "github.com", allowCredentials: []).map(\.itemID) == ["h", "w"])
        // allowCredentials names exactly which, discoverable or not, and only for this RP ID.
        #expect(BitwardenPasskey.matching(all, rpID: "github.com", allowCredentials: [Data([3]), Data([1])]).map(\.itemID) == ["n", "w"])
        #expect(BitwardenPasskey.matching(all, rpID: "github.com", allowCredentials: [Data([4]), Data([9])]).isEmpty)
        #expect(BitwardenPasskey.matching(all, rpID: "GitHub.com", allowCredentials: []).isEmpty)
        #expect(BitwardenPasskey.matching(all, rpID: "evil.test", allowCredentials: []).isEmpty)
    }

    @Test func countsLikeBitwarden() throws {
        #expect(try BitwardenPasskeyCounter.next(after: 0) == 0)
        #expect(try BitwardenPasskeyCounter.next(after: 41) == 42)
        #expect(throws: PasswordProviderError.self) { _ = try BitwardenPasskeyCounter.next(after: UInt32.max) }
        let item = try #require(JSONValue.parse(Data(PasskeyFixture.json(PasskeyFixture.item(counter: "5")).utf8)))
        let edited = try #require(BitwardenPasskeyCounter.item(item, settingCounter: 6))
        #expect(edited["login"]?["fido2Credentials"]?[0]?["counter"]?.string == "6")
        // Everything else is sent back as it was.
        #expect(edited["login"]?["password"] == item["login"]?["password"] && edited["name"] == item["name"])
        #expect(edited["login"]?["fido2Credentials"]?[0]?["keyValue"] == item["login"]?["fido2Credentials"]?[0]?["keyValue"])
        #expect(BitwardenPasskeyCounter.item(.object(["login": .object([:])]), settingCounter: 1) == nil)
    }
}

@Suite struct BitwardenPasskeyProviderTests {
    static let clientData = WebAuthnAssertion.clientDataJSON(challenge: Data(repeating: 5, count: 32), origin: "https://github.com")

    static func verify(_ assertion: PasskeyAssertion, key: P256.Signing.PrivateKey) throws -> Bool {
        var signed = assertion.authenticatorData
        signed.append(Data(SHA256.hash(data: clientData)))
        return key.publicKey.isValidSignature(try P256.Signing.ECDSASignature(derRepresentation: assertion.signature), for: signed)
    }

    @Test func signsWithAFreshReadAndLeavesAZeroCounterAlone() async throws {
        let key = P256.Signing.PrivateKey()
        let item = PasskeyFixture.item(key: key)
        let runner = FakeRunner(installed: ["bw"])
        let provider = try PasskeyFixture.provider(runner)
        runner.reply(["list", "items"], stdout: PasskeyFixture.json([item]))
        let passkey = try #require(try await provider.passkeys().first)
        runner.reply(["get", "item", "item-1"], stdout: PasskeyFixture.json(item))
        let assertion = try await provider.assertion(for: passkey, rpID: "github.com", clientDataJSON: Self.clientData, userVerified: true)
        #expect(assertion.credentialID == Data([1, 2, 3, 4]) && assertion.userHandle == Data([0xa1, 0xb2]))
        #expect(assertion.authenticatorData
            == WebAuthnAssertion.authenticatorData(rpID: "github.com", flags: [.userPresent, .userVerified, .backupEligible, .backedUp], signCount: 0))
        #expect(try Self.verify(assertion, key: key))
        #expect(runner.calls.map { $0.arguments.first ?? "" } == ["list", "get"])
        #expect(runner.calls.allSatisfy { $0.environment["BW_SESSION"] == "fixture-session" && $0.arguments.last == "--nointeraction" })
        // The key never goes into a command line, the reply or a description.
        let secret = PasskeyFixture.keyValue(item)
        #expect(!runner.allArguments.contains(secret))
        let reply = WebAuthnReply.credential(PasskeyCredential(assertion: assertion, clientDataJSON: Self.clientData))
        #expect(reply.message.values.allSatisfy { !$0.contains(secret) })
        var dumped = ""
        dump(assertion, to: &dumped)
        #expect(!dumped.contains(secret))

        // Without verification, the UV flag stays off.
        let unverified = try await provider.assertion(for: passkey, rpID: "github.com", clientDataJSON: Self.clientData, userVerified: false)
        #expect(unverified.authenticatorData[32] == 0x19)
        #expect(try Self.verify(unverified, key: key))
    }

    @Test func aCounterAboveZeroIsSyncedIncrementedAndSavedBeforeSigning() async throws {
        let key = P256.Signing.PrivateKey()
        let item = PasskeyFixture.item(key: key, counter: "5")
        let runner = FakeRunner(installed: ["bw"])
        let provider = try PasskeyFixture.provider(runner)
        let passkey = try #require(PasskeyFixture.passkey(item))
        runner.reply(["sync"], stdout: "Syncing complete.")
        runner.reply(["get", "item", "item-1"], stdout: PasskeyFixture.json(item))
        runner.reply(["edit", "item", "item-1"], stdout: PasskeyFixture.json(PasskeyFixture.item(key: key, counter: "6")))
        let assertion = try await provider.assertion(for: passkey, rpID: "github.com", clientDataJSON: Self.clientData, userVerified: true)
        #expect(assertion.authenticatorData.suffix(4) == Data([0, 0, 0, 6]))
        #expect(try Self.verify(assertion, key: key))
        #expect(runner.calls.map { $0.arguments.first ?? "" } == ["sync", "get", "edit"])
        // The edit goes through standard input (bw's base64 JSON), never the command line.
        let edit = try #require(runner.calls.last)
        #expect(edit.arguments == ["edit", "item", "item-1", "--nointeraction"])
        let sent = try #require(edit.input.flatMap { Data(base64Encoded: $0) }.flatMap { JSONValue.parse($0) })
        #expect(sent["login"]?["fido2Credentials"]?[0]?["counter"]?.string == "6")
        #expect(sent["login"]?["password"]?.string == "fixture-password" && sent["id"]?.string == "item-1")
    }

    @Test func noAssertionWhenTheCountCantBeSaved() async throws {
        let item = PasskeyFixture.item(counter: "5")
        let passkey = try #require(PasskeyFixture.passkey(item))
        for edit in [(stdout: "", status: Int32(1)), (stdout: PasskeyFixture.json(PasskeyFixture.item(counter: "5")), status: Int32(0)),
            (stdout: "not json", status: Int32(0))] {
            let runner = FakeRunner(installed: ["bw"])
            let provider = try PasskeyFixture.provider(runner)
            runner.reply(["sync"], stdout: "Syncing complete.")
            runner.reply(["get", "item", "item-1"], stdout: PasskeyFixture.json(item))
            runner.reply(["edit", "item", "item-1"], stdout: edit.stdout, stderr: "failed", status: edit.status)
            await #expect(throws: PasswordProviderError.self) {
                _ = try await provider.assertion(for: passkey, rpID: "github.com", clientDataJSON: Self.clientData, userVerified: true)
            }
        }
        // A failed sync stops it before anything is read.
        let runner = FakeRunner(installed: ["bw"])
        let provider = try PasskeyFixture.provider(runner)
        runner.reply(["sync"], stderr: "offline", status: 1)
        await #expect(throws: PasswordProviderError.self) {
            _ = try await provider.assertion(for: passkey, rpID: "github.com", clientDataJSON: Self.clientData, userVerified: true)
        }
        #expect(runner.calls.map { $0.arguments.first ?? "" } == ["sync"])
    }

    @Test func refusesWhenTheItemChangedOrNeedsVerification() async throws {
        let passkey = try #require(PasskeyFixture.passkey(PasskeyFixture.item()))
        let changed: [[String: Any]] = [
            PasskeyFixture.item(credentialID: "b64.CQkJ"), PasskeyFixture.item(rpID: "gitlab.com"), PasskeyFixture.item(curve: "P-384"),
            PasskeyFixture.item(deletedDate: "2026-02-01T00:00:00.000Z"),
        ]
        for item in changed {
            let runner = FakeRunner(installed: ["bw"])
            let provider = try PasskeyFixture.provider(runner)
            runner.reply(["get", "item", "item-1"], stdout: PasskeyFixture.json(item))
            await #expect(throws: PasswordProviderError.notFound) {
                _ = try await provider.assertion(for: passkey, rpID: "github.com", clientDataJSON: Self.clientData, userVerified: true)
            }
        }
        // Signing for another RP ID than the passkey's is refused too.
        let runner = FakeRunner(installed: ["bw"])
        let provider = try PasskeyFixture.provider(runner)
        runner.reply(["get", "item", "item-1"], stdout: PasskeyFixture.json(PasskeyFixture.item()))
        await #expect(throws: PasswordProviderError.notFound) {
            _ = try await provider.assertion(for: passkey, rpID: "evil.test", clientDataJSON: Self.clientData, userVerified: true)
        }
        // Bitwarden's master password re-prompt: only after Touch ID or the Mac's password.
        let guarded = PasskeyFixture.item(reprompt: 1)
        let guardedPasskey = try #require(PasskeyFixture.passkey(guarded))
        runner.reply(["get", "item", "item-1"], stdout: PasskeyFixture.json(guarded))
        await #expect(throws: PasswordProviderError.notFound) {
            _ = try await provider.assertion(for: guardedPasskey, rpID: "github.com", clientDataJSON: Self.clientData, userVerified: false)
        }
        _ = try await provider.assertion(for: guardedPasskey, rpID: "github.com", clientDataJSON: Self.clientData, userVerified: true)
        // Locked: no session, no bw.
        let locked = BitwardenProvider(runner: FakeRunner(installed: ["bw"]), sessions: MemorySecretStore())
        #expect(!locked.hasSession)
        await #expect(throws: PasswordProviderError.locked) { _ = try await locked.passkeys() }
    }
}

/// Answers prompts the way a test says, and records them.
@MainActor final class FakeSignInUI: PasskeySignInUI {
    var prompts: [PasskeySignInPrompt] = []
    var reasons: [String] = []
    var choose: (PasskeySignInPrompt) -> BitwardenPasskey? = { $0.choices.first }
    var verification = PasskeyUserVerification.verified
    var onConfirm: (() async -> Void)?
    var onVerify: (() async -> Void)?

    func confirm(_ prompt: PasskeySignInPrompt) async -> BitwardenPasskey? {
        prompts.append(prompt)
        await onConfirm?()
        return choose(prompt)
    }

    func verifyUser(reason: String) async -> PasskeyUserVerification {
        reasons.append(reason)
        await onVerify?()
        return verification
    }
}

/// Fixed passkeys; records each sign-in it is asked for.
final class FakePasskeyVault: PasskeyVault, @unchecked Sendable {
    struct Signing: Equatable { var itemID: String; var rpID: String; var clientDataJSON: Data; var userVerified: Bool }
    private let lock = NSLock()
    private let list: [BitwardenPasskey]?
    private var signings: [Signing] = []

    init(_ list: [BitwardenPasskey]?) { self.list = list }

    var signed: [Signing] { lock.withLock { signings } }

    func passkeys() async throws -> [BitwardenPasskey] {
        guard let list else { throw PasswordProviderError.locked }
        return list
    }

    func assertion(for passkey: BitwardenPasskey, rpID: String, clientDataJSON: Data, userVerified: Bool) async throws -> PasskeyAssertion {
        lock.withLock { signings.append(Signing(itemID: passkey.itemID, rpID: rpID, clientDataJSON: clientDataJSON, userVerified: userVerified)) }
        return PasskeyAssertion(credentialID: passkey.credentialID, authenticatorData: Data([1]), signature: Data([2]), userHandle: passkey.userHandle)
    }
}

@MainActor @Suite struct PasskeySignInTests {
    static let origin = WebAuthnOrigin(scheme: "https", host: "github.com", port: 0)!
    static let octocat = BitwardenPasskey(itemID: "a", itemName: "GitHub", userName: "octocat", rpID: "github.com",
        storedCredentialID: "b64.AQ", credentialID: Data([1]), userHandle: Data([7]), counter: 0, discoverable: true)
    static let hubot = BitwardenPasskey(itemID: "b", itemName: "GitHub (work)", userName: "hubot", rpID: "github.com",
        storedCredentialID: "b64.Ag", credentialID: Data([2]), userHandle: nil, counter: 0, discoverable: true)

    static func request(rpID: String? = nil, allow: [WebAuthnGetRequest.AllowedCredential] = [], verification: WebAuthnGetRequest.UserVerification = .preferred,
        mediation: WebAuthnGetRequest.Mediation = .optional) -> WebAuthnGetRequest {
        WebAuthnGetRequest(id: "r1", challenge: Data(repeating: 9, count: 32), rpID: rpID, allowCredentials: allow, userVerification: verification,
            mediation: mediation)
    }

    static let guarded = BitwardenPasskey(itemID: "r", itemName: "", userName: "r", rpID: "github.com", storedCredentialID: "b64.BQ",
        credentialID: Data([5]), userHandle: nil, counter: 0, discoverable: true, requiresReprompt: true)

    /// `PasskeySignIn.answer` for github.com, asking for Touch ID on every sign-in only when `touchID` is on.
    static func answer(_ request: WebAuthnGetRequest = PasskeySignInTests.request(), vault: PasskeyVault, ui: PasskeySignInUI,
        touchID: Bool = false, from origin: WebAuthnOrigin = PasskeySignInTests.origin) async -> WebAuthnReply {
        await PasskeySignIn.answer(request, from: origin, vault: vault, ui: ui, alwaysVerifiesUser: touchID)
    }

    /// Bitwarden's browser extension's way, and the setting's default: the click is the confirmation, and the assertion
    /// says the user was present but not verified.
    @Test func signsInAfterTheClickAloneByDefault() async throws {
        #expect(!BrowserSettings().confirmsPasskeysWithTouchID)
        for verification in [WebAuthnGetRequest.UserVerification.preferred, .discouraged] {
            let vault = FakePasskeyVault([Self.octocat])
            let ui = FakeSignInUI()
            let reply = await Self.answer(Self.request(rpID: "github.com", verification: verification), vault: vault, ui: ui)
            #expect(ui.prompts.map(\.title) == ["Sign in to github.com as octocat with your Bitwarden passkey?"])
            #expect(ui.prompts.first?.verifiesUser == false && ui.prompts.first?.detail == "")
            #expect(ui.reasons.isEmpty, "no Touch ID for \(verification)")
            let clientData = WebAuthnAssertion.clientDataJSON(challenge: Data(repeating: 9, count: 32), origin: "https://github.com")
            #expect(vault.signed == [.init(itemID: "a", rpID: "github.com", clientDataJSON: clientData, userVerified: false)])
            guard case .credential(let credential) = reply else { Issue.record("\(reply)"); return }
            #expect(credential.message == [
                "id": "AQ", "clientDataJSON": Base64URL.encode(clientData), "authenticatorData": "AQ", "signature": "Ag", "userHandle": "Bw",
            ])
            #expect(reply.message["status"] == "ok")
        }
    }

    @Test func theTouchIDSettingVerifiesEverySignIn() async throws {
        for verification in [WebAuthnGetRequest.UserVerification.preferred, .discouraged, .required] {
            let vault = FakePasskeyVault([Self.octocat])
            let ui = FakeSignInUI()
            let reply = await Self.answer(Self.request(verification: verification), vault: vault, ui: ui, touchID: true)
            #expect(reply.message["status"] == "ok")
            #expect(ui.prompts.first?.verifiesUser == true)
            #expect(ui.prompts.first?.detail == "You’ll confirm with Touch ID or your Mac password next.")
            #expect(ui.reasons == ["sign in to github.com with your Bitwarden passkey"])
            #expect(vault.signed.map(\.userVerified) == [true], "\(verification)")
        }
        // Failing or cancelling Touch ID signs nothing.
        let vault = FakePasskeyVault([Self.octocat])
        let ui = FakeSignInUI()
        ui.verification = .failed
        #expect(await Self.answer(vault: vault, ui: ui, touchID: true) == .notAllowed)
        #expect(ui.reasons.count == 1 && vault.signed.isEmpty)
        // A Mac that can't verify (no Touch ID, no password): the click alone counts, without the UV flag.
        ui.verification = .unavailable
        #expect(await Self.answer(vault: vault, ui: ui, touchID: true).message["status"] == "ok")
        #expect(vault.signed.map(\.userVerified) == [false])
    }

    /// With the setting off, a site that requires user verification still gets Touch ID or the password, and the UV
    /// flag only when that succeeded.
    @Test func aSiteThatRequiresVerificationStillGetsTouchID() async throws {
        let vault = FakePasskeyVault([Self.octocat])
        let ui = FakeSignInUI()
        #expect(await Self.answer(Self.request(verification: .required), vault: vault, ui: ui).message["status"] == "ok")
        #expect(ui.prompts.first?.verifiesUser == true)
        #expect(ui.prompts.first?.detail == "You’ll confirm with Touch ID or your Mac password next.")
        #expect(ui.reasons == ["sign in to github.com with your Bitwarden passkey"])
        #expect(vault.signed.map(\.userVerified) == [true])
        for verification in [PasskeyUserVerification.failed, .unavailable] {
            ui.verification = verification
            #expect(await Self.answer(Self.request(verification: .required), vault: vault, ui: ui) == .notAllowed, "\(verification)")
        }
        #expect(vault.signed.count == 1 && ui.reasons.count == 3)
    }

    /// Bitwarden's master password re-prompt always needs Touch ID or the password; when a re-prompt item is among
    /// several choices, the sheet says so and every choice verifies.
    @Test func aRepromptItemNeedsTouchID() async throws {
        let vault = FakePasskeyVault([Self.guarded])
        let ui = FakeSignInUI()
        #expect(await Self.answer(vault: vault, ui: ui).message["status"] == "ok")
        #expect(ui.prompts.first?.detail == "You’ll confirm with Touch ID or your Mac password next.")
        #expect(ui.reasons.count == 1 && vault.signed.map(\.userVerified) == [true])
        for verification in [PasskeyUserVerification.failed, .unavailable] {
            ui.verification = verification
            #expect(await Self.answer(vault: vault, ui: ui) == .notAllowed, "\(verification)")
        }
        #expect(vault.signed.count == 1)

        let mixed = FakePasskeyVault([Self.octocat, Self.guarded])
        let picker = FakeSignInUI()
        picker.choose = { $0.choices.first { $0.itemID == "a" } }
        #expect(await Self.answer(vault: mixed, ui: picker).message["status"] == "ok")
        #expect(picker.prompts.first?.detail == "Choose an account. You’ll confirm with Touch ID or your Mac password next.")
        #expect(picker.reasons.count == 1 && mixed.signed.map(\.itemID) == ["a"] && mixed.signed.map(\.userVerified) == [true])
    }

    /// The sheet's second line says who asked, whether to pick an account, and whether Touch ID comes next.
    @Test func theSheetSaysWhatComesNext() {
        let touchID = " You’ll confirm with Touch ID or your Mac password next."
        for verifies in [false, true] {
            let tail = verifies ? touchID : ""
            func detail(_ requester: String, _ choices: [BitwardenPasskey]) -> String {
                PasskeySignInPrompt(site: "github.com", requester: requester, choices: choices, verifiesUser: verifies).detail
            }
            #expect(detail("github.com", [Self.octocat]) == String(tail.dropFirst()))
            #expect(detail("github.com", [Self.octocat, Self.hubot]) == "Choose an account." + tail)
            #expect(detail("gist.github.com", [Self.octocat]) == "The request comes from gist.github.com." + tail)
            #expect(detail("gist.github.com", [Self.octocat, Self.hubot]) == "The request comes from gist.github.com. Choose an account." + tail)
        }
    }

    @Test func aSubdomainSignsInToItsParentAndSaysWhoAsked() async throws {
        let google = BitwardenPasskey(itemID: "g", itemName: "Google", userName: "me@example.test", rpID: "google.com", storedCredentialID: "b64.Aw",
            credentialID: Data([3]), userHandle: nil, counter: 0, discoverable: true)
        let ui = FakeSignInUI()
        let origin = try #require(WebAuthnOrigin(scheme: "https", host: "accounts.google.com", port: 0))
        let vault = FakePasskeyVault([google])
        let reply = await Self.answer(Self.request(rpID: "google.com"), vault: vault, ui: ui, from: origin)
        #expect(reply.message["status"] == "ok")
        #expect(ui.prompts.first?.detail == "The request comes from accounts.google.com.")
        #expect(vault.signed.first?.clientDataJSON == WebAuthnAssertion.clientDataJSON(challenge: Data(repeating: 9, count: 32),
            origin: "https://accounts.google.com"))
        _ = await Self.answer(Self.request(rpID: "google.com"), vault: vault, ui: ui, touchID: true, from: origin)
        #expect(ui.prompts.last?.detail == "The request comes from accounts.google.com. You’ll confirm with Touch ID or your Mac password next.")
    }

    @Test func severalMatchesLetTheUserPick() async throws {
        let vault = FakePasskeyVault([Self.octocat, Self.hubot])
        let ui = FakeSignInUI()
        ui.choose = { $0.choices.last }
        let reply = await Self.answer(vault: vault, ui: ui)
        let prompt = try #require(ui.prompts.first)
        #expect(prompt.title == "Sign in to github.com with your Bitwarden passkey?")
        #expect(prompt.detail == "Choose an account.")
        #expect(prompt.choices.map(\.itemID) == ["b", "a"] && prompt.choices.map(prompt.label(for:)) == ["hubot · GitHub (work)", "octocat · GitHub"])
        #expect(vault.signed.map(\.itemID) == ["a"])
        guard case .credential(let credential) = reply else { Issue.record("\(reply)"); return }
        #expect(credential.message["id"] == "AQ" && credential.message["userHandle"] == "Bw")
        // A choice that wasn't offered is refused.
        let stranger = BitwardenPasskey(itemID: "z", itemName: "", userName: "z", rpID: "github.com", storedCredentialID: "b64.CQ",
            credentialID: Data([9]), userHandle: nil, counter: 0, discoverable: true)
        ui.choose = { _ in stranger }
        #expect(await Self.answer(vault: vault, ui: ui) == .notAllowed)
        #expect(await Self.answer(vault: vault, ui: ui, touchID: true) == .notAllowed)
        #expect(vault.signed.count == 1 && ui.reasons.isEmpty)
    }

    @Test func cancellingTheSheetSignsNothing() async throws {
        for touchID in [false, true] {
            for verification in [WebAuthnGetRequest.UserVerification.preferred, .required] {
                let vault = FakePasskeyVault([Self.octocat])
                let ui = FakeSignInUI()
                ui.choose = { _ in nil }
                #expect(await Self.answer(Self.request(verification: verification), vault: vault, ui: ui, touchID: touchID) == .notAllowed)
                #expect(ui.prompts.count == 1 && ui.reasons.isEmpty && vault.signed.isEmpty)
            }
        }
    }

    @Test func aCancelledRequestSignsNothing() async throws {
        // While the sheet is up, with or without Touch ID to follow.
        for touchID in [false, true] {
            let vault = FakePasskeyVault([Self.octocat])
            let ui = FakeSignInUI()
            var task: Task<WebAuthnReply, Never>?
            ui.onConfirm = { task?.cancel() }
            task = Task { await Self.answer(vault: vault, ui: ui, touchID: touchID) }
            #expect(await task?.value == .notAllowed)
            #expect(ui.reasons.isEmpty && vault.signed.isEmpty)
        }
        // During Touch ID, even when it then reports success.
        let vault = FakePasskeyVault([Self.octocat])
        let ui = FakeSignInUI()
        var task: Task<WebAuthnReply, Never>?
        ui.onVerify = { task?.cancel() }
        task = Task { await Self.answer(Self.request(verification: .required), vault: vault, ui: ui) }
        #expect(await task?.value == .notAllowed)
        #expect(ui.reasons.count == 1 && vault.signed.isEmpty)
    }

    @Test func refusesRPIDsTheOriginCantClaim() async throws {
        for (host, rpID) in [("evil.com", "github.com"), ("github.com.evil.com", "github.com"), ("alice.github.io", "github.io"), ("github.com", "com")] {
            let vault = FakePasskeyVault([Self.octocat])
            let ui = FakeSignInUI()
            let origin = try #require(WebAuthnOrigin(scheme: "https", host: host, port: 0))
            let reply = await PasskeySignIn.answer(Self.request(rpID: rpID), from: origin, vault: vault, ui: ui,
                alwaysVerifiesUser: false)
            #expect(reply == .invalidRPID, "\(host) claiming \(rpID)")
            #expect(reply.message["name"] == "SecurityError")
            #expect(ui.prompts.isEmpty && vault.signed.isEmpty)
        }
        // A page on evil.com asking for its own RP ID finds none of github.com's passkeys.
        let ui = FakeSignInUI()
        let evil = try #require(WebAuthnOrigin(scheme: "https", host: "evil.com", port: 0))
        #expect(await Self.answer(vault: FakePasskeyVault([Self.octocat]), ui: ui, from: evil) == .fallback)
        #expect(ui.prompts.isEmpty)
    }

    @Test func whatCoincideCantAnswerGoesToTheBrowser() async throws {
        let ui = FakeSignInUI()
        let vault = FakePasskeyVault([Self.octocat])
        // Autofill-style and silent requests never prompt or sign.
        for mediation in [WebAuthnGetRequest.Mediation.conditional, .silent] {
            for touchID in [false, true] {
                #expect(await Self.answer(Self.request(mediation: mediation), vault: vault, ui: ui, touchID: touchID) == .fallback)
            }
        }
        // No matching passkey; Bitwarden locked or failing; only security keys allowed.
        #expect(await Self.answer(Self.request(allow: [.init(id: Data([8]))]), vault: vault, ui: ui) == .fallback)
        #expect(await Self.answer(vault: FakePasskeyVault(nil), ui: ui) == .fallback)
        #expect(await Self.answer(Self.request(allow: [.init(id: Data([1]), transports: ["usb", "nfc"])]), vault: vault, ui: ui) == .fallback)
        #expect(await PasskeySignIn.answer(Self.request(), from: Self.origin, vault: vault, ui: ui, alwaysVerifiesUser: false, suffixes: nil)
            == .fallback)
        #expect(ui.prompts.isEmpty && ui.reasons.isEmpty && vault.signed.isEmpty)
        // A credential the site lists with "internal" among its transports is still offered.
        let reply = await Self.answer(Self.request(allow: [.init(id: Data([1]), transports: ["internal", "hybrid"])]), vault: vault, ui: ui)
        #expect(reply.message["status"] == "ok")
        #expect(WebAuthnReply.fallback.message == ["status": "fallback"])
        #expect(WebAuthnReply.notAllowed.message["name"] == "NotAllowedError")
    }

    @Test func bitwardenPasskeysNeedTheSettingBitwardenAndASession() throws {
        let folder = try FixtureFolder()
        let settings = BrowserSettingsStore(directory: folder.url)
        let sessions = MemorySecretStore()
        let vault = PasswordVault(settings: settings, providers: [BitwardenProvider(runner: FakeRunner(installed: ["bw"]), sessions: sessions)])
        #expect(BrowserSettings().usesBitwardenPasskeys)
        #expect(!BrowserSettings().confirmsPasskeysWithTouchID && !settings.settings.confirmsPasskeysWithTouchID)
        #expect(vault.bitwardenPasskeys == nil)
        settings.update { $0.passwordManagers = [.bitwarden] }
        #expect(vault.bitwardenPasskeys == nil)
        try sessions.write("fixture-session", for: BitwardenProvider.sessionAccount)
        #expect(vault.bitwardenPasskeys != nil)
        settings.update { $0.usesBitwardenPasskeys = false }
        #expect(vault.bitwardenPasskeys == nil)
        // Settings saved before the switches existed have passkeys on and Touch ID for every sign-in off.
        let old = try JSONDecoder().decode(BrowserSettings.self, from: Data(#"{"passwordManagers": ["bitwarden"]}"#.utf8))
        #expect(old.usesBitwardenPasskeys && !old.confirmsPasskeysWithTouchID)
        // The Touch ID switch is saved in browser.json like the others, and doesn't turn passkeys on or off.
        settings.update { $0.confirmsPasskeysWithTouchID = true }
        let reloaded = BrowserSettingsStore(directory: folder.url).settings
        #expect(reloaded.confirmsPasskeysWithTouchID && !reloaded.usesBitwardenPasskeys)
        let encoded = try JSONEncoder().encode(reloaded)
        #expect(try JSONDecoder().decode(BrowserSettings.self, from: encoded).confirmsPasskeysWithTouchID)
    }
}
