import AppKit
import CoincideKit
import Foundation
import Testing

@testable import Coincide

/// The app the Open In button opens project folders in: the rail button's right-click menu, Settings › General's
/// picker and the choice they share. Every store here is a scratch one, the installed apps are fakes, and opening an
/// app is recorded rather than done, so no real app launches and no menu or window appears on screen.
@MainActor
struct OpenInTests {
    private let folder = TemporaryDirectory("open-in")
    private let store: AppStore

    private static let zed = OpenTarget(
        bundleID: "dev.zed.Zed", name: "Zed", kind: .editor, appURL: URL(fileURLWithPath: "/Applications/Zed.app"))
    private static let xcode = OpenTarget(
        bundleID: "com.apple.dt.Xcode", name: "Xcode", kind: .editor, appURL: URL(fileURLWithPath: "/Applications/Xcode.app"))
    private static let terminal = OpenTarget(
        bundleID: "com.apple.Terminal", name: "Terminal", kind: .terminal,
        appURL: URL(fileURLWithPath: "/System/Applications/Utilities/Terminal.app"))
    private static let finder = OpenTarget(
        bundleID: "com.apple.finder", name: "Finder", kind: .fileManager,
        appURL: URL(fileURLWithPath: "/System/Library/CoreServices/Finder.app"))
    private static let targets = [zed, xcode, terminal, finder]

    init() {
        store = AppStore(directory: folder.url)
    }

    /// Records what the chooser would have opened.
    private final class Launches {
        var opened: [(folder: URL, bundleID: String)] = []
    }

    private func chooser(folder: URL?, launches: Launches) -> OpenTargetChooser {
        let chooser = OpenTargetChooser(store: store, targets: { Self.targets }) { folder, target in
            launches.opened.append((folder, target.bundleID))
        }
        chooser.folder = { folder }
        return chooser
    }

    private func item(_ menu: NSMenu, _ title: String) throws -> NSMenuItem {
        try #require(menu.items.first { $0.title == title })
    }

    // MARK: Right-click menu

    @Test func theMenuListsTheAppsGroupedWithTheDefaultChecked() throws {
        let menu = chooser(folder: nil, launches: Launches()).makeMenu()
        #expect(menu.items.map { $0.isSeparatorItem ? "-" : $0.title } == ["Zed", "Xcode", "-", "Terminal", "-", "Finder"])
        // Automatic: the first installed editor.
        #expect(menu.items.filter { $0.state == .on }.map(\.title) == ["Zed"])
        #expect(try item(menu, "Xcode").image != nil)

        store.updateSettings { $0.preferredOpenTarget = Self.terminal.bundleID }
        let chosen = chooser(folder: nil, launches: Launches()).makeMenu()
        #expect(chosen.items.filter { $0.state == .on }.map(\.title) == ["Terminal"])
    }

    @Test func aChoiceThatIsNoLongerInstalledFallsBackToAutomatic() {
        store.updateSettings { $0.preferredOpenTarget = "com.example.gone" }
        let menu = chooser(folder: nil, launches: Launches()).makeMenu()
        #expect(menu.items.filter { $0.state == .on }.map(\.title) == ["Zed"])
        #expect(OpenTargets.preferred(in: store.settings, among: Self.targets) == Self.zed)
        #expect(OpenTargets.preferred(in: store.settings, among: [Self.terminal, Self.finder]) == Self.finder)
        #expect(OpenTargets.preferred(in: store.settings, among: []) == nil)
    }

    @Test func choosingAnAppMakesItTheDefaultAndOpensTheFolderInIt() throws {
        let launches = Launches()
        let project = folder.url.appendingPathComponent("project")
        let chooser = chooser(folder: project, launches: launches)
        let menu = chooser.makeMenu()
        let pick = try item(menu, "Terminal")
        #expect(pick.target === chooser)
        chooser.choose(pick)
        #expect(store.settings.preferredOpenTarget == Self.terminal.bundleID)
        #expect(launches.opened.map(\.folder) == [project])
        #expect(launches.opened.map(\.bundleID) == [Self.terminal.bundleID])
        // The menu checks it next time.
        #expect(chooser.makeMenu().items.filter { $0.state == .on }.map(\.title) == ["Terminal"])
    }

    @Test func withoutAFolderChoosingOnlyChangesTheDefault() throws {
        let launches = Launches()
        let chooser = chooser(folder: nil, launches: launches)
        chooser.choose(try item(chooser.makeMenu(), "Finder"))
        #expect(store.settings.preferredOpenTarget == Self.finder.bundleID)
        #expect(launches.opened.isEmpty)
    }

    @Test func changingTheDefaultIsAnnounced() {
        let announced = Launches()
        let observer = NotificationCenter.default.addObserver(
            forName: OpenTargets.preferredDidChange, object: store, queue: nil
        ) { _ in MainActor.assumeIsolated { announced.opened.append((URL(fileURLWithPath: "/"), "")) } }
        defer { NotificationCenter.default.removeObserver(observer) }
        OpenTargets.setPreferred(Self.xcode.bundleID, in: store)
        OpenTargets.setPreferred(Self.xcode.bundleID, in: store)
        #expect(announced.opened.count == 1)
        OpenTargets.setPreferred(nil, in: store)
        #expect(announced.opened.count == 2)
        #expect(store.settings.preferredOpenTarget == nil)
    }

    // MARK: Rail button

    @Test func theRailButtonNamesTheAppAndFollowsTheDefault() throws {
        let rail = NavigationRailViewController(store: store, openInChooser: chooser(folder: nil, launches: Launches()))
        rail.loadViewIfNeeded()
        let button = rail.openInButton
        let hint = "Right-click to choose another app"
        #expect(button.accessibilityLabel() == "Open in Zed")
        let tip = try #require(button.toolTip)
        #expect(tip.hasPrefix("Open in Zed"))
        #expect(tip.hasSuffix("\n" + hint))
        #expect(button.accessibilityHelp() == hint)

        OpenTargets.setPreferred(Self.xcode.bundleID, in: store)
        #expect(button.accessibilityLabel() == "Open in Xcode")
        #expect(button.toolTip?.hasPrefix("Open in Xcode") == true)
        #expect(button.toolTip?.hasSuffix("\n" + hint) == true)

        // Settings › General and Restore Defaults write the settings directly; the window then asks the rail.
        store.updateSettings { GeneralSettingsView.restoreDefaults(in: &$0) }
        rail.updateOpenInTarget()
        #expect(button.accessibilityLabel() == "Open in Zed")
    }

    @Test func withNoFolderTheButtonIsDisabledButItsMenuStillOpens() throws {
        let rail = NavigationRailViewController(store: store, openInChooser: chooser(folder: nil, launches: Launches()))
        rail.loadViewIfNeeded()
        rail.update(threadsOpen: false, terminalOpen: false, canOpenFolder: false)
        #expect(!rail.openInButton.isEnabled)
        let menu = try #require(rail.openInButton.contextMenu?())
        #expect(menu.items.contains { $0.title == "Terminal" })
    }

    // MARK: Settings › General

    @Test func thePickerOffersAutomaticThenTheAppsWithIcons() {
        let choices = OpenInSettingsRow.choices(targets: Self.targets, selection: nil)
        #expect(choices.map(\.value) == [nil, "dev.zed.Zed", "com.apple.dt.Xcode", "com.apple.Terminal", "com.apple.finder"])
        #expect(choices.first?.title == "Automatic (first installed editor)")
        #expect(choices.dropFirst().allSatisfy { $0.image != nil && $0.group != nil })
        #expect(choices.map(\.group) == [nil, "Editors", "Editors", "Terminals", "File Manager"])

        // A saved app that was uninstalled stays visible rather than leaving the picker blank.
        let gone = OpenInSettingsRow.choices(targets: Self.targets, selection: "com.microsoft.VSCode")
        #expect(gone.map(\.value).prefix(2) == [nil, "com.microsoft.VSCode"])
        #expect(gone[1].title == "VS Code (not installed)")
    }

    @Test func thePickerWritesTheSameChoiceTheButtonUses() {
        let registry = ProviderRegistry(store: store, providers: [ClaudeProvider()])
        let model = SettingsModel(store: store, registry: registry)
        let binding = model.binding(\.preferredOpenTarget)
        #expect(binding.wrappedValue == nil)
        binding.wrappedValue = Self.terminal.bundleID
        #expect(store.settings.preferredOpenTarget == Self.terminal.bundleID)
        #expect(OpenTargets.preferred(in: store.settings, among: Self.targets) == Self.terminal)
        // A choice made from a menu shows in the picker.
        OpenTargets.setPreferred(Self.finder.bundleID, in: store)
        #expect(binding.wrappedValue == Self.finder.bundleID)
        binding.wrappedValue = nil
        #expect(OpenTargets.preferred(in: store.settings, among: Self.targets) == Self.zed)
    }

    @Test func restoreDefaultsGoesBackToAutomatic() {
        var settings = AppSettings()
        settings.preferredOpenTarget = Self.terminal.bundleID
        GeneralSettingsView.restoreDefaults(in: &settings)
        #expect(settings.preferredOpenTarget == nil)
    }

    @Test func settingsSearchFindsThePicker() throws {
        let entries = SettingsSearchResults.entries(kinds: [])
        for query in ["open project", "Open In", "editor", "Xcode", "Finder"] {
            #expect(entries.contains { $0.setting == .openIn && $0.matches(query) }, "\(query) doesn't find it")
        }
        let entry = try #require(entries.first { $0.setting == .openIn })
        #expect(entry.pane == .section(.general))
    }

    @Test func theChoiceIsSavedWithTheSettings() throws {
        #expect(AppSettings().preferredOpenTarget == nil)
        store.updateSettings { $0.preferredOpenTarget = Self.zed.bundleID }
        store.flush()
        #expect(AppStore(directory: folder.url).settings.preferredOpenTarget == Self.zed.bundleID)
        let old = try JSONDecoder().decode(AppSettings.self, from: Data(#"{"fontSize": 15}"#.utf8))
        #expect(old.preferredOpenTarget == nil && old.fontSize == 15)
    }

    // MARK: Moving the choice out of UIState

    @Test func theChoiceEarlierVersionsKeptMovesIntoTheSettings() {
        let stateFolder = TemporaryDirectory("open-in-ui")
        let state = UIState(directory: stateFolder.url)
        state.update { $0.preferredOpenTarget = Self.zed.bundleID }
        OpenTargets.migrateLegacyChoice(from: state, to: store)
        #expect(store.settings.preferredOpenTarget == Self.zed.bundleID)
        #expect(state.values.preferredOpenTarget == nil)
        state.flush()
        #expect(UIState(directory: stateFolder.url).values.preferredOpenTarget == nil)

        // Running again changes nothing.
        OpenTargets.migrateLegacyChoice(from: state, to: store)
        #expect(store.settings.preferredOpenTarget == Self.zed.bundleID)
    }

    @Test func aChoiceAlreadyInTheSettingsWinsOverTheOldOne() {
        let stateFolder = TemporaryDirectory("open-in-ui")
        let state = UIState(directory: stateFolder.url)
        state.update { $0.preferredOpenTarget = Self.zed.bundleID }
        store.updateSettings { $0.preferredOpenTarget = Self.terminal.bundleID }
        OpenTargets.migrateLegacyChoice(from: state, to: store)
        #expect(store.settings.preferredOpenTarget == Self.terminal.bundleID)
        #expect(state.values.preferredOpenTarget == nil)
    }
}
