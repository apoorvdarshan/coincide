import AppKit
import CoincideKit
import Testing

@testable import Coincide

/// OSC 9;4 progress on the terminal's tab, and the translucent terminal background. No window is shown.
@MainActor
@Suite(.serialized)
struct TerminalProgressTests {
    @Test func progressReportsParse() {
        func parse(_ text: String) -> TerminalProgress?? { TerminalProgress.parse(Array(text.utf8)) }
        #expect(parse("4;1;45") == .some(TerminalProgress(state: .normal, percent: 45)))
        #expect(parse("4;1;250") == .some(TerminalProgress(state: .normal, percent: 100)))
        #expect(parse("4;2;30") == .some(TerminalProgress(state: .error, percent: 30)))
        #expect(parse("4;3") == .some(TerminalProgress(state: .indeterminate, percent: nil)))
        #expect(parse("4;4;80") == .some(TerminalProgress(state: .paused, percent: 80)))
        #expect(parse("4;0") == .some(nil))
        // Notifications and nonsense are not progress.
        #expect(parse("Build finished") == nil)
        #expect(parse("4;9;1") == nil)
        #expect(parse("4;x") == nil)
        #expect(TerminalProgress(state: .normal, percent: 45).description == String(localized: "45% done"))
    }

    @Test func aProgramsReportReachesTheTabAndItsRemovalClearsIt() async throws {
        let terminal = ShellTerminalView(font: Theme.monoFont)
        var changes = 0
        terminal.onProgressChange = { changes += 1 }
        terminal.feed(text: "\u{1b}]9;4;1;45\u{07}")
        for _ in 0..<100 where terminal.progress == nil {
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(terminal.progress == TerminalProgress(state: .normal, percent: 45))
        terminal.feed(text: "\u{1b}]9;4;0\u{07}")
        for _ in 0..<100 where terminal.progress != nil {
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(terminal.progress == nil)
        #expect(changes == 2)
    }

    @Test func theTabShowsARingOrASignInPlaceOfItsIcon() {
        let item = TerminalTabItemView()
        var tab = TerminalHeaderView.Tab(id: UUID(), title: "brew", symbolName: "terminal", toolTip: "", hasExited: false)
        item.configure(tab, isSelected: true)
        #expect(item.progressRing.isHidden)

        tab.progress = TerminalProgress(state: .normal, percent: 60)
        item.configure(tab, isSelected: true)
        #expect(!item.progressRing.isHidden && !item.progressRing.isIndeterminate)
        #expect(item.progressRing.doubleValue == 60)
        #expect(item.accessibilityLabel()?.contains(String(localized: "60% done")) == true)

        tab.progress = TerminalProgress(state: .error, percent: 60)
        item.configure(tab, isSelected: true)
        #expect(item.progressRing.isHidden)
    }

    @Test func translucencyIsOffByDefaultAndPutsTheDesktopBehindTheTerminal() throws {
        #expect(!AppSettings().terminalTranslucentBackground)
        let decoded = try JSONDecoder().decode(
            AppSettings.self, from: Data(#"{"terminalTranslucentBackground": "yes", "fontSize": 15}"#.utf8))
        #expect(!decoded.terminalTranslucentBackground && decoded.fontSize == 15)

        let saved = ShellTerminalView.prefersTranslucency
        defer { ShellTerminalView.prefersTranslucency = saved }
        var translucent = false
        ShellTerminalView.prefersTranslucency = { translucent }
        let pane = TerminalPaneView(terminalView: ShellTerminalView(font: Theme.monoFont))
        #expect(pane.material == nil)
        translucent = true
        pane.updateTranslucency()
        #expect(pane.material?.blendingMode == .behindWindow)
        translucent = false
        pane.updateTranslucency()
        #expect(pane.material == nil)
    }

    @Test func settingsSearchFindsTranslucency() throws {
        let entries = SettingsSearchResults.entries(kinds: [])
        for query in ["translucent", "transparency", "blur"] {
            #expect(entries.contains { $0.setting == .terminalTranslucency && $0.matches(query) }, "\(query) doesn't find it")
        }
    }
}
