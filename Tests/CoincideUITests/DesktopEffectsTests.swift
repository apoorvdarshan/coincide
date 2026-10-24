import AppKit
import CoincideCore
import Testing
@testable import Coincide

/// One simulated native key owner; no window is ordered or the app activated.
@MainActor private final class DesktopEffectsWindow: NSWindow {
    private static weak var owner: DesktopEffectsWindow?
    override var isKeyWindow: Bool { Self.owner === self }
    override func makeKey() { Self.owner = self }
    override func resignKey() { if Self.owner === self { Self.owner = nil } }
    override func close() { resignKey(); super.close() }
}

/// Test-owned value that main-actor effect closures read after later changes.
@MainActor private final class DesktopEffectsValue<Value> {
    var value: Value
    init(_ value: Value) { self.value = value }
}

@MainActor @Test func quitShortcutConsultsTheDispatcherOnceAndResetsAcrossWindowsAndMarkedText() async throws {
    _ = NSApplication.shared
    let one = DesktopEffectsWindow(contentRect: .init(x: -10_000, y: -10_000, width: 400, height: 300), styleMask: [.titled], backing: .buffered, defer: false)
    let two = DesktopEffectsWindow(contentRect: .init(x: -10_000, y: -10_000, width: 400, height: 300), styleMask: [.titled], backing: .buffered, defer: false)
    one.isReleasedWhenClosed = false; two.isReleasedWhenClosed = false
    defer { one.close(); two.close() }
    let suite = "coincide-quit-effects-" + UUID().uuidString
    let defaults = try #require(UserDefaults(suiteName: suite)); defer { defaults.removePersistentDomain(forName: suite) }
    var routed = 0, hints = 0, quits = 0
    let customBinding = DesktopEffectsValue(true)
    let monitor = QuitShortcutMonitor(defaults: defaults, defaultMode: .hold, routeKeyDown: { _ in routed += 1; return customBinding.value },
        effects: .init(showHint: { _ in hints += 1 }, hideHint: { _ in })) { quits += 1 }
    func key(_ window: NSWindow, _ characters: String = "q", keyCode: UInt16 = 12) throws -> NSEvent {
        try #require(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: .command,
            timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber, context: nil,
            characters: characters, charactersIgnoringModifiers: characters, isARepeat: false, keyCode: keyCode))
    }
    one.makeKey()
    let bound = try key(one)
    #expect(monitor.handle(bound) && monitor.handle(bound))
    #expect(routed == 1 && hints == 0 && quits == 0)
    customBinding.value = false
    #expect(monitor.handle(try key(one)))
    #expect(hints == 1 && quits == 0)
    two.makeKey()
    #expect(monitor.handle(try key(two)))
    #expect(hints == 2 && quits == 0, "The new key window starts a fresh quit sequence.")
    let beforeWrongWindow = routed
    #expect(monitor.handle(try key(one)), "A blocked Cmd-Q cannot fall through to the global Quit menu.")
    #expect(!monitor.handle(try key(one, "x", keyCode: 7)), "Other keys retain native handling in an ineligible scope.")
    #expect(routed == beforeWrongWindow && quits == 0)
    let editor = NSTextView(frame: .init(x: 0, y: 0, width: 300, height: 100))
    two.contentView = editor
    #expect(two.makeFirstResponder(editor))
    editor.setMarkedText("拼", selectedRange: .init(location: 1, length: 0), replacementRange: .init(location: NSNotFound, length: 0))
    #expect(editor.hasMarkedText())
    let beforeMarked = routed
    #expect(monitor.handle(try key(two)) && routed == beforeMarked, "Marked text blocks quitting and consumes the global Quit equivalent.")
    #expect(!monitor.handle(try key(two, "x", keyCode: 7)))
    editor.unmarkText()
    #expect(monitor.handle(try key(two)))
    #expect(quits == 0)
    await monitor.shutdown()
    #expect(!monitor.handle(try key(two)) && quits == 0)
}

@MainActor @Test func activityAssertionInjectedEffectsDrainBeforeShutdownAndCannotResume() async throws {
    let suite = "coincide-activity-drain-" + UUID().uuidString
    let defaults = try #require(UserDefaults(suiteName: suite)); defer { defaults.removePersistentDomain(forName: suite) }
    let count = DesktopEffectsValue(1)
    var begins = 0, ends = 0
    defaults.set(ActivityAssertionPolicy.Preference.always.rawValue, forKey: AgentActivityAssertion.preference)
    let assertion = AgentActivityAssertion(activeConversations: { count.value }, power: { .ac }, defaults: defaults,
        activities: .init(begin: { _ in begins += 1; return NSObject() }, end: { _ in ends += 1 }), releaseDelay: .seconds(30))
    assertion.start(); #expect(assertion.level == .preventIdleSleep && begins == 1)
    count.value = 0; assertion.update()
    assertion.shutdown(); await assertion.drain()
    #expect(assertion.level == .none && ends == 1)
    count.value = 2; assertion.update()
    #expect(begins == 1 && ends == 1 && assertion.level == .none)
}
