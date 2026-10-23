import Foundation

/// Provider payloads are transient. No templates, skill bodies or native error
/// text become catalog metadata, and conflicting names are never chosen first.
enum ProviderCommandCatalog {
    static func pi(_ value: JSONValue, cwd: String) throws -> ProviderCommandInventory {
        guard let rows = value["commands"].array, rows.count <= 4_000,
              (try JSONEncoder().encode(value)).count <= 4_194_304 else { throw ProviderCommandError(.invalidResponse) }
        var commands: [ProviderCommand] = [], skills: [ProviderSkill] = [], problems: [ProviderCommandProblem] = []
        for row in rows {
            let skill = row["source"] == .string("skill")
            do {
                let name = try text(row["name"], maximum: 256, required: true)!
                let description = try text(row["description"], maximum: 16_384, multiline: true) ?? ""
                let enabled = try boolean(row, "enabled") ?? true
                let invocable = try boolean(row, "userInvocable") ?? true
                if skill {
                    let actualName = name.hasPrefix("skill:") ? String(name.dropFirst(6)) : name
                    let info = row["sourceInfo"]
                    let path = try text(info["path"], maximum: 4_096) ?? text(row["path"], maximum: 4_096) ?? "pi:skill:" + actualName
                    let rawScope = try text(info["scope"], maximum: 128) ?? text(row["location"], maximum: 128) ?? ""
                    let scope: String
                    switch rawScope.lowercased() {
                    case "global", "personal": scope = "user"
                    case "workspace", "local": scope = "project"
                    default: scope = rawScope
                    }
                    let interface = row["interface"]
                    let display = try text(row["displayName"], maximum: 256) ?? text(info["displayName"], maximum: 256) ?? text(interface["displayName"], maximum: 256)
                    let short = try text(row["shortDescription"], maximum: 4_096, multiline: true) ?? text(info["shortDescription"], maximum: 4_096, multiline: true) ?? text(interface["shortDescription"], maximum: 4_096, multiline: true)
                    let value = ProviderSkill(name: actualName, path: path, displayName: display, description: description,
                        shortDescription: short, scope: scope, enabled: enabled, userInvocable: invocable, nativeID: name)
                    try value.validate(); skills.append(value)
                } else {
                    let source = try text(row["source"], maximum: 128, required: true)!
                    guard source == "extension" || source == "prompt" else { throw ProviderCommandError(.invalidResponse) }
                    if name == "compact" { continue } // Pi's TUI builtin owns this exact spelling.
                    let value = ProviderCommand(name: name, description: description, source: source,
                        enabled: enabled, userInvocable: invocable)
                    try value.validate(); commands.append(value)
                }
            } catch { try problem(&problems, skill ? .skills : .commands, "Invalid advertised metadata was omitted.") }
        }
        commands.insert(.init(name: "compact", description: "Summarize the conversation and reduce context usage",
            source: "builtin", hints: ["Optional instructions"]), at: 0)
        return try finish(cwd: cwd, commands: commands, skills: skills, problems: problems)
    }

    static func openCode(commands rows: JSONValue?, skills skillRows: JSONValue?, generation: OpenCodeGeneration,
                         cwd: String, problems initial: [ProviderCommandProblem] = []) throws -> ProviderCommandInventory {
        var commands: [ProviderCommand] = [], skills: [ProviderSkill] = [], problems = initial
        if let rows {
            guard let rows = rows.array, rows.count <= 2_000 else { throw ProviderCommandError(.invalidResponse) }
            for row in rows {
                do {
                    let name = try text(row["name"], maximum: 256, required: true)!
                    let source = try text(row["source"], maximum: 128)
                    let hints: [String]
                    if row["hints"] == .null { hints = [] }
                    else {
                        guard let values = row["hints"].array, values.count <= 32 else { throw ProviderCommandError(.invalidResponse) }
                        hints = try values.map { try text($0, maximum: 4_096, multiline: true, required: true)! }
                    }
                    let value = ProviderCommand(name: name,
                        description: try text(row["description"], maximum: 16_384, multiline: true) ?? "", source: source,
                        hints: hints, enabled: try boolean(row, "enabled") ?? true, userInvocable: try boolean(row, "userInvocable") ?? true)
                    try value.validate(); commands.append(value)
                } catch { try problem(&problems, .commands, "Invalid advertised command metadata was omitted.") }
            }
        }
        if let skillRows {
            guard let rows = skillRows.array, rows.count <= 2_000 else { throw ProviderCommandError(.invalidResponse) }
            for row in rows {
                do {
                    let displayName = try text(row["name"], maximum: 256, required: true)!
                    let nativeID = generation == .v2 ? try text(row["id"], maximum: 256, required: true)! : displayName
                    let name = generation == .v2 ? nativeID : displayName
                    let path = try text(row[generation == .v2 ? "path" : "location"], maximum: 4_096, required: true)!
                    let value = ProviderSkill(name: name, path: path, displayName: displayName == name ? nil : displayName,
                        description: try text(row["description"], maximum: 16_384, multiline: true) ?? "",
                        enabled: try boolean(row, "enabled") ?? true, userInvocable: try boolean(row, "userInvocable") ?? true,
                        nativeID: nativeID)
                    try value.validate(); skills.append(value)
                } catch { try problem(&problems, .skills, "Invalid advertised skill metadata was omitted.") }
            }
        }
        commands.removeAll { $0.name == "compact" }
        commands.insert(.init(name: "compact", description: "Summarize the conversation and reduce context usage",
            source: "builtin"), at: 0)
        return try finish(cwd: cwd, commands: commands, skills: skills, problems: problems)
    }

    static func selection(in text: String, inventory: ProviderCommandInventory) throws -> ProviderCommandSelection? {
        try inventory.validate()
        guard let parsed = try ProviderCommandSelection.parse(text) else { return nil }
        if inventory.problems.contains(where: { $0.component == .commands && $0.name == nil }) {
            throw ProviderCommandError(.unavailable)
        }
        if inventory.problems.contains(where: { $0.component == .commands && $0.name?.lowercased() == parsed.name.lowercased() }) {
            throw ProviderCommandError(.invalidResponse)
        }
        guard let command = inventory.commands.first(where: { $0.name == parsed.name }) else { return nil }
        guard command.canInvokeFromComposer else { throw ProviderCommandError(.unsupported) }
        return parsed
    }

    /// V1 exposes skills as commands. Its command API cannot attach arbitrary
    /// inline skills, so only a single leading advertised skill is representable.
    static func v1Selection(in text: String, inventory: ProviderCommandInventory) throws -> ProviderCommandSelection? {
        if let command = try selection(in: text, inventory: inventory) { return command }
        let ids = try skillIDs(in: text, inventory: inventory)
        guard !ids.isEmpty else { return nil }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let knownNames = Set(inventory.skills.map(\.name))
        let occurrences = try skillMentions(text, deduplicate: false).filter { knownNames.contains($0) }
        guard ids.count == 1, occurrences.count == 1, let skill = inventory.skills.first(where: { $0.nativeID == ids[0] }),
              trimmed.hasPrefix("$" + skill.name),
              trimmed.dropFirst(skill.name.count + 1).first.map({ $0.isWhitespace }) ?? true,
              let command = inventory.commands.first(where: { $0.name == skill.name && $0.source == "skill" }),
              command.canInvokeFromComposer else { throw ProviderCommandError(.unsupported) }
        return try .init(name: command.name, arguments: String(trimmed.dropFirst(skill.name.count + 1)).drop(while: { $0.isWhitespace }).description)
    }

    static func requiresInventory(_ text: String) throws -> Bool {
        let command = try ProviderCommandSelection.parse(text)
        if command != nil { return true }
        return !(try skillMentions(text)).isEmpty
    }

    static func skillIDs(in text: String, inventory: ProviderCommandInventory) throws -> [String] {
        try inventory.validate()
        let mentions = try skillMentions(text), names = Set(mentions)
        if !mentions.isEmpty, inventory.problems.contains(where: { $0.component == .skills && $0.name == nil }) {
            throw ProviderCommandError(.unavailable)
        }
        var result: [String] = []
        let byName = Dictionary(uniqueKeysWithValues: inventory.skills.map { ($0.name, $0) })
        for name in mentions {
            guard let skill = byName[name] else { continue }
            guard skill.canInvokeFromComposer, let id = skill.nativeID else { throw ProviderCommandError(.invalidResponse) }
            if !result.contains(id) { result.append(id) }
        }
        // A catalog conflict is explicit refusal; it must not silently turn a
        // selected native skill into an ordinary unmatched prose token.
        let folded = Set(names.map { $0.lowercased() })
        if inventory.problems.contains(where: { $0.component == .skills && $0.name.map({ folded.contains($0.lowercased()) }) == true }) {
            throw ProviderCommandError(.invalidResponse)
        }
        return result
    }

    static func skillMentions(_ text: String, deduplicate: Bool = true) throws -> [String] {
        guard text.utf8.count <= 4_194_304 else { throw ProviderCommandError(.invalidResponse) }
        let pattern = #"(^|\s)\p{Sc}(?![0-9][0-9_]*(?:[kKmMbBtT]|[eE][0-9]+)?(?:\s|$))(?=[a-zA-Z0-9:_-]*[a-zA-Z])([a-zA-Z0-9][a-zA-Z0-9:_-]*)(?=\s|$)"#
        let regex = try NSRegularExpression(pattern: pattern)
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        var result: [String] = []
        for match in regex.matches(in: text, range: range) {
            guard let range = Range(match.range(at: 2), in: text) else { throw ProviderCommandError(.invalidResponse) }
            let name = String(text[range]); if !deduplicate || !result.contains(name) { result.append(name) }
            guard result.count <= 256 else { throw ProviderCommandError(.invalidResponse) }
        }
        return result
    }

    private static func finish(cwd: String, commands: [ProviderCommand], skills: [ProviderSkill],
                               problems initial: [ProviderCommandProblem]) throws -> ProviderCommandInventory {
        var problems = initial
        let commands = try unique(commands, name: { $0.name }, component: .commands, problems: &problems)
        let skills = try unique(skills, name: { $0.name }, component: .skills, problems: &problems)
        let result = ProviderCommandInventory(cwd: cwd, commands: commands, skills: skills, problems: problems)
        try result.validate(); return result
    }
    private static func unique<T: Equatable>(_ rows: [T], name: (T) -> String, component: ProviderCommandProblem.Component,
                                             problems: inout [ProviderCommandProblem]) throws -> [T] {
        var seen: [String: T] = [:], ambiguous = Set<String>()
        for row in rows {
            let key = name(row).lowercased()
            if ambiguous.contains(key) { continue }
            if let prior = seen[key], prior != row {
                seen.removeValue(forKey: key); ambiguous.insert(key)
                guard problems.count < 256 else { throw ProviderCommandError(.invalidResponse) }
                problems.append(.init(component: component, name: name(row), message: "Conflicting advertised names were omitted. Refresh before invoking them."))
            } else { seen[key] = row }
        }
        var emitted = Set<String>()
        return rows.filter { let key = name($0).lowercased(); return !ambiguous.contains(key) && emitted.insert(key).inserted }
    }
    private static func problem(_ values: inout [ProviderCommandProblem], _ component: ProviderCommandProblem.Component, _ message: String) throws {
        guard values.count < 256 else { throw ProviderCommandError(.invalidResponse) }
        values.append(.init(component: component, message: message))
    }
    private static func text(_ value: JSONValue, maximum: Int, multiline: Bool = false, required: Bool = false) throws -> String? {
        if value == .null, !required { return nil }
        guard let result = value.string else { throw ProviderCommandError(.invalidResponse) }
        do { try SkillValidation.text(result, maximum: maximum, empty: !required, multiline: multiline) }
        catch { throw ProviderCommandError(.invalidResponse) }
        return result
    }
    private static func boolean(_ row: JSONValue, _ key: String) throws -> Bool? {
        guard let raw = row.object?[key] else { return nil }
        guard case .bool(let value) = raw else { throw ProviderCommandError(.invalidResponse) }
        return value
    }
}
