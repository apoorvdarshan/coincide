import Foundation
import IOKit
import IOKit.ps

// coincide-power-helper: the battery helper for Settings › General › Keep Awake › "Sleep normally on battery". A
// launchd daemon running as root (CoincideAgentHost/LaunchDaemons/power-helper.plist), registered with SMAppService only
// while that option and Keep Awake are on. It does one thing: `pmset disablesleep` 1 on the charger and 0 on battery,
// so closing the lid on battery sleeps the Mac. It takes no input from anyone; the power source is all it reads.

/// The Mac itself: the power source and `disablesleep` read from IOKit, `disablesleep` set with pmset.
final class MacBatterySleepControl: BatterySleepControl {
    func onBattery() -> Bool? { PowerSource.isOnBattery() }

    func sleepDisabled() -> Bool? {
        let root = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("IOPMrootDomain"))
        guard root != IO_OBJECT_NULL else { return nil }
        defer { IOObjectRelease(root) }
        // What `ioreg` shows; absent until it is first set, which means sleep is enabled.
        let value = IORegistryEntryCreateCFProperty(root, "SleepDisabled" as CFString, kCFAllocatorDefault, 0)?
            .takeRetainedValue()
        return value as? Bool ?? false
    }

    func setSleepDisabled(_ disabled: Bool) -> Bool {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/pmset")
        process.arguments = ["-a", "disablesleep", disabled ? "1" : "0"]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
        } catch {
            return false
        }
        process.waitUntilExit()
        return process.terminationStatus == 0
    }
}

nonisolated(unsafe) let batterySwitch = BatterySleepSwitch(control: MacBatterySleepControl())
batterySwitch.update()
// Power source changes, delivered on the main run loop.
if let source = IOPSNotificationCreateRunLoopSource({ _ in batterySwitch.update() }, nil)?.takeRetainedValue() {
    CFRunLoopAddSource(CFRunLoopGetMain(), source, .defaultMode)
}
CFRunLoopRun()
