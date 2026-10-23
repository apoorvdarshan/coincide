import Foundation

/// Inline SDK settings belong to the immutable launch capture, rather than the
/// user's native settings files. Storage stays small in historical run values.
public struct ClaudeLaunchSettings: Codable, Sendable, Equatable, Hashable {
    private struct Payload: Codable, Sendable, Hashable { let autoCompactWindow: Int? }
    private let storage: [Payload]
    public var autoCompactWindow: Int? { storage[0].autoCompactWindow }
    public init(autoCompactWindow: Int? = nil) { storage = [.init(autoCompactWindow: autoCompactWindow)] }
    public init(from decoder: any Decoder) throws { storage = [try Payload(from: decoder)]; try validate() }
    public func encode(to encoder: any Encoder) throws { try validate(); try storage[0].encode(to: encoder) }
    public func validate() throws {
        if let autoCompactWindow, !(100_000...1_000_000).contains(autoCompactWindow) { throw ClaudeRuntimeProfile.invalid() }
    }
    /// Mirrors Agent SDK query settings lowering. The only permitted setting is
    /// numeric and cannot carry native credentials, hooks, or launch arguments.
    public func arguments() throws -> [String] {
        try validate()
        guard let autoCompactWindow else { return [] }
        return ["--settings", "{\"autoCompactWindow\":\(autoCompactWindow)}"]
    }
    /// get_settings reports the merged setting, not an observed compaction or
    /// the model's effective compaction trigger. Never retain its raw sources.
    public func validateEffective(_ response: JSONValue) throws {
        guard let requested = autoCompactWindow else { return }
        guard case .number(let value) = response["effective"]["autoCompactWindow"],
              value.isFinite, value == Double(requested) else { throw Self.unconfirmed() }
    }
    static func unconfirmed() -> CoincideError {
        .init("Claude could not confirm the requested auto-compact setting. No user input was submitted. Use the CLI default or choose a runtime that supports this setting.")
    }
}

/// Saved defaults for new captures only. No account data or native settings are
/// copied into this profile, and no filesystem access is needed to edit it.
public struct ClaudeRuntimeProfile: Codable, Sendable, Equatable {
    private struct Payload: Codable, Sendable, Equatable {
        let instanceID: UUID
        let executable: String
        let configurationDirectory: String?
        let autoCompactWindow: Int?
    }
    private let storage: [Payload]
    public var instanceID: UUID { storage[0].instanceID }
    public var executable: String { storage[0].executable }
    public var configurationDirectory: String? { storage[0].configurationDirectory }
    public var autoCompactWindow: Int? { storage[0].autoCompactWindow }
    public var launchSettings: ClaudeLaunchSettings? { autoCompactWindow.map { .init(autoCompactWindow: $0) } }
    public init(instanceID: UUID = ClaudeRuntimeConfiguration.defaultInstanceID, executable: String = "claude",
                configurationDirectory: String? = nil, autoCompactWindow: Int? = nil) {
        storage = [.init(instanceID: instanceID, executable: executable.isEmpty ? "claude" : executable,
            configurationDirectory: configurationDirectory?.isEmpty == true ? nil : configurationDirectory,
            autoCompactWindow: autoCompactWindow)]
    }
    public init(from decoder: any Decoder) throws { storage = [try Payload(from: decoder)]; try validate() }
    public func encode(to encoder: any Encoder) throws { try validate(); try storage[0].encode(to: encoder) }
    public func validate() throws {
        if executable.hasPrefix("/") { try ClaudeRuntimeValidation.path(executable) }
        else {
            guard (1...255).contains(executable.utf8.count), !executable.hasPrefix("-"), ![".", ".."].contains(executable),
                  executable.utf8.allSatisfy({ (48...57).contains($0) || (65...90).contains($0) || (97...122).contains($0) || [45,46,95,43].contains($0) }) else { throw Self.invalid() }
        }
        if let configurationDirectory {
            guard configurationDirectory != "/" else { throw Self.invalid() }
            try ClaudeConfigurationDirectorySelection.explicitDirectory(environmentPath: configurationDirectory).validate()
        }
        try launchSettings?.validate()
    }
    public func capture(workspacePath: String, environment: [String: String] = ProcessChannel.environment()) throws -> ClaudeRuntimeConfiguration {
        try validate()
        return try .capture(workspacePath: workspacePath, executable: executable, configurationDirectory: configurationDirectory,
            environment: environment, instanceID: instanceID, launchSettings: launchSettings)
    }
    public func editing(executable: String, configurationDirectory: String?, autoCompactWindow: Int?) throws -> Self {
        let normalizedExecutable = executable.isEmpty ? "claude" : executable
        let normalizedDirectory = configurationDirectory?.isEmpty == true ? nil : configurationDirectory
        let sameNamespace = self.executable.utf8.elementsEqual(normalizedExecutable.utf8) &&
            self.configurationDirectory.map { Array($0.utf8) } == normalizedDirectory.map { Array($0.utf8) }
        let result = Self(instanceID: sameNamespace ? instanceID : UUID(), executable: normalizedExecutable,
            configurationDirectory: normalizedDirectory, autoCompactWindow: autoCompactWindow)
        try result.validate(); return result
    }
    public static func invalid() -> CoincideError {
        .init("Choose a Claude executable name or absolute path, an optional absolute configuration folder, and an auto-compact threshold from 100,000 to 1,000,000 tokens.")
    }
}
