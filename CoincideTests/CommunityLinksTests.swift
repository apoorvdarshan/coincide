import AppKit
import CoincideKit
import CoincideRemoteKit
import Testing

@testable import Coincide

/// Help & Community: help and reports, Discord and the source code, the developer's accounts, and contact and legal
/// pages, in Settings › About, the Help menu, the command palette and Coincide Remote's Settings (which share
/// `CommunityLink`). Report an Issue and Request a Feature open the GitHub issue forms, with only the version fields of
/// a bug report filled in, or the Discord channel. Nothing here opens a browser or shows a window.
@Suite(.serialized)
struct CommunityLinksTests {
    private static let repository = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()

    private func query(_ url: URL) -> [String: String] {
        let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        return Dictionary(items.map { ($0.name, $0.value ?? "") }) { first, _ in first }
    }

    // MARK: URLs

    @Test func reportsOpenTheirIssueForms() {
        #expect(CommunityLink.reportIssue.url().absoluteString
            == "https://github.com/apoorvdarshan/coincide/issues/new?template=bug_report.yml")
        #expect(CommunityLink.requestFeature.url().absoluteString
            == "https://github.com/apoorvdarshan/coincide/issues/new?template=feature_request.yml")
        #expect(CommunityLink.allCases.filter { $0.template != nil } == [.reportIssue, .requestFeature])
    }

    @Test func reportsOfferTheirDiscordChannelAndCommand() {
        #expect(CommunityLink.reportIssue.discordChannel == CoincideLinks.discordBugReports)
        #expect(CommunityLink.requestFeature.discordChannel == CoincideLinks.discordFeatureRequests)
        #expect(CommunityLink.reportIssue.slashCommand == "/bug")
        #expect(CommunityLink.requestFeature.slashCommand == "/feature")
        #expect(CommunityLink.allCases.filter { $0.discordChannel != nil } == [.reportIssue, .requestFeature])
        for channel in [CoincideLinks.discordHelp, CoincideLinks.discordBugReports, CoincideLinks.discordFeatureRequests] {
            #expect(channel.host == "discord.com")
            #expect(channel.path.hasPrefix("/channels/1566352780862427258/"))
        }
    }

    @Test func everyOtherLinkGoesToItsPage() {
        let expected: [CommunityLink: String] = [
            .getHelp: "https://discord.com/channels/1566352780862427258/1566353949336797275",
            .joinDiscord: "https://discord.gg/DETrbhDVqw",
            .starOnGitHub: "https://github.com/apoorvdarshan/coincide",
            .supportOnKoFi: "https://ko-fi.com/apoorvdarshan",
            .x: "https://x.com/apoorvdarshan",
            .instagram: "https://instagram.com/apoorvcodes",
            .linkedIn: "https://www.linkedin.com/showcase/coincide-dev",
            .contact: "mailto:apoorv@fud-ai.app",
            .privacyPolicy: "https://coincide.dev/privacy",
            .termsOfService: "https://coincide.dev/terms",
        ]
        for (link, address) in expected {
            #expect(link.url().absoluteString == address, "\(link)")
            // Versions go only into a bug report.
            #expect(link.url(coincideVersion: "0.1.0 (12)", macOSVersion: "macOS 26.1") == link.url(), "\(link)")
        }
        #expect(Set(expected.keys).union([.reportIssue, .requestFeature]) == Set(CommunityLink.allCases))
        // App Store review page: none until Coincide Remote is published.
        #expect(CoincideLinks.remoteAppStoreReview == nil)
    }

    @Test func linksAreGroupedInOrder() {
        #expect(CommunityLink.links(in: .community, on: .mac)
            == [.getHelp, .reportIssue, .requestFeature, .joinDiscord, .starOnGitHub, .supportOnKoFi])
        #expect(CommunityLink.links(in: .follow, on: .mac) == [.x, .instagram, .linkedIn])
        #expect(CommunityLink.links(in: .contact, on: .mac) == [.contact, .privacyPolicy, .termsOfService])
        #expect(CommunityLink.Group.allCases.flatMap { CommunityLink.links(in: $0, on: .mac) } == CommunityLink.allCases)
    }

    /// Ko-fi is the Mac's alone: Coincide Remote lists every other link, in the same groups and order.
    @Test func koFiIsOnlyOnTheMac() {
        #expect(CommunityLink.offered(on: .mac) == CommunityLink.allCases)
        #expect(CommunityLink.offered(on: .remote) == CommunityLink.allCases.filter { $0 != .supportOnKoFi })
        #expect(CommunityLink.links(in: .community, on: .remote)
            == [.getHelp, .reportIssue, .requestFeature, .joinDiscord, .starOnGitHub])
        #expect(CommunityLink.links(in: .follow, on: .remote) == CommunityLink.links(in: .follow, on: .mac))
        #expect(CommunityLink.links(in: .contact, on: .remote) == CommunityLink.links(in: .contact, on: .mac))
        #expect(!CommunityLink.supportOnKoFi.isOffered(on: .remote))
    }

    /// Coincide Remote builds only for iOS, so its views can't run here; its sources must list the links offered on
    /// the phone, never all of them or the Mac's.
    @Test func coincideRemoteListsOnlyThePhonesLinks() throws {
        let folder = Self.repository.appendingPathComponent("CoincideRemote")
        let files = try #require(FileManager.default.enumerator(at: folder, includingPropertiesForKeys: nil))
            .compactMap { $0 as? URL }.filter { $0.pathExtension == "swift" }
        var listings = 0
        for file in files {
            let source = try String(contentsOf: file, encoding: .utf8)
            #expect(!source.contains("CommunityLink.allCases"), "\(file.lastPathComponent)")
            #expect(!source.contains("on: .mac"), "\(file.lastPathComponent)")
            listings += source.components(separatedBy: "on: .remote)").count - 1
        }
        // The Settings rows and Settings search.
        #expect(listings >= 2)
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
        let feature = CommunityLink.requestFeature.url(coincideVersion: "0.1.0 (12)", macOSVersion: "macOS 26.1")
        #expect(query(feature) == ["template": "feature_request.yml"])
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

    /// Rate asks for iOS's prompt, and opens the App Store page instead only when the prompt was asked for recently
    /// and there is a page.
    @Test func rateOpensTheStorePageOnlyAfterARecentPrompt() throws {
        let page = try #require(URL(string: "https://apps.apple.com/app/id1?action=write-review"))
        let now = Date(timeIntervalSince1970: 2_000_000_000)
        #expect(RemoteReview.storePage(lastPrompt: nil, now: now, page: page) == nil)
        #expect(RemoteReview.storePage(lastPrompt: now.addingTimeInterval(-3600), now: now, page: page) == page)
        #expect(RemoteReview.storePage(lastPrompt: now.addingTimeInterval(-RemoteReview.promptInterval - 1), now: now, page: page) == nil)
        #expect(RemoteReview.storePage(lastPrompt: now.addingTimeInterval(-3600), now: now, page: nil) == nil)
        // Until Coincide Remote is on the App Store, it always asks for the prompt.
        #expect(RemoteReview.storePage(lastPrompt: now.addingTimeInterval(-3600), now: now) == nil)
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
        #expect(CommunityLink.contact.macURL == CoincideLinks.contact)
    }

    /// The links name forms and fields the repository has, so renaming one in `.github/ISSUE_TEMPLATE` fails here.
    @Test func theFormsAndFieldsExistInTheRepository() throws {
        let folder = Self.repository.appendingPathComponent(".github/ISSUE_TEMPLATE")
        for template in CommunityLink.allCases.compactMap(\.template) {
            let form = try String(contentsOf: folder.appendingPathComponent(template), encoding: .utf8)
            #expect(form.contains("body:"), "\(template)")
        }
        let bug = try String(contentsOf: folder.appendingPathComponent("bug_report.yml"), encoding: .utf8)
        #expect(bug.contains("id: \(CommunityLink.Field.macOSVersion)\n"))
        #expect(bug.contains("id: \(CommunityLink.Field.coincideVersion)\n"))
    }

    // MARK: Entry points

    @Test func theReportCommandsAreInTheHelpGroupWithoutShortcuts() {
        #expect(KeyCommand.reportIssue.menu == .help)
        #expect(KeyCommand.requestFeature.menu == .help)
        #expect(KeyCommand.reportIssue.defaultShortcut == nil)
        #expect(KeyCommand.requestFeature.defaultShortcut == nil)
        #expect(KeyCommand.reportIssue.title == "Report an Issue…")
        #expect(KeyCommand.requestFeature.title == "Request a Feature…")
        #expect(CommunityLink.allCases.compactMap(\.command) == [.reportIssue, .requestFeature])
        // Settings › Keyboard can give them one.
        let bindings = KeyBindings(overrides: ["help.reportIssue": "mod+alt+shift+i"])
        #expect(bindings.shortcut(for: .reportIssue) == KeyShortcut("mod+alt+shift+i"))
        #expect(bindings.customized == [.reportIssue])
    }

    @Test func theHelpMenuListsTheLinksByGroupForTheAppDelegate() throws {
        let windowController = MainWindowController(window: nil)
        let mainMenu = MainMenu(windowController: windowController)
        let appDelegate = AppDelegate()
        let menu = mainMenu.build(appDelegate: appDelegate)
        let help = try #require(menu.items.last?.submenu)
        #expect(help.title == "Help")
        #expect(help.items.map { $0.isSeparatorItem ? "-" : $0.title } == [
            "Get Help on Discord", "Report an Issue…", "Request a Feature…", "Join the Discord", "Star on GitHub",
            "Support Coincide on Ko-fi", "-",
            "X: @apoorvdarshan", "Instagram: @apoorvcodes", "LinkedIn", "-",
            "Contact: apoorv@fud-ai.app", "Privacy Policy", "Terms of Service",
        ])
        let entries = help.items.filter { !$0.isSeparatorItem }
        #expect(entries.count == CommunityLink.offered(on: .mac).count)
        for (item, link) in zip(entries, CommunityLink.offered(on: .mac)) {
            #expect(item.target === appDelegate)
            #expect(item.action == #selector(AppDelegate.openCommunityLink(_:)))
            #expect(item.representedObject as? String == link.rawValue)
            // Only the two reports are commands with a shortcut of their own (AppKit names the others after their action).
            #expect(item.identifier.flatMap(KeyCommand.init(menuItemIdentifier:)) == link.command)
            #expect(item.keyEquivalent.isEmpty)
        }
        #expect(NSApp.windows.filter(\.isVisible).isEmpty)
    }

    @Test func thePaletteFindsTheLinks() throws {
        let (core, more) = PaletteCatalog(windowController: nil).actions()
        let items = core + more
        for link in CommunityLink.offered(on: .mac) {
            let item = try #require(items.first { $0.id == "help:\(link.rawValue)" }, "\(link)")
            #expect(item.title == link.menuTitle)
            #expect(item.trailing == nil)
        }
        let report = try #require(items.first { $0.id == "help:reportIssue" })
        for word in ["bug", "crash", "feedback", "github", "discord"] {
            #expect(report.keywords.contains(word), "\(word)")
        }
        let feature = try #require(items.first { $0.id == "help:requestFeature" })
        for word in ["feature", "idea", "feedback"] {
            #expect(feature.keywords.contains(word), "\(word)")
        }
    }

    @Test func settingsSearchFindsTheLinksInAbout() {
        let entries = SettingsSearchResults.entries(kinds: [])
        let cases: [(String, [String])] = [
            ("Report an Issue", ["report", "bug", "feedback", "discord"]), ("Request a Feature", ["feature", "idea"]),
            ("Join the Discord", ["discord", "community"]), ("Star on GitHub", ["star", "open source"]),
            ("Privacy Policy", ["privacy"]), ("Terms of Service", ["terms"]), ("Contact", ["email"]),
            ("Support on Ko-fi", ["ko-fi", "donate", "coffee"]),
            ("X", ["twitter"]), ("LinkedIn", ["linkedin"]),
        ]
        for (title, queries) in cases {
            for query in queries {
                #expect(entries.contains { $0.title == title && $0.pane == .section(.about) && $0.matches(query) }, "\(title): \(query)")
            }
        }
    }
}
