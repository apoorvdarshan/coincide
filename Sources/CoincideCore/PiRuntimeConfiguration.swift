import Darwin
import Foundation

/// A reviewed launch/storage binding. No credentials or native settings bodies
/// are copied here. The version is observed separately by the owned process.
public struct PiRuntimeConfiguration: Codable, Sendable, Equatable, Hashable {
    public enum Profile: String, Codable, Sendable, Hashable { case settledEntriesV3 }
    public enum AgentDirectorySelection: Codable, Sendable, Equatable, Hashable {
        case defaultHome(homeDirectory: String)
        case explicitDirectory(environmentPath: String)
    }
    public enum SessionDirectorySelection: Codable, Sendable, Equatable, Hashable {
        /// Preserve native project/global settings intent, rather than guessing
        /// that the default always lives below agentDirectory/sessions.
        case nativeConfigured
        case explicitDirectory(environmentPath: String)
    }
    private struct Payload: Codable, Sendable, Equatable, Hashable {
        let instanceID: UUID
        let requestedExecutable: String
        let executable: String
        let workspacePath: String
        let registeredWorkspacePath: String
        let homeDirectory: String
        let agentDirectory: String
        let agentDirectorySelection: AgentDirectorySelection
        let sessionDirectory: String?
        let sessionDirectorySelection: SessionDirectorySelection
        let profile: Profile
    }

    /// Captures are embedded in several durable configuration/evidence values.
    /// Immutable indirection keeps those value copies bounded without changing
    /// their content semantics or introducing shared mutable configuration.
    private final class Storage: Sendable {
        let payload: Payload
        init(_ payload: Payload) { self.payload = payload }
    }
    private let storage: Storage

    public var instanceID: UUID { storage.payload.instanceID }
    public var requestedExecutable: String { storage.payload.requestedExecutable }
    public var executable: String { storage.payload.executable }
    public var workspacePath: String { storage.payload.workspacePath }
    public var registeredWorkspacePath: String { storage.payload.registeredWorkspacePath }
    public var homeDirectory: String { storage.payload.homeDirectory }
    public var agentDirectory: String { storage.payload.agentDirectory }
    public var agentDirectorySelection: AgentDirectorySelection { storage.payload.agentDirectorySelection }
    public var sessionDirectory: String? { storage.payload.sessionDirectory }
    public var sessionDirectorySelection: SessionDirectorySelection { storage.payload.sessionDirectorySelection }
    public var profile: Profile { storage.payload.profile }

    public init(instanceID: UUID, executable: String, requestedExecutable: String? = nil, workspacePath: String,
                registeredWorkspacePath: String? = nil, homeDirectory: String,
                agentDirectory: String, agentDirectorySelection: AgentDirectorySelection,
                sessionDirectory: String? = nil, sessionDirectorySelection: SessionDirectorySelection = .nativeConfigured,
                profile: Profile = .settledEntriesV3) throws {
        storage = Storage(.init(instanceID: instanceID, requestedExecutable: requestedExecutable ?? executable,
            executable: executable, workspacePath: workspacePath, registeredWorkspacePath: registeredWorkspacePath ?? workspacePath,
            homeDirectory: homeDirectory, agentDirectory: agentDirectory, agentDirectorySelection: agentDirectorySelection,
            sessionDirectory: sessionDirectory, sessionDirectorySelection: sessionDirectorySelection, profile: profile))
        try validate()
    }

    public init(from decoder: any Decoder) throws {
        storage = Storage(try Payload(from: decoder))
    }
    public func encode(to encoder: any Encoder) throws {
        try storage.payload.encode(to: encoder)
    }
    public static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.storage.payload == rhs.storage.payload
    }
    public func hash(into hasher: inout Hasher) {
        storage.payload.hash(into: &hasher)
    }

    public static func capture(workspacePath: String, executable: String = "pi", instanceID: UUID = UUID(),
                               environment: [String: String] = ProcessChannel.environment()) throws -> Self {
        let launcher: URL
        if executable.hasPrefix("/") { launcher = URL(fileURLWithPath: executable) }
        else {
            guard !executable.contains("/"), let found = (environment["PATH"] ?? "").split(separator: ":").lazy
                .map({ URL(fileURLWithPath: String($0)).appendingPathComponent(executable) })
                .first(where: { FileManager.default.isExecutableFile(atPath: $0.path) }) else { throw invalid() }
            launcher = found
        }
        let home = environment["HOME"] ?? NSHomeDirectory()
        let agentSelection: AgentDirectorySelection
        let rawAgent: String
        if let value = environment["PI_CODING_AGENT_DIR"], !value.isEmpty {
            agentSelection = .explicitDirectory(environmentPath: value); rawAgent = value
        } else { agentSelection = .defaultHome(homeDirectory: home); rawAgent = home + "/.pi/agent" }
        let sessionSelection: SessionDirectorySelection
        let session: String?
        if let value = environment["PI_CODING_AGENT_SESSION_DIR"], !value.isEmpty {
            sessionSelection = .explicitDirectory(environmentPath: value)
            session = try physical(expand(value, home: home), allowMissing: true)
        } else { sessionSelection = .nativeConfigured; session = nil }
        return try .init(instanceID: instanceID, executable: launcher.path, requestedExecutable: executable, workspacePath: physical(workspacePath),
            registeredWorkspacePath: workspacePath, homeDirectory: home,
            agentDirectory: physical(expand(rawAgent, home: home), allowMissing: true), agentDirectorySelection: agentSelection,
            sessionDirectory: session, sessionDirectorySelection: sessionSelection)
    }

    public func replacingWorkspace(_ registeredPath: String, physicalPath: String? = nil) throws -> Self {
        try .init(instanceID: instanceID, executable: executable, requestedExecutable: requestedExecutable, workspacePath: physicalPath ?? Self.physical(registeredPath),
            registeredWorkspacePath: registeredPath, homeDirectory: homeDirectory, agentDirectory: agentDirectory,
            agentDirectorySelection: agentDirectorySelection, sessionDirectory: sessionDirectory,
            sessionDirectorySelection: sessionDirectorySelection, profile: profile)
    }

    public func validate() throws {
        try PiConfiguration.identifier(requestedExecutable, maximum: 16_384)
        guard requestedExecutable.hasPrefix("/") || !requestedExecutable.contains("/"), !requestedExecutable.contains("://"),
              !requestedExecutable.contains("="), !requestedExecutable.contains(where: \.isWhitespace) || requestedExecutable.hasPrefix("/") else { throw Self.invalid() }
        if requestedExecutable.hasPrefix("/") { try Self.lexicalPath(requestedExecutable) }
        else { guard requestedExecutable != ".", requestedExecutable != ".." else { throw Self.invalid() } }
        for path in [executable, workspacePath, registeredWorkspacePath, homeDirectory, agentDirectory] { try Self.path(path) }
        for path in [executable, workspacePath, agentDirectory] { try Self.lexicalPath(path) }
        switch agentDirectorySelection {
        case .defaultHome(let home): guard home == homeDirectory else { throw Self.invalid() }
        case .explicitDirectory(let raw): _ = try Self.expand(raw, home: homeDirectory)
        }
        switch sessionDirectorySelection {
        case .nativeConfigured: guard sessionDirectory == nil else { throw Self.invalid() }
        case .explicitDirectory(let raw):
            _ = try Self.expand(raw, home: homeDirectory)
            guard let sessionDirectory else { throw Self.invalid() }; try Self.path(sessionDirectory)
        }
    }

    /// Preserve namespace spelling while independently checking its physical
    /// target before every spawn. Inherited defaults never become an override.
    public func environment(from inherited: [String: String] = ProcessChannel.environment()) throws -> [String: String] {
        try validate()
        guard try Self.physical(registeredWorkspacePath) == workspacePath else { throw Self.invalid() }
        let rawAgent: String
        var result = inherited; result["HOME"] = homeDirectory
        switch agentDirectorySelection {
        case .defaultHome: result.removeValue(forKey: "PI_CODING_AGENT_DIR"); rawAgent = homeDirectory + "/.pi/agent"
        case .explicitDirectory(let raw): result["PI_CODING_AGENT_DIR"] = raw; rawAgent = raw
        }
        guard try Self.physical(Self.expand(rawAgent, home: homeDirectory), allowMissing: true) == agentDirectory else { throw Self.invalid() }
        switch sessionDirectorySelection {
        case .nativeConfigured: result.removeValue(forKey: "PI_CODING_AGENT_SESSION_DIR")
        case .explicitDirectory(let raw):
            guard try Self.physical(Self.expand(raw, home: homeDirectory), allowMissing: true) == sessionDirectory else { throw Self.invalid() }
            result["PI_CODING_AGENT_SESSION_DIR"] = raw
        }
        return result
    }

    public static func supportsObservedVersion(_ value: String) -> Bool {
        guard value.utf8.count <= 32 else { return false }
        let parts = value.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 3, parts.allSatisfy({ !$0.isEmpty && $0.allSatisfy(\.isNumber) }),
              let major = UInt(parts[0]), let minor = UInt(parts[1]), let patch = UInt(parts[2]) else { return false }
        return major > 0 || minor > 80 || (minor == 80 && patch >= 5)
    }

    static func invalid() -> CoincideError { .init("The captured Pi runtime or storage namespace changed. Review its configuration before sending.") }
    static func path(_ value: String) throws {
        guard value.hasPrefix("/"), value.utf8.count <= 16_384,
              !value.unicodeScalars.contains(where: { $0.value < 32 || $0.value == 127 }),
              !value.split(separator: "/").contains(where: { $0 == "." || $0 == ".." }) else { throw invalid() }
    }
    static func lexicalPath(_ value: String) throws {
        try path(value)
        guard value == "/" || !value.split(separator: "/", omittingEmptySubsequences: false).dropFirst().contains(where: \.isEmpty) else { throw invalid() }
    }
    private static func expand(_ value: String, home: String) throws -> String {
        let expanded = value.hasPrefix("~/") ? home + String(value.dropFirst()) : value
        try path(expanded); return expanded
    }
    static func physical(_ path: String, allowMissing: Bool = false) throws -> String {
        try Self.path(path)
        var current = URL(fileURLWithPath: path).standardizedFileURL.path, suffix: [String] = []
        while true {
            if let pointer = current.withCString({ realpath($0, nil) }) {
                defer { free(pointer) }
                var result = String(cString: pointer)
                for component in suffix.reversed() { result = (result as NSString).appendingPathComponent(component) }
                return result
            }
            guard allowMissing, errno == ENOENT, current != "/" else { throw invalid() }
            suffix.append((current as NSString).lastPathComponent); current = (current as NSString).deletingLastPathComponent
        }
    }
}
