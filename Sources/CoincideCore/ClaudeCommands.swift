import Foundation

/// The Agent SDK's initialize/commands_changed SlashCommand metadata. The
/// native loader owns root, plugin and settings precedence; never infer a path
/// or read a command/skill body from these advertised names.
enum ClaudeCommands {
    static func inventory(_ value: JSONValue, cwd: String) throws -> ProviderCommandInventory {
        guard let rows = value.array, rows.count <= 2_000,
              try JSONEncoder().encode(value).count <= 4_194_304 else { throw ProviderCommandError(.invalidResponse) }
        var ordered: [ProviderCommand] = [], seen: [String: ProviderCommand] = [:], ambiguous: Set<String> = []
        var problems: [ProviderCommandProblem] = []
        for row in rows {
            do {
                guard row.object != nil, let name = row["name"].string,
                      let description = row["description"].string, let hint = row["argumentHint"].string else {
                    throw ProviderCommandError(.invalidResponse)
                }
                let aliases: [String]
                if row["aliases"] == .null { aliases = [] }
                else {
                    guard let values = row["aliases"].array, values.count <= 32 else { throw ProviderCommandError(.invalidResponse) }
                    aliases = try values.map { value in
                        guard let alias = value.string else { throw ProviderCommandError(.invalidResponse) }; return alias
                    }
                }
                var advertised: [ProviderCommand] = []
                for spelling in [name] + aliases {
                    let command = ProviderCommand(name: spelling, description: description, source: "native",
                        hints: hint.isEmpty ? [] : [hint])
                    try command.validate()
                    guard command.canInvokeFromComposer else { throw ProviderCommandError(.invalidResponse) }
                    advertised.append(command)
                }
                for command in advertised {
                    let key = command.name.lowercased()
                    guard !ambiguous.contains(key) else { continue }
                    if let previous = seen[key], previous != command {
                        seen.removeValue(forKey: key); ambiguous.insert(key)
                        try problem(&problems, name: command.name, message: "Conflicting native command names were omitted.")
                    } else if seen[key] == nil { seen[key] = command; ordered.append(command) }
                }
            } catch {
                try problem(&problems, message: "Invalid native command metadata was omitted.")
            }
        }
        let commands = ordered.filter { !ambiguous.contains($0.name.lowercased()) }
        let inventory = ProviderCommandInventory(cwd: cwd, commands: commands, skills: [], problems: problems)
        try inventory.validate(); return inventory
    }
    private static func problem(_ problems: inout [ProviderCommandProblem], name: String? = nil, message: String) throws {
        guard problems.count < 256 else { throw ProviderCommandError(.invalidResponse) }
        problems.append(.init(component: .commands, name: name, message: message))
    }
}
