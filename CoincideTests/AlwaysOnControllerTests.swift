import CoincideKit
import Foundation
import Testing

@testable import Coincide

/// Settings › General › Keep Awake against a fake Mac: no power setting changes, no password prompt and nothing
/// registered with launchd.
@MainActor
struct AlwaysOnControllerTests {
    final class FakeSystem: AlwaysOnSystem {
        var power: PowerSettings? = PowerSettings(sleepDisabled: false, chargerSleep: 10, batterySleep: 3)
        var adminResult = AlwaysOnAdminResult.succeeded
        var scripts: [String] = []
        var serviceState = AlwaysOnServiceState.notRegistered
        var registrations = 0
        var unregistrations = 0
        var batteryHelperState = AlwaysOnServiceState.notRegistered
        /// The user allows the battery helper in Login Items as soon as it's registered.
        var approvesBatteryHelper = true
        var hasLid = true
        var standalone: StandaloneAlwaysOn?
        var removed: [StandaloneAlwaysOn] = []
        var audioRestores: [URL] = []
        /// What happened, in order: admin, watcher+, watcher-, helper+, helper-.
        var events: [String] = []
        /// Checked at each prompt and registration, for what must already be on disk then.
        var onAdmin: (() -> Void)?
        var onRegister: (() -> Void)?

        func readPower() async -> PowerSettings? { power }

        func runAsAdministrator(_ script: String, prompt: String) async -> AlwaysOnAdminResult {
            scripts.append(script)
            events.append("admin")
            onAdmin?()
            if adminResult == .succeeded, let current = power { power = Self.applying(script, to: current) }
            switchSleepLikeTheHelper()
            return adminResult
        }

        func registerService() throws {
            onRegister?()
            registrations += 1
            events.append("watcher+")
            serviceState = .running
        }

        func unregisterService() async throws {
            unregistrations += 1
            events.append("watcher-")
            serviceState = .notRegistered
        }

        func registerBatteryHelper() throws {
            events.append("helper+")
            batteryHelperState = approvesBatteryHelper ? .running : .needsApproval
            switchSleepLikeTheHelper()
        }

        func unregisterBatteryHelper() async throws {
            events.append("helper-")
            batteryHelperState = .notRegistered
        }

        /// What the running helper does: sleep disabled on the charger, enabled on battery.
        func switchSleepLikeTheHelper() {
            guard batteryHelperState == .running, let current = power else { return }
            power?.sleepDisabled = !current.onBattery
        }

        func unplug(_ onBattery: Bool) {
            power?.onBattery = onBattery
            switchSleepLikeTheHelper()
        }

        func openLoginItems() {}
        func findStandalone() -> StandaloneAlwaysOn? { standalone }

        func removeStandalone(_ install: StandaloneAlwaysOn) async throws {
            removed.append(install)
            standalone = nil
        }

        func restoreAudio(stateFile: URL) { audioRestores.append(stateFile) }

        /// What pmset would make of the script's commands.
        static func applying(_ script: String, to power: PowerSettings) -> PowerSettings {
            var result = power
            let firstPart = script.components(separatedBy: " || {").first ?? script
            for command in firstPart.components(separatedBy: "/usr/bin/pmset ").dropFirst() {
                let words = command.split(whereSeparator: { $0 == " " || $0 == ";" || $0 == "&" || $0 == "|" }).map(String.init)
                guard words.count >= 3, let value = Int(words[2]) else { continue }
                switch (words[0], words[1]) {
                case ("-c", "sleep"): result.chargerSleep = value
                case ("-b", "sleep"): result.batterySleep = value
                case ("-a", "disablesleep"): result.sleepDisabled = value == 1
                default: break
                }
            }
            return result
        }
    }

    private let folder = TemporaryDirectory("always-on")
    private let system = FakeSystem()
    private var store: AppStore { AppStore(directory: folder.url) }

    private func controller(_ store: AppStore) -> AlwaysOnController {
        AlwaysOnController(store: store, system: system)
    }

    private var restorePointFile: URL { AlwaysOnIdentity.restorePointFile(in: folder.url) }

    @Test func turningOnSavesTheRestorePointFirstAndStartsTheWatcherAfterTheSettingIsOnDisk() async throws {
        let store = store
        let controller = controller(store)
        let settingsFile = AlwaysOnIdentity.settingsFile(in: folder.url)
        let point = restorePointFile
        var savedBeforePrompt: AlwaysOnRestorePoint?
        var enabledOnDiskAtRegistration = false
        system.onAdmin = { savedBeforePrompt = AlwaysOnRestorePoint.load(from: point) }
        system.onRegister = { enabledOnDiskAtRegistration = AlwaysOnSettings.read(settingsFile: settingsFile).enabled }
        await controller.setEnabled(true)
        #expect(savedBeforePrompt == AlwaysOnRestorePoint(sleepDisabled: false, chargerSleep: 10))
        #expect(system.scripts == [try AlwaysOnScript.apply(current: PowerSettings(sleepDisabled: false, chargerSleep: 10, batterySleep: 3))])
        #expect(store.settings.alwaysOn.enabled)
        #expect(enabledOnDiskAtRegistration)
        #expect(system.events == ["admin", "watcher+"])
        #expect(controller.service == .running)
        // No battery helper unless the Mac should sleep on battery.
        #expect(controller.batteryHelper == .notRegistered)
        #expect(controller.power?.isAwake(sleepsOnBattery: false) == true)
        #expect(controller.problem == nil)
    }

    @Test func aCancelledOrFailedPromptChangesNothing() async throws {
        for result in [AlwaysOnAdminResult.cancelled, .failed("pmset: no")] {
            let store = store
            let controller = controller(store)
            system.adminResult = result
            await controller.setEnabled(true)
            #expect(!store.settings.alwaysOn.enabled)
            #expect(system.registrations == 0)
            #expect(AlwaysOnRestorePoint.load(from: restorePointFile) == nil)
            #expect(system.power?.sleepDisabled == false)
            if case .failed = result { #expect(controller.problem?.contains("pmset: no") == true) } else { #expect(controller.problem == nil) }
        }
    }

    @Test func turningOffPutsBackExactlyTheSavedValues() async throws {
        let store = store
        let controller = controller(store)
        await controller.setEnabled(true)
        await controller.setEnabled(false)
        #expect(system.scripts.last == (try AlwaysOnScript.restore(AlwaysOnRestorePoint(sleepDisabled: false, chargerSleep: 10))))
        #expect(!store.settings.alwaysOn.enabled)
        #expect(AlwaysOnRestorePoint.load(from: restorePointFile) == nil)
        #expect(system.unregistrations == 1)
        #expect(system.audioRestores == [AlwaysOnIdentity.audioStateFile(in: folder.url)])
        #expect(system.power == PowerSettings(sleepDisabled: false, chargerSleep: 10, batterySleep: 3))
    }

    @Test func aCancelledTurnOffKeepsItOnAndSaysWhy() async throws {
        let store = store
        let controller = controller(store)
        await controller.setEnabled(true)
        system.adminResult = .cancelled
        await controller.setEnabled(false)
        #expect(store.settings.alwaysOn.enabled)
        #expect(AlwaysOnRestorePoint.load(from: restorePointFile) != nil)
        #expect(system.unregistrations == 0)
        #expect(controller.problem?.isEmpty == false)
    }

    @Test func aLostRestorePointPutsBackMacOSDefaults() async throws {
        let store = store
        let controller = controller(store)
        await controller.setEnabled(true)
        try FileManager.default.removeItem(at: restorePointFile)
        await controller.setEnabled(false)
        #expect(system.scripts.last == (try AlwaysOnScript.restore(.macOSDefaults(hasBattery: true))))
        #expect(!store.settings.alwaysOn.enabled)
    }

    // MARK: Sleeping on battery

    @Test func theBatteryHelperRunsOnlyWhileKeepAwakeAndTheOptionAreOn() async throws {
        let store = store
        let controller = controller(store)
        await controller.setSleepsOnBattery(true)
        #expect(store.settings.alwaysOn.sleepsOnBattery)
        #expect(system.events.isEmpty)
        await controller.setEnabled(true)
        #expect(system.events == ["admin", "watcher+", "helper+"])
        #expect(controller.batteryHelper == .running)
        // Unplugged, sleep is on again; plugged in, off.
        system.unplug(true)
        await controller.refresh()
        #expect(system.power?.sleepDisabled == false)
        #expect(!controller.isOutOfStep)
        system.unplug(false)
        #expect(system.power?.sleepDisabled == true)
        // Off: the helper goes before the saved values come back, so it can't switch sleep after them.
        system.unplug(true)
        await controller.setEnabled(false)
        #expect(Array(system.events.suffix(3)) == ["helper-", "admin", "watcher-"])
        #expect(system.power == PowerSettings(sleepDisabled: false, chargerSleep: 10, batterySleep: 3, onBattery: true))
        #expect(controller.batteryHelper == .notRegistered)
    }

    @Test func turningTheOptionOnWhileAwakeAsksForNoPassword() async throws {
        let store = store
        let controller = controller(store)
        await controller.setEnabled(true)
        system.unplug(true)
        await controller.setSleepsOnBattery(true)
        #expect(system.scripts.count == 1)
        #expect(system.events.last == "helper+")
        #expect(system.power?.sleepDisabled == false)
    }

    @Test func turningTheOptionOffOnBatteryDisablesSleepAgain() async throws {
        let store = store
        let controller = controller(store)
        store.updateSettings { $0.alwaysOn.sleepsOnBattery = true }
        await controller.setEnabled(true)
        system.unplug(true)
        await controller.setSleepsOnBattery(false)
        #expect(Array(system.events.suffix(2)) == ["helper-", "admin"])
        #expect(system.scripts.last == AlwaysOnScript.sleepDisabled(true, undo: false))
        #expect(system.power?.sleepDisabled == true)
        #expect(!store.settings.alwaysOn.sleepsOnBattery)
        #expect(controller.batteryHelper == .notRegistered)
        #expect(!controller.isOutOfStep)
    }

    @Test func turningTheOptionOffOnTheChargerNeedsNoPassword() async throws {
        let store = store
        let controller = controller(store)
        store.updateSettings { $0.alwaysOn.sleepsOnBattery = true }
        await controller.setEnabled(true)
        await controller.setSleepsOnBattery(false)
        #expect(system.scripts.count == 1)
        #expect(system.events.last == "helper-")
    }

    @Test func aCancelledPromptAfterRemovingTheHelperShowsHowToFixIt() async throws {
        let store = store
        let controller = controller(store)
        store.updateSettings { $0.alwaysOn.sleepsOnBattery = true }
        await controller.setEnabled(true)
        system.unplug(true)
        system.adminResult = .cancelled
        await controller.setSleepsOnBattery(false)
        #expect(controller.problem?.isEmpty == false)
        #expect(controller.isOutOfStep)
        system.adminResult = .succeeded
        await controller.applyAgain()
        #expect(!controller.isOutOfStep)
    }

    @Test func aCancelledTurnOffStartsTheBatteryHelperAgain() async throws {
        let store = store
        let controller = controller(store)
        store.updateSettings { $0.alwaysOn.sleepsOnBattery = true }
        await controller.setEnabled(true)
        system.adminResult = .cancelled
        await controller.setEnabled(false)
        #expect(store.settings.alwaysOn.enabled)
        #expect(Array(system.events.suffix(3)) == ["helper-", "admin", "helper+"])
        #expect(controller.batteryHelper == .running)
    }

    @Test func aHelperWaitingForApprovalIsShownButNotOutOfStep() async throws {
        system.approvesBatteryHelper = false
        let store = store
        let controller = controller(store)
        store.updateSettings { $0.alwaysOn.sleepsOnBattery = true }
        await controller.setEnabled(true)
        system.unplug(true)
        await controller.refresh()
        #expect(controller.batteryHelper == .needsApproval)
        // Until it's allowed, sleep stays disabled on battery, as without the option.
        #expect(system.power?.sleepDisabled == true)
        #expect(!controller.isOutOfStep)
    }

    @Test func aMacWithoutABatteryNeverGetsTheHelper() async throws {
        system.power = PowerSettings(sleepDisabled: false, chargerSleep: 10, batterySleep: nil)
        let store = store
        let controller = controller(store)
        await controller.refresh()
        await controller.setEnabled(true)
        await controller.setSleepsOnBattery(true)
        #expect(!system.events.contains("helper+"))
    }

    @Test func launchRemovesAHelperNothingNeedsAndStartsOneThatWentMissing() async throws {
        let store = store
        system.batteryHelperState = .running
        let controller = controller(store)
        controller.startAtLaunch()
        for _ in 0..<100 where !system.events.contains("helper-") { try await Task.sleep(for: .milliseconds(10)) }
        #expect(system.events == ["helper-"])
        store.updateSettings {
            $0.alwaysOn.enabled = true
            $0.alwaysOn.sleepsOnBattery = true
        }
        let relaunched = AlwaysOnController(store: store, system: system)
        relaunched.startAtLaunch()
        for _ in 0..<100 where !system.events.contains("helper+") { try await Task.sleep(for: .milliseconds(10)) }
        #expect(system.events.suffix(2) == ["watcher+", "helper+"])
        #expect(system.scripts.isEmpty)
    }

    // MARK: Options and launch

    @Test func displayAndSoundOptionsNeedNoPassword() async {
        let store = store
        let controller = controller(store)
        controller.set(\.muteWhileClosed, true)
        controller.set(\.keepDisplaysOff, true)
        #expect(store.settings.alwaysOn.muteWhileClosed)
        #expect(store.settings.alwaysOn.keepDisplaysOff)
        #expect(system.scripts.isEmpty)
    }

    @Test func aMacWithoutALidKeepsAwakeWithoutAWatcher() async {
        system.hasLid = false
        let store = store
        let controller = controller(store)
        await controller.refresh()
        await controller.setEnabled(true)
        #expect(store.settings.alwaysOn.enabled)
        #expect(system.registrations == 0)
    }

    @Test func launchStartsALostWatcherWithoutAPrompt() async throws {
        let store = store
        store.updateSettings { $0.alwaysOn.enabled = true }
        let controller = controller(store)
        controller.startAtLaunch()
        for _ in 0..<100 where system.registrations == 0 { try await Task.sleep(for: .milliseconds(10)) }
        #expect(system.registrations == 1)
        #expect(system.scripts.isEmpty)
    }

    @Test func outOfStepSettingsAreShownAndAppliedAgain() async {
        let store = store
        let controller = controller(store)
        await controller.setEnabled(true)
        system.power?.sleepDisabled = false
        await controller.refresh()
        #expect(controller.isOutOfStep)
        await controller.applyAgain()
        #expect(!controller.isOutOfStep)
        #expect(system.scripts.count == 2)
    }

    // MARK: macbook-24x7-agents

    private func standalone(muting: Bool = true) throws -> StandaloneAlwaysOn {
        StandaloneAlwaysOn(
            label: "com.someone.lidwatch", plist: try folder.file("LaunchAgents/com.someone.lidwatch.plist"),
            script: try folder.file("bin/lid-display-off.sh"),
            audioStateFile: folder.url.appendingPathComponent("macbook-24x7-agents/audio-mute-state"),
            keepsDisplaysOff: true, mutesWhileClosed: muting)
    }

    @Test func anInstalledStandaloneWatcherMustBeSwitchedFromFirst() async throws {
        system.standalone = try standalone()
        let store = store
        let controller = controller(store)
        await controller.refresh()
        await controller.setEnabled(true)
        #expect(!store.settings.alwaysOn.enabled)
        #expect(system.scripts.isEmpty)
        #expect(system.removed.isEmpty)
        #expect(controller.problem?.isEmpty == false)
    }

    @Test func switchingFromTheStandaloneInstallKeepsItsOptionsAndSettingsWithoutAPrompt() async throws {
        let install = try standalone()
        try folder.file("macbook-24x7-agents/audio-mute-state", "false\n")
        system.standalone = install
        // What its install.sh left: sleep disabled, no idle sleep anywhere.
        system.power = PowerSettings(sleepDisabled: true, chargerSleep: 0, batterySleep: 0)
        let store = store
        let controller = controller(store)
        await controller.refresh()
        await controller.switchFromStandalone()
        #expect(system.removed == [install])
        #expect(system.scripts.isEmpty)
        let options = store.settings.alwaysOn
        #expect(options.enabled && options.keepDisplaysOff && options.muteWhileClosed && options.displayOffOnLidClose)
        #expect(!options.sleepsOnBattery)
        #expect(AlwaysOnRestorePoint.load(from: restorePointFile) == .macOSDefaults(hasBattery: true))
        #expect(AlwaysOnAudioState(url: AlwaysOnIdentity.audioStateFile(in: folder.url)).previousMute == false)
        #expect(!FileManager.default.fileExists(atPath: install.audioStateFile.path))
        #expect(system.registrations == 1)
        #expect(controller.standalone == nil)
    }

    @Test func switchingFromAnUndoneStandaloneInstallTurnsOnAsUsual() async throws {
        system.standalone = try standalone(muting: false)
        let store = store
        let controller = controller(store)
        await controller.refresh()
        await controller.switchFromStandalone()
        #expect(system.scripts.count == 1)
        #expect(store.settings.alwaysOn.enabled)
        #expect(!store.settings.alwaysOn.muteWhileClosed)
    }

    // MARK: Settings

    @Test func searchFindsAndRevealsKeepAwake() throws {
        let entries = SettingsSearchResults.entries(kinds: [])
        for query in [
            "keep awake", "24/7", "24x7", "sleep", "lid", "clamshell", "pmset", "macbook-24x7-agents", "battery",
            "charger", "unplugged", "battery helper", "disablesleep",
        ] {
            #expect(entries.contains { $0.setting == .keepAwake && $0.matches(query) }, "Missing search alias: \(query)")
        }
        #expect(entries.contains { $0.setting == .keepAwake && $0.title == String(localized: "Sleep normally on battery") })
        let entry = try #require(entries.first { $0.setting == .keepAwake })
        #expect(entry.pane == .section(.general))
        let store = store
        let model = SettingsModel(store: store, registry: ProviderRegistry(store: store, providers: []))
        model.pane = .section(.about)
        model.navigate(to: entry.pane, reveal: entry.setting)
        #expect(model.pane == .section(.general))
        #expect(model.reveal?.setting == .keepAwake)
    }

    @Test func restoringGeneralDefaultsLeavesKeepAwakeAlone() {
        var settings = AppSettings()
        settings.alwaysOn.enabled = true
        settings.alwaysOn.muteWhileClosed = true
        settings.alwaysOn.sleepsOnBattery = true
        GeneralSettingsView.restoreDefaults(in: &settings)
        #expect(settings.alwaysOn.enabled)
        #expect(settings.alwaysOn.muteWhileClosed)
        #expect(settings.alwaysOn.sleepsOnBattery)
    }
}
