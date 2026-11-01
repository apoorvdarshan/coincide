import AppKit
import CoincideKit
import CoincideRemoteKit
import Testing

@testable import Coincide

/// Help & Community: Report an Issue and Request a Feature open the repository's GitHub issue forms, with only the
/// version fields of a bug report filled in, from Settings › About, the Help menu, the command palette and Coincide
/// Remote's Settings (whose links share `CommunityLink`). Nothing here opens a browser or shows a window.
@Suite(.serialized)
struct CommunityLinksTests {
    private static let repository = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()

    private func query(_ url: URL) -> [String: String] {
        let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        return Dictionary(items.map { ($0.name, $0.value ?? "") }) { first, _ in first }
    }

    // MARK: URLs

    @Test func eachLinkOpensItsIssueForm() {
        for link in CommunityLink.allCases {
            let url = link.url()
            #expect(url.scheme == "https")
            #expect(url.host == "github.com")
            #expect(url.path == "/apoorvdarshan/coincide/issues/new")
            #expect(query(url) == ["template": link.template])
        }
        #expect(CommunityLink.reportIssue.url().absoluteString
            == "https://github.com/apoorvdarshan/coincide/issues/new?template=bug_report.yml")
        #expect(CommunityLink.requestFeature.url().absoluteString
            == "https://github.com/apoorvdarshan/coincide/issues/new?template=feature_request.yml")
    }

    @Test func aBugReportFillsInOnlyTheVersions() {
        let url = CommunityLink.reportIssue.url(coincideVersion: "0.1.0 (12)", macOSVersion: "macOS 26.1 (25B78)")
        #expect(query(url) == [
            "template": "bug_report.yml", "coincide-version": "0.1.0 (12)", "macos-version": "macOS 26.1 (25B78)",
        ])
        // A plus sign stays one instead of turning into a space on GitHub.
        let plus = CommunityLink.reportIssue.url(coincideVersion: "1.0+beta")
        #expect(plus.absoluteString.contains("coincide-version=1.0%2Bbeta"))
        #expect(query(plus)["coincide-version"] == "1.0+beta")
    }

    @Test func aFeatureRequestTakesNoFields() {
        let url = CommunityLink.requestFeature.url(coincideVersion: "0.1.0 (12)", macOSVersion: "macOS 26.1")
        #expect(query(url) == ["template": "feature_request.yml"])
    }

    @Test func fieldsAreOneTrimmedLineOfLimitedLength() {
        let empty = CommunityLink.reportIssue.url(coincideVersion: "   ", macOSVersion: "")
        #expect(query(empty) == ["template": "bug_report.yml"])
        let lines = CommunityLink.reportIssue.url(coincideVersion: " 0.1.0\n(12) ")
        #expect(query(lines)["coincide-version"] == "0.1.0 (12)")
        let long = CommunityLink.reportIssue.url(coincideVersion: String(repeating: "9", count: 500))
        #expect(query(long)["coincide-version"]?.count == CommunityLink.maxFieldLength)
    }

    @Test func versionsAreWrittenAsTheFormsPlaceholdersDo() {
        #expect(CommunityLink.appVersion("0.1.0", build: "12") == "0.1.0 (12)")
        #expect(CommunityLink.appVersion("0.1.0", build: nil) == "0.1.0")
        #expect(CommunityLink.appVersion("0.1.0", build: " ") == "0.1.0")
        #expect(CommunityLink.appVersion(nil, build: "12") == nil)
        let system = OperatingSystemVersion(majorVersion: 26, minorVersion: 1, patchVersion: 0)
        #expect(CommunityLink.systemVersion(system) == "26.1")
        #expect(CommunityLink.systemVersion(system, build: "25B78") == "26.1 (25B78)")
        let patched = OperatingSystemVersion(majorVersion: 26, minorVersion: 1, patchVersion: 2)
        #expect(CommunityLink.systemVersion(patched) == "26.1.2")
        #expect(CommunityLink.remoteCoincideVersion(mac: nil, remote: "1.0 (3)", system: "26.1")
            == "Coincide Remote 1.0 (3) on iOS 26.1")
        #expect(CommunityLink.remoteCoincideVersion(mac: "0.1.0 (12)", remote: "1.0 (3)", system: "26.1", systemName: "iPadOS")
            == "0.1.0 (12) · Coincide Remote 1.0 (3) on iPadOS 26.1")
    }

    /// The Mac fills in this build of Coincide and the macOS running, and nothing else.
    @Test func theMacFillsInItsOwnVersions() throws {
        let fields = query(CommunityLink.reportIssue.macURL)
        #expect(Set(fields.keys) == ["template", "coincide-version", "macos-version"])
        let info = try #require(Bundle.main.infoDictionary)
        let version = try #require(info["CFBundleShortVersionString"] as? String)
        #expect(fields["coincide-version"]?.hasPrefix(version) == true)
        let os = ProcessInfo.processInfo.operatingSystemVersion
        #expect(fields["macos-version"]?.hasPrefix("macOS \(os.majorVersion).\(os.minorVersion)") == true)
        #expect(query(CommunityLink.requestFeature.macURL) == ["template": "feature_request.yml"])
    }

    /// The links name forms and fields the repository has, so renaming one in `.github/ISSUE_TEMPLATE` fails here.
    @Test func theFormsAndFieldsExistInTheRepository() throws {
        let folder = Self.repository.appendingPathComponent(".github/ISSUE_TEMPLATE")
        for link in CommunityLink.allCases {
            let form = try String(contentsOf: folder.appendingPathComponent(link.template), encoding: .utf8)
            #expect(form.contains("body:"), "\(link.template)")
        }
        let bug = try String(contentsOf: folder.appendingPathComponent(CommunityLink.reportIssue.template), encoding: .utf8)
        #expect(bug.contains("id: \(CommunityLink.Field.macOSVersion)\n"))
        #expect(bug.contains("id: \(CommunityLink.Field.coincideVersion)\n"))
    }

    // MARK: Entry points

    @Test func theCommandsAreInTheHelpGroupWithoutShortcuts() {
        #expect(KeyCommand.reportIssue.menu == .help)
        #expect(KeyCommand.requestFeature.menu == .help)
        #expect(KeyCommand.reportIssue.defaultShortcut == nil)
        #expect(KeyCommand.requestFeature.defaultShortcut == nil)
        #expect(KeyCommand.reportIssue.title == "Report an Issue…")
        #expect(KeyCommand.requestFeature.title == "Request a Feature…")
        #expect(CommunityLink.allCases.map(\.command) == [.reportIssue, .requestFeature])
        // Settings › Keyboard can give them one.
        let bindings = KeyBindings(overrides: ["help.reportIssue": "mod+alt+shift+i"])
        #expect(bindings.shortcut(for: .reportIssue) == KeyShortcut("mod+alt+shift+i"))
        #expect(bindings.customized == [.reportIssue])
    }

    @Test func theHelpMenuListsTheLinksForTheAppDelegate() throws {
        let windowController = MainWindowController(window: nil)
        let mainMenu = MainMenu(windowController: windowController)
        let appDelegate = AppDelegate()
        let menu = mainMenu.build(appDelegate: appDelegate)
        let help = try #require(menu.items.last?.submenu)
        #expect(help.title == "Help")
        #expect(help.items.map(\.title) == ["Report an Issue…", "Request a Feature…"])
        for (item, link) in zip(help.items, CommunityLink.allCases) {
            #expect(item.target === appDelegate)
            #expect(item.action == #selector(AppDelegate.openCommunityLink(_:)))
            #expect(item.representedObject as? String == link.rawValue)
            #expect(item.identifier == .keyCommand(link.command))
            #expect(item.keyEquivalent.isEmpty)
        }
        #expect(NSApp.windows.filter(\.isVisible).isEmpty)
    }

    @Test func thePaletteFindsTheLinks() throws {
        let (core, more) = PaletteCatalog(windowController: nil).actions()
        let items = core + more
        let report = try #require(items.first { $0.id == "help:reportIssue" })
        let feature = try #require(items.first { $0.id == "help:requestFeature" })
        #expect(report.title == "Report an Issue…")
        #expect(feature.title == "Request a Feature…")
        #expect(report.trailing == nil && feature.trailing == nil)
        for word in ["bug", "crash", "feedback", "github"] {
            #expect(report.keywords.contains(word), "\(word)")
        }
        for word in ["feature", "idea", "feedback"] {
            #expect(feature.keywords.contains(word), "\(word)")
        }
    }

    @Test func settingsSearchFindsTheLinksInAbout() {
        let entries = SettingsSearchResults.entries(kinds: [])
        for query in ["report", "bug", "feedback"] {
            #expect(entries.contains { $0.title == "Report an Issue" && $0.pane == .section(.about) && $0.matches(query) }, "\(query)")
        }
        for query in ["feature", "idea", "feedback"] {
            #expect(entries.contains { $0.title == "Request a Feature" && $0.pane == .section(.about) && $0.matches(query) }, "\(query)")
        }
    }
}
