import CoincideRemoteKit
import Foundation
import Testing

@testable import Coincide
@testable import CoincideKit

private final class RemoteModelsProvider: AgentProvider {
    let kind = ProviderKind.codex
    let executableNames = ["sh"]
    let setupHint = ""
    func detect(executable: URL?, environment: [String: String]) async -> ProviderStatus { ProviderStatus(state: .ready) }
    func models(status: ProviderStatus, environment: [String: String]) async -> [ModelOption] {
        [ModelOption(provider: .codex, modelID: "a", displayName: "Model A"), ModelOption(provider: .codex, modelID: "b", displayName: "Model B")]
    }
    func makeSession(_ launch: AgentLaunch) -> AgentSession { fatalError("Settings tests never start a session") }
}

/// Coincide Remote's Models, Browser and Instructions panes: what the Mac describes, and the changes the phone may make.
@MainActor
struct RemoteSettingsPanesTests {
    private func adapter(_ name: String) async -> (RemoteStoreAdapter, AppStore, TemporaryDirectory, BrowserProfile) {
        let folder = TemporaryDirectory(name)
        let store = AppStore(directory: folder.url)
        let registry = ProviderRegistry(store: store, providers: [RemoteModelsProvider()])
        await registry.refresh()
        let runner = ThreadRunner(store: store, registry: registry)
        let adapter = RemoteStoreAdapter(store: store, runner: runner, registry: registry, services: RemoteSessionTests.services(store: store))
        let browser = BrowserProfile(directory: folder.url.appending(path: "browser"), isPersistent: false)
        adapter.settingsServices = .init(computerUsePermissions: { (true, true) }, showOnMac: { _ in }, browser: { browser })
        adapter.instructions = RemoteInstructions(discover: { [] })
        return (adapter, store, folder, browser)
    }

    @Test func thePhoneStarsAndHidesEachAgentsModels() async throws {
        let (adapter, store, folder, _) = await adapter("remote-settings-models")
        defer { _ = folder }
        let snapshot = adapter.settingsSnapshot()
        let rows = RemoteSettingsRow.index(snapshot)
        // Models lists each agent's models on a page of its own, which no sidebar lists.
        #expect(rows["models.list.codex"]?.kind == .page)
        #expect(rows["models.list.codex"]?.target == "models.codex")
        #expect(snapshot.page("models.codex")?.group == .detail)
        #expect(rows["models.favorite.codex/b"]?.value == .bool(false))
        #expect(rows["models.shown.codex/b"]?.value == .bool(true))

        try adapter.changeSetting("models.favorite.codex/b", to: .bool(true))
        #expect(store.settings.favoriteModels == [ModelReference(provider: .codex, modelID: "b")])
        try adapter.changeSetting("models.shown.codex/a", to: .bool(false))
        #expect(store.settings.hiddenModels == [ModelReference(provider: .codex, modelID: "a")])
        let updated = RemoteSettingsRow.index(adapter.settingsSnapshot())
        #expect(updated["models.favorite.codex/b"]?.value == .bool(true))
        #expect(updated["models.shown.codex/a"]?.value == .bool(false))
        #expect(updated["models.list.codex"]?.detail?.contains("1 starred") == true)
        // A model the Mac doesn't list can't be starred.
        #expect(throws: RemoteError.self) { try adapter.changeSetting("models.favorite.codex/zzz", to: .bool(true)) }
    }

    @Test func thePhoneChangesTheBrowserButNotItsPasswords() async throws {
        let (adapter, _, folder, browser) = await adapter("remote-settings-browser")
        defer { _ = folder }
        #expect(browser.library.addBookmark(url: URL(string: "https://example.com/account?session=abc123")!, title: "Example"))
        let rows = RemoteSettingsRow.index(adapter.settingsSnapshot())
        #expect(rows["browser.privateSessions"]?.value == .bool(false))
        #expect(rows["browser.searchEngine"]?.options?.isEmpty == false)
        #expect(rows["browser.clearHistory"]?.isDestructive == true)

        try adapter.changeSetting("browser.privateSessions", to: .bool(true))
        #expect(browser.settings.settings.usesPrivateSessions)
        try adapter.changeSetting("browser.agentControl", to: .bool(false))
        #expect(browser.settings.settings.agentControlByDefault == false)
        let engine = try #require(SearchEngine.allCases.last)
        try adapter.changeSetting("browser.searchEngine", to: .string(engine.rawValue))
        #expect(browser.settings.settings.searchEngine == engine)
        #expect(throws: RemoteError.self) { try adapter.changeSetting("browser.searchEngine", to: .string("altavista")) }

        // A bookmark shows its title and host, never its path or query, and can be removed.
        let bookmark = try #require(rows.values.first { $0.id.hasPrefix("browser.bookmark.remove.") })
        #expect(bookmark.title == "Example")
        #expect(bookmark.detail == "example.com")
        let json = String(decoding: try RemoteProtocol.makeEncoder().encode(adapter.settingsSnapshot()), as: UTF8.self)
        #expect(!json.contains("abc123"))
        try adapter.performSettingsAction(bookmark.id)
        #expect(browser.library.bookmarks.isEmpty)

        // Password managers and saved logins are never described or changed from the phone.
        #expect(!json.localizedCaseInsensitiveContains("bitwarden"))
        #expect(throws: RemoteError.self) { try adapter.changeSetting("browser.agentsUsePasswordManagers", to: .bool(true)) }
    }

    @Test func instructionFilesAreReadAndSavedWholeWithoutOverwritingTheMacs() async throws {
        let (adapter, _, folder, _) = await adapter("remote-settings-instructions")
        defer { _ = folder }
        let file = folder.url.appending(path: "AGENTS.md")
        try "Be brief.\n".write(to: file, atomically: true, encoding: .utf8)
        let key = RemoteInstructions.keyPrefix + file.path
        adapter.instructions = RemoteInstructions(discover: {
            [RemoteInstructions.Listed(key: key, url: file, title: "~/AGENTS.md", detail: "Codex", isMaster: false)]
        })
        await adapter.instructions.refresh()
        let row = try #require(RemoteSettingsRow.index(adapter.settingsSnapshot())[key])
        #expect(row.kind == .document)
        #expect(row.detail == "Codex")

        var document = try adapter.instructions.document(key)
        #expect(document.text == "Be brief.\n")
        document.text = "Be brief. Use the tests.\n"
        let saved = try adapter.instructions.save(document)
        #expect(try String(contentsOf: file, encoding: .utf8) == "Be brief. Use the tests.\n")
        #expect(saved.version != document.version)

        // Saving from an old version after the file changed on the Mac is refused, and the Mac's text stays.
        try "Changed on the Mac.\n".write(to: file, atomically: true, encoding: .utf8)
        var stale = saved
        stale.text = "From the phone.\n"
        #expect(throws: RemoteError.self) { try adapter.instructions.save(stale) }
        #expect(try String(contentsOf: file, encoding: .utf8) == "Changed on the Mac.\n")
        do {
            _ = try adapter.instructions.save(stale)
        } catch let error as RemoteError {
            #expect(error.code == .conflict)
        }

        // Only files the Mac listed: never a path the phone makes up.
        #expect(throws: RemoteError.self) { try adapter.instructions.document(RemoteInstructions.keyPrefix + "/etc/hosts") }
        let forged = RemoteSettingsDocument(key: RemoteInstructions.keyPrefix + "/tmp/x", title: "x", text: "x", version: "")
        #expect(throws: RemoteError.self) { try adapter.instructions.save(forged) }
    }

    @Test func documentRequestsAndConflictsSurviveEncoding() throws {
        let document = RemoteSettingsDocument(key: "instructions.file./a", title: "~/a", text: "Hi", version: "v1")
        for request in [RemoteRequest.settingsDocument(key: document.key), .saveSettingsDocument(document)] {
            let data = try RemoteProtocol.makeEncoder().encode(RemoteClientMessage(id: "1", request: request))
            #expect(try RemoteProtocol.makeDecoder().decode(RemoteClientMessage.self, from: data).request == request)
        }
        let response = RemoteServerMessage.response(id: "1", result: .settingsDocument(document))
        let data = try RemoteProtocol.makeEncoder().encode(response)
        #expect(try RemoteProtocol.makeDecoder().decode(RemoteServerMessage.self, from: data) == response)
        let conflict = RemoteServerMessage.failure(id: "2", error: RemoteError(.conflict, "Changed"))
        #expect(
            try RemoteProtocol.makeDecoder().decode(RemoteServerMessage.self, from: try RemoteProtocol.makeEncoder().encode(conflict))
                == conflict)
        // A phone from before documents reads the new row kind and page group as unknown, and leaves them out.
        let row = #"{"id":"x","kind":"document","title":"t"}"#
        #expect(try JSONDecoder().decode(RemoteSettingsRow.self, from: Data(row.utf8)).kind == .document)
        let page = #"{"id":"p","title":"t","symbol":"s","color":"gray","group":"somethingNewer","sections":[]}"#
        #expect(try JSONDecoder().decode(RemoteSettingsPage.self, from: Data(page.utf8)).group == .unknown)
    }
}
