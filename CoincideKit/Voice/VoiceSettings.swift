import Foundation

/// What turns speech into text for the composer's dictation.
public enum DictationEngineKind: String, Codable, CaseIterable, Sendable {
    /// Apple's on-device speech recognition (`SpeechAnalyzer`, or `SFSpeechRecognizer` where that isn't available).
    case apple
    /// OpenAI's transcription API, with the user's own API key.
    case openAI
    /// Groq's Whisper API, with the user's own API key.
    case groq
    /// Whisper running on this Mac (WhisperKit), with a model the user downloads in Settings › Voice.
    case whisper

    public nonisolated var displayName: String {
        switch self {
        case .apple: String(localized: "Apple (on device)")
        case .openAI: "OpenAI"
        case .groq: "Groq"
        case .whisper: String(localized: "Whisper (on this Mac)")
        }
    }

    /// Whether the audio leaves the Mac.
    public nonisolated var sendsAudioToProvider: Bool { self == .openAI || self == .groq }
}

/// What the dictation shortcut does when pressed: hold to talk, tap to start and stop, or both.
public enum DictationShortcutMode: String, Codable, CaseIterable, Sendable {
    /// Hold past `DictationTriggerMachine.holdThreshold` to talk until release; a quick tap starts, the next one stops.
    case both
    case hold
    case tap

    public nonisolated var displayName: String {
        switch self {
        case .both: String(localized: "Hold to talk, tap to toggle")
        case .hold: String(localized: "Hold only")
        case .tap: String(localized: "Tap only")
        }
    }
}

/// A modifier key pressed on its own as the dictation shortcut.
public enum DictationModifierKey: String, Codable, CaseIterable, Sendable {
    /// The Fn (🌐) key.
    case fn
    case control
    case option
    case shift
    case command

    public nonisolated var glyph: String {
        switch self {
        case .fn: "🌐 fn"
        case .control: "⌃"
        case .option: "⌥"
        case .shift: "⇧"
        case .command: "⌘"
        }
    }

    public nonisolated var spokenName: String {
        switch self {
        case .fn: String(localized: "Fn")
        case .control: String(localized: "Control")
        case .option: String(localized: "Option")
        case .shift: String(localized: "Shift")
        case .command: String(localized: "key.command", defaultValue: "Command", comment: "Spoken name of the ⌘ key")
        }
    }
}

/// The key that starts and stops dictation: a modifier on its own (Fn by default), or a key with modifiers such as ⌥Space.
public enum DictationShortcut: Hashable, Sendable, Codable, CustomStringConvertible {
    case modifier(DictationModifierKey)
    case keys(KeyShortcut)

    public nonisolated static let `default` = DictationShortcut.modifier(.fn)

    /// "fn", "option" for a lone modifier; T3-style text such as "alt+space" for keys.
    public nonisolated var stringValue: String {
        switch self {
        case .modifier(let key): key.rawValue
        case .keys(let shortcut): shortcut.stringValue
        }
    }

    /// Reads `stringValue` back. A key needs a modifier (or is a function key), so dictation never takes a typing key.
    public nonisolated init?(_ text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if let key = DictationModifierKey(rawValue: trimmed) {
            self = .modifier(key)
        } else if let shortcut = KeyShortcut(trimmed), Self.isUsable(shortcut) {
            self = .keys(shortcut)
        } else {
            return nil
        }
    }

    /// A key shortcut works for dictation when it has Command, Control or Option, or is a function key: Shift alone or
    /// no modifier would take the key from typing. Escape is kept for cancelling.
    public nonisolated static func isUsable(_ shortcut: KeyShortcut) -> Bool {
        if shortcut.key == "esc" { return false }
        return !shortcut.modifiers.isDisjoint(with: [.command, .control, .option]) || shortcut.key.hasPrefix("f") && shortcut.key.count > 1
            && Int(shortcut.key.dropFirst()) != nil
    }

    public nonisolated var displayString: String {
        switch self {
        case .modifier(let key): key.glyph
        case .keys(let shortcut): shortcut.displayString
        }
    }

    public nonisolated var spokenDescription: String {
        switch self {
        case .modifier(let key): key.spokenName
        case .keys(let shortcut): shortcut.spokenDescription
        }
    }

    public nonisolated var description: String { stringValue }

    public nonisolated var isLoneModifier: Bool {
        if case .modifier = self { return true }
        return false
    }

    public nonisolated init(from decoder: Decoder) throws {
        let text = try decoder.singleValueContainer().decode(String.self)
        guard let value = DictationShortcut(text) else {
            throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath, debugDescription: "Not a dictation shortcut"))
        }
        self = value
    }

    public nonisolated func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(stringValue)
    }
}

/// Settings › Voice: dictation in the composer.
public struct VoiceSettings: Codable, Hashable, Sendable {
    /// The composer shows the microphone button. On by default; the microphone permission is asked for on first use.
    public var isEnabled: Bool
    public var engine: DictationEngineKind
    /// "auto", or a locale identifier such as "en-US" (`DictationLanguage`).
    public var language: String
    /// The keyboard shortcut is off by default: no keys are watched until the user turns it on.
    public var shortcutEnabled: Bool
    public var shortcut: DictationShortcut
    public var shortcutMode: DictationShortcutMode
    /// Send the message when dictation stops. Off by default: the text waits in the composer.
    public var sendsWhenStopped: Bool
    /// The model OpenAI transcribes with (`TranscriptionProvider.openAI.models`).
    public var openAIModel: String
    /// The model Groq transcribes with.
    public var groqModel: String
    /// The Whisper model run on this Mac, by `WhisperModel.id`.
    public var whisperModel: String
    /// The Core Audio unique ID of the microphone; nil for the system's default input.
    public var inputDeviceUID: String?

    public nonisolated init() {
        isEnabled = true
        engine = .apple
        language = DictationLanguage.automatic
        shortcutEnabled = false
        shortcut = .default
        shortcutMode = .both
        sendsWhenStopped = false
        openAIModel = TranscriptionProvider.openAI.defaultModel
        groqModel = TranscriptionProvider.groq.defaultModel
        whisperModel = WhisperModel.defaultID
        inputDeviceUID = nil
    }

    public nonisolated init(from decoder: Decoder) throws {
        let defaults = VoiceSettings()
        let container = try decoder.container(keyedBy: CodingKeys.self)
        func value<T: Decodable>(_ key: CodingKeys, _ fallback: T) -> T {
            (try? container.decodeIfPresent(T.self, forKey: key)) ?? fallback
        }
        isEnabled = value(.isEnabled, defaults.isEnabled)
        engine = value(.engine, defaults.engine)
        language = value(.language, defaults.language)
        shortcutEnabled = value(.shortcutEnabled, defaults.shortcutEnabled)
        shortcut = value(.shortcut, defaults.shortcut)
        shortcutMode = value(.shortcutMode, defaults.shortcutMode)
        sendsWhenStopped = value(.sendsWhenStopped, defaults.sendsWhenStopped)
        openAIModel = value(.openAIModel, defaults.openAIModel)
        groqModel = value(.groqModel, defaults.groqModel)
        whisperModel = value(.whisperModel, defaults.whisperModel)
        inputDeviceUID = value(.inputDeviceUID, defaults.inputDeviceUID)
        if language.trimmingCharacters(in: .whitespaces).isEmpty { language = DictationLanguage.automatic }
        if WhisperModel.model(id: whisperModel) == nil { whisperModel = defaults.whisperModel }
    }

    /// The model the chosen API engine uses, or nil for an engine on the Mac.
    public nonisolated func model(for provider: TranscriptionProvider) -> String {
        switch provider {
        case .openAI: openAIModel
        case .groq: groqModel
        }
    }
}

/// The languages dictation offers. "Automatic" is the Mac's language for Apple's recognizer, which needs one, and lets
/// the other engines detect the language.
public enum DictationLanguage {
    public nonisolated static let automatic = "auto"

    /// Locale identifiers offered besides Automatic.
    public nonisolated static let identifiers: [String] = [
        "en-US", "en-GB", "en-AU", "en-IN", "es-ES", "es-MX", "fr-FR", "fr-CA", "de-DE", "it-IT", "pt-BR", "pt-PT", "nl-NL",
        "sv-SE", "da-DK", "nb-NO", "fi-FI", "pl-PL", "cs-CZ", "ru-RU", "uk-UA", "tr-TR", "el-GR", "ar-SA", "he-IL", "hi-IN",
        "th-TH", "vi-VN", "id-ID", "ms-MY", "ja-JP", "ko-KR", "zh-CN", "zh-TW", "zh-HK",
    ]

    /// The language's name in the interface's language, such as "German (Germany)".
    public nonisolated static func displayName(_ identifier: String, locale: Locale = .current) -> String {
        if identifier == automatic { return String(localized: "Automatic") }
        return locale.localizedString(forIdentifier: identifier) ?? identifier
    }

    /// The locale Apple's recognizer listens for: the chosen one, or the Mac's for Automatic.
    public nonisolated static func appleLocale(for identifier: String, current: Locale = .autoupdatingCurrent) -> Locale {
        identifier == automatic ? current : Locale(identifier: identifier)
    }

    /// The ISO 639-1 code the transcription APIs and Whisper take ("de"), or nil for Automatic, which lets them
    /// detect the language.
    public nonisolated static func isoCode(for identifier: String) -> String? {
        guard identifier != automatic else { return nil }
        return Locale(identifier: identifier).language.languageCode?.identifier
    }
}

/// What dictation does when it stops: sending is opt-in (`VoiceSettings.sendsWhenStopped`), and only a dictation that
/// inserted text and wasn't cancelled sends.
public enum DictationCompletion {
    public nonisolated static func shouldSend(settings: VoiceSettings, transcript: String, cancelled: Bool) -> Bool {
        settings.sendsWhenStopped && !cancelled && !transcript.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
}
