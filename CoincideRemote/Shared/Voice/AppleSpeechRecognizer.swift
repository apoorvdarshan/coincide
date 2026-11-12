@preconcurrency import AVFAudio
import Foundation
@preconcurrency import Speech

/// Apple's on-device speech recognition, for dictation in Coincide and Coincide Remote. It uses `SpeechAnalyzer` with
/// `SpeechTranscriber`, downloading the language's assets through `AssetInventory` the first time, and falls back to
/// `SFSpeechRecognizer` with on-device recognition required where `SpeechTranscriber` isn't available. Audio never
/// leaves the device.
nonisolated final class AppleSpeechRecognizer: @unchecked Sendable {
    enum Failure: LocalizedError, Equatable {
        case languageUnavailable(String)
        case notAuthorized
        case unavailable

        var errorDescription: String? {
            switch self {
            case .languageUnavailable(let language):
                String(localized: "On-device recognition isn’t available for \(language). Choose another language.")
            case .notAuthorized:
                String(localized: "Speech recognition isn’t allowed. Turn it on in Settings › Privacy & Security › Speech Recognition.")
            case .unavailable: String(localized: "Speech recognition isn’t available right now.")
            }
        }
    }

    let locale: Locale
    private let lock = NSLock()
    // SpeechAnalyzer
    private var transcriber: SpeechTranscriber?
    private var analyzer: SpeechAnalyzer?
    private var input: AsyncStream<AnalyzerInput>.Continuation?
    private var results: Task<Void, Error>?
    // SFSpeechRecognizer
    private var recognizer: SFSpeechRecognizer?
    private var request: SFSpeechAudioBufferRecognitionRequest?
    private var task: SFSpeechRecognitionTask?
    private var fallbackDone: CheckedContinuation<String, Error>?
    /// The older recognizer sent its last result or stopped.
    private var fallbackEnded = false
    // Transcript
    private var finalized = ""
    private var volatile = ""

    init(locale: Locale) {
        self.locale = locale
    }

    private var languageName: String {
        Locale.current.localizedString(forIdentifier: locale.identifier) ?? locale.identifier
    }

    /// Picks the recognizer and gets its assets, reporting a download's progress 0…1.
    func prepare(progress: @escaping @Sendable (Double) -> Void) async throws {
        if SpeechTranscriber.isAvailable, let supported = await SpeechTranscriber.supportedLocale(equivalentTo: locale) {
            let transcriber = SpeechTranscriber(locale: supported, preset: .progressiveTranscription)
            if let installation = try await AssetInventory.assetInstallationRequest(supporting: [transcriber]) {
                let watcher = Task {
                    while !Task.isCancelled {
                        progress(installation.progress.fractionCompleted)
                        try? await Task.sleep(for: .milliseconds(200))
                    }
                }
                defer { watcher.cancel() }
                try await installation.downloadAndInstall()
                progress(1)
            }
            lock.withLock { self.transcriber = transcriber }
            return
        }
        // The older recognizer, kept on the device.
        guard let recognizer = SFSpeechRecognizer(locale: locale), recognizer.supportsOnDeviceRecognition else {
            throw Failure.languageUnavailable(languageName)
        }
        guard await Self.requestAuthorization() else { throw Failure.notAuthorized }
        guard recognizer.isAvailable else { throw Failure.unavailable }
        lock.withLock { self.recognizer = recognizer }
    }

    /// Asks for speech recognition, which only the older recognizer needs.
    static func requestAuthorization() async -> Bool {
        switch SFSpeechRecognizer.authorizationStatus() {
        case .authorized: return true
        case .denied, .restricted: return false
        case .notDetermined:
            return await withCheckedContinuation { continuation in
                SFSpeechRecognizer.requestAuthorization { continuation.resume(returning: $0 == .authorized) }
            }
        @unknown default: return false
        }
    }

    func audioFormat() async -> AVAudioFormat? {
        if let transcriber = lock.withLock({ transcriber }) {
            return await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: [transcriber])
        }
        return AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16_000, channels: 1, interleaved: false)
    }

    /// Starts recognizing; `partial` gets the whole transcript so far whenever it changes.
    func begin(partial: @escaping @Sendable (String) -> Void) async throws {
        lock.withLock {
            finalized = ""
            volatile = ""
            fallbackEnded = false
        }
        if let transcriber = lock.withLock({ transcriber }) {
            let analyzer = SpeechAnalyzer(modules: [transcriber])
            let (stream, continuation) = AsyncStream<AnalyzerInput>.makeStream()
            let results = Task { [weak self] in
                for try await result in transcriber.results {
                    guard let self else { return }
                    let text = String(result.text.characters)
                    let transcript = self.lock.withLock {
                        if result.isFinal {
                            self.finalized += text
                            self.volatile = ""
                        } else {
                            self.volatile = text
                        }
                        return self.finalized + self.volatile
                    }
                    partial(transcript)
                }
            }
            lock.withLock {
                self.analyzer = analyzer
                input = continuation
                self.results = results
            }
            try await analyzer.start(inputSequence: stream)
            return
        }
        guard let recognizer = lock.withLock({ recognizer }) else { throw Failure.unavailable }
        let request = SFSpeechAudioBufferRecognitionRequest()
        request.requiresOnDeviceRecognition = true
        request.shouldReportPartialResults = true
        request.addsPunctuation = true
        let task = recognizer.recognitionTask(with: request) { [weak self] result, error in
            guard let self else { return }
            if let result {
                let text = result.bestTranscription.formattedString
                lock.withLock { self.finalized = text }
                partial(text)
                if result.isFinal { endFallback() }
            } else if error != nil {
                // Most often "no speech detected"; what was heard so far stands.
                endFallback()
            }
        }
        lock.withLock {
            self.request = request
            self.task = task
        }
    }

    func append(_ buffer: AVAudioPCMBuffer) {
        let (input, request) = lock.withLock { (self.input, self.request) }
        if let input {
            input.yield(AnalyzerInput(buffer: buffer))
        } else {
            request?.append(buffer)
        }
    }

    /// Stops listening and returns the final transcript.
    func finish() async throws -> String {
        let (analyzer, input, results, request) = lock.withLock { (self.analyzer, self.input, self.results, self.request) }
        if let analyzer {
            input?.finish()
            try await analyzer.finalizeAndFinishThroughEndOfInput()
            _ = try? await results?.value
            return lock.withLock {
                defer { reset() }
                return finalized + volatile
            }
        }
        guard let request else { return "" }
        let text = try await withCheckedThrowingContinuation { continuation in
            let current: String? = lock.withLock {
                guard !fallbackEnded else { return finalized }
                fallbackDone = continuation
                return nil
            }
            if let current { continuation.resume(returning: current) }
            request.endAudio()
        }
        lock.withLock { reset() }
        return text
    }

    func cancel() async {
        let (analyzer, input, results, task) = lock.withLock { (self.analyzer, self.input, self.results, self.task) }
        input?.finish()
        results?.cancel()
        task?.cancel()
        if let analyzer { await analyzer.cancelAndFinishNow() }
        lock.withLock { finalized = "" }
        endFallback()
        lock.withLock { reset() }
    }

    private func endFallback() {
        let (continuation, text) = lock.withLock {
            fallbackEnded = true
            defer { fallbackDone = nil }
            return (fallbackDone, finalized)
        }
        continuation?.resume(returning: text)
    }

    /// Call with `lock` held.
    private func reset() {
        analyzer = nil
        input = nil
        results = nil
        request = nil
        task = nil
        fallbackDone = nil
    }
}
