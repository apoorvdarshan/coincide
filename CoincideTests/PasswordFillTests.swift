import AppKit
import CoincideKit
import Testing
import WebKit
@testable import Coincide

/// A password manager with one synthetic login. Nothing here reaches 1Password, Bitwarden or the Keychain.
struct FixtureLoginProvider: PasswordProvider {
    static let password = "fixture-password-Zq7"
    static let code = "482916"
    let kind = PasswordManagerKind.onePassword
    let capabilities = PasswordCapabilities(lookupByDomain: false, totp: true)
    let host: String
    func status() async -> PasswordProviderStatus { .unlocksOnUse(account: nil) }
    func logins(for page: URL) async throws -> [LoginItem] {
        [LoginItem(source: kind, itemID: "fixture", title: "Fixture Login", username: "agent-user", urls: ["http://\(host)"], hasTOTP: true)]
    }
    func secret(for item: LoginItem) async throws -> LoginSecret {
        LoginSecret(username: "agent-user", password: Self.password, totp: Self.code)
    }
}

@MainActor @Suite(.serialized) struct PasswordFillTests {
    static let loginPage = """
        <!doctype html><meta charset=utf-8><title>Sign in</title>
        <form id=f onsubmit="event.preventDefault(); document.title = 'Submitted'">
        <input id=user name=username autocomplete=username><input id=pw type=password name=password>
        <input id=code name=otp autocomplete=one-time-code><button id=go type=submit>Sign in</button></form>
        """

    @Test func agentsSignInOnlyAfterApprovalAndNeverSeeTheSecret() async throws {
        let page = try await LoopbackPage.start(title: "Sign in", html: Self.loginPage)
        defer { page.stop() }
        let harness = BrowserProfileTests.Harness()
        do {
            let id = UUID()
            harness.sessions.vault = PasswordVault(settings: harness.profile.settings, providers: [FixtureLoginProvider(host: page.url.host! + ":\(page.url.port!)")])
            harness.profile.settings.update { $0.passwordManagers = [.onePassword] }
            try await harness.sessions.enableAccess(for: id)
            let client = BridgeClient(try #require(harness.sessions.bridge.access(for: id)))
            _ = try await client.send(["action": "navigate", "url": .string(page.url.absoluteString)])
            let session = try #require(harness.sessions.existingSession(for: id))
            try await waitFor { session.webView.title == "Sign in" && !session.webView.isLoading }

            // Denied: nothing is filled and the agent is told so.
            let denied = Task { try await client.send(["action": "fill-login"]) }
            try await waitFor { session.loginApproval.request != nil }
            #expect(session.loginApproval.request?.site == "127.0.0.1")
            #expect(harness.revealed.last == id)
            session.loginApproval.answer(.deny)
            let refusal = try await denied.value
            #expect(refusal["error"]?.string?.contains("didn't allow") == true)
            #expect(try await value("pw", in: session) == "")

            // Allowed once: filled, and the reply carries the username only.
            let allowed = Task { try await client.send(["action": "fill-login", "item": "Fixture"]) }
            try await waitFor { session.loginApproval.request != nil }
            session.loginApproval.answer(.allowOnce)
            let reply = try await allowed.value
            #expect(reply["filled"]?.bool == true && reply["username"]?.string == "agent-user")
            #expect(reply["fields"]?.array == ["username", "password"] && reply["oneTimeCode"]?.string == "filled")
            for text in [reply.compactJSON, try await client.send(["action": "read"]).compactJSON] {
                #expect(!text.contains(FixtureLoginProvider.password) && !text.contains(FixtureLoginProvider.code))
            }
            #expect(try await value("pw", in: session) == FixtureLoginProvider.password)
            #expect(try await value("code", in: session) == FixtureLoginProvider.code)
            let shot = try await client.send(["action": "screenshot"])
            #expect(shot["path"]?.string != nil && !shot.compactJSON.contains(FixtureLoginProvider.code))

            // "Allow once" covers the follow-up (a two-factor page) without asking again.
            let again = try await client.send(["action": "fill-login"])
            #expect(again["filled"]?.bool == true && session.loginApproval.request == nil)

            // Coincide's own fill is not offered for saving.
            harness.profile.settings.update { $0.passwordManagers = [.onePassword, .coincide] }
            _ = try await session.webView.callAsyncJavaScript("document.getElementById('go').click(); return true", arguments: [:], in: nil, contentWorld: .page)
            try await waitFor { session.webView.title == "Submitted" }
            try await Task.sleep(for: .milliseconds(200))
            #expect(session.savePrompt == nil)

            // Another thread asks again; Always for This Site is remembered and listed.
            let other = UUID()
            try await harness.sessions.enableAccess(for: other)
            let second = BridgeClient(try #require(harness.sessions.bridge.access(for: other)))
            _ = try await second.send(["action": "navigate", "url": .string(page.url.absoluteString)])
            let otherSession = try #require(harness.sessions.existingSession(for: other))
            try await waitFor { otherSession.webView.title == "Sign in" && !otherSession.webView.isLoading }
            let always = Task { try await second.send(["action": "fill-login"]) }
            try await waitFor { otherSession.loginApproval.request != nil }
            otherSession.loginApproval.answer(.always)
            #expect(try await always.value["filled"]?.bool == true)
            #expect(harness.profile.settings.settings.loginGrants.map(\.site) == ["127.0.0.1"])
        }
        await harness.tearDown()
    }

    @Test func aSubmittedSignInIsOfferedForSavingInMemoryOnly() async throws {
        let page = try await LoopbackPage.start(title: "Sign in", html: Self.loginPage)
        defer { page.stop() }
        let harness = BrowserProfileTests.Harness()
        do {
            harness.profile.settings.update { $0.passwordManagers = [.coincide] }
            let session = harness.sessions.session(for: UUID())
            try session.navigate(page.url.absoluteString)
            try await waitFor { session.webView.title == "Sign in" && !session.webView.isLoading }
            _ = try await session.webView.callAsyncJavaScript(
                "document.getElementById('user').value = 'typed-user'; document.getElementById('pw').value = 'typed-secret'; document.getElementById('go').click(); return true",
                arguments: [:], in: nil, contentWorld: .page)
            try await waitFor { session.savePrompt != nil }
            #expect(session.savePrompt?.username == "typed-user")
            session.answerSavePrompt(save: true, never: false, provider: harness.profile.logins, settings: harness.profile.settings)
            #expect(harness.profile.logins.saved.map(\.username) == ["typed-user"])
            #expect(harness.profile.logins.isSaved(url: page.url, username: "typed-user", password: "typed-secret"))
            let list = try String(contentsOf: harness.folder.appendingPathComponent("browser-logins.json"), encoding: .utf8)
            #expect(!list.contains("typed-secret"))
            // Saved now: the same sign-in isn't offered again.
            _ = try await session.webView.callAsyncJavaScript("document.getElementById('go').click(); return true", arguments: [:], in: nil, contentWorld: .page)
            try await Task.sleep(for: .milliseconds(300))
            #expect(session.savePrompt == nil)
        }
        await harness.tearDown()
    }

    private func value(_ id: String, in session: PreviewSession) async throws -> String {
        try await session.webView.callAsyncJavaScript("return document.getElementById(id).value", arguments: ["id": id], in: nil, contentWorld: .page) as? String ?? ""
    }

    private func waitFor(_ condition: () -> Bool) async throws {
        for _ in 0..<500 {
            if condition() { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        Issue.record("Timed out waiting")
    }
}
