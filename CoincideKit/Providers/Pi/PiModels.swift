import Foundation
import ImageIO
import UniformTypeIdentifiers

/// Pi's model inventory and thinking levels, as reported by `get_available_models` and `get_state`.
enum PiModels {
    /// Uses the model Pi is configured with, without calling `set_model`.
    static let defaultModelID = "default"
    /// Pi's thinking levels, in increasing order.
    static let thinkingLevels = ["off", "minimal", "low", "medium", "high", "xhigh", "max"]
    /// `get_entries` arrived in 0.80.3 and `agent_settled` in 0.80.4; 0.80.5 was the first release with both.
    static let minimumVersion = "0.80.5"

    /// What the picker offers when Pi's inventory is unknown: its configured default.
    static var fallback: [ModelOption] { [defaultOption(active: nil, thinkingLevel: nil)] }

    /// The picker entry for Pi's configured default model, described by the active model in `get_state`.
    static func defaultOption(active: JSONValue?, thinkingLevel: String?) -> ModelOption {
        let efforts = efforts(for: active)
        let name = PiText.nonEmpty(active?["name"]?.string)
        return ModelOption(
            provider: .pi, modelID: defaultModelID,
            displayName: name.map { String(localized: "Default (\($0))") } ?? String(localized: "Default"),
            efforts: efforts, defaultEffort: clamp(thinkingLevel, to: efforts), contextWindow: contextWindow(of: active),
            supportsImages: active.map(acceptsImages) ?? true)
    }

    /// The default entry followed by every available model as `provider/id`. Returns nil when the inventory
    /// is malformed, so a broken response is not mistaken for "no models".
    static func catalog(models data: JSONValue?, state: JSONValue?) -> [ModelOption]? {
        guard let entries = data?["models"]?.array else { return nil }
        let thinkingLevel = state?["thinkingLevel"]?.string
        var seen = Set<String>()
        var models: [(model: JSONValue, slug: String, name: String, provider: String)] = []
        for model in entries {
            guard let slug = slug(of: model), let provider = model["provider"]?.string else { return nil }
            guard seen.insert(slug).inserted else { continue }
            models.append((model, slug, PiText.nonEmpty(model["name"]?.string) ?? slug, provider))
        }
        // The same model is often offered by several providers (Anthropic and OpenRouter, say).
        let nameCounts = Dictionary(models.map { ($0.name, 1) }, uniquingKeysWith: +)
        let options = models.map { entry in
            let efforts = efforts(for: entry.model)
            return ModelOption(
                provider: .pi, modelID: entry.slug,
                displayName: nameCounts[entry.name, default: 0] > 1 ? "\(entry.name) (\(entry.provider))" : entry.name,
                efforts: efforts, defaultEffort: clamp(thinkingLevel, to: efforts),
                contextWindow: contextWindow(of: entry.model), supportsImages: acceptsImages(entry.model))
        }
        return [defaultOption(active: state?["model"], thinkingLevel: thinkingLevel)] + options
    }

    /// Distinct providers with usable models, in Pi's order.
    static func providers(in data: JSONValue?) -> [String] {
        var seen = Set<String>()
        return (data?["models"]?.array ?? []).compactMap { $0["provider"]?.string }.filter { seen.insert($0).inserted }
    }

    /// Levels a model accepts. `xhigh` and `max` need an explicit entry in its `thinkingLevelMap`
    /// (advertising them globally makes `set_thinking_level` fail); a `null` entry removes a level.
    static func efforts(for model: JSONValue?) -> [String] {
        guard let model, model["reasoning"]?.bool == true else { return [] }
        let map = model["thinkingLevelMap"]?.object
        return thinkingLevels.filter { level in
            let mapped = map?[level]
            if mapped?.isNull == true { return false }
            if level == "xhigh" || level == "max" { return mapped != nil }
            return true
        }
    }

    /// The closest level a model accepts: the requested one, else the next higher, else the next lower.
    static func clamp(_ level: String?, to levels: [String]) -> String? {
        guard let level, let requested = thinkingLevels.firstIndex(of: level), !levels.isEmpty else { return nil }
        if levels.contains(level) { return level }
        if let higher = thinkingLevels[(requested + 1)...].first(where: { levels.contains($0) }) { return higher }
        return thinkingLevels[..<requested].reversed().first(where: { levels.contains($0) }) ?? levels.first
    }

    static func slug(of model: JSONValue?) -> String? {
        guard let provider = model?["provider"]?.string, let id = model?["id"]?.string,
            PiText.nonEmpty(provider) != nil, PiText.nonEmpty(id) != nil
        else { return nil }
        return "\(provider)/\(id)"
    }

    /// Splits `provider/model`; the model id itself may contain slashes (`openrouter/deepseek/deepseek-v4`).
    static func parseSlug(_ slug: String) -> (provider: String, modelID: String)? {
        guard let separator = slug.firstIndex(of: "/"), separator != slug.startIndex,
            slug.index(after: separator) != slug.endIndex
        else { return nil }
        return (String(slug[..<separator]), String(slug[slug.index(after: separator)...]))
    }

    static func contextWindow(of model: JSONValue?) -> Int? {
        guard let window = model?["contextWindow"]?.int, window > 0 else { return nil }
        return window
    }

    private static func acceptsImages(_ model: JSONValue) -> Bool {
        model["input"]?.array?.contains(.string("image")) ?? false
    }

    /// The version in `pi --version` output, which is `1.4.0` today and was `pi 0.84.3` before.
    static func version(in output: String) -> String? {
        guard let range = output.range(of: #"\bv?\d+\.\d+\.\d+\b"#, options: .regularExpression) else { return nil }
        let match = output[range]
        return String(match.hasPrefix("v") ? match.dropFirst() : match)
    }

    static func isSupported(version: String) -> Bool {
        version.compare(minimumVersion, options: .numeric) != .orderedAscending
    }
}

/// A turn's handoff recap (see `AgentTurnInput.handoffRecap`) and the user's own message.
///
/// Pi runs slash commands (extension commands, skills, prompt templates and `/compact`) only when the prompt
/// starts with one, so a recap in front would turn the command into plain text. The session then sends the
/// recap on its own first.
struct PiPrompt: Equatable {
    /// Everything before the user's message: the recap and the line that introduces the message.
    var recap: String?
    var message: String

    init(recap: String? = nil, message: String) {
        self.recap = recap.flatMap { $0.isEmpty ? nil : $0 }
        self.message = message
    }

    /// The recap only has to travel separately when the message is a slash command.
    var needsSeparateRecap: Bool { recap != nil && message.hasPrefix("/") }
}

/// `/compact [instructions]`, which Pi only handles in its terminal UI, maps to the RPC `compact` command.
struct PiCompactCommand: Equatable {
    var instructions: String?

    static func parse(_ text: String) -> PiCompactCommand? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.hasPrefix("/compact") else { return nil }
        let rest = trimmed.dropFirst("/compact".count)
        if rest.isEmpty { return PiCompactCommand() }
        guard rest.first?.isWhitespace == true else { return nil }
        return PiCompactCommand(instructions: PiText.nonEmpty(String(rest)))
    }
}

/// Image attachments in the form Pi's `prompt` takes: base64 data with a MIME type.
enum PiImages {
    static func payload(_ paths: [String]) throws -> [JSONValue] {
        try paths.map { path -> JSONValue in
            let url = URL(fileURLWithPath: path)
            guard let data = try? Data(contentsOf: url) else {
                throw AgentError.providerError(String(localized: "Coincide could not read the image \(url.lastPathComponent)."))
            }
            let (bytes, mimeType) = try encodable(data, type: UTType(filenameExtension: url.pathExtension), name: url.lastPathComponent)
            return ["type": "image", "data": .string(bytes.base64EncodedString()), "mimeType": .string(mimeType)]
        }
    }

    /// Pi accepts PNG, JPEG, GIF and WebP; anything else (HEIC, TIFF) is converted to PNG. The type comes from
    /// the image data when ImageIO recognizes it, so a JPEG saved as `.png` is still sent as a JPEG.
    private static func encodable(_ data: Data, type declared: UTType?, name: String) throws -> (Data, String) {
        let accepted: [(UTType, String)] = [(.png, "image/png"), (.jpeg, "image/jpeg"), (.gif, "image/gif"), (.webP, "image/webp")]
        let source = CGImageSourceCreateWithData(data as CFData, nil)
        let detected = source.flatMap { CGImageSourceGetType($0) }.flatMap { UTType($0 as String) }
        if let type = detected ?? declared, let match = accepted.first(where: { type.conforms(to: $0.0) }) {
            return (data, match.1)
        }
        let output = NSMutableData()
        guard let source,
            let destination = CGImageDestinationCreateWithData(output as CFMutableData, UTType.png.identifier as CFString, 1, nil)
        else { throw AgentError.providerError(String(localized: "Pi cannot use the image \(name).")) }
        CGImageDestinationAddImageFromSource(destination, source, 0, nil)
        guard CGImageDestinationFinalize(destination) else {
            throw AgentError.providerError(String(localized: "Pi cannot use the image \(name)."))
        }
        return (output as Data, "image/png")
    }
}
