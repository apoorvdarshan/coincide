import AppKit
import CoincideKit
import Testing

@testable import Coincide

/// Where clicked links open: web links in the browser preview or the default browser, by the click and the setting;
/// everything else as before.
struct LinkRoutingTests {
    @Test(arguments: [
        // (⌘ held, setting on, where it opens)
        (false, false, LinkDestination.coincideBrowser),
        (true, false, LinkDestination.defaultBrowser),
        (false, true, LinkDestination.defaultBrowser),
        (true, true, LinkDestination.coincideBrowser),
    ])
    func theSettingSwapsWhatAClickAndACommandClickDo(commandKey: Bool, opensInDefaultBrowser: Bool, expected: LinkDestination) {
        #expect(LinkRouting.destination(commandKey: commandKey, opensInDefaultBrowser: opensInDefaultBrowser) == expected)
        let url = URL(string: "https://example.com/docs")!
        #expect(
            LinkRouting.request(for: url, commandKey: commandKey, opensInDefaultBrowser: opensInDefaultBrowser)
                == WebLinkRequest(url: url, destination: expected))
    }

    @Test(arguments: [
        "https://example.com/a?b=c#d", "http://localhost:3000", "HTTPS://Example.com", "http://127.0.0.1:8080/x",
    ])
    func webLinksAreRouted(address: String) throws {
        let url = try #require(URL(string: address))
        #expect(LinkRouting.webURL(url) == url)
        #expect(LinkRouting.webURL(address) == url)
        for commandKey in [false, true] {
            for setting in [false, true] {
                #expect(LinkRouting.request(for: url, commandKey: commandKey, opensInDefaultBrowser: setting)?.url == url)
            }
        }
    }

    @Test func bareWWWAddressesAreWebLinks() {
        #expect(LinkRouting.webURL("www.example.com/page")?.absoluteString == "https://www.example.com/page")
    }

    /// Files, mail and other schemes keep going where they went before, whatever the click or the setting.
    @Test(arguments: [
        "mailto:me@example.com", "file:///etc/hosts", "src/App.swift:12", "/Users/me/notes.md", "ssh://host",
        "javascript:alert(1)", "vscode://file/a.swift", "#section", "http://", "https:///path", "",
    ])
    func otherLinksAreLeftAlone(link: String) {
        #expect(LinkRouting.webURL(link) == nil)
        if let url = URL(string: link) { #expect(LinkRouting.webURL(url) == nil) }
        for commandKey in [false, true] {
            for setting in [false, true] {
                #expect(LinkRouting.request(for: link, commandKey: commandKey, opensInDefaultBrowser: setting) == nil)
            }
        }
        #expect(LinkRouting.webURL(URL(fileURLWithPath: "/tmp/page.html")) == nil)
    }

    @Test func theHintSaysWhatAClickAndACommandClickDo() {
        #expect(LinkRouting.hint(opensInDefaultBrowser: false) == "Click to open in Coincide · ⌘-click to open in your browser")
        #expect(LinkRouting.hint(opensInDefaultBrowser: true) == "Click to open in your browser · ⌘-click to open in Coincide")
    }

    @Test func webLinkTooltipsAddTheHintUnderTheAddress() throws {
        var style = ChatMarkdownStyle(fontSize: 13)
        style.webLinkHint = "HINT"
        let rendered = ChatMarkdownRenderer.render("[site](https://example.com/a) [file](src/App.swift) <mailto:a@b.co>", style: style)
        let string = rendered.string.string as NSString
        func tip(_ text: String) -> String? {
            rendered.string.attribute(.toolTip, at: string.range(of: text).location, effectiveRange: nil) as? String
        }
        #expect(tip("site") == "https://example.com/a\nHINT")
        #expect(tip("file") == "src/App.swift")
        #expect(tip("mailto") == "mailto:a@b.co")
    }
}

/// How the transcript's text view hands clicked links on, and its menu for web links.
@MainActor struct ChatTextViewLinkTests {
    private func textView(setting: Bool = false) -> (ChatTextView, () -> [Any]) {
        let view = ChatTextView()
        view.opensLinksInDefaultBrowser = { setting }
        var opened: [Any] = []
        view.onOpenLink = { link in
            opened.append(link)
            return true
        }
        return (view, { opened })
    }

    @Test(arguments: [(false, false), (true, false), (false, true), (true, true)])
    func clicksOnWebLinksArriveWithWhereToOpenThem(commandKey: Bool, setting: Bool) throws {
        let (view, opened) = textView(setting: setting)
        let url = try #require(URL(string: "https://example.com"))
        view.openLink(url, commandKey: commandKey)
        let request = try #require(opened().first as? WebLinkRequest)
        #expect(request.url == url)
        #expect(request.destination == LinkRouting.destination(commandKey: commandKey, opensInDefaultBrowser: setting))
    }

    @Test(arguments: [false, true])
    func otherLinksArriveAsTheyAre(commandKey: Bool) throws {
        let (view, opened) = textView()
        let mail = try #require(URL(string: "mailto:me@example.com"))
        view.openLink(mail, commandKey: commandKey)
        view.openLink("src/App.swift:12", commandKey: commandKey)
        #expect(opened().count == 2)
        #expect(opened().first as? URL == mail)
        #expect(opened().last as? String == "src/App.swift:12")
    }

    @Test func aWebLinksMenuOpensItEitherWayOrCopiesIt() throws {
        let (view, opened) = textView()
        let pasteboard = NSPasteboard(name: NSPasteboard.Name("coincide-link-test-\(UUID().uuidString)"))
        defer { pasteboard.releaseGlobally() }
        view.linkPasteboard = pasteboard
        let url = try #require(URL(string: "https://example.com/docs"))
        let menu = view.linkMenu(for: url)
        let items = menu.items.filter { !$0.isSeparatorItem }
        #expect(items.map(\.title) == ["Open in Coincide Browser", "Open in New Tab", "Open in Default Browser", "Copy Link"])
        #expect(items.allSatisfy { $0.isEnabled && $0.target === view })

        for item in items {
            let action = try #require(item.action)
            #expect(NSApp.sendAction(action, to: item.target, from: item))
        }
        #expect(opened().compactMap { $0 as? WebLinkRequest } == [
            WebLinkRequest(url: url, destination: .coincideBrowser), WebLinkRequest(url: url, destination: .coincideBrowserNewTab),
            WebLinkRequest(url: url, destination: .defaultBrowser),
        ])
        #expect(pasteboard.string(forType: .string) == "https://example.com/docs")
    }

    @Test func theLinkUnderAPointIsFound() throws {
        let (view, _) = textView()
        view.frame = NSRect(x: 0, y: 0, width: 400, height: 40)
        let url = try #require(URL(string: "https://example.com"))
        let text = NSMutableAttributedString(string: "See the site here.", attributes: [.font: NSFont.systemFont(ofSize: 13)])
        let linkRange = (text.string as NSString).range(of: "site")
        text.addAttribute(.link, value: url, range: linkRange)
        view.setText(text)
        let linkRect = try #require(view.rect(for: linkRange))
        #expect(view.link(at: NSPoint(x: linkRect.midX, y: linkRect.midY)) as? URL == url)
        let plainRect = try #require(view.rect(for: (text.string as NSString).range(of: "See")))
        #expect(view.link(at: NSPoint(x: plainRect.midX, y: plainRect.midY)) == nil)
        // Past the end of the text is not over the last link.
        #expect(view.link(at: NSPoint(x: 395, y: linkRect.midY)) == nil)
    }
}

/// Opening a link in Coincide loads it in the selected thread's preview and shows the panel, as the user's own
/// navigation: agent control stays as it was.
@MainActor @Suite(.serialized) struct BrowserPreviewLinkTests {
    @Test func aLinkOpensInTheThreadsPreviewWithoutGivingTheAgentControl() throws {
        let saved = UIState.shared.values
        let folder = TemporaryDirectory("preview-links")
        let store = AppStore.shared
        let project = store.addProject(at: folder.url)
        let id = store.createThread(in: project.id).id
        UIState.shared.update {
            $0.isInspectorOpen = false
            $0.inspectorPanel = .diff
        }
        let controller = MainWindowController()
        defer {
            PreviewSessions.shared.session(for: id).webView.stopLoading()
            controller.window?.close()
            store.removeProject(project.id)
            UIState.shared.update { $0 = saved }
        }
        controller.splitController.view.frame = NSRect(x: 0, y: 0, width: 1400, height: 800)

        // Nothing opens without a thread; the caller then uses the default browser.
        controller.open(nil)
        let url = try #require(URL(string: "http://127.0.0.1:9/docs"))
        #expect(!controller.openInBrowserPreview(url))
        #expect(!controller.splitController.isPreviewOpen)

        controller.open(id)
        #expect(controller.openInBrowserPreview(url))
        #expect(controller.splitController.isPreviewOpen)
        #expect(controller.splitController.preview.threadID == id)
        #expect(PreviewSessions.shared.bridge.access(for: id) == nil)
        // Addresses the preview never loads are refused, so they open elsewhere.
        #expect(!controller.openInBrowserPreview(try #require(URL(string: "http://user:secret@example.com"))))
    }
}
