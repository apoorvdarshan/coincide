// Narrow native C ABI. No device, authorization, asset, or recognizer activity
// occurs until explicit prepare/start. Native callbacks retain only this state.
@preconcurrency import AVFAudio
@preconcurrency import Speech
import Foundation

private let maxSamples = 16_000 * 60
private let maxTextBytes = 1_048_576
private enum SpeechFailure: Error { case unavailable, denied, bounds, cancelled }

@available(macOS 26.0, *)
private final class ModernSpeech: @unchecked Sendable {
    let transcriber: SpeechTranscriber
    var analyzer: SpeechAnalyzer?
    var input: AsyncStream<AnalyzerInput>.Continuation?
    var results: Task<Void, Error>?
    var converter: AVAudioConverter?
    var format: AVAudioFormat?
    let textLock = NSLock()
    var finalized = ""
    var volatile = ""
    var revision: UInt64 = 0
    var invalid = false
    init(_ transcriber: SpeechTranscriber) { self.transcriber = transcriber }
    func begin() async throws {
        guard let format = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: [transcriber]),
              let source = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16_000, channels: 1, interleaved: false),
              let converter = AVAudioConverter(from: source, to: format) else { throw SpeechFailure.unavailable }
        self.format = format
        self.converter = converter
        let analyzer = SpeechAnalyzer(modules: [transcriber])
        let (stream, continuation) = AsyncStream<AnalyzerInput>.makeStream(bufferingPolicy: .bufferingOldest(256))
        self.analyzer = analyzer
        input = continuation
        results = Task { [self] in
            for try await result in transcriber.results {
                let fragment = String(result.text.characters)
                let valid = textLock.withLock {
                    guard fragment.utf8.count <= maxTextBytes else { invalid = true; return false }
                    if result.isFinal { finalized += fragment; volatile = "" } else { volatile = fragment }
                    revision &+= 1
                    if finalized.utf8.count + volatile.utf8.count > maxTextBytes { invalid = true; return false }
                    return true
                }
                if !valid { throw SpeechFailure.bounds }
            }
        }
        try await analyzer.start(inputSequence: stream)
    }
    func append(_ buffer: AVAudioPCMBuffer) throws {
        guard let converter, let format, let input else { throw SpeechFailure.unavailable }
        let capacity = Int(ceil(Double(buffer.frameLength) * format.sampleRate / 16_000)) + 128
        guard capacity > 0, capacity <= 65_536,
              let output = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(capacity)) else { throw SpeechFailure.bounds }
        var supplied = false
        var error: NSError?
        let status = converter.convert(to: output, error: &error) { _, state in
            if supplied { state.pointee = .noDataNow; return nil }
            supplied = true; state.pointee = .haveData; return buffer
        }
        guard error == nil, status != .error else { throw SpeechFailure.unavailable }
        if output.frameLength > 0 {
            switch input.yield(AnalyzerInput(buffer: output)) {
            case .enqueued: break
            case .dropped, .terminated: throw SpeechFailure.bounds
            @unknown default: throw SpeechFailure.unavailable
            }
        }
    }
    func finish() async throws -> String {
        // Flush the resampler tail before terminating the bounded input stream.
        if let converter, let format, let input {
            var drained = false
            for _ in 0..<16 {
                guard let output = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 4096) else { throw SpeechFailure.bounds }
                var error: NSError?
                let status = converter.convert(to: output, error: &error) { _, state in state.pointee = .endOfStream; return nil }
                guard error == nil, status != .error else { throw SpeechFailure.unavailable }
                if output.frameLength > 0 {
                    switch input.yield(AnalyzerInput(buffer: output)) {
                    case .enqueued: break
                    case .dropped, .terminated: throw SpeechFailure.bounds
                    @unknown default: throw SpeechFailure.unavailable
                    }
                }
                if status == .endOfStream || output.frameLength == 0 { drained = true; break }
            }
            if !drained { throw SpeechFailure.bounds }
        }
        input?.finish()
        guard let analyzer else { throw SpeechFailure.unavailable }
        try await analyzer.finalizeAndFinishThroughEndOfInput()
        try await results?.value
        return try textLock.withLock {
            if invalid { throw SpeechFailure.bounds }
            return finalized + volatile
        }
    }
    func cancel() async {
        input?.finish(); results?.cancel()
        if let analyzer { await analyzer.cancelAndFinishNow() }
        _ = try? await results?.value
    }
}

private final class SpeechSession: @unchecked Sendable {
    let lock = NSLock()
    let locale: Locale
    var phase: Int32 = 0 // new, preparing, ready, starting, listening, finishing, complete, failed, cancelled
    var code: Int32 = 0
    var returned = true
    var abandoned = false
    var released = false
    var cancelled = false
    var progress: Double = 0
    var samples = 0
    var owner: Task<Void, Never>?
    var modern: AnyObject?
    var recognizer: SFSpeechRecognizer?
    var request: SFSpeechAudioBufferRecognitionRequest?
    var recognition: SFSpeechRecognitionTask?
    var fallbackEnded = false
    var text = ""
    var revision: UInt64 = 0
    init(_ language: String) { locale = language == "auto" ? Locale.current : Locale(identifier: language) }
    func check() throws { if lock.withLock({ cancelled }) || Task.isCancelled { throw SpeechFailure.cancelled } }
    func launch(_ phase: Int32, action: @escaping @Sendable (SpeechSession) async throws -> Void) -> Int32 {
        let admitted = lock.withLock { () -> Bool in
            guard returned, !cancelled, !abandoned else { return false }
            returned = false; self.phase = phase; code = 0; return true
        }
        guard admitted else { return 0 }
        let work = Task { [self] in
            do { try check(); try await action(self); try check() }
            catch {
                lock.withLock {
                    self.phase = cancelled ? 8 : 7
                    switch error {
                    case SpeechFailure.denied: code = 2
                    case SpeechFailure.bounds: code = 3
                    case SpeechFailure.cancelled: code = 4
                    default: code = 1
                    }
                }
                await cancelNative()
            }
        }
        lock.withLock { owner = work }
        Task { [self] in
            await work.value // actual task-return receipt, distinct from cancellation request
            lock.withLock { returned = true; owner = nil }
            releaseIfAbandoned()
        }
        return 1
    }
    func prepare() async throws {
        if #available(macOS 26.0, *), SpeechTranscriber.isAvailable,
           let supported = await SpeechTranscriber.supportedLocale(equivalentTo: locale) {
            try check()
            let transcriber = SpeechTranscriber(locale: supported, preset: .progressiveTranscription)
            if let installation = try await AssetInventory.assetInstallationRequest(supporting: [transcriber]) {
                let watcher = Task { [self] in
                    while !Task.isCancelled {
                        lock.withLock { progress = min(1, max(0, installation.progress.fractionCompleted)) }
                        do { try await Task.sleep(for: .milliseconds(100)) } catch { return }
                    }
                }
                do { try await installation.downloadAndInstall() }
                catch { watcher.cancel(); await watcher.value; throw error }
                watcher.cancel(); await watcher.value
            }
            try check()
            lock.withLock { modern = ModernSpeech(transcriber); progress = 1; phase = 2 }
            return
        }
        guard let recognizer = SFSpeechRecognizer(locale: locale), recognizer.supportsOnDeviceRecognition else { throw SpeechFailure.unavailable }
        let authorized: Bool
        switch SFSpeechRecognizer.authorizationStatus() {
        case .authorized: authorized = true
        case .notDetermined:
            authorized = await withCheckedContinuation { continuation in
                SFSpeechRecognizer.requestAuthorization { continuation.resume(returning: $0 == .authorized) }
            }
        default: authorized = false
        }
        try check()
        guard authorized else { throw SpeechFailure.denied }
        guard recognizer.isAvailable else { throw SpeechFailure.unavailable }
        lock.withLock { self.recognizer = recognizer; progress = 1; phase = 2 }
    }
    func begin() async throws {
        if #available(macOS 26.0, *), let modern = lock.withLock({ modern as? ModernSpeech }) {
            try await modern.begin(); try check(); lock.withLock { phase = 4 }; return
        }
        guard let recognizer = lock.withLock({ recognizer }) else { throw SpeechFailure.unavailable }
        let request = SFSpeechAudioBufferRecognitionRequest()
        request.requiresOnDeviceRecognition = true
        request.shouldReportPartialResults = true
        request.addsPunctuation = true
        let recognition = recognizer.recognitionTask(with: request) { [self] result, error in
            lock.withLock {
                if let result {
                    let value = result.bestTranscription.formattedString
                    if value.utf8.count <= maxTextBytes { if text != value { text = value; revision &+= 1 } } else { code = 3; phase = 7 }
                    if result.isFinal { fallbackEnded = true }
                }
                // Match Swift's final-or-no-speech behavior: a terminal native
                // error ends the stream; whatever bounded text was heard stands.
                if error != nil { fallbackEnded = true }
            }
        }
        lock.withLock { self.request = request; self.recognition = recognition; phase = 4 }
        try check()
    }
    func append(_ input: UnsafePointer<Float>, _ count: Int) -> Int32 {
        let admitted = lock.withLock { () -> Bool in
            guard phase == 4, returned, !cancelled, count > 0, count <= 4096, samples <= maxSamples - count else { return false }
            samples += count; return true
        }
        guard admitted, let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16_000, channels: 1, interleaved: false),
              let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(count)), let output = buffer.floatChannelData?[0] else { return 0 }
        for index in 0..<count { let value = input[index]; guard value.isFinite, abs(value) <= 1 else { return 0 }; output[index] = value }
        buffer.frameLength = AVAudioFrameCount(count)
        do {
            if #available(macOS 26.0, *), let modern = lock.withLock({ modern as? ModernSpeech }) { try modern.append(buffer) }
            else { guard let request = lock.withLock({ request }) else { return 0 }; request.append(buffer) }
            return 1
        } catch { lock.withLock { phase = 7; code = 3 }; return 0 }
    }
    func finish() async throws {
        if #available(macOS 26.0, *), let modern = lock.withLock({ modern as? ModernSpeech }) {
            let value = try await modern.finish(); try check()
            guard value.utf8.count <= maxTextBytes else { throw SpeechFailure.bounds }
            lock.withLock { text = value; phase = 6 }; return
        }
        lock.withLock { request }?.endAudio()
        while true {
            try check()
            let done = lock.withLock { fallbackEnded && (recognition?.state == .completed) }
            if done { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        try check()
        try lock.withLock { if code != 0 { throw SpeechFailure.unavailable }; phase = 6 }
    }
    func cancelNative() async {
        lock.withLock { request }?.endAudio()
        lock.withLock { recognition }?.cancel()
        if #available(macOS 26.0, *), let modern = lock.withLock({ modern as? ModernSpeech }) { await modern.cancel() }
        while let task = lock.withLock({ recognition }), task.state != .completed {
            try? await Task.sleep(for: .milliseconds(10))
        }
    }
    func cancel() {
        let (work, spawn) = lock.withLock { () -> (Task<Void, Never>?, Bool) in
            guard !cancelled else { return (nil, false) }
            cancelled = true
            let terminal = returned && phase >= 6
            phase = 8
            if terminal { return (nil, false) }
            if let owner { return (owner, false) }
            returned = false
            return (nil, true)
        }
        work?.cancel()
        if spawn {
            Task { [self] in await cancelNative(); lock.withLock { returned = true }; releaseIfAbandoned() }
        }
    }
    func releaseIfAbandoned() {
        let release = lock.withLock { () -> Bool in guard abandoned, returned, !released else { return false }; released = true; return true }
        if release { Unmanaged.passUnretained(self).release() }
    }
}
@_cdecl("cc_voice_speech_create")
func speechCreate(_ language: UnsafePointer<UInt8>?, _ length: Int) -> UnsafeMutableRawPointer? {
    guard let language, length > 0, length <= 64,
          let value = String(bytes: UnsafeBufferPointer(start: language, count: length), encoding: .utf8),
          !value.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) else { return nil }
    return Unmanaged.passRetained(SpeechSession(value)).toOpaque()
}
private func session(_ raw: UnsafeMutableRawPointer) -> SpeechSession { Unmanaged<SpeechSession>.fromOpaque(raw).takeUnretainedValue() }
@_cdecl("cc_voice_speech_prepare")
func speechPrepare(_ raw: UnsafeMutableRawPointer) -> Int32 { session(raw).launch(1) { try await $0.prepare() } }
@_cdecl("cc_voice_speech_begin")
func speechBegin(_ raw: UnsafeMutableRawPointer) -> Int32 { let value = session(raw); guard value.lock.withLock({ value.phase == 2 }) else { return 0 }; return value.launch(3) { try await $0.begin() } }
@_cdecl("cc_voice_speech_append")
func speechAppend(_ raw: UnsafeMutableRawPointer, _ samples: UnsafePointer<Float>?, _ count: Int) -> Int32 { guard let samples else { return 0 }; return session(raw).append(samples, count) }
@_cdecl("cc_voice_speech_finish")
func speechFinish(_ raw: UnsafeMutableRawPointer) -> Int32 { let value = session(raw); guard value.lock.withLock({ value.phase == 4 }) else { return 0 }; return value.launch(5) { try await $0.finish() } }
@_cdecl("cc_voice_speech_status")
func speechStatus(_ raw: UnsafeMutableRawPointer, _ phase: UnsafeMutablePointer<Int32>, _ returned: UnsafeMutablePointer<Int32>, _ code: UnsafeMutablePointer<Int32>, _ progress: UnsafeMutablePointer<Double>) {
    let value = session(raw); value.lock.withLock { phase.pointee = value.phase; returned.pointee = value.returned ? 1 : 0; code.pointee = value.code; progress.pointee = value.progress }
}
@_cdecl("cc_voice_speech_revision")
func speechRevision(_ raw: UnsafeMutableRawPointer) -> UInt64 {
    let value = session(raw)
    if #available(macOS 26.0, *), let modern = value.lock.withLock({ value.modern as? ModernSpeech }) { return modern.textLock.withLock { modern.revision } }
    return value.lock.withLock { value.revision }
}
@_cdecl("cc_voice_speech_partial")
func speechPartial(_ raw: UnsafeMutableRawPointer, _ output: UnsafeMutablePointer<UInt8>?, _ capacity: Int) -> Int {
    let value = session(raw)
    let snapshot: String
    if #available(macOS 26.0, *), let modern = value.lock.withLock({ value.modern as? ModernSpeech }) {
        snapshot = modern.textLock.withLock { modern.finalized + modern.volatile }
    } else { snapshot = value.lock.withLock { value.text } }
    guard value.lock.withLock({ !value.cancelled && value.phase >= 4 && value.phase <= 6 }), snapshot.utf8.count <= maxTextBytes else { return -1 }
    let bytes = Array(snapshot.utf8)
    guard let output, capacity >= bytes.count else { return bytes.count }
    for index in bytes.indices { output[index] = bytes[index] }
    return bytes.count
}
@_cdecl("cc_voice_speech_text")
func speechText(_ raw: UnsafeMutableRawPointer, _ output: UnsafeMutablePointer<UInt8>?, _ capacity: Int) -> Int {
    let value = session(raw)
    return value.lock.withLock {
        guard value.phase == 6, value.returned, !value.cancelled else { return -1 }
        let bytes = Array(value.text.utf8); guard bytes.count <= maxTextBytes else { return -1 }
        guard let output, capacity >= bytes.count else { return bytes.count }
        for index in bytes.indices { output[index] = bytes[index] }; return bytes.count
    }
}
@_cdecl("cc_voice_speech_cancel")
func speechCancel(_ raw: UnsafeMutableRawPointer) { session(raw).cancel() }
@_cdecl("cc_voice_speech_release")
func speechRelease(_ raw: UnsafeMutableRawPointer) {
    let value = session(raw); value.cancel(); value.lock.withLock { value.abandoned = true }; value.releaseIfAbandoned()
}
