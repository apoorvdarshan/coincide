import AppKit
import CoincideCore
import SwiftUI

/// Intercepts ⌘Q before menu key equivalents and feeds QuitShortcutStateMachine.
/// The Quit menu item itself still quits immediately, as in T3; direct mode passes
/// the key through unchanged so the standard menu path handles it.
@MainActor
final class QuitShortcutMonitor {
    static let preference = "quitShortcutMode"
    private var machine = QuitShortcutStateMachine()
    private var monitor: Any?
    private var timer: Task<Void, Never>?
    private let hud = QuitHoldHUD()
    private let defaults: UserDefaults
    private let defaultMode: QuitShortcutStateMachine.Mode
    private let quit: @MainActor () -> Void
    private let origin = ContinuousClock.now

    init(defaults: UserDefaults = .standard, defaultMode: QuitShortcutStateMachine.Mode, quit: @escaping @MainActor () -> Void) {
        self.defaults = defaults; self.defaultMode = defaultMode; self.quit = quit
    }

    var mode: QuitShortcutStateMachine.Mode {
        QuitShortcutStateMachine.Mode(rawValue: defaults.string(forKey: Self.preference) ?? "") ?? defaultMode
    }

    func install() {
        guard monitor == nil else { return }
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .keyUp, .flagsChanged]) { [weak self] event in
            let consumed = MainActor.assumeIsolated { self?.handle(event) ?? false }
            return consumed ? nil : event
        }
    }

    func uninstall() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil; timer?.cancel(); timer = nil; hud.hide(linger: false)
    }

    private var now: Int64 {
        let elapsed = origin.duration(to: .now)
        return elapsed.components.seconds * 1_000 + elapsed.components.attoseconds / 1_000_000_000_000_000
    }

    /// Returns true when the event was consumed.
    func handle(_ event: NSEvent) -> Bool {
        // Modal alerts (including the quit confirmations) keep their own key handling.
        guard NSApp.modalWindow == nil else { return false }
        let mode = self.mode
        let input: QuitShortcutStateMachine.Input
        // Characters are read only from key events; flagsChanged events have none.
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

    private func apply(_ effects: [QuitShortcutStateMachine.Effect]) {
        for effect in effects {
            switch effect {
            case .showHint(let mode): hud.show(mode)
            case .hideHint: hud.hide(linger: true)
            case .cancelTimer: timer?.cancel(); timer = nil
            case let .schedule(token, milliseconds):
                timer?.cancel()
                timer = Task { [weak self] in
                    try? await Task.sleep(for: .milliseconds(milliseconds))
                    guard !Task.isCancelled, let self else { return }
                    self.apply(self.machine.handle(.timer(token), mode: self.mode, now: self.now).effects)
                }
            case .quit:
                timer?.cancel(); timer = nil; hud.hide(linger: false)
                // Leave the event monitor before the terminate flow runs its alerts.
                Task { @MainActor [quit] in quit() }
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
