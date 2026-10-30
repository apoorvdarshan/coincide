import Foundation
import Testing
@testable import CoincideKit

@MainActor @Suite struct BrowserLibraryTests {
    @Test func historyKeepsWebAddressesAndRanksSuggestions() throws {
        let folder = try FixtureFolder()
        let library = BrowserLibrary(directory: folder.url)
        library.recordVisit(url: try #require(URL(string: "https://user:pw@github.com/apple/swift#readme")), title: "Swift")
        library.recordVisit(url: try #require(URL(string: "https://github.com/apple/swift")), title: "Swift")
        library.recordVisit(url: try #require(URL(string: "https://gitlab.test/")), title: "GitLab", at: Date().addingTimeInterval(-90 * 86_400))
        library.recordVisit(url: try #require(URL(string: "file:///etc/passwd")), title: "nope")
        #expect(library.history.map(\.url) == ["https://github.com/apple/swift", "https://gitlab.test/"])
        #expect(library.history.first?.visitCount == 2)
        #expect(library.suggestions(for: "git").first?.url == "https://github.com/apple/swift")
        #expect(library.suggestions(for: "GitLab").map(\.url) == ["https://gitlab.test/"])
        #expect(library.inlineCompletion(for: "githu") == "github.com/apple/swift")
        #expect(library.inlineCompletion(for: "https://git")?.hasPrefix("https://git") == true)
        #expect(library.inlineCompletion(for: "x") == nil)

        library.flush()
        let path = folder.url.appendingPathComponent("browser-library.json").path
        let mode = try FileManager.default.attributesOfItem(atPath: path)[.posixPermissions] as? NSNumber
        #expect(mode?.intValue == 0o600)
        let reloaded = BrowserLibrary(directory: folder.url)
        #expect(reloaded.history.count == 2)
        reloaded.clearHistory()
        #expect(reloaded.history.isEmpty && reloaded.suggestions(for: "git").isEmpty)
    }

    @Test func importsMergeWithoutDuplicates() throws {
        let folder = try FixtureFolder()
        let library = BrowserLibrary(directory: folder.url)
        let page = try #require(URL(string: "https://docs.test/a"))
        library.recordVisit(url: page, title: "")
        let older = Date(timeIntervalSince1970: 1_000)
        #expect(library.mergeHistory([
            BrowserHistoryItem(url: "https://docs.test/a", title: "Docs", visitCount: 9, lastVisit: older),
            BrowserHistoryItem(url: "javascript:alert(1)", title: "x"),
        ]) == 1)
        #expect(library.history.count == 1)
        #expect(library.history.first?.visitCount == 9 && library.history.first?.title == "Docs")
        #expect(library.history.first.map { $0.lastVisit > older } == true)

        #expect(library.addBookmark(url: page, title: "Docs"))
        #expect(!library.addBookmark(url: page, title: "Again"))
        #expect(library.mergeBookmarks([
            BrowserBookmark(url: "https://docs.test/a", title: "Dup"),
            BrowserBookmark(url: "https://other.test/", title: "", folder: "Chrome"),
            BrowserBookmark(url: "data:text/html,x", title: "x"),
        ]) == 1)
        #expect(library.bookmarks.map(\.url) == ["https://docs.test/a", "https://other.test/"])
        #expect(library.bookmarks.last?.title == "https://other.test/")
        // Bookmarks come first in suggestions even when never visited.
        #expect(library.suggestions(for: "other").first?.url == "https://other.test/")
        library.removeBookmark(url: page)
        #expect(!library.isBookmarked(page))
    }
}

@MainActor @Suite struct BrowserSettingsTests {
    /// Coincide 0.1 kept no browser file: every thread had ephemeral storage. The first launch after this change
    /// starts from a new shared profile (nothing of the old storage to carry over), with private sessions off.
    @Test func missingFileMigratesToASharedProfile() throws {
        let folder = try FixtureFolder()
        let store = BrowserSettingsStore(directory: folder.url)
        #expect(store.isNew)
        #expect(!store.settings.usesPrivateSessions)
        #expect(store.settings.agentControlByDefault)
        #expect(FileManager.default.fileExists(atPath: folder.url.appendingPathComponent("browser.json").path))
        let reopened = BrowserSettingsStore(directory: folder.url)
        #expect(!reopened.isNew)
        #expect(reopened.settings.profileID == store.settings.profileID)

        // Unknown or missing keys fall back to defaults instead of resetting the profile.
        let id = UUID()
        try Data(#"{"profileID":"\#(id.uuidString)","future":true}"#.utf8).write(to: folder.url.appendingPathComponent("browser.json"))
        let partial = BrowserSettingsStore(directory: folder.url)
        #expect(partial.settings.profileID == id && partial.settings.agentControlByDefault)
    }

    @Test func perThreadAgentControlOverridesTheDefaultAndIsPruned() throws {
        let folder = try FixtureFolder()
        let store = BrowserSettingsStore(directory: folder.url)
        let on = UUID(), off = UUID()
        store.update { $0.agentControl[off.uuidString] = false }
        #expect(store.settings.isAgentControlEnabled(for: on))
        #expect(!store.settings.isAgentControlEnabled(for: off))
        store.update { $0.agentControlByDefault = false }
        #expect(!store.settings.isAgentControlEnabled(for: on))
        store.prune(keeping: [on])
        #expect(store.settings.agentControl.isEmpty)
    }
}

@MainActor @Suite struct UserTurnGateTests {
    @Test func doneTimeoutAndSupersededRequests() async {
        let gate = UserTurnGate()
        var changes = 0
        gate.onChange = { changes += 1 }
        let first = Task { await gate.ask("Sign in to example.test, then click Done.", timeout: 60) }
        await Task.yield()
        #expect(gate.request?.message == "Sign in to example.test, then click Done.")
        gate.finish(.done)
        #expect(await first.value == .done)
        #expect(gate.request == nil && changes >= 2)

        let replaced = Task { await gate.ask("one", timeout: 60) }
        await Task.yield()
        let second = Task { await gate.ask("two", timeout: 60) }
        #expect(await replaced.value == .superseded)
        await Task.yield()
        #expect(gate.request?.message == "two")
        gate.finish(.declined)
        #expect(await second.value == .declined)

        #expect(await gate.ask("short", timeout: 1) == .timeout)
    }

    @Test func messagesAreBoundedPlainText() {
        #expect(UserTurnGate.clean("  a\u{0}b\u{1B}[31m  ") == "a b [31m")
        #expect(UserTurnGate.clean(String(repeating: "x", count: 900)).count == UserTurnGate.maximumMessage)
        #expect(!UserTurnGate.clean(" \n ").isEmpty)
    }
}

@Suite struct PreviewCommandAdditionsTests {
    @Test func showAndAskUserAreBoundedAndStorageIsNotExposed() throws {
        #expect(try PreviewCommand(json: ["action": "show"]) == .show)
        #expect(try PreviewCommand(json: ["action": "ask-user", "message": "Solve the CAPTCHA"]) == .askUser(message: "Solve the CAPTCHA", timeout: 300))
        #expect(try PreviewCommand(json: ["action": "ask-user", "message": "x", "timeout": 30]).timeout == 35)
        for json: JSONValue in [
            ["action": "ask-user"], ["action": "ask-user", "message": "x", "timeout": 0], ["action": "ask-user", "message": "x", "timeout": 901],
            ["action": "ask-user", "message": .string(String(repeating: "x", count: 4097))],
            ["action": "cookies"], ["action": "storage"], ["action": "evaluate", "script": "document.cookie"],
        ] {
            #expect(throws: PreviewError.self) { try PreviewCommand(json: json) }
        }
        #expect(PreviewCommand.read().timeout == 30)
    }
}

@MainActor @Suite(.serialized) struct PreviewBridgeTimingTests {
    @Test func slowCommandsTimeOutAndLateResultsAreDropped() async throws {
        await #expect(throws: PreviewError.self) {
            _ = try await PreviewBridge.run(.read(), within: 0.1) {
                try await Task.sleep(for: .seconds(5))
                return ["late": true]
            }
        }
        let fast = try await PreviewBridge.run(.read(), within: 5) { ["ok": true] }
        #expect(fast["ok"]?.bool == true)
    }

    /// An ask-user call holds its connection open past the old 30-second receive deadline logic and returns the
    /// user's answer.
    @Test func askUserWaitsForTheUsersAnswerOverTheBridge() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("coincide-ask-" + UUID().uuidString)
        let bridge = PreviewBridge(directory: directory)
        defer { bridge.stop() }
        let id = UUID()
        #expect(bridge.enableNow(threadID: id) { _, _ in [:] } == nil)
        try await bridge.prepare()
        let gate = UserTurnGate()
        let access = try #require(bridge.enableNow(threadID: id) { command, _ in
            guard case .askUser(let message, let timeout) = command else { return ["unexpected": true] }
            return ["result": .string(await gate.ask(message, timeout: timeout).rawValue)]
        })
        let curl = Task.detached {
            await ProcessRunner.run(URL(fileURLWithPath: "/usr/bin/curl"),
                ["--config", access.configuration.path, "--data-binary", #"{"action":"ask-user","message":"Please sign in","timeout":20}"#],
                timeout: 30)
        }
        for _ in 0..<200 where gate.request == nil { try await Task.sleep(for: .milliseconds(10)) }
        #expect(gate.request?.message == "Please sign in")
        try await Task.sleep(for: .milliseconds(300))
        gate.finish(.done)
        let result = await curl.value
        #expect(result.succeeded)
        #expect(JSONValue.parse(Data(result.stdout.utf8))?["result"]?.string == "done")
        let config = try String(contentsOf: access.configuration, encoding: .utf8)
        #expect(config.contains("max-time = 930"))
        #expect(access.instructions.contains("ask-user") && access.instructions.contains("Never try to"))
    }
}
