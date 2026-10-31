import CryptoKit
import Foundation
import Testing

@testable import CoincideKit

// MARK: - Settings

struct VoiceSettingsTests {
    private func decode(_ json: String) throws -> AppSettings {
        try JSONDecoder().decode(AppSettings.self, from: Data(json.utf8))
    }

    @Test func defaultsAreOnWithAppleAndNoShortcut() {
        let voice = VoiceSettings()
        #expect(voice.isEnabled)
        #expect(voice.engine == .apple)
        #expect(voice.language == DictationLanguage.automatic)
        // The keyboard shortcut is off until the user turns it on, preset to Fn, hold or tap.
        #expect(voice.shortcutEnabled == false)
        #expect(voice.shortcut == .modifier(.fn))
        #expect(voice.shortcutMode == .both)
        #expect(voice.sendsWhenStopped == false)
        #expect(voice.openAIModel == "gpt-transcribe")
        #expect(voice.groqModel == "whisper-large-v3-turbo")
        #expect(voice.whisperModel == WhisperModel.defaultID)
        #expect(voice.inputDeviceUID == nil)
        #expect(AppSettings().voice == voice)
    }

    @Test func settingsFromBeforeVoiceGetTheDefaults() throws {
        let settings = try decode(#"{"fontSize": 15}"#)
        #expect(settings.voice == VoiceSettings())
        #expect(settings.fontSize == 15)
    }

    @Test func voiceSettingsRoundTrip() throws {
        var settings = AppSettings()
        settings.voice.engine = .groq
        settings.voice.language = "de-DE"
        settings.voice.shortcutEnabled = true
        settings.voice.shortcut = .keys(try #require(KeyShortcut("alt+space")))
        settings.voice.shortcutMode = .hold
        settings.voice.sendsWhenStopped = true
        settings.voice.inputDeviceUID = "BuiltInMicrophoneDevice"
        settings.voice.whisperModel = "small"
        let data = try JSONEncoder().encode(settings)
        let object = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        let voice = try #require(object["voice"] as? [String: Any])
        #expect(voice["shortcut"] as? String == "alt+space")
        #expect(voice["engine"] as? String == "groq")
        #expect(try JSONDecoder().decode(AppSettings.self, from: data) == settings)
    }

    @Test func unreadableValuesFallBackOneByOne() throws {
        let settings = try decode(
            #"{"voice": {"isEnabled": "yes", "engine": "siri", "shortcut": "a", "shortcutMode": 3, "sendsWhenStopped": true, "whisperModel": "huge", "language": ""}}"#
        )
        #expect(settings.voice.isEnabled)
        #expect(settings.voice.engine == .apple)
        #expect(settings.voice.shortcut == .modifier(.fn))
        #expect(settings.voice.shortcutMode == .both)
        #expect(settings.voice.sendsWhenStopped)
        #expect(settings.voice.whisperModel == WhisperModel.defaultID)
        #expect(settings.voice.language == DictationLanguage.automatic)
    }

    @Test func aVoiceValueThatIsNotAnObjectKeepsTheRest() throws {
        let settings = try decode(#"{"voice": 4, "sendOnReturn": false}"#)
        #expect(settings.voice == VoiceSettings())
        #expect(settings.sendOnReturn == false)
    }

    @Test(arguments: ["fn", "option", "command", "control", "shift", "alt+space", "mod+shift+d", "ctrl+m", "f5"])
    func shortcutsReadBack(text: String) throws {
        let shortcut = try #require(DictationShortcut(text))
        #expect(DictationShortcut(shortcut.stringValue) == shortcut)
    }

    @Test(arguments: ["a", "space", "shift+a", "esc", "alt+esc", "", "fn+fn"])
    func shortcutsThatWouldTakeTypingKeysAreRefused(text: String) {
        #expect(DictationShortcut(text) == nil)
    }

    @Test func languagesMapToEachEngine() {
        #expect(DictationLanguage.isoCode(for: "auto") == nil)
        #expect(DictationLanguage.isoCode(for: "de-DE") == "de")
        #expect(DictationLanguage.isoCode(for: "zh-TW") == "zh")
        #expect(DictationLanguage.appleLocale(for: "fr-CA").identifier == "fr-CA")
        let current = Locale(identifier: "ja_JP")
        #expect(DictationLanguage.appleLocale(for: "auto", current: current) == current)
        #expect(Set(DictationLanguage.identifiers).count == DictationLanguage.identifiers.count)
    }

    @Test func onlyTheAPIEnginesSendAudio() {
        #expect(DictationEngineKind.allCases.filter(\.sendsAudioToProvider) == [.openAI, .groq])
        #expect(TranscriptionProvider(engine: .apple) == nil)
        #expect(TranscriptionProvider(engine: .whisper) == nil)
        #expect(TranscriptionProvider(engine: .groq) == .groq)
    }
}

// MARK: - Sending

struct DictationCompletionTests {
    @Test func dictationNeverSendsByDefault() {
        #expect(DictationCompletion.shouldSend(settings: VoiceSettings(), transcript: "Fix the tests", cancelled: false) == false)
    }

    @Test func sendWhenStoppedSendsOnlyRealText() {
        var settings = VoiceSettings()
        settings.sendsWhenStopped = true
        #expect(DictationCompletion.shouldSend(settings: settings, transcript: "Fix the tests", cancelled: false))
        #expect(DictationCompletion.shouldSend(settings: settings, transcript: "  \n", cancelled: false) == false)
        #expect(DictationCompletion.shouldSend(settings: settings, transcript: "Fix the tests", cancelled: true) == false)
    }
}

// MARK: - Shortcut

struct DictationTriggerTests {
    private typealias Machine = DictationTriggerMachine
    private let hold = Machine.holdThreshold

    @Test func aQuickTapOfFnStartsAndTheNextStops() {
        var machine = Machine(mode: .both, isLoneModifier: true)
        #expect(machine.triggerDown(at: 10) == .scheduleHoldCheck(hold))
        #expect(machine.triggerUp(at: 10.1) == .start)
        #expect(machine.holdCheck(at: 10.3) == .none)
        #expect(machine.isRecording)
        #expect(machine.triggerDown(at: 12) == .none)
        #expect(machine.triggerUp(at: 12.1) == .stop)
        #expect(machine.isRecording == false)
    }

    @Test func holdingFnTalksUntilRelease() {
        var machine = Machine(mode: .both, isLoneModifier: true)
        #expect(machine.triggerDown(at: 10) == .scheduleHoldCheck(hold))
        #expect(machine.holdCheck(at: 10 + hold) == .start)
        #expect(machine.triggerUp(at: 13) == .stop)
        #expect(machine.isRecording == false)
    }

    @Test func fnWithAnotherKeyIsNotTheShortcut() {
        var machine = Machine(mode: .both, isLoneModifier: true)
        _ = machine.triggerDown(at: 10)
        #expect(machine.otherInput(at: 10.05) == .none)  // Fn-arrow, an F-key, Fn-letter, or another modifier
        #expect(machine.holdCheck(at: 10 + hold) == .none)
        #expect(machine.triggerUp(at: 10.1) == .none)
        #expect(machine.isRecording == false)
        // A long Fn-arrow doesn't start either.
        _ = machine.triggerDown(at: 20)
        _ = machine.otherInput(at: 20.5)
        #expect(machine.holdCheck(at: 20.6) == .none)
        #expect(machine.triggerUp(at: 21) == .none)
    }

    @Test func anotherKeyDuringAnFnHoldCancelsIt() {
        var machine = Machine(mode: .both, isLoneModifier: true)
        _ = machine.triggerDown(at: 10)
        #expect(machine.holdCheck(at: 10 + hold) == .start)
        #expect(machine.otherInput(at: 10.5) == .cancel)
        #expect(machine.triggerUp(at: 11) == .none)
        #expect(machine.isRecording == false)
    }

    @Test func otherKeysWhileTapDictationRunsDontStopIt() {
        var machine = Machine(mode: .both, isLoneModifier: true)
        _ = machine.triggerDown(at: 10)
        #expect(machine.triggerUp(at: 10.1) == .start)
        // Fn-arrow while dictating is the user doing something else.
        _ = machine.triggerDown(at: 11)
        #expect(machine.otherInput(at: 11.05) == .none)
        #expect(machine.triggerUp(at: 11.1) == .none)
        #expect(machine.isRecording)
    }

    @Test func holdOnlyIgnoresTaps() {
        var machine = Machine(mode: .hold, isLoneModifier: true)
        #expect(machine.triggerDown(at: 10) == .scheduleHoldCheck(hold))
        #expect(machine.triggerUp(at: 10.1) == .none)
        #expect(machine.isRecording == false)
        _ = machine.triggerDown(at: 11)
        #expect(machine.holdCheck(at: 11 + hold) == .start)
        #expect(machine.triggerUp(at: 12) == .stop)
    }

    @Test func tapOnlyIgnoresHolds() {
        var machine = Machine(mode: .tap, isLoneModifier: true)
        #expect(machine.triggerDown(at: 10) == .none)
        #expect(machine.holdCheck(at: 10 + hold) == .none)
        #expect(machine.triggerUp(at: 10.6) == .start)
        _ = machine.triggerDown(at: 12)
        #expect(machine.triggerUp(at: 12.1) == .stop)
        // Fn held for a while is Fn used for something else.
        _ = machine.triggerDown(at: 20)
        #expect(machine.triggerUp(at: 20 + Machine.longestTap + 0.5) == .none)
        #expect(machine.isRecording == false)
    }

    @Test func aKeyShortcutActsOnKeyDown() {
        var both = Machine(mode: .both, isLoneModifier: false)
        #expect(both.triggerDown(at: 10) == .start)
        #expect(both.triggerUp(at: 10.1) == .none)  // a tap: dictation stays on
        #expect(both.triggerDown(at: 12) == .stop)
        #expect(both.triggerUp(at: 12.1) == .none)
        #expect(both.triggerDown(at: 14) == .start)
        #expect(both.triggerUp(at: 15) == .stop)  // held: push-to-talk

        var hold = Machine(mode: .hold, isLoneModifier: false)
        #expect(hold.triggerDown(at: 10) == .start)
        #expect(hold.triggerUp(at: 10.1) == .stop)

        var tap = Machine(mode: .tap, isLoneModifier: false)
        #expect(tap.triggerDown(at: 10) == .start)
        #expect(tap.triggerUp(at: 11) == .none)
        #expect(tap.triggerDown(at: 12) == .stop)
        // Other keys don't interrupt a key shortcut.
        #expect(tap.otherInput(at: 12.1) == .none)
    }

    @Test func escapeCancels() {
        var machine = Machine(mode: .both, isLoneModifier: true)
        #expect(machine.escape() == .none)
        _ = machine.triggerDown(at: 10)
        _ = machine.triggerUp(at: 10.1)
        #expect(machine.escape() == .cancel)
        #expect(machine.isRecording == false)

        var held = Machine(mode: .both, isLoneModifier: false)
        _ = held.triggerDown(at: 10)
        #expect(held.escape() == .cancel)
        #expect(held.triggerUp(at: 11) == .none)
    }

    @Test func repeatsAndBouncesAreIgnored() {
        var machine = Machine(mode: .both, isLoneModifier: false)
        #expect(machine.triggerDown(at: 10) == .start)
        #expect(machine.triggerDown(at: 10.05) == .none)  // key repeat
        #expect(machine.triggerUp(at: 10.1) == .none)
        // Pressed again right after starting: a bounce, not a stop.
        #expect(machine.triggerDown(at: 10.11) == .none)
        #expect(machine.triggerUp(at: 10.115) == .none)
        #expect(machine.isRecording)
    }

    @Test func dictationEndingElsewhereIsKnown() {
        var machine = Machine(mode: .both, isLoneModifier: true)
        machine.recordingStarted()  // the microphone button
        _ = machine.triggerDown(at: 10)
        #expect(machine.triggerUp(at: 10.1) == .stop)
        machine.recordingStarted()
        machine.recordingEnded()  // an error
        _ = machine.triggerDown(at: 20)
        #expect(machine.triggerUp(at: 20.1) == .start)
    }
}

// MARK: - Insertion

struct DictationInsertionTests {
    private func apply(_ text: inout String, _ edit: (range: NSRange, replacement: String)?) {
        guard let edit else { return }
        text = (text as NSString).replacingCharacters(in: edit.range, with: edit.replacement)
    }

    @Test func partialsReplaceEachOtherAtTheCaret() {
        var text = "Please fix"
        var insertion = DictationInsertion(text: text, selection: NSRange(location: 10, length: 0))
        apply(&text, insertion.update("the"))
        #expect(text == "Please fix the")
        apply(&text, insertion.update("the failing"))
        #expect(text == "Please fix the failing")
        apply(&text, insertion.update("the failing tests."))
        #expect(text == "Please fix the failing tests.")
        #expect(insertion.caret == NSRange(location: (text as NSString).length, length: 0))
    }

    @Test func textGoesBetweenWordsWithSpaces() {
        var text = "Fixtests"
        var insertion = DictationInsertion(text: text, selection: NSRange(location: 3, length: 0))
        apply(&text, insertion.update(" the  "))
        #expect(text == "Fix the tests")
    }

    @Test func noSpaceBeforePunctuationOrAtTheStart() {
        var text = "."
        var insertion = DictationInsertion(text: text, selection: NSRange(location: 0, length: 0))
        apply(&text, insertion.update("Done"))
        #expect(text == "Done.")
    }

    @Test func theSelectionIsReplacedOnceThereAreWords() {
        var text = "Use the old words here"
        var insertion = DictationInsertion(text: text, selection: NSRange(location: 8, length: 9))
        #expect(insertion.update("") == nil)  // nothing heard yet: the selection stays
        #expect(text == "Use the old words here")
        apply(&text, insertion.update("new"))
        #expect(text == "Use the new here")
        apply(&text, insertion.update(""))
        #expect(text == "Use the  here")
    }

    @Test func emojiAndOtherWideCharactersCountInUTF16() {
        var text = "👋"
        var insertion = DictationInsertion(text: text, selection: NSRange(location: 2, length: 0))
        apply(&text, insertion.update("hi"))
        apply(&text, insertion.update("hi there"))
        #expect(text == "👋 hi there")
    }

    @Test func aCaretOutsideTheTextIsClamped() {
        var text = "ab"
        var insertion = DictationInsertion(text: text, selection: NSRange(location: 99, length: 5))
        apply(&text, insertion.update("c"))
        #expect(text == "ab c")
    }
}

// MARK: - Transcription APIs

/// Answers requests with a canned response and keeps them, so tests see exactly what would be sent.
final class TranscriptionURLProtocol: URLProtocol, @unchecked Sendable {
    nonisolated(unsafe) static var response: (status: Int, body: Data) = (200, Data())
    nonisolated(unsafe) static var requests: [(request: URLRequest, body: Data)] = []
    static let lock = NSLock()

    static func session(status: Int, body: String) -> URLSession {
        lock.withLock {
            response = (status, Data(body.utf8))
            requests = []
        }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [TranscriptionURLProtocol.self]
        return URLSession(configuration: configuration)
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        var body = request.httpBody ?? Data()
        if body.isEmpty, let stream = request.httpBodyStream {
            stream.open()
            var buffer = [UInt8](repeating: 0, count: 64 * 1024)
            while stream.hasBytesAvailable {
                let count = stream.read(&buffer, maxLength: buffer.count)
                if count <= 0 { break }
                body.append(buffer, count: count)
            }
            stream.close()
        }
        let canned = Self.lock.withLock {
            Self.requests.append((request, body))
            return Self.response
        }
        let response = HTTPURLResponse(url: request.url!, statusCode: canned.status, httpVersion: "HTTP/1.1", headerFields: nil)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: canned.body)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

@Suite(.serialized)
struct TranscriptionAPITests {
    private let key = "sk-test-0123456789abcdefghij"
    private let audio = WAVEncoder.encode(samples: [0, 0.5, -0.5, 1], sampleRate: 16_000)

    private func text(_ data: Data) -> String { String(decoding: data, as: UTF8.self) }

    @Test func theRequestCarriesTheKeyOnlyInItsHeader() throws {
        let request = TranscriptionRequests.transcription(
            provider: .openAI, apiKey: key, model: "gpt-4o-mini-transcribe", languageCode: "de", audio: audio, boundary: "B")
        #expect(request.url?.absoluteString == "https://api.openai.com/v1/audio/transcriptions")
        #expect(request.httpMethod == "POST")
        #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer \(key)")
        #expect(request.value(forHTTPHeaderField: "Content-Type") == "multipart/form-data; boundary=B")
        #expect(request.url?.absoluteString.contains(key) == false)
        #expect(request.url?.query == nil)
        let body = try #require(request.httpBody)
        #expect(text(body).contains(key) == false)
        let string = String(decoding: body, as: UTF8.self)
        #expect(string.hasPrefix("--B\r\nContent-Disposition: form-data; name=\"model\"\r\n\r\ngpt-4o-mini-transcribe\r\n"))
        #expect(string.contains("name=\"response_format\"\r\n\r\njson\r\n"))
        #expect(string.contains("name=\"language\"\r\n\r\nde\r\n"))
        #expect(string.contains("name=\"file\"; filename=\"dictation.wav\"\r\nContent-Type: audio/wav\r\n\r\n"))
        #expect(string.hasSuffix("\r\n--B--\r\n"))
        #expect(body.range(of: audio) != nil)
    }

    @Test func gptTranscribeTakesALanguageListAndAutomaticSendsNone() throws {
        let listed = TranscriptionRequests.transcription(
            provider: .openAI, apiKey: key, model: "gpt-transcribe", languageCode: "fr", audio: audio, boundary: "B")
        let body = text(try #require(listed.httpBody))
        #expect(body.contains("name=\"languages[]\"\r\n\r\nfr\r\n"))
        #expect(body.contains("name=\"language\"") == false)
        let automatic = TranscriptionRequests.transcription(
            provider: .groq, apiKey: key, model: "whisper-large-v3", languageCode: nil, audio: audio, boundary: "B")
        #expect(automatic.url?.absoluteString == "https://api.groq.com/openai/v1/audio/transcriptions")
        #expect(text(try #require(automatic.httpBody)).contains("language") == false)
    }

    @Test func aTranscriptComesBack() async throws {
        let session = TranscriptionURLProtocol.session(status: 200, body: #"{"text": "  Fix the build. "}"#)
        let client = TranscriptionClient(session: session)
        let transcript = try await client.transcribe(provider: .groq, apiKey: key, model: "whisper-large-v3-turbo", languageCode: nil, wav: audio)
        #expect(transcript == "Fix the build.")
        let sent = try #require(TranscriptionURLProtocol.lock.withLock { TranscriptionURLProtocol.requests.first })
        #expect(sent.request.value(forHTTPHeaderField: "Authorization") == "Bearer \(key)")
        #expect(sent.request.url?.absoluteString.contains(key) == false)
        #expect(sent.body.range(of: audio) != nil)
    }

    @Test(arguments: [
        (401, TranscriptionAPIError.invalidKey(.openAI)),
        (413, TranscriptionAPIError.tooLarge),
        (429, TranscriptionAPIError.rateLimited(.openAI, "You exceeded your quota.")),
        (400, TranscriptionAPIError.badRequest("You exceeded your quota.")),
        (403, TranscriptionAPIError.forbidden(.openAI, "You exceeded your quota.")),
        (503, TranscriptionAPIError.server(503, "You exceeded your quota.")),
    ])
    func errorsMapToWhatTheUserCanDo(status: Int, expected: TranscriptionAPIError) async throws {
        let session = TranscriptionURLProtocol.session(status: status, body: #"{"error": {"message": "You exceeded your quota."}}"#)
        await #expect(throws: expected) {
            try await TranscriptionClient(session: session).transcribe(
                provider: .openAI, apiKey: key, model: "gpt-transcribe", languageCode: nil, wav: audio)
        }
    }

    @Test func errorsNeverRepeatTheKey() throws {
        let body = Data(#"{"error": {"message": "Incorrect API key provided: sk-test-0123456789abcdefghij."}}"#.utf8)
        let message = try #require(TranscriptionRequests.errorMessage(in: body))
        #expect(message.contains(key) == false)
        #expect(message.contains("sk-test") == false)
        for error in [TranscriptionAPIError.invalidKey(.openAI), .badRequest(message), .missingKey(.groq)] {
            #expect(error.localizedDescription.contains(key) == false)
        }
    }

    @Test func anUnreadableAnswerIsAnError() async throws {
        let session = TranscriptionURLProtocol.session(status: 200, body: "<html>")
        await #expect(throws: TranscriptionAPIError.unreadableResponse) {
            try await TranscriptionClient(session: session).transcribe(
                provider: .openAI, apiKey: key, model: "whisper-1", languageCode: nil, wav: audio)
        }
    }

    @Test func testingAKeyListsModelsWithTheKeyInTheHeader() async throws {
        let session = TranscriptionURLProtocol.session(status: 200, body: #"{"data": []}"#)
        try await TranscriptionClient(session: session).testKey(provider: .openAI, apiKey: key)
        let sent = try #require(TranscriptionURLProtocol.lock.withLock { TranscriptionURLProtocol.requests.first })
        #expect(sent.request.url?.absoluteString == "https://api.openai.com/v1/models")
        #expect(sent.request.httpMethod == "GET")
        #expect(sent.request.value(forHTTPHeaderField: "Authorization") == "Bearer \(key)")

        let refused = TranscriptionURLProtocol.session(status: 401, body: "{}")
        await #expect(throws: TranscriptionAPIError.invalidKey(.groq)) {
            try await TranscriptionClient(session: refused).testKey(provider: .groq, apiKey: key)
        }
    }

    @Test func aRecordingTooLargeForTheAPIIsNotSent() async throws {
        let session = TranscriptionURLProtocol.session(status: 200, body: #"{"text": "x"}"#)
        let huge = Data(count: TranscriptionProvider.maximumUploadBytes + 1)
        await #expect(throws: TranscriptionAPIError.tooLarge) {
            try await TranscriptionClient(session: session).transcribe(
                provider: .openAI, apiKey: key, model: "whisper-1", languageCode: nil, wav: huge)
        }
        #expect(TranscriptionURLProtocol.lock.withLock { TranscriptionURLProtocol.requests.isEmpty })
    }

    @Test func modelsAreTheDocumentedOnes() {
        #expect(TranscriptionProvider.openAI.models.map(\.id) == ["gpt-transcribe", "gpt-4o-transcribe", "gpt-4o-mini-transcribe", "whisper-1"])
        #expect(TranscriptionProvider.groq.models.map(\.id) == ["whisper-large-v3-turbo", "whisper-large-v3"])
    }

    @Test func theWAVHeaderDescribesSixteenKilohertzMono() {
        let wav = WAVEncoder.encode(samples: [0, 1, -1], sampleRate: 16_000)
        #expect(wav.count == 44 + 6)
        #expect(String(decoding: wav.prefix(4), as: UTF8.self) == "RIFF")
        #expect(String(decoding: wav[8..<16], as: UTF8.self) == "WAVEfmt ")
        let rate = wav[24..<28].withUnsafeBytes { $0.loadUnaligned(as: UInt32.self) }
        #expect(UInt32(littleEndian: rate) == 16_000)
        let last = wav[48..<50].withUnsafeBytes { $0.loadUnaligned(as: Int16.self) }
        #expect(Int16(littleEndian: last) == -Int16.max)
    }

    @Test func aMissingKeyStopsBeforeRecording() async throws {
        let keys = VoiceKeyStore(store: MemorySecretStore())
        let engine = TranscriptionAPIEngine.make(provider: .openAI, settings: VoiceSettings(), keys: keys)
        await #expect(throws: TranscriptionAPIError.missingKey(.openAI)) { try await engine.prepare { _ in } }
    }
}

// MARK: - Keys

struct VoiceKeyTests {
    @Test func keysAreKeptPerProviderAndTrimmed() throws {
        let memory = MemorySecretStore()
        let keys = VoiceKeyStore(store: memory)
        #expect(keys.hasKey(for: .openAI) == false)
        try keys.setKey("  sk-abc123  \n", for: .openAI)
        #expect(keys.key(for: .openAI) == "sk-abc123")
        #expect(keys.hasKey(for: .groq) == false)
        #expect(Set(memory.allAccounts) == ["openai"])
        try keys.setKey("", for: .openAI)
        #expect(keys.hasKey(for: .openAI) == false)
        try keys.setKey("gsk_x", for: .groq)
        keys.removeKey(for: .groq)
        #expect(memory.allAccounts.isEmpty)
    }
}

struct CodexAPIKeyImportTests {
    private func file(_ json: String) throws -> URL {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("codex-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let url = folder.appendingPathComponent("auth.json")
        try Data(json.utf8).write(to: url)
        return url
    }

    @Test func anAPIKeyLoginIsOffered() throws {
        let url = try file(#"{"OPENAI_API_KEY": "sk-proj-abcdefghijklmnopqrstuvwxyz", "tokens": null, "last_refresh": null}"#)
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        #expect(CodexAPIKeyImport(authFile: url).apiKey() == "sk-proj-abcdefghijklmnopqrstuvwxyz")
    }

    @Test func aChatGPTLoginIsNeverRead() throws {
        // A ChatGPT sign-in keeps tokens and no API key: nothing is offered, and no token is ever returned.
        let url = try file(
            #"{"OPENAI_API_KEY": null, "tokens": {"id_token": "eyJ-id-token-0123456789", "access_token": "eyJ-access-token-0123456789", "refresh_token": "rt-0123456789abcdefghij", "account_id": "acct"}}"#
        )
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        #expect(CodexAPIKeyImport(authFile: url).apiKey() == nil)
        #expect(CodexAPIKeyImport(authFile: url).hasAPIKey == false)
    }

    @Test func onlyTheAPIKeyFieldCounts() {
        #expect(CodexAPIKeyImport.apiKey(in: ["access_token": "sk-looks-like-a-key-0123456789"]) == nil)
        #expect(CodexAPIKeyImport.apiKey(in: ["openai_api_key": "sk-looks-like-a-key-0123456789"]) == nil)
        #expect(CodexAPIKeyImport.apiKey(in: ["OPENAI_API_KEY": "short"]) == nil)
        #expect(CodexAPIKeyImport.apiKey(in: ["OPENAI_API_KEY": "sk with spaces in it 0123456789"]) == nil)
        #expect(CodexAPIKeyImport.apiKey(in: ["OPENAI_API_KEY": 42]) == nil)
    }

    @Test func aMissingOrBrokenFileOffersNothing() throws {
        let missing = FileManager.default.temporaryDirectory.appendingPathComponent("no-such-\(UUID().uuidString)/auth.json")
        #expect(CodexAPIKeyImport(authFile: missing).apiKey() == nil)
        let broken = try file("{not json")
        defer { try? FileManager.default.removeItem(at: broken.deletingLastPathComponent()) }
        #expect(CodexAPIKeyImport(authFile: broken).apiKey() == nil)
    }
}

// MARK: - Whisper models

struct WhisperCatalogTests {
    @Test func theCatalogIsPinnedAndComplete() {
        let catalog = WhisperModel.catalog
        #expect(catalog.map(\.id) == ["tiny", "base", "small", "large-v3-turbo"])
        #expect(WhisperModel.model(id: WhisperModel.defaultID) != nil)
        #expect(Set(catalog.map(\.folder)).count == catalog.count)
        for model in catalog {
            #expect(model.expectedBytes > 50_000_000)
            #expect(model.sources.count == 2)
            #expect(model.sources[0].repo == "argmaxinc/whisperkit-coreml")
            #expect(model.sources[0].prefix == model.folder)
            #expect(model.sources[1].files == ["tokenizer.json", "tokenizer_config.json"])
            for source in model.sources {
                #expect(source.revision.count == 40 && source.revision.allSatisfy(\.isHexDigit))
            }
        }
        #expect(catalog.map(\.expectedBytes) == catalog.map(\.expectedBytes).sorted())
    }

    @Test func aHuggingFaceListingBecomesFilesToCheck() throws {
        let source = ModelSource(repo: "argmaxinc/whisperkit-coreml", revision: String(repeating: "a", count: 40), prefix: "openai_whisper-tiny")
        let entries: [[String: Any]] = [
            ["type": "directory", "path": "openai_whisper-tiny/AudioEncoder.mlmodelc", "size": 0],
            [
                "type": "file", "path": "openai_whisper-tiny/AudioEncoder.mlmodelc/weights/weight.bin", "size": 16_422_784,
                "oid": "1111111111111111111111111111111111111111", "lfs": ["oid": "bcd0879f", "size": 16_422_784],
            ],
            ["type": "file", "path": "openai_whisper-tiny/config.json", "size": 1464, "oid": "543fc73d"],
            ["type": "file", "path": "openai_whisper-base/config.json", "size": 1464, "oid": "other"],
        ]
        let files = try HuggingFaceDownloader.files(in: entries, source: source)
        #expect(files.map(\.path) == ["AudioEncoder.mlmodelc/weights/weight.bin", "config.json"])
        #expect(files[0].checksum == .sha256("bcd0879f"))
        #expect(files[1].checksum == .gitBlobSHA1("543fc73d"))
        #expect(
            files[0].url.absoluteString
                == "https://huggingface.co/argmaxinc/whisperkit-coreml/resolve/\(source.revision)/openai_whisper-tiny/AudioEncoder.mlmodelc/weights/weight.bin")
    }

    @Test func aListingThatClimbsOutOfTheFolderIsRefused() {
        let source = ModelSource(repo: "r", revision: "x", prefix: "m")
        let entries: [[String: Any]] = [["type": "file", "path": "m/../../evil", "size": 1, "oid": "a"]]
        #expect(throws: WhisperModelError.manifestMismatch) { try HuggingFaceDownloader.files(in: entries, source: source) }
    }

    @Test func aTokenizerListingMustHaveBothFiles() {
        let source = ModelSource(repo: "openai/whisper-tiny", revision: "x", files: ["tokenizer.json", "tokenizer_config.json"])
        let entries: [[String: Any]] = [["type": "file", "path": "tokenizer.json", "size": 1, "oid": "a"]]
        #expect(throws: WhisperModelError.manifestMismatch) { try HuggingFaceDownloader.files(in: entries, source: source) }
    }

    @Test func checksumsReadTheContents() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("checksum-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: url) }
        let contents = Data("hello\n".utf8)
        try contents.write(to: url)
        let sha256 = SHA256.hash(data: contents).map { String(format: "%02x", $0) }.joined()
        #expect(try ModelChecksum.sha256(sha256).matches(fileAt: url))
        #expect(try ModelChecksum.sha256(String(repeating: "0", count: 64)).matches(fileAt: url) == false)
        // `git hash-object` of "hello\n".
        #expect(try ModelChecksum.gitBlobSHA1("ce013625030ba8dba906f756967f9e9ca394464a").matches(fileAt: url))
    }
}

/// A downloader that serves files from memory, so no test touches the network.
final class StubModelDownloader: ModelDownloading, @unchecked Sendable {
    struct Served {
        let path: String
        let contents: Data
        /// What the manifest claims, which a test can make wrong.
        let checksum: ModelChecksum
    }

    let files: [ModelSource: [Served]]
    /// Download calls wait here until released, for testing cancel.
    let gate: AsyncStream<Void>?
    private let lock = NSLock()
    private(set) var downloads: [String] = []

    init(files: [ModelSource: [Served]], gate: AsyncStream<Void>? = nil) {
        self.files = files
        self.gate = gate
    }

    static func sha256(_ data: Data) -> ModelChecksum { .sha256(SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()) }

    func manifest(for source: ModelSource) async throws -> [ModelFile] {
        (files[source] ?? []).map {
            ModelFile(path: $0.path, url: URL(string: "https://example.invalid/\($0.path)")!, size: Int64($0.contents.count), checksum: $0.checksum)
        }
    }

    func download(_ file: ModelFile, to destination: URL, progress: @escaping @Sendable (Int64) -> Void) async throws {
        lock.withLock { downloads.append(file.path) }
        if let gate {
            for await _ in gate { break }
            try Task.checkCancellation()
        }
        let served = files.values.joined().first { $0.path == file.path }!
        try served.contents.write(to: destination)
        progress(Int64(served.contents.count))
    }
}

@MainActor
struct WhisperModelManagerTests {
    private let encoder = Data(repeating: 7, count: 4096)
    private let config = Data(#"{"model": "tiny"}"#.utf8)
    private let tokenizer = Data(#"{"tokenizer": true}"#.utf8)
    private let main = ModelSource(repo: "argmaxinc/whisperkit-coreml", revision: "r1", prefix: "test-model")
    private let tokens = ModelSource(repo: "openai/whisper-tiny", revision: "r2", files: ["tokenizer.json"])

    private func model(expectedBytes: Int64? = nil) -> WhisperModel {
        WhisperModel(
            id: "test", name: "Test", detail: "", folder: "test-model", sources: [main, tokens],
            expectedBytes: expectedBytes ?? Int64(encoder.count + config.count + tokenizer.count))
    }

    private func served(encoderChecksum: ModelChecksum? = nil) -> [ModelSource: [StubModelDownloader.Served]] {
        [
            main: [
                .init(path: "AudioEncoder.mlmodelc/weights/weight.bin", contents: encoder, checksum: encoderChecksum ?? StubModelDownloader.sha256(encoder)),
                .init(path: "config.json", contents: config, checksum: StubModelDownloader.sha256(config)),
            ],
            tokens: [.init(path: "tokenizer.json", contents: tokenizer, checksum: StubModelDownloader.sha256(tokenizer))],
        ]
    }

    private func directory() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("whisper-\(UUID().uuidString)", isDirectory: true)
    }

    @Test func nothingIsDownloadedUntilAsked() {
        let folder = directory()
        let downloader = StubModelDownloader(files: served())
        let manager = WhisperModelManager(directory: folder, downloader: downloader, catalog: [model()])
        #expect(manager.state(model()) == .notDownloaded)
        #expect(manager.folder(of: model()) == nil)
        #expect(downloader.downloads.isEmpty)
        #expect(FileManager.default.fileExists(atPath: folder.path) == false)
    }

    @Test func aVerifiedDownloadIsInstalled() async throws {
        let folder = directory()
        defer { try? FileManager.default.removeItem(at: folder) }
        let manager = WhisperModelManager(directory: folder, downloader: StubModelDownloader(files: served()), catalog: [model()])
        manager.download(model())
        #expect(manager.state(model()).fraction != nil)
        await manager.waitForDownload(model())
        #expect(manager.state(model()) == .downloaded)
        let installed = try #require(manager.folder(of: model()))
        #expect(try Data(contentsOf: installed.appendingPathComponent("AudioEncoder.mlmodelc/weights/weight.bin")) == encoder)
        #expect(try Data(contentsOf: installed.appendingPathComponent("tokenizer.json")) == tokenizer)
        let staging = try FileManager.default.contentsOfDirectory(atPath: folder.path).filter { $0.hasPrefix(".download-") }
        #expect(staging.isEmpty)
        // A new manager finds it, as after a relaunch.
        let relaunched = WhisperModelManager(directory: folder, downloader: StubModelDownloader(files: [:]), catalog: [model()])
        #expect(relaunched.state(model()) == .downloaded)

        manager.delete(model())
        #expect(manager.state(model()) == .notDownloaded)
        #expect(FileManager.default.fileExists(atPath: installed.path) == false)
    }

    @Test func aChecksumMismatchInstallsNothing() async throws {
        let folder = directory()
        defer { try? FileManager.default.removeItem(at: folder) }
        let wrong = ModelChecksum.sha256(String(repeating: "0", count: 64))
        let manager = WhisperModelManager(
            directory: folder, downloader: StubModelDownloader(files: served(encoderChecksum: wrong)), catalog: [model()])
        manager.download(model())
        await manager.waitForDownload(model())
        guard case .failed(let message) = manager.state(model()) else {
            Issue.record("Expected a failure, got \(manager.state(model()))")
            return
        }
        #expect(message.contains("AudioEncoder.mlmodelc/weights/weight.bin"))
        #expect(manager.folder(of: model()) == nil)
        let leftovers = (try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []
        #expect(leftovers.isEmpty)
    }

    @Test func aManifestOfTheWrongSizeIsRefusedBeforeDownloading() async throws {
        let folder = directory()
        defer { try? FileManager.default.removeItem(at: folder) }
        let downloader = StubModelDownloader(files: served())
        let manager = WhisperModelManager(directory: folder, downloader: downloader, catalog: [model(expectedBytes: 1)])
        manager.download(model(expectedBytes: 1))
        await manager.waitForDownload(model(expectedBytes: 1))
        #expect(manager.state(model(expectedBytes: 1)) == .failed(WhisperModelError.manifestMismatch.localizedDescription))
        #expect(downloader.downloads.isEmpty)
    }

    @Test func cancellingLeavesNothingBehind() async throws {
        let folder = directory()
        defer { try? FileManager.default.removeItem(at: folder) }
        let (gate, release) = AsyncStream<Void>.makeStream()
        let downloader = StubModelDownloader(files: served(), gate: gate)
        let manager = WhisperModelManager(directory: folder, downloader: downloader, catalog: [model()])
        manager.download(model())
        while downloader.downloads.isEmpty { await Task.yield() }
        manager.cancel(model())
        release.yield()
        release.finish()
        await manager.waitForDownload(model())
        #expect(manager.state(model()) == .notDownloaded)
        #expect(manager.folder(of: model()) == nil)
        let leftovers = (try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []
        #expect(leftovers.isEmpty)
    }
}
