import AppKit
import CoincideKit
import Testing

@testable import Coincide

/// Appshots from the trigger to the composer, with the screen, the windows and the HUD replaced: nothing is captured
/// from the real screen, no window shows and no sound plays.
@MainActor
struct AppshotControllerTests {
    private final class RecordingHUD: AppshotHUDPresenting {
        var messages: [String] = []
        var alerts: [Bool] = []
        func show(_ message: String, symbol: String, alert: Bool, around frame: CGRect?) {
            messages.append(message)
            alerts.append(alert)
        }
    }

    @MainActor
    final class Box<Value> {
        var values: [Value] = []
    }

    private struct Fixture {
        let folder = TemporaryDirectory("appshots")
        let store: AppStore
        let thread: UUID
        let chat: UUID
        let composer: ComposerViewController
        let controller: AppshotController
        let hud = RecordingHUD()
        /// Where the fake screen saved its captures.
        let captured = Box<String>()
        let openedBox = Box<UUID>()
        let newChatsBox = Box<UUID>()
        let activations = Box<Bool>()
        var opened: [UUID] { openedBox.values }
        var newChats: Int { newChatsBox.values.count }

        init() {
            store = AppStore(directory: folder.url)
            let project = store.addProject(at: folder.url)
            thread = store.createThread(in: project.id).id
            chat = store.createThread(in: project.id).id
            let registry = ProviderRegistry(store: store, providers: [])
            composer = ComposerViewController(store: store, registry: registry, runner: ThreadRunner(store: store, registry: registry))
            _ = composer.view
            composer.threadID = thread
            controller = AppshotController(store: store)
            controller.hud = hud
            controller.screen = AppshotControllerTests.screen(capturedInto: captured)
            controller.accessibilityCheck = { true }
            controller.screenRecordingCheck = { true }
            controller.visibleThread = { nil }
            let (openedSink, chatsSink, activationSink, chatID) = (openedBox, newChatsBox, activations, chat)
            controller.openThread = { openedSink.values.append($0) }
            controller.newChat = {
                chatsSink.values.append(chatID)
                return chatID
            }
            controller.activate = { activationSink.values.append(true) }
            controller.openSettings = {}
        }

        /// The composer's thumbnails and cards.
        func strip() -> (images: [ComposerAttachment], context: [MessageContext]) {
            guard let strip = Self.findView(ComposerAttachmentStrip.self, in: composer.view),
                let row = (strip.arrangedSubviews.first as? NSScrollView)?.documentView?.subviews.first as? NSStackView
            else { return ([], []) }
            return (
                row.arrangedSubviews.compactMap { ($0 as? ComposerAttachmentChip)?.attachment },
                row.arrangedSubviews.compactMap { ($0 as? ComposerContextCard)?.context }
            )
        }

        private static func findView<View: NSView>(_ type: View.Type, in root: NSView) -> View? {
            if let match = root as? View { return match }
            return root.subviews.lazy.compactMap { findView(type, in: $0) }.first
        }
    }

    private static let safari: Int32 = 4242
    private static let coincideWindow = AppshotWindow(
        id: 1, ownerPID: 1, ownerName: "Coincide", bounds: CGRect(x: 0, y: 0, width: 800, height: 600))

    /// A screen with Coincide's window in front of Safari's, and Safari the frontmost app.
    private static func screen(capturedInto paths: Box<String>, text: String? = "Example Domain\nMore information") -> AppshotScreen {
        var screen = AppshotScreen()
        screen.ownPID = 1
        screen.windows = {
            [
                coincideWindow,
                AppshotWindow(
                    id: 2, ownerPID: safari, ownerName: "Safari", title: "Example", bounds: CGRect(x: 40, y: 40, width: 900, height: 700)),
            ]
        }
        screen.frontmostPID = { safari }
        screen.appName = { $0.ownerName }
        screen.isTakingPassword = { _, _ in false }
        screen.capture = { window, directory in
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let url = directory.appendingPathComponent("appshot-\(window.id).png")
            try Data([0x89, 0x50, 0x4E, 0x47]).write(to: url)
            await MainActor.run { paths.values.append(url.path) }
            return url.path
        }
        screen.readText = { _ in text }
        return screen
    }

    private func waitForCapture(_ controller: AppshotController) async {
        for _ in 0..<500 where controller.isCapturing { try? await Task.sleep(for: .milliseconds(10)) }
    }

    @Test func offWatchesNothing() {
        let fixture = Fixture()
        let controller = fixture.controller
        controller.start()
        defer { controller.shutdown() }
        #expect(!controller.isWatching)
        controller.enabled = true
        #expect(controller.isWatching)
        controller.trigger = .shortcut
        #expect(controller.isWatching)
        controller.enabled = false
        #expect(!controller.isWatching)
        // Off, a trigger does nothing at all.
        controller.takeAppshot()
        #expect(fixture.hud.messages.isEmpty && fixture.newChats == 0 && fixture.captured.values.isEmpty)
    }

    @Test func anAppshotOfTheFrontWindowWaitsUnsentInTheThreadUsedLastMinute() async throws {
        let fixture = Fixture()
        let controller = fixture.controller
        controller.enabled = true
        defer { controller.shutdown() }
        controller.recordInteraction(with: fixture.thread)
        controller.takeAppshot()
        await waitForCapture(controller)

        // Safari's window, not Coincide's in front of it, saved with the other attachments.
        let paths = fixture.captured.values
        #expect(paths.count == 1 && paths.first?.hasSuffix("appshot-2.png") == true)
        #expect(paths.first?.hasPrefix(fixture.store.directory.appendingPathComponent("attachments").path) == true)
        #expect(fixture.opened == [fixture.thread] && fixture.newChats == 0)
        #expect(fixture.activations.values.count == 1)
        let shown = fixture.strip()
        #expect(shown.images.map(\.path) == paths)
        #expect(shown.images.first?.name == "Appshot of Safari")
        let context = try #require(shown.context.first)
        #expect(shown.context.count == 1)
        #expect(context.title == "Window text from Safari")
        #expect(context.detailText == "Example Domain\nMore information")
        // Waiting in the draft, not sent.
        #expect(fixture.store.thread(fixture.thread)?.items.isEmpty == true)
        #expect(fixture.store.thread(fixture.thread)?.draftContext == [context])
        #expect(fixture.hud.messages == ["Appshot of Safari added"] && fixture.hud.alerts == [false])
    }

    @Test func withoutARecentThreadAnAppshotStartsAChat() async {
        let fixture = Fixture()
        let controller = fixture.controller
        controller.screen = Self.screen(capturedInto: fixture.captured, text: nil)
        controller.enabled = true
        defer { controller.shutdown() }
        controller.takeAppshot()
        await waitForCapture(controller)

        #expect(fixture.newChats == 1 && fixture.opened.isEmpty)
        // It waits with the new chat's message; the thread on screen keeps its own.
        #expect(fixture.strip().images.isEmpty)
        fixture.composer.threadID = fixture.chat
        #expect(fixture.strip().images.map(\.path) == fixture.captured.values)
        #expect(fixture.strip().context.isEmpty)

        // The next appshot within a minute joins that chat.
        controller.takeAppshot()
        await waitForCapture(controller)
        #expect(fixture.newChats == 1 && fixture.opened == [fixture.chat])
    }

    @Test func windowsThatMustNotBeCapturedAreSkipped() async {
        let fixture = Fixture()
        let controller = fixture.controller
        var screen = Self.screen(capturedInto: fixture.captured)
        controller.enabled = true
        defer { controller.shutdown() }

        screen.isTakingPassword = { _, _ in true }
        controller.screen = screen
        controller.takeAppshot()
        #expect(controller.lastOutcome == .passwordField(app: "Safari"))

        screen.isTakingPassword = { _, _ in false }
        let protected = AppshotWindow(
            id: 3, ownerPID: Self.safari, ownerName: "Safari", bounds: CGRect(x: 0, y: 0, width: 500, height: 500), isShareable: false)
        screen.windows = { [protected] }
        controller.screen = screen
        controller.takeAppshot()
        #expect(controller.lastOutcome == .protectedWindow(app: "Safari"))

        // Only Coincide's own window is on screen, and Coincide is in front.
        screen.windows = { [Self.coincideWindow] }
        screen.frontmostPID = { 1 }
        controller.screen = screen
        controller.takeAppshot()
        #expect(controller.lastOutcome == .noWindow)

        await waitForCapture(controller)
        #expect(fixture.captured.values.isEmpty && fixture.newChats == 0 && fixture.opened.isEmpty)
        #expect(fixture.hud.alerts == [true, true, true])
    }

    @Test func withoutScreenRecordingItPointsToSettings() {
        let fixture = Fixture()
        let controller = fixture.controller
        controller.screenRecordingCheck = { false }
        let settingsOpened = Box<Bool>()
        controller.openSettings = { settingsOpened.values.append(true) }
        controller.enabled = true
        defer { controller.shutdown() }
        controller.takeAppshot()
        #expect(controller.lastOutcome == .screenRecordingNeeded && settingsOpened.values.count == 1)
        #expect(fixture.captured.values.isEmpty && fixture.newChats == 0)
        #expect(controller.stateDescription == "Waiting for Screen Recording access")
    }

    @Test func imagesForAnotherThreadWaitForIt() {
        let fixture = Fixture()
        let image = ComposerAttachment(path: "/tmp/appshot-other.png", name: "Appshot of Notes")
        AppEvents.addToComposer(images: [image], threadID: fixture.chat)
        #expect(fixture.strip().images.isEmpty)
        AppEvents.addToComposer(images: [image], threadID: fixture.thread)
        // The same image twice is attached once.
        AppEvents.addToComposer(images: [image], threadID: fixture.thread)
        #expect(fixture.strip().images.map(\.path) == [image.path])
        fixture.composer.threadID = fixture.chat
        #expect(fixture.strip().images.map(\.path) == [image.path])
        // A thread this composer's store doesn't have is not its to keep.
        AppEvents.addToComposer(images: [image], threadID: UUID())
        #expect(fixture.strip().images.count == 1)
    }

    @Test func settingsSearchFindsAppshots() {
        let entries = SettingsSearchResults.entries(kinds: [])
        for query in ["appshot", "screenshot", "command", "window"] {
            #expect(entries.contains { $0.pane == .section(.appshots) && $0.matches(query) }, "Missing search alias: \(query)")
        }
        #expect(SettingsSection(rawValue: "appshots") == .appshots)
        #expect(SettingsSection.appshots.title == "Appshots")
    }
}
