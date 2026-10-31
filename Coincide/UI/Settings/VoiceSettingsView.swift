@preconcurrency import AVFAudio
import AppKit
import CoincideKit
import Observation
import SwiftUI

/// Settings › Voice: dictation in the composer, its engine and language, the optional keyboard shortcut, the
/// microphone, the API keys of the transcription providers and the Whisper models on this Mac.
struct VoiceSettingsView: View {
    let model: SettingsModel
    @State private var voice = VoiceSettingsModel()
    @State private var highlighted: SettingsRowID?

    private var settings: VoiceSettings { model.settings.voice }

    var body: some View {
        ScrollViewReader { proxy in
            Form {
                Section {
                    SettingsPaneHeader(title: SettingsSection.voice.title) {
                        SettingsIconTile(symbol: SettingsSection.voice.symbolName, color: SettingsSection.voice.tint, size: 44)
                    } subtitle: {
                        Text("Dictate messages in the composer instead of typing them.")
                    }
                }

                Section {
                    Toggle(isOn: model.binding(\.voice.isEnabled)) {
                        Text("Dictation")
                        Text("Shows a microphone in the composer. Coincide asks for microphone access the first time you dictate.")
                    }
                    .settingsRevealable(.voiceEnabled, highlighted: highlighted)
                    ThemedPicker(
                        selection: model.binding(\.voice.engine),
                        options: DictationEngineKind.allCases.map { .init($0, $0.displayName) }
                    ) {
                        Text("Engine")
                        Text(engineDescription(settings.engine))
                    }
                    .settingsRevealable(.voiceEngine, highlighted: highlighted)
                    ThemedPicker(
                        selection: model.binding(\.voice.language),
                        options: ([DictationLanguage.automatic] + DictationLanguage.identifiers).map {
                            .init($0, DictationLanguage.displayName($0))
                        }
                    ) {
                        Text("Language")
                        Text(
                            settings.engine == .apple
                                ? "Automatic uses your Mac’s language." : "Automatic lets the engine detect the language you speak.")
                    }
                    .settingsRevealable(.voiceLanguage, highlighted: highlighted)
                    Toggle(isOn: model.binding(\.voice.sendsWhenStopped)) {
                        Text("Send when I stop")
                        Text("Sends the message as soon as dictation ends. Off, the text waits in the composer for you to check.")
                    }
                    .settingsRevealable(.voiceSendWhenStopped, highlighted: highlighted)
                }
                .disabled(!settings.isEnabled)

                Section("Keyboard Shortcut") {
                    shortcutRows
                        .settingsRevealable(.voiceShortcut, highlighted: highlighted)
                }
                .disabled(!settings.isEnabled)

                Section("Microphone") {
                    microphoneRows
                        .settingsRevealable(.voiceMicrophone, highlighted: highlighted)
                }

                engineSection
            }
            .formStyle(.grouped)
            .modifier(SettingsRevealHandler(request: model.reveal, proxy: proxy, highlighted: $highlighted))
        }
        .onAppear { voice.refresh() }
        .onDisappear { voice.stopTest() }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in voice.refresh() }
    }

    private func engineDescription(_ engine: DictationEngineKind) -> String {
        switch engine {
        case .apple: String(localized: "Apple’s speech recognition, on this Mac. Partial text appears as you speak.")
        case .openAI: String(localized: "OpenAI transcribes the recording with your API key. Audio is sent to OpenAI.")
        case .groq: String(localized: "Groq transcribes the recording with your API key. Audio is sent to Groq.")
        case .whisper: String(localized: "Whisper runs on this Mac with a model you download. Works offline.")
        }
    }

    // MARK: Shortcut

    @ViewBuilder private var shortcutRows: some View {
        VStack(alignment: .leading, spacing: 10) {
            Toggle(isOn: model.binding(\.voice.shortcutEnabled)) {
                Text("Keyboard shortcut")
                Text("Off by default. When it’s on, it works while a Coincide window is in front; Coincide watches no keys for dictation while it’s off.")
            }
            if settings.shortcutEnabled {
                LabeledContent {
                    DictationShortcutRecorder(shortcut: settings.shortcut) { shortcut in
                        model.update { $0.voice.shortcut = shortcut }
                    }
                    .frame(width: ShortcutRecorderView.width, height: ShortcutRecorderView.height)
                } label: {
                    Text("Shortcut")
                    Text("A key with ⌘, ⌃ or ⌥, or one modifier pressed on its own.")
                }
                ThemedPicker(
                    selection: model.binding(\.voice.shortcutMode),
                    options: DictationShortcutMode.allCases.map { .init($0, $0.displayName) }
                ) {
                    Text("Mode")
                    Text(modeDescription(settings.shortcutMode))
                }
                ForEach(DictationShortcutConflicts.warnings(for: settings.shortcut), id: \.self) { warning in
                    Label {
                        Text(warning)
                    } icon: {
                        Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                    }
                    .font(.callout)
                    .foregroundStyle(.secondary)
                }
                if settings.shortcut == .modifier(.fn), voice.fnUsage != .doNothing {
                    HStack(alignment: .firstTextBaseline) {
                        Label {
                            if voice.fnUsage == .unknown {
                                Text("macOS may also act when you press 🌐. To use 🌐 only for Coincide’s dictation, set “Press 🌐 key to” to Do Nothing in Keyboard settings.")
                            } else {
                                Text("macOS is also set to \(voice.fnUsage.displayName) when you press 🌐. To use 🌐 only for Coincide’s dictation, set “Press 🌐 key to” to Do Nothing in Keyboard settings.")
                            }
                        } icon: {
                            Image(systemName: "info.circle").foregroundStyle(.secondary)
                        }
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        Spacer(minLength: 8)
                        Button("Open Keyboard Settings") { SystemFnKeyUsage.openKeyboardSettings() }
                    }
                }
                if settings.shortcut != .default || settings.shortcutMode != .both {
                    HStack {
                        Spacer()
                        Button("Use 🌐 fn, Hold or Tap") {
                            model.update {
                                $0.voice.shortcut = .default
                                $0.voice.shortcutMode = .both
                            }
                        }
                    }
                }
            }
        }
    }

    private func modeDescription(_ mode: DictationShortcutMode) -> String {
        switch mode {
        case .both: String(localized: "Hold the shortcut to talk and let go to stop, or tap it to start and tap again to stop.")
        case .hold: String(localized: "Dictates while you hold the shortcut.")
        case .tap: String(localized: "Tap to start dictating, tap again to stop.")
        }
    }

    // MARK: Microphone

    @ViewBuilder private var microphoneRows: some View {
        ThemedPicker(
            selection: Binding(get: { settings.inputDeviceUID ?? "" }, set: { uid in model.update { $0.voice.inputDeviceUID = uid.isEmpty ? nil : uid } }),
            options: [.init("", String(localized: "System default"))]
                + voice.devices.map { .init($0.uid, $0.name) }
                + (settings.inputDeviceUID.map { uid in voice.devices.contains { $0.uid == uid } ? [] : [.init(uid, String(localized: "Disconnected microphone"))] } ?? [])
        ) {
            Text("Input")
            Text("The microphone dictation listens to.")
        }
        if voice.microphoneDenied {
            HStack {
                Label {
                    Text("Coincide doesn’t have access to the microphone.")
                } icon: {
                    Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                }
                Spacer()
                Button("Open System Settings") { DictationController.openMicrophoneSettings() }
            }
        }
        LabeledContent {
            HStack(spacing: 10) {
                if voice.isTesting {
                    LevelBar(level: voice.testLevel)
                        .frame(width: 120, height: 6)
                        .accessibilityLabel(Text("Microphone level"))
                        .accessibilityValue(Text(verbatim: "\(Int(voice.testLevel * 100))%"))
                }
                Button(voice.isTesting ? "Stop" : "Test Microphone") {
                    if voice.isTesting { voice.stopTest() } else { voice.startTest(deviceUID: settings.inputDeviceUID) }
                }
            }
        } label: {
            Text("Test")
            Text(voice.testMessage ?? String(localized: "Speak and watch the level move. Nothing is recorded."))
        }
    }

    // MARK: Engines

    @ViewBuilder private var engineSection: some View {
        if settings.engine == .apple {
            Section("Apple Speech Recognition") {
                AppleSpeechRows(voice: voice, language: settings.language)
            }
        }
        if settings.engine == .openAI || highlighted == .voiceOpenAI {
            Section("OpenAI") {
                APIKeyRows(model: model, voice: voice, provider: .openAI)
                    .settingsRevealable(.voiceOpenAI, highlighted: highlighted)
            }
        }
        if settings.engine == .groq || highlighted == .voiceGroq {
            Section("Groq") {
                APIKeyRows(model: model, voice: voice, provider: .groq)
                    .settingsRevealable(.voiceGroq, highlighted: highlighted)
            }
        }
        if settings.engine == .whisper || highlighted == .voiceWhisper {
            Section {
                WhisperModelRows(model: model, manager: VoiceServices.shared.whisperModels)
                    .settingsRevealable(.voiceWhisper, highlighted: highlighted)
            } header: {
                Text("Whisper Models")
            } footer: {
                Text("Models download from Hugging Face only when you click Download, are checked against their published checksums, and run offline afterwards.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }
}

/// A level from 0 to 1 in the theme's accent.
private struct LevelBar: View {
    let level: Float

    var body: some View {
        GeometryReader { geometry in
            ZStack(alignment: .leading) {
                Capsule().fill(Color(nsColor: Theme.accent).opacity(0.2))
                Capsule().fill(Color(nsColor: Theme.accent))
                    .frame(width: max(6, geometry.size.width * CGFloat(level)))
            }
        }
    }
}

private struct AppleSpeechRows: View {
    let voice: VoiceSettingsModel
    let language: String

    var body: some View {
        LabeledContent {
            if let progress = voice.appleProgress {
                ProgressView(value: progress).frame(width: 120)
            } else {
                Button("Download Now") { voice.prepareApple(language: language) }
            }
        } label: {
            Text("Speech model")
            Text(voice.appleMessage ?? String(localized: "macOS downloads the language’s speech model the first time you dictate. You can get it now instead."))
        }
    }
}

private struct APIKeyRows: View {
    let model: SettingsModel
    let voice: VoiceSettingsModel
    let provider: TranscriptionProvider
    @State private var key = ""
    @State private var confirmingCodex = false

    var body: some View {
        Label {
            Text("Your recordings are sent to \(provider.displayName) to be transcribed, under your account and its data policies.")
        } icon: {
            Image(systemName: "network").foregroundStyle(.secondary)
        }
        .font(.callout)
        .foregroundStyle(.secondary)
        ThemedPicker(
            selection: Binding(
                get: { model.settings.voice.model(for: provider) },
                set: { id in
                    model.update {
                        switch provider {
                        case .openAI: $0.voice.openAIModel = id
                        case .groq: $0.voice.groqModel = id
                        }
                    }
                }),
            options: provider.models.map { .init($0.id, "\($0.name) — \($0.detail)") }
        ) {
            Text("Model")
        }
        VStack(alignment: .leading, spacing: 6) {
            Text("API key")
            HStack(spacing: 6) {
                SecureField(
                    "API key", text: $key,
                    prompt: Text(voice.hasKey(provider) ? String(localized: "Saved in the Keychain") : String(localized: "Paste the API key"))
                )
                .labelsHidden()
                .font(.callout.monospaced())
                .onSubmit(save)
                Button(voice.hasKey(provider) ? String(localized: "Replace") : String(localized: "Save"), action: save)
                    .disabled(key.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                if voice.hasKey(provider) {
                    Button("Test Key") { voice.testKey(provider) }
                        .disabled(voice.testingKey == provider)
                    Button(String(localized: "Remove Key"), role: .destructive) { voice.removeKey(provider) }
                }
            }
            HStack(spacing: 6) {
                if voice.testingKey == provider { ProgressView().controlSize(.small) }
                if let result = voice.keyResults[provider] {
                    Label(result.message, systemImage: result.ok ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                        .foregroundStyle(result.ok ? Color.green : Color.orange)
                }
                Spacer()
                Link("Get a Key", destination: provider.keysPage)
            }
            .font(.caption)
        }
        if provider == .openAI, voice.codexHasKey {
            LabeledContent {
                Button("Use Codex’s Key…") { confirmingCodex = true }
            } label: {
                Text("Use the OpenAI API key from Codex")
                Text("Codex is signed in with an API key. Coincide can copy that key to its own Keychain item; it never reads ChatGPT sign-ins.")
            }
            .confirmationDialog("Copy Codex’s OpenAI API key?", isPresented: $confirmingCodex) {
                Button("Copy Key") { voice.importCodexKey() }
            } message: {
                Text("Coincide copies OPENAI_API_KEY from ~/.codex/auth.json into its Keychain and sends it only to OpenAI, with your dictation audio. Changing the key in Codex later doesn’t change Coincide’s copy.")
            }
        }
    }

    private func save() {
        voice.saveKey(key, for: provider)
        key = ""
    }
}

private struct WhisperModelRows: View {
    let model: SettingsModel
    let manager: WhisperModelManager

    var body: some View {
        ForEach(WhisperModel.catalog) { whisper in
            let state = manager.state(whisper)
            let selected = model.settings.voice.whisperModel == whisper.id
            HStack(spacing: 10) {
                Image(systemName: selected ? "largecircle.fill.circle" : "circle")
                    .foregroundStyle(selected ? Color(nsColor: Theme.accent) : .secondary)
                    .onTapGesture { model.update { $0.voice.whisperModel = whisper.id } }
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 2) {
                    Text(verbatim: "\(whisper.name) · \(whisper.sizeDescription)")
                    Text(statusText(state, whisper))
                        .font(.caption)
                        .foregroundStyle(state.isFailure ? Color.orange : .secondary)
                }
                Spacer()
                switch state {
                case .notDownloaded, .failed:
                    Button("Download") { manager.download(whisper) }
                case .downloading:
                    ProgressView(value: state.fraction ?? 0).frame(width: 90)
                    Button("Cancel") { manager.cancel(whisper) }
                case .verifying:
                    ProgressView().controlSize(.small)
                case .downloaded:
                    if !selected { Button("Use") { model.update { $0.voice.whisperModel = whisper.id } } }
                    Button("Delete", role: .destructive) {
                        Task { await WhisperKitRunner.shared.unload() }
                        manager.delete(whisper)
                    }
                }
            }
            .accessibilityElement(children: .contain)
            .accessibilityLabel(Text(verbatim: "\(whisper.name), \(whisper.sizeDescription)"))
            .accessibilityValue(selected ? Text("Selected") : Text(verbatim: ""))
        }
    }

    private func statusText(_ state: WhisperModelState, _ whisper: WhisperModel) -> String {
        switch state {
        case .notDownloaded: whisper.detail
        case .downloading(let received, let total):
            String(
                localized: "Downloading \(ByteCountFormatter.string(fromByteCount: received, countStyle: .file)) of \(ByteCountFormatter.string(fromByteCount: total, countStyle: .file))")
        case .verifying: String(localized: "Checking the files…")
        case .downloaded: String(localized: "Downloaded · \(whisper.detail)")
        case .failed(let message): message
        }
    }
}

extension WhisperModelState {
    fileprivate var isFailure: Bool {
        if case .failed = self { return true }
        return false
    }
}

/// The parts of Settings › Voice that aren't settings: the Keychain's keys, key tests, the microphone test and the
/// Apple speech model download.
@Observable
final class VoiceSettingsModel {
    struct KeyResult: Equatable {
        let ok: Bool
        let message: String
    }

    private(set) var devices: [AudioInputDevices.Device] = []
    private(set) var microphoneDenied = false
    private(set) var fnUsage: SystemFnKeyUsage = .unknown
    private(set) var keysSaved: Set<TranscriptionProvider> = []
    private(set) var keyResults: [TranscriptionProvider: KeyResult] = [:]
    private(set) var testingKey: TranscriptionProvider?
    private(set) var codexHasKey = false
    private(set) var isTesting = false
    private(set) var testLevel: Float = 0
    private(set) var testMessage: String?
    private(set) var appleProgress: Double?
    private(set) var appleMessage: String?

    @ObservationIgnored private let keys: VoiceKeyStore
    @ObservationIgnored private var capture: AudioCapture?
    @ObservationIgnored private var testTimeout: Task<Void, Never>?

    init(keys: VoiceKeyStore = .standard) {
        self.keys = keys
    }

    func refresh() {
        devices = AudioInputDevices.all()
        microphoneDenied = DictationController.microphoneDenied
        fnUsage = SystemFnKeyUsage.current
        keysSaved = Set(TranscriptionProvider.allCases.filter { keys.hasKey(for: $0) })
        codexHasKey = CodexAPIKeyImport.standard.hasAPIKey
    }

    // MARK: Keys

    func hasKey(_ provider: TranscriptionProvider) -> Bool { keysSaved.contains(provider) }

    func saveKey(_ key: String, for provider: TranscriptionProvider) {
        do {
            try keys.setKey(key, for: provider)
            keyResults[provider] = nil
        } catch {
            keyResults[provider] = KeyResult(ok: false, message: error.localizedDescription)
        }
        refresh()
    }

    func removeKey(_ provider: TranscriptionProvider) {
        keys.removeKey(for: provider)
        keyResults[provider] = nil
        refresh()
    }

    func testKey(_ provider: TranscriptionProvider) {
        guard let key = keys.key(for: provider) else { return }
        testingKey = provider
        keyResults[provider] = nil
        Task {
            do {
                try await TranscriptionClient().testKey(provider: provider, apiKey: key)
                keyResults[provider] = KeyResult(ok: true, message: String(localized: "\(provider.displayName) accepted the key."))
            } catch {
                keyResults[provider] = KeyResult(ok: false, message: error.localizedDescription)
            }
            testingKey = nil
        }
    }

    /// Copies Codex's `OPENAI_API_KEY`, after the user confirmed.
    func importCodexKey() {
        guard let key = CodexAPIKeyImport.standard.apiKey() else {
            keyResults[.openAI] = KeyResult(ok: false, message: String(localized: "Codex no longer has an API key."))
            return refresh()
        }
        saveKey(key, for: .openAI)
        if keyResults[.openAI] == nil {
            keyResults[.openAI] = KeyResult(ok: true, message: String(localized: "Copied Codex’s key to the Keychain."))
        }
    }

    // MARK: Microphone test

    func startTest(deviceUID: String?) {
        stopTest()
        testMessage = nil
        Task {
            guard await DictationController.requestMicrophone() else {
                microphoneDenied = true
                testMessage = String(localized: "Coincide doesn’t have access to the microphone.")
                return
            }
            guard let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16_000, channels: 1, interleaved: false)
            else { return }
            let capture = AudioCapture()
            let throttle = LevelThrottle { level in
                Task { @MainActor in self.testLevel = level }
            }
            do {
                // The test only reads the level; the audio itself is dropped as it arrives.
                try capture.start(deviceUID: deviceUID, format: format, sink: { _ in }, level: { throttle.report($0) })
            } catch {
                testMessage = error.localizedDescription
                return
            }
            self.capture = capture
            isTesting = true
            testTimeout = Task {
                try? await Task.sleep(for: .seconds(15))
                guard !Task.isCancelled else { return }
                self.stopTest()
            }
        }
    }

    func stopTest() {
        testTimeout?.cancel()
        testTimeout = nil
        capture?.stop()
        capture = nil
        isTesting = false
        testLevel = 0
    }

    // MARK: Apple speech model

    func prepareApple(language: String) {
        appleProgress = 0
        appleMessage = nil
        let recognizer = AppleSpeechRecognizer(locale: DictationLanguage.appleLocale(for: language))
        Task {
            do {
                try await recognizer.prepare { fraction in
                    Task { @MainActor in self.appleProgress = fraction }
                }
                appleMessage = String(localized: "The speech model for \(DictationLanguage.displayName(language)) is on this Mac.")
            } catch {
                appleMessage = error.localizedDescription
            }
            appleProgress = nil
        }
    }
}
