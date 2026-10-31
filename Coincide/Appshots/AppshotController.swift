import AppKit
import ApplicationServices
import CoincideKit
import CoreGraphics
import Observation

/// Settings › Appshots, modelled on ChatGPT's: pressing both ⌘ keys (or the user's shortcut) captures the frontmost
/// window of the app in front, and Coincide comes forward with the picture, and the window's text when allowed,
/// attached to a chat's message, unsent, for the user to ask about it.
///
/// Detecting both ⌘ keys uses AppKit's global monitor for `flagsChanged` events, the least a Mac app can watch: it sees
/// the modifier keys going up and down, never what is typed, and can't change or block anything. macOS delivers other
/// apps' key events to it once Coincide has Accessibility access (the same permission the window's text needs). To
/// tell ⌘C from both ⌘ keys without watching keystrokes, it asks the window server only how long ago a key last went
/// down (`CGEventSource.secondsSinceLastEventType`). A recorded shortcut is a Carbon hot key instead, which needs no
/// permission at all. While Appshots is off, nothing is installed.
@MainActor
@Observable
final class AppshotController {
    static let shared = AppshotController()

    /// What the last appshot did, for the HUD and Settings.
    enum Outcome: Equatable {
        case added(app: String)
        case screenRecordingNeeded
        case noWindow
        case protectedWindow(app: String)
        case passwordField(app: String)
        case failed(String)

        var message: String {
            switch self {
            case .added(let app): String(localized: "Appshot of \(app) added")
            case .screenRecordingNeeded: String(localized: "Allow Screen Recording in Settings › Appshots")
            case .noWindow: String(localized: "No window to capture")
            case .protectedWindow(let app): String(localized: "\(app) doesn’t allow capturing this window")
            case .passwordField(let app): String(localized: "Skipped: \(app) is taking a password")
            case .failed(let reason): reason
            }
        }

        var isAdded: Bool {
            if case .added = self { return true }
            return false
        }

        var symbol: String {
            switch self {
            case .added: "camera.viewfinder"
            case .screenRecordingNeeded, .protectedWindow, .passwordField: "lock.fill"
            case .noWindow, .failed: "exclamationmark.triangle.fill"
            }
        }
    }

    /// What is installed while Appshots is on: the observers of Coincide coming and going, and what notices the trigger
    /// (nothing until a shortcut is recorded).
    private struct Installation: Equatable {
        enum Watch: Equatable {
            case bothCommandKeys(accessibility: Bool)
            case shortcut(AppshotShortcut)
        }

        var watch: Watch?
    }

    @ObservationIgnored private let store: AppStore
    @ObservationIgnored var accessibilityCheck: () -> Bool = { AXIsProcessTrusted() }
    @ObservationIgnored var screenRecordingCheck: () -> Bool = { CGPreflightScreenCaptureAccess() }
    /// The thread the main window shows; tests replace it.
    @ObservationIgnored var visibleThread: () -> UUID? = { ThreadActivity.shared.visibleThreadID }
    @ObservationIgnored var hud: AppshotHUDPresenting = AppshotHUD()
    @ObservationIgnored var screen = AppshotScreen()
    /// Opening a thread, starting a chat and bringing Coincide forward; tests replace them, so no window shows.
    @ObservationIgnored var openThread: (UUID) -> Void = { AppEvents.openThread($0) }
    @ObservationIgnored var newChat: () -> UUID? = { ThreadActions.newChat() }
    @ObservationIgnored var activate: () -> Void = { NSApp.activate() }
    @ObservationIgnored var openSettings: () -> Void = { AppEvents.showSettings(section: .appshots) }
    @ObservationIgnored private var observation: ObservationToken?
    /// Nil while nothing is installed.
    @ObservationIgnored private var installation: Installation?
    @ObservationIgnored private var monitors: [Any] = []
    @ObservationIgnored private var hotKey: GlobalHotKey?
    @ObservationIgnored private var appObservers: [NSObjectProtocol] = []
    @ObservationIgnored private var detector = BothCommandKeysDetector()
    @ObservationIgnored private var destination = AppshotDestination()

    private(set) var settings: AppshotSettings
    private(set) var accessibilityGranted = false
    private(set) var screenRecordingGranted = false
    private(set) var isCapturing = false
    private(set) var lastOutcome: Outcome?
    /// macOS refused the recorded shortcut, usually because another app has it.
    private(set) var shortcutUnavailable = false

    init(store: AppStore = .shared) {
        self.store = store
        settings = store.settings.appshots
    }

    // MARK: Settings

    var enabled: Bool {
        get { settings.enabled }
        set { update { $0.enabled = newValue } }
    }

    var trigger: AppshotTrigger {
        get { settings.trigger }
        set { update { $0.trigger = newValue } }
    }

    var includesWindowText: Bool {
        get { settings.includesWindowText }
        set { update { $0.includesWindowText = newValue } }
    }

    var shortcut: KeyShortcut? { settings.shortcut?.keyShortcut }

    /// Records the shortcut the user typed (with its key code), or removes it.
    func setShortcut(_ shortcut: KeyShortcut?, keyCode: UInt16?) {
        update { settings in
            settings.shortcut = shortcut.flatMap { shortcut in keyCode.map { AppshotShortcut(keyCode: Int($0), shortcut: shortcut) } }
        }
    }

    private func update(_ mutate: (inout AppshotSettings) -> Void) {
        store.updateSettings { mutate(&$0.appshots) }
        apply()
    }

    var stateDescription: String {
        guard settings.enabled else { return String(localized: "Off") }
        if !screenRecordingGranted { return String(localized: "Waiting for Screen Recording access") }
        switch settings.trigger {
        case .bothCommandKeys:
            if !accessibilityGranted { return String(localized: "Waiting for Accessibility access") }
            return String(localized: "Ready: press both ⌘ keys")
        case .shortcut:
            guard let shortcut = settings.activeShortcut?.keyShortcut else { return String(localized: "Record a shortcut") }
            if shortcutUnavailable { return String(localized: "\(shortcut.displayString) is in use by another app") }
            return String(localized: "Ready: press \(shortcut.displayString)")
        }
    }

    // MARK: Lifecycle

    func start() {
        guard observation == nil else { return }
        observation = store.observe { [weak self] change in
            if case .settings = change { self?.apply() }
        }
        apply()
    }

    func shutdown() {
        observation = nil
        uninstall()
    }

    /// Follows the saved settings: installs what notices the trigger while Appshots is on, and nothing while it's off.
    private func apply() {
        if settings != store.settings.appshots { settings = store.settings.appshots }
        refreshPermissions()
        let wanted: Installation? =
            if !settings.enabled {
                nil
            } else if settings.trigger == .bothCommandKeys {
                Installation(watch: .bothCommandKeys(accessibility: accessibilityGranted))
            } else {
                Installation(watch: settings.activeShortcut.map { .shortcut($0) })
            }
        guard wanted != installation else { return }
        uninstall()
        guard let wanted else { return }
        installation = wanted
        switch wanted.watch {
        case .bothCommandKeys:
            // Other apps' modifier changes; Coincide's own come to the local monitor, with its key presses.
            if let global = NSEvent.addGlobalMonitorForEvents(matching: .flagsChanged, handler: { [weak self] event in
                self?.flagsChanged(event)
            }) {
                monitors.append(global)
            }
            if let local = NSEvent.addLocalMonitorForEvents(matching: [.flagsChanged, .keyDown], handler: { [weak self] event in
                if event.type == .keyDown { self?.detector.keyDown() } else { self?.flagsChanged(event) }
                return event
            }) {
                monitors.append(local)
            }
        case .shortcut(let shortcut):
            let modifiers = shortcut.keyShortcut?.modifiers ?? []
            hotKey = GlobalHotKey(keyCode: shortcut.keyCode, modifiers: modifiers) { [weak self] in self?.takeAppshot() }
            shortcutUnavailable = hotKey == nil
        case nil:
            break
        }
        let center = NotificationCenter.default
        // Leaving Coincide is the last moment the user interacted with the thread on screen.
        appObservers.append(
            center.addObserver(forName: NSApplication.didResignActiveNotification, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.recordInteraction() }
            })
        // Permissions granted in System Settings take effect when the user comes back.
        appObservers.append(
            center.addObserver(forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.refresh() }
            })
    }

    private func uninstall() {
        for monitor in monitors { NSEvent.removeMonitor(monitor) }
        monitors = []
        hotKey = nil
        shortcutUnavailable = false
        for observer in appObservers { NotificationCenter.default.removeObserver(observer) }
        appObservers = []
        installation = nil
        detector = BothCommandKeysDetector()
    }

    /// Reads the permissions again, and starts watching the keys anew once Accessibility was granted.
    func refresh() {
        let hadAccessibility = accessibilityGranted
        refreshPermissions()
        if accessibilityGranted != hadAccessibility { apply() }
    }

    private func refreshPermissions() {
        let accessibility = accessibilityCheck()
        let screenRecording = screenRecordingCheck()
        if accessibility != accessibilityGranted { accessibilityGranted = accessibility }
        if screenRecording != screenRecordingGranted { screenRecordingGranted = screenRecording }
    }

    // MARK: Permissions

    func requestAccessibility() {
        // The option's key, spelled out: the imported constant is a mutable global under strict concurrency.
        _ = AXIsProcessTrustedWithOptions(["AXTrustedCheckOptionPrompt": true] as CFDictionary)
        refresh()
    }

    func requestScreenRecording() {
        // macOS asks once; after that the user changes the answer in System Settings.
        _ = CGRequestScreenCaptureAccess()
        refresh()
    }

    func openAccessibilitySettings() { openPrivacyPane("Privacy_Accessibility") }
    func openScreenRecordingSettings() { openPrivacyPane("Privacy_ScreenCapture") }

    private func openPrivacyPane(_ anchor: String) {
        guard let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?\(anchor)") else { return }
        NSWorkspace.shared.open(url)
    }

    // MARK: Trigger

    private func flagsChanged(_ event: NSEvent) {
        let now = ProcessInfo.processInfo.systemUptime
        let sinceKey = CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: .keyDown)
        let lastKeyDown = sinceKey.isFinite ? now - sinceKey : nil
        if detector.flagsChanged(UInt(event.modifierFlags.rawValue), at: event.timestamp, lastKeyDown: lastKeyDown) {
            takeAppshot()
        }
    }

    private func recordInteraction() {
        recordInteraction(with: visibleThread())
    }

    /// The user interacted with `thread` (or with no thread) just now: an appshot within a minute goes there.
    func recordInteraction(with thread: UUID?) {
        destination.recordInteraction(with: thread, at: ProcessInfo.processInfo.systemUptime)
    }

    /// Whether anything is installed, for tests: nothing may be while Appshots is off.
    var isWatching: Bool { installation != nil }

    // MARK: Taking an appshot

    /// Captures the frontmost window of the app in front (not Coincide) and attaches it to a chat, unsent.
    func takeAppshot() {
        guard settings.enabled, !isCapturing else { return }
        // In Coincide itself, the thread on screen is the one in use right now.
        if NSApp.isActive { recordInteraction() }
        refreshPermissions()
        guard screenRecordingGranted else {
            finish(.screenRecordingNeeded, around: nil)
            openSettings()
            activate()
            return
        }
        let window: AppshotWindow
        switch AppshotWindowPicker.choose(from: screen.windows(), frontmostPID: screen.frontmostPID(), excluding: [screen.ownPID]) {
        case .none:
            return finish(.noWindow, around: nil)
        case .protected(let protected):
            return finish(.protectedWindow(app: screen.appName(protected)), around: protected.bounds)
        case .capture(let chosen):
            window = chosen
        }
        let app = screen.appName(window)
        let canReadApp = accessibilityGranted
        let readsText = settings.includesWindowText && canReadApp
        let directory = store.directory.appendingPathComponent("attachments", isDirectory: true)
        let (isTakingPassword, capture, readText) = (screen.isTakingPassword, screen.capture, screen.readText)
        isCapturing = true
        Task {
            defer { isCapturing = false }
            // Asking the app about its focused field may wait on it, so not on the main thread.
            guard await !isTakingPassword(window, canReadApp) else {
                return finish(.passwordField(app: app), around: window.bounds)
            }
            // The text is read while the picture is taken.
            async let text: String? = readsText ? await readText(window) : nil
            do {
                let path = try await capture(window, directory)
                let context = await text.map { MessageContext(.windowText(.init(app: app, title: window.title, text: $0))) }
                deliver(ComposerAttachment(path: path, name: String(localized: "Appshot of \(app)")), context: context)
                finish(.added(app: app), around: window.bounds)
            } catch {
                finish(.failed(error.localizedDescription), around: window.bounds)
            }
        }
    }

    /// Brings Coincide forward with the appshot in a composer: the thread the user interacted with in the last minute,
    /// otherwise a new chat. Never sends.
    func deliver(_ image: ComposerAttachment, context: MessageContext?) {
        let now = ProcessInfo.processInfo.systemUptime
        let target = destination.target(at: now) { [store] id in store.summary(id).map { !$0.isArchived } ?? false }
        let threadID: UUID
        if let target {
            threadID = target
            openThread(target)
        } else if let chat = newChat() {
            threadID = chat
        } else {
            return
        }
        destination.recordInteraction(with: threadID, at: now)
        AppEvents.addToComposer(images: [image], threadID: threadID)
        if let context { AppEvents.addToComposer(context, threadID: threadID) }
        activate()
    }

    private func finish(_ outcome: Outcome, around frame: CGRect?) {
        lastOutcome = outcome
        hud.show(outcome.message, symbol: outcome.symbol, alert: !outcome.isAdded, around: frame)
    }
}

/// What an appshot reads from the screen. Tests replace it, so they never capture the real screen.
struct AppshotScreen {
    /// Coincide's own process, whose windows are never captured.
    var ownPID = ProcessInfo.processInfo.processIdentifier
    var windows: () -> [AppshotWindow] = { AppshotCapture.windows() }
    var frontmostPID: () -> Int32? = { NSWorkspace.shared.frontmostApplication?.processIdentifier }
    var appName: (AppshotWindow) -> String = { window in
        NSRunningApplication(processIdentifier: window.ownerPID)?.localizedName
            ?? (window.ownerName.isEmpty ? String(localized: "the app") : window.ownerName)
    }
    /// Whether the window's app is taking a password; the flag says whether Coincide may read the app.
    var isTakingPassword: @Sendable (AppshotWindow, Bool) async -> Bool = {
        await AppshotPrivacy.isTakingPassword($0, canReadApp: $1)
    }
    /// Captures the window into the folder and returns the picture's path.
    var capture: @Sendable (AppshotWindow, URL) async throws -> String = { try await AppshotCapture.capture($0, into: $1) }
    var readText: @Sendable (AppshotWindow) async -> String? = { await AppshotWindowText.read(from: $0) }
}
