@preconcurrency import AVFAudio
import AVFoundation
import AppKit
import CoincideKit

/// One composer's dictation: asks for the microphone the first time, readies the engine Settings › Voice chose,
/// captures the microphone into it, and reports levels, partial transcripts and the final one to the composer.
final class DictationController {
    enum State: Equatable {
        case idle
        /// Getting the engine ready; `progress` while speech assets or a model download.
        case preparing(progress: Double?)
        case listening(since: Date)
        /// Waiting for the final transcript, such as from a transcription API.
        case transcribing
    }

    private(set) var state: State = .idle {
        didSet { if state != oldValue { onStateChange?(state) } }
    }

    var onStateChange: ((State) -> Void)?
    /// The microphone's level, 0…1, about 20 times a second while listening.
    var onLevel: ((Float) -> Void)?
    /// The whole transcript so far, from engines that stream.
    var onPartial: ((String) -> Void)?
    /// The final transcript; `send` when Settings › Voice says to send on stop.
    var onFinish: ((_ transcript: String, _ send: Bool) -> Void)?
    /// Dictation was cancelled or failed; partial text should go.
    var onCancel: (() -> Void)?
    var onError: ((DictationError) -> Void)?

    private let store: AppStore
    private let models: WhisperModelManager
    private var engine: (any DictationEngine)?
    private var capture: AudioCapture?
    private var session: Task<Void, Never>?
    private var generation = 0
    private var limitTimer: Timer?

    init(store: AppStore = .shared, models: WhisperModelManager = VoiceServices.shared.whisperModels) {
        self.store = store
        self.models = models
    }

    var isActive: Bool { state != .idle }
    var isListening: Bool {
        if case .listening = state { return true }
        return false
    }

    func toggle() {
        if isActive { stop() } else { start() }
    }

    func start() {
        guard state == .idle else { return }
        let settings = store.settings.voice
        guard settings.isEnabled else { return }
        generation += 1
        let generation = generation
        state = .preparing(progress: nil)
        session = Task { [weak self] in
            await self?.run(settings: settings, generation: generation)
        }
    }

    private func run(settings: VoiceSettings, generation: Int) async {
        // Kept here too: a dictation cancelled while it got ready must still let its engine go.
        var made: (any DictationEngine)?
        do {
            guard await Self.requestMicrophone() else { throw DictationError.microphoneDenied }
            let engine = DictationEngines.make(settings: settings, models: models)
            made = engine
            self.engine = engine
            try await engine.prepare { [weak self] fraction in
                Task { @MainActor in
                    guard let self, self.generation == generation, case .preparing = self.state else { return }
                    self.state = .preparing(progress: fraction)
                }
            }
            try Task.checkCancellation()
            let format = try await engine.audioFormat()
            try await engine.begin { [weak self] text in
                Task { @MainActor in
                    guard let self, self.generation == generation, self.isListening else { return }
                    self.onPartial?(text)
                }
            }
            try Task.checkCancellation()
            guard self.generation == generation else { throw CancellationError() }
            let capture = AudioCapture()
            let meter = LevelThrottle { [weak self] level in
                Task { @MainActor in
                    guard let self, self.generation == generation else { return }
                    self.onLevel?(level)
                }
            }
            try capture.start(
                deviceUID: settings.inputDeviceUID, format: format, sink: { engine.append($0) }, level: { meter.report($0) })
            self.capture = capture
            state = .listening(since: Date())
            if let recorded = engine as? RecordedDictationEngine { watchLimit(recorded, generation: generation) }
        } catch {
            guard self.generation == generation, !(error is CancellationError) else {
                await made?.cancel()
                return
            }
            fail(error)
        }
    }

    /// Stops listening and inserts the transcript.
    func stop() {
        switch state {
        case .idle, .transcribing: return
        case .preparing:
            cancel()
            return
        case .listening:
            break
        }
        let generation = generation
        capture?.stop()
        capture = nil
        limitTimer?.invalidate()
        guard let engine else { return finishIdle() }
        state = .transcribing
        session = Task { [weak self] in
            do {
                let text = try await engine.finish()
                guard let self, self.generation == generation else { return }
                self.engine = nil
                state = .idle
                let settings = store.settings.voice
                onFinish?(text, DictationCompletion.shouldSend(settings: settings, transcript: text, cancelled: false))
            } catch is CancellationError {
                return
            } catch {
                guard let self, self.generation == generation else { return }
                fail(error)
            }
        }
    }

    /// Stops and throws the recording away (Escape, the cancel button, the thread changing).
    func cancel() {
        guard state != .idle else { return }
        generation += 1
        session?.cancel()
        session = nil
        capture?.stop()
        capture = nil
        limitTimer?.invalidate()
        if let engine { Task { await engine.cancel() } }
        engine = nil
        state = .idle
        onCancel?()
    }

    private func finishIdle() {
        engine = nil
        state = .idle
    }

    private func fail(_ error: Error) {
        capture?.stop()
        capture = nil
        limitTimer?.invalidate()
        if let engine { Task { await engine.cancel() } }
        engine = nil
        state = .idle
        onCancel?()
        let dictation = (error as? DictationError) ?? .failed(error.localizedDescription)
        onError?(dictation)
    }

    /// A recording that reaches its length limit stops on its own, so it still fits in one upload.
    private func watchLimit(_ engine: RecordedDictationEngine, generation: Int) {
        limitTimer?.invalidate()
        limitTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, self.generation == generation, engine.isFull else { return }
                self.stop()
            }
        }
    }

    // MARK: Permission

    /// Asks for the microphone the first time; afterwards answers from what the user chose.
    static func requestMicrophone() async -> Bool {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized: return true
        case .denied, .restricted: return false
        case .notDetermined: return await AVCaptureDevice.requestAccess(for: .audio)
        @unknown default: return false
        }
    }

    static var microphoneDenied: Bool {
        let status = AVCaptureDevice.authorizationStatus(for: .audio)
        return status == .denied || status == .restricted
    }

    static func openMicrophoneSettings() {
        open("x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone")
    }

    static func openSpeechRecognitionSettings() {
        open("x-apple.systempreferences:com.apple.preference.security?Privacy_SpeechRecognition")
    }

    private static func open(_ string: String) {
        if let url = URL(string: string) { NSWorkspace.shared.open(url) }
    }
}

/// Passes on at most one level every 50 ms, the loudest since the last, from the audio thread.
nonisolated final class LevelThrottle: @unchecked Sendable {
    private let lock = NSLock()
    private var peak: Float = 0
    private var last = Date.distantPast
    private let send: @Sendable (Float) -> Void

    init(_ send: @escaping @Sendable (Float) -> Void) {
        self.send = send
    }

    func report(_ level: Float) {
        let value: Float? = lock.withLock {
            peak = max(peak, level)
            let now = Date()
            guard now.timeIntervalSince(last) >= 0.05 else { return nil }
            last = now
            defer { peak = 0 }
            return peak
        }
        if let value { send(value) }
    }
}

/// What dictation shares across composers and Settings: the Whisper models on this Mac.
final class VoiceServices {
    static let shared = VoiceServices()

    let whisperModels: WhisperModelManager

    init(store: AppStore = .shared) {
        whisperModels = WhisperModelManager(
            directory: store.directory.appendingPathComponent("Voice", isDirectory: true).appendingPathComponent("Whisper", isDirectory: true))
    }
}
