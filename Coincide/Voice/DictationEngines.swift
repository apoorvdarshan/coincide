@preconcurrency import AVFAudio
import CoincideKit
import Foundation
@preconcurrency import WhisperKit

/// Apple's on-device recognition as a `DictationEngine`.
nonisolated final class AppleDictationEngine: DictationEngine, @unchecked Sendable {
    let streamsPartials = true
    private let recognizer: AppleSpeechRecognizer

    init(locale: Locale) {
        recognizer = AppleSpeechRecognizer(locale: locale)
    }

    func prepare(progress: @escaping @Sendable (Double) -> Void) async throws {
        do {
            try await recognizer.prepare(progress: progress)
        } catch let failure as AppleSpeechRecognizer.Failure {
            switch failure {
            case .languageUnavailable(let language): throw DictationError.languageUnavailable(language)
            case .notAuthorized: throw DictationError.speechRecognitionDenied
            case .unavailable: throw DictationError.recognizerUnavailable
            }
        }
    }

    func audioFormat() async throws -> AVAudioFormat {
        guard let format = await recognizer.audioFormat() else { throw DictationError.recognizerUnavailable }
        return format
    }

    func begin(partial: @escaping @Sendable (String) -> Void) async throws { try await recognizer.begin(partial: partial) }
    func append(_ buffer: AVAudioPCMBuffer) { recognizer.append(buffer) }
    func finish() async throws -> String { try await recognizer.finish() }
    func cancel() async { await recognizer.cancel() }
}

/// Whisper on this Mac through WhisperKit, with a model from Settings › Voice. Works offline: the model's folder holds
/// its tokenizer, so WhisperKit never downloads anything. A loaded model is kept for the next dictation.
actor WhisperKitRunner {
    static let shared = WhisperKitRunner()

    private var pipeline: WhisperKit?
    private var loadedFolder: URL?

    func load(folder: URL) async throws {
        guard loadedFolder != folder || pipeline == nil else { return }
        pipeline = nil
        loadedFolder = nil
        let config = WhisperKitConfig(
            modelFolder: folder.path, tokenizerFolder: folder, verbose: false, logLevel: .none, prewarm: false, load: true,
            download: false)
        pipeline = try await WhisperKit(config)
        loadedFolder = folder
    }

    func transcribe(_ samples: [Float], languageCode: String?) async throws -> String {
        guard let pipeline else { throw DictationError.modelNotDownloaded }
        let options = DecodingOptions(
            task: .transcribe, language: languageCode, temperature: 0, usePrefillPrompt: languageCode != nil,
            detectLanguage: languageCode == nil, skipSpecialTokens: true, withoutTimestamps: true)
        let results = try await pipeline.transcribe(audioArray: samples, decodeOptions: options)
        return results.map(\.text).joined(separator: " ").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Frees the model, such as after it's deleted.
    func unload() {
        pipeline = nil
        loadedFolder = nil
    }
}

enum DictationEngines {
    /// The engine Settings › Voice chose.
    @MainActor
    static func make(settings: VoiceSettings, models: WhisperModelManager) -> any DictationEngine {
        switch settings.engine {
        case .apple:
            return AppleDictationEngine(locale: DictationLanguage.appleLocale(for: settings.language))
        case .openAI, .groq:
            let provider = TranscriptionProvider(engine: settings.engine) ?? .openAI
            return TranscriptionAPIEngine.make(provider: provider, settings: settings)
        case .whisper:
            let folder = WhisperModel.model(id: settings.whisperModel).flatMap { models.folder(of: $0) }
            let language = DictationLanguage.isoCode(for: settings.language)
            return RecordedDictationEngine(
                prepare: { _ in
                    guard let folder else { throw DictationError.modelNotDownloaded }
                    try await WhisperKitRunner.shared.load(folder: folder)
                },
                transcribe: { samples in
                    try await WhisperKitRunner.shared.transcribe(samples, languageCode: language)
                })
        }
    }
}
