import Foundation

extension CodingThread {
    public mutating func selectClaudeModel(_ row: ProviderModel?) throws {
        guard provider == .claude else { throw ClaudeModelControl.invalidOptions() }
        guard let row else {
            model = ""; agentConfiguration = try ClaudeModelControl.setting(.init(), in: agentConfiguration); return
        }
        var options = try ClaudeModelControl.options(in: .init(thread: self))
        // A model switch retains each compatible choice, matching the native
        // model selector. Unsupported choices return to that model's defaults.
        if let effort = options.effort,
           (try? ClaudeModelControl.validate(.init(effort: effort), model: row)) == nil { options.effort = nil }
        if let fast = options.fastMode,
           (try? ClaudeModelControl.validate(.init(fastMode: fast), model: row)) == nil { options.fastMode = nil }
        if let thinking = options.thinking,
           (try? ClaudeModelControl.validate(.init(thinking: thinking), model: row)) == nil { options.thinking = nil }
        if let context = options.contextWindow,
           (try? ClaudeModelControl.validate(.init(contextWindow: context), model: row)) == nil { options.contextWindow = nil }
        try ClaudeModelControl.validate(options, model: row)
        model = row.id; agentConfiguration = try ClaudeModelControl.setting(options, in: agentConfiguration)
    }
    public mutating func selectClaudeModelOptions(_ options: ClaudeModelOptions, model row: ProviderModel) throws {
        guard provider == .claude,
              model.utf8.elementsEqual(row.id.utf8) || row.claudeCapabilities?.resolvedModel.map({ model.utf8.elementsEqual($0.utf8) }) == true else { throw ClaudeModelControl.invalidOptions() }
        try ClaudeModelControl.validate(options, model: row)
        agentConfiguration = try ClaudeModelControl.setting(options, in: agentConfiguration)
    }
}
