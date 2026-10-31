import AppKit
import AudioToolbox

/// The sound of an appshot being taken. Tests replace it, so no sound plays.
@MainActor
protocol AppshotSoundPlaying: AnyObject {
    func playCapture()
}

/// The sound macOS makes for a screenshot, played as a system sound: at the alert volume, through the device chosen
/// for sound effects, and not at all while "Play user interface sound effects" is off (System Settings › Sound), the
/// way the system's own screenshots behave.
final class AppshotShutterSound: AppshotSoundPlaying {
    private static let systemSounds = "/System/Library/Components/CoreAudio.component/Contents/SharedSupport/SystemSounds/system/"
    /// The screenshot sound, then older and plainer ones, for a macOS that moved it.
    static let candidates = [
        systemSounds + "Screen Capture.aif", systemSounds + "Grab.aif", systemSounds + "Shutter.aif",
        "/System/Library/Sounds/Tink.aiff",
    ]

    private var soundID: SystemSoundID?

    func playCapture() {
        guard let soundID = soundID ?? load() else { return }
        AudioServicesPlaySystemSound(soundID)
    }

    /// Registered once and kept: disposing of a system sound while it plays cuts it off.
    private func load() -> SystemSoundID? {
        for path in Self.candidates where FileManager.default.fileExists(atPath: path) {
            var id: SystemSoundID = 0
            if AudioServicesCreateSystemSoundID(URL(fileURLWithPath: path) as CFURL, &id) == noErr {
                soundID = id
                return id
            }
        }
        return nil
    }
}
