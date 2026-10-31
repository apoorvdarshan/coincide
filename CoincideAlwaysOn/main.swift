import Foundation
import IOKit

// coincide-always-on: the lid watcher for Settings › General › Keep Awake. launchd starts it at login while Keep
// Awake is on (CoincideAgentHost/LaunchAgents/always-on.plist) and the app unregisters it when it turns off. With sleep
// disabled macOS no longer turns the display off when the lid closes, so this does, and optionally keeps displays
// off and sound muted until the lid opens. It waits for the lid's notifications instead of polling, and ticks every
// two seconds only while a closed lid needs it (LidWatcherCore).

/// Connects the core to the lid's notifications, the tick and the settings the app saves. Everything runs on the
/// main queue.
@MainActor
final class LidWatcher {
    /// kIOPMMessageClamshellStateChange: iokit_family_msg(sub_iokit_powermanagement, 0x100).
    nonisolated static let clamshellChanged: UInt32 = 0xE003_4100

    private let directory = AlwaysOnIdentity.dataDirectory
    private let core: LidWatcherCore
    private var port: IONotificationPortRef?
    private var notification: io_object_t = IO_OBJECT_NULL
    private var timer: DispatchSourceTimer?
    private var signals: [DispatchSourceSignal] = []

    init() {
        core = LidWatcherCore(
            hardware: MacLidHardware(), audio: AlwaysOnAudioState(url: AlwaysOnIdentity.audioStateFile(in: directory)),
            settings: AlwaysOnSettings.read(settingsFile: AlwaysOnIdentity.settingsFile(in: directory)))
    }

    func run() -> Never {
        guard core.settings.enabled else { finish() }
        for signal in [SIGTERM, SIGINT] {
            Darwin.signal(signal, SIG_IGN)
            let source = DispatchSource.makeSignalSource(signal: signal, queue: .main)
            source.setEventHandler { [weak self] in MainActor.assumeIsolated { self?.finish() } }
            source.resume()
            signals.append(source)
        }
        // A Mac without a lid has nothing to watch; sleep stays disabled without it.
        guard let closed = ClamshellSensor.isClosed() else { finish() }
        listen()
        core.lid(closed: closed)
        updateTick()
        dispatchMain()
    }

    private func listen() {
        let root = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("IOPMrootDomain"))
        guard root != IO_OBJECT_NULL, let port = IONotificationPortCreate(kIOMainPortDefault) else { return }
        defer { IOObjectRelease(root) }
        self.port = port
        IONotificationPortSetDispatchQueue(port, .main)
        let context = Unmanaged.passUnretained(self).toOpaque()
        IOServiceAddInterestNotification(port, root, kIOGeneralInterest, { context, _, message, _ in
            guard let context, message == LidWatcher.clamshellChanged else { return }
            MainActor.assumeIsolated { Unmanaged<LidWatcher>.fromOpaque(context).takeUnretainedValue().lidChanged() }
        }, context, &notification)
    }

    private func lidChanged() {
        guard reload(), let closed = ClamshellSensor.isClosed() else { return }
        core.lid(closed: closed)
        updateTick()
    }

    /// Settings changed in the app take effect at the next lid change or tick; turned off, the watcher exits.
    private func reload() -> Bool {
        core.settings = AlwaysOnSettings.read(settingsFile: AlwaysOnIdentity.settingsFile(in: directory))
        guard core.settings.enabled else { finish() }
        return true
    }

    private func updateTick() {
        if core.needsTick, timer == nil {
            let timer = DispatchSource.makeTimerSource(queue: .main)
            timer.schedule(deadline: .now() + 2, repeating: 2, leeway: .milliseconds(250))
            timer.setEventHandler { [weak self] in
                MainActor.assumeIsolated {
                    guard let self, self.reload() else { return }
                    self.core.tick()
                    self.updateTick()
                }
            }
            timer.resume()
            self.timer = timer
        } else if !core.needsTick, let timer {
            timer.cancel()
            self.timer = nil
        }
    }

    /// Puts back what it muted. Exits cleanly, so launchd doesn't start it again (KeepAlive SuccessfulExit false).
    private func finish() -> Never {
        core.stop()
        exit(0)
    }
}

LidWatcher().run()
