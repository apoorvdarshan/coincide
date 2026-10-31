import CoincideKit
import Foundation
import Observation

/// Settings › General › Keep Awake: keeps this Mac running 24/7 for agents, with the lid closed and the display off,
/// as macbook-24x7-agents does (github.com/apoorvdarshan/macbook-24x7-agents).
///
/// Turning it on saves the sleep settings it is about to change (`AlwaysOnRestorePoint`), then asks for the user's
/// password once to run `pmset` (`AlwaysOnScript`), then starts the lid watcher (`coincide-always-on`), which launchd
/// runs at login until Keep Awake turns off. Turning it off puts back exactly the saved values. A cancelled prompt or
/// a failed step leaves the Mac as it was: the script undoes its own changes, and the setting is saved only after it.
///
/// With "Sleep normally on battery" the battery helper (`coincide-power-helper`) also runs, a launchd daemon that
/// switches `disablesleep` with the power source, so the Mac sleeps on battery and stays awake on the charger. It is
/// registered only while that option and Keep Awake are both on, and gone otherwise.
@MainActor
@Observable
final class AlwaysOnController {
    static let shared = AlwaysOnController()

    @ObservationIgnored private let store: AppStore
    @ObservationIgnored private let system: AlwaysOnSystem

    /// The live sleep settings, re-read on every refresh so they show changes made outside Coincide.
    private(set) var power: PowerSettings?
    private(set) var service: AlwaysOnServiceState = .notRegistered
    private(set) var batteryHelper: AlwaysOnServiceState = .notRegistered
    private(set) var standalone: StandaloneAlwaysOn?
    private(set) var hasLid = true
    private(set) var isWorking = false
    /// What went wrong last, or why Keep Awake is still on.
    private(set) var problem: String?

    init(store: AppStore = .shared, system: AlwaysOnSystem = MacAlwaysOnSystem()) {
        self.store = store
        self.system = system
    }

    var settings: AlwaysOnSettings { store.settings.alwaysOn }
    private var restorePointFile: URL { AlwaysOnIdentity.restorePointFile(in: store.directory) }
    private var audioStateFile: URL { AlwaysOnIdentity.audioStateFile(in: store.directory) }

    var hasBattery: Bool { power?.hasBattery ?? true }
    /// The battery helper switches sleep only while Keep Awake and "Sleep normally on battery" are on, on a laptop.
    private var wantsBatteryHelper: Bool { settings.enabled && settings.sleepsOnBattery && hasBattery }
    private var batteryHelperIsRegistered: Bool { batteryHelper == .running || batteryHelper == .needsApproval }

    /// On but the Mac's settings no longer keep it awake, for example after `pmset` was run by hand. While the battery
    /// helper waits for approval sleep stays disabled on battery, which its own row explains.
    var isOutOfStep: Bool {
        guard settings.enabled, let power else { return false }
        if wantsBatteryHelper, batteryHelper != .running { return power.chargerSleep != 0 }
        return !power.isAwake(sleepsOnBattery: wantsBatteryHelper)
    }

    // MARK: Launch and refresh

    /// Starts the lid watcher and battery helper again if launchd lost them, for example after Coincide moved, and
    /// removes a battery helper nothing needs. Never asks for a password.
    func startAtLaunch() {
        Task {
            await refresh()
            if settings.enabled, hasLid, service == .notRegistered { registerWatcher() }
            if wantsBatteryHelper, batteryHelper == .notRegistered {
                registerBatteryHelper()
            } else if !wantsBatteryHelper, batteryHelperIsRegistered {
                try? await system.unregisterBatteryHelper()
                batteryHelper = system.batteryHelperState
            }
        }
    }

    func refresh() async {
        hasLid = system.hasLid
        service = system.serviceState
        batteryHelper = system.batteryHelperState
        standalone = system.findStandalone()
        power = await system.readPower()
    }

    func openLoginItems() { system.openLoginItems() }

    // MARK: Turning it on and off

    func setEnabled(_ on: Bool) async {
        guard !isWorking, on != settings.enabled else { return }
        isWorking = true
        defer { isWorking = false }
        problem = nil
        if on { await turnOn() } else { await turnOff() }
        await refresh()
    }

    private func turnOn() async {
        guard standalone == nil else {
            problem = String(localized: "Switch from macbook-24x7-agents first, so only one lid watcher runs.")
            return
        }
        guard let power = await system.readPower() else {
            problem = String(localized: "Coincide couldn’t read this Mac’s sleep settings.")
            return
        }
        let earlier = AlwaysOnRestorePoint.load(from: restorePointFile)
        let point = (earlier ?? AlwaysOnRestorePoint())
            .adding(AlwaysOnRestorePoint(sleepDisabled: power.sleepDisabled, chargerSleep: power.chargerSleep))
        do {
            let script = try AlwaysOnScript.apply(current: power)
            // Saved before anything changes, so the values survive a crash between here and turning it off.
            try point.save(to: restorePointFile)
            let result = await system.runAsAdministrator(script, prompt: Self.turnOnPrompt)
            guard result == .succeeded else {
                // Nothing changed: the restore point goes back to what it was.
                if let earlier { try? earlier.save(to: restorePointFile) } else { try? FileManager.default.removeItem(at: restorePointFile) }
                if case .failed(let reason) = result { problem = String(localized: "Keep Awake didn’t turn on: \(reason)") }
                return
            }
        } catch {
            problem = String(localized: "Keep Awake didn’t turn on: \(error.localizedDescription)")
            return
        }
        store.updateSettings { $0.alwaysOn.enabled = true }
        registerWatcher()
        if wantsBatteryHelper { registerBatteryHelper() }
    }

    private func turnOff() async {
        // First, so it can't switch sleep again after the saved values are back.
        if batteryHelperIsRegistered {
            do {
                try await system.unregisterBatteryHelper()
            } catch {
                problem = String(localized: "Keep Awake is still on: \(error.localizedDescription)")
                return
            }
        }
        let point = AlwaysOnRestorePoint.load(from: restorePointFile)
            // Lost: put back macOS's own defaults rather than leave sleep disabled.
            ?? (power?.sleepDisabled == true ? .macOSDefaults(hasBattery: power?.hasBattery ?? true) : AlwaysOnRestorePoint())
        if !point.isEmpty {
            do {
                switch await system.runAsAdministrator(try AlwaysOnScript.restore(point), prompt: Self.turnOffPrompt) {
                case .succeeded: break
                case .cancelled:
                    problem = String(localized: "Keep Awake is still on. macOS needs your password to turn sleep back on.")
                    if wantsBatteryHelper { registerBatteryHelper() }
                    return
                case .failed(let reason):
                    problem = String(localized: "Keep Awake is still on: \(reason)")
                    if wantsBatteryHelper { registerBatteryHelper() }
                    return
                }
            } catch {
                problem = String(localized: "Keep Awake is still on: \(error.localizedDescription)")
                if wantsBatteryHelper { registerBatteryHelper() }
                return
            }
        }
        try? FileManager.default.removeItem(at: restorePointFile)
        store.updateSettings { $0.alwaysOn.enabled = false }
        store.flush()
        // The watcher puts back what it muted when launchd stops it; this covers a watcher that isn't running.
        try? await system.unregisterService()
        system.restoreAudio(stateFile: audioStateFile)
    }

    /// The watcher reads the settings file when it starts, so the switch is on disk first.
    private func registerWatcher() {
        guard hasLid else { return }
        store.flush()
        do {
            try system.registerService()
        } catch {
            problem = String(localized: "Sleep is off, but the lid watcher didn’t start: \(error.localizedDescription)")
        }
        service = system.serviceState
    }

    /// macOS asks the user to allow it in Login Items; until then sleep stays disabled on battery too.
    private func registerBatteryHelper() {
        do {
            try system.registerBatteryHelper()
        } catch {
            problem = String(localized: "The battery helper didn’t start: \(error.localizedDescription)")
        }
        batteryHelper = system.batteryHelperState
    }

    /// Asks for the password again to put the settings back in step (see `isOutOfStep`), and starts what isn't running.
    func applyAgain() async {
        guard settings.enabled, !isWorking else { return }
        isWorking = true
        defer { isWorking = false }
        problem = nil
        if let power = await system.readPower(), !power.isAwake(sleepsOnBattery: wantsBatteryHelper) {
            // With the battery helper, it sets disablesleep itself; only the charger's idle sleep is Coincide's.
            if !wantsBatteryHelper || power.chargerSleep != 0 {
                do {
                    let script = try AlwaysOnScript.apply(current: power)
                    if case .failed(let reason) = await system.runAsAdministrator(script, prompt: Self.turnOnPrompt) {
                        problem = String(localized: "Keep Awake didn’t turn on: \(reason)")
                    }
                } catch {
                    problem = String(localized: "Keep Awake didn’t turn on: \(error.localizedDescription)")
                }
            }
        }
        if system.serviceState == .notRegistered { registerWatcher() }
        if wantsBatteryHelper, system.batteryHelperState == .notRegistered { registerBatteryHelper() }
        await refresh()
    }

    // MARK: Options

    /// Display and sound options need no password: the watcher reads them at the next lid change.
    func set(_ option: WritableKeyPath<AlwaysOnSettings, Bool>, _ value: Bool) {
        store.updateSettings { $0.alwaysOn[keyPath: option] = value }
    }

    /// While Keep Awake is on, turning it on starts the battery helper (which macOS asks the user to allow once);
    /// turning it off removes the helper, and asks for the password only if the Mac is on battery with sleep enabled.
    func setSleepsOnBattery(_ value: Bool) async {
        guard !isWorking, value != settings.sleepsOnBattery else { return }
        store.updateSettings { $0.alwaysOn.sleepsOnBattery = value }
        guard settings.enabled, hasBattery else { return }
        isWorking = true
        defer { isWorking = false }
        problem = nil
        if value {
            registerBatteryHelper()
        } else {
            do {
                try await system.unregisterBatteryHelper()
            } catch {
                problem = String(localized: "The battery helper couldn’t be removed: \(error.localizedDescription)")
            }
            // It left sleep enabled if the Mac is on battery: disable it again, as Keep Awake does everywhere else.
            if let power = await system.readPower(), !power.sleepDisabled {
                let script = AlwaysOnScript.sleepDisabled(true, undo: false)
                switch await system.runAsAdministrator(script, prompt: Self.turnOnPrompt) {
                case .succeeded: break
                case .cancelled:
                    problem = String(localized: "The Mac still sleeps on battery until you apply Keep Awake again.")
                case .failed(let reason):
                    problem = String(localized: "The Mac still sleeps on battery: \(reason)")
                }
            }
        }
        await refresh()
    }

    // MARK: macbook-24x7-agents

    /// Replaces a macbook-24x7-agents install with Keep Awake, keeping its options. Its lid watcher, LaunchAgent and
    /// script go; the sleep settings it made stay, and turning Keep Awake off later puts back macOS's defaults, as its
    /// `uninstall.sh` would. Only when the user asks.
    func switchFromStandalone() async {
        guard !isWorking, let install = system.findStandalone() else { return }
        isWorking = true
        problem = nil
        do {
            try await system.removeStandalone(install)
        } catch {
            problem = String(localized: "macbook-24x7-agents couldn’t be removed: \(error.localizedDescription)")
            isWorking = false
            await refresh()
            return
        }
        // A mute it still had to put back is now the watcher's to put back.
        if let text = try? String(contentsOf: install.audioStateFile, encoding: .utf8),
            let muted = Bool(text.trimmingCharacters(in: .whitespacesAndNewlines))
        {
            _ = AlwaysOnAudioState(url: audioStateFile).save(muted)
        }
        try? FileManager.default.removeItem(at: install.audioStateFile)
        try? FileManager.default.removeItem(at: install.audioStateFile.deletingLastPathComponent())
        let power = await system.readPower()
        store.updateSettings {
            $0.alwaysOn.keepDisplaysOff = install.keepsDisplaysOff
            $0.alwaysOn.muteWhileClosed = install.mutesWhileClosed
            $0.alwaysOn.displayOffOnLidClose = true
            // Its install.sh keeps the Mac awake on battery too.
            $0.alwaysOn.sleepsOnBattery = false
        }
        standalone = nil
        isWorking = false
        if let power, power.isAwake(sleepsOnBattery: false) {
            // Its install.sh also turned idle sleep off on battery, which its uninstall.sh puts back.
            do {
                try AlwaysOnRestorePoint.macOSDefaults(hasBattery: power.hasBattery).save(to: restorePointFile)
            } catch {
                problem = String(localized: "Keep Awake didn’t turn on: \(error.localizedDescription)")
                await refresh()
                return
            }
            store.updateSettings { $0.alwaysOn.enabled = true }
            registerWatcher()
            await refresh()
        } else {
            // Its sleep settings were undone already: turn on as usual, which asks for the password.
            await setEnabled(true)
        }
    }

    private static let turnOnPrompt = String(
        localized: "Coincide wants to keep this Mac awake, even with the lid closed, so agents keep working.")
    private static let turnOffPrompt = String(localized: "Coincide wants to turn sleep back on for this Mac.")
}
