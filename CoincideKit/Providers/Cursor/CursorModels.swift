import Foundation

/// One select option from Cursor's ACP `configOptions`: the mode, the model, or a model
/// parameter such as reasoning effort (`thought_level`) or context size.
struct CursorConfigOption: Hashable, Sendable {
    var id: String
    var category: String?
    var currentValue: String?
    var values: [String]

    nonisolated init(id: String, category: String? = nil, currentValue: String? = nil, values: [String] = []) {
        self.id = id
        self.category = category
        self.currentValue = currentValue
        self.values = values
    }

    nonisolated init?(_ json: JSONValue) {
        guard let id = json["id"]?.string, !id.isEmpty else { return nil }
        self.id = id
        category = json["category"]?.string
        currentValue = json["currentValue"].flatMap { $0.isNull ? nil : $0.displayText }
        // Options may be flat or grouped (`{group, options: [...]}`).
        values = (json["options"]?.array ?? []).flatMap { option -> [String] in
            if let value = option["value"] { return [value.displayText] }
            return (option["options"]?.array ?? []).compactMap { $0["value"]?.displayText }
        }
    }

    nonisolated var isThoughtLevel: Bool { category == "thought_level" }
    nonisolated var isContextSize: Bool { id == "context" || id == "contextWindow" }

    nonisolated static func list(_ json: JSONValue?) -> [CursorConfigOption] {
        (json?.array ?? []).compactMap(CursorConfigOption.init)
    }
}

enum CursorModels {
    /// The model of the user's own Cursor CLI settings. Coincide never sends this id to Cursor; a session
    /// switches to that model when Cursor runs another, for example in a reopened chat that last used one.
    nonisolated static let defaultModelID = "default"

    /// Cursor's own default model, offered when the CLI cannot be asked for the account's models.
    nonisolated static let fallback = [
        ModelOption(provider: .cursor, modelID: "composer-2.5", displayName: "Composer 2.5")
    ]

    nonisolated static func defaultOption(currentModelName: String?) -> ModelOption {
        let name = currentModelName.map(cleanName).flatMap { $0.isEmpty ? nil : $0 }
        return ModelOption(
            provider: .cursor, modelID: defaultModelID,
            displayName: name.map { String(localized: "Default (\($0))") } ?? String(localized: "Default"))
    }

    /// Puts the default entry first unless Cursor itself lists a model with that id.
    nonisolated static func withDefault(_ models: [ModelOption], currentModelName: String?) -> [ModelOption] {
        if models.contains(where: { $0.modelID == defaultModelID }) { return models }
        return [defaultOption(currentModelName: currentModelName)] + models
    }

    /// Models from the `cursor/list_available_models` ACP extension. Each may carry parameter
    /// options; a `thought_level` one supplies the efforts and a `context` one the context window.
    nonisolated static func catalog(_ result: JSONValue) -> [ModelOption] {
        var seen = Set<String>()
        return (result["models"]?.array ?? []).compactMap { entry in
            guard let id = (entry["value"] ?? entry["modelId"])?.string?.trimmingCharacters(in: .whitespaces),
                !id.isEmpty, seen.insert(id).inserted
            else { return nil }
            let options = CursorConfigOption.list(entry["configOptions"])
            let effort = options.first(where: \.isThoughtLevel)
            let context = options.first(where: \.isContextSize)
            let name = cleanName(entry["name"]?.string ?? "")
            return ModelOption(
                provider: .cursor, modelID: id, displayName: name.isEmpty ? id : name, efforts: effort?.values ?? [],
                defaultEffort: effort?.currentValue, contextWindow: contextWindow(context?.currentValue))
        }
    }

    /// Parses `cursor-agent models`, whose lines look like `grok-4.7-high - Grok 4.7 High (default)`.
    nonisolated static func parseModelsCommand(_ output: String) -> [ModelOption] {
        var seen = Set<String>()
        var models: [ModelOption] = []
        for rawLine in CursorConnection.stripANSI(output).split(whereSeparator: \.isNewline) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            guard let separator = line.range(of: " - ") else { continue }
            let id = String(line[..<separator.lowerBound])
            guard !id.isEmpty, !id.contains(" "), seen.insert(id).inserted else { continue }
            var name = cleanName(String(line[separator.upperBound...]))
            for marker in [" (default)", " (current)"] where name.hasSuffix(marker) {
                name.removeLast(marker.count)
            }
            models.append(ModelOption(provider: .cursor, modelID: id, displayName: name.isEmpty ? id : name))
        }
        return models
    }

    /// Context sizes such as `272k`, `1m` or `200000`.
    nonisolated static func contextWindow(_ value: String?) -> Int? {
        guard var text = value?.trimmingCharacters(in: .whitespaces).lowercased(), !text.isEmpty else { return nil }
        var multiplier = 1
        if text.hasSuffix("k") {
            multiplier = 1_000
            text.removeLast()
        } else if text.hasSuffix("m") {
            multiplier = 1_000_000
            text.removeLast()
        }
        guard let number = Double(text), number > 0 else { return nil }
        // nil for a size too large for an Int (`1e19`, `inf`) rather than trapping.
        return Int(exactly: (number * Double(multiplier)).rounded(.towardZero))
    }

    /// The `context` parameter of a bracketed model id such as `grok-4.7[context=256k,fast=false]`.
    nonisolated static func contextWindow(modelID: String) -> Int? {
        guard let open = modelID.firstIndex(of: "["), modelID.hasSuffix("]") else { return nil }
        let parameters = modelID[modelID.index(after: open)..<modelID.index(before: modelID.endIndex)]
        for pair in parameters.split(separator: ",") {
            let parts = pair.split(separator: "=", maxSplits: 1)
            if parts.count == 2, parts[0].trimmingCharacters(in: .whitespaces) == "context" {
                return contextWindow(String(parts[1]))
            }
        }
        return nil
    }

    /// Cursor pads some names with zero-width spaces and double spaces.
    nonisolated static func cleanName(_ name: String) -> String {
        let invisible: Set<Character> = ["\u{200B}", "\u{200C}", "\u{200D}", "\u{2060}", "\u{FEFF}"]
        return name.filter { !invisible.contains($0) }.split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }
}
