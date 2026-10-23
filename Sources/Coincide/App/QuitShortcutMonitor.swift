import AppKit
import CoincideCore
import SwiftUI

/// Intercepts ⌘Q before menu key equivalents and feeds QuitShortcutStateMachine.
/// The Quit menu item itself still quits immediately, as in T3; direct mode passes
/// the key through unchanged so the standard menu path handles it.
@MainActor
final class QuitShortcutMonitor {
    static let preference = "quitShortcutMode"
    struct Effects {
        var showHint: @MainActor (QuitShortcutStateMachine.Mode) -> Void
        var hideHint: @MainActor (Bool) -> Void
        var drain: @MainActor () async -> Void = {}
    }
    private var machine = QuitShortcutStateMachine()
    private var monitor: Any?
    private var observations: [any NSObjectProtocol] = []
    private var timer: Task<Void, Never>?
    private var timerJobs: [UUID: Task<Void, Never>] = [:]
    private var quitTask: Task<Void, Never>?
    private weak var owner: NSWindow?
    private var ownerMode: QuitShortcutStateMachine.Mode?
    private let effects: Effects
    private let defaults: UserDefaults
    private let defaultMode: QuitShortcutStateMachine.Mode
    private let routeKeyDown: @MainActor (NSEvent) -> Bool
    private let quit: @MainActor () -> Void
    private let origin = ContinuousClock.now
    private var stopped = false
    private struct Decision { let event: NSEvent; let consumed: Bool }
    private var decisions: [ObjectIdentifier: Decision] = [:]
    private var decisionOrder: [ObjectIdentifier] = []

    init(defaults: UserDefaults = .standard, defaultMode: QuitShortcutStateMachine.Mode,
         routeKeyDown: @escaping @MainActor (NSEvent) -> Bool = { _ in false }, effects: Effects? = nil,
         quit: @escaping @MainActor () -> Void) {
        self.defaults = defaults; self.defaultMode = defaultMode; self.quit = quit; self.routeKeyDown = routeKeyDown
        if let effects { self.effects = effects }
        else if Self.isProductApp {
            let hud = QuitHoldHUD()
            self.effects = .init(showHint: { hud.show($0) }, hideHint: { hud.hide(linger: $0) }, drain: { await hud.drain() })
        } else { self.effects = .init(showHint: { _ in }, hideHint: { _ in }) }
    }

    private static var isProductApp: Bool {
        Bundle.main.bundleIdentifier == "com.apoorvdarshan.coincide" && Bundle.main.bundleURL.pathExtension == "app"
            && ProcessInfo.processInfo.environment["COINCIDE_UI_TESTING"] != "1"
    }
    var mode: QuitShortcutStateMachine.Mode {
        QuitShortcutStateMachine.Mode(rawValue: defaults.string(forKey: Self.preference) ?? "") ?? defaultMode
    }

    func install() {
        guard monitor == nil, Self.isProductApp else { return }
        stopped = false
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .keyUp, .flagsChanged]) { [weak self] event in
            let consumed = MainActor.assumeIsolated { self?.handle(event) ?? false }
            return consumed ? nil : event
        }
        for name in [NSWindow.didResignKeyNotification, NSApplication.didResignActiveNotification] {
            observations.append(NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.cancelScope() }
            })
        }
    }

    func uninstall() {
        stopped = true
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
        for token in observations { NotificationCenter.default.removeObserver(token) }; observations.removeAll()
        cancelScope(); for task in timerJobs.values { task.cancel() }
        decisions.removeAll(); decisionOrder.removeAll()
    }
    func shutdown() async {
        uninstall()
        while !timerJobs.isEmpty { for task in Array(timerJobs.values) { await task.value }; await Task.yield() }
        await quitTask?.value
        await effects.drain()
    }

    private var now: Int64 {
        let elapsed = origin.duration(to: .now)
        return elapsed.components.seconds * 1_000 + elapsed.components.attoseconds / 1_000_000_000_000_000
    }
    private static func eligible(_ window: NSWindow?) -> Bool {
        guard let window, window.isKeyWindow, window.attachedSheet == nil, NSApp?.modalWindow == nil else { return false }
        if let editor = window.firstResponder as? NSTextView, editor.hasMarkedText() { return false }
        return true
    }
    private func cancelScope() {
        apply(machine.handle(.cancel, mode: mode, now: now).effects)
        timer?.cancel(); timer = nil; owner = nil; ownerMode = nil
        effects.hideHint(false)
    }

    /// The dispatcher and native monitor can observe the same event; perform it once.
    func handle(_ event: NSEvent) -> Bool {
        guard !stopped else { return false }
        let identity = ObjectIdentifier(event)
        if let prior = decisions[identity], prior.event === event { return prior.consumed }
        let consumed = handleOnce(event)
        decisions[identity] = .init(event: event, consumed: consumed); decisionOrder.append(identity)
        if decisionOrder.count > 32 { decisions.removeValue(forKey: decisionOrder.removeFirst()) }
        return consumed
    }
    private func handleOnce(_ event: NSEvent) -> Bool {
        let window = event.window ?? owner
        guard Self.eligible(window) else {
            // Passing a blocked Cmd-Q through would invoke the global Quit menu
            // after this monitor refused the sheet, input-method or window scope.
            let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
            let consumesQuit = window != nil && event.type == .keyDown && flags.contains(.command)
                && flags.isDisjoint(with: [.option, .shift, .control])
                && event.charactersIgnoringModifiers?.lowercased() == "q"
            cancelScope(); return consumesQuit
        }
        if event.type == .keyDown, routeKeyDown(event) { cancelScope(); return true }
        if owner !== window || ownerMode != mode { cancelScope() }
        owner = window; ownerMode = mode
        let input: QuitShortcutStateMachine.Input
        switch event.type {
        case .keyDown:
            let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
            if mode == .direct && !machine.isShowingHint { return false }
            input = .keyDown(isQ: event.charactersIgnoringModifiers?.lowercased() == "q", command: flags.contains(.command),
                             otherModifiers: !flags.isDisjoint(with: [.option, .shift, .control]), isRepeat: event.isARepeat)
        case .keyUp:
            guard event.charactersIgnoringModifiers?.lowercased() == "q" else { return false }
            input = .qKeyUp
        case .flagsChanged:
            guard !event.modifierFlags.contains(.command) else { return false }
            input = .commandReleased
        default: return false
        }
        let output = machine.handle(input, mode: mode, now: now)
        apply(output.effects)
        return event.type == .keyDown && output.consumed
    }

    private func apply(_ values: [QuitShortcutStateMachine.Effect]) {
        for effect in values {
            switch effect {
            case .showHint(let mode): effects.showHint(mode)
            case .hideHint: effects.hideHint(true)
            case .cancelTimer: timer?.cancel(); timer = nil
            case let .schedule(token, milliseconds):
                timer?.cancel()
                let id = UUID()
                let task = Task { [weak self] in
                    defer { self?.timerJobs[id] = nil }
                    try? await Task.sleep(for: .milliseconds(milliseconds))
                    guard !Task.isCancelled, let self else { return }
                    guard !self.stopped, Self.eligible(self.owner), self.ownerMode == self.mode else { self.cancelScope(); return }
                    self.apply(self.machine.handle(.timer(token), mode: self.mode, now: self.now).effects)
                }
                timer = task; timerJobs[id] = task
            case .quit:
                timer?.cancel(); timer = nil; effects.hideHint(false)
                guard quitTask == nil else { continue }
                quitTask = Task { @MainActor [weak self] in
                    guard let self else { return }
                    defer { self.quitTask = nil }
                    guard !self.stopped, Self.eligible(self.owner), self.ownerMode == self.mode else { return }
                    self.quit()
                }
            }
        }
    }
}

/// A non-activating HUD like T3's QuitHoldOverlay, above the key window.
@MainActor
final class QuitHoldHUD {
    static let lingerAfterHold: Duration = .milliseconds(1_200)
    private var panel: NSPanel?
    private var shownMode: QuitShortcutStateMachine.Mode?
    private var hideTask: Task<Void, Never>?

    func show(_ mode: QuitShortcutStateMachine.Mode) {
        hideTask?.cancel(); hideTask = nil
        shownMode = mode
        let panel = self.panel ?? Self.makePanel()
        self.panel = panel
        let hosting = NSHostingView(rootView: QuitHoldHUDView(mode: mode))
        panel.contentView = hosting
        let size = hosting.fittingSize
        let anchor = NSApp.keyWindow?.frame ?? NSApp.mainWindow?.frame ?? NSScreen.main?.visibleFrame ?? .init(x: 0, y: 0, width: 800, height: 600)
        panel.setFrame(.init(x: anchor.midX - size.width / 2, y: anchor.maxY - anchor.height * 0.22 - size.height,
                             width: size.width, height: size.height), display: true)
        panel.orderFrontRegardless()
        let element: Any = NSApp.keyWindow.map { $0 as Any } ?? NSApp as Any
        NSAccessibility.post(element: element, notification: .announcementRequested,
                             userInfo: [.announcement: QuitHoldHUDView.message(for: mode), .priority: NSAccessibilityPriorityLevel.high.rawValue])
    }

    func hide(linger: Bool) {
        hideTask?.cancel(); hideTask = nil
        guard let panel, panel.isVisible else { return }
        // A released hold leaves its hint briefly so the instruction can be read.
        guard linger, shownMode == .hold else { panel.orderOut(nil); return }
        hideTask = Task { [weak panel] in
            try? await Task.sleep(for: Self.lingerAfterHold)
            guard !Task.isCancelled else { return }
            panel?.orderOut(nil)
        }
    }

    func drain() async {
        let task = hideTask
        hide(linger: false)
        await task?.value
    }

    private static func makePanel() -> NSPanel {
        let panel = NSPanel(contentRect: .init(x: 0, y: 0, width: 320, height: 64), styleMask: [.borderless, .nonactivatingPanel],
                            backing: .buffered, defer: true)
        panel.isOpaque = false; panel.backgroundColor = .clear; panel.hasShadow = false
        panel.level = .floating; panel.ignoresMouseEvents = true; panel.hidesOnDeactivate = true
        panel.isReleasedWhenClosed = false
        panel.collectionBehavior = [.canJoinAllSpaces, .transient, .ignoresCycle]
        return panel
    }
}

struct QuitHoldHUDView: View {
    let mode: QuitShortcutStateMachine.Mode
    static func message(for mode: QuitShortcutStateMachine.Mode) -> String {
        mode == .doublePress ? String(localized: "Press ⌘Q again to quit") : String(localized: "Hold ⌘Q or press twice to quit")
    }
    var body: some View {
        Text(Self.message(for: mode))
            .font(.title2.weight(.semibold))
            .multilineTextAlignment(.center)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.horizontal, 28).padding(.vertical, 14)
            .frame(maxWidth: 440)
            .coincideSurface(cornerRadius: 26)
            .padding(12)
            .accessibilityAddTraits(.isStaticText)
            .accessibilityIdentifier("quit-hold-hint")
    }
}
