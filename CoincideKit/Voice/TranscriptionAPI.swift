import Foundation

/// A transcription API the user brings their own key for. The key goes in the `Authorization` header only, never in a
/// URL, a log or an error message.
public enum TranscriptionProvider: String, CaseIterable, Sendable {
    case openAI
    case groq

    public nonisolated var displayName: String {
        switch self {
        case .openAI: "OpenAI"
        case .groq: "Groq"
        }
    }

    public nonisolated var engine: DictationEngineKind {
        switch self {
        case .openAI: .openAI
        case .groq: .groq
        }
    }

    public nonisolated init?(engine: DictationEngineKind) {
        switch engine {
        case .openAI: self = .openAI
        case .groq: self = .groq
        case .apple, .whisper: return nil
        }
    }

    /// The OpenAI-compatible API root; transcriptions are at `audio/transcriptions`.
    public nonisolated var baseURL: URL {
        switch self {
        case .openAI: URL(string: "https://api.openai.com/v1/")!
        case .groq: URL(string: "https://api.groq.com/openai/v1/")!
        }
    }

    /// Where the user creates a key.
    public nonisolated var keysPage: URL {
        switch self {
        case .openAI: URL(string: "https://platform.openai.com/api-keys")!
        case .groq: URL(string: "https://console.groq.com/keys")!
        }
    }

    /// The Keychain item the key is kept in (`VoiceKeyStore`).
    public nonisolated var keychainAccount: String {
        switch self {
        case .openAI: "openai"
        case .groq: "groq"
        }
    }

    /// The models offered, checked against the providers' documentation (October 2026): OpenAI's
    /// `/v1/audio/transcriptions` models, and Groq's Whisper models.
    public nonisolated var models: [TranscriptionModelOption] {
        switch self {
        case .openAI:
            [
                TranscriptionModelOption(id: "gpt-transcribe", name: "GPT Transcribe", detail: String(localized: "Recommended")),
                TranscriptionModelOption(
                    id: "gpt-4o-transcribe", name: "GPT-4o Transcribe", detail: String(localized: "Retires February 2027")),
                TranscriptionModelOption(
                    id: "gpt-4o-mini-transcribe", name: "GPT-4o mini Transcribe", detail: String(localized: "Retires February 2027")),
                TranscriptionModelOption(id: "whisper-1", name: "Whisper", detail: String(localized: "Retires February 2027")),
            ]
        case .groq:
            [
                TranscriptionModelOption(
                    id: "whisper-large-v3-turbo", name: "Whisper Large v3 Turbo", detail: String(localized: "Faster")),
                TranscriptionModelOption(id: "whisper-large-v3", name: "Whisper Large v3", detail: String(localized: "More accurate")),
            ]
        }
    }

    public nonisolated var defaultModel: String { models[0].id }

    /// Most audio either API takes in one request.
    public nonisolated static let maximumUploadBytes = 25 * 1024 * 1024
}

public struct TranscriptionModelOption: Hashable, Sendable, Identifiable {
    public let id: String
    public let name: String
    public let detail: String
}

/// Why a transcription request failed, in words the user can act on. Never includes the key.
public enum TranscriptionAPIError: LocalizedError, Equatable, Sendable {
    case missingKey(TranscriptionProvider)
    case invalidKey(TranscriptionProvider)
    case forbidden(TranscriptionProvider, String?)
    case rateLimited(TranscriptionProvider, String?)
    case tooLarge
    case badRequest(String?)
    case server(Int, String?)
    case network(String)
    case unreadableResponse

    public nonisolated var errorDescription: String? {
        switch self {
        case .missingKey(let provider):
            String(localized: "Add your \(provider.displayName) API key in Settings › Voice.")
        case .invalidKey(let provider):
            String(localized: "\(provider.displayName) didn’t accept the API key. Check it in Settings › Voice.")
        case .forbidden(let provider, let message):
            message ?? String(localized: "\(provider.displayName) refused the request. The key may not have access to this model.")
        case .rateLimited(let provider, let message):
            message ?? String(localized: "\(provider.displayName) is limiting requests or the account is out of credit. Try again later.")
        case .tooLarge:
            String(localized: "The recording is too long to send. Dictate in shorter parts.")
        case .badRequest(let message):
            message ?? String(localized: "The provider couldn’t read the recording.")
        case .server(let status, let message):
            message ?? String(localized: "The provider had a problem (HTTP \(status)). Try again.")
        case .network(let message):
            String(localized: "Couldn’t reach the provider: \(message)")
        case .unreadableResponse:
            String(localized: "The provider’s answer couldn’t be read.")
        }
    }
}

/// Builds and reads transcription requests. Separate from sending them so tests can check the exact bytes.
public enum TranscriptionRequests {
    /// A `multipart/form-data` POST to `audio/transcriptions` with the WAV `audio`.
    public nonisolated static func transcription(
        provider: TranscriptionProvider, apiKey: String, model: String, languageCode: String?, audio: Data,
        boundary: String = "coincide-\(UUID().uuidString)"
    ) -> URLRequest {
        var request = URLRequest(url: provider.baseURL.appendingPathComponent("audio/transcriptions"))
        request.httpMethod = "POST"
        request.timeoutInterval = 120
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        var body = MultipartBody(boundary: boundary)
        body.addField("model", model)
        body.addField("response_format", "json")
        if let languageCode, !languageCode.isEmpty {
            // OpenAI's gpt-transcribe takes a list of the languages to expect instead of one.
            if provider == .openAI, model == "gpt-transcribe" {
                body.addField("languages[]", languageCode)
            } else {
                body.addField("language", languageCode)
            }
        }
        body.addFile("file", fileName: "dictation.wav", contentType: "audio/wav", data: audio)
        request.httpBody = body.finished()
        return request
    }

    /// Lists the account's models: a cheap request that tells whether the key works.
    public nonisolated static func models(provider: TranscriptionProvider, apiKey: String) -> URLRequest {
        var request = URLRequest(url: provider.baseURL.appendingPathComponent("models"))
        request.httpMethod = "GET"
        request.timeoutInterval = 20
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        return request
    }

    /// The transcript of a successful response, or the error a failed one stands for.
    public nonisolated static func transcript(provider: TranscriptionProvider, data: Data, response: URLResponse) throws -> String {
        try check(provider: provider, data: data, response: response)
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any], let text = object["text"] as? String else {
            throw TranscriptionAPIError.unreadableResponse
        }
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Throws the error a non-2xx response stands for.
    public nonisolated static func check(provider: TranscriptionProvider, data: Data, response: URLResponse) throws {
        guard let http = response as? HTTPURLResponse else { throw TranscriptionAPIError.unreadableResponse }
        guard !(200..<300).contains(http.statusCode) else { return }
        let message = errorMessage(in: data)
        switch http.statusCode {
        // The providers' 401 messages can quote part of the key; ours never does.
        case 401: throw TranscriptionAPIError.invalidKey(provider)
        case 403: throw TranscriptionAPIError.forbidden(provider, message)
        case 413: throw TranscriptionAPIError.tooLarge
        case 429: throw TranscriptionAPIError.rateLimited(provider, message)
        case 400..<500: throw TranscriptionAPIError.badRequest(message)
        default: throw TranscriptionAPIError.server(http.statusCode, message)
        }
    }

    /// `error.message` of an OpenAI-style error body, without anything that looks like a key.
    nonisolated static func errorMessage(in data: Data) -> String? {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let error = object["error"] as? [String: Any], let message = error["message"] as? String
        else { return nil }
        let trimmed = message.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let redacted = trimmed.replacingOccurrences(of: #"(sk|gsk)[-_][A-Za-z0-9_\-\*]{4,}"#, with: "…", options: .regularExpression)
        return String(redacted.prefix(300))
    }
}

/// Sends dictated audio to a transcription API.
public struct TranscriptionClient: Sendable {
    public let session: URLSession

    public nonisolated init(session: URLSession = .shared) {
        self.session = session
    }

    public nonisolated func transcribe(
        provider: TranscriptionProvider, apiKey: String, model: String, languageCode: String?, wav: Data
    ) async throws -> String {
        guard wav.count <= TranscriptionProvider.maximumUploadBytes else { throw TranscriptionAPIError.tooLarge }
        let request = TranscriptionRequests.transcription(
            provider: provider, apiKey: apiKey, model: model, languageCode: languageCode, audio: wav)
        let (data, response) = try await send(request)
        return try TranscriptionRequests.transcript(provider: provider, data: data, response: response)
    }

    /// Checks that the key is accepted, without sending audio.
    public nonisolated func testKey(provider: TranscriptionProvider, apiKey: String) async throws {
        let (data, response) = try await send(TranscriptionRequests.models(provider: provider, apiKey: apiKey))
        try TranscriptionRequests.check(provider: provider, data: data, response: response)
    }

    private nonisolated func send(_ request: URLRequest) async throws -> (Data, URLResponse) {
        do {
            return try await session.data(for: request)
        } catch let error as URLError where error.code == .cancelled {
            throw CancellationError()
        } catch let error as URLError {
            throw TranscriptionAPIError.network(error.localizedDescription)
        }
    }
}

/// A `multipart/form-data` body (RFC 7578).
struct MultipartBody {
    let boundary: String
    private var data = Data()

    nonisolated init(boundary: String) {
        self.boundary = boundary
    }

    nonisolated mutating func addField(_ name: String, _ value: String) {
        data.append(Data("--\(boundary)\r\nContent-Disposition: form-data; name=\"\(name)\"\r\n\r\n\(value)\r\n".utf8))
    }

    nonisolated mutating func addFile(_ name: String, fileName: String, contentType: String, data file: Data) {
        data.append(
            Data(
                "--\(boundary)\r\nContent-Disposition: form-data; name=\"\(name)\"; filename=\"\(fileName)\"\r\nContent-Type: \(contentType)\r\n\r\n"
                    .utf8))
        data.append(file)
        data.append(Data("\r\n".utf8))
    }

    nonisolated func finished() -> Data {
        data + Data("--\(boundary)--\r\n".utf8)
    }
}

/// 16-bit PCM WAV, mono, for uploads: built in memory, so the recording never touches the disk.
public enum WAVEncoder {
    public nonisolated static func encode(samples: [Float], sampleRate: Int) -> Data {
        let dataSize = samples.count * 2
        var data = Data(capacity: 44 + dataSize)
        func append<T: FixedWidthInteger>(_ value: T) {
            withUnsafeBytes(of: value.littleEndian) { data.append(contentsOf: $0) }
        }
        data.append(Data("RIFF".utf8))
        append(UInt32(36 + dataSize))
        data.append(Data("WAVEfmt ".utf8))
        append(UInt32(16))  // fmt chunk size
        append(UInt16(1))  // PCM
        append(UInt16(1))  // mono
        append(UInt32(sampleRate))
        append(UInt32(sampleRate * 2))  // byte rate
        append(UInt16(2))  // block align
        append(UInt16(16))  // bits per sample
        data.append(Data("data".utf8))
        append(UInt32(dataSize))
        for sample in samples {
            let clipped = max(-1, min(1, sample))
            append(Int16(clipped * Float(Int16.max)))
        }
        return data
    }
}
