import Foundation

/// The API keys of the transcription providers: one Keychain item each, under Coincide's own service (the Debug build
/// has its own), never in settings, logs or URLs.
public struct VoiceKeyStore: Sendable {
    public nonisolated static let standard = VoiceKeyStore(store: KeychainSecretStore(service: CoincideIdentity.scoped("voice")))

    private let store: any SecretStore

    public nonisolated init(store: any SecretStore) {
        self.store = store
    }

    public nonisolated func key(for provider: TranscriptionProvider) -> String? {
        guard let key = store.read(provider.keychainAccount)?.trimmingCharacters(in: .whitespacesAndNewlines), !key.isEmpty
        else { return nil }
        return key
    }

    public nonisolated func hasKey(for provider: TranscriptionProvider) -> Bool { key(for: provider) != nil }

    public nonisolated func setKey(_ key: String, for provider: TranscriptionProvider) throws {
        let trimmed = key.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return removeKey(for: provider) }
        try store.write(trimmed, for: provider.keychainAccount)
    }

    public nonisolated func removeKey(for provider: TranscriptionProvider) {
        store.delete(provider.keychainAccount)
    }
}

/// Reads the OpenAI API key a Codex CLI signed in with an API key keeps in `~/.codex/auth.json`
/// (`"OPENAI_API_KEY": "sk-…"`). Only that field is read: a ChatGPT sign-in's tokens in the same file are never looked
/// at, used or copied. Settings › Voice offers it only when it's there, and copies it to Coincide's Keychain only after
/// the user confirms.
public struct CodexAPIKeyImport: Sendable {
    public let authFile: URL

    public nonisolated init(authFile: URL) {
        self.authFile = authFile
    }

    /// `$CODEX_HOME/auth.json`, or `~/.codex/auth.json`.
    public nonisolated static var standard: CodexAPIKeyImport {
        let environment = ProcessInfo.processInfo.environment
        let home =
            environment["CODEX_HOME"].flatMap { $0.isEmpty ? nil : URL(fileURLWithPath: $0, isDirectory: true) }
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".codex", isDirectory: true)
        return CodexAPIKeyImport(authFile: home.appendingPathComponent("auth.json"))
    }

    /// The API key, or nil when the file is missing, unreadable, or Codex signed in with ChatGPT.
    public nonisolated func apiKey() -> String? {
        guard let data = try? Data(contentsOf: authFile, options: [.uncached]), data.count < 1_000_000,
            let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return nil }
        return Self.apiKey(in: object)
    }

    /// Whether there's a key to offer, without keeping it.
    public nonisolated var hasAPIKey: Bool { apiKey() != nil }

    /// `OPENAI_API_KEY` of the parsed file, when it's a plausible key. No other field is touched.
    nonisolated static func apiKey(in object: [String: Any]) -> String? {
        guard let key = (object["OPENAI_API_KEY"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines), key.count >= 20,
            !key.contains(where: \.isWhitespace)
        else { return nil }
        return key
    }
}
