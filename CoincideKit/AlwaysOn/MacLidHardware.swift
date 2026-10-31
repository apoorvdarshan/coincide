import CoreAudio
import Foundation
import IOKit

/// The Mac itself, for the lid watcher (and the app, to put back the mute setting when Keep Awake turns off):
/// displays through pmset, sound through CoreAudio, input idle time from the HID system.
public final class MacLidHardware: LidWatcherHardware {
    public init() {}

    public func sleepDisplays() {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/pmset")
        process.arguments = ["displaysleepnow"]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try? process.run()
        process.waitUntilExit()
    }

    public func outputMuted() -> Bool? {
        guard let (device, element) = muteControl() else { return nil }
        var address = Self.muteAddress(element)
        var value: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        guard AudioObjectGetPropertyData(device, &address, 0, nil, &size, &value) == noErr else { return nil }
        return value != 0
    }

    public func setOutputMuted(_ muted: Bool) -> Bool {
        guard let (device, element) = muteControl() else { return false }
        var address = Self.muteAddress(element)
        var value: UInt32 = muted ? 1 : 0
        return AudioObjectSetPropertyData(device, &address, 0, nil, UInt32(MemoryLayout<UInt32>.size), &value) == noErr
    }

    public func secondsSinceInput() -> Double? {
        let system = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("IOHIDSystem"))
        guard system != IO_OBJECT_NULL else { return nil }
        defer { IOObjectRelease(system) }
        // Nanoseconds since the last keyboard or pointer event.
        let value = IORegistryEntryCreateCFProperty(system, "HIDIdleTime" as CFString, kCFAllocatorDefault, 0)?
            .takeRetainedValue()
        guard let nanoseconds = (value as? NSNumber)?.doubleValue else { return nil }
        return nanoseconds / 1_000_000_000
    }

    /// The default output and the element that mutes it: the main one, or the first channel on devices without it.
    private func muteControl() -> (AudioObjectID, AudioObjectPropertyElement)? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice, mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        var device = AudioObjectID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &device) == noErr,
            device != AudioObjectID(kAudioObjectUnknown)
        else { return nil }
        for element in [kAudioObjectPropertyElementMain, 1] {
            var mute = Self.muteAddress(element)
            var settable: DarwinBoolean = false
            if AudioObjectHasProperty(device, &mute), AudioObjectIsPropertySettable(device, &mute, &settable) == noErr,
                settable.boolValue
            {
                return (device, element)
            }
        }
        return nil
    }

    private static func muteAddress(_ element: AudioObjectPropertyElement) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyMute, mScope: kAudioDevicePropertyScopeOutput, mElement: element)
    }
}
