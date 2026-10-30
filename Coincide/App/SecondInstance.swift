import AppKit
import UserNotifications

/// Keeps one Coincide running. macOS can launch another copy of the app (a development build, a version kept for
/// rolling back) to deliver a notification click; that copy passes the click to the Coincide already running and
/// quits, so the thread opens in the window the user has instead of a second window onto the same threads.
final class SecondInstance: NSObject, UNUserNotificationCenterDelegate {
    /// Posted by the copy that's handing over. userInfo["threadID"]: the thread's UUID string;
    /// userInfo["opensBrowser"]: whether to show its browser.
    static let openThread = Notification.Name("com.apoorvdarshan.coincide.openThreadFromAnotherCopy")

    private static var current: SecondInstance?
    private let running: NSRunningApplication

    private init(running: NSRunningApplication) {
        self.running = running
    }

    /// True when another Coincide is already running, in which case this copy stays out of sight, passes on any
    /// notification click and quits.
    static func handOffIfAnotherIsRunning() -> Bool {
        let me = NSRunningApplication.current
        guard let bundleID = Bundle.main.bundleIdentifier,
            // Test hosts run with the prohibited policy and never count.
            let running = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).first(where: {
                $0.processIdentifier != me.processIdentifier && $0.activationPolicy == .regular && !$0.isTerminated
            })
        else { return false }
        NSApp.setActivationPolicy(.prohibited)
        let handOff = SecondInstance(running: running)
        current = handOff
        UNUserNotificationCenter.current().delegate = handOff
        // A click is delivered just after launch; when none comes, this copy was opened some other way.
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) { handOff.finish() }
        return true
    }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse) async {
        let info = response.notification.request.content.userInfo
        let threadID = info["threadID"] as? String
        let opensBrowser = info["opensBrowser"] as? Bool == true
        await MainActor.run {
            if let threadID {
                DistributedNotificationCenter.default().postNotificationName(
                    Self.openThread, object: nil, userInfo: ["threadID": threadID, "opensBrowser": opensBrowser],
                    deliverImmediately: true)
            } else {
                running.activate()
            }
            finish()
        }
    }

    private func finish() {
        guard Self.current != nil else { return }
        Self.current = nil
        // Without a click to pass on, at least bring the running Coincide forward.
        running.activate()
        NSApp.terminate(nil)
    }
}
