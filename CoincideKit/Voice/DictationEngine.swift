@preconcurrency import AVFAudio
import Foundation

/// A speech-to-text engine for dictation. The composer's `DictationController` captures the microphone and hands each
/// buffer to the engine in the format it asks for; the engine reports partial transcripts when it can and the final
/// transcript when listening stops. Engines are swappable, and tests drive the controller with a fake one.
public protocol DictationEngine: AnyObject, Sendable {
    /// Whether partial transcripts arrive while the user speaks.
    nonisolated var streamsPartials: Bool { get }

    /// Gets ready to listen: checks the permission it needs, downloads speech assets or loads a model. `progress` gets
    /// 0…1 while something downloads.
    func prepare(progress: @escaping @Sendable (Double) -> Void) async throws

    /// The audio format `append(_:)` takes.
    func audioFormat() async throws -> AVAudioFormat

    /// Starts a recognition. `partial` gets the whole transcript so far, each time it changes.
    func begin(partial: @escaping @Sendable (String) -> Void) async throws

    /// Takes captured audio, on the audio thread. Must not block.
    nonisolated func append(_ buffer: AVAudioPCMBuffer)

    /// Stops listening and returns the final transcript.
    func finish() async throws -> String

    /// Stops listening and throws the audio away.
    func cancel() async
}

public enum DictationError: LocalizedError, Equatable, Sendable {
    case microphoneDenied
    case speechRecognitionDenied
    case noMicrophone
    case languageUnavailable(String)
    case modelNotDownloaded
    case recognizerUnavailable
    case nothingHeard
    case failed(String)

    public nonisolated var errorDescription: String? {
        switch self {
        case .microphoneDenied:
            String(localized: "Coincide doesn’t have access to the microphone. Turn it on in System Settings › Privacy & Security › Microphone.")
        case .speechRecognitionDenied:
            String(localized: "Coincide isn’t allowed to use speech recognition. Turn it on in System Settings › Privacy & Security › Speech Recognition.")
        case .noMicrophone: String(localized: "No microphone is connected.")
        case .languageUnavailable(let language):
            String(localized: "On-device recognition isn’t available for \(language) on this Mac. Choose another language or engine in Settings › Voice.")
        case .modelNotDownloaded: String(localized: "Download a Whisper model in Settings › Voice first.")
        case .recognizerUnavailable: String(localized: "Speech recognition isn’t available right now.")
        case .nothingHeard: String(localized: "No speech was heard.")
        case .failed(let message): message
        }
    }

    /// Whether System Settings is where the user fixes it.
    public nonisolated var opensSystemSettings: Bool {
        self == .microphoneDenied || self == .speechRecognitionDenied
    }
}

/// Collects 16 kHz mono samples while the user speaks, then transcribes them all at once: the transcription APIs and
/// Whisper on the Mac. The audio stays in memory and is dropped when the engine finishes.
public final class RecordedDictationEngine: DictationEngine, @unchecked Sendable {
    public nonisolated static let sampleRate = 16_000.0
    /// Ten minutes, which also keeps an upload's WAV under the APIs' 25 MB.
    public nonisolated static let maximumSamples = Int(sampleRate) * 600

    public nonisolated let streamsPartials = false
    private let lock = NSLock()
    private nonisolated(unsafe) var samples: [Float] = []
    private nonisolated(unsafe) var isListening = false
    private let prepareWork: @Sendable (@escaping @Sendable (Double) -> Void) async throws -> Void
    private let transcribe: @Sendable ([Float]) async throws -> String

    /// `transcribe` turns the samples into text; `prepare` readies it, such as by loading a model.
    public nonisolated init(
        prepare: @escaping @Sendable (@escaping @Sendable (Double) -> Void) async throws -> Void = { _ in },
        transcribe: @escaping @Sendable ([Float]) async throws -> String
    ) {
        prepareWork = prepare
        self.transcribe = transcribe
    }

    public func prepare(progress: @escaping @Sendable (Double) -> Void) async throws {
        try await prepareWork(progress)
    }

    public func audioFormat() async throws -> AVAudioFormat {
        guard let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: Self.sampleRate, channels: 1, interleaved: false)
        else { throw DictationError.recognizerUnavailable }
        return format
    }

    public func begin(partial: @escaping @Sendable (String) -> Void) async throws {
        lock.withLock {
            samples = []
            samples.reserveCapacity(Int(Self.sampleRate) * 30)
            isListening = true
        }
    }

    public nonisolated func append(_ buffer: AVAudioPCMBuffer) {
        guard let channel = buffer.floatChannelData?[0] else { return }
        let count = Int(buffer.frameLength)
        lock.withLock {
            guard isListening, samples.count < Self.maximumSamples else { return }
            samples.append(contentsOf: UnsafeBufferPointer(start: channel, count: min(count, Self.maximumSamples - samples.count)))
        }
    }

    /// Whether the recording reached `maximumSamples`.
    public nonisolated var isFull: Bool { lock.withLock { samples.count >= Self.maximumSamples } }

    public func finish() async throws -> String {
        let recorded = lock.withLock {
            isListening = false
            defer { samples = [] }
            return samples
        }
        // Less than a quarter of a second is a slip of the key, not speech.
        guard recorded.count > Int(Self.sampleRate / 4) else { return "" }
        return try await transcribe(recorded)
    }

    public func cancel() async {
        lock.withLock {
            isListening = false
            samples = []
        }
    }
}

/// Transcribes recordings with a transcription API.
public enum TranscriptionAPIEngine {
    public nonisolated static func make(
        provider: TranscriptionProvider, settings: VoiceSettings, keys: VoiceKeyStore = .standard,
        client: TranscriptionClient = TranscriptionClient()
    ) -> RecordedDictationEngine {
        let model = settings.model(for: provider)
        let language = DictationLanguage.isoCode(for: settings.language)
        return RecordedDictationEngine(
            prepare: { _ in
                guard keys.hasKey(for: provider) else { throw TranscriptionAPIError.missingKey(provider) }
            },
            transcribe: { samples in
                guard let key = keys.key(for: provider) else { throw TranscriptionAPIError.missingKey(provider) }
                let wav = WAVEncoder.encode(samples: samples, sampleRate: Int(RecordedDictationEngine.sampleRate))
                return try await client.transcribe(provider: provider, apiKey: key, model: model, languageCode: language, wav: wav)
            })
    }
}
