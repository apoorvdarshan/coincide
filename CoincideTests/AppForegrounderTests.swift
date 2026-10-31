import AppKit
import Testing

@testable import Coincide

/// Bringing Coincide forward after an appshot taken in another app, with macOS replaced: nothing is activated, shown
/// or unhidden for real.
@MainActor
struct AppForegrounderTests {
    private final class FakeWindow: ForegroundWindow {
        var isMiniaturized: Bool
        var deminiaturized = 0
        var orderedFront = 0

        init(minimized: Bool = false) { isMiniaturized = minimized }

        func deminiaturize(_ sender: Any?) {
            deminiaturized += 1
            isMiniaturized = false
        }

        func makeKeyAndOrderFront(_ sender: Any?) { orderedFront += 1 }
    }

    /// What the foregrounder asked of macOS, in order.
    private final class Log {
        var steps: [String] = []
        var active = false
        var hidden = false
        /// Whether macOS grants the polite request.
        var grants = true
    }

    private func foregrounder(_ log: Log, window: FakeWindow?) -> AppForegrounder {
        let foregrounder = AppForegrounder()
        var system = AppForegrounder.System()
        system.isActive = { log.active }
        system.isHidden = { log.hidden }
        system.unhide = {
            log.steps.append("unhide")
            log.hidden = false
        }
        system.requestActivation = {
            log.steps.append("request")
            if log.grants { log.active = true }
        }
        system.forceActivation = {
            log.steps.append("force")
            log.active = true
        }
        system.mainWindow = { window }
        system.sleep = { _ in await Task.yield() }
        foregrounder.system = system
        return foregrounder
    }

    @Test func fromAnotherAppItAsksAndFocusesTheComposer() async {
        let log = Log()
        let window = FakeWindow()
        var focused = 0
        let task = foregrounder(log, window: window).bringForward { focused += 1 }
        await task?.value
        #expect(log.steps == ["request"])
        #expect(window.orderedFront == 1 && window.deminiaturized == 0)
        // Right away, and again once Coincide is active.
        #expect(focused == 2)
    }

    @Test func whenMacOSTurnsTheRequestDownItInsists() async {
        let log = Log()
        log.grants = false
        let window = FakeWindow()
        var focused = 0
        let task = foregrounder(log, window: window).bringForward { focused += 1 }
        await task?.value
        #expect(log.steps == ["request", "force"])
        #expect(log.active && window.orderedFront == 2 && focused == 2)
    }

    @Test func hiddenOrMinimizedComesBack() async {
        let log = Log()
        log.hidden = true
        let window = FakeWindow(minimized: true)
        await foregrounder(log, window: window).bringForward {}?.value
        #expect(log.steps.first == "unhide" && !log.hidden)
        #expect(window.deminiaturized == 1 && !window.isMiniaturized && window.orderedFront >= 1)
    }

    @Test func alreadyActiveItOnlyFocuses() {
        let log = Log()
        log.active = true
        let window = FakeWindow()
        var focused = 0
        let task = foregrounder(log, window: window).bringForward { focused += 1 }
        #expect(task == nil && log.steps.isEmpty && focused == 1 && window.orderedFront == 1)
    }
}
