import Foundation
import IOKit

/// The lid sensor, read from the power-management root (`AppleClamshellState`, what `ioreg` shows).
public enum ClamshellSensor {
    /// nil on Macs without a lid.
    public static func isClosed() -> Bool? {
        let root = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("IOPMrootDomain"))
        guard root != IO_OBJECT_NULL else { return nil }
        defer { IOObjectRelease(root) }
        let value = IORegistryEntryCreateCFProperty(root, "AppleClamshellState" as CFString, kCFAllocatorDefault, 0)?
            .takeRetainedValue()
        return value as? Bool
    }

    public static var hasLid: Bool { isClosed() != nil }
}
