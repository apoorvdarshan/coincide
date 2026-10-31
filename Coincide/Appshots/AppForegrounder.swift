import AppKit

/// The window `AppForegrounder` brings forward; `NSWindow` in the app, a stand-in in tests.
@MainActor
protocol ForegroundWindow: AnyObject {
    var isMiniaturized: Bool { get }
    func deminiaturize(_ sender: Any?)
    func makeKeyAndOrderFront(_ sender: Any?)
}

extension NSWindow: ForegroundWindow {}

/// Brings Coincide to the front with its main window, from a trigger that fired while another app was in front (an
/// appshot's shortcut or both ⌘ keys), and puts the keyboard focus where `focus` says once Coincide is active.
///
/// Since macOS 14, `NSApp.activate()` only asks: macOS grants it when the request follows the user's own input to
/// Coincide, such as its hot key, and may turn it down otherwise, as for both ⌘ keys, which reach the app in front
/// rather than Coincide. Coincide asks first; when it is still not active a moment later, it activates the way it did
/// before macOS 14 (`activate(ignoringOtherApps:)`), which macOS still honours for an app the user summoned.
///
/// - Hidden (⌘H): shown again first, without activating, so the request below brings it forward like any other.
/// - Minimized: the main window comes back out of the Dock.
/// - On another Space: activating with the window ordered front moves to its Space, as clicking Coincide in the Dock
///   does (System Settings › Desktop & Dock › "When switching to an application, switch to a Space with open
///   windows for the application"). Coincide never moves the window itself.
@MainActor
final class AppForegrounder {
    static let shared = AppForegrounder()

    /// How long macOS gets to grant the request before Coincide insists, and how often it looks meanwhile.
    static let grantWait: Duration = .milliseconds(250)
    static let pollInterval: Duration = .milliseconds(50)

    struct System {
        var isActive: () -> Bool = { NSApp.isActive }
        var isHidden: () -> Bool = { NSApp.isHidden }
        var unhide: () -> Void = { NSApp.unhideWithoutActivation() }
        var requestActivation: () -> Void = { NSApp.activate() }
        var forceActivation: () -> Void = { NSApp.activate(ignoringOtherApps: true) }
        var mainWindow: () -> ForegroundWindow? = { (NSApp.delegate as? AppDelegate)?.mainWindow?.window }
        var sleep: (Duration) async -> Void = { try? await Task.sleep(for: $0) }
    }

    var system = System()
    private var pending: Task<Void, Never>?

    /// Shows Coincide, brings its main window forward and makes it active, then calls `focus`: right away, and again
    /// once Coincide became active when it wasn't yet. Returns the work still waiting on macOS, for tests.
    @discardableResult
    func bringForward(focus: @escaping @MainActor () -> Void) -> Task<Void, Never>? {
        pending?.cancel()
        pending = nil
        if system.isHidden() { system.unhide() }
        let window = system.mainWindow()
        if let window {
            if window.isMiniaturized { window.deminiaturize(nil) }
            window.makeKeyAndOrderFront(nil)
        }
        // Focus goes into the window now, so it is where the keys go the moment Coincide is active.
        focus()
        guard !system.isActive() else { return nil }
        system.requestActivation()
        let task = Task { [system] in
            var waited: Duration = .zero
            while waited < Self.grantWait {
                await system.sleep(Self.pollInterval)
                if Task.isCancelled { return }
                if system.isActive() { break }
                waited += Self.pollInterval
            }
            if !system.isActive() {
                system.forceActivation()
                window?.makeKeyAndOrderFront(nil)
            }
            focus()
        }
        pending = task
        return task
    }
}
