import Foundation

/// The models an OpenCode server offers, turned into picker options the way T3 Code does.
enum OpenCodeCatalog {
    struct Snapshot: Sendable {
        var models: [ModelOption]
        /// Connected integrations, e.g. "Anthropic, OpenAI".
        var account: String?
    }

    /// Reads models, provider names and connected integrations.
    nonisolated static func load(api: OpenCodeAPI, directory: String) async throws -> Snapshot {
        let rawModels = try await settledModels(api: api, directory: directory)
        let providers = (try? await api.providers(directory: directory)) ?? []
        let integrations = (try? await api.integrations(directory: directory)) ?? []
        return Snapshot(
            models: models(from: rawModels, providers: providers),
            account: account(fromIntegrations: integrations))
    }

    /// Reads models until two reads agree. A cold server answers 503 until it has activated the
    /// directory's plugins (such as MCP servers), then may list a partial catalog for a moment.
    private nonisolated static func settledModels(api: OpenCodeAPI, directory: String) async throws -> [JSONValue] {
        let deadline = Date().addingTimeInterval(30)
        var settleBy: Date?
        var latest: [JSONValue] = []
        var previous: String?
        while true {
            do {
                let models = try await api.models(directory: directory)
                if !models.isEmpty {
                    let print = fingerprint(models)
                    if print == previous { return models }
                    previous = print
                    latest = models
                    settleBy = settleBy ?? Date().addingTimeInterval(5)
                }
            } catch let error as OpenCodeAPIError where error.isTransient && latest.isEmpty && Date() < deadline {
                // Still starting up.
            } catch {
                if !latest.isEmpty { return latest }
                throw error
            }
            let now = Date()
            if let settleBy, now >= settleBy { return latest }
            guard now < deadline else { return latest }
            try await Task.sleep(for: .milliseconds(latest.isEmpty ? 1_000 : 250))
        }
    }

    private nonisolated static func fingerprint(_ models: [JSONValue]) -> String {
        models.map { model in
            let variants = (model["variants"]?.array ?? []).compactMap { $0["id"]?.string }.sorted()
            return [model["providerID"]?.string ?? "", model["id"]?.string ?? "", model["name"]?.string ?? ""]
                .joined(separator: "|") + "|" + variants.joined(separator: ",")
        }.sorted().joined(separator: "\n")
    }

    /// Picker options from `GET /api/model`: enabled models sorted by name, with superseded releases of a
    /// family and deprecated models moved to the end. Names shared by several providers get the provider.
    nonisolated static func models(from list: [JSONValue], providers: [JSONValue]) -> [ModelOption] {
        var providerNames: [String: String] = [:]
        for provider in providers {
            if let id = provider["id"]?.string, let name = provider["name"]?.string { providerNames[id] = name }
        }

        struct Entry {
            var option: ModelOption
            var name: String
            var providerID: String
            var family: String?
            var released: Double?
            var deprecated: Bool
        }
        var entries: [Entry] = []
        for model in list {
            guard model["enabled"]?.bool != false, let providerID = model["providerID"]?.string,
                let id = model["id"]?.string
            else { continue }
            let name = (model["name"]?.string?.trimmingCharacters(in: .whitespaces)).flatMap { $0.isEmpty ? nil : $0 } ?? id
            let efforts = orderedEfforts((model["variants"]?.array ?? []).compactMap { $0["id"]?.string })
            let window = model.at("limit.input")?.int.flatMap { $0 > 0 ? $0 : nil } ?? model.at("limit.context")?.int
            let inputs = (model.at("capabilities.input")?.array ?? []).compactMap(\.string)
            let option = ModelOption(
                provider: .opencode, modelID: "\(providerID)/\(id)", displayName: name, efforts: efforts,
                defaultEffort: defaultEffort(providerID: providerID, efforts: efforts),
                contextWindow: window.flatMap { $0 > 0 ? $0 : nil }, supportsImages: inputs.contains("image"))
            entries.append(
                Entry(
                    option: option, name: name, providerID: providerID, family: model["family"]?.string,
                    released: model.at("time.released")?.number, deprecated: model["status"]?.string == "deprecated"))
        }

        var newest: [String: Double] = [:]
        for entry in entries where !entry.deprecated {
            guard let family = entry.family, let released = entry.released else { continue }
            let key = "\(entry.providerID)/\(family)"
            newest[key] = max(newest[key] ?? released, released)
        }
        let nameCounts = Dictionary(entries.map { ($0.name, Set([$0.providerID])) }, uniquingKeysWith: { $0.union($1) })

        var current: [ModelOption] = []
        var legacy: [ModelOption] = []
        for var entry in entries {
            if (nameCounts[entry.name]?.count ?? 0) > 1 {
                entry.option.displayName = "\(entry.name) (\(providerLabel(entry.providerID, names: providerNames)))"
            }
            let latest = entry.family.flatMap { newest["\(entry.providerID)/\($0)"] }
            let superseded = latest.map { latest in entry.released.map { $0 < latest } ?? false } ?? false
            if entry.deprecated || superseded {
                legacy.append(entry.option)
            } else {
                current.append(entry.option)
            }
        }
        let byName: (ModelOption, ModelOption) -> Bool = {
            $0.displayName.localizedStandardCompare($1.displayName) == .orderedAscending
        }
        return current.sorted(by: byName) + legacy.sorted(by: byName)
    }

    /// Context window per `provider/model` slug.
    nonisolated static func contextWindows(from list: [JSONValue]) -> [String: Int] {
        var windows: [String: Int] = [:]
        for model in list {
            guard let providerID = model["providerID"]?.string, let id = model["id"]?.string else { continue }
            let input = model.at("limit.input")?.int ?? 0
            let window = input > 0 ? input : model.at("limit.context")?.int ?? 0
            if window > 0 { windows["\(providerID)/\(id)"] = window }
        }
        return windows
    }

    /// "Default / OpenCode" names the account and the provider; show the provider.
    nonisolated static func providerLabel(_ providerID: String, names: [String: String]) -> String {
        guard let name = names[providerID], !name.isEmpty else { return providerID }
        return name.components(separatedBy: " / ").last ?? name
    }

    private nonisolated static let effortRank = ["none", "minimal", "low", "medium", "high", "xhigh", "max"]

    /// Variants in increasing order of effort; unknown ones keep their order after the known ones.
    nonisolated static func orderedEfforts(_ variants: [String]) -> [String] {
        let unique = variants.reduce(into: [String]()) { if !$0.contains($1) { $0.append($1) } }
        let known = unique.filter { effortRank.contains($0) }.sorted {
            effortRank.firstIndex(of: $0)! < effortRank.firstIndex(of: $1)!
        }
        return known + unique.filter { !effortRank.contains($0) }
    }

    /// T3 Code's default reasoning variant per provider.
    nonisolated static func defaultEffort(providerID: String, efforts: [String]) -> String? {
        if efforts.count == 1 { return efforts[0] }
        if providerID == "anthropic" || providerID.hasPrefix("google") {
            return efforts.contains("high") ? "high" : nil
        }
        if providerID == "openai" || providerID == "opencode" {
            return efforts.contains("medium") ? "medium" : efforts.contains("high") ? "high" : nil
        }
        return nil
    }

    /// Connected integrations from `GET /api/integration`, without MCP servers.
    nonisolated static func account(fromIntegrations integrations: [JSONValue]) -> String? {
        let names = integrations.compactMap { integration -> String? in
            guard let id = integration["id"]?.string, !id.hasPrefix("mcp_"),
                !(integration["connections"]?.array ?? []).isEmpty
            else { return nil }
            return integration["name"]?.string ?? id
        }
        return names.isEmpty ? nil : names.sorted { $0.localizedStandardCompare($1) == .orderedAscending }.joined(separator: ", ")
    }

    /// The version in `opencode --version` output, e.g. "opencode v2.1.4" → "2.1.4".
    nonisolated static func parseVersion(_ output: String) -> String? {
        guard let match = output.firstMatch(of: /v?(\d+\.\d+(?:\.\d+)?(?:[-+][0-9A-Za-z.\-]+)?)/) else { return nil }
        return String(match.1)
    }

    nonisolated static func majorVersion(_ version: String) -> Int? {
        Int(version.prefix { $0.isNumber })
    }

    /// Shown when the server cannot list its models: OpenCode's free model and common provider models,
    /// with their reasoning variants as OpenCode 2 reports them.
    nonisolated static let fallbackModels: [ModelOption] = [
        ModelOption(
            provider: .opencode, modelID: "opencode/big-pickle", displayName: "Big Pickle", contextWindow: 160_000,
            supportsImages: false),
        ModelOption(
            provider: .opencode, modelID: "anthropic/claude-sonnet-4-5", displayName: "Claude Sonnet 4.5",
            efforts: ["high", "max"], defaultEffort: "high", contextWindow: 200_000),
        ModelOption(
            provider: .opencode, modelID: "openai/gpt-5.5", displayName: "GPT-5.5",
            efforts: ["none", "low", "medium", "high", "xhigh"], defaultEffort: "medium", contextWindow: 272_000),
    ]
}
