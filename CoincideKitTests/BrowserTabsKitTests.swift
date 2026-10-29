import Foundation
import Testing
@testable import CoincideKit

@Suite struct BrowserTabsKitTests {
    @Test func tabCommandsParseAndStayBounded() throws {
        #expect(try PreviewCommand(json: ["action": "tabs"]) == .tabs)
        #expect(try PreviewCommand(json: ["action": "new-tab"]) == .newTab(nil))
        #expect(try PreviewCommand(json: ["action": "new-tab", "url": "example.test"]) == .newTab(URL(string: "https://example.test")))
        #expect(try PreviewCommand(json: ["action": "select-tab", "tab": "tab-2"]) == .selectTab("tab-2"))
        #expect(try PreviewCommand(json: ["action": "close-tab", "tab": "tab-2"]) == .closeTab("tab-2"))
        #expect(try PreviewCommand(json: ["action": "read", "tab": "tab-3"]) == .inTab("tab-3", .read))
        #expect(try PreviewCommand(json: ["action": "fill-login", "tab": "tab-3"]) == .inTab("tab-3", .fillLogin(item: nil)))
        for json: JSONValue in [
            ["action": "select-tab"], ["action": "close-tab", "tab": "../x"], ["action": "read", "tab": 3],
            ["action": "show", "tab": "tab-1"], ["action": "tabs", "tab": "tab-1"], ["action": "new-tab", "url": "file:///etc/hosts"],
            ["action": "read", "tab": .string(String(repeating: "a", count: 33))],
        ] {
            #expect(throws: PreviewError.self) { try PreviewCommand(json: json) }
        }
        #expect(PreviewCommand.inTab("tab-1", .read).timeout == PreviewCommand.read.timeout)
    }

    @Test func rememberedTabsAreCleanAndBounded() throws {
        let state = BrowserTabsState(urls: ["https://a.test/#frag", "javascript:alert(1)", "", "http://user:pw@b.test/"], selected: 9)
        #expect(state.urls == ["https://a.test/", "", "", "http://b.test/"])
        #expect(state.selected == 3)
        #expect(BrowserTabsState(urls: [], selected: -1).urls == [""])
        #expect(BrowserTabsState(urls: Array(repeating: "https://a.test/", count: 40), selected: 0).urls.count == PreviewCommand.tabLimit)
        let decoded = try JSONDecoder().decode(BrowserTabsState.self, from: Data(#"{"urls":["https://c.test/"],"selected":4}"#.utf8))
        #expect(decoded.selected == 0)
        #expect(try JSONDecoder().decode(BrowserTabsState.self, from: Data("{}".utf8)).urls == [""])
    }

    @Test func unloadingSparesActiveTabsAndRecentOnes() {
        let now = Date()
        let tabs = (0..<6).map { TabUnloading.Candidate(id: "t\($0)", isActive: $0 == 0 || $0 == 5, lastUsed: now.addingTimeInterval(Double($0))) }
        #expect(TabUnloading.tabsToUnload(tabs, budget: 3) == ["t1", "t2", "t3"])
        #expect(TabUnloading.tabsToUnload(tabs, budget: 10).isEmpty)
        #expect(TabUnloading.tabsToUnload(tabs, budget: 0) == ["t1", "t2", "t3", "t4"])
    }
}
