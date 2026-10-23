import Foundation

/// The selected native runtime supplies selectable model rows and capabilities.
/// Pinned T3 profiles supply only their documented aliases/option lowering; they
/// never manufacture a model row or override a native negative capability.
enum ClaudeModelCatalog {
    struct Profile {
        let name: String
        let aliases: [String]
        let defaultEffort: String?
        let effortMap: [String: String]
        let promptEffort: Bool
        let ultracode: Bool
        let thinking: Bool
        let contextWindows: [String]
        let minimumVersion: String?
    }
    private static let profiles: [Profile] = [
        .init(name: "claude-opus-5-5", aliases: ["opus-5.5", "claude-opus-5.5"], defaultEffort: "medium", effortMap: [:], promptEffort: true, ultracode: true, thinking: false, contextWindows: [], minimumVersion: "2.1.280"),
        .init(name: "claude-sonnet-5-5", aliases: ["sonnet-5.5", "claude-sonnet-5.5"], defaultEffort: "high", effortMap: [:], promptEffort: true, ultracode: false, thinking: false, contextWindows: [], minimumVersion: "2.1.284"),
        .init(name: "claude-fable-5-1", aliases: ["fable-5.1", "claude-fable-5.1"], defaultEffort: "medium", effortMap: [:], promptEffort: true, ultracode: true, thinking: false, contextWindows: [], minimumVersion: "2.1.257"),
        .init(name: "claude-fable-5", aliases: [], defaultEffort: "medium", effortMap: [:], promptEffort: true, ultracode: true, thinking: false, contextWindows: [], minimumVersion: "2.1.169"),
        .init(name: "claude-opus-5", aliases: ["opus-5", "claude-opus-5.0", "claude-opus-5-0"], defaultEffort: "high", effortMap: [:], promptEffort: true, ultracode: true, thinking: false, contextWindows: [], minimumVersion: "2.1.219"),
        .init(name: "claude-opus-4-8", aliases: ["opus-4.8", "claude-opus-4.8"], defaultEffort: "high", effortMap: [:], promptEffort: true, ultracode: true, thinking: false, contextWindows: [], minimumVersion: "2.1.154"),
        .init(name: "claude-opus-4-7", aliases: ["opus-4.7", "claude-opus-4.7"], defaultEffort: "xhigh", effortMap: ["xhigh": "max"], promptEffort: true, ultracode: false, thinking: false, contextWindows: [], minimumVersion: "2.1.111"),
        .init(name: "claude-opus-4-6", aliases: ["opus-4.6", "claude-opus-4.6", "claude-opus-4-6-20251117"], defaultEffort: "high", effortMap: [:], promptEffort: true, ultracode: false, thinking: false, contextWindows: ["200k", "1m"], minimumVersion: nil),
        .init(name: "claude-opus-4-5", aliases: [], defaultEffort: "high", effortMap: [:], promptEffort: false, ultracode: false, thinking: false, contextWindows: [], minimumVersion: nil),
        .init(name: "claude-sonnet-5", aliases: ["sonnet-5", "claude-sonnet-5.0", "claude-sonnet-5-0"], defaultEffort: "high", effortMap: [:], promptEffort: true, ultracode: false, thinking: false, contextWindows: [], minimumVersion: nil),
        .init(name: "claude-sonnet-4-6", aliases: ["sonnet-4.6", "claude-sonnet-4.6", "claude-sonnet-4-6-20251117"], defaultEffort: "high", effortMap: ["max": "high"], promptEffort: true, ultracode: false, thinking: false, contextWindows: ["200k", "1m"], minimumVersion: nil),
        .init(name: "claude-haiku-5-5", aliases: ["haiku-5.5", "claude-haiku-5.5"], defaultEffort: "medium", effortMap: [:], promptEffort: true, ultracode: false, thinking: false, contextWindows: [], minimumVersion: "2.1.293"),
        .init(name: "claude-haiku-4-5", aliases: ["haiku-4.5", "claude-haiku-4.5", "claude-haiku-4-5-20251001"], defaultEffort: nil, effortMap: [:], promptEffort: false, ultracode: false, thinking: true, contextWindows: [], minimumVersion: nil)
    ]

    static func models(_ value: JSONValue, version: String? = nil) throws -> [ProviderModel] {
        guard value != .null else { return [] }
        guard let rows = value.array, rows.count <= 2_048 else { throw invalidCatalog() }
        var result: [ProviderModel] = [], seen: [String: ProviderModel] = [:]
        for row in rows {
            guard row.object != nil, let id = try string(row["value"] == .null ? row["id"] : row["value"], maximum: 4_096) else { throw invalidCatalog() }
            let name = try string(row["displayName"], maximum: 16_384) ?? id
            let resolved = try string(row["resolvedModel"], maximum: 4_096)
            let description = try string(row["description"], maximum: 16_384, allowEmpty: true, allowMultiline: true)
            let supportsEffort = try flag(row["supportsEffort"]), supportsFast = try flag(row["supportsFastMode"])
            let supportsAdaptive = try flag(row["supportsAdaptiveThinking"])
            let nativeEfforts: [String]
            if row["supportedEffortLevels"] == .null { nativeEfforts = [] }
            else {
                guard let values = row["supportedEffortLevels"].array, values.count <= 32 else { throw invalidCatalog() }
                nativeEfforts = try values.map { value in
                    guard let effort = try string(value, maximum: 128), ["low", "medium", "high", "xhigh", "max"].contains(effort) else { throw invalidCatalog() }
                    return effort
                }
                guard Set(nativeEfforts).count == nativeEfforts.count else { throw invalidCatalog() }
            }
            guard supportsEffort != false || nativeEfforts.isEmpty else { throw invalidCatalog() }
            let profile = profile(resolved ?? id)
            if let minimum = profile?.minimumVersion, let version, let comparison = compareVersions(version, minimum), comparison < 0 { continue }
            var efforts = supportsEffort == true ? nativeEfforts : []
            if supportsEffort == true, let profile {
                for key in profile.effortMap.keys.sorted() where nativeEfforts.contains(profile.effortMap[key]!) && !efforts.contains(key) { efforts.append(key) }
                if profile.ultracode, nativeEfforts.contains("xhigh") { efforts.append("ultracode") }
                if profile.promptEffort, let fallback = profile.defaultEffort,
                   nativeEfforts.contains(profile.effortMap[fallback] ?? fallback) { efforts.append("ultrathink") }
            }
            let defaultEffort = profile?.defaultEffort.flatMap { efforts.contains($0) ? $0 : nil }
            let hasMetadata = resolved != nil || supportsEffort != nil || supportsFast != nil || supportsAdaptive != nil || !nativeEfforts.isEmpty || profile != nil
            let metadata: ClaudeModelCapabilities? = hasMetadata ? .init(resolvedModel: resolved, description: description,
                supportsFastMode: supportsFast == true, supportsThinking: supportsAdaptive == true || profile?.thinking == true,
                contextWindows: profile?.contextWindows ?? [], minimumVersion: profile?.minimumVersion) : nil
            let model = ProviderModel(id: id, name: name,
                reasoningEfforts: efforts.map { .init(id: $0, description: effortLabel($0)) }, defaultReasoningEffort: defaultEffort,
                claudeCapabilities: metadata)
            if let previous = seen[id] { guard previous == model else { throw invalidCatalog() } }
            else { seen[id] = model; result.append(model) }
        }
        return result
    }

    static func compile(model: String, options: ClaudeModelOptions, models: [ProviderModel], version: String? = nil) throws -> CompiledClaudeModelSelection {
        try options.validate()
        if let minimum = profile(model)?.minimumVersion, let version, let comparison = compareVersions(version, minimum), comparison < 0 { throw ClaudeModelControl.unsupported() }
        // Empty options preserve the existing model/default path on old CLIs.
        guard !options.isEmpty else { return .init(model: model, effort: nil, promptEffort: nil, fastMode: nil, thinking: nil, ultracode: false, options: options) }
        let base = withoutContextSuffix(model)
        guard let advertised = models.first(where: { $0.id == model || withoutContextSuffix($0.claudeCapabilities?.resolvedModel ?? $0.id) == base }),
              let capabilities = advertised.claudeCapabilities else { throw ClaudeModelControl.unsupported() }
        let profile = profile(capabilities.resolvedModel ?? advertised.id)
        if let minimum = profile?.minimumVersion, let version, let comparison = compareVersions(version, minimum), comparison < 0 { throw ClaudeModelControl.unsupported() }
        if options.fastMode != nil, !capabilities.supportsFastMode { throw ClaudeModelControl.unsupported() }
        if options.thinking != nil, !capabilities.supportsThinking { throw ClaudeModelControl.unsupported() }
        if let context = options.contextWindow, !capabilities.contextWindows.contains(context) { throw ClaudeModelControl.unsupported() }
        if let effort = options.effort, !advertised.reasoningEfforts.contains(where: { $0.id == effort }) { throw ClaudeModelControl.unsupported() }
        let promptEffort = options.effort == "ultrathink" ? "ultrathink" : nil
        let effort: String?
        if options.effort == "ultracode" { effort = "xhigh" }
        else if options.effort == "ultrathink" { effort = profile?.defaultEffort.map { profile?.effortMap[$0] ?? $0 } }
        else { effort = options.effort.map { profile?.effortMap[$0] ?? $0 } }
        let wireModel: String
        if let context = options.contextWindow { wireModel = withoutContextSuffix(model) + (context == "1m" ? "[1m]" : "") }
        else { wireModel = model }
        return .init(model: wireModel, effort: effort, promptEffort: promptEffort, fastMode: options.fastMode,
            thinking: options.thinking, ultracode: options.effort == "ultracode", options: options)
    }

    static func effortLabel(_ value: String) -> String {
        switch value { case "xhigh": "Extra High"; case "ultrathink": "Ultrathink"; case "ultracode": "Ultracode"; default: value.capitalized }
    }
    private static func profile(_ value: String) -> Profile? {
        let normalized = withoutContextSuffix(value).lowercased()
        return profiles.first { $0.name == normalized || $0.aliases.contains(normalized) }
    }
    private static func withoutContextSuffix(_ value: String) -> String { value.hasSuffix("[1m]") ? String(value.dropLast(4)) : value }
    private static func compareVersions(_ first: String, _ second: String) -> Int? {
        func numbers(_ value: String) -> [Int]? {
            let pieces = value.split(separator: ".", omittingEmptySubsequences: false)
            guard pieces.count == 3, pieces.allSatisfy({ !$0.isEmpty && $0.utf8.count <= 8 && $0.utf8.allSatisfy { (48...57).contains($0) } }) else { return nil }
            let result = pieces.compactMap { Int($0) }; return result.count == 3 ? result : nil
        }
        guard let a = numbers(first), let b = numbers(second) else { return nil }
        for (left, right) in zip(a, b) where left != right { return left < right ? -1 : 1 }; return 0
    }
    private static func flag(_ value: JSONValue) throws -> Bool? {
        switch value { case .null: nil; case .bool(let result): result; default: throw invalidCatalog() }
    }
    private static func string(_ value: JSONValue, maximum: Int, allowEmpty: Bool = false, allowMultiline: Bool = false) throws -> String? {
        guard value != .null else { return nil }
        guard let text = value.string, text.utf8.count <= maximum, allowEmpty || !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              !text.unicodeScalars.contains(where: { $0.value == 0 || ((!allowMultiline || ![9, 10, 13].contains($0.value)) && ($0.value < 32 || $0.value == 127)) }) else { throw invalidCatalog() }
        return text
    }
    private static func invalidCatalog() -> CoincideError { .init("The Claude model catalog could not be read safely. Refresh models and try again.") }
}
