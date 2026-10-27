import Foundation

/// Claude models and their reasoning options, mirroring T3 Code's bundled model manifest.
///
/// The CLI's own model list (from the `initialize` handshake) decides which models are offered;
/// the catalog adds T3's effort options, defaults and context windows, and is the fallback list
/// when the CLI cannot be asked.
enum ClaudeModelCatalog {
    struct Profile: Sendable {
        /// Effort ids in increasing order, including T3's `ultracode` and `ultrathink` options.
        var efforts: [String]
        var defaultEffort: String?
        /// Efforts passed to the CLI as another level; a `nil` value passes no effort at all.
        var effortMap: [String: String?] = [:]
        var contextWindow: Int
        /// Appended to the model id to select the default context window, e.g. `[1m]`.
        var modelSuffix: String?
    }

    struct Entry: Sendable {
        var slug: String
        var name: String
        var aliases: [String]
        var isCurrent: Bool
        /// Oldest Claude Code version that knows the model.
        var minVersion: String?
        var profile: Profile
    }

    /// What to pass for one effort choice.
    struct EffortPlan: Sendable, Hashable {
        /// Value for `--effort` / `effortLevel`.
        var cliEffort: String?
        /// Ultracode: xhigh effort plus multi-agent workflow orchestration, a session setting.
        var ultracode = false
        /// Ultrathink has no CLI level; the prompt asks for it instead.
        var ultrathink = false
    }

    /// Effort levels Claude Code itself accepts.
    static let cliEfforts = ["low", "medium", "high", "xhigh", "max"]

    private static let effortsWithUltracode = cliEfforts + ["ultracode", "ultrathink"]
    private static let ultraMap: [String: String?] = ["ultracode": "xhigh", "ultrathink": nil]

    private static let fable5 = Profile(
        efforts: effortsWithUltracode, defaultEffort: "medium", effortMap: ultraMap, contextWindow: 1_000_000)
    private static let opus5 = Profile(
        efforts: effortsWithUltracode, defaultEffort: "high", effortMap: ultraMap, contextWindow: 1_000_000)
    private static let opus47 = Profile(
        efforts: cliEfforts + ["ultrathink"], defaultEffort: "xhigh", effortMap: ["xhigh": "max", "ultrathink": nil],
        contextWindow: 1_000_000)
    private static let opus46 = Profile(
        efforts: ["low", "medium", "high", "max", "ultrathink"], defaultEffort: "high", effortMap: ["ultrathink": nil],
        contextWindow: 1_000_000, modelSuffix: "[1m]")
    private static let opus45 = Profile(efforts: ["low", "medium", "high", "max"], defaultEffort: "high", contextWindow: 200_000)
    private static let sonnet5 = Profile(
        efforts: cliEfforts + ["ultrathink"], defaultEffort: "high", effortMap: ["ultrathink": nil], contextWindow: 1_000_000)
    private static let sonnet46 = Profile(
        efforts: ["low", "medium", "high", "max", "ultrathink"], defaultEffort: "high",
        effortMap: ["max": "high", "ultrathink": nil], contextWindow: 200_000)
    private static let haiku55 = Profile(
        efforts: cliEfforts + ["ultrathink"], defaultEffort: "medium", effortMap: ["ultrathink": nil], contextWindow: 1_000_000)
    private static let haiku45 = Profile(efforts: [], defaultEffort: nil, contextWindow: 200_000)

    /// T3's manifest order: current models first as listed there, then legacy ones.
    static let entries: [Entry] = [
        Entry(
            slug: "claude-opus-5-5", name: "Opus 5.5", aliases: ["opus", "opus-5.5", "claude-opus-5.5"], isCurrent: true,
            minVersion: "2.1.280", profile: fable5),
        Entry(
            slug: "claude-sonnet-5-5", name: "Sonnet 5.5", aliases: ["sonnet", "sonnet-5.5", "claude-sonnet-5.5"],
            isCurrent: true, minVersion: "2.1.284", profile: sonnet5),
        Entry(
            slug: "claude-fable-5-1", name: "Fable 5.1", aliases: ["fable", "fable-5.1", "claude-fable-5.1"], isCurrent: true,
            minVersion: "2.1.257", profile: fable5),
        Entry(
            slug: "claude-haiku-5-5", name: "Haiku 5.5", aliases: ["haiku", "haiku-5.5", "claude-haiku-5.5"], isCurrent: true,
            minVersion: "2.1.293", profile: haiku55),
        Entry(slug: "claude-fable-5", name: "Fable 5", aliases: [], isCurrent: false, minVersion: "2.1.169", profile: fable5),
        Entry(
            slug: "claude-opus-5", name: "Opus 5", aliases: ["opus-5", "claude-opus-5.0", "claude-opus-5-0"], isCurrent: false,
            minVersion: "2.1.219", profile: opus5),
        Entry(
            slug: "claude-opus-4-8", name: "Opus 4.8", aliases: ["opus-4.8", "claude-opus-4.8"], isCurrent: false,
            minVersion: "2.1.154", profile: opus5),
        Entry(
            slug: "claude-opus-4-7", name: "Opus 4.7", aliases: ["opus-4.7", "claude-opus-4.7"], isCurrent: false,
            minVersion: "2.1.111", profile: opus47),
        Entry(
            slug: "claude-opus-4-6", name: "Opus 4.6", aliases: ["opus-4.6", "claude-opus-4.6", "claude-opus-4-6-20251117"],
            isCurrent: false, profile: opus46),
        Entry(slug: "claude-opus-4-5", name: "Opus 4.5", aliases: [], isCurrent: false, profile: opus45),
        Entry(
            slug: "claude-sonnet-5", name: "Sonnet 5", aliases: ["sonnet-5", "claude-sonnet-5.0", "claude-sonnet-5-0"],
            isCurrent: false, profile: sonnet5),
        Entry(
            slug: "claude-sonnet-4-6", name: "Sonnet 4.6",
            aliases: ["sonnet-4.6", "claude-sonnet-4.6", "claude-sonnet-4-6-20251117"], isCurrent: false, profile: sonnet46),
        Entry(
            slug: "claude-haiku-4-5", name: "Haiku 4.5",
            aliases: ["haiku-4.5", "claude-haiku-4.5", "claude-haiku-4-5-20251001"], isCurrent: false, profile: haiku45),
    ]

    /// The model id that means "whatever Claude Code would pick".
    static let defaultModelID = "default"

    /// Finds a model by slug or alias, ignoring a context-window suffix such as `[1m]`.
    static func entry(for modelID: String?) -> Entry? {
        guard var value = modelID?.trimmingCharacters(in: .whitespaces), !value.isEmpty else { return nil }
        if let bracket = value.firstIndex(of: "[") { value = String(value[..<bracket]) }
        if let exact = entries.first(where: { $0.slug == value }) { return exact }
        let lowered = value.lowercased()
        return entries.first { $0.aliases.contains { $0.lowercased() == lowered } }
    }

    // MARK: Model lists

    /// Models from the CLI's `initialize` response, enriched with the catalog's options.
    static func models(fromInitialize rows: [JSONValue]) -> [ModelOption] {
        var seen = Set<String>()
        var models: [ModelOption] = []
        for row in rows {
            guard let value = row["value"]?.string, !value.isEmpty, seen.insert(value).inserted else { continue }
            let resolved = row["resolvedModel"]?.string
            let entry = entry(for: resolved) ?? entry(for: value)
            let cliLevels = row["supportsEffort"]?.bool == false ? [] : (row["supportedEffortLevels"]?.array ?? []).compactMap(\.string)
            let efforts: [String]
            if let entry {
                efforts = cliLevels.isEmpty ? entry.profile.efforts : entry.profile.efforts.filter { !cliEfforts.contains($0) || cliLevels.contains($0) }
            } else {
                efforts = cliLevels
            }
            let defaultEffort = entry?.profile.defaultEffort.flatMap { efforts.contains($0) ? $0 : nil }
            models.append(
                ModelOption(
                    provider: .claude, modelID: value, displayName: displayName(row: row, value: value, entry: entry),
                    efforts: efforts, defaultEffort: defaultEffort, contextWindow: entry?.profile.contextWindow))
        }
        return models
    }

    private static func displayName(row: JSONValue, value: String, entry: Entry?) -> String {
        let cliName = row["displayName"]?.string?.trimmingCharacters(in: .whitespaces)
        guard value == defaultModelID else { return cliName.flatMap { $0.isEmpty ? nil : $0 } ?? entry?.name ?? value }
        let description = row["description"]?.string?.components(separatedBy: " · ").first?.trimmingCharacters(in: .whitespaces)
        if let name = entry?.name ?? description, !name.isEmpty {
            return String(localized: "Default (\(name))")
        }
        return String(localized: "Default")
    }

    /// The built-in list used when the CLI cannot be asked: `default`, then T3's models the
    /// installed version knows. Current models use their short alias, like Claude Code's picker.
    static func fallbackModels(version: String?) -> [ModelOption] {
        var models = [
            ModelOption(provider: .claude, modelID: defaultModelID, displayName: String(localized: "Default"), efforts: cliEfforts)
        ]
        for entry in entries where isSupported(entry, version: version) {
            let id = entry.isCurrent ? entry.aliases.first ?? entry.slug : entry.slug
            models.append(
                ModelOption(
                    provider: .claude, modelID: id, displayName: entry.name, efforts: entry.profile.efforts,
                    defaultEffort: entry.profile.defaultEffort, contextWindow: entry.profile.contextWindow))
        }
        return models
    }

    private static func isSupported(_ entry: Entry, version: String?) -> Bool {
        guard let minVersion = entry.minVersion else { return true }
        guard let version else { return false }
        return compareVersions(version, minVersion) >= 0
    }

    /// T3's hint when the installed CLI is too old for a catalog model.
    static func upgradeMessage(version: String?) -> String? {
        let unavailable =
            entries
            .filter { entry in entry.minVersion.map { min in version.map { compareVersions($0, min) < 0 } ?? true } ?? false }
            .min { compareVersions($0.minVersion ?? "", $1.minVersion ?? "") < 0 }
        guard let unavailable, let minVersion = unavailable.minVersion else { return nil }
        if let version {
            return String(
                localized: "Claude Code v\(version) is too old for \(unavailable.name). Upgrade to v\(minVersion) or newer to use it.")
        }
        return String(localized: "The installed Claude Code is too old for \(unavailable.name). Upgrade to v\(minVersion) or newer to use it.")
    }

    // MARK: Launch values

    /// The value for `--model` / `set_model`, or nil to let Claude Code use its default.
    /// Aliases of current models pass through so they keep following the newest model.
    static func launchModel(for modelID: String) -> String? {
        let trimmed = modelID.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty, trimmed != defaultModelID else { return nil }
        guard !trimmed.contains("["), let entry = entry(for: trimmed), !entry.isCurrent else { return trimmed }
        return entry.slug + (entry.profile.modelSuffix ?? "")
    }

    /// Resolves an effort choice the way T3 compiles a Claude model selection. `resolvedModel` is
    /// the concrete model behind `default` or an alias, when the CLI reported it.
    static func effortPlan(modelID: String, resolvedModel: String?, effort: String?) -> EffortPlan {
        let requested = effort?.trimmingCharacters(in: .whitespaces).lowercased()
        guard let entry = entry(for: resolvedModel) ?? entry(for: modelID) else {
            return EffortPlan(cliEffort: requested.flatMap { cliEfforts.contains($0) ? $0 : nil })
        }
        let profile = entry.profile
        guard let chosen = requested.flatMap({ profile.efforts.contains($0) ? $0 : nil }) ?? profile.defaultEffort else {
            return EffortPlan()
        }
        let cliEffort = profile.effortMap.keys.contains(chosen) ? profile.effortMap[chosen] ?? nil : chosen
        return EffortPlan(cliEffort: cliEffort, ultracode: chosen == "ultracode", ultrathink: chosen == "ultrathink")
    }

    static func contextWindow(modelID: String, resolvedModel: String?) -> Int? {
        if modelID.lowercased().hasSuffix("[1m]") { return 1_000_000 }
        return (entry(for: resolvedModel) ?? entry(for: modelID))?.profile.contextWindow
    }

    /// Prefixes the prompt for the `ultrathink` effort, unless it starts with a slash command.
    static func applyUltrathink(to text: String) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !trimmed.hasPrefix("Ultrathink:"),
            trimmed.range(of: #"^/[^\s/]+(\s|$)"#, options: .regularExpression) == nil
        else { return text }
        return "Ultrathink:\n" + trimmed
    }

    // MARK: Versions

    /// Extracts `x.y.z` from output such as `2.1.308 (Claude Code)`.
    static func parseVersion(_ output: String) -> String? {
        guard let range = output.range(of: #"\d+\.\d+\.\d+"#, options: .regularExpression) else { return nil }
        return String(output[range])
    }

    static func compareVersions(_ lhs: String, _ rhs: String) -> Int {
        let left = lhs.split(separator: ".").map { Int($0.prefix { $0.isNumber }) ?? 0 }
        let right = rhs.split(separator: ".").map { Int($0.prefix { $0.isNumber }) ?? 0 }
        for index in 0..<max(left.count, right.count) {
            let a = index < left.count ? left[index] : 0
            let b = index < right.count ? right[index] : 0
            if a != b { return a < b ? -1 : 1 }
        }
        return 0
    }
}
