import Foundation
import IOKit.ps

/// Where the Mac's power comes from now.
public enum PowerSource {
    /// nil when macOS doesn't say.
    public static func isOnBattery() -> Bool? {
        guard let info = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
            let type = IOPSGetProvidingPowerSourceType(info)?.takeUnretainedValue()
        else { return nil }
        return (type as String) == kIOPSBatteryPowerValue
    }
}

/// What the battery helper reads and changes. Its own implementation uses IOKit and pmset as root; tests use a fake.
public protocol BatterySleepControl: AnyObject {
    /// nil when the power source is unknown.
    func onBattery() -> Bool?
    /// `pmset disablesleep`; nil when it can't be read.
    func sleepDisabled() -> Bool?
    /// false when pmset refused.
    func setSleepDisabled(_ disabled: Bool) -> Bool
}

/// "Sleep normally on battery": sleep is disabled on the charger and enabled on battery, so closing the lid on battery
/// sleeps the Mac. The helper runs this at start and whenever the power source reports a change, which includes
/// battery percentage updates, so it changes the setting only when it differs.
public final class BatterySleepSwitch {
    private let control: BatterySleepControl

    public init(control: BatterySleepControl) {
        self.control = control
    }

    /// The `disablesleep` value the Mac now has, or nil when the power source is unknown and nothing changed.
    @discardableResult
    public func update() -> Bool? {
        guard let battery = control.onBattery() else { return nil }
        let wanted = !battery
        if control.sleepDisabled() == wanted { return wanted }
        return control.setSleepDisabled(wanted) ? wanted : control.sleepDisabled()
    }
}
