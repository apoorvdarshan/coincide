import AppKit
import CoincideKit
import Testing
import WebKit
@testable import Coincide

/// Real WebKit pages in transparent offscreen windows; no live profile, site, user zoom or app window is touched.
@MainActor @Suite(.serialized)
struct BrowserViewportTests {
    private static let html = """
        <!doctype html><meta charset=utf-8><meta name=viewport content="width=device-width,initial-scale=1">
        <title>Responsive fixture</title><style>
        body { margin:0; background:#123; color:white; font:16px system-ui }
        main { display:grid; grid-template-columns:1fr 1fr; gap:10px; padding:12px }
        article { min-width:0; padding:12px; background:#358 }
        #narrow { display:none } @media(max-width:500px) { main { grid-template-columns:1fr } #narrow { display:block } }
        </style><main><article><h1>Fixture</h1><input id=name><button id=apply>Apply</button></article>
        <article id=answer>Ready</article></main><p id=narrow>Narrow layout</p>
        <script>document.getElementById('apply').onclick = () => document.getElementById('answer').textContent = document.getElementById('name').value;</script>
        """

    @Test func panelWidthsReachCSSAndResetImmediatelyRestoresResponsiveSizing() async throws {
        let page = try await LoopbackPage.start(title: "Responsive fixture", html: Self.html)
        defer { page.stop() }
        let harness = Harness(width: 980)
        defer { harness.stop() }
        try harness.session.navigate(page.url.absoluteString)
        try await harness.waitForPage()
        try await harness.expectWidth(980)
        let zoom = harness.session.webView.pageZoom
        harness.resize(420)
        try await harness.expectWidth(420)
        let narrow = try await harness.read()
        #expect(narrow["viewport"]?["mode"]?.string == "panel")
        #expect(narrow["panelVisible"]?.bool == true)
        #expect(narrow["text"]?.string?.contains("Narrow layout") == true)
        let fits = try await harness.session.webView.callAsyncJavaScript(
            "return document.documentElement.scrollWidth <= innerWidth", arguments: [:], in: nil, contentWorld: .page)
        #expect(fits as? Bool == true)

        _ = try await harness.perform(.viewport(width: 1280, height: 860))
        try await harness.expectWidth(1280)
        #expect(try await harness.read()["viewport"]?["mode"]?.string == "fixed")
        let canvas = try #require(harness.session.webView.enclosingScrollView)
        #expect(canvas.hasHorizontalScroller && canvas.hasVerticalScroller)
        #expect(canvas.documentVisibleRect.width < harness.session.webView.bounds.width)
        canvas.contentView.scroll(to: NSPoint(x: 200, y: 0))
        canvas.reflectScrolledClipView(canvas.contentView)
        #expect(canvas.contentView.bounds.minX > 0)
        harness.resize(700)
        try await harness.expectWidth(1280)
        // Native geometry changes synchronously, before the next read or panel layout.
        let reset = try await harness.perform(.viewport(width: nil, height: nil))
        #expect(reset["width"]?.number == 700)
        #expect(harness.session.webView.bounds.width == 700)
        try await harness.expectWidth(700)
        #expect(harness.session.webView.pageZoom == zoom)
    }

    @Test func hideKeepsWorkingPageAndScreenshotGeometryAndAskUserCanShowItAgain() async throws {
        let page = try await LoopbackPage.start(title: "Responsive fixture", html: Self.html)
        defer { page.stop() }
        let harness = Harness(width: 620)
        defer { harness.stop() }
        let access = try await harness.sessions.enableAccess(for: harness.id)
        let client = BridgeClient(access)
        _ = try await client.send(["action": "navigate", "url": .string(page.url.absoluteString)])
        try await harness.waitForPage()
        try await harness.expectWidth(620)
        let size = harness.session.webView.bounds.size
        _ = try await client.send(["action": "hide"])
        #expect(PreviewParking.shared.isParked(harness.session.webView))
        #expect(harness.session.webView.bounds.size == size)
        _ = try await client.send(["action": "input", "selector": "#name", "text": "Still working in the background"])
        _ = try await client.send(["action": "click", "selector": "#apply"])
        let hidden = try await client.send(["action": "read"])
        #expect(hidden["text"]?.string?.contains("Still working in the background") == true)
        #expect(hidden["panelVisible"]?.bool == false)
        #expect(hidden["viewport"]?["width"]?.number == Double(size.width))
        let screenshot = try await client.send(["action": "screenshot"])
        let path = try #require(screenshot["path"]?.string)
        let bitmap = try #require(NSBitmapImageRep(data: Data(contentsOf: URL(fileURLWithPath: path))))
        #expect(abs(Double(bitmap.pixelsWide) / Double(bitmap.pixelsHigh) - size.width / size.height) < 0.02)
        #expect(harness.session.webView.window?.isVisible == false)
        #expect(harness.sessions.bridge.access(for: harness.id) != nil)
        #expect(PreviewParking.shared.isParked(harness.session.webView))

        // Explicit viewports must also survive parking, background reset and tab unloading/reloading.
        _ = try await client.send(["action": "viewport", "width": 320, "height": 300])
        #expect(harness.session.webView.bounds.size == NSSize(width: 320, height: 300))
        harness.session.activeTab.unload()
        #expect(harness.session.webView.bounds.size == NSSize(width: 320, height: 300))
        try await harness.waitForPage()
        _ = try await client.send(["action": "viewport", "reset": true])
        #expect(harness.session.webView.bounds.size == size)

        let answer = Task { try await client.send(["action": "ask-user", "message": "Inspect the local fixture, then click Done.", "timeout": 10]) }
        for _ in 0..<300 where harness.session.userTurn.request == nil || !harness.panel.isPresented {
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(harness.panel.isPresented && !harness.panel.userTurnBanner.isHidden)
        #expect(!PreviewParking.shared.isParked(harness.session.webView))
        harness.session.userTurn.finish(.done)
        #expect(try await answer.value["result"]?.string == "done")
        // Finishing a handoff leaves visibility to the agent/user; hiding is explicit.
        #expect(harness.panel.isPresented)
        harness.panel.view.layoutSubtreeIfNeeded()
        #expect(harness.session.webView.bounds.size == size)
        _ = try await client.send(["action": "hide"])
        #expect(try await client.send(["action": "read"])["panelVisible"]?.bool == false)
        _ = try await client.send(["action": "show"])
        #expect(harness.panel.isPresented)
        #expect(try await client.send(["action": "read"])["panelVisible"]?.bool == true)
        #expect(harness.session.webView.bounds.size == size)
    }

    @Test func sitesWithAMinimumWidthRemainHorizontallyScrollableAtTheActualPanelWidth() async throws {
        let html = """
            <!doctype html><title>Responsive fixture</title><style>body{margin:0;min-width:960px;background:#124;color:white}
            #last{position:absolute;left:900px;width:60px;top:20px}</style><h1>Wide document</h1><button id=last>Right edge</button>
            """
        let page = try await LoopbackPage.start(title: "Responsive fixture", html: html)
        defer { page.stop() }
        let harness = Harness(width: 420)
        defer { harness.stop() }
        try harness.session.navigate(page.url.absoluteString)
        try await harness.waitForPage()
        try await harness.expectWidth(420)
        let dimensions = try await harness.session.webView.callAsyncJavaScript(
            "scrollTo(960,0); return {viewport:innerWidth, document:document.documentElement.scrollWidth, x:scrollX, edge:document.getElementById('last').getBoundingClientRect().right}",
            arguments: [:], in: nil, contentWorld: .page) as? [String: Double]
        #expect(dimensions?["viewport"] == 420)
        #expect((dimensions?["document"] ?? 0) >= 960)
        #expect((dimensions?["x"] ?? 0) > 0)
        #expect((dimensions?["edge"] ?? 1000) <= 420)
    }

    private final class Harness {
        let folder = TemporaryDirectory("browser-viewport")
        let id = UUID()
        let sessions: PreviewSessions
        let panel = PreviewViewController()
        let window: NSWindow
        var session: PreviewSession { sessions.session(for: id) }

        init(width: CGFloat) {
            let profile = BrowserProfile(directory: folder.url, isPersistent: false)
            sessions = PreviewSessions(
                profile: profile, bridge: PreviewBridge(directory: folder.url.appendingPathComponent("bridge")),
                warningStore: AppStore(directory: folder.url.appendingPathComponent("store")))
            window = NSWindow(
                contentRect: NSRect(x: -20_000, y: -20_000, width: width, height: 640), styleMask: [.borderless], backing: .buffered,
                defer: false)
            window.alphaValue = 0
            panel.sessions = sessions
            panel.threadID = id
            // Match the inspector: a controller embedded in an already sized host. Making the panel the window's
            // content controller instead lets its chrome-only fitting size resize this artificial window.
            let host = NSView(frame: NSRect(origin: .zero, size: NSSize(width: width, height: 640)))
            window.contentView = host
            panel.view.frame = host.bounds
            panel.view.autoresizingMask = [.width, .height]
            host.addSubview(panel.view)
            window.setContentSize(NSSize(width: width, height: 640))
            window.orderBack(nil)
            panel.view.layoutSubtreeIfNeeded()
            #expect(panel.view.bounds.size == NSSize(width: width, height: 640))
            sessions.reveal = { [weak self] target in
                guard let self, target == self.id, let host = self.window.contentView else { return false }
                self.panel.view.frame = host.bounds
                if self.panel.view.superview !== host { host.addSubview(self.panel.view) }
                self.panel.view.isHidden = false
                self.panel.isPresented = true
                self.panel.view.layoutSubtreeIfNeeded()
                return true
            }
            sessions.conceal = { [weak self] target in
                guard let self, target == self.id else { return true }
                self.panel.isPresented = false
                self.panel.view.isHidden = true
                // A collapsed inspector leaves the window. Even a zero-size detached host must not shrink its page.
                self.panel.view.removeFromSuperview()
                self.panel.view.setFrameSize(.zero)
                return true
            }
        }

        func resize(_ width: CGFloat) {
            window.setContentSize(NSSize(width: width, height: 640))
            panel.view.layoutSubtreeIfNeeded()
        }

        func perform(_ command: PreviewCommand) async throws -> JSONValue {
            try await sessions.perform(command, threadID: id, directory: folder.url)
        }

        func read() async throws -> JSONValue { try await perform(.read()) }

        func waitForPage() async throws {
            for _ in 0..<500 {
                if session.webView.title == "Responsive fixture", !session.webView.isLoading { return }
                try await Task.sleep(for: .milliseconds(10))
            }
            Issue.record("Local fixture did not finish loading")
        }

        func expectWidth(_ width: Double) async throws {
            for _ in 0..<300 {
                let result = try await read()
                if result["viewport"]?["width"]?.number == width {
                    #expect(Double(session.webView.bounds.width) == width)
                    return
                }
                try await Task.sleep(for: .milliseconds(10))
            }
            let actual = try await read()
            #expect(actual["viewport"]?["width"]?.number == width)
        }

        func stop() {
            panel.isPresented = false
            panel.view.removeFromSuperview()
            window.contentView = nil
            window.orderOut(nil)
            sessions.stop()
            UIState.shared.update {
                $0.previewAddresses.removeValue(forKey: id.uuidString)
                $0.previewTabs.removeValue(forKey: id.uuidString)
            }
        }
    }
}
