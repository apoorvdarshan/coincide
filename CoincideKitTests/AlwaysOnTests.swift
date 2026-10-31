import Foundation
import Testing

@testable import CoincideKit

/// Keep Awake's pieces that touch no real setting: reading pmset, the administrator scripts (run against a fake
/// pmset), the restore point, the saved settings and the lid watcher's decisions.
struct AlwaysOnPowerTests {
    static let laptopGeneral = """
        System-wide power settings:
         SleepDisabled\t\t1
        Currently in use:
         standby              1
         sleep                0 (sleep prevented by coreaudiod, powerd)
         displaysleep         0 (display sleep prevented by Google Chrome)
        """
    static let laptopCustom = """
        Battery Power:
         Sleep On Power Button 1
         lowpowermode         1
         displaysleep         2
         sleep                5
         disksleep            10
        AC Power:
         Sleep On Power Button 1
         displaysleep         10
         sleep                1
         disksleep            10
        """

    @Test func readsALaptopsSettings() throws {
        let power = try #require(PowerSettings.parse(general: Self.laptopGeneral, custom: Self.laptopCustom))
        #expect(power == PowerSettings(sleepDisabled: true, chargerSleep: 1, batterySleep: 5))
        #expect(power.hasBattery)
    }

    @Test func aDesktopHasOnlyChargerSettingsAndSleepDisabledIsOffWhenNotListed() throws {
        let custom = "AC Power:\n sleep                10\n displaysleep         10\n"
        let power = try #require(PowerSettings.parse(general: "Currently in use:\n sleep 10\n", custom: custom))
        #expect(power == PowerSettings(sleepDisabled: false, chargerSleep: 10, batterySleep: nil))
        #expect(!power.hasBattery)
        #expect(PowerSettings.parse(general: "", custom: "Battery Power:\n sleep 1\n") == nil)
        #expect(PowerSettings.parse(general: "SleepDisabled 0", custom: custom)?.sleepDisabled == false)
    }

    @Test func awakeNeedsSleepDisabledAndNoIdleSleepWhereChosen() {
        let charging = PowerSettings(sleepDisabled: true, chargerSleep: 0, batterySleep: 5)
        #expect(charging.isAwake(onlyWhileCharging: true))
        #expect(!charging.isAwake(onlyWhileCharging: false))
        #expect(!PowerSettings(sleepDisabled: false, chargerSleep: 0, batterySleep: 0).isAwake(onlyWhileCharging: false))
        #expect(PowerSettings(sleepDisabled: true, chargerSleep: 0, batterySleep: nil).isAwake(onlyWhileCharging: false))
    }
}

struct AlwaysOnScriptTests {
    /// Runs a script with /usr/bin/pmset replaced by a recorder that fails the command named in `failing`.
    private func run(_ script: String, failing: String? = nil) throws -> (status: Int32, calls: [String]) {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("always-on-script-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let log = folder.appendingPathComponent("calls")
        let fake = folder.appendingPathComponent("pmset")
        try """
            #!/bin/sh
            echo "$*" >> '\(log.path)'
            [ "$*" != '\(failing ?? "")' ]
            """.write(to: fake, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: fake.path)
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", script.replacingOccurrences(of: "/usr/bin/pmset", with: fake.path)]
        try process.run()
        process.waitUntilExit()
        let calls = (try? String(contentsOf: log, encoding: .utf8))?.split(separator: "\n").map(String.init) ?? []
        return (process.terminationStatus, calls)
    }

    private let power = PowerSettings(sleepDisabled: false, chargerSleep: 10, batterySleep: 3)

    @Test func turningOnOnlyWhileChargingLeavesBatteryAlone() throws {
        let script = try AlwaysOnScript.apply(onlyWhileCharging: true, current: power)
        let result = try run(script)
        #expect(result.status == 0)
        #expect(result.calls == ["-c sleep 0", "-a disablesleep 1"])
    }

    @Test func turningOnEverywhereAlsoStopsBatteryIdleSleep() throws {
        let result = try run(try AlwaysOnScript.apply(onlyWhileCharging: false, current: power))
        #expect(result.status == 0)
        #expect(result.calls == ["-c sleep 0", "-b sleep 0", "-a disablesleep 1"])
        // A Mac without a battery is never asked about one.
        let desktop = PowerSettings(sleepDisabled: false, chargerSleep: 10, batterySleep: nil)
        #expect(try run(try AlwaysOnScript.apply(onlyWhileCharging: false, current: desktop)).calls == ["-c sleep 0", "-a disablesleep 1"])
    }

    @Test func aFailedStepPutsBackWhatTheScriptChangedAndFails() throws {
        let result = try run(try AlwaysOnScript.apply(onlyWhileCharging: false, current: power), failing: "-a disablesleep 1")
        #expect(result.status != 0)
        #expect(result.calls == [
            "-c sleep 0", "-b sleep 0", "-a disablesleep 1", "-c sleep 10", "-b sleep 3", "-a disablesleep 0",
        ])
    }

    @Test func restoringPutsBackOnlySavedValuesWithSleepLast() throws {
        let point = AlwaysOnRestorePoint(sleepDisabled: false, chargerSleep: 10, batterySleep: nil)
        let result = try run(try AlwaysOnScript.restore(point))
        #expect(result.status == 0)
        #expect(result.calls == ["-c sleep 10", "-a disablesleep 0"])
        #expect(try AlwaysOnScript.restore(AlwaysOnRestorePoint()) == "true")
    }

    @Test func restoringRunsEveryStepEvenWhenOneFails() throws {
        let point = AlwaysOnRestorePoint(sleepDisabled: false, chargerSleep: 10, batterySleep: 3)
        let result = try run(try AlwaysOnScript.restore(point), failing: "-c sleep 10")
        #expect(result.status != 0)
        #expect(result.calls == ["-c sleep 10", "-b sleep 3", "-a disablesleep 0"])
    }

    @Test func switchingBatterySleepUndoesItselfOnFailure() throws {
        #expect(try run(try AlwaysOnScript.batterySleep(0, undo: 3)).calls == ["-b sleep 0"])
        let failed = try run(try AlwaysOnScript.batterySleep(0, undo: 3), failing: "-b sleep 0")
        #expect(failed.status != 0)
        #expect(failed.calls == ["-b sleep 0", "-b sleep 3"])
    }

    @Test func valuesOutsidePmsetsRangeAreRefused() {
        #expect(throws: AlwaysOnScript.Failure.invalidValue) {
            try AlwaysOnScript.restore(AlwaysOnRestorePoint(chargerSleep: -1))
        }
        #expect(throws: AlwaysOnScript.Failure.invalidValue) { try AlwaysOnScript.batterySleep(0, undo: 1_000_000) }
    }
}

struct AlwaysOnRestorePointTests {
    @Test func earlierValuesWinAndTheFileRoundTrips() throws {
        let earlier = AlwaysOnRestorePoint(sleepDisabled: false, chargerSleep: 10)
        let merged = earlier.adding(AlwaysOnRestorePoint(sleepDisabled: true, chargerSleep: 0, batterySleep: 4))
        #expect(merged == AlwaysOnRestorePoint(sleepDisabled: false, chargerSleep: 10, batterySleep: 4))
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("restore-\(UUID().uuidString)/point.json")
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        try merged.save(to: url)
        #expect(AlwaysOnRestorePoint.load(from: url) == merged)
        #expect(AlwaysOnRestorePoint.macOSDefaults(hasBattery: false) == AlwaysOnRestorePoint(sleepDisabled: false, chargerSleep: 1))
        #expect(AlwaysOnRestorePoint().isEmpty)
    }
}

@MainActor
struct AlwaysOnSettingsTests {
    @Test func offByDefaultWithTheRepositorysDefaults() throws {
        let settings = AppSettings().alwaysOn
        #expect(!settings.enabled)
        #expect(settings.onlyWhileCharging)
        #expect(settings.displayOffOnLidClose)
        #expect(!settings.keepDisplaysOff)
        #expect(!settings.muteWhileClosed)
        #expect(try JSONDecoder().decode(AppSettings.self, from: Data(#"{"fontSize":16}"#.utf8)).alwaysOn == AlwaysOnSettings())
    }

    @Test(arguments: ["null", "3", #""on""#, "[]", #"{"enabled":"yes","muteWhileClosed":true}"#])
    func unreadableValuesKeepTheirDefaultsAndTheOtherSettings(value: String) throws {
        let data = Data(#"{"alwaysOn":\#(value),"fontSize":16,"commandLineControl":false}"#.utf8)
        let settings = try JSONDecoder().decode(AppSettings.self, from: data)
        #expect(!settings.alwaysOn.enabled)
        #expect(settings.fontSize == 16)
        #expect(!settings.commandLineControl)
        if value.contains("muteWhileClosed") { #expect(settings.alwaysOn.muteWhileClosed) }
    }

    @Test func theWatcherReadsWhatTheAppSaved() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("always-on-settings-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = AlwaysOnIdentity.settingsFile(in: directory)
        #expect(AlwaysOnSettings.read(settingsFile: file) == AlwaysOnSettings())
        let store = AppStore(directory: directory)
        store.updateSettings {
            $0.alwaysOn.enabled = true
            $0.alwaysOn.keepDisplaysOff = true
        }
        store.flush()
        let read = AlwaysOnSettings.read(settingsFile: file)
        #expect(read.enabled)
        #expect(read.keepDisplaysOff)
        try Data("{not json".utf8).write(to: file)
        #expect(!AlwaysOnSettings.read(settingsFile: file).enabled)
    }

    @Test func theWatcherLooksWhereTheAppSaves() {
        #expect(AlwaysOnIdentity.dataDirectory.path.hasSuffix("Library/Application Support/Coincide"))
        if ProcessInfo.processInfo.environment["COINCIDE_DATA_DIR"] == nil {
            #expect(AlwaysOnIdentity.dataDirectory == AppStore.defaultDirectory)
        }
    }
}

/// The lid watcher's decisions against a fake Mac, as `tests/test-lid-display-off.sh` checks the script's.
struct LidWatcherCoreTests {
    final class FakeHardware: LidWatcherHardware {
        var displaySleeps = 0
        var muted: Bool? = false
        var setterWorks = true
        var idle: Double? = 60
        var sets: [Bool] = []

        func sleepDisplays() { displaySleeps += 1 }
        func outputMuted() -> Bool? { muted }
        func setOutputMuted(_ value: Bool) -> Bool {
            sets.append(value)
            guard setterWorks else { return false }
            muted = value
            return true
        }
        func secondsSinceInput() -> Double? { idle }
    }

    private let stateURL = FileManager.default.temporaryDirectory.appendingPathComponent("lid-audio-\(UUID().uuidString).json")

    private func core(_ hardware: FakeHardware, _ change: (inout AlwaysOnSettings) -> Void = { _ in }) -> LidWatcherCore {
        var settings = AlwaysOnSettings()
        settings.enabled = true
        change(&settings)
        return LidWatcherCore(hardware: hardware, audio: AlwaysOnAudioState(url: stateURL), settings: settings)
    }

    @Test func theDisplaySleepsOncePerClose() {
        let hardware = FakeHardware()
        let watcher = core(hardware)
        watcher.lid(closed: false)
        #expect(hardware.displaySleeps == 0)
        watcher.lid(closed: true)
        watcher.lid(closed: true)
        #expect(hardware.displaySleeps == 1)
        watcher.lid(closed: false)
        watcher.lid(closed: true)
        #expect(hardware.displaySleeps == 2)
        #expect(!watcher.needsTick)
    }

    @Test func turnedOffDisplaySleepLeavesTheDisplayAlone() {
        let hardware = FakeHardware()
        let watcher = core(hardware) { $0.displayOffOnLidClose = false }
        watcher.lid(closed: true)
        #expect(hardware.displaySleeps == 0)
    }

    @Test func keepDisplaysOffActsOnlyAfterRecentInputWhileClosed() {
        let hardware = FakeHardware()
        let watcher = core(hardware) { $0.keepDisplaysOff = true }
        watcher.lid(closed: true)
        #expect(watcher.needsTick)
        watcher.tick()
        #expect(hardware.displaySleeps == 1)
        hardware.idle = 1
        watcher.tick()
        #expect(hardware.displaySleeps == 2)
        watcher.lid(closed: false)
        watcher.tick()
        #expect(hardware.displaySleeps == 2)
        #expect(!watcher.needsTick)
    }

    @Test func muteSavesTheEarlierSettingOnceAndPutsItBackOnOpen() {
        defer { try? FileManager.default.removeItem(at: stateURL) }
        let hardware = FakeHardware()
        let watcher = core(hardware) { $0.muteWhileClosed = true }
        watcher.lid(closed: true)
        #expect(hardware.muted == true)
        #expect(AlwaysOnAudioState(url: stateURL).previousMute == false)
        // A restart while closed must not save the mute it applied itself.
        let restarted = core(hardware) { $0.muteWhileClosed = true }
        restarted.lid(closed: true)
        #expect(AlwaysOnAudioState(url: stateURL).previousMute == false)
        // Something unmuted it: the tick mutes it again.
        hardware.muted = false
        restarted.tick()
        #expect(hardware.muted == true)
        restarted.lid(closed: false)
        #expect(hardware.muted == false)
        #expect(AlwaysOnAudioState(url: stateURL).previousMute == nil)
    }

    @Test func aMutedMacStaysMutedAfterOpening() {
        defer { try? FileManager.default.removeItem(at: stateURL) }
        let hardware = FakeHardware()
        hardware.muted = true
        let watcher = core(hardware) { $0.muteWhileClosed = true }
        watcher.lid(closed: true)
        watcher.lid(closed: false)
        #expect(hardware.muted == true)
        #expect(!hardware.sets.contains(false))
    }

    @Test func aFailedRestoreKeepsTheSavedSettingAndRetries() {
        defer { try? FileManager.default.removeItem(at: stateURL) }
        let hardware = FakeHardware()
        let watcher = core(hardware) { $0.muteWhileClosed = true }
        watcher.lid(closed: true)
        hardware.setterWorks = false
        watcher.lid(closed: false)
        #expect(AlwaysOnAudioState(url: stateURL).previousMute == false)
        #expect(watcher.needsTick)
        hardware.setterWorks = true
        watcher.tick()
        #expect(hardware.muted == false)
        #expect(!watcher.needsTick)
    }

    @Test func anUnreadableMuteSettingIsLeftAlone() {
        defer { try? FileManager.default.removeItem(at: stateURL) }
        let hardware = FakeHardware()
        hardware.muted = nil
        let watcher = core(hardware) { $0.muteWhileClosed = true }
        watcher.lid(closed: true)
        #expect(hardware.sets.isEmpty)
        #expect(AlwaysOnAudioState(url: stateURL).previousMute == nil)
    }

    @Test func stoppingPutsBackWhatItMuted() {
        defer { try? FileManager.default.removeItem(at: stateURL) }
        let hardware = FakeHardware()
        let watcher = core(hardware) { $0.muteWhileClosed = true }
        watcher.lid(closed: true)
        watcher.stop()
        #expect(hardware.muted == false)
        #expect(AlwaysOnAudioState(url: stateURL).previousMute == nil)
    }
}
