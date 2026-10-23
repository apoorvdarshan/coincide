import Foundation

/// SSH configuration contains no credentials. Remote POSIX paths are opaque to
/// this Mac: they are never expanded, resolved, opened or treated as local URLs.
public struct SSHRemoteEnvironmentConfiguration: Codable, Sendable, Equatable, Hashable {
    public var target: String
    public var port: Int?
    public var helperPath: String
    public var dataDirectory: String
    public init(target: String, port: Int? = nil, helperPath: String, dataDirectory: String) {
        self.target = target; self.port = port; self.helperPath = helperPath; self.dataDirectory = dataDirectory
    }
    public func validate() throws {
        let parts = target.split(separator: "@", omittingEmptySubsequences: false)
        guard (1...2).contains(parts.count), target.utf8.count <= 320,
              parts.allSatisfy({ !$0.isEmpty }),
              String(parts.last!).range(of: "^[A-Za-z0-9][A-Za-z0-9._-]{0,254}$", options: .regularExpression) != nil,
              parts.count == 1 || String(parts[0]).range(of: "^[A-Za-z_][A-Za-z0-9_.-]{0,63}$", options: .regularExpression) != nil,
              port.map({ (1...65_535).contains($0) }) ?? true else { throw RemoteEnvironmentClientError(.invalidConfiguration) }
        try Self.validatePath(helperPath); try Self.validatePath(dataDirectory)
        guard helperPath.split(separator: "/").last == "CoincideEnvironment" else {
            throw RemoteEnvironmentClientError(.invalidConfiguration)
        }
    }
    private static func validatePath(_ path: String) throws {
        guard path.hasPrefix("/"), path != "/", path.utf8.count <= 4_096,
              !path.unicodeScalars.contains(where: { $0.value < 32 || $0.value == 127 }),
              !path.split(separator: "/", omittingEmptySubsequences: false).dropFirst().contains(where: { $0.isEmpty || $0 == "." || $0 == ".." }) else {
            throw RemoteEnvironmentClientError(.invalidConfiguration)
        }
    }
}

public enum SSHRemoteEnvironment {
    public static func arguments(configuration: SSHRemoteEnvironmentConfiguration) throws -> [String] {
        try configuration.validate()
        var values = ["-T", "-o", "BatchMode=yes", "-o", "StrictHostKeyChecking=yes", "-o", "RequestTTY=no",
            "-o", "ClearAllForwardings=yes", "-o", "PermitLocalCommand=no", "-o", "ConnectTimeout=15",
            "-o", "ServerAliveInterval=15", "-o", "ServerAliveCountMax=2"]
        if let port = configuration.port { values += ["-p", String(port)] }
        let command = "exec " + quote(configuration.helperPath) + " --stdio --data-directory " + quote(configuration.dataDirectory)
        return values + ["--", configuration.target, command]
    }
    public static func makeClient(configuration: SSHRemoteEnvironmentConfiguration, expectedEnvironmentID: UUID? = nil) throws -> RemoteEnvironmentClient {
        let arguments = try arguments(configuration: configuration)
        return RemoteEnvironmentClient(factory: {
            try JSONRPCConnection(executable: URL(fileURLWithPath: "/usr/bin/ssh"), arguments: arguments,
                dialect: .jsonRPC2, maximumFrameSize: RemoteEnvironmentProtocol.maximumFrameBytes, drainProcessOnClose: true)
        }, expectedEnvironmentID: expectedEnvironmentID)
    }
    private static func quote(_ value: String) -> String { "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'" }
}
