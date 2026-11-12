@preconcurrency import AVFAudio
import Foundation

#if os(macOS)
import CoreAudio
#endif

/// The microphone, for dictation: AVAudioEngine's input, converted to the format the speech engine asks for, with a
/// level for the composer's meter. Audio only passes through memory; nothing is written to disk.
///
/// Shared by Coincide and Coincide Remote. On the Mac the input can be a chosen device (`deviceUID`); on iOS it's the
/// audio session's.
nonisolated final class AudioCapture: @unchecked Sendable {
    private let engine = AVAudioEngine()
    private let lock = NSLock()
    private var running = false

    /// Starts capturing. `sink` gets buffers in `format` and `level` 0…1 (both on the audio thread).
    func start(
        deviceUID: String?, format: AVAudioFormat, sink: @escaping @Sendable (AVAudioPCMBuffer) -> Void,
        level: @escaping @Sendable (Float) -> Void
    ) throws {
        stop()
        #if os(iOS)
        let session = AVAudioSession.sharedInstance()
        try session.setCategory(.record, mode: .measurement, options: [.duckOthers])
        try session.setActive(true, options: .notifyOthersOnDeactivation)
        #endif
        let input = engine.inputNode
        #if os(macOS)
        if let deviceUID, let device = Self.deviceID(forUID: deviceUID), let unit = input.audioUnit {
            var id = device
            AudioUnitSetProperty(
                unit, kAudioOutputUnitProperty_CurrentDevice, kAudioUnitScope_Global, 0, &id, UInt32(MemoryLayout<AudioDeviceID>.size))
        }
        #endif
        let inputFormat = input.outputFormat(forBus: 0)
        guard inputFormat.sampleRate > 0, inputFormat.channelCount > 0 else { throw AudioCaptureError.noInput }
        guard let converter = AVAudioConverter(from: inputFormat, to: format) else { throw AudioCaptureError.unsupportedFormat }
        let ratio = format.sampleRate / inputFormat.sampleRate
        input.installTap(onBus: 0, bufferSize: 2048, format: inputFormat) { buffer, _ in
            level(Self.level(of: buffer))
            let capacity = AVAudioFrameCount(Double(buffer.frameLength) * ratio) + 32
            guard let converted = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: capacity) else { return }
            nonisolated(unsafe) var supplied = false
            var error: NSError?
            converter.convert(to: converted, error: &error) { _, status in
                if supplied {
                    status.pointee = .noDataNow
                    return nil
                }
                supplied = true
                status.pointee = .haveData
                return buffer
            }
            if error == nil, converted.frameLength > 0 { sink(converted) }
        }
        engine.prepare()
        do {
            try engine.start()
        } catch {
            input.removeTap(onBus: 0)
            throw error
        }
        lock.withLock { running = true }
    }

    func stop() {
        let wasRunning = lock.withLock {
            defer { running = false }
            return running
        }
        guard wasRunning else { return }
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        #if os(iOS)
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        #endif
    }

    /// The buffer's loudness on a 0…1 scale: its RMS in decibels, from -50 dB (silence) to 0.
    static func level(of buffer: AVAudioPCMBuffer) -> Float {
        guard let channel = buffer.floatChannelData?[0], buffer.frameLength > 0 else { return 0 }
        var sum: Float = 0
        let count = Int(buffer.frameLength)
        for index in 0..<count { sum += channel[index] * channel[index] }
        let rms = (sum / Float(count)).squareRoot()
        let decibels = 20 * log10(max(rms, 0.000_001))
        return max(0, min(1, (decibels + 50) / 50))
    }

    #if os(macOS)
    private static func deviceID(forUID uid: String) -> AudioDeviceID? {
        AudioInputDevices.all().first { $0.uid == uid }?.id
    }
    #endif
}

nonisolated enum AudioCaptureError: LocalizedError {
    case noInput
    case unsupportedFormat

    var errorDescription: String? {
        switch self {
        case .noInput: String(localized: "No microphone is available.")
        case .unsupportedFormat: String(localized: "The microphone’s audio format isn’t supported.")
        }
    }
}

#if os(macOS)
/// The Mac's audio input devices, for Settings › Voice › Microphone.
nonisolated struct AudioInputDevices {
    struct Device: Hashable, Identifiable {
        let id: AudioDeviceID
        let uid: String
        let name: String
    }

    static func all() -> [Device] {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size) == noErr else { return [] }
        var ids = [AudioDeviceID](repeating: 0, count: Int(size) / MemoryLayout<AudioDeviceID>.size)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &ids) == noErr else { return [] }
        return ids.compactMap { id in
            guard hasInput(id), let uid = string(id, kAudioDevicePropertyDeviceUID), let name = string(id, kAudioObjectPropertyName) else {
                return nil
            }
            return Device(id: id, uid: uid, name: name)
        }
    }

    private static func hasInput(_ id: AudioDeviceID) -> Bool {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyStreamConfiguration, mScope: kAudioDevicePropertyScopeInput, mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(id, &address, 0, nil, &size) == noErr, size > 0 else { return false }
        let list = UnsafeMutableRawPointer.allocate(byteCount: Int(size), alignment: MemoryLayout<AudioBufferList>.alignment)
        defer { list.deallocate() }
        guard AudioObjectGetPropertyData(id, &address, 0, nil, &size, list) == noErr else { return false }
        let buffers = UnsafeMutableAudioBufferListPointer(list.assumingMemoryBound(to: AudioBufferList.self))
        return buffers.contains { $0.mNumberChannels > 0 }
    }

    private static func string(_ id: AudioDeviceID, _ selector: AudioObjectPropertySelector) -> String? {
        var address = AudioObjectPropertyAddress(
            mSelector: selector, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        var value: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        guard AudioObjectGetPropertyData(id, &address, 0, nil, &size, &value) == noErr, let value else { return nil }
        return value.takeRetainedValue() as String
    }
}
#endif
