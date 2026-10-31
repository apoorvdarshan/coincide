import Foundation

/// The sleep settings Keep Awake changes, as `pmset -g` and `pmset -g custom` report them.
public struct PowerSettings: Codable, Hashable, Sendable {
    /// `pmset disablesleep`: nothing sleeps the system, closing the lid included.
    public var sleepDisabled: Bool
    /// Idle sleep on the charger, in minutes; 0 is never.
    public var chargerSleep: Int
    /// Idle sleep on battery; nil on Macs without one.
    public var batterySleep: Int?
    /// Running on battery now (`PowerSource`), not read from pmset.
    public var onBattery: Bool

    public init(sleepDisabled: Bool, chargerSleep: Int, batterySleep: Int?, onBattery: Bool = false) {
        self.sleepDisabled = sleepDisabled
        self.chargerSleep = chargerSleep
        self.batterySleep = batterySleep
        self.onBattery = onBattery
    }

    public var hasBattery: Bool { batterySleep != nil }

    /// nil when the output has no charger settings, which every Mac reports.
    public static func parse(general: String, custom: String) -> PowerSettings? {
        var source = ""
        var charger: Int?
        var battery: Int?
        for line in custom.split(whereSeparator: \.isNewline) {
            let text = line.trimmingCharacters(in: .whitespaces)
            if text.hasSuffix("Power:") {
                source = text
                continue
            }
            let fields = text.split(whereSeparator: \.isWhitespace)
            guard fields.count >= 2, fields[0] == "sleep", let minutes = Int(fields[1]) else { continue }
            if source == "AC Power:" { charger = minutes } else if source == "Battery Power:" { battery = minutes }
        }
        guard let charger else { return nil }
        // Listed under "System-wide power settings" only while it is set.
        let disabled = general.split(whereSeparator: \.isNewline).contains { line in
            let fields = line.split(whereSeparator: \.isWhitespace)
            return fields.count >= 2 && fields[0] == "SleepDisabled" && fields[1] == "1"
        }
        return PowerSettings(sleepDisabled: disabled, chargerSleep: charger, batterySleep: battery)
    }

    /// What Keep Awake needs now: no idle sleep on the charger, and sleep disabled, except on battery when the Mac
    /// should sleep there (the battery helper turns it back on).
    public func isAwake(sleepsOnBattery: Bool) -> Bool {
        chargerSleep == 0 && sleepDisabled == !(sleepsOnBattery && onBattery)
    }
}

/// The values Keep Awake changed and what they were, saved before changing them so turning it off puts back exactly
/// those, also after a crash or an update. A field is nil when Keep Awake left it alone.
public struct AlwaysOnRestorePoint: Codable, Hashable, Sendable {
    public var sleepDisabled: Bool?
    public var chargerSleep: Int?
    public var batterySleep: Int?

    public init(sleepDisabled: Bool? = nil, chargerSleep: Int? = nil, batterySleep: Int? = nil) {
        self.sleepDisabled = sleepDisabled
        self.chargerSleep = chargerSleep
        self.batterySleep = batterySleep
    }

    /// What `uninstall.sh` of macbook-24x7-agents puts back, for a Mac that ran it before Coincide: its own
    /// earlier values are gone.
    public static func macOSDefaults(hasBattery: Bool) -> AlwaysOnRestorePoint {
        AlwaysOnRestorePoint(sleepDisabled: false, chargerSleep: 1, batterySleep: hasBattery ? 1 : nil)
    }

    /// Values saved earlier win: they are from before Keep Awake changed anything.
    public func adding(_ other: AlwaysOnRestorePoint) -> AlwaysOnRestorePoint {
        AlwaysOnRestorePoint(
            sleepDisabled: sleepDisabled ?? other.sleepDisabled, chargerSleep: chargerSleep ?? other.chargerSleep,
            batterySleep: batterySleep ?? other.batterySleep)
    }

    public var isEmpty: Bool { sleepDisabled == nil && chargerSleep == nil && batterySleep == nil }

    public static func load(from url: URL) -> AlwaysOnRestorePoint? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(AlwaysOnRestorePoint.self, from: data)
    }

    public func save(to url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONEncoder().encode(self).write(to: url, options: .atomic)
    }
}

/// The commands run as administrator. Built only from numbers and fixed words, so nothing typed or read reaches the
/// shell. A step that fails puts back what the script already changed before it reports the failure, so the Mac is
/// never left half changed.
public enum AlwaysOnScript {
    static let pmset = "/usr/bin/pmset"
    /// pmset takes minutes; anything else is refused.
    static let minutes = 0...100_000

    public enum Failure: Error, Equatable { case invalidValue }

    /// Turns sleep off: idle sleep never on the charger, and `disablesleep 1`. The battery's idle timer is left alone:
    /// with sleep disabled it never fires, and the battery helper relies on it when the Mac should sleep on battery.
    public static func apply(current: PowerSettings) throws -> String {
        let steps = ["\(pmset) -c sleep 0", "\(pmset) -a disablesleep 1"]
        let undo = try restore(AlwaysOnRestorePoint(sleepDisabled: current.sleepDisabled, chargerSleep: current.chargerSleep))
        return guarded(steps, undo: undo)
    }

    /// `disablesleep` alone, for turning sleeping on battery off while Keep Awake stays on.
    public static func sleepDisabled(_ disabled: Bool, undo previous: Bool) -> String {
        guarded(["\(pmset) -a disablesleep \(disabled ? 1 : 0)"], undo: "\(pmset) -a disablesleep \(previous ? 1 : 0)")
    }

    /// Puts back the saved values; sleep is enabled again last, once idle sleep has its timers back. Every step runs
    /// even when one fails, and the script fails if any did.
    public static func restore(_ point: AlwaysOnRestorePoint) throws -> String {
        var steps: [String] = []
        if let charger = point.chargerSleep {
            guard minutes.contains(charger) else { throw Failure.invalidValue }
            steps.append("\(pmset) -c sleep \(charger)")
        }
        if let battery = point.batterySleep {
            guard minutes.contains(battery) else { throw Failure.invalidValue }
            steps.append("\(pmset) -b sleep \(battery)")
        }
        if let disabled = point.sleepDisabled { steps.append("\(pmset) -a disablesleep \(disabled ? 1 : 0)") }
        guard !steps.isEmpty else { return "true" }
        return "failed=; " + steps.map { $0 + " || failed=1" }.joined(separator: "; ") + #"; [ -z "$failed" ]"#
    }

    private static func guarded(_ steps: [String], undo: String) -> String {
        "{ " + steps.joined(separator: " && ") + "; } || { " + undo + "; exit 1; }"
    }
}
